-- Build inv-project.ai_analysis_us.master_owned_accounts (Layer-2 bridge mart, WEB-1620 §3).
-- Grain: (master_user_id, account_id) + role. One row per OwnedAccount and per MemberAccount.
-- Source: master_user_raw (raw STRING landing = one Mongo masterUser Extended-JSON doc per row).
-- Cluster: account_id (account-centric entry point + the accounts/account_metrics join).
--
-- Notes:
--  - JSON_QUERY_ARRAY(raw,'$.MemberAccounts') is NULL when the field is absent → UNNEST(NULL) yields 0 rows.
--  - user_deleted: masterUser.DeletedAt is either JSON null or {"$date":{"$numberLong":...}}; test the deep
--    epoch path so null → not deleted, date object → deleted (JSON_VALUE on the object/null both give SQL NULL,
--    so we must reach the scalar $numberLong).

CREATE OR REPLACE TABLE `inv-project.ai_analysis_us.master_owned_accounts`
CLUSTER BY account_id AS
WITH mu AS (
  SELECT
    JSON_VALUE(raw, '$._id')                       AS master_user_id,
    JSON_QUERY_ARRAY(raw, '$.OwnedAccounts')       AS owned,
    JSON_QUERY_ARRAY(raw, '$.MemberAccounts')      AS members,
    JSON_VALUE(raw, '$.DeletedAt."$date"."$numberLong"') IS NOT NULL AS user_deleted
  FROM `inv-project.ai_analysis_us.master_user_raw`
  WHERE STARTS_WITH(raw, '{')
)
SELECT master_user_id, JSON_VALUE(a, '$.AccountId') AS account_id, 'owned'  AS role, user_deleted
FROM mu, UNNEST(owned) a
WHERE JSON_VALUE(a, '$.AccountId') IS NOT NULL
UNION ALL
SELECT master_user_id, JSON_VALUE(m, '$.AccountId') AS account_id, 'member' AS role, user_deleted
FROM mu, UNNEST(members) m
WHERE JSON_VALUE(m, '$.AccountId') IS NOT NULL;
