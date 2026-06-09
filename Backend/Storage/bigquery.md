BigQuery stores
===============

All BigQuery datasets across the workspace **that our code writes**. Index: [`AGENTS.md`](AGENTS.md). Store-level inventory — full DDL lives in the owning migration code (linked). For the live survey of *everything* in the GCP projects (analytics, GA4 export, pubsub audit, etc.), see [`bigquery-sources.md`](bigquery-sources.md).

---

## `ai_analysis_v2`

**Type:** BigQuery dataset · **Location:** `US`
**Env:** test = `invoicesapp-project-test` · **prod = not configured in code** (deploy-time ADC/env; WEB-1523 blocker)
**Owner / writer:** `Tofu.AI.Backend` (`Tofu.AI.Api`, in-process Hangfire) · **Config key:** `Analyses:BigQuery` (`appsettings.json:39-43`; `ProjectId`, `DatasetId=ai_analysis_v2`, `Location=US`, `MaxStaleness="15 MINUTE"`)
**Write path:** Storage Write API **CDC UPSERT** (`_CHANGE_TYPE='UPSERT'`, expiry = re-refresh never delete) for data rows; DDL via `migrate` CLI (`IBigQueryMigration` `V00x`, tracked in `migration_history`).

### Objects
| Object | Purpose | Key | Partition / Cluster | Write path | Notes |
|---|---|---|---|---|---|
| `account_metrics` | Shared per-account feature store | `account_id STRING NOT NULL` (PK NOT ENFORCED) | `PARTITION BY DATE_TRUNC(updated_at, MONTH)` · `CLUSTER BY account_id` | CDC UPSERT (`MetricsRefreshJob`, hourly) | 11 metric cols + `business_name` + `expires_at`/`updated_at`; metrics NULLABLE → unset = **NULL = no signal**; no version cols (unversioned by design); `max_staleness` option set |
| `account_fsm_fit` | FSM-fit per-analysis result | `account_id` (PK NOT ENFORCED) | `PARTITION BY DATE_TRUNC(updated_at, MONTH)` · `CLUSTER BY account_id, tier` | CDC UPSERT (`AnalyzeFsmFitJob`) | 6 LLM bools + `industry`/`specialization` + `score`/`tier`/`industry_bonus` + `recommended_offers ARRAY<STRUCT<offer,weight>>` + 5 version dims (`schema_version`/`rule_version`/`prompt_version`/`model_id`/`input_hash`) + `analyzed_at`/`triggered_by`/`properties JSON` |
| `v_fsm_fit` | Analyst/read view: metrics ⟕ fsm-fit | — (view) | — | `CREATE OR REPLACE VIEW` | `account_metrics m LEFT JOIN account_fsm_fit f ON account_id`; cold-start accounts surface with NULL score; surfaces version cols (stage-2 API hides them) |
| `migration_history` | BigQuery migration runner state | `name` | — | `MERGE` by runner | one row per applied `V00x`; no PK |

### Proto lockstep (CDC descriptors)
Field names/types/tags must match table DDL 1:1 — CDC ingestion uses the proto descriptor:
- `account_metrics` ⇄ `AccountMetricsProto` — `Protos/account_metrics.proto` (proto2, all `optional`; timestamps INT64 micros)
- `account_fsm_fit` ⇄ `AccountFsmFitProto` (+ top-level `OfferStruct`) — `Protos/account_fsm_fit.proto`

### Links
- Schema in code: `Tofu.AI.Backend/src/Analyses/Analyses.Persistence/Migrations/Modules/BigQuery/{V001_CreateAccountMetrics,V002_CreateAccountFsmFit,V003_CreateVFsmFitView}.cs`; protos under `Analyses.Persistence/Protos/`; options `BigQuery/BigQueryOptions.cs`
- Design: [`features/WEB-1523-segmentation/implementation/storage.md`](../../features/WEB-1523-segmentation/implementation/storage.md), [`.../analyses/versioning.md`](../../features/WEB-1523-segmentation/analyses/versioning.md), [`.../implementation/migrations.md`](../../features/WEB-1523-segmentation/implementation/migrations.md)
- Evolution/topology theory: [`.../analyses/flexible-metrics.md`](../../features/WEB-1523-segmentation/analyses/flexible-metrics.md), [`.../analyses/metrics-gold-migration.md`](../../features/WEB-1523-segmentation/analyses/metrics-gold-migration.md)

### Known gotchas
- 🐞 **`MetricsRefreshJob` crashes on the first run against a fresh/empty dataset.** `BigQueryWarehouseStateStore.GetLastSnapshotAsync` (`Tofu.AI.Backend` `Analyses.Persistence/Warehouse`) detects "table never built" by catching `GoogleApiException` only `when (ex.HttpStatusCode == HttpStatusCode.NotFound)`. But BigQuery surfaces a missing table from `ExecuteQueryAsync` as a **query-job error** (`reason: notFound`, no HTTP status), so the `when` filter misses it and the job throws on the very first tick (when `warehouse_state` doesn't exist yet). Prod is masked because the table already exists from a prior run. Fix: also catch the job-error `notFound` form, or bootstrap an empty `warehouse_state (snapshot_ts STRING, refreshed_at TIMESTAMP)` before the job runs. Found 2026-06-03 standing up a fresh `ai_analysis_us` in `invoicesapp-project-test`.
