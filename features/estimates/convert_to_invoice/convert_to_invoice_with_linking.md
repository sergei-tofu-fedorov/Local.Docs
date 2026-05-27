# Convert Estimate to Invoice — Implementation Plan

## Overview

Allow creating an Invoice from an Estimate with a bidirectional link (`Invoice.EstimateId` + future enrichment in `EstimateDto`).

**Approach:** Client-side — the client fetches the Estimate, builds an `InvoiceDto` copying relevant fields, sets `EstimateId`, and sends via the standard `PUT /api/invoices`. The server persists the link.

## Business Rules

- **No status validation** — any Estimate status can be used to create an Invoice.
- **No automatic status transition** — the client updates the Estimate status (e.g., to Done) separately after creating the Invoice.
- **No server-side conversion endpoint** — uses the existing `PUT /api/invoices` flow.

## Field Mapping (Client Responsibility)

Fields copied from Estimate to Invoice by the client:

| Estimate Field   | Invoice Field    | Notes                              |
|------------------|------------------|------------------------------------|
| Client           | Client           | Direct copy                        |
| Date             | Date             | Or current date — client decides   |
| DueDays          | DueDays          | Direct copy                        |
| Items            | Items            | Direct copy (shared InvoiceItem[]) |
| Notes            | Notes            | Direct copy                        |
| Discount         | Discount         | Direct copy                        |
| Tax              | Tax              | Direct copy                        |
| SubtotalAmount   | SubtotalAmount   | Direct copy                        |
| DiscountAmount   | DiscountAmount   | Direct copy                        |
| TaxAmount        | TaxAmount        | Direct copy                        |
| TotalAmount      | TotalAmount      | Direct copy                        |
| CurrencyCode     | CurrencyCode     | Direct copy                        |
| Attachments      | Attachments      | Client decides                     |
| —                | EstimateId       | Set to Estimate.Id                 |
| —                | Number           | Invoice's own numbering            |
| —                | Status           | `NotPaid` (default)                |
| —                | TotalDue         | = TotalAmount                      |

## Phase 1: Invoices.Backend

### 1. Core Model — `Invoices.Core/Models/Invoice.cs`

Add field:

```csharp
/// <summary>Optional back-reference to the source estimate.</summary>
public string? EstimateId { get; set; }
```

### 2. API DTO — `Invoices.Api/Models/InvoiceDto.cs`

Add field:

```csharp
public string? EstimateId { get; set; }
```

### 3. DTO <-> Core Mapping — `Invoices.Api/Models/Invoices/Mapping.cs`

Update `Invoice.Map() -> InvoiceDto`:

```csharp
EstimateId = model.EstimateId,
```

Update `InvoiceDto.Map() -> Invoice`:

```csharp
EstimateId = model.EstimateId,
```

### 4. gRPC Mapping — `Tofu.Invoices/Mapping/Mapper.cs`

Add EstimateId mapping in both directions. Will be functional after proto update (Phase 2).

In `MapToInvoice (Core -> gRPC)`:

```csharp
EstimateId = obj.EstimateId ?? string.Empty
```

In `MapToInvoice (gRPC -> Core)`:

```csharp
EstimateId = string.IsNullOrEmpty(obj.EstimateId) ? null : obj.EstimateId
```

## Phase 2: Tofu.Invoices Service (Separate PR)

Add `EstimateId` support to the Tofu.Invoices.Backend codebase — proto, domain model, persistence, and mapping. Follows the existing `JobId` pattern exactly.

### 1. Proto — Add `estimate_id` to `InvoiceObj`

File: `src/Tofu.Invoices.Protos/V1/InvoicesApi.proto`

```proto
message InvoiceObj {
    // ... existing fields 1-34 ...
    google.protobuf.StringValue job_id = 34;
    google.protobuf.StringValue estimate_id = 35;
}
```

### 2. Domain Model — `Invoice.cs`

File: `src/Tofu.Invoices.Domain/Models/Invoices/Invoice.cs`

Add property (next to `JobId` for consistency):

```csharp
[BsonIgnoreIfNull]
public string? EstimateId { get; set; }
```

### 3. EnrichedInvoice — Copy on Update

File: `src/Tofu.Invoices.Domain/Models/Invoices/EnrichedInvoice.cs`

In `Update()` method, add the same null-guard pattern used by `JobId` — write-once, never clear:

```csharp
if (newInvoice.EstimateId != null)
{
    Entity.EstimateId = newInvoice.EstimateId;
}
```

Place right after the existing `JobId` block:
```csharp
if (newInvoice.JobId != null)
{
    Entity.JobId = newInvoice.JobId;
}
if (newInvoice.EstimateId != null)
{
    Entity.EstimateId = newInvoice.EstimateId;
}
```

### 4. Repository — Persist `EstimateId`

File: `src/Tofu.Invoices.Infrastructure/Repositories/InvoicesRepository.cs`

In `DefineInsertOrUpdate()`, add after the `JobId` line:

```csharp
.Set(inv => inv.JobId, updatedEntity.JobId)
.Set(inv => inv.EstimateId, updatedEntity.EstimateId);
```

### 5. gRPC Mapping — Both Directions

File: `src/Tofu.Invoices.Api/Grpc/Mapping/InvoicesServiceMapping.cs`

**Proto → Domain** (`MapToInvoice`), add after `JobId = invoiceObj.JobId`:

```csharp
EstimateId = invoiceObj.EstimateId,
```

**Domain → Proto** (`MapToInvoiceObj`), add after `JobId = invoice.JobId`:

```csharp
EstimateId = invoice.EstimateId
```

### 6. Tests

- **Unit test**: Mapping round-trip — `Invoice` with `EstimateId` → `InvoiceObj` → `Invoice` preserves value.
- **Unit test**: `EnrichedInvoice.Update` — sets `EstimateId` when non-null, preserves existing when null.
- **Functional test**: Create invoice with `EstimateId` via `Add` → fetch via `Get` → verify `EstimateId` returned.

### 7. Cross-repo: Publish NuGet and Update Invoices.Backend

After merging the changes above:

1. **Publish new `Tofu.Invoices.Protos` NuGet** — update version so consumers get the new `estimate_id` field.
2. **Update NuGet in Invoices.Backend** — reference new proto package so Phase 1's gRPC mapping compiles.

### Files Affected (Phase 2)

| File | Change |
|------|--------|
| `src/Tofu.Invoices.Protos/V1/InvoicesApi.proto` | Add `estimate_id = 35` to `InvoiceObj` |
| `src/Tofu.Invoices.Domain/Models/Invoices/Invoice.cs` | Add `EstimateId` property |
| `src/Tofu.Invoices.Domain/Models/Invoices/EnrichedInvoice.cs` | Copy `EstimateId` in `Update()` |
| `src/Tofu.Invoices.Infrastructure/Repositories/InvoicesRepository.cs` | Persist `EstimateId` in `DefineInsertOrUpdate` |
| `src/Tofu.Invoices.Api/Grpc/Mapping/InvoicesServiceMapping.cs` | Map `EstimateId` in both directions |
| `tests/Tofu.Invoices.UnitTests/` | Mapping + EnrichedInvoice tests |
| `tests/Tofu.Invoices.FunctionalTests/` | Persistence round-trip test |

### Notes

- **No validation** — the server does not verify that the referenced estimate exists. It stores the `EstimateId` as-is (same as `JobId`).
- **No domain events** — setting `EstimateId` is a data link, not a business state change.
- **Write-once semantics** — once `EstimateId` is set, a subsequent update with `EstimateId = null` won't clear it (same `if != null` guard as `JobId`). This prevents accidental unlinking by clients that don't send the field.

## Phase 3: Write-time Estimate ↔ Invoice Link

When an invoice is created with `EstimateId`, the backend automatically sets `InvoiceId` on the corresponding estimate. This is a **write-time denormalization** — the link is established at invoice creation, not looked up at read time.

### Design Decisions

- **Write-time, not read-time** — the backend sets `Estimate.InvoiceId` inside `AddInvoiceCommandHandler`, right after saving the invoice. No enrichment at read time.
- **`InvoiceId` on Estimate is server-managed** — clients cannot set it through the Estimates API. The proto field exists for reading only; `MapToEstimate` (proto → domain) does not map it. Only the backend writes it during invoice creation.
- **`EstimateId` on Invoice is client-provided** — the client sets it when creating an invoice (Phase 2). The backend stores it as-is, no validation that the estimate exists.
- **Only `InvoiceId`, no `InvoiceNumber`** — avoids stale denormalized data. The client fetches the invoice by ID if it needs the number.
- **Overwrite on re-conversion** — if a second invoice is created from the same estimate, `InvoiceId` on the estimate is overwritten with the new invoice's ID.
- **Soft-delete does NOT clear link** — if the linked invoice is soft-deleted, `InvoiceId` remains on the estimate as a historical fact.
- **Log + swallow on failure** — if updating the estimate fails after the invoice is saved, the error is logged but the invoice creation succeeds. Eventual consistency.

### Flow

```
Client → AddInvoice({ ..., estimateId: "est-123" })

AddInvoiceCommandHandler:
  1. Validate & save invoice (existing flow)
  2. Publish domain events (existing flow)
  3. NEW: if invoice.EstimateId != null:
       try:
         estimatesRepository.SetInvoiceId(accountId, estimateId, invoice.Id, token)
       catch:
         logger.LogWarning("Failed to link estimate {EstimateId} to invoice {InvoiceId}")
  4. Return saved invoice
```

### 1. Estimate Domain Model — Add `InvoiceId`

File: `src/Tofu.Invoices.Domain/Models/Estimate/Estimate.cs`

```csharp
[BsonIgnoreIfNull]
public string? InvoiceId { get; set; }
```

### 2. Proto — Add `invoice_id` to `EstimateObj`

File: `src/Tofu.Invoices.Protos/V1/EstimatesApi.proto`

```proto
message EstimateObj {
    // ... existing fields 1-27 ...
    google.protobuf.StringValue invoice_id = 28;
}
```

### 3. Estimates Mapping — Read-only

File: `src/Tofu.Invoices.Api/Grpc/Mapping/EstimatesServiceMapping.cs`

**Domain → Proto** (`MapToEstimateObj`) — include `InvoiceId`:

```csharp
InvoiceId = estimate.InvoiceId
```

**Proto → Domain** (`MapToEstimate`) — do NOT map `InvoiceId`. The field is server-managed. If a client sends it in an estimate update, it is silently ignored.

### 4. Estimates Repository — `SetInvoiceId`

File: `src/Tofu.Invoices.Domain/Interfaces/IEstimatesRepository.cs`

```csharp
Task SetInvoiceId(string accountId, string estimateId, string invoiceId, CancellationToken token);
```

File: `src/Tofu.Invoices.Infrastructure/Repositories/EstimatesRepository.cs`

Direct MongoDB update (no version check, no `EnrichedEstimate` — this is a server-side side-effect):

```csharp
public async Task SetInvoiceId(string accountId, string estimateId, string invoiceId, CancellationToken token)
{
    var uniqueId = AccountScopedEntity<Estimate>.GetUniqueId(accountId, estimateId);
    var update = Builders<Estimate>.Update.Set(e => e.InvoiceId, invoiceId);

    await Collection.UpdateOneAsync(
        e => e.UniqueId == uniqueId,
        update,
        new UpdateOptions { IsUpsert = false },
        cancellationToken: token);
}
```

`InvoiceId` is **not** included in `DefineInsertOrUpdate`. The field is managed exclusively through `SetInvoiceId` (direct MongoDB update). This avoids a race condition where a client-initiated upsert could overwrite a freshly set `InvoiceId` with `null` (since `MapToEstimate` does not map this field, it is always `null` on the domain model during upsert).

### 5. AddInvoiceCommandHandler — Link After Save

File: `src/Tofu.Invoices.Domain/Commands/AddInvoice/AddInvoiceCommandHandler.cs`

Inject `IEstimatesRepository`. After saving the invoice and publishing events, link to estimate:

```csharp
private readonly IEstimatesRepository _estimatesRepository;

// ... in constructor:
_estimatesRepository = estimatesRepository;

public async Task<Invoice> Handle(AddInvoiceCommand command, CancellationToken token)
{
    // ... existing validation, save, events logic ...

    // Link estimate → invoice (write-time denormalization)
    if (!string.IsNullOrWhiteSpace(enrichedInvoice.Entity.EstimateId))
    {
        await TryLinkEstimateToInvoice(
            enrichedInvoice.Entity.AccountId,
            enrichedInvoice.Entity.EstimateId,
            enrichedInvoice.Entity.Id,
            token);
    }

    return savedInvoice;
}

private async Task TryLinkEstimateToInvoice(
    string accountId, string estimateId, string invoiceId, CancellationToken token)
{
    try
    {
        await _estimatesRepository.SetInvoiceId(accountId, estimateId, invoiceId, token);
        _logger.LogDebug("Linked estimate '{EstimateId}' to invoice '{InvoiceId}'", estimateId, invoiceId);
    }
    catch (Exception ex)
    {
        _logger.LogWarning(ex,
            "Failed to link estimate '{EstimateId}' to invoice '{InvoiceId}'",
            estimateId, invoiceId);
    }
}
```

### 6. Tests

- **Unit test**: `AddInvoiceCommandHandler` — when `EstimateId` is set, calls `SetInvoiceId` on estimates repository.
- **Unit test**: `AddInvoiceCommandHandler` — when `SetInvoiceId` throws, invoice is still returned successfully.
- **Unit test**: `AddInvoiceCommandHandler` — when `EstimateId` is null/empty, does not call `SetInvoiceId`.
- **Unit test**: `EstimatesServiceMapping.MapToEstimate` — does not map `InvoiceId` from proto.
- **Unit test**: `EstimatesServiceMapping.MapToEstimateObj` — maps `InvoiceId` to proto.
- **Functional test**: Create estimate → create invoice with `EstimateId` → fetch estimate → verify `InvoiceId` is set.
- **Functional test**: Create estimate → create invoice with `EstimateId` → create second invoice with same `EstimateId` → verify `InvoiceId` overwritten.

### Files Affected (Phase 3)

| File | Change |
|------|--------|
| `src/Tofu.Invoices.Protos/V1/EstimatesApi.proto` | Add `invoice_id = 28` to `EstimateObj` |
| `src/Tofu.Invoices.Domain/Models/Estimate/Estimate.cs` | Add `InvoiceId` property |
| `src/Tofu.Invoices.Domain/Interfaces/IEstimatesRepository.cs` | Add `SetInvoiceId` method |
| `src/Tofu.Invoices.Domain/Commands/AddInvoice/AddInvoiceCommandHandler.cs` | Inject `IEstimatesRepository`, add link logic after save |
| `src/Tofu.Invoices.Infrastructure/Repositories/EstimatesRepository.cs` | Implement `SetInvoiceId` (direct MongoDB update) |
| `src/Tofu.Invoices.Api/Grpc/Mapping/EstimatesServiceMapping.cs` | Map `InvoiceId` domain → proto only |
| `tests/Tofu.Invoices.UnitTests/` | Handler, mapping, and repo tests |
| `tests/Tofu.Invoices.FunctionalTests/` | End-to-end link test |

### Dependencies

- **Phase 2 must be complete** — `Invoice.EstimateId` must exist in domain model, proto, and persistence before the handler can read it.

### Edge Cases

- **Estimate doesn't exist** — `SetInvoiceId` updates 0 documents (no match on `UniqueId`). No error, no side effect. Logged at debug level.
- **Re-conversion** — second invoice with same `EstimateId` overwrites `InvoiceId` on the estimate. Both invoices keep their `EstimateId` pointing to the same estimate.
- **Invoice deleted** — `InvoiceId` stays on the estimate. The client can check if the linked invoice still exists by fetching it.
- **Estimate update from client** — safe by design. `MapToEstimate` does not map `InvoiceId`, and `DefineInsertOrUpdate` does not include `InvoiceId`. The field is managed exclusively by `SetInvoiceId` (direct MongoDB update), so client-initiated upserts never touch it.

## Files Affected (Phase 1)

| File | Change |
|------|--------|
| `Src/Invoices.Core/Models/Invoice.cs` | Add `EstimateId` property |
| `Src/Invoices.Api/Models/InvoiceDto.cs` | Add `EstimateId` property |
| `Src/Invoices.Api/Models/Invoices/Mapping.cs` | Map `EstimateId` in both directions |
| `Src/Tofu.Invoices/Mapping/Mapper.cs` | Map `EstimateId` in both directions (after proto update) |
