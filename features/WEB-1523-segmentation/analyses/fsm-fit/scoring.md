# WEB-1523 — FSM-fit scoring (instance)

The **FSM-fit instance** of the analysis contract defined in [`../scoring.md`](../scoring.md). Defines the rule, weights, thresholds, industry bonus, and offer-routing decision tree.

> **Provider (2026-05-13).** **OpenAI `gpt-4.1-nano`** with strict structured outputs (`response_format: { type: "json_schema", strict: true }`). Cheapest tier with schema-strict JSON: $0.10/$0.025-cached/$0.40 per 1M tokens, **measured at ~$0.0002 per account** on a 1,000-account validation run. See [`../../investigation/provider.md`](../../investigation/provider.md) § Decision for cost data.

## Contract instance

The six slots from [`../scoring.md`](../scoring.md) § Analysis contract, filled in for FSM-fit:

| Slot | FSM-fit value | Where defined |
|---|---|---|
| `analysis_type` | `"fsm_fit"` | catalog key; stored on every BigQuery row |
| `payload_schema` | `FsmFitPayload` — `business_name` + raw top-N invoice item names + Presidio-redacted top-N notes + 8 backend metrics + 2 backend booleans + `distinct_addresses` count | full field-by-field table in [`../../investigation/privacy.md`](../../investigation/privacy.md) § 1 |
| `emit_schema` | 6 evidence booleans + `industry` (24-ID enum) + `specialization` + `reasoning` (≤ 500 chars) — wire-enforced via OpenAI strict structured outputs | § Emit schema below |
| `rule` | `FsmFitRule v1` — weighted sum of the 8 booleans + `+0.15` FSM-suited industry bonus, sum-capped at `1.0`; tier thresholds at `0.30` / `0.65`; also outputs `recommended_offers` (plural ARRAY, one winner per row in v1) via a 7-rule decision tree | § Rule + § Offer routing below |
| `tier_vocabulary` | `strong \| weak \| none` | § Rule (thresholds row) |
| `score_range` | `0.0 .. 1.0` (sum-capped) | § Rule |

### Concrete fills — what each slot looks like in code and on the wire

**`payload_schema` (input to LLM):**

```jsonc
{
  "business_name": "Acme Plumbing",
  "top_item_names": [
    { "name": "Drain cleaning service", "count": 12 },
    { "name": "Boiler install — labour", "count": 8 }
  ],
  "backend_metrics": {
    "invoice_count_30d": 12,
    "avg_invoice_amount": 2330.67,
    "invoice_amount_variance_cv": 1.039,
    "avg_line_items_per_invoice": 1.79,
    "repeat_customer_ratio": 0.44,
    "avg_days_between_repeats": 8.8,
    "estimate_to_invoice_rate": null,
    "estimate_count": 0
  },
  "b2b_clients_present": true,
  "multi_address_work": true,
  "distinct_addresses": 6
}
```

**`emit_schema` (LLM output, strict-mode-enforced):**

```jsonc
{
  "evidence": {
    "on_site_work":            true,
    "labour_billing":          true,
    "scheduling":              false,
    "recurring_billing":       false,
    "complex_multi_line_jobs": true,
    "contract_based_billing":  false
  },
  "industry":       "plumbing",
  "specialization": "Drain cleaning",
  "reasoning":      "Item text references on-site work and labour billing; client list is mixed B2C / B2B with several distinct service addresses."
}
```

**`rule` (post-LLM, deterministic) — produces:**

For the LLM emit above (`on_site_work` + `labour_billing` + `complex_multi_line_jobs` = true) combined with the payload's backend signals (`b2b_clients_present` + `multi_address_work` = true) and the `plumbing` industry bonus:

```
score raw   = 0.40 (on_site_work) + 0.25 (labour_billing) + 0.15 (complex_multi_line_jobs)
            + 0.10 (b2b_clients_present) + 0.05 (multi_address_work)
            + 0.15 (industry bonus — plumbing is FSM-suited)
            = 1.10
score       = 1.00                                                  // capped at 1.0
tier        = "strong"                                              // ≥ 0.65
recommended_offers = [ { offer: "jobs_as_folders", weight: 1.0 } ]  // single winner from rule #4
                                                                    // (complex_multi_line_jobs + on_site_work);
                                                                    // ARRAY shape allows multi-offer distributions in future
```

Stored alongside the LLM emit (see § Storage mapping below).

A churn-risk or suspicious-user analysis fills these same six slots with totally different concrete values; the framework code never branches on `analysis_type`.

## System prompt

See [`prompt.md`](prompt.md) — verbatim mirror of `SYSTEM_PROMPT` in [`Investigation/main-1361-collect/analyze-exports.js`](../../../../Investigation/main-1361-collect/analyze-exports.js), plus section-by-section explanation and open prompt issues. Current version: `v6-industry-scheduling`.

## Emit schema

**LLM emits** (constrained via OpenAI strict structured outputs):

- **6 evidence booleans:** `on_site_work`, `labour_billing`, `scheduling`, `recurring_billing`, `complex_multi_line_jobs`, `contract_based_billing`.
- `industry` — constrained to the **24-ID canonical enum** (`general_contracting`, `electrical`, `hvac`, `locksmith`, `mechanical_service`, `plumbing`, `handyman`, `appliance_repair`, `flooring`, `junk_removal`, `painting`, `pest_control`, `pool_spa_service`, `renovations`, `roofing`, `cleaning`, `arborist_tree_care`, `landscaping`, `lawn_care_maintenance`, `snow_removal`, `computers_it`, `home_theater`, `security_alarm`, `other`) — enforced by strict structured outputs.
- `specialization` — short low-cardinality string.
- `reasoning` — ≤ 500 chars.

**Backend computes 2 additional booleans** (no LLM call):

- `b2b_clients_present` — regex over client names for `LLC|Inc|Corp|Property Management|LLP|Ltd`.
- `multi_address_work` — ≥ 2 distinct addresses in client records.

## Rule

Impl: `Training/fsm_fit/scripts/apply-rule.js`; tuneable per [`training.md`](training.md).

Applied **after** the LLM emit, in this order:

1. **Conflict resolution** (deterministic, backend metrics only) — see § Conflict resolution below.
2. **Weighted sum** with the table below.
3. **Industry bonus** if applicable.
4. **Sum cap** at `1.0`, then **tier mapping**.

| Signal | Source | Weight |
|---|---|---:|
| `on_site_work` | LLM | 0.40 |
| `labour_billing` | LLM | 0.25 |
| `scheduling` | LLM | 0.15 |
| `recurring_billing` | LLM | 0.10 |
| `complex_multi_line_jobs` | LLM | 0.15 |
| `contract_based_billing` | LLM | 0.10 |
| `b2b_clients_present` | backend | 0.10 |
| `multi_address_work` | backend | 0.05 |
| **FSM-suited industry** bonus | rule | +0.15 |

**Sum cap: 1.0.** Tier thresholds: `score < 0.30` → `none`; `0.30 ≤ score < 0.65` → `weak`; `score ≥ 0.65` → `strong`.

**FSM-suited industry bonus.** +0.15 when the LLM's `industry` value is one of the PM-ranked top-FSM-candidate IDs (`handyman`, `cleaning`, `hvac`, `plumbing`, `painting`, `appliance_repair`, `general_contracting`). Sourced from the in-app industry picker; the bonus reflects PM business intent rather than purely model-derived evidence. Locked 2026-05-13 — see [`../../ideas/misha/README.md`](../../ideas/misha/README.md) § "Open #4 partial-resolution".

**Validation aftermath (2026-05-13, 1,000-account sample).** The +0.15 bonus fired on **203 accounts (20%)**. Tier flips: **16 weak → strong**, **2 none → weak**. New distribution: `strong` 509→525, `weak` 117→103, `none` 374→372. PM still re-evaluating whether the 51%+ `strong` rate is acceptable or whether the rule needs a tighter cap — tracked as Misha § "Open #4" *Still open*.

## Conflict resolution

Deterministic post-LLM step. Runs before the weighted sum. The prompt ([`prompt.md`](prompt.md)) carries the semantic guidance ("these booleans describe opposite patterns"); the numeric tiebreak lives here because it's pure arithmetic on backend metrics — no item-name interpretation needed.

### `complex_multi_line_jobs` vs `contract_based_billing`

The two booleans are nearly mutually exclusive: complex = many items per job; contract = few items per job. The prompt asks the LLM not to mark both true, but on borderline accounts it sometimes does. When both come back true, resolve via `avg_line_items_per_invoice` (backend metric, in payload):

| Condition | Resolution |
|---|---|
| `avg_line_items_per_invoice ≥ 3` | force `complex_multi_line_jobs = true`, `contract_based_billing = false` |
| `avg_line_items_per_invoice ≤ 2` AND `avg_invoice_amount ≥ $2000` | force `contract_based_billing = true`, `complex_multi_line_jobs = false` |
| neither condition matches | leave both true — genuine bimodal mix, weighted sum stands |

The resolved booleans are what get written to the typed evidence columns on `account_fsm_fit` ([`storage.md`](../../implementation/storage.md) § Structure) — i.e. the resolver's output is the canonical record, not the raw LLM emit.

**Status.** Documented; not yet implemented in `applyRuleV3`. Currently both booleans go straight into the weighted sum, so an LLM that emits both true on the same account double-counts to `0.15 + 0.10 = 0.25`. Implementation tracked alongside the next rule-tuning pass.

## Offer routing

The rule also outputs `recommended_offers` (plural ARRAY; single winner in v1) via a deterministic decision tree. Evaluated top-to-bottom; the first row whose conditions all hold wins (PM tiebreaker priority); the winning offer is stored as a one-element ARRAY entry.

| # | Conditions | Offer | Pitch |
|---|---|---|---|
| 1 | `b2b_clients_present` AND `avg_invoice_amount ≥ $2000` AND `invoice_count_30d ≥ 15` | `workers_team` | High-volume B2B operation → multi-user workspace with role-based access |
| 2 | `recurring_billing` AND `on_site_work` AND `repeat_customer_ratio ≥ 0.5` | `recurring_automation` | Repeat service visits → recurring-invoice templates + auto-billing |
| 3 | `contract_based_billing` AND `on_site_work` AND `avg_invoice_amount ≥ $2000` | `contract_deposits` | Large project work → progress invoicing + deposit handling |
| 4 | `complex_multi_line_jobs` AND `on_site_work` | `jobs_as_folders` | Composite jobs → group line items into job folders |
| 5 | `scheduling` AND `on_site_work` | `schedule_visits` | Appointment / multi-visit work → calendar + dispatch (default FSM-fit offer) |
| 6 | `labour_billing` AND `estimate_to_invoice_rate < 0.6` | `estimate_workflow` | Quoting bottleneck → estimate → invoice conversion flow |
| 7 | (no row above matched) | `none` | — |

The offer powers in-app proposal copy — per-segment messages live in [`copy.md`](copy.md). PM-drafted source: [`../../ideas/misha/README.md`](../../ideas/misha/README.md) § H. **EQ-5 open** ([`../../ideas/misha/README.md`](../../ideas/misha/README.md) § "Open engineering questions"): whether this decision tree executes in the C# rule (current shape), is emitted by the LLM directly, or runs in the BFF. Engineering recommendation is C# rule (this section's current shape).

**Relationship to weights / tier.** Offer routing is **independent of the weighted sum and tier score** — it only reads the (resolved) LLM-emit booleans, two backend booleans, and a few backend metrics. Re-tuning the weights ([`training.md`](training.md) § Rule weight tuning) does not change which offer an account is routed to.

What the weights / tier *do* drive is the surrounding UX: tier (`strong` / `weak` / `none`) decides whether the in-app proposal is shown at all (PM cut-off TBD, typically `strong` only or `strong + weak`). So weights matter for **gating**; offer routing matters for **content**. The two are orthogonal.

**Tier vocabulary:** `strong | weak | none`. **Score range:** `0.0 .. 1.0` (capped).

## Storage mapping

Per [`../../implementation/storage.md`](../../implementation/storage.md), FSM-fit data lives on two tables — the shared `account_metrics` + the per-analysis `account_fsm_fit` — joined by the `v_fsm_fit` view. Both tables use Storage Write API CDC ingestion with `PRIMARY KEY ... NOT ENFORCED`.

**On `account_fsm_fit`** (one row per `account_id`, refreshed by `AnalyzeJob<FsmFit>`):

- **Typed LLM-emit columns** — `on_site_work`, `labour_billing`, `scheduling`, `recurring_billing`, `complex_multi_line_jobs`, `contract_based_billing` (BOOL); `industry` (STRING, 24-ID enum); `specialization` (STRING).
- **Typed rule outputs** (materialised at write by `FsmFitRule.Apply()`) — `score` (FLOAT64, capped 1.0), `tier` (STRING `strong|weak|none`), `recommended_offers ARRAY<STRUCT<offer STRING, weight FLOAT64>>` (single winner in v1; ARRAY shape future-proofs multi-offer distributions), `industry_bonus` (FLOAT64, 0 or +0.15).
- **Typed provenance** — `reasoning` (STRING ≤ 500 chars), `input_hash` (BYTES, SHA256 over canonicalised payload + prompt + model), `rule_version`, `model_id`, `prompt_version`, `analyzed_at`, `expires_at`, `triggered_by`.

**On `account_metrics`** (one row per subject, shared across all analyses):

- **Typed columns** — the 8 PM-spec numeric metrics (`invoice_count_30d`, `avg_invoice_amount`, `invoice_amount_variance_cv`, `avg_line_items_per_invoice`, `repeat_customer_ratio`, `avg_days_between_repeats`, `estimate_to_invoice_rate`, `estimate_count`); 2 derived booleans (`b2b_clients_present`, `multi_address_work`); `distinct_addresses` count; `business_name`; own `analyzed_at` / `expires_at` / `updated_at`.

**On `v_fsm_fit`** (LEFT JOIN of `account_fsm_fit` and `account_metrics` on subject key):

- Projection + join only. **No rule logic in the view.** All scoring outputs (`score`, `tier`, `recommended_offers`, `industry_bonus`) are read straight from the materialised columns on `account_fsm_fit`. The view is deliberately MV-eligible so Looker Studio can promote it to a materialised view if read latency demands it.

**Why materialised at write, not derived in the view.** Avoids training/serving skew (the C# `IAnalysisRule<FsmFit>` impl is the same one used during Optuna weight tuning); prevents per-read rule drift; lets consumers filter on `tier` and `recommended_offers` with plain typed-column predicates, no `CASE` or JSON shredding. Rationale: [`../../implementation/storage.md`](../../implementation/storage.md) § Structure.
