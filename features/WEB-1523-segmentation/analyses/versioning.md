# WEB-1523 — Versioning (framework)

How every analysis result records *what produced it* and *when it must be recomputed*. This is a **framework-level** concern — the same five version dimensions and the same re-judgement mechanic apply to every analysis in the catalog (FSM-fit v1; `churn_risk` / `suspicious_user` v2). The FSM-fit concrete values are in [`fsm-fit/scoring.md`](fsm-fit/scoring.md); the storage columns are declared in [`../implementation/storage.md`](../implementation/storage.md) § Schemas and the `account_fsm_fit` proto.

Consolidated here because versioning was previously scattered across `architecture.md` (the `input_hash` glossary), `scoring.md` (the rule/threshold split), `storage.md` (the result-row columns), `migrations.md` (table schema), and `provider.md` (`prompt_cache_key`). This doc is the single place that ties them together.

## Decision

- **Five version dimensions are stored on every per-analysis result row** (`account_<type>`): `schema_version`, `prompt_version`, `model_id`, `rule_version`, and the derived `input_hash`. Plus `triggered_by` for audit. They are **debug/audit columns**, not part of the consumer-facing contract.
- **`input_hash = SHA256(canonicalised payload ‖ prompt_version ‖ model_id)` is the re-judgement trigger** — and the one expensive lever, because a drift here means an LLM call. It deliberately **excludes `rule_version`**: the deterministic rule is cheap C# over already-stored evidence, so a rule change must not force a re-prompt.
- **The shared `account_metrics` table is NOT versioned.** It is rule-free and model-free (just aggregated Mongo signal), so it carries no version columns — only `analyzed_at` / `expires_at`. Versioning is an analysis-output concern.
- **Cost asymmetry is the load-bearing idea.** Prompt / model changes → `input_hash` drifts → full LLM re-judge of the whole audience. Rule / threshold changes → re-derive `score` / `tier` from stored evidence with **no LLM call**. Schema changes → table migration + backfill. The framework keeps these three cost classes independent.
- **Per-analysis schemas migrate independently** through the `IModuleMigration` framework ([`../implementation/migrations.md`](../implementation/migrations.md)); adding or altering one analysis's table never touches another's.

## The five versioned dimensions

All live on `account_<type>` (e.g. `account_fsm_fit`); none on `account_metrics`.

| Dimension | Column (type) | Identifies | Bump when… |
|---|---|---|---|
| **Prompt** | `prompt_version` (INT64) | the prompt file `prompts/<analysis_type>/v<N>.md` | the system prompt text / rubric changes |
| **Model** | `model_id` (STRING) | the LLM (e.g. `gpt-4.1-nano`) | you swap model or model snapshot |
| **Rule** | `rule_version` (STRING) | the deterministic `IAnalysisRule.Apply()` — weights + thresholds | the rule's output shape or its tuned weights/thresholds change |
| **Schema** | `schema_version` (INT64) | the emit/table shape (evidence columns, output columns) | you add / rename / drop evidence or output columns |
| **Input hash** | `input_hash` (STRING) | `SHA256(payload ‖ prompt_version ‖ model_id)` | *derived* — recomputed every tick; not bumped by hand |

Plus `triggered_by` (STRING: `scheduled` / `event:<name>` / `manual`) and `analyzed_at` so each row is fully self-describing: *which prompt + model + rule + schema produced this score, when, and why it ran.*

## How versions drive recompute

The per-analysis `AnalyzeJob<TAnalysis>` candidate scan (see [`../implementation/storage.md`](../implementation/storage.md) § Q2 and [`../implementation/analyze.md`](../implementation/analyze.md)):

```
re-judge a subject WHEN  expires_at < NOW()              -- TTL safety net
                    OR   input_hash != computed_hash      -- payload / prompt / model drifted
```

- **Drift path (expensive):** recompute `input_hash` from the current payload + `prompt_version` + `model_id`. If it differs from the stored hash, the LLM fires, the rule runs, and a fresh row is UPSERTed with the new versions. Bumping `prompt_version` or changing `model_id` changes the hash for *every* subject, so the whole audience is re-judged **gradually on the natural cron cadence** — a rolling backfill, not a mass SQL update.
- **Recheck-no-drift (cheap):** if `input_hash` is unchanged when a row's `expires_at` lapses, the producer re-sends the existing row with only `expires_at` / `updated_at` advanced — **no LLM call, no rule re-run** ([`../implementation/storage.md`](../implementation/storage.md) § Recheck-no-drift).
- **Rule re-derive (cheap, separate trigger):** because `rule_version` is *not* in `input_hash`, a rule/threshold change doesn't drift the hash and won't ride the recheck path. It is propagated by an explicit **backfill pass** that re-applies `IAnalysisRule.Apply()` over the **stored evidence** and rewrites `score` / `tier` / `rule_version` — no re-prompting. This is exactly the option-C operational win in [`scoring.md`](scoring.md): "change what counts as strong-fit without re-spending the LLM budget."

## Change playbook

| You changed… | Bump | Re-judgement cost | How it propagates |
|---|---|---|---|
| **Prompt text** | `prompt_version` (+ bump the `prompt_cache_key` suffix, [`../investigation/provider.md`](../investigation/provider.md)) | **LLM call per subject** | `input_hash` drifts → rolling re-judge on the cron |
| **Model** | `model_id` | **LLM call per subject** | `input_hash` drifts → rolling re-judge on the cron |
| **Rule weights / thresholds** | `rule_version` | none (deterministic C#) | explicit backfill re-applies the rule over stored evidence |
| **Evidence / output columns** | `schema_version` + table migration | LLM re-judge to populate new evidence columns | new `V00x` migration alters `account_<type>`; backfill |

The four are independent — e.g. retuning thresholds (Optuna, [`training.md`](training.md)) is a `rule_version`-only change and costs nothing in LLM spend.

## Schema & migration versioning

The table side of versioning, owned by [`../implementation/migrations.md`](../implementation/migrations.md):

- **`IModuleMigration` + ordered `V00x_*` migrations**, applied by the pre-deploy `dotnet Tofu.AI.Api.dll migrate` Job before any rollout (the CI/CD gate). The framework ships with `V001_CreateAccountMetrics` (the shared metrics table); `V002_CreateAccountFsmFit` and `V003_CreateVFsmFit` are introduced later, alongside the `fsm_fit` analysis feature itself.
- **Per-analysis tables migrate independently** ([`../architecture.md`](../architecture.md) § Decision) — one analysis's DDL change never blocks or touches another's. Adding an analysis = new `account_<type>` table + `v_<type>` view migration, picked up automatically.
- **Proto ⇄ table lockstep.** Each result table has a matching Storage Write API proto (`account_metrics.proto`, `account_fsm_fit.proto`); field names/types must track the table DDL, since CDC ingestion uses the proto descriptor. A `schema_version` bump usually means editing both in the same change.

## Catalog / release versioning

The product-release axis (distinct from per-row versions):

- **v1** = `fsm_fit` only. **v2** = `churn_risk` + `suspicious_user` — the framework, storage schema, and abstractions accommodate them **day one** (zero-DDL slot-in per [`../README.md`](../README.md) § Scope). Adding an analysis is one folder + one prompt file + one rule + one migration + one config block — no framework-code edits.
- **Stage 1** (BigQuery only, no user surface) → **Stage 2** (typed REST read API + BFF). The stage-2 read contract is **additive** — new endpoints / optional fields, never a breaking change to stage-1 storage.

## Internal vs. exposed

The version columns are **internal/audit**: they answer "why did this score change?" for engineering and analysts. The BigQuery view `v_fsm_fit` surfaces `rule_version` / `model_id` / `prompt_version` for analyst drill-down, but the **stage-2 consumer-facing API hides them** — the client gets `score` / `tier` / `recommended_offers` / (optionally) `reasoning`, not the debug versions (see `clickup.md` § contract). Treat the version columns as a debugging/audit surface, not a public contract.

## FSM-fit instance (v1 concrete values)

- `prompt_version = 1` — single prompt baked at `prompts/fsm_fit/v1.md` (the ~1,400-token production prompt, [`fsm-fit/prompt.md`](fsm-fit/prompt.md)).
- `model_id = gpt-4.1-nano` (locked, [`../investigation/provider.md`](../investigation/provider.md)).
- `rule_version` — initial weights from the Phase A training sweep; re-tuned via Optuna against stored emit ([`fsm-fit/training.md`](fsm-fit/training.md)) bumps it without re-prompting.
- `schema_version = 1` — the 6 LLM-emit booleans + 2 backend-derived + industry enum in `account_fsm_fit`.

## Open questions

- [ ] **Rule-backfill trigger.** Confirm the concrete mechanism that fans a `rule_version` bump across existing rows (one-off backfill job vs. adding `rule_version` to the candidate-scan predicate). `input_hash` deliberately excludes it, so it needs its own trigger.
- [ ] **`prompt_version` / `schema_version` as INT64 vs semver string.** Currently monotonic integers. Revisit if prompts ever need branch/variant identifiers (e.g. A/B prompt arms during a forward experiment — see [`fsm-fit/forward-ab.md`](fsm-fit/forward-ab.md)).
- [ ] **Retention of superseded rows.** UPSERT overwrites in place (no history table). If "what did this account score under prompt v1?" becomes a question, decide between BigQuery time-travel (partitioning is already in place) and an append-only audit table.
