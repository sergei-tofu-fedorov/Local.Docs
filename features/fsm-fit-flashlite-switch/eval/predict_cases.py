"""Run a model over cases.jsonl → predictions json keyed by case id (for run_eval.py).
Reuses the seed runners' call logic. Default = flash-lite (Vertex). Set FSMFIT_OUT for the output name.

  python predict_cases.py                       # flash-lite, current FsmFitPrompt (v9)
  FSMFIT_OUT=nano_pred.json python predict_cases.py --model nano
"""
import argparse, json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
SEED = os.path.normpath(os.path.join(HERE, "..", "web-1525-fsmfit-seed"))
sys.path.insert(0, SEED)

def items_str(item_names):
    return " | ".join(f"{t['name']} x{t['count']}" for t in (item_names or []))

def rows():
    out = []
    for line in open(os.path.join(HERE, "cases.jsonl"), encoding="utf-8"):
        line = line.strip()
        if not line: continue
        c = json.loads(line)
        out.append({"account_id": c["id"], "business_name": c.get("business_name"),
                    "items": items_str(c.get("item_names")), "metrics": c.get("metrics") or {}})
    return out

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--model", default="flashlite", choices=["flashlite","nano"])
    a = ap.parse_args()
    mod = __import__("flash_lite_run" if a.model=="flashlite" else "nano_run")
    out = os.environ.get("FSMFIT_OUT", f"{a.model}_pred.json")
    preds = {}
    for w in rows():
        r = mod.call(w)
        preds[w["account_id"]] = {"industry": r.get("industry"), "flags": r.get("flags", {})} if "flags" in r else {"error": r.get("error")}
    json.dump(preds, open(os.path.join(HERE, out), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    errs = [k for k,v in preds.items() if "error" in v]
    print(f"wrote {out} ({len(preds)} preds, {len(errs)} errors)")

if __name__ == "__main__":
    main()
