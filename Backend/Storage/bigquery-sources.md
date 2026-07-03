BigQuery sources — live GCP survey & usage opportunities
=========================================================

What actually exists in BigQuery across our GCP projects and how we could use it. Complements [`bigquery.md`](bigquery.md) (code-derived inventory of the dataset **we** write) — this doc surveys **everything live** in the projects, including datasets owned by analytics/marketing pipelines we don't write from backend code.

Surveyed **2026-06-05** via free metadata calls only (`bq ls` / `bq show` — no bytes scanned). Sizes/freshness drift; re-run the survey commands (bottom) before relying on them.

GCP projects
------------

| Project | Role | BQ datasets |
|---|---|---|
| `inv-project` | **prod** | 14 datasets (below) |
| `invoicesapp-project-test` | test | `ai_analysis` (EU), `ai_analysis_us` (US), `ai_analysis_v2` (EU) — all Tofu.AI |
| `playfair-project` | marketing DWH (separate org-side project) | `data_layer` + dbt marts — see [Playfair section](#adjacent-playfair-dwh) |

---

Prod (`inv-project`) datasets
-----------------------------

All `US` location. Sizes/rows as of 2026-06-05.

| Dataset | What it is | Key objects | Size | Fresh? | Writer |
|---|---|---|---|---|---|
| `analytics` | **Server-side billing/account events** (Subz, iOS products) | `events` (18.7M rows, 7.2 GB) · `all_events` **VIEW** · `events_tofu-fieldservice[-worker]` (per-product tables) · many manual backups | 7+ GB | ✅ daily | **Subz `EventStream.Handler.BigQuery`** (streaming insert, per-product `BigQuery:Products` config — `C:\Git\Work\Subz`); event names `subscription_paid`, `account_created`, … |
| `analytics_316355057` | **GA4 / Firebase export** for iOS app (`com.getpaidapp.invoices`) | `events_YYYYMMDD` daily shards since 2022-05-24 + `events_intraday_*` | large (sharded) | ✅ daily | Firebase native export |
| `analytics_android` | Android server-side billing/account events | `events` (1.8M rows, 0.5 GB), `events_tofu-fieldservice-worker` | 0.5 GB | ✅ daily | Subz `EventStream.Handler.BigQuery` (since 2023-11) |
| `analytics_web` | Web payment/subscription events | `events_invoices_stripe`, `events_invoices_paddle`, `events_tofu_stripe`, `events_template` | small | ? | Web billing pipeline |
| `analytics_backup` | Automated 2×-daily snapshots of `analytics.events` | `events_YYYYMMDDHH` SNAPSHOTs | — | ✅ | scheduled snapshot |
| `attribution` | **AppsFlyer raw attribution export** | `appsflyer_attribution` (4.1M rows, 2.9 GB) + dedupe view `analytics.appsflyer_attribution_uniq` | 2.9 GB | ⚠️ **stale since 2023-07-24** | AppsFlyer (apparently stopped) |
| `event_stream` | **Pub/Sub→BQ audit of the product event bus** | `incoming_events_audit`, `enriched_events_audit` (3.7M rows each, ~2 GB each) — raw Pub/Sub envelope (`data`, `attributes`, `publish_time`) | ~4 GB | ✅ daily | Pub/Sub BQ subscription (since 2024-12) |
| `pubsub_audit` | **Store server-to-server billing notifications** | `apple_server_to_server_notifications` (3.25M rows, **61 GB**, since 2025-03) · `android_server_to_server_notifications` (269K rows, since 2025-08) | 61+ GB | ✅ daily | Pub/Sub BQ subscription |
| `ai_analysis_us` | **Tofu.AI prod DWH** (FSM-fit) | Renamed to `src_/mart_/dim_/sys_` scheme (verified live 2026-07-03): **sources** `src_accounts`, `src_clients`, `src_invoices`, `src_estimates`, `src_items` (saved catalog / price lists), `src_business_profiles`, `src_account_identifiers`, `src_master_users` · **marts** `mart_invoice_line_items` (24.7M line items: `item_name`, `unit_price`, `quantity`; month-partitioned on `date`), `mart_account_metrics`, `mart_account_fsm_fit`, `mart_account_current_plan`, `mart_account_subscriptions`, `mart_subscription_periods`, `mart_master_*`, `mart_recurring_offer_*` · **dims** `dim_account` (trade/state; ⚠️ `state` empty, `trade` only ~11k accounts), `dim_skus` · `user_links`, `sys_warehouse_state`, `sys_migration_history` · views `v_fsm_fit`, `v_contractor_pricing`, `v_contractor_invoice_pricing`. ⚠️ `src_clients.id` = `<account_id>\|<client_guid>` composite while `src_invoices.client_id` is a bare guid with inconsistent dashes — normalize both sides to join | — | ✅ | `Tofu.AI.Backend` (see [`bigquery.md`](bigquery.md)) |
| `dev_agiletich` / `dev_akibuk` / `dev_bolshakov` / `dev_kgulyaev` / `dev_piskarev` | Per-analyst sandboxes | ad-hoc | — | — | analysts |

### Schemas worth knowing

**`analytics.events`** (same shape in `analytics_android.events`):
`event_time, event_name, event_params (ARRAY<STRUCT>), account_id, environment, server_time, revenue, idfa, appsflyer_id, firebase_id`

**`analytics.all_events` view — the canonical event entry point.** Unions:
- Firebase GA4 export (`analytics_316355057.events_*`, app-origin events only, iOS app, `_TABLE_SUFFIX` pruned, intraday included; `user_id` → `account_id`; `revenue = 0.7 × event_value_in_usd`; env derived from `user_properties.environment='appstore'`), plus `app_version`/`os_version`/`country`
- backend `analytics.events`
then dedupes on `(event_time, event_name, account_id, source)`. Adds `source ∈ {firebase, backend}`.

**`event_stream.*` / `pubsub_audit.*`** — raw Pub/Sub envelope: `subscription_name, message_id, publish_time, data (payload), attributes`. Payload needs `JSON_*` extraction from `data`.

**`attribution.appsflyer_attribution`** — full AppsFlyer raw-data export shape (touch type/time, media source, campaign/adset/ad, revenue, contributors…). Use the dedupe view `analytics.appsflyer_attribution_uniq`.

### Join keys

- `account_id` is the common key: `analytics*.events`, `ai_analysis_us.*` all carry it. GA4 export carries it as `user_id`.
- Device/attribution bridge: `idfa` / `appsflyer_id` / `firebase_id` columns on `analytics.events`, mirrored from Mongo `accountIdentifiers` (also loaded daily into Playfair `data_layer.mongo_invoices_account_identifiers`).

---

Test (`invoicesapp-project-test`)
---------------------------------

Only Tofu.AI datasets: `ai_analysis` (EU, legacy), `ai_analysis_v2` (EU), `ai_analysis_us` (US, current — stood up 2026-06-03). ⚠️ Live locations of `ai_analysis`/`ai_analysis_v2` are **EU**, while config/[`bigquery.md`](bigquery.md) say `Location=US` — the `_us` dataset exists precisely to converge on US. Also note [`bigquery.md`](bigquery.md) records "prod = not configured in code", yet prod `ai_analysis_us` exists and is populated — prod project id is supplied at deploy time.

---

Adjacent: Playfair DWH
----------------------

`playfair-project` (marketing/LTV warehouse, Dagster + dbt; repo `C:\Git\Work\Playfair.DWH.BigQuery`). Ingests Tofu Payments Postgres (`data_layer.tofu_postgres_payment_orders`, daily) and Mongo `accountIdentifiers` (`data_layer.mongo_invoices_account_identifiers`, daily); drives LTV cohorts, attributed revenue, AB-test marts, finance Sheets exports. Mongo invoice/estimate/account loaders exist but are **disabled**. Full investigation: `Invoices.Backend/Docs/features/WEB-1523-segmentation/investigation/dwh.md`.

---

How we can use this (mapped to known gaps)
------------------------------------------

The WEB-1523 data inventory ([`features/WEB-1523-segmentation/analyses/data-sources.md`](../../features/WEB-1523-segmentation/analyses/data-sources.md)) flagged gaps that this survey partially **closes**:

1. **"No in-app event stream" — partially false.** `analytics.all_events` gives a deduped per-`account_id` behavioral stream (Firebase app events + backend events) back to 2022. Engagement-health, activation scoring, and feature-usage signals can be derived here without new instrumentation. Caveat: event taxonomy is product-analytics-driven; verify event names before modeling.
2. **Involuntary-churn signal exists.** `data-sources.md` marked dunning risk ⚠️ "needs App Store Server Notifications v2 + Google RTDN ingestion" — `pubsub_audit` **already captures both** (Apple since 2025-03, Android since 2025-08). Decline/renewal payloads are in the raw `data` column.
3. **FSM-fit enrichment joins.** `ai_analysis_us` (metrics + fsm-fit + warehouse mirror of accounts/clients/invoices/estimates) and `analytics.all_events` share `account_id` — behavioral features (event frequency, feature adoption) can join into segmentation/training queries with zero new plumbing.
4. **Attribution / LTV cross-reference.** `attribution.appsflyer_attribution` (⚠️ stale 2023) and Playfair's identity bridge let analyses tie `account_id` to acquisition channel — but confirm whether the AppsFlyer export was deliberately stopped (Playfair ingests AF separately).
5. **Event-bus debugging.** `event_stream.{incoming,enriched}_events_audit` is a queryable audit of the Pub/Sub **billing-lifecycle event bus** (`Subz.EventStream.Contracts.Events.*` — subscription paid/expired/retried, account created/updated) — useful for investigations ("did event X for account Y reach the bus?") without log spelunking. Full pipeline map incl. the Amplitude/GA4/AppsFlyer fan-out: [`../Flows/ANALYTICS_EVENTS_FLOWS.md`](../Flows/ANALYTICS_EVENTS_FLOWS.md).

Querying gotchas (cost)
-----------------------

Per the workspace rule: **always `--dry_run` first; metadata (`bq ls/show`) is free; bytes scanned bill.**

- ⚠️ `analytics.events`, `event_stream.*`, `pubsub_audit.*` are **not partitioned** — every query full-scans the table. `pubsub_audit.apple_server_to_server_notifications` is **61 GB**: a careless `SELECT *` costs real money. Select only needed columns (BQ bills per-column).
- GA4 `analytics_316355057.events_*` is day-sharded — **always** constrain `_TABLE_SUFFIX` (the `all_events` view does this for you, but the view still scans both full underlying event tables for the date range you keep — filter early).
- Only `ai_analysis_us` tables are partitioned/clustered (`invoices`/`estimates` by month on `date`, metrics by month on `updated_at`, clustered on `account_id`) — prefer them for per-account scans of invoice/estimate data over Mongo exports or raw events.
- Benchmark-style repeated queries: test project only (workspace rule).

Survey commands (re-run to refresh)
-----------------------------------

```bash
bq ls --project_id=inv-project --format=prettyjson                  # datasets (free)
bq ls --project_id=inv-project --max_results=50 inv-project:<ds>    # tables (free)
bq show --format=prettyjson inv-project:<ds>.<table>                # rows/bytes/schema/partitioning (free)
bq query --dry_run --use_legacy_sql=false 'SELECT ...'              # cost preview before any scan
```
