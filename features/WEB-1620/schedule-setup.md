# Create daily scheduled query: `sku_mapping` (playfair)

How to (re)create the daily Scheduled Query for `sku_mapping`. Companion to [`README.md`](README.md) (WEB-1620).

> **As deployed (current):** the Scheduled Query lives in **`inv-project`** with runner
> **`playfair-invoices@inv-project.iam.gserviceaccount.com`** (job runs/bills in inv-project, writes
> cross-project to playfair `dbt_external`). The step-by-step below was written for an earlier
> **playfair / `tofu-bq`** ownership model and differs in project + identity — use it for the Console/CLI
> mechanics, but substitute the inv-project + `playfair-invoices` values above. The inline query is current.

- **Destination:** `playfair-project.dbt_external.sku_mapping` (do NOT touch `tofu_sku_mapping`).
- **Location:** `US`. **Cadence:** every 24h (09:00 UTC).
- **Semantics:** upsert — INSERT absent product_ids; on match sync `trial_period`/`sub_price`/app-store `trial_price` without nulling. See [`fields.md`](fields.md).
- **Cost:** ~5 GB scanned/run (mostly `inv-project.analytics.events`) ≈ $0.025/day.

---

## Prerequisites (you, the playfair admin)

1. You can create scheduled queries in `playfair-project` (`roles/bigquery.admin` or `bigquery.transfers.update`).
2. To assign `tofu-bq` as the runner you need **`roles/iam.serviceAccountUser` on that SA**:
   ```bash
   gcloud iam service-accounts add-iam-policy-binding \
     tofu-bq@playfair-project.iam.gserviceaccount.com \
     --member="user:<YOUR-EMAIL>@tofu.com" \
     --role="roles/iam.serviceAccountUser"
   ```
3. **Target table must exist** — a DML `MERGE` fails on a missing table. Create it once (safe / idempotent):
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

---

## Create the schedule — Console (recommended)

1. BigQuery → **Scheduled queries** → **Create scheduled query** (project `playfair-project`).
2. Paste the query from the [The query](#the-query) section below.
3. **Schedule:** Repeats = Days, every 1 day. **Location:** `US`.
4. **Destination:** leave EMPTY — this is a DML `MERGE`, it writes itself (no destination table / write disposition).
5. **Service account:** select `tofu-bq@playfair-project.iam.gserviceaccount.com`.
6. Save.

## Or via `bq` CLI

```bash
bq mk --transfer_config \
  --project_id=playfair-project \
  --data_source=scheduled_query \
  --display_name="sku_mapping daily upsert" \
  --location=US \
  --schedule="every 24 hours" \
  --service_account_name="tofu-bq@playfair-project.iam.gserviceaccount.com" \
  --params='{"query":"<paste the MERGE SQL below as a single escaped string>"}'
```

DML `MERGE` writes itself → no `destination_table` / `write_disposition` needed.

---

## The query

> Source of truth: `sku_mapping_merge.sql` (keep in sync if that file changes).
> `sub_length` is the subscription length in **days**: `<n> * unit-days` with `d=1, w=7, m=31, y=365`
> (matches the original `tofu_sku_mapping` catalog, which uses 7 / 31 / 365).

```sql
MERGE `playfair-project.dbt_external.sku_mapping` T
USING (
  WITH ev AS (
    SELECT 'invoices' AS app_name, event_name,
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='product_id') pid,
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='subscription_duration') dur,
      (SELECT value.numeric_value FROM UNNEST(event_params) WHERE key='user_price') price,
      (SELECT value.int_value     FROM UNNEST(event_params) WHERE key='is_in_intro_offer_period') in_intro,
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='offer_metadata.trial_price') otp,
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='trial_duration') trial_dur
    FROM `inv-project.analytics.events`
    WHERE event_name IN ('subscription_paid','trial_started')
    UNION ALL
    SELECT 'invoices_android', event_name,
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='product_id'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='subscription_duration'),
      (SELECT value.numeric_value FROM UNNEST(event_params) WHERE key='user_price'),
      (SELECT value.int_value     FROM UNNEST(event_params) WHERE key='is_in_intro_offer_period'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='offer_metadata.trial_price'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='trial_duration')
    FROM `inv-project.analytics_android.events`
    WHERE event_name IN ('subscription_paid','trial_started')
    UNION ALL
    SELECT 'field_service', event_name,
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='product_id'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='subscription_duration'),
      (SELECT value.numeric_value FROM UNNEST(event_params) WHERE key='user_price'),
      (SELECT value.int_value     FROM UNNEST(event_params) WHERE key='is_in_intro_offer_period'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='offer_metadata.trial_price'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='trial_duration')
    FROM `inv-project.analytics.events_tofu-fieldservice`
    WHERE event_name IN ('subscription_paid','trial_started')
    UNION ALL
    SELECT 'tofu_web', event_name,
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='product_id'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='subscription_duration'),
      (SELECT value.numeric_value FROM UNNEST(event_params) WHERE key='user_price'),
      (SELECT value.int_value     FROM UNNEST(event_params) WHERE key='is_in_intro_offer_period'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='offer_metadata.trial_price'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='trial_duration')
    FROM `inv-project.analytics_web.events_invoices_stripe`
    WHERE event_name IN ('subscription_paid','trial_started')
    UNION ALL
    SELECT 'tofu_web', event_name,
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='product_id'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='subscription_duration'),
      (SELECT value.numeric_value FROM UNNEST(event_params) WHERE key='user_price'),
      (SELECT value.int_value     FROM UNNEST(event_params) WHERE key='is_in_intro_offer_period'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='offer_metadata.trial_price'),
      (SELECT value.string_value  FROM UNNEST(event_params) WHERE key='trial_duration')
    FROM `inv-project.analytics_web.events_tofu_stripe`
    WHERE event_name IN ('subscription_paid','trial_started')
  ),
  agg AS (
    SELECT
      app_name,
      pid AS product_id,
      ANY_VALUE(dur) AS dur_raw,
      MAX(trial_dur) AS trial_dur_raw,                     -- source of truth: any non-null trial_duration for this pid
      MAX(IF(in_intro=0 OR in_intro IS NULL, price, NULL)) AS reg_price,
      APPROX_TOP_COUNT(IF(in_intro=0 OR in_intro IS NULL, price, NULL), 5) AS price_top,  -- top non-intro user_price candidates (NULLs filtered downstream)
      APPROX_TOP_COUNT(IF(in_intro=1, price, NULL), 5) AS intro_top,                       -- top intro user_price candidates -> app-store trial_price
      MAX(SAFE_CAST(otp AS NUMERIC)) / 100                 AS nominal_trial,
      COUNTIF(event_name='trial_started')                  AS trial_started
    FROM ev
    WHERE pid IS NOT NULL
    GROUP BY app_name, pid
  )
  SELECT
    app_name,
    product_id,
    -- subscription_duration (e.g. 1w/1m/3m/1y/3d) -> days: <n> * unit-days (d=1,w=7,m=31,y=365)
    CASE
      WHEN dur_raw IS NULL THEN NULL
      WHEN REGEXP_CONTAINS(LOWER(dur_raw), r'[dwmy]') THEN
        CAST(
          COALESCE(SAFE_CAST(REGEXP_EXTRACT(LOWER(dur_raw), r'(\d+)') AS INT64), 1)
          * CASE REGEXP_EXTRACT(LOWER(dur_raw), r'[dwmy]')
              WHEN 'd' THEN 1 WHEN 'w' THEN 7 WHEN 'm' THEN 31 WHEN 'y' THEN 365
            END
        AS STRING)
      ELSE dur_raw   -- unknown unit -> keep raw
    END AS sub_length,
    -- trial_duration (e.g. 3d/1w/7d) -> days; source of truth when present, else 0 (no trial, never NULL)
    COALESCE(
      CASE
        WHEN trial_dur_raw IS NULL THEN NULL
        WHEN REGEXP_CONTAINS(LOWER(trial_dur_raw), r'[dwmy]') THEN
          CAST(
            COALESCE(SAFE_CAST(REGEXP_EXTRACT(LOWER(trial_dur_raw), r'(\d+)') AS INT64), 1)
            * CASE REGEXP_EXTRACT(LOWER(trial_dur_raw), r'[dwmy]')
                WHEN 'd' THEN 1 WHEN 'w' THEN 7 WHEN 'm' THEN 31 WHEN 'y' THEN 365
              END
          AS STRING)
        ELSE trial_dur_raw
      END, '0') AS trial_period,
    -- tofu_web: Stripe reg_price; app-store: most common non-intro user_price excluding NULLs (matches catalog, no FX noise)
    CASE WHEN app_name='tofu_web' THEN CAST(reg_price AS STRING)
         ELSE CAST((SELECT e.value FROM UNNEST(price_top) e WHERE e.value IS NOT NULL ORDER BY e.count DESC LIMIT 1) AS STRING)
    END AS sub_price,
    -- tofu_web: offer_metadata trial / free-trial 0 / else NULL; app-store: mode of intro user_price, else 0 (no trial)
    CASE WHEN app_name='tofu_web'
         THEN COALESCE(CAST(nominal_trial AS STRING), IF(trial_started > 0, '0', NULL))
         ELSE COALESCE(CAST((SELECT e.value FROM UNNEST(intro_top) e WHERE e.value IS NOT NULL ORDER BY e.count DESC LIMIT 1) AS STRING), '0')
    END AS trial_price
  FROM agg
  WHERE NOT (app_name='tofu_web' AND reg_price IS NULL)   -- skip intro-only tofu_web rows (no full price yet)
) S
ON T.product_id = S.product_id
WHEN MATCHED AND (
     (SAFE_CAST(S.trial_period AS INT64) > 0 AND T.trial_period IS DISTINCT FROM S.trial_period)
  OR (S.sub_price IS NOT NULL AND T.sub_price IS DISTINCT FROM S.sub_price)
  OR (T.app_name != 'tofu_web' AND S.trial_price IS NOT NULL AND T.trial_price IS DISTINCT FROM S.trial_price)
) THEN
  UPDATE SET
    trial_period = IF(SAFE_CAST(S.trial_period AS INT64) > 0, S.trial_period, T.trial_period),  -- positive event trial only
    sub_price    = COALESCE(S.sub_price, T.sub_price),                                           -- event price (Stripe/app-store mode); never null out
    trial_price  = CASE WHEN T.app_name='tofu_web' THEN T.trial_price                            -- protect tofu_web (manual/Stripe values)
                        ELSE COALESCE(S.trial_price, T.trial_price) END                          -- app-store: sync from events
WHEN NOT MATCHED THEN
  INSERT (app_name, product_id, sub_length, trial_period, sub_price, trial_price, first_seen_date)
  VALUES (S.app_name, S.product_id, S.sub_length, S.trial_period, S.sub_price, S.trial_price, CURRENT_DATE());
```

---

## Verify after first run

- First run inserts ~69 rows; `tofu_sku_mapping` is untouched (it is a different table).
- Trigger a manual run again ("Schedule backfill" / Run now) → it should insert **0** rows (idempotent, insert-only on `product_id`).
- Spot-check: `app_name` prefixes resolve correctly, `sub_length` in {7, 31, 365, ...}, `sub_price`/`trial_price` only populated for `tofu_web`.
