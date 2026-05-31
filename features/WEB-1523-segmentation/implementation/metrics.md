# WEB-1523 — Metrics collection (implementation)

> **✅ Shipped (WEB-1527), reconciled to code 2026-05-27.** This doc matches the implementation with these as-built corrections (applied below): collectors live under `Analyses.Infrastructure/Metrics/Collectors/` (not `Signals/`); **discovery runs every tick, with no once-per-UTC-day guard and no `MetricsRefreshState` row**; `AccountMetricsRow` is keyed on a plain `account_id` string (no `SubjectRef`, no `AnalyzedAt` column); the BigQuery side is a single `BigQueryAccountMetricsRepository` (writer + expired-scan + net-new reader folded together) over `StorageWriteApiHelper` + `BigQueryMappings`, not separate `AccountMetricsWriter`/`AccountMetricsReader`; the recurring job is registered via `RegisterAnalysesRecurringJobs(IRecurringJobManager, MetricsOptions)` and gated on `Analyses:Metrics:Enabled` (default **false** in `appsettings.json`); there is no `metrics-once` CLI / single-account `BuildAsync`.

How `Tofu.AI.Backend` actually wires up the Mongo read path that populates the shared `account_metrics` BigQuery table. The *what / why / query plan* lives in [`../analyses/metrics.md`](../analyses/metrics.md) (spec); the *where the data comes from and on what terms* lives in [`../investigation/mongo-read-isolation.md`](../investigation/mongo-read-isolation.md) (decision). This doc covers the *where it lives in code and how it's wired*.

> **Scope guardrail.** No metric definitions, no eligibility rules, no per-metric query plans here — those are locked upstream and quoted only when an implementation choice depends on them. If something below contradicts `analyses/metrics.md`, the spec wins.
>
> **Metrics only.** This doc covers the `account_metrics` read path *exclusively*. The analyze pipeline that consumes `account_metrics` (redaction → LLM → rule → score → `account_fsm_fit`) — including the `AnalyzeJob<TAnalysis>` / `AnalyzeFsmFitJob` / `SmokeProbeJob` classes, the `ILlmClient` / `IPromptLoader` registrations, and the `openai-ping` CLI — lives in [`analyze.md`](analyze.md). The metrics stage ships first and stands alone.
>
> **Audience eligibility deferred to the next stage.** The FSM-using-account exclusion (drop accounts already using FSM, since v1's audience is invoice-only) is **not** part of the metrics stage. `account_metrics` is analysis-agnostic and is populated for *all* invoice-active accounts; deciding which subset a given analysis scores is that analysis's concern. The `IFsmEligibilityProbe` (+ its `NoOp` dev fallback and the cross-repo `Invoices.Backend` Postgres `jobs.Jobs` probe) is therefore an FSM-fit audience filter and lives in [`analyze.md`](analyze.md) § Audience eligibility. The metrics discovery funnel keeps only the cheap single-store gates (invoice-active, alive, non-technical).

## Decision

- **All metric collection runs in-process inside `Tofu.AI.Api`.** Single Deployment, single image — Hangfire server + dashboard are co-hosted with the HTTP surface in `tofu-ai-api-deployment` (see [`service.md`](service.md) § Decision). There is no `Tofu.AI.Worker` Deployment in v1; the project shell of the same name in the solution is empty scaffolding.
- **Job class lives at `src/Analyses/Analyses.Application/Jobs/MetricsRefreshJob.cs`.** Hangfire registration + dashboard wiring lives at `src/Tofu.AI.Api/Hangfire/HangfireConfiguration.cs` (the three-method `AddAnalysesHangfire` / `AddAnalysesHangfireServer` / `UseAnalysesHangfireDashboard` shape). Recurring-job binding is done from `Program.cs` via `Analyses.Application.DependencyInjection.RegisterAnalysesRecurringJobs(IRecurringJobManager, MetricsOptions)` after `app.Build()` — it `AddOrUpdate`s the job when `Analyses:Metrics:Enabled`, else `RemoveIfExists`.
- **Signal collectors live at `src/Analyses/Analyses.Infrastructure/Metrics/Collectors/`** (with `MetricWindow.cs` + `AccountDiscovery.cs` one level up in `Metrics/`, and shared Mongo helpers in `Metrics/../Mongo/`). One collector per source collection (`InvoiceMetricsCollector`, `EstimateMetricsCollector`, `ClientMetricsCollector`, `AccountMetricsCollector`) behind the `MetricsCollector` façade — sized to match the per-metric pipelines in `analyses/metrics.md` § Per-metric query plan.
- **One Hangfire recurring job — `MetricsRefreshJob` — runs hourly** (cron from `Analyses:Metrics:Cadence`, default `0 * * * *`; the job is **disabled by default** via `Analyses:Metrics:Enabled = false` until an env opts in). Composes the signal collectors + the BigQuery CDC writer. Runs against a **single** Mongo connection resolved from `ConnectionStrings:Mongo` — the Federation endpoint in prod, a plain connection to the real prod Mongo in stage. `Invoices.Backend` and `Tofu.Invoices.Backend` collections share one database, so one connection serves all four. **No per-env code branches** — only the connection-string *value* differs by env.
- **Two read-only data connections, no shared abstraction.** Each has a distinct lifetime and a distinct identity in DI: `IMongoClient` (Federation / live) and the `BigQueryClient` already used by the persistence layer (for `EXCEPT` lookups against `account_metrics.account_id`). Wrapping them in a generic `IReadSource<T>` adds nothing — the call sites are stable. (The third connection — read-only Postgres against `Invoices.Backend`'s `jobs` schema — belonged to the FSM eligibility probe and moves with it to [`analyze.md`](analyze.md).)
- **Cross-replica safety.** API is at 2 replicas. `MetricsRefreshJob.RunAsync` already declares `[DisableConcurrentExecution(timeoutInSeconds: 600)]`; `Hangfire.PostgreSql`'s distributed advisory lock serialises the recurring tick across pods. No bespoke leader election needed.
- **No incremental field-level updates and no in-memory caching across ticks.** Each refreshed account produces one full upsert row per tick; CDC ingestion handles the merge. Idempotency falls out of the BQ primary key.
- **Batched reads and writes — never per single account.** Each tick chunks its candidate accounts into batches of `AggregationBatchSize` (default ~300). Per batch: one `$match {AccountId: {$in: batch}} → $group {_id: "$AccountId"}` aggregation per source family (4 reads cover the whole batch), composed into one `AccountMetricsRow` per account, then a single batched Storage Write API append. Round-trips are ~4 reads + 1 write per *batch*, not per *account* — and the leading `$in` `$match` still uses the `AccountId` index. `AggregationBatchSize` bounds the per-batch server-side `$group` working set; `MaxConcurrentBatches` bounds concurrency.

Everything below this section is the supporting detail — class layout, wiring, configuration, failure surfaces.

## Code layout

```
src/
├── Tofu.AI.Api/
│   ├── Hangfire/
│   │   └── HangfireConfiguration.cs      # AddAnalysesHangfire + AddAnalysesHangfireServer + UseAnalysesHangfireDashboard
│   └── Program.cs                        # composition root — calls AddAnalysesHangfire + RegisterAnalysesRecurringJobs
│
└── Analyses/
    ├── Analyses.Application/
    │   ├── Jobs/
    │   │   └── MetricsRefreshJob.cs      # recurring-job entry point — coordinates the tick
    │   │                                 # (AnalyzeJob<T>, AnalyzeFsmFitJob, SmokeProbeJob live in this
    │   │                                 #  same folder — specified in analyze.md, not this doc)
    │   └── DependencyInjection.cs        # AddAnalysesApplication + RegisterAnalysesRecurringJobs
    │                                     # (Eligibility/ — the FSM audience probe — moves to analyze.md)
    │
    ├── Analyses.Infrastructure/
    │   ├── Metrics/
    │   │   ├── Collectors/
    │   │   │   ├── MetricsCollector.cs      # façade — batched fan-out over the four collectors → one AccountMetricsRow per account
    │   │   │   ├── InvoiceMetricsCollector.cs   # invoice_count_30d, avg_invoice_amount, invoice_amount_variance_cv,
    │   │   │   │                                #  avg_line_items_per_invoice, repeat_customer_ratio, avg_days_between_repeats
    │   │   │   ├── EstimateMetricsCollector.cs  # estimate_count, estimate_to_invoice_rate
    │   │   │   ├── ClientMetricsCollector.cs    # b2b_clients_present, multi_address_work, distinct_addresses
    │   │   │   └── AccountMetricsCollector.cs   # business_name (single-doc projection)
    │   │   ├── MetricWindow.cs              # 30d / 12mo window anchors from analyzedAt
    │   │   └── AccountDiscovery.cs          # IAccountDiscovery — invoices sweep + accounts eligibility gate
    │   ├── Mongo/
    │   │   ├── MongoDatabaseFactory.cs      # builds the single IMongoDatabase from ConnectionStrings:Mongo (DB name from URL)
    │   │   ├── BsonReads.cs                 # null-tolerant readers + ById/ToIds helpers for aggregation docs
    │   │   ├── Collections.cs               # source collection-name constants
    │   │   ├── MongoConventions.cs          # AllowDiskUse + the [false, null] "alive" set
    │   │   └── MongoFilters.cs              # NotDeleted / NotTechnical / DateBetween fragments
    │   ├── AnalysesConnectionStrings.cs     # well-known ConnectionStrings keys (Mongo)
    │   └── DependencyInjection.cs           # AddAnalysesInfrastructure — registers the IMongoDatabase + collectors + AccountDiscovery
    │
    └── Analyses.Persistence/
        ├── BigQuery/
        │   ├── StorageWriteApiHelper.cs     # default-stream Storage Write API append (CDC, _CHANGE_TYPE=UPSERT) — analysis-agnostic
        │   ├── BigQueryMappings.cs          # AccountMetricsRow → proto (null metric → unset ⇒ NULL; ts → INT64 micros)
        │   └── BigQuerySettings.cs          # Analyses:BigQuery bind
        ├── Protos/account_metrics.proto     # CDC row message (proto2, all-optional)
        └── Repositories/
            └── BigQueryAccountMetricsRepository.cs  # IAccountMetricsRepository — UpsertMany (CDC) + GetExpired + ExceptExisting (Query API)
```

Each `*Collector` owns its Mongo aggregation(s) for a **batch** of accounts and projects into a typed C# record per account (`InvoiceMetricsResult`, `ClientMetricsResult`, …). `MetricsCollector` is the only class `MetricsRefreshJob` talks to in the signal path — it returns one `AccountMetricsRow` per `account_id` in the batch. No collector knows about BigQuery; no writer knows about Mongo. The seam is the typed record.

Runtime flow: the `MetricsRefreshJob` tick is sequenced in [`metrics-interaction.md`](metrics-interaction.md) — kept separate to keep this doc focused on the static layout.

## Collector code (high-level)

`MetricsCollector.BuildBatchAsync` is the single seam `MetricsRefreshJob` calls — **per batch of accounts, not per account**. It fans the four source-family collectors out concurrently; each runs **one** `$match {AccountId: {$in: batch}} → $group {_id: "$AccountId"}` aggregation and returns a `Dictionary<accountId, result>`. The façade then composes one flat `AccountMetricsRow` per requested account. The per-metric **pipeline shapes are locked in [`../analyses/metrics.md`](../analyses/metrics.md) § Per-metric query plan** (group-by-account form); this code only wires them to typed records.

```csharp
// MetricsCollector.cs — façade; the only class MetricsRefreshJob talks to in the signal path.
// (As built: takes the concrete MetricsOptions singleton; there is no single-account BuildAsync.)
internal sealed class MetricsCollector(
    InvoiceMetricsCollector  invoices,
    EstimateMetricsCollector estimates,
    ClientMetricsCollector   clients,
    AccountMetricsCollector  account,
    MetricsOptions options) : IMetricsCollector
{
    public async Task<IReadOnlyList<AccountMetricsRow>> BuildBatchAsync(
        IReadOnlyCollection<string> accountIds, DateTimeOffset analyzedAt, CancellationToken ct)
    {
        if (accountIds.Count == 0) return [];
        var w = MetricWindow.From(analyzedAt);

        // Four batched reads, independent → run concurrently. Each is one $in aggregation grouped by
        // account, returning Dictionary<accountId, result>. (Concurrency *across batches* is the tick loop's.)
        var invTask = invoices.CollectBatchAsync(accountIds, w, ct);
        var estTask = estimates.CollectBatchAsync(accountIds, w, ct);
        var cliTask = clients.CollectBatchAsync(accountIds, ct);
        var accTask = account.CollectBatchAsync(accountIds, ct);
        await Task.WhenAll(invTask, estTask, cliTask, accTask);

        // One row per requested account. An account absent from a family's dictionary had no matching docs
        // in window → its *.Empty default (count 0 / null averages) — the null-vs-zero rule.
        var expiresAt = analyzedAt + options.RefreshTtl;
        var rows = new List<AccountMetricsRow>(accountIds.Count);
        foreach (var id in accountIds)
        {
            var i = invTask.Result.GetValueOrDefault(id) ?? InvoiceMetricsResult.Empty;
            var e = estTask.Result.GetValueOrDefault(id) ?? EstimateMetricsResult.Empty;
            var c = cliTask.Result.GetValueOrDefault(id) ?? ClientMetricsResult.Empty;
            rows.Add(new AccountMetricsRow(
                AccountId: id,                                    // plain string key — no SubjectRef
                BusinessName: accTask.Result.GetValueOrDefault(id),   // null when the account doc is absent
                InvoiceCount30d: i.InvoiceCount30d,
                AvgInvoiceAmount: i.AvgInvoiceAmount,
                InvoiceAmountVarianceCv: i.InvoiceAmountVarianceCv,
                AvgLineItemsPerInvoice: i.AvgLineItemsPerInvoice,
                RepeatCustomerRatio: i.RepeatCustomerRatio,
                AvgDaysBetweenRepeats: i.AvgDaysBetweenRepeats,
                EstimateToInvoiceRate: e.EstimateToInvoiceRate,
                EstimateCount: e.EstimateCount,
                B2bClientsPresent: c.B2bClientsPresent,
                MultiAddressWork: c.MultiAddressWork,
                DistinctAddresses: c.DistinctAddresses,
                ExpiresAt: expiresAt));                           // no AnalyzedAt — updated_at stamped at write
        }
        return rows;
    }
}
```

**Internals — one collector per source family, each batched.** The only change from the single-account shape is the `$match` (`AccountId == X` → `AccountId ∈ batch`) and the group key (`_id: null` → `_id: "$AccountId"`); the cursor then yields one doc per account, keyed into a dictionary. The parameterised `$match` stays typed (`Builders`); the static stages are the spec's pipeline as JSON (`BsonDocument.Parse`). All four collectors share the **single** injected `IMongoDatabase` (§ Connection wiring) — `Invoices.Backend` and `Tofu.Invoices.Backend` collections live in one database. `InvoiceMetricsCollector` is the representative shape:

```csharp
// InvoiceMetricsCollector.cs — batched: $match {AccountId: {$in}} → $group by account.
internal sealed class InvoiceMetricsCollector(IMongoDatabase db)
{
    private static readonly AggregateOptions Opts = new() { AllowDiskUse = true };
    private static readonly BsonValue[] NotDeleted = [false, BsonNull.Value];

    public async Task<IReadOnlyDictionary<string, InvoiceMetricsResult>> CollectBatchAsync(
        IReadOnlyCollection<string> accountIds, MetricWindow w, CancellationToken ct)
    {
        var invoices = db.GetCollection<BsonDocument>("invoices");
        var f = Builders<BsonDocument>.Filter;

        // 30d volume — grouped BY account (was _id: null). One result doc per account with ≥1 invoice in window.
        var volume = await invoices.Aggregate(Opts)
            .Match(f.In("AccountId", accountIds) & f.In("IsDeleted", NotDeleted)
                 & f.Gte("Date", w.Start30d) & f.Lt("Date", w.End))
            .AppendStage<BsonDocument>(BsonDocument.Parse(
                """
                { "$group": {
                    "_id": "$AccountId",
                    "count": { "$sum": 1 }, "mean": { "$avg": "$TotalAmount" },
                    "sd": { "$stdDevPop": "$TotalAmount" },
                    "avgLineItems": { "$avg": { "$size": { "$ifNull": ["$Items", []] } } }
                } }
                """))
            .AppendStage<BsonDocument>(BsonDocument.Parse(/* $project: invoice_count_30d / avg / cv / avg_line_items — _id kept as account id */))
            .ToListAsync(ct);                  // N docs, one per account — NOT FirstOrDefault

        // 12mo repeat — group by {account, client}, then re-group by account (group-by-account form in the spec).
        var repeat = await invoices.Aggregate(Opts)
            .Match(f.In("AccountId", accountIds) & f.In("IsDeleted", NotDeleted)
                 & f.Gte("Date", w.Start12mo) & f.Lt("Date", w.End))
            .AppendStage<BsonDocument>(BsonDocument.Parse(/* $addFields _clientId → $group _id:{a,c} → $group _id:"$_id.a" → $project */))
            .ToListAsync(ct);

        // Key both result sets by account id; the façade substitutes InvoiceMetricsResult.Empty for misses.
        return IndexByAccount(volume, repeat);
    }
}
```

The other three change identically — `$in` match + `_id: "$AccountId"` group + `ToListAsync` + dictionary:

| Collector | Collection | Emits | Note |
|---|---|---|---|
| `EstimateMetricsCollector` | `estimates` | `estimate_count`, `estimate_to_invoice_rate` | 12mo window; `null` rate when the account uses no estimates |
| `ClientMetricsCollector` | `clients` | `b2b_clients_present`, `multi_address_work`, `distinct_addresses` | regex B2B match + address normalisation **inside** the pipeline; carry `AccountId` through `$project` before grouping |
| `AccountMetricsCollector` | `accounts` | `business_name` | `Find {_id: {$in: batch}}` → `Dictionary<accountId, string?>`, no aggregation |

`MetricWindow`, the `*MetricsResult` records (each with a static `Empty` default for the façade's missing-account case), and the JSON pipeline strings live alongside the collectors in `Analyses.Infrastructure/Signals/`. The JSON stages are transcribed from `analyses/metrics.md` (group-by-account form) — the spec stays source of truth.

## Tick orchestration

`MetricsRefreshJob.RunAsync(ct)` (as built) takes one `analyzedAt` anchor for the whole tick, then runs expired-scan + discovery + a bounded-concurrency batch loop:

```text
RunAsync(ct):
    analyzedAt = UtcNow                                   # single anchor → stable windows + expires_at across batches
    expired    = repo.GetExpiredAsync(ExpiredScanBatchSize)   # account_id[] WHERE expires_at < CURRENT_TIMESTAMP()
    discovered = DiscoverAsync(ct)                        # EVERY tick — no daily guard
    queue      = distinct(expired ∪ discovered)

    Parallel.ForEachAsync(queue.Chunk(AggregationBatchSize), MaxDegreeOfParallelism = MaxConcurrentBatches):
        rows = collector.BuildBatchAsync(batch, analyzedAt)   # 4 batched $in aggregations, grouped by account
        repo.UpsertManyAsync(rows)                            # one BQ Storage Write API append per batch (CDC UPSERT)
```

`DiscoverAsync` (a private method on `MetricsRefreshJob`) runs the three-step funnel; the sweep + eligibility steps live on `AccountDiscovery` (Infrastructure), the `EXCEPT` step on the repository:

```text
DiscoverAsync(ct):
    active  = discovery.SweepActiveAccountsAsync(DiscoveryWindowDays)   # Mongo invoices: CreatedTime ≥ now-90d, alive
    netNew  = repo.ExceptExistingAsync(active)                          # active EXCEPT existing account_metrics.account_id
    return    discovery.FilterEligibleAsync(netNew)                     # Mongo accounts: alive, non-technical
                                                                        #   (account-age >90d is an FSM-fit AUDIENCE filter — see analyze.md § Audience eligibility,
                                                                        #    not a metrics-discovery gate)
```

The FSM-using-account trim that used to sit between `active` and `netNew` (`− PG probe(jobs.Jobs recent)`) is **gone from this stage** — `account_metrics` now covers FSM-using accounts too. The FSM-fit analyze job applies that exclusion itself; see [`analyze.md`](analyze.md) § Audience eligibility.

> **Account maturity is not a discovery gate.** An earlier revision planned a 4th eligibility condition here (account created > 90 days ago). It was **relocated to the FSM-fit audience filter** — applied inside `AnalyzeFsmFitJob` at scoring time, alongside the FSM-using exclusion — see [`analyze.md`](analyze.md) § Audience eligibility § Account-maturity gate. `account_metrics` stays analysis-agnostic (rows exist for <90-day accounts too); only FSM-fit drops them from its scored set. `FilterEligibleAsync` therefore keeps just conditions 1–2 (alive, non-technical).

**No once-per-day discovery guard (as built).** The full funnel runs **every tick** — there is no `MetricsRefreshState` row and no `LastDiscoveryAt` check. It's safe to run hourly because the funnel is idempotent (read-only sweep, `ExceptExistingAsync` dedupes net-new, the CDC upsert is repeat-safe) and cheap at current volume. Cross-tick serialisation comes from `[DisableConcurrentExecution(600)]` (PG advisory lock). Re-throttle (a durable Postgres claim, or a dedicated daily Hangfire job) only if the sweep cost grows.

## Connection wiring

### Mongo

`MongoDatabaseFactory` builds the **single** `IMongoDatabase` straight from `ConnectionStrings:Mongo` — a plain connection, exactly as the other services do. **No `MongoClientSettings` tuning in code** (no read-preference / read-concern / app-name overrides): anything of that sort rides on the connection-string URI, so there's nothing env-specific to branch on.

`Invoices.Backend` (`accounts`, `clients`) and `Tofu.Invoices.Backend` (`invoices`, `estimates`) collections **share one database**, so a single connection serves all four collectors:

- **Prod:** the connection string points at the Mongo Data Federation endpoint, which exposes the snapshots as one logical DB. The live cluster is never touched.
- **Stage:** a plain connection string to the real prod Mongo, as the other services use. Federation is **not** stood up on stage; stage's worker volume is negligible, so no special read routing is needed (see [`../investigation/mongo-read-isolation.md`](../investigation/mongo-read-isolation.md) § Decision).

**Collection names are identical in both cases** — Federation exposes `invoices` / `estimates` / `clients` / `accounts` under their native names (no prefix, no alias map). So collector code is **env-invariant**: only the connection-string *value* changes between prod and stage.

> The read-only Postgres connection to `Invoices.Backend`'s `jobs` schema (`ConnectionStrings:InvoicesJobs`) is **not** wired in this stage — it served the FSM eligibility probe only. Its connection factory, settings, and the cross-repo role/grant prerequisite move to [`analyze.md`](analyze.md) § Audience eligibility.

### BigQuery

As built, a single **`BigQueryAccountMetricsRepository` (implements `IAccountMetricsRepository`)** owns all `account_metrics` access — there are no separate `AccountMetricsWriter` / `AccountMetricsReader` classes, and the originally-planned `IAccountMetricsReader` is folded in. It exposes exactly three methods:

- `UpsertManyAsync(rows)` — maps each row to the `AccountMetricsProto` via `BigQueryMappings.ToProto` (null metric → unset field ⇒ NULL; timestamps → INT64 micros), stamps one `updated_at` for the batch, and makes **one** `StorageWriteApiHelper.AppendManyAsync` call (default-stream CDC, `_CHANGE_TYPE = "UPSERT"`). No single-row write path exists.
- `GetExpiredAsync(batchSize)` — Query API: `SELECT account_id … WHERE expires_at < CURRENT_TIMESTAMP() ORDER BY expires_at LIMIT @batchSize`.
- `ExceptExistingAsync(candidates)` — the discovery funnel's net-new filter: pulls existing `account_id`s once and subtracts in-memory (sidesteps IN-list limits). All via the same injected `BigQueryClient`.

## Configuration

`appsettings.json` adds one section:

```jsonc
{
  "ConnectionStrings": {
    // One DB serves all four collections. Prod: the Federation endpoint. Stage: the real prod Mongo.
    "Mongo": "<resolved per env from GSM>"
  },
  "Analyses": {
    "Metrics": {
      "Cadence": "0 * * * *",          // hourly Hangfire cron
      "RefreshTtl": "1.00:00:00",      // 24h — see analyses/metrics.md § Decision
      "ExpiredScanBatchSize": 500,     // BQ expired-row scan cap per tick
      "AggregationBatchSize": 300,     // accounts per batched Mongo aggregation ($in size + $group working set)
      "MaxConcurrentBatches": 4,       // batches processed concurrently
      "DiscoveryWindowDays": 90        // Mongo invoice sweep window (locked in spec)
    }
  }
}
```

The `Analyses:Postgres:JobsDb` connection (read-only role on `Invoices.Backend`'s `jobs.Jobs`) is added by the analyze stage — see [`analyze.md`](analyze.md) § Audience eligibility.

Bound to a strongly-typed `MetricsOptions` record via `services.Configure<MetricsOptions>(config.GetSection("Analyses:Metrics"));`. **No env-specific overrides** — `appsettings.Production.json` provides the per-env connection strings via the GSM mount; `appsettings.Development.json` provides local equivalents for dev / unit tests.

`Cadence`, `RefreshTtl`, `ExpiredScanBatchSize`, `AggregationBatchSize`, `MaxConcurrentBatches` are deliberately knobs (operability lever — see `analyses/metrics.md` § Performance budget § "What would break this"). They are not used to gate logic — only to size loops; `AggregationBatchSize` is the main lever bounding the per-batch `$group` working set.

## DI registration

Registration is split across three module DI files, all called from `Tofu.AI.Api/Program.cs`:

| Registration | Lifetime | Module (DI file) | Note |
|---|---|---|---|
| `MetricsRefreshJob` | Scoped | `AddAnalysesApplication` | matches Hangfire job-activator lifetime |
| `MetricsOptions` | Options + concrete singleton | `AddAnalysesApplication` | `Configure<>` from `Analyses:Metrics`, plus `AddSingleton(sp => IOptions.Value)` so the job + façade take the plain `MetricsOptions` |
| `IMongoDatabase` | Singleton | `AddAnalysesInfrastructure` | via `MongoDatabaseFactory` from `ConnectionStrings:Mongo` (DB name from URL); all four collectors share it; resolved lazily so the `migrate` CLI never opens Mongo |
| 4 `*MetricsCollector` + `MetricsCollector` (+ `IMetricsCollector`) + `IAccountDiscovery` | Singleton | `AddAnalysesInfrastructure` | stateless aggregation |
| `IAccountMetricsRepository`, `StorageWriteApiHelper`, BigQuery clients | Scoped / Singleton | `AddAnalysesPersistence` | repository scoped; `BigQueryClient` + `BigQueryWriteClient` + helper singletons |

The `IFsmEligibilityProbe` registrations (`NoOp` default + the PG-backed real probe + its `NpgsqlDataSource`) move to the analyze stage — see [`analyze.md`](analyze.md) § Audience eligibility § DI.

`Tofu.AI.Api/Program.cs` is the only composition root. Wiring order:

```text
Program.cs (composition root):
    AddAnalysesPersistence()       # BQ client + migrations
    AddAnalysesApplication()       # jobs
    AddAnalysesInfrastructure()    # Mongo + collectors
    IF NOT cli-mode:
        AddAnalysesHangfire(hangfireConn) + AddAnalysesHangfireServer()

    app ← Build()
    IF NOT cli-mode:
        UseAnalysesHangfireDashboard()
        RegisterAnalysesRecurringJobs(recurringJobManager, config)
```

`RegisterAnalysesRecurringJobs` reads `Analyses:Metrics:Cadence` and calls `IRecurringJobManager.AddOrUpdate<MetricsRefreshJob>("metrics-refresh", j => j.RunAsync(...), cadence)`. In the metrics-only stage this is the **sole** recurring-job registration; `AnalyzeFsmFitJob` and `SmokeProbeJob` are added to the same call site by the analyze stage — see [`analyze.md`](analyze.md) § Recurring-job + CLI registration.

**CLI-mode short-circuit.** `dotnet Tofu.AI.Api.dll migrate` skips both `AddAnalyses*Hangfire*()` and `RegisterAnalysesRecurringJobs` — the migrate path is what creates the `analyses` Hangfire schema, so it must not depend on it existing first. See `service.md` § Q2 § "CLI-mode short-circuit". (The `openai-ping` LLM-probe CLI is the analyze stage's — covered in [`analyze.md`](analyze.md).)

## Observability

Three signals worth wiring before stage 1 ships — see also `analyses/metrics.md` § Performance budget for the thresholds these protect.

| Signal | Where | Why |
|---|---|---|
| Per-tick duration + per-batch aggregation P95 (with batch size) | Serilog structured log (`MetricsRefreshJob.Tick`) | Cheapest way to spot a regression when a new metric pipeline lands or a batch's `$group` working set grows too large |
| Discovery-sweep duration + matched-account count | Same log + a daily one-shot summary line | The discovery sweep is the load-bearing daily op; a 10× slowdown means the partial index dropped (see § Index audit in spec) |
| BQ CDC upsert failures + retry count | Hangfire's built-in retry telemetry + a Stackdriver alert on `metrics-refresh` job failure rate > 1% | CDC failures are silent without an alert — the next tick re-reads stale data without raising |

LLM-call telemetry is **not** here — that belongs to `AnalyzeJob<TAnalysis>` (see [`analyze.md`](analyze.md) § Observability), not `MetricsRefreshJob`. `account_metrics` is rule-free, model-free.

## Test surface

Per the skill's testing requirement, this lands with at least one integration test in `tests/Tofu.AI.FunctionalTests` (or whatever the repo's existing functional-test project ends up named):

- **`MetricsRefreshJob_runs_full_tick_against_fixture_mongo_and_writes_account_metrics_row`** — uses TestContainers Mongo + the BQ emulator (or a mock writer if the emulator is too heavy in CI); seeds one invoice-active account and one deleted account; asserts that one row lands in BQ with the expected typed columns. End-to-end through the actual `MetricsCollector` fan-out + CDC upsert path — not a unit test over a single collector. (The FSM-using-account exclusion is no longer this stage's concern — its integration test lives in `analyze.md` § Audience eligibility and needs the PG container.)
- **`MetricsCollector_build_batch_returns_one_row_per_account_and_defaults_empties`** — the batching contract proof: seed 2–3 accounts (one full, one with no invoices/estimates/clients) into the TestContainers Mongo, call `BuildBatchAsync` over all of them in **one** call, and assert one `AccountMetricsRow` per account, the empty one defaulting to count 0 / null averages, and **no cross-account bleed** from the shared `$in` `$group` (each account's metrics are its own). (There is no single-account `BuildAsync` — `BuildBatchAsync` is the only entry point.)

Unit tests over each `*MetricsCollector` are useful but secondary — they verify each Mongo pipeline shape against the fixture data. They do **not** replace the integration test; the contract proof is the full tick.

After writing these tests, invoke the `/tests` skill against the new test files to refactor in line with project conventions before `/feature lint`.

## Cross-repo prerequisites

These must land before WEB-1523 ships, but they are **not** WEB-1523 commits:

| Prereq | Owner | Where |
|---|---|---|
| Mongo Data Federation endpoint provisioned in prod, snapshots cover `invoices` / `estimates` / `clients` / `accounts` with windows ≥ 12mo | Platform / DBA | Federation config; out of repo |
| New partial index `invoices.{CreatedTime: 1}` with `partialFilterExpression: {IsDeleted: {$in: [false, null]}}` | `Tofu.Invoices.Backend` | `MongoDbContext.cs` `Configure(...)` block — separate PR in that repo |

The two `Invoices.Backend` Postgres prerequisites (read-only `jobs.Jobs` role + the `{AccountId}` index) belonged to the FSM eligibility probe and move with it to [`analyze.md`](analyze.md) § Audience eligibility § Cross-repo prerequisites — they no longer gate the metrics stage.

The `Affected repos` table in the parent `README.md` should grow to list `Tofu.Invoices.Backend` as a v1 touch point for the new `invoices` index once it's scheduled — even though the change is tiny, it's a separate PR that gates the WEB-1523 deploy.

## Open questions (implementation-side)

- [x] ~~**Federation virtual-collection naming** — exact names vs. per-cluster prefix?~~ **Resolved:** Federation is configured to expose `invoices` / `estimates` / `clients` / `accounts` under their **native names** (no prefix, no alias map). Collector code is env-invariant; stage uses the real clusters via different connection-string values only. (Platform still owns the one-time Federation config that pins these names — a setup task, not a code unknown.)
- [x] ~~**One cluster or two on stage?**~~ **Resolved:** `Invoices.Backend` and `Tofu.Invoices.Backend` collections share one database. The metrics stage uses a single `ConnectionStrings:Mongo` connection / one `IMongoDatabase` for all four collections — no per-source split.
- [ ] **Federation scan-cost shape.** Aggregation is already batched (`$in` per `AggregationBatchSize` accounts, grouped by account — not per-account reads), which is the first cost mitigation. If first-month observed cost still lands above $50/mo, escalate to a single full batched sweep that lands intermediate per-account results in a staging BQ table and have collectors read from BQ thereafter. Decision deferred to post-deploy measurement.
- [x] ~~**`MetricsRefreshState` row vs. Hangfire's distributed lock for the once-per-day discovery guard.**~~ **Resolved (as built):** there is no once-per-day guard — discovery runs every tick (idempotent + cheap), so no state row was needed. Cross-tick serialisation is `[DisableConcurrentExecution]`'s PG advisory lock. Revisit only if the sweep cost forces re-throttling.
- [x] ~~**Cancellation propagation.**~~ **Resolved (as built):** `RunAsync` passes the job `ct` into `ParallelOptions.CancellationToken` and threads a per-batch `ct` into `BuildBatchAsync` / `UpsertManyAsync`, so an API-pod SIGTERM aborts in-flight aggregations. Still worth a load-test confirmation that HTTP graceful-shutdown and the Hangfire job's SIGTERM don't block each other (shared in-process host).
- [ ] **`AggregationBatchSize` tuning.** Start at 300; measure the per-batch `$group` working set on a real batch before raising — the `ClientMetricsCollector` `$push allAddresses` and the repeat compound group (`{account, client}`) are the heaviest. `allowDiskUse` covers spill, but keep the `$in` list comfortable (≤ ~1,000 ids) so the query doc and index scan stay sane.
