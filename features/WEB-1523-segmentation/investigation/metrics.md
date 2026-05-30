# WEB-1523 — Filling `account_metrics` — sourcing options

Investigation of the read-path options for populating the shared `account_metrics` BigQuery table that feeds every analysis (FSM-fit v1, then `churn_risk` / `suspicious_user` in v2).

The locked plan today (per [`../analyses/metrics.md`](../analyses/metrics.md) § Decision + [`../implementation/storage.md`](../implementation/storage.md)) is **direct Mongo aggregation reads from `Tofu.AI.Api`** to populate `account_metrics`. This doc is the prior exploration of *why that path*, what alternatives were considered, and what would have to change if we revisit.

> **As built (2026-05-27, WEB-1527).** The direct-Mongo path shipped: batched `$in` aggregations (`AggregationBatchSize`/`MaxConcurrentBatches`, not a per-account `MaxConcurrentAccounts`), the discovery sweep runs **every tick** (not daily), into dataset **`ai_analysis_v2`**. The discovery-cadence and knob wording below predate this — read it as research context.

> **Update (2026-05-24):** the PG `jobs.Jobs` batch probe discussed below as a "job-eligibility" step in the metrics funnel has since moved **out of metrics collection** into the FSM-fit **audience filter**, applied at scoring time by `AnalyzeFsmFitJob` — see [`../implementation/analyze.md`](../implementation/analyze.md) § Audience eligibility. `account_metrics` is now analysis-agnostic (no FSM-using gate). Read the PG-eligibility passages below as historical context; the connection still exists, just consumed by the analyze stage rather than the discovery sweep.

> Out of scope: the output schema (locked in `storage.md`), the per-metric query shapes (locked in `analyses/metrics.md`), and the LLM payload shape (locked in `privacy.md`). This doc is about *where the numbers come from*, not what they look like.

## TL;DR

| Option | What it is | v1 fit |
|---|---|---|
| **A. Direct Mongo + PG reads** (current plan) | `Tofu.AI.Api` opens read-only secondary connections to each source DB and runs per-account aggregations on demand. | **Locked.** Simplest producer surface, freshest signal, lowest contract churn. |
| B. Event-sourced metrics | Backend services emit domain events (invoice-created, estimate-converted, client-added, …); `Tofu.AI.Api` consumes and maintains its own materialised store keyed by `account_id`. | Deferred. Significant upstream work in `Invoices.Backend` / `Tofu.Invoices.Backend` before the producer can write a single row; benefits unlock at v2+ scale. |
| C. Read from a BigQuery DWH/mirror | Stand up Mongo streams into a shared BigQuery warehouse; aggregate in BQ; `Tofu.AI.Api` reads BQ instead of Mongo. | Rejected for v1. Daily staleness, PII-hashing on the invoice loader strips item text, cross-team coupling. |
| D. Amplitude events | Use the existing Amplitude product-analytics pipeline as the signal source for behavioural metrics. | Partial fit (behavioural cohort signals only); does not cover invoice/estimate/client structure. Candidate for v2 `churn_risk` and `activation`, **not** FSM-fit. |

See per-option detail below. Cross-reference: Amplitude event production from the BFF is referenced in [`../analyses/fsm-fit/analytics-events.md`](../analyses/fsm-fit/analytics-events.md) (write side) but not as an analysis input today.

## What `account_metrics` actually needs

The 12 fields that have to be filled per row, extracted from [`../analyses/metrics.md`](../analyses/metrics.md) § Per-metric query plan + [`../implementation/storage.md`](../implementation/storage.md) § Schemas:

| # | Metric | Source DB | Collection / Table | Source fields | Window | Aggregation |
|---|---|---|---|---|---|---|
| 1 | `business_name` | Mongo (Invoices.Backend) | `accounts` | `BusinessName` | n/a | direct projection on `_id` |
| 2 | `invoice_count_30d` | Mongo (Tofu.Invoices.Backend) | `invoices` | `AccountId`, `IsDeleted`, `Date` | 30d | `$sum: 1` |
| 3 | `avg_invoice_amount` | Mongo (Tofu.Invoices.Backend) | `invoices` | `TotalAmount` | 30d | `$avg` |
| 4 | `invoice_amount_variance_cv` | Mongo (Tofu.Invoices.Backend) | `invoices` | `TotalAmount` | 30d | `$stdDevPop / $avg` |
| 5 | `avg_line_items_per_invoice` | Mongo (Tofu.Invoices.Backend) | `invoices` | `Items` (`$size`) | 30d | `$avg` over `$size` |
| 6 | `repeat_customer_ratio` | Mongo (Tofu.Invoices.Backend) | `invoices` | `ClientId` / `Client.CatalogId`, `Date` | 12mo | group by client → share with `count ≥ 2` |
| 7 | `avg_days_between_repeats` | Mongo (Tofu.Invoices.Backend) | `invoices` | `ClientId` / `Client.CatalogId`, `Date` | 12mo | mean of consecutive-day diffs per repeat client |
| 8 | `estimate_to_invoice_rate` | Mongo (Tofu.Invoices.Backend) | `estimates` | `AccountId`, `IsDeleted`, `Date`, `InvoiceId` | 12mo | `count(InvoiceId IS NOT NULL) / total` |
| 9 | `estimate_count` | Mongo (Tofu.Invoices.Backend) | `estimates` | `AccountId`, `IsDeleted`, `Date` | 12mo | `$sum: 1` |
| 10 | `b2b_clients_present` | Mongo (Invoices.Backend) | `clients` | `Info[].Name`, `DeletedAt` | all-time alive | any regex match on `LLC\|Inc\|Corp\|Property Management\|LLP\|Ltd` |
| 11 | `multi_address_work` | Mongo (Invoices.Backend) | `clients` | `Info[].Address`, `DeletedAt` | all-time alive | distinct addresses ≥ 2 |
| 12 | `distinct_addresses` | Mongo (Invoices.Backend) | `clients` | `Info[].Address`, `DeletedAt` | all-time alive | `$setUnion` count after trim/lowercase |

**Eligibility gate** (not stored on the row — gates row creation, per [`../analyses/metrics.md`](../analyses/metrics.md) § Eligibility):

| Check | Source DB | Collection / Table | Source fields |
|---|---|---|---|
| Alive / non-technical | Mongo (Invoices.Backend) | `accounts` | `IsDeleted`, `IsTechnical` |
| Has invoiced in last 90d (proof-of-life) | Mongo (Tofu.Invoices.Backend) | `invoices` | `AccountId`, `Date`, `IsDeleted` (also drives the discovery sweep) |
| Has no recent jobs (invoice-only audience) | **Postgres** (Invoices.Backend, schema `jobs`) | `Jobs` | `AccountId`, `IsDeleted`, `CompletionTime` |

**Two source Mongos + one Postgres.** The metric columns themselves only touch Mongo; Postgres enters only through the eligibility probe. No metric depends on `Tofu.Auth.Backend`, Stripe, or any external service in v1.

Two characteristic properties drive sourcing:

1. **Entity-shaped, not event-shaped.** Most fields are aggregates over invoices / estimates / clients as they exist *now* (after edits, deletions, soft-deletes). Event streams would have to fold edit / delete events back into the aggregate.
2. **Item text is the load-bearing FSM-fit signal** — but `Items[]` text feeds the LLM payload (in `privacy.md`), not the metrics table. `account_metrics` only counts items (`avg_line_items_per_invoice`); the text path is separate. This matters because the warehouse invoice loader **MD5-hashes Client struct values**, which would not break metrics but would break the LLM payload — so even if metrics moved to BQ, the LLM payload would still need direct Mongo.

## Option A — Direct Mongo + PG reads (current plan)

**Shape.** `Tofu.AI.Api` runs the `MetricsRefreshJob` Hangfire cron; per refreshed account, it issues one aggregation pipeline per metric family against:

- `secondaryPreferred` on `Invoices.Backend` Mongo (`accounts`, `clients`).
- `secondaryPreferred` on `Tofu.Invoices.Backend` Mongo (`invoices`, `estimates`).
- Read-only PG on `Invoices.Backend` (`jobs.Jobs` for eligibility).

Detail in [`../analyses/metrics.md`](../analyses/metrics.md).

**Why it won v1.**

- **Zero new producer-side contracts.** No RPCs in `Invoices.Backend` / `Tofu.Invoices.Backend` to maintain — every new metric or rule-weight tweak stays inside `Tofu.AI.Backend`.
- **Freshness.** Cold-start latency ≈ 2h from first invoice to first `v_fsm_fit` row. Event-sourced and DWH paths can't match this without change-stream or per-tick reload plumbing.
- **PII control.** The Worker reads raw `Items[]` text, then hands it to the redaction layer locally — no upstream hashing.
- **Index economics.** Per-account queries fit on existing `ix_invoices.accountid.date.createdtime` / `ix_estimates.accountid.date.createdtime` / `ix_clients.accountid` indexes; one new partial index unlocks the daily discovery sweep.

**Risks / what it imposes.**

- **Cross-DB read coupling.** `Tofu.AI.Api` knows three connection strings (two Mongo, one PG) and must track schema drift in each. Mitigated by reading only stable fields (`AccountId`, `Date`, `TotalAmount`, `IsDeleted`, `Items.$size`, `ClientId`) — no surprise migrations on hot fields in the last 12 months.
- **Live-cluster read load avoided.** ~1.2/s sustained per-account aggregations at ~100k scored accounts. The `InvoicesCluster` (M30, GCP us-east1) Atlas dashboard as of 2026-05-21 shows both secondaries already running Max System CPU ~100–150% sustained — landing this load on the live cluster is unsafe. **The locked Option A query shape is unchanged, but in prod it runs against the Mongo Data Federation endpoint backed by periodic snapshots, not the live secondaries** (collection names match, so query code is identical). Stage uses a plain default connection to prod Mongo (as the other services), since stage volume is negligible. See [`mongo-read-isolation.md`](mongo-read-isolation.md) § Decision.
- **Eligibility funnel touches PG.** Adds a second connection class to maintain. Acceptable because the PG probe is batched (10k AccountIds per query) and only runs on the daily discovery sweep, not per-refresh.

## Option B — Event-sourced metrics

**Shape.** Upstream services emit domain events on every state change to the entities `account_metrics` cares about — invoice created / edited / deleted / paid, estimate created / converted, client added / removed, account profile updated. `Tofu.AI.Api` subscribes and folds events into a local materialised table (PG schema `analyses.metric_state` or similar), then projects into BQ on the same `MetricsRefreshJob` schedule.

**Where the events would come from.**

- Need to confirm the current production state. The architecture refers to "domain events" in several places (e.g. job analytics events in `Invoices.Backend/Src/Jobs/`), but there is **no general invoice / estimate / client event bus today** that the producer could plug into. Building one is a `Tofu.Invoices.Backend` + `Invoices.Backend` change, not a `Tofu.AI.Backend` change.
- Existing analytics events (Amplitude — see Option D) are *product* events (user clicked, screen viewed), not entity-state events, and would not cover the aggregations FSM-fit needs.

**Pros.**

- **Decouples the producer.** Once events flow, `Tofu.AI.Api` no longer holds Mongo / PG credentials for upstream DBs.
- **Replayable.** Backfills, re-shaped metrics, and v2 analyses can replay from the event log without re-querying source DBs.
- **Lower steady-state read load** on Mongo secondaries — folding the event stream is cheaper than per-account aggregation × 100k/day.
- **Fits the v2 catalogue better.** `churn_risk` (login / session signal) and `suspicious_user` (per-`platform_user_id` activity) are naturally event-shaped; aggregating those over Mongo requires hitting more collections and an `auth` DB the producer does not own today.

**Cons.**

- **Massive upstream prereq.** Producer side has to define the event schema, emit reliably (outbox or change-stream), and back-fill history before any v1 row can be written. This is weeks-to-months of work in `Invoices.Backend` / `Tofu.Invoices.Backend`, gated by their roadmaps — not by ours.
- **Fold semantics for soft-deletes and edits.** `Items[]` is an array; mutating one element fires "invoice edited" with no easy delta. Either every edit re-emits the full invoice (large), or the consumer reconstructs the entity from a partial event (fragile).
- **Schema versioning.** New metric → new event field → producer schema change. Same cross-repo churn we said direct reads avoid, just shifted to a contract surface instead of a query surface.
- **Cold-start regression.** No event log replay = no historical metrics. The current direct-read path scores any active account on its first refresh tick; an event-only path scores only accounts that have been active since the event bus came online.

**Verdict.** Don't block v1 on this. Revisit after v2 lands and we have ≥3 analyses sharing the metric layer — the event bus prereq amortises across analyses, not just FSM-fit.

## Option C — Read from a BigQuery DWH/mirror

**Shape.** Stand up Mongo streams (the `invoices`, `estimates`, `clients`, `accounts` loaders) into a shared BigQuery warehouse. Aggregate in BQ via dbt models. `Tofu.AI.Api` then reads finished metrics from BQ instead of Mongo.

**Pros.**

- **No new connection classes** in `Tofu.AI.Backend` — only the BQ client it needs anyway for writes.
- **Aggregation in BQ scales arbitrarily** — dbt models replace the Hangfire per-account aggregation loop.
- **Joinable with other warehouse data** keyed by `account_id ↔ user_id`. Could enable cross-cohort analyses cheaply.

**Cons.**

- **Daily staleness.** A daily warehouse refresh moves cold-start latency from ~2h to ~24h. Below the proposal-surface SLA.
- **PII hashing on the invoice loader.** The invoice stream MD5-hashes Client struct values on write. Doesn't affect `account_metrics` directly (we don't store Client fields there), but it shows the loader's PII regime is owned by the warehouse pipeline and not under our control — a future metric needing raw client data would force re-coordination.
- **Cross-team coupling.** Standing up and maintaining the streams is a warehouse-owner conversation, not a `Tofu.AI.Backend` decision.
- **Doesn't help the LLM payload path.** Direct Mongo reads are still needed for the redacted-text payload regardless, so this option *adds* a second read path rather than replacing the first.

**Verdict.** Rejected for v1. Worth keeping warm as a fallback if direct Mongo reads start contending with BFF traffic at scale, but the daily-staleness regression alone disqualifies it from the proposal-surface use case.

## Option D — Amplitude events

**Shape.** Use the existing Amplitude pipeline (surfaced in the warehouse as `amplitude_users_in_experiments_clean`) as a signal source.

**What Amplitude can give us.**

- User-level session, screen, and tap events keyed by `user_id`.
- Funnel and retention signals (last-active, days-active-in-last-30, feature-touch rates).
- Experiment-cohort membership.

**What Amplitude cannot give us.**

- Anything entity-shaped — no invoice totals, no item counts, no client struct, no estimate conversion. Amplitude tracks *behaviour*, not *data*.
- Aggregations over soft-deletable entities (it has no concept of "deleted invoice").
- The FSM-fit prompt payload itself (item text, business name) — Amplitude doesn't carry it.

**v1 (FSM-fit) fit.** Poor. None of the 11 `account_metrics` fields can be filled from Amplitude alone.

**v2 fit.** Stronger for `churn_risk` — login recency, session frequency, last-feature-touch are exactly Amplitude's shape. Worth a focused investigation when `churn_risk` lands; not relevant for FSM-fit.

**One viable hybrid for v1.** `business_name` lives on `accounts.BusinessName` (Mongo). Everything else on `account_metrics` is structural. Amplitude buys us nothing here.

**Verdict.** Park until v2 `churn_risk` planning. Logged as "candidate behavioural input for v2" — not committed.

## Cross-option comparison

| Concern | A. Direct Mongo+PG | B. Event-sourced | C. BQ warehouse (DWH) | D. Amplitude |
|---|---|---|---|---|
| Time to first `account_metrics` row | days | months | weeks | n/a (insufficient signal) |
| Cold-start latency (first invoice → score) | ~2h | event-bus-dependent | ~24h | n/a |
| New cross-repo contracts | 0 | event schema × N services | stand up warehouse streams | none net-new (Amplitude already prod) |
| Producer-side read load | Mongo secondaries, PG | event broker | none on Mongo | none on Mongo |
| PII control | local | depends on event schema | hashing owned by the warehouse pipeline | event-set-determined |
| Replay / backfill | re-run aggregation | event log replay | re-run dbt | Amplitude retention window |
| v2 analyses fit | ok (more Mongo collections) | great | partial | great for `churn_risk` |

## Recommendation

Stay on **Option A** for v1; revisit after v2 launches and we have evidence on:

1. Whether secondary read load is actually visible on `Tofu.Invoices.Backend` Mongo dashboards under steady state (if no — direct reads are uncomplicated forever; if yes — Option B amortises better with multiple analyses).
2. Whether `churn_risk` proposed payload pulls enough Amplitude signal to justify wiring it as a second input channel — if so, Option D becomes a real piece of the architecture rather than a parked candidate.
3. Whether a warehouse owner has a use case to stand up the Mongo streams independent of WEB-1523 — if so, Option C becomes cheaper for us and worth re-evaluating for the v2 metrics that don't need sub-day freshness.

## Open questions

- [ ] **Is there a Tofu-wide domain-event bus today?** Job analytics events exist in `Invoices.Backend/Src/Jobs/`, but I have not confirmed whether invoice / estimate / client mutations emit events on a shared broker. If they do, Option B's prereq cost drops sharply and the verdict should be re-run.
- [ ] **Does Amplitude carry account-keyed events** (vs only user-keyed)? Affects how cleanly Amplitude data would join `account_metrics` for any future hybrid metric.
- [ ] **What does the `amplitude_users_in_experiments_clean` schema look like for invoice apps?** First step before Option D can be evaluated for `churn_risk` — list the actual event names + properties that arrive for `invoices` / `invoices_android` / `tofu_web` audiences.
