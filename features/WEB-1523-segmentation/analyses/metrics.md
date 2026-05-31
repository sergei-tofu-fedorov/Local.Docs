# WEB-1523 — Backend metrics collection (Mongo → `account_metrics`)

> **✅ Shipped as WEB-1527 — read the as-built deltas.** This is the metric/query **spec**; the implementation is in [`../implementation/metrics.md`](../implementation/metrics.md). Three forms below differ from what shipped: (1) the per-metric pipelines are shown in **single-account** form (`AccountId: @account_id`, `$group _id: null`), but the code runs the **batched group-by-account** form (`$match {AccountId: {$in: batch}}` → `$group _id: "$AccountId"`) — same logic, one query per *batch* of ~300 accounts, not per account; (2) **discovery runs every tick**, not once per UTC day; (3) `account_metrics` is **account-only** (single `account_id` column) — the three-subject-level model and the `analyzed_at` column were dropped. Dataset is **`ai_analysis_v2`**.

How `MetricsRefreshJob` populates the shared `account_metrics` table by querying the workspace's Mongo collections. Defines source collections, eligibility filters, the `expires_at`-driven candidate selection loop, and a per-metric query plan for the 8 numeric metrics + 2 derived booleans + `distinct_addresses` + `business_name` columns committed in [`../implementation/storage.md`](../implementation/storage.md) § Schemas.

> **Out of scope here.** The output schema (column names, types, partition / cluster keys) is locked in `storage.md`. The downstream LLM payload shape is locked in [`../investigation/privacy.md`](../investigation/privacy.md) § 1. This doc covers only the *read path* from Mongo into the typed columns.

> **Scale baseline (2026-05-20).** ~5M total accounts and ~11M invoices in Mongo backing stores; the three metrics-collection gates (§ Eligibility) leave on the order of **~100k+ accounts with an `account_metrics` row** (invoice-active accounts). Note `account_metrics` now includes FSM-using accounts — the ~100k invoice-only figure is the FSM-fit *scored* subset *after* the analyze-stage audience filter, so the `account_metrics` set is a superset of it. All throughput, refresh, and cost numbers below are sized to the `account_metrics` set — not to the 5M backing-store total. The 50k-subject figure used elsewhere in this folder (`storage.md:203`, `provider.md` § Decision) predates this calibration and should be read with the same correction in mind.

## Decision

- **Two-source read via Mongo Data Federation (prod) / plain default connection (stage).** Logical sources are **two databases**: `Invoices.Backend` Mongo (accounts, clients) and `Tofu.Invoices.Backend` Mongo (invoices, estimates). In **prod**, `Tofu.AI.Api` (Hangfire jobs in-process — single-pod design, see [`../implementation/service.md`](../implementation/service.md) § Decision) reads via a Mongo Data Federation endpoint backed by periodic snapshots of those four collections — prod replica sets are not touched. In **stage**, the same code reads directly from the live prod Mongo clusters via a plain default connection (collection names match, so only the connection string differs by env). No new gRPC contracts. Rationale and rejected alternatives in [`../investigation/mongo-read-isolation.md`](../investigation/mongo-read-isolation.md) § Decision.
- **Candidate selection — two-track.** Re-refresh of already-collected accounts driven by `expires_at < NOW()` on the BQ `account_metrics` table. Discovery of net-new candidates driven by an indexed sweep over `invoices` (`CreatedTime`-leading partial index, added in this feature), not by scanning `accounts`. **(As built the discovery sweep runs every tick — idempotent + cheap — not once per day.)**
- **Batched aggregation pipelines.** One Mongo aggregation per metric family **per batch** of ~`AggregationBatchSize` accounts (`$match {AccountId: {$in: batch}}` → `$group _id: "$AccountId"`), pushed server-side, fanned out concurrently across families. C# composes the 11 numeric/boolean output fields per account from the per-account result docs. Item counts and group-by-client live inside the pipeline; nothing meaningful happens in C# beyond shaping the upsert rows. (The single-account `_id: null` form in § Per-metric query plan is illustrative of one account's slice of each batched pipeline.)
- **30-day rolling window** for activity-windowed metrics (`invoice_count_30d`, `avg_invoice_amount`, etc.). Window is `analyzed_at - 30d ≤ Date < analyzed_at`, anchored on `analyzed_at` so re-reads are stable until the next refresh.
- **`RefreshTtl = 24h`** (the `MetricsRefreshJob.RefreshTtl` value referenced in `storage.md:96`). Configurable per-deploy via `Analyses:Metrics:RefreshTtl`.
- **Eligibility filter — alive, non-technical, invoice-active** (see § Eligibility). `account_metrics` is analysis-agnostic and does **not** exclude FSM-using accounts **nor gate on account age** — both are FSM-fit *audience* decisions applied at scoring time, see [`../implementation/analyze.md`](../implementation/analyze.md) § Audience eligibility. (FSM-fit drops FSM-using accounts and accounts created ≤ 90 days ago from its scored set; neither affects which accounts get an `account_metrics` row.)
- **No incremental field-level updates.** Each refresh upserts the full row. CDC ingestion (`_CHANGE_TYPE = 'UPSERT'`) handles the merge in BQ.

## Sources

| Collection | DB | Repo of record | Fields read |
|---|---|---|---|
| `accounts` | Invoices.Backend Mongo | `Invoices.Backend` | `_id`, `BusinessName`, `IsDeleted`, `IsTechnical`, `SchemaVersion`, `CreatedTime` |
| `clients` | Invoices.Backend Mongo | `Invoices.Backend` (`ManageableClient`) | `AccountId`, `Info[].Name`, `Info[].Address`, `DeletedAt` (nullable DateTime; `DeletedAt = null` ⇒ alive) |
| `invoices` | Tofu.Invoices.Backend Mongo | `Tofu.Invoices.Backend` | `AccountId`, `Date`, `TotalAmount`, `Items[]` (`$size`), `ClientId` / `Client.CatalogId`, `IsDeleted`, `Status` |
| `estimates` | Tofu.Invoices.Backend Mongo | `Tofu.Invoices.Backend` | `AccountId`, `Date`, `InvoiceId`, `IsDeleted` |

**Why Mongo direct and not gRPC.** Adding metric-aggregation RPCs across `Invoices.Backend` + `Tofu.Invoices.Backend` would be a high-churn contract surface — every new analysis or rule-weight tuning iteration would ripple through two repos. Direct Mongo reads (via Federation in prod, a plain connection in stage) keep the producer surface inside `Tofu.AI.Backend` only; the read pattern is heavy aggregation, which Mongo's aggregation framework handles natively. The Federation endpoint in prod removes the live-cluster load question entirely (we don't touch the cluster).

**`IsDeleted` is nullable on `invoices` and `estimates`.** Match the existing `InvoicesRepository.cs:22` pattern — `IsDeleted IN (false, null)`, never `IsDeleted = false`. Older documents predate the field.

**`clients` uses `DeletedAt`, not `IsDeleted`.** The `ManageableClient` model in `Invoices.Backend` carries a nullable `DateTime DeletedAt` (confirmed by `ix_clients.accountid.deletedat.infoname.clientid_en`). Filter shape is `DeletedAt: null` or `{ $exists: false }`. Do not import the invoice/estimate `IsDeleted` shape here.

**FSM usage is in Postgres, not Mongo — and it is not a metrics-collection source.** Whether an account uses FSM is read from `Job` / `JobEvent` in `Invoices.Backend`'s PG schema `jobs` (`Src/Jobs/Jobs.Infrastructure/Database/JobsDbContext.cs:8` — EF Core `DbContext`; `data-sources.md:201` has this slightly muddled). But that read belongs to the FSM-fit **audience filter**, not to `account_metrics` population — see [`../implementation/analyze.md`](../implementation/analyze.md) § Audience eligibility. Metrics collection reads only the four Mongo collections above.

## Eligibility — which accounts get a `account_metrics` row

`account_metrics` is **analysis-agnostic**. A row is created for an account if **all** hold:

1. `Account.IsDeleted IN (false, null)`
2. `Account.IsTechnical = false`
3. At least one non-deleted `Invoice` in the last 90 days (proof-of-life; rules out abandoned accounts)

> **Account maturity is *not* a metrics gate.** An earlier revision listed a 4th condition ("account created > 90 days ago"). It was **moved to the FSM-fit audience filter** — applied at scoring time inside `AnalyzeFsmFitJob`, alongside the FSM-using exclusion — see [`../implementation/analyze.md`](../implementation/analyze.md) § Audience eligibility § Account-maturity gate. Rationale: `account_metrics` is analysis-agnostic, so gating row creation on age would wrongly starve other analyses (e.g. `churn_risk`) of young-account rows. The ClickUp source placed "старше 3 месяцев" under *Сбор метрик*, but it is a per-analysis audience decision and lives with the analysis. Threshold: uniform **90 days** (`Analyses:FsmFit:MinAccountAgeDays`, default `90`).

These are cheap, single-store (Mongo) gates. There is deliberately **no FSM-using-account gate here** — `account_metrics` holds rows for FSM users too. Whether an account is *scored* for a given analysis is that analysis's audience decision: FSM-fit excludes FSM-using accounts at scoring time via a PG batched query against `Invoices.Backend`'s `jobs.Jobs`, documented in [`../implementation/analyze.md`](../implementation/analyze.md) § Audience eligibility. It does not gate row creation.

Condition 3 is evaluated by the Mongo discovery sweep itself (§ Refresh strategy, step 2) — a `$match` on `Date >= now-90d` over `invoices` is exactly the gate. Conditions 1–2 (alive, non-technical) are evaluated via a batched `accounts` lookup against the discovery survivors — both read straight from the `accounts` doc (`IsDeleted` / `IsTechnical`, listed in § Sources). They are not stored on `account_metrics` — they only gate row creation. (`AccountDiscovery.FilterEligibleAsync` applies exactly these two; the account-maturity gate is **not** here — it's an FSM-fit audience filter, see above.) An account that drops out of eligibility (e.g., goes dormant — no invoices for 90 days) stops being refreshed; its old `account_metrics` row ages out via the BQ partition retention path (when configured) and disappears from `v_fsm_fit` joins for cold-start accounts via the `LEFT JOIN m → f` shape (`storage.md:188`).

**Subject-key population.** As built, `account_metrics` has a single `account_id STRING NOT NULL` key — the three-subject-level model (`master_user_id` / `platform_user_id` / `account_id`) was dropped before implementation (see [`../implementation/storage.md`](../implementation/storage.md) § Subject identity). FSM-fit is account-level, so this loses nothing for v1. A v2 per-user analysis (`suspicious_user` is per-`platform_user_id`) would add its user-keyed metrics in a **separate** table rather than reintroducing nullable subject columns here.

## Refresh strategy — `expires_at`-driven loop

`MetricsRefreshJob` runs hourly (Hangfire cron `0 * * * *`). Each tick:

1. **Expired-row pass.** Query BQ (`GetExpiredAsync`):
   ```sql
   SELECT account_id
   FROM `<project>.ai_analysis_v2.account_metrics`
   WHERE expires_at < CURRENT_TIMESTAMP()
   ORDER BY expires_at
   LIMIT @batch_size            -- ExpiredScanBatchSize, default 500
   ```
   Each returned `account_id` is enqueued for refresh.
2. **Discovery pass** (runs **every tick**, after the expired-row pass — see the as-built note; the original once-per-UTC-day guard was dropped as unnecessary). One indexed sweep over `invoices` returns the active-account set:
   ```js
   db.invoices.aggregate([
     { $match: { CreatedTime: { $gte: ISODate(<now - 90d>) },
                 IsDeleted:   { $in: [false, null] } } },
     { $group: { _id: "$AccountId" } }
   ])
   ```
   Backed by the `invoices.{CreatedTime: 1}` partial index added in this feature (`partialFilterExpression: {IsDeleted: {$in: [false, null]}}`). Scans the ~3M-doc recent slice in 1–3 min on a secondary. Output is the **~200–500k account ids** that have invoiced in the last 90 days.

   From there:
   - **BQ `EXCEPT`** against the existing `account_metrics.account_id` column isolates net-new candidates (already-collected accounts get re-refreshed via the `expires_at` path in step 1, not discovery).
   - **Batched `accounts` lookup** in Mongo applies the remaining § Eligibility checks (alive, non-technical).

   Net-new survivors are enqueued for refresh. There is no FSM-using-account trim in discovery — `account_metrics` covers FSM users too; the exclusion is an FSM-fit audience filter applied at scoring time (see [`../implementation/analyze.md`](../implementation/analyze.md) § Audience eligibility).
3. **Aggregation.** The enqueued `account_id`s are chunked into batches of `AggregationBatchSize` (default 300) and processed with `Parallel.ForEachAsync` at `MaxConcurrentBatches` (default 4) concurrency. Per batch, the four metric-family pipelines below run concurrently in their batched `$in`/group-by-account form, compose one `AccountMetricsRow` per account, and UPSERT into BQ via Storage Write API CDC in one append. `expires_at = analyzedAt + RefreshTtl` (one `analyzedAt` anchor for the whole tick); `updated_at` is stamped per batch at write time. **There is no `analyzed_at` column** — `analyzedAt` is only the in-memory window/expiry anchor.

**Idempotency.** A refresh that crashes mid-batch leaves the previous row's `expires_at` intact — the next tick picks it up again. CDC ingestion is upsert by primary key, so a duplicate refresh just overwrites the same row.

**Cold-start latency.** A net-new account is discoverable on the next hourly tick after its first invoice, then scored on the next FSM-fit `AnalyzeJob<FsmFit>` tick (per-analysis cron, see `service.md`). Cold-start P95 is ~2 hours from first invoice to first `v_fsm_fit` row, which is below the in-app proposal-surface latency budget. Tightening this would mean Mongo change-stream wiring — deferred to v2.

## Per-metric query plan

Each query below runs against the Mongo Data Federation endpoint in prod, or a plain default connection to prod Mongo in stage — collection names and field shapes are identical between the two, so query code is unchanged. The 11 outputs go into the upsert row in one batch.

### `business_name` (denorm)
Direct `accounts._id = @account_id` projection. Single-doc read, no aggregation. NULL on user-keyed rows (n/a for v1 which only writes account-keyed rows).

### `invoice_count_30d`, `avg_invoice_amount`, `invoice_amount_variance_cv`
One aggregation over `invoices`:
```js
db.invoices.aggregate([
  { $match: {
      AccountId: @account_id,
      IsDeleted: { $in: [false, null] },
      Date: { $gte: @windowStart, $lt: @windowEnd }
  }},
  { $group: {
      _id: null,
      count: { $sum: 1 },
      mean:  { $avg: "$TotalAmount" },
      sd:    { $stdDevPop: "$TotalAmount" }
  }},
  { $project: {
      _id: 0,
      invoice_count_30d: "$count",
      avg_invoice_amount: "$mean",
      invoice_amount_variance_cv: {
        $cond: [ { $gt: ["$mean", 0] }, { $divide: ["$sd", "$mean"] }, null ]
      }
  }}
])
```
`@windowStart = analyzed_at - 30d`, `@windowEnd = analyzed_at`. `$stdDevPop` (not `$stdDevSamp`) — we're describing the observed window, not estimating a population. Empty window → `null` for all three (FSM-fit prompt tolerates nulls; see `fsm-fit/scoring.md` § payload schema).

### `avg_line_items_per_invoice`
Same `$match` as above, then `$project` `lineCount: { $size: { $ifNull: ["$Items", []] } }`, then `$group: { _id: null, avg_line_items_per_invoice: { $avg: "$lineCount" } }`. Folded into the same pipeline as the amount stats — one round-trip per account.

### `repeat_customer_ratio`, `avg_days_between_repeats`
One pipeline over `invoices`, grouped twice:
```js
db.invoices.aggregate([
  { $match: { /* same as above, but no 30d window — use last 12mo for repeat signal */ } },
  { $sort: { ClientId: 1, Date: 1 } },
  { $group: {
      _id: "$ClientId",
      invoiceCount: { $sum: 1 },
      gaps: { $push: "$Date" }
  }},
  { $project: {
      _id: 1,
      isRepeat: { $gte: ["$invoiceCount", 2] },
      gapDays: {
        $cond: [
          { $gte: ["$invoiceCount", 2] },
          { /* mean of consecutive-day diffs in $gaps */ },
          null
        ]
      }
  }},
  { $group: {
      _id: null,
      total: { $sum: 1 },
      repeatCount: { $sum: { $cond: ["$isRepeat", 1, 0] } },
      meanGap: { $avg: "$gapDays" }
  }},
  { $project: {
      repeat_customer_ratio: { $divide: ["$repeatCount", "$total"] },
      avg_days_between_repeats: "$meanGap"
  }}
])
```
**Why 12-month window** (not 30d): a repeat-client signal needs enough history to observe a second visit; the 30d window starves the signal. The 8 invoice-volume metrics stay 30d (current activity intensity); repeat signals look further back.

`ClientId` reference: `invoices.ClientId` for legacy docs; `invoices.Client.CatalogId` for newer ones (per `InvoicesRepository.cs:24`). Use `$ifNull` to coalesce both before the `$group`. If both are null on a row (walk-in / no-client invoice), exclude from the repeat-ratio denominator.

### `estimate_to_invoice_rate`, `estimate_count`
One aggregation over `estimates`:
```js
db.estimates.aggregate([
  { $match: {
      AccountId: @account_id,
      IsDeleted: { $in: [false, null] },
      Date: { $gte: @windowStart12mo, $lt: @windowEnd }
  }},
  { $group: {
      _id: null,
      total: { $sum: 1 },
      converted: { $sum: { $cond: [ { $ne: ["$InvoiceId", null] }, 1, 0 ] } }
  }},
  { $project: {
      estimate_count: "$total",
      estimate_to_invoice_rate: {
        $cond: [ { $gt: ["$total", 0] }, { $divide: ["$converted", "$total"] }, null ]
      }
  }}
])
```
`null` rate when the account uses no estimates — the LLM treats null as "no signal" rather than "0% conversion". 12-month window for the same reason as repeats — conversion semantics need history.

### `b2b_clients_present`, `multi_address_work`, `distinct_addresses`
One aggregation over `clients`. Regex match per `fsm-fit/scoring.md:101` (`LLC|Inc|Corp|Property Management|LLP|Ltd`, case-insensitive):
```js
db.clients.aggregate([
  { $match: { AccountId: @account_id, DeletedAt: null } },
  { $project: {
      isB2B: { /* regex match on Info[].Name; $anyElementTrue over $map */ },
      addresses: {
        $filter: {
          input: "$Info.Address",
          cond: { $and: [ { $ne: ["$$this", null] }, { $ne: ["$$this", ""] } ] }
        }
      }
  }},
  { $group: {
      _id: null,
      b2b_clients_present: { $max: { $cond: ["$isB2B", 1, 0] } },   // any → 1
      distinct_addresses:  { $addToSet: "$addresses" }              // flattened in $project below
  }},
  { $project: {
      b2b_clients_present: { $eq: ["$b2b_clients_present", 1] },
      distinct_addresses_count: {
        $size: { $reduce: { input: "$distinct_addresses", initialValue: [], in: { $setUnion: ["$$value", "$$this"] } } }
      },
      multi_address_work: { /* count ≥ 2 */ }
  }}
])
```
Address normalisation (trim, lowercase, collapse whitespace) happens **inside the pipeline** via `$trim` / `$toLower` before the `$setUnion`, so "123 Main St" and "123 main st  " count as one. Empty / null addresses are filtered before counting.

## Performance budget

At ~100k+ `account_metrics` accounts (invoice-active accounts, filtered from 5M backing-store accounts), 24h `RefreshTtl`:

- **Re-refresh load** — 100k/day ÷ 24h ≈ **4,200/hour ≈ 1.2/s** sustained. Batched at `AggregationBatchSize = 300` with `MaxConcurrentBatches = 4` (~4 reads + 1 write per batch), there's ample headroom; the in-process Hangfire server inside `tofu-ai-api-deployment` (2 replicas, distributed lock serialises the recurring tick) absorbs this comfortably.
- **Per-account aggregation footprint** — average ~110 invoices per active account (11M / ~100k). A 30d window touches ~30 invoices; a 12mo window ~110. Each pipeline runs in single-digit ms once the index hits.
- **Discovery sweep** — ~3M-doc partial scan once daily. With the new `invoices.{CreatedTime: 1}` partial index: **1–3 min on a secondary**. Without it: 10–30 min (acceptable fallback if the index ships late).

(The PG eligibility-probe budget moved with the FSM audience filter — see [`../implementation/analyze.md`](../implementation/analyze.md) § Audience eligibility.)

**What would break this.** A sudden 10× growth in eligible-account count would push refresh load to ~12/s and start contending with the discovery sweep. The levers are `MaxConcurrentBatches` (raise from 4) and `AggregationBatchSize`. Beyond that, lengthen `RefreshTtl` to 48h or 7d (signal drift on FSM-fit inputs is weekly+, not daily), or re-throttle discovery to less-than-every-tick. A heavy-volume account (1000+ invoices/month) inflating the per-batch `$group` working set is mitigated by `AllowDiskUse = true`, set on every collector aggregation (`MongoConventions.Aggregate`).

## Index audit

**Existing indexes — all per-account queries are covered:**

| Query | Covering index | Defined in |
|---|---|---|
| Invoice metrics (count / avg / CV / items / repeats) | `ix_invoices.accountid.date.createdtime` (`AccountId, IsDeleted, Date, CreatedTime`) | `Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Database/MongoDbContext.cs:60` |
| Estimate metrics | `ix_estimates.accountid.date.createdtime` | same file:85 |
| Client B2B / address signals | `ix_clients.accountid` (simple) or `ix_clients.accountid.deletedat.infoname.clientid_en` (richer) | `Invoices.Backend/Src/Invoices.Implementation.MongoDb/Repositories/Shared/MongoDbContext.cs:317–333` |
| `business_name` lookup | `accounts._id` (default) | n/a |

**New index added by this feature** — `invoices.{CreatedTime: 1}` with `partialFilterExpression: {IsDeleted: {$in: [false, null]}}`, added to the existing `Configure(...)` block in `Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Database/MongoDbContext.cs`. Estimated index size at 11M docs: ~150 MB. Justification: drops the daily discovery sweep from 10–30 min to 1–3 min on a secondary, and unblocks any future analysis that needs a time-windowed `invoices` scan (the framework is multi-analysis by design — `churn_risk`, `suspicious_user` will both want it).

**PG side.** The FSM-using exclusion's `jobs.Jobs.{AccountId}` index requirement moved with the audience filter — see [`../implementation/analyze.md`](../implementation/analyze.md) § Audience eligibility § Cross-repo prerequisites. Metrics collection touches no Postgres.

## Open questions

- [ ] **Eligibility funnel actuals** — pin two numbers against a prod secondary before deploy: the **invoice-active** count (sizes the `account_metrics` refresh load — this stage's budget) and the **invoice-only** subset (the FSM-fit scored audience after the analyze-stage filter). The ~100k estimate was for invoice-only; the `account_metrics` count is the larger invoice-active figure. If invoice-active is materially higher than expected (>500k), revisit `RefreshTtl` and `MaxConcurrentAccounts`.
- [x] ~~**`CreatedTime` vs `Date` for the discovery sweep**~~ **Decided (as built): `CreatedTime`** (system-set, monotonic — backed by the `invoices.{CreatedTime:1}` partial index), with an inline comment in `AccountDiscovery.SweepActiveAccountsAsync` flagging the back-dated-invoice trade-off. Switch the index to `{Date:1}` only if missed back-dated invoices prove material.
- [ ] **Address normalisation** — current plan trims + lowercases. Real-world addresses ("123 Main St" vs "123 Main Street") will over-count `distinct_addresses`. PM-decision whether to invest in canonicalisation (libpostal / Google Geocoding) for v1 or accept the over-count.
- [ ] **Window length for repeat signals** — 12 months chosen by analogy to typical FSM contract cadence. The MAIN-1361 exports used a different window; reconcile with Phase A½ validation results before locking.
- [x] ~~**Account-age gate (condition 4)**~~ — **relocated** to the FSM-fit *audience* filter (it is not a metrics gate). Threshold **90 days** (`Analyses:FsmFit:MinAccountAgeDays`, default `90`); the account-age source (add `account_created_at` to `account_metrics` vs read `accounts.CreatedTime` at analyze time) and null-`CreatedTime` handling (treat as eligible — pre-dates the field) are tracked in [`../implementation/analyze.md`](../implementation/analyze.md) § Audience eligibility § Account-maturity gate.
- [ ] **Multi-tenant accounts** — `Account` can have multiple `MasterUser`s (team accounts). All metrics here are scoped by `AccountId`, so this is naturally correct — but worth flagging that `repeat_customer_ratio` reflects the *team's* combined client base, not any one operator's.
