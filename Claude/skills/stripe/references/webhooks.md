# Stripe webhooks

Purpose: which Stripe events the backend receives, where, and who acts on them. Key split: the BFF handles the **Connect/merchant-payments** side; **subscription-lifecycle** events are owned by subz (see [pricing-and-trials.md](pricing-and-trials.md)).

## Ingestion point (BFF)

Single endpoint: `Invoices.Backend/Src/Invoices.Api/Controllers/PaymentsController.cs`
- `[HttpPost("/callback/hooks/stripe/events")] StripeEventsHook` (`:321-334`). Reads the raw body + `Stripe-Signature` header (`GetFormattedEvent:336-343`), builds an `EventHookRaw`, then `_eventHookMapper.Map(...)` → `_paymentEventsService.HandleEvent(...)`.

## Verify + map

`Tofu.Stripe/StripeEventHookMapper.cs` (implements `Invoices.Common`'s `IEventHookMapper`):
- `EventUtility.ConstructEvent(payload, signature, secret)` (`:23`) verifies the signature. Secret = `PaymentTypes[Stripe].Items["WebHookSecret"]` (DI: `PaymentsServicesInstaller.cs:31`).
- Live/test-mode guard at `:26`/`:37`.
- Switch over `EventTypes.*` (`:54-92`) → internal `PaymentEvent` / `EventType`.

Handled event types → internal event:

| Stripe event | Internal | Notes |
|---|---|---|
| `account.updated` | `AccountWasUpdated` | + account metadata (`AccountId`, `ext_account_id`) |
| `charge.refunded` / `charge.succeeded` | `ChargeWasUpdated` | |
| `checkout.session.completed` / `...async_payment_succeeded` | `CheckoutSessionCompleted` | |
| `checkout.session.async_payment_failed` | `CheckoutSessionAsyncPaymentFailed` | |
| `payout.updated/canceled/created/failed` | `PayoutWasUpdated` | |
| `payout.paid` | `PayoutWasPaid` | |
| `balance.available` + external-account created/updated/deleted | `BalanceSummaryWasUpdated` | |
| `account.application.deauthorized` | (logged) | |

## Act

`Invoices.Payments/PaymentEventsService.cs` `HandleEvent` (`:47-120`):
- `AccountWasUpdated` / `ChargeWasUpdated` / `BalanceSummaryWasUpdated` → `FinishAuthenticatePaymentType` and/or `UpdateBalanceSummary` (feature-flagged via `Config.UpdateStripeAccountsWhen*Enabled`).
- `CheckoutSessionCompleted` → `PaymentIntentsService.TrySuccessPayment`; `…AsyncPaymentFailed` → `TryFailPayment`.
- `PayoutWasUpdated/Paid` → payout status/capture + analytics/push.
- `AccountApplicationDeauthorized` → logs deauthorization.

## What is NOT handled here

Subscription-lifecycle events (`invoice.paid`, `customer.subscription.updated`, `customer.subscription.deleted`, trial-will-end, etc.) do **not** hit this endpoint. They are owned by the external **subz** service, which reconciles subscription state on the Tofu Stripe account. The BFF only relays receipts / customer-ids to subz (see [accounts-and-keys.md](accounts-and-keys.md)); it does not observe subscription webhooks itself. When a question is "why did a subscription flip to X on renewal / trial end", the answer is in subz, not this endpoint.
