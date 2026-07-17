# sku_mapping fix plan — tofu_web reg-price guard drops coupon-only / trial-only SKUs

Fix plan for `build_sku_mapping`: stop dropping web SKUs that have no full-price payment yet, and resolve the `1m = 31d` vs playfair `1m = 30d` discrepancy. Based on prod findings 2026-07-06.

## Problem

The web branch of the SKU build has a guard that excludes any `tofu_web` row with no observed full-price payment:

```sql
WHERE NOT (app_name = 'tofu_web' AND reg_price IS NULL)
```

(`reg_price` = `MAX(user_price)` over payments with `is_in_intro_offer_period = 0 OR IS NULL`; see [`sku-mapping-logic.md`](sku-mapping-logic.md).)

When it was written, web `product_id`s were coarse (one id per plan), so "no full price seen yet" meant a brand-new SKU and skipping it briefly was safe. Web payments now carry **composite per-price ids** — `tofu.<code>.<N><unit>ly.prod_<stripeProduct>.price_<stripePrice>` — one id per Stripe price. Coupon experiments produce price ids whose payments are **all** discounted (`is_in_intro_offer_period = 1` = coupon on web), and trial-only prices produce only `trial_started`. For such ids `reg_price` is permanently NULL → the guard drops the whole SKU forever.

### Prod evidence (2026-07-06, `inv-project.analytics_web.events_tofu_stripe`)

SKUs with real volume that are missing from `ai_analysis_us.dim_skus` / `playfair-project.dbt_external.sku_mapping`:

| product_id (abbreviated) | Payments | Why dropped |
|---|---|---|
| `tofu.fsm_solo.1monthly.…price_1TJvz9…5QzBUWOB` | 105 (avg $9.23) | all payments `in_intro=1` (coupon) |
| `tofu.fsm_solo.1monthly.…price_1Sx1R5…uMdYWpWj` | 21 (avg $12.52) | all coupon |
| `tofu.fsm_team.1monthly.…price_1TJw0g…EcIem9kd` | 7 (avg $14.71) | all coupon |
| `tofu.fsm_solo.1monthly.…price_1TJvzn…zTEtwBGN` | 4 (avg $5.50) | all coupon |
| `tofu.fsm_business.1yearly.…price_1T4g5T…SJfXZK9D` | 0 (≥10 trials) | trial-only |
| `tofu.fsm_team.1yearly.…price_1T4g5N…SpLydhfq` | 0 (≥22 trials) | trial-only |

Downstream effect: `mart_account_subscriptions` joins `dim_skus` on `(app_name, product_id)` for `trial_len_days` — subscriptions on these ids get no catalog row (trial length falls back to the 7-day default; sub metadata missing).

## Fix

Applies to the shared source SELECT used by **both** deployment surfaces (see Rollout):

1. **Insert instead of drop.** For ids matching the composite pattern
   (`REGEXP_CONTAINS(product_id, r'\.prod_[A-Za-z0-9]+\.price_')`), keep the row even when
   `reg_price IS NULL` and insert with `sub_price = NULL`. Keep dropping non-composite (legacy
   bare-code) rows without a price — same behaviour as today for old ids.
   The MERGE update branch already does `sub_price = COALESCE(S.sub_price, T.sub_price)`, so the row
   self-heals the first time a full-price payment appears.
2. **`sub_length` fallback from the id.** When `subscription_duration` is absent, parse the
   `<N><unit>ly` segment of the composite id (`1weekly`→7, `1monthly`→month, `1yearly`→365,
   `quarterly`→3 months) so trial-only rows still get a length.
3. **Out of scope (deliberate):**
   - Coupon price is NOT written to `sub_price`/`trial_price` — it is a discounted realized amount,
     not a list price. If needed it is extractable ad-hoc (median of `in_intro=1` payments per
     `(product_id, promotional_offer_id)` — recipe in
     [`sku-mapping-logic.md` § coupon prices](sku-mapping-logic.md)).
   - Playfair's PF-659 `invoices_web`/`tofu_web` app split is **not** replicated here: it is
     campaign-driven with hardcoded per-price exceptions on their side. Our `app_name='tofu_web'`
     stays the raw-source label; playfair maps sub-apps via their own `municorn_products_mapping` seed.

## Month-length discrepancy (1m = 31d vs 30d)

Our duration converter maps `m → 31` days; playfair's seed (and the retired `tofu_sku_mapping`
catalog) use `1m → 30`. Any cross-check of `sub_length` between `sku_mapping` and playfair's mapping
flags every monthly SKU.

**Recommendation: align to `m → 30`** (catalog + playfair convention) in the same change.
Impact to review before applying: `mart_account_subscriptions` computes
`expires_at = last_paid_at + sub_length_days`, so monthly-sub expiry (and `is_active`/`status`)
shifts 1 day earlier. If that grace day is load-bearing for anyone, keep 31 and instead document the
delta here — but pick one; don't leave it implicit.

## Rollout

The guard lives in two places that must change together:

| Surface | What | How to deploy |
|---|---|---|
| `Tofu.AI.Backend` `…/Warehouse/Sql/Routines/build_subscriptions.sql` → `build_sku_mapping()` (writes `ai_analysis_us.dim_skus`) | routine DDL | deploy service (routine deployer); executes on next daily DTS `CALL` 09:00 UTC |
| DTS "Playfair invoices_products daily upsert" (writes `playfair-project.dbt_external.sku_mapping`) | raw MERGE body = [`sku_mapping_merge.sql`](sku_mapping_merge.sql) | update transfer config **as the `tofu-ai-backend` prod SA** (user-account `bq update` is a silent no-op — read the config back to confirm), and update the reference copy in this folder |

Verification after the first run:
- the 6 ids above are present, coupon-only rows with `sub_price IS NULL`, trial-only yearly rows with `sub_length = 365`;
- re-run inserts 0 rows (idempotency preserved);
- `mart_account_subscriptions` rows on these ids pick up `trial_len_days` after the next rebuild.
