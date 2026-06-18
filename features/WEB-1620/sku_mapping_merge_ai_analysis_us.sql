-- Daily upsert of the event-derived SKU mapping into inv-project.ai_analysis_us.sku_mapping.
-- Identical logic to sku_mapping_merge.sql (playfair target); only the MERGE target table differs.
-- Identity: playfair-invoices@inv-project.iam.gserviceaccount.com (job runs AND writes in inv-project; no cross-project).
-- Target must already exist (DDL in README). Run as a BigQuery Scheduled Query (US), daily.

MERGE `inv-project.ai_analysis_us.sku_mapping` T
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
      MAX(trial_dur) AS trial_dur_raw,
      MAX(IF(in_intro=0 OR in_intro IS NULL, price, NULL)) AS reg_price,
      APPROX_TOP_COUNT(IF(in_intro=0 OR in_intro IS NULL, price, NULL), 5) AS price_top,
      APPROX_TOP_COUNT(IF(in_intro=1, price, NULL), 5) AS intro_top,
      MAX(SAFE_CAST(otp AS NUMERIC)) / 100                 AS nominal_trial,
      COUNTIF(event_name='trial_started')                  AS trial_started
    FROM ev
    WHERE pid IS NOT NULL
    GROUP BY app_name, pid
  )
  SELECT
    app_name,
    product_id,
    CASE
      WHEN dur_raw IS NULL THEN NULL
      WHEN REGEXP_CONTAINS(LOWER(dur_raw), r'[dwmy]') THEN
        CAST(
          COALESCE(SAFE_CAST(REGEXP_EXTRACT(LOWER(dur_raw), r'(\d+)') AS INT64), 1)
          * CASE REGEXP_EXTRACT(LOWER(dur_raw), r'[dwmy]')
              WHEN 'd' THEN 1 WHEN 'w' THEN 7 WHEN 'm' THEN 31 WHEN 'y' THEN 365
            END
        AS STRING)
      ELSE dur_raw
    END AS sub_length,
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
    CASE WHEN app_name='tofu_web' THEN CAST(reg_price AS STRING)
         ELSE CAST((SELECT e.value FROM UNNEST(price_top) e WHERE e.value IS NOT NULL ORDER BY e.count DESC LIMIT 1) AS STRING)
    END AS sub_price,
    CASE WHEN app_name='tofu_web'
         THEN COALESCE(CAST(nominal_trial AS STRING), IF(trial_started > 0, '0', NULL))
         ELSE COALESCE(CAST((SELECT e.value FROM UNNEST(intro_top) e WHERE e.value IS NOT NULL ORDER BY e.count DESC LIMIT 1) AS STRING), '0')
    END AS trial_price
  FROM agg
  WHERE NOT (app_name='tofu_web' AND reg_price IS NULL)
) S
ON T.product_id = S.product_id
WHEN MATCHED AND (
     (SAFE_CAST(S.trial_period AS INT64) > 0 AND T.trial_period IS DISTINCT FROM S.trial_period)
  OR (S.sub_price IS NOT NULL AND T.sub_price IS DISTINCT FROM S.sub_price)
  OR (T.app_name != 'tofu_web' AND S.trial_price IS NOT NULL AND T.trial_price IS DISTINCT FROM S.trial_price)
) THEN
  UPDATE SET
    trial_period = IF(SAFE_CAST(S.trial_period AS INT64) > 0, S.trial_period, T.trial_period),
    sub_price    = COALESCE(S.sub_price, T.sub_price),
    trial_price  = CASE WHEN T.app_name='tofu_web' THEN T.trial_price
                        ELSE COALESCE(S.trial_price, T.trial_price) END
WHEN NOT MATCHED THEN
  INSERT (app_name, product_id, sub_length, trial_period, sub_price, trial_price, first_seen_date)
  VALUES (S.app_name, S.product_id, S.sub_length, S.trial_period, S.sub_price, S.trial_price, CURRENT_DATE());
