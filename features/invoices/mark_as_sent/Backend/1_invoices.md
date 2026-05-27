# Part 1 — Invoice Side (WEB-1435)

Scope: invoice-level backend work. Introduces a nullable `SentMethod` field on the invoice, surfaces it through `PUT /Invoices`, and emits a dedicated timeline event when it changes.

Covers changes in:

- `Tofu.Invoices.Backend` — domain, events, proto, gRPC mapping.
- `Invoices.Backend` (gateway) — core model, DTO, invoice-level gRPC response mapping.

Prerequisites: none. This part stands on its own and delivers the invoice-side feature; job-side propagation lives in [`2_jobs.md`](./2_jobs.md).

## Current State

### Estimate side (template)

- Enum: `src/Tofu.Invoices.Domain/Models/Estimate/EstimateSentMethod.cs` — `{ Unknown, Email, Manual }`.
- Field on `Estimate`: `EstimateSentMethod? SentMethod`.
- Domain logic: `EnrichedEstimate.SetStatus()` (`Models/Estimate/EnrichedEstimate.cs:67-112`) combines status + sent-method and registers `EstimateStatusChangeDomainEvent`. Handles silent correction `null → Email` (no event raised when email send transitions the estimate to `Sent`).
- Proto: `EstimatesApi.proto` — `enum EstimateSentMethod { ESM_UNKNOWN, ESM_EMAIL, ESM_MANUAL }`, field `EstimateSentMethod sent_method = 26` on `EstimateObj`.
- Proto ↔ domain mapping: `src/Tofu.Invoices.Api/Grpc/Mapping/EstimatesServiceMapping.cs:147-165` — `EsmUnknown ↔ null`, `EsmEmail ↔ Email`, `EsmManual ↔ Manual`.
- Gateway DTO: `Invoices.Backend/Src/Invoices.Api/Models/EstimateDto.cs` — `EstimateSentMethodDto? SentMethod`; dedicated DTO type in `Invoices.Backend/Src/Invoices.Api/Models/EstimateSentMethodDto.cs`.

### Invoice side (today)

- `Invoice` (`Models/Invoices/Invoice.cs`) has no `SentMethod` field. Send state is tracked only in `MailStatus` (enum `EmailStatusType`).
- `EnrichedInvoice.Update()` (`Models/Invoices/EnrichedInvoice.cs:178-221`) mirrors the estimate update shape but does not call anything equivalent to `SetStatus(sentMethod)`.
- `AddInvoiceCommandHandler` (`Commands/AddInvoice/AddInvoiceCommandHandler.cs`) uses the upsert flow and collects domain events via `InvoiceEventsFactory`.
- Gateway DTO: `Invoices.Backend/Src/Invoices.Api/Models/InvoiceDto.cs` already carries `Status` and `MailStatus` but has no `SentMethod`. No `InvoiceSentMethodDto` exists — it needs to be created.
- Core model `Invoices.Backend/Src/Invoices.Core/Models/Invoice.cs` has `MailStatus` but no `SentMethod` (estimates do — `Invoices.Core/Models/Estimate.cs:34` + dedicated `EstimateSentMethod.cs`).
- Proto ↔ domain mapping lives in `src/Tofu.Invoices.Api/Grpc/Mapping/InvoicesServiceMapping.cs` (alongside `EstimatesServiceMapping.cs`).

## Changes by Layer

### 1. Domain — new enum

**New file**: `src/Tofu.Invoices.Domain/Models/Invoices/InvoiceSentMethod.cs`.

```csharp
namespace Tofu.Invoices.Domain.Models.Invoices;

public enum InvoiceSentMethod
{
    Unknown = 0,
    Email   = 1,
    Manual  = 2,
}
```

### 2. Domain — new field on `Invoice`

**File**: `src/Tofu.Invoices.Domain/Models/Invoices/Invoice.cs`.

Add a nullable field following the same BSON/null conventions used for optional enums:

```csharp
[BsonIgnoreIfNull]
public InvoiceSentMethod? SentMethod { get; set; }
```

MongoDB is the storage — no data migration is required; documents without the field read back as `null`.

### 3. Domain event

**File**: `src/Tofu.Invoices.Domain/Models/Events/DomainEvent.cs`.

```csharp
public sealed class InvoiceSentMethodChangeDomainEvent
    : InvoiceDomainEvent<InvoiceSentMethod>
{
    // OldValue / NewValue / DocNumber / OccurredAt inherited
}
```

The existing generic `InvoiceDomainEvent<T>` already carries `OldValue`, `NewValue`, `DocNumber`, `OccurredAt`.

### 4. Domain — `EnrichedInvoice.SetSentMethod`

**File**: `src/Tofu.Invoices.Domain/Models/Invoices/EnrichedInvoice.cs`.

Add a new method:

```csharp
public Result<bool> SetSentMethod(
    InvoiceSentMethod? newMethod,
    DateTimeOffset? occurredAt)
{
    if (Entity.SentMethod == newMethod)
        return Result.Success(false);

    RegisterDomainEvent(new InvoiceSentMethodChangeDomainEvent
    {
        OldValue = Entity.SentMethod,
        NewValue = newMethod,
        OccurredAt = occurredAt ?? DateTimeOffset.UtcNow,
        DocNumber = Entity.Number,
    });
    Entity.SentMethod = newMethod;
    return Result.Success(true);
}
```

Unlike estimates, invoice has no workflow status coupled with `SentMethod`, so `SetSentMethod` is an independent method rather than being folded into `SetStatus`.

**Silent correction in `SetMailStatus`** (`EnrichedInvoice.cs:108-135`): when `newStatus` transitions to `EmailStatusType.Sent` (provider confirmed delivery) and `Entity.SentMethod` is `null`, set `Entity.SentMethod = Email` **without** registering `InvoiceSentMethodChangeDomainEvent`. Only the existing `InvoiceMailStatusChangeDomainEvent` is raised. Skipping the sent-method event here avoids a duplicate timeline entry that would repeat what the email-sent event already shows.

Template: `EnrichedEstimate.SetStatus:91-108` (inside the estimate's status-change method, because estimate's `Sent` is a workflow status that carries the sent-method). For invoices the same behaviour belongs in `SetMailStatus` because invoices have no status-driven `Sent` transition — the email delivery itself (`MailStatus → Sent`) is the signal that `SentMethod` should become `Email`.

### 5. Domain — wire into upsert flow

**File**: `src/Tofu.Invoices.Domain/Models/Invoices/EnrichedInvoice.cs`.

In `Update()`, immediately after the `SetStatus(...)` call on line 215, add:

```csharp
var setSentMethodResult = SetSentMethod(newInvoice.SentMethod, occurredAt);
if (setSentMethodResult.IsFailure)
    logger.LogError(setSentMethodResult.Error);
```

`AddInvoiceCommandHandler` itself needs no changes — it already wraps existing invoices via `ToEnrichedInvoice()` and calls `Update()`; domain events are collected downstream by `InvoiceEventsFactory`.

### 6. Event factory

**File**: `src/Tofu.Invoices.Domain/Models/Events/InvoiceEvent.cs`.

A dedicated `SentMethodChanged` type is introduced rather than folding the change into `EmailStatusChanged`: manual mark and email delivery are distinct concepts, and a dedicated type keeps the timeline parser simple and mirrors the estimate domain.

```csharp
public enum InvoiceEventType
{
    Unknown = 0,
    StatusChanged,
    EmailStatusChanged,
    PaymentReceived,
    CreatedFromEstimate,
    CreatedFromJob,
    Created,
    SentMethodChanged, // NEW
}

[Serializable]
public record InvoiceSentMethodChangedPayload
{
    public string? DocNumber { get; init; }
    public required InvoiceSentMethod? From { get; init; }
    public required InvoiceSentMethod? To { get; init; }
}
```

**File**: `src/Tofu.Invoices.Domain/Events/InvoiceEventsFactory.cs`.

Extend the `switch` in `CreateInvoiceEvents` (lines 42-57):

```csharp
InvoiceSentMethodChangeDomainEvent sentMethodChange => BuildInvoiceEvent(
    sentMethodChange, entity.AccountId, entity.Id, masterUserId, entity.Version, actorType),
```

Add the corresponding `BuildInvoiceEvent` overload that serialises `InvoiceSentMethodChangedPayload` and sets `EventType = InvoiceEventType.SentMethodChanged`.

### 7. Proto — `InvoiceObj` field and enum

**File**: `src/Tofu.Invoices.Protos/V1/InvoicesApi.proto`.

Add the enum (mirroring `EstimateSentMethod` layout):

```proto
enum InvoiceSentMethod {
  ISM_UNKNOWN = 0;
  ISM_EMAIL   = 1;
  ISM_MANUAL  = 2;
}
```

Add the field to `InvoiceObj` at the next free tag (`37` — highest used is `InvoiceSource source = 36`):

```proto
message InvoiceObj {
    // ... existing fields ...
    InvoiceSentMethod sent_method = 37;
}
```

Any request message that accepts a full `InvoiceObj` picks up the field transparently.

### 8. Proto — timeline event type

**File**: `src/Tofu.Invoices.Protos/V1/InvoicesApi.proto` (continuing the `InvoiceEventType` enum at lines 420-428).

Add the next value after `IET_CREATED = 6`:

```proto
enum InvoiceEventType {
    IET_UNKNOWN = 0;
    IET_STATUS_CHANGED = 1;
    IET_EMAIL_STATUS_CHANGED = 2;
    IET_PAYMENT_RECEIVED = 3;
    IET_CREATED_FROM_ESTIMATE = 4;
    IET_CREATED_FROM_JOB = 5;
    IET_CREATED = 6;
    IET_SENT_METHOD_CHANGED = 7;   // NEW
}
```

### 9. Proto ↔ domain mapping

**File**: `src/Tofu.Invoices.Api/Grpc/Mapping/InvoicesServiceMapping.cs` (alongside `EstimatesServiceMapping.cs`).

Follow the shape used for estimates in `EstimatesServiceMapping.cs:147-165`:

```csharp
public static InvoiceSentMethod? MapToDomain(InvoiceSentMethodProto proto)
    => proto switch
    {
        InvoiceSentMethodProto.IsmUnknown => null,
        InvoiceSentMethodProto.IsmEmail   => InvoiceSentMethod.Email,
        InvoiceSentMethodProto.IsmManual  => InvoiceSentMethod.Manual,
        _ => null,
    };

public static InvoiceSentMethodProto MapToProto(InvoiceSentMethod? value)
    => value switch
    {
        InvoiceSentMethod.Unknown => InvoiceSentMethodProto.IsmUnknown,
        InvoiceSentMethod.Email   => InvoiceSentMethodProto.IsmEmail,
        InvoiceSentMethod.Manual  => InvoiceSentMethodProto.IsmManual,
        _ => InvoiceSentMethodProto.IsmUnknown,
    };
```

Also ensure the timeline-item mapping in this file maps `InvoiceEventType.SentMethodChanged` → `InvoiceEventTypeProto.IetSentMethodChanged` in the `GetTimelineByEntityId` response (`Tofu.Invoices.Api/Grpc/V1/InvoicesService.cs:244-262`).

### 10. Gateway — core model and DTO

**New file**: `Invoices.Backend/Src/Invoices.Core/Models/InvoiceSentMethod.cs`.

```csharp
namespace Invoices.Core.Models;

public enum InvoiceSentMethod
{
    Unknown = 0,
    Email   = 1,
    Manual  = 2,
}
```

**File**: `Invoices.Backend/Src/Invoices.Core/Models/Invoice.cs`.

Add the field (mirror `Estimate.cs:34`):

```csharp
public InvoiceSentMethod? SentMethod { get; set; }
```

**New file**: `Invoices.Backend/Src/Invoices.Api/Models/InvoiceSentMethodDto.cs` — dedicated DTO enum mirroring `EstimateSentMethodDto` shape. Do not reuse the estimate DTO across domains.

**File**: `Invoices.Backend/Src/Invoices.Api/Models/InvoiceDto.cs`.

```csharp
public InvoiceSentMethodDto? SentMethod { get; set; }
```

### 11. Gateway — mappings

**File**: `Invoices.Backend/Src/Tofu.Invoices/Mapping/Mapper.cs`.

1. Extend the `InvoiceObj` ↔ `Invoices.Core.Models.Invoice` mapping so the new `sent_method` field is copied in both directions.
2. Extend `MapInvoiceEventType` (switch on lines 1218-1228):

   ```csharp
   InvoiceEventType.IetSentMethodChanged => EventType.InvoiceSentMethodChanged,
   ```

**File**: `Invoices.Backend/Src/Invoices.Core/Models/Timeline/EventType.cs`.

Add to the invoice group and to `EventTypeExtensions.EventTypesByEntityType[AggregateCursorEntityType.Invoice]`:

```csharp
public enum EventType
{
    // ... existing invoice types ...
    InvoiceSentMethodChanged,   // NEW
    // ... existing job/visit types ...
}
```

**File**: `Invoices.Backend/Src/Invoices.Api/Models/InvoiceDto.cs` + its mapper — pass the new `SentMethod` through the `InvoiceDto ↔ Invoices.Core.Invoice ↔ gRPC InvoiceObj` chain, following the `EstimateSentMethodDto` mapping convention.

### 12. Gateway — `?sentMethod=` filter on `GET /api/v3/Invoices/paged`

**New file**: `Invoices.Backend/Src/Invoices.Api/Models/PagedInvoiceSentMethod.cs` (mirroring the `PagedInvoiceStatus.cs` shape).

```csharp
[Newtonsoft.Json.JsonConverter(typeof(StringOnlyEnumConverter))]
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum PagedInvoiceSentMethod
{
    [EnumMember(Value = "none")]   None,
    [EnumMember(Value = "email")]  Email,
    [EnumMember(Value = "manual")] Manual,
    [EnumMember(Value = "any")]    Any,
}
```

**File**: `Invoices.Backend/Src/Invoices.Core/Models/Invoices/GetInvoicesPagedRequestModel.cs`.

Add the filter field — kept as a dedicated enum on the core model to avoid leaking the API-layer `PagedInvoiceSentMethod` deeper than the controller:

```csharp
public InvoiceSentMethodFilter? SentMethodFilter { get; set; }
```

Where `InvoiceSentMethodFilter` is a new enum in `Invoices.Core.Models`:

```csharp
public enum InvoiceSentMethodFilter { None, Email, Manual, Any }
```

**File**: `Invoices.Backend/Src/Invoices.Api/Controllers/V3/InvoicesController.cs` (the `Paged` action on lines 68-93).

Add the query parameter and translate to the core enum alongside the existing `invoiceStatus` mapping:

```csharp
[FromQuery] PagedInvoiceSentMethod? sentMethod,
// ...
SentMethodFilter = sentMethod switch
{
    PagedInvoiceSentMethod.None   => InvoiceSentMethodFilter.None,
    PagedInvoiceSentMethod.Email  => InvoiceSentMethodFilter.Email,
    PagedInvoiceSentMethod.Manual => InvoiceSentMethodFilter.Manual,
    PagedInvoiceSentMethod.Any    => InvoiceSentMethodFilter.Any,
    _ => null,
},
```

**File**: `Invoices.Backend/Src/Tofu.Invoices/Mapping/Mapper.cs` — extend `MapToGetInvoicesPagedRequest` (near line 125, where `InvoiceStatusType = MapToStatus(obj.InvoiceStatusType)` lives) to set the new gRPC field:

```csharp
SentMethodFilter = MapToSentMethodFilterProto(obj.SentMethodFilter),
```

With a small helper mapping `InvoiceSentMethodFilter` → `InvoiceSentMethodFilterProto` (1-to-1 value mapping; `null` → `ISMF_UNSPECIFIED`).

### 13. Tofu.Invoices.Backend — proto & repository filter

**File**: `src/Tofu.Invoices.Protos/V1/InvoicesApi.proto`.

Add a new enum:

```proto
enum InvoiceSentMethodFilter {
  ISMF_UNSPECIFIED = 0;   // no filter
  ISMF_NONE        = 1;   // SentMethod is null / absent
  ISMF_EMAIL       = 2;
  ISMF_MANUAL      = 3;
  ISMF_ANY         = 4;   // SentMethod != null
}
```

Extend `GetInvoicesPagedRequest` (currently `account_id = 1`, `limit = 2`, `client_id = 3`, `invoice_status_type = 4`, `token = 5`):

```proto
message GetInvoicesPagedRequest {
    string account_id = 1;
    int32 limit = 2;
    google.protobuf.StringValue client_id = 3;
    InvoiceStatus invoice_status_type = 4;
    google.protobuf.StringValue token = 5;
    InvoiceSentMethodFilter sent_method_filter = 6;   // NEW
}
```

**File**: `src/Tofu.Invoices.Api/Grpc/Mapping/InvoicesServiceMapping.cs`.

Map the proto filter enum → a domain-level filter enum (`InvoiceSentMethodFilter` in `Tofu.Invoices.Domain.Models.Invoices`, mirroring the gateway core one). Use the existing proto-enum mapping helpers as a template.

**File**: `src/Tofu.Invoices.Infrastructure/Repositories/InvoicesRepository.cs` — the `GetPaged` query builder.

Extend the Mongo `FilterDefinition<Invoice>` chain with a new clause when `SentMethodFilter` is not `null`:

| Filter | Mongo clause |
|---|---|
| `None` | `Builders<Invoice>.Filter.Or(Eq(i => i.SentMethod, null), Exists(i => i.SentMethod, false))` |
| `Email` | `Eq(i => i.SentMethod, InvoiceSentMethod.Email)` |
| `Manual` | `Eq(i => i.SentMethod, InvoiceSentMethod.Manual)` |
| `Any` | `Ne(i => i.SentMethod, null)` (matches `Email` and `Manual`, excludes null/missing) |

The field is stored `[BsonIgnoreIfNull]` (see change 2), so "absent" and "null" both represent the not-sent case — the `None` filter accepts both. A descending index on `SentMethod` is not required for correctness, but worth adding if account-level invoice counts grow large and the filter becomes hot.

### No `PUT /Invoices` controller changes

The existing `PUT /Invoices` (`Invoices.Backend/Src/Invoices.Api/Controllers/V1/InvoicesController.cs:147-169`) already calls `_invoicesService.Add(...)` which carries the full entity through to the microservice. Once the DTO carries `SentMethod`, mark-as-sent and undo are just two calls of the same endpoint with different payload values.

## Behaviour

All operations go through `PUT /Invoices`:

| Scenario | Incoming DTO | Domain event raised | Resulting state |
|---|---|---|---|
| Mark as sent (new invoice, never sent) | `SentMethod = Manual` | `InvoiceSentMethodChangeDomainEvent(null → Manual)` | `SentMethod = Manual`, `MailStatus` unchanged |
| Mark as sent (email previously succeeded) | `SentMethod = Manual` | `InvoiceSentMethodChangeDomainEvent(Email → Manual)` | `SentMethod = Manual`, `MailStatus = Sent` |
| Undo (never sent before) | `SentMethod = null` | `InvoiceSentMethodChangeDomainEvent(Manual → null)` | `SentMethod = null` |
| Undo (email sent before) | `SentMethod = Email` | `InvoiceSentMethodChangeDomainEvent(Manual → Email)` | `SentMethod = Email` |
| Idempotent repeat | `SentMethod = Manual` (already Manual) | none | no change |
| Email send succeeds while `SentMethod = null` | internal `SetMailStatus(Sent)` | only `InvoiceMailStatusChangeDomainEvent` | `SentMethod = Email` (silent), `MailStatus = Sent` |

## Invoice Timeline

Every `PUT /Invoices` that causes a `SentMethod` change produces exactly one persisted `InvoiceEvent` via `InvoiceEventsFactory`:

- `EventType = InvoiceEventType.SentMethodChanged`
- `Payload = InvoiceSentMethodChangedPayload { From, To, DocNumber }`
- `ActorType = User` when the call carries a master user id (falls back to `Unknown` otherwise)

Idempotent repeats and the silent correction on email send do not emit this event.

Returned by `GET /api/timeline/{invoiceId}` with shape:

- `eventType: "invoiceSentMethodChanged"`
- `payload: { from, to, docNumber }` with `from` / `to` ∈ `null | "email" | "manual"`

Frontend text (invoice timeline):

| From → To | Text |
|---|---|
| `null → manual`, `email → manual` | "You marked this invoice as sent" |
| `manual → null`, `manual → email` | "You reverted the invoice from sent" |

## Backward Compatibility

- Existing invoice documents (Tofu.Invoices MongoDB) have no `SentMethod` field; reads return `null`. No data migration is required.
- Clients derive the "Sent" badge for legacy invoices using the fallback rule in [`overview.md` → Sent badge derivation](./overview.md#sent-badge-derivation): `MailStatus ∈ { Sent, Opened, MarkedAsSent }` is treated as sent until `SentMethod` is populated. The backend does **not** synthesise `SentMethod` from `MailStatus` on read — the field stays `null` until the silent correction or a manual mark promotes it.
- The silent correction promotes `null → Email` transparently on the next successful email-send for any legacy invoice, without emitting a timeline event.
- No changes to the `InvoiceStatus` proto / API enum (or to `PagedInvoiceStatus`). Existing clients cannot receive an unknown value on the payment-status fields; they only see the new `sent_method` / `sentMethod` field, which follows the null-for-unknown convention shared with `EstimateSentMethod`.
- `SentMethod` is not an input to any existing list filter. The value is only read/written through `InvoiceObj` and `InvoiceDto`; `GetInvoicesPaged` and `GetAll` ignore it. See [`overview.md` → Filtering](./overview.md#filtering).

## Docs to Update

`Backend/Services/Tofu.Invoices/Activity.md` — add `InvoiceSentMethodChangeDomainEvent`, the `SentMethodChanged` persisted event type, and the payload; update the "Invoice Event Types" table.

## Testing

### Tofu.Invoices.Backend — Unit (`tests/Tofu.Invoices.UnitTests`)

- `EnrichedInvoice.SetSentMethod`:
  - `null → Manual` raises event, updates entity.
  - `Manual → null` raises event (undo).
  - `Manual → Manual` returns `Success(false)`, no event.
  - `Email → Manual` raises event (mark over email-send).
- `EnrichedInvoice.SetMailStatus` silent correction:
  - `MailStatus: null → Sent` when `SentMethod = null` sets `SentMethod = Email`, raises only `InvoiceMailStatusChangeDomainEvent`.
  - Same transition when `SentMethod = Manual` leaves `SentMethod` unchanged.
- `InvoiceEventsFactory` serialises `InvoiceSentMethodChangeDomainEvent` into an `InvoiceEvent` with the expected `EventType` and payload.

### Tofu.Invoices.Backend — Functional (`tests/Tofu.Invoices.FunctionalTests`)

- `PUT /v1/invoices` with `sent_method = ISM_MANUAL` on a previously unsent invoice → persists `Manual`, emits one timeline event of type `SentMethodChanged`.
- Idempotency: repeating the same PUT does not emit a second event.
- Undo: subsequent PUT with `ISM_UNKNOWN` (→ null) from `Manual` emits the reverse event.
- Email-send flow: `SetEmailStatus(ES_SENT)` on an invoice with `sent_method = null` sets `sent_method` to `EMAIL` in the response without producing a `SentMethodChanged` event.
- `GetTimelineByEntityId` includes `IET_SENT_METHOD_CHANGED` items with the expected payload shape.
- `GetInvoicesPaged` filter matrix — seed one invoice per sent state (`null`, `Email`, `Manual`) and verify each `sent_method_filter` value returns the expected subset (`ISMF_NONE` → null only; `ISMF_EMAIL` → Email only; `ISMF_MANUAL` → Manual only; `ISMF_ANY` → Email + Manual; `ISMF_UNSPECIFIED` → all three).
- `GetInvoicesPaged` with `ISMF_NONE` matches both `{ SentMethod: null }` and documents where the field is absent (covers legacy invoices written before the migration ships).

### Invoices.Backend — Unit (`Invoices.Tests`)

- `Mapper.MapInvoiceEventType(IetSentMethodChanged)` returns `EventType.InvoiceSentMethodChanged`.
- `InvoiceDto` ↔ `Invoices.Core.Invoice` ↔ `InvoiceObj` mapping round-trips `SentMethod` for all three values (`null`, `Email`, `Manual`).
- `Mapper.MapToGetInvoicesPagedRequest` round-trips `SentMethodFilter` through the `PagedInvoiceSentMethod` → `InvoiceSentMethodFilter` → `InvoiceSentMethodFilterProto` chain for all four values plus the "no filter" case.

### Invoices.Backend — Integration (`Invoices.Tests.Integration`)

- `GET /api/v3/Invoices/paged?sentMethod=manual` returns only invoices with `sentMethod = "manual"`.
- `GET /api/v3/Invoices/paged?sentMethod=any&invoiceStatus=notPaid` combines both filters (sent but unpaid).
- `GET /api/v3/Invoices/paged` without `sentMethod` returns all invoices regardless of send state (backward-compat).
