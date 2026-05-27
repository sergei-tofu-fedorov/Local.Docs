# Email Rate Limit

## Overview

Rolling 24-hour email sending limit per account, enforced in `EmailService.Send()` only when `ActorType == User`.
Limits differ by platform: web clients have a lower limit than mobile (iOS/Android).

Callers pass `EmailSendingContext(ActorType, Platform)` — API controllers use `ActorType.User`, Worker operation handlers use `ActorType.System` (skips rate limit).

Emails with `EmailStatusType.Error` (4) are excluded from the count.

## Limits

| Platform enum | Default Limit |
|---------------|---------------|
| `Web` | 20 |
| `IOS` | 100 |
| `Android` | 100 |
| `Unknown` / other | 100 (mobile limit) |

Platform detection uses the `Platform` enum (`Invoices.Core.Models.Platform`), passed via `EmailSendingContext`.

## Behaviour

- `Send()` checks rate limit only when `context.ActorType == ActorType.User`.
- Counts non-error emails sent in the last 24 hours for the account from the `emailStatus` MongoDB collection.
- If `count >= limit` the service throws `EmailRateLimitExceededException`.
- The middleware maps this exception to HTTP 429 (Too Many Requests).
- `SendNotification()` and `OnlineInvoiceSend()` are not rate-limited (no `EmailSendingContext`).

## Configuration

Both API and Worker read from `Services:EmailRateLimit`:

```json
"Services": {
  "EmailRateLimit": {
    "WebLimit": 20,
    "MobileLimit": 100
  }
}
```

Options class: `Tofu.Email.Service.EmailRateLimitOptions`

Registered via the Options pattern in:
- `Invoices.Api/DI/CommonConfiguration.cs`
- `Invoices.Worker/DI/WorkerCommonConfiguration.cs`

## Files

| File | Purpose |
|------|---------|
| `Invoices.Common/Models/Email/EmailSendingContext.cs` | `record(ActorType, Platform)` passed to `Send()` |
| `Tofu.Email/Service/EmailRateLimitOptions.cs` | Configuration (WebLimit, MobileLimit) |
| `Tofu.Email/Service/EmailService.cs` | `EnforceEmailRateLimit()` when `ActorType.User` |
| `Invoices.Core/Exceptions/EmailRateLimitExceededException.cs` | Exception thrown at limit |
| `Invoices.Core/Repositories/IEmailStatusRepository.cs` | `CountSentEmails(accountId, since, ct)` |
| `Invoices.Implementation.MongoDb/Repositories/EmailStatusRepository.cs` | MongoDB query implementation |
| `Invoices.Api/Middleware/ApiExceptionHandlingMiddleware.cs` | Maps to HTTP 429 |
| `Invoices.Api/Controllers/V3/EmailController.cs` | Re-throws before generic catch |
| `Invoices.Api/Controllers/V1/EmailController.cs` | Re-throws before generic catch |

## MongoDB Index

Compound index on the `emailStatus` collection for the rate-limit query:

| Index | Fields | Purpose |
|-------|--------|---------|
| `ix_emailstatus.accountid_date` | `{ AccountId: 1, Date: -1 }` | Filter by account + date range |

Defined in `MongoDbContext.Configure()`.

## Query Logic

```csharp
// EmailStatusRepository.CountSentEmails
var since = DateTime.UtcNow.AddHours(-24);
Collection.CountDocumentsAsync(
    r => r.AccountId == accountId
         && r.Date >= since
         && r.Type != EmailStatusType.Error);
```

## Tests

Unit tests in `Tofu.Email.UnitTests/EmailServiceTests.cs`:

| Test | Scenario |
|------|----------|
| `Send_ThrowsEmailRateLimitExceeded_WhenLimitReached` | Theory: (Web, 20) and (IOS, 100), throws |
| `Send_Succeeds_WhenUnderLimit` | Platform.Web, count = 19, succeeds |

Integration test in `Invoices.IntegrationTests/Tests/Controllers/EmailsControllerTests.cs`:

| Test | Scenario |
|------|----------|
| `SendAsync_RateLimitExceeded_Returns429` | Pre-fill emailStatus to limit, next send returns HTTP 429 |
