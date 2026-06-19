-- Rebuild inv-project.ai_analysis_us.account_subscriptions
-- Grain: one row per subscription = (app_name, account_id, original_transaction_id). Trials included.
-- Identity: playfair-invoices@inv-project (runs + writes in inv-project). Run daily as a Scheduled Query (US).
--
-- account_id = the SUBSCRIBER / store account id from analytics events = PublicId (first 25 chars of the
--   platform user id; Stripe customer id on web). It does NOT equal the invoices account id. We RESOLVE the
--   invoices account (tofu_account_id) by a UserId match on the subz account_id, NOT device identifiers:
--     1. accountIdentifiers: account_id (= _id) where SUBSTR(user_id,1,25) = subz account_id, else
--     2. masterUser: the owned account of the canonical IsFirstLink link (ai_analysis_us.platform_user_accounts).
--   platform_user_id = the canonical IsFirstLink identity via platform_user_canonical (maps ANY link's public_id
--   -> the master's first-link platform user), else the raw accountIdentifiers UserId.
--
-- Expiration is NOT emitted by Subz (events carry only `subscription_duration`), so it is computed:
--   expires_at = last subscription_paid.event_time + sub_length_days
--   (trial-only: trial_started.event_time + trial_period_days, fallback 7d), overridden by an explicit
--   subscription_expired (natural expiry) or subscription_cancelled (= refund).

CREATE OR REPLACE TABLE `inv-project.ai_analysis_us.account_subscriptions`
CLUSTER BY platform_user_id AS
WITH ev AS (
  SELECT 'invoices' AS app_name, event_name, event_time, account_id,
    UPPER(firebase_id) fb, appsflyer_id af, UPPER(idfa) idfa,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='product_id') pid,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='original_transaction_id') otx,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='subscription_duration') dur,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='store_country') store_country,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key='renew_enabled') renew_enabled
  FROM `inv-project.analytics.events`
  WHERE event_name IN ('subscription_paid','trial_started','subscription_expired','subscription_cancelled','renew_state_changed','renew_product_changed')
  UNION ALL
  SELECT 'invoices_android', event_name, event_time, account_id, UPPER(firebase_id), appsflyer_id, UPPER(idfa),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='product_id'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='original_transaction_id'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='subscription_duration'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='store_country'),
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key='renew_enabled')
  FROM `inv-project.analytics_android.events`
  WHERE event_name IN ('subscription_paid','trial_started','subscription_expired','subscription_cancelled','renew_state_changed','renew_product_changed')
  UNION ALL
  SELECT 'field_service', event_name, event_time, account_id, UPPER(firebase_id), appsflyer_id, UPPER(idfa),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='product_id'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='original_transaction_id'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='subscription_duration'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='store_country'),
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key='renew_enabled')
  FROM `inv-project.analytics.events_tofu-fieldservice`
  WHERE event_name IN ('subscription_paid','trial_started','subscription_expired','subscription_cancelled','renew_state_changed','renew_product_changed')
  UNION ALL
  SELECT 'tofu_web', event_name, event_time, account_id, UPPER(firebase_id), appsflyer_id, UPPER(idfa),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='product_id'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='original_transaction_id'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='subscription_duration'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='store_country'),
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key='renew_enabled')
  FROM `inv-project.analytics_web.events_invoices_stripe`
  WHERE event_name IN ('subscription_paid','trial_started','subscription_expired','subscription_cancelled','renew_state_changed','renew_product_changed')
  UNION ALL
  SELECT 'tofu_web', event_name, event_time, account_id, UPPER(firebase_id), appsflyer_id, UPPER(idfa),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='product_id'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='original_transaction_id'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='subscription_duration'),
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key='store_country'),
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key='renew_enabled')
  FROM `inv-project.analytics_web.events_tofu_stripe`
  WHERE event_name IN ('subscription_paid','trial_started','subscription_expired','subscription_cancelled','renew_state_changed','renew_product_changed')
),
ev2 AS (
  SELECT *,
    CASE WHEN dur IS NULL THEN NULL
         WHEN REGEXP_CONTAINS(LOWER(dur), r'[dwmy]') THEN
           COALESCE(SAFE_CAST(REGEXP_EXTRACT(LOWER(dur), r'(\d+)') AS INT64),1)
           * CASE REGEXP_EXTRACT(LOWER(dur), r'[dwmy]') WHEN 'd' THEN 1 WHEN 'w' THEN 7 WHEN 'm' THEN 31 WHEN 'y' THEN 365 END
         ELSE NULL END AS dur_days
  FROM ev
  WHERE account_id IS NOT NULL AND otx IS NOT NULL
),
-- ACCOUNT + PLATFORM-USER resolution. account_id in events = PublicId = first 25 chars of the platform user id.
-- Invoices account (tofu_account_id): accountIdentifiers (UserId match) first, else the masterUser first-link
-- owned account. Platform user: the canonical IsFirstLink identity -- platform_user_canonical maps ANY link's
-- public_id -> the master's first-link platform user, so a non-first-link UserId (e.g. from accountIdentifiers)
-- still resolves to the first-link identity/subscription -- else the raw accountIdentifiers UserId.
canon AS (
  SELECT public_id, ANY_VALUE(first_link_platform_user_id) first_link_platform_user_id,
         ANY_VALUE(master_user_id) master_user_id
  FROM `inv-project.ai_analysis_us.platform_user_canonical` GROUP BY public_id
),
ai_map AS (
  SELECT SUBSTR(user_id,1,25) public_id, ANY_VALUE(user_id) user_id, ANY_VALUE(account_id) account_id
  FROM `inv-project.ai_analysis_us.account_identifiers` WHERE user_id IS NOT NULL GROUP BY 1
),
mu_acct AS (
  SELECT public_id, ANY_VALUE(account_id) account_id
  FROM `inv-project.ai_analysis_us.platform_user_accounts` GROUP BY public_id
),
agg AS (
  SELECT
    app_name, account_id, otx AS original_transaction_id,
    COALESCE(
      ARRAY_AGG(IF(event_name='subscription_paid', pid, NULL) IGNORE NULLS ORDER BY event_time DESC LIMIT 1)[OFFSET(0)],
      ARRAY_AGG(IF(event_name='trial_started',    pid, NULL) IGNORE NULLS ORDER BY event_time DESC LIMIT 1)[OFFSET(0)]
    ) AS product_id,
    ARRAY_AGG(store_country IGNORE NULLS ORDER BY event_time DESC LIMIT 1)[SAFE_OFFSET(0)] AS store_country,
    ARRAY_AGG(fb   IGNORE NULLS ORDER BY event_time DESC LIMIT 1)[SAFE_OFFSET(0)] AS firebase_id,
    ARRAY_AGG(af   IGNORE NULLS ORDER BY event_time DESC LIMIT 1)[SAFE_OFFSET(0)] AS appsflyer_id,
    ARRAY_AGG(idfa IGNORE NULLS ORDER BY event_time DESC LIMIT 1)[SAFE_OFFSET(0)] AS idfa,
    MAX(dur_days) AS sub_length_days,
    MIN(IF(event_name IN ('subscription_paid','trial_started'), event_time, NULL)) AS started_at,
    MAX(IF(event_name='subscription_paid',  event_time, NULL)) AS last_paid_at,
    MIN(IF(event_name='trial_started',       event_time, NULL)) AS trial_started_at,
    MAX(IF(event_name='subscription_expired',event_time, NULL)) AS expired_at,
    MAX(IF(event_name='subscription_cancelled',event_time,NULL)) AS refunded_at,
    COUNTIF(event_name='subscription_paid') AS paid_count,
    MAX(event_time) AS last_event_at,
    ARRAY_AGG(IF(event_name='renew_state_changed', renew_enabled, NULL) IGNORE NULLS ORDER BY event_time DESC LIMIT 1)[SAFE_OFFSET(0)] AS renew_enabled_last
  FROM ev2
  GROUP BY app_name, account_id, otx
),
resolved AS (
  SELECT a.*,
    -- invoices account: accountIdentifiers (UserId match) first, else masterUser first-link owned account
    COALESCE(ai.account_id, mu.account_id) AS tofu_account_id,
    CASE WHEN ai.account_id IS NOT NULL THEN 'accountIdentifiers'
         WHEN mu.account_id IS NOT NULL THEN 'masterUser-firstLink' END AS resolved_via,
    -- platform user: canonical IsFirstLink identity (any link -> first link), else accountIdentifiers UserId
    COALESCE(c.first_link_platform_user_id, ai.user_id) AS platform_user_id,
    c.master_user_id AS master_user_id,
    CASE WHEN c.public_id IS NOT NULL THEN 'masterUser'
         WHEN ai.public_id IS NOT NULL THEN 'accountIdentifiers' END AS user_resolved_via
  FROM agg a
  LEFT JOIN ai_map  ai ON a.account_id = ai.public_id
  LEFT JOIN canon   c  ON a.account_id = c.public_id
  LEFT JOIN mu_acct mu ON a.account_id = mu.public_id
),
joined AS (
  SELECT r.*,
    SAFE_CAST(NULLIF(m.trial_period,'0') AS INT64) AS trial_len_days
  FROM resolved r
  LEFT JOIN `inv-project.ai_analysis_us.sku_mapping` m USING (product_id)
),
computed AS (
  SELECT *,
    CASE
      WHEN last_paid_at IS NOT NULL AND sub_length_days IS NOT NULL
        THEN TIMESTAMP_ADD(last_paid_at, INTERVAL sub_length_days DAY)
      WHEN last_paid_at IS NULL AND trial_started_at IS NOT NULL
        -- trial length: known trial_period, else a conservative 7-day default (NEVER sub_length_days,
        -- which would treat an unconverted annual trial as active for a year)
        THEN TIMESTAMP_ADD(trial_started_at, INTERVAL COALESCE(trial_len_days, 7) DAY)
      ELSE NULL
    END AS base_expires_at
  FROM joined
)
SELECT
  app_name,
  account_id,                 -- subscriber/store account (events) = PublicId = platform_user_id[:25]
  platform_user_id,           -- full platform user id (owns N invoices accounts via master_user_accounts)
  master_user_id,             -- masterUser id (NULL when resolved via accountIdentifiers fallback)
  user_resolved_via,          -- 'accountIdentifiers' | 'masterUser' | NULL
  tofu_account_id,            -- invoices account: accountIdentifiers UserId match, else masterUser first-link
  resolved_via,               -- 'accountIdentifiers' | 'masterUser-firstLink' | NULL
  original_transaction_id,
  product_id,
  store_country,
  firebase_id, appsflyer_id, idfa,
  sub_length_days,
  trial_len_days,
  paid_count,
  (paid_count = 0 AND trial_started_at IS NOT NULL) AS is_trial,
  started_at,
  trial_started_at,
  last_paid_at,
  last_event_at,
  expired_at,
  refunded_at,
  CASE WHEN renew_enabled_last IS NULL THEN NULL ELSE renew_enabled_last = 1 END AS auto_renew_enabled,
  CASE
    WHEN refunded_at IS NOT NULL THEN refunded_at
    WHEN expired_at  IS NOT NULL THEN expired_at
    ELSE base_expires_at
  END AS expires_at,
  CASE
    WHEN refunded_at IS NOT NULL THEN 'refunded'
    WHEN expired_at  IS NOT NULL THEN 'expired'
    WHEN COALESCE(
           CASE WHEN refunded_at IS NOT NULL THEN refunded_at
                WHEN expired_at IS NOT NULL THEN expired_at
                ELSE base_expires_at END, TIMESTAMP '1970-01-01') < CURRENT_TIMESTAMP() THEN 'expired'
    WHEN paid_count = 0 AND trial_started_at IS NOT NULL THEN 'trial'
    ELSE 'active'
  END AS status,
  (refunded_at IS NULL
   AND expired_at IS NULL
   AND (CASE WHEN base_expires_at IS NOT NULL THEN base_expires_at ELSE TIMESTAMP '1970-01-01' END) >= CURRENT_TIMESTAMP()
  ) AS is_active,
  CURRENT_TIMESTAMP() AS updated_at
FROM computed;
