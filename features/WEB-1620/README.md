# sku_mapping — event-derived SKU catalog → playfair (WEB-1620)

**Status:** deployed. Daily Scheduled Query live in `inv-project` (every day 09:00 UTC); table populated (91 rows).
**Last worked:** 2026-07-06 — fix plan for the tofu_web reg-price guard ([`sku-mapping-guard-fix.md`](sku-mapping-guard-fix.md)); prior work 2026-06-11.

## Goal

Reproduce the SKU catalog shape from analytics **events** (not the Google Doc), and keep a table in
the marketing DWH (`playfair`) updated daily. Now **self-sufficient from events** — `tofu_sku_mapping`
is being retired and is no longer a run-time dependency.

- Source data: `inv-project` BigQuery (analytics events).
- Destination: `playfair-project.dbt_external.sku_mapping` (do NOT touch `tofu_sku_mapping`).
- Identity for the job: `playfair-invoices@inv-project.iam.gserviceaccount.com` (job runs in inv-project, writes to playfair).
- Semantics: INSERT absent product_ids; on match, sync `trial_period` (positive event value only), `sub_price`, and app-store `trial_price` — never nulling existing values. Per-column logic in [`fields.md`](fields.md).

## Files (in this folder)

| File | What |
|---|---|
| `README.md` | This doc — feature plan / status. |
| `ai_analysis_us_tables.md` | **The `inv-project.ai_analysis_us` clone (`sku_mapping`) + `account_subscriptions` (active sub + computed expiration) + `account_identifiers` (account↔device-id bridge).** Deployed 2026-06-18. |
| `sku_mapping_merge_ai_analysis_us.sql` | MERGE targeting `inv-project.ai_analysis_us.sku_mapping` (in-project clone of the playfair job). |
| `account_subscriptions_rebuild.sql` | Daily `CREATE OR REPLACE` rebuild of `account_subscriptions`; resolves `platform_user_id`/`master_user_id` (masterUser first, accountIdentifiers fallback). |
| `reload_master_user.sh` | **Legacy** load of `masterUser` → the original `platform_user_accounts` (link×account cartesian, no `is_first_link`). Still live: the deployed `account_subscriptions` scheduled query reads it. |
| `rebuild_master_marts.sh` | **New three-layer rebuild (built 2026-06-19, `ai_analysis_us_tables.md` §3):** loads `master_user_raw` (landing, raw STRING; persisted) → builds `master_owned_accounts` + `master_platform_links`. Additive; does not touch the legacy table. |
| `master_owned_accounts.sql` | Build of the `(master_user_id, account_id, role)` bridge mart (cluster: `account_id`). |
| `master_platform_links.sql` | Build of the `(master_user_id, platform_user_id, public_id, is_first_link, …)` bridge mart (cluster: `platform_user_id`; web `public_id` not truncated). |
| `account_current_plan.sql` | Build of the final per-account primary-plan mart (PK `account_id`). v0 — tier ordering pending GAP 3 (§5). |
| `reload_account_identifiers.sh` | Periodic load of `account_identifiers` (fallback bridge) from the Atlas snapshot (tofu-ai SA; load job). |
| `sku-mapping-logic.md` | Human-readable build logic — web/iOS/Android differences, the `is_in_intro_offer_period` (no-intro) condition, upsert semantics. |
| `sku-mapping-guard-fix.md` | **Fix plan (2026-07-06):** tofu_web `reg_price IS NULL` guard drops coupon-only / trial-only composite-id SKUs (6 live ids, 137 payments invisible); insert-with-NULL-price fix + `1m=30d` vs `31d` alignment vs playfair seed. |
| `fields.md` | Per-column derivation logic for `sku_mapping` (terse reference). |
| `schedule-setup.md` | How to (re)create the daily Scheduled Query + the live MERGE query. |
| `sku_mapping_merge.sql` | **Production** MERGE → `playfair-project.dbt_external.sku_mapping`. |
| `sku_mapping_from_events.sql` | The same SELECT without MERGE (exploration / ad-hoc). |
| `sku_mapping_from_events.tsv` | Result snapshot. |
| `tofu_sku_mapping.{tsv,json,csv}` | Snapshot of the original catalog (`tofu_sku_mapping`), kept for reference (being retired). |

## Output schema (6 catalog cols + audit)

`app_name, product_id, sub_length, trial_period, sub_price, trial_price` (+ `first_seen_date` in the target table).

## Data model findings

### Source tables (all `inv-project`, location US, NOT partitioned)
| Table | Rows | Size | → app_name |
|---|---|---|---|
| `analytics.events` | 18.7M | 7.2 GB | `invoices` (iOS) |
| `analytics_android.events` | 1.84M | 475 MB | `invoices_android` |
| `analytics.events_tofu-fieldservice` | 13.4K | 3.2 MB | `field_service` |
| `analytics_web.events_invoices_stripe` | 899 | 0.2 MB | `tofu_web` |
| `analytics_web.events_tofu_stripe` | 88.7K | 37.5 MB | `tofu_web` |

`analytics_android.events_tofu-fieldservice-worker` carries NO subscription/trial events → skipped.

### Events & params
- Events used: `subscription_paid` + `trial_started`.
- `event_params` is GA4-style `ARRAY<STRUCT<key STRING, value STRUCT<string_value, int_value, numeric_value>>>`.
- Key params: `product_id`, `subscription_duration` (`1w`/`1m`/`1y`), `user_price` (numeric),
  `is_in_intro_offer_period` (0/1), `offer_metadata.trial_price` (string, **cents**).

### Column logic
- **app_name**: CASE on product_id prefix →
  `com.getpaidapp.android.*`→invoices_android · `com.getpaidapp.fieldservice.*`→field_service ·
  `com.getpaidapp.invoices.*`→invoices · `tofu.*`/`invoices.*`→tofu_web.
- **sub_length**: `subscription_duration` mapped to days (w→7, m→31, y→365).
- **sub_price / trial_price**: filled ONLY for `tofu_web` (Stripe price_id = one fixed USD price).
  App-store prices left BLANK — `user_price` there is the actual amount paid (varies by country/promo),
  noisy; this is exactly why `tofu_sku_mapping` leaves iOS/Android prices blank.
  - `sub_price` = `user_price` when NOT in intro period (full/list price).
  - `trial_price` = **nominal** trial:
    - `offer_metadata.trial_price / 100` (cents→USD) when a paid intro offer exists;
    - else `0` when the product has `trial_started` events (free trial);
    - else blank (no trial).
- **trial_period (days)**: NOT derivable (param `trial_duration` exists but only on ~62 iOS rows) → blank, as in catalog.
- tofu_web rows with only intro payments observed (no full-price renewal yet) → `sub_price` blank → **dropped** in the SELECT/MERGE source.

### Comparison vs `tofu_sku_mapping` (after nominal-trial fix)
- 69 event-derived product_ids; **0** that aren't already in the catalog.
- 68 match (or blank for app-store, as designed). **1** diff: `price_1QZwZ6…11AWy527` sub_price catalog=`19` vs events=`17.99` — and the catalog's own *Reconciliation* note already corrects this to 17.99 (= live Stripe), i.e. **events are right / catalog cell stale.**
- 22 catalog product_ids not seen in events = marker strings w/o price, archived prices, Paddle `pri_*`, and new/no-payment SKUs — expected.

### Cost
Full daily run scans ~5 GB (mostly `analytics.events`) ≈ **$0.025/day**.

## Deployment plan (Option A: single cross-project job as the SA)

inv-project (US) read → playfair (US) MERGE in ONE job under `tofu-bq@playfair-project`. Locations match (US↔US), so a single job is legal.

### IAM — current vs needed (verified 2026-06-10)
| Scope | Permission | Current | Needed |
|---|---|---|---|
| `playfair.dbt_external` | WRITER (create table + MERGE write) | ✅ has | ok |
| `playfair-project` | run query jobs (`jobs.create`) | ✅ has | ok |
| `inv-project` analytics*/analytics_android/analytics_web | read (`tables.getData`) | ❌ none | **grant `roles/bigquery.dataViewer`** |
| `playfair-project` | manage transfers (`transfers.update/get`) | ❌ denied | only if the SA itself creates the schedule |

**To SELECT source data:** SA needs `roles/bigquery.dataViewer` on inv-project `analytics`, `analytics_android`, `analytics_web`. (No jobUser needed on inv-project — job runs/bills in playfair.)

**To CREATE a scheduled query** (Google docs): `bigquery.transfers.update` OR (`bigquery.jobs.create` + `bigquery.transfers.get`) + `bigquery.datasets.get`; predefined `roles/bigquery.admin` covers it. To assign a SA as runner, the creator needs `iam.serviceAccountUser` on the SA.

**To RUN the scheduled query** (as SA): `bigquery.jobs.create` + `bigquery.datasets.get` on target — **already satisfied**.

#### Two ways to own the schedule
1. **Least-privilege (recommended):** a human admin / Terraform creates the scheduled query and sets `tofu-bq` as runner. SA only gets `dataViewer` on the 3 inv-project datasets. Admin needs `iam.serviceAccountUser` on the SA.
2. **SA does it all:** add `roles/bigquery.admin` (or custom role w/ `transfers.update`+`transfers.get`) to the SA on playfair — broader rights in the marketing project.

### Grant commands (Option 1)
```bash
# inv-project: read source datasets (dataset-level)
for DS in analytics analytics_android analytics_web; do
  bq update --source <(bq show --format=prettyjson inv-project:$DS \
    | jq '.access += [{"role":"READER","userByEmail":"tofu-bq@playfair-project.iam.gserviceaccount.com"}]') \
    inv-project:$DS
done
# playfair: let the schedule creator assign the SA as runner
gcloud iam service-accounts add-iam-policy-binding \
  tofu-bq@playfair-project.iam.gserviceaccount.com \
  --member="user:<admin>@tofu.com" --role="roles/iam.serviceAccountUser"
```

### Target table DDL (run once, SA can do this now — it's WRITER on dbt_external)
```sql
CREATE TABLE IF NOT EXISTS `playfair-project.dbt_external.sku_mapping` (
  app_name        STRING,
  product_id      STRING,
  sub_length      STRING,
  trial_period    STRING,
  sub_price       STRING,
  trial_price     STRING,
  first_seen_date DATE
);
```

### MERGE
See `sku_mapping_merge.sql` (target table is `sku_mapping`). Insert-only: `ON T.product_id = S.product_id` + only `WHEN NOT MATCHED THEN INSERT`.

### Schedule (daily, US) — bq CLI
```bash
bq mk --transfer_config \
  --project_id=playfair-project \
  --data_source=scheduled_query \
  --display_name="sku_mapping daily upsert" \
  --location=US \
  --schedule="every 24 hours" \
  --service_account_name="tofu-bq@playfair-project.iam.gserviceaccount.com" \
  --params='{"query":"<contents of sku_mapping_merge.sql>"}'
```
DML MERGE writes itself → no destination_table/write_disposition needed.

## How to run things (auth)
- Source reads / inv-project: `gcloud config set account s.fedorov@tofu.com` (prod reads need this user; service default is denied).
- playfair / the SA: `gcloud auth activate-service-account --key-file="C:\Files\playfair-project-bf780411c09d.json"` then REST with `gcloud auth print-access-token`. **Restore** with `gcloud config set account s.fedorov@tofu.com` after.
- `bq` CLI is ACL-broken on this machine → use the BigQuery REST API (`/queries`, `/jobs`) with a bearer token. Examples are in the shell history / earlier in this work.

## Next steps (tomorrow)
1. Decide ownership model (Option 1 admin-owned schedule vs Option 2 SA-owned).
2. Apply IAM: `roles/bigquery.dataViewer` to the SA on inv-project `analytics`, `analytics_android`, `analytics_web`.
3. Create the target table (DDL above) — can be done now under the SA.
4. First manual run of `sku_mapping_merge.sql` as the SA; verify rows inserted and `tofu_sku_mapping` untouched.
5. Re-run once more → confirm 0 new inserts (idempotent).
6. Create the daily scheduled query (US).
7. (Optional) document the table in `Local.Docs/Backend/Domain/product-prices.md` as the event-derived companion to the Google-Doc source.
