# Product Prices Catalog

Flat catalog of every subscription product/price we sell across iOS, Android,
Stripe web and Field Service. **Mirrors the Google Doc used as the BQ
subscription-products reference** — keep the column order and `app_name`
values identical so it can be diffed/copied against the BQ source.

The `tofu_web` (Stripe) rows were reconciled against the live Stripe price list
(prod snapshot, 2026-06-08). For the richer per-price metadata (intro coupons,
`product_type` resolution, archived ids) see [`plans-stripe.md`](plans-stripe.md)
and [`Services/Invoices.Backend/SubscriptionProductIds.md`](../Services/Invoices.Backend/SubscriptionProductIds.md).

## Columns

| Column | Meaning |
|--------|---------|
| `app_name` | Source app / channel: `invoices` (iOS), `invoices_android` (Android), `tofu_web` (Stripe web), `field_service` (FSM store products). |
| `product_id` | Store product id (Apple/Google) or Stripe product/price identifier (`...prod_X.price_Y`). |
| `sub_length` | Subscription period in days (7 = weekly, 31 = monthly, 365 = annual). |
| `trial_period` | Trial length in days (0 = no trial). |
| `sub_price` | Base recurring price (USD). Blank = not yet recorded. |
| `trial_price` | Amount charged during the trial (USD); 0 = free trial; blank = no trial. |

The live Stripe payload also carries `pricePerWeek`, `seatCount` (all 1 here),
`currency` (`usd`) and `metadata` — not part of the BQ schema, so dropped.

## Catalog

| app_name | product_id | sub_length | trial_period | sub_price | trial_price |
|---|---|---|---|---|---|
| invoices | com.getpaidapp.invoices.unlimited_monthly | 31 | 0 | | |
| invoices | com.getpaidapp.invoices.unlimited_annual | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.unlimited_weekyl | 7 | 3 | | |
| invoices | com.getpaidapp.invoices.pro_weekly | 7 | 3 | | |
| invoices | com.getpaidapp.invoices.pro_monthly | 31 | 0 | | |
| invoices | com.getpaidapp.invoices.pro_annual | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.premium_weekly | 7 | 3 | | |
| invoices | com.getpaidapp.invoices.premium_monthly | 31 | 0 | | |
| invoices | com.getpaidapp.invoices.premium_annual | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.pro14.99_monthly | 31 | 3 | | |
| invoices | com.getpaidapp.invoices.pro99.99_annual | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.premium_annual_trial | 365 | 3 | | |
| invoices | com.getpaidapp.invoices.premium_monthly_new | 31 | 0 | | |
| invoices_android | com.getpaidapp.android.invoices.premium:week | 7 | 3 | | |
| invoices_android | com.getpaidapp.android.invoices.premium:month | 31 | 0 | | |
| invoices | com.getpaidapp.invoices.premium_annual_trial_7 | 365 | 0 | | |
| invoices_android | com.getpaidapp.android.invoices.premium:year | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.premium_weekly_no_trial | 7 | 0 | | |
| invoices_android | com.getpaidapp.android.invoices.pro:week | 7 | 3 | | |
| invoices_android | com.getpaidapp.android.invoices.pro:month | 31 | 0 | | |
| invoices_android | com.getpaidapp.android.invoices.pro:year | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.premium_plan_weekly | 7 | 3 | | |
| invoices | com.getpaidapp.invoices.premium_plan_monthly | 31 | 0 | | |
| tofu_web | tofu.weekly.prod_RSsJ6xTIcLRqoy | 7 | 7 | | |
| tofu_web | tofu.1weekly.prod_RSsJ6xTIcLRqoy | 7 | 7 | | |
| invoices | com.getpaidapp.invoices.month_premium | 31 | 0 | | |
| invoices | com.getpaidapp.invoices.year_premium | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.pro_annual_premium | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.pro179.99_annual_premium | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.unlimited_monthly_premium | 31 | 0 | | |
| tofu_web | tofu.1monthly.prod_RSsJ6xTIcLRqoy | 31 | 7 | | |
| tofu_web | tofu.1yearly.prod_RSsJ6xTIcLRqoy | 365 | 14 | | |
| invoices | com.getpaidapp.invoices.pro17.99_monthly_premium | 31 | 0 | | |
| invoices | com.getpaidapp.invoices.unlimited_annual_premium | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.pro_monthly_premium | 31 | 0 | | |
| invoices | invoices.1monthly.pri_01jnk16mc34bbr84d0y9cgnarj | 31 | 0 | | |
| invoices | invoices.1weekly.pri_01jnk15k4r45s4qn2vr5j4w9md | 7 | 0 | | |
| tofu_web | tofu.1yearly.prod_S1ij0BqbWrxLjC | 365 | 14 | | |
| invoices | com.getpaidapp.invoices.plus_weekly_trial | 7 | 3 | | |
| invoices | com.getpaidapp.invoices.plus_weekly_no_trial | 7 | 0 | | |
| tofu_web | invoices.1yearly.pri_01jnk14nm2q2vp5g4pzvwxb5j0 | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.month_premium_trial | 31 | 3 | | |
| tofu_web | tofu.1monthly.prod_RSsJ6xTIcLRqoy.price_1QZwZ6Jnc2Yr4yxF11AWy527 | 31 | 7 | 17.99 | 0 |
| tofu_web | tofu.1monthly.prod_RSsJ6xTIcLRqoy.price_1RbKCUJnc2Yr4yxF9agFfOJ8 | 31 | 0 | 17.99 | |
| tofu_web | tofu.1weekly.prod_RSsJ6xTIcLRqoy.price_1QZwZ6Jnc2Yr4yxFw2rCetyZ | 7 | 0 | 5.99 | |
| tofu_web | tofu.1monthly.prod_RSsJ6xTIcLRqoy.price_1RnytVJnc2Yr4yxFFveN5o6q | 31 | 3 | 17.99 | 1.79 |
| tofu_web | tofu.1yearly.prod_RSsJ6xTIcLRqoy.price_1QZwZ6Jnc2Yr4yxF50ZxBUEL | 365 | 14 | 179.99 | 0 |
| tofu_web | tofu.1yearly.prod_S1ij0BqbWrxLjC.price_1R7fHyJnc2Yr4yxFv0fIHMcX | 365 | 14 | 99.99 | 0 |
| tofu_web | tofu.1monthly.prod_RSsJ6xTIcLRqoy.price_1RyAAQJnc2Yr4yxFPFgCrDpn | 31 | 3 | 19 | 1.99 |
| tofu_web | tofu.1weekly.prod_RSsJ6xTIcLRqoy.price_1RyvEiJnc2Yr4yxFq5nqLAdi | 7 | 0 | 9 | 0 |
| tofu_web | tofu.1yearly.prod_RSsJ6xTIcLRqoy.price_1RyvCwJnc2Yr4yxFnS2XaFId | 365 | 0 | 99 | 0 |
| tofu_web | tofu.1yearly.prod_RSsJ6xTIcLRqoy.price_1Ryv4kJnc2Yr4yxFxqe381rG | 365 | 14 | 156 | 0 |
| tofu_web | tofu.1monthly.prod_RSsJ6xTIcLRqoy.price_1RyA9xJnc2Yr4yxFTMTO1aJZ | 31 | 7 | 19 | 0 |
| tofu_web | tofu.1yearly.prod_S1ij0BqbWrxLjC.price_1S0znRJnc2Yr4yxFFLKNYTOm | 365 | 14 | 99 | 0 |
| tofu_web | tofu.1monthly.prod_RSsJ6xTIcLRqoy.price_1SInkDJnc2Yr4yxFEdOhYbHW | 31 | 7 | 19 | 4.99 |
| tofu_web | tofu.1weekly.prod_S1ij0BqbWrxLjC.price_1S0znhJnc2Yr4yxFgeXpGNFz | 7 | 0 | 9 | |
| invoices | com.getpaidapp.invoices.weekly_plus_no_trial | 7 | 0 | 7.99 | 0 |
| invoices | com.getpaidapp.invoices.weekly_plus_trial | 7 | 3 | 7.99 | 0 |
| invoices | com.getpaidapp.invoices.premium_plan_weekly_no_trial | 7 | 0 | | 0 |
| invoices | com.getpaidapp.invoices.premium_plan_annual | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.plus_plan_annual | 365 | 0 | | |
| invoices | com.getpaidapp.invoices.week_plus_trial | 7 | 3 | 9.99 | 0 |
| invoices | com.getpaidapp.invoices.week_plus_no_trial | 7 | 0 | 9.99 | 0 |
| field_service | com.getpaidapp.fieldservice.invoicing.weekly.intro499 | 7 | 7 | 9.99 | 4.99 |
| field_service | com.getpaidapp.fieldservice.invoicing.weekly.trial3d | 7 | 3 | 9.99 | 0 |
| field_service | com.getpaidapp.fieldservice.invoicing.yearly.base | 365 | 0 | 139.99 | |
| field_service | com.getpaidapp.fieldservice.solo.monthly.intro19 | 31 | 31 | 29 | 19 |
| field_service | com.getpaidapp.fieldservice.solo.monthly.trial7d | 31 | 7 | 29 | 0 |
| field_service | com.getpaidapp.fieldservice.solo.yearly.base | 365 | 0 | 179.99 | |
| tofu_web | tofu.invoicing.1monthly.prod_TuqwDeiXn9S3xp.price_1Sx1EyJnc2Yr4yxFOsZo1oZC | 31 | 3 | 19 | 0 |
| tofu_web | tofu.fsm_solo.1monthly.prod_Tur9txcpGbDZFA.price_1Sx1R5Jnc2Yr4yxFtTis1auO | 31 | 7 | 29 | 0 |
| tofu_web | tofu.invoicing.1yearly.prod_TuqwDeiXn9S3xp.price_1Sx1EyJnc2Yr4yxFVEFmCcQD | 365 | 3 | 120 | 0 |
| tofu_web | tofu.fsm_solo.1yearly.prod_Tur9txcpGbDZFA.price_1Sx1R5Jnc2Yr4yxFoJNKBC2z | 365 | 7 | 180 | 0 |
| tofu_web | tofu.fsm_solo.1monthly.prod_Tur9txcpGbDZFA.price_1Sx1R5Jnc2Yr4yxFZsBMoNhZ | 31 | 3 | 29 | 1.99 |
| tofu_web | tofu.fsm_solo.1monthly.prod_Tur9txcpGbDZFA.price_1Sx1R5Jnc2Yr4yxFuMdYWpWj | 31 | 7 | 29 | 1.99 |
| tofu_web | tofu.invoicing.1monthly.prod_TuqwDeiXn9S3xp.price_1Sx1EyJnc2Yr4yxFuyKTdisp | 31 | 3 | 19 | 1.99 |
| tofu_web | tofu.fsm_team.1monthly.prod_U2lcEk1EmstDUi.price_1T4g5NJnc2Yr4yxF3NARgyCy | 31 | 7 | 79 | 0 |
| tofu_web | tofu.fsm_team.1yearly.prod_U2lcEk1EmstDUi.price_1T4g5NJnc2Yr4yxFSpLydhfq | 365 | 7 | 600 | 0 |
| tofu_web | tofu.fsm_business.1monthly.prod_U2lceCNatplg8D.price_1T4g5UJnc2Yr4yxFqNfQTeVZ | 31 | 7 | 149 | 0 |
| invoices | tofu | 31 | 3 | 19 | 4.99 |
| invoices | tofu.fsm_solo | | | | |
| invoices | tofu.invoicing | | | | |
| invoices | tofu.fsm_team | | | | |
| tofu_web | tofu.fsm_solo.1monthly.prod_Tur9txcpGbDZFA.price_1TJvz9Jnc2Yr4yxF5QzBUWOB | 31 | 7 | 29 | 1 |
| tofu_web | tofu.fsm_team.1monthly.prod_U2lcEk1EmstDUi.price_1TJw0SJnc2Yr4yxFQdqoeiA1 | 31 | 7 | 79 | 1 |
| tofu_web | tofu.fsm_business.1yearly.prod_U2lceCNatplg8D.price_1T4g5TJnc2Yr4yxFSJfXZK9D | 365 | 7 | 1200 | 0 |
| tofu_web | tofu.fsm_team.1monthly.prod_U2lcEk1EmstDUi.price_1TJw0gJnc2Yr4yxFEcIem9kd | 31 | 14 | 79 | 1 |
| tofu_web | tofu.fsm_solo.1monthly.prod_Tur9txcpGbDZFA.price_1TJvznJnc2Yr4yxFzTEtwBGN | 31 | 14 | 29 | 1 |
| tofu_web | tofu.fsm_business.1monthly.prod_U2lceCNatplg8D.price_1TJw1RJnc2Yr4yxFpyzEfk6w | 31 | 7 | 149 | 1 |
| field_service | com.getpaidapp.fieldservice.team.monthly.trial7d | | | | |
| field_service | com.getpaidapp.fieldservice.team.yearly.base | | | | |
| field_service | com.getpaidapp.fieldservice.business.monthly.trial7d | | | | |
| tofu_web | tofu.1monthly.prod_RSsJ6xTIcLRqoy.price_1Sk1R4Jnc2Yr4yxFXhZXn5Ky | 31 | 0 | 19 | |
| tofu_web | tofu.fsm_solo.1monthly.prod_Tur9txcpGbDZFA.price_1TJw0AJnc2Yr4yxF73z0eCA7 | 31 | 0 | 29 | |
| tofu_web | tofu.fsm_team.1monthly.prod_U2lcEk1EmstDUi.price_1TJw1FJnc2Yr4yxFSNyvgayq | 31 | 0 | 79 | |
| tofu_web | tofu.fsm_team.1yearly.prod_U2lcEk1EmstDUi.price_1TJw28Jnc2Yr4yxFZLLaPj7T | 365 | 0 | 600 | |
| tofu_web | tofu.fsm_business.1monthly.prod_U2lceCNatplg8D.price_1TJw1rJnc2Yr4yxFpC2E4MCW | 31 | 0 | 149 | |
| tofu_web | tofu.fsm_business.1monthly.prod_U2lceCNatplg8D.price_1TJw1bJnc2Yr4yxFi3t6QlrO | 31 | 14 | 149 | 1 |
| tofu_web | tofu.fsm_business.1yearly.prod_U2lceCNatplg8D.price_1TJw2WJnc2Yr4yxFs5pxHcQu | 365 | 0 | 1200 | |
| tofu_web | tofu.fsm_business.1monthly.prod_U2lceCNatplg8D.price_1TCMIeJnc2Yr4yxFyWOaG4KE | 31 | 0 | 0 | |

## Reconciliation vs live Stripe (2026-06-08)

The `tofu_web` rows were checked against the live Stripe price list. All values
were confirmed except for the following.

**Corrected (BQ source was stale):**

- `price_1QZwZ6Jnc2Yr4yxF11AWy527` — `sub_price` was `19`, live = **17.99**.
- `price_1RbKCUJnc2Yr4yxF9agFfOJ8` — was `trial_period 31 / trial_price 1.79`;
  live has **no trial** (no `trialPeriod`), so `trial_period 0`, `trial_price` blank.

**Added (live prices missing from the BQ source — last 8 rows):**

- `price_1Sk1R4…XhZXn5Ky` — Plus monthly $19, no trial.
- `price_1TJw0AJ…73z0eCA7` — FSM Solo Meta monthly $29, no trial.
- `price_1TJw1FJ…SNyvgayq` — FSM Team Meta monthly $79, no trial.
- `price_1TJw28J…ZLLaPj7T` — FSM Team Meta annual $600, no trial.
- `price_1TJw1rJ…pC2E4MCW` — FSM Business Meta monthly $149, no trial.
- `price_1TJw1bJ…i3t6QlrO` — FSM Business Meta monthly $149, 14-day $1 paid trial.
- `price_1TJw2WJ…s5pxHcQu` — FSM Business Meta annual $1200, no trial.
- `price_1TCMIeJ…yWOaG4KE` — FSM Business "early access" $0.

**Present in BQ but NOT in the live active list — likely archived (left in place,
not deleted):**

- `price_1RyvEiJnc2Yr4yxFq5nqLAdi` — Plus weekly $9.
- `price_1RyvCwJnc2Yr4yxFnS2XaFId` — Plus annual $99.

## Pending values

- **iOS / Android `invoices*` rows** — `sub_price` / `trial_price` not recorded
  in the BQ source; pull from App Store Connect / Play Console.
- **`invoices tofu.fsm_solo` / `tofu.invoicing` / `tofu.fsm_team`** — these are
  `product_type` marker strings, not concrete prices.
- **`field_service` team/business store products** (3 rows) — Stripe-web
  equivalents are $79/mo, $149/mo (7-day trial) and $600/yr; the exact store
  IAP amounts need confirming from the store consoles.
