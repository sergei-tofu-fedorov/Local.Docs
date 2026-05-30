# WEB-1523 — AI-powered user analysis

**Status:** in-progress — stage 1 + FSM-fit analyze stage + Read API all landed on `feature/WEB-1557` (cumulative; **not yet merged to `develop`**). Remaining gaps: Presidio redaction (docs-only), BFF proposal surface, dashboards.
**Started:** 2026-05-10
**Updated:** 2026-05-30
**ClickUp:** https://app.clickup.com/t/WEB-1523
**Affected repos:** see § "Affected repos" below
**Implementation:** split into sub-tickets in the code repo — see § "Implementation status" below

> **Doc vs. code:** this folder is the framework/spec plan. The shipped implementation is the source of truth and is tracked in `Tofu.AI.Backend/Docs/features/{WEB-1526,WEB-1527,WEB-1555,WEB-1557}/`. Where the two disagree, the in-repo docs + code win; the deltas are recorded in § "Implementation status" and inline in the affected docs.

## Implementation status

Built inside the existing **`Tofu.AI.Backend`** repo (base branch `develop`), split into four sub-tickets. As of 2026-05-30 all four are stacked on **`feature/WEB-1557`** (each branched off the previous); the branch is **1 behind / 5 ahead of `origin/develop` and not yet merged**. The repo's own `Docs/features/` is the authoritative implementation record.

| Sub-ticket | Status | Commit | What landed | Repo doc |
|---|---|---|---|---|
| **WEB-1526** — FSM-fit analysis layer + CI/CD migrate gate | landed (on WEB-1557; `origin/feature/WEB-1526-prep` merged to develop) | `e5a63fe` | `Analyses.Application` + `Analyses.Persistence` projects; store-agnostic **module-migration framework** (`IModuleMigration` + runner, parity with `Invoices.Backend`) + `migrate` CLI mode; BigQuery client/settings (`Analyses:BigQuery`); **in-process Hangfire** on Postgres (schema `analyses`); **stub** `MetricsRefreshJob`; Cloud Build retired (GitHub Actions becomes the only deploy path, with a pre-deploy migrate Job gate); Presidio sidecars added to the K8s overlay. | `Docs/features/WEB-1526/README.md` |
| **WEB-1527** — Account metrics collection | landed (on WEB-1557) | `b7161ab`, `b88380a` | `Analyses.Domain` + `Analyses.Infrastructure` projects; four batched Mongo **metrics collectors** (invoices / estimates / clients / accounts) + discovery funnel; the **`account_metrics`** BigQuery table via `V001_CreateAccountMetrics` (replaces the WEB-1526 bootstrap stub); **Storage Write API CDC** upserts; the real `MetricsRefreshJob` (hourly, every-tick discovery + expired re-refresh). Incidental: chat-context GCS made config-driven (`Storage:ServiceAccountKeyPath`, ADC default). | `Docs/features/WEB-1527/{overview,plan}.md` |
| **WEB-1555** — FSM-fit analyze stage (LLM scoring + CDC write) | landed (on WEB-1557) | `bde31e6` | `IFsmFitLlmClient` + **`OpenAiFsmFitClient`** (gpt-4.1-nano, structured outputs); **`FsmFitPrompt`**; **`FsmFitScorer`** (deterministic rule + tiering); **`AnalyzeFsmFitJob`** (due/missing candidates → **FSM-using eligibility trim** via `InvoicesJobsRepository.GetAccountIdsWithRecentJobsAsync` → input-hash cache → LLM + scorer → CDC-UPSERT); **`account_fsm_fit`** table (`V002_CreateAccountFsmFit`) + **`v_fsm_fit`** view (`V003_CreateVFsmFitView`); domain models (`FsmFitFlags/Evidence/Offer/Payload/RuleResult/Tier`, 24-ID `Industry` enum, `InputHash`); `BigQueryAccountFsmFitRepository`; invoice item-name + invoices-jobs signal repos. **Presidio redaction NOT in code — docs only** (`Docs/features/WEB-1555-presidio/`); payload is built from aggregated metrics + top item names directly. | `Docs/features/WEB-1555/{overview,plan}.md`, `WEB-1555-presidio/{overview,plan}.md` |
| **WEB-1557** — FSM-fit Read API | landed (HEAD) | `8c936d5` | **`AccountAnalysesController`** + `FsmFitReadService` / `IFsmFitReadService` / `FsmFitResponse` + BQ read methods on `BigQueryAccountFsmFitRepository`. This is the **stage-2 read API** brought forward (HTTP/REST on `Tofu.AI.Api`). | `Docs/features/WEB-1557/{overview,plan}.md` |

**Still NOT built:**
- **Presidio redaction** (analyze stage) — design docs only (`WEB-1555-presidio/`), no code; the LLM payload currently goes unredacted-by-Presidio (aggregated metrics + item names only).
- **BFF in-app proposal surface** (`Invoices.Backend`) — zero commits; consumes the new Read API in a future ticket.
- **Looker Studio dashboards + checked-in `queries/`**, privacy-policy + sub-processor list update, the SQL-rule baseline comparison, and the industry-expansion cohort.

**Key deltas this plan's design docs were written against, now overridden by the shipped code** (each reconciled inline in the relevant doc):

- **Account-only subject.** `account_metrics` is keyed on a single **`account_id STRING NOT NULL`** PK. `master_user_id` / `platform_user_id` and the `SubjectRef` abstraction were dropped — multi-subject metrics, if ever needed, go in a separate table. *(Overrides `implementation/storage.md` § Q1.)*
- **Partitioning.** `PARTITION BY DATE_TRUNC(updated_at, MONTH)`; the `analyzed_at` column was dropped (recompute == write, so `updated_at` is the single freshness stamp). *(Was `DATE(analyzed_at)`.)*
- **Dataset.** `ai_analysis_v2` (test project `invoicesapp-project-test`), not `ai_analysis`.
- **Migration.** `V001_CreateAccountMetrics`, not `V001_Bootstrap` (the bootstrap stub was replaced before any environment applied it).
- **Single Deployment.** Hangfire runs in-process inside `Tofu.AI.Api`; no separate Worker Deployment in v1.

## Goal

Build an **AI-powered analysis platform** over our **users** (the SaaS account owners on our platform). "Users" here means our customers — the people who pay us — **not** the `Client.cs` entity (which represents a contact a user invoices). The platform pulls together what a user generates on the platform — clients, invoices, estimates, payments, subscription state, product behaviour — and feeds it through a generic per-analysis pipeline (signal aggregation → redaction → LLM → deterministic rule → score + tier) into BigQuery.

**v1 ships one analysis** — `fsm_fit` — but the system is built as a multi-analysis platform from day one. The intended catalog: v2 brings `churn_risk` and `suspicious_user`, with `activation` / `expansion` / `lookalike` queued behind them. Every doc in this folder is either framework-level (applies to all analyses) or the FSM-fit instance of a framework concern.

**v1 primary outcome:** **propose the FSM (Jobs) feature to invoice-only users in-app** — score users currently issuing only invoices for whether their business pattern suggests they'd benefit from the FSM upsell, then surface a proposal banner / suggestion card to high-fit accounts. The audience is invoice-only users; existing job-using users are out of scope (they already have FSM). FSM-fit must therefore be inferred from invoice-only signal: item text, business name, repeat-client patterns, etc.

**v2 outcomes (committed scope, framework must accommodate on day one):** `churn_risk` (ops retention outreach) and `suspicious_user` (ops review queue). These do not ship in v1, but the framework, storage schema, and abstractions must already support them: the analysis contract in [`analyses/scoring.md`](analyses/scoring.md) § Decision plus the per-analysis JSON shape in [`implementation/storage.md`](implementation/storage.md) make slotting them in zero-DDL.

## Scope

**v1 / stage 1 (this feature):**
- In scope:
  - Extend the existing `Tofu.AI.Backend` repo (currently a ChatGPT-proxy service) with the generic multi-analysis framework (see [`implementation/service.md`](implementation/service.md)).
  - **One concrete analysis: `fsm_fit`** — full training sweep, prompt, rule, BigQuery storage.
  - BigQuery dataset (`ai_analysis_v2`) + shared `account_metrics` (shipped) + per-analysis `account_<type>` table + `v_<type>` view (planned); Storage Write API CDC ingestion (`_CHANGE_TYPE = 'UPSERT'`, `PRIMARY KEY ... NOT ENFORCED`); rule materialised at write time in C#, no view-side SQL ([`implementation/storage.md`](implementation/storage.md)).
  - Hangfire background jobs **in-process inside `Tofu.AI.Api`** (storage: Postgres in schema `analyses`) + K8s manifests + pre-deploy migration Job + CI/CD ([`implementation/service.md`](implementation/service.md)). Single-pod design — no separate Worker Deployment in v1.
  - Results consumed via existing BigQuery clients (Looker Studio ad-hoc, BQ Web UI, `gcloud bq`) under the PM Google Group's `dataViewer` binding.
  - Privacy-policy + sub-processor list updates covering the **catalog**, not just FSM-fit.
- Stage 2 (deferred — separate ticket):
  - HTTP/REST read API (`GET /accounts/{id}/analyses`, `GET /accounts/{id}/analyses/{type}` — JSON in the view's nested-array shape).
  - BFF integration exposing FSM-fit to the in-app proposal surface.
  - Committed Looker Studio dashboards + checked-in queries under `queries/fsm_fit/`.
- Out of scope (deferred further / future):
  - Concrete `churn_risk` / `suspicious_user` analyses — framework supports them, but training/prompt/rule land in their own future tickets.
  - `Tofu.Auth.Backend` signal-source gRPC client (needed by churn/suspicious, not FSM-fit).
  - Per-analysis-type-specific dashboards beyond FSM-fit.
  - Active-learning / feedback loop on hand-labels.

## Affected repos

**v1 scope:**

- `Tofu.AI.Backend` (**existing repo, extended** — producer of analyses) — currently a single-project ChatGPT-proxy service (`Tofu.AI.Api`, deployed as `tofu-ai-api-deployment` on `invoices-cluster`). WEB-1523 stage 1 extends it in-place with the FSM-fit multi-analysis framework: adds the `src/Analyses/` module (Domain / Application / Infrastructure / Persistence split) + an in-process Hangfire server inside `Tofu.AI.Api` + pre-deploy migration Job for BigQuery schema. The same single Deployment serves HTTP requests, runs the migration CLI, and executes the Hangfire recurring jobs that write to BigQuery. Hangfire storage is Postgres in schema `analyses`. The typed HTTP/REST read API lands in stage 2 (additional controllers in the same process). A separate `Tofu.AI.Worker` Deployment was considered but deferred — see [`implementation/service.md`](implementation/service.md) § Q1 § "Why single Deployment in v1".
- `Tofu.Docs` — this plan + API docs.

**Stage 2 / future repos:**

- `Invoices.Backend` (BFF / consumer) — stage 2: calls the new gRPC client and surfaces FSM-fit proposal in-app.
- `Tofu.Auth.Backend` — signal source for `churn_risk` (login recency, session signal). v1 must not preclude wiring a gRPC client here in v2; no v1 code changes.
- `Tofu.Invoices.Backend` — currently no v1 code changes required (signal aggregation reads Mongo directly via the BFF aggregator pattern). May host invoice-derived signal RPCs in v2 if v1 aggregation turns out cross-cutting; tracked, not committed.

**Cross-repo notes:**
- **Stage 1 contract changes:** none across repos — `Tofu.AI.Backend` writes to its own BigQuery dataset; no consumer wiring required.
- **Stage 2 contract changes:** additive — two new HTTP/REST endpoints under `Tofu.AI.Api` returning JSON in the consumer-facing view shape (generic envelope; analysis-specific evidence/output lives inside a JSON object per element). The BFF references the new `Tofu.AI.Api.Client` NuGet (HTTP client generated from controllers via NSwag/Refit, or hand-written DTOs) after the producer is deployed. REST chosen over gRPC because per-analysis JSON cells are variable-shaped — see [`implementation/service.md`](implementation/service.md) § Decision § Read API.

## Plan

Implementation breakdown is tracked directly in ClickUp under WEB-1523 sub-tickets (WEB-1526, WEB-1527). The architectural shape lives in [`architecture.md`](architecture.md); per-area execution detail lives in [`implementation/service.md`](implementation/service.md), [`implementation/storage.md`](implementation/storage.md), [`implementation/metrics.md`](implementation/metrics.md), and [`implementation/migrations.md`](implementation/migrations.md). The authoritative record for shipped slices is `Tofu.AI.Backend/Docs/features/WEB-1526` + `WEB-1527`.

## Docs in this folder

> Paths corrected 2026-05-27 — most spike docs moved into `analyses/`, `investigation/`, `implementation/`, and `prototype/` subfolders. The **Built?** column marks whether the doc's design exists in `Tofu.AI.Backend` code today (✅ shipped, 🟡 partial, ⬜ not yet). The authoritative record for built features is the in-repo `Docs/features/WEB-1526` + `WEB-1527`.

**Top-level**

| Doc | What it covers | Scope | Built? |
|---|---|---|---|
| [`architecture.md`](architecture.md) | Architecture & implementation overview — the consolidated shape across storage, service, pipeline. | framework | 🟡 |
| [`clickup.md`](clickup.md) | ClickUp task tree (Phase 1 / Phase 2 breakdown). | process | — |

**Framework + FSM-fit design (`analyses/`)**

| Doc | What it covers | Scope | Built? |
|---|---|---|---|
| [`analyses/data-sources.md`](analyses/data-sources.md) | Data inventory across the workspace — the sources available for any analysis's payload. | framework | — |
| [`analyses/metrics.md`](analyses/metrics.md) | Backend metrics catalog + per-metric Mongo query plan feeding `account_metrics`. | framework | ✅ |
| [`analyses/scoring.md`](analyses/scoring.md) | Analysis contract (`IAnalysis` / `IAnalysisRule` / emit schema / tier vocabulary) + option-C decision + LLM-reliability findings. | framework | 🟡 (FSM-fit concrete via `FsmFitScorer`; generic `IAnalysis<T>` extraction deferred to 2nd analysis) |
| [`analyses/versioning.md`](analyses/versioning.md) | The five per-row version dimensions (`schema_version` / `prompt_version` / `model_id` / `rule_version` / `input_hash`) + recompute + catalog versioning. | framework | 🟡 (`input_hash` cache shipped in `AnalyzeFsmFitJob`) |
| [`analyses/flexible-metrics.md`](analyses/flexible-metrics.md) | **Theory** — evolving the `account_metrics` feature store: metric-as-code catalog, additive-only schema + proto lockstep, definition-hash versioning, TTL-loop-as-backfill, recompute. | framework | ⬜ (design only) |
| [`analyses/presidio.md`](analyses/presidio.md) | Presidio redaction implementation plan (analyze-stage PII scrub before the LLM call). | framework | ⬜ (docs only — sidecars in K8s overlay, no redaction code) |
| [`analyses/training.md`](analyses/training.md) | Per-analysis training pattern — prompt iteration + rule-weight tuning with Optuna against stored LLM emit. | framework | n/a |
| [`analyses/fsm-fit/scoring.md`](analyses/fsm-fit/scoring.md) | FSM-fit — 6 LLM-emit booleans + 2 backend-derived + 24-ID industry enum + offer routing tree + storage mapping. | FSM-fit | ✅ (`FsmFitScorer` + `FsmFit*` models + `Industry` enum) |
| [`analyses/fsm-fit/prompt.md`](analyses/fsm-fit/prompt.md) | FSM-fit system prompt — verbatim mirror + section reading + open issues. | FSM-fit | ✅ (`FsmFitPrompt`) |
| [`analyses/fsm-fit/copy.md`](analyses/fsm-fit/copy.md) | FSM-fit proposal copy. | FSM-fit | ⬜ |
| [`analyses/fsm-fit/analytics-events.md`](analyses/fsm-fit/analytics-events.md) | Event schema for the BFF proposal surface (`cohort_assigned`, `proposal_shown`/`_clicked`/`_dismissed`, `fsm_trial_started`). | FSM-fit | ⬜ |
| [`analyses/fsm-fit/forward-ab.md`](analyses/fsm-fit/forward-ab.md) | Forward A/B design — hypothesis, primary metric menu, cohort, MDE, kill switch. `PM TO DECIDE` marked. | FSM-fit | ⬜ |
| [`analyses/fsm-fit/training.md`](analyses/fsm-fit/training.md) | FSM-fit training cycle — sample + hand-labelled seed + prompt-refinement history + Optuna skeleton. | FSM-fit | n/a |
| [`analyses/fsm-fit/industry-expansion.md`](analyses/fsm-fit/industry-expansion.md) | Proposal to extend the 24-ID `industry` enum from the `tier=strong ∧ industry=other` v3 cohort. | FSM-fit | ⬜ |

**Implementation specs (`implementation/`) — reconciled against shipped code**

| Doc | What it covers | Scope | Built? |
|---|---|---|---|
| [`implementation/service.md`](implementation/service.md) | `Tofu.AI.Backend` service layout, abstractions, in-process Hangfire, K8s manifest, `migrate` CLI. | framework | 🟡 |
| [`implementation/storage.md`](implementation/storage.md) | BigQuery layout — `account_metrics` + `account_fsm_fit` (`V002`) + `v_fsm_fit` (`V003`) all shipped; partitioning + CDC write paths live. | framework | ✅ |
| [`implementation/metrics.md`](implementation/metrics.md) | Metrics collection implementation — collectors, discovery funnel, batched aggregations. | framework | ✅ |
| [`implementation/metrics-interaction.md`](implementation/metrics-interaction.md) | Metrics-collection interaction/sequence detail. | framework | ✅ |
| [`implementation/migrations.md`](implementation/migrations.md) | Module-migration framework (`IModuleMigration` + runner) + BigQuery module + `migrate` gate. | framework | ✅ |
| [`implementation/ci-cd.md`](implementation/ci-cd.md) | CI/CD — single GitHub Actions deploy path with a pre-deploy migrate Job gate (Cloud Build retired). | framework | ✅ |
| [`implementation/analyze.md`](implementation/analyze.md) | Analyze-stage pipeline (LLM + redaction + scoring) implementation plan. | framework | 🟡 (LLM + scoring + CDC write shipped in WEB-1555; redaction step still missing) |
| [`implementation/mongo-data-federation.md`](implementation/mongo-data-federation.md) | Mongo snapshot export → GCS → BigQuery Data Federation read path. | framework | ⬜ |

**Investigation spikes (`investigation/`)**

| Doc | What it covers | Scope |
|---|---|---|
| [`investigation/provider.md`](investigation/provider.md) | LLM model + integration + cost mechanics. Locked on OpenAI `gpt-4.1-nano`. | framework + FSM-fit |
| [`investigation/privacy.md`](investigation/privacy.md) | PII payload shape, Presidio redaction, per-analysis PII allow-list, DPA layer, disclosure (privacy policy, sub-processor list, AI Act). | framework + FSM-fit |
| [`investigation/metrics.md`](investigation/metrics.md) | Filling `account_metrics` — sourcing options (Mongo direct vs Federation vs DWH). | framework |
| [`investigation/dwh.md`](investigation/dwh.md) | Playfair DWH — existing Tofu data already in BigQuery. | framework |
| [`investigation/mongo-read-isolation.md`](investigation/mongo-read-isolation.md) | Mongo read-isolation options for `account_metrics` collection. | framework |
| [`investigation/postgres-read-isolation.md`](investigation/postgres-read-isolation.md) | Postgres read-isolation options for the (analyze-stage) eligibility probe. | framework |
| [`investigation/scoring-patterns.md`](investigation/scoring-patterns.md) | Industry scoring patterns (research). | FSM-fit |

**Prototype (`prototype/infrastructure/`)** — superseded Postgres-store prototype, kept for history; the shipped store is BigQuery.

| Doc | What it covers |
|---|---|
| [`prototype/infrastructure/service.md`](prototype/infrastructure/service.md) | Service (Postgres prototype). |
| [`prototype/infrastructure/storage.md`](prototype/infrastructure/storage.md) | Storage (Postgres prototype). |

`ideas/{maxim,misha,tanya}/` hold individual brainstorming notes. Most `*.md` open with a `## Decision` section capturing the locked picks; the rest is the research that informed them.

> The Looker Studio / dashboards doc referenced in earlier revisions (`infrastructure/dashboards.md`) was never written — dashboards are stage-2 and unbuilt. The `queries/` subdirectory it referenced likewise does not exist yet.

## Upstream blockers

The **metrics feature-store** (WEB-1527), framework scaffolding (WEB-1526), the **FSM-fit analyze stage** (WEB-1555 — LLM scoring + CDC write), and the **Read API** (WEB-1557) have all landed on `feature/WEB-1557`. The blockers below no longer gate that built work — they now gate **production rollout** (prod GCP, OpenAI billing) and the **stage-2 BFF proposal surface** (PM proposal-surface decision, forward-A/B). The Presidio redaction code gap is tracked in § "Implementation status", not here.

| Blocker | Status | Owned by |
|---|---|---|
| **Training step 2 — run the sweep, pick winner** (see [`analyses/fsm-fit/training.md`](analyses/fsm-fit/training.md) § Decision) | ✅ done (2026-05-13) — winner OpenAI `gpt-4.1-nano`, ~1,400-token prompt, `$0.20 / 1,000 accounts` | Engineering |
| **GCP project name** (referenced throughout [`implementation/storage.md`](implementation/storage.md)) | 🟡 test set — `invoicesapp-project-test` is wired in `appsettings.json`; prod project still to confirm | Whoever owns prod-GCP IAM |
| **PM Google Group identity** — `dataViewer` binding shape; fallback to per-user if no group | ⬜ open (stage-2 read access) | Sales-ops / platform |
| **OpenAI billing-owner confirmation** ([`investigation/provider.md`](investigation/provider.md) § Decision) | ⬜ open (analyze stage) | Whoever owns the OpenAI relationship |
| **PM nails down proposal surface** — banner / card / inbox; static vs LLM copy; is `reasoning` user-visible; suppression on dismiss / re-score. Score has no target shape until locked. | ⬜ open (analyze stage / stage 2) | PM |
| **Forward A/B design for FSM-fit rollout** — hard gate before BFF stage-2 surface. Event schema ([`analyses/fsm-fit/analytics-events.md`](analyses/fsm-fit/analytics-events.md)) + experiment draft ([`analyses/fsm-fit/forward-ab.md`](analyses/fsm-fit/forward-ab.md)) pre-committed; PM decides primary metric, holdout, MDE, kill triggers. | ⬜ open (stage 2) | PM |
| **SQL-rule baseline for FSM-fit** — deterministic non-LLM heuristic on the 1,000-account sample, a comparison column in the validation artifact. | ⬜ open (analyze stage) | Engineering |
| **`queries/` subdirectory** doesn't exist yet — dashboards/query templates are stage-2 and unstarted | ⬜ open (stage 2) | Implementation PR |

Stage 1's load-bearing blocker (the training sweep) has cleared; the remaining blockers are analyze-stage / stage-2 concerns.

## Sequenced next moves

**Phase A — training (complete, 2026-05-13).** Hand-labelled 30 stratified seed accounts; ran the prompt-variant × cheap-tier-model sweep; winner is OpenAI `gpt-4.1-nano` with the ~1,400-token production prompt. Full 1,000-account validation run produced the measured cost of `$0.20 / 1,000 accounts`. Details in [`analyses/fsm-fit/training.md`](analyses/fsm-fit/training.md).

**Phase A½ — PM demo (~few hours).** Run the winning combo over a 100-account demo subset and produce a markdown + JSON artifact that the product manager signs off on *before* we invest in the service infrastructure. If this fails, iterate on the prompt / rule / redaction and re-run — far cheaper than discovering the problem after the service ships.

**Phase B — clear admin blockers in parallel (~1 week).** GCP project name (test wired; prod TBD); PM Google Group; OpenAI billing-owner. `Scope` + `Affected repos` above are filled.

**Phase D — implementation (in progress).** Status as of 2026-05-30 (all on `feature/WEB-1557`, not yet merged to `develop`):

- ✅ **Done (WEB-1526 + WEB-1527):** extended the existing `Tofu.AI.Backend` solution with the `src/Analyses/` module (`Analyses.{Domain,Application,Infrastructure,Persistence}`; existing `Tofu.AI.Api` chat code untouched); BigQuery dataset + shared `account_metrics` via `IBigQueryMigration` (`V001_CreateAccountMetrics`) applied by the `migrate` CLI / pre-deploy K8s Job (per [`implementation/service.md`](implementation/service.md) + [`implementation/storage.md`](implementation/storage.md)); the four Mongo metrics collectors + discovery funnel; Hangfire jobs **in-process inside `Tofu.AI.Api`** streaming UPSERTs into BigQuery via Storage Write API **CDC** (no staging tables, no MERGE); the K8s overlay bumped (Hangfire co-hosted, migration Job added, Presidio sidecars) — no new Deployment objects.
- ✅ **Done (WEB-1555 — analyze stage):** `account_fsm_fit` table (`V002`) + `v_fsm_fit` view (`V003`); OpenAI `gpt-4.1-nano` LLM client per [`investigation/provider.md`](investigation/provider.md); `FsmFitScorer` deterministic rule + tiering; `AnalyzeFsmFitJob` with FSM-using eligibility trim + input-hash cache + CDC-UPSERT. **Gap:** Presidio redaction is docs-only (no code) — payload is unredacted aggregated metrics + item names.
- ✅ **Done (WEB-1557 — read API, pulled forward from stage 2):** `AccountAnalysesController` + `FsmFitReadService` returning the view-shaped FSM-fit JSON.
- ⬜ **Pending:** Presidio redaction code; BFF in-app proposal surface in `Invoices.Backend`; Looker Studio dashboard + checked-in `queries/*.sql`; privacy-policy + sub-processor list update; SQL-rule baseline comparison.

Full breakdown tracked in ClickUp.

**Phase E — rollout.** Canary on 100 internal-test accounts → 1000 real accounts → all 50k. `/feature done` to flip `Status: shipped`.

## Prior art

- `Tofu.Docs/features/ai_summary/` — existing `feature/ai_summary` branch with an AI Summary endpoint and a DeepSeek-based **FSM compatibility** classifier built off invoice history. The branch is being dropped per the feature owner's call; WEB-1523 builds fresh as `Tofu.AI.Backend`.

## API / DTO changes

**Stage 1 (shipped): none cross-repo.** `Tofu.AI.Backend` writes to its own BigQuery dataset; no gRPC/REST contract is exposed to other repos. The only new "interface" is the `migrate` CLI verb on the existing image (`dotnet Tofu.AI.Api.dll migrate [--dryrun]`).

**Stage 2 (planned): additive REST** — `GET /accounts/{id}/analyses` + `GET /accounts/{id}/analyses/{type}` on `Tofu.AI.Api`, consumed by the BFF via a new `Tofu.AI.Api.Client`. Not yet built.

## Breaking changes

**Cross-repo: none — additive only.** Stage 1 is an isolated extension of an existing service writing to a fresh dataset.

Internal / operational notes (not consumer-facing):
- **Migration rename** `V001_Bootstrap` → `V001_CreateAccountMetrics`. Fresh DBs apply cleanly; any dev DB that already ran the WEB-1526 bootstrap stub must drop the stale `schema_bootstrap` table + its `migration_history` row. No environment shipped the bootstrap, so this is a no-op in practice.
- **Chat-context GCS is now config-driven** (`Storage:ServiceAccountKeyPath`, ADC by default) — the hardcoded `gcs-secrets/…json` key file is gone. Envs that relied on the key file must run under Workload Identity / ADC or set the path.

## Data / migration

- **New BigQuery dataset `ai_analysis_v2`** (test project `invoicesapp-project-test`, location `US`): `account_metrics` table + a `migration_history` table (owned by the BigQuery migration runner). Created by the `migrate` Job, not at app startup.
- **Postgres schema `analyses`** for Hangfire job storage (`ConnectionStrings:Analyses`); auto-prepared at startup (`PrepareSchemaIfNecessary`), not by the migrate gate.
- **Mongo: read-only.** The collectors + discovery read `invoices`, `estimates`, `clients`, `accounts` via `ConnectionStrings:Mongo`; no writes, no new collections.
- **Cross-repo prerequisite:** a partial index `invoices.{CreatedTime:1}` (filter `IsDeleted IN [false, null]`) in `Tofu.Invoices.Backend` gates discovery-sweep performance (separate PR).
- No new Mongo collections for cached analyses/embeddings/scoring — analysis results live in BigQuery (`account_<type>` tables), not Mongo.

## Open questions

- [x] ~~How does this overlap with `feature/ai_summary` / FSM-compatibility work? Extend, replace, or coexist?~~ — **Resolved (2026-05-12):** `feature/ai_summary` (an earlier DeepSeek-based exploration) is dropped. WEB-1523 builds the FSM-fit pipeline inside the **existing `Tofu.AI.Backend` repo** (currently a ChatGPT-proxy service with `tofu-ai-api-deployment` live on `invoices-cluster`). The existing chat code stays untouched; the new analysis pipeline lives in new projects added to the same solution. The `tofu-ai.yaml` K8s overlay is **not orphaned** — it is the live manifest for the existing repo, which WEB-1523 extends rather than replaces.
- [x] ~~Cloud LLM vs. self-hosted~~ — **Resolved:** cloud (OpenAI `gpt-4.1-nano` direct API, strict structured outputs). See [`investigation/provider.md`](investigation/provider.md).
- [x] ~~Which secondary outcomes are in scope for v1 vs. deferred?~~ — **Resolved (2026-05-13):** v1 ships `fsm_fit` only; `churn_risk` + `suspicious_user` are committed v2; rest are future. Framework must accommodate v2 on day one.
- [x] ~~What is the user-facing surface — admin dashboard widget? internal-only sales-ops tool? user-facing insight in the app?~~ — **Resolved (2026-05-13):** **in-app proposal** for FSM-fit (audience: end user). v2 analyses are ops-only. Per-analysis audience captured in the catalog.
- [ ] **Proposal-surface specifics for `fsm_fit`** (PM): banner vs. card vs. inbox; static copy vs. LLM-generated; is `reasoning` user-visible; suppression rules on dismiss / re-score. Drives prompt rubric and the score's target shape — must land before Phase D starts.
- [ ] **Forward-A/B design** for the FSM-fit rollout — see [`analyses/fsm-fit/forward-ab.md`](analyses/fsm-fit/forward-ab.md) (engineering staged the event schema and experiment skeleton; PM-decision sections marked). Hard gate before stage-2 BFF surface — see also [`ideas/misha/README.md`](ideas/misha/README.md) § 7.

