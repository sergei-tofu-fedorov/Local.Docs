# WEB-1523 — Migrating `account_metrics` to the Gold serving model (theory)

> **⬜ Theory — not built. Decision-gated.** A concrete, phased plan to move the metrics feature store from today's **single CDC-collector table** to the **medallion hybrid** (bronze mirrors → silver per-domain marts → gold thin serving row) described in [`flexible-metrics.md`](flexible-metrics.md) § "If metrics churn fast." This is the *how* for that *what*. **Do not start** until the escalation trigger is real (measured metric churn) and the Playfair-pipeline ownership questions in [`../investigation/dwh.md`](../investigation/dwh.md) § Open questions are answered. The whole point of the plan is to be reversible at every step.

## Decision — the migration spine

- **Freeze the gold contract, swap the producer.** `account_metrics`' shape — `account_id` PK, the typed metric columns, `updated_at` / `expires_at`, the `DATE_TRUNC(updated_at, MONTH)` partition — **does not change**. Consumers (the analyze job's batch read, the `v_fsm_fit` join) never see the migration. Only *what fills the table* changes: Mongo collectors + CDC → a dbt model over per-domain marts. This is **expand-contract / strangler-fig**, not a rewrite.
- **Introduce a read seam first.** Before any producer change, put a `v_account_metrics` view in front of the physical table and repoint every consumer to it. The eventual cutover is then a **one-line view repoint**, not a consumer change — and the instant rollback path.
- **Parallel-run to a shadow table, gate on parity.** The dbt-built gold writes to `account_metrics_gold` (shadow) alongside the live CDC table for N days; cutover only after a row/column/value diff clears tolerance. Never let two write paths own the *live* table at once.
- **Materialise gold into the dataset consumers already read** (`ai_analysis_v2`), wherever bronze/silver physically live (Playfair `data_layer` or a dedicated landing). Consumers don't move datasets.
- **Numeric-only invariant.** Only non-PII aggregates flow through the mirrors. The LLM signal payload stays on its existing direct-Mongo path — this migration touches the **feature store, not the analyze stage** ([`../investigation/privacy.md`](../investigation/privacy.md) unaffected).

## From → To

```
TODAY                                    TARGET (Gold)
Mongo (federation) ─┐                    Mongo ─► Bronze mirrors (BQ, dumb/stable)
  4 collectors      │                              │
  MetricsRefreshJob ├─► account_metrics            ▼
  Storage Write CDC │   (ai_analysis_v2)    Silver: per-domain dbt marts
  proto lockstep    ┘        ▲                account_invoice_metrics
                             │                account_estimate_metrics
   consumers:                │                account_client_metrics
   • AnalyzeFsmFitJob ───────┤                      │  (churn lives here, as PR'd SQL)
   • v_fsm_fit JOIN ─────────┘                      ▼
                                          Gold: dbt model → account_metrics
                                                 (same shape, ai_analysis_v2)
                                                       ▲
                                          consumers read via v_account_metrics (unchanged)
```

The three coupled axes ([`flexible-metrics.md`](flexible-metrics.md) § topology) split: **bronze** absorbs ingestion (stops changing per metric), **silver** absorbs metric logic (churns as dbt PRs), **gold** holds the frozen serving contract.

## Gold dataflow (end-to-end)

Every object the data passes through, in flow order. Each metric is mapped to the **silver mart that owns it** (so changing one metric touches exactly one mart); the gold model only assembles. Windows / `null` rules are the spec in [`metrics.md`](metrics.md) § Per-metric query plan.

```
SOURCE (Mongo, live)              BRONZE (BQ mirrors · daily · dumb — no metric logic)
  invoices  (Tofu.Invoices) ───►  mongo_invoices  ─┐
  estimates (Tofu.Invoices) ───►  mongo_estimates ─┤  raw copy, schema-stable
  clients   (Invoices)      ───►  mongo_clients   ─┤  (Client PII MD5-hashed)
  accounts  (Invoices)      ───►  mongo_accounts  ─┘  → ingestion stops changing per metric
                                          │
                                          ▼
SILVER (per-domain dbt marts · 1 row/account · METRIC LOGIC LIVES HERE — churns as dbt PRs)
  account_invoice_metrics  ◄─ mongo_invoices    30d: invoice_count_30d, avg_invoice_amount,
                                                     invoice_amount_variance_cv, avg_line_items
                                                12mo: repeat_customer_ratio, avg_days_between_repeats
  account_estimate_metrics ◄─ mongo_estimates   12mo: estimate_count, estimate_to_invoice_rate
  account_client_metrics   ◄─ mongo_clients     b2b_clients_present, distinct_addresses,
                                                     multi_address_work
  account_base             ◄─ mongo_accounts    eligibility gate (alive, non-technical,
                              (+ invoices            invoice-active 90d) + business_name
                               for activity)
                                          │
                                          ▼   LEFT JOIN on account_id   (ASSEMBLY ONLY — no math)
GOLD (dbt scheduled table · frozen serving shape · NOT an incremental MV — outer joins)
  account_metrics = account_base ⟕ invoice_metrics ⟕ estimate_metrics ⟕ client_metrics
                    + updated_at / expires_at / def_version        → into ai_analysis_v2
                                          │
                                          ▼
SERVING SEAM
  v_account_metrics   (SELECT * — the cutover lever; repoint here, consumers untouched)
                                          │
                        ┌─────────────────┴──────────────────┐
                        ▼                                     ▼
CONSUMERS (unchanged by the migration)
  AnalyzeFsmFitJob (hourly)                      v_fsm_fit (analyst view)
   batch read → FSM-using trim →                  account_metrics ⟕ account_fsm_fit
   input_hash cache → LLM + scorer
   → account_fsm_fit
```

**How to read it for change-impact:** a metric definition change edits exactly **one silver row (#9–12)** as a dbt PR — bronze (#5–8) and the gold contract (#13–14) and every consumer (#15–16) stay frozen. Adding a metric edits its silver mart **and** the gold assembly (#13) to surface the new column — still no proto, no `V00x`, no redeploy. Only a change to the *serving shape itself* (rare, breaking) ripples to consumers, and that's the dbt-model-versions / new-column rule from [`flexible-metrics.md`](flexible-metrics.md) § Schema evolution.

## Phases

Each phase is independently shippable and leaves the system working. Consumer-visible change happens only at Phase 4.

### Phase 0 — Decisions & prerequisites (no code)
- **Confirm the escalation is warranted** — measured metric-change rate vs the single-table cost. If churn is low, stop here; the single table wins.
- **Pick the bronze source:** (a) enable the dormant Playfair `mongo_invoices_*` streams ([`../investigation/dwh.md`](../investigation/dwh.md)), or (b) stand up a dedicated Dagster/scheduled snapshot into an `ai_analysis_v2` landing dataset. (a) reuses plumbing but couples to Playfair ownership + its PII-hashing + daily cadence; (b) is independent but new infra.
- **Confirm freshness budget.** Mirror cadence is daily; FSM-fit drift is weekly+ ([`metrics.md`](metrics.md)), so acceptable — but cold-start metrics latency goes from ~2 h to ~1 day. Sign-off needed.
- **Confirm PII invariant.** Every metric in scope is a numeric/boolean aggregate. Any metric needing raw text is out of scope and stays on the collector path.
- **Locate the dbt project** (extend Playfair's, or a new one owned by this team) and the gold write target (`ai_analysis_v2.account_metrics`).

### Phase 1 — Read seam (consumer-invisible, ships immediately)
- Add `v_account_metrics` as `SELECT * FROM account_metrics`.
- Repoint `AnalyzeFsmFitJob`'s batch read and the `v_fsm_fit` join to `v_account_metrics`. Pure refactor, no behaviour change.
- *Why first:* it's the cutover lever. Note the view-in-`migration_history` caveat ([`../implementation/migrations.md`](../implementation/migrations.md) § Open questions) — decide view-evolution-via-new-`V00N` vs excluded-from-history so the repoint actually re-applies.

### Phase 2 — Bronze (consumer-invisible)
- Land the four source collections (`invoices`, `estimates`, `clients`, `accounts`) into BQ as raw, schema-stable mirrors. No metric logic. Apply the same **eligibility gates** ([`metrics.md`](metrics.md) § Eligibility) downstream, not in bronze.
- Validate freshness + row counts against Mongo.

### Phase 3 — Silver per-domain marts (consumer-invisible)
- One dbt model per source instance: `account_invoice_metrics`, `account_estimate_metrics`, `account_client_metrics` — each **re-expressing the existing collector aggregations as SQL** (the per-metric query plan in [`metrics.md`](metrics.md) § Per-metric query plan is the spec to port: 30 d vs 12 mo windows, `null`-vs-zero, repeat-client logic, address normalisation).
- Carry the `def_version` stamp ([`flexible-metrics.md`](flexible-metrics.md) § Versioning) per metric.
- Materialise heavy marts (dbt incremental / single-source BQ MV where legal); views for light ones.

### Phase 4 — Gold parallel-run + cutover (the only consumer-visible step)
1. **Build gold as a dbt model** assembling the exact `account_metrics` shape from the silver marts (`LEFT JOIN` per domain on `account_id` to keep accounts missing a domain). Write to **`account_metrics_gold`** (shadow).
   - *Constraint:* this multi-source `LEFT JOIN` **can't be an incremental BQ MV** (outer joins forbidden) — gold stays a dbt-built **scheduled table**. Incremental MVs are legal only at single-source silver.
2. **Parallel run** both paths for N days (≥ one full refresh cycle).
3. **Parity gate** (§ Parity validation). Cutover only when clear.
4. **Cutover = repoint `v_account_metrics`** to `account_metrics_gold` (or swap table names). One statement. Consumers unaffected.
5. **Disable the CDC path:** stop `MetricsRefreshJob`, retire the collectors and the Storage Write API CDC write. Keep them *runnable* (not deleted) for the rollback window.

### Phase 5 — Contract / cleanup (consumer-invisible)
- After the rollback window closes: delete the collectors, the `AccountMetricsProto`, and the metric-column `V00x` DDL ownership. Metrics now evolve as **dbt PRs over silver** — no proto, no migration, no redeploy.
- Fold the metric catalog / `def_version` registry ([`flexible-metrics.md`](flexible-metrics.md) § Metric-as-code) into the dbt models as the single source of metric truth.

## Parity validation (the cutover gate)

Diff `account_metrics` (live) vs `account_metrics_gold` (shadow) at a **fixed snapshot** (the two paths have different freshness, so compare as-of a common `updated_at` floor, not live):

- **Population:** symmetric set-diff of `account_id` — investigate any account present in one path only (eligibility-gate skew, discovery-cadence skew).
- **Per-column null rate:** a metric newly all-null in gold means a broken/missing silver port.
- **Value deltas:** exact match for INT64/BOOL; float metrics (`avg_*`, ratios, CV) within an epsilon — small deltas are expected from Mongo-`$stdDevPop` vs SQL re-implementation and snapshot skew; set and justify the tolerance.
- **Spot-check the tails:** highest-volume accounts and zero-signal accounts, where window/`null` semantics bite hardest.

Gate: population diff under threshold **and** every metric within tolerance for K consecutive runs.

## Rollback

- **Pre-cutover:** the CDC path is the live producer throughout Phases 1–3; gold is shadow-only — nothing to roll back.
- **At cutover:** repoint `v_account_metrics` back to the CDC table. Instant, because the CDC path was only paused, not deleted, during the rollback window.
- **Post-window:** once collectors/proto are deleted (Phase 5), rollback means re-deploying them — so hold Phase 5 until confidence is high.

## Risks

| Risk | Mitigation |
|---|---|
| **Freshness regression** (hourly → daily; cold-start ~2 h → ~1 day) | Confirm against FSM-fit's weekly drift budget in Phase 0; keep an on-demand top-up path if any metric needs it |
| **Playfair coupling / unknown ownership** | Phase-0 gate on `dwh.md` open questions; option (b) dedicated landing avoids the dependency |
| **Two write paths racing the live table** | Gold writes to a *shadow* table until cutover; cutover is an atomic view repoint |
| **Silver SQL drifts from collector semantics** | Parity gate; port the `metrics.md` query plan verbatim incl. window lengths and `null` rules |
| **Cross-project read** (silver in `playfair-project`, consumers in `ai_analysis_v2`) | Materialise gold *into* `ai_analysis_v2`; consumers never change project |
| **PII leak via mirrors** | Numeric-only invariant asserted in Phase 0; raw-text metrics excluded by definition |

## Out of scope

- The **analyze stage** (`account_fsm_fit`, LLM, scorer) — it consumes `account_metrics` through the unchanged seam and is untouched.
- The **per-row analysis versioning** (`prompt_version` / `model_id` / `rule_version` / `input_hash`) — a different axis ([`versioning.md`](versioning.md)); only the feature-definition `def_version` is involved here.
- Choosing the topology — that's [`flexible-metrics.md`](flexible-metrics.md); this doc assumes the gold/medallion target has already been chosen.

## Open questions

- [ ] **Bronze source** — enable Playfair streams vs dedicated `ai_analysis_v2` landing (Phase 0 decision; gates everything).
- [ ] **dbt ownership** — extend Playfair's dbt project or a new team-owned one; affects who reviews metric PRs.
- [ ] **Parity tolerance** — the epsilon for float metrics and the population-diff threshold that constitute "clear to cut over."
- [ ] **View-evolution mechanism** — resolve the `migration_history` view caveat ([`../implementation/migrations.md`](../implementation/migrations.md)) so the Phase-1 seam and Phase-4 repoint actually re-apply.
- [ ] **Gold refresh trigger** — dbt-on-Dagster-schedule vs a non-incremental MV with a staleness window; tied to the freshness budget.

## Sources

Migration mechanics (the patterns this plan instantiates):
- Expand-contract / parallel-change — https://martinfowler.com/bliki/ParallelChange.html
- Strangler-fig migration — https://martinfowler.com/bliki/StranglerFigApplication.html
- Backward-compatible DB / blue-green schema change — https://www.prisma.io/dataguide/types/relational/expand-and-contract-pattern

Topology rationale lives in [`flexible-metrics.md`](flexible-metrics.md) § Sources (medallion, data-mesh, BQ MV limits, dbt semantic layer).
