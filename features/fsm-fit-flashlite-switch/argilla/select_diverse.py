"""Select ~200 NON-EASY, INDUSTRY-DIVERSE, NON-3A-heavy accounts for human Argilla judging.
Source = the difficulty-tagged pool web-1525-fsmfit-seed/candidates.json. Excludes everything already
judged / in Argilla (200 seed + 36 sparse + 140 gold + 65 3A-contested). 3A is capped low; the other 20
industries carry the set. 'non-easy' = difficulty_score >= 1, ranked desc."""
import json, os, hashlib
from collections import defaultdict, Counter

HERE = os.path.dirname(os.path.abspath(__file__))
SEED = os.path.normpath(os.path.join(HERE, "..", "web-1525-fsmfit-seed"))
EVAL = os.path.normpath(os.path.join(HERE, "..", "bq-batch-fsm-fit", "eval"))
THREE_A = {"cleaning", "lawn_care_maintenance", "landscaping", "pool_spa_service"}
TARGET = 200
NON3A_PER = 8           # ALL 24 industries get an equal share (~8 each); 3A included, just not dominant
THREEA_PER = 8

def fp(a): return int(hashlib.sha1(a.encode()).hexdigest(), 16)
def is_true(v): return v is True or v == "true"

# ---- exclusions: everything already handled ----
excl = set()
for wf in (os.path.join(SEED, "seed_worksheet.json"), os.path.join(SEED, "sparse_worksheet.json")):
    if os.path.exists(wf):
        for r in json.load(open(wf, encoding="utf-8")): excl.add(r["account_id"])
for gf in (os.path.join(EVAL, "gold.jsonl"), os.path.join(EVAL, "gold_3a.jsonl")):
    if os.path.exists(gf):
        for line in open(gf, encoding="utf-8"):
            if line.strip(): excl.add(json.loads(line)["account_id"])

pool = [r for r in json.load(open(os.path.join(SEED, "candidates.json"), encoding="utf-8"))
        if r["account_id"] not in excl and int(r["difficulty_score"]) >= 1]
for r in pool: r["_d"] = int(r["difficulty_score"]); r["_fp"] = fp(r["account_id"])
print(f"pool (excl {len(excl)} already-handled, difficulty>=1): {len(pool)}")

by_ind = defaultdict(list)
for r in pool: by_ind[r["industry"]].append(r)
for ind in by_ind:
    by_ind[ind].sort(key=lambda r: (-r["_d"], -r["_fp"]))   # hardest first, deterministic

non3a = sorted(i for i in by_ind if i not in THREE_A)
threea = sorted(i for i in by_ind if i in THREE_A)

picked, taken = [], Counter()
def take(ind, n):
    avail = [r for r in by_ind[ind] if r["account_id"] not in {p["account_id"] for p in picked}]
    for r in avail[:n]:
        picked.append(r); taken[ind] += 1

for ind in non3a: take(ind, NON3A_PER)     # ~10 each from the 20 non-3A industries
for ind in threea: take(ind, THREEA_PER)   # ~3 each from 3A (token)

# top up to TARGET from the hardest remaining accounts across ALL 24 industries
if len(picked) < TARGET:
    chosen = {p["account_id"] for p in picked}
    rest = sorted((r for ind in by_ind for r in by_ind[ind] if r["account_id"] not in chosen),
                  key=lambda r: (-r["_d"], -r["_fp"]))
    for r in rest[:TARGET - len(picked)]:
        picked.append(r); taken[r["industry"]] += 1
# trim if slightly over
picked = picked[:TARGET]

print(f"\nselected: {len(picked)} | 3A share: {sum(1 for p in picked if p['industry'] in THREE_A)}")
print("by industry:", dict(sorted(taken.items(), key=lambda kv: -kv[1])))

def row_ws(r):
    return {
        "account_id": r["account_id"], "business_name": r.get("business_name"),
        "items": r.get("items_str"), "n_items": r.get("n_items"),
        "prod_industry": r["industry"], "prod_tier": r["tier"], "prod_score": r["score"],
        "prod_flags": {k: is_true(r.get(k)) for k in
            ["on_site_work","labour_billing","scheduling","recurring_billing",
             "complex_multi_line_jobs","contract_based_billing"]},
        "prod_reasoning": r.get("reasoning"),
        "metrics": {k: r.get(k) for k in
            ["invoice_count_30d","avg_invoice_amount","avg_line_items_per_invoice",
             "repeat_customer_ratio","multi_address_work","b2b_clients_present","distinct_addresses"]},
        "difficulty_tags": [t for t in
            ["t_homonym","t_generic","t_sparse","t_borderline","t_inconsistent",
             "t_recur_reactive","t_mixed","t_reason_contra"] if is_true(r.get(t))],
        "difficulty_score": r["_d"],
    }
ws = [row_ws(r) for r in picked]
json.dump(ws, open(os.path.join(HERE, "judge_worksheet.json"), "w", encoding="utf-8"),
          ensure_ascii=False, indent=1)
print(f"\nwrote judge_worksheet.json ({len(ws)})")
print("tier:", dict(Counter(p["tier"] for p in picked)),
      "| avg difficulty:", round(sum(p['_d'] for p in picked)/len(picked), 2))
print("difficulty buckets:", dict(Counter(t for w in ws for t in w["difficulty_tags"])))
