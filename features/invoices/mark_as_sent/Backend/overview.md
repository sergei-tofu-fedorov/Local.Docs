# Invoice Mark as Sent — Backend Implementation Plan

Backend plan for recording that an invoice was delivered to a customer outside the system (downloaded PDF, printed, shared link) without sending an email. The action is undoable until another change overrides it.

Covers the full backend work for the product initiative, split into two parts:

- **[Part 1 — Invoice side (WEB-1435)](./1_invoices.md)** — domain, events, proto, and gateway DTO. Introduces a nullable `SentMethod` field on the invoice, surfaces it through `PUT /Invoices`, emits a dedicated `SentMethodChanged` timeline event. Stands on its own and delivers the invoice-level feature.
- **[Part 2 — Job side (WEB-1436)](./2_jobs.md)** — surfaces the invoice's `SentMethod` on the linked job response via a new `invoiceSentMethod` field (so clients can render a "Sent" billing badge on top of `Invoiced` without a new enum value) and merges the mark-as-sent / undo events into the aggregated job timeline. Depends on part 1.

Frontend (WEB-980) is out of scope — only behaviour visible through the backend contract is described.

Related ClickUp tasks: WEB-885 (initiative), WEB-979 (BE parent), WEB-1435 (part 1), WEB-1436 (part 2).

## High-level Approach

Mirror the existing **estimate** implementation: introduce a nullable `SentMethod` field on the invoice with values `Email` / `Manual`. `MailStatus` stays dedicated to email-delivery tracking and is **not** touched by manual mark-as-sent. Changes propagate through the existing `PUT /Invoices` upsert flow — no new endpoint is introduced.

### Semantics

| `SentMethod` | Meaning |
|---|---|
| `null` | Invoice was never sent and never manually marked |
| `Email` | Invoice was sent via email through the system |
| `Manual` | User marked the invoice as sent manually |

Undo restores the previous value: `Manual → null` if the invoice was never sent via email before, or `Manual → Email` if an email-send had succeeded earlier.

### Job-side effects (summary)

When the invoice is linked to a job, the invoice's `SentMethod` is surfaced on the job response via a new `invoiceSentMethod` field (`"email" | "manual" | null`). Undoing back to `null` clears the field. The job timeline shows `"You marked Invoice #N as sent"` / `"You reverted Invoice #N from sent"` — aggregated from the invoice timeline via the existing gRPC pull (no duplicated job-side event). The `status` enum on the job is **not** extended — clients derive the "Sent" bucket locally from `status === "invoiced" && invoiceSentMethod !== null` to avoid breaking older clients that don't know a new enum value. See `features/jobs/Activity.md` for the display spec.

## Authorization

Reuses the existing `invoice.email.send` permission — this flow semantically belongs to the "send invoice" capability, so users who can send invoices can also record manual delivery. No new permission is introduced.

## Public Contract Summary (for WEB-980 frontend)

### API

`PUT /Invoices` — no new endpoint. Request and response carry a new field `sentMethod` ∈ `null | "email" | "manual"`.

- Mark as sent: send full `InvoiceDto` with `"sentMethod": "manual"`.
- Undo: send full `InvoiceDto` with either `"sentMethod": null` (invoice was never emailed before the manual mark) or `"sentMethod": "email"` (invoice had a successful email send before the manual mark).

`GET /api/v3/Invoices/paged` and `GET /api/v3/Invoices` return `sentMethod` on every item. The paged endpoint gains a new query parameter `sentMethod` — see [Filtering](#filtering).

### Timeline event

Both `GET /api/timeline/{invoiceId}` and `GET /api/v3/jobs/{id}/timeline` start returning items with:

- `eventType: "invoiceSentMethodChanged"`
- `payload: { from, to, docNumber }` with `from` / `to` ∈ `null | "email" | "manual"`

Text mapping depends on context:

| From → To | Invoice timeline | Job timeline |
|---|---|---|
| `null → manual`, `email → manual` | "You marked this invoice as sent" | "You marked Invoice #{docNumber} as sent" |
| `manual → null`, `manual → email` | "You reverted the invoice from sent" | "You reverted Invoice #{docNumber} from sent" |

The "Undo" chip belongs on entries where `to = "manual"` and this is the most recent `invoiceSentMethodChanged` event; the chip's click performs a `PUT /Invoices` with `sentMethod` set back to the invoice's pre-manual value (`null` or `"email"`).

### Job badge

The job response gains a new field `invoiceSentMethod` ∈ `null | "email" | "manual"` on both `JobDto` (details) and `JobSummaryItemResponseDto` (list), projected from the linked invoice. The existing `status` enum is **not** extended — the old values (`unscheduled`, `scheduled`, `inProgress`, `readyForInvoice`, `invoiced`, `paid`) are preserved as-is. Clients opt-in to the new "Sent" bucket by reading the new field: render `Sent` when `status === "invoiced" && invoiceSentMethod !== null` (and fall back to the `invoiced` badge for clients not yet updated).

### Filtering

The existing payment filter is unchanged: `GET /api/v3/Invoices/paged?invoiceStatus=notPaid|paid` and `GetAllInvoicesRequestModel.Statuses` continue to accept `InvoiceStatus` / `PagedInvoiceStatus` values (payment-only). `SentMethod` does **not** participate in those — the two dimensions are orthogonal.

A new query parameter is introduced on `GET /api/v3/Invoices/paged` to filter by send state:

| `?sentMethod=` | Matches invoices where |
|---|---|
| omitted | no send-state filter (all invoices) |
| `none` | `SentMethod == null` (not sent) |
| `email` | `SentMethod == Email` |
| `manual` | `SentMethod == Manual` |
| `any` | `SentMethod != null` (sent, either channel) |

Combinable with `invoiceStatus` (e.g. `?invoiceStatus=notPaid&sentMethod=any` = "sent but unpaid"). Absent parameter → no send-state filter; malformed values → `400 Bad Request` (enum model-binding rejects unknown strings).

Plumbed through: gateway API enum `PagedInvoiceSentMethod` → core model `GetInvoicesPagedRequestModel.SentMethodFilter` → gRPC `GetInvoicesPagedRequest.sent_method_filter` (new proto field using the new `InvoiceSentMethodFilter` enum) → `InvoicesRepository.GetPaged` Mongo filter. No change to existing payment-status machinery. See [Part 1](./1_invoices.md) changes 12–13 for code-level details.

`GetAll` is deliberately **not** extended — it's used internally (reports, currency summaries) where a send-state filter has no use case today.

### Sent badge derivation

The client's "Sent" badge today reads from `MailStatus` (treating `Sent` / `MarkedAsSent` / `Opened` as "sent"). Going forward, `SentMethod` becomes the canonical signal. `MailStatus` keeps driving the email-specific sub-states (`InProgress`, `Error`, `Opened`) for the detailed email tracking UI, but the top-level "Sent" / "Not sent" indicator comes from `SentMethod` plus a legacy fallback:

| Invoice fields | "Sent" badge |
|---|---|
| `SentMethod != null` | Yes |
| `SentMethod == null`, `MailStatus ∈ { Sent, Opened, MarkedAsSent }` | Yes (legacy fallback) |
| `SentMethod == null`, `MailStatus ∈ { null, InProgress, Error }` | No |

Clients read `SentMethod` and `MailStatus` from the invoice response and apply this rule locally. The fallback row covers legacy invoices not re-saved since the feature shipped (no data migration; see Backward Compatibility). Once any subsequent email-send succeeds, the silent `null → Email` correction populates `SentMethod`, after which the first row takes over. The backend does **not** mutate stored `SentMethod` based on `MailStatus` — this keeps the "never-sent-via-email and never-manually-marked" case observable on the stored `SentMethod` for other consumers of the contract.

## Backward Compatibility

- Existing invoice documents (Tofu.Invoices MongoDB) have no `SentMethod` field; reads return `null`. No data migration required.
- Clients display legacy invoices using the fallback row from the [Sent badge derivation](#sent-badge-derivation) table: `MailStatus ∈ { Sent, Opened, MarkedAsSent }` is treated as sent until `SentMethod` is populated.
- The silent correction promotes `null → Email` transparently on the next successful email-send for any legacy invoice, without emitting a timeline event. After that the canonical `SentMethod != null` rule takes over.
- Existing jobs have `Summary.InvoiceSentMethod = null` after the code ships. `Job.EffectiveStatus` continues to return `Invoiced` / `Paid` exactly as before until a linked invoice is re-saved through `PUT /Invoices`, at which point the new field is populated and the `Sent` badge appears where appropriate.
- No changes to the `InvoiceStatus` proto/enum or to `PagedInvoiceStatus`. Existing iOS / Android / Web clients cannot receive an unknown value on those fields. The only new enum value surfaced to clients is `InvoiceSentMethod` (with `Unknown` tag `0` reserved, following the `EstimateSentMethod` convention — unknown tags round-trip as `null`).

## Docs to Update

- `Backend/Services/Tofu.Invoices/Activity.md` — new `SentMethodChanged` event type and payload (details in [Part 1](./1_invoices.md)).
- `features/jobs/Activity.md` — mark the "Sent" billing status and the "Mark invoice as sent (manual)" rows as implemented; add the `invoiceSentMethodChanged` phrasing row (details in [Part 2](./2_jobs.md)).
