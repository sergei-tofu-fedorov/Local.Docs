# WEB-1523 — Postgres read-isolation options for the eligibility probe

> ⬜ **Analyze-stage, not built.** The `jobs.Jobs` eligibility probe this doc covers moved **out of metrics collection** into the FSM-fit **audience filter** (`AnalyzeFsmFitJob`, see [`../implementation/analyze.md`](../implementation/analyze.md) § Audience eligibility) and is part of the unbuilt analyze stage. The shipped metrics pipeline (WEB-1527) touches **no Postgres** for reads — only Mongo (reads) + the service's own `analyses` PG schema (Hangfire). Read this as forward design.

Comparison of the ways `Tofu.AI.Api` can read from `Invoices.Backend`'s Postgres (`jobs.Jobs` for the FSM-fit eligibility probe; future analyses may add `Tofu.Auth.Backend` PG) without loading the primary. Sibling to [`mongo-read-isolation.md`](mongo-read-isolation.md) — same shape, but smaller load and a simpler answer.

> Scope: the PG read path defined in [`../analyses/metrics.md`](../analyses/metrics.md) § Eligibility. The query shape (batched `AccountId = ANY(@batch)` lookups on `jobs.Jobs`) and the daily discovery cadence are unchanged. This doc covers only *where* those queries land.
>
> Motivating concern: symmetry with the Mongo isolation conversation, plus a small reality check on whether the locked plan's "read from prod PG" assumption is durable for v2+.

> Pricing below is **ballpark, USD, late-2025 reference**. Cloud SQL pricing is region-dependent; quoted figures are GCP us-east1 baseline. Re-verify against the GCP pricing pages before committing.

## Decision

- **v1 default — read from a Cloud SQL read replica of `Invoices.Backend` PG (Option 1).** Cheapest isolation pattern; same query shape as today; replica lag is sub-second in steady state. ~$50–150/mo depending on replica tier.
- **If no replica exists today**, provision one — the read-replica path is the PG-side equivalent of the Mongo Data Federation read plane (different mechanism, same intent: keep AI reads off the BFF-serving primary), scaled to the much lower PG load.
- **Reading the primary directly (Option 0) — rejected for v1** on symmetry grounds with the Mongo decision, even though the eligibility-probe load alone wouldn't force it.
- **Reserve `Datastream → BigQuery` (Option 2) for v2+** when at least one analysis wants PG-derived data joinable in BQ alongside `account_metrics`. Symmetric to the Mongo CDC-to-warehouse path.
- **Skip the snapshot-export-to-GCS pattern (Option 3) and the custom Dagster pipeline (Option 4)** unless a specific reason emerges. They don't beat 1 or 2 on either ease or cost for our load profile.

## Criteria

The PG read shape, copied from [`../analyses/metrics.md`](../analyses/metrics.md) § Eligibility:

- **Source:** `Invoices.Backend` Postgres, schema `jobs`, table `Jobs`. Fields read: `AccountId`, `IsDeleted`, `CompletionTime`.
- **Query shape:** `SELECT "AccountId" FROM jobs."Jobs" WHERE "AccountId" = ANY(@batch) AND ("IsDeleted" IS NULL OR "IsDeleted" = false) AND "CompletionTime" >= NOW() - INTERVAL '90 days';`
- **Batch size:** ≤10k `AccountId`s per round-trip.
- **Total queries per day:** 20–50 (only the daily discovery sweep; not per-refresh).
- **Index assumption:** `jobs.Jobs.{AccountId}` covering index exists (cross-repo prereq — see `analyses/metrics.md` § Index audit).
- **Freshness budget:** the eligibility check guards row creation; up-to-day-old data is fine — a recently-onboarded FSM-using account will simply get scored one cycle later than it could have been.

Net load: trivially small. The question is whether to isolate it on principle, not necessity.

## Options surveyed

| # | Approach | One-liner |
|---|---|---|
| 0 | Read primary directly | Same connection string as BFF; no isolation. Status quo if no replica exists. |
| 1 | **Cloud SQL read replica** (recommended) | Provision a streaming replica; pin `Tofu.AI.Api` reads to it. Real-time, native PG. |
| 2 | **Datastream → BigQuery** | GCP-managed CDC; PG WAL → BQ tables. Worker queries BQ instead of PG. |
| 3 | BigQuery `EXTERNAL_QUERY` to Cloud SQL | BQ federated query proxying to the PG instance (or its replica). |
| 4 | Cloud SQL export to GCS + BQ external table | Daily `gcloud sql export` to GCS; BQ external table consumes it. |
| 5 | Custom Dagster pipeline (Playfair-style) | Extend Playfair's `tofu_postgres_job.py` to ingest `jobs.Jobs` into `data_layer.*`. |
| 6 | Logical replication to a separate analytics PG | Native PG `CREATE SUBSCRIPTION`; the AI worker queries the analytics instance. |

## Capability matrix

| | 0. Primary | 1. Read replica | 2. Datastream → BQ | 3. BQ `EXTERNAL_QUERY` | 4. GCS export + BQ external | 5. Dagster CDC | 6. Logical replication |
|---|---|---|---|---|---|---|---|
| **Load isolation from primary** | none | yes (replica absorbs) | yes (WAL slot, near-zero overhead) | partial (federated query routes back to PG) | partial (export runs on source/replica) | yes (Dagster pulls from replica) | yes (subscriber absorbs) |
| **Freshness** | real-time | sub-second lag | seconds → low minutes | real-time | daily | daily | sub-second lag |
| **Indexes** | source | source (inherited) | configurable in BQ | source | none (file scan) | configurable in BQ | configurable on subscriber |
| **Query shape change** | none | none | rewrite to BQ SQL | minimal (wrap in `EXTERNAL_QUERY`) | rewrite to BQ SQL | rewrite to BQ SQL | none |
| **Setup effort** | 0 | tiny (provision replica) | small (UI + replication flag) | tiny (BQ connection) | medium (Scheduler + Function + table) | medium (Playfair cross-team) | medium (subscription + monitoring) |
| **Ongoing ops surface** | none | replica + lag monitoring | replication slot monitoring | none beyond #0/#1 | Cloud Scheduler + GCS lifecycle | Playfair pipeline ownership | subscription slot + DDL coordination |
| **Failure / drift risk** | nil | nil (streaming) | non-zero (stuck slot → WAL buildup on source) | nil | export job can silently fail | depends on Dagster job health | non-zero (stuck slot, DDL drift) |
| **Cost shape** | $0 incremental | replica hourly | per-GB CDC + BQ storage | BQ scan + Cloud SQL | tiny (GCS + BQ) | Dagster compute + BQ | analytics instance hourly |
| **Best fit scenario** | tiny load, no symmetry concern | want PG-native isolation, simplest | want data joinable in BQ, near-real-time | ad-hoc BQ access, no copies | daily file artifact for another reason | already extending Playfair | want native PG mirror + column filtering |

## Pricing detail

### 0. Primary
- **$0 incremental.**

### 1. Cloud SQL read replica
- Billed at the same hourly rate as a regular Cloud SQL instance of the matching tier (vCPU + RAM + disk).
- Rough per-month on GCP us-east1:
  - `db-custom-1-3840` (1 vCPU, 3.75 GB) ≈ **$50/mo**
  - `db-custom-2-7680` (2 vCPU, 7.5 GB) ≈ **$95/mo**
  - `db-custom-4-15360` (4 vCPU, 15 GB) ≈ **$190/mo**
- Disk replicated automatically (same size as primary); no separate disk charge beyond what the primary already pays.
- Cross-region replicas add network egress; same-region is the default.

### 2. Datastream → BigQuery
- Datastream charges per GB processed in the stream: roughly **$0.10–$0.30 per GB** depending on direction (GCP-internal cheaper).
- BQ storage on destination tables: standard **$0.02/GB/month** (active) / **$0.01/GB/month** (long-term).
- BQ query cost on destination: **$6.25/TB scanned**.
- For our `jobs.Jobs` slice (~200–500k rows for the active window, small fields): destination table is megabytes. Steady-state CDC + BQ cost likely **<$20/mo**.

### 3. BigQuery `EXTERNAL_QUERY` to Cloud SQL
- BQ scan side: **$6.25/TB scanned**, billed on what BQ pulls back from PG.
- Cloud SQL side: just the per-query CPU/IO on the instance the connection targets. If pointed at the primary, you're back to loading prod; if at a replica, you pay replica hourly cost as in Option 1.
- Per-query latency is higher than direct PG (proxy overhead), so this is good for ad-hoc analytical queries, bad for tight per-batch loops.

### 4. GCS export + BQ external table
- `gcloud sql export` is free apart from the brief CPU/IO on the source during the export.
- GCS storage: **~$0.02/GB/mo** (Standard, us-east1).
- BQ external table queries: **$6.25/TB scanned**.
- At our table size, **<$1/mo**.

### 5. Custom Dagster pipeline
- Compute: amortised in the existing Dagster cluster (~$0 incremental).
- BQ storage + query: same as Option 2 (**<$20/mo**).
- Real cost is **Playfair-team ownership** of a new stream — coordination, not dollars.

### 6. Logical replication to a separate analytics PG
- Subscriber instance: Cloud SQL hourly cost as in Option 1 (~$50–190/mo per tier).
- Replication slot on source is small CPU overhead; WAL volume drives any extra cost (negligible for our slice).
- Best when you also want native PG access to the mirrored data from multiple consumers, not just BQ.

## Common scenarios — pick by what you're trying to solve

| Scenario | Best fit | Why |
|---|---|---|
| "We just want PG reads off the primary, minimum fuss." | **Option 1 — read replica** | Cheapest GCP-native isolation, same query shape, no rewrite, no pipeline. |
| "We want the data in BQ to join with `account_metrics`." | **Option 2 — Datastream** | GCP-native CDC, near-real-time, no Playfair coordination. |
| "We want occasional BQ access without copying data." | **Option 3 — `EXTERNAL_QUERY`** | Lowest setup; load lands wherever the connection points. |
| "We already have a daily file artifact for another consumer." | **Option 4 — GCS export** | Reuse the artifact; cheapest steady-state at daily cadence. |
| "We want the PG data in the warehouse alongside Playfair's existing PG/Mongo streams." | **Option 5 — extend Playfair pipeline** | Single canonical warehouse; amortises across analyses; cross-team coordination required. |
| "Multiple non-BQ consumers need the mirrored data." | **Option 6 — logical replication** | Native PG, configurable indexes, no warehouse hop. |

## Staged recommendation for WEB-1523

1. **Confirm the source PG topology** — Cloud SQL? AlloyDB? Self-managed? Does a read replica already exist? (See § Open questions.)
2. **If on Cloud SQL with no replica → provision one** sized to match expected analytics load. For the eligibility probe alone, the smallest tier is sufficient. Pin `Tofu.AI.Api` reads to its connection string.
3. **If a replica exists → just use it.** Same effect, zero infrastructure change.
4. **Add Cloud SQL dashboard panels** post-cutover: replica lag, replica CPU/IO, query latency. Tripwire for moving to Option 2 is "replica saturated" or "v2 analysis wants PG data joined in BQ."
5. **Option 2 (Datastream) becomes the right pick once any of:** (a) a v2 analysis needs `Tofu.Auth.Backend` PG data at scale, (b) we want eligibility-funnel rows queryable from BQ for cohort analysis alongside `account_metrics`, (c) the replica starts contending with whatever else uses it.
6. **Option 5 (extend Playfair)** is the long-horizon answer — same role here as Option 9 in the Mongo doc. Revisit when ≥2 analyses share the warehouse path.

## Open questions

- [ ] **What is the source PG topology?** Cloud SQL for PostgreSQL, AlloyDB, or self-managed on GCE/GKE? Drives the Option 1 / 2 setup specifics. Default assumption in this doc is Cloud SQL.
- [ ] **Does a Cloud SQL read replica already exist** on `Invoices.Backend`'s PG instance? If yes, Option 1 is "add a connection string"; if no, ~15 min of provisioning.
- [ ] **Is `wal_level=logical` enabled** on the source instance? Required for Option 2 (Datastream) and Option 6 (logical replication). Flipping it on a Cloud SQL instance requires a flag change + restart.
- [ ] **Does `jobs.Jobs.{AccountId}` index exist?** Carry-over from [`../analyses/metrics.md`](../analyses/metrics.md) § Index audit — confirm before locking the discovery batch size, independent of the read-isolation choice here.
- [ ] **Future PG load from v2 analyses** — `churn_risk` proposed to use `Tofu.Auth.Backend` PG (login recency, session signal). If that volume materially exceeds the eligibility probe, the right shape might be Option 2 from the start rather than scaling Option 1.

## Cross-references

- [`mongo-read-isolation.md`](mongo-read-isolation.md) — the Mongo-side counterpart; same options framework, much larger load, locked answer is Mongo Data Federation over snapshots (prod) / plain default connection (stage).
- [`metrics.md`](metrics.md) — broader sourcing-category investigation (direct reads vs. event-sourced vs. DWH vs. Amplitude); PG sits inside Option A (direct reads).
- [`../analyses/metrics.md`](../analyses/metrics.md) — locked eligibility-funnel query and batching strategy; this doc does not change them.
- [`dwh.md`](dwh.md) — Playfair DWH inventory including the existing `tofu_postgres_payment_orders` daily PG → BQ ingestion. Reference for Option 5's shape.
