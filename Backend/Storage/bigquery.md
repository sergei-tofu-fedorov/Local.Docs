BigQuery stores
===============

All BigQuery datasets across the workspace **that our code writes**. Index: [`AGENTS.md`](AGENTS.md). Store-level inventory — full DDL lives in the owning migration code (linked). For the live survey of *everything* in the GCP projects (analytics, GA4 export, pubsub audit, etc.), see [`bigquery-sources.md`](bigquery-sources.md).

---

## `ai_analysis_us`

**Type:** BigQuery dataset · **Location:** `US`
**Env:** prod = `inv-project` (primary) · stage = `invoicesapp-project-test` (same-named dataset)
**Owner / writer:** `Tofu.AI.Backend` (`Tofu.AI.Api`, in-process Hangfire + `migrate` CLI) · **Config key:** `Analyses:BigQuery` (`appsettings.json:28-33`; `ProjectId` — test in config, prod at deploy time; `DatasetId=ai_analysis_us`, `Location=US`, `MaxStaleness="15 MINUTE"`)
**Predecessors:** stage-only `ai_analysis` (v1) and `ai_analysis_v2` are obsolete (last writes 2026-05-24 / 2026-06-03); deletion pending — dataset OWNER is only `projectOwners`/appspot-SA, so an owner must drop them (verified denied for user account, 2026-07-06). Prod never had them.

### Naming convention (WEB-1620/FS-1241) — layer prefixes

| Prefix | Layer | Built by |
|---|---|---|
| `src_*` | typed landing of Mongo Atlas snapshot collections | `build_<coll>` routines over `EXTERNAL TABLE <coll>_ext` (gz on GCS, schema-on-read) |
| `mart_*` | derived marts | `build_*` routines, CDC UPSERT jobs, DTS scheduled queries |
| `dim_*` | dimensions (`dim_account`, `dim_skus`) | routines |
| `sys_*` | system state (`sys_migration_history`, `sys_warehouse_state`) | migration runner / orchestrator |
| `v_*` | analyst/read views | `CREATE OR REPLACE VIEW` |

### Write paths

- **Daily rebuild:** `MetricsRefreshJob` (hourly tick) → `CALL rebuild_warehouse(snapshot_uri, ts)` — but **only when the GCS Atlas snapshot changed** (daily ~16:1x UTC); deploying new SQL does *not* rebuild by itself. Routines deploy every release via the repeatable `bigquery-routines` module of the `migrate` CLI (`CREATE OR REPLACE`, Flyway-`R__` semantics).
- **CDC UPSERT** (Storage Write API, `_CHANGE_TYPE='UPSERT'`): `mart_account_metrics` (`MetricsRefreshJob`), `mart_account_fsm_fit` (`AnalyzeFsmFitJob`); proto descriptors must match DDL 1:1 (`Analyses.Persistence/Protos/`).
- **DTS scheduled queries** (`Warehouse/Sql/ScheduledQueries/`): recurring-offer marts daily (both envs); `refresh_account_subscriptions` / `refresh_sku_mapping` are **prod-only** (read `analytics*` events that exist only in `inv-project`).

### Objects (verified live 2026-07-06)

| Group | Objects | Notes |
|---|---|---|
| `src_*` (8) | `accounts`, `account_identifiers`, `business_profiles`, `clients`, `estimates`, `invoices`, `items`, `master_users` | from daily Atlas snapshot. Since 2026-07-13 (`build_sources`): `src_invoices` carries `mail_status`/`sent_method`/`sent_at` + `sent_method_derived`; `src_estimates` — `status`/`mail_status`/`sent_method` + `sent_method_derived` |
| identity dims (2) | `dim_account_identity`, `dim_platform_user_identity` | join hub account ↔ platform user ↔ master + 25-char Amplitude short ids; `build_identity` routine, ASSERT-guarded invariants; spine = `account_identifiers` (keeps deleted accounts). Also creates `amplitude_us.v_events_resolved`. Query recipes: [`bigquery-agent-guide.md`](bigquery-agent-guide.md) |
| `mart_*` | `account_metrics`, `account_fsm_fit`, `invoice_line_items`, `master_owned_accounts`, `master_platform_links`, `recurring_offer_groups`, `recurring_offer_cohort`, `account_current_plan` | both envs; on stage `account_current_plan` is a **hand-built static stub** (all accounts active till 2099 — no subz events on stage) |
| prod-only | `dim_skus`, `mart_account_subscriptions`, `mart_subscription_periods`, `mart_master_platform_link_periods`, `user_links` | sources are prod-only `analytics*` events; `user_links` = append-only master↔platform id map (WEB-1525/1638) |
| `dim_*` | `dim_account` (+ prod `dim_skus`) | ⚠️ `dim_account.state` is empty for all rows; `trade` only for FSM-fit-scored accounts |
| `sys_*` | `sys_migration_history`, `sys_warehouse_state` | |
| `v_*` | `v_fsm_fit`, `v_contractor_pricing`, `v_contractor_invoice_pricing` | |

### Links

- Warehouse design + rebuild mechanics: `Tofu.AI.Backend/Docs/features/warehouse/README.md`; scheduled queries: `.../Warehouse/Sql/ScheduledQueries/README.md`
- Schema in code: `Tofu.AI.Backend/src/Analyses/Analyses.Infrastructure/Warehouse/Sql/Routines/*.sql` + `Analyses.Persistence/Migrations/Modules/BigQuery/`
- Design history: [`features/WEB-1523-segmentation/`](../../features/WEB-1523-segmentation/)

### Known gotchas

- 🐞 **First run against a fresh/empty dataset crashes `MetricsRefreshJob`**: missing-table surfaces as a query-job error (`reason: notFound`, no HTTP status), which the `GoogleApiException`-`NotFound` filter in `BigQueryWarehouseStateStore.GetLastSnapshotAsync` misses. Bootstrap `sys_warehouse_state` first (found 2026-06-03).
- **Deploy ≠ rebuild**: tables refresh only on snapshot change; to apply routine edits sooner, force a rebuild (see `Tofu.AI.Backend/Docs/features/warehouse/README.md`).
- **Mongo Extended-JSON int enums** land as `{"$numberInt":"N"}`, not bare scalars — decode with `$.X."$numberInt"` + bare-int fallback, else silent NULLs (bit `mart_invoice_line_items.item_type`, `src_invoices.status`; audited/fixed 2026-06-30).
- **Join gotcha:** `src_clients.id` = `<account_id>|<client_guid>` while `src_invoices.client_id` is a bare guid with inconsistent dashes — normalize `REPLACE(LOWER(x),'-','')` + account_id on both sides.

---

## `amplitude_us`

**Type:** BigQuery dataset · **Location:** `US`
**Env:** prod = `inv-project` · stage = `invoicesapp-project-test`
**Owner / writer:** `Tofu.AI.Backend` `amplitude-export` Hangfire tick (FS-1352, daily 04:00 UTC, Export-API → direct load → MERGE on `insert_id`) · **Config:** `Analyses:Amplitude` + `Analyses:BigQuery:AmplitudeDatasetId`
**Objects:** `src_amplitude_events` (day-partitioned `event_time`, **90-day expiration**, cluster `event_type,user_id`; iOS prod 213333 only), `v_events_resolved` (identity-resolved view, created by `build_identity`), `sys_amplitude_export_state` (watermark).
**Gotchas:** rolling 90 days; hours of ingest lag (query full days ≤ yesterday); lossy-by-design; `account_id`/`user_id` are 25-char SHORT ids — join via the identity dims or use `v_events_resolved`. Full guide: [`bigquery-agent-guide.md`](bigquery-agent-guide.md).

---

## `payments_us`

**Type:** BigQuery dataset · **Location:** `US`
**Env:** prod = `inv-project`
**Owner / writer:** `Tofu.AI.Backend` `payment-orders` Hangfire tick (FS-1352, daily 01:00 UTC, Tofu Payments Postgres → watermark MERGE) · **Config:** `Analyses:PaymentOrders`
**Objects:** `src_payment_orders` (day-partitioned `updated_at`, cluster `account_id` — FULL account ids, join `dim_account_identity` directly), `dim_currency` (`ordinal`↔ISO code).
**Gotchas:** int enums (`status`, `payment_provider`, `currency_code`) — decode per `Tofu.Payments` code / `dim_currency`; `entity_id` → invoice/request needs dash-normalization before joining `src_invoices.id`. Guide: [`bigquery-agent-guide.md`](bigquery-agent-guide.md).

---

## `ml_training_us`

**Type:** BigQuery dataset · **Location:** `US`
**Env:** prod = `inv-project` (pipeline instance — empty until the first retraining run) · test = `invoicesapp-project-test` (prototype sandbox; holds the v0 snapshot tables below)
**Owner / writer:** FS-1335 price model (v0: manual materialization 2026-07-03 in test + prototype scripts; pipeline: `Tofu.AI.Backend` dataset routines + Vertex CustomJob, **all in prod** per the 2026-07-06 revision — see [`features/FS-1335/research/research-vertex-automation.md`](../../features/FS-1335/research/research-vertex-automation.md))
**Purpose:** one shared dataset for **all** on-device-ML training tasks — never create per-ticket datasets. Table name = layer prefix (same `src_/dim_/mart_/sys_` scheme as `ai_analysis_us`) + task prefix (`price_` for FS-1335). History: named `fs1335_us` until 2026-07-06.

### Objects — test sandbox (task `price_*`, snapshot of prod data from 2026-07-03)

| Object | Layer | Rows | Notes |
|---|---|---|---|
| `src_price_line_items` | input snapshot | 5.48M | USD, 2018+, name+price>0, client has address; month-partitioned on `date`, clustered `account_id`; derived from prod `mart_invoice_line_items` — retraining must re-materialize |
| `dim_price_names` | dictionary | 6,075 | name→id, `suppress` flags, per-name medians |
| `mart_price_rows_vocab` | training rows (dictionary branch) | 910K | vocab names only |
| `mart_price_rows_text` | training rows (text/OOV branches) | 3.7M | all names with extracted state |

### Links

- Feature docs: [`features/FS-1335/`](../../features/FS-1335/) (`research-data-audit.md` — filters/funnel, `research-vertex-automation.md` — retraining pipeline + naming decision)
- Model artifacts (GCS): `gs://tofu-ml-models/models/price-v1/` (see [`gcs.md`](gcs.md))
- Consumer: local prototype `C:\Git\_scratch\fs1335-price-model` (`download.py` maps BQ tables → historical parquet stems)
