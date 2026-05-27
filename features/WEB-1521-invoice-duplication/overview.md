# WEB-1521 — Invoice Duplication — Backend Implementation Plan

[ClickUp task](https://app.clickup.com/t/WEB-1521).

## Summary

Duplicate-invoice flow rides existing `PUT /api/invoices`. New optional field `OriginalInvoiceId` on the payload triggers a new timeline event `InvoiceCreatedFromInvoice`. Field is persisted on the invoice and ships with every sync. No new endpoint, no schema migration.

Tooltip for the duplicate UX reuses existing `POST /api/onboarding/dismiss-modal` with a new `ModalType.InvoiceDuplicateTooltip` value.

## What changes

**Contract (gateway):**
- `InvoiceDto.OriginalInvoiceId: string?` — new optional field next to `EstimateId`.
- `InvoiceSourceDto` — unchanged. Duplication is field-driven, not enum-driven.
- New `EventTypeDto.InvoiceCreatedFromInvoice` (wire: `"invoiceCreatedFromInvoice"`).

**Domain (gateway + service):**
- `Invoice.OriginalInvoiceId: string?` on both `Invoices.Core.Models.Invoice` and `Tofu.Invoices.Domain.Models.Invoices.Invoice`.
- New `EventType.InvoiceCreatedFromInvoice` (gateway) + `InvoiceEventType.CreatedFromInvoice` (service).
- New `InvoiceCreatedFromInvoiceDomainEvent { OriginalInvoiceId, OriginalInvoiceNumber }` + matching `InvoiceCreatedFromInvoicePayload`.

**Proto (Tofu.Invoices.Protos):**
- `InvoiceObj.original_invoice_id` (field 37).
- `IET_CREATED_FROM_INVOICE = 7` in `InvoiceEventType`.
- `InvoiceSource` proto enum — unchanged.

**Onboarding (gateway only):**
- `ModalType.InvoiceDuplicateTooltip = 2` + `ModalTypeDto` mirror + `OnboardingMapping` arms.

## Trigger logic

In `Tofu.Invoices.Domain.Models.Invoices.EnrichedInvoice.Create`:

```csharp
if (!string.IsNullOrWhiteSpace(invoice.OriginalInvoiceId))
{
    // Register InvoiceCreatedFromInvoiceDomainEvent, skip legacy Source resolution.
    return enrichedInvoice;
}
// existing switch over ResolveSource(source, jobId, estimateId) ...
```

- Old clients never set `OriginalInvoiceId` → legacy events emitted as before.
- Duplication wins over carried-over `JobId` / `EstimateId` on the payload.

## Activity log copy

| Aspect | Value |
|---|---|
| Event | `InvoiceCreatedFromInvoice` |
| Payload | `{ docNumber, originalInvoiceId, originalInvoiceNumber }` |
| Render | `"You created this invoice from Invoice #{originalInvoiceNumber}"` |
| Link | `#{originalInvoiceNumber}` → `/invoices/{originalInvoiceId}` |
| Fallback (`originalInvoiceNumber` is null) | `"You created this invoice from another invoice"` — text-only, no link |
| Fallback (`originalInvoiceId` points to a deleted/inaccessible invoice) | Link still rendered; target route handles the 404 with the standard "invoice not found" view |

Final wording is owned by product; this section pins the contract between backend payload and frontend rendering. Changes to the copy do not require backend updates.

## Files changed

**Gateway (`Invoices.Backend`):**
| File | Change |
|---|---|
| `Invoices.Api/Models/InvoiceDto.cs` | + `OriginalInvoiceId` |
| `Invoices.Core/Models/Invoice.cs` | + `OriginalInvoiceId` |
| `Invoices.Api/Models/Invoices/Mapping.cs` | propagate `OriginalInvoiceId` DTO ↔ domain |
| `Invoices.Core/Models/Timeline/EventType.cs` | + `InvoiceCreatedFromInvoice` + entry in `EventTypesByEntityType[Invoice]` |
| `Invoices.Api/Models/Timeline/EventTypeDto.cs` | + `InvoiceCreatedFromInvoice` (append at end) |
| `Invoices.Api/Models/Timeline/Mapping.cs` | + arm in `Map(EventType)` switch |
| `Tofu.Invoices/Mapping/Mapper.cs` | + `IetCreatedFromInvoice → InvoiceCreatedFromInvoice` arm; propagate `OriginalInvoiceId` proto ↔ domain |
| `Invoices.Core/Models/ModalType.cs` | + `InvoiceDuplicateTooltip = 2` |
| `Invoices.Api/Dto/ModalTypeDto.cs` | mirror |
| `Invoices.Api/Models/OnboardingMapping.cs` | + bidirectional arm |

**Service (`Tofu.Invoices.Backend`):**
| File | Change |
|---|---|
| `src/Tofu.Invoices.Protos/V1/InvoicesApi.proto` | + `original_invoice_id`, + `IET_CREATED_FROM_INVOICE` |
| `src/Tofu.Invoices.Domain/Models/Invoices/Invoice.cs` | + `OriginalInvoiceId` |
| `src/Tofu.Invoices.Domain/Models/Invoices/EnrichedInvoice.cs` | early return on `OriginalInvoiceId` in `Create` |
| `src/Tofu.Invoices.Domain/Models/Events/DomainEvent.cs` | + `InvoiceCreatedFromInvoiceDomainEvent` |
| `src/Tofu.Invoices.Domain/Models/Events/InvoiceEvent.cs` | + `InvoiceEventType.CreatedFromInvoice`, + `InvoiceCreatedFromInvoicePayload` |
| `src/Tofu.Invoices.Domain/Events/InvoiceEventsFactory.cs` | + switch arm + builder overload |
| `src/Tofu.Invoices.Domain/Commands/AddInvoice/AddInvoiceCommandHandler.cs` | account-scoped lookup of original invoice number; forwarded to `EnrichedInvoice.Create` |
| `src/Tofu.Invoices.Api/Grpc/Mapping/InvoicesServiceMapping.cs` | propagate `OriginalInvoiceId`; + `IetCreatedFromInvoice` arm |

## Execution order

1. Service: proto + domain + handler. CI publishes new `Tofu.Invoices.Protos` NuGet preview.
2. Gateway: bumps Protos package, DTO + mappings + Timeline.
3. Onboarding flag: independent, lands in parallel.

## Tests

**Service (`Tofu.Invoices.UnitTests`):**
- `EnrichedInvoiceTests`: `OriginalInvoiceId` set / null / whitespace / null number / JobId co-present → expected event and payload.
- `InvoiceEventsFactoryTests`: domain event → `InvoiceEvent` with correct `InvoiceEventType.CreatedFromInvoice` and payload.
- `AddInvoiceCommandHandlerTests`: original-invoice lookup happens / skipped on null+whitespace / graceful when not found.

**Service (`Tofu.Invoices.FunctionalTests`):**
- `AddInvoice_FromInvoice_Tests`: end-to-end. Original invoice untouched. Cross-account `OriginalInvoiceId` stored as-is (best-effort, matches `EstimateId` / `JobId`).

**Gateway (`Invoices.Tests`):**
- `InvoiceDuplicationMappingTests`: round-trip `OriginalInvoiceId` DTO ↔ domain; `EventType.InvoiceCreatedFromInvoice.MapToDto()` → `EventTypeDto.InvoiceCreatedFromInvoice` (regression-pin for the timeline mapping); `ModalTypeDto.InvoiceDuplicateTooltip.ToDomain()`.

**Gateway (`Invoices.IntegrationTests`):**
- `PutInvoice_DuplicateTests`: `PUT` with `originalInvoiceId` → new event in timeline; inline catalog items round-trip; payload without `originalInvoiceId` keeps legacy `invoiceCreated` behaviour.
- `Onboarding/DismissModalTests`: dismissal counter for `InvoiceDuplicateTooltip` increments independently of other modal types.
