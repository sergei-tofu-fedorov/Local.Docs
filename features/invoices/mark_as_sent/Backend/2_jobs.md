# Part 2 — Job Side (WEB-1436)

Scope: propagate the invoice's `SentMethod` into the linked job's billing badge and surface the mark-as-sent / undo events in the job timeline.

Covers changes in `Invoices.Backend` (Jobs domain and aggregation layer) only. Invoice-level domain, events, proto, and gateway DTO changes live in [`1_invoices.md`](./1_invoices.md) and are a prerequisite for this part.

Prerequisites: part 1 shipped — core `Invoices.Core.Models.Invoice.SentMethod` is populated by the gateway on every `PUT /Invoices`, and `InvoiceEventType.SentMethodChanged` is mapped to the central `EventType.InvoiceSentMethodChanged` in `Mapper.MapInvoiceEventType`.

## Current State (job side)

- Job timeline endpoint: `GET /api/v3/jobs/{id}/timeline` → `Invoices.Backend/Src/Invoices.Api/Controllers/JobsController.cs:169-187` → `GetJobTimelineQueryHandler` (`Jobs/Jobs.Application/Queries/GetJobTimelineQueryHandler.cs:38-91`).
- The handler is an **aggregator**: local `JobEventSource` + `InvoiceEventSource` (gRPC → `InvoicesGateway.GetTimelineByEntityId`) + `EstimateEventSource` (gRPC). Events are merged and ordered by `OccurredAt` desc — no duplicated job-side event is needed for invoice actions. Invoice/estimate events are fetched on every timeline read (per `features/jobs/Activity.md`).
- Invoice → job summary sync: `InvoicesService.Add` calls `TryUpdateJobSummary` → `UpdateJobFromInvoiceCommandHandler` → `Job.UpdateInvoiceInfo(invoice, occurredAt)` (`Jobs/Jobs.Domain/Models/Job.cs:378-399`). Today this updates `Summary.InvoiceId`, `Summary.InvoiceStatus` (Paid/Unpaid — `JobInvoiceStatus.cs`), and `Summary.Amounts`.
- Billing badge is derived in `Job.EffectiveStatus` (`Job.cs:67-96`). It returns `ReadyForInvoice` / `Invoiced` / `Paid` and is **not** extended here. Instead, the invoice's `SentMethod` is surfaced as a separate field on the job response so that clients can render the "Sent" bucket on top of `Invoiced` without the backend adding a new enum value that would confuse older clients.

## Changes by Layer

### 1. Summary field — `InvoiceSentMethod`

**File**: the job `Summary` class (`Invoices.Backend/Src/Jobs/Jobs.Domain/Models/Job.cs` near the other `Summary.*` fields like `InvoiceId` / `InvoiceStatus`).

```csharp
public sealed class Summary
{
    // ... existing fields ...
    public InvoiceSentMethod? InvoiceSentMethod { get; set; }
}
```

Preferred shape: a nullable `InvoiceSentMethod` mirrored from the invoice, rather than a derived bool — keeps future extensibility (e.g. separate phrasing for Email vs Manual in analytics).

### 2. `Job.UpdateInvoiceInfo` populates the summary field

**File**: `Invoices.Backend/Src/Jobs/Jobs.Domain/Models/Job.cs:378-399`.

```csharp
public void UpdateInvoiceInfo(Invoice invoice, DateTimeOffset occurredAt)
{
    Summary.InvoiceStatus = JobInvoiceStatusMapper.FromInvoiceStatus(invoice.Status);
    Summary.InvoiceSentMethod = invoice.SentMethod;   // NEW
    // ... existing Amounts etc ...
    RefreshComputedFields(occurredAt);
}
```

No new gRPC call is needed: the existing `TryUpdateJobSummary` already runs on every `InvoicesService.Add` (which is the path `PUT /Invoices` takes). When the invoice PUT carries `SentMethod = Manual`, the job summary is refreshed and `EffectiveStatus` returns `Sent` on the next read.

### 3. `invoiceSentMethod` field on job response

**Files**:
- Contract: `Invoices.Backend/Src/Jobs/Jobs.Contracts/Jobs/JobDto.cs` + `JobSummaryItemDto.cs` — add nullable `JobInvoiceSentMethodDto` field (`email | manual | null`).
- API DTOs: `Invoices.Backend/Src/Invoices.Api/Dto/Jobs/JobDetailsDto.cs` (`JobDto`) + `JobSummaryItemResponseDto.cs` — add nullable `InvoiceSentMethodDto` field.
- Domain-to-contract mapping: `Invoices.Backend/Src/Jobs/Jobs.Application/JobsMappings.cs` — project `Summary.InvoiceSentMethod` (`InvoiceSentMethod?` from `Invoices.Core.Models`) to the contract enum.
- Contract-to-API mapping: `Invoices.Backend/Src/Invoices.Api/Dto/Jobs/JobsApiMappings.cs` — thread the new field through in `ToApi(JobDto)` and `ToApi(JobSummaryItemDto)`.

Response shape (both endpoints):
```json
{ "id": "...", "status": "invoiced", "invoiceSentMethod": "manual", ... }
```

### 4. `Job.EffectiveStatus` — unchanged

**File**: `Invoices.Backend/Src/Jobs/Jobs.Domain/Models/Job.cs:67-96`.

The enum-driven status stays at `Unscheduled | Scheduled | InProgress | ReadyForInvoice | Invoiced | Paid`. No new `Sent` value is introduced — the "Sent" bucket is derived client-side from `status === "invoiced" && invoiceSentMethod !== null`, which keeps existing clients working without an upgrade.

## Job Timeline — aggregation

The `GetJobTimelineQueryHandler` is event-type-agnostic: it merges items from `JobEventSource` with items from `InvoiceEventSource` / `EstimateEventSource` (both fed by gRPC `GetTimelineByEntityId`). Once part 1 ships, each `InvoiceSentMethodChanged` item produced by `Tofu.Invoices.Backend` is mapped to central `EventType.InvoiceSentMethodChanged` by `Mapper.MapInvoiceEventType` and flows through `InvoiceEventSource.FetchEvents` into the merged result automatically.

Consequences:

- **No new `JobEventType`** — invoice actions never create duplicate job-side events.
- **No new gRPC method** — `GetTimelineByEntityId` is reused; only its response payload starts including the new event type.
- **No changes to `GetJobTimelineQueryHandler`**, `InvoiceEventSource`, or pagination logic.

### Response item

`GET /api/v3/jobs/{id}/timeline` starts returning items with:

- `eventType: "invoiceSentMethodChanged"`
- `payload: { from, to, docNumber }` with `from` / `to` ∈ `null | "email" | "manual"`

Frontend text (job timeline — distinct from invoice timeline because the invoice is a linked entity, not the subject):

| From → To | Job-timeline text |
|---|---|
| `null → manual`, `email → manual` | "You marked Invoice #{docNumber} as sent" |
| `manual → null`, `manual → email` | "You reverted Invoice #{docNumber} from sent" |

The "Undo" chip may be shown in the job timeline as well — it acts on the same underlying invoice via `PUT /Invoices`.

## Badge — contract change

The job response gains a new field `invoiceSentMethod` ∈ `null | "email" | "manual"` on `JobDto` (details) and `JobSummaryItemResponseDto` (list). The existing `status` enum stays at `Unscheduled | Scheduled | InProgress | ReadyForInvoice | Invoiced | Paid`. Clients that know about the new field render the "Sent" bucket locally (`status === "invoiced" && invoiceSentMethod !== null`); clients that don't see the same `Invoiced` badge as before — zero client-side breakage.

## Behaviour

"Job side" column below assumes the linked job has `manual status = Completed`.

| Invoice action | `Summary.InvoiceSentMethod` | Job response fields | Job timeline adds |
|---|---|---|---|
| Mark as sent (new invoice, never sent) | `null → Manual` | `status=invoiced, invoiceSentMethod=manual` | "You marked Invoice #N as sent" |
| Mark as sent (email previously succeeded) | `Email → Manual` | `status=invoiced, invoiceSentMethod=manual` | "You marked Invoice #N as sent" |
| Undo (never sent before) | `Manual → null` | `status=invoiced, invoiceSentMethod=null` | "You reverted Invoice #N from sent" |
| Undo (email sent before) | `Manual → Email` | `status=invoiced, invoiceSentMethod=email` | "You reverted Invoice #N from sent" |
| Idempotent repeat | no change | no change | — |
| Email send succeeds while `SentMethod = null` | `null → Email` (silent) | `status=invoiced, invoiceSentMethod=email` | "You sent Invoice #N to {email}" (existing `InvoiceEmailStatusChanged`) |

## Backward Compatibility

- Existing clients (iOS / Android / KMP worker / Web) continue to receive the same `status` enum values they always have — the new `invoiceSentMethod` field is simply an additional key they can ignore until they ship support.
- Jobs DB migration adds `Summary.InvoiceSentMethod` (nullable `int`). Existing rows default to `null`; the field is populated on the next `PUT /Invoices` that touches the linked invoice.

## Docs to Update

`features/jobs/Activity.md` — mark the "Sent" billing status and the "Mark invoice as sent (manual)" action rows as implemented; add the `invoiceSentMethodChanged` row to the "Event Payloads and Phrasing" table with the job-context text.

## Testing

### Unit (`Invoices.Tests` and/or `Jobs.Tests`)

- `Job.UpdateInvoiceInfo` copies `invoice.SentMethod` into `Summary.InvoiceSentMethod`.
- `Job.EffectiveStatus`:
  - `Completed` + linked unpaid invoice → `Invoiced` regardless of `Summary.InvoiceSentMethod`.
  - `Completed` + linked invoice with `InvoiceStatus = Paid` → `Paid`.
- Domain-to-contract mapping: `Summary.InvoiceSentMethod` projects to `JobInvoiceSentMethodDto` on both `JobDto` and `JobSummaryItemDto`; `null` domain value maps to `null` on the DTO.

### Integration (`Invoices.IntegrationTests` / `Invoices.Tests.Integration`)

- `PUT /api/invoices/{id}` with `sentMethod = "manual"` for an invoice linked to a `Completed` job:
  - Subsequent `GET /api/v3/jobs/{jobId}` returns `status = "invoiced"` and `invoiceSentMethod = "manual"`.
  - Subsequent `GET /api/v3/jobs/{jobId}/timeline` includes an `invoiceSentMethodChanged` item with the expected payload and correct ordering.
- Undo path via the same endpoint clears `invoiceSentMethod` to `null` (or `"email"` if a prior email send succeeded) and adds the reverse timeline item.
- Email-send on an invoice linked to a `Completed` job sets `invoiceSentMethod = "email"` on the linked job response through silent correction (no `SentMethodChanged` entry, existing `InvoiceEmailStatusChanged` appears instead).
