# WEB-1523 — Architecture & implementation overview

> **Implementation status (2026-05-27).** This overview describes the full target architecture. **Built today (WEB-1526 + WEB-1527):** the single-Deployment runtime, in-process Hangfire (schema `analyses`), the `migrate` CLI + gate, the BigQuery dataset **`ai_analysis_v2`**, and **Layer A** — the shared **`account_metrics`** table + the Mongo metrics-collection pipeline (`MetricsRefreshJob`), via Storage Write API CDC. **Not built (analyze stage):** **Layer B** in its entirety — the LLM judgement path, Presidio redaction, the FSM-fit audience filter, the per-analysis `account_<type>` tables (`account_fsm_fit`) + `v_<type>` views, the scoring rule, and the multi-analysis framework abstractions (`IAnalysis`/`IAnalysisRule`/`AnalyzeJob<T>`). Two corrections applied throughout: `account_metrics` is keyed on a **single `account_id`** (not the subject-key triple), and there is **no `Tofu.AI.Worker` project**. Cadence is **hourly**, not daily.

## TL;DR

`Tofu.AI.Backend` runs an analytical pipeline that, **for each platform user account**, asks an LLM specific questions about their business pattern, applies a deterministic C# scoring rule, and stores the result in BigQuery. v1 ships **one analysis** — `fsm_fit`, scoring invoice-only users on whether they'd benefit from the FSM/Jobs product — but the framework supports adding new analyses by adding one table + one view, with no edits to framework code or existing analyses' tables.

Single K8s Deployment (`tofu-ai-api-deployment`, 2 replicas) — the API process hosts the HTTP surface, the migration CLI, and the Hangfire server + dashboard **in-process**. A separate `tofu-ai-worker-deployment` was originally planned (mirroring `Invoices.Backend`'s API+Worker split) but never created — deferred until either Hangfire load demonstrably contends with HTTP latency or read-path scaling demands diverge from write-path. Storage: one shared `account_metrics` table (shipped) + one `account_<analysis>` table per analysis + one thin `v_<analysis>` view per analysis (analyze stage, unbuilt). Writes via Storage Write API **CDC ingestion** (`_CHANGE_TYPE = 'UPSERT'`, `PRIMARY KEY ... NOT ENFORCED`, `max_staleness = INTERVAL 15 MINUTE`) — no staging tables, no scheduled batch reconciliation. The metrics refresh job runs **hourly** (24h `RefreshTtl`); the FSM-fit LLM cadence (90d) and v2 cadences belong to the unbuilt Layer B ([`analyses/scoring.md`](analyses/scoring.md)).

## Key decisions

The foundational choices the rest of the design depends on. Each row is "what we picked" + a one-line rationale or a link to the deep-dive that justifies it.

| Decision | Pick | Why / where justified |
|---|---|---|
| Persistence | **BigQuery** (dataset `ai_analysis_v2`) | Columnar analytics workload + native CDC ingestion via Storage Write API; Looker Studio is the primary consumer ([`storage.md`](implementation/storage.md) § Q2). |
| Table layout | **One `account_<type>` table per analysis** (not one unified `account_analyses` table) | Eliminates JSON shredding on read; MV-eligible views; per-analysis schema migrations stay independent ([`storage.md`](implementation/storage.md) § Structure). |
| Ingestion mechanic | **Storage Write API CDC stream** with `_CHANGE_TYPE = 'UPSERT'` and `PRIMARY KEY ... NOT ENFORCED` (not staging tables + scheduled `MERGE`) | Native row-level upserts, no batch reconciliation job, sub-minute write-to-visible latency ([`storage.md`](implementation/storage.md) § Q2). |
| Deployment shape | **Single Deployment** (`tofu-ai-api-deployment` — API + Hangfire in-process, 2 replicas) | API+Worker split deferred — at v1 load the Hangfire workload fits inside the API pod's headroom and the split's ops cost (separate manifest, separate tuning, separate rollout) outweighs the failure-isolation benefit. Re-evaluate triggers in [`service.md`](implementation/service.md) § Q1 § "Why single Deployment in v1". |
| Job runtime | **Hangfire** embedded in the API process, storage on **Postgres** in schema `analyses` | Mirrors `Invoices.Backend`'s `Hangfire.PostgreSql` setup (`Src/Notifications/Notifications.Infrastructure/Hangfire/HangfireConfiguration.cs`, which uses schema `hangfire`) in shape, but inlined in the AI service's API host at `src/Tofu.AI.Api/Hangfire/HangfireConfiguration.cs`. AI service uses schema `analyses` to keep its job tables clearly owned. **New Postgres dependency** for this service. With 2 API replicas, `Hangfire.PostgreSql`'s distributed advisory lock serialises recurring ticks across pods ([`service.md`](implementation/service.md) § Q2). |
| LLM provider | **OpenAI `gpt-4.1-nano`** with EU/US jurisdiction routing per account | Strict structured outputs + per-jurisdiction OpenAI Projects keep payloads compliant ([`investigation/provider.md`](investigation/provider.md) § 2). |
| PII redaction | **Presidio sidecar** in-cluster | Redact-before-egress is non-negotiable; per-analysis allow-list is a first-class concern ([`investigation/privacy.md`](investigation/privacy.md)). |
| Source-of-truth for inputs | **Mongo Data Federation over snapshots** for invoice / estimate / client / account signals (prod); a **plain default connection to prod Mongo** on stage, as the other services use (collection names match, no Federation needed there). The **read-only Postgres against `Invoices.Backend`'s `jobs` schema** is *not* a metrics input — it backs the FSM-fit **audience filter** (Layer B), see [`implementation/analyze.md`](implementation/analyze.md) § Audience eligibility | AI reads are bulk + async; the snapshot-backed Federation endpoint keeps prod replica sets uncontested entirely ([`investigation/mongo-read-isolation.md`](investigation/mongo-read-isolation.md) § Decision, [`service.md`](implementation/service.md) § Q1). |

## Services interaction

```
                          ┌───────────────────────────────┐
                          │  PM dashboards (Looker Studio)│
                          │  Ad-hoc bq queries            │
                          │  BFF stage-2 HTTP/REST client │
                          └────────────────┬──────────────┘
                                           │ SELECT … FROM v_<analysis>
                                           ▼
                          ┌───────────────────────────────┐
                          │  BigQuery `ai_analysis_v2`       │
                          │                               │
                          │   v_fsm_fit (view)            │  ◄── projection + join
                          │      ↑   ↑                    │     (no rule logic;
                          │      │   │ LEFT JOIN          │      MV-eligible)
                          │      │   │                    │
                          │   account_fsm_fit             │  ◄── typed columns,
                          │     (PK account_id,           │      score/tier/offers
                          │      max_staleness 15m)       │      materialised at
                          │      ▲                        │      write by C# rule
                          │      │                        │
                          │   account_metrics             │  ◄── shared, hourly
                          │     (PK account_id,NOT ENFRCD)│
                          └────────────────▲──────────────┘
                                           │ Storage Write API CDC
                                           │ (_CHANGE_TYPE = 'UPSERT')
                                           │ Storage Write API CDC
                                           ▼
                          ┌───────────────────────────────────────┐
                          │   Tofu.AI.Api  (2 replicas)           │
                          │     ─ HTTP entry (chat-proxy + stage-2)
                          │     ─ Hangfire server + dashboard     │
                          │       (in-process, schema `analyses`) │
                          │     ─ Recurring jobs:                 │
                          │         • metrics refresh             │
                          │         • LLM judgement               │
                          │     ─ `dotnet ... migrate` CLI mode   │
                          └───────────┬─────────────┬─────────────┘
                                      │             │
                                      │             │ aggregate from snapshots
                                      │             ▼
                                      │   ┌─────────────────────────┐
                                      │   │  Mongo Data Federation  │
                                      │   │  endpoint (prod)        │
                                      │   │   ↑ periodic snapshots  │
                                      │   │   ↑ invoices/estimates/ │
                                      │   │     clients/accounts    │
                                      │   │                         │
                                      │   │  stage: secondaryPref.  │
                                      │   │  direct to prod Mongo   │
                                      │   └─────────────────────────┘
                                      │
                                      │ LLM call (strict structured outputs)
                                      ▼
                          ┌─────────────────────────────┐
                          │  OpenAI API                 │
                          │  gpt-4.1-nano               │
                          │  US project / EU project    │
                          │  (per-account jurisdiction) │
                          └─────────────────────────────┘
```

**Boundary rules:**

- **`Tofu.AI.Api` is the only writer to BigQuery** — the Hangfire server runs in-process inside this Deployment; no separate Worker. Recurring jobs (metrics refresh, per-analysis LLM judgement) are scheduled and executed by the same pod that serves HTTP and runs the migration CLI ([`implementation/service.md`](implementation/service.md) § Q2).
- **`Tofu.AI.Api` is also the only reader of BigQuery** (when stage-2 lands) — read-side controllers share the same process as the writer.
- **Cross-repo data reads are read-only.** In **prod**, Mongo reads go through the **Data Federation endpoint** backed by periodic snapshots of `invoices` / `estimates` / `clients` / `accounts` — prod replica sets are not touched at all ([`investigation/mongo-read-isolation.md`](investigation/mongo-read-isolation.md) § Decision). In **stage**, the same code reads directly from the live prod Mongo clusters via a plain default connection, as the other services use (collection names match between Federation and live cluster, so query code is identical — only the connection string differs by env). `AnalyzeFsmFitJob` (Layer B, **not** metrics collection) opens a **read-only Postgres connection against `Invoices.Backend`'s `jobs` schema** to apply the FSM-fit audience filter — exclude FSM-using accounts ([`implementation/analyze.md`](implementation/analyze.md) § Audience eligibility) — read-only, batched, no writes ever. Schema `analyses` on `Tofu.AI.Backend`'s own Postgres is the only PG location the service writes to (Hangfire job state).
- **OpenAI is jurisdiction-routed** — see [`investigation/provider.md`](investigation/provider.md) § 2. EU accounts route via an EU OpenAI Project; US via US Project. Same model, same prompts.

## Data flow

### Write path — two independent layers

```
┌────────── Layer A — Metrics (hourly, cheap, shared) — ✅ SHIPPED ┐
│                                                           │
│  Hangfire cron → metrics refresh                          │
│    candidate query:                                       │
│      • expires_at < NOW() (re-refresh existing)           │
│      • discovery sweep on invoices.{CreatedTime}          │
│        partial index → ~200–500k active accounts          │
│      • batched accounts lookup for Store/IsDeleted/       │
│        IsTechnical gates                                  │
│    aggregate from Mongo Data Federation (prod) /          │
│      plain connection to prod Mongo (stage)               │
│    Storage Write API CDC stream (_CHANGE_TYPE='UPSERT')   │
│      → account_metrics                                    │
│        (PK match by account_id, NOT ENFORCED)             │
│                                                           │
└───────────────────────────────────────────────────────────┘

┌────────── Layer B — LLM (per-analysis cadence) — ⬜ NOT BUILT ┐
│                                                           │
│  Hangfire cron → FSM-fit judgement                        │
│    candidate query: expires_at < NOW()                    │
│                   OR input_hash drifted                   │
│                   OR row missing                          │
│    for each candidate:                                    │
│      ├─ recompute input_hash                              │
│      ├─ unchanged → forward existing row, bump            │
│      │              expires_at only (no LLM call)         │
│      └─ drifted   → build payload + Presidio redact       │
│                     + LLM (strict structured outputs)     │
│                     + apply deterministic rule            │
│                       → (score, tier, recommended_offers) │
│    Storage Write API CDC stream (_CHANGE_TYPE='UPSERT')   │
│      → account_fsm_fit (PK match by account_id)           │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

The two layers are independent — a failure in one (e.g. OpenAI outage) doesn't block the other (metrics keep refreshing). Per-analysis paths in Layer B are also independent of each other: a churn-risk bug doesn't block FSM-fit. The **FSM-using-account exclusion lives in Layer B** (the FSM-fit path's audience filter, via the `jobs.Jobs` PG probe), not Layer A — `account_metrics` is analysis-agnostic. See [`implementation/analyze.md`](implementation/analyze.md) § Audience eligibility.

**`input_hash` is the primary re-judgement trigger**, not TTL. `SHA256(canonicalised payload + prompt_version + model_id)`. If the payload doesn't change between cadences, the LLM doesn't re-fire even past 90 days — only `expires_at` is bumped on the existing row. If the payload changes (e.g. user adds invoices), re-judgement fires on the next tick. See [`implementation/storage.md`](implementation/storage.md) § Q2 for the recheck-no-drift path.

End-to-end visibility latency: 3–5 seconds worker → CDC stream (Storage Write API), plus up to `max_staleness` (15 minutes v1, tunable per analysis) for the background apply. Worst case ~15 minutes worker-write to consumer-visible.

### Read path

```
Consumer (Looker Studio / BFF / ad-hoc bq query)
       │
       │  SELECT … FROM v_fsm_fit WHERE account_id = 'X'
       ▼
v_fsm_fit (regular view; MV-eligible)
       │
       │  LEFT JOIN on account_id
       ▼
account_fsm_fit ⋈ account_metrics
       │              │
       │ typed cols   │ typed cols
       ▼              ▼
   score / tier / recommended_offers — read straight from columns
   (stamped at write time by the per-analysis rule)
```

Score / tier / `recommended_offers` are **stamped at write time** into typed columns on `account_fsm_fit` by the FSM-fit rule, then read directly — no rule SQL in the view, no per-read recomputation. Rationale (training/serving skew, feature-store convention): [`implementation/storage.md`](implementation/storage.md) § Structure ("Rule lives in C#, materialised at write time"). Consumer-side ergonomics (Looker Studio, BFF) get plain typed-column filters with no `CASE` or `JSON_VALUE` shredding.

## Data structures at a glance

```
account_metrics (shared, hourly refresh) ✅     ─┐
  ├─ PK: account_id NOT ENFORCED                │   LEFT JOIN on
  │   (single column — subject-key triple        │   per-analysis
  │    dropped before implementation)            │   subject key
  ├─ expires_at + updated_at (no analyzed_at)   │
  └─ 11 typed metric columns + business_name    │
                                                │
account_<analysis> (one per type) ⬜ not built   │
  ├─ PK: single NOT NULL column ◄───────────────┘
  │   (account_id for FSM-fit / churn_risk;
  │    platform_user_id for suspicious_user)
  ├─ typed evidence + output columns
  ├─ typed score / tier / recommended_offers
  │   (materialised by C# IAnalysisRule at write)
  └─ refreshed by AnalyzeJob<T>, per-analysis cron

v_<analysis> (one per type)
  └─ LEFT JOIN of the two above. Projection + join only —
     no rule logic. MV-eligible.
```

All three object kinds:
- Live in dataset `ai_analysis_v2` (default location `US`; EU multi-region is the prod data-residency intent, set per-env via `Analyses:BigQuery:Location`).
- Partitioned `BY DATE_TRUNC(updated_at, MONTH)`; clustered on subject key + analysis-specific high-cardinality filter columns.
- Tables declare `PRIMARY KEY ... NOT ENFORCED` so Storage Write API CDC ingestion can apply UPSERTs natively.
- `OPTIONS(max_staleness = INTERVAL 15 MINUTE)` v1 default — tunable per analysis.

## Implementation approach

### Multi-analysis framework

Every analysis plugs into the framework through a 6-slot contract — see [`analyses/scoring.md`](analyses/scoring.md) § Analysis contract for the concrete shape (interfaces, method signatures, registration). At the architecture level the slots are:

| Slot | What it does | Concrete v1 value (FSM-fit) |
|---|---|---|
| Type tag | Identifier used everywhere (table name, prompt path, config key) | `"fsm_fit"` |
| Payload schema | What the LLM sees — defines the per-analysis data contract | `business_name` + Presidio-redacted top-N invoice items + 8 backend metrics + 2 backend booleans |
| Emit schema | What the LLM returns, wire-enforced via OpenAI strict structured outputs | 6 booleans + 24-ID industry enum + free-text specialization + reasoning |
| Rule | Deterministic scoring run at write time; materialises score / tier / `recommended_offers` into typed columns. No rule SQL in views. | FSM-fit rule per [`analyses/fsm-fit/scoring.md`](analyses/fsm-fit/scoring.md) § Tiers |
| Tier vocabulary | Typed `STRING` column values consumers can filter on | per [`analyses/fsm-fit/scoring.md`](analyses/fsm-fit/scoring.md) § Tiers |
| Score range | Bounded numeric scale (deliberately not `0..1` — weighted sum, not a probability; see [`implementation/storage.md`](implementation/storage.md) § Structure) | `0..100 FLOAT64` |

**Adding an analysis = one folder under `src/Analyses/Analyses.Domain/<NewType>/`** + one prompt file + one rule implementation + one migration (creates `account_<type>` table + `v_<type>` view) + one config block. No framework-code edits, no edits to other analyses' tables. Task 3.7 (framework verification gate) proves this end-to-end by adding a throwaway analysis and reverting it.

### v1 scope: FSM-fit only

FSM-fit is the v1 ship. v2 candidates (`churn_risk`, `suspicious_user`) have placeholder folders + briefs but no implementation — they slot into the same framework when committed. Full FSM-fit spec lives in [`analyses/fsm-fit/`](analyses/fsm-fit/).

### Adding a new analysis (worked example)

Walk-through for adding `churn_risk` to the framework. Each step touches **one** file or folder; no framework-code edits required. For concrete contract shapes (interface names, method signatures, DI registration), see [`analyses/scoring.md`](analyses/scoring.md) § Analysis contract.

1. **Define the payload and emit shapes** — under `src/Analyses/Analyses.Domain/ChurnRisk/`, declare what the LLM sees and what it returns (strict schema).
2. **Register the analysis** — bind the type tag (`"churn_risk"`), payload/emit shapes, TTL, model id, and prompt path. Hangfire wiring is automatic via DI scan.
3. **Write the rule** — deterministic scoring from metrics + evidence to `(score, tier, recommended_offers)`. Runs at write time; no view-side SQL.
4. **Add the migration** — declare `account_churn_risk` (typed columns + CDC primary key + `max_staleness`) and `v_churn_risk` (LEFT JOIN with `account_metrics`). Picked up automatically by the migration CLI on next deploy.
5. **Drop the prompt** — `src/Analyses/.../ChurnRisk/prompts/v1.md`. Loaded by the generic prompt resolver (`prompts/<analysis_type>/v<N>.md`).
6. **Register in config** — add a `Analyses:ChurnRisk` block to `appsettings.json` with cadence + model id.

No edits to `account_fsm_fit`, `v_fsm_fit`, the metrics refresh job, or any framework code. The framework-verification gate (a one-off ClickUp ticket; "stub a noop analysis end-to-end and revert it") proves this works.

## Conventions & glossary

**Naming patterns** (per-analysis objects mirror the same suffix):

| Kind | Pattern | Example (FSM-fit) |
|---|---|---|
| Table | `account_<type>` | `account_fsm_fit` |
| View | `v_<type>` | `v_fsm_fit` |
| Hangfire job | `Analyze<Type>Job` (impl) / `AnalyzeJob<T>` (generic) | `AnalyzeFsmFitJob : AnalyzeJob<FsmFit>` |
| Rule | `IAnalysisRule<T>` impl named `<Type>Rule` | `FsmFitRule` |
| Migration | `<Type>Migration : IModuleMigration` | `FsmFitMigration` |
| Folder | `src/Analyses/Analyses.Domain/<Type>/` | `src/Analyses/Analyses.Domain/FsmFit/` |

**Glossary** (terms used throughout this doc and its children):

- **Subject-key triple** — `(master_user_id, platform_user_id, account_id)`, the *original* multi-subject design. **Dropped before implementation:** the shipped `account_metrics` has a single `account_id` PK (see [`implementation/storage.md`](implementation/storage.md) § Subject identity). The triple survives only as the multi-subject pattern to revisit if a future per-user analysis needs its own metrics table. Per-analysis tables (unbuilt) use a single non-NULL subject column.
- **Layer A / Layer B** — write-path split. Layer A = shared metrics aggregation from Mongo → `account_metrics`. Layer B = per-analysis LLM judgement → `account_<type>`. Independent — failure in one doesn't block the other.
- **`input_hash`** — `SHA256(canonicalised payload + prompt_version + model_id)`. Primary re-judgement trigger: if it hasn't drifted, no LLM call fires even past `expires_at`.
- **Recheck-no-drift** — when an `AnalyzeJob<T>` tick finds a row whose `input_hash` hasn't changed: forward the existing row, bump `expires_at` only, **don't** call the LLM. Cost optimization; see [`implementation/storage.md`](implementation/storage.md) § Q2.
- **Signal collector** — base class for Mongo aggregation. Reads via the Mongo Data Federation endpoint in prod (snapshot-backed) or a plain default connection to prod Mongo in stage. Connection-string config is the single source of truth for which env points where; no per-call override allowed. See [`implementation/service.md`](implementation/service.md) § Q1.
- **MV-eligible** — view shape that BigQuery can materialise on demand (simple LEFT JOIN, no rule logic). Our `v_<type>` views are deliberately MV-eligible so Looker Studio can switch to a materialised view if read latency demands it.
- **`max_staleness`** — BigQuery table option (`INTERVAL 15 MINUTE` v1). Bounded delay between a CDC UPSERT being committed and the row becoming visible to readers. Tunable per analysis.
- **Presidio** — Microsoft Presidio runs as a sidecar; redacts PII (names, emails, phone numbers, addresses) from invoice items before any payload leaves the cluster. Allow-list per analysis: see [`investigation/privacy.md`](investigation/privacy.md).
- **Payload builder** — per-analysis adapter that turns raw Mongo aggregates into the typed payload shape the LLM sees. Where Presidio redaction is invoked. Concrete contract in [`analyses/scoring.md`](analyses/scoring.md) § Analysis contract.

## Code layout

The `src/Analyses/` module folder is load-bearing — it groups framework + per-analysis code so adding a new analysis stays a one-folder change.

```
Tofu.AI.Backend/src/
  ├── Tofu.AI.Api/       HTTP entry, migration CLI, Hangfire server + dashboard (in-process)
  └── Analyses/          Module (Analyses.{Domain,Application,Infrastructure,Persistence})
  # No Tofu.AI.Worker project — the solution is exactly Tofu.AI.Api + the four Analyses.* projects.
```

Full tree in [`implementation/service.md`](implementation/service.md) § *Repo and project layout*.

## Doc map

| Doc | Covers |
|---|---|
| [`README.md`](README.md) | Feature lifecycle, status, implementation tracking, upstream blockers |
| [`implementation/metrics.md`](implementation/metrics.md) + [`analyses/metrics.md`](analyses/metrics.md) | Layer A — metrics collectors, discovery funnel, per-metric query plan (✅ shipped) |
| [`implementation/migrations.md`](implementation/migrations.md) + [`implementation/ci-cd.md`](implementation/ci-cd.md) | Module-migration framework + `migrate` gate + single GitHub Actions deploy path (✅ shipped) |
| [`implementation/storage.md`](implementation/storage.md) | DDL + PK + partitioning + clustering + `max_staleness`; CDC mechanics (`_CHANGE_TYPE`, DML restrictions, recheck-no-drift); common-column convention; subject semantics; `recommended_offers` + `score` vs `tier`; cost; IAM; "Adding a new analysis" |
| [`implementation/service.md`](implementation/service.md) | Single-pod design (API hosts Hangfire in-process), K8s, CI/CD, IAM bootstrap |
| [`prototype/infrastructure/`](prototype/infrastructure/) | Superseded Postgres-store prototype (history); dashboards/Looker doc is stage-2 and unwritten |
| [`analyses/scoring.md`](analyses/scoring.md) § Analysis contract | `IAnalysis<T>` / `IAnalysisRule<T>` framework contract |
| [`analyses/fsm-fit/scoring.md`](analyses/fsm-fit/scoring.md) § Tiers | FSM-fit rule logic, weights, tier vocabulary, offer routing |
| [`analyses/fsm-fit/prompt.md`](analyses/fsm-fit/prompt.md) | FSM-fit prompt + emit schema (v6 production) |
| [`analyses/training.md`](analyses/training.md) + [`analyses/fsm-fit/training.md`](analyses/fsm-fit/training.md) | Training — hand-labelled seed + Optuna (Phase A complete) |
| [`investigation/privacy.md`](investigation/privacy.md) | Presidio redaction + per-analysis PII allow-list |
| [`investigation/provider.md`](investigation/provider.md) § 2 | LLM provider — gpt-4.1-nano + multi-region routing |
| [`analyses/fsm-fit/forward-ab.md`](analyses/fsm-fit/forward-ab.md) + [`analyses/fsm-fit/analytics-events.md`](analyses/fsm-fit/analytics-events.md) | Hard launch gates — Forward A/B + analytics events |
| [`ideas/misha/README.md`](ideas/misha/README.md) | PM open questions / decisions log |

For substantive design questions not covered above: open a PR comment on the relevant deep-dive doc, or surface in the team's normal discussion channel. The two most recent locked decisions are the **per-analysis-table + CDC ingestion redesign** ([`implementation/storage.md`](implementation/storage.md) § Structure, § Q2) and the **collapse to a single-pod deployment** with Hangfire embedded in `Tofu.AI.Api` ([`implementation/service.md`](implementation/service.md) § Decision).
