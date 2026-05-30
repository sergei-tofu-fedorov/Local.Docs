# WEB-1523 — Mongo read-isolation options for `account_metrics`

Comparison of the ways `Tofu.AI.Api` can read invoices / estimates / clients / accounts data without loading the prod Mongo cluster — Atlas Analytics Nodes, mongosync, change-stream mirrors, Data Federation, Online Archive, Data Lake snapshots, and CDC-to-warehouse. **Locked answer (2026-05-22; stage refined 2026-05-24):** Mongo Data Federation over snapshots in prod; a plain default connection to prod Mongo in stage (no enforced read preference — stage volume is negligible). See `## Decision` below. The capability matrix, pricing detail, and scenario picker further down are kept as reference for future re-evaluations and for analyses with different freshness budgets.

> Scope: only the read path for the `account_metrics` source aggregation defined in [`../analyses/metrics.md`](../analyses/metrics.md). The output schema, per-metric query plan, eligibility funnel, and refresh strategy are unchanged. Companion to [`metrics.md`](metrics.md) (which compares sourcing categories more broadly: direct DB reads vs. event-sourced vs. DWH vs. Amplitude).
>
> Motivating concern: the locked plan in `analyses/metrics.md` runs ~1.2/s sustained per-account aggregations against shared replica-set secondaries on two prod clusters (`Invoices.Backend` Mongo, `Tofu.Invoices.Backend` Mongo). If BFF traffic also lands on those secondaries, the worker would contend with user-facing reads. This doc enumerates the ways to keep our reads off the prod cluster's BFF-shared nodes.

> Pricing below is **ballpark, USD, late-2025 reference**. Quoted figures are AWS us-east-1; GCP us-east1 (where `InvoicesCluster` lives) is comparable for M30+ tiers. Atlas re-tiers periodically — re-verify against the current Atlas pricing page before committing.

> **As built (2026-05-27).** Federation-in-prod / plain-connection-in-stage shipped as decided. Two wording corrections vs. below: the worker knobs are `AggregationBatchSize` (300) + `MaxConcurrentBatches` (4), **not** `MaxConcurrentAccounts = 32`; and the destination dataset is **`ai_analysis_v2`**. The discovery sweep runs every tick, not daily — but at snapshot-backed Federation that doesn't change the cost argument here.

## Decision

- **v1 default — Mongo Data Federation over snapshots (Option 6).** Updated 2026-05-22: previous recommendation (Atlas Analytics Node) was flipped after the team converged on a snapshot-based read plane. `Tofu.AI.Api` connects to a Federation endpoint that resolves `invoices`, `estimates`, `clients`, `accounts` from periodic snapshots — prod replica sets are not touched at all. Collection **names** match the live cluster, so the aggregation pipelines in [`../analyses/metrics.md`](../analyses/metrics.md) run **unmodified**; only the connection string differs.
- **Snapshot inventory must cover all four collections.** Existing snapshot setup covers some collections but not `clients` — adding the `clients` snapshot (matching whatever cadence + `_id`/partition layout the existing snapshots use) is part of WEB-1523 Phase 1 (see `clickup.md` § "Сбор метрик для анализа"). Verify `invoices` and `estimates` snapshot windows cover the 30d / 12mo metric windows.
- **Stage environment — plain default connection to the real prod Mongo clusters, as the other services use.** Data Federation is **not** stood up on stage; collection names match, so the same query code points at the live cluster via a different connection string. **No enforced read preference** (reads may land on the prod primary) — acceptable because stage's worker volume is negligible and stage is only used for end-to-end correctness, not load.
- **Direct secondary reads in prod (Option 1) — rejected.** Atlas dashboard evidence below shows prod secondaries already running hot on `InvoicesCluster`; adding 1.2/s sustained aggregations is unsafe.
- **Atlas Analytics Node (Option 2) — rejected.** Was the locked decision as of 2026-05-21; superseded once Data Federation came in as a viable path that eliminates *all* live-cluster read load (analytics node still hits the same physical cluster, just a logically-tagged member). The line item ($400–$2,300/mo for analytics nodes across both clusters) also goes away with the snapshot-backed path.
- **Reserve mongosync / custom change-stream mirror (Options 4–5)** for the case where physical isolation *plus* live-freshness becomes a hard requirement. Snapshot-backed Federation gives us isolation; freshness on snapshot cadence (typ. daily or hourly) is acceptable for FSM-fit's metric windows.
- **CDC-to-BigQuery (Option 9 — CDC → external BigQuery warehouse) stays as the long-horizon answer** when v2+ analyses and BI dashboards justify a shared warehouse.

**Caveat on cost shape (revisit during implementation).** This doc originally rejected Option 6 partly because per-account targeted reads × 100k accounts/day would multiply Federation scan cost vs. a single batched sweep. That economic concern still applies: if the worker keeps the per-account aggregation pattern unchanged, scan billing on the Federation endpoint may dominate. Two ways to handle: (a) re-shape the refresh into a batched per-snapshot sweep that lands intermediate results in `account_metrics` and have per-analysis code read from BQ thereafter — this matches the Layer A / Layer B split already in [`architecture.md`](../architecture.md); or (b) accept the per-account scan cost as the simpler path for v1 and measure before optimising. The implementation task should price both before committing.

## Criteria

FSM-fit's read shape, copied from [`../analyses/metrics.md`](../analyses/metrics.md) so this doc can be evaluated standalone:

- ~100k accounts in the scored set (filtered from ~5M backing-store).
- ~11M invoices in `Tofu.Invoices.Backend` Mongo; per-account 30d window ≈ 30 invoices, 12mo window ≈ 110.
- Refresh: hourly `MetricsRefreshJob` cron with 24h `RefreshTtl`; per-account aggregation × ~4,200 accounts/hour ≈ 1.2/s sustained.
- Cold-start budget: ~2h from first invoice to first `v_fsm_fit` row (proposal-surface SLA).
- Pipelines hit existing indexes — `ix_invoices.accountid.date.createdtime`, `ix_estimates.accountid.date.createdtime`, `ix_clients.accountid` — and run in single-digit ms each.
- PG eligibility probe (`jobs.Jobs`) is out of scope for this doc — Mongo-read isolation options don't cover it.

## Options surveyed

| # | Approach | One-liner |
|---|---|---|
| 1 | Direct secondary reads (current plan) | `secondaryPreferred` to existing replica-set secondaries — no new infra |
| 2 | Atlas Analytics Node | Add a tagged member to each prod cluster; analytics reads pinned via `readPreferenceTags` |
| 3 | Hidden secondary (self-managed Mongo) | Same idea as #2 but for non-Atlas clusters — `hidden:true, priority:0, votes:0` + tag |
| 4 | Cluster-to-Cluster Sync (`mongosync`) | Mongo-provided BSON-level continuous sync to a separate cluster |
| 5 | Custom change-stream mirror | Tail `db.watch()` from a sync worker, replay into a separate cluster (Atlas or self-hosted) |
| 6 | Atlas Data Lake snapshot + Data Federation | Periodic cluster snapshot to S3-backed storage; query via Federation endpoint |
| 7 | Atlas Online Archive + Data Federation | Auto-tier *old* docs off the cluster to cheap storage; transparent federated read |
| 8 | Data Federation over the live cluster | Federation endpoint that proxies straight to the live cluster — no load shedding |
| 9 | CDC → external BigQuery warehouse | Stream Mongo changes into a shared BigQuery warehouse; query metrics there |

## Capability matrix

| | 1. Direct secondary | 2. Atlas Analytics Node | 3. Hidden secondary | 4. mongosync → separate cluster | 5. Custom change-stream mirror | 6. Data Lake + Federation | 7. Online Archive + Federation | 8. Federation over live | 9. CDC to BigQuery |
|---|---|---|---|---|---|---|---|---|---|
| **Load isolation from prod cluster** | none (shares secondaries with BFF) | logical (tag) — same cluster | logical (tag) — same cluster | physical (separate cluster) | physical (separate cluster) | physical (snapshot) | physical for cold rows only | none (passes through) | physical (separate system) |
| **Freshness** | real-time | real-time (oplog) | real-time (oplog) | real-time-ish (~sub-sec lag) | real-time-ish (~sub-sec, lag depends on worker) | snapshot cadence (≥hourly typ.; daily realistic) | real-time for hot, snapshot for cold | real-time | daily (warehouse refresh cadence) |
| **Indexes** | prod indexes | prod indexes | prod indexes | configurable on destination | configurable on destination | partition-level only; no native btree | hot tier yes, cold tier no | prod indexes (but only on `$match` stage) | configurable in BQ |
| **Per-account aggregation efficiency** | excellent (point lookups) | excellent (point lookups) | excellent (point lookups) | excellent if indexes copied | excellent if indexes copied | poor (scan-shaped) | excellent for 30d, poor for 12mo | degrades after `$match` | depends on BQ partitioning |
| **PII shaping at ingest** | no | no | no | limited (filter at sync; no transform) | yes (full control) | snapshot-time projection only | no | no | yes (transform in the CDC pipeline) |
| **Cross-cluster joins** | no | no | no | no | possible if both sources sync to one mirror | yes (the one real Federation win) | yes | yes | yes (BQ joins) |
| **Setup effort** | 0 | small (Atlas cluster config) | small (replica-set config) | medium (mongosync host + tuning) | medium-high (write sync worker, resume tokens, monitoring) | medium (snapshot schedule + endpoint) | small (UI toggle per collection) | small | high (stand up CDC streams, cross-team) |
| **Ongoing ops surface** | none new | none beyond Atlas | one extra Mongo node | mongosync process + lag monitor | sync worker + lag monitor + resume-token store | snapshot lifecycle, federation IAM | trivial | trivial | warehouse pipeline ownership |
| **Failure / drift risk** | nil | nil (replica-set guarantee) | nil (replica-set guarantee) | bounded by mongosync resume support; silent drift if not monitored | unbounded if resume tokens lost; can silently miss writes | snapshot can fail without alarm; per-cycle staleness | nil if Atlas-managed | nil | depends on CDC pipeline health |
| **Cold-start latency (first invoice → first score)** | ~2h | ~2h | ~2h | ~2h | ~2h | next snapshot (up to 24h) | ~2h (hot writes go to live) | ~2h | ~24h |
| **Covers PG eligibility probe** | no — separate PG conn | no | no | no | no | no | no | no | no |
| **Best fit scenario** | small scoped set, no BFF contention | BFF and analytics must not share secondaries | self-managed Mongo equivalent of #2 | want full physical isolation, no custom code | want isolation + ingest-time PII shaping or schema slimming | want batch sweeps, accept daily freshness | most reads are hot; cold rows rarely scanned | cross-source join in one MQL query | multi-analysis future, daily ok, share with BI |

## Pricing detail

### 1. Direct secondary reads
- **Incremental cost: $0.** Uses existing replica-set capacity.
- Hidden cost: extra throughput on the shared secondary tier could force a cluster size-up. At our budget (~1.2/s indexed) this is unlikely on either prod cluster.

### 2. Atlas Analytics Node
- Billed at the same per-hour rate as a regular cluster node of the same tier.
- Rough per-month per node (24×30 h): M10 ~$58, M20 ~$145, M30 ~$390, M40 ~$570, M50 ~$1,140.
- One node per cluster × two clusters → **2× the line item above**.
- No data-egress cost — traffic stays inside the Atlas VPC.
- Analytics-node tier can sometimes differ from the rest of the replica set; check current cluster tier before sizing.

### 3. Hidden secondary (self-managed)
- Whatever your IaaS bill is for one extra Mongo VM per replica set (EC2 / GCE + storage).
- Comparable $ shape to #2 once you add backup snapshots and monitoring.
- Only relevant if not on Atlas — otherwise #2 is the vendor-managed flavour of the same idea.

### 4. Cluster-to-Cluster Sync (`mongosync`)
- `mongosync` itself is free.
- You pay for (a) the **destination cluster** at full Atlas pricing — sized for mirrored data + indexes — and (b) the host running `mongosync` (small EC2 / K8s pod, usually <$50/mo).
- Cross-cluster network egress if source and destination cross AWS accounts / regions.
- Practical total = "another full Atlas cluster, possibly one tier smaller than prod". M30-equivalent ~$400/mo per source cluster → **~$800/mo for both prod Mongos**, plus sync hosts.

### 5. Custom change-stream mirror
- Same destination-cluster line item as #4: rough M30 equivalent ~$400/mo per source → **~$800/mo for both**.
- Sync worker: small pod on existing K8s, effectively $0 incremental.
- Real cost is engineering: ~1–2 weeks to build resume-token persistence, lag metrics, backfill, dead-letter handling, schema-evolution policy.

### 6. Atlas Data Lake snapshot + Federation
- Snapshot storage on S3-backed Atlas Data Lake: ~$0.10–$0.30/GB/mo (cheaper than Atlas cluster storage).
- Federation query cost: **~$5 per TB scanned** (region-dependent).
- Sample math at our scale: 11M invoices × ~1 KB hot fields ≈ ~11 GB hot snapshot. A daily sweep over the full snapshot scans 11 GB → ~$0.05/sweep → ~$1.50/mo. Cheap.
- But if you keep per-account aggregation × 100k accounts/day, Federation must read the relevant partition each time → effective scan multiplies. **The cost case only works if refresh flips to a single batched sweep per cycle.** That's an architecture change, not a swap.

### 7. Atlas Online Archive
- Storage ~$0.30/GB/mo on the archive tier (sometimes *more* per-GB than cluster tier — the point of Online Archive is freeing cluster IOPS, not saving on storage).
- Federated reads against archived data: same ~$5/TB scanned.
- Doesn't help here — windows are 30d/12mo, all hot.

### 8. Data Federation over the live cluster
- ~$5/TB scanned **on top of** existing cluster reads. Worse than direct secondary on every axis (cost, latency, prod load) unless you actually need cross-source `$lookup` in MQL.

### 9. CDC to BigQuery (external BigQuery warehouse)
- Detailed in [`metrics.md`](metrics.md) Option C. We'd pay BQ storage + slot/scan cost for new dbt models (cents/month at our row count) plus the cross-team cost of standing up the CDC streams.

## Common scenarios — pick by what you're trying to solve

| Scenario | Best fit | Why |
|---|---|---|
| "We just want to ship v1; BFF doesn't read those secondaries anyway." | **#1 Direct secondary** | $0 incremental, freshest, simplest. Watch Mongo dashboards post-launch; escalate only if real contention shows up. |
| "BFF reads those secondaries and we need hard isolation, but minimal new ops surface." | **#2 Atlas Analytics Node** | Logical isolation via tag, real-time, no sync code, ~$400–$600/mo per cluster. |
| "We want the metric layer physically separate from prod and isolated even from Atlas-project-level blast radius." | **#4 mongosync** (no custom code) or **#5 change-stream mirror** (if you also want PII-shaping / field filtering at ingest) | Physical separation, real-time, ~$800/mo for both clusters. #5 adds PII control at a 1–2-week engineering cost. |
| "Most of the metric reads are over old data that's rarely touched." | **#7 Online Archive** | Frees cluster IOPS for hot reads. *Not our case* — windows are 30d/12mo, all hot. |
| "We want batch sweeps over snapshots, fresh-enough is fine, and we don't want per-account targeted reads on Mongo at all." | **#6 Data Lake + Federation** | Daily snapshot, single-sweep refresh, predictable per-GB cost. Requires flipping the refresh model from per-account to batch. |
| "Multiple downstream analyses + BI need this data, daily freshness is fine, and we'd like one canonical warehouse." | **#9 CDC → BigQuery** | Amortises across all consumers in a shared BigQuery warehouse. |
| "We need to join two source clusters in one MQL pipeline." | **#8 Federation over live** | The one place Federation-over-live earns its keep. Not our use case in v1. |

## Staged recommendation for WEB-1523

1. **Inventory existing snapshots and add the `clients` snapshot.** Confirm what snapshot infrastructure already exists for `InvoicesCluster` and `Tofu.Invoices.Backend` Mongo: which collections, what cadence, what `_id` / partition layout, what storage backing. If `invoices`, `estimates`, `accounts` snapshots already exist, the v1 work is just adding `clients` to match. If snapshots are partial / missing, all four need to land.
2. **Verify snapshot windows cover the metric horizons.** FSM-fit metrics include 30d and 12mo windows on `invoices` and `estimates` (see [`../analyses/metrics.md`](../analyses/metrics.md) § Per-metric query plan). Snapshot retention must include both windows; daily snapshot cadence is acceptable since metrics refresh is hourly with 24h TTL.
3. **Provision the Mongo Data Federation endpoint** pointing at the snapshot storage; expose to `Tofu.AI.Api` via a single connection string. Collection names match the live cluster, so aggregation code in `IPayloadBuilder<T>` impls runs unchanged.
4. **Stage environment — wire `Tofu.AI.Api` to prod Mongo with a plain default connection string (as the other services use).** No Federation setup on stage, no enforced read preference. Stage's worker volume is low enough that the load is negligible against the prod cluster, and identical collection names mean the same code paths exercise the prod schema for end-to-end correctness testing.
5. **Add observability:** per-collection p95 read latency on the Federation endpoint, bytes-scanned-per-refresh-cycle (the cost driver), snapshot freshness lag (snapshot timestamp vs. wall clock), and the worker's `MaxConcurrentBatches` (4) × `AggregationBatchSize` (300) queue depth. Bytes-scanned in particular gates whether we stay on Option 6 or pivot to a batched-sweep / `account_metrics`-cache pattern.
6. **Only escalate to Option 2 / 4 / 5** if (a) Federation scan cost runs away after first-month measurement, (b) snapshot cadence proves too stale for a future analysis that needs <1h freshness, or (c) a security requirement demands a physically-separate read plane. The snapshot path is the v1 default until one of those triggers fires.
7. **Option 9 remains the long-horizon answer** for the multi-analysis future; revisit when ≥2 analyses share the metric layer and a 24h staleness budget is acceptable for them.

## Open questions

- [x] ~~Are the prod Mongo clusters Atlas-managed or self-hosted?~~ — **Resolved (2026-05-21):** Atlas, on GCP. Confirmed via the `InvoicesCluster` Atlas Metrics view.
- [x] ~~What is BFF's actual read preference on `InvoicesCluster`?~~ — **Resolved (2026-05-21):** secondaries are clearly serving reads (Max System CPU ~100–150% sustained on both `-00-00` and `-00-01`). This evidence drove flipping off direct-secondary reads; with Data Federation the question becomes moot (we don't touch the live cluster at all).
- [x] ~~v1 read plane choice (Analytics Node vs. Federation vs. mongosync)?~~ — **Resolved (2026-05-22):** Mongo Data Federation over snapshots. See `## Decision` above for the flip rationale.
- [ ] **Snapshot inventory.** Which collections already have snapshots configured against `InvoicesCluster` and `Tofu.Invoices.Backend` Mongo? What's the cadence (hourly / daily), what's the `_id` / partition layout, where do they land (GCS / S3 bucket)? Needed before scoping the `clients` snapshot work.
- [ ] **Snapshot window coverage.** Do existing snapshot retentions span the 30d and 12mo windows referenced in [`../analyses/metrics.md`](../analyses/metrics.md)? If retention is shorter, we either extend it or change the metric definition.
- [ ] **Federation scan-cost projection.** Per-account aggregation × ~100k accounts/day on Federation endpoints bills per TB scanned (~$5/TB region-dependent). Need a back-of-envelope on bytes-per-cycle before committing — if it's high enough to materially change the v1 cost profile, switch to a batched-sweep refresh that lands into `account_metrics` once and then reads from BQ.
- [ ] **Federation billing owner.** Data Federation scan + snapshot storage costs need a named owner. Likely the same owner as the BigQuery `ai_analysis_v2` dataset, but confirm.
- [ ] **Stage env conn-string ergonomics.** Stage `Tofu.AI.Api` connects to prod Mongo with a plain connection string. Verify the IAM / VPC path from stage cluster → prod Mongo is open (Atlas IP allowlist, GCP VPC peering, etc.) and that the read-only service account is provisioned. If not, stage falls back to a snapshot of its own, which adds setup work.

## Cross-references

- [`metrics.md`](metrics.md) — broader sourcing-category investigation (direct reads vs. event-sourced vs. DWH vs. Amplitude). This doc deep-dives the "direct reads" branch under the lens of prod-cluster isolation.
- [`postgres-read-isolation.md`](postgres-read-isolation.md) — Postgres-side counterpart for the eligibility-probe read path (`jobs.Jobs`). Same framework, smaller load, recommendation is a Cloud SQL read replica.
- [`../analyses/metrics.md`](../analyses/metrics.md) — locked per-metric query plan, eligibility funnel, refresh strategy. Read paths in this doc must not change those.
- [`../implementation/storage.md`](../implementation/storage.md) — BigQuery layout for `account_metrics` (the destination, unchanged by any option here).
