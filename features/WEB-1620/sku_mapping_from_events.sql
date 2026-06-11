-- Reconstruct the tofu_sku_mapping catalog shape from analytics events.
-- Events used: subscription_paid + trial_started.
--
-- Sources (5 tables):
--   inv-project.analytics.events                         -> invoices (iOS)
--   inv-project.analytics_android.events                 -> invoices_android
--   inv-project.analytics.events_tofu-fieldservice       -> field_service (store IAP)
--   inv-project.analytics_web.events_invoices_stripe     -> tofu_web
--   inv-project.analytics_web.events_tofu_stripe         -> tofu_web
--   (analytics_android.`events_tofu-fieldservice-worker` carries no subscription/trial events -> skipped)
--
-- Pricing rule:
--   * App-store channels (invoices / invoices_android / field_service): `user_price` is the
--     ACTUAL amount paid (varies by country/promo) -> NOT a clean list price. Left BLANK,
--     same as tofu_sku_mapping (real prices come from App Store / Play consoles).
--   * tofu_web (Stripe price_id): one fixed USD price per price_id -> reliable.
--       sub_price   = user_price when NOT in intro period (full/list price)
--       trial_price = NOMINAL trial price (not the amount actually charged):
--           - offer_metadata.trial_price / 100  (cents -> USD) when a paid intro offer exists
--           - else 0 when the product has trial_started events (free trial)
--           - else blank (no trial)
--     tofu_web rows where only intro payments were seen (sub_price would be empty) are DROPPED
--     (new / low-volume price_ids with no full-price renewal observed yet).
--   * trial_period: source param `trial_duration` exists (added recently) but is present on
--     only a few iOS-price events -> left BLANK, same as tofu_sku_mapping.
--
-- Cost: ~5 GB scan (analytics.events is 7.2 GB unpartitioned; android ~0.17 GB; rest tiny).

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
    MAX(SAFE_CAST(otp AS NUMERIC)) / 100                 AS nominal_trial,   -- offer_metadata.trial_price (cents -> USD)
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
  -- trial_period from trial_duration (3d/1w/7d) -> days; source of truth when present, else 0 (no trial)
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
WHERE NOT (app_name='tofu_web' AND reg_price IS NULL)                       -- drop intro-only tofu_web rows
ORDER BY app_name, product_id
