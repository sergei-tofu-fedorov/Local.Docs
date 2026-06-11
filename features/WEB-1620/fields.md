# sku_mapping — field logic (WEB-1620)

Per-column derivation for `playfair-project.dbt_external.sku_mapping`, built by `sku_mapping_merge.sql`
(daily Scheduled Query in inv-project, runner `playfair-invoices@inv-project`).

**Source:** GA4-style analytics **events** (`subscription_paid` + `trial_started`) across 5 tables in `inv-project`:

| Source table | → app_name |
|---|---|
| `analytics.events` | `invoices` (iOS) |
| `analytics_android.events` | `invoices_android` |
| `analytics.events_tofu-fieldservice` | `field_service` |
| `analytics_web.events_invoices_stripe` + `analytics_web.events_tofu_stripe` | `tofu_web` |

Event params used: `product_id`, `subscription_duration`, `user_price`, `is_in_intro_offer_period`,
`offer_metadata.trial_price`, `trial_duration`. Rows are aggregated per `(app_name, product_id)`.

---

## Fields

| Field | Logic |
|---|---|
| **app_name** | Channel, set by which source table the event came from (literal per UNION branch). |
| **product_id** | `event_params.product_id`. **Merge key** (`ON T.product_id = S.product_id`) — unique per row. |
| **sub_length** | From `subscription_duration` (e.g. `1w`/`1m`/`3m`/`1y`/`3d`), `ANY_VALUE` per product_id, converted to **days**: `<n> × unit` where `d=1, w=7, m=31, y=365`. Unknown unit → raw value. |
| **trial_period** | Days of trial. **Source of truth = event `trial_duration`** (same day-conversion), `MAX` over the product_id (used if present on *any* event); else **`0`** (never NULL). Historically also one-time backfilled from the catalog where events had none. |
| **sub_price** | List/full price. **`tofu_web`** → `reg_price` = `MAX` of non-intro `user_price` (Stripe price_id = one fixed USD price). **app-store** (`invoices`/`android`/`field_service`) → **mode** (most common non-intro `user_price`, NULLs excluded) — matches the store list price, drops FX/promo noise. NULL if no non-intro price seen. |
| **trial_price** | Intro/trial price. **`tofu_web`** → `offer_metadata.trial_price / 100` (cents→USD); else `0` if any `trial_started`; else NULL. **app-store** → **mode** of intro (`is_in_intro_offer_period=1`) `user_price`, else **`0`** (no/free trial). |
| **first_seen_date** | `CURRENT_DATE()` at INSERT. Set once, never updated. |

---

## MERGE semantics (`sku_mapping_merge.sql`)

- **WHEN NOT MATCHED → INSERT**: new `product_id`s are added with all fields above.
- **WHEN MATCHED → UPDATE** (existing rows kept, except a targeted sync that never nulls values out):
  - `trial_period` ← event value **only if > 0** (a positive `trial_duration` overrides; 0/NULL never downgrades an existing value).
  - `sub_price` ← `COALESCE(event, existing)` (event Stripe/app-store mode; never nulls out).
  - `trial_price` ← synced **for app-store only**; **`tofu_web` is protected** (preserves manual / Stripe values).
- **Filter**: `tofu_web` rows with no full (non-intro) price are dropped from the source — intro-only price_ids with no list price yet are not inserted.

## Notes

- **App-store prices are derived, not from the App/Play console** — the *mode* of non-intro `user_price` reconstructs the USD list price (validated 14/14 vs the old `tofu_sku_mapping` catalog). `MAX` is **not** used for app-store sub_price (it catches expensive foreign-currency outliers).
- `sku_mapping` is **self-sufficient from events** — it does not depend on `tofu_sku_mapping` at run time (the catalog was a one-time validation/backfill source and is being retired).
- Exploration/ad-hoc version of the same SELECT (no MERGE): `sku_mapping_from_events.sql`.
