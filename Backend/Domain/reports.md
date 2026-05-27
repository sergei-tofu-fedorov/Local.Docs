# Reports Domain

Report generation in `Invoices.Backend` (BFF). Routes live on `ReportsController` (`/api/reports`); domain logic in `Invoices.Common/Services/Reports/ReportsService.cs`.

## Endpoints

| Route | Returns | Source |
|---|---|---|
| `GET /api/reports/{type}` where `type` ∈ {`invoices_full_period_csv`, `invoices_full_period_pdf_zip`} | CSV / ZIP | All-clients invoices, full period |
| `GET /api/reports/clients/{clientId}/{type}` where `type` ∈ {`clients_invoices_full_period_csv`, `clients_invoices_full_period_pdf_zip`} | CSV / ZIP | Per-client invoices |
| `GET /api/reports/totalsByYears` | JSON `ReportByYears` | Invoices **+** payment requests |
| `GET /api/reports/stats/paid?clientId=` | JSON `InvoicesStatsDto` | Invoices **+** payment requests (PRs excluded when `clientId` is set) |
| `GET /api/reports/invoices/statement/paid?Year=&CurrencyCode=&ClientId=` | CSV | Paid invoices, filterable |
| `GET /api/reports/invoices/archive/paid?Year=&CurrencyCode=&ClientId=` | ZIP (streamed) | Paid invoices, filterable |
| `POST /api/reports/send` | — | Queues an email job carrying the same paid-invoices payload |

A backwards-compat alias `GET /api/v3/invoices/stats/paid` lives on `InvoicesController` and routes through the same service path; documented in `Backend/Api/INVOICES_API_REFERENCE.md`.

All routes require `PermissionKeys.Report.View` (`POST send` requires `PermissionKeys.Report.Send`).

The PDF-zip variants are also exposed via separate streaming routes that return the same data — see `ReportsController` for the full path list.

## Status filtering

Single shared constant in `ReportsService`:

```csharp
private static readonly InvoiceStatus[] PaidStatuses = [InvoiceStatus.Paid, InvoiceStatus.PaidByCard];
```

`InvoiceStatus` enum: `NotPaid`, `Paid`, `PaidByCard`, `Refunded`, `PartialRefunded`. `PaidStatuses` excludes the last three.

| Endpoint | Statuses included |
|---|---|
| `invoices_full_period_csv` / `_pdf_zip` | `PaidStatuses` |
| `clients_invoices_full_period_csv` / `_pdf_zip` | **all statuses** |
| `totalsByYears` (invoice side) | `PaidStatuses` |
| `stats/paid` (invoice side) | `PaidStatuses` |
| `invoices/statement/paid` / `archive/paid` | `PaidStatuses` + in-memory year/currency filter |

The per-client endpoints include drafts/refunds; the all-clients siblings do not. Asymmetric — same product feature, different scope, divergent semantics.

## Date basis

When invoices/PRs are bucketed by calendar (`totalsByYears`, `stats/paid`, and the year-filter on `statement/paid` / `archive/paid`):

```
date(invoice)        = invoice.PaidDate ?? invoice.MarkAsPaidDate ?? invoice.Date
date(paymentRequest) = pr.PaidDate ?? pr.CreatedDate
```

## Amount semantics

| Report | Amount used |
|---|---|
| CSV (all variants) | `Invoice.TotalAmount` (formatted), with separate `ReceivedPayments` / `TotalDue` columns. Projected via `InvoiceInfo.FromInvoice(invoice, accountCurrency)` |
| PDF ZIP (all variants) | n/a — renders the invoice template |
| `totalsByYears` / `stats/paid`, invoice contribution | `Invoice.Info.CalculatedTotalAmount` (= `invoice.CalculateTotals().totalAmount` recomputed in the producer) |
| `totalsByYears` / `stats/paid`, payment-request contribution | `pr.PaidAmount.GetValueOrDefault()` |

Stored `Invoice.TotalAmount` and computed `Info.CalculatedTotalAmount` *should* match (validated by `Invoice.ValidateTotals()`), but legacy data can drift. Aggregation paths use the computed value; CSV display uses the stored one.

## Currency resolution

`CurrencyHelper.GetCurrencyCode(invoice.CurrencyCode, accountCurrency)` — per-invoice value, falling back to the account's configured currency, then to USD. `accountCurrency` is loaded once per request via `IAccountsRepository.GetCurrencyCode(accountId)`.

CSV uses it inside `InvoiceInfo.FromInvoice`. `totalsByYears` and `stats/paid` use it in the shared `GetEntities` helper. Multi-currency accounts produce parallel buckets/rows; no FX conversion ever happens.

## Source composition

```
totalsByYears  =  paid_invoices(account)  ∪  paid_payment_requests(account)
                  ────────────────────────────────────────────────────────
                  if productKey == "Payments":  paid_payment_requests only

stats/paid     =  same as totalsByYears
                  ────────────────────────────────────────────────────────
                  if clientId is set:  paid_invoices(account, clientId) only
                                       (PaymentRequest has no ClientId field)
```

Both endpoints are served by `ReportsService.GetEntities(accountId, productKey, clientId, ct)` — single source of truth. CSV/PDF reports remain **invoice-only**: payment requests never appear in CSV rows, never contribute to PDF archives.

`Invoice.ReceivedPayments` is a `decimal[]` written only by client upserts. The PSP webhook flow (`PaymentIntentsService.InvoicePaymentSuccess`) flips status to `PaidByCard` and sets `PaidDate` but never appends to `ReceivedPayments`. PR-paid amounts therefore never indirectly leak into invoice totals via the document either.

## Aggregation formula (shared by `totalsByYears` and `stats/paid`)

```
T(y, m, c) = Σ amount(e)   for every paid entity e where
               year(date(e))  = y
               month(date(e)) = m
               currency(e)    = c

T(y, q, c) = Σ T(y, m, c)   for m ∈ months(q)        (totalsByYears only — quarters)
T(y, c)    = Σ T(y, m, c)   for m ∈ 1..12
T(c)       = Σ T(y, c)      for y ∈ years            (stats/paid only — currency totals)
```

Each entity contributes its full `amount(e)` to exactly one `(y, m, c)` cell — no proration across months, no partial-payment unrolling. `totalsByYears` adds a quarter rollup; `stats/paid` skips quarters and lets the frontend roll up if needed, plus rolls each currency up to a top-level total.

For zero-history accounts, `totalsByYears` scaffolds the current quarter with a single current-month entry; `stats/paid` returns an empty `byCurrency` array (no zero-fill).

`totalsByYears` emits quarters and months newest-first within a year and years descending; `stats/paid` emits years descending, months ascending (no quarter rollup).

## Known rough edges

- **`DateTime.Now` vs `DateTime.UtcNow` mixed** in `GetReportByYearsJson` — paid-on-Dec-31-23:00-UTC entities can shift cells when running in `+HH` zones.
- **`Month.Number` is the year-offset from current year**, not the calendar month. Misleading; iOS ignores the field.
- **Per-client CSV/PDF endpoints include all statuses**, while the all-clients siblings filter to `PaidStatuses`.
- **Partial received payments never appear in any paid report.** A `NotPaid` invoice with non-empty `ReceivedPayments` is income that arrived but is invisible to every export and to `totalsByYears`. There is no `PartiallyPaid` value in `InvoiceStatus`.

## Related

- WEB-875: introduced `stats/paid`, `statement/paid`, `archive/paid`, plus the V3 `/api/invoices/stats/paid` alias. Plan: `Tofu.Docs/features/WEB-875/README.md`.
- V3 alias documented in `Tofu.Docs/Backend/Api/INVOICES_API_REFERENCE.md` (until retired).
