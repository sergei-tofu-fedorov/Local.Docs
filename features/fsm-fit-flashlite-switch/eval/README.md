# FSM-fit evaluation suite

A designed, PII-free, version-controlled test set for the FSM-fit classifier — the professional replacement
for ad-hoc investigation dumps. Treat it like a behavioural unit-test suite: every case targets one specific
behaviour, the gold labels are objective by construction, and any model (gpt-4.1-nano, gemini-flash-lite, …)
is scored the same way.

## What the classifier outputs (the label schema)

Per account the model emits, from `business_name` + `item_names` (+ aggregates):
- **industry** — one of the 24 enum values (`Industry.cs`): general_contracting, electrical, hvac, locksmith,
  mechanical_service, plumbing, handyman, appliance_repair, flooring, junk_removal, painting,
  pest_control, pool_spa_service, renovations, roofing, cleaning, arborist_tree_care, landscaping,
  lawn_care_maintenance, snow_removal, computers_it, home_theater, security_alarm, other.
- **6 evidence flags** — `on_site_work`, `labour_billing`, `scheduling`, `recurring_billing`,
  `complex_multi_line_jobs`, `contract_based_billing`.

The deterministic `FsmFitScorer` turns the flags into score/tier/offer — so the flags are what the LLM must get
right; tier/offer are tested separately and derived.

Flag definitions are the source of truth in `FsmFitPrompt.cs`. The eval encodes the **current** definitions —
notably `scheduling` (PromptVersion 9, `v13-scheduling-calendar`) = *"would the account benefit from the app's
visit calendar"* (visit/appointment-based work → TRUE, even at one visit per customer; product/walk-in/digital/
name-only → FALSE). When a definition changes, re-derive the gold for that flag and bump `suite_version`.

## Design — two layers

| layer | file | purpose | gold source |
|---|---|---|---|
| **behavioural** | `cases.jsonl` | hand-crafted, synthetic-but-realistic cases; one per industry + explicit TRUE/FALSE per flag + homonym/edge traps. Objective answers, no PII → lives in git. | authored to the prompt rules |
| **real holdout** | (private, not here) | a stratified prod sample for aggregate accuracy + calibration. PII-sensitive (`item_names`) → keep out of the repo. | human-adjudicated (Argilla) |

This README + `cases.jsonl` are the behavioural layer. Keep the real holdout in `web-1525-fsmfit-seed/` (private).

## Case schema (`cases.jsonl`, one JSON object per line)

```json
{
  "id": "flag-recurring-false-reactive-trade",
  "dim": ["recurring_billing", "trap"],          // which behaviour(s) this case probes
  "business_name": "Rapid Plumbing Co",
  "item_names": [{"name": "Labour", "count": 22}, {"name": "Service call", "count": 14}, {"name": "Parts", "count": 9}],
  "metrics": {"invoice_count_30d": 30, "avg_invoice_amount": 420, "avg_line_items_per_invoice": 3.1,
              "repeat_customer_ratio": 0.6, "multi_address_work": true, "b2b_clients_present": false, "distinct_addresses": 25},
  "expected": {"industry": "plumbing", "on_site_work": true, "labour_billing": true, "scheduling": true,
               "recurring_billing": false, "complex_multi_line_jobs": true, "contract_based_billing": false},
  "rationale": "High repeat ratio but reactive Labour/Parts/Service-call = different one-off jobs → recurring=false (the nano over-flag trap).",
  "difficulty": "hard"
}
```

`metrics` carries only what the flags need (contract→avg_invoice_amount; complex→line-items+amount; recurring↔repeat
ratio is a hint the item text overrides). `dim` lets the runner report accuracy **per probed behaviour**.

## Metrics the runner reports (`run_eval.py`)

- **industry**: overall accuracy **and macro-F1** (unweighted mean of per-industry F1 — fair when industries are
  uneven), + a confusion list of the misses.
- **per flag**: accuracy, precision, recall, and the **error direction** (over-predict vs under-predict) — because
  the flags have known directional biases (nano under-flags on_site/labour; flash-lite under-flags labour, over
  contract). Direction is what you act on.
- **per dimension (`dim`)**: pass-rate on the cases that probe each behaviour — so a regression on, say, the
  homonym traps or the `recurring-false-reactive` rule is visible immediately.
- **tier** (optional, if `FsmFitScorer` parity is wired): exact-tier match.
- A **scorecard** + a list of every failing case with expected-vs-got, for triage.

Run:
```bash
# 1. produce predictions with any model — reuse the existing runners, pointed at cases.jsonl as input,
#    OR any tool that writes {id: {industry, flags{...}}} to a json file.
# 2. score:
python run_eval.py --pred nano_pred.json        # vs cases.jsonl
python run_eval.py --pred flashlite_pred.json --thresholds   # also check pass/fail gates
```

## How to extend (keep it professional)

1. Add a case **only** when it probes a behaviour not already covered (check `dim` coverage the runner prints).
2. Keep inputs **synthetic & PII-free** — invent plausible business names + item names; never paste a real
   customer's data into this layer.
3. Make the gold **objective**: if two reasonable annotators could disagree, it belongs in the real holdout
   (judgement call), not here (deterministic rule). Borderline-by-design cases go under `dim: ["boundary"]`
   with the rule that settles them in `rationale`.
4. One behaviour per case; isolate the flag under test by holding the others obvious.
5. Bump `suite_version` in this README on any gold change; note the reason.

## suite_version

- **v1 (2026-06-29)** — initial behavioural suite: **47 cases**, all 24 industries, TRUE/FALSE discriminators for
  all 6 flags, and homonym/out-of-scope/name-only/bimodal traps. Encodes prompt PromptVersion 10
  (scheduling=visit-calendar; automotive_repair enum removed → road-vehicle mechanical repair = mechanical_service).
  Gold authored to `FsmFitPrompt.cs` rules; not yet cross-checked by a second human.

  **Baseline (gemini-2.5-flash-lite, prompt v10, `predict_cases.py` → `run_eval.py`):** industry **98%** (macro-F1
  0.98, 46/47 — only a single hvac↔mechanical edge), scheduling 96%, traps **100%** (homonyms/out-of-scope → other),
  name-only/boundary/on_site/labour/complex/contract dims all **100%**. **Remaining real weakness = `recurring_billing`**
  (dim 71%, precision 54%): flash-lite OVER-flags recurring on subscription / reactive-trade traps — a weakness the
  designed suite surfaces that the real-seed concordance hid (because here the gold is objective). exact
  all-6-flags-correct 68%. Thin one-polarity coverage to widen in v2: `contract_based_billing` TRUE (2),
  `recurring_billing` TRUE (8), `scheduling` FALSE (11).
