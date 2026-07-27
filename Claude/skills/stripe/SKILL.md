---
name: stripe
description: >-
  Reference + how-to for how the Tofu/Invoices backend integrates with Stripe, plus a general Stripe
  knowledge base: subscription price config and the price metadata that drives trials/coupons
  (`subs_trial_period_days`, `subs_trial_price`, `subs_default_coupon`, `WebCheckout:PriceConfigs`),
  coupons (incl. "3 months free" via `duration_in_months` and the `ios_migration_*` URL whitelist), the
  two Stripe accounts and the `IsTofu` fork (charge Stripe directly vs delegate to the subz service),
  Connect merchant onboarding / Tap-to-Pay / payouts, and webhook ingestion. ALWAYS invoke on any
  backend Stripe task — even if "Stripe" is never said: prices, plans, trials, coupons/discounts/promos,
  price or product metadata, `PriceConfig` / `IsTofu` / `TofuSecretKey`, the subz payment-intent flow or
  `ignoreTrialFromOffer`, Connect onboarding / Tap-to-Pay, payouts/balance, Stripe webhooks/events, or a
  general "how does Stripe work" question (coupon durations, trial semantics, idempotency, rate limits)
  even when not about our code. NOT for revenue/payout totals (→ BigQuery skill), a production payment
  error / 500 / alert (→ investigation skill), or client Stripe crashes in Sentry (→ Sentry skill).
  Prefer the bundled `references/` over grepping the repos.
---

# How the Tofu/Invoices backend works with Stripe

Stripe does two unrelated things here: **subscription billing** (plans, trials, coupons) and **merchant payments** (Connect onboarding to accept invoice payments, Tap-to-Pay, payouts). Different accounts, keys, code paths — don't conflate them.

This is a **reference + how-to**. Answer from the matching `references/` file (each opens with a short answer box, then the mechanics with `file:line`). For a single-domain question you normally need **one** reference; open a second only when the question truly spans domains. For a general "how does Stripe itself work" question, answer from Stripe's own semantics — the references still show how we use the feature.

## Route by the question

| The question is about… | Read |
|---|---|
| A **price/plan/trial** — where trial length/price comes from, price/product **metadata** keys, adding a price | `references/pricing-and-trials.md` |
| A **coupon / discount / promo**, "3 months free", `ios_migration_*`, how a coupon is trusted/resolved/applied | `references/coupons.md` |
| **Which account / which key**, the `IsTofu` fork, who talks to Stripe (BFF vs subz vs Tofu.Payments) | `references/accounts-and-keys.md` |
| **Connect onboarding**, embedded components, Tap-to-Pay/Terminal, payment capture, payouts | `references/connect-onboarding.md` |
| A **Stripe webhook / event** — what's handled where, who owns subscription-lifecycle events | `references/webhooks.md` |

## The one boundary to hold in your head

```
WebCheckout entry (config/create/confirm)
   ├── IsTofu == false ─► BFF charges Stripe DIRECTLY (WebCheckout:SecretKey, Invoices account)
   │                      trial/price from appsettings PriceConfigs
   └── IsTofu == true  ─► BFF proxies to subz over HTTP (WebCheckout:TofuSecretKey, Tofu account)
                          subz reads Stripe price METADATA, applies trial + coupon, creates the PI

Merchant payments (separate keys: PaymentTypes[Stripe].Token): Connect onboarding + Tap-to-Pay
  (Tofu.Stripe), capture/payouts (Tofu.Payments/StripeGateway), webhook ingest (BFF).
```

For the current (Tofu) product the authoritative pricing/trial/coupon logic lives in the **`subz` repo** (`C:\Git\Work\Subz`), not the BFF — the BFF only forwards `priceId` + `coupon`.

## How-to index

- **Add a price/plan (with trial):** `references/pricing-and-trials.md` → "How to add a new price / plan".
- **Set up "3 months free" / any promo:** `references/coupons.md` → "How to set up 3 months free".
- **Per-user discount in a URL:** `references/coupons.md` → trust gate + `SubsPriceKey` (needs the whitelist extended beyond `ios_migration_*`).
- **Wire a merchant to accept payments:** `references/connect-onboarding.md`.

## Repos

`Invoices.Backend` (BFF: WebCheckout, `Tofu.Stripe`, `Invoices.Payments`) · `Subz` (`C:\Git\Work\Subz`, owns Tofu-account subscription billing) · `Tofu.Payments.Backend` (`StripeGateway`) · `Tofu.Auth.Backend`/`Tofu.Invoices.Backend` (no Stripe SDK).
