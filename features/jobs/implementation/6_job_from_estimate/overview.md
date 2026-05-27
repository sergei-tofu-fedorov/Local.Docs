# Step 6: Job From Estimate — Overview

**Task**: [WEB-1047](https://app.clickup.com/t/24553599/WEB-1047)

## Overview

Extends the existing "create job from estimate" flow (`POST /jobs/from-estimate`) with status validation, currency propagation, activity events, and the full Estimate ↔ Job ↔ Invoice relation chain.

## Relation Model

Ownership lives on invoice and estimate. Job never receives relation IDs from client input.

```
+--------------+        +--------------+        +--------------+
|   Invoice    |        |   Estimate   |        |     Job      |
+--------------+        +--------------+        +--------------+
| JobId        |------->| JobId        |------->| (response    |
| EstimateId   |------->|              |        |  only):      |
|              |        |              |        | InvoiceId    |
|              |        |              |        | EstimateId   |
+--------------+        +--------------+        +--------------+
  Client sends            Client sends           Derived from
  on PUT                   on PUT                Job.Relations
```

| Entity | Field | Direction | How Job learns about it |
|--------|-------|-----------|-------------------------|
| **Invoice** | `JobId` | Client input | `InvoicesService.TryUpdateJobSummary` → `UpdateJobFromInvoiceCommand` → `Job.Relations.Invoices` + `Summary` |
| **Invoice** | `EstimateId` | Client input | Stored on invoice; used to resolve `JobId` and for event cross-links |
| **Estimate** | `JobId` | Client input | `EstimatesService.TryUpdateJobLink` → `UpdateJobFromEstimateCommand` → `Job.Relations.Estimates` |
| **Job** | `InvoiceId`, `EstimateId` | Response only | Derived from `Job.Relations.Invoices[0]` / `Job.Relations.Estimates[0]` |

**Job relations are append-only.** Once an invoice or estimate is added to `Job.Relations`, it cannot be changed or removed — only appended. Exceptions: job deletion clears all links; invoice removal clears `Job.Relations.Invoices` and resets `Job.Summary`. The domain methods `TryAddInvoiceLink` / `TryAddEstimateLink` are idempotent (skip duplicates) and never replace existing entries.

## Workflow Diagrams

### Create Job From Estimate

```
Client                  Invoices.Backend (Jobs domain)         Tofu.Invoices (gRPC)
  │                              │                                    │
  │ POST /jobs/from-estimate     │                                    │
  │─────────────────────────────▶│                                    │
  │                              │  GetEstimateWithItems              │
  │                              │───────────────────────────────────▶│
  │                              │◀───────────────────────────────────│
  │                              │                                    │
  │                              │  Validate status = Approved        │
  │                              │  Create Job aggregate              │
  │                              │  job.TryAddEstimateLink()          │
  │                              │  Set currency from estimate        │
  │                              │  Save job + jobCreated event       │
  │                              │                                    │
  │                              │  LinkJobToEstimate RPC             │
  │                              │  (sets JobId + estimateJobCreated) │
  │                              │───────────────────────────────────▶│
  │                              │◀───────────────────────────────────│
  │                              │                                    │
  │◀─────────────────────────────│                                    │
  │  JobDto response             │                                    │
```

### Save Invoice with JobId

```
Client                  Invoices.Backend                       Tofu.Invoices (gRPC)
  │                              │                                    │
  │ PUT /invoices                │                                    │
  │ { jobId, estimateId, ... }   │                                    │
  │─────────────────────────────▶│                                    │
  │                              │                                    │
  │                              │  InvoicesController.Put            │
  │                              │  ├─ Map InvoiceDto → Invoice       │
  │                              │  │  (JobId, EstimateId preserved)  │
  │                              │  ├─ Sync attachments               │
  │                              │  │                                 │
  │                              │  └─ InvoicesService.Add            │
  │                              │     (Invoices.Api/Services/)       │
  │                              │     │                              │
  │                              │     ├─ TryGetJob(jobId)            │
  │                              │     │  If found:                   │
  │                              │     │  → check job has no different│
  │                              │     │    invoice linked            │
  │                              │     │  → set jobNumber             │
  │                              │     │  → if job has estimate:      │
  │                              │     │    set invoice.EstimateId    │
  │                              │     │  If not found: OK (sync —    │
  │                              │     │  job will come later)        │
  │                              │     │                              │
  │                              │     ├─ InvoicesGateway.Add         │
  │                              │     │  (gRPC proxy → AddAsync      │
  │                              │     │   + jobNumber in request)    │
  │                              │     │  NOTE: if new invoice has    │
  │                              │     │  JobId → created from job    │
  │                              │     │─────────────────────────────▶│
  │                              │     │◀─────────────────────────────│
  │                              │     │                              │
  │                              │     └─ TryUpdateJobSummary         │
  │                              │        (if jobId non-empty):       │
  │                              │        → UpdateJobFromInvoiceCmd   │
  │                              │        → job.TryAddInvoiceLink     │
  │                              │          (append-only, idempotent) │
  │                              │        → job.UpdateInvoiceInfo     │
  │                              │          (Summary: amounts, status)│
  │                              │                                    │
  │◀─────────────────────────────│                                    │
  │  InvoiceDto response         │                                    │
```

### Save Estimate with JobId

```
Client                  Invoices.Backend                       Tofu.Invoices (gRPC)
  │                              │                                    │
  │ PUT /estimates               │                                    │
  │ { jobId, ... }               │                                    │
  │─────────────────────────────▶│                                    │
  │                              │                                    │
  │                              │  EstimatesController.Put           │
  │                              │  ├─ Map EstimateDto → Estimate     │
  │                              │  │  (JobId preserved)              │
  │                              │  ├─ Sync attachments               │
  │                              │  │                                 │
  │                              │  └─ EstimatesService.Add           │
  │                              │     (Invoices.Api/Services/)       │
  │                              │     │                              │
  │                              │     ├─ TryGetJob(jobId)            │
  │                              │     │  If found:                   │
  │                              │     │  → check job has same or no │
  │                              │     │    estimate linked           │
  │                              │     │  → set jobNumber             │
  │                              │     │  → if job has invoice:       │
  │                              │     │    set estimate.InvoiceId    │
  │                              │     │  If not found: OK (sync —    │
  │                              │     │  job will come later)        │
  │                              │     │                              │
  │                              │     ├─ EstimatesGateway.Add        │
  │                              │     │  (gRPC proxy → AddAsync      │
  │                              │     │   + jobNumber in request)    │
  │                              │     │  If JobId changed from null  │
  │                              │     │  → generates estimateJob-    │
  │                              │     │    Created event             │
  │                              │     │─────────────────────────────▶│
  │                              │     │◀─────────────────────────────│
  │                              │     │                              │
  │                              │     └─ TryUpdateJobLink            │
  │                              │        (if not already linked      │
  │                              │         and jobId non-empty):      │
  │                              │        → UpdateJobFromEstimateCmd  │
  │                              │        → job.TryAddEstimateLink    │
  │                              │          (append-only, idempotent) │
  │                              │                                    │
  │◀─────────────────────────────│                                    │
  │  EstimateDto response        │                                    │
```

### Remove Invoice (cleanup)

```
Client                  Invoices.Backend                       Tofu.Invoices (gRPC)
  │                              │                                    │
  │ DELETE /invoices/{id}        │                                    │
  │─────────────────────────────▶│                                    │
  │                              │                                    │
  │                              │  InvoicesService.Delete            │
  │                              │  (Invoices.Api/Services/)          │
  │                              │  │                                 │
  │                              │  ├─ InvoicesGateway.Delete         │
  │                              │  │  (gRPC proxy; if invoice has    │
  │                              │  │   EstimateId, Tofu.Invoices     │
  │                              │  │   clears InvoiceId on Estimate) │
  │                              │  │─────────────────────────────────▶│
  │                              │  │◀─────────────────────────────────│
  │                              │  │                                 │
  │                              │  └─ TryClearJobLinksForDeleted-    │
  │                              │     Invoice (unconditional):       │
  │                              │     → ClearJobInvoiceLinkCommand   │
  │                              │       finds job by invoiceId       │
  │                              │     → Remove invoice from          │
  │                              │       Job.Relations.Invoices       │
  │                              │     → Reset Job.Summary            │
  │                              │       (no-op if no job linked)     │
  │                              │                                    │
  │◀─────────────────────────────│                                    │
```

### Delete Job (cleanup)

```
Client                  Invoices.Backend (Jobs domain)         Tofu.Invoices (gRPC)
  │                              │                                    │
  │ DELETE /jobs/{id}            │                                    │
  │─────────────────────────────▶│                                    │
  │                              │  ClearInvoiceLinks                 │
  │                              │  (set invoice.JobId = null)        │
  │                              │───────────────────────────────────▶│
  │                              │                                    │
  │                              │  ClearEstimateLinks                │
  │                              │  (set estimate.JobId = null)       │
  │                              │───────────────────────────────────▶│
  │                              │                                    │
  │                              │  Soft-delete job                   │
  │                              │  Save + jobDeleted event           │
  │                              │                                    │
  │◀─────────────────────────────│                                    │
```

## Current State

| Aspect | Implementation |
|--------|----------------|
| Endpoint | `POST /api/v3/jobs/from-estimate?estimateId={id}` |
| Estimate → Job link | `Estimate.JobId` ↔ `Job.Relations.Estimates` (via `TryUpdateJobLink` in `Invoices.Api/Services/EstimatesService`) |
| Invoice → Job link | `Invoice.JobId` ↔ `Job.Relations.Invoices` (via `TryUpdateJobSummary` in `Invoices.Api/Services/InvoicesService`) |
| Invoice → Estimate link | `Invoice.EstimateId` — client sends on create-from-estimate |
| Estimate → Invoice link | `Estimate.InvoiceId` — cross-link resolved from job on save (Tofu.Invoices proto has field) |
| Job input linking | `JobUpsertRequestDto` has `InvoiceId`/`EstimateId` — **deprecated** (`[Obsolete]`), remove in 6.5 |
| Estimate events | `estimateJobCreated` — proto `EetJobCreated` mapped, event type registered in `EventType.cs` / `EventTypeDto.cs` |
| Invoice events | `invoiceCreatedFromJob` — proto `IetCreatedFromJob` mapped, event type registered |
| Job validation | `InvoicesService.Add` / `EstimatesService.Add` validate duplicate invoice/estimate per job (400 `jobAlreadyHasInvoice` / `jobAlreadyHasEstimate`) |
| Gateway/Service split | `Tofu.Invoices` classes renamed to `InvoicesGateway`/`EstimatesGateway` (thin gRPC proxies); new `Invoices.Api/Services/InvoicesService`/`EstimatesService` add business logic on top |
| Status gate | None — any estimate can be converted |
| Currency | Job has no currency field; defaults to `USD` constant |

## Rules

- Only estimates with **Approved** status can be converted to a job.
- The client is responsible for transitioning the estimate to **Done** via a separate call after job creation.
- A job can have at most **one invoice**. If the job already has an invoice, creating another from the linked estimate is blocked.
- When saving an invoice/estimate with a `JobId`, the backend resolves cross-entity links from the job's relations and sets them before saving to Tofu.Invoices (e.g. `invoice.EstimateId` from job's estimate, `estimate.InvoiceId` from job's invoice).
- Job relations are **append-only** — invoice/estimate links can only be added, never changed or removed. Exceptions: job deletion clears all links; invoice removal clears `Job.Relations.Invoices` and resets `Job.Summary`.

## Requirements

### 1. Status gate

- Reject conversion for any status other than **Approved**.
- The backend does **not** transition the estimate to Done — the client makes a separate call to update the estimate status after job creation.

### 2. Currency on Job

- Add `CurrencyCode` property to the `Job` entity (default: `USD`).
- When created from estimate, copy estimate's currency.
- `GetDisplayCurrencyCode()` falls back to `Job.CurrencyCode` instead of the static `DefaultCurrencyCode`.
- Expose through contract and API DTOs.

### 3. Activity events

| Event | EntityType | Payload | Display text |
|-------|------------|---------|--------------|
| `jobCreated` | Job | `{ }` | "You created job" |
| `estimateJobCreated` | Estimate | `{ "jobId", "jobNumber", "docNumber" }` | Estimate timeline: "You created [Job #...](...) from this estimate" |

- A single `jobCreated` event fires for all new jobs (whether created manually or from an estimate).
- `estimateJobCreated` fires on the estimate timeline when a job is linked to that estimate. Handled via the `LinkJobToEstimate` gRPC RPC — Tofu.Invoices sets `JobId` and emits the event when `JobId` changes from null to non-null.
- **Sync scenario:** If the job hasn't been synced yet and `jobNumber` is unavailable, events are still created with an empty `jobNumber`. The client handles the missing job number in the display text.

### 4. Relation model changes

**Deprecate job-side input linking:**
- Mark `InvoiceId` and `EstimateId` as `[Obsolete]` on `JobUpsertRequestDto` and `UpsertJobCommand`.
- Keep `FetchAndApplyRelations` in `UpsertJobCommandHandler` for backward compatibility.
- Full removal deferred to 6.6 after all clients are updated.

**Add `EstimateId` to Invoice:**
- Add `EstimateId` field to `Invoice` model, `InvoiceDto`, and gRPC proto mapping.
- Client sends `EstimateId` when creating an invoice from an estimate.
- Enables backend to resolve `JobId` from estimate if client doesn't provide it.

### 5. Duplicate invoice prevention (server-side)

- In `InvoicesService.Add()`, before the gRPC call: if the invoice has a `JobId`, check whether the job already has a **different** invoice linked.
- If so, return `400` with error code `jobAlreadyHasInvoice`.
- Allows updating the existing linked invoice (same ID passes validation).
- Client-side uses estimate status (**Done**) to disable the conversion UI — an estimate linked to a job that already has an invoice should be in Done status.

### 6. Onboarding: invoiceGenerator source

- Expose `isFromGenerator` in the onboarding response so clients can adjust the estimate-to-job flow.

### 7. "Convert to job" suggestion modal with dismissal

- Modal suggests converting to a **job** instead of directly to an invoice.
- After 3 dismissals, stop showing it.
- Backend provides a generic modal dismissal counter on the `Onboarding` entity.

## Scope Boundary

| Invoices.Backend | Tofu.Invoices.Backend |
|------------------|------------------------|
| Status validation before conversion | `LinkJobToEstimate` RPC: set JobId, `estimateJobCreated` event |
| Currency field on Job | Approval lock enforcement |
| Activity event: `jobCreated` | |
| `LinkJobToEstimate` gRPC client call | |
| Deprecate job input linking (6.2) | |
| Add `EstimateId` to Invoice model/DTO | |
| Duplicate invoice server-side check | |
| Modal dismissal counter on Onboarding | |

## Implementation Steps

| Step | Repo | Scope |
|------|------|-------|
| [6.1](6.1_tofu_invoices_link_job.md) | Tofu.Invoices.Backend | Contract updates: event infrastructure, `jobNumber` in Add RPCs (`estimateJobCreated`, `invoiceCreatedFromJob` events), clear estimate `InvoiceId` on invoice deletion |
| [6.2](6.2_relations.md) | Invoices.Backend | Relation design, deprecate job input linking, job validation, `EstimateId` on Invoice, invoice removal cleanup |
| [6.3](6.3_create_job_from_estimate.md) | Invoices.Backend + Tofu.Invoices.Backend | Status gate, currency, `jobCreated` event, `LinkJobToEstimate` RPC + client call, refactor |
| [6.4](6.4_onboarding_updates.md) | Invoices.Backend | Expose `isFromGenerator`, generic modal dismissal counter |
| [6.5](6.5_invoice_estimate_sources.md) | Tofu.Invoices.Backend | TODO |
| [6.6](6.6_cleanup_deprecated.md) | Invoices.Backend | Remove deprecated job input linking after all clients updated |
| [6.7](6.7_client_updates.md) | Client apps | Contract changes, migration guide, required client-side actions (estimate Done status, deprecated fields, new fields, error handling) |
| [6.8](6.8_frontend_activity_fixes.md) | Invoices.Backend | Frontend activity fixes — remap new event types to legacy ones for web compatibility |
| [6.9](6.9_contract_changes.md) | All | API contract changes summary — all new/changed fields across Invoice, Estimate, Job, and Onboarding DTOs |
| [6.10](6.10_subscription_priority.md) | Invoices.Backend | Subscription tier priority — select highest-tier plan when user has multiple active subscriptions |
