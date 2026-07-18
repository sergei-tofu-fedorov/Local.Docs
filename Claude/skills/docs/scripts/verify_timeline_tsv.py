#!/usr/bin/env python3
"""Verify the Timeline Events TSV after an edit.

Checks every data row for:
  - the same column count as the header,
  - RFC 4180 quoting (a bare `"` — inside a quoted field or not — breaks GitHub's
    TSV parser), and
  - a clean strict-CSV parse.

It also prints a per-EntityType row tally so you can eyeball that the edit landed
where you meant it to. Exits non-zero if any check fails, so it can gate a commit.

Usage:
    python verify_timeline_tsv.py ["Local.Docs/features/timeline/Timeline Events.tsv"]

The path argument is optional; it defaults to the canonical location relative to
the workspace root (run from `C:\\Git\\Work\\Backend`).
"""
import csv
import sys
from collections import Counter

DEFAULT_PATH = "Local.Docs/features/timeline/Timeline Events.tsv"


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
    lines = open(path, "r", encoding="utf-8").readlines()
    hcols = len(lines[0].rstrip("\n").split("\t"))

    bad = []   # (line_no, actual_col_count)
    qerr = []  # (line_no, col_no, message)
    for i, l in enumerate(lines[1:], 2):
        cols = l.rstrip("\n").split("\t")
        if len(cols) != hcols:
            bad.append((i, len(cols)))
        for ci, cell in enumerate(cols):
            if cell.startswith('"') and cell.endswith('"') and len(cell) > 1:
                inner = cell[1:-1]
                j = 0
                while j < len(inner):
                    if inner[j] == '"':
                        if j + 1 < len(inner) and inner[j + 1] == '"':
                            j += 2
                        else:
                            qerr.append((i, ci + 1, 'unescaped " in quoted field'))
                            break
                    else:
                        j += 1
            elif '"' in cell:
                qerr.append((i, ci + 1, 'unquoted cell contains "'))

    ent = Counter(l.split("\t")[0] for l in lines[1:])
    print(f"Lines: {len(lines)} (1 header + {len(lines) - 1} data) | Columns: {hcols}")
    for k, v in sorted(ent.items()):
        print(f"  {k}: {v}")

    ok = True
    if bad:
        ok = False
        print(f"ERROR: {len(bad)} rows have wrong column count:")
        for ln, c in bad[:5]:
            print(f"  Line {ln}: {c} cols (expected {hcols})")
    else:
        print("All row column counts OK.")

    if qerr:
        ok = False
        print(f"ERROR: {len(qerr)} quoting issues (RFC 4180):")
        for ln, col, msg in qerr[:5]:
            print(f"  Line {ln}, col {col}: {msg}")
    else:
        print("All quoting RFC 4180 compliant.")

    # Strict CSV parse as a final backstop.
    try:
        with open(path, "r", encoding="utf-8", newline="") as f:
            reader = csv.reader(f, delimiter="\t", strict=True)
            ri = 0
            for ri, _row in enumerate(reader, 1):
                pass
        print(f"Strict CSV parse: all {ri} lines OK.")
    except csv.Error as e:
        ok = False
        print(f"Strict CSV ERROR: {e}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
