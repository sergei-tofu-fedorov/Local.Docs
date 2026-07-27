# Prices, price metadata, and trials

Purpose: how a plan/price is defined and how trial length + trial price are resolved and applied. This is the heart of the subscription-pricing model. Two mechanisms exist — pick by the `IsTofu` fork ([accounts-and-keys.md](accounts-and-keys.md)).

## TL;DR — where trial/price come from

| Path | Trial length | Trial price | Source of truth |
|---|---|---|---|
| **non-Tofu** (`IsTofu=false`, BFF direct) | `PriceConfig.TrialPeriodDays` (appsettings) | `PriceConfig.TrialPrice` (appsettings) | BFF `WebCheckout:PriceConfigs` |
| **Tofu** (`IsTofu=true`, current, via subz) | Stripe **price metadata** `subs_trial_period_days` → else `recurring.trial_period_days` | Stripe **price metadata** `subs_trial_price` (minor units) | the **Stripe price object itself** (subz reads it) |

For the current product the authoritative definition lives **on the Stripe price** (metadata), read by subz. The BFF's `PriceConfigs` is the legacy self-serve path. **`offerId == Stripe priceId`** everywhere.

## non-Tofu path — BFF `PriceConfig` (appsettings)

Config model `WebCheckoutStripeService.Config.PriceConfig` (`Invoices.Backend/.../WebCheckout/WebCheckoutStripeService.cs:480-486`), section `WebCheckout:PriceConfigs`, keyed by Stripe price id:

```csharp
public record PriceConfig {
    public string? CouponId { get; init; }        // coupon auto-applied (see coupons.md)
    public long? TrialPeriodDays { get; init; }    // → SubscriptionCreateOptions.TrialPeriodDays
    public decimal? TrialPrice { get; init; }      // → paid-trial one-off invoice item
    public bool IsTofu { get; init; } = false;     // routing fork
}
```

Applied in `InternalCreateSubscription` (`:110-168`): when `needTrialPeriod`, `TrialPeriodDays`/`TrialPrice` are set; a non-zero `TrialPrice` fetches the price (expand `product`) and adds a one-off invoice item so the trial is *paid* (e.g. $1). `GetConfig` (`:301`) also computes `trialPercentOff` and exposes `trial-interval`/`trial-price` to the checkout page. `TrialPeriodDays` here maps onto Stripe's legacy `recurring.trial_period_days`.

## Tofu path — Stripe price/product metadata (read by subz)

subz projects each **recurring Stripe Price + its Product** into an **Offer** (`Subz/src/Stripe/…/Domain/Offers/Models/Offer.cs`; `offerId == priceId`, `Offer.ProductId == productId`). It reads a set of **`subs_`-prefixed** metadata keys off the price/product. Key constants: `MetadataFieldNames.cs`; reads fall back to the legacy un-prefixed key (`MetadataExtensions.TryGetValueWithLegacyFallback`).

| Metadata key | On | Meaning |
|---|---|---|
| `subs_product_code` | Product | subz product code — filters which products belong to a productKey |
| `subs_trial_period_days` | Price | trial **length** in days; **wins over** `recurring.trial_period_days` |
| `subs_trial_price` | Price | paid-trial amount in **minor units** (cents); absent ⇒ free trial |
| `subs_default_coupon` | Price | coupon id auto-applied to the offer (see [coupons.md](coupons.md)) |
| `default_coupon_behavior` | Price | `paid_trial` / `subscription` / else → how the coupon is applied (no `subs_` prefix — 40-char limit) |
| `seat_count` | Price→Product | seats; `>1` ⇒ corporate plan (default 1) |
| `subs_description` | Product | human description |
| `subs_features` | Product | comma-separated feature list → `string[]` |
| `subs_is_consumable` | — | one-time repurchasable flag |
| `subs_platform` | — | platform tag |
| `subs_setup_intent_failed` | Subscription | set when setup-intent fails; makes the update handler skip |
| `subs_created_by` | Subscription | write-only stamp on subs subz creates |

**Two classification keys, don't confuse them:** `subs_product_code` is subz-internal. Before subz returns the offer to the BFF, `RemoveInternalKeys` strips **all `subs_`-prefixed keys**, so the BFF never sees `subs_product_code`. The BFF instead reads a separate **non-prefixed** `product_type` key that survives stripping — see product/plan mapping below.

**Validation** (`MetadataExtensions.ValidateMetadata`): ≤10 pairs, key ≤40 chars, value ≤500.

### Trial resolution (subz)

`StripePriceExtensions`:
- `GetTrialDuration` — metadata `subs_trial_period_days` first, else `price.Recurring.TrialPeriodDays` (both supported, metadata wins).
- `GetTrialPrice` — metadata `subs_trial_price` only (minor units), currency = price currency.

Offer normalization (`Offer.cs:43-51`): `TrialPrice` set but no `TrialDuration` ⇒ duration = one billing period (paid trial lasts one period); `TrialDuration` set but no `TrialPrice` ⇒ price = 0 (free trial).

### Trial applied at subscription creation (subz)

`StripePaymentIntentRegistrar.BuildSubscriptionCreateOptions`:
- `TrialEnd = now + TrialDuration` **unless `ignoreTrialFromOffer`**.
- `TrialSettings.EndBehavior.MissingPaymentMethod = "cancel"`.
- **Paid trial** (e.g. $1): adds a `SubscriptionAddInvoiceItem` billed immediately (`PriceData{Product, Currency, UnitAmount=trialPrice}`), while `TrialEnd` delays the first *recurring* charge. So "7 days free, first charge day 7" = free trial (`TrialEnd`, no invoice item); "$1 for 7 days" = paid trial (invoice item + `TrialEnd`).

### The `IgnoreTrialFromOffer` gotcha

The BFF's authorized path calls the **account-scoped** route `PUT api/adapters/stripe/accounts/{acc}/payment-intents`, which in subz **hard-codes `ignoreTrialFromOffer = false`** (`ExternalEndpoints.cs:131-138`). A separate non-account route carries the flag. So today the BFF **cannot suppress the offer's trial** through the authorized subscription call — relevant when a state (e.g. "trial already used") must charge immediately with no trial. Suppressing it requires plumbing the flag through that route.

## Product / plan mapping (Stripe id → ProductType)

The BFF classifies a subscription into a `ProductType` (Invoicing / FsmSolo / FsmTeam / FsmBusiness / Premium / Plus) via `PlanInfoProvider.cs`:
1. Reads the **`product_type`** metadata code from the subz offer `Metadata` dict (non-`subs_` key, `ProductTypeFieldName = "product_type"`).
2. Matches it against `PlansConstants` codes (`plus`, `premium`, `invoicing`, `fsm_solo`, `fsm_team`, `fsm_business`); `Duration.Week` ⇒ `Plus`; `PlusProductId` substring ⇒ `Plus`.
3. Apple/Google (non-Stripe) subscriptions instead match `productId` against hardcoded id sets in `PlansConstants.cs`.

Duration comes from the product-id string (`Subscription/Mapper.cs:GetDuration` — `week`/`month`/`annual|year` substrings) or the subz offer duration unit. `AccountController.cs` (V3) keeps an extra hardcoded `StripePlusProductIds` set to normalize premium vs plus product ids.

## How to add a new price / plan

**Tofu (current) path — metadata-driven, no BFF code change needed for trial/price:**
1. In the Stripe **Tofu account**, create the recurring Price (and Product if new).
2. Set Product metadata `subs_product_code` (subz classification) and the non-prefixed `product_type` (BFF classification) — both, since they feed different classifiers.
3. Set Price metadata as needed: `subs_trial_period_days`, `subs_trial_price` (cents, for a paid trial), `subs_default_coupon` + `default_coupon_behavior` (see [coupons.md](coupons.md)), `seat_count` for corporate.
4. Ensure the price's Stripe account is registered in subz config (`Products[productKey].StripeAccountId` → `Stripe:Accounts[id]`).
5. The BFF only needs a `PriceConfigs[priceId]` entry with `IsTofu = true` (so it routes to subz) — no trial/coupon fields needed there; subz owns them.

**non-Tofu (legacy) path — config-driven:** create the Stripe price on the Invoices account, then add `PriceConfigs[priceId]` with `TrialPeriodDays`/`TrialPrice`/`CouponId` and `IsTofu = false`.

**Reference material:** `Invoices.Backend/Docs/domain/stripe-plan-upgrades.md`, `Docs/features/WEB-1403/stripe_prices.md` (end-to-end price setup incl. `metadata[trial_price]`), and the metadata audit artifacts in the Backend root (`product_prices_metadata.*`, `product_id_lookup_final.csv`).
