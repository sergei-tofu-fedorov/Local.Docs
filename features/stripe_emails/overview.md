Stripe Payment Status Emails & Push Migration
===============================================

**Task**: [WEB-914](https://app.clickup.com/t/24553599/WEB-914) (subtask of [WEB-1001](https://app.clickup.com/t/869c16ryv))
**Initiative**: [WEB-892](https://app.clickup.com/t/869bt3wvd) — Payments: Stripe emails (duplicate our pushes as emails)

Overview
--------

Add email notifications for Stripe payment account status changes and payment events. Both new emails and existing push notifications are delivered via the generic Hangfire delivery jobs (`EmailDeliveryJob`, `PushDeliveryJob`) from the FS-867 notification infrastructure — giving retries, correlation IDs, and async delivery.

Emails
------

| # | Email | Trigger | Template Key | SendGrid ID | Brevo ID | Params |
|---|-------|---------|-------------|-------------|----------|--------|
| 1 | First Payment | First payment received via Stripe | `first_payment` | `d-e984966e358b48e3aa837e185f5cdc0c` | #29 | `invoiceUrl`, `amount`, `date` |
| 2 | Action Required | APT status -> InformationIsRequired | `action_required` | `d-c2d76f5888134694ac0887b87ce0b5df` | #31 | none |
| 3 | Verification Complete | APT status -> Connected | `verification_complete` | `d-9bc8c6ad25a8467f9ea6e2985b3b5043` | #30 | none |
| 4 | Finish Setting Up | Delayed nudge while APT InProgress | `finish_setting_up` | `d-74144e844af946cb9f1b13378ed9714c` | #28 | none |

Figma: [Stripe connection flow](https://www.figma.com/design/764v2gvLfnou3Rp45zbdil/%F0%9F%92%B3-Stripe-connection-flow)

Recipient: account owner (merchant), NOT the end-client. Resolved via `IAccountEmailResolver.FindOwnerEmail()` — checks account contacts email first, falls back to master user's tofu platform link email.

Architecture
------------

Both email and push notifications are delivered via Hangfire delivery jobs. The calling services build template params and enqueue jobs — actual sending happens asynchronously in the Worker.

```
Stripe webhook
  -> StripeEventHookMapper
    -> PaymentEventsService.HandleEvent()
      -> PaymentsService.FinishAuthenticatePaymentType()
        -> SafetySendPushAndAnalyticsByStatus()
          -> IPaymentsNotificationService  -- enqueues PushDeliveryJob
          -> IPaymentsEmailService         -- enqueues EmailDeliveryJob

PaymentIntentsService.ProcessPaymentEntity()
  -> isFirstPayment?
    -> IPaymentsNotificationService        -- enqueues PushDeliveryJob
    -> IPaymentsEmailService               -- enqueues EmailDeliveryJob

PaymentAccountStatusInProgressOperationHandler.Handle()
  -> first attempt (count == 0)?
    -> IPaymentsEmailService               -- enqueues EmailDeliveryJob
  -> IPaymentsNotificationService          -- enqueues PushDeliveryJob

                    ↓ Hangfire (Worker)

EmailDeliveryJob
  -> IAccountEmailResolver.FindOwnerEmail()
  -> IEmailFactory: SendGrid → Sendinblue fallback
  -> resolve templateKey → templateId from per-provider config

PushDeliveryJob
  -> IPushService.SendWithParams()
  -> optional analytics event logging on success
```

Trigger Points
--------------

### 1. First Payment

**Where**: `PaymentIntentsService.ProcessPaymentEntity()`, after `isFirstPayment` check (invoice and payment request paths).

**Email data**: `invoiceUrl` (from `IWebLinkService.ShortUrlForInvoice()`, null for payment requests), `amount` (formatted with currency sign), `date` (`DateTimeOffset.UtcNow`).

**Push data**: localized message with client name, amount, invoice number. Template key `InvoicesPayment`, event type `firstPayment`.

### 2. Action Required

**Where**: `PaymentsService.SafetySendPushAndAnalyticsByStatus()`, when status changed to `InformationIsRequired`.

**Email data**: none (template-only).

**Push data**: localized message with connection error details from `PaymentErrorMapper`. Event type `providerAlert`.

### 3. Verification Complete

**Where**: `PaymentsService.SafetySendPushAndAnalyticsByStatus()`, when status changed to `Connected`.

**Email data**: none (template-only).

**Push data**: localized status message. Event type `verificationCompleted`.

### 4. Finish Setting Up

**Where**: `PaymentAccountStatusInProgressOperationHandler.Handle()`, first notification attempt only (parsed `notificationsNumber` is 0 or unparseable).

**Email data**: none (template-only). Sent only on first attempt.

**Push data**: localized unfinished status message. Sent on every attempt (up to 4 retries).

Implementation
--------------

### Email delivery via `EmailDeliveryJob`

`PaymentsEmailService` enqueues `EmailDeliveryJob` with `EmailDeliveryParams` (accountId, templateKey, templateParams, correlationId). The service is a thin layer that builds params and enqueues.

```
class PaymentsEmailService : IPaymentsEmailService
    inject IBackgroundJobClient

    TrySendFirstPaymentEmail(accountId, invoiceUrl, amount, date, ct):
        Enqueue("first_payment", { invoiceUrl, amount, date = date.ToString(...) })

    TrySendActionRequiredEmail(accountId, ct):
        Enqueue("action_required", {})

    ...

    private Enqueue(templateKey, data):
        _jobClient.Enqueue<EmailDeliveryJob>(j => j.Send(
            new EmailDeliveryParams { AccountId, TemplateKey, TemplateParams, CorrelationId }))
```

`EmailDeliveryJob` resolves recipient email via `INotificationEmailSender` (which uses `IAccountEmailResolver`), then tries SendGrid → Sendinblue via `IEmailFactory`. Template IDs resolved from per-provider `NotificationTemplateIds` dictionary.

### Push delivery via `PushDeliveryJob`

`PaymentsNotificationService` builds localized push message templates inline (localization, APT lookup, error mapping must happen at call time with current data), then enqueues `PushDeliveryJob`.

```
class PaymentsNotificationService : IPaymentsNotificationService
    inject IBackgroundJobClient, IRegionalLocalizationFactory, ...

    TrySendPushByStatus(accountId, authenticatedPaymentType, ct):
        ... build templateProps (localization, error mapping — same as before) ...
        _jobClient.Enqueue<PushDeliveryJob>(j => j.Send(
            new PushDeliveryParams {
                AccountId, ProductKey, TemplateKey = "InvoicesPayment",
                TemplateProps = templateProps,
                CorrelationId = Guid.NewGuid(),
                AnalyticsEvent = "payment_account_status_push"
            }))
```

Return type changes from `Task<bool>` to `Task` — analytics logging moves into `PushDeliveryJob` via optional `AnalyticsEvent`/`AnalyticsParams` fields on `PushDeliveryParams`.

### Config

Template IDs are in the shared `NotificationTemplateIds` dictionary (per provider):

```json
{
  "SendGrid": {
    "NotificationTemplateIds": {
      "first_payment": "d-e984966e358b48e3aa837e185f5cdc0c",
      "action_required": "d-c2d76f5888134694ac0887b87ce0b5df",
      "verification_complete": "d-9bc8c6ad25a8467f9ea6e2985b3b5043",
      "finish_setting_up": "d-74144e844af946cb9f1b13378ed9714c"
    }
  },
  "Sendinblue": {
    "NotificationTemplateIds": {
      "first_payment": "29",
      "action_required": "31",
      "verification_complete": "30",
      "finish_setting_up": "28"
    }
  }
}
```

### Shared email resolution

`IAccountEmailResolver` extracted from `EmailService.GetEmail()` into a reusable service. Used by both `NotificationEmailSender` (inside `EmailDeliveryJob`) and `EmailService`. Priority: account contacts email → master user tofu platform link email.

`NotificationEmailSender` refactored to use `IAccountEmailResolver` instead of duplicating resolution logic with `IMasterUserRepository` + `IAccountsRepository`.

### `EmailDeliveryJob` dual-provider support

Refactored from SendGrid-only (`IEmailGateway`) to dual-provider fallback via `IEmailFactory`:

```
EmailDeliveryJob.Send(params):
    email = _emailSender.ResolveEmail(accountId, ct)
    for each provider in [SendGrid, Sendinblue]:
        templateId = provider.NotificationTemplateIds[params.TemplateKey]
        if templateId missing: skip
        gateway = _emailFactory.GetGatewayAndTemplateServices(provider)
        try send → if success return
        log warning, try next provider
```

### `PushDeliveryJob` analytics support

Extended with optional analytics event logging on successful send:

```
PushDeliveryJob.Send(params):
    await _pushService.SendWithParams(...)
    if params.AnalyticsEvent is not null:
        log analytics event
```

`PushDeliveryParams` extended with `AnalyticsEvent?` and `AnalyticsParams?`.

### `IPaymentsNotificationService` interface change

All 5 methods change from `Task<bool>` to `Task`:
- `TrySendPushByStatus`
- `TrySendPushByPayment`
- `TrySendPushByPayout`
- `TrySendPushByBalance`
- `SendPushByStatusByUnfinishedStatus`

Callers (`PaymentsService`, `PaymentIntentsService`, `PaymentAccountStatusInProgressOperationHandler`) remove `var isPushSent = await ...` checks and conditional analytics blocks.

Design Decisions
----------------

1. **Hangfire delivery jobs** for both email and push — retries, correlation IDs, async delivery. Reuses generic infrastructure from FS-867.

2. **SendGrid + Brevo fallback** in `EmailDeliveryJob` — tries SendGrid first, falls back to Sendinblue/Brevo. Template IDs per provider in `NotificationTemplateIds` dictionary.

3. **Shared email resolution** via `IAccountEmailResolver` — single implementation used by `NotificationEmailSender`, `EmailService`, and any future email sender.

4. **Analytics in delivery jobs** — push analytics move from caller-side conditional logging into `PushDeliveryJob`. Callers no longer need the send result.

5. **Message building stays inline** — push notification localization, APT lookup, and error mapping happen at enqueue time (not in the job). The job only handles the network send. This ensures messages reflect current state.

6. **Finish Setting Up** email sent only on first delayed notification attempt — avoids spamming on retries.

File Summary
------------

| Action | File |
|--------|------|
| Refactor | `Notifications.Application/Hangfire/NotificationEmailSender.cs` — use `IAccountEmailResolver` |
| Refactor | `Notifications.Application/Hangfire/EmailDeliveryJob.cs` — dual-provider via `IEmailFactory` |
| Extend | `Notifications.Application/Hangfire/PushDeliveryJob.cs` — add analytics |
| Extend | `Notifications.Contracts/.../PushDeliveryParams.cs` — add analytics fields |
| Simplify | `Invoices.Payments/PaymentsEmailService.cs` — enqueue job instead of direct send |
| New | `Invoices.Common/Services/Payments/IPaymentsEmailService.cs` — interface |
| New | `Tofu.Email/Service/IAccountEmailResolver.cs` — shared email resolution |
| New | `Tofu.Email/Service/AccountEmailResolver.cs` — implementation |
| Refactor | `Invoices.Payments/PaymentsNotificationService.cs` — enqueue job, return `Task` |
| Refactor | `Invoices.Common/.../IPaymentsNotificationService.cs` — `Task<bool>` → `Task` |
| Refactor | `Invoices.Payments/PaymentsService.cs` — remove push result checks |
| Refactor | `Invoices.Payments/PaymentIntentsService.cs` — remove push result checks |
| Refactor | `Invoices.Worker/.../PaymentAccountStatusInProgressOperationHandler.cs` — same |
| Refactor | `Tofu.Email/Service/EmailService.cs` — use `IAccountEmailResolver` |
| Refactor | `Tofu.Email/ServiceCollectionExtensions.cs` — register `IAccountEmailResolver` |
| Config | `Invoices.Api/appsettings.json` — payment template keys in `NotificationTemplateIds` |
| Config | `Invoices.Worker/appsettings.json` — same |
| Update | Test files for constructor/interface changes |
