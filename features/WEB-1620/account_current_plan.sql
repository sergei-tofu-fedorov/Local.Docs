-- Build inv-project.ai_analysis_us.account_current_plan (Layer-3 final mart, WEB-1620 §3).
-- Grain: account_id (PK, one row per invoices account). Cluster: account_id.
-- The consumer surface for account metrics / BI — the per-account PRIMARY plan, so consumers never join.
-- Mirrors backend GetPrimarySubscription (§5) + the master/no-master resolution (§6/§7).
--
-- ⚠️ GAP 3 (§5): account_subscriptions has NO product_type / tier-priority column yet, so the true
--    "tier first, then expiry" ordering cannot be applied. This v0 orders by is_active → expiry only
--    (good enough when an account has a single active sub; wrong when it has several active tiers).
--    Once account_subscriptions carries product_type + product_type_priority, add them to the ORDER BY:
--      ORDER BY is_active DESC, product_type_priority DESC, COALESCE(expires_at, TIMESTAMP '9999-12-31') DESC
--
-- Depends on: master_owned_accounts, master_platform_links (§3), account_subscriptions, account_identifiers.

CREATE OR REPLACE TABLE `inv-project.ai_analysis_us.account_current_plan`
CLUSTER BY account_id AS
WITH first_links AS (                                    -- master → its first-link platform users (§6)
  SELECT DISTINCT master_user_id, platform_user_id
  FROM `inv-project.ai_analysis_us.master_platform_links`
  WHERE is_first_link
),
master_path AS (                                         -- account → master → first-link subs
  SELECT oa.account_id, oa.master_user_id, s.* EXCEPT(account_id, master_user_id)
  FROM `inv-project.ai_analysis_us.master_owned_accounts` oa
  JOIN first_links fl ON fl.master_user_id = oa.master_user_id
  JOIN `inv-project.ai_analysis_us.account_subscriptions` s
    ON s.platform_user_id = fl.platform_user_id
  WHERE oa.role = 'owned'                                -- subscriptions follow ownership, not worker membership
),
nomaster_path AS (                                       -- §7: accounts with no master → accountIdentifiers 1:1
  SELECT ai.account_id, CAST(NULL AS STRING) AS master_user_id, s.* EXCEPT(account_id, master_user_id)
  FROM `inv-project.ai_analysis_us.account_identifiers` ai
  JOIN `inv-project.ai_analysis_us.account_subscriptions` s
    ON s.account_id = SUBSTR(ai.user_id, 1, 25)          -- public_id (⚠ web caveat, GAP 2)
  WHERE ai.account_id NOT IN (SELECT account_id FROM `inv-project.ai_analysis_us.master_owned_accounts`)
),
unioned AS (
  SELECT * FROM master_path
  UNION ALL
  SELECT * FROM nomaster_path
)
SELECT
  account_id,
  master_user_id,
  product_id,
  app_name,
  status,
  is_active,
  is_trial,
  started_at,
  expires_at,
  auto_renew_enabled,
  CURRENT_TIMESTAMP() AS updated_at
FROM unioned
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY account_id
  ORDER BY is_active DESC, COALESCE(expires_at, TIMESTAMP '9999-12-31') DESC   -- v0: tier pending GAP 3
) = 1;
