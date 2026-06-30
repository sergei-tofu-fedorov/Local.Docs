# How to improve gemini-2.5-flash-lite on FSM-fit (grounded in WEB-1525 biases + web best practices)

flash-lite already **beats nano on industry (78% vs 65%) and recurring_billing (95% vs 61%)** on the hard set,
but has three **systematic, opposite** flag biases vs the claude-gold (concordance — re-validate against the
Argilla human gold when ready):

| flag | flash-lite error | measured (all 236 / confident 102) |
|---|---|---|
| `labour_billing` | **UNDER-flags** (says false when true) | acc 69% / 57%; under 71 / 43 |
| `scheduling` | **OVER-flags** (says true when false) | acc 75% / 67%; over 51 / 29 |
| `contract_based_billing` | **OVER-flags** | acc 76% / 74%; over 55 / 27 |

The fixes below are **model-specific** (apply to the flash-lite call path, not the shared `FsmFitPrompt` —
that prompt is nano-tuned and shared; per project policy don't over-tune it [[fsmfit-3a-classification-quality]]).
Order = expected ROI.

## 1. Add per-field `description` to the responseSchema (highest ROI, ~free)

Google's docs and practitioners are unanimous: **"Use the `description` field to guide the model… the better
your descriptions, the more accurate the output."** Our current `responseSchema` (`flash_lite_run.py`) has the 6
booleans with **no descriptions** — the model leans only on the system prompt. Gemini reads each property's
`description` at generation time, so embedding the exact rule (and the failure mode) per flag directly steers it.
Target the three biased flags:

- `labour_billing`: *"TRUE for per-hour / day-rate / per-job / 'Labor'|'Labour' line items / time-based service
  pricing. A 'Labor' or 'Service call' line, or per-job pricing, IS labour_billing even alongside parts. Do not
  default to false."* (counters the under-flag)
- `scheduling`: *"TRUE only for multi-visit / multi-stage ('Day 1','Phase 2') / appointment / route / follow-up
  language. A SINGLE visit to a single address is on_site_work but NOT scheduling."* (counters the over-flag)
- `contract_based_billing`: *"TRUE only when invoices are BOTH high-amount ($2000+) AND have very few (1-3) line
  items. Few line items alone, at low amounts, is NOT contract billing."* (counters the over-flag)

`enum` on `industry` is already set (good). Keep `propertyOrdering` consistent with any examples (docs warn a
mismatch confuses the model).
Sources: [Gemini structured-output docs](https://ai.google.dev/gemini-api/docs/structured-output),
[Structured output with Gemini (Medium)](https://medium.com/google-cloud/structured-output-with-gemini-models-begging-borrowing-and-json-ing-f70ffd60eae6),
[Improving Structured Outputs in the Gemini API](https://blog.google/innovation-and-ai/technology/developers-tools/gemini-api-structured-outputs/).

## 2. Put `reasoning` FIRST in the schema (reason-before-commit) — A/B it

Gemini emits properties in `propertyOrdering` / schema order ([structured-output docs / property ordering](https://ai.google.dev/gemini-api/docs/structured-output)).
Our schema currently lists the 6 booleans first and `reasoning` LAST — so the model **commits to each boolean
before it reasons**. Moving `reasoning` (or a short per-flag `evidence` string) to the FRONT forces think-on-paper
before the flags — the standard CoT-in-structured-output pattern, and exactly what the over/under conditional
flags need. This is a test, not a doc-guaranteed win; measure on the gold.

## 3. Turn on a small thinking budget (512) for the flag pass — A/B it

flash-lite ships **thinking OFF**; our run used off. Google's guidance + an independent eval: a 512–2048 thinking
budget gives **modest accuracy gains but a large schema-compliance / hallucination drop (≈10×)** and helps the
model *"maintain intermediate hypotheses, avoid premature commitment, and follow sequential conditions"* — which
is precisely what `labour/scheduling/contract` (multi-condition flags) require. Our own earlier A/B saw thinking@512
lift industry concordance 92→95% and labour-flag agreement [[vertex-fsmfit-adapter]]. Cost ≈ 2× (~$0.27→$0.42/1k).
Worth A/B against levers 1–2; pick the cheapest that closes the flag gap.
Sources: [Gemini 2.5 thinking updates](https://developers.googleblog.com/en/gemini-2-5-thinking-model-updates/),
[Flash-Lite getting-started](https://medium.com/google-cloud/developers-guide-to-getting-started-with-gemini-2-5-flash-lite-8795eed5486c),
[Flash-Lite overview (Galileo)](https://galileo.ai/model-hub/gemini-2-5-flash-lite-overview).

## 4. Add flag-level few-shot hard-negatives (the v7 prompt only few-shots INDUSTRY)

`FsmFitPrompt` v7 has industry few-shots but **no flag few-shots**. In the flash-lite call path, append 2-3
contrastive flag examples targeting the biases — e.g.
`'Labor 3hr | Service call | Compressor' -> labour_billing=true` (fix under-flag);
`'House wash at <address>' (one visit) -> on_site_work=true, scheduling=false` (fix over-flag);
`'Bathroom renovation $8,000' (1 line) -> contract=true`; `'5 itemized lines, $400' -> contract=false`.

## 5. Re-validate against the Argilla HUMAN gold, not the claude gold

All deltas above are vs the **claude self-judge** (concordance). Some flash-lite "errors" (esp. labour_billing,
where flash is conservative) may be the *judge* over-calling, not flash-lite under-calling. The Argilla pass
(`fsm-fit-web1525-seed`, 134 uncertain) produces human truth — re-score levers 1–4 against it before committing a
prompt/schema change. Cheap loop: re-run `flash_lite_run.py` (swap in the schema descriptions) → `compare3.py`.

## Not recommended
- **Switching to gemini-2.5-flash (thinking-on)**: ~12× the cost ($5.57 vs $0.48/1k) for marginal industry gain —
  not worth it for flag fixes that schema-descriptions + a 512 budget can address [[vertex-fsmfit-adapter]].
- **Editing the shared `FsmFitPrompt`** for flash-lite quirks: it's nano-tuned and stamped on every prod row; use
  the model-specific schema/description path instead.
