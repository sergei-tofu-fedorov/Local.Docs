# FSM-fit — continuation / handoff (state at 2026-06-30)

Pick-up note for the FSM-fit model work. TL;DR: we are switching prod from `gpt-4.1-nano` to
`gemini-2.5-flash-lite`, fixed the `scheduling` definition (→ visit-calendar) and removed the
`automotive_repair` enum, built a real eval suite, and prepared a 200-account human-judging set in Argilla.
**Tomorrow’s main task = label the Argilla set, then score nano-v10 vs flash-lite-v10 against your gold.**

---

## 1. ACTIVE TASK — label the diverse judging set in Argilla

- **Dataset:** `fsm-fit-judge-diverse` (200 accounts) — Argilla UI **http://localhost:6900** (`argilla` / `12345678`).
  - If Argilla is down: `cd C:\Git\_scratch\argilla && docker compose up -d` (wait ~30s for ES).
- **What it is:** 200 NON-easy, INDUSTRY-DIVERSE prod accounts — **all 24 industries, 8 each** (3A included, not
  dominant; `other`=16), avg difficulty 2.87. Excludes everything already judged (200 seed + 36 sparse + 140 gold +
  65 3A-contested).
- **Label:** `industry` (24) + `flags` (6) + optional note. Suggestions pre-filled from **flash-lite v10**.
- **Model votes** shown 3-per-line per record: `prod-nano (v7)` / `nano (v10)` / `flash-lite (v10)`.
  - `prod-nano (v7)` = stored prod label (old prompt + notes). `nano (v10)` & `flash-lite (v10)` = fresh, same
    no-notes input → those two are the apples-to-apples pair.
- **Start with the disagreements:** filter `metadata.all3_agree = false` → **115 cases** (the worth-your-time ones).
  Agreement now: all-3 = 42% (85/200); nano-v10 == flash-v10 = 63% (126/200).
- Artifacts (this folder): `select_diverse.py` (selection), `judge_worksheet.json` (the 200 + signals),
  `predict_judge.py` (`--model flashlite|nano`), `flashlite_pred.json`, `nano_pred.json`, `build_load_argilla.py`.

## 2. AFTER labelling — export + score (the decision number)

1. Export the submitted responses from Argilla (mirror `../bq-batch-fsm-fit/eval/export_from_argilla.py`: pull
   records, take `responses` for `industry` + `flags`, key by `account_id`) → `gold.jsonl`.
2. Score **nano-v10 (`nano_pred.json`) and flash-lite-v10 (`flashlite_pred.json`) vs your human gold**: industry
   accuracy + macro-F1, per-flag precision/recall + over/under. The `../fsm-fit-eval/run_eval.py` scorer can be
   pointed at a `{id: {industry, flags}}` predictions file vs a gold jsonl (adapt the loader to read your gold as
   the expected). This gives the final, human-grounded nano-vs-flash-lite verdict on a diverse set.

## 3. Eval suite — `../fsm-fit-eval/` (designed behavioural tests, PII-free, in case you want unit-style checks)

- `cases.jsonl` (47 hand-crafted cases, all 24 industries + TRUE/FALSE per flag + traps), `run_eval.py` (scorecard:
  industry acc/macro-F1, per-flag P/R + direction, per-dim, thresholds), `predict_cases.py` (`--model`).
- **Baseline (flash-lite, prompt v10):** industry 98% (macro-F1 0.98), scheduling/traps/name-only/boundary 100%;
  **remaining weakness = `recurring_billing`** (flash over-flags on subscription/reactive traps). See its README.

## 4. Branch + prompt code state — `Tofu.AI.Backend`, branch `feature/fsm-fit-vertex-cached`

- **Rebased onto `feature/FS-1241`** (clean, no conflicts; backup branch `backup/fsm-fit-vertex-cached-prerebase`;
  diverged from origin 5/5 → push needs `git push --force-with-lease`).
- **Uncommitted working-tree changes** (3 files): `FsmFitPrompt.cs`, `Industry.cs`, `FsmFitScorer.cs`
  - `scheduling` redefined → "would benefit from a VISIT CALENDAR" (PromptVersion 9, validated WEB-1525: flash 90% vs nano 56%).
  - `automotive_repair` enum **removed** → road-vehicle mechanical = `mechanical_service` again (PromptVersion **10**, 24 industries).
  - flash-lite **already configured** in `appsettings.json` (`Analyses:Llm:Provider=Vertex`,
    `Vertex:Model=gemini-2.5-flash-lite`, explicit CachedContent) — this branch IS the flash-lite path.
  - Build green (Domain + API, 0/0). **Not committed** (awaiting go-ahead). Suggested: commit prompt change(s) on the branch (no push yet).
- Lockstep note: doc comment references `Investigation/main-1361-collect/analyze-exports.js` (JS prompt mirror) — NOT in this workspace, couldn't update.

## 5. DEPLOY BLOCKERS (prod, `inv-project`) — two actions before flash-lite works in prod

1. **IAM mis-grant:** `roles/aiplatform.user` is on `tofu-auth-backend` (wrong SA). Grant it to the AI SA:
   `gcloud projects add-iam-policy-binding inv-project --member="serviceAccount:tofu-ai-backend@inv-project.iam.gserviceaccount.com" --role="roles/aiplatform.user"`
2. **Config switch:** prod secret `tofu-ai-api-secret` (inv-project) has NO `Analyses:Llm:Provider` → still on nano.
   Add `Analyses:Llm:Provider="Vertex"` (new secret version). Vertex section optional — DI falls back to the
   BigQuery ProjectId (`inv-project`) + inline SA key; Model/Location default to flash-lite / us-central1.
- Verified OK: Vertex API enabled on inv-project; BigQuery.ProjectId=inv-project; inline SA key present; FsmFit job
  Enabled (hourly).
- ⚠️ Bump PromptVersion → 10 means input_hash changes for ALL accounts → **full prod re-judge on first tick** (cost).

## 6. Other Argilla datasets already prepared (from earlier today)

- `fsm-fit-web1525-seed` (134 uncertain, general industry+flags) · `fsm-fit-web1525-flashlite-flags` (145, flash-lite
  weak flags: labour/contract — scheduling dropped, it’s resolved). In `../web-1525-fsmfit-seed/`.

## 7. Open follow-ups / decisions

- [ ] Label `fsm-fit-judge-diverse` (start `all3_agree=false`), export, score nano-v10 vs flash-lite-v10 vs gold.
- [ ] Decide: improve flash-lite `recurring_billing` over-flag (per `../fsm-fit-eval/` + `../web-1525-fsmfit-seed/flashlite-improvement.md`: schema field-descriptions, reasoning-first, few-shot).
- [ ] Commit the prompt/enum changes on `feature/fsm-fit-vertex-cached` (you push).
- [ ] Prod: do the 2 deploy actions (IAM + secret), then deploy the branch image.
- Consolidated research doc: `../fsm-fit-benchmarks-summary.md` (§0 = latest WEB-1525 findings). Full bundle: `../fsm-fit-research-bundle.zip`.
