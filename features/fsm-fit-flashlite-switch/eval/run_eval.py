"""Score any model's FSM-fit predictions against the behavioural suite (cases.jsonl).

Predictions file = JSON dict keyed by case `id`:
  { "ind-plumbing": {"industry": "plumbing",
                     "flags": {"on_site_work": true, "labour_billing": true, ...}}, ... }
(a flat form {"industry":..., "on_site_work":..., ...} per id is also accepted.)

Usage:
  python run_eval.py --validate                 # check cases.jsonl + print coverage, no predictions needed
  python run_eval.py --pred flashlite_pred.json # score; add --thresholds for pass/fail gates
"""
import argparse, json, os, sys
from collections import defaultdict, Counter

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "cases.jsonl")
INDUSTRIES = {"general_contracting","electrical","hvac","locksmith","mechanical_service",
    "plumbing","handyman","appliance_repair","flooring","junk_removal","painting","pest_control",
    "pool_spa_service","renovations","roofing","cleaning","arborist_tree_care","landscaping",
    "lawn_care_maintenance","snow_removal","computers_it","home_theater","security_alarm","other"}
FLAGS = ["on_site_work","labour_billing","scheduling","recurring_billing",
         "complex_multi_line_jobs","contract_based_billing"]
THRESH = {"industry_acc": 0.90, "flag_acc": 0.85, "dim_pass": 0.80}

def load_cases():
    cases = []
    for i, line in enumerate(open(CASES, encoding="utf-8"), 1):
        line = line.strip()
        if not line: continue
        try: c = json.loads(line)
        except json.JSONDecodeError as e: sys.exit(f"cases.jsonl line {i}: invalid JSON: {e}")
        for k in ("id","expected"): assert k in c, f"line {i}: missing {k}"
        e = c["expected"]
        assert e["industry"] in INDUSTRIES, f"{c['id']}: bad industry {e['industry']}"
        for f in FLAGS: assert f in e, f"{c['id']}: missing flag {f}"
        cases.append(c)
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids)), "duplicate case ids"
    return cases

def coverage(cases):
    inds = Counter(c["expected"]["industry"] for c in cases)
    print(f"cases: {len(cases)} | industries covered: {len(inds)}/24")
    missing = sorted(INDUSTRIES - set(inds))
    if missing: print(f"  industries with NO case: {missing}")
    print("  flag TRUE/FALSE coverage (need both per flag):")
    for f in FLAGS:
        t = sum(1 for c in cases if c["expected"][f]); fa = len(cases)-t
        warn = "  ⚠ missing one polarity" if (t==0 or fa==0) else ""
        print(f"    {f:24} TRUE={t:3} FALSE={fa:3}{warn}")
    dims = Counter(d for c in cases for d in c.get("dim",[]))
    print("  dim coverage:", dict(dims.most_common()))

def norm_pred(p):
    if "flags" in p: return p.get("industry"), {f: bool(p["flags"].get(f)) for f in FLAGS}
    return p.get("industry"), {f: bool(p.get(f)) for f in FLAGS}

def macro_f1(cases, pred):
    # per-industry P/R/F1 over the cases, unweighted mean (small-N: indicative, not absolute)
    tp=Counter(); fp=Counter(); fn=Counter()
    for c in cases:
        g=c["expected"]["industry"]; pi=pred.get(c["id"],(None,None))[0]
        if pi==g: tp[g]+=1
        else: fn[g]+=1; (fp.update([pi]) if pi else None)
    f1s=[]
    for ind in set(list(tp)+list(fn)):
        p = tp[ind]/(tp[ind]+fp[ind]) if (tp[ind]+fp[ind]) else 0.0
        r = tp[ind]/(tp[ind]+fn[ind]) if (tp[ind]+fn[ind]) else 0.0
        f1s.append(2*p*r/(p+r) if (p+r) else 0.0)
    return sum(f1s)/len(f1s) if f1s else 0.0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pred"); ap.add_argument("--validate", action="store_true")
    ap.add_argument("--thresholds", action="store_true")
    a = ap.parse_args()
    cases = load_cases()
    print("=== cases.jsonl OK ==="); coverage(cases)
    if a.validate or not a.pred: return

    raw = json.load(open(a.pred, encoding="utf-8"))
    pred = {cid: norm_pred(p) for cid, p in raw.items()}
    miss = [c["id"] for c in cases if c["id"] not in pred]
    if miss: print(f"\n⚠ predictions missing for {len(miss)} cases: {miss[:8]}")

    n=len(cases)
    ind_ok=sum(1 for c in cases if pred.get(c["id"],(None,None))[0]==c["expected"]["industry"])
    print(f"\n=== INDUSTRY ===\n  accuracy: {ind_ok}/{n} = {ind_ok/n:.0%} | macro-F1: {macro_f1(cases,pred):.2f}")
    for c in cases:
        g=c["expected"]["industry"]; pi=pred.get(c["id"],(None,None))[0]
        if pi!=g: print(f"    MISS {c['id']:38} gold={g:20} got={pi}")

    print("\n=== FLAGS (acc | precision | recall | over/under vs gold) ===")
    flagfail=[]
    for f in FLAGS:
        tp=fp=fn=tn=0
        for c in cases:
            g=c["expected"][f]; pf=pred.get(c["id"],(None,{}))[1].get(f) if c["id"] in pred else None
            if pf is None: continue
            if g and pf: tp+=1
            elif g and not pf: fn+=1
            elif (not g) and pf: fp+=1
            else: tn+=1
        tot=tp+fp+fn+tn
        acc=(tp+tn)/tot if tot else 0; prec=tp/(tp+fp) if (tp+fp) else 0; rec=tp/(tp+fn) if (tp+fn) else 0
        if acc<THRESH["flag_acc"]: flagfail.append(f)
        print(f"  {f:24} acc {acc:.0%} | P {prec:.0%} | R {rec:.0%} | over {fp} / under {fn}")

    print("\n=== PER DIMENSION (scores the PROBED thing: flag-dim -> that flag; industry/trap/boundary/name-only -> industry) ===")
    dim_tot=defaultdict(int); dim_ok=defaultdict(int); dimfail=[]
    def dim_correct(c, pi, pf, d):
        if d in FLAGS: return pf.get(d) == c["expected"][d]
        return pi == c["expected"]["industry"]   # industry / trap / boundary / name-only
    for c in cases:
        pi,pf=pred.get(c["id"],(None,{}))
        for d in c.get("dim",["(none)"]):
            dim_tot[d]+=1; dim_ok[d]+= 1 if dim_correct(c,pi,pf,d) else 0
    for d in sorted(dim_tot):
        r=dim_ok[d]/dim_tot[d]
        if r<THRESH["dim_pass"]: dimfail.append(d)
        print(f"  {d:24} {dim_ok[d]}/{dim_tot[d]} = {r:.0%}")
    exact=sum(1 for c in cases if (lambda pi,pf: pi==c["expected"]["industry"] and all(pf.get(f)==c["expected"][f] for f in FLAGS))(*pred.get(c["id"],(None,{}))))
    print(f"  {'[exact: all 6 flags+ind]':24} {exact}/{n} = {exact/n:.0%}")

    if a.thresholds:
        print("\n=== THRESHOLD GATES ===")
        ip = ind_ok/n >= THRESH["industry_acc"]
        print(f"  industry acc >= {THRESH['industry_acc']:.0%}: {'PASS' if ip else 'FAIL'}")
        print(f"  every flag acc >= {THRESH['flag_acc']:.0%}: {'PASS' if not flagfail else 'FAIL '+str(flagfail)}")
        print(f"  every dim pass >= {THRESH['dim_pass']:.0%}: {'PASS' if not dimfail else 'FAIL '+str(dimfail)}")
        sys.exit(0 if (ip and not flagfail and not dimfail) else 1)

if __name__ == "__main__":
    main()
