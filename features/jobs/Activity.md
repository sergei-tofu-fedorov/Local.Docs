Job Activity / Audit Timeline
=============================

Overview
--------

This document describes the **job activity timeline**: what events appear in
`/api/v3/jobs/{id}/timeline`, how they are phrased, and how they relate to
job statuses and billing state.

Terminology
-----------

- **Job status (system)** = `JobStatusDto` - the source of truth for job
  business logic. Core statuses: `created`, `scheduled`, `in_progress`, `completed`.
- **Billing (post-completion) status** - statuses that appear **only after
  `completed`** and reflect invoicing/payment (Invoiced / Sent / Paid).
- **Email status** = `EmailStatusType` - email transport only (for sending
  estimate/invoice).
- **Badge (UI)** - derived display for the user.
- **Timeline phrasing** - how the event appears in activity.

Job Statuses (4 Core Statuses)
------------------------------

| Job system status | Badge (UI)     | Description                              | Created/Changed when                                      | Activity phrasing                                                                 |
|-------------------|----------------|------------------------------------------|-----------------------------------------------------------|-----------------------------------------------------------------------------------|
| `created`         | Created        | Job created, may have no visits yet      | On job creation                                           | `"You created the job"`                                                           |
| `scheduled`       | Scheduled      | At least 1 scheduled visit exists        | First visit with date/time added                          | `"You scheduled a visit for {Worker} on {Date} at {Time}"` (or without worker)    |
| `in_progress`     | In progress    | Work has started                         | (a) Worker started visit, or (b) Manager set in progress  | Worker: `"{Worker} started the visit"` (`WorkerVisitStatusChanged`) / Manager: `"You started the visit"` (`VisitStatusChanged`) |
| `completed`       | Job completed  | Work is finished                         | Always manual action by manager                           | `"You marked this job as completed"`                                              |

Post-Completion Billing Status
------------------------------

This "ladder" appears **only when job is `completed`**.

| Billing status | Badge (UI) | Description                    | Created/Changed when        | Timeline phrasing                                              |
|----------------|------------|--------------------------------|-----------------------------|----------------------------------------------------------------|
| `invoiced`     | Invoiced   | Invoice created for this job   | After "Create invoice"      | `"You created Invoice #[N] for this job"` (Invoice #N = link)  |
| `sent`         | Sent       | Invoice sent to client         | After sending invoice email or manual mark-as-sent | `"You sent Invoice #[N] to [email]"` (email) / `"You marked Invoice #[N] as sent"` (manual) |
| `paid`         | Paid       | Invoice is paid                | After Add payment / Mark paid | `"You recorded a payment for Invoice #[N]"` / `"You marked Invoice #[N] as paid"` |

Base Rules (Jobs)
-----------------

1. **`scheduled`** means: at least 1 visit is scheduled.
   - Jobs can have multiple visits; visits belong to the job.
   - Activity records visit changes separately (see actions table below).

2. **`in_progress`** sources:
   - **Worker**: Worker started a visit in web or worker app → raises `WorkerVisitStatusChanged` event.
   - **Manager**: Manager clicked "Set in progress" / "Start visit" → raises `VisitStatusChanged` event.

3. **`completed`** - always manual (only manager).

4. **Post-completion statuses** (Invoiced/Sent/Paid) available only after `completed`.

5. **Job activity is an aggregator**: timeline includes not just job/visit statuses, but also:
   - Estimate: create/send/approve/decline
   - Invoice: create/send
   - Payment: add payment / mark as paid

Job Actions Specification
-------------------------

| Action                         | Job status change                       | Badge (UI)     | Activity phrasing                                                                        | Allowed from statuses                    | Notes                                     |
|--------------------------------|-----------------------------------------|----------------|------------------------------------------------------------------------------------------|------------------------------------------|-------------------------------------------|
| Create job                     | `— → created`                           | Created        | `"You created the job"`                                                                  | —                                        | Status assigned automatically             |
| Create first visit             | `created → scheduled` / `completed → scheduled` | Scheduled | Without worker: `"You scheduled a visit on {Date} at {Time}"` With worker: `"You scheduled a visit for {Worker} on {Date} at {Time}"` | `created`, `scheduled`, `completed` | Job becomes `scheduled` when first visit with date appears |
| Create non-first visit         | —                                       | No change      | `"You created a visit on {Date} at {Time}"`                                              | `created`, `scheduled`, `in_progress`, `completed` | Creating visit alone doesn't make job `scheduled` |
| Assign visit to worker         | —                                       | No change      | `"You assigned the visit to [Worker name]"` (the visit = link with tooltip)              | `created`, `scheduled`, `in_progress`    | Multiple visits possible                  |
| Create estimate                | —                                       | No change      | `"You created Estimate #[N] for this job"`                                               | Any                                      | —                                         |
| Send estimate                  | —                                       | No change      | `"You sent Estimate #[N] to [email]"`                                                    | Any                                      | Email = transport                         |
| Mark estimate as sent (manual) | —                                       | No change      | `"You marked Estimate #[N] as sent"`                                                     | Any (per estimate rules)                 | —                                         |
| Estimate email error           | —                                       | No change      | Current error message                                                                    | Any (per estimate rules)                 | Transport error                           |
| Mark estimate as approved      | —                                       | No change      | `"You marked Estimate #[N] as approved"`                                                 | Any (per estimate rules)                 | —                                         |
| Mark estimate as declined      | —                                       | No change      | `"You marked Estimate #[N] as declined"`                                                 | Any (per estimate rules)                 | —                                         |
| Start visit (manual by manager)| `→ in_progress`                         | In progress    | `"You started the visit"` (the visit = link with tooltip)                                | `created`, `scheduled`                   | Event: `VisitStatusChanged`               |
| Start visit (worker)           | `→ in_progress`                         | In progress    | `"[Worker name] started the visit"` (the visit = link with tooltip)                      | `scheduled`                              | Event: `WorkerVisitStatusChanged`         |
| Finish visit (manual)          | —                                       | No change      | `"You completed the visit"` (the visit = link with tooltip)                              | `in_progress`, `created`, `scheduled`    | Event: `VisitStatusChanged`               |
| Finish visit (worker)          | —                                       | No change      | `"[Worker name] completed the visit"` (the visit = link with tooltip)                    | `in_progress`                            | Event: `WorkerVisitStatusChanged`         |
| Mark completed                 | `→ completed`                           | Completed      | `"You marked this job as completed"`                                                     | `in_progress`, `created`, `scheduled`    | Manual action by manager                  |
| Create invoice                 | `— (billing → invoiced)`                | Invoiced       | `"You created Invoice #[N] for this job"` (Invoice #N = link)                            | `completed`                              | Starts billing ladder                     |
| Send invoice                   | `— (billing → sent)`                    | Sent           | `"You sent Invoice #[N] to [email]"`                                                     | `completed` + `invoiced`                 | Email = transport                         |
| Invoice email error            | —                                       | No change      | `"Invoice email didn't reach [email]. Check the email address and try again"`            | Any (per invoice rules)                  | —                                         |
| Mark invoice as sent (manual)  | `— (billing → sent)`                    | Sent           | `"You marked Invoice #[N] as sent"`                                                      | `completed` + `invoiced`                 | Without email, manual confirmation. Undoable via `invoiceSentMethodChanged` with `to: null` / `to: "email"`. |
| Invoice viewed by client       | —                                       | No change      | `"Invoice was viewed by {client's email}"`                                               | `completed` + `invoiced`                 | Email = transport                         |
| Add payment                    | —                                       | No change      | `"You updated received payments (total {sum}) in the invoice"` (the invoice = link)      | `completed` + `sent`/`invoiced`          | Partial or full payment                   |
| Mark as paid                   | `— (billing → paid)`                    | Paid           | `"You marked Invoice #[N] as paid"`                                                      | `completed` + `sent`/`invoiced`          | Manual payment confirmation               |
| Paid (Stripe automatic)        | `— (billing → paid)`                    | Paid           | Payment via Stripe phrasing + icon (from invoices)                                       | —                                        | —                                         |

Event Payloads and Phrasing
---------------------------

**Source of truth**: `features/jobs/Job Timeline Events.csv`

Phrasing is determined by `EventType` and payload fields. Frontend builds text based on event type and conditions.

> **Note**: Date/time formatting is handled by client - parses `scheduledDate` from payload.

| Event Type | Condition | Phrasing |
|------------|-----------|----------|
| `jobCreated` | — | "You created the job" |
| `visitCreated` | `visitCount: 1`, `workerId: null` | "You scheduled a visit on {Date} at {Time}" |
| `visitCreated` | `visitCount: 1`, `workerId != null` | "You scheduled a visit for {Worker name} on {Date} at {Time}" |
| `visitCreated` | `visitCount > 1` | "You created a visit on {Date} at {Time}" |
| `visitStatusChanged` | `workerName: null`, `newStatus: in_progress` | "You started the visit" |
| `visitStatusChanged` | `workerName: null`, `newStatus: completed` | "You completed the visit" |
| `visitStatusChanged` | `workerName != null`, `newStatus: in_progress` | "{Worker name} started the visit" |
| `visitStatusChanged` | `workerName != null`, `newStatus: completed` | "{Worker name} completed the visit" |
| `jobStatusChanged` | `newStatus: completed` | "You marked this job as completed" |
| `jobStatusChanged` | `newStatus: none` (undo) | "You reverted job from completed" |
| `invoiceSentMethodChanged` | `to: "manual"` (from `null` or `"email"`) | "You marked Invoice #{docNumber} as sent" |
| `invoiceSentMethodChanged` | `to: null` or `to: "email"` (from `"manual"`) | "You reverted Invoice #{docNumber} from sent" |

### Worker vs Manager Actions

Worker-driven and manager-driven visit status changes use the **same event type** (`visitStatusChanged`). The difference is in the payload:
- Manager action: `workerId: null`, `workerName: null`
- Worker action: `workerId: null`, `workerName: "Worker name"`

> **Note**: Per CSV spec, `workerId` is always `null` in visitStatusChanged. Use `workerName` presence to determine actor.

### Payload Examples

**jobCreated**:
```json
{ }
```

**visitCreated** (first visit):
```json
{ "visitId": "guid", "scheduledDate": "2024-10-23T12:00:00Z", "workerId": null, "workerName": null, "visitCount": 1 }
```

**visitCreated** (subsequent visit):
```json
{ "visitId": "guid", "scheduledDate": "2024-10-23T12:00:00Z", "workerId": null, "workerName": null, "visitCount": 2 }
```

**visitStatusChanged** (manager):
```json
{ "visitId": "guid", "previousStatus": "scheduled", "newStatus": "in_progress", "workerId": null, "workerName": null }
```

**visitStatusChanged** (worker):
```json
{ "visitId": "guid", "previousStatus": "scheduled", "newStatus": "in_progress", "workerId": null, "workerName": "Worker name" }
```

**jobStatusChanged** (mark completed):
```json
{ "previousStatus": "none", "newStatus": "completed" }
```

**jobStatusChanged** (undo):
```json
{ "previousStatus": "completed", "newStatus": "none" }
```

Event Types in Code
-------------------

### Job Events (Jobs.Domain)

`JobEventType` enum:
- `Created` (1) - job created
- `StatusChanged` (10) - job status changed (manual completed/uncompleted, set in progress)
- `VisitCreated` (20) - visit created
- `VisitStatusChanged` (21) - visit status changed by manager (started, completed)
- `WorkerVisitStatusChanged` (23) - visit status changed by worker (started, completed)

### Invoice Events (Tofu.Invoices.Domain)

`InvoiceEventType` enum:
- `StatusChanged` - invoice status changed (NotPaid, Paid, PaidByCard, Refunded, etc.)
- `EmailStatusChanged` - email status changed (Sent, Opened, MarkedAsSent, Error)
- `PaymentReceived` - payment recorded (partial or full)
- `SentMethodChanged` - `SentMethod` transitioned between `null` / `Email` / `Manual`. Aggregated into the job timeline via gRPC; promotes the job's billing badge to `Sent` when non-null (unpaid). See [Invoice Mark as Sent plan](../invoices/mark_as_sent/Backend/overview.md).

### Estimate Events (Tofu.Invoices.Domain)

`EventType` enum:
- `StatusChanged` - estimate status changed (Draft, Sent, Approved, Canceled, Done)
- `EmailStatusChanged` - email status changed (Sent, Opened, MarkedAsSent, Error)

### Email Statuses

`EmailStatusType` enum: `Sent`, `InProgress`, `Opened`, `MarkedAsSent`, `Error`

API and Persistence
-------------------

- **Timeline endpoint**: `GET /api/v3/jobs/{id}/timeline` returns audit trail
  ordered by `OccurredAt`.
- **Persistence**: Job events stored in `jobs.JobEvents`. Invoice/estimate
  events fetched from `Tofu.Invoices` service via gRPC.
- See `features/jobs/Backend/Persistence.md` for schema.

Related Code
------------

- **Jobs**: `Jobs.Domain.Models.Job.EffectiveStatus`, `JobEventType`, `JobDomainEvent`
- **Invoices**: `Tofu.Invoices.Domain.Models.Events.InvoiceEventType`, `InvoiceEvent`
- **Estimates**: `Tofu.Invoices.Domain.Models.Events.EventType`, `EstimateEvent`

Known Issues
------------

### Convert Estimate to Invoice - Duplicate Events

**Current behavior**: Two events appear in activity:
1. `"You created Invoice #[N] for this job"`
2. `"You converted Estimate #[N] into an invoice"`

**Expected**: Only one event - the conversion event. Remove duplicate "created invoice" event.
