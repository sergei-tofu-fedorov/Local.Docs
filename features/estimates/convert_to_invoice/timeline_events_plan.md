# Timeline Events: invoiceCreatedFromEstimate & estimateInvoiceCreated

Implementation plan for adding two new timeline events when an invoice is created from an estimate.

## Source (TSV rows)

### Row 47 — `invoiceCreatedFromEstimate` (Invoice entity)
- **Payload**: `{ "estimateId": "...", "estimateNumber": "ES001", "docNumber": "INV001" }`
- **Text in job**: `You created Invoice #{docNumber} from Estimate #{estimateNumber}`
- **Text in invoice**: `You created this invoice from [Estimate #{estimateNumber}](tofu://estimate?id={estimateId})`
- **Condition**: `estimateId != null`
- **Created offline**: Yes

### Row 30 — `estimateInvoiceCreated` (Estimate entity)
- **Payload**: `{ "invoiceId": "guid", "invoiceNumber": "INV001", "docNumber": "ES001" }`
- **Text in estimate**: `You converted this estimate into [Invoice #{invoiceNumber}](tofu://invoice?id={invoiceId})`
- **Created offline**: Yes

## Decisions

- `invoiceCreatedFromEstimate` **replaces** the regular `invoiceCreated` (StatusChanged null→notPaid) — one event instead of two.
- `estimateInvoiceCreated` is handled **directly inside `AddInvoiceCommandHandler`** via `EnrichedEstimate` → domain event → factory → events repository flow. No separate command — this keeps invoice and estimate work in one logical unit (important for transactional consistency).

## Implementation Steps

### Step 1 — Event type enums

| File | Change |
|------|--------|
| `src/.../Models/Events/InvoiceEvent.cs` | Add `CreatedFromEstimate = 4` to `InvoiceEventType` |
| `src/.../Models/Events/EstimateEvent.cs` | Add `InvoiceCreated = 3` to `EventType` |

### Step 2 — Payload models

**`InvoiceEvent.cs`** — add:
```csharp
[Serializable]
public record InvoiceCreatedFromEstimatePayload
{
    public string? DocNumber { get; init; }
    public required string EstimateId { get; init; }
    public required string? EstimateNumber { get; init; }
}
```

**`EstimateEvent.cs`** — add:
```csharp
[Serializable]
public record EstimateInvoiceCreatedPayload
{
    public string? DocNumber { get; init; }
    public required string InvoiceId { get; init; }
    public required string? InvoiceNumber { get; init; }
}
```

### Step 3 — Domain events (`DomainEvent.cs`)

```csharp
// Invoice side — replaces InvoiceCreatedDomainEvent when EstimateId is present
public sealed class InvoiceCreatedFromEstimateDomainEvent : InvoiceDomainEvent
{
    public required string EstimateId { get; set; }
    public required string? EstimateNumber { get; set; }
}

// Estimate side — registered by EnrichedEstimate.SetInvoiceLink()
public sealed class EstimateInvoiceCreatedDomainEvent : EstimateDomainEvent
{
    public required string InvoiceId { get; set; }
    public required string? InvoiceNumber { get; set; }
}
```

### Step 4 — `EnrichedInvoice.Create()`

When `invoice.EstimateId` is not empty, register `InvoiceCreatedFromEstimateDomainEvent` **instead of** `InvoiceCreatedDomainEvent`.

The `EstimateNumber` is available because `AddInvoiceCommandHandler` loads the estimate first (see Step 7) and passes it to `Create()`.

**Option**: Add an overload or parameter to `Create()`:
```csharp
public static EnrichedInvoice Create(Invoice invoice, ILogger logger, DateTimeOffset? occurredAt,
    string? estimateNumber = null)
{
    // ...
    if (!string.IsNullOrWhiteSpace(invoice.EstimateId))
    {
        enrichedInvoice.RegisterDomainEvent(new InvoiceCreatedFromEstimateDomainEvent
        {
            OccurredAt = occurredAt ?? DateTimeOffset.UtcNow,
            DocNumber = invoice.Number,
            EstimateId = invoice.EstimateId,
            EstimateNumber = estimateNumber
        });
    }
    else
    {
        enrichedInvoice.RegisterDomainEvent(new InvoiceCreatedDomainEvent
        {
            OccurredAt = occurredAt ?? DateTimeOffset.UtcNow,
            DocNumber = invoice.Number
        });
    }
    // ...
}
```

### Step 5 — `EnrichedEstimate.SetInvoiceLink()`

Add a new method to `EnrichedEstimate`:
```csharp
public void SetInvoiceLink(string invoiceId, string? invoiceNumber, DateTimeOffset? occurredAt)
{
    Entity.InvoiceId = invoiceId;
    RegisterDomainEvent(new EstimateInvoiceCreatedDomainEvent
    {
        OccurredAt = occurredAt ?? DateTimeOffset.UtcNow,
        DocNumber = Entity.Number,
        InvoiceId = invoiceId,
        InvoiceNumber = invoiceNumber
    });
}
```

### Step 6 — `InvoiceEventsFactory`

Add case in the switch:
```csharp
InvoiceCreatedFromEstimateDomainEvent created => BuildInvoiceEvent(
    created, entity.AccountId, entity.Id, masterUserId, entity.Version, actorType),
```

Add builder method:
```csharp
private static InvoiceEvent BuildInvoiceEvent(InvoiceCreatedFromEstimateDomainEvent domainEvent,
    string accountId, string invoiceId, string? masterUserId,
    int invoiceVersion, ActorType actorType)
{
    var payload = new InvoiceCreatedFromEstimatePayload
    {
        DocNumber = domainEvent.DocNumber,
        EstimateId = domainEvent.EstimateId,
        EstimateNumber = domainEvent.EstimateNumber
    };
    var serialized = EventJsonSerializer.SerializePayload(payload);
    return InvoiceEvent.Create(accountId, invoiceId, masterUserId,
        InvoiceEventType.CreatedFromEstimate, actorType, serialized, invoiceVersion, domainEvent.OccurredAt);
}
```

### Step 6b — `EstimateEventsFactory`

Add case in the switch:
```csharp
EstimateInvoiceCreatedDomainEvent invoiceCreated => BuildEstimateEvent(
    invoiceCreated, entity.AccountId, entity.Id, masterUserId, entity.Version, actorType),
```

Add builder method:
```csharp
private static EstimateEvent BuildEstimateEvent(EstimateInvoiceCreatedDomainEvent domainEvent,
    string accountId, string estimateId, string? masterUserId,
    int estimateVersion, ActorType actorType)
{
    var payload = new EstimateInvoiceCreatedPayload
    {
        DocNumber = domainEvent.DocNumber,
        InvoiceId = domainEvent.InvoiceId,
        InvoiceNumber = domainEvent.InvoiceNumber
    };
    var serialized = EventJsonSerializer.SerializePayload(payload);
    return EstimateEvent.Create(accountId, estimateId, masterUserId,
        EventType.InvoiceCreated, actorType, serialized, estimateVersion, domainEvent.OccurredAt);
}
```

### Step 7 — Update `AddInvoiceCommandHandler`

Replace `TryLinkEstimateToInvoice()` with inline `EnrichedEstimate` logic. This keeps invoice + estimate work in one handler for transactional consistency.

**New dependencies** (add to constructor):
```csharp
private readonly IEstimateEventsRepository _estimateEventsRepository;
private readonly IEstimateEventsFactory _estimateEventsFactory;
```

**Updated `Handle()` method** — load estimate before invoice creation to get `EstimateNumber`:

```csharp
public async Task<Invoice> Handle(AddInvoiceCommand command, CancellationToken token)
{
    await _validator.ValidateAndThrowAsync(command, token);
    if (!command.Invoice.ValidateTotals())
        _logger.LogWarning("Totals are invalid in invoice with id '{InvoiceId}'", command.Invoice.Id);

    var existingInvoice = await _repository.Find(command.Invoice.AccountId, command.Invoice.Id, token);

    // --- Load estimate early (needed for EstimateNumber in the invoice event) ---
    Estimate? estimate = null;
    if (!string.IsNullOrWhiteSpace(command.Invoice.EstimateId))
    {
        estimate = await _estimatesRepository.Find(
            command.Invoice.AccountId, command.Invoice.EstimateId, token);
    }

    EnrichedInvoice enrichedInvoice;
    if (existingInvoice != null)
    {
        enrichedInvoice = existingInvoice.ToEnrichedInvoice();
        enrichedInvoice.Update(command.Invoice, _logger, command.OccurredAt);
    }
    else
    {
        enrichedInvoice = EnrichedInvoice.Create(
            command.Invoice, _logger, command.OccurredAt, estimate?.Number);
    }

    var savedInvoice = await _repository.InsertOrUpdate(enrichedInvoice.Entity, token);

    // --- Invoice events ---
    var invoiceEvents = _invoiceEventsFactory.CreateInvoiceEvents(
        enrichedInvoice,
        command.MasterUserId,
        string.IsNullOrWhiteSpace(command.MasterUserId) ? ActorType.Unknown : ActorType.User);

    if (invoiceEvents.Count != 0)
    {
        await _invoiceEventsRepository.Add(invoiceEvents, token);
        _logger.LogDebug("Published '{EventCount}' events for InvoiceId '{InvoiceId}'",
            invoiceEvents.Count, enrichedInvoice.Entity.Id);
    }

    // --- Link estimate (inline, no separate command) ---
    if (estimate != null)
    {
        await TryLinkEstimateToInvoice(
            estimate, enrichedInvoice.Entity, command.MasterUserId, command.OccurredAt, token);
    }

    return savedInvoice;
}
```

**Rewritten `TryLinkEstimateToInvoice()`** — now uses `EnrichedEstimate` + domain events:

```csharp
private async Task TryLinkEstimateToInvoice(
    Estimate estimate, Invoice invoice, string? masterUserId,
    DateTimeOffset? occurredAt, CancellationToken token)
{
    try
    {
        var enrichedEstimate = estimate.ToEnrichedEstimate();
        enrichedEstimate.SetInvoiceLink(invoice.Id, invoice.Number, occurredAt);

        await _estimatesRepository.InsertOrUpdate(enrichedEstimate.Entity, token);

        var events = _estimateEventsFactory.CreateEstimateEvents(
            enrichedEstimate,
            masterUserId,
            string.IsNullOrWhiteSpace(masterUserId) ? ActorType.Unknown : ActorType.User);

        if (events.Count != 0)
        {
            await _estimateEventsRepository.Add(events, token);
            _logger.LogDebug("Published '{EventCount}' link events for EstimateId '{EstimateId}'",
                events.Count, estimate.Id);
        }

        _logger.LogDebug("Linked estimate '{EstimateId}' to invoice '{InvoiceId}'",
            estimate.Id, invoice.Id);
    }
    catch (Exception ex)
    {
        _logger.LogError(ex,
            "Failed to link estimate '{EstimateId}' to invoice '{InvoiceId}'",
            estimate.Id, invoice.Id);
    }
}
```

### Step 8 — Proto files

**`InvoicesApi.proto`**:
```proto
enum InvoiceEventType {
    IET_UNKNOWN = 0;
    IET_STATUS_CHANGED = 1;
    IET_EMAIL_STATUS_CHANGED = 2;
    IET_PAYMENT_RECEIVED = 3;
    IET_CREATED_FROM_ESTIMATE = 4;  // new
}
```

**`EstimatesApi.proto`**:
```proto
enum EstimateEventType {
    EET_UNKNOWN = 0;
    EET_STATUS_CHANGED = 1;
    EET_EMAIL_STATUS_CHANGED = 2;
    EET_INVOICE_CREATED = 3;  // new
}
```

### Step 9 — gRPC mapping

**`InvoicesServiceMapping.cs`** in `MapToInvoiceEventType`:
```csharp
InvoiceEventType.CreatedFromEstimate => InvoiceEventTypeProto.IetCreatedFromEstimate,
```

**`EstimatesServiceMapping.cs`** in `MapToEstimateEventType`:
```csharp
EventType.InvoiceCreated => EstimateEventTypeProto.EetInvoiceCreated,
```

### Step 10 — Unit tests

- `InvoiceEventsFactory`: verify `InvoiceCreatedFromEstimateDomainEvent` → correct event type and payload
- `EstimateEventsFactory`: verify `EstimateInvoiceCreatedDomainEvent` → correct event type and payload
- `AddInvoiceCommandHandler`: scenario with `EstimateId` — verify estimate is loaded, `SetInvoiceLink` is called, estimate events are saved, `invoiceCreatedFromEstimate` replaces `invoiceCreated`

## Dependency order

```
Step 1 (enums) + Step 2 (payloads)                    — parallel
         ↓
Step 3 (domain events)
         ↓
Step 4 (EnrichedInvoice) + Step 5 (EnrichedEstimate)   — parallel
         ↓
Step 6 + 6b (factories)                                 — parallel
         ↓
Step 7 (AddInvoiceCommandHandler update)
         ↓
Step 8 (proto) + Step 9 (mapping)                       — parallel
         ↓
Step 10 (tests)
```

## Files to modify

| File | Type of change |
|------|---------------|
| `src/Tofu.Invoices.Domain/Models/Events/InvoiceEvent.cs` | Enum + payload |
| `src/Tofu.Invoices.Domain/Models/Events/EstimateEvent.cs` | Enum + payload |
| `src/Tofu.Invoices.Domain/Models/Events/DomainEvent.cs` | Two new domain event classes |
| `src/Tofu.Invoices.Domain/Models/Invoices/EnrichedInvoice.cs` | Conditional event in `Create()` |
| `src/Tofu.Invoices.Domain/Models/Estimate/EnrichedEstimate.cs` | New `SetInvoiceLink()` method |
| `src/Tofu.Invoices.Domain/Events/InvoiceEventsFactory.cs` | New event builder |
| `src/Tofu.Invoices.Domain/Events/EstimateEventsFactory.cs` | New event builder |
| `src/Tofu.Invoices.Domain/Commands/AddInvoice/AddInvoiceCommandHandler.cs` | Rewrite `TryLinkEstimateToInvoice` with `EnrichedEstimate` + new deps |
| `src/Tofu.Invoices.Protos/V1/InvoicesApi.proto` | New enum value |
| `src/Tofu.Invoices.Protos/V1/EstimatesApi.proto` | New enum value |
| `src/Tofu.Invoices.Api/Grpc/Mapping/InvoicesServiceMapping.cs` | Mapping |
| `src/Tofu.Invoices.Api/Grpc/Mapping/EstimatesServiceMapping.cs` | Mapping |

## New files

None — all changes are in existing files.
