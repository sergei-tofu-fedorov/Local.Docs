# WEB-875: Invoices Report

**Status:** in-progress
**ClickUp:** https://app.clickup.com/t/WEB-875
**Affected repos:**
- `Invoices.Backend` (BFF) — new `stats/paid`, `statement/paid`, `archive/paid` endpoints; `ReportsService` aggregation shared with `totalsByYears`. Branch `feature/WEB-875`.
- `Tofu.Docs` — this plan + `Backend/Domain/reports.md`.

## Overview

Adds a paid-invoices stats endpoint and two filter-aware paid-invoices report endpoints (CSV statement, streaming PDF ZIP archive) under `/api/reports/invoices/...`. Stats power the new frontend year/currency picker; reports export the slice the user picked. Legacy report endpoints stay untouched and active for now since several non-workspace clients (notably the iOS app) still depend on them — see [External BFF consumers](#external-bff-consumers).

**See also**:
- [`API.md`](API.md) — endpoint-by-endpoint reference for the four routes WEB-875 introduces (canonical `stats/paid`, V3 alias, CSV statement, streamed PDF archive).
- [`Backend/Domain/reports.md`](../../Backend/Domain/reports.md) — cross-cutting reports-domain reference (full endpoint inventory, status-filter table, date basis, amount semantics, shared aggregation formula).

This plan doc captures the WEB-875 deltas and decisions; `API.md` captures the wire contract; the domain doc captures the steady-state cross-feature behaviour.

## Scope

- **Paid stats endpoint** — invoice totals grouped by month+year and currency. Request: optional `clientId`. No `year` / `currency` filters — the client picks them from the response on the frontend.
- **Paid report endpoints** — exports paid invoices (CSV statement / PDF ZIP) filtered by `year` + `currency` (+ optional `clientId`).

### Stats endpoint — response contract

`GET /api/reports/stats/paid?clientId=...`. Lives on `ReportsController` because the source set spans both invoices and paid payment requests — same source as `totalsByYears`.

A backwards-compatible alias `GET /api/invoices/stats/paid` (v3) is kept on `InvoicesController` for already-shipped clients; both routes call into the same `IReportsService.GetPaidInvoicesStats` and return identical responses. The `/api/invoices/...` alias can be removed in a follow-up once external consumers have migrated.

Returns `InvoicesStatsDto`:

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

Shape notes:
- `year` is numeric (int); `month` is `1..12` numeric. Localized labels (month names, quarter titles) are the frontend's responsibility.
- Years are emitted descending; months ascending within a year.
- Months with no paid invoices are omitted — no zero-fill (unlike legacy `totalsByYears`, which pads the trailing 12 months).
- `totalAmount` at currency / year / month levels is the sum of the level below — frontend can use any tier directly without re-summing.
- `count` at every level is **paid-invoice count only** — payment requests never contribute to `count`, even though they contribute to `totalAmount`. This keeps `count` aligned with the row count of `archive/paid` / `statement/paid` exports for the same filter (those endpoints are invoice-only).

Conventions:
- `InvoicesStatsDto` is intentionally generic — although today it's only populated from paid stats, the DTO stays reusable for future non-paid variants. The "paid only" semantic is enforced server-side, not in the DTO name.
- Top-level `ByCurrency` mirrors existing per-currency arrays (`AmountByCurrencyDto`, `InvoicesBalancesDto.Balances`).
- Nested year → month with `TotalAmount` at each level; quarter rollup is the frontend's job.
- Replaces `GET /api/reports/totalsByYears`. Legacy endpoint can be deprecated once the frontend migrates.

### Stats source — BFF-local aggregation, parity with `totalsByYears`

`stats/paid` aggregates in `Invoices.Backend` itself, on top of the existing `IInvoicesGateway.GetAll` + `IPaymentRequestsService.GetPaidPaymentRequests`. The producer-side `Tofu.Invoices.GetPaidInvoicesStatsAsync` RPC exists but is **not called** from this BFF; the BFF reuses the same `ReportsService.GetEntities` source-loading that powers `totalsByYears`, so the two endpoints stay byte-for-byte equivalent on the invoice-side projection.

**Server-side guarantees** (verified against `totalsByYears` invoice contribution):
- Paid statuses only (`Paid`, `PaidByCard`).
- Source set for `totalAmount`: paid invoices **plus** paid payment requests, mirroring `totalsByYears`. For `productKey == "Payments"` accounts: only payment requests. When `clientId` is supplied, payment requests are excluded (the `PaymentRequest` model has no `ClientId` field).
- Source set for `count`: paid invoices only. Payment requests are excluded from `count` unconditionally — irrespective of `clientId` or `productKey`. For `Payments`-product accounts, `count` is always `0` even when `totalAmount` is non-zero. This keeps `count` aligned with the export endpoints (`archive/paid` / `statement/paid`), which are invoice-only.
- Date basis: invoices use `PaidDate ?? MarkAsPaidDate ?? Date`; payment requests use `PaidDate ?? CreatedDate`.
- Amount basis: `Info.CalculatedTotalAmount` for invoices (recomputed in the producer at gRPC mapping time); `PaidAmount` for payment requests.
- Currency: `CurrencyHelper.GetCurrencyCode(entity.CurrencyCode, accountCurrency)` — per-entity value, falling back to the account's configured currency, then to USD. Matches `totalsByYears`.

The shared helper lives in `ReportsService.GetEntities(accountId, productKey, clientId, ct)`; both `GetReportByYearsJson` and `GetPaidInvoicesStats` call it. `ProjectPaidInvoice` is the single-source-of-truth projection for invoices.

**Producer RPC — deferred.** The `GetPaidInvoicesStatsAsync` proto/handler in `Tofu.Invoices.Backend` are kept in place but unused from this BFF. A future iteration may swap to the producer's server-side aggregation; doing so requires either (a) extending the proto with `account_currency_code` so the producer can apply the same fallback, or (b) post-processing per-currency buckets at the BFF. Out of scope for this iteration.

`GetReport` (P&L) is left untouched — different semantics.

### Report endpoints — new filter-aware surface

Two `GET` endpoints on `ReportsController` (`/api/reports/...`), alongside the legacy report routes which stay untouched in this iteration.

```
GET /api/reports/invoices/statement/paid?Year=&CurrencyCode=&ClientId=    -> text/csv
GET /api/reports/invoices/archive/paid?Year=&CurrencyCode=&ClientId=      -> application/zip   (streamed)
```

Query parameters: ASP.NET Core model binding is case-insensitive — `Year=2025` and `year=2025` both work. `CurrencyCode` is the `CurrencyCodeType` enum, parsed by name (`USD`, `EUR`, …); invalid names produce a 400.

- `invoices/statement/paid` returns a CSV statement of paid invoices.
- `invoices/archive/paid` writes a ZIP containing one PDF per paid invoice on-the-fly to `Response.Body` — no full archive held in memory. Mirrors the existing `stream/invoices_full_period_pdf_zip` pattern. Only the streaming variant is exposed; no buffered counterpart.
- Both set `Content-Disposition: attachment` with a constructed filename: `[clientName_]paid_invoices[_year][_currency].csv|.zip`.

**Route shape — `paid` is a literal, not yet a parameter.** Hardcoded `/paid` segment for this iteration. The intent is to lift it to a `{status}` route parameter later (e.g. `invoices/statement/{status}`) when more statuses need exporting; until then keep it static so the controller stays simple.

**Status filter — paid only.** Both endpoints push `Statuses = [Paid, PaidByCard]` down to `IInvoicesGateway.GetAll`. The `paid` segment makes the semantic explicit at the boundary.

**Legacy report routes stay untouched** — `GET /api/reports/{type}`, `GET /api/reports/clients/{clientId}/{type}`, `GET /api/reports/invoices/archive`, `GET /api/reports/clients/{clientId}/invoices/archive`, `GET /api/reports/stream/...`, and `POST /api/reports/send` stay untouched in this iteration. Deprecation happens after **all** consumers (web frontend + iOS + any other external clients — see [External BFF consumers](#external-bff-consumers)) cut over to the new endpoints.

#### Shared filter

```csharp
sealed record InvoicesReportFilter
{
    int? Year;
    CurrencyCodeType? CurrencyCode;
    string? ClientId;
}
```

`ClientId` pushes down to `GetAll`. `Year` and `CurrencyCode` are applied API-side. Date basis matches the stats endpoint: `PaidDate ?? MarkAsPaidDate ?? Date`. Currency is resolved per-invoice with `CurrencyHelper.GetCurrencyCode(invoice.CurrencyCode, accountCurrency)` so invoices without an explicit currency match the account's default.

> **Known performance limitation:** the API fetches *all* paid invoices for the account (only `ClientId` and `Statuses` push to the gateway), then filters by `Year` / `CurrencyCode` in memory. Acceptable for current account sizes; revisit if export volume grows.

#### Tofu.Invoices contract — no change

Reuse `IInvoicesGateway.GetAll` as-is. `ClientId` and `Statuses` push down to the gRPC call; `Year` and `CurrencyCode` filter in-process.

#### Deferred

- `POST /api/reports/invoices/paid/send` — async/queued variant that emails the report. Will reuse `InvoicesPdfZipReportOperationHandler` / `ClientInvoicesPdfZipReportOperationHandler` with an extended payload carrying `InvoicesReportFilter`. Not in this iteration.

#### Legacy routes

`GET /api/reports/{type}`, `GET /api/reports/clients/{clientId}/{type}`, `GET /api/reports/invoices/archive`, `GET /api/reports/clients/{clientId}/invoices/archive`, `GET /api/reports/stream/...`, and `POST /api/reports/send` stay untouched in this iteration. Deprecation happens **only after every external BFF consumer** (see below) has cut over to `/api/reports/invoices/statement/paid` and `/api/reports/invoices/archive/paid`.

## External BFF consumers

`Invoices.Backend` (this BFF) is consumed by clients that live **outside** this workspace (`C:\Git\Work\Backend\`). Any change to a public endpoint — addition, rename, removal, response-shape change — has to be planned with all of them in scope, not just the web frontend that lives alongside the backend repos.

Known consumers (paths are local checkouts on the dev machine; treat them as pointers to the actual repos):

| Client | Local path | Notes |
|--------|-----------|-------|
| iOS app | `C:\Git\Work\IOS\Invoices.Apps.iOS` | Native iOS, separate repo. Calls the BFF directly. Ships independently of backend deploys, so deprecating an endpoint requires waiting for an iOS App Store release that has migrated. |
| Web frontend | `C:\Git\Work\Tofu.Web.Frontend` | Web client. Generally moves in lockstep with the backend (closest to a "lockstep deploy"), but still a separate repo. |
| Other / Android | _confirm with team_ | Add to this list as we identify them. |

**Implications for WEB-875:**
- New endpoints (`statement/paid`, `archive/paid`, `stats/paid`) are purely additive — no immediate impact on iOS / other clients.
- Legacy endpoints **must remain working** until each external client has cut over. The web frontend is fast to migrate; iOS is the long pole because it ships through the App Store. Plan deprecation around the iOS release cycle, not the backend deploy cycle.
- Any breaking change here (renumbering a proto, changing response field types, removing a query param, etc.) requires explicit coordination with the iOS team. None of this iteration's changes are breaking — confirmed.

**Pre-deprecation checklist** (for the eventual follow-up that removes legacy report endpoints):

1. Confirm web frontend has migrated to `statement/paid` / `archive/paid`.
2. Confirm iOS has shipped a build that uses the new endpoints, **and** that older iOS builds in the field have aged out (App Store min-supported-version policy).
3. Verify analytics / logs show no traffic on the legacy routes for at least the agreed sunset window.
4. Only then remove the legacy controller actions in a follow-up ticket.

## Plan

### Invoices.Backend
1. [x] `ReportsController` — add `invoices/statement/paid` (CSV) and `invoices/archive/paid` (streamed PDF ZIP) routes; share metadata/filename helpers.
2. [x] `ReportsController` — add canonical `[HttpGet("stats/paid")]` returning `InvoicesStatsDto`; calls `IReportsService.GetPaidInvoicesStats` directly.
3. [x] V3 `InvoicesController` — keep `[HttpGet("stats/paid")]` as a backwards-compat alias for shipped clients; routes through the same `IReportsService.GetPaidInvoicesStats`. To be retired in a follow-up once external consumers cut over.
4. [x] `ReportsService` — add `LoadFilteredPaidInvoices` + `MatchesFilter` (year/currency in-memory) and `BuildInvoicesCsvBytes` reusable for both legacy and filtered CSV.
5. [x] `ReportsService` — extract `ProjectPaidInvoice` helper; `GetEntities` accepts optional `clientId` and gates PR fetch on it; `GetReportByYearsJson` reuses the same path; new `GetPaidInvoicesStats(accountId, productKey, clientId, ct)` consumes the same `GetEntities` and groups into `InvoiceStatsItem[]`.
6. [x] `IReportsService` — add `GetPaidInvoicesStats(accountId, productKey, clientId, ct)`.
7. [x] Auth fix — add `[AuthorizeAction(PermissionKeys.Report.View)]` to `invoices/statement/paid` and `invoices/archive/paid` (matching every other route on `ReportsController`).
8. [x] Drop dead code: `IInvoicesGateway.GetPaidStats`, `InvoicesGateway.GetPaidStats`, `IInvoicesService.GetPaidStats`, `InvoicesService.GetPaidStats`, `Tofu.Invoices/Mapping/Mapper.cs` stats arms (no longer called from this BFF). `GetPaidInvoicesStatsRequestModel` deleted (unused).
9. [x] Integration tests — four `PaidStats_*` cases (aggregation, empty, PR merge, clientId-excludes-PRs) in a new `ReportsControllerTests` test class targeting `IReportsClient.GetPaidStatsAsync`. `MockSetup` gained `IPaymentRequestsService` mock + `SetupGetPaidPaymentRequests` helper + multi-invoice `SetupGetAllInvoices(IReadOnlyCollection<InvoiceObj>)` overload.
10. [x] `/feature lint` (default + `--deep`): `dotnet build` with `TreatWarningsAsErrors`, `dotnet format`, `dotnet format analyzers`, and `jb inspectcode` — all green on feature-changed files.
11. [x] `/feature review` — additive only on REST/proto/Mongo/queue/config; internal-only churn on the C# surface; no breaking changes.

### Tofu.Docs
1. [x] `Backend/Domain/reports.md` — domain reference for the reports surface.
2. [x] `features/WEB-875/README.md` — this plan.
3. [ ] _Follow-up_: create `Backend/Api/REPORTS_API_REFERENCE.md` covering the full `ReportsController` surface (legacy + new). `INVOICES_API_REFERENCE.md` only documents the V3 alias for `stats/paid`.

### Follow-up — `count` = invoices only

Original WEB-875 ship counted invoices + paid payment requests in `count`, which diverges from the export endpoints (`archive/paid` / `statement/paid`) that are invoice-only. Frontend shows "N paid items" via stats but the CSV/ZIP contains fewer entries.

Fix: `count` at every level (`byCurrency`, `byCurrency[].years`, `byCurrency[].years[].months`) counts only paid invoices. `totalAmount` semantics are **unchanged** — invoices + payment requests, mirroring `totalsByYears`. Applies unconditionally — no dependency on `clientId` or `productKey`.

1. [ ] `ReportsService.GetPaidInvoicesStats` — split the accumulator: `count` increments only when projecting a paid invoice; `totalAmount` increments for both invoices and payment requests. Verify month / year / currency rollups all use the same invoice-only count.
2. [ ] Integration tests in `ReportsControllerTests`:
   - Extend `PaidStats_IncludesPaidPaymentRequests_AlongsideInvoices` — assert `totalAmount` includes the PR amount **but** `count` excludes it.
   - Add `PaidStats_PaymentsProductAccount_HasZeroCount_NonZeroTotal` — covers the `Payments` product where only PRs exist.
   - Extend `PaidStats_WithClientId_ExcludesPaymentRequests` — assert `count` matches invoice count (already implicitly true when `clientId` filters PRs out; make the assertion explicit).
3. [ ] `/feature lint` and `/feature review` on the change.

## Test plan

- **Integration tests** (in `Invoices.IntegrationTests/Tests/Controllers/ReportsControllerTests.cs`):
  - `PaidStats_WithMultipleCurrenciesAndMonths_AggregatesIntoNestedTree` — multi-currency, multi-year invoice grouping with descending years and ascending months.
  - `PaidStats_WithNoSourceData_ReturnsEmptyByCurrency` — empty source returns empty `ByCurrency`.
  - `PaidStats_IncludesPaidPaymentRequests_AlongsideInvoices` — invoice + PR merge into one currency bucket.
  - `PaidStats_WithClientId_ExcludesPaymentRequests` — PRs are dropped when `clientId` is supplied.
- **Mocks** (`MockSetup`): added `Mock<IPaymentRequestsService>` registration with default empty list, plus `SetupGetPaidPaymentRequests(...)` and a multi-invoice `SetupGetAllInvoices(IReadOnlyCollection<InvoiceObj>)` overload.
- **V3 alias** is intentionally not separately tested — it routes through the same `IReportsService.GetPaidInvoicesStats`, so the canonical-route tests prove behaviour for both.
- **Manual verification**: not required — the integration tests cover the contract end-to-end.

## Open questions

- [ ] Should `Tofu.Invoices.GetPaidInvoicesStatsAsync` (producer RPC) be removed in a follow-up, or kept for future server-side aggregation? See "Producer RPC — deferred" above.
- [ ] Frontend ETA for cutting over from `totalsByYears` to `stats/paid`. Drives when legacy can be deprecated.
- [ ] When does the `GET /api/invoices/stats/paid` V3 alias get retired? Same dependency on external-consumer migration as the legacy report routes.
