# WEB-875 — API Reference (new endpoints)

API reference for the endpoints introduced by WEB-875. Existing endpoints (`/api/invoices/balances`, the legacy `/api/reports/...` routes, etc.) are documented in `Backend/Api/INVOICES_API_REFERENCE.md` and are not repeated here.

For the cross-cutting reports-domain reference (status filter, date basis, amount semantics, shared aggregation formula), see [`Backend/Domain/reports.md`](../../Backend/Domain/reports.md). This API doc captures the WEB-875 surface; the domain doc captures the steady-state contract.

**API versioning is header-based**, not path-based. Clients select the API version via the `Api-Version: 3` request header — there is no `/v3/` segment in the URL. The V3 stats alias requires `Api-Version: 3`; the canonical reports routes accept v1, v2, or v3.

**Target Audience**: Frontend Developers, Backend Developers, QA Engineers

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/reports/stats/paid` | [Get paid stats](#1-get-paid-stats) (totals by currency / year / month) — **canonical route** |
| GET | `/api/invoices/stats/paid` | [Get paid stats — V3 alias](#2-get-paid-stats--v3-alias) — backwards-compat alias for shipped clients |
| GET | `/api/reports/invoices/statement/paid` | [Get paid-invoices CSV statement](#3-get-paid-invoices-csv-statement) |
| GET | `/api/reports/invoices/archive/paid` | [Get paid-invoices PDF ZIP archive](#4-get-paid-invoices-pdf-zip-archive) (streamed) |

> **External clients note.** This BFF has consumers outside the workspace (iOS app at `C:\Git\Work\IOS\Invoices.Apps.iOS`, web frontend at `C:\Git\Work\Tofu.Web.Frontend`, possibly more). Any breaking change to these endpoints requires coordinated rollout with all of them; deprecating legacy endpoints (or the V3 alias below) requires waiting for the iOS App Store release cycle. See the plan README's [External BFF consumers](README.md#external-bff-consumers) section.

---

## 1. Get Paid Stats

Returns paid totals grouped by currency, then by year, then by month. Powers the frontend year/currency picker on the reports screen — the client picks `year` + `currency` from this response and passes them to the report endpoints.

The source set spans **paid invoices and paid payment requests** — same as `GET /api/reports/totalsByYears`. Both endpoints share `ReportsService.GetEntities`, so `stats/paid` and `totalsByYears` are byte-for-byte equivalent on overlapping data.

**Endpoint**: `GET /api/reports/stats/paid`

**Authorization**: requires `Report.View` permission (`[AuthorizeAction(PermissionKeys.Report.View)]`).

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `clientId` | string | No | Restrict stats to a single client. **Paid payment requests are excluded** when `clientId` is supplied because the `PaymentRequest` model has no `ClientId` field — the response then covers invoices for that client only. |

**Example Request**:

```
GET /api/reports/stats/paid
GET /api/reports/stats/paid?clientId=client_123
```

**Response**: `200 OK`

```json
{
  "byCurrency": [
    {
      "currencyCode": "USD",
      "totalAmount": 10950.00,
      "count": 8,
      "years": [
        {
          "year": 2026,
          "totalAmount": 3700.00,
          "count": 3,
          "months": [
            { "month": 1, "totalAmount": 1200.00, "count": 1 },
            { "month": 2, "totalAmount": 2500.00, "count": 2 }
          ]
        },
        {
          "year": 2025,
          "totalAmount": 7250.00,
          "count": 5,
          "months": [
            { "month": 3, "totalAmount": 3000.00, "count": 2 },
            { "month": 7, "totalAmount": 4250.00, "count": 3 }
          ]
        }
      ]
    }
  ]
}
```

**Response Fields** (`InvoicesStatsDto`):

| Field | Type | Description |
|-------|------|-------------|
| `byCurrency` | array | Stats grouped by currency |
| `byCurrency[].currencyCode` | string | ISO 4217 currency code (e.g. `USD`, `EUR`) |
| `byCurrency[].totalAmount` | decimal | Sum of amounts in this currency (paid invoice totals + paid payment-request amounts) |
| `byCurrency[].count` | integer | **Number of paid invoices in this currency. Payment requests are intentionally excluded from this field**, even though their amounts contribute to `totalAmount`. Matches the row count of `archive/paid` / `statement/paid` exports for the same filter. |
| `byCurrency[].years` | array | Per-year breakdown for this currency |
| `byCurrency[].years[].year` | integer | Calendar year |
| `byCurrency[].years[].totalAmount` | decimal | Sum of amounts in this year |
| `byCurrency[].years[].count` | integer | Number of paid invoices in this year. **Payment requests excluded** (same rule as the top-level `count`). |
| `byCurrency[].years[].months` | array | Per-month breakdown for this year |
| `byCurrency[].years[].months[].month` | integer | Month number, `1..12` |
| `byCurrency[].years[].months[].totalAmount` | decimal | Sum of amounts in this month |
| `byCurrency[].years[].months[].count` | integer | Number of paid invoices in this month. **Payment requests excluded** (same rule as the top-level `count`). |

**Notes**:
- **Source set for `totalAmount`**: paid invoices (`Paid` / `PaidByCard`) **plus** paid payment requests. For accounts on the `Payments` product (no invoices), only payment requests contribute to `totalAmount`.
- **Source set for `count`**: paid invoices only — payment requests are always excluded from `count`, regardless of `clientId`, `productKey`, or any other parameter. The intent is that `count` matches the number of rows that `archive/paid` / `statement/paid` would return for the same filter (those endpoints are invoice-only). For `Payments`-product accounts that have no invoices, `count` is always `0` even when `totalAmount` is non-zero.
- **`clientId` exclusion**: when `clientId` is set, payment requests drop out of `totalAmount` as well (they are not client-scoped); the response then covers invoices for that client only.
- **Date basis**: invoices use `PaidDate ?? MarkAsPaidDate ?? Date`; payment requests use `PaidDate ?? CreatedDate`.
- **Amount basis**: invoices contribute `Info.CalculatedTotalAmount` (recomputed from items in the producer); payment requests contribute `PaidAmount`.
- **Currency**: per-entity `CurrencyCode`, falling back to the account's configured currency, then to USD (`CurrencyHelper.GetCurrencyCode`).
- Years are emitted descending; months ascending within a year.
- Months with zero income are omitted (no zero-fill — unlike legacy `totalsByYears`, which pads the trailing 12 months).
- Totals at currency / year / month levels are pre-summed — clients can read any tier directly without re-aggregating.
- Localized labels (month names, quarter titles) are the frontend's responsibility — the response is purely numeric.
- **Replaces** `GET /api/reports/totalsByYears` for the new frontend; legacy `totalsByYears` stays active until external consumers migrate.

---

## 2. Get Paid Stats — V3 Alias

Backwards-compatible alias for [`GET /api/reports/stats/paid`](#1-get-paid-stats). Same response, same semantics, same server-side implementation — only the route differs. Kept on `InvoicesController` so already-shipped clients can keep working until they migrate to the canonical reports route.

**Endpoint**: `GET /api/invoices/stats/paid` — requires `Api-Version: 3` request header.

**Canonical equivalent**: `GET /api/reports/stats/paid` (preferred for new integrations).

Behaviour, query parameters, response shape, and notes are identical to the canonical route — see [section 1](#1-get-paid-stats). This alias will be retired in a follow-up once external consumers migrate.

---

## 3. Get Paid-Invoices CSV Statement

Returns a CSV statement of paid invoices, optionally filtered by year, currency, and client.

**Endpoint**: `GET /api/reports/invoices/statement/paid`

**Authorization**: requires `Report.View` permission.

**Query Parameters** (`InvoicesReportFilter`):

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Year` | integer | No | Calendar year filter (matches the date basis below) |
| `CurrencyCode` | string (enum) | No | `CurrencyCodeType` name (`USD`, `EUR`, …); invalid names produce 400 |
| `ClientId` | string | No | Restrict to a single client |

Query parameters are case-insensitive (`Year=2025` and `year=2025` both work).

**Example Request**:

```
GET /api/reports/invoices/statement/paid?Year=2025&CurrencyCode=USD
GET /api/reports/invoices/statement/paid?Year=2025&CurrencyCode=USD&ClientId=client_123
```

**Response**: `200 OK`

- `Content-Type: text/csv`
- `Content-Disposition: attachment; filename="[clientName_]paid_invoices[_year][_currency].csv"`
- Body: CSV with a header row plus one row per paid invoice.

**Notes**:
- **Invoice-only** — payment requests are not included in CSV exports (unlike `stats/paid` and `totalsByYears`).
- Paid statuses only — `Paid` and `PaidByCard`.
- Date basis: `PaidDate ?? MarkAsPaidDate ?? Date`.
- Currency resolved per-invoice via `CurrencyHelper.GetCurrencyCode(invoice.CurrencyCode, accountCurrency)` so invoices without an explicit currency are matched against the account default.
- All filters are optional — omitting all three returns every paid invoice for the account.

---

## 4. Get Paid-Invoices PDF ZIP Archive

Streams a ZIP archive containing one PDF per paid invoice directly to the response, optionally filtered by year, currency, and client. The archive is built on-the-fly — the full ZIP is never held in memory server-side.

**Endpoint**: `GET /api/reports/invoices/archive/paid`

**Authorization**: requires `Report.View` permission.

**Query Parameters** (`InvoicesReportFilter`):

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Year` | integer | No | Calendar year filter |
| `CurrencyCode` | string (enum) | No | `CurrencyCodeType` name (`USD`, `EUR`, …); invalid names produce 400 |
| `ClientId` | string | No | Restrict to a single client |

**Example Request**:

```
GET /api/reports/invoices/archive/paid?Year=2025&CurrencyCode=USD
GET /api/reports/invoices/archive/paid?Year=2025&CurrencyCode=USD&ClientId=client_123
```

**Response**: `200 OK`

- `Content-Type: application/zip`
- `Content-Disposition: attachment; filename="[clientName_]paid_invoices[_year][_currency].zip"`
- Body: ZIP archive, streamed; one PDF entry per matching invoice.

**Notes**:
- **Invoice-only** — payment requests have no PDF representation, so they cannot appear in archives.
- Paid statuses only — `Paid` and `PaidByCard`. Same date basis and currency resolution as the CSV statement endpoint.
- When the filter matches no invoices, the response is still `200 OK` with an empty ZIP archive.
- The buffered (non-streaming) variant from earlier iterations of this feature is **not** exposed; only this streaming endpoint exists for the PDF ZIP archive.

---

## Conventions

- **`paid` is a literal route segment, not yet a parameter.** It will likely become `{status}` in a follow-up once more statuses need exporting; until then, only `paid` is supported.
- **Status filter is server-enforced** — clients cannot ask for non-paid invoices through these endpoints.
- **The V3 alias** (`/api/invoices/stats/paid`) is intentionally not a separate code path — it routes through the same `IReportsService.GetPaidInvoicesStats` as the canonical route, so behaviour cannot diverge.
- **Authentication, error responses, and rate limiting** are handled globally and follow the conventions documented in `Backend/Api/INVOICES_API_REFERENCE.md`.
