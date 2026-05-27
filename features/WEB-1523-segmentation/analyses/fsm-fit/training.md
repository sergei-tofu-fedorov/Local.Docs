# WEB-1523 — FSM-fit training cycle (instance)

Instance of the per-analysis training pattern in [`../training.md`](../training.md). Captures the FSM-fit-specific choices and outcomes.

## Sample

- **Collected 2026-05-10.** Top 1,000 active accounts with **>10 invoices ever**, sorted by latest invoice `CreatedTime`.
- **Per-account payload:** `business_name` + the 10 latest invoices.
- **On-disk:** `Training/fsm_fit/accounts/`, ~32 MB total (one JSON per account).
- **Known gap:** 12 accounts have no `BusinessName` — prompt uses `"Unknown business"` fallback.
- **Provenance:** one-off collection script run against MongoDB; re-runnable manually.

## Hand-labelled seed

- **30 accounts**, stratified random from the 1,000 (~10 per `fsm_fit` tier).
- Location: `Training/fsm_fit/seed-labels/30-account-ground-truth.csv`.
- Columns: `account_id` + each evidence boolean (6 LLM + 2 backend) + `expected_tier` + `expected_industry` + `expected_recommended_offers` (CSV-encoded `offer:weight` pairs; in v1 a single entry per row). Plus context columns (`business_name`, `top_item_names`) so a reviewer can sanity-check a label without separately fetching the raw account JSON.

## How the production prompt was arrived at

**Iterative refinement on `gpt-4.1-nano`**, not a formal cross-model sweep. The team picked `gpt-4.1-nano` on cost grounds (see [`../../investigation/provider.md`](../../investigation/provider.md) § Decision) and iterated on the prompt against the hand-labelled seed:

- **v1-zero-shot** — initial prompt with the 4-boolean evidence shape; ~600 tokens.
- **v2-baseline** — refined instructions; ~750 tokens.
- **v3-with-backend** — current production. Adds 2 evidence booleans (`complex_multi_line_jobs`, `contract_based_billing`), constrains `industry` to the 24-ID canonical enum, adds in-prompt examples + FSM-suited / FSM-poor industry lists. ~1,400 tokens (deliberately past OpenAI's 1,024-token caching floor — see [`../../investigation/provider.md`](../../investigation/provider.md) § 1).

Source of truth: [`Investigation/main-1361-collect/analyze-exports.js`](../../../../Investigation/main-1361-collect/analyze-exports.js) `SYSTEM_PROMPT`. Mirrored verbatim in [`scoring.md`](scoring.md) § System prompt.

Production lock: **`gpt-4.1-nano` + v3-with-backend prompt + rule v3**, validated by the 2026-05-13 1,000-account run.

## Prompt iteration

Open issues in the current prompt live at the bottom of [`prompt.md`](prompt.md). Follow the workflow in [`../training.md`](../training.md) § Prompt iteration:

1. Pick an open issue from [`prompt.md`](prompt.md).
2. Edit `Investigation/main-1361-collect/analyze-exports.js` `SYSTEM_PROMPT`.
3. Mirror the edit in [`prompt.md`](prompt.md) (the docs block must match the production source line-for-line).
4. Re-run on the 30-seed; diff tier outputs vs the prior run with `scripts/diff_runs.py`.
5. Spot-check the changed accounts.
6. Ship if no regressions; bump `prompt_version`.

## Rule weight tuning — Optuna

The rule's 8 evidence weights + FSM-suited industry bonus + 2 tier thresholds are tunable. Script at `Training/fsm_fit/scripts/optimize_weights.py` runs Optuna against the seed using stored LLM emit from the most recent run. **Zero LLM cost** — the LLM call already happened.

### Inputs

- Stored LLM emit: any results JSONL produced by the locked prompt (the most recent run's `results.jsonl`).
- Seed labels: `Training/fsm_fit/seed-labels/30-account-ground-truth.csv`.
- Hand-tuned baseline (current production): `{on_site_work: 0.40, labour_billing: 0.25, scheduling: 0.15, recurring_billing: 0.10, complex_multi_line_jobs: 0.15, contract_based_billing: 0.10, b2b_clients_present: 0.10, multi_address_work: 0.05, industry_bonus: 0.10, t_weak: 0.30, t_strong: 0.65}` — used as the regularisation target.

### Script skeleton

```python
import json, pandas as pd, optuna
from sklearn.metrics import f1_score
from sklearn.model_selection import KFold

results = [json.loads(line) for line in open("results.jsonl")]
seed    = pd.read_csv("seed-labels/30-account-ground-truth.csv")
joined  = seed.merge(pd.DataFrame(results), on="account_id", how="inner")

FSM_SUITED = {"handyman", "cleaning", "hvac", "plumbing", "painting",
              "appliance_repair", "general_contracting"}

BASELINE = {
    "on_site_work": 0.40, "labour_billing": 0.25, "scheduling": 0.15,
    "recurring_billing": 0.10, "complex_multi_line_jobs": 0.15,
    "contract_based_billing": 0.10, "b2b_clients_present": 0.10,
    "multi_address_work": 0.05, "industry_bonus": 0.10,
    "t_weak": 0.30, "t_strong": 0.65,
}

def derive_tier(row, p):
    score = sum(p[f"w_{k}"] * row[k] for k in BASELINE
                if k not in ("industry_bonus", "t_weak", "t_strong"))
    if row["industry"] in FSM_SUITED:
        score += p["industry_bonus"]
    score = min(score, 1.0)
    if score < p["t_weak"]:   return "none"
    if score < p["t_strong"]: return "weak"
    return "strong"

def objective(trial):
    p = {f"w_{k}": trial.suggest_float(f"w_{k}", 0.0, 0.6)
         for k in BASELINE if k not in ("industry_bonus", "t_weak", "t_strong")}
    p["industry_bonus"] = trial.suggest_float("industry_bonus", 0.0, 0.3)
    p["t_weak"]   = trial.suggest_float("t_weak",   0.10, 0.50)
    p["t_strong"] = trial.suggest_float("t_strong", p["t_weak"] + 0.05, 0.95)

    # 5-fold CV on macro-F1
    scores = []
    for _, fold_idx in KFold(n_splits=5, shuffle=True, random_state=42).split(joined):
        fold = joined.iloc[fold_idx]
        predicted = fold.apply(lambda r: derive_tier(r, p), axis=1)
        scores.append(f1_score(fold["expected_tier"], predicted, average="macro"))
    f1 = sum(scores) / len(scores)

    # L2-regularise toward BASELINE
    distance = sum(
        (p.get(f"w_{k}", BASELINE[k]) - BASELINE[k]) ** 2
        for k in BASELINE
    )
    return f1 - 0.05 * distance

study = optuna.create_study(direction="maximize",
                            sampler=optuna.samplers.TPESampler(seed=42))
study.optimize(objective, n_trials=1000)
print("Best CV F1:", study.best_value)
print("Best params:", study.best_params)
```

Run: `python Training/fsm_fit/scripts/optimize_weights.py`. Outputs:

- `study.best_params` — recommended weights + thresholds.
- `optuna.visualization.plot_param_importances(study)` — which weight actually moves the score.
- `optuna.visualization.plot_contour(study, params=["w_on_site_work", "t_strong"])` — the score landscape on the two parameters that usually dominate.

### Workflow

1. Run the optimiser (~10 seconds for 1000 trials on the 30-seed).
2. Compare the optimiser's best CV macro-F1 against the hand-tuned weights' CV macro-F1.
3. If material improvement (> ~3 F1 points): bump `rule_version` in `appsettings.json`, update `WEIGHTS_V3` in `analyze-exports.js`, and update the Rule table in [`scoring.md`](scoring.md).
4. If no material improvement: the hand-tuned weights are near-optimal. The Optuna run banks calibration confidence — that's the win.

### Re-run triggers

- Prompt changed materially (likely shifts the LLM's evidence distribution).
- Seed grew (more data → less overfit risk → tighter optimised weights).
- Production tier distribution drifts away from PM's target.

## Measured cost (LLM)

Reminder: weight tuning is free. The LLM cost figures below are for the **emit production** step, not for tuning.

| Metric | Value |
|---|---:|
| Accounts analyzed | 1,000 |
| Total cost | **$0.20** (~$0.000202/account) |
| Run date | 2026-05-13 |
| Duration | ~6 min @ concurrency 5 |

Cache hit ratio on the run was effectively zero (the original prompt was below OpenAI's 1,024-token caching floor). The current ~1,400-token production prompt measures **35% cache hit at burst / ~50% steady-state**, projecting ~$0.15 per 1,000 accounts and ~$15/month for a weekly 50k refresh. See [`../../investigation/provider.md`](../../investigation/provider.md) for the cost mechanics.
