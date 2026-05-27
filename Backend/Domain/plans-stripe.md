# Plans ↔ Stripe: Upgrade Selection

How `POST /api/plans/upgrade-links` decides which upgrades to offer.
Implemented in `PlanUpgradeService.GetPlanUpgradeLinksAsync`.

## Pipeline

1. **Load active plans** — `PlansService.GetAllActiveAsync` for the caller's product users.
2. **Pick one source plan** to upgrade from (`FindPlanToUpgrade`).
3. **Fetch all offers** for that plan's `(adapterType, productKey)` via `PlansService.GetAllAsync` (cached).
4. **Filter offers** through the blacklist + `IsValidUpgrade` matrix.
5. **Generate a deep link per surviving target** via `ISubscriptionService.GeneratePlanUpgradeLinkAsync`. Targets that throw `SubscriptionCanNotBeUpdatedException` are dropped; the rest are returned.

## Step 2 — Source plan selection

From the user's active plans, keep only those that satisfy **all** of:

- `AdapterType == Stripe`
- `Duration != Unknown`
- `ProductType ∈ { Plus, Premium, Invoicing, FsmSolo, FsmTeam, FsmBusiness }`

If none survive → return `[]`. Otherwise pick the one whose `ProductKey` equals
`ProductConst.Tofu` first, else any remaining.

## Step 4 — Target offer filtering

A candidate offer passes only if **both** conditions hold:

**(a) Not blacklisted.** Its `OriginOfferId` is not in
`StripeSubscriptionsOptions.NonUpgradeablePlans` (per-product Stripe price-id list).

**(b) `IsValidUpgrade(currentProductType, currentDuration, targetProductType, targetDuration)` returns true:**

| Current `ProductType` | Allowed target `ProductType` | Duration constraint |
|-----------------------|------------------------------|---------------------|
| `Plus`, `Premium`     | `Invoicing`, `FsmSolo`, `FsmTeam`, `FsmBusiness` only | target duration ≥ current |
| same as current (`Invoicing` / `Fsm*`) | same `ProductType` | target duration **>** current |
| different from current (`Invoicing` / `Fsm*`) | strictly higher-priority `ProductType` | target duration ≥ current |

Duration priority: `Year (3) > Month (2) > Week (1)`.
`ProductType` priority comes from `PlansExtensions.GetPriority`.

## Step 5 — Two-portal note

The deep link is built against the **restricted** Stripe Customer Portal
configuration `StripeSubscriptionsOptions.PortalConfigurationId` (passed as
`configuration=...` to the Subs API). This is a different portal from the
default one used by `GET /api/plans/active` /
`GET /api/users/{id}/subscription-management-link`, which sends no
`configuration` parameter and therefore uses the Stripe dashboard default.

The restricted portal limits switchable plans on Stripe's side, so the
backend's blacklist + `IsValidUpgrade` filter and the Stripe portal
configuration must be kept in sync — adding a new upgrade target requires
updating both.

## Configuration reference

`Subscriptions:Stripe:<productKey>` → `StripeSubscriptionsOptions`:

| Field | Used at step | Meaning |
|-------|--------------|---------|
| `NonUpgradeablePlans`   | 4(a) | Stripe price-id blacklist for upgrade targets. |
| `PortalConfigurationId` | 5    | Restricted Stripe portal configuration id for upgrade deep links. Required. |
| `PlusProductId`         | —    | Used by `PlanInfoProvider` to classify products as `Plus` vs `Premium`; not part of upgrade selection. |
| `IntroCoupons`          | Price metadata (intro) | Map of `couponKey → stripeCouponId` referenced by `metadata.default_coupon_behavior` on Stripe Prices. |

Example JSON:

```jsonc
"Subscriptions": {
  "Stripe": {
    "meta": {
      "PlusProductId": "prod_...",
      "PortalConfigurationId": "bpc_...",
      "NonUpgradeablePlans": [ "price_..." ],
      // Coupons attached automatically when a Price has
      // metadata.default_coupon_behavior = subscription.
      "IntroCoupons": {
        "solo_intro_3mo":     "coupon_...",
        "team_intro_1mo":     "coupon_...",
        "business_intro_1mo": "coupon_..."
      }
    }
  }
}
```

## Stripe Price metadata

Trial and intro behaviour for a product's Prices are driven by metadata
attached to each Stripe Price object. The backend reads these keys when
creating a checkout / subscription:

| Metadata key                | Type / values         | When to set | Effect |
|-----------------------------|-----------------------|-------------|--------|
| `trial_price`               | integer (cents)       | Paid trial (e.g. $1) | Backend bills this amount for the trial period instead of the default $0 trial. Combined with the legacy Stripe `trial_period_days` field on the Price, which controls trial length. |
| `default_coupon_behavior`   | `subscription`        | Plans with an intro phase | Backend automatically attaches the configured intro coupon (looked up in `Subscriptions:Stripe:<productKey>:IntroCoupons`) to the new subscription. The coupon's own `duration` / `duration_in_months` controls how long the intro discount runs before billing rolls over to the Price's `unit_amount` (the base price). |

Notes:

- `trial_period_days` is Stripe's **legacy** field on the Price object;
  it is set in the Stripe Dashboard alongside the Price, not in backend
  code.
- A Price with neither `trial_price` nor `default_coupon_behavior`
  behaves as a plain recurring price — no trial charge, no coupon
  attached.
- Cross-reference for the WEB-1403 `meta` plans (Solo / Team / Business
  with 7-day, 14-day and no-trial variants, plus 1- or 3-month intro
  phases): see `features/WEB-1403/stripe_prices.md`.

## Web checkout `PriceConfigs`

`WebCheckout.PriceConfigs` (`WebCheckoutStripeService.Options.PriceConfig`,
`Src/Invoices.Implementation.Services/WebCheckout/WebCheckoutStripeService.cs:473`)
is a per-Stripe-price map consumed by `WebCheckoutStripeService` when
building checkout sessions and subscriptions. The Stripe Price object
itself only needs the recurring `unit_amount` and the `trial_period_days`
field; the rest of the trial / intro / account routing lives here.

| Field             | Type          | Meaning |
|-------------------|---------------|---------|
| `CouponId`        | `string?`     | Stripe coupon attached to subscriptions/checkouts created for this price. Drives the intro phase. |
| `TrialPeriodDays` | `long?`       | Trial length in days. Surfaces on the public checkout (`trial-interval` query param) and the subscription. |
| `TrialPrice`      | `decimal?`    | Charged during the trial instead of $0. Only meaningful when `TrialPeriodDays` is set. |
| `IsTofu`          | `bool` (false)| Routes Stripe API calls to the Tofu account credentials (`TofuSecretKey` / `TofuPublishableKey`) and uses the Subs API path instead of the legacy direct-Stripe path. All `tofu.*` products (incl. FSM Solo / Team / Business) must set this to `true`. |

The map key is the Stripe price id. Any price referenced from the
checkout / web flow must have an entry — `WebCheckoutStripeService`
indexes into the dictionary directly and will throw if missing.

Example entries:

```jsonc
"WebCheckout": {
  "PriceConfigs": {
    // Paid trial: 14 days at $1.99, then intro coupon, then base price
    "price_xxx": {
      "CouponId": "coupon_xxx",
      "TrialPeriodDays": 14,
      "TrialPrice": 1.99,
      "IsTofu": true
    },
    // No trial, intro coupon only
    "price_yyy": {
      "CouponId": "coupon_xxx",
      "IsTofu": true
    },
    // Plain recurring price (annual), no trial, no coupon
    "price_zzz": {
      "IsTofu": true
    }
  }
}
```

## Test environment inventory

Snapshot of Stripe **test** account products and prices for the FSM
plans (as of 2026-04-08). Default price for each product is marked
*(default)*.

### FSM Solo — `prod_TlBXAiOqAYuLzv`

`metadata.product_code = tofu.fsm_solo`

| Nickname | Price ID | Interval | Amount | Trial days | Metadata |
|---|---|---|---|---|---|
| FSM Solo Monthly Free Trial | `price_1SnfAVJnc2Yr4yxFhVgYGa36` *(default)* | month | $29 | 7 | `product_type=fsm_solo` |
| FSM Solo Monthly Paid Trial | `price_1SnfQrJnc2Yr4yxFL3uSXs49` | month | $29 | 3 | `trial_price=199`, `default_coupon_behavior=subscription` (legacy, not in WEB-1403 plan) |
| FSM Solo Monthly Paid Trial | `price_1SnfUCJnc2Yr4yxFZORLplME` | month | $29 | 7 | `trial_price=199`, `default_coupon_behavior=subscription` (legacy $1.99 trial, superseded by 7d $1 below) |
| FSM Solo Meta Monthly Paid Trial 7d | `price_1TJvehJnc2Yr4yxF65ZAaVyg` | month | $29 | 7 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Solo Meta Monthly Paid Trial 14d | `price_1TJv0qJnc2Yr4yxFbBbCzFRl` | month | $29 | 14 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Solo Meta Monthly No Trial | `price_1TJv0sJnc2Yr4yxFSKR7H4dA` | month | $29 | — | `default_coupon_behavior=subscription` |
| FSM Solo Annual Free Trial | `price_1SnfPCJnc2Yr4yxFF6zte2Oy` | year | $180 | 7 | `product_type=fsm_solo` |

### FSM Team — `prod_TzTh0vfFkjRFO3`

`metadata.product_code = tofu.fsm_team`

| Nickname | Price ID | Interval | Amount | Trial days | Metadata |
|---|---|---|---|---|---|
| FSM Team Monthly Free Trial | `price_1T1UjhJnc2Yr4yxFKmB7wUXj` *(default)* | month | $79 | 7 | `product_type=fsm_team` |
| FSM Team Meta Monthly Paid Trial 7d | `price_1TJvDkJnc2Yr4yxFyQH7ZrYy` | month | $79 | 7 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Team Meta Monthly Paid Trial 14d | `price_1TJvDmJnc2Yr4yxFEBDLYzcb` | month | $79 | 14 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Team Meta Monthly No Trial | `price_1TJvDoJnc2Yr4yxFqQgq0WwD` | month | $79 | — | `default_coupon_behavior=subscription` |
| FSM Team Meta Annual No Trial | `price_1TJvDwJnc2Yr4yxF8DIwYyi3` | year | $600 | — | `product_type=fsm_team` |
| ~~FSM Team Annual Free Trial~~ *(archived)* | `price_1T1UpRJnc2Yr4yxFYiUOUDpq` | year | $600 | 7 | `product_type=fsm_team` |

### FSM Business — `prod_TzTsjKNZfIbkVy`

`metadata.product_code = tofu.fsm_business`

| Nickname | Price ID | Interval | Amount | Trial days | Metadata |
|---|---|---|---|---|---|
| FSM Business Monthly Free Trial | `price_1T1UuwJnc2Yr4yxFv7gUMzNK` *(default)* | month | $149 | 7 | `product_type=fsm_business` |
| FSM Business Meta Monthly Paid Trial 7d | `price_1TJvDqJnc2Yr4yxFrAmB0PMB` | month | $149 | 7 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Business Meta Monthly Paid Trial 14d | `price_1TJvDtJnc2Yr4yxFjA2g0YOa` | month | $149 | 14 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Business Meta Monthly No Trial | `price_1TJvDuJnc2Yr4yxF25JRDaVN` | month | $149 | — | `default_coupon_behavior=subscription` |
| FSM Business Meta Annual No Trial | `price_1TJvDyJnc2Yr4yxF4OQ2r83t` | year | $1200 | — | `product_type=fsm_business` |
| ~~FSM Business Annual Free Trial~~ *(archived)* | `price_1T1UviJnc2Yr4yxFVfqaTKUH` | year | $1200 | 7 | `product_type=fsm_business` |
| early access | `price_1TAV5lJnc2Yr4yxF7iPsd9Gv` | month | $0 | — | `product_type=fsm_business` |

### Coupons

| Coupon ID | Name | Amount off | Duration | Redemptions |
|---|---|---|---|---|
| `qC3E7vlV` | first purchase FSM Solo | $10 | repeating, 3 months | 111 |
| `k8t0QKqk` | first purchase FSM Team | $30 | once | 7 |
| `cXuyFLgB` | first purchase FSM Business | $50 | once | 4 |
| `t9T2Ux23` | first purchase Invoicing | $10 | once | 38 |
| `CCMgXCWF` | Month 90% off | $16.20 | once | 129 |

Notes:

- Discount amounts line up with the WEB-1403 intro phases:
  Solo $10 off ($29 → $19), Team $30 off ($79 → $49),
  Business $50 off ($149 → $99).
- `qC3E7vlV` (Solo) is `repeating` for 3 months — matches the Solo
  3-month intro. Team/Business coupons are `duration=once`, which
  discounts only the first invoice — for a monthly plan that is
  effectively a 1-month intro, matching the target plan.
- None of the coupons currently carry metadata; the link between a
  Stripe Price (via `metadata.default_coupon_behavior=subscription`)
  and a coupon is configured backend-side under
  `Subscriptions:Stripe:meta:IntroCoupons`.

## Prod environment inventory

Snapshot of the **Tofu prod** Stripe account (2026-04-08). Only FSM
products are listed below; the legacy Plus / Premium / Invoicing prices
are not relevant to WEB-1403.

### FSM Solo — `prod_Tur9txcpGbDZFA`

`metadata.product_code = tofu.fsm_solo`

| Nickname | Price ID | Interval | Amount | Trial days | Metadata |
|---|---|---|---|---|---|
| FSM Solo Monthly Free Trial | `price_1Sx1R5Jnc2Yr4yxFtTis1auO` *(default)* | month | $29 | 7 | `product_type=fsm_solo` |
| FSM Solo Monthly Paid Trial | `price_1Sx1R5Jnc2Yr4yxFZsBMoNhZ` | month | $29 | 3 | `trial_price=199`, `default_coupon_behavior=subscription` (legacy $1.99 trial, not in WEB-1403 plan) |
| FSM Solo Monthly Paid Trial | `price_1Sx1R5Jnc2Yr4yxFuMdYWpWj` | month | $29 | 7 | `trial_price=199`, `default_coupon_behavior=subscription` (legacy $1.99 trial, superseded by 7d $1 below) |
| FSM Solo Meta Monthly Paid Trial 7d | `price_1TJvz9Jnc2Yr4yxF5QzBUWOB` | month | $29 | 7 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Solo Meta Monthly Paid Trial 14d | `price_1TJvznJnc2Yr4yxFzTEtwBGN` | month | $29 | 14 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Solo Meta Monthly No Trial | `price_1TJw0AJnc2Yr4yxF73z0eCA7` | month | $29 | — | `default_coupon_behavior=subscription` |
| FSM Solo Annual Free Trial | `price_1Sx1R5Jnc2Yr4yxFoJNKBC2z` | year | $180 | 7 | `product_type=fsm_solo` |

### FSM Team — `prod_U2lcEk1EmstDUi`

`metadata.product_code = tofu.fsm_team`

| Nickname | Price ID | Interval | Amount | Trial days | Metadata |
|---|---|---|---|---|---|
| FSM Team Monthly Free Trial | `price_1T4g5NJnc2Yr4yxF3NARgyCy` *(default)* | month | $79 | 7 | `product_type=fsm_team` |
| FSM Team Meta Monthly Paid Trial 7d | `price_1TJw0SJnc2Yr4yxFQdqoeiA1` | month | $79 | 7 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Team Meta Monthly Paid Trial 14d | `price_1TJw0gJnc2Yr4yxFEcIem9kd` | month | $79 | 14 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Team Meta Monthly No Trial | `price_1TJw1FJnc2Yr4yxFSNyvgayq` | month | $79 | — | `default_coupon_behavior=subscription` |
| FSM Team Meta Annual No Trial | `price_1TJw28Jnc2Yr4yxFZLLaPj7T` | year | $600 | — | `product_type=fsm_team` |
| FSM Team Annual Free Trial | `price_1T4g5NJnc2Yr4yxFSpLydhfq` | year | $600 | 7 | `product_type=fsm_team` (superseded by Meta annual above; not yet archived) |

### FSM Business — `prod_U2lceCNatplg8D`

`metadata.product_code = tofu.fsm_business`

| Nickname | Price ID | Interval | Amount | Trial days | Metadata |
|---|---|---|---|---|---|
| FSM Business Monthly Free Trial | `price_1T4g5UJnc2Yr4yxFqNfQTeVZ` *(default)* | month | $149 | 7 | `product_type=fsm_business` |
| FSM Business Meta Monthly Paid Trial 7d | `price_1TJw1RJnc2Yr4yxFpyzEfk6w` | month | $149 | 7 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Business Meta Monthly Paid Trial 14d | `price_1TJw1bJnc2Yr4yxFi3t6QlrO` | month | $149 | 14 | `trial_price=100`, `default_coupon_behavior=subscription` |
| FSM Business Meta Monthly No Trial | `price_1TJw1rJnc2Yr4yxFpC2E4MCW` | month | $149 | — | `default_coupon_behavior=subscription` |
| FSM Business Meta Annual No Trial | `price_1TJw2WJnc2Yr4yxFs5pxHcQu` | year | $1200 | — | `product_type=fsm_business` |
| FSM Business Annual Free Trial | `price_1T4g5TJnc2Yr4yxFSJfXZK9D` | year | $1200 | 7 | `product_type=fsm_business` (superseded by Meta annual above; not yet archived) |
| early access | `price_1TCMIeJnc2Yr4yxFyWOaG4KE` | month | $0 | — | `product_type=fsm_business` |

### Coupons (prod)

| Coupon ID | Name | Amount off | Duration | Redemptions |
|---|---|---|---|---|
| `XTkamoax` | first purchase FSM Solo | $10 | repeating, 3 months | 2870 |
| `aVEpeekL` | first purchase FSM Team | $30 | once | 24 |
| `PF0BBbTl` | first purchase FSM Business | $50 | once | 8 |
| `rUlkPEZB` | first purchase Invoicing | $10 | once | 130 |
| `hRnpHxN5` | Month 90% off | $16.20 | once | 700 |

The three FSM coupons match the WEB-1403 intro phases (Solo
$29→$19 / 3 months, Team $79→$49 / 1 month, Business $149→$99 /
1 month) — no new coupons need to be created on prod.

### Prod status vs WEB-1403 target plans

All target FSM Solo / Team / Business price variants now exist on
prod (see tables above; new prices carry the `Meta` marker in their
nicknames). The legacy Solo 3-day and 7-day $1.99 paid trial prices
remain active but are not part of the WEB-1403 plan. The
trial-bearing Team / Business annual prices
(`price_1T4g5NJnc2Yr4yxFSpLydhfq`, `price_1T4g5TJnc2Yr4yxFSJfXZK9D`)
have been **superseded** by the new no-trial annual prices but have
**not yet been archived** — that is a separate decision pending
verification that no live subscriptions reference them.

### Status vs WEB-1403 target plans

All target FSM Solo / Team / Business price variants now exist on the
test account (see tables above). The trial-bearing annual prices have
been archived and replaced with no-trial variants. The 3-day paid
trial Solo price (`price_1SnfQrJnc2Yr4yxFL3uSXs49`) is not part of the
WEB-1403 plan and remains active for legacy reasons.
