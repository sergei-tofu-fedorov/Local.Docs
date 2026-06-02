# WEB-1555 → BigQuery flow (no Mongo) — spike findings & migration plan

**Status:** spike complete (invoice metrics proven end-to-end on real data). Migration not yet implemented.
**Date:** 2026-06-02
**Goal:** Move the WEB-1555 account-metrics / FSM-fit pipeline off **live MongoDB queries** onto a **BigQuery-sourced flow**, where source collections are loaded from Atlas snapshot exports into BQ and the metric collectors become SQL. Keep only the OpenAI FSM-fit step in C#.

---

## TL;DR / verdict

- **Yes, it works.** Every metrics collector is a pure SQL aggregation. The 30-day invoice-volume collector was rewritten as one `GROUP BY account_id` query and run against real data (106,130 accounts, correct values).
- **Joins are a strength.** With all collections clustered by `account_id`, the app-side fan-out (4 collectors stitched in C#) collapses into a single multi-CTE SQL query joined on `account_id`.
- **The only real labor** is escaping MongoDB canonical Extended JSON into typed columns (one-time projection per collection), plus partitioning `invoices` by `Date`.
- **The only thing that can't be SQL** is the OpenAI LLM reasoning call (`AnalyzeFsmFitJob`). Keep it in C# (reads metrics from BQ), or push to a BQ remote function.
- **Main behavior change:** BQ source = **snapshot freshness** (stale up to the export cadence), not live Mongo. Today only the **2026-05-27** snapshot exists; the daily Atlas export is **not currently running** (it stopped ~Sep 2025).

---

## Current BQ state (what exists RIGHT NOW)

**Project:** `inv-project` (PROD). **Dataset:** `ai_analysis_us` @ **US** (created during this spike; the existing `ai_analysis_v2` is **EU**, which can't load from the US-EAST1 snapshot bucket — that's why a new US dataset was needed).

| Table | Schema | Rows | Size | Layout |
|---|---|---|---|---|
| `accounts_raw` | `_id STRING, doc STRING` (raw canonical Extended-JSON line) | 5,134,160 | 3.36 GB | clustered by `_id` |
| `accounts` | `account_id STRING, business_name STRING, is_deleted BOOL, is_technical BOOL, store STRING, created_time TIMESTAMP` | 5,134,160 | 0.53 GB | clustered by `account_id` |
| `invoices` | `id STRING, account_id STRING, date TIMESTAMP, total_amount FLOAT64, line_item_count INT64, notes STRING, client_id STRING` | 10,071,718 | 2.85 GB | **PARTITION BY month(date), CLUSTER BY account_id**; deleted rows filtered out on ingest |

**Not yet built:** `estimates`, `clients` (typed). `invoices` does **not** carry item names (only `line_item_count`) — see "remaining work".

Account population: total 5,134,160 → **eligible 3,544,279** (not deleted, not technical), technical 1,568,119, deleted 23,122.

---

## Data pipeline: snapshot gz → BQ

**Source snapshot (the only one that exists):**
```
gs://atlas-snap-export-production/exported_snapshots/5a58ddfbdf9db10eed1cc64d/
  5a58ddfbdf9db10eed1cc650/InvoicesCluster/2026-05-27T1011/1779885870/invoicesDB/<collection>/*.json.gz
```
Collections present: accounts, clients, estimates, invoices (+ many others). gz sizes: accounts 517 MB, clients 583 MB, estimates 425 MB, invoices 3.75 GB.

**Two ways to ingest+shape (both used here):**

1. **Load raw, then transform** (used for `accounts`):
   - `LOAD DATA` the gz as a single STRING column → staging (CSV, empty/control-char delimiter, `quote=''`, so each NDJSON line = one field). Load is **free**.
   - `CREATE TABLE … CLUSTER BY … AS SELECT <projection> FROM staging` to type/filter.

2. **External table + CTAS, one step, no raw table** (used for `invoices` — this is the "filter/project while exporting from gz to BQ" pattern):
   ```sql
   CREATE OR REPLACE EXTERNAL TABLE ai_analysis_us.invoices_ext (raw STRING)
   OPTIONS (format='CSV', field_delimiter='\t', quote='',  -- tab never appears raw in NDJSON (JSON escapes it)
            uris=['gs://.../invoicesDB/invoices/*.json.gz']);

   CREATE OR REPLACE TABLE ai_analysis_us.invoices
   PARTITION BY TIMESTAMP_TRUNC(date, MONTH)
   CLUSTER BY account_id AS
   SELECT
     JSON_VALUE(raw,'$._id')        AS id,
     JSON_VALUE(raw,'$.AccountId')  AS account_id,
     TIMESTAMP_MILLIS(SAFE_CAST(JSON_VALUE(raw,'$.Date."$date"."$numberLong"') AS INT64)) AS date,
     SAFE_CAST(JSON_VALUE(raw,'$.TotalAmount."$numberDecimal"') AS FLOAT64) AS total_amount,
     COALESCE(ARRAY_LENGTH(JSON_QUERY_ARRAY(raw,'$.Items')),0) AS line_item_count,
     JSON_VALUE(raw,'$.Notes') AS notes,
     COALESCE(JSON_VALUE(raw,'$.ClientId'), JSON_VALUE(raw,'$.Client.CatalogId')) AS client_id
   FROM ai_analysis_us.invoices_ext
   WHERE LOWER(COALESCE(JSON_VALUE(raw,'$.IsDeleted'),'false')) <> 'true'
     AND SAFE_CAST(JSON_VALUE(raw,'$.Date."$date"."$numberLong"') AS INT64) BETWEEN 1262304000000 AND 1893456000000;
   ```
   The CTAS scanned 21.8 GB decompressed gz once (free under tier). External table is just a pointer; drop it after.

> The **load job itself cannot filter/transform** — it's a dumb ingest. Filtering/projection happens in the `SELECT` of the CTAS (Option 1 or 2 above).

### Production daily-refresh primitive (when daily export is re-enabled)
Snapshots are **full dumps**, so the right pattern is a daily **atomic full-replace** (handles deletes for free), one statement:
```sql
LOAD DATA OVERWRITE ai_analysis_us.<table>
CLUSTER BY account_id
FROM FILES (format='JSON', compression='GZIP', uris=['gs://.../<latest-snapshot>/.../<collection>/*.json.gz']);
```
Caveats: (a) the snapshot folder path is timestamped → the job must resolve the **latest** prefix first; (b) export must finish before load (GCS→Pub/Sub trigger, or time-lag + a row-count guard); (c) for canonical Extended JSON you still need the typed projection, so in practice it's external-table + CTAS per collection, or re-export in **Relaxed** Extended JSON.

---

## Source field mapping & Extended-JSON gotchas (IMPORTANT)

The snapshot is **canonical MongoDB Extended JSON**. Key rules discovered:

- **`$`-keys must be escaped with double quotes in BQ JSONPath:** `'$.Date."$date"."$numberLong"'`. NOT `.$date`, NOT `['$date']` (both error).
- **Booleans & strings come through native** (`JSON_VALUE(doc,'$.IsDeleted')` → `"true"`/`"false"`).
- **Numbers & dates are wrapped, and the wrapper varies per value/field:**
  - `invoices.TotalAmount` → `{"$numberDecimal":"…"}`  (Decimal128 — **not** `$numberDouble`!)
  - `Date`, `CreatedTime` → `{"$date":{"$numberLong":"<epoch-ms>"}}` → `TIMESTAMP_MILLIS(CAST(… AS INT64))`
  - generic numbers elsewhere may be `$numberInt` / `$numberLong` / `$numberDouble` → `COALESCE` across them
- **Legacy docs omit fields:** invoices may have no `IsDeleted`/`CreatedTime` → `null` correctly = "not deleted" (matches Mongo `$in:[false,null]`).
- **`_id` is a plain string** in all four collections (accounts `_id` IS the AccountId).
- Clustering by `account_id` requires it be a **real promoted column** (can't cluster on `JSON_VALUE`). Promoting it is exactly what the filters/joins need.

**Relaxed Extended JSON re-export would remove ~90% of this pain** (numbers/bools become native; only Date/ObjectId stay wrapped). Worth requesting on the Atlas export config.

---

## The metrics: Mongo collectors → BQ SQL

Latest branch `feature/WEB-1555`. Design: **fan-out by AccountId, zero `$lookup`, app-side join.** 9 read-only queries.

Code locations:
- `src/Analyses/Analyses.Infrastructure/Metrics/AccountDiscovery.cs` — `SweepActiveAccountsAsync` (active accounts), `FilterEligibleAsync` (eligibility gate)
- `src/Analyses/Analyses.Infrastructure/Metrics/Collectors/InvoiceMetricsCollector.cs` — 30d volume + 12mo repeat
- `…/Collectors/EstimateMetricsCollector.cs` — 12mo conversion
- `…/Collectors/ClientMetricsCollector.cs` — B2B + distinct addresses
- `…/Collectors/AccountMetricsCollector.cs` — business name
- `…/Collectors/InvoiceSignalsCollector.cs` — top item names + top notes
- `src/Analyses/Analyses.Infrastructure/Mongo/AccountsRepository.cs` — `GetAccountIdsCreatedSinceAsync` (maturity filter)
- `…/Metrics/MetricsCollector.cs` (façade), `…/Mongo/MongoDatabaseFactory.cs`, `…/Mongo/BsonReads.cs`, `…/DependencyInjection.cs`

Metric → SQL mapping:

| Metric (output field) | Source | BQ SQL |
|---|---|---|
| `invoice_count_30d`, `avg_invoice_amount`, `invoice_amount_variance_cv`, `avg_line_items_per_invoice` | invoices, 30d window | `GROUP BY account_id` + `COUNT/AVG/STDDEV_POP`; CV = `IF(AVG>0, STDDEV_POP/AVG, NULL)` ✅ proven |
| `repeat_customer_ratio`, `avg_days_between_repeats` | invoices, 12mo, by client | 2-level: group `(account_id, client_id)` → group `account_id`; gap = `TIMESTAMP_DIFF(max,min,MILLISECOND)/((n-1)*86400000.0)` |
| `estimate_count`, `estimate_to_invoice_rate` | estimates, 12mo | `GROUP BY account_id`, `SAFE_DIVIDE(COUNTIF(invoice_id IS NOT NULL), COUNT(*))` |
| `b2b_clients_present`, `distinct_addresses`, `multi_address_work` | clients (DeletedAt null) | `UNNEST(Info)` → `LOGICAL_OR(REGEXP_CONTAINS(name, r'(?i)LLC\|Inc\|Corp\|Property Management\|LLP\|Ltd'))`, `COUNT(DISTINCT LOWER(TRIM(addr)))`; multi = `distinct_addresses >= 2` |
| `business_name` | accounts | join `accounts` |
| eligibility gate | accounts | `WHERE NOT is_deleted AND NOT is_technical` |
| `top_item_names`, `top_notes` (signals) | invoices | `ARRAY_AGG(STRUCT(name,c) ORDER BY c DESC, name ASC LIMIT N)`; item names need `UNNEST(items)` — **requires item_names column (not built yet)** |

Fidelity notes: repeat-ratio denominator = distinct clients (`COUNT(*)` over the per-client CTE); top-N tie-break `ORDER BY count DESC, name ASC` matches the Mongo `{count:-1,_id.n:1}` that stabilizes `input_hash`.

---

## Working metrics SQL (invoice-only, against CURRENT tables) — dry-run validated ✅

This produces the `InvoiceMetricsCollector` outputs (the numeric metrics) + `business_name`, for eligible accounts. (Notes/items excluded — selected separately.) Validated via dry-run on 2026-06-02. *(If you saw "Name avg_invoice_amount is ambiguous" — that was a paste/edit artifact; this canonical form validates clean.)*

```sql
DECLARE end_ts    TIMESTAMP DEFAULT TIMESTAMP '2026-05-27';   -- job uses "now"; anchor to snapshot
DECLARE start_30d TIMESTAMP DEFAULT TIMESTAMP_SUB(end_ts, INTERVAL 30  DAY);
DECLARE start_12m TIMESTAMP DEFAULT TIMESTAMP_SUB(end_ts, INTERVAL 365 DAY);

WITH
vol AS (
  SELECT account_id,
    COUNT(*)                                                AS invoice_count_30d,
    AVG(total_amount)                                       AS avg_invoice_amount,
    IF(AVG(total_amount) > 0,
       STDDEV_POP(total_amount) / AVG(total_amount), NULL) AS invoice_amount_variance_cv,
    AVG(line_item_count)                                    AS avg_line_items_per_invoice
  FROM `inv-project.ai_analysis_us.invoices`
  WHERE date >= start_30d AND date < end_ts
  GROUP BY account_id
),
per_client AS (
  SELECT account_id, client_id, COUNT(*) AS n, MIN(date) AS min_d, MAX(date) AS max_d
  FROM `inv-project.ai_analysis_us.invoices`
  WHERE date >= start_12m AND date < end_ts AND client_id IS NOT NULL
  GROUP BY account_id, client_id
),
repeat AS (
  SELECT account_id,
    SAFE_DIVIDE(COUNTIF(n >= 2), COUNT(*))                  AS repeat_customer_ratio,
    AVG(IF(n >= 2, TIMESTAMP_DIFF(max_d, min_d, MILLISECOND) / ((n - 1) * 86400000.0), NULL))
                                                            AS avg_days_between_repeats
  FROM per_client GROUP BY account_id
)
SELECT a.account_id, a.business_name,
  COALESCE(v.invoice_count_30d, 0) AS invoice_count_30d,
  v.avg_invoice_amount, v.invoice_amount_variance_cv, v.avg_line_items_per_invoice,
  r.repeat_customer_ratio, r.avg_days_between_repeats
FROM `inv-project.ai_analysis_us.accounts` a
LEFT JOIN vol    v ON v.account_id = a.account_id
LEFT JOIN repeat r ON r.account_id = a.account_id
WHERE NOT a.is_deleted AND NOT a.is_technical;
```
Switches: `INNER JOIN vol` to keep only accounts active in the 30d window; wrap in `CREATE OR REPLACE TABLE … AS` (inline the timestamps — DDL+scripting must be one job) to materialize.

Measured: the 30d window query billed **78.5 MB** (2.8% of the table) thanks to month partition pruning; returned 106,130 accounts.

---

## What stays in C# (does NOT move to SQL)

- **OpenAI FSM-fit reasoning** (`AnalyzeFsmFitJob`, gpt-4.1-nano structured output). Options: (a) BQ computes metrics, C# reads them and calls OpenAI — simplest; (b) BQ remote function → Cloud Function → OpenAI; (c) `ML.GENERATE_TEXT` w/ Vertex (different model — not OpenAI).
- The deterministic `FsmFitScorer` **could** move to SQL (weighted arithmetic → a view over the metrics table), optional.

---

## Remaining work to actually migrate the branch

1. **Re-enable the daily snapshot export** (currently stopped; only 2026-05-27 exists). Decide acceptable freshness. Without this, BQ data is frozen.
2. **Build typed `estimates` + `clients`** tables (same external-table + CTAS pattern). estimates needs `account_id, date, invoice_id`; clients needs `account_id, deleted_at, Info[] (Name, Address)` — keep `Info` as JSON array for `UNNEST`.
3. **Rebuild `invoices` with `item_names ARRAY<STRING>`** (currently only `line_item_count`) so the top-item-names signal can be computed in SQL. (Notes already present.)
4. **Write the full `account_metrics` SQL** (all collectors, multi-CTE, LEFT JOIN on account_id) → `CREATE OR REPLACE TABLE ai_analysis_us.account_metrics AS …`. Diff a few accounts vs the C# output to confirm parity (watch the repeat day-gap math, distinct-address set-union, top-N tie-break).
5. **Discovery sweep** (`SweepActiveAccountsAsync`) filters by `CreatedTime` with **no** AccountId predicate → AccountId clustering won't prune it. Partition invoices by date (already done) or rewrite as `SELECT DISTINCT account_id WHERE created_time >= …`.
6. **C# integration** — two shapes:
   - Replace `IAccountDiscovery` + `MetricsCollector` (and `IAccountMetricsRepository` read path) with a **BigQuery-backed** implementation (run SQL via `Google.Cloud.BigQuery.V2`, map rows to `AccountMetricsRow`). Keep DI swap behind config so Mongo path stays available.
   - Or: a **scheduled BQ query** materializes `account_metrics`; C# `MetricsRefreshJob` just triggers/reads it.
7. **Scheduling** — `MetricsRefreshJob` (Hangfire) either fires the BQ query (`jobs.insert`) or a BQ Scheduled Query does it; `AnalyzeFsmFitJob` keeps reading metrics + calling OpenAI.
8. **Cost model** — confirm whether `inv-project` is on-demand or flat-rate (couldn't check: no `reservations.list` perm). On-demand a full metrics run is pennies; flat-rate it's $0 marginal.

---

## Cost (measured this spike)

- **Query:** 26.4 GB billed across 11 jobs ≈ **$0.16** at on-demand list ($6.25/TiB). The 21.8 GB invoices CTAS dominates. Loads were **free**.
- **Storage added:** 6.32 GB (accounts_raw 3.13 + invoices 2.66 + accounts 0.53) ≈ **$0.13/month** while it exists. `accounts_raw` is now redundant (superseded by typed `accounts`) — drop it to halve this.
- Likely **lower or $0** in reality: shared 1 TiB/mo query + 10 GB storage free tiers, and possible flat-rate. Could not read Cloud Billing (API disabled on the SA) — use Console → Billing → Reports for the real figure.

---

## How to operate BQ here (auth & tooling)

- **`bq` CLI is broken on the original machine** (ACL error) → all ops done via **BigQuery REST API + `gcloud auth print-access-token`** (`jobs.insert` for load/query/DDL; poll `jobs/<id>?location=US`; results via `queries/<id>`). On another computer `bq` may work fine — try it first.
- **Auth:** a BQ-scoped service account `tofu-ai-backend@inv-project.iam.gserviceaccount.com` was used (the human account lacks `bigquery.datasets.create` in prod). Key file was at `C:\Files\inv-project-e097726fbd27.json` on the original machine — **machine-specific; provide your own key/auth on the new computer.** Activate with `gcloud auth activate-service-account --key-file=<key>`, and remember to switch back to your user account afterward.
- **Dataset is in US**, source bucket is **US-EAST1** — keep any new dataset in US (or us-east1); the existing EU `ai_analysis_v2` cannot load from this bucket.

---

## Open decisions

- Live freshness (Mongo) vs snapshot freshness (BQ) — acceptable for FSM-fit? (Probably yes; confirm.)
- Canonical vs **Relaxed** Extended-JSON export (Relaxed massively simplifies typing).
- Keep `accounts_raw`/raw landing, or go straight external-table → typed (no raw).
- Where the LLM call lives (C# vs BQ remote function).
- DI: config-gated Mongo↔BQ source so rollback is trivial.
