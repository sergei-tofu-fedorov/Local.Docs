# AI Summary — Job For Latest Invoice

Endpoint on the `feature/ai_summary` branch that surfaces the job tied to the
account's most recent invoice — creating that job **together with a scheduled
visit and a draft estimate cloned from the invoice** if one doesn't exist
yet — so the post-onboarding flow can drop the user straight onto a real,
populated job details page.

Companion to the FSM-compatibility / DeepSeek work already staged on this
branch: that feature classifies an account's fit for FSM based on invoice
history; this endpoint hands the user a concrete starting point once we've
decided the account is a fit.

> **FSM Compatibility API contract** — see
> [`FSM_COMPATIBILITY_API.md`](FSM_COMPATIBILITY_API.md) for the full
> request/response shape, including the `specialization` field and the
> string-serialized `fsmFit` enum.

## Goals

- One call, one populated job returned in `JobDetailsDto` shape — job, its
  invoice, and its estimate, all in one response.
- Idempotent: repeat calls return the same job and the same estimate; they
  do not accumulate visits or estimates.
- Reuse the existing job-building blocks (`InvoiceExtensions.ToJobItems`,
  `IJobClientsService`, `IJobsRepository`, `IJobDomainEventService`,
  `IJobWorkerService`, `IJobInvoiceService`).

## Non-goals

- No LLM call. DeepSeek is scoped to `/api/FsmCompatibility`.
- No request payload. The endpoint derives everything from the calling
  account's latest invoice.
- No arbitrary visit scheduling. Exactly **two** scheduled, unassigned
  visits are created — today and tomorrow — as seed entries the user can
  later reschedule or assign.

## Endpoints added on this branch

Five endpoints land together on `feature/ai_summary`. The jobs one below is
the main subject of this doc; the others are cross-links to where they're
documented in detail.

| Route                                          | Ver  | Response                     | Docs                                                            |
|------------------------------------------------|------|------------------------------|-----------------------------------------------------------------|
| `PUT /api/jobs/ai-summary`                     | 3.0  | `JobDetailsDto`              | [API contract](#api-contract) (this doc)                        |
| `POST /api/authenticate/web-handoff-token`     | 3.0  | `WebHandoffTokenResponseDto` | [Web handoff token](#post-apiauthenticateweb-handoff-token) (this doc) |
| `GET /api/FsmCompatibility`                    | 3.0  | `FsmCompatibilityResult`     | [FSM_COMPATIBILITY_API.md](FSM_COMPATIBILITY_API.md)            |
| `GET /api/FsmCompatibility/stats`              | 3.0  | `FsmInvoiceStats`            | [FSM_COMPATIBILITY_API.md](FSM_COMPATIBILITY_API.md)            |
| `GET /api/FsmCompatibility/estimates-stats`    | 3.0  | `FsmEstimateStats`           | [FSM_COMPATIBILITY_API.md](FSM_COMPATIBILITY_API.md)            |

## API contract

```
PUT /api/jobs/ai-summary              (ApiVersion 3.0)
```

- **Request body**: none.
- **Query / path params**: none.
- **Auth**: standard BFF auth — account resolved via `BaseController.AccountId`.
- **Controller**: `JobsController.EnsureJobForLatestInvoice`
  (`Src/Invoices.Api/Controllers/JobsController.cs`).

The original `PUT /api/jobs` upsert path is untouched.

### Response envelope

All BFF responses pass through `ResultWrapperFilter`, which wraps the
payload as:

```json
{
  "result": { /* JobDetailsDto */ }
}
```

Property names are camel-cased globally
(`CamelCasePropertyNamesContractResolver` for Newtonsoft.Json).

### Response body — `JobDetailsDto`

Same shape returned by `GET /api/jobs/{id}?includeRelated=true`. Source:
`Src/Invoices.Api/Dto/Jobs/JobDetailsDto.cs`.

| Field      | Type           | Notes                                                                                      |
|------------|----------------|--------------------------------------------------------------------------------------------|
| `job`      | `JobDto`       | Always present. See table below.                                                           |
| `client`   | `ClientDto?`   | Populated only when `job.clientSnapshot` is null — i.e. the job hasn't been completed yet. |
| `invoice`  | `InvoiceDto?`  | Always populated for this endpoint — the latest invoice used to build / resolve the job.   |
| `estimate` | `EstimateDto?` | Populated on the creation path (cloned from the invoice). May be null if the upstream estimate creation failed — the job is still returned. On the short-circuit path it reflects whatever estimate is currently linked. |

### `JobDto` (key fields)

Source: `Src/Invoices.Api/Dto/Jobs/JobDetailsDto.cs`. Full list in code;
the fields the AI-summary flow is most likely to care about:

| Field            | Type                      | Notes                                                                           |
|------------------|---------------------------|---------------------------------------------------------------------------------|
| `id`             | Guid                      | Newly-minted on the creation path, stable on the short-circuit path.            |
| `accountId`      | string                    | Echo of the caller.                                                             |
| `version`        | int                       | Optimistic-concurrency version.                                                 |
| `createdAt`      | DateTimeOffset (UTC)      | Serialized via `DateTimeOffsetAsUtcConverter`.                                  |
| `number`         | string?                   | From `IJobsRepository.NextNumber(accountId)` on creation.                       |
| `title`          | string?                   | `invoice.Client.Name` fallback `"Job #{jobNumber}"`.                            |
| `status`         | `JobStatusDto` (string)   | Derived; a freshly-created job with two scheduled visits is `scheduled`.        |
| `manualStatus`   | `JobManualStatusDto`      | `none` by default.                                                              |
| `clientId`       | string                    | The invoice's `Client.CatalogId`.                                               |
| `invoiceId`      | string?                   | The latest invoice's id.                                                        |
| `estimateId`     | string?                   | The freshly-created estimate's id (or null if estimate creation failed).        |
| `currencyCode`   | string?                   | Mirrored from `invoice.CurrencyCode`.                                           |
| `visits`         | `VisitDto[]`              | Exactly two on the creation path (today + tomorrow); see visit shape below.     |
| `items`          | `InvoiceItemDto[]?`       | Cloned 1:1 from `invoice.Items`.                                                |
| `completionTime` | DateTimeOffset?           | Null — the job has just been created.                                           |
| `actionsRequired`| `JobActionRequiredDto[]`  | Empty by default.                                                               |
| `clientSnapshot` | `ClientDto?`              | Null — a snapshot is only captured when the job is completed.                   |

### `VisitDto[]` (the two visits we create)

Both visits share the same shape; only `dateTime` differs.

| Field               | Visit 1 (today)                                  | Visit 2 (tomorrow)                                       |
|---------------------|--------------------------------------------------|----------------------------------------------------------|
| `id`                | Freshly-minted Guid                              | Freshly-minted Guid                                      |
| `dateTime`          | `now` (UTC)                                      | `now + 1 day` (UTC)                                      |
| `status`            | `"scheduled"` (string-serialized `VisitStatus`)  | `"scheduled"`                                            |
| `assignedWorkerId`  | `null`                                           | `null`                                                   |

### `InvoiceDto` and `EstimateDto`

Both are the standard BFF DTOs — see `Src/Invoices.Api/Models/InvoiceDto.cs`
and `Src/Invoices.Api/Models/EstimateDto.cs`. The notable bits for this
endpoint:

- `invoice.client.address` is **always non-null** — if the stored invoice
  had a null address, the handler fills `"No address provided"` before
  returning (see [Client address fill](#client-address-fill)).
- `estimate.status` is always `"draft"` on the creation path.
- `estimate.items` mirrors `invoice.items` byte-for-byte (same line items,
  quantities, unit prices, discounts, tax flags).
- `estimate.attachments` is always `[]` — invoice attachments are not
  cloned into the estimate.

### Example — creation path

Request:

```http
PUT /api/jobs/ai-summary HTTP/1.1
api-version: 3.0
```

Response (abbreviated):

```json
{
  "result": {
    "job": {
      "id": "7a3f8c2e-1c2d-4e5f-9a3b-2d5e1f0a4b7c",
      "accountId": "5f9d4a3b7e2c1a0b8c7d6e5f",
      "version": 1,
      "createdAt": "2026-04-22T14:33:21.000Z",
      "number": "JOB-00042",
      "title": "Acme Plumbing",
      "status": "scheduled",
      "manualStatus": "none",
      "clientId": "client-abc123",
      "invoiceId": "inv-9876",
      "estimateId": "est-5f3e2c1a-...",
      "currencyCode": "USD",
      "visits": [
        {
          "id": "8b4d9e1f-...",
          "dateTime": "2026-04-23T14:33:21.000Z",
          "status": "scheduled",
          "assignedWorkerId": null
        },
        {
          "id": "9c5eaf20-...",
          "dateTime": "2026-04-24T14:33:21.000Z",
          "status": "scheduled",
          "assignedWorkerId": null
        }
      ],
      "items": [
        { "name": "Drain clearing", "quantity": 1, "unitPrice": 180.00, "isTaxApplied": true }
      ],
      "actionsRequired": [],
      "clientSnapshot": null
    },
    "client": {
      "name": "Acme Plumbing",
      "phone": "+1 555 0100",
      "email": "ops@acme.example",
      "address": "221B Baker Street, London",
      "catalogId": "client-abc123"
    },
    "invoice": {
      "id": "inv-9876",
      "client": {
        "name": "Acme Plumbing",
        "address": "221B Baker Street, London"
      }
    },
    "estimate": {
      "id": "est-5f3e2c1a-...",
      "status": "draft",
      "client": {
        "name": "Acme Plumbing",
        "address": "221B Baker Street, London"
      }
    }
  }
}
```

### Errors

| Condition                                                           | HTTP | Error envelope              |
|---------------------------------------------------------------------|------|-----------------------------|
| Account has zero non-deleted invoices.                              | 200  | `error.code = "notFound"`   |
| Latest invoice has no `Client.CatalogId` (can't resolve a client).  | 500  | Generic — logged.           |
| Matching catalog client is archived or missing in the jobs domain.  | 500  | Generic — logged.           |
| Estimate upsert fails upstream.                                     | 200  | No error — job still returned, `estimate` is null. |

## `POST /api/authenticate/web-handoff-token`

```
POST /api/authenticate/web-handoff-token     (ApiVersion 3.0)
```

Short-lived Firebase **custom token** issued to the currently-authenticated
user so a web client can call `signInWithCustomToken(...)` and adopt the
same Firebase identity as the mobile caller. Sibling to the AI-summary
onboarding flow: once the user is classified as an FSM fit, this token is
what hands them off into the web app with their account already signed in.

- **Controller**: `AuthenticateController.GetWebHandoffToken`
  (`Src/Invoices.Api/Controllers/AuthenticateController.cs`).
- **Request body**: none. **Query / path params**: none.
- **Auth**: the caller must already be authenticated — the handler resolves
  `AuthenticationInfo` from the standard middleware and throws
  `AuthenticationException("Should call auth first")` if it's missing.
- **Upstream**: delegates to `TofuAuthApiClient.CreateWebHandoffTokenAsync`,
  which returns the Firebase custom token minted for the caller.

### Response body — `WebHandoffTokenResponseDto`

Source: `Src/Invoices.Api/Models/Authenticate/WebHandoffTokenResponseDto.cs`.

| Field         | Type   | Notes                                                                 |
|---------------|--------|-----------------------------------------------------------------------|
| `customToken` | string | Firebase custom token (JWT). Short-lived; signed by the auth service. Pass it directly to `signInWithCustomToken` on the web client. |

Wrapped by `ResultWrapperFilter` as:

```json
{
  "result": {
    "customToken": "eyJhbGciOi..."
  }
}
```

### Errors

| Condition                                      | HTTP | Error envelope                         |
|------------------------------------------------|------|----------------------------------------|
| Caller is unauthenticated.                     | 401  | Thrown by `AuthenticationException` and mapped by the auth middleware. |
| Upstream auth service rejects the mint request.| 500  | Surfaced as whatever the Tofu.Auth client maps the failure to. |

## Flow

```
┌───────────────────────────────────────────────────────────────────────────┐
│  Controller: JobsController.EnsureJobForLatestInvoice                     │
│  1. Dispatch EnsureJobForLatestInvoiceCommand(AccountId, MasterUserId)    │
│  2. Call IJobDetailsService.GetRelatedData(result.Job)                    │
│  3. Return JobDetailsDto { Job, Client, Invoice, Estimate }               │
└───────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  Handler: EnsureJobForLatestInvoiceCommandHandler                         │
│  a. IInvoicesGateway.GetAll(AccountId)                                    │
│  b. Filter non-deleted, OrderByDescending(Date), take first               │
│  c. No invoice → throw EntityNotFoundException                            │
│  d. invoice.JobId parses and repository finds the job →                   │
│        return (existing Job, Created=false)                               │
│  e. Else:                                                                 │
│     1. Build new Job (items + currency from invoice, TryAddInvoiceLink).  │
│     2. Build a fresh draft Estimate from the invoice (same items / notes  │
│        / totals, Status=Draft, Source=Job, JobId already set to job.Id). │
│     3. IEstimatesGateway.Add(estimate) → TryAddEstimateLink(estimate.Id). │
│     4. IJobWorkerService.GetTeam → job.UpdateVisits([two scheduled        │
│        visits, unassigned: DateTime=now and DateTime=now+1day]).          │
│     5. _jobsRepository.Insert / _jobDomainEventService.Save / SaveChanges.│
│     6. IJobInvoiceService.TryLinkInvoice → flips invoice.JobId back-ref   │
│        so subsequent calls short-circuit to this job.                     │
│     Return (new Job, Created=true).                                       │
└───────────────────────────────────────────────────────────────────────────┘
```

The `Created` flag on `EnsureJobForLatestInvoiceResult` is informational;
the controller doesn't surface it today, but it's available for telemetry.

## Client address fill

Before cloning, if `invoice.Client.Address` is null/whitespace, the handler
writes the placeholder **`"No address provided"`** into it and persists the
updated invoice upstream via `IInvoicesGateway.Add`. The estimate clone and
the `JobDetailsDto.Invoice` the client receives therefore both carry a
non-null address. Invoices that already have an address are untouched, and
a failure to persist the address update is logged-and-swallowed — the
in-memory estimate clone still benefits even if the upstream write fails.

## What the new job looks like

- **Items & totals** cloned 1:1 from the invoice (`invoice.ToJobItems()`).
- **Currency** mirrored via `job.SetCurrencyCode(invoice.CurrencyCode)`.
- **Title**: `invoice.Client.Name`, or `"Job #{jobNumber}"` as a fallback.
- **Links**: `invoice.Id` and the freshly-created `estimate.Id`.
- **Visits**: exactly two, both `Status=Scheduled`, `AssignedWorkerId=null`.
  Visit 1 `DateTime=now`; Visit 2 `DateTime=now+1 day`.

## The cloned estimate

Built in-memory from the invoice, then persisted through `IEstimatesGateway.Add`:

| Field                 | Source                                               |
|-----------------------|------------------------------------------------------|
| `Id`                  | `Guid.NewGuid().ToString()`                          |
| `AccountId`           | command.AccountId                                    |
| `ProductKey`          | `invoice.ProductKey`                                 |
| `Client`              | `invoice.Client` (same instance)                     |
| `Date` / `CreatedOn`  | `now`                                                |
| `Items`               | `invoice.Items`                                      |
| `Notes`               | `invoice.Notes`                                      |
| `Discount` / `Tax`    | `invoice.Discount` / `invoice.Tax`                   |
| Totals                | `invoice.SubtotalAmount/DiscountAmount/TaxAmount/TotalAmount` |
| `CurrencyCode`        | `invoice.CurrencyCode`                               |
| `Attachments`         | `[]` (empty — invoice attachments are not cloned)    |
| `Status`              | `EstimateStatus.Draft`                               |
| `SentMethod`          | `EstimateSentMethod.Unknown`                         |
| `Source`              | `EstimateSource.Job`                                 |
| `JobId`               | `job.Id.ToString()`                                  |

If estimate creation throws (upstream gRPC hiccup), the error is logged and
the job is still returned without an estimate link — the primary UX (job +
invoice + visit) still lands for the user.

## Edge cases

- **No invoices at all** → `EntityNotFoundException` → 200 + `error.code = "notFound"`.
- **Latest invoice has no `CatalogId` on its client** →
  `InvalidOperationException`. We deliberately don't fall back to an older
  invoice; the intent is "show a job for the *latest* invoice or none."
- **Client archived or missing in the jobs domain** →
  `InvalidOperationException`. Same rationale as above.
- **`invoice.JobId` is set but the job was since deleted** → treat as "no
  job" and build a fresh one (including a new estimate and visit).
- **Estimate creation fails** → the job is still persisted with the invoice
  link and visit; `JobDetailsDto.Estimate` is null on the response.

## Idempotency

Once the handler succeeds, `TryLinkInvoice` writes `invoice.JobId = job.Id`
upstream so subsequent calls find the existing job via that back-reference
and short-circuit (`Created=false`). The endpoint is safe to call
repeatedly — at most one job, one estimate, and two visits per latest
invoice.

## Authorization

Reuses the existing permission that guards `PUT /api/jobs` — writes are
scoped to the jobs collection plus one estimate upsert.

## Related code

- Endpoint: `JobsController.EnsureJobForLatestInvoice`
  (`Src/Invoices.Api/Controllers/JobsController.cs`).
- Command / result: `EnsureJobForLatestInvoiceCommand`
  (`Src/Jobs/Jobs.Contracts/Jobs/Commands/EnsureJobForLatestInvoiceCommand.cs`).
- Handler: `EnsureJobForLatestInvoiceCommandHandler`
  (`Src/Jobs/Jobs.Application/Commands/EnsureJobForLatestInvoiceCommandHandler.cs`).
- Invoice → job items: `InvoiceExtensions.ToJobItems`
  (`Src/Jobs/Jobs.Application/Extensions/InvoiceExtensions.cs`).
- Details assembly: `JobDetailsService.GetRelatedData`
  (`Src/Invoices.Api/Services/JobDetailsService.cs`).
- Integration tests: `JobsAiSummaryIntegrationTests`
  (`Src/Invoices.IntegrationTests/Jobs/JobsAiSummaryIntegrationTests.cs`).
- Sibling AI feature on the same branch: `FsmCompatibilityService`
  (`Src/Invoices.Implementation.Services/FsmCompatibility/FsmCompatibilityService.cs`).
