#!/usr/bin/env bash
# Reload the masterUser-derived tables in inv-project.ai_analysis_us from the latest Atlas Mongo snapshot:
#   master_users            (nested, source of truth: ARRAY<STRUCT> links + owned accounts)
#   platform_user_accounts  (materialized first-link bridge derived from master_users; compat + clustered)
#   platform_user_canonical (VIEW: any link's id -> its master's IsFirstLink identity)
# Like reload_account_identifiers.sh, this is a BigQuery *load job* (snapshot path has a daily DATE folder), not a
# scheduled query. Run periodically. Identity: tofu-ai SA (reads the backup bucket).
#
# Model: masterUser.PlatformUserLinks[].PlatformId is the platform user id sent to Subz; events.account_id (PublicId)
# = SUBSTR(PlatformId,1,25). masterUser.OwnedAccounts[].AccountId = the invoices account(s) the user owns (1:many).
#
# Usage:  bash reload_master_user.sh [SNAPSHOT_DATE e.g. 2026-06-17T1613]
set -euo pipefail
SA_KEY="C:/Files/SA/tofu-ai-backend@inv-project.iam.gserviceaccount.com/inv-project-e097726fbd27.json"
BUCKET="atlas-snap-export-production"
ROOT="exported_snapshots/5a58ddfbdf9db10eed1cc64d/5a58ddfbdf9db10eed1cc650/InvoicesCluster"

gcloud auth activate-service-account --key-file="$SA_KEY" >/dev/null 2>&1
TOKEN=$(gcloud auth print-access-token --account=tofu-ai-backend@inv-project.iam.gserviceaccount.com)

DATE="${1:-}"
if [ -z "$DATE" ]; then
  DATE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://storage.googleapis.com/storage/v1/b/$BUCKET/o?delimiter=/&prefix=$ROOT/" \
    | python -c "import sys,json;ps=json.load(sys.stdin).get('prefixes',[]);print(sorted(p.rstrip('/').split('/')[-1] for p in ps)[-1])")
fi
EPOCH=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://storage.googleapis.com/storage/v1/b/$BUCKET/o?delimiter=/&prefix=$ROOT/$DATE/" \
  | python -c "import sys,json;ps=json.load(sys.stdin).get('prefixes',[]);print(ps[0].rstrip('/').split('/')[-1])")
URI="gs://$BUCKET/$ROOT/$DATE/$EPOCH/invoicesDB/masterUser/*.json.gz"
echo "Loading $URI"

python - "$TOKEN" "$URI" <<'PY'
import sys, json, urllib.request, time
token, uri = sys.argv[1], sys.argv[2]
def post(url, body):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(body).encode(),
        headers={"Authorization":"Bearer "+token,"Content-Type":"application/json"})))
# load raw: one JSON doc per line -> single STRING column. fieldDelimiter is a literal SOH (, shown as
# ^A / invisible) because it never appears in the docs; BQ treats "" as comma and would split the JSON. Do
# not "fix" the empty-looking delimiter below.
job={"configuration":{"load":{"sourceUris":[uri],"sourceFormat":"CSV","fieldDelimiter":"","quote":"",
  "allowQuotedNewlines":True,"allowJaggedRows":True,
  "schema":{"fields":[{"name":"raw","type":"STRING"}]},
  "destinationTable":{"projectId":"inv-project","datasetId":"ai_analysis_us","tableId":"master_user_raw"},
  "writeDisposition":"WRITE_TRUNCATE"}}}
jid=post("https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/jobs", job)['jobReference']['jobId']
for _ in range(60):
    s=json.load(urllib.request.urlopen(urllib.request.Request(
        "https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/jobs/%s?location=US"%jid,
        headers={"Authorization":"Bearer "+token})))
    if s['status']['state']=='DONE':
        e=s['status'].get('errorResult'); print("load:", "ERROR "+e['message'] if e else "OK rows=%s"%s['statistics']['load']['outputRows']); break
    time.sleep(4)
QURL="https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/queries"
JURL="https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/jobs/%s?location=US"
def run_sql(sql, label):  # jobs.query, then poll the job if it didn't finish synchronously
    r=post(QURL, {"query":sql,"useLegacySql":False,"timeoutMs":150000})
    if r.get("jobComplete"): print(label,"OK"); return
    jid=r["jobReference"]["jobId"]
    for _ in range(120):
        s=json.load(urllib.request.urlopen(urllib.request.Request(JURL%jid,
            headers={"Authorization":"Bearer "+token})))
        if s['status']['state']=='DONE':
            e=s['status'].get('errorResult'); print(label, "ERROR "+e['message'] if e else "OK"); return
        time.sleep(3)
    print(label,"TIMEOUT")

# 1) Nested source of truth: one row per master user, faithful ARRAY<STRUCT> of links + owned accounts.
#    No fan-out; all first-link / by-product / canonical policy is applied downstream via UNNEST.
mu_sql='''CREATE OR REPLACE TABLE `inv-project.ai_analysis_us.master_users` CLUSTER BY master_user_id AS
WITH mu AS (
  SELECT JSON_VALUE(raw,'$._id') master_user_id, JSON_VALUE(raw,'$.DeletedAt') deleted_at,
    JSON_QUERY_ARRAY(raw,'$.PlatformUserLinks') links, JSON_QUERY_ARRAY(raw,'$.OwnedAccounts') accts
  FROM `inv-project.ai_analysis_us.master_user_raw` WHERE STARTS_WITH(raw,'{'))
SELECT master_user_id, deleted_at IS NOT NULL AS user_deleted,
  ARRAY(SELECT AS STRUCT
    JSON_VALUE(l,'$.PlatformId') platform_user_id,
    SUBSTR(JSON_VALUE(l,'$.PlatformId'),1,25) public_id,
    SAFE_CAST(JSON_VALUE(l,'$.Platform."$numberInt"') AS INT64) platform,
    JSON_VALUE(l,'$.Product') product,
    SAFE_CAST(JSON_VALUE(l,'$.IsFirstLink') AS BOOL) is_first_link,
    TIMESTAMP_MILLIS(SAFE_CAST(JSON_VALUE(l,'$.CreatedAt."$date"."$numberLong"') AS INT64)) created_at
    FROM UNNEST(links) l) links,
  ARRAY(SELECT AS STRUCT
    JSON_VALUE(a,'$.AccountId') account_id,
    JSON_VALUE(a,'$.OwnedAccountMeta.AssignedBy.PlatformId') assigned_by_platform_id
    FROM UNNEST(accts) a) accounts
FROM mu'''

# 2) First-link bridge (kept materialized + clustered for compat): canonical link x owned accounts.
pua_sql='''CREATE OR REPLACE TABLE `inv-project.ai_analysis_us.platform_user_accounts` CLUSTER BY platform_user_id AS
WITH fl AS (
  SELECT master_user_id, user_deleted, accounts,
    (SELECT AS STRUCT l.platform_user_id, l.public_id, l.platform, l.product
     FROM UNNEST(links) l ORDER BY l.is_first_link DESC, l.created_at LIMIT 1) link
  FROM `inv-project.ai_analysis_us.master_users`)
SELECT master_user_id, link.platform_user_id platform_user_id, link.public_id public_id,
  link.platform platform, link.product product, a.account_id, user_deleted
FROM fl, UNNEST(accounts) a'''

# 3) Canonical map (view): any link's (platform_user_id/public_id) -> its master's IsFirstLink identity.
#    Lets a non-first-link id (e.g. from accountIdentifiers) resolve to the first-link platform user.
canon_sql='''CREATE OR REPLACE VIEW `inv-project.ai_analysis_us.platform_user_canonical` AS
WITH fl AS (
  SELECT master_user_id,
    ARRAY_AGG(STRUCT(l.platform_user_id, l.public_id)
              ORDER BY l.is_first_link DESC, l.created_at LIMIT 1)[OFFSET(0)] first
  FROM `inv-project.ai_analysis_us.master_users`, UNNEST(links) l GROUP BY master_user_id)
SELECT l.platform_user_id, l.public_id, l.is_first_link, m.master_user_id,
  fl.first.platform_user_id first_link_platform_user_id, fl.first.public_id first_link_public_id
FROM `inv-project.ai_analysis_us.master_users` m, UNNEST(m.links) l JOIN fl USING (master_user_id)'''

run_sql(mu_sql,    "master_users:")
run_sql(pua_sql,   "platform_user_accounts:")
run_sql(canon_sql, "platform_user_canonical view:")
post(QURL, {"query":"DROP TABLE IF EXISTS `inv-project.ai_analysis_us.master_user_raw`","useLegacySql":False})
print("master_users + platform_user_accounts + platform_user_canonical rebuilt; raw dropped.")
PY
gcloud config set account s.fedorov@tofu.com >/dev/null 2>&1 || true
