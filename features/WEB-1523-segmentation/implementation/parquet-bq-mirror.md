# WEB-1523 — Source mirror via Federation `$out` → Parquet → native BigQuery (alternative read plane)

Proposed alternative to the JSON.gz-snapshot + per-account-Federation read plane in [`mongo-data-federation.md`](mongo-data-federation.md): mirror the Mongo source collections into **native, clustered BigQuery tables** once per cycle (incrementally), and run all per-account work in BQ — eliminating per-account reads over archived JSON.gz through Federation.

> **Status: DRAFT / proposal — decision OPEN.** This is an investigation outcome, not a locked plan. The shipped WEB-1527 read plane (MQL aggregation over Federation → `account_metrics` via Storage Write API CDC) still stands. Adopting any of this would change that read plane — see § "Directional options (the open decision)". Dollar figures and a few API details are tagged **[verify]** and must be confirmed against live docs/pricing before implementation.

> **Scope guardrail.** Read-plane mechanism only. *What* gets aggregated (per-metric query plan, eligibility funnel, refresh cadence) stays owned by [`../analyses/metrics.md`](../analyses/metrics.md); the destination `account_metrics`/`account_fsm_fit` schema by [`storage.md`](storage.md). Those win on conflict.

## Motivation

The shipped/locked plan reads source signals via **Atlas Data Federation over gzip Extended-JSON snapshots** (`mongo-data-federation.md`). Two docs already flag the load-bearing cost risk: per-account targeted reads × ~100k accounts/day against JSON.gz have **no columnar pushdown and no indexes**, so Federation scan billing can dominate (`mongo-read-isolation.md` § Caveat; `mongo-data-federation.md` § Cost shape). Concerns this doc addresses:

- **No indexes** on the archived snapshot read path → full-file scans per access.
- **Reading "archived" data** (JSON.gz snapshots) through Federation per cycle is the expensive scan.
- **BigQuery read cost** worry — addressed by reframing (below): BQ reads of the *aggregated* tables are already cheap; the spend is the *source* scan.
- **Avoid re-importing everything** each cycle.

**Reframe — where the money actually is.** Reading `account_metrics` / `account_fsm_fit` from BQ is **not** the cost problem: ~100k tiny rows, fractions of a cent, under the 1 TiB/mo on-demand free tier, and trivially cheap once clustered. The real spend is the **per-cycle source scan**. So the goal is to eliminate the archived-JSON Federation read, not to swap the output store.

## TL;DR

Mirror the source into native, clustered BQ once per cycle — **incrementally** — and do everything else in BQ:

1. **Incremental export** — Federation `$out` Parquet delta keyed on `ModifiedTime` for the big mutable collections (`invoices`, `estimates`); cheap full-reload for the small ones (`accounts`, `clients`).
2. **Free `LOAD` + `MERGE`** into native BQ tables **partitioned by month, clustered by `account_id`**.
3. **Aggregate in BQ SQL** (`GROUP BY account_id`) → `account_metrics` (also clustered).
4. Analyze-stage + consumers read the clustered native tables.

This makes BQ clustering the index substitute, removes per-account archived-JSON reads, and (via the `ModifiedTime` watermark) moves only the daily delta rather than re-pickling 11M rows.

## How Parquet works (the cost-relevant bits)

Parquet is a **columnar, self-describing** file format:

- **Columnar layout** → engines read only the columns a query needs (**projection/column pruning**). Row formats (JSON/BSON/CSV) must read whole documents.
- **Structure**: file → *row groups* → *column chunks* → *pages*.
- **Footer statistics**: min, max, null-count per column per row group. The engine reads the footer first and **skips entire row groups** whose `[min,max]` can't satisfy the filter (**predicate pushdown**).
- **Encoding + compression**: dictionary / RLE / bit-packing, then a block codec (Snappy default, gzip, zstd).

Net: Parquet queries commonly read **10–100× less data** than row formats for filtered/analytical access — the "bytes read" axis you pay for in both BQ and Federation.

## Pipeline

```
Source (Atlas)                    GCS                          BigQuery (native)
┌───────────────┐  Federation   ┌──────────────────────┐  free LOAD   ┌──────────────────────┐
│ snapshot store│   $out         │ partitioned Parquet  │  + MERGE     │ partitioned+clustered │
│  (json.gz)    │ ─────────────▶ │ dt=.../shard.parquet │ ───────────▶ │ (Capacitor columnar)  │
│  or live clstr│  (MQL agg)     │ (Snappy, row groups) │   wildcard   │   cluster BY account_id│
└───────────────┘                └──────────────────────┘   URIs       └──────────┬───────────┘
                                                                                   │ cheap reads
                                                                                   ▼
                                                                   metric SQL / analyze stage / consumers
```

### Stage 1 — Federation `$out` → partitioned Parquet on GCS

**Confirmed:** Atlas Data Federation `$out` writes to **GCS** in **Parquet** (formats: bson/csv/json/parquet/tsv ± gz). Snapshot *export* (Cloud Backup) still emits **gzip Extended-JSON only** — so Parquet comes from `$out`, not from the snapshot export. (This corrects the "Parquet ❌ not available" row in `mongo-data-federation.md` § Best practices — it *is* available, natively, via `$out`; no Dataflow.)

Prerequisites (one-time): FDI with a GCS store; Atlas-managed GCP SA with write on the bucket; a Mongo user with the **`outToGCP`** privilege (or `atlasAdmin`).

`$out` is the terminal stage of a normal aggregation, so partitioning is done by making `filename` an **expression** that evaluates per-document to a path string:

```javascript
db.invoices.aggregate([
  { $match: { /* latest snapshot + watermark — see Incremental */ IsDeleted: { $in: [false, null] } } },
  { $project: { AccountId: 1, Date: 1, TotalAmount: 1, Items: 1, ClientId: 1, "Client.CatalogId": 1, Status: 1, ModifiedTime: 1 } },
  { $out: {
      gcs: {
        bucket: "tofu-ai-mongo-parquet-prod",
        region: "us-central1",
        filename: { $concat: [ "invoices/", "dt=", { $dateToString: { format: "%Y-%m", date: "$Date" } }, "/" ] },
        format: { name: "parquet", maxFileSize: "256MiB", maxRowGroupSize: "128MiB", columnCompression: "snappy" },
        errorMode: "continue"
      }
  }}
])
```

Produces Hive-style paths (`dt=2026-05/shard.1.parquet`, …) that both BQ load and external tables can read as a partition column. Knobs: `maxFileSize` (default 200 MiB, rolls `shard.N`), `maxRowGroupSize` (Parquet only; default min(128 MiB, maxFileSize), hard max 1 GB — the pushdown granularity), `columnCompression` (snappy default).

**Scheduling:** `$out` is just an aggregation → **trigger it from the in-process Hangfire job** against the FDI connection string. Fits the single-pod design; no new infra. Avoid Atlas App Services Scheduled Triggers (deprecation path) — keep the schedule in our code.

**Cost:** Federation bills **~$5/TB processed + 10 MB min/query** **[verify]**; reading the ~11 GB hot invoice slice once ≈ **~$0.055/run** (~$1.65/mo daily) for a *full* export. Incremental (below) drops this to ~the 10 MB floor.

### Stage 2 — free `LOAD` into a native BQ table

Parquet is self-describing → BQ **auto-detects schema**; **batch `LOAD` jobs are free** (pay only storage + later queries). One job takes **wildcard URIs**.

```sql
LOAD DATA OVERWRITE ai_analysis_v2.invoices_raw
  PARTITION BY DATE_TRUNC(Date, MONTH)
  CLUSTER BY AccountId
FROM FILES ( format = 'PARQUET', uris = ['gs://tofu-ai-mongo-parquet-prod/invoices/dt=*/*.parquet'] );
```

Write dispositions: `WRITE_TRUNCATE`/`OVERWRITE` (full refresh), `WRITE_APPEND`, `WRITE_EMPTY`. Partitioning is set from a **data column** (`Date`) — the `dt=` folders are for GCS organisation / external reads, not required for a native load. Appending/overwriting partitioned+clustered tables via load works in **bq CLI / API / SQL** (not the Cloud Console) — fine, we drive it from code.

**Cost:** $0 for the load. Ongoing = GCS Parquet storage (~$0.02/GB/mo **[verify]**, smaller than JSON.gz) + BQ active storage (~$0.02/GB/mo **[verify]**). The GCS Parquet can be lifecycle-expired after a successful load if not kept as backup.

## Incremental — no full reimport

**Enabler (confirmed in code):** `Invoice`/`Estimate` derive from `VersionedEntity` with `CreatedTime` **and** `ModifiedTime`; `ModifiedTime` is stamped on every write via Mongo `$currentDate` (`VersionedEntityRepository.cs:61`, `InvoicesRepository.cs:164`). Inserts, edits, status changes, and **soft-deletes** (`IsDeleted` flip) all bump it. There's a proven precedent: `SyncInvoicesQueryHandler` pages by a `(ModifiedTime, UniqueId)` cursor (`filterBuilder.Gt(x => x.ModifiedTime, …)`) backed by `ix_invoices.accountid.modifiedtime.uniqueid`. That tuple is the watermark a delta export needs; `UniqueId` is the tiebreaker for equal timestamps.

**Export side** — leading `$match` on the watermark (no special feature):

```javascript
{ $match: { ModifiedTime: { $gt: ISODate("<last watermark>") } } }
```

Persist the new watermark = max `(ModifiedTime, UniqueId)` exported, in the `analyses` Postgres schema (already present) or a tiny BQ control table. First run = empty watermark → full backfill; subsequent runs = delta only.

**Load side — two options:**

**Option A — delta load + `MERGE` upsert (correct for mutable data).**
```sql
LOAD DATA OVERWRITE ai_analysis_v2._stg_invoices
FROM FILES (format='PARQUET', uris=['gs://.../invoices_delta/run=<ts>/*.parquet']);

MERGE ai_analysis_v2.invoices_raw T
USING ai_analysis_v2._stg_invoices S
  ON T._id = S._id AND T.Date = S.Date          -- Date in the join lets BQ prune target partitions
WHEN MATCHED THEN UPDATE SET ...                 -- edits + soft-deletes flow through
WHEN NOT MATCHED THEN INSERT ROW;
```
Store soft-deleted rows as-is and let metric SQL filter `IsDeleted IN (false,null)` (matches existing convention). `MERGE` scans only the touched target partitions → cost proportional to churn, not table size. **This is the option that handles updates correctly.**

**Option B — partition-decorator overwrite (cheaper, append-only data only).**
```bash
bq load --replace --source_format=PARQUET \
  ai_analysis_v2.invoices_raw'$202605' \
  'gs://.../invoices/dt=2026-05/*.parquet'
```
Loading into `table$YYYYMM` replaces just that partition, leaving others untouched **[verify exact `$`-decorator load syntax]**. **Blind spot:** an edit today to an old invoice lands in its *old* `Date` partition (outside the reload window) → missed, even though it's inside the 12-month metric window. Partitioning by `ModifiedTime` instead would double-count (`_id` present in both old and new partitions). So Option B is clean only for genuinely immutable/append-only data.

**Verdict:** for `invoices`/`estimates` (mutable within the metric window), use **Option A**. Option B only where rows never change after creation.

**Per-collection strategy:**

| Collection | Size | Strategy |
|---|---|---|
| `invoices`, `estimates` | ~11M, mutable | **Incremental:** `ModifiedTime` watermark → delta `$out` → `MERGE`. Field + index confirmed (`VersionedEntity`, `ix_*.accountid.modifiedtime.uniqueid`). |
| `clients` | smaller, slow-changing (`DeletedAt` soft-delete) | Incremental **if** it carries a modified field; else **full reload** (cheap). **[verify — `clients` lives in `Invoices.Backend`, not checked]** |
| `accounts` | ~5M but tiny docs, slow-changing | Likely **full reload** each cycle — too small to be worth a MERGE. **[verify modified field]** |

**Caveats:**
- **Hard deletes** aren't caught by a watermark (no `ModifiedTime` to scan). This app uses soft deletes (`IsDeleted`/`DeletedAt` + `ModifiedTime` bump) so deletes are captured as updates. If hard deletes ever occur, add a periodic **full reconcile** (weekly full reload or `_id` set-diff) to GC orphans.
- **Overlap, not gaps.** Advance the watermark only after a successful load; re-scan with a small lookback (`>=` a few minutes before the last cursor). The `_id` `MERGE` is idempotent, so re-importing a few rows twice is harmless; a gap loses data.

## Reads afterward (clustering = the index substitute)

BigQuery has **no secondary indexes** by design — it replaces them with **partition pruning** (skip partitions outside a `WHERE` on the partition column) + **clustering** (data sorted into blocks by up to 4 columns → block skipping on filters). A native `invoices_raw` partitioned by month, clustered by `AccountId`, gives near-point-lookup per-account access billed on the touched blocks/columns only. Inside native tables data lives in Google's **Capacitor** columnar store — same column-pruning/min-max-skip benefits as Parquet, plus clustering. (Querying external Parquet *in place* is the option to avoid: slower, billed on **logical uncompressed** bytes, no clustering.)

## Cost summary (all **[verify]** against live pricing)

| Path | Billing | At our scale |
|---|---|---|
| JSON.gz snapshot → Federation per-account read (current) | $5/TB processed, no pushdown | the flagged multiplier risk |
| `$out` full export → Parquet | $5/TB read once + write | ~$0.055/run full; ~10 MB floor incremental |
| `LOAD` Parquet → native BQ | **free** | $0 |
| `MERGE` delta upsert | on-demand ~$6.25/TiB scanned (touched partitions) | small if partition-pruned |
| Native clustered reads | ~$6.25/TiB, 1 TiB/mo free; clustered/partition pruned | sub-cent for `account_metrics` |
| External Parquet table reads (avoid) | ~$6.25/TiB on **logical uncompressed** bytes, columns read | worse than native |
| GCS Parquet storage | ~$0.02/GB/mo | pennies (smaller than JSON.gz) |

## Directional options (the open decision)

1. **Incremental native mirror (full fix)** — build the pipeline above; move metric aggregation into BQ SQL. Eliminates archived-JSON Federation reads; raw data becomes cheaply queryable for analysts + v2 analyses. **Cost: rewrites the shipped WEB-1527 read plane** (MQL → BQ SQL; CDC writer → load/MERGE; + watermark state + GCS Parquet staging).
2. **Cluster the shipped tables only (minimal)** — keep the shipped MQL/Federation pipeline; just add partition + clustering to the output BQ tables. Fixes the consumer-read "no indexes / read cost" worry cheaply, but keeps the per-cycle Federation source scans.
3. **Hybrid — ship minimal now, mirror later** — cluster output tables for v1; schedule the incremental Parquet mirror as a follow-up ticket, triggered when raw-level data or a 2nd analysis justifies it.

(No option selected yet — this is the call to make. Option 1 is the only one that removes the archived-JSON source read; options 2/3 are lower-effort but leave it in place.)

## Open questions / verify-before-implement

- [ ] **Directional option (1/2/3 above)** — the load-bearing decision.
- [ ] **Pricing** — confirm Federation $/TB + min, BQ on-demand $/TiB (US) + free tier, GCS + BQ storage $/GB against live pages. Replace every **[verify]**.
- [ ] **BQ partition-decorator load syntax** (`table$YYYYMM` + WRITE_TRUNCATE replacing one partition) — confirm before relying on Option B.
- [ ] **`clients` / `accounts` modified field** — do the `Invoices.Backend` models carry a `ModifiedTime`-equivalent? Decides incremental-vs-full-reload for those two.
- [ ] **`$out` source** — read the JSON.gz snapshot store (then the latest-snapshot filter from `mongo-data-federation.md` applies to `$out` too) vs. read the live cluster off-peak (no snapshot, but touches prod). Pick per isolation budget.
- [ ] **Aggregate-in-BQ rewrite scope** — porting the per-metric MQL pipelines (`analyses/metrics.md` § Per-metric query plan) to BQ SQL is the bulk of Option 1's work; size it.

## Cross-references

- [`mongo-data-federation.md`](mongo-data-federation.md) — the JSON.gz-snapshot read plane this proposes an alternative to (and whose § Best practices "Parquet not available" row this corrects).
- [`../investigation/mongo-read-isolation.md`](../investigation/mongo-read-isolation.md) — read-plane option survey + the scan-cost caveat motivating this.
- [`../analyses/metrics.md`](../analyses/metrics.md) — per-metric query plan (would move from MQL to BQ SQL under Option 1).
- [`storage.md`](storage.md) — `account_metrics` / `account_fsm_fit` destination (would gain clustering under any option).

## Sources (web, May 2026)

- [Atlas `$out` — GCS + Parquet, filename expression, file/row-group/compression knobs](https://www.mongodb.com/docs/atlas/data-federation/supported-unsupported/pipeline/out/)
- [Atlas Export Cloud Backup Snapshot — gzip Extended-JSON only](https://www.mongodb.com/docs/atlas/backup/cloud-backup/export/)
- [Atlas Data Federation billing — $5/TB processed, 10 MB min](https://www.mongodb.com/docs/atlas/billing/data-federation/)
- [BigQuery loading Parquet — free batch load, schema auto-detect, write dispositions, wildcards, partitioned/clustered](https://docs.cloud.google.com/bigquery/docs/loading-data-cloud-storage-parquet)
- [BigQuery external tables — Parquet column pruning](https://docs.cloud.google.com/bigquery/docs/external-tables)
- [BigQuery cost best practices — external billed on logical bytes](https://docs.cloud.google.com/bigquery/docs/best-practices-costs)
- [BigQuery pricing](https://cloud.google.com/bigquery/pricing)
- [Apache Parquet structure — row groups, footer stats, pushdown](https://www.parquetexplorer.com/blog/parquet-file-structure)
