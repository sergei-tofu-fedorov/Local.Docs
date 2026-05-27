# WEB-1523 — Industry scoring patterns (research)

Research on how production CRM and lead-scoring products shape their model-emitted vs. stored scoring data. Informed the analysis-shape decision in [`../analyses/scoring.md`](../analyses/scoring.md) § Decision (composite multi-signal — LLM emits booleans, rule derives score + tier).

> **Caveat — traditional ML, not LLMs.** The products surveyed below emit numeric scores from **supervised ML trained on historical outcome data** (leads that closed / didn't, deals that won / lost). The score is a calibrated probability (`P(close | features)`), not a prose-grounded judgement. Our case has no labelled-outcome dataset, so the LLM-emit-numeric variant of this pattern would be uncalibrated. The reliability rationale for our chosen shape (LLM emits booleans, rule derives the number) lives in [`../analyses/scoring.md`](../analyses/scoring.md) § LLM reliability.

## The dominant industry pattern: hybrid numeric + tier

Every CRM-style product surveyed stores **both** a numeric score and a derived categorical tier. The numeric supports sorting / filtering / model retraining; the tier drives action.

| Product | What the model emits | What's stored | How it's used |
|---|---|---|---|
| **HubSpot** | Numeric 0–100 probability | Both: numeric `Likelihood to Close` and derived categorical `Contact Priority` | Tier drives routing; score drives sorting and filtering |
| **Salesforce Einstein** | Numeric 1–99 | Numeric custom field; tiering implicit in dashboards | Same |
| **Lead Qualification Framework (2026)** | 100-point composite | Score + threshold tier | Same |
| **MarketSizer Tri-Score** | **Three independent dimensions** (ICP Fit, Purchase Intent, Win Probability) | All three dimensions stored, plus a tier derived from their alignment | *Diagnostic* use — "high intent but low win probability" is a different action than "perfect ICP fit but not in-market" |

The **Tri-Score is the most relevant analog** for an LLM-driven analysis because it explicitly separates emit-shape from store-shape: the model produces sub-dimensions, the storage layer keeps them independently, and the verdict is derived. This unlocks recalibration (change the threshold, get a new verdict) without re-running the model.

## How WEB-1523 maps onto this

WEB-1523's FSM-fit shape is a **stricter variant of Tri-Score**:

- Sub-signals are **booleans** (6 LLM-emit + 2 backend-computed), not continuous dimensions — easier for an LLM to emit reliably without anchored training data.
- The composite **score is rule-derived**, not model-emitted — recalibration is a config change, not a re-prompt of every account.
- Tier (`strong | weak | none`) is threshold-derived from the score — same shape as HubSpot's `Contact Priority`.

The hybrid-storage pattern these products popularised survives in our design (numeric + tier + sub-signals all stored, see [`../implementation/storage.md`](../implementation/storage.md) § Structure; the FSM-fit-specific rule weights and offer routing live in [`../analyses/fsm-fit/scoring.md`](../analyses/fsm-fit/scoring.md)). The traditional-ML-emits-numeric model architecture does not — we substitute LLM-emits-booleans + deterministic-rule for it.

## Sources

- [HubSpot — Predictive lead scoring](https://knowledge.hubspot.com/properties/determine-likelihood-to-close-with-predictive-lead-scoring) — numeric `Likelihood to Close` + derived categorical `Contact Priority`; the dominant CRM pattern.
- [Salesforce — Einstein Lead Scoring](https://trailhead.salesforce.com/content/learn/modules/lead-scoring-and-grading-in-account-engagement/einstein-scoring-in-account-engagement) — numeric score with implicit threshold tiers.
- [MarketSizer — Tri-Score propensity framework](https://www.marketsizer.io/blog-posts/crm-propensity-model-data-points-for-b2b-saas) — independent-dimension pattern that informed our `evidence` sub-signal shape.
