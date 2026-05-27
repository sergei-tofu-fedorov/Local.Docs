Tofu.Invoices Activity Events
==============================

This document lists all activity/analytics events triggered for invoices and estimates in the Tofu.Invoices solution.

Event Architecture Overview
---------------------------

The system uses a dual-layer event architecture:
- **Domain Events**: Internal business logic events raised within the domain layer
- **Persisted Events**: Stored in database for audit/timeline purposes (converted from domain events)

### Domain Event Hierarchy

Intermediate base classes carry shared per-entity properties (currently `DocNumber`):

```
DomainEvent / DomainEvent<T>
├── InvoiceDomainEvent / InvoiceDomainEvent<T>   → DocNumber
│   ├── InvoiceCreatedDomainEvent
│   ├── InvoiceStatusChangeDomainEvent
│   ├── InvoiceMailStatusChangeDomainEvent
│   ├── InvoicePaymentReceivedDomainEvent
│   └── InvoiceSentMethodChangeDomainEvent
└── EstimateDomainEvent / EstimateDomainEvent<T>  → DocNumber
    ├── EstimateCreatedDomainEvent
    ├── EstimateStatusChangeDomainEvent
    └── EstimateMailStatusChangeDomainEvent
```

`DocNumber` is set by `EnrichedInvoice` / `EnrichedEstimate` at each event-creation site and flows through to the persisted event payload via the factory.

Estimate Events
---------------

### EstimateCreatedDomainEvent
- **Triggered when**: A new estimate is created via `AddEstimateCommand`
- **Persisted as**: `StatusChanged` event type
- **Payload**: Status set to the initial status (typically Draft), `DocNumber` from estimate

### EstimateStatusChangeDomainEvent
- **Triggered when**: Estimate status changes between valid states
- **Valid transitions**:
  - Draft -> Sent, Approved, Canceled
  - Sent -> Draft, Approved, Canceled
  - Approved -> Draft, Sent, Done
  - Canceled -> Draft, Sent
- **Persisted as**: `StatusChanged` event type
- **Payload**: `StatusChangedPayload` containing:
  - `From`: Previous status
  - `To`: New status
  - `SentMethod`: Email/Manual (when transitioning to Sent)
  - `DocNumber`: Estimate document number (nullable)

### EstimateMailStatusChangeDomainEvent
- **Triggered when**: Email delivery status changes for an estimate
- **Status transitions**: Pending -> Sent -> Delivered/Opened/Error
- **Persisted as**: `EmailStatusChanged` event type
- **Payload**: `EmailStatusChangedPayload` containing:
  - `From`: Previous email status
  - `To`: New email status
  - `Recipient`: Email recipient address
  - `DocNumber`: Estimate document number (nullable)

Invoice Events
--------------

### InvoiceCreatedDomainEvent
- **Triggered when**: A new invoice is created via `AddInvoiceCommand`
- **Persisted as**: `StatusChanged` event type
- **Payload**: Status set to initial status (typically NotPaid), `DocNumber` from invoice

### InvoiceStatusChangeDomainEvent
- **Triggered when**: Invoice status changes between valid states
- **Valid transitions**:
  - NotPaid -> Paid, PaidByCard, Canceled, Refunded
  - Other transitions as defined by business rules
- **Persisted as**: `StatusChanged` event type
- **Payload**: `InvoiceStatusChangedPayload` containing:
  - `From`: Previous status
  - `To`: New status
  - `Provider`: Payment provider (when status changes to Paid)
  - `DocNumber`: Invoice document number (nullable)

### InvoiceMailStatusChangeDomainEvent
- **Triggered when**: Email delivery status changes for an invoice
- **Status transitions**: Pending -> Sent -> Delivered/Opened/Error
- **Persisted as**: `EmailStatusChanged` event type
- **Payload**: `InvoiceEmailStatusChangedPayload` containing:
  - `From`: Previous email status
  - `To`: New email status
  - `Recipient`: Email recipient address
  - `DocNumber`: Invoice document number (nullable)

### InvoicePaymentReceivedDomainEvent
- **Triggered when**:
  - Status changes to `PaidByCard` (full payment via PSP)
  - Payment amount in `ReceivedPayments` changes by more than 1 unit
- **Persisted as**: `PaymentReceived` event type
- **Payload**: `InvoicePaymentReceivedPayload` containing:
  - `From`: Previous payment amount
  - `To`: New payment amount
  - `ByPsp`: Whether payment was via Payment Service Provider
  - `Provider`: Payment provider name
  - `CurrencyCode`: Currency of the payment
  - `DocNumber`: Invoice document number (nullable)

### InvoiceSentMethodChangeDomainEvent
- **Triggered when**: `Invoice.SentMethod` changes via `PUT /Invoices` (mark-as-sent flow). Not raised for the silent `null → Email` promotion in `SetMailStatus` — the existing `InvoiceMailStatusChangeDomainEvent` already covers that transition.
- **Values**: `null | Email | Manual`
- **Persisted as**: `SentMethodChanged` event type
- **Payload**: `InvoiceSentMethodChangedPayload` containing:
  - `From`: Previous sent-method (nullable)
  - `To`: New sent-method (nullable)
  - `DocNumber`: Invoice document number (nullable)

Push Notification Events
------------------------

### OverdueInvoice
- **Triggered when**: Background worker job `SendPastDueDatePushJob` sends overdue invoice notifications
- **Type**: Push notification to external analytics system
- **Properties**:
  - `accountId`: Account identifier
  - `environment`: Runtime environment
  - `push_id`: "overdue_invoice"
  - `type`: "automatic"

Persisted Event Types
---------------------

### Estimate Event Types (stored in database)
| Event Type | Value | Description |
|------------|-------|-------------|
| Unknown | 0 | Unknown event type |
| StatusChanged | 1 | Status transition event |
| EmailStatusChanged | 2 | Email delivery status change |

### Invoice Event Types (stored in database)
| Event Type | Value | Description |
|------------|-------|-------------|
| Unknown | 0 | Unknown event type |
| StatusChanged | 1 | Status transition event |
| EmailStatusChanged | 2 | Email delivery status change |
| PaymentReceived | 3 | Payment received event |
| CreatedFromEstimate | 4 | Invoice created from an estimate |
| CreatedFromJob | 5 | Invoice created from a job |
| Created | 6 | Invoice created standalone |
| SentMethodChanged | 7 | `SentMethod` changed (manual mark-as-sent / undo) |

Actor Types
-----------

Events capture who triggered them via `ActorType`:

| Actor Type | Value | Description |
|------------|-------|-------------|
| Unknown | 0 | Unknown actor (default for missing user ID) |
| System | 1 | System-initiated actions |
| User | 2 | User-initiated actions |
| External | 3 | External service-initiated actions |
