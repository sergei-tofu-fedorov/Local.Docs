Notifications - Domain Model
============================

Core Entities
-------------

1. Notification
- `Id` (int, auto-increment)
- `TargetAccountId`
- `TargetMasterUserId` (optional)
- `TargetProductKey` (optional)
- `Type` (NotificationType enum, stored as string in DB)
- `Payload` (JSON)
- `CreatedAt`
- `ReadAt` (null = unread)
- `SchemaVersion`
- `Source` (NotificationSource enum, stored as string in DB)

2. NotificationEvent
- `TargetAccountId`
- `TargetMasterUserId` (optional)
- `TargetProductKey` (optional)
- `Type` (NotificationType enum)
- `Payload`
- `OccurredAt`
- `Source` (NotificationSource enum)

3. NotificationDefinition (Planned)
- `Type`
- `DefaultChannels` (InApp, Push, Email)
- `RequiresLocalization` (bool)
- `SchemaVersion`
- `IdempotencyKey` (optional template for de-duplication)

> **Status**: Not yet implemented. Channel routing is currently hardcoded.

Enums
-----

### NotificationType (camelCase in API)

```csharp
public enum NotificationType
{
    Unknown,              // "unknown"
    FirstPaymentReceived, // "firstPaymentReceived"
    PspOnboardingCompleted // "pspOnboardingCompleted"
}
```

### NotificationSource

```csharp
public enum NotificationSource
{
    Unknown,   // "unknown"
    Payments,  // "payments"
    Stripe     // "stripe"
}
```

Event Types
-----------
- `firstPaymentReceived` - First successful payment for the account. Source: `Payments`.
- `pspOnboardingCompleted` - PSP (Stripe) onboarding completed successfully. Source: `Stripe`.

Payload Structures
------------------

Payload is stored as a JSON string. Each notification type has its own payload schema.

### FirstPaymentReceivedPayload

```csharp
public record FirstPaymentReceivedPayload
{
    public required decimal Amount { get; set; }
    public required string CurrencySign { get; set; }
    public required string? ClientName { get; set; }
    public required string? DocumentNumber { get; set; }
}
```

**Example JSON (stored as string):**
```json
{"amount":120.50,"currencySign":"$","clientName":"Emily Johnson","documentNumber":"1001"}
```

Routing Rules
-------------
- Always write the in-app notification record.
- Apply product gating and user preferences per channel.
- Map type -> template data for each channel.
- Email delivery should reuse the stored notification record as the source of
  truth for content selection and auditing.
- Ordering guarantee per account is based on monotonically increasing
  `notification_id`.
- Scope rule:
  - `TargetMasterUserId` is null -> account-wide notification (visible to all users).
  - `TargetMasterUserId` set -> user-scoped notification (visible only to that user).
  - `TargetProductKey` (optional) scopes notifications to a product/app.
  - Target fields use the `Target*` prefix to make recipient scope explicit.

Delivery Channels
-----------------

**Currently Implemented:**
- InApp: Stored record in PostgreSQL + REST API for retrieval.

**Planned:**
- Push: Integration with existing `IPushService` + template services.
- Email: Integration with `IEmailService` + notification email templates.

Idempotency (Planned)
---------------------

> **Status**: Not yet implemented. Currently, duplicates are prevented at the
> dispatcher level by checking existing notifications before inserting.

Future implementation will use deterministic idempotency keys per notification type:

| Type | Template | Strategy |
|------|----------|----------|
| `firstPaymentReceived` | `{type}:{accountId}` | Once per account lifetime |
| `pspOnboardingCompleted` | `{type}:{accountId}` | Once per account lifetime |
