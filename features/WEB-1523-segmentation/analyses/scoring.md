# WEB-1523 — Scoring (analysis contract)

> ⬜ **Not built — analyze-stage design.** None of this contract exists in code yet: there is no `IAnalysis` / `IPayloadBuilder<T>` / `IAnalysisRule<T>`, no `account_<type>` result table, no `v_<type>` view, no LLM emit/scoring path. Only the analysis-agnostic **`account_metrics`** feature-store (WEB-1527) has shipped. This doc is the locked target shape for when the LLM analyze stage lands. (Dataset is `ai_analysis_v2`; storage DDL lives in [`../implementation/storage.md`](../implementation/storage.md).)

The **framework contract** every analysis in the catalog must conform to — what the LLM is allowed to emit, what gets stored, and how the score / tier are derived. The v1 FSM-fit instance lives in [`fsm-fit/scoring.md`](fsm-fit/scoring.md); the same shape applies to v2 (`churn_risk`, `suspicious_user`) and any future analysis.

Comparing three candidate shapes for an LLM-driven analysis (research was done against FSM-fit, but the conclusion applies framework-wide):

- **A) Categorical N-class** — model emits a tier directly (e.g. `tier ∈ strong | weak | none`).
- **B) Single numeric 0..1 score** — model emits a continuous score; tier is threshold-derived from it.
- **C) Composite multi-signal** — model emits sub-signals (booleans + low-cardinality labels + reasoning); a deterministic rule derives the score and tier downstream.

## Decision

**Option C — Composite multi-signal.** LLM emits structured evidence (booleans + low-cardinality labels + reasoning); a deterministic rule derives the score and tier. All three are stored.

Every analysis in the catalog follows this shape, with its own evidence schema, rule, and tier vocabulary.

## Analysis contract (applies to every `analysis_type`)

Every analysis registered in `Tofu.AI.Backend` must expose this 5-tuple. Adding a new analysis is filling in these slots — *no framework code changes*.

| Slot | Type | Notes |
|---|---|---|
| `analysis_type` | string id (e.g. `fsm_fit`, `churn_risk`) | The catalog key. Names the per-analysis table (`account_<type>`) and view (`v_<type>`). |
| `payload_schema` | C# record + JSON schema | What the `IPayloadBuilder<T>` produces from raw account data (joined with shared `account_metrics` columns at payload-build time). Per-analysis. |
| `emit_schema` | JSON schema enforced via **OpenAI strict structured outputs** (`response_format: { type: "json_schema", strict: true }`) | What the LLM is constrained to emit. Per-analysis. Stored as **typed columns** on `account_<type>` — never as `JSON` cells. Adding an analysis means picking the right column types for that analysis's emit fields. |
| `rule` | C# `IAnalysisRule<T>.Apply(metrics, evidence)` | Pure function `metrics + evidence → (score, tier, recommended_offers)`. Runs **at write time** inside the Hangfire job (hosted in the `Tofu.AI.Api` pod — single-pod design, see [`../implementation/service.md`](../implementation/service.md) § Decision); outputs are materialised into typed columns on `account_<type>`. No SQL CASE arm in views, no per-read recomputation — keeps training/serving parity and prevents per-read rule drift. |
| `tier_vocabulary` | string enum + per-analysis doc | E.g. `strong\|weak\|none` for FSM-fit; `high\|med\|low` for churn-risk; `flag\|review\|clean` for suspicious-user. Stored as a typed `STRING` column on `account_<type>` — never constrained to one shared enum. |
| `score_range` | per-analysis (in doc, not in storage) | Pick the range that's natural for the rule (e.g. `0..1` for a probability-shaped one, `0..100` for a weighted-sum one). Not normalised across analyses. |

**Per-row provenance** (typed columns on `account_<type>`): `reasoning`, `input_hash`, `rule_version`, `prompt_version`, `model_id`, `analyzed_at`, `expires_at`, `triggered_by`. **Materialised rule outputs** (typed columns, set at write time by `IAnalysisRule<T>.Apply()`): `score`, `tier`, `recommended_offers ARRAY<STRUCT<offer STRING, weight FLOAT64>>` (the plural array supports a tiebreaker that emits one winner today but is shaped for future multi-offer distributions). See [`../implementation/storage.md`](../implementation/storage.md) for the full DDL.

**Shared backend metrics** (the 8 numeric aggregates + 2 derived booleans + `distinct_addresses`) live as typed columns on the cross-analysis `account_metrics` table, joined in by each per-analysis view (`v_<type>`). Adding an analysis = **one folder under `src/Analyses/Analyses.Domain/<NewType>/`** + one prompt + one `IAnalysisRule<T>` impl + one `IModuleMigration` that creates `account_<type>` (typed columns) + `v_<type>` (LEFT JOIN to `account_metrics`). No edits to framework code, no edits to other analyses' tables or views. See [`../implementation/storage.md`](../implementation/storage.md) § Structure.

## Sketch: a hypothetical `churn_risk` instance (illustrative, not v1 scope)

To verify the contract isn't FSM-fit-shaped in disguise:

- `payload_schema` — login recency, invoice-volume trend (last 90d vs prior 90d), payment-failure count, subscription tenure, current plan.
- `emit_schema` — `evidence: { engagement_decline: bool, payment_stress: bool, plan_downgrade_recent: bool, support_friction: bool }`, `predicted_action: "outreach" | "discount_offer" | "no_action"`, `reasoning: string ≤ 500`.
- `rule` (sketch v0) — weighted sum of the four booleans → score in `[0, 1]`; threshold 0.6/0.3 → `high/med/low`.
- `tier_vocabulary` — `high | medium | low`.
- `score_range` — `0.0 .. 1.0` (probabilistic framing).

Storage / API / worker / training harness all accommodate this **without code changes outside the new `ChurnRiskAnalysis` class and its prompt file**.

## Findings

> The product-survey context — what CRMs (HubSpot, Salesforce Einstein, MarketSizer Tri-Score, etc.) do for their scoring shapes — lives in [`../investigation/scoring-patterns.md`](../investigation/scoring-patterns.md). Those products use **supervised ML on outcomes**, not LLMs, so the survey informs storage shape but not model-architecture choice. The reliability findings below are the load-bearing ones for an LLM-driven analysis.

### LLM reliability — categorical >> continuous

**No.** The LLM-calibration literature is unanimous and well-replicated:

> "LLMs often struggle with the subtleties of continuous scales, leading to inconsistent results even with slight prompt modifications or across different models, and repeated tests have shown that scores can fluctuate significantly."
> — [Evidently AI — LLM evaluation metrics](https://www.evidentlyai.com/llm-guide/llm-evaluation-metrics)

> "Categorical evaluations are recommended in production environments. A categorical score of either 1 or 0 can be pretty useful as you can average your scores but don't have the disadvantages of continuous range."
> — [Confident AI — LLM Evaluation Metrics Guide](https://www.confident-ai.com/blog/llm-evaluation-metrics-everything-you-need-for-llm-evaluation)

But the same literature is also clear that LLMs *are* reliable at **structured per-field classifications** — booleans, low-cardinality enums, normalised categorical labels. The Cleanlab benchmark explicitly shows per-field trust scores outperforming holistic LLM-as-judge by ~25% on structured outputs.

The mechanism: a binary "does evidence X appear?" judgement has a sharp decision surface; a "rate 0..1 how strongly this fits" judgement has an arbitrary one the LLM has to invent each time. With temperature 0 + OpenAI strict structured outputs ([`../investigation/provider.md`](../investigation/provider.md) § 1), booleans and low-cardinality enums are wire-constrained and effectively deterministic; continuous scores never are.

This is decisive for the shape choice: **option B (LLM emits 0..1) is out**. Option C (LLM emits per-dimension structured signals, downstream rules union) is the reliable path.

### Recalibration without re-running

The lead-scoring practitioner literature (Breadcrumbs, Default, Coefficient) is consistent that **threshold tuning happens post-hoc, after the score is stored**. Re-running the model on every threshold change is expensive (compute) and slow (lead time to recalibrate). Storing the underlying numeric or sub-signals and deriving the tier deterministically lets sales-ops tweak thresholds in a config file and rerun queries instantly.

At ~195k analyses/month, being able to change "what counts as strong-fit" without re-spending the LLM budget is a real operational win. With option C this is a SQL update over stored evidence; with option B it would be re-prompting every account.

## Implications

Connecting findings to the three candidate shapes:

- **A) Categorical N-class** — sufficient for sales-ops action but loses ordering, is non-recalibratable, and discards the diagnostic information the LLM clearly *has* when it makes the verdict. Throws away signal we already paid for.
- **B) Single numeric 0..1 score** — rejected per § LLM reliability. LLMs are unreliable at continuous calibration; we'd be chasing prompt-tuning artefacts month over month.
- **C) Composite multi-signal** — preferred. LLM emits per-dimension signals it can reliably judge (booleans + low-card enums). A deterministic rule unions them into a numeric score and a tier. Recalibration is a config change. The reasoning text is preserved alongside the structured signals.

The combined finding (drawn from the Tri-Score analog in [`../investigation/scoring-patterns.md`](../investigation/scoring-patterns.md) plus the LLM-calibration evidence above): **LLM emits structured sub-signals + reasoning; downstream rule derives both a numeric score and a categorical tier; all three are stored.**

## Sources

- [Confident AI — LLM Evaluation Metrics](https://www.confident-ai.com/blog/llm-evaluation-metrics-everything-you-need-for-llm-evaluation) and [Evidently AI — LLM evaluation metrics](https://www.evidentlyai.com/llm-guide/llm-evaluation-metrics) — categorical >> continuous for reliable LLM emission; the load-bearing reason we rejected option B.
- [Braintrust — What is an LLM-as-a-judge?](https://www.braintrust.dev/articles/what-is-llm-as-a-judge) — *"Numeric scores work well for continuous judgments like helpfulness from 0 to 1, while categorical scores are useful when you want explicit labels such as correct, partially_correct, or incorrect."*
