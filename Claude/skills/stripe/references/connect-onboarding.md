# Stripe Connect onboarding & Tap-to-Pay

Purpose: how merchants connect a Stripe account to accept invoice / payment-request payments, and how Tap-to-Pay/Terminal works. This is the **merchant/Connect** side — unrelated to subscription billing (that's [pricing-and-trials.md](pricing-and-trials.md) / subz). All code is in `Invoices.Backend/Src/Tofu.Stripe/` wrapped by `Invoices.Payments`.

## Connect account onboarding

`Tofu.Stripe/StripeAccountClient.cs` (`IStripeAccountClient`) — thin wrapper over the Stripe SDK for standard connected accounts. Sets `StripeConfiguration.ApiKey = token` in the ctor (`:16`).

| Method | Line | SDK call | Purpose |
|---|---|---|---|
| `PreAuth` | `:95` | `AccountService.CreateAsync` (type `standard`) | Create the connected account; stamps internal `AccountId` into Stripe account metadata |
| `Authenticate` | `:34` | `AccountLinkService.CreateAsync` (`account_onboarding`) | Build the hosted onboarding link (refresh/return URLs) |
| `FinishAuthenticate` | `:66` | `AccountService.GetAsync` | Read `Requirements` / `ChargesEnabled` / `PayoutsEnabled` / verification status |
| `UpdateAccount` | `:111` | `AccountService.UpdateAsync` | Update the connected account |
| `CreateAccountSession` | `:194` | `AccountSessionService.CreateAsync` | Client secret for embedded components (Payments / PaymentDetails / Payouts / Onboarding) |

**Provider wrapper:** `Invoices.Payments/Stripe/StripeProvider.cs` implements `IPaymentProvider` for the "Stripe" payment type and delegates to `IStripeAccountClient`:
- `Authenticate:26` — builds refresh/return URLs, starts onboarding.
- `GetAuthenticationProcess:68` — calls `FinishAuthenticate`, then interprets Stripe requirements into `FinishAuthenticationStatus` (`InformationIsRequired` / `Verification` / `Rejected`), surfacing `connectionErrors`, payouts-enabled, currency, country.
- `CreateAccountSession:126` — passes through for embedded components.

`PaymentProviderFactory.cs:19-22` news up `new StripeAccountClient(paymentType.Items["Token"])`. A background job `Invoices.Worker/Jobs/Payments/UpdateStripeAccountsJob.cs:129` periodically re-syncs connected-account status via `FinishAuthenticate`.

**Hosted vs embedded onboarding** is an active design area — see the research under `Invoices.Backend/Docs/features/stripe-onboarding-redesign/` (and the Local.Docs feature folder of the same name) for the funnel analysis, prefill fields, and the embedded-vs-hosted A/B plan.

## Tap-to-Pay / Terminal

`Tofu.Stripe/StripeTap2PayClient.cs` (`IStripeTap2PayClient`) — Terminal / Tap-to-Pay. `StripeConfiguration.ApiKey` from `PaymentType.Items["Token"]` (`:60`). SDK: `AccountService`, `LocationService` (`Stripe.Terminal`), `ConnectionTokenService`.

- `CreateLocation:71` — `AccountService.GetAsync`, then `LocationService.ListAsync`/`CreateAsync`. Country allow-listing + AU/CA postal-code fixups.
- `CreateConnectionToken:230` — `ConnectionTokenService.CreateAsync`; passes the connected account via `RequestOptions.StripeAccount` (`:251`).

Orchestrated by `Invoices.Payments/Stripe/StripeTap2PayService.cs`.

## Payment capture / payouts (platform side)

Invoice / payment-request charge capture and payouts are **not** in `Tofu.Stripe` — they live in `Tofu.Payments.Backend/src/Tofu.Payments.Stripe/StripeGateway.cs` (`IStripeGateway`), exposed to the BFF over gRPC. `StripeConfiguration.ApiKey = stripeOptions.Token` (`:38`); all calls use `RequestOptions.StripeAccount = <connected account>`.

| Method | Line | Purpose |
|---|---|---|
| `CreateSession` | `:47` | Checkout `SessionService.CreateAsync` for a payment (`ApplicationFeeAmount`, `ext_*` metadata) |
| `GetSessionInfo` / `GetPaymentIntentInfo` | `:149` / `:172` | Read session / payment-intent |
| `CapturePaymentIntent` | `:203` | `PaymentIntentService.CaptureAsync` + `ChargeService.UpdateAsync` |
| `GetBalanceInfo` / `GetExternalAccountInfos` | `:262` / `:308` | Balance + external accounts |
| `CreatePayout` / `GetPayout` | `:341` / `:393` | Payouts |

The one price-unrelated metadata key read here: `ext_client_fee` off a Charge/PaymentIntent (`Tofu.Payments.Stripe/StripeGateway.cs:187,229`) — the surcharge passed to the customer.

## `IStripePaymentClient` — legacy/unused

`Tofu.Stripe/IStripePaymentClient.cs` is declared but has **no implementation and no DI registration** (`CreatePayment`/`GetPayment`/`GetRefunds`). Ignore it; it is dead surface.
