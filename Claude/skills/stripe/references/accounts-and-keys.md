# Stripe accounts, keys, and the service boundary

Purpose: which Stripe accounts exist, how the code picks a key per request, and which backend component owns which slice of Stripe. Read this first when a question is about "which account / which key / who talks to Stripe".

## Two Stripe accounts (web-checkout subscriptions)

Web-checkout subscriptions run against **two different Stripe accounts**, selected per price by the `IsTofu` flag on that price's config:

| Account | Keys (config) | Used for |
|---|---|---|
| Default / Invoices | `WebCheckout:SecretKey`, `WebCheckout:PublishableKey` | legacy/self-serve web subscriptions (`IsTofu == false`) — charged **directly** by the BFF |
| Tofu | `WebCheckout:TofuSecretKey`, `WebCheckout:TofuPublishableKey` | current Tofu-branded subscriptions (`IsTofu == true`) — delegated to the **subz** microservice |

Definition: `WebCheckoutStripeService.Config` (`Invoices.Backend/Src/Invoices.Implementation.Services/WebCheckout/WebCheckoutStripeService.cs:463-487`), section `WebCheckout` in `appsettings.json`. The comment at `:467` marks the Tofu keys.

**Where the key is chosen** (all in `WebCheckoutStripeService.cs`), keyed off `PriceConfig.IsTofu`:
- `GetConfig:283` — `ApiKey = IsTofu ? TofuSecretKey : SecretKey`; publishable key likewise at `:322`.
- `CreateSubscription:62` — `IsTofu` → `InternalCreateSubscriptionInSubs` (subz); else `InternalCreateSubscription` direct-to-Stripe with `SecretKey` (`:102, :147`).
- `TryConfirmSubscription:360` — `IsTofu ? …ForSubs (TofuSecretKey) : … (SecretKey)`.
- `CreateSubscriptionForAuthorizedUser:76-81` — rejects non-Tofu prices (Tofu-only, always via subz).

Coupons and prices resolve **on whichever account the price lives on** — a coupon id only exists on the account whose key you use. Looking up a Tofu coupon with the Invoices key returns "not found". See [coupons.md](coupons.md).

## Connect / merchant payments (a separate key set)

The Stripe **Connect** side (merchants accepting invoice/payment-request payments, Tap-to-Pay, payouts) uses a **different** config area — the `PaymentTypes[Name="Stripe"].Items` block in `Invoices.Api/appsettings.json` (`:104-117`): `Token` (`STRIPE_TOKEN`), `WebHookSecret`, `PublishableKey`, `RefreshUrl`, `ReturnUrl`. `Tofu.Payments.Backend` uses `StripeOptions.Token` (section `PaymentProviders:Stripe`).

Connect clients set the process-wide `StripeConfiguration.ApiKey` from the injected token and pass the connected-account id via `RequestOptions.StripeAccount`. This is orthogonal to the subscription `SecretKey`/`TofuSecretKey` split above — different keys, different purpose. See [connect-onboarding.md](connect-onboarding.md).

## Who touches Stripe (component map)

Only two of the four backend repos call the Stripe SDK; plus the external subz service.

| Component | Repo | Stripe responsibility |
|---|---|---|
| `Tofu.Stripe` | `Invoices.Backend` (5.Domain) | Connect account onboarding, Tap-to-Pay/Terminal, webhook signature verify + event mapping. Does **not** touch subscriptions. |
| `WebCheckoutStripeService` | `Invoices.Backend` (Implementation.Services) | Direct-to-Stripe web subscriptions for **non-Tofu** prices (create/confirm/config); forwards Tofu prices to subz. |
| `Invoices.Payments/Stripe` | `Invoices.Backend` | `StripeProvider` = merchant Connect onboarding for the "Stripe" payment type (wraps `Tofu.Stripe`); Tap-to-Pay orchestration. |
| `StripeGateway` | `Tofu.Payments.Backend` | Platform-side gateway over gRPC: Checkout sessions, payment-intent capture, payouts, balance, external accounts. |
| **subz** (external) | `C:\Git\Work\Subz` | Owns **Tofu-account subscription billing end-to-end**: reads price metadata, applies trial + coupon, creates subscription payment-intents, handles subscription lifecycle webhooks. The BFF proxies to it over HTTP. |

`Tofu.Auth.Backend` and `Tofu.Invoices.Backend` contain **no** Stripe SDK usage.

## The IsTofu fork (the single most important boundary)

```
WebCheckout entry (config / create / confirm)
        │
        ├── IsTofu == false ──► BFF charges Stripe DIRECTLY (SecretKey / Invoices account)
        │                        WebCheckoutStripeService.InternalCreateSubscription
        │                        trial + trialPrice from PriceConfig (appsettings)
        │
        └── IsTofu == true  ──► BFF proxies to subz over HTTP (Web2WebSubscriptionService
                                 → SubscriptionService → PUT api/adapters/stripe/.../payment-intents)
                                 subz reads Stripe price METADATA and applies trial + coupon on the Tofu account
```

Consequence for anyone reasoning about trials/coupons/prices: **for the current (Tofu) path, the authoritative logic is in the subz repo, not the BFF.** The BFF only forwards `priceId` + `coupon`. See [pricing-and-trials.md](pricing-and-trials.md) and [coupons.md](coupons.md).

## Subz HTTP client (the BFF side of the boundary)

- Client: `Invoices.Implementation.Services/Subscription/SubscriptionService.cs` — plain HTTP (not Stripe SDK) to `SubzOptions.BaseAddress`, bearer `ApiToken` (config `Services:Subz`).
- Registered as `ISubscriptionService → Web2WebSubscriptionService` (a decorator that remaps anonymous web users to their claimed account).
- Key op: `CreateStripePaymentIntentsWithAccountAsync` → `PUT api/adapters/stripe/accounts/{acc}/payment-intents` (body `PaymentIntentAdapterRequest(OfferId, IgnoreTrialFromOffer, CustomerId, Coupon)`). Other ops: account upsert, customer-id link, receipt validation, list/get subscriptions, portal link (injects `StripeCancellationPortalId`), offers/plans, plan-upgrade link, cancel, renew.
