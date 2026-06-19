-- Build inv-project.ai_analysis_us.master_platform_links (Layer-2 bridge mart, WEB-1620 §3).
-- Grain: (master_user_id, platform_user_id) + public_id, platform, product, is_first_link, created_at.
-- Source: master_user_raw (raw STRING landing). Cluster: platform_user_id
--   (joins account_subscriptions on platform_user_id; also the public_id resolver inside the rebuild).
--
-- Platform enum (Invoices.Core/Models/MasterUser.cs): Unknown=0, IOS=1, Android=2, Web=3.
--   Stored Extended-JSON as {"$numberInt":"3"} → read via $.Platform."$numberInt" (fallback to bare int).
-- public_id = events account_id = Account.GetShortUserId(platformUserId):
--   mobile (platform!=3) → first 25 chars;  WEB (platform=3) → FULL id (NOT truncated). (GAP 2, §6/§7.)
-- is_first_link = PlatformUserLink.IsFirstLink (bool) → closes GAP 1 (§6). NULL/absent → FALSE.
-- created_at: PlatformUserLink.CreatedAt = {"$date":{"$numberLong":"<epoch_millis>"}} → TIMESTAMP_MILLIS.

CREATE OR REPLACE TABLE `inv-project.ai_analysis_us.master_platform_links`
CLUSTER BY platform_user_id AS
WITH mu AS (
  SELECT
    JSON_VALUE(raw, '$._id')                          AS master_user_id,
    JSON_QUERY_ARRAY(raw, '$.PlatformUserLinks')      AS links
  FROM `inv-project.ai_analysis_us.master_user_raw`
  WHERE STARTS_WITH(raw, '{')
),
flat AS (
  SELECT
    master_user_id,
    JSON_VALUE(l, '$.PlatformId')                                                          AS platform_user_id,
    COALESCE(SAFE_CAST(JSON_VALUE(l, '$.Platform."$numberInt"') AS INT64),
             SAFE_CAST(JSON_VALUE(l, '$.Platform')             AS INT64))                   AS platform,
    JSON_VALUE(l, '$.Product')                                                             AS product,
    COALESCE(CAST(JSON_VALUE(l, '$.IsFirstLink') AS BOOL), FALSE)                           AS is_first_link,
    TIMESTAMP_MILLIS(SAFE_CAST(JSON_VALUE(l, '$.CreatedAt."$date"."$numberLong"') AS INT64)) AS created_at
  FROM mu, UNNEST(links) l
  WHERE JSON_VALUE(l, '$.PlatformId') IS NOT NULL
)
SELECT
  master_user_id,
  platform_user_id,
  CASE WHEN platform = 3 THEN platform_user_id           -- web: full id
       ELSE SUBSTR(platform_user_id, 1, 25) END AS public_id,
  platform,
  product,
  is_first_link,
  created_at
FROM flat;
