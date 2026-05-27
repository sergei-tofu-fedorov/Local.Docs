# FSM Compatibility — API Reference

DeepSeek-backed classifier that labels an account's industry, narrow
specialization, and Field-Service-Management product fit from its invoice
line items and notes. Sibling feature to the AI Summary job backfill (see
`README.md`).

Three endpoints live on the controller:

| Route                                        | Purpose                                                                             |
|----------------------------------------------|-------------------------------------------------------------------------------------|
| `GET /api/FsmCompatibility`                  | Classify industry / specialization / FSM fit (LLM call, cached per account).        |
| `GET /api/FsmCompatibility/stats`            | Headline invoice-history numbers (count, billed, clients) over the last 90 days.    |
| `GET /api/FsmCompatibility/estimates-stats`  | Headline estimates-history numbers (count, total value, clients) over the last 90 days. |

## `GET /api/FsmCompatibility`

```
GET /api/FsmCompatibility            (ApiVersion 3.0)
```

- Controller: `Src/Invoices.Api/Controllers/FsmCompatibilityController.cs`
- Service:   `Src/Invoices.Implementation.Services/FsmCompatibility/FsmCompatibilityService.cs`
- No request body, no query parameters. The account is resolved from the
  standard auth/middleware pipeline (`BaseController.AccountId`).

First call triggers a DeepSeek classification and persists the result in
`fsmCompatibilityRecords`. Subsequent calls for the same account are served
from that cache (no LLM call, `elapsedMs` reflects cache-hit latency only).

## Response envelope

All BFF responses pass through `ResultWrapperFilter`, which wraps the
payload as:

```json
{
  "result": { /* FsmCompatibilityResult */ }
}
```

Property names are camel-cased (`CamelCasePropertyNamesContractResolver` is
installed globally for Newtonsoft.Json).

## Response body — `FsmCompatibilityResult`

| Field                | Type               | Notes |
|----------------------|--------------------|-------|
| `accountId`          | string             | Echo of the calling account id. |
| `invoicesAnalyzed`   | int                | Non-deleted invoices fetched for the account at classification time. |
| `distinctItems`      | int                | Count of unique invoice line-item names sent to the LLM (capped by `DeepSeek:MaxItemsPerAccount`, default 200). |
| `notesSampled`       | int                | Count of distinct invoice notes sent to the LLM (capped by `DeepSeek:MaxNotesPerAccount`, default 50). |
| `industry`           | string             | Broad industry label, e.g. `"Home Services"`, `"Event & Party Rental"`, `"Retail"`, `"Professional Services"`. `"Unknown"` if the LLM omits it. |
| `specialization`     | string             | Narrow trade/vertical inside `industry`, e.g. `"Plumbing"`, `"HVAC"`, `"Bounce House Rental"`, `"Wedding Photography"`. Title Case, 1-4 words. `"Unknown"` when evidence is too thin. |
| `fsmFit`             | string enum        | See enum table below. Serialized as a lowercase string (not an integer). |
| `reasoning`          | string             | 1-2 sentences from the LLM citing the items or notes that drove the call. |
| `elapsedMs`          | long               | Total service time in milliseconds — includes the DeepSeek round-trip on a cache miss, or just the Mongo lookup on a cache hit. |

### `fsmFit` enum values

The enum is declared in `Invoices.Core.Services.FsmFit` and decorated with
`[JsonConverter(typeof(StringEnumConverter))]` so it serializes as a
lowercase string — matching the convention used by `JobStatusDto`,
`VisitStatusDto`, and the rest of the BFF.

| Wire value | Meaning |
|------------|---------|
| `"strong"` | Business dispatches people for on-site work (HVAC, plumbing, cleaning, landscaping, pest control, electrical, appliance repair, pool service). |
| `"weak"`   | Business delivers or rents things but does not really dispatch technicians (event rental, product resale, photography). |
| `"none"`   | Pure digital, consulting, or retail. Also the fallback when the LLM returns an unrecognized label. |

### Example

```json
{
  "result": {
    "accountId": "5f9d4a3b7e2c1a0b8c7d6e5f",
    "invoicesAnalyzed": 17,
    "distinctItems": 42,
    "notesSampled": 12,
    "industry": "Home Services",
    "specialization": "Plumbing",
    "fsmFit": "strong",
    "reasoning": "Line items reference drain clearing, water-heater installs, and burst-pipe repairs; notes repeatedly mention on-site access and scheduled visits.",
    "elapsedMs": 1843
  }
}
```

## Error responses

Errors flow through `ApiExceptionHandlingMiddleware` and are returned inside
the standard envelope.

| Condition | HTTP | Envelope error code | Notes |
|-----------|------|---------------------|-------|
| Account has fewer than `DeepSeek:MinInvoicesBeforeAnalysis` non-deleted invoices (default 2). | `200` | `badRequest` | Thrown by `NotEnoughInvoicesForFsmCompatibilityException`; logged at Information. No DeepSeek call is made. |
| Account has invoices but zero line items and zero notes after filtering. | `500` | (generic) | `InvalidOperationException`, treated as an unexpected state. |
| DeepSeek returns a non-2xx status, non-JSON content, or an empty message. | `500` | (generic) | Upstream failure; logged at Warning with the response body. |

## `GET /api/FsmCompatibility/stats`

```
GET /api/FsmCompatibility/stats      (ApiVersion 3.0)
```

- Controller: `FsmCompatibilityController.GetStats`
- Service:    `FsmCompatibilityService.GetStats`
- No request body, no query parameters. Account is resolved from the
  auth/middleware pipeline.

Powers the pre-FSM onboarding teaser ("Nice work! That's **145** invoices in
**90** days", "**$24,300** Billed", "**83** Clients"). The lookback window
is a fixed **90 days** on `Invoice.CreatedOn`, and no caching is applied —
every call recomputes from the source invoices.

### Response body — `FsmInvoiceStats`

Wrapped as `{ "result": FsmInvoiceStats }` by `ResultWrapperFilter`.

| Field            | Type                 | Notes |
|------------------|----------------------|-------|
| `accountId`      | string               | Echo of the calling account id. |
| `periodDays`     | int                  | Width of the lookback window. Always `90` today; exposed so the frontend doesn't hard-code it. |
| `invoicesCount`  | int                  | Count of non-deleted invoices with `CreatedOn` within the window. Invoices missing `CreatedOn` are skipped. |
| `totalBilled`    | decimal              | Sum of `TotalAmount` across the counted invoices. Mixed-currency accounts sum as raw numbers — use `currencyCode` for formatting. |
| `clientsCount`   | int                  | Distinct `Client.CatalogId` values across the counted invoices. Invoices with a null/empty catalog id are ignored for this count but still contribute to `invoicesCount` and `totalBilled`. |
| `currencyCode`   | string enum or null  | Most frequent currency across the counted invoices (ISO 4217 letters, e.g. `"USD"`, `"EUR"`). `null` when no invoice in the window carries a currency code. Serialized as a string via `StringOnlyEnumConverter`. |

### Example

```json
{
  "result": {
    "accountId": "5f9d4a3b7e2c1a0b8c7d6e5f",
    "periodDays": 90,
    "invoicesCount": 145,
    "totalBilled": 24300.00,
    "clientsCount": 83,
    "currencyCode": "USD"
  }
}
```

### Error responses

No domain-specific errors. An account with zero qualifying invoices returns
a 200 with `invoicesCount: 0`, `totalBilled: 0`, `clientsCount: 0`,
`currencyCode: null`.

## `GET /api/FsmCompatibility/estimates-stats`

```
GET /api/FsmCompatibility/estimates-stats      (ApiVersion 3.0)
```

- Controller: `FsmCompatibilityController.GetEstimatesStats`
- Service:    `FsmCompatibilityService.GetEstimatesStats`
- No request body, no query parameters. Account is resolved from the
  auth/middleware pipeline.

Parallel to `/stats`, but over the account's **estimates** rather than
invoices — same 90-day window on `Estimate.CreatedOn`, same filters, same
dominant-currency pick. Not cached; every call recomputes from the source
estimates.

### Response body — `FsmEstimateStats`

Wrapped as `{ "result": FsmEstimateStats }` by `ResultWrapperFilter`.

| Field             | Type                 | Notes |
|-------------------|----------------------|-------|
| `accountId`       | string               | Echo of the calling account id. |
| `periodDays`      | int                  | Width of the lookback window. Always `90` today; same constant as `/stats`. |
| `estimatesCount`  | int                  | Count of non-deleted estimates with `CreatedOn` within the window. Estimates missing `CreatedOn` are skipped. |
| `totalValue`      | decimal              | Sum of `TotalAmount` across the counted estimates. Mixed-currency accounts sum as raw numbers — use `currencyCode` for formatting. |
| `clientsCount`    | int                  | Distinct `Client.CatalogId` values across the counted estimates. Estimates with a null/empty catalog id are ignored for this count but still contribute to `estimatesCount` and `totalValue`. |
| `currencyCode`    | string enum or null  | Most frequent currency across the counted estimates (ISO 4217 letters, e.g. `"USD"`, `"EUR"`). `null` when no estimate in the window carries a currency code. Serialized as a string via `StringOnlyEnumConverter`. |

### Example

```json
{
  "result": {
    "accountId": "5f9d4a3b7e2c1a0b8c7d6e5f",
    "periodDays": 90,
    "estimatesCount": 37,
    "totalValue": 18650.00,
    "clientsCount": 21,
    "currencyCode": "USD"
  }
}
```

### Error responses

No domain-specific errors. An account with zero qualifying estimates
returns a 200 with `estimatesCount: 0`, `totalValue: 0`, `clientsCount: 0`,
`currencyCode: null`.

## Caching

Classifications from `GET /api/FsmCompatibility` are cached per-account in
the Mongo collection `fsmCompatibilityRecords`
(`FsmCompatibilityRepository`). There is currently no invalidation hook — a
record persists until manually removed. If the `specialization` field is
added to records produced before that field existed, the Mongo driver
deserializes it as `null` (the `required` keyword is compile-time only);
delete stale rows to force a refresh.

`GET /api/FsmCompatibility/stats` and `GET /api/FsmCompatibility/estimates-stats`
are **not** cached and read the full invoice / estimate list on every call —
the numbers reflect the current collection state.

## Related code

- Controller: `Src/Invoices.Api/Controllers/FsmCompatibilityController.cs`
- Service:    `Src/Invoices.Implementation.Services/FsmCompatibility/FsmCompatibilityService.cs`
- Result/enum: `Src/Invoices.Core/Services/IFsmCompatibilityService.cs`
- Cached record: `Src/Invoices.Core/Models/FsmCompatibilityRecord.cs`
- Repository:   `Src/Invoices.Implementation.MongoDb/Repositories/FsmCompatibilityRepository.cs`
- Options:      `Src/Invoices.Implementation.Services/FsmCompatibility/DeepSeekOptions.cs`
- Exception map: `Src/Invoices.Api/Middleware/ApiExceptionHandlingMiddleware.cs`
- Integration test: `Src/Invoices.IntegrationTests/Tests/Controllers/FsmCompatibilityControllerTests.cs`
