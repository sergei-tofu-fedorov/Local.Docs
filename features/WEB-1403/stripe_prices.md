# Stripe Prices for `meta` Product

**Ticket:** WEB-1403

## Goal

Provision new Stripe prices for the `meta` product so the paid plans
(Solo / Team / Business, monthly and annual) can be sold through the
existing Stripe-based subscription flow.

Each plan ships in three trial variants — **7-day $1**, **14-day $1**,
and **no trial** — so the marketing site can route users into the
correct funnel without changing the underlying base price.

## Current Stripe Products (Prod)

The Stripe Prod account already contains six active products:

| Product       | Existing prices | Created       |
|---------------|-----------------|---------------|
| FSM Solo      | 4               | Feb 4         |
| FSM Team      | 2               | Feb 25        |
| FSM Business  | 3               | Feb 25        |
| Invoicing     | 3               | Feb 4         |
| Plus Plan     | 3               | Mar 28, 2025  |
| Premium Plan  | 13              | Dec 25, 2024  |

The new prices in the table below are to be **added under the existing
`FSM Solo` / `FSM Team` / `FSM Business` products** — no new product
objects are created. Same approach for Staging.

## Plans

### Monthly

| Plan     | Trial          | Intro | Intro Duration | Base | Staging price id | Prod price id |
|----------|----------------|-------|----------------|------|------------------|---------------|
| Solo     | 7 days — $1    | $19   | 3 months @ $19 | $29  | `price_1TJvehJnc2Yr4yxF65ZAaVyg` | `price_1TJvz9Jnc2Yr4yxF5QzBUWOB` |
| Solo     | 14 days — $1   | $19   | 3 months @ $19 | $29  | `price_1TJv0qJnc2Yr4yxFbBbCzFRl` | `price_1TJvznJnc2Yr4yxFzTEtwBGN` |
| Solo     | —              | $19   | 3 months @ $19 | $29  | `price_1TJv0sJnc2Yr4yxFSKR7H4dA` | `price_1TJw0AJnc2Yr4yxF73z0eCA7` |
| Team     | 7 days — $1    | $49   | 1 month @ $49  | $79  | `price_1TJvDkJnc2Yr4yxFyQH7ZrYy` | `price_1TJw0SJnc2Yr4yxFQdqoeiA1` |
| Team     | 14 days — $1   | $49   | 1 month @ $49  | $79  | `price_1TJvDmJnc2Yr4yxFEBDLYzcb` | `price_1TJw0gJnc2Yr4yxFEcIem9kd` |
| Team     | —              | $49   | 1 month @ $49  | $79  | `price_1TJvDoJnc2Yr4yxFqQgq0WwD` | `price_1TJw1FJnc2Yr4yxFSNyvgayq` |
| Business | 7 days — $1    | $99   | 1 month @ $99  | $149 | `price_1TJvDqJnc2Yr4yxFrAmB0PMB` | `price_1TJw1RJnc2Yr4yxFpyzEfk6w` |
| Business | 14 days — $1   | $99   | 1 month @ $99  | $149 | `price_1TJvDtJnc2Yr4yxFjA2g0YOa` | `price_1TJw1bJnc2Yr4yxFi3t6QlrO` |
| Business | —              | $99   | 1 month @ $99  | $149 | `price_1TJvDuJnc2Yr4yxF25JRDaVN` | `price_1TJw1rJnc2Yr4yxFpC2E4MCW` |

### Annual

| Plan     | Trial | Annual                          | Duration | Staging price id | Prod price id |
|----------|-------|---------------------------------|----------|------------------|---------------|
| Team     | —     | $600  (effective $50 / month)   | 1 year   | `price_1TJvDwJnc2Yr4yxF8DIwYyi3` | `price_1TJw28Jnc2Yr4yxFZLLaPj7T` |
| Business | —     | $1200 (effective $100 / month)  | 1 year   | `price_1TJvDyJnc2Yr4yxF4OQ2r83t` | `price_1TJw2WJnc2Yr4yxFs5pxHcQu` |

## Stripe Configuration Rules

How each column maps onto a Stripe Price:

### `Base`

The monthly (or annual) renewal price. This is the recurring amount
charged after the trial and intro phases finish. It is configured as
the standard `unit_amount` of the Stripe Price.

### `Trial`

Configured via Stripe's legacy `trial_period_days` field on the Price
(e.g. `7` or `14`). Plans with no trial leave the field unset.

When the trial itself is **paid** (the marketing-side $1 charge),
add metadata to the Price so the backend can charge the trial amount:

```
metadata.trial_price = 100   # cents — e.g. $1.00
```

The backend reads `trial_price` from price metadata and bills it as
the trial-period charge instead of the default $0 trial.

### `Intro`

The intro phase (discounted period after trial / before base) is
delivered as a Stripe **coupon** plus a metadata flag on the Price:

1. Create a coupon in the Stripe Dashboard with the discounted amount
   and the intro duration (e.g. 3 months for Solo, 1 month for Team
   and Business).
2. Reference that coupon from backend code (the existing
   `Subscriptions:Stripe:meta` configuration block).
3. On the Stripe Price itself, add metadata so the subscription flow
   knows to apply the coupon automatically:

```
metadata.default_coupon_behavior = subscription
```

When the backend sees `default_coupon_behavior=subscription` on the
selected Price, it attaches the configured coupon to the new
subscription so the intro discount runs for the coupon's duration,
then rolls over to the `Base` price.

## Notes

- Prices are configured in the Stripe Dashboard; the backend only
  references them by id via `Subscriptions:Stripe:meta`.
- The `Intro` column is the discounted phase that runs immediately
  after the trial (or immediately for the no-trial variants); after
  the intro period, billing rolls over to the `Base` price.
- Annual plans currently have **no trial** and **no intro phase** —
  the listed price is the renewal price for the full year.
- Staging and prod price ids are filled in once the prices are created
  in the corresponding Stripe accounts.

## Test environment — prices to create

Snapshot of the Stripe **test** account (2026-04-08) is in
`Backend/Domain/plans-stripe.md` → *Test environment inventory*. The
existing FSM products and their relevant ids:

| Product       | Stripe product id        | `metadata.product_code` |
|---------------|--------------------------|-------------------------|
| FSM Solo      | `prod_TlBXAiOqAYuLzv`    | `tofu.fsm_solo`         |
| FSM Team      | `prod_TzTh0vfFkjRFO3`    | `tofu.fsm_team`         |
| FSM Business  | `prod_TzTsjKNZfIbkVy`    | `tofu.fsm_business`     |

The intro coupons already exist on test and will be wired up via
`Subscriptions:Stripe:meta:IntroCoupons` (no Stripe-side change
needed):

| Plan     | Coupon id    | Discount  | Duration              |
|----------|--------------|-----------|-----------------------|
| Solo     | `qC3E7vlV`   | $10 off   | repeating, 3 months   |
| Team     | `k8t0QKqk`   | $30 off   | once (= 1 month)      |
| Business | `cXuyFLgB`   | $50 off   | once (= 1 month)      |

### Prices to create

Below are the `POST /v1/prices` calls that need to run against the
test account to fill the gaps identified above. All amounts are in
USD cents. Replace `$STRIPE_TEST_KEY` with the test secret key.

Common conventions:

- Paid-trial variants set `trial_period_days`, `metadata[trial_price]=199`
  (i.e. $1.99) and `metadata[default_coupon_behavior]=subscription`.
- No-trial variants omit `trial_period_days` but still carry
  `metadata[default_coupon_behavior]=subscription` so the intro coupon
  is attached at subscription creation.
- All include `metadata[product_type]` to match the existing nicknames.

#### FSM Solo (`prod_TlBXAiOqAYuLzv`)

Solo monthly base $29 / intro $19 (3 months via coupon `qC3E7vlV`).
Existing: 7-day free trial, 7-day $1 paid trial, 3-day $1 paid trial,
annual. Missing variants:

```bash
# Solo monthly — 14-day $1 paid trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_TEST_KEY:" \
  -d product=prod_TlBXAiOqAYuLzv \
  -d nickname="FSM Solo Monthly Paid Trial 14d" \
  -d currency=usd \
  -d unit_amount=2900 \
  -d "recurring[interval]=month" \
  -d "recurring[trial_period_days]=14" \
  -d "metadata[product_type]=fsm_solo" \
  -d "metadata[trial_price]=100" \
  -d "metadata[default_coupon_behavior]=subscription"

# Solo monthly — no trial (intro only)
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_TEST_KEY:" \
  -d product=prod_TlBXAiOqAYuLzv \
  -d nickname="FSM Solo Monthly No Trial" \
  -d currency=usd \
  -d unit_amount=2900 \
  -d "recurring[interval]=month" \
  -d "metadata[product_type]=fsm_solo" \
  -d "metadata[default_coupon_behavior]=subscription"
```

#### FSM Team (`prod_TzTh0vfFkjRFO3`)

Team monthly base $79 / intro $49 (1 month via coupon `k8t0QKqk`).
Existing: 7-day free trial, annual. Missing variants:

```bash
# Team monthly — 7-day $1 paid trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_TEST_KEY:" \
  -d product=prod_TzTh0vfFkjRFO3 \
  -d nickname="FSM Team Monthly Paid Trial 7d" \
  -d currency=usd \
  -d unit_amount=7900 \
  -d "recurring[interval]=month" \
  -d "recurring[trial_period_days]=7" \
  -d "metadata[product_type]=fsm_team" \
  -d "metadata[trial_price]=100" \
  -d "metadata[default_coupon_behavior]=subscription"

# Team monthly — 14-day $1 paid trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_TEST_KEY:" \
  -d product=prod_TzTh0vfFkjRFO3 \
  -d nickname="FSM Team Monthly Paid Trial 14d" \
  -d currency=usd \
  -d unit_amount=7900 \
  -d "recurring[interval]=month" \
  -d "recurring[trial_period_days]=14" \
  -d "metadata[product_type]=fsm_team" \
  -d "metadata[trial_price]=100" \
  -d "metadata[default_coupon_behavior]=subscription"

# Team monthly — no trial (intro only)
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_TEST_KEY:" \
  -d product=prod_TzTh0vfFkjRFO3 \
  -d nickname="FSM Team Monthly No Trial" \
  -d currency=usd \
  -d unit_amount=7900 \
  -d "recurring[interval]=month" \
  -d "metadata[product_type]=fsm_team" \
  -d "metadata[default_coupon_behavior]=subscription"
```

#### FSM Business (`prod_TzTsjKNZfIbkVy`)

Business monthly base $149 / intro $99 (1 month via coupon `cXuyFLgB`).
Existing: 7-day free trial, annual, $0 *early access*. Missing variants:

```bash
# Business monthly — 7-day $1 paid trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_TEST_KEY:" \
  -d product=prod_TzTsjKNZfIbkVy \
  -d nickname="FSM Business Monthly Paid Trial 7d" \
  -d currency=usd \
  -d unit_amount=14900 \
  -d "recurring[interval]=month" \
  -d "recurring[trial_period_days]=7" \
  -d "metadata[product_type]=fsm_business" \
  -d "metadata[trial_price]=100" \
  -d "metadata[default_coupon_behavior]=subscription"

# Business monthly — 14-day $1 paid trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_TEST_KEY:" \
  -d product=prod_TzTsjKNZfIbkVy \
  -d nickname="FSM Business Monthly Paid Trial 14d" \
  -d currency=usd \
  -d unit_amount=14900 \
  -d "recurring[interval]=month" \
  -d "recurring[trial_period_days]=14" \
  -d "metadata[product_type]=fsm_business" \
  -d "metadata[trial_price]=100" \
  -d "metadata[default_coupon_behavior]=subscription"

# Business monthly — no trial (intro only)
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_TEST_KEY:" \
  -d product=prod_TzTsjKNZfIbkVy \
  -d nickname="FSM Business Monthly No Trial" \
  -d currency=usd \
  -d unit_amount=14900 \
  -d "recurring[interval]=month" \
  -d "metadata[product_type]=fsm_business" \
  -d "metadata[default_coupon_behavior]=subscription"
```

### Annual prices — recreate without trial

The existing Team annual (`price_1T1UpRJnc2Yr4yxFYiUOUDpq`, $600) and
Business annual (`price_1T1UviJnc2Yr4yxFVfqaTKUH`, $1200) carry
`trial_period_days=7`, which conflicts with the **no trial** rule for
annual plans. Recreate them without `trial_period_days` and archive
the originals (Stripe prices are immutable on price-affecting fields).

```bash
# Team annual — no trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_TEST_KEY:" \
  -d product=prod_TzTh0vfFkjRFO3 \
  -d nickname="FSM Team Annual No Trial" \
  -d currency=usd \
  -d unit_amount=60000 \
  -d "recurring[interval]=year" \
  -d "metadata[product_type]=fsm_team"

# Business annual — no trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_TEST_KEY:" \
  -d product=prod_TzTsjKNZfIbkVy \
  -d nickname="FSM Business Annual No Trial" \
  -d currency=usd \
  -d unit_amount=120000 \
  -d "recurring[interval]=year" \
  -d "metadata[product_type]=fsm_business"
```

Then archive the trial-bearing originals:

```bash
curl https://api.stripe.com/v1/prices/price_1T1UpRJnc2Yr4yxFYiUOUDpq \
  -u "$STRIPE_TEST_KEY:" -d active=false

curl https://api.stripe.com/v1/prices/price_1T1UviJnc2Yr4yxFVfqaTKUH \
  -u "$STRIPE_TEST_KEY:" -d active=false
```

Notes:

- No `default_coupon_behavior` metadata — annual plans have no intro
  phase.
- Confirm the existing $600 / $1200 prices are not referenced by any
  live test subscriptions before archiving (archiving leaves existing
  subscriptions intact but blocks new ones).

### `WebCheckout:PriceConfigs` — test environment

The new prices need to be registered under `WebCheckout.PriceConfigs`
in the test/stage `appsettings.json` so `WebCheckoutStripeService` can
find them (it indexes the dictionary directly and throws on miss). See
`Backend/Domain/plans-stripe.md` → *Web checkout `PriceConfigs`* for
the field reference.

Intro coupon ids (already exist on test):

| Plan     | Coupon id    | Discount |
|----------|--------------|----------|
| Solo     | `qC3E7vlV`   | $10 off, repeating 3 months |
| Team     | `k8t0QKqk`   | $30 off, once (= 1 month)   |
| Business | `cXuyFLgB`   | $50 off, once (= 1 month)   |

Drop-in snippet to merge into the existing `WebCheckout.PriceConfigs`
(only the new entries created for WEB-1403; existing free-trial
prices already have their own entries):

```json
"WebCheckout": {
  "PriceConfigs": {
    "price_1TJvehJnc2Yr4yxF65ZAaVyg": {
      "CouponId": "qC3E7vlV",
      "TrialPeriodDays": 7,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJv0qJnc2Yr4yxFbBbCzFRl": {
      "CouponId": "qC3E7vlV",
      "TrialPeriodDays": 14,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJv0sJnc2Yr4yxFSKR7H4dA": {
      "CouponId": "qC3E7vlV",
      "IsTofu": true
    },
    "price_1TJvDkJnc2Yr4yxFyQH7ZrYy": {
      "CouponId": "k8t0QKqk",
      "TrialPeriodDays": 7,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJvDmJnc2Yr4yxFEBDLYzcb": {
      "CouponId": "k8t0QKqk",
      "TrialPeriodDays": 14,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJvDoJnc2Yr4yxFqQgq0WwD": {
      "CouponId": "k8t0QKqk",
      "IsTofu": true
    },
    "price_1TJvDqJnc2Yr4yxFrAmB0PMB": {
      "CouponId": "cXuyFLgB",
      "TrialPeriodDays": 7,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJvDtJnc2Yr4yxFjA2g0YOa": {
      "CouponId": "cXuyFLgB",
      "TrialPeriodDays": 14,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJvDuJnc2Yr4yxF25JRDaVN": {
      "CouponId": "cXuyFLgB",
      "IsTofu": true
    },
    "price_1TJvDwJnc2Yr4yxF8DIwYyi3": {
      "IsTofu": true
    },
    "price_1TJvDyJnc2Yr4yxF4OQ2r83t": {
      "IsTofu": true
    }
  }
}
```

Notes:

- `IsTofu: true` because all FSM products live in the Tofu Stripe
  account (`product_code = tofu.fsm_*`).
- Annual entries have neither coupon nor trial — plain recurring.
- The Solo intro coupon `qC3E7vlV` is `repeating, 3 months`; the Team
  and Business coupons are `once`, which discounts only the first
  monthly invoice — matching the 1-month intro phase from the plan.
- The archived Team/Business annual prices
  (`price_1T1UpRJnc2Yr4yxFYiUOUDpq`, `price_1T1UviJnc2Yr4yxFVfqaTKUH`)
  should be removed from `PriceConfigs` once nothing references them.

## Prod environment — prices to create

Snapshot of the Tofu **prod** Stripe account is in
`Backend/Domain/plans-stripe.md` → *Prod environment inventory*. The
existing FSM products and intro coupons:

| Product       | Stripe product id        | `metadata.product_code` |
|---------------|--------------------------|-------------------------|
| FSM Solo      | `prod_Tur9txcpGbDZFA`    | `tofu.fsm_solo`         |
| FSM Team      | `prod_U2lcEk1EmstDUi`    | `tofu.fsm_team`         |
| FSM Business  | `prod_U2lceCNatplg8D`    | `tofu.fsm_business`     |

| Plan     | Coupon id   | Discount  | Duration              |
|----------|-------------|-----------|-----------------------|
| Solo     | `XTkamoax`  | $10 off   | repeating, 3 months   |
| Team     | `aVEpeekL`  | $30 off   | once (= 1 month)      |
| Business | `PF0BBbTl`  | $50 off   | once (= 1 month)      |

> ⚠️ The commands below are **drafts only** — do not run them
> automatically. They must be executed manually with the prod secret
> key after a final review of the plan, and each new price id must be
> recorded in `Backend/Domain/plans-stripe.md` and in the plan tables
> above.

Same conventions as the test environment:

- Paid-trial variants set `trial_period_days`,
  `metadata[trial_price]=100` ($1.00) and
  `metadata[default_coupon_behavior]=subscription`.
- No-trial variants omit `trial_period_days` but still carry
  `metadata[default_coupon_behavior]=subscription` (for monthly intro)
  or no coupon flag at all (for annual).
- All carry `metadata[product_type]` and a `Meta`-marked nickname so
  prod prices line up with the test naming.

#### FSM Solo (`prod_Tur9txcpGbDZFA`)

Solo monthly base $29 / intro $19 (3 months via coupon `XTkamoax`).

```bash
# Solo monthly — 7-day $1 paid trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_LIVE_KEY:" \
  -d product=prod_Tur9txcpGbDZFA \
  -d nickname="FSM Solo Meta Monthly Paid Trial 7d" \
  -d currency=usd \
  -d unit_amount=2900 \
  -d "recurring[interval]=month" \
  -d "recurring[trial_period_days]=7" \
  -d "metadata[product_type]=fsm_solo" \
  -d "metadata[trial_price]=100" \
  -d "metadata[default_coupon_behavior]=subscription"

# Solo monthly — 14-day $1 paid trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_LIVE_KEY:" \
  -d product=prod_Tur9txcpGbDZFA \
  -d nickname="FSM Solo Meta Monthly Paid Trial 14d" \
  -d currency=usd \
  -d unit_amount=2900 \
  -d "recurring[interval]=month" \
  -d "recurring[trial_period_days]=14" \
  -d "metadata[product_type]=fsm_solo" \
  -d "metadata[trial_price]=100" \
  -d "metadata[default_coupon_behavior]=subscription"

# Solo monthly — no trial (intro only)
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_LIVE_KEY:" \
  -d product=prod_Tur9txcpGbDZFA \
  -d nickname="FSM Solo Meta Monthly No Trial" \
  -d currency=usd \
  -d unit_amount=2900 \
  -d "recurring[interval]=month" \
  -d "metadata[product_type]=fsm_solo" \
  -d "metadata[default_coupon_behavior]=subscription"
```

#### FSM Team (`prod_U2lcEk1EmstDUi`)

Team monthly base $79 / intro $49 (1 month via coupon `aVEpeekL`).

```bash
# Team monthly — 7-day $1 paid trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_LIVE_KEY:" \
  -d product=prod_U2lcEk1EmstDUi \
  -d nickname="FSM Team Meta Monthly Paid Trial 7d" \
  -d currency=usd \
  -d unit_amount=7900 \
  -d "recurring[interval]=month" \
  -d "recurring[trial_period_days]=7" \
  -d "metadata[product_type]=fsm_team" \
  -d "metadata[trial_price]=100" \
  -d "metadata[default_coupon_behavior]=subscription"

# Team monthly — 14-day $1 paid trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_LIVE_KEY:" \
  -d product=prod_U2lcEk1EmstDUi \
  -d nickname="FSM Team Meta Monthly Paid Trial 14d" \
  -d currency=usd \
  -d unit_amount=7900 \
  -d "recurring[interval]=month" \
  -d "recurring[trial_period_days]=14" \
  -d "metadata[product_type]=fsm_team" \
  -d "metadata[trial_price]=100" \
  -d "metadata[default_coupon_behavior]=subscription"

# Team monthly — no trial (intro only)
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_LIVE_KEY:" \
  -d product=prod_U2lcEk1EmstDUi \
  -d nickname="FSM Team Meta Monthly No Trial" \
  -d currency=usd \
  -d unit_amount=7900 \
  -d "recurring[interval]=month" \
  -d "metadata[product_type]=fsm_team" \
  -d "metadata[default_coupon_behavior]=subscription"
```

#### FSM Business (`prod_U2lceCNatplg8D`)

Business monthly base $149 / intro $99 (1 month via coupon `PF0BBbTl`).

```bash
# Business monthly — 7-day $1 paid trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_LIVE_KEY:" \
  -d product=prod_U2lceCNatplg8D \
  -d nickname="FSM Business Meta Monthly Paid Trial 7d" \
  -d currency=usd \
  -d unit_amount=14900 \
  -d "recurring[interval]=month" \
  -d "recurring[trial_period_days]=7" \
  -d "metadata[product_type]=fsm_business" \
  -d "metadata[trial_price]=100" \
  -d "metadata[default_coupon_behavior]=subscription"

# Business monthly — 14-day $1 paid trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_LIVE_KEY:" \
  -d product=prod_U2lceCNatplg8D \
  -d nickname="FSM Business Meta Monthly Paid Trial 14d" \
  -d currency=usd \
  -d unit_amount=14900 \
  -d "recurring[interval]=month" \
  -d "recurring[trial_period_days]=14" \
  -d "metadata[product_type]=fsm_business" \
  -d "metadata[trial_price]=100" \
  -d "metadata[default_coupon_behavior]=subscription"

# Business monthly — no trial (intro only)
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_LIVE_KEY:" \
  -d product=prod_U2lceCNatplg8D \
  -d nickname="FSM Business Meta Monthly No Trial" \
  -d currency=usd \
  -d unit_amount=14900 \
  -d "recurring[interval]=month" \
  -d "metadata[product_type]=fsm_business" \
  -d "metadata[default_coupon_behavior]=subscription"
```

#### Annual — recreate without trial

Existing prod annual prices carry `trial_period_days=7`, which
conflicts with the no-trial annual rule. Recreate without
`trial_period_days` and archive the originals.

```bash
# Team annual — no trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_LIVE_KEY:" \
  -d product=prod_U2lcEk1EmstDUi \
  -d nickname="FSM Team Meta Annual No Trial" \
  -d currency=usd \
  -d unit_amount=60000 \
  -d "recurring[interval]=year" \
  -d "metadata[product_type]=fsm_team"

# Business annual — no trial
curl https://api.stripe.com/v1/prices \
  -u "$STRIPE_LIVE_KEY:" \
  -d product=prod_U2lceCNatplg8D \
  -d nickname="FSM Business Meta Annual No Trial" \
  -d currency=usd \
  -d unit_amount=120000 \
  -d "recurring[interval]=year" \
  -d "metadata[product_type]=fsm_business"
```

Then archive the originals **only after** confirming no live prod
subscriptions reference them (archiving leaves existing subscriptions
intact but blocks new ones):

```bash
curl https://api.stripe.com/v1/prices/price_1T4g5NJnc2Yr4yxFSpLydhfq \
  -u "$STRIPE_LIVE_KEY:" -d active=false   # FSM Team Annual Free Trial

curl https://api.stripe.com/v1/prices/price_1T4g5TJnc2Yr4yxFSJfXZK9D \
  -u "$STRIPE_LIVE_KEY:" -d active=false   # FSM Business Annual Free Trial
```

### Prod `WebCheckout:PriceConfigs`

```json
"WebCheckout": {
  "PriceConfigs": {
    "price_1TJvz9Jnc2Yr4yxF5QzBUWOB": {
      "CouponId": "XTkamoax",
      "TrialPeriodDays": 7,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJvznJnc2Yr4yxFzTEtwBGN": {
      "CouponId": "XTkamoax",
      "TrialPeriodDays": 14,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJw0AJnc2Yr4yxF73z0eCA7": {
      "CouponId": "XTkamoax",
      "IsTofu": true
    },
    "price_1TJw0SJnc2Yr4yxFQdqoeiA1": {
      "CouponId": "aVEpeekL",
      "TrialPeriodDays": 7,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJw0gJnc2Yr4yxFEcIem9kd": {
      "CouponId": "aVEpeekL",
      "TrialPeriodDays": 14,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJw1FJnc2Yr4yxFSNyvgayq": {
      "CouponId": "aVEpeekL",
      "IsTofu": true
    },
    "price_1TJw1RJnc2Yr4yxFpyzEfk6w": {
      "CouponId": "PF0BBbTl",
      "TrialPeriodDays": 7,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJw1bJnc2Yr4yxFi3t6QlrO": {
      "CouponId": "PF0BBbTl",
      "TrialPeriodDays": 14,
      "TrialPrice": 1.00,
      "IsTofu": true
    },
    "price_1TJw1rJnc2Yr4yxFpC2E4MCW": {
      "CouponId": "PF0BBbTl",
      "IsTofu": true
    },
    "price_1TJw28Jnc2Yr4yxFZLLaPj7T": {
      "IsTofu": true
    },
    "price_1TJw2WJnc2Yr4yxFs5pxHcQu": {
      "IsTofu": true
    }
  }
}
```

The trial-bearing Team / Business annual prices
(`price_1T4g5NJnc2Yr4yxFSpLydhfq`, `price_1T4g5TJnc2Yr4yxFSJfXZK9D`)
have **not** been archived — they remain active on prod and should be
removed from `PriceConfigs` only after live subscriptions are
confirmed clear.

## NonUpgradeable Meta plans

All new `meta` prices created in this ticket must be added to
`Subscriptions:Stripe:meta:NonUpgradeablePlans`. The Stripe-portal
upgrade flow (`PlanUpgradeService` →
`subscription-update-link`) is **not** the upgrade path for `meta` /
FSM plans — these go through the web checkout flow. Listing every
new price here prevents `PlanUpgradeService` from offering any
in-portal upgrade target between Solo / Team / Business or surfacing
them as upgrades to existing tofu subscribers.

The match is by `OriginOfferId` (the Stripe price id),
case-insensitively (see `PlanUpgradeService.GetAvailableUpgradesAsync`,
`Src/Invoices.Implementation.Services/Plans/PlanUpgradeService.cs:173`).

Adding the `meta` entry to `Subscriptions:Stripe` is itself tracked
separately (see *Out of Scope*); the snippets below assume that
entry exists.

### Test (`appsettings.Development.json`)

```json
"Subscriptions": {
  "Stripe": {
    "meta": {
      "NonUpgradeablePlans": [
        "price_1TJvehJnc2Yr4yxF65ZAaVyg",
        "price_1TJv0qJnc2Yr4yxFbBbCzFRl",
        "price_1TJv0sJnc2Yr4yxFSKR7H4dA",
        "price_1TJvDkJnc2Yr4yxFyQH7ZrYy",
        "price_1TJvDmJnc2Yr4yxFEBDLYzcb",
        "price_1TJvDoJnc2Yr4yxFqQgq0WwD",
        "price_1TJvDqJnc2Yr4yxFrAmB0PMB",
        "price_1TJvDtJnc2Yr4yxFjA2g0YOa",
        "price_1TJvDuJnc2Yr4yxF25JRDaVN",
        "price_1TJvDwJnc2Yr4yxF8DIwYyi3",
        "price_1TJvDyJnc2Yr4yxF4OQ2r83t"
      ]
    }
  }
}
```

| Plan                          | Price id                          |
|-------------------------------|-----------------------------------|
| FSM Solo monthly 7d $1 trial  | `price_1TJvehJnc2Yr4yxF65ZAaVyg`  |
| FSM Solo monthly 14d $1 trial | `price_1TJv0qJnc2Yr4yxFbBbCzFRl`  |
| FSM Solo monthly no trial     | `price_1TJv0sJnc2Yr4yxFSKR7H4dA`  |
| FSM Team monthly 7d $1 trial  | `price_1TJvDkJnc2Yr4yxFyQH7ZrYy`  |
| FSM Team monthly 14d $1 trial | `price_1TJvDmJnc2Yr4yxFEBDLYzcb`  |
| FSM Team monthly no trial     | `price_1TJvDoJnc2Yr4yxFqQgq0WwD`  |
| FSM Business monthly 7d $1 trial  | `price_1TJvDqJnc2Yr4yxFrAmB0PMB` |
| FSM Business monthly 14d $1 trial | `price_1TJvDtJnc2Yr4yxFjA2g0YOa` |
| FSM Business monthly no trial     | `price_1TJvDuJnc2Yr4yxF25JRDaVN` |
| FSM Team annual               | `price_1TJvDwJnc2Yr4yxF8DIwYyi3`  |
| FSM Business annual           | `price_1TJvDyJnc2Yr4yxF4OQ2r83t`  |

### Prod (`appsettings.json`)

```json
"Subscriptions": {
  "Stripe": {
    "meta": {
      "NonUpgradeablePlans": [
        "price_1TJvz9Jnc2Yr4yxF5QzBUWOB",
        "price_1TJvznJnc2Yr4yxFzTEtwBGN",
        "price_1TJw0AJnc2Yr4yxF73z0eCA7",
        "price_1TJw0SJnc2Yr4yxFQdqoeiA1",
        "price_1TJw0gJnc2Yr4yxFEcIem9kd",
        "price_1TJw1FJnc2Yr4yxFSNyvgayq",
        "price_1TJw1RJnc2Yr4yxFpyzEfk6w",
        "price_1TJw1bJnc2Yr4yxFi3t6QlrO",
        "price_1TJw1rJnc2Yr4yxFpC2E4MCW",
        "price_1TJw28Jnc2Yr4yxFZLLaPj7T",
        "price_1TJw2WJnc2Yr4yxFs5pxHcQu"
      ]
    }
  }
}
```

| Plan                          | Price id                          |
|-------------------------------|-----------------------------------|
| FSM Solo monthly 7d $1 trial  | `price_1TJvz9Jnc2Yr4yxF5QzBUWOB`  |
| FSM Solo monthly 14d $1 trial | `price_1TJvznJnc2Yr4yxFzTEtwBGN`  |
| FSM Solo monthly no trial     | `price_1TJw0AJnc2Yr4yxF73z0eCA7`  |
| FSM Team monthly 7d $1 trial  | `price_1TJw0SJnc2Yr4yxFQdqoeiA1`  |
| FSM Team monthly 14d $1 trial | `price_1TJw0gJnc2Yr4yxFEcIem9kd`  |
| FSM Team monthly no trial     | `price_1TJw1FJnc2Yr4yxFSNyvgayq`  |
| FSM Business monthly 7d $1 trial  | `price_1TJw1RJnc2Yr4yxFpyzEfk6w` |
| FSM Business monthly 14d $1 trial | `price_1TJw1bJnc2Yr4yxFi3t6QlrO` |
| FSM Business monthly no trial     | `price_1TJw1rJnc2Yr4yxFpC2E4MCW` |
| FSM Team annual               | `price_1TJw28Jnc2Yr4yxFZLLaPj7T`  |
| FSM Business annual           | `price_1TJw2WJnc2Yr4yxFs5pxHcQu`  |

Notes:

- The legacy trial-bearing Team / Business annual prices
  (`price_1T1UpRJnc2Yr4yxFYiUOUDpq`, `price_1T1UviJnc2Yr4yxFVfqaTKUH`
  on test; `price_1T4g5NJnc2Yr4yxFSpLydhfq`,
  `price_1T4g5TJnc2Yr4yxFSJfXZK9D` on prod) should also be added to
  `NonUpgradeablePlans` while live subscriptions still reference
  them, then dropped along with the prices once they are archived.

## Out of Scope

- Backend code changes — adding the `meta` product to
  `SubscriptionsOptions.Stripe` is tracked separately.
- Marketing site / paywall changes.
- Migration of existing subscribers between plans.
