"""Rebuild judge_worksheet.json (the PII-bearing input) from BigQuery, on any machine.

The public repo stores only sample_manifest.json (200 account_ids + prod label/tier/difficulty,
NO names/items/financials). This script pulls business_name + top_item_names + metrics for those
ids from inv-project.ai_analysis_us.mart_account_metrics and reconstitutes the worksheet locally.
The output judge_worksheet.json is .gitignored — it is regenerated, never committed.

Prereqs: gcloud/bq authenticated as an identity with READ on inv-project BQ (s.fedorov read-only
is enough). Cost: a few hundred MB scan (cost-conscious -> run with --dry-run first to see bytes).

  python rebuild_worksheet.py --dry-run     # print scanned bytes estimate, do nothing
  python rebuild_worksheet.py               # write judge_worksheet.json (200)

Then: python build_load_argilla.py          # (re)create the Argilla dataset from worksheet + preds
"""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = "inv-project"
TABLE = "`inv-project.ai_analysis_us.mart_account_metrics`"
METRIC_KEYS = ["invoice_count_30d", "avg_invoice_amount", "avg_line_items_per_invoice",
               "repeat_customer_ratio", "multi_address_work", "b2b_clients_present", "distinct_addresses"]
FLAGS = ["on_site_work", "labour_billing", "scheduling", "recurring_billing",
         "complex_multi_line_jobs", "contract_based_billing"]


def bq(sql, dry_run=False):
    """Run a query via the bq CLI, feeding the SQL on stdin (bq reads the query from stdin when
    none is given). stdin avoids quoting a 200-id IN-list / cmd.exe line-length limits on Windows.

    PYTHONUTF8=1 forces bq's own Python to UTF-8 so non-ASCII business names don't make it abort;
    errors='replace' on our side is a final guard. NB: on Windows the bq CLI may still substitute a
    few non-ASCII chars (e.g. a smart apostrophe) with U+FFFD '�' — cosmetic only, the trade is
    still readable; it does not affect labelling."""
    cmd = f"bq query --use_legacy_sql=false --project_id={PROJECT} --format=json --max_rows=100000 --quiet"
    if dry_run:
        cmd += " --dry_run"
    env = {**os.environ, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"}
    p = subprocess.run(cmd, shell=True, input=sql, capture_output=True,
                       encoding="utf-8", errors="replace", env=env)
    if p.returncode != 0:
        sys.exit(f"bq failed (rc={p.returncode}):\n{p.stderr or p.stdout}")
    return p.stdout or ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="print scanned-bytes estimate only")
    args = ap.parse_args()

    manifest = json.load(open(os.path.join(HERE, "sample_manifest.json"), encoding="utf-8"))
    by_id = {m["account_id"]: m for m in manifest}
    id_list = ",".join("'" + a.replace("'", "") + "'" for a in by_id)

    sql = f"""
SELECT
  account_id,
  business_name,
  ARRAY_LENGTH(top_item_names) AS n_items,
  (SELECT STRING_AGG(FORMAT('%s x%d', t.name, t.count), ' | ' ORDER BY t.count DESC)
     FROM UNNEST(top_item_names) t) AS items_str,
  {", ".join(METRIC_KEYS)}
FROM {TABLE}
WHERE account_id IN ({id_list})
"""
    if args.dry_run:
        out = bq(sql, dry_run=True)
        print(out.strip() or "(dry-run ok; see bq stderr for bytes)")
        return

    rows = {r["account_id"]: r for r in json.loads(bq(sql))}
    missing = [a for a in by_id if a not in rows]
    if missing:
        print(f"WARNING: {len(missing)} account_ids not found in BQ (warehouse drift?): {missing[:5]}...")

    worksheet = []
    for a, m in by_id.items():
        r = rows.get(a, {})
        worksheet.append({
            "account_id": a,
            "business_name": r.get("business_name"),
            "items": r.get("items_str"),
            "n_items": int(r["n_items"]) if r.get("n_items") not in (None, "") else None,
            "prod_industry": m["prod_industry"],
            "prod_tier": m["prod_tier"],
            "prod_score": None,
            "prod_flags": {k: bool(m["prod_flags"].get(k)) for k in FLAGS},
            "prod_reasoning": None,
            "metrics": {k: r.get(k) for k in METRIC_KEYS},
            "difficulty_tags": [],
            "difficulty_score": int(m["difficulty_score"]),
        })
    out = os.path.join(HERE, "judge_worksheet.json")
    json.dump(worksheet, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"wrote judge_worksheet.json ({len(worksheet)}; {len(missing)} missing)")
    print("next: python build_load_argilla.py")


if __name__ == "__main__":
    main()
