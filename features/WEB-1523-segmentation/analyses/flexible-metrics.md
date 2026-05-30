# WEB-1523 — Flexible account metrics (theory / framework)

> **⬜ Theory — not built.** A design exploration for evolving the shared `account_metrics` feature store over time: how to add new per-account metrics flexibly, version their definitions, deal with rows that predate a metric, and backfill/recompute when a definition changes. Grounds the abstract patterns in the *as-built* system ([`metrics.md`](metrics.md) → [`../implementation/metrics.md`](../implementation/metrics.md), [`../implementation/storage.md`](../implementation/storage.md), [`../implementation/migrations.md`](../implementation/migrations.md), [`versioning.md`](versioning.md)). Nothing here is committed; it's the menu for when the catalog grows past the v1 column set.

## The problem

`account_metrics` shipped (WEB-1527) as a **fixed wide table**: `account_id` PK + 11 typed metric columns + `business_name` + `updated_at`/`expires_at`, partitioned `PARTITION BY DATE_TRUNC(updated_at, MONTH)`, fed by Storage Write API **CDC UPSERTs** whose proto (`AccountMetricsProto`) is field-for-field locked to the table DDL. Per [`versioning.md`](versioning.md) § Decision it is deliberately **unversioned** — "rule-free and model-free, so it carries no version columns."

That is correct for v1. But the platform is multi-analysis by design, and every new analysis (`churn_risk`, `suspicious_user`, …) wants new signal. So the recurring question becomes: **how do we keep adding metrics — and change how existing ones are computed — without painful schema churn, and without silently mixing old and new definitions in the same column?** This doc surveys how the industry solves it and maps the winner onto our migration + CDC machinery.

## Decision (recommended shape)

1. **Keep the wide, one-column-per-metric table.** It is the columnar-native choice; an unused column costs ~nothing to existing queries, and adding one is a cheap additive DDL. Reject EAV/long key-value rows and a primary JSON blob — both trade query ergonomics or typing for flexibility we don't need at a bounded-but-growing metric count (§ Design space).
2. **Treat each metric as a code-defined catalog entry** (name, type, window, owning collector, `def_version`) — the feature-store "definition as code + registry" pattern, realised through our existing `IMetricsCollector` seam rather than a new framework.
3. **Evolve schema additively only**, through one `V00N` `ADD COLUMN IF NOT EXISTS` step **plus the matching proto field append** (lockstep). A *breaking* redefinition becomes a **new column** (`metric_v2`), never an in-place retype — the dbt "model-versions" rule at column granularity.
4. **Lean on the TTL refresh loop as a free rolling backfill.** Because `MetricsRefreshJob` upserts the **full row** every time `expires_at` lapses, a newly-added column self-populates across the whole audience within one `RefreshTtl` (24 h) with zero extra code. Old rows read `NULL` ("metric predates this row") until their next refresh.
5. **Add one lightweight version stamp** so "which rows used the old definition" is a `WHERE` filter, not a guess — and so a definition change can be *forced* faster than TTL by marking mismatched rows expired. This is the single net-new mechanism vs. today.
6. **Keep a JSON `extras` escape hatch** for experimental metrics that haven't earned a typed column yet — graduate them to real columns once stable.

## Design space (and why wide wins here)

| Layout | Add a metric = | Strength | Breaks when… | Verdict |
|---|---|---|---|---|
| **Wide table** (1 col/metric) | `ADD COLUMN` (DDL) | columnar pruning, typed, optimiser-friendly; unused columns are free to read | metric count is huge/sparse, or DDL churn itself becomes the bottleneck | **chosen** — our case is bounded growth |
| **STRUCT / repeated RECORD** | new sub-field | groups cohesive bundles (e.g. an `invoices` struct), keeps columnar pruning; storage ≈ flat columns | cross-bundle queries; still DDL to add a field | use to *group*, not as the base layout |
| **JSON column** | write a new key, no DDL | zero-DDL flexibility | every query pays a parse cost; loses typing + column pruning | **escape hatch only** (`extras`) |
| **EAV / long** (`account_id, metric_key, value`) | new *row*, no DDL | maximal flexibility | wide per-account reads need self-joins/pivots; loses types + optimiser; "simplest queries require huge resources" | rejected |

BigQuery's own guidance backs this: nested/repeated denormalisation is recommended for hierarchical-and-co-queried data, JSON is for *source-evolving ingestion* (hybrid: "transform JSON to structs/columns for analytics"), and EAV is a documented antipattern outside genuinely sparse high-cardinality attribute sets. A wide table with optional STRUCT grouping and a single JSON overflow lane is the BigQuery-idiomatic answer.

## Metric-as-code: a catalog over the collector seam

The feature-store lesson (Feast/Tecton registry, dbt semantic layer) is **definitions live in version-controlled code and are applied through a registry/migration**, so a metric's formula, inputs, owner, and version are one reviewable artifact — not tribal knowledge spread across a Mongo pipeline and a DDL string.

We already have the seam: `IMetricsCollector.BuildBatchAsync(accountIds, analyzedAt, expiresAt, ct)` → "one row per id; absent metrics stay null." The proposal is to make the catalog **explicit** rather than implicit in the collectors:

```csharp
// a metric definition is data, not just code buried in a pipeline
public sealed record MetricDescriptor(
    string   Column,          // BQ column + proto field name (lockstep)
    BqType   Type,            // INT64 / DOUBLE / BOOL — drives the V00N DDL + proto tag
    string   Window,          // "30d" / "12mo" / "all" — the aggregation window
    string   DefVersion,      // content hash of (formula ‖ inputs ‖ window ‖ collector ref)
    string   Owner);          // analysis(es) that consume it
```

This is the minimum that makes adding a metric a *declared* change: the descriptor drives the migration (column + proto field), documents the window (the silent gotcha in [`metrics.md`](metrics.md) — some metrics are 30 d, some 12 mo), and carries the `def_version` that powers staleness detection (§ Versioning). It is a registry-of-metrics in the Feast/dbt spirit, sized to one service — not a new framework.

## Schema evolution: additive-only, lockstep, immutable-aware

Constraints inherited from [`../implementation/migrations.md`](../implementation/migrations.md) § BigQuery best practices:

- **Add a metric** = one `V00N_AddXxxMetric : IBigQueryMigration` with `ALTER TABLE … ADD COLUMN IF NOT EXISTS xxx <TYPE>` **+** append `optional <type> xxx = <nextTag>;` to `account_metrics.proto`. The proto tag must be the next free number — CDC ingestion is keyed on the proto descriptor, so column and field must stay 1:1. Forward-only, double-guarded (history table *and* idempotent DDL).
- **NULL is the predates-signal.** New columns are `NULLABLE` (CDC protos are all `optional`); existing rows read `NULL` until recomputed. Our `null-vs-zero` convention already means "no signal," so an absent metric is self-describing — no sentinel needed.
- **Breaking redefinition → new column.** Renames/retypes/partition changes are destructive against history (partitioning/clustering are *immutable* after create; a key change means rebuild-via-`CREATE TABLE AS SELECT`). So a metric whose *meaning* changes ships as `metric_v2` alongside a deprecation note on `metric`, mirroring dbt's "two or three versions live at once, like a web API" rule. Consumers migrate on their own clock.
- **STRUCT for bundles, `extras` JSON for experiments.** A cohesive group (all invoice-volume stats) can become a STRUCT sub-field set; a one-off experimental metric can ride in a single `JSON extras` column until it proves out, then graduate to a typed column via a normal `V00N`.

## Versioning the feature store (the one net-new piece)

Today `account_metrics` has only `updated_at`/`expires_at`. That's enough for *additive* growth (TTL backfill fills the gap, § Backfill) but **not** enough to answer "which rows still hold the old definition of `repeat_customer_ratio`?" after a formula change. Two levels, used together — the Feast/dbt pattern of registry-hash + per-row stamp:

- **Per-metric definition hash in the registry (code).** `DefVersion = sha256(canonical(formula ‖ inputs ‖ window ‖ collector ref))`. Canonicalise first so whitespace/reorder refactors don't spuriously drift it. The hash detects **logic drift** mechanically — "many drift investigations turn out to be definition problems, not model problems."
- **A version stamp on the row.** Cheapest: a single table-level `metrics_version INT64` (bump on *any* metric change) — coarse but trivial. More precise: a `_meta STRUCT<def_versions ...>` or a parallel `xxx__def_version` column per versioned metric, so the recompute set is exactly `WHERE def_version != @current`. Start coarse (table-level) and only go per-metric if independent metric recompute becomes a real need — `account_metrics`' full-row-upsert model (below) makes coarse surprisingly workable.

Note this stays consistent with [`versioning.md`](versioning.md): the **five analysis-output versions** (prompt/model/rule/schema/`input_hash`) remain an `account_<type>` concern. This adds only a *feature-definition* version to the metrics store — a different axis (how the signal was computed, not how it was judged).

## Backfill / recomputation: the TTL loop is most of the answer

The load-bearing realisation: [`metrics.md`](metrics.md) § Refresh states **"No incremental field-level updates — each refresh upserts the full row,"** driven by `expires_at < NOW()` on an hourly cron, idempotent via CDC UPSERT. That means:

- **Additive metric → no backfill job needed.** Within one `RefreshTtl` (24 h) every row is naturally re-collected and the new column populated. The existing loop *is* a rolling backfill — gradual, throttled, resumable — exactly the production-preferred shape over a mass `UPDATE`.
- **Definition change → mark-expired, don't mass-update.** To recompute a changed metric, set `expires_at` to the past on the affected rows (`WHERE def_version != @current`, or all rows for a coarse stamp); the refresh loop reprocesses them idempotently on its own cadence. No bespoke backfill SQL, no `UPDATE` — recompute reuses the one write path, so it's automatically idempotent and CDC-merged. This is Tecton's "backfill only the stale set" applied through our scheduler.
- **Forward-only option.** When history needn't be exact (the change only matters going forward), do nothing — let natural TTL turnover converge — and just bump the registry hash so new writes carry the new definition. Equivalent to Tecton's `--suppress-recreates`.
- **Scoping & cost.** The chunked `AggregationBatchSize`/`MaxConcurrentBatches` machinery already bounds load; a targeted backfill is just a larger expired set flowing through the same throttle.

**The one caveat — full-row coupling.** Because a refresh recomputes *all* metrics for a row, adding or backfilling one **cheap** metric re-runs every metric in that row. Today all metrics are cheap Mongo aggregations, so this is fine. It breaks if a future metric is **expensive** (e.g. an LLM-derived or cross-store signal): then full-row recompute on every TTL is wasteful, and you'd either (a) split that metric into its own table with its own expiry, or (b) move to per-metric expiry/`def_version` so only the changed metric recomputes. Flag this at the point an expensive metric is proposed, not before.

## Worked example — add `avg_payment_delay_days`

1. **Catalog:** add a `MetricDescriptor("avg_payment_delay_days", DOUBLE, "90d", <hash>, "churn_risk")`.
2. **Collector:** extend the invoices/payments collector's batched pipeline to emit the field (null when no paid invoices — no-signal, not zero).
3. **Migration:** `V00N_AddAvgPaymentDelay` → `ADD COLUMN IF NOT EXISTS avg_payment_delay_days FLOAT64`; append `optional double avg_payment_delay_days = 17;` to the proto.
4. **Rollout:** deploy through the pre-deploy `migrate` gate. Old rows read `NULL`; the hourly loop populates them within 24 h. No backfill job.
5. **Later tweak** (say the window changes 90 d → 60 d): bump the descriptor hash; to force fast convergence, mark matching rows expired; otherwise let TTL converge forward-only.

## When this design breaks / open questions

- [ ] **Version-stamp granularity.** Table-level `metrics_version` vs per-metric `def_version` (STRUCT/parallel columns). Coarse is trivial and fine while all metrics are cheap and recompute together; per-metric is needed once metrics have independent cost/cadence. Decide lazily.
- [ ] **Expensive-metric escape.** First LLM-/cross-store-derived metric breaks the "full-row recompute is cheap" assumption — predefine the split-table vs per-metric-expiry rule before that metric lands.
- [ ] **Retention of superseded values.** UPSERT overwrites in place; there's no history of a metric's pre-change values. If "what did this account score under the old definition?" matters, lean on BigQuery time-travel (partitioning is in place) or an append-only audit table — same open question as [`versioning.md`](versioning.md) § Open questions.
- [ ] **`extras` JSON governance.** An overflow lane rots into a dumping ground without a graduation policy (experimental → typed column within N releases or delete).
- [ ] **Backfill completion signal.** With TTL-driven convergence, "is the rollout done?" needs a check — e.g. `COUNT(*) WHERE def_version != @current` trending to zero — rather than a job-complete event.

## Sources

- BigQuery nested/repeated best practices — https://cloud.google.com/bigquery/docs/best-practices-performance-nested
- BigQuery modify table schemas (additive-only, NULL backfill) — https://cloud.google.com/bigquery/docs/managing-table-schemas
- JSON vs Structs vs Columns benchmark — https://www.letmesqlthatforyou.com/2020/05/json-vs-structs-vs-columns-in-bigquery.html
- EAV antipattern — https://cedanet.com.au/antipatterns/eav.php
- Feast registry / feature-repo as code — https://docs.feast.dev/getting-started/components/registry , https://docs.feast.dev/reference/feature-repository
- Feature-store point-in-time correctness & time travel — https://www.systemoverflow.com/learn/ml-feature-stores/feature-store-architecture/point-in-time-correctness-and-time-travel
- Tecton change/backfill behaviour (scoped backfill, suppress-recreates) — https://docs.tecton.ai/docs/change-features , https://docs.tecton.ai/docs/running-in-production/making-changes-to-features
- dbt model versions (API-style versioning, deprecation_date) — https://docs.getdbt.com/docs/mesh/govern/model-versions
- dbt Semantic Layer / MetricFlow (metric-as-code) — https://docs.getdbt.com/docs/use-dbt-semantic-layer/dbt-sl
- Idempotent partition-scoped backfill — https://www.thedataops.org/backfill/ , https://medium.com/towards-data-engineering/building-idempotent-data-pipelines-a-practical-guide-to-reliability-at-scale-2afc1dcb7251
- Definition/content hashing & drift detection — https://medium.com/mantisnlp/data-version-control-for-reproducible-analytical-pipelines-5255782d355d , https://medium.com/@manik.ruet08/drift-detection-monitoring-schema-logic-and-metric-changes-in-real-time-a2398428ccc1
