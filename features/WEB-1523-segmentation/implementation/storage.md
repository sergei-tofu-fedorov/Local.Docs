# WEB-1523 — Storage (BigQuery)

> **Implementation status (2026-05-27).** Only the shared **`account_metrics`** table has shipped (WEB-1527, via `V001_CreateAccountMetrics` in `Tofu.AI.Backend`). The per-analysis result tables (`account_fsm_fit`, …), the per-analysis views (`v_fsm_fit`, …), and the `AnalyzeJob<TAnalysis>` LLM write path described below are the **unbuilt analyze stage** — design only.
>
> **Shipped reality differs from the original `account_metrics` design here in three ways** (the DDL + subject-identity prose below have been corrected to match code; this banner records the *why*):
> - **Account-only subject.** A single `account_id STRING NOT NULL` PK — the `master_user_id` / `platform_user_id` columns and the three-level subject model were dropped (they carried the NULL-PK CDC-matching risk noted in § Q2). Multi-subject metrics, if ever needed, go in a separate table.
> - **No `analyzed_at` column.** Recompute == write, so `updated_at` is the single freshness stamp; the partition key is `updated_at`.
> - **Dataset `ai_analysis_v2`**, default location **`US`** (test). EU multi-region (per `../investigation/privacy.md` § 3) is the prod data-residency intent — set per-env via `Analyses:BigQuery:Location`, not hard-coded.
>
> Refresh cadence is **hourly** (`0 * * * *`), not daily.

## Why BigQuery

Given the workspace already runs Cloud SQL Postgres (`Tofu.Auth.Backend`) and MongoDB (`Invoices.Backend`) on GCP, the three realistic options for a new analytical store:

| Option | Verdict | Why |
|---|---|---|
| **BigQuery** (this design) | ✅ | Free tier covers the year-1 workload (~$0/mo at 3.5 GB/year); Looker Studio native connector for PM dashboards; per-table partitioning + clustering + materialized-view path map idiomatically to the per-analysis layout; EU multi-region one-line config; analyses live in their own dataset with no cross-service domain coupling. |
| **New Cloud SQL Postgres instance** | ❌ at this scale | Cloud SQL has a fixed instance floor (~$10–50/mo even at our row count) — **more expensive than BigQuery's free tier**; Looker Studio works but loses native column-pruning ergonomics. Reusing the `Tofu.Auth` PG instance would couple two services to one DB — rejected on architecture grounds. |
| **Reuse `Invoices.Backend`'s MongoDB** | ❌ | No native Looker Studio connector — load-bearing for PM access (the dashboards/query-templates surface is stage-2 and unbuilt); AI write load competes with the BFF on the same physical cluster; violates the workspace's "each service owns its own DB" pattern. |

Also considered and rejected on workspace fit:

- **ClickHouse Cloud** — $99–$451/mo entry tier. Solves a sub-second-latency problem we explicitly don't have; ~10,000× our current BQ bill at year-1 scale.
- **Snowflake** — ~$465/mo realistic floor for a small-team config. Multi-cloud capability is irrelevant on a GCP-only deployment.
- **DuckDB / MotherDuck / Iceberg "lakehouse-lite"** — 2025–2026 buzz for 50 GB–2 TB workloads, but no native Looker Studio connector and team has no DuckDB ops experience. Reconsider if the AI workload pivots toward heavy ad-hoc Python analytics over result data.

**When this decision would flip:**
- PII residency tightens beyond multi-region (would need single-region SQL).
- GCP contracts/credits make Cloud SQL effectively free → reusing or adding Postgres becomes cost-neutral.
- BFF read volume on a per-analysis view exceeds ~1M/day *without* caching, clustering, and materialized view (see § Q1 § Cost — Read-path cost at scale).

None apply today.

## Structure

**One shared metrics table + one table per analysis + per-analysis views, all in `<project>.ai_analysis_v2`** (default location `US`; EU multi-region per [`../investigation/privacy.md`](../investigation/privacy.md) § 3 is the prod data-residency intent, set per-env). Of these, only `account_metrics` exists in code today.

| Layer | Object | One row per | Refresh | Notes |
|---|---|---|---|---|
| **Backend metrics** | `account_metrics` (table) | **account** | `MetricsRefreshJob`, hourly | ✅ shipped. Shared across all analyses. Typed columns. Read from Mongo (`invoices`/`estimates`/`clients`/`accounts`). |
| **Per-analysis result** | `account_fsm_fit` (table, v1); `account_churn_risk`, `account_suspicious_user` (tables, v2) | subject | `AnalyzeJob<TAnalysis>`, per-analysis cron | ⬜ **not built** (analyze stage). LLM emit + `input_hash` + **materialised** `score` / `tier` / `recommended_offers`. Typed columns for evidence/output. |
| **Per-analysis view** | `v_fsm_fit` (and one per analysis when v2 lands) | subject | computed on read | ⬜ **not built**. Thin join of `account_<analysis>` with `account_metrics`. Primary surface for dashboards and BFF drilldown. MV-compatible. |

**Per-analysis tables.** Each analysis owns its own physical table with typed columns for evidence + output + materialised score, partitioned and clustered for that analysis's access pattern. Pattern matches feature-store convention ([Vertex AI](https://cloud.google.com/vertex-ai/docs/featurestore/latest/create-featuregroup), [Feast](https://docs.feast.dev/reference/offline-stores/bigquery), [Tecton](https://docs.tecton.ai/docs/defining-features/feature-tables)) — one logical feature group → one physical table.

**Rule lives in C#, materialised at write time.** `score` / `tier` / `recommended_offers` are computed by `IAnalysisRule.Apply()` in the producer's `AnalyzeJob<TAnalysis>` and stamped into typed columns on `account_<analysis>` alongside the LLM emit. The view contains **no rule logic** — it's projection + join. Single source of truth: the C# rule class. Rationale: [Feast on-demand views](https://docs.feast.dev/reference/beta-on-demand-feature-view), [Uber Michelangelo](https://www.uber.com/us/en/blog/michelangelo-machine-learning-model-representation/), [Ploomber on training-serving skew](https://ploomber.io/blog/train-serve-skew/).

**Subject identity — account-only for `account_metrics` (shipped).** As built, `account_metrics` is keyed on a single **`account_id STRING NOT NULL`** column. The originally-designed three-level subject model (`master_user_id` / `platform_user_id` / `account_id` as three nullable columns, exactly one set per row) was dropped before implementation — it carried the NULL-valued-composite-PK CDC-matching risk flagged in § Q2, and no v1 analysis needs user-level metrics. Master/platform-user metrics, if ever required, go in a separate table.

Per-analysis tables (unbuilt) still declare **only the subject-key column their analysis operates at**, NOT NULL:

- `account_fsm_fit` is keyed on `account_id` only — FSM-fit asks whether *the business* would benefit from the FSM upsell; user-level scoring isn't meaningful here.
- `account_churn_risk` (v2) keyed on `account_id` only — same reasoning, asks whether *the business* is at retention risk.
- `account_suspicious_user` (v2) keyed on `platform_user_id` only — suspicious-user signal is per-user, not per-account.

Joins between a per-analysis table and `account_metrics` are now a plain `ON account_id` equi-join — every `account_metrics` row is account-keyed, so there are no user-keyed rows to skip.

**Common column convention across `account_<analysis>` tables.** Every per-analysis table commits to the same name + type for: `score FLOAT64`, `tier STRING`, `recommended_offers ARRAY<STRUCT<offer STRING, weight FLOAT64>>`, `schema_version INT64`, `rule_version STRING`, `input_hash STRING`, `model_id STRING`, `prompt_version INT64`, `reasoning STRING`, `analyzed_at TIMESTAMP`, `expires_at TIMESTAMP`, `triggered_by STRING`, `properties JSON`, `updated_at TIMESTAMP`. Subject-key columns vary per analysis (above). Analysis-specific evidence/output columns vary freely. Reason: consistent shape across analyses keeps the producer's `AnalyzeJob<TAnalysis>` template generic over `T` — the CDC upsert pattern is identical for every analysis, only the column list varies.

**`recommended_offers` semantics.** Probability distribution: weights are non-negative FLOAT64s summing to 1.0 when the array is non-empty; ordered by weight DESC. Empty array means "no applicable offer" (replaces a 'none' sentinel). Consumer (BFF) picks one offer per render via weighted-random sampling, or deterministically via a hash on `(account_id, day_bucket)` for stable per-day rotation. The rule is the sole writer of this column; do not synthesise distributions in dashboard SQL.

**`score` vs `tier` — why both.** Standard pattern across scored-analytics products ([Stripe Radar `risk_score` 0–99 + `risk_level`](https://docs.stripe.com/radar/risk-evaluation); Salesforce score+grade; Mailchimp engagement-score+star-rating). `score` is the continuous 0–100 value for sorting, percentile dashboards, and rule-tuning thresholds; `tier` is the bucketed label for dashboard filters (`WHERE tier = 'strong'`), in-app proposal targeting, and frozen historical semantics — if the strong/medium boundary shifts next quarter, historical rows preserve what they were classified as at scoring time, with `rule_version` recording the boundary regime. Both are stamped by `IAnalysisRule.Apply()` in the same CDC upsert row, so drift is impossible by construction. Score range is **0–100 FLOAT64**, deliberately not 0–1 — the score is a weighted sum of LLM booleans + backend metrics, not a calibrated probability; 0–1 would imply probability semantics we don't have.

**Schema deliberately omits LLM-call observability** (no `tokens_*` / `cost_usd` / `latency_ms` / `raw_output` / `trace_id` / `cache_hit` columns on any result table). Those are call traces, not result data — separate retention policy, separate right-to-erasure surface. Observability path deferred to v2. If someone proposes adding cost/token columns to a per-analysis table, push back.

**`expires_at` stays — as a per-table policy field.** Each table needs its own stored expiry so candidate-row scans (`WHERE expires_at < NOW()`) inside that analysis's refresh job are local to its own table.

**Read paths.** Per-analysis dashboards and the BFF admin drilldown query the analysis-specific view (`v_fsm_fit`). Typed columns throughout. The consumer side (Looker Studio setup, starter dashboards, query templates under `queries/`) is **stage-2 and unbuilt** — there is no `dashboards.md` yet.

**Cost:** <$0.01/month at year-1 scale (free tier). Stays well under $20/month even at 1M BFF reads/day after clustering + cache.

Rationale: see § Q1 (schemas + per-analysis views + partitioning + cost), § Q2 (write paths + per-table CDC upserts). The PM access surface (Looker Studio + dashboards + query templates) is stage-2 and not yet written.

## Findings

### Q1 — GCP / BigQuery setup

#### Schemas

**Backend metrics (shared) — ✅ shipped.** Typed columns for the shared metric set; refreshed hourly by `MetricsRefreshJob`. This is the verbatim shape created by `V001_CreateAccountMetrics` (`Tofu.AI.Backend/src/Analyses/Analyses.Persistence/Migrations/Modules/BigQuery/`):

```sql
CREATE TABLE IF NOT EXISTS `<project>.ai_analysis_v2.account_metrics` (
  account_id    STRING NOT NULL,               -- sole subject key (account-only; see § Subject identity)
  business_name STRING,                        -- denormalised from accounts.BusinessName at write time

  -- 8 numeric metrics (all nullable: null = "no signal", never coerced to 0):
  invoice_count_30d            INT64,
  avg_invoice_amount           FLOAT64,
  invoice_amount_variance_cv   FLOAT64,
  avg_line_items_per_invoice   FLOAT64,
  repeat_customer_ratio        FLOAT64,
  avg_days_between_repeats     FLOAT64,
  estimate_to_invoice_rate     FLOAT64,
  estimate_count               INT64,

  -- 2 derived booleans + count:
  b2b_clients_present  BOOL,                    -- regex over clients.Info[].Name (LLC|Inc|Corp|Property Management|LLP|Ltd)
  multi_address_work   BOOL,                    -- ≥ 2 distinct client addresses (derived in C# from distinct_addresses)
  distinct_addresses   INT64,

  expires_at   TIMESTAMP NOT NULL,             -- analyzedAt + MetricsOptions.RefreshTtl (default 24h)
  updated_at   TIMESTAMP NOT NULL,             -- stamped by the repository on every CDC UPSERT batch

  PRIMARY KEY (account_id) NOT ENFORCED        -- single-column CDC upsert key (no NULL-PK ambiguity)
)
PARTITION BY DATE_TRUNC(updated_at, MONTH)
CLUSTER BY account_id
OPTIONS (
  description    = "Backend-aggregated metrics per account. Refreshed by MetricsRefreshJob via Storage Write API CDC ingestion.",
  max_staleness  = INTERVAL 15 MINUTE          -- from Analyses:BigQuery:MaxStaleness; background-merge cadence
);
```

> **No `analyzed_at` column** — dropped vs the original design. Each tick recomputes from scratch and writes, so recompute == write; `updated_at` (write time) is the single freshness stamp and the partition key. `expires_at` carries the 24h TTL. Timestamps are written as INT64 micros-since-epoch over the Storage Write API.

**Per-analysis result — FSM-fit (v1 instance, template for v2+). ⬜ Not built — analyze-stage design.** No `account_fsm_fit` table, no `AnalyzeJob`, no LLM write path exists in code yet. Typed columns for evidence + output + materialised score columns + common columns.

```sql
CREATE TABLE `<project>.ai_analysis_v2.account_fsm_fit` (
  -- Subject key — FSM-fit operates at the account level:
  account_id  STRING NOT NULL,

  -- 6 FSM-fit evidence booleans from the LLM emit
  -- (see ../analyses/fsm-fit/scoring.md § Evidence shape for canonical names):
  mentions_onsite_work        BOOL,
  mentions_scheduling         BOOL,
  mentions_dispatch           BOOL,
  mentions_recurring_visits   BOOL,
  mentions_field_service      BOOL,
  mentions_multi_worker_jobs  BOOL,

  -- LLM-emit output beyond evidence:
  industry        STRING,                       -- 24-value enum, see analyses/fsm-fit/scoring.md § Industry classification
  specialization  STRING,

  -- Materialised at write time by IAnalysisRule.Apply() in the producer:
  score               FLOAT64 NOT NULL,                                          -- 0..100 weighted-sum output (NOT a calibrated probability — keep range 0..100 to avoid 0..1 probability-semantic implication; see scoring.md § Score range). Per-subject; do not SUM, use AVG / percentile.
  tier                STRING  NOT NULL,                                          -- 'strong' | 'medium' | 'weak' | 'unfit' — bucketed label, frozen at scoring time; see scoring.md § Tiers
  recommended_offers  ARRAY<STRUCT<offer STRING, weight FLOAT64>> NOT NULL,      -- weighted offer distribution; weights sum to 1.0 (when non-empty), ordered by weight DESC. Empty = no applicable offer. See scoring.md § Offer routing.

  -- Common columns (identical name+type across all account_<analysis> tables):
  reasoning       STRING,
  schema_version  INT64  NOT NULL,
  rule_version    STRING NOT NULL,               -- bumped when IAnalysisRule.Apply() output shape or weights change
  input_hash      STRING NOT NULL,               -- SHA256(canonicalised payload || prompt_version || model_id) — re-judge trigger
  model_id        STRING NOT NULL,
  prompt_version  INT64  NOT NULL,

  analyzed_at   TIMESTAMP NOT NULL,
  expires_at    TIMESTAMP NOT NULL,              -- analyzed_at + IAnalysis<FsmFit>.RefreshTtl
  triggered_by  STRING,                          -- 'scheduled' | 'event:<name>' | 'manual'
  properties    JSON,                            -- caller-supplied tags
  updated_at    TIMESTAMP NOT NULL,              -- stamped by producer on every CDC UPSERT

  PRIMARY KEY (account_id) NOT ENFORCED          -- CDC upsert key; single-column for per-analysis tables
)
PARTITION BY DATE_TRUNC(updated_at, MONTH)
CLUSTER BY account_id, tier
OPTIONS (
  description    = "FSM-fit analysis per subject. Refreshed by AnalyzeJob<FsmFit> via Storage Write API CDC ingestion. Common columns match account_<analysis> convention; evidence + output are analysis-specific.",
  max_staleness  = INTERVAL 15 MINUTE
);
```

v2 tables (`account_churn_risk`, `account_suspicious_user`) follow the same template — same subject keys, same common columns (identical types), analysis-specific evidence + output columns, materialised `score` / `tier` / `recommended_offers`, clustering tuned per analysis.

#### Per-analysis views — the primary read surface ⬜ not built

Each analysis exposes a thin view that joins its result table with `account_metrics` (design only — no `v_fsm_fit` exists yet):

```sql
CREATE OR REPLACE VIEW `<project>.ai_analysis_v2.v_fsm_fit` AS
SELECT
  m.account_id,
  m.business_name,
  -- metrics (typed)
  m.invoice_count_30d, m.avg_invoice_amount, m.invoice_amount_variance_cv,
  m.avg_line_items_per_invoice, m.repeat_customer_ratio, m.avg_days_between_repeats,
  m.estimate_to_invoice_rate, m.estimate_count,
  m.b2b_clients_present, m.multi_address_work, m.distinct_addresses,
  -- FSM-fit evidence + output (typed; NULL for cold-start accounts not yet scored)
  f.mentions_onsite_work, f.mentions_scheduling, f.mentions_dispatch,
  f.mentions_recurring_visits, f.mentions_field_service, f.mentions_multi_worker_jobs,
  f.industry, f.specialization,
  -- materialised score columns (typed)
  f.score, f.tier, f.recommended_offers,
  -- bookkeeping
  f.reasoning, f.rule_version, f.model_id, f.prompt_version,
  f.analyzed_at, f.expires_at, f.triggered_by, f.properties,
  GREATEST(m.updated_at, IFNULL(f.updated_at, m.updated_at)) AS updated_at
FROM `<project>.ai_analysis_v2.account_metrics` AS m
LEFT JOIN `<project>.ai_analysis_v2.account_fsm_fit` AS f
  ON m.account_id = f.account_id
WHERE m.account_id IS NOT NULL;   -- user-keyed metrics rows are not FSM-fit-relevant
```

**Properties of this shape:**
- All columns typed — no `JSON_VALUE` shredding for dashboard filters.
- `LEFT JOIN m → f` exposes cold-start accounts (metrics-only, no FSM-fit verdict yet) with NULL evidence/score columns; the `WHERE m.account_id IS NOT NULL` filters out user-keyed and master-user-keyed metrics rows that FSM-fit doesn't apply to.
- [MV-eligible](https://cloud.google.com/bigquery/docs/materialized-views-intro): no UDFs, no UNNEST, no analytic functions, no UNION/wildcard. Can be promoted to a materialized view with smart-tuning auto-routing of consumer queries when read volume justifies — that's the extensibility hook this design exists for.

#### Partitioning, clustering, schema flexibility

**`PARTITION BY DATE_TRUNC(updated_at, MONTH)` on every result table.** Same four reasons as before:

*(a) Why partition at all when cost is already $0.* `partition_expiration_days` is a future option only if partitioning exists at `CREATE TABLE`. Per-partition time-travel cost. Drift / "what changed last quarter" queries become free. No operational tax — one line of DDL.

*(b) Why `updated_at`.* Top-level `TIMESTAMP` (not nested), tracks freshness, BigQuery requires a top-level column for the partition key. The producer stamps `updated_at = CURRENT_TIMESTAMP()` on every CDC UPSERT payload.

*(c) Why MONTH.* At steady state ~50k subjects, each per-analysis table churns ~50k rows/month (~25–40 MB). DAY would be too small for partition pruning to earn its keep; YEAR loses drift-query granularity. Google's guidance recommends ≥1 GB per partition for pruning to matter, but we partition for future retention / time-travel, not present pruning.

*(d) `DATE_TRUNC(_, MONTH)`* is BigQuery's monthly-partition form ([partitioning docs](https://cloud.google.com/bigquery/docs/partitioned-tables)).

**Clustering per table — different keys per analysis.** With per-analysis tables, each spends its [4-column clustering budget](https://cloud.google.com/bigquery/docs/clustered-tables) on what matters for its access pattern:

- `account_metrics` — `CLUSTER BY account_id` (point lookups + join key).
- `account_fsm_fit` — `CLUSTER BY account_id, tier` (account drilldown + tier-bucket filters like `WHERE tier = 'strong'`).
- `account_churn_risk` (v2) — likely `CLUSTER BY account_id, risk_bucket`.
- `account_suspicious_user` (v2) — likely `CLUSTER BY account_id, severity`.

Caveat: on clustered tables, BigQuery's [`--dry_run` cost estimate is not accurate](https://cloud.google.com/bigquery/docs/clustered-tables) (block pruning is decided at execution). Cost-control still works (scan-size still bounded by table size); just don't trust dry-run numbers for budgeting.

**Schema flexibility — alternatives considered.**

| Alternative | Why not |
|---|---|
| Single table combining metrics + LLM emit | Forces fast and slow features under one TTL — exactly the failure mode the layer split avoids. |
| Drop per-analysis views; consumers join in code | Looker Studio + BQ Web UI consumers need a SQL surface — per-analysis views are the cheapest way. |
| All-JSON per-analysis tables (drop typed columns) | Loses partition-pruning + ~2.3× typed-column filter speed advantage; dashboard filters become `JSON_VALUE(...)` everywhere. |
| Iceberg V3 with `VARIANT` | Spectacular overkill at 3.5 GB/year. Reconsider only with external consumers or 100×+ growth. |

**Where JSON still earns its keep.** The `properties JSON` column on each per-analysis table holds caller-supplied tags (`triggered_by` context, free-form ops metadata). Per Google's [JSON-in-Capacitor blog](https://cloud.google.com/blog/products/databases/how-bigquery-powers-semi-structured-data-storage), native JSON is shredded into per-path virtual columns inside Capacitor — fast when filtered, cheap when ignored. Reserved for genuinely free-form auxiliary fields; promote to a typed column the moment any consumer needs `WHERE` / `CLUSTER BY` / dashboard-filter ergonomics on it.

**Schema deployment — `IModuleMigration` pattern (✅ framework shipped).** The store-agnostic module-migration framework lives in `Tofu.AI.Backend/src/Analyses/Analyses.Persistence/Migrations/` (`IModuleMigration` + `ModuleMigrationsRunner`); the BigQuery module (`Migrations/Modules/BigQuery/`) ensures the dataset + `migration_history` table, then applies each `IBigQueryMigration` once in `Name` order, recording success via `MERGE`. **As built, the one migration is `V001_CreateAccountMetrics`** (the shared metrics table); the `account_fsm_fit` table + `v_fsm_fit` view are later `V###` steps in the unbuilt analyze stage. New analyses (v2 `churn_risk`, `suspicious_user`) each add one migration that creates the per-analysis table + per-analysis view. No staging tables — CDC ingestion writes directly to the live table. CLI shape (`dotnet Tofu.AI.Api.dll migrate [--dryrun]`), state tracking (`migration_history` in BigQuery), pre-deploy K8s Job — see [`migrations.md`](migrations.md) + [`service.md`](service.md). Failed migration rethrows and aborts the deploy cleanly — live pods never see a half-applied schema.

#### Cost

Per-analysis tables at year-1 scale stay well inside the free tier.

| Line item | Free tier | Beyond free tier | Year-1 usage | Monthly cost |
|---|---|---|---|---|
| **Active storage** (< 90 days unchanged) | 10 GB/mo | $0.02/GB-mo | ~0.3 GB rolling (metrics + fsm_fit combined) | **$0** |
| **Long-term storage** (≥ 90 days unchanged) | included in 10 GB | $0.01/GB-mo | ~3 GB by year 2 | **$0** |
| **On-demand query** (data scanned) | 1 TiB/mo | $6.25/TiB | ~30 GB scanned/mo (per-analysis view, typed columns project cleanly) | **$0** |
| **Storage Write API** (data written) | — | $0.025/GB | ~0.4 GB/mo (metrics + fsm_fit combined) | **<$0.01** |
| BI Engine (in-memory cache) | none | $0.04/GB-hour reserved | not used | $0 |
| Slot reservations (flat-rate) | — | from $2,000/mo | not used (on-demand suffices) | $0 |
| **Egress** out of GCP | 1 GB/mo | $0.12+/GB | Looker Studio stays in-cloud | $0 |
| Looker Studio | free, no caps | n/a | unlimited dashboards | $0 |
| **Total at year-1 scale** | | | | **<$0.01/month** |

**Year-1 and growth scenarios** (sources: [BQ pricing](https://cloud.google.com/bigquery/pricing); typed columns Capacitor compression per the [JSON-in-Capacitor blog](https://cloud.google.com/blog/products/databases/how-bigquery-powers-semi-structured-data-storage)):

| Item | Cost |
|---|---:|
| Storage at year 5 (~35 GB compressed) | ~$6/yr |
| Dashboards — 50/day, analysis-specific | ~$0.04/yr |
| BFF reads — 10k/day, analysis-specific, cached | ~$8/yr |
| BFF reads — 1M/day, analysis-specific | ~$700/yr |
| CDC background-merge (Storage Write API ingestion, on-demand) | ~$0.50/yr |

Everything sits in the single-digit-to-low-double-digit dollars-per-year range until BFF read volume crosses ~1M/day, at which point clustering + cache + MV bring it back down.

**Read-path cost at scale (per-analysis view).** If stage-2 BFF reads `v_fsm_fit` on every page render:

| BFF reads/day | Unoptimised (typed cols only) | + cluster on `account_id, tier` | + BFF-side cache |
|---|---:|---:|---:|
| 10k (≈ 1/active-user/day) | ~$8/yr | <$1/yr | <$1/yr |
| 100k (5–10 renders/user) | ~$80/yr | ~$5/yr | <$5/yr |
| 1M (worst case) | ~$700/yr | ~$50/yr | ~$10/yr |

Per-query scan with typed columns and clustering: ~1 MB.

**Three independent levers** (any one is enough at v1 scale; combining is belt-and-braces):

1. **Cluster keys tuned per analysis** — already in the DDL (`account_id, tier` on FSM-fit). No row migration needed if we add columns later.
2. **BFF-side cache** — verdicts move slowly (LLM TTL 90d; metrics 24h), so a session-scoped `(account_id, analysis) → verdict` cache eliminates most BQ reads.
3. **Promote `v_<analysis>` to materialized view** — BigQuery refreshes on base-table change and serves from cache. Per-analysis views are MV-eligible by construction (no UDFs, no UNNEST, no UNION). [Smart tuning](https://cloud.google.com/bigquery/docs/materialized-views-use) auto-routes consumer queries hitting the regular view to the MV.

BigQuery's free 24h exact-match cache helps repeat reads per `account_id` (same user opens dashboard twice → second hit free), but doesn't help across users or beyond 24h.

### Q2 — Hangfire write paths

One shared metrics path + one path per analysis — N+1 refresh jobs, each writing directly to its live table via the Storage Write API's [CDC ingestion mode](https://docs.cloud.google.com/bigquery/docs/change-data-capture). No staging tables. No scheduled batch reconciliation. Producer stamps `_CHANGE_TYPE = 'UPSERT'` on each appended row; BigQuery's CDC engine applies the upsert against the table's `PRIMARY KEY ... NOT ENFORCED` declaration in the background. Reads inside the table's `max_staleness` window (15 min for v1) serve already-applied results.

#### Layer A — metrics path (cheap, frequent, shared) — ✅ shipped

```
MetricsRefreshJob (Hangfire recurring, hourly)
  └─ expired scan: account_metrics.account_id WHERE expires_at < CURRENT_TIMESTAMP() LIMIT ExpiredScanBatchSize
  └─ discovery (every tick): invoices CreatedTime sweep → ExceptExisting (net-new) → accounts eligibility gate
  └─ aggregate from Mongo (one IMongoDatabase from ConnectionStrings:Mongo; Data Federation in prod) — see service.md § Q1
  └─ Storage Write API default stream, _CHANGE_TYPE = 'UPSERT' → account_metrics
       BigQuery applies upserts keyed on PRIMARY KEY (account_id);
       new rows insert, existing rows replace in place.
```

As built: `BigQueryAccountMetricsRepository.UpsertManyAsync` stamps one `updated_at` per batch and makes one `AppendRows` call per batch (~300 rows); `GetExpiredAsync` + `ExceptExistingAsync` run via the Query API. See [`metrics.md`](metrics.md) for the collectors and the discovery funnel.

#### Layer B — LLM path (expensive, per-analysis cadence, one pipeline per analysis)

```
AnalyzeJob<TAnalysis> (Hangfire recurring, per-analysis cron) — one instance per registered analysis
  └─ candidate query: subjects (joined to account_metrics for current metrics)
                      WHERE account_<analysis>.expires_at < NOW()
                         OR account_<analysis>.input_hash != computed_hash
                         OR row missing for this subject
  └─ for each candidate:
       ├─ recompute input_hash
       ├─ if hash unchanged → forward existing evidence/output/score unchanged,
       │                       bump expires_at = NOW() + RefreshTtl
       └─ if hash drifted   → build payload via IPayloadBuilder<T>, Presidio-redact,
                              LLM call (provider.md § 1),
                              IAnalysisRule<T>.Apply(metrics, evidence)
                                → (score, tier, recommended_offers)
  └─ Storage Write API default stream, _CHANGE_TYPE = 'UPSERT' → account_<analysis>
       BigQuery applies upserts keyed on PRIMARY KEY (account_id for FSM-fit / churn_risk,
       platform_user_id for suspicious_user); new rows insert, existing rows replace in place.
```

**`IAnalysisRule<T>.Apply()` runs once per LLM emit**, in C#, with metrics + evidence in hand. Output goes into the same Storage Write API payload as the LLM emit booleans — score/tier/offer are typed columns, not derived at read time.

**`input_hash = SHA256(canonicalised payload || prompt_version || model_id)`.** Re-judgment fires when this drifts even before `expires_at` lapses — matches the dominant LLM-caching pattern in the feature-store literature ([Feast](https://docs.feast.dev/reference/offline-stores/bigquery) / [Anthropic](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) / [OpenAI](https://platform.openai.com/docs/guides/prompt-caching) caching guides). TTL is the safety net; hash-drift is the primary invalidation trigger.

**Rule changes that don't bump prompt or model** (re-weighting an existing rule, adding a new tier band) are applied by a one-shot backfill job — not direct SQL. The job scans `account_<analysis>` for rows with stale `rule_version`, recomputes `(score, tier, recommended_offers)` in C# via the new `IAnalysisRule<T>.Apply()` over the stored evidence + metrics, and re-sends each row through the **same CDC stream** with the new `rule_version`. Same write path; just driven by a migration script instead of the recurring AnalyzeJob. No DML.

#### Why CDC ingestion via Storage Write API

| Approach | Mechanism | Latency to queryable | Notes |
|---|---|---|---|
| **CDC ingestion** (this design) | Storage Write API default stream + `_CHANGE_TYPE = 'UPSERT'`, applied by BigQuery against table's `PRIMARY KEY` | within `max_staleness` window (15 min v1) | Current Google recommendation for streamed-upsert workloads. One write path, no intermediate staging. |
| Legacy streaming insert (`tabledata.insertAll`) | REST, at-least-once | 1–3 seconds | Deprecated for new pipelines. |
| Batch load (GCS → BQ) | Write JSONL to GCS, periodic load job | Minutes | Cheapest but adds a GCS bucket + scheduler. |

From the [BigQuery CDC ingestion docs](https://docs.cloud.google.com/bigquery/docs/change-data-capture):

> "When you stream an UPSERT, BigQuery updates existing records or inserts new ones based on matching primary keys."

**`max_staleness` knob.** Per-table option set in `CREATE TABLE OPTIONS(...)`. Trades read freshness for background-merge cost: at `INTERVAL 0` BigQuery merges at query time (always fresh, costlier reads); at `INTERVAL 15 MINUTE` (v1 default) merges run cheaply in the background and queries within 15 minutes of a write may see the older row. Tunable per analysis — v2 `suspicious_user` (1h TTL) may want `INTERVAL 1 MINUTE` for tighter SLA, v2 `churn_risk` can stay at 15 min.

**Live-table DML is restricted while CDC is active.** Plain `UPDATE` / `DELETE` / `MERGE` against `account_<analysis>` is blocked by BigQuery — all writes flow through the Storage Write API stream. Implications:

- **Recheck-no-drift path** (bump `expires_at` only): producer re-sends the existing row through UPSERT with `expires_at` + `updated_at` advanced, all other columns unchanged. ~1 KB payload, negligible.
- **Rule-version backfills:** handled by the C# job pattern above. No direct SQL UPDATE.
- **Ad-hoc ops correction** (delete a corrupted row, fix a typo): one-off script through Storage Write API — `_CHANGE_TYPE = 'UPSERT'` for fixes, `_CHANGE_TYPE = 'DELETE'` for removals.

CDC writes don't count against DML quotas. Each table's CDC stream is independent — a metrics-side incident doesn't block any analysis's writes, and vice versa.

#### Idempotency, failure recovery, isolation

**Idempotency.** Re-sending the same UPSERT (same PK, same column values) produces the same final row state. BigQuery's CDC engine deduplicates by PK at the apply step.

**Failure mid-batch.** If a producer crashes mid-batch, rows that successfully appended to the CDC stream are still applied; rows that didn't are simply absent. The candidate-scan query on the next AnalyzeJob<T> run re-picks any missing rows (their `expires_at` is still stale or their `input_hash` still drifted). No buffered work to recover.

**Provider outage / network failure** doesn't accumulate work in any staging buffer — there is none. Affected rows stay stale until the next successful run picks them up.

**Failure isolation across analyses.** A bug in `AnalyzeJob<ChurnRisk>` doesn't block `AnalyzeJob<FsmFit>` or `MetricsRefreshJob`. Each path writes to its own table's CDC stream with its own background merger; dashboards for the working analyses stay accurate while the broken one is fixed.

**Composite-PK behavior on `account_metrics` — resolved by design.** The original triple `(master_user_id, platform_user_id, account_id)` PK (two columns NULL on every row) raised an unresolved question about BigQuery CDC matching on NULL-valued PK columns. Rather than verify-then-fallback, the shipped table uses a **single `account_id` PK** — the upsert key is one non-null column, so matching is unambiguous and the NULL-PK concern is gone. (The `(subject_kind, subject_id)` normalisation suggested here is the path to take *if* multi-subject metrics ever land in a shared table.)

### Adding a new analysis (storage perspective)

Adding a new analysis is a deliberate act — new table, new view, new clustering decision. At ~1.5 analyses/year that's appropriate; at >10 analyses/year, consider automating via dbt or Dataform.

1. Pick the analysis type identifier (table name `account_<type>`, e.g. `account_churn_risk`).
2. Decide the typed schema: evidence columns (LLM-emit booleans/enums), output columns (LLM-emit fields beyond evidence), per [`../analyses/scoring.md`](../analyses/scoring.md) § Analysis contract. Pick clustering keys and the subject-level PK.
3. Implement `IAnalysis<TChurnRisk>` + `IAnalysisRule<TChurnRisk>` in C# — the rule computes `score` / `tier` / `recommended_offers` at write time.
4. Add `IModuleMigration` that creates:
   - `account_<type>` table with `PRIMARY KEY (...) NOT ENFORCED` and `OPTIONS(max_staleness = INTERVAL <N> MINUTE)` — no staging table; CDC ingestion writes direct to live.
   - `v_<type>` view (LEFT JOIN against `account_metrics` on the analysis's subject key)
5. Add `queries/<type>/*.sql` dashboards.
6. Register an `AnalyzeJob<TChurnRisk>` Hangfire entry.
7. Bind IAM if the analysis needs scoped access (e.g. `suspicious_user` → ops-only `dataViewer`).

The producer's framework (`AnalyzeJob<T>`) is generic over `T` — adding an analysis is a registration of a new generic-parameter class, not new orchestration code. The CDC write pattern is identical across analyses; only the column list varies.

If a future analysis needs new backend metrics beyond the 11 columns in `account_metrics`, that's an `ALTER TABLE ADD COLUMN` migration on the shared table. Promote a metric to a typed column only when (a) most analyses would benefit, or (b) the metric needs typed-column dashboard ergonomics.

## Sources

- [BigQuery — Pricing](https://cloud.google.com/bigquery/pricing) — on-demand $6.25/TiB queried, $0.02/GB-month active storage. Year-1 stays in free tier.
- [BigQuery — Stream table updates with change data capture ingestion](https://docs.cloud.google.com/bigquery/docs/change-data-capture) — `_CHANGE_TYPE` pseudocolumn, `PRIMARY KEY ... NOT ENFORCED` declaration, `max_staleness` knob, live-table DML restrictions while CDC is active. The pattern used on every result table.
- [BigQuery — Storage Write API](https://cloud.google.com/bigquery/docs/write-api) and [best practices](https://docs.cloud.google.com/bigquery/docs/write-api-best-practices) — default-stream guidance for CDC ingestion.
- [BigQuery — Quotas and limits](https://cloud.google.com/bigquery/quotas) — DML quotas (don't apply to CDC writes); concurrency model.
- [BigQuery — Introduction to clustered tables](https://cloud.google.com/bigquery/docs/clustered-tables) — per-analysis clustering budget (4 columns), dry-run cost-estimate caveat.
- [BigQuery — Introduction to materialized views](https://cloud.google.com/bigquery/docs/materialized-views-intro) and [unsupported features](https://cloud.google.com/bigquery/docs/materialized-views-intro#unsupported_sql_features) — MV restrictions: no UDFs, no UNION, no wildcard. Per-analysis views are MV-eligible.
- [BigQuery — Use materialized views (smart tuning)](https://cloud.google.com/bigquery/docs/materialized-views-use) — auto-routing of regular-view consumer queries to MV.
- [BigQuery — Introduction to partitioned tables](https://cloud.google.com/bigquery/docs/partitioned-tables) — `DATE_TRUNC` partitioning pattern.
- [BigQuery — IAM access control](https://cloud.google.com/bigquery/docs/access-control) — table-level vs dataset-level bindings for per-analysis IAM.
- [BigQuery — Visualize with Looker Studio](https://cloud.google.com/bigquery/docs/visualize-looker-studio) — native connector for PM dashboards.
- [How BigQuery powers semi-structured data storage (JSON in Capacitor)](https://cloud.google.com/blog/products/databases/how-bigquery-powers-semi-structured-data-storage) — JSON shredding into per-path virtual columns; relevant for the `properties JSON` column.
- [Vertex AI Feature Store — Create feature group](https://cloud.google.com/vertex-ai/docs/featurestore/latest/create-featuregroup), [Feast — BigQuery offline store](https://docs.feast.dev/reference/offline-stores/bigquery), [Tecton — Feature tables](https://docs.tecton.ai/docs/defining-features/feature-tables) — feature-store convention of one-table-per-feature-group; the production-tested basis for per-analysis tables.
- [Feast — On-demand feature views](https://docs.feast.dev/reference/beta-on-demand-feature-view), [Uber — Evolving Michelangelo](https://www.uber.com/us/en/blog/michelangelo-machine-learning-model-representation/), [Ploomber — Training-serving skew](https://ploomber.io/blog/train-serve-skew/) — why the rule lives in C# only.
- [Stripe Radar — Risk evaluations](https://docs.stripe.com/radar/risk-evaluation), [Salesforce — Lead scoring and grading](https://www.salesforce.com/products/guide/lead-gen/scoring-and-grading/), [Mailchimp — Contact ratings](https://mailchimp.com/help/about-contact-ratings/) — score-plus-tier convention; why we keep both the continuous `score` (0–100) and the bucketed `tier` enum.
- [Anthropic — Prompt caching](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching), [OpenAI — Prompt caching](https://platform.openai.com/docs/guides/prompt-caching) — input-hash + model-version-keyed cache invalidation, the model for the `input_hash` column.
