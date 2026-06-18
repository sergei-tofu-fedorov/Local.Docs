#!/usr/bin/env bash
# Reload inv-project.ai_analysis_us.platform_user_accounts from the latest Atlas Mongo snapshot (masterUser collection).
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
# load raw (docs have nested arrays + commas -> CSV with disabled quoting + quoted-newlines allowed)
job={"configuration":{"load":{"sourceUris":[uri],"sourceFormat":"CSV","fieldDelimiter":"","quote":"",
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
# explode PlatformUserLinks x OwnedAccounts -> flat (public_id -> account_id) map, clustered by platform_user_id
q=("CREATE OR REPLACE TABLE `inv-project.ai_analysis_us.platform_user_accounts` "
   "CLUSTER BY platform_user_id AS "
   "WITH mu AS (SELECT JSON_VALUE(raw,'$._id') master_user_id, "
   "JSON_QUERY_ARRAY(raw,'$.PlatformUserLinks') links, JSON_QUERY_ARRAY(raw,'$.OwnedAccounts') accts, "
   "JSON_VALUE(raw,'$.DeletedAt') deleted_at "
   "FROM `inv-project.ai_analysis_us.master_user_raw` WHERE STARTS_WITH(raw,'{')) "
   "SELECT master_user_id, JSON_VALUE(l,'$.PlatformId') platform_user_id, "
   "SUBSTR(JSON_VALUE(l,'$.PlatformId'),1,25) public_id, "
   "SAFE_CAST(JSON_VALUE(l,'$.Platform.\"$numberInt\"') AS INT64) platform, "
   "JSON_VALUE(l,'$.Product') product, JSON_VALUE(a,'$.AccountId') account_id, "
   "deleted_at IS NOT NULL AS user_deleted "
   "FROM mu, UNNEST(links) l, UNNEST(accts) a")
post("https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/queries", {"query":q,"useLegacySql":False,"timeoutMs":180000})
post("https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/queries",
     {"query":"DROP TABLE IF EXISTS `inv-project.ai_analysis_us.master_user_raw`","useLegacySql":False})
print("platform_user_accounts rebuilt; raw dropped.")
PY
gcloud config set account s.fedorov@tofu.com >/dev/null 2>&1 || true
