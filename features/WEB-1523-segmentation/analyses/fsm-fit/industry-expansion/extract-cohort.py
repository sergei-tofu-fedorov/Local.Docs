"""Extract the strong+other cohort from the v3 sweep and emit a TSV of
specializations with count >= THRESHOLD, each carrying example business names
and example top-item names for downstream clustering.

Inputs:
  prototype/v3/results.jsonl     — per-account emits (filter v3-with-backend)
  prototype/v3/accounts/*.json   — per-account payloads (for top_item_names)

Outputs:
  industry-expansion/strong-other-specs.tsv

Run from the WEB-1523-segmentation folder:
  python analyses/fsm-fit/industry-expansion/extract-cohort.py
"""
from __future__ import annotations

import json
import os
from collections import defaultdict
from pathlib import Path

THRESHOLD = 5
MAX_EXAMPLES = 5
MAX_TOP_ITEMS = 5

ROOT = Path(__file__).resolve().parents[3]
RESULTS = ROOT / "prototype" / "v3" / "results.jsonl"
ACCOUNTS_DIR = ROOT / "prototype" / "v3" / "accounts"
OUT_TSV = Path(__file__).resolve().parent / "strong-other-specs.tsv"


def load_cohort():
    """Yield (account_id, business_name, specialization) for v3 strong+other rows."""
    with RESULTS.open(encoding="utf-8") as f:
        for line in f:
            row = json.loads(line)
            if row.get("prompt_version") != "v3-with-backend":
                continue
            if row.get("tier") != "strong":
                continue
            if row.get("industry") != "other":
                continue
            yield row["account_id"], row.get("business_name") or "", (row.get("specialization") or "").strip()


def load_top_items(account_id: str) -> list[str]:
    # Account files are named "<account_id>.json"; tolerate missing files (the
    # prototype folder may not contain every account from the sweep).
    path = ACCOUNTS_DIR / f"{account_id}.json"
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return []
    items = (data.get("invoice") or {}).get("top_item_names") or []
    return [(it.get("name") or "").strip() for it in items if (it.get("name") or "").strip()]


def main() -> None:
    by_spec_count: dict[str, int] = defaultdict(int)
    by_spec_examples: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for account_id, business_name, spec in load_cohort():
        if not spec or spec.lower() == "unspecified":
            continue
        by_spec_count[spec] += 1
        if len(by_spec_examples[spec]) < MAX_EXAMPLES:
            by_spec_examples[spec].append((account_id, business_name))

    surviving = sorted(
        ((spec, n) for spec, n in by_spec_count.items() if n >= THRESHOLD),
        key=lambda kv: (-kv[1], kv[0].lower()),
    )

    OUT_TSV.parent.mkdir(parents=True, exist_ok=True)
    with OUT_TSV.open("w", encoding="utf-8", newline="") as out:
        out.write("count\tspecialization\texample_business_names\texample_top_items\n")
        for spec, count in surviving:
            examples = by_spec_examples[spec]
            business_names = " | ".join(sorted({bn for _, bn in examples if bn})[:MAX_EXAMPLES])
            top_items_set: list[str] = []
            for account_id, _ in examples:
                for name in load_top_items(account_id):
                    if name not in top_items_set:
                        top_items_set.append(name)
                    if len(top_items_set) >= MAX_TOP_ITEMS:
                        break
                if len(top_items_set) >= MAX_TOP_ITEMS:
                    break
            top_items = " | ".join(top_items_set)
            spec_clean = spec.replace("\t", " ").replace("\n", " ")
            business_names = business_names.replace("\t", " ").replace("\n", " ")
            top_items = top_items.replace("\t", " ").replace("\n", " ")
            out.write(f"{count}\t{spec_clean}\t{business_names}\t{top_items}\n")

    cohort_total = sum(by_spec_count.values())
    surviving_total = sum(n for _, n in surviving)
    print(f"cohort rows (non-empty spec): {cohort_total}")
    print(f"unique specs: {len(by_spec_count)}")
    print(f"specs with count >= {THRESHOLD}: {len(surviving)}")
    print(f"accounts covered by surviving specs: {surviving_total} ({surviving_total/cohort_total:.1%})")
    print(f"wrote: {OUT_TSV}")


if __name__ == "__main__":
    main()
