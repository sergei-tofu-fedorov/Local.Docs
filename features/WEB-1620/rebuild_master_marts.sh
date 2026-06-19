#!/usr/bin/env bash
# Rebuild the masterUser-derived BQ tables (WEB-1620 §3 three-layer design):
#   Layer 1  master_user_raw        (landing, raw STRING, PERSISTED — not dropped)
#   Layer 2  master_owned_accounts  + master_platform_links   (flat bridge marts)
# Additive: does NOT touch the deployed platform_user_accounts (still read by the account_subscriptions
# scheduled query). The mart SQL is the sibling *.sql files (source of truth) — this script just loads + runs them.
# Layer 3 account_current_plan is built separately (see account_current_plan.sql; depends on GAP 3).
#
# Identity: tofu-ai SA (reads the backup bucket + writes inv-project). bq CLI is broken here → BQ REST.
# Usage:  bash rebuild_master_marts.sh [SNAPSHOT_DATE e.g. 2026-06-17T1613]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

OWNED_SQL=$(cat "$HERE/master_owned_accounts.sql")
LINKS_SQL=$(cat "$HERE/master_platform_links.sql")

python - "$TOKEN" "$URI" "$OWNED_SQL" "$LINKS_SQL" <<'PY'
import sys, json, urllib.request, time
token, uri, owned_sql, links_sql = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def post(url, body):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(body).encode(),
        headers={"Authorization":"Bearer "+token,"Content-Type":"application/json"})))
def query(q):
    r = post("https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/queries",
             {"query":q,"useLegacySql":False,"timeoutMs":300000})
    e = r.get("errors")
    print("  ERROR", e) if e else print("  rows:", r.get("totalRows","?"))

# Layer 1 — load masterUser docs as raw STRING (nested arrays + commas → CSV w/ no delimiter/quote)
job={"configuration":{"load":{"sourceUris":[uri],"sourceFormat":"CSV","fieldDelimiter":"","quote":"",
  "allowQuotedNewlines":True,"allowJaggedRows":True,
  "schema":{"fields":[{"name":"raw","type":"STRING"}]},
  "destinationTable":{"projectId":"inv-project","datasetId":"ai_analysis_us","tableId":"master_user_raw"},
  "writeDisposition":"WRITE_TRUNCATE"}}}
jid=post("https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/jobs", job)['jobReference']['jobId']
for _ in range(90):
    s=json.load(urllib.request.urlopen(urllib.request.Request(
        "https://bigquery.googleapis.com/bigquery/v2/projects/inv-project/jobs/%s?location=US"%jid,
        headers={"Authorization":"Bearer "+token})))
    if s['status']['state']=='DONE':
        e=s['status'].get('errorResult')
        print("load master_user_raw:", "ERROR "+e['message'] if e else "OK rows=%s"%s['statistics']['load']['outputRows']); break
    time.sleep(4)

# Layer 2 — build the two marts from the persisted landing (raw is NOT dropped)
print("build master_owned_accounts:"); query(owned_sql)
print("build master_platform_links:"); query(links_sql)
print("done — master_user_raw persisted; platform_user_accounts left untouched.")
PY
gcloud config set account s.fedorov@tofu.com >/dev/null 2>&1 || true
