#!/usr/bin/env bash
# Reload inv-project.ai_analysis_us.account_identifiers from the latest Atlas Mongo snapshot.
# The snapshot path has a daily DATE folder, so this is a BigQuery *load job* (NOT a scheduled query).
# Run periodically (weekly is plenty — identifiers are stable). Identity: tofu-ai SA (reads the backup bucket).
#
# Usage:  bash reload_account_identifiers.sh [SNAPSHOT_DATE e.g. 2026-06-17T1613]
set -euo pipefail

SA_KEY="C:/Files/SA/tofu-ai-backend@inv-project.iam.gserviceaccount.com/inv-project-e097726fbd27.json"
BUCKET="atlas-snap-export-production"
ROOT="exported_snapshots/5a58ddfbdf9db10eed1cc64d/5a58ddfbdf9db10eed1cc650/InvoicesCluster"

gcloud auth activate-service-account --key-file="$SA_KEY" >/dev/null 2>&1
TOKEN=$(gcloud auth print-access-token --account=tofu-ai-backend@inv-project.iam.gserviceaccount.com)

# 1) find the newest snapshot date folder (or use the arg)
DATE="${1:-}"
if [ -z "$DATE" ]; then
  DATE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://storage.googleapis.com/storage/v1/b/$BUCKET/o?delimiter=/&prefix=$ROOT/" \
    | python -c "import sys,json;ps=json.load(sys.stdin).get('prefixes',[]);print(sorted(p.rstrip('/').split('/')[-1] for p in ps)[-1])")
fi
# 2) the snapshot has one epoch subfolder under the date — discover it
EPOCH=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://storage.googleapis.com/storage/v1/b/$BUCKET/o?delimiter=/&prefix=$ROOT/$DATE/" \
  | python -c "import sys,json;ps=json.load(sys.stdin).get('prefixes',[]);print(ps[0].rstrip('/').split('/')[-1])")
URI="gs://$BUCKET/$ROOT/$DATE/$EPOCH/invoicesDB/accountIdentifiers/*.json.gz"
echo "Loading $URI"

# 3) load each NDJSON line as a single raw STRING (Mongo Extended JSON has \$-prefixed field names → autodetect fails)
python - "$TOKEN" "$URI" <<'PY'
import sys, json, urllib.request, urllib.error, time
token, uri = sys.argv[1], sys.argv[2]
def post(url, body):
    req=urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Authorization":"Bearer "+token,"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(req))
job={"configuration":{"load":{"sourceUris":[uri],"sourceFormat":"CSV","fieldDelimiter":"","quote":"",
  "schema":{"fields":[{"name":"raw","type":"STRING"}]},
  "destinationTable":{"projectId":"inv-project","datasetId":"ai_analysis_us","tableId":"account_identifiers_raw"},
  "writeDisposition":"WRITE_TRUNCATE"}}}
jid=post("https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/jobs", job)['jobReference']['jobId']
for _ in range(60):
    s=json.load(urllib.request.urlopen(urllib.request.Request(
        "https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/jobs/%s?location=US"%jid,
        headers={"Authorization":"Bearer "+token})))
    if s['status']['state']=='DONE':
        err=s['status'].get('errorResult')
        print("load:", "ERROR "+err['message'] if err else "OK rows=%s"%s['statistics']['load']['outputRows']); break
    time.sleep(5)
# parse raw -> typed table, then drop raw
q=("CREATE OR REPLACE TABLE `inv-project.ai_analysis_us.account_identifiers` AS "
   "SELECT JSON_VALUE(raw,'$._id') account_id, JSON_VALUE(raw,'$.UserId') user_id, "
   "UPPER(JSON_VALUE(raw,'$.FirebaseId')) firebase_id, UPPER(JSON_VALUE(raw,'$.Idfa')) idfa, "
   "JSON_VALUE(raw,'$.AppsflyerId') appsflyer_id, JSON_VALUE(raw,'$.VendorId') vendor_id "
   "FROM `inv-project.ai_analysis_us.account_identifiers_raw` WHERE STARTS_WITH(raw,'{')")
post("https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/queries", {"query":q,"useLegacySql":False,"timeoutMs":180000})
post("https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/queries",
     {"query":"DROP TABLE IF EXISTS `inv-project.ai_analysis_us.account_identifiers_raw`","useLegacySql":False})
print("account_identifiers rebuilt; raw dropped.")
PY

gcloud config set account s.fedorov@tofu.com >/dev/null 2>&1 || true
