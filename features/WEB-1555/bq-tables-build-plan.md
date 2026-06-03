# WEB-1555 → BigQuery — table build plan (4 source tables → `account_metrics`)

**Status:** plan (ready to execute against the 2026-06-02 snapshot).
**Date:** 2026-06-02
**Companion to:** [`bq-migration-spike.md`](bq-migration-spike.md) (the spike findings this operationalises).
**Decision locked:** **(a) SQL-materialized `account_metrics` + daily `LOAD DATA OVERWRITE` refresh** (not the C# CDC path). See § Daily refresh.

## Goal

Build the four typed BigQuery source tables from the latest Atlas snapshot, then materialize **`account_metrics`** carrying as much of what `AnalyzeFsmFitJob` consumes as the privacy boundary allows — so the analyze tick reads from BigQuery, not live Mongo.

What `AnalyzeFsmFitJob` actually needs per account (verified against code on `feature/WEB-1555-bq`):

| Input | Source today | Lands where in this plan |
|---|---|---|
| 13 numeric/bool metrics (`AccountMetricsRow`) | Mongo collectors → `account_metrics` (CDC) | `account_metrics` columns (SQL) ✅ |
| `top_item_names` (top 50, raw) | `InvoiceSignalsCollector` (live Mongo `invoices`) | `account_metrics.top_item_names` (SQL) ✅ |
| `top_notes` (top 20, **redacted**) | `InvoiceSignalsCollector` (live Mongo) → C# Presidio redact | **see § The notes problem** — not pure SQL |
| account maturity (`CreatedTime`, ≥90d gate) | Mongo `accounts` | `accounts.created_time` (BQ) — C# swap |

**Target dataset:** `inv-project.ai_analysis_us` (PROD, **US** — must match the US-EAST1 snapshot bucket; EU `ai_analysis_v2` cannot read it).
**Snapshot source (latest, only one in the bucket after cleanup):**
```
gs://atlas-snap-export-production/exported_snapshots/5a58ddfbdf9db10eed1cc64d/
  5a58ddfbdf9db10eed1cc650/InvoicesCluster/2026-06-02T1611/1780430470/invoicesDB/<collection>/*.json.gz
```
Anchor every time window to the **snapshot instant** (`2026-06-02 16:11 UTC`), not `now()` — BQ data is frozen as-of-snapshot.

---

## Build order

1. **`accounts`** — already built by the spike; verify columns (`account_id, business_name, is_deleted, is_technical, created_time`). No change expected.
2. **`invoices`** — rebuild to add `item_names ARRAY<STRING>`.
3. **`estimates`** — build.
4. **`clients`** — build.
5. **`account_metrics`** — materialize **last**, deriving from 1–4.

Each source build uses the spike's proven **external-table → `CREATE OR REPLACE TABLE … AS SELECT`** pattern (load is free; typed projection/filter happens in the `SELECT`; drop the `_ext` pointer after). Extended-JSON unwrapping rules (`$numberDecimal`, `$date."$numberLong"`, `$`-key escaping) are documented in the spike doc — not repeated here.

---

## Step 2 — `invoices` (add `item_names`)

`item_names` = the **named** line items (`Items[].Name`, non-empty), for the signals path — keep duplicates so `COUNT(*)` later reproduces Mongo's `$unwind` occurrence counting. Keep **`line_item_count` = `ARRAY_LENGTH(Items)`** over **all** items (incl. unnamed): `avg_line_items_per_invoice` uses `$size:$Items`, not the named subset — do **not** derive one from the other.

```sql
CREATE OR REPLACE EXTERNAL TABLE ai_analysis_us.invoices_ext (raw STRING)
OPTIONS (format='CSV', field_delimiter='\t', quote='',
         uris=['gs://atlas-snap-export-production/.../2026-06-02T1611/1780430470/invoicesDB/invoices/*.json.gz']);

CREATE OR REPLACE TABLE ai_analysis_us.invoices
PARTITION BY TIMESTAMP_TRUNC(date, MONTH)
CLUSTER BY account_id AS
SELECT
  JSON_VALUE(raw,'$._id')                                                                       AS id,
  JSON_VALUE(raw,'$.AccountId')                                                                 AS account_id,
  TIMESTAMP_MILLIS(SAFE_CAST(JSON_VALUE(raw,'$.Date."$date"."$numberLong"') AS INT64))          AS date,
  TIMESTAMP_MILLIS(SAFE_CAST(JSON_VALUE(raw,'$.CreatedTime."$date"."$numberLong"') AS INT64))   AS created_time, -- discovery parity (optional)
  SAFE_CAST(JSON_VALUE(raw,'$.TotalAmount."$numberDecimal"') AS FLOAT64)                         AS total_amount,
  COALESCE(ARRAY_LENGTH(JSON_QUERY_ARRAY(raw,'$.Items')),0)                                      AS line_item_count, -- ALL items
  ARRAY(                                                                                          -- NAMED items only
    SELECT JSON_VALUE(i,'$.Name')
    FROM UNNEST(JSON_QUERY_ARRAY(raw,'$.Items')) AS i
    WHERE COALESCE(JSON_VALUE(i,'$.Name'),'') != ''
  )                                                                                              AS item_names,
  JSON_VALUE(raw,'$.Notes')                                                                      AS notes,
  COALESCE(JSON_VALUE(raw,'$.ClientId'), JSON_VALUE(raw,'$.Client.CatalogId'))                   AS client_id
FROM ai_analysis_us.invoices_ext
WHERE LOWER(COALESCE(JSON_VALUE(raw,'$.IsDeleted'),'false')) <> 'true';  -- NotDeleted: false-or-absent (matches MongoFilters.NotDeleted)

DROP EXTERNAL TABLE ai_analysis_us.invoices_ext;
```

## Step 3 — `estimates`

Needs (`EstimateMetricsCollector`, 12mo window, NotDeleted): `account_id`, `date`, `invoice_id` (presence ⇒ converted).

```sql
CREATE OR REPLACE EXTERNAL TABLE ai_analysis_us.estimates_ext (raw STRING)
OPTIONS (format='CSV', field_delimiter='\t', quote='',
         uris=['gs://.../2026-06-02T1611/1780430470/invoicesDB/estimates/*.json.gz']);

CREATE OR REPLACE TABLE ai_analysis_us.estimates
PARTITION BY TIMESTAMP_TRUNC(date, MONTH)
CLUSTER BY account_id AS
SELECT
  JSON_VALUE(raw,'$._id')                                                                AS id,
  JSON_VALUE(raw,'$.AccountId')                                                          AS account_id,
  TIMESTAMP_MILLIS(SAFE_CAST(JSON_VALUE(raw,'$.Date."$date"."$numberLong"') AS INT64))   AS date,
  JSON_VALUE(raw,'$.InvoiceId')                                                          AS invoice_id
FROM ai_analysis_us.estimates_ext
WHERE LOWER(COALESCE(JSON_VALUE(raw,'$.IsDeleted'),'false')) <> 'true';

DROP EXTERNAL TABLE ai_analysis_us.estimates_ext;
```

## Step 4 — `clients`

Needs (`ClientMetricsCollector`): `account_id`, alive = **`DeletedAt` null** (NOT `IsDeleted`), and the `Info[]` array of `{Name, Address}` (keep as repeated `STRUCT` for `UNNEST`).

```sql
CREATE OR REPLACE EXTERNAL TABLE ai_analysis_us.clients_ext (raw STRING)
OPTIONS (format='CSV', field_delimiter='\t', quote='',
         uris=['gs://.../2026-06-02T1611/1780430470/invoicesDB/clients/*.json.gz']);

CREATE OR REPLACE TABLE ai_analysis_us.clients
CLUSTER BY account_id AS
SELECT
  JSON_VALUE(raw,'$._id')        AS id,
  JSON_VALUE(raw,'$.AccountId')  AS account_id,
  ARRAY(
    SELECT AS STRUCT JSON_VALUE(i,'$.Name') AS name, JSON_VALUE(i,'$.Address') AS address
    FROM UNNEST(JSON_QUERY_ARRAY(raw,'$.Info')) AS i
  )                              AS info
FROM ai_analysis_us.clients_ext
WHERE JSON_VALUE(raw,'$.DeletedAt') IS NULL;   -- alive: DeletedAt absent/null

DROP EXTERNAL TABLE ai_analysis_us.clients_ext;
```

---

## The notes problem — can `account_metrics` hold *everything* `AnalyzeFsmFitJob` needs?

**Item names: yes, in pure SQL.** They go to the LLM raw, so a raw `top_item_names ARRAY<STRUCT<name STRING, count INT64>>` column on `account_metrics` is fine and cuts Mongo for items.

**Notes: not in pure SQL.** `FsmFitPayloadBuilder` redacts notes through Presidio (`IRedactor`) before the LLM, and the codebase guarantees **raw notes never land in BigQuery** (`IInvoiceSignalsCollector` doc-comment). Redaction is a service call, fail-closed, and has no SQL equivalent. So a `top_notes` column can only be filled one of two ways:

### Design A (recommended) — items in `account_metrics` (SQL); notes redacted at analyze time from BQ `invoices` (C#)
- `account_metrics` gains `top_item_names` (SQL). Numeric metrics + items cut over to BQ.
- The **notes** half of `InvoiceSignalsCollector` is re-pointed from Mongo `invoices` to **BQ `invoices`** (raw read), then redacted in C# exactly as today; raw text still never persisted.
- **Mongo fully cut**, privacy invariant intact, daily refresh stays pure SQL.
- Trade-off: `account_metrics` holds *almost* everything — notes are still fetched (from BQ `invoices`) + redacted in the analyze tick.

### Design B — fully self-sufficient `account_metrics` (redacted notes stored in BQ)
- Daily refresh gains a **C# Presidio pass**: SQL aggregates raw `top_notes` into a staging table → C# reads, redacts, writes `top_notes_redacted` onto `account_metrics` → raw staging dropped. The analyze tick then reads **one row** and builds the payload with **no** separate signals read and **no** analyze-time redaction.
- Trade-off: refresh is **no longer pure SQL** (needs a Presidio step), and it **persists redacted notes in BigQuery** — a privacy-policy call that must be signed off against [`../WEB-1523-segmentation/investigation/privacy.md`](../WEB-1523-segmentation/investigation/privacy.md) (this plan does not decide it). Redaction also moves out of the per-account fail-closed path, changing failure semantics.

**Recommendation:** ship **Design A** first (privacy-safe, pure-SQL refresh, Mongo fully cut). Treat Design B as a later optimisation if a one-row-per-account read is worth a Presidio stage in the pipeline — and only after privacy sign-off.

> Either way, **build the 4 tables first, then `account_metrics`** — that sequencing is exactly the plan. The only thing the notes decision changes is whether `account_metrics` carries notes or the analyze tick fetches them from BQ `invoices`.

---

## Step 5 — materialize `account_metrics` (Design A shape)

Decision (a): plain SQL table, full-replaced daily — drop the CDC machinery (no Storage Write API, no `PRIMARY KEY … NOT ENFORCED`, no `max_staleness`, no `updated_at` partition; every row's `updated_at` = snapshot instant, so a partition on it would be one useless partition).

```sql
CREATE OR REPLACE TABLE `inv-project.ai_analysis_us.account_metrics`
CLUSTER BY account_id AS
WITH
vol AS (   -- InvoiceMetricsCollector 30d volume
  SELECT account_id,
    COUNT(*) AS invoice_count_30d,
    AVG(total_amount) AS avg_invoice_amount,
    IF(AVG(total_amount) > 0, STDDEV_POP(total_amount)/AVG(total_amount), NULL) AS invoice_amount_variance_cv,
    AVG(line_item_count) AS avg_line_items_per_invoice
  FROM `inv-project.ai_analysis_us.invoices`
  WHERE date >= TIMESTAMP_SUB(TIMESTAMP '2026-06-02 16:11:00', INTERVAL 30 DAY)
    AND date <  TIMESTAMP '2026-06-02 16:11:00'
  GROUP BY account_id
),
per_client AS (   -- 12mo, client_id required (walk-ins dropped)
  SELECT account_id, client_id, COUNT(*) AS n, MIN(date) AS min_d, MAX(date) AS max_d
  FROM `inv-project.ai_analysis_us.invoices`
  WHERE date >= TIMESTAMP_SUB(TIMESTAMP '2026-06-02 16:11:00', INTERVAL 12 MONTH)
    AND date <  TIMESTAMP '2026-06-02 16:11:00' AND client_id IS NOT NULL
  GROUP BY account_id, client_id
),
rep AS (
  SELECT account_id,
    SAFE_DIVIDE(COUNTIF(n >= 2), COUNT(*)) AS repeat_customer_ratio,   -- denom = distinct clients
    AVG(IF(n >= 2, TIMESTAMP_DIFF(max_d, min_d, MILLISECOND)/((n-1)*86400000.0), NULL)) AS avg_days_between_repeats
  FROM per_client GROUP BY account_id
),
est AS (   -- EstimateMetricsCollector 12mo; converted = invoice_id present
  SELECT account_id, COUNT(*) AS estimate_count,
    SAFE_DIVIDE(COUNTIF(invoice_id IS NOT NULL), COUNT(*)) AS estimate_to_invoice_rate
  FROM `inv-project.ai_analysis_us.estimates`
  WHERE date >= TIMESTAMP_SUB(TIMESTAMP '2026-06-02 16:11:00', INTERVAL 12 MONTH)
    AND date <  TIMESTAMP '2026-06-02 16:11:00'
  GROUP BY account_id
),
cli AS (   -- ClientMetricsCollector (no window; alive filtered at ingest)
  SELECT c.account_id,
    LOGICAL_OR(REGEXP_CONTAINS(COALESCE(i.name,''), r'(?i)LLC|Inc|Corp|Property Management|LLP|Ltd')) AS b2b_clients_present,
    COUNT(DISTINCT IF(TRIM(COALESCE(i.address,''))='', NULL, LOWER(TRIM(i.address)))) AS distinct_addresses
  FROM `inv-project.ai_analysis_us.clients` c, UNNEST(c.info) AS i
  GROUP BY c.account_id
),
items AS (   -- InvoiceSignalsCollector top item names — occurrence count via UNNEST (mirrors Mongo $unwind)
  SELECT account_id, name, COUNT(*) AS c
  FROM `inv-project.ai_analysis_us.invoices`, UNNEST(item_names) AS name
  WHERE COALESCE(name,'') != ''
  GROUP BY account_id, name
),
top_items AS (
  SELECT account_id,
    -- tie-break (count DESC, name ASC) MUST match the Mongo {count:-1,_id.n:1} order — stabilises input_hash
    ARRAY_AGG(STRUCT(name, c AS count) ORDER BY c DESC, name ASC LIMIT 50) AS top_item_names
  FROM items GROUP BY account_id
)
SELECT
  a.account_id, a.business_name,
  COALESCE(v.invoice_count_30d,0) AS invoice_count_30d,   -- collector coalesces 0; others stay NULL = "no signal"
  v.avg_invoice_amount, v.invoice_amount_variance_cv, v.avg_line_items_per_invoice,
  r.repeat_customer_ratio, r.avg_days_between_repeats,
  e.estimate_to_invoice_rate, e.estimate_count,
  cli.b2b_clients_present, cli.distinct_addresses >= 2 AS multi_address_work, cli.distinct_addresses,
  ti.top_item_names,                                       -- raw; LLM-safe (Design A)
  TIMESTAMP_ADD(TIMESTAMP '2026-06-02 16:11:00', INTERVAL 24 HOUR) AS expires_at,
  TIMESTAMP '2026-06-02 16:11:00' AS updated_at
FROM `inv-project.ai_analysis_us.accounts` a
LEFT JOIN vol v       ON v.account_id   = a.account_id
LEFT JOIN rep r       ON r.account_id   = a.account_id
LEFT JOIN est e       ON e.account_id   = a.account_id
LEFT JOIN cli         ON cli.account_id = a.account_id
LEFT JOIN top_items ti ON ti.account_id = a.account_id
WHERE NOT a.is_deleted AND NOT a.is_technical;   -- eligibility 1–3 (FilterEligibleAsync)
```

**Notes for Design B** would add a `top_notes` CTE (`WHERE notes IS NOT NULL AND TRIM(notes)!=''`, `ARRAY_AGG(... ORDER BY c DESC, note ASC LIMIT 20)`) into a **raw staging** table, then a C# Presidio pass writes `top_notes_redacted` — never the raw column — onto `account_metrics`.

**Audience:** populates a row per **eligible** account. Production additionally restricts to discovery-active accounts (invoices `CreatedTime` within 90d) — add `AND a.account_id IN (SELECT DISTINCT account_id FROM invoices WHERE created_time >= TIMESTAMP_SUB(<end>, INTERVAL 90 DAY))` for parity. The 90-day **maturity gate** is *not* applied here — it's an analyze-stage filter.

---

## Daily refresh — decision (a): full-replace

Atlas snapshots are **full dumps**, so overwriting the whole table each day handles deletes for free — no merge/CDC. Daily sequence (runnable as a BigQuery **Scheduled Query**):

1. **Refresh the 4 source tables** — re-run the Step 2–4 `CREATE OR REPLACE EXTERNAL TABLE …_ext → CREATE OR REPLACE TABLE <typed> AS SELECT … → DROP …_ext` against the latest snapshot. `CREATE OR REPLACE` *is* the atomic overwrite for canonical Extended-JSON (the typed projection can't be skipped).
2. **Re-materialize `account_metrics`** = the Step 5 `CREATE OR REPLACE TABLE … AS` (Design A), or that + the C# Presidio notes pass (Design B).

**Two sub-decisions to resolve:**
- **Latest-snapshot URI resolution.** The prefix is timestamped, so a pure Scheduled Query can't see "latest". Cleanest fix = a tiny step relinking the newest `.complete` snapshot under a fixed **`current/`** prefix, so all SQL has constant URIs and the whole refresh is plain scheduled SQL. Otherwise a small driver (Hangfire job / Cloud Function) templates today's prefix into the DDL.
- **Relaxed Extended-JSON export.** Flipping the Atlas export to **Relaxed** JSON collapses each source refresh to the spike's one-liner — `LOAD DATA OVERWRITE … FROM FILES(format='JSON', compression='GZIP', uris=[...])` — no external-table+CTAS, no `$numberDecimal`/`$date` unwrapping. Strong synergy with (a); recommended pairing.

**Trigger/ordering:** refresh must run *after* the day's export `.complete` lands (GCS→Pub/Sub on the marker, or a time-lag schedule + a guard asserting the latest `.complete` is today's). Depends on **re-enabling the daily Atlas export policy** (spike remaining-work #1 — today's 2026-06-02 export was a manual one-off).

---

## C# changes to fully cut Mongo

`account_metrics` lives in `ai_analysis_us` here (the spike's US dataset), so point the read repo's `BigQueryOptions.DatasetId` at it. Then:

- **`MetricsRefreshJob` + the Mongo collectors** (`InvoiceMetricsCollector` et al.) — retired for `account_metrics`; the SQL CTEs replace them. Keep behind a config flag for rollback (the spike's config-gated Mongo↔BQ source).
- **`AccountMetricsRow` + `BigQueryAccountMetricsRepository.Map`/`GetBatchAsync`** — add `TopItemNames` (and, Design B, `TopNotesRedacted`); extend the `SELECT` column list. (Design A changes `AnalyzeFsmFitJob`'s signal wiring after all — my earlier "unchanged" only held while signals stayed a separate Mongo collector.)
- **`InvoiceSignalsCollector`** — Design A: re-point the **notes** read from Mongo `invoices` to BQ `invoices`; items now come from the metrics row. Design B: collector removed from the analyze path entirely.
- **Maturity gate** (`AccountsRepository.GetAccountIdsCreatedSinceAsync`) — re-point from Mongo `accounts` to BQ `accounts.created_time` (the column exists). Last Mongo read in the analyze tick.

---

## Parity validation (don't skip)

Diff ~5–10 accounts spanning the metric space, BQ vs the C# collectors, against the same snapshot date. Known traps:
1. **repeat day-gap** — `((n-1)*86400000.0)` divisor; `AVG` only over `n>=2`.
2. **distinct-address set-union** — null/blank exclusion + lower/trim before distinct.
3. **top-N tie-break** — `ORDER BY count DESC, name ASC` (item names) / `note ASC` (notes); must match Mongo `{count:-1,_id.n:1}` or `input_hash` churns and forces paid LLM re-judges.

---

## Open decisions

- **Design A vs B** for notes (above) — A recommended.
- **Snapshot freshness** acceptable for FSM-fit (BQ = as-of-snapshot, not live)? Spike says probably yes.
- **Relaxed vs canonical** export + **`current/` prefix** — both simplify the daily refresh; decide together.
- **Discovery-restricted vs full-eligible** population for `account_metrics`.
- **`item_names` duplicates within an invoice** kept (Mongo counts occurrences via `$unwind`) — confirm intended weighting.
