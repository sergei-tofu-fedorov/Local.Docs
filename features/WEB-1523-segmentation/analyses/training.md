# WEB-1523 — Training (per-analysis evaluation methodology)

> **Framework note.** This doc covers the **per-analysis training pattern**. Each `analysis_type` (v1 `fsm_fit`, v2 `churn_risk` + `suspicious_user`, …) runs its own training cycle with its own seed labels, prompt iteration, and rule-weight tuning. The methodology below is shared; the contents (sample, labels, prompt, weights) are per-analysis.

Training has **two separable concerns**:

1. **Prompt quality** — improved by inspection + spot-checks against the hand-labelled seed. The prompt tells the LLM what to emit; quality issues (ambiguous instructions, missing edge cases, conflicting examples) are read off the prompt and the per-account outputs. **No eval framework is required for this loop.**
2. **Rule weight tuning** — the deterministic rule that turns the LLM's evidence emit into `score`, `tier`, and `recommended_offers` has tunable weights and thresholds. Tune these with **Optuna** against the hand-labelled seed using stored LLM emit. **No LLM cost** — the LLM call already happened; this is pure compute over stored evidence.

This split is deliberate. The LLM emit is expensive to re-run (API cost × N accounts × time); the rule is cheap to re-evaluate over stored emit. Lock the prompt by inspection first; tune the rule by optimisation second.

## Sample collection

Per-analysis raw-account corpus at `Training/<analysis_type>/accounts/` — one JSON per account. Selection criteria, payload shape, and re-collection cadence are per-analysis (see the per-analysis `training.md`).

## Hand-labelled seed

- **~30 accounts**, stratified random from the raw corpus across the tier vocabulary.
- Ground-truth columns: each evidence boolean + expected `tier` + expected `industry` + (optionally) any rule-derived field whose calibration we want to validate (e.g. `recommended_offers`).
- Lives at `Training/<analysis_type>/seed-labels/30-account-ground-truth.csv`.
- One row per account. Plus context columns (`business_name`, `top_item_names`) so a human reviewer can sanity-check a label without separately fetching the raw account JSON.
- Hand-labelling is the only step that can't be Claude-accelerated. Budget ~2 hours of focused work per analysis.

## Prompt iteration

Workflow:

1. **Read the prompt.** Identify gaps from inspection: ambiguous rules, missing edge cases, conflicting examples, soft-overlapping output enums, no few-shot grounding.
2. **Capture known issues** at the bottom of the per-analysis `prompt.md` (e.g. [`fsm-fit/prompt.md`](fsm-fit/prompt.md)) — a running list of "things to fix" with severity and proposed wording. Close items by removing them once the fix is shipped (the `prompt_version` label on each BigQuery row carries the history).
3. **Edit the prompt** in the canonical source (for FSM-fit: `Investigation/main-1361-collect/analyze-exports.js`'s `SYSTEM_PROMPT` constant). Mirror the edit in the per-analysis `prompt.md`.
4. **Re-run the prompt on the 30-seed.** Diff each account's tier and evidence emit against the previous run. Surface accounts where any field changed.
5. **Spot-check** the 5–10 changed accounts manually. Did the change improve the assignment, leave it the same, or introduce a regression?
6. **Ship if no clear regressions on previously-correct accounts.** Bump `prompt_version` in `appsettings.json` and commit the new prompt.

No automated eval framework is needed for this loop. The seed is small enough to eyeball; structured-output mode wire-constrains the LLM's JSON shape, so failures are about *content* (which boolean for which signal), not *format*. The diff-and-spot-check workflow catches regressions reliably at this scale.

## Rule weight tuning — Optuna

The rule has tunable parameters: weights on each evidence signal, the FSM-suited industry bonus, and the tier thresholds. With stored LLM emit + a labelled seed, these are a small HPO problem (~10 continuous params, ~30 examples, pure-code objective).

### Tool

**[Optuna](https://github.com/optuna/optuna)** (Python, ~10k+ GitHub stars). TPE sampler by default; built-in cross-validation, param-importance plots, contour plots. Industry-standard for small-to-medium HPO.

### Inputs

- **Stored LLM emit** — one JSON per account from a recent run, containing the model's evidence booleans + industry + specialization + reasoning. No new LLM calls during weight tuning.
- **Hand-labelled seed** — the CSV above.
- **The rule** — pure code; re-implement in Python (matching the C# / JS `IAnalysisRule` semantics) or call the existing JS implementation from Python.

### Objective and overfit guards

With ~30 labelled examples and ~10 parameters (~3 examples per param), the optimiser will overfit if turned loose. Three mitigations baked into the methodology:

1. **K-fold cross-validation** in the objective — measure macro-F1 averaged across 5 folds, not on a single fit to all 30. Optuna integrates with `sklearn.model_selection.KFold` directly.
2. **Regularise toward the hand-tuned weights** — add a small L2 penalty for distance from the current production weight set. Stops the optimiser from finding seed-specific artefacts at the cost of generalisation.
3. **Hold out 5–10 accounts** for the final eval. Optimise on the rest, report the held-out score as the trust number.

### Output

- Best weights + thresholds (a JSON dict).
- Optuna's param-importance plot — tells you which weight actually matters (often one or two signals dominate; others are near-zero).
- Macro-F1 on the holdout set.

If the optimiser's best holdout score is materially better than the hand-tuned weights' holdout score, ship the optimised weights. If not, the hand-tuned weights are near-optimal and you've gained calibration confidence rather than new weights.

### When to re-run

Optuna isn't a one-time exercise; re-run when:

- The prompt changes (different evidence distribution).
- The seed grows (more data → less overfit risk → tighter weights).
- A real-world A/B suggests the production tier distribution is off (e.g. PM says "too many strong, want closer to 20%" — re-target the thresholds).

## Repo layout — per-analysis

```
Training/
├── accounts/                                    # raw account JSONs (shared corpus across all analyses)
└── <analysis_type>/                             # one subdir per analysis (fsm_fit, churn_risk, suspicious_user, ...)
    ├── prompts/                                 # prompt versions; current production at the top
    ├── seed-labels/                             # hand-labelled ground-truth CSV
    ├── scripts/
    │   ├── prep_input.py                        # account JSON → prompt vars (incl. server-side redaction)
    │   ├── apply_rule.py                        # deterministic rule (mirror of C# IAnalysisRule)
    │   ├── optimize_weights.py                  # Optuna driver for rule-weight tuning
    │   └── diff_runs.py                         # diff tier assignments between two stored runs (regression watch)
    └── results/<timestamp>/
        ├── raw/                                 # per-account LLM emit
        └── summary.md                           # locked config: prompt version, weights, thresholds, seed F1
```

## Adding a new analysis

When a new analysis moves to "in flight":

1. **Create `Training/<analysis_type>/`** with the same subdirectory shape as `Training/fsm_fit/`.
2. **Hand-label the seed** (~30 accounts) against the new analysis's tier vocabulary.
3. **Iterate the prompt** by inspection. Track open issues at the bottom of the per-analysis `prompt.md`.
4. **Implement the rule** in `apply_rule.py` (Python) matching the C# `IAnalysisRule` semantics.
5. **Run Optuna** on the seed + stored emit. Compare against hand-tuned weights.
6. **Document the locked config** at `results/<timestamp>/summary.md` and the per-analysis `training.md`.

The methodology (this doc), the seed-construction workflow, and the Optuna scaffold are unchanged. No shared-file edits.

**The training Phase (sample → seed labels → prompt iteration → rule tuning) repeats once per analysis** — each analysis is its own budget. Implementation tracked in ClickUp.

## Sources

- [Optuna](https://github.com/optuna/optuna) — chosen weight-optimisation library. TPE sampler, cross-validation integration, visualisation suite.
- [Akiba et al., "Optuna: A Next-generation Hyperparameter Optimization Framework"](https://arxiv.org/abs/1907.10902) — canonical reference for the TPE sampler.
- [arXiv:2008.05756 "Metrics for Multi-Class Classification"](https://arxiv.org/pdf/2008.05756) — canonical reference for macro-F1 and per-class metrics used in the objective.
- [Zhao et al., "Self-Preference Bias in LLM-as-a-Judge", arXiv:2410.21819](https://arxiv.org/abs/2410.21819) — if/when we ever do LLM-as-judge for free-text fields (`industry`, `reasoning`), the judge must be from a different model family than the candidate. Not used in v1.
