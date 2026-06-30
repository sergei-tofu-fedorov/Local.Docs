# Argilla judging set — `fsm-fit-judge-diverse` (portable rebuild kit)

200 NON-easy, industry-diverse prod accounts (all 24 industries, 8 each; 3A included, not dominant;
avg difficulty 2.87) for **human labelling** of FSM-fit `industry` (24) + `flags` (6). Excludes
everything already judged (200 seed + 36 sparse + 140 gold + 65 3A-contested).

## Why a rebuild kit (not the raw data)

`Local.Docs` is a **public** repo. The labelling inputs contain real `business_name` + `item_names`
(PII). So this folder commits **only**:

| Committed (PII-free) | What |
|---|---|
| `sample_manifest.json` | The 200 pinned `account_id`s + their prod label / tier / difficulty_score / prod_flags. No names, items, or financials. |
| `flashlite_pred.json`, `nano_pred.json` | Model predictions (v10) keyed by account_id — `{industry, flags}` only. Drive the Argilla suggestions + the 3-way vote display. |
| `rebuild_worksheet.py` | Pulls the PII fields (names/items/metrics) from BigQuery by account_id → local `judge_worksheet.json`. |
| `build_load_argilla.py` | Creates/loads the `fsm-fit-judge-diverse` dataset into a local Argilla from worksheet + preds. |
| `select_diverse.py` | Provenance only — how the 200 were sampled (needs the original BQ candidate pool; not part of restore). |

`judge_worksheet.json` (the rebuilt PII file) is **`.gitignored`** — regenerated on each machine, never committed.

## Restore + continue on another PC

Prereqs: Python with `argilla` + `pandas`; a running local Argilla; `gcloud`/`bq` authenticated with
**read** access to `inv-project` BigQuery (s.fedorov read-only is enough).

```bash
# 1. start Argilla (the local docker stack)
cd C:/Git/_scratch/argilla && docker compose up -d        # UI http://localhost:6900  (argilla / 12345678)

# 2. rebuild the PII worksheet from BigQuery (cost-conscious: check bytes first)
cd <repo>/features/fsm-fit-flashlite-switch/argilla
python rebuild_worksheet.py --dry-run                     # prints scanned-bytes estimate
python rebuild_worksheet.py                               # writes judge_worksheet.json (200)

# 3. (re)create + load the dataset
python build_load_argilla.py                              # -> dataset 'fsm-fit-judge-diverse' (200)
```

Then open http://localhost:6900, dataset **`fsm-fit-judge-diverse`**, workspace `default`.

## How to label

- Filter **`metadata.all3_agree = false`** → **115** disagreement cases (the ones worth your time;
  the other 85 are unanimous across the 3 model votes).
- Per record set **`industry`** (24) + **`flags`** (6). Suggestions are pre-filled from flash-lite v10.
- `model_votes` field shows three votes, one per line: `prod-nano (v7)` (stored prod, old prompt + notes) /
  `nano (v10)` / `flash-lite (v10)`. The last two share the same no-notes input → the apples-to-apples pair.
- Guideline (definitions for the 6 flags, out-of-scope→`other`, name-only→`other`) is on the dataset.

> ⚠️ The labels you submit live in the **Argilla docker volume**, not in these files. To move
> *in-progress labels* between machines, export them (see below) and carry the export privately —
> do NOT commit the export (it embeds the PII records). The rebuild kit only reproduces the
> *unlabelled* set.

## After labelling — score the decision

Export submitted responses, then score **nano-v10 (`nano_pred.json`)** vs **flash-lite-v10
(`flashlite_pred.json`)** against your human gold (industry accuracy + macro-F1, per-flag
precision/recall + over/under direction). Recipe in `../CONTINUE-HERE.md` §2; the scorer in
`../eval/run_eval.py` can be pointed at a `{id: {industry, flags}}` predictions file vs a gold jsonl.

## Regenerating the model predictions (optional)

`flashlite_pred.json` / `nano_pred.json` are committed so restore needs no LLM calls. To regenerate
(e.g. after a prompt change), use `predict_judge.py` from the original work folder
`Investigations/fsm-fit-judge-set/` (it imports the Vertex/OpenAI wrappers from
`Investigations/web-1525-fsmfit-seed/`, which are not part of this committed kit).
