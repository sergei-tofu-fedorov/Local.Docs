# Coupons

Purpose: how coupons are configured, transported, trusted, resolved, and applied — including the "3 months free / discounted" pattern. Coupons span the BFF and subz; a coupon id only exists on the Stripe account whose key resolves it ([accounts-and-keys.md](accounts-and-keys.md)).

## The mental model

A Stripe **coupon** is a discount attached to a subscription/invoice item — it is **not** part of a Price. So a coupon is reused across prices; you never create a new price to add a discount. Duration is a coupon property: `once` / `repeating` (`duration_in_months`) / `forever`. **"3 months free/discounted" = a `repeating` coupon with `duration_in_months = 3`**, not a special price.

There are two orthogonal questions, kept separate on purpose:
- **Trust** — may *this* coupon id be applied given *where it came from*? (config = trusted; URL = policy-gated).
- **Availability** — does the coupon exist/valid on the right account, and apply to the price?

## Where a coupon id comes from

| Source | Mechanism | Trust |
|---|---|---|
| **Per-price config (BFF)** | `PriceConfigs[priceId].CouponId` (appsettings) | trusted (server-set) |
| **Per-offer default (subz)** | Stripe price metadata `subs_default_coupon` + `default_coupon_behavior` | trusted (set on the Stripe object) |
| **URL / client** | appended to the price key as `price__c=coupon` (`SubsPriceKey`) | untrusted — whitelisted |
| **Computed (iOS migration)** | `IosMigrationDiscountCalculator` produces `ios_migration_XX` from subscription state | passed via the URL key, whitelisted |

## Transport: the `SubsPriceKey` embedding

The client passes a coupon by appending it to the price id: `price_123__c=ios_migration_50`. `Invoices.Core/Models/WebCheckout/SubsPriceKey.cs` (`Encode`/`Parse`, separator `__c=`) splits it back into `(PriceId, CouponHint)`. `PlansController migration-offers` encodes the offer's computed coupon into this key (`Mapping.cs:383`); `WebCheckoutController` parses it on `config` and `subscriptions`.

## Trust gate (URL coupons)

`IosMigrationDiscountCalculator.IsValidCouponId` — regex whitelist `^ios_migration_(10|20|...|90)$` (9 pre-created coupons). Used **only** on `POST subscriptions` (`WebCheckoutController.cs:54`): a URL hint is honored only if it matches, else it falls back to `PriceConfigs.CouponId`. `GET config` has **no** such gate — it previews any hinted coupon, which can desync preview vs charge. This is the trust boundary: because the coupon rides in a client-controlled URL, the BFF trusts only a fixed id set. Any generalization (e.g. a launch coupon via URL) must extend this policy — see the WEB-1788 design note (`Local.Docs/features/WEB-1788/coupon-check-design.md`).

## Resolution (BFF) — three divergent paths (known smell)

| Endpoint | Resolution |
|---|---|
| `GET config` (`WebCheckoutStripeService.cs:288`) | `couponHint ?? PriceConfig.CouponId` — accepts **any** hint |
| `POST subscriptions` (authorized, Tofu) | `couponOverride ?? PriceConfig.CouponId`, override = hint **only if** whitelisted |
| `POST create-subscription` (anon, non-Tofu) | hint ignored; `PriceConfig.CouponId`, and only when `!needTrialPeriod` (coupon ⟂ trial) |

Consequence: preview (`config`) may show a discount that the actual charge (`subscriptions`) drops. A unified resolver is proposed in the WEB-1788 design note.

## Reading a coupon for display (BFF)

`GetConfig` calls `CouponService.GetAsync(couponId, requestOptions)` on the price's account and reads `PercentOff` / `AmountOff` / `DurationInMonths` / `Duration` to compute `coupon-price`, `coupon-percent-off`, `coupon-duration`, `coupon-duration-in-months` for the checkout page. It does **not** check `coupon.Valid` — an expired/exhausted coupon surfaces only as an opaque error at charge time.

## Application (subz) — behavior matters

For Tofu prices the coupon reaches subz via the payment-intent request (`Coupons` list; obsolete singular `Coupon` throws on collision). subz then:
1. **Merges** request coupons with the offer's `subs_default_coupon` → `CouponBrief(items, behavior)` (`StripePaymentIntentRegistrar.BuildCouponCollection`).
2. Picks a **behavior** from `default_coupon_behavior` metadata → `CouponBehavior`: `PaidTrial` / `Subscription` / `PaidTrialOrSubscription` (default).
3. **Applies** (`ApplyCouponBehavior`):
   - `PaidTrial` → discount on the **trial invoice item**.
   - `Subscription` → discount on the **subscription item**.
   - `PaidTrialOrSubscription` → trial item if it exists, else subscription item.

So *where* a coupon bites (the $1 trial charge vs the recurring price) is controlled by `default_coupon_behavior` on the price. `DurationInMonths` on the Stripe coupon controls for how many months it repeats (the "3 months" part). subz validates coupon existence per account (`StripeCouponProvider.GetCouponOrThrowAsync`, previews via `ValidateCouponsAsync`).

## How to set up "3 months free" (or 3-month discount)

1. Create a Stripe **coupon** on the plan's account: `duration = repeating`, `duration_in_months = 3`, and the discount (`percent_off = 100` for fully free, or an amount/percent for a discount). For "for everybody, indefinitely" leave **`max_redemptions` and `redeem_by` unset** — otherwise it stops working once the cap/date is hit.
2. Attach it as the offer default: set Stripe **price metadata** `subs_default_coupon = <coupon_id>` and `default_coupon_behavior` (`subscription` to discount the recurring charge; `paid_trial` to discount the trial charge). No new price, no BFF code.
   - Alternative (legacy/non-Tofu): set `PriceConfigs[priceId].CouponId` in appsettings.
3. The coupon must exist on the **same Stripe account** as the price (Tofu vs Invoices). A coupon created on the wrong account resolves as "not found".
4. If the discount must ride in a per-user **URL** rather than sit on the price, it additionally has to pass the trust whitelist (`IsValidCouponId`) — today that only allows `ios_migration_*`; anything else needs the policy extended.

## iOS-migration coupons (computed, state-derived)

`IosMigrationDiscountCalculator.Calculate` computes a per-user discount from the user's remaining iOS subscription value vs the Stripe annual price: prorate remaining value, divide by Stripe price, round up to the nearest 10, clamp 10–90 → coupon id `ios_migration_{percent}`. Packed into the `SubsPriceKey` for `migration-offers` and honored at checkout via the whitelist. The 9 `ios_migration_10..90` coupons must be pre-created in Stripe; the code references them by id and does not create them.
