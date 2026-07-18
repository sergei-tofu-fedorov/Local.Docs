# BFF (Invoices.Backend) — server-emitted Amplitude events catalog

- Send path: `WithContext(Context(accountId, productKey))` then `Log(Event)` — `Src/Invoices.Analytics/Analytics.cs:43` (WithContext), `:32` (Log buffers `(context, event)`). Interface: `Src/Invoices.Core/Analytics/IAnalytics.cs`. On dispose → `FlushAll` (`Analytics.cs:62`) offloads; `FlushAll` static (`:78`) groups by AccountId, resolves environment + user_id, then calls `AnalyticsService.Send(context, event, userId, environment)` (`Src/Invoices.Analytics/AnalyticsService.cs:20`), which POSTs to internal collector `/api/events` with `{ productKey, eventType = event.Type, payload { occuredAt, userId, accountId, properties, userProperties } }`.
- Event base: `Src/Invoices.Core/Analytics/Events/Event.cs` — `abstract string Type` (the Amplitude eventType/name), `required DateTime OccuredAt`, `abstract Dictionary<string,string?> GetEventProps()`, `virtual Dictionary<string,string> GetUserProps() => new()`. All concrete events live in `Src/Invoices.Common/Analytics/Events/`.
- Context = (AccountId, ProductKey) only — the acting/authenticated user is dropped; user_id is reconstructed server-side in `Analytics.ResolveUserId` (`Analytics.cs:133`) from the account owner (`MasterUserRepository.FindOwnerForAccountId`) per the event's ProductKey. Every event also gets an auto-injected prop `environment` = `accountsRepository.GetAsync(accountId).GetEnvironment()` (`Analytics.cs:95`, added in `AnalyticsService.Send:23`), plus payload-level `userId` and `accountId`.
- **No event overrides `GetUserProps()`** — every event ships an empty `userProperties` object. (Only override of the virtual is the base itself, `Event.cs:8`.)
- `PushEvent` (`Events/PushEvent.cs:5`) is an abstract base: `Type => "Push sent"` for ALL push subclasses (they are differentiated only by the `push_id` prop, not by eventType), `PushType => "automatic"`, abstract `PushId`. `push_id` values come from `Src/Invoices.Common/Consts/Consts.cs` `EventPushTypes` (lines 13–25).

## Events

### `Invite Sent` (class `InviteSent`, `Events/InviteSent.cs:5`)
- Fired at: `Src/Invoices.Api/Controllers/InvitationsController.cs:250` (in `LogSmsInviteSent`, called from `CreateSmsInvitation` at `:104`); productKey: `ProductKey` from BaseController/middleware (WithContext at `:235`). Fired only when `invitation.RemindersSent == 0`.
- Props (with backend calculation):
  | prop | how BFF computes it |
  |------|---------------------|
  | `channel` | literal `"sms"` (`:252`) |
  | `tenant_id` | `context` — `AccountId` from BaseController middleware (`:253`) |
  | `invitation_id` | `input` — `invitation.Id.ToString()`; `invitation` is `result.Invitation` from `_tofuAuthApiClient.CreateSmsInvitationAsync` response (Tofu.Auth gRPC/HTTP, `InvitationsController.cs:101`) |
  | `delivery_status` | `input` — `invitation.DeliveryStatus?.ToString()` from the Tofu.Auth create-invitation response DTO |
- User props: none.

### `Invite SMS Resent` (class `InviteSmsResent`, `Events/InviteSmsResent.cs:5`)
- Fired at: `InvitationsController.cs:239` (in `LogSmsInviteSent`); productKey: `ProductKey` (WithContext `:235`). Fired only when `invitation.RemindersSent > 0`.
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `channel` | literal `"sms"` (hardcoded in `GetEventProps`, `InviteSmsResent.cs:18`) |
  | `tenant_id` | `context` — `AccountId` (`:241`) |
  | `invitation_id` | `input` — `invitation.Id` from Tofu.Auth `CreateSmsInvitationAsync` response |
  | `resend_count` | `input` — `invitation.RemindersSent` (int→string) from the Tofu.Auth response DTO |
  | `delivery_status` | `input` — `invitation.DeliveryStatus?.ToString()` from the Tofu.Auth response |
- User props: none.

### `Invoice Paid` (class `InvoicePaid`, `Events/InvoicePaid.cs:5`)
- Fired at: `Src/Invoices.Payments/PaymentIntentsService.cs:643` (in `InvoicePaymentSuccess`, only when `paymentOrderInfo.ProviderType == "stripe"`, `:640`); productKey: `entity.ProductKey` (the invoice's product; WithContext `:606`).
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `invoice_id` | `input` — `paymentOrderInfo.InvoiceId`; `paymentOrderInfo` is a `PaymentOrderInfo` from the payment webhook flow (Tofu.Payments) processed in `ProcessPaymentEntity` (`:482`) |
  | `payment_provider` | `input` — `paymentOrderInfo.ProviderType` (payment provider string, e.g. "stripe") |
- User props: none.

### `Reminder Sent` (class `ReminderSent`, `Events/ReminderSent.cs:5`)
- Fired at: `Src/Notifications/Notifications.Application/PaymentReminder/PaymentReminderNotificationProcessor.cs:40` (in `LogReminderSent`, only when the process produced deliveries: `result.Deliveries.Count > 0`, `:31`); productKey: `eligibility.ProductKey` — from `IPaymentReminderVerifier.Verify(accountId, context)` (`:27`, WithContext `:39`).
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `invoice_id` | `input` — `context.InvoiceId` (the `PaymentReminderContext` for the wake-up) |
  | `reminder_number` | `input` — `context.ReminderNumber` (int→string), the reminder index being dispatched |
- User props: none.

### `Email Notification Sent` (class `EmailNotificationSent`, `Events/EmailNotificationSent.cs:8`)
- Fired at TWO sites in `Src/Tofu.Email/Service/EmailCallbackService.cs`:
  - `:127` in `HandleButtonClickAsync` (recipient clicked "see live status" CTA); productKey: `emailStatusEntity.ProductKey` (WithContext `:126`).
  - `:339` in `SendEmailNotificationAsync` (recipient opened the email; gated on status changed + `EmailStatusType.Opened` + product in `ProductsWithEmailNotifications`); productKey: `emailStatus.ProductKey` (WithContext `:333`).
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `trigger_type` | literal — `Consts.Email.TriggerType.Click` at click site (`:130`), `...TriggerType.Opened` at open site (`:342`) |
  | `cta_name` | literal `"see_live_status"` at click site (`:131`); `null` at open site (property default) |
  | `stripe_connected` | `input` — `@event.HasStripe.ToString()` (lowercased in `GetEventProps`) at click site (`:132`), where `@event` is the inbound `EmailButtonClickEvent`; `null` at open site |
  | `email_type` | `computed` — at click site: `@event.EmailLinkType == CheckInvoiceEmailStatus ? "invoice_viewed" : "estimate_viewed"` (`:133`); `null` at open site |
- User props: none.

### `Payout received` (class `PayoutReceived`, `Events/PayoutReceived.cs:6`)
- Fired at: `Src/Invoices.Payments/PaymentEventsService.cs:244` (in `SendAnalyticsAndPushByPayout`, on payout `PayoutStatusType.Paid`); productKey: `authenticatedPaymentType.ProductKey` (WithContext `:234`). Fired unconditionally once the payout is paid (the push variant is conditional; this analytics event is not).
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `amount` | `input` — `payoutInfo.Amount` formatted via `decimal.FormatAsMoney(3, "")`; `payoutInfo` is `PayoutInfo` from `_paymentPayoutsService.CapturePayout` response (Tofu.Payments gRPC, `:176`) |
  | `currency` | `input` — `payoutInfo.CurrencyCode.ToString().ToLower()` |
  | `payment_provider` | `input` — `authenticatedPaymentType.Name` (provider name, e.g. stripe/paypal), from the account's `AuthenticatedPaymentType` |
  | `is_instant` | `computed` — `payoutInfo.Method == PayoutMethodType.Instant ? true : false` (`:249`) → "True"/"False" |
  | `source` | `computed` — `isFromTofu ? "tofu" : "stripe"`, where `isFromTofu = !string.IsNullOrEmpty(productKey)` passed into the method (`PaymentEventsService.cs:182`) |
- User props: none.

### `Payment received` (class `PaymentReceived`, `Events/PaymentReceived.cs:6`)
- Fired at TWO sites in `Src/Invoices.Payments/PaymentIntentsService.cs`:
  - `:619` in `InvoicePaymentSuccess` (`PaymentSource = "Invoice"`); productKey: `entity.ProductKey` (invoice; WithContext `:606`).
  - `:710` in `RequestPaymentSuccess` (`PaymentSource = "Request"`); productKey: `entity.ProductKey` (payment request; WithContext `:697`).
- Props (Invoice site values shown; Request site noted where different):
  | prop | how BFF computes it |
  |------|---------------------|
  | `amount` | `input` — `paymentOrderInfo.Amount` (`decimal.FormatAsMoney(3, "")`); from `PaymentOrderInfo` (Tofu.Payments) |
  | `invoiceAmount` | `input` — `entity.TotalAmount` at Invoice site; **`null`** at Request site (`:724`); formatted `FormatAsMoney(3,"")` |
  | `currency` | `computed` — `CurrencyHelper.GetCurrencyCode(entity.CurrencyCode, account.CurrencyCode).ToString().ToLower()` (falls back to account currency) |
  | `payment_method` | `computed` — Invoice site: `sourceType == "tap-to-pay" ? "TapToPay" : "WebLink"` where `sourceType = paymentOrderInfo.Infos.GetValue("source-type")` (`:489`). Request site: switch on `entity.PaymentMethod` → QrCode/TapToPay/WebLink (`:715`) |
  | `payment_source` | literal — `"Invoice"` (`:621`) / `"Request"` (`:712`) |
  | `payment_provider` | `input` — `paymentOrderInfo.ProviderType` |
  | `payment_provider_method_type` | `input` — `paymentMethodType?.Value ?? "unknown"`, `paymentMethodType = paymentOrderInfo.Infos.FindInfo("payment-method-type")` (webhook metadata, `:490`) |
  | `application_fee_amount ` (note trailing space in key) | `input` — `paymentOrderInfo.FeeAmount ?? ProviderConstants.DefaultFee`, formatted `FormatAsMoney(3,"", MidpointRounding.ToZero)` (`PaymentReceived.cs:26`) |
  | `payment_fee_paid_by` | `computed` — `paymentOrderInfo.ClientFeeAmount.HasValue ? "client" : "business"` (`:634`) |
- User props: none.

### `Payment account status` (class `PaymentAccountStatus`, `Events/PaymentAccountStatus.cs:5`)
- Fired at: `Src/Invoices.Payments/PaymentsService.cs:342` (in `SafetySendPushAndAnalyticsByStatus`, only when `oldStatus != authenticatedPaymentType.Status`, `:294`); productKey: `authenticatedPaymentType.ProductKey` (WithContext `:296`).
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `provider` | `input` — `providerType` string arg (e.g. stripe) |
  | `enabled` | `input` — `authenticatedPaymentType.Enabled.ToString()` (bool from the account's payment-type record after provider sync) |
  | `status` | `computed` — `(authenticatedPaymentType.Status ?? PaymentAccountConnectionStatus.Unknown).ToString()`, status refreshed from provider in `TryFetchStateFromProviderAndUpdateApt` |
  | `requirements` | `computed` — `string.Join(", ", authenticatedPaymentType.Items.ConnectionErrors?.Select(e => e.Message ?? "") ?? [])` (`:336`) |
- User props: none.

### `Push sent` — push `email_opened` (class `EmailSent`, `Events/EmailSent.cs:3`)
- Fired at: `Src/Tofu.Email/Service/EmailCallbackService.cs:312` (in `SendPushNotification`, after enqueueing the push; gated on status changed + product in `ProductsWithNotifications`); productKey: `emailStatus.ProductKey` (WithContext `:282`).
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `push_id` | literal — `EventPushTypes.EmailOpened` = `"email_opened"` (`Consts.cs:18`). NOTE: this same event/`push_id` is logged for BOTH `EmailStatusType.Opened` and `EmailStatusType.Error` push branches — the Error case does not emit `EmailError` (see below); the template comment explains `push_id` intentionally stays `email_opened` (`PushNotificationTemplateService.cs:49`) |
  | `type` | literal — `"automatic"` (`PushEvent.PushType`) |
- User props: none.

### `Push sent` — push `email_error` (class `EmailError`, `Events/EmailError.cs:3`)
- Fired at: **NO active call site found.** The class exists and would emit `push_id = EventPushTypes.EmailError` (`"email_error"`, `Consts.cs:19`) + `type = "automatic"`, but no `_analytics.Log(new EmailError...)` exists in the codebase (the error push path emits `EmailSent` with `push_id = email_opened` instead). Treat as declared-but-unused/dead.
- Props (if ever fired): `push_id` = literal `"email_error"`; `type` = literal `"automatic"`.
- User props: none.

### `Push sent` — push `payment_account_unfinished` (class `PaymentAccountUnfinishedPushSent`, `Events/PaymentAccountUnfinishedPushSent.cs:3`)
- Fired at TWO worker sites, both only when `isPushSent`:
  - `Src/Invoices.Worker/OperationHandlers/PaymentAccountStatusInProgressOperationHandler.cs:62`; productKey: `operation.FindProp(OperationProp.ProductKey)` (WithContext `:61`); `Status = InProgress`.
  - `Src/Invoices.Worker/OperationHandlers/PaymentAccountStatusInformationIsRequiredOperationHandler.cs:46`; productKey: `operation.FindProp(OperationProp.ProductKey)` (WithContext `:45`); `Status = InformationIsRequired`.
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `push_id` | `computed` — `EventPushTypes.PaymentAccountUnfinished` (`"{provider} account was unfinished"`) with `{provider}` replaced by `Provider` (`PaymentAccountUnfinishedPushSent.cs:11`) |
  | `type` | literal — `"automatic"` |
  | `status` | `input` — `PaymentAccountConnectionStatus.InProgress` / `.InformationIsRequired`, hardcoded per handler |
  (`Provider` = `input` `operation.GetProp(OperationProp.ProviderType)` from the queued worker operation) |
- User props: none.

### `Push sent` — push `payment_account_changed` (class `PaymentAccountChangedPushSent`, `Events/PaymentAccountChangedPushSent.cs:3`)
- Fired at: `Src/Invoices.Payments/PaymentsService.cs:315` (in `SafetySendPushAndAnalyticsByStatus`, only when status changed AND `isPushSent`); productKey: `authenticatedPaymentType.ProductKey` (WithContext `:296`).
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `push_id` | `computed` — `EventPushTypes.PaymentAccountChanged` (`"{provider} account was changed"`) with `{provider}` → `Provider` |
  | `type` | literal — `"automatic"` |
  | `status` | `computed` — `(authenticatedPaymentType.Status ?? Unknown).ToString()` |
  (`Provider` = `input` `providerType` arg) |
- User props: none.

### `Push sent` — push `payout_paid` (class `PayoutReceivedPushSent`, `Events/PayoutReceivedPushSent.cs:5`)
- Fired at: `Src/Invoices.Payments/PaymentEventsService.cs:236` (in `SendAnalyticsAndPushByPayout`, only when `isPushSent`); productKey: `authenticatedPaymentType.ProductKey` (WithContext `:234`).
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `amount` | `input` — `payoutInfo.Amount` (`FormatAsMoney(3,"")`), from `CapturePayout` response |
  | `currency` | `input` — `payoutInfo.CurrencyCode.ToString().ToLower()` |
  | `push_id` | literal — `EventPushTypes.PayoutReceived` = `"payout_paid"` |
  | `type` | literal — `"automatic"` |
  | `payment_provider` | `input` — `authenticatedPaymentType.Name` |
- User props: none.

### `Push sent` — push `get paid from {provider}` (class `PaymentReceivedPushSent`, `Events/PaymentReceivedPushSent.cs:5`)
- Fired at TWO sites in `Src/Invoices.Payments/PaymentIntentsService.cs`, each only when `isPushSent`:
  - `:608` in `InvoicePaymentSuccess` (`InvoiceAmount = entity.TotalAmount`); productKey `entity.ProductKey` (WithContext `:606`).
  - `:699` in `RequestPaymentSuccess` (`InvoiceAmount = null`); productKey `entity.ProductKey` (WithContext `:697`).
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `amount` | `input` — `paymentOrderInfo.Amount` (`FormatAsMoney(3,"")`) |
  | `invoiceAmount` | `input` — `entity.TotalAmount` (Invoice site) / `null` (Request site) |
  | `currency` | `computed` — `CurrencyHelper.GetCurrencyCode(entity.CurrencyCode, account.CurrencyCode).ToString().ToLower()` |
  | `push_id` | `computed` — `EventPushTypes.PaymentReceived` (`"get paid from {provider}"`) with `{provider}` → `Provider` (`PaymentReceivedPushSent.cs:20`) |
  | `type` | literal — `"automatic"` |
  (`Provider` = `input` `paymentOrderInfo.ProviderType`) |
- User props: none.

### `Push sent` — push `instant_payout_available` (class `BalanceAvailableUpdatedPushSent`, `Events/BalanceAvailableUpdatedPushSent.cs:3`)
- Fired at: `Src/Invoices.Payments/PaymentEventsService.cs:208` (in `SendAnalyticsAndPushByBalance`, gated on config + `authenticatedPaymentType.SoftEnabled` + `availableInstantHasIncreased` + `isPushSent`); productKey: `authenticatedPaymentType.ProductKey` (WithContext `:207`).
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `push_id` | literal — `EventPushTypes.BalanceAvailableUpdated` = `"instant_payout_available"` |
  | `type` | literal — `"automatic"` |
  | `payment_provider` | `input` — `authenticatedPaymentType.Name` |
- User props: none.

### `Push sent` — push `visit_assigned` (class `VisitAssignedPushSent`, `Events/VisitAssignedPushSent.cs:3`)  ⚠ FieldServiceWorker
- Fired at: `Src/Jobs/Jobs.Application/Services/Push/JobNotificationService.cs:111` (in `SendAssigned`, on an `AssignTo` action after enqueuing the push); productKey: **`ProductConst.FieldServiceWorker`** (via `LogEvent` → WithContext `:177`).
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `push_id` | literal — `EventPushTypes.VisitAssigned` = `"visit_assigned"` |
  | `type` | literal — `"automatic"` |
  | `job_id` | `input` — `job.JobId.ToString()` (`assign.Job`) |
  | `visit_id` | `computed` — `visits.Count == 1 ? visits[0].VisitId.ToString() : null` (null for the batched multi-visit push) |
  | `visit_count` | `input` — `visits.Count` (int→string), the assigned visits in this action |
- User props: none.

### `Push sent` — push `visit_changed` (class `VisitChangedPushSent`, `Events/VisitChangedPushSent.cs:3`)  ⚠ FieldServiceWorker
- Fired at TWO sites, both with productKey **`ProductConst.FieldServiceWorker`**:
  - `Src/Notifications/Notifications.Application/WorkerVisits/WorkerVisitChangedNotificationProcessor.cs:45` (in `LogPushSent`, when `result.Deliveries.Count > 0`); `Kind` = `cancelled` if visit is null/deleted else `time_updated` (`:50`); WithContext `:44`.
  - `Src/Jobs/Jobs.Application/Services/Push/JobNotificationService.cs:130` (in `SendCancelled`, on a `Cancel` action); `Kind` = `cancelled`; WithContext via `LogEvent` `:177`.
- Props:
  | prop | how BFF computes it |
  |------|---------------------|
  | `push_id` | literal — `EventPushTypes.VisitChanged` = `"visit_changed"` |
  | `type` | literal — `"automatic"` |
  | `job_id` | `input` — `context.JobId` / `job.JobId` (`.ToString()`) |
  | `visit_id` | `input` — `context.VisitId.ToString()` (processor) / `cancel.LogVisitId?.ToString()` (job cancel, may be null) |
  | `kind` | `computed` — `time_updated` (`KindTimeUpdated`) or `cancelled` (`KindCancelled`): processor picks by whether the reloaded visit is null/`IsDeleted` (`WorkerVisitChangedNotificationProcessor.cs:37`); the job-cancel site always sends `cancelled` |
- User props: none.

## Worker-product events (attribution-sensitive)

Events fired with `ProductConst.FieldServiceWorker` (= `"tofu-fieldservice-worker"`, `Src/Invoices.Core/Models/ProductConst.cs:13`) hard-coded as the Context ProductKey (so user_id is resolved to the field-service-worker platform link, NOT the acting user):

- **`VisitAssignedPushSent`** — `JobNotificationService.cs:111` (WithContext `:177`).
- **`VisitChangedPushSent`** — `JobNotificationService.cs:130` (WithContext `:177`) AND `WorkerVisitChangedNotificationProcessor.cs:45` (WithContext `:44`).

All other events derive ProductKey from the triggering entity/account/operation (invoice `entity.ProductKey`, `authenticatedPaymentType.ProductKey`, `emailStatus.ProductKey`, `operation.ProductKey`, invitation `ProductKey`, reminder `eligibility.ProductKey`).

## Notable backend calculations reused across events

- **`environment` (auto-added to every event's `properties`)** — `accountsRepository.GetAsync(accountId).GetEnvironment()` in `Analytics.FlushAll` (`Analytics.cs:95`), injected in `AnalyticsService.Send` (`AnalyticsService.cs:23`). Not declared on any event class.
- **`user_id` (payload-level, not a prop)** — `Analytics.ResolveUserId` (`Analytics.cs:133`): owner via `IMasterUserRepository.FindOwnerForAccountId` → `ResolveUserIdFromMaster` picks `MasterUser.FindPlatformUserLinkByProduct(productKey)` and `Account.GetShortUserId(link.PlatformId, link.Platform)`; fallback to `masterUser.Id`, or account identifiers slot (`FindIdentifiersAsync`) for legacy/anonymous. ProductKey directly determines which platform's user_id stream the event lands in.
- **Money formatting** — all `amount`/`invoiceAmount`/`application_fee_amount ` props use `decimal.FormatAsMoney(3, "")` (fee uses `MidpointRounding.ToZero`); extension in `Invoices.Core.Models`.
- **Currency resolution** — `CurrencyHelper.GetCurrencyCode(entity.CurrencyCode, account.CurrencyCode)` falls back to the account currency; used by all payment/payout events, then `.ToString().ToLower()`.
- **`isPushSent` gating** — most `Push sent` events fire only if the corresponding `_paymentsNotificationService.TrySendPush*` / notification process actually delivered a push; the non-push analytics events (`PayoutReceived`, `PaymentReceived`, `PaymentAccountStatus`, `InvoicePaid`) fire regardless of push delivery.
- **Payment provider metadata** — `PaymentReceived`/`InvoicePaid`/`PaymentReceivedPushSent` read from `PaymentOrderInfo` (Tofu.Payments webhook processing in `PaymentIntentsService.ProcessPaymentEntity:482`): `ProviderType`, `Amount`, `FeeAmount`, `ClientFeeAmount`, and `Infos` key/values (`source-type`, `payment-method-type`, `latest-charge-id`, `receipt-url`).
- **`AuthenticatedPaymentType`** — provider-connection record per account (`Name` = provider, `Status`, `Enabled`, `SoftEnabled`, `ProductKey`, `Items.ConnectionErrors`), refreshed from the PSP; source for all `payment_provider`/`provider`/`status`/`enabled`/`requirements` props.
- **`isFirstPayment`** — `PaymentIntentsService.cs:502`: `_paymentOrdersService.Search(...).Infos.Count == 1` (Tofu.Payments); drives first-payment notification/email branches (not an event prop itself but gates surrounding logic).
