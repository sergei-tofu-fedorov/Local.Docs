# FSM-fit — switch to flash-lite + eval/judging kit

**Status:** in progress · **Started:** 2026-06-29 · **Owner:** s.fedorov
**Related repos:** `Tofu.AI.Backend` (prompt + Vertex client), this repo (docs/eval).
**ClickUp:** WEB-1525 *"Собрать и вручную разметить seed-выборку аккаунтов для валидации правила FSM-fit v3"*.

> ⚠️ Ticket-number note: `features/WEB-1525/` in this repo is a **different** WEB-1525
> (SCD-2 историзация master↔platId в `ai_analysis_us`). This FSM-fit seed/judging work
> reuses the same ClickUp id but is unrelated — kept in its own folder to avoid the collision.

## What this is

Evaluation + decision record for moving the FSM-fit classifier in prod from `gpt-4.1-nano`
to `gemini-2.5-flash-lite` (Vertex, cached, thinking-off), plus two prompt-definition fixes:

1. **`scheduling`** redefined → *"the business would benefit from the app's VISIT CALENDAR"*
   (visit/appointment-based work, even one visit per customer) — was the narrow "multi-visit job".
   Validated on the hard WEB-1525 set: flash-lite 90% vs nano 56%.
2. **`automotive_repair` enum removed** → road-vehicle mechanical work routes to `mechanical_service`
   (back to 24 industries). PromptVersion bumped to **10**.

Net: flash-lite matches/beats nano on the hard tail and fixes nano's systematic
`recurring_billing` over-flag on reactive trades; its one residual weakness is over-flagging
`recurring_billing` on subscription/reactive traps (see `eval/`).

## Contents

| Path | What |
|---|---|
| `benchmarks-summary.md` | Consolidated research: model comparisons, manual tests, latest good-flash-lite findings (caching + no-thinking). The narrative source of truth. |
| `CONTINUE-HERE.md` | Live handoff/pickup note — current task, branch state, deploy blockers, open follow-ups. **Read this first to resume.** |
| `eval/` | **Designed behavioural eval suite (PII-free).** 47 hand-authored cases (all 24 industries + TRUE/FALSE per flag + traps), `run_eval.py` scorecard, `predict_cases.py`. flash-lite v10 baseline: industry 98% / macro-F1 0.98. |
| `notes/rubric.md` | FsmFit prompt rubric (verbatim) used for manual judging. |
| `notes/flashlite-improvement.md` | Flash-lite weak-flag improvement options (schema field-descriptions, reasoning-first, few-shot). |
| `notes/scheduling-v8-test.md` | The scheduling-redefinition A/B (nano vs flash-lite vs claude). |
| `argilla/` | Portable kit to rebuild the 200-account human-judging set (`fsm-fit-judge-diverse`) on another machine — see its own README. |

## Run the eval suite

```bash
cd eval
python predict_cases.py --model flashlite     # or --model nano  -> writes <model>_pred.json
python run_eval.py                            # scorecard vs cases.jsonl gold
```
(Needs the same model credentials as `Tofu.AI.Backend`; cases carry their own synthetic gold,
no prod data.)

## Prod deploy blockers (see CONTINUE-HERE.md §5)

1. Grant `roles/aiplatform.user` to `tofu-ai-backend@inv-project` (currently mis-granted to `tofu-auth-backend`).
2. Add `Analyses:Llm:Provider="Vertex"` to prod secret `tofu-ai-api-secret`.
3. ⚠️ PromptVersion → 10 changes `input_hash` for all accounts → full prod re-judge on first tick (cost).

## PII / privacy

This folder is committable to the **public** `Local.Docs` repo because everything here is
PII-free: the eval cases are synthetic, the docs cite only aggregate metrics and the feature
name `business_name`, never real account values. **Raw prod account data (real business names,
item names, account ids) is deliberately NOT committed here** — the `argilla/` kit rebuilds it
from BigQuery on demand instead. See `argilla/README.md`.
