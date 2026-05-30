# WEB-1527 — Account metrics collection — Implementation Plan

> See `overview.md` for analysis, decisions, data contracts, and risk points.
> Scope: metrics stage only (`account_metrics` + `MetricsRefreshJob`). No LLM / redaction / eligibility / `account_fsm_fit` / `v_fsm_fit`.

Bottom-up order: new projects + config → domain contracts → Mongo read side → collectors → discovery → BigQuery write side → BigQuery read + migration → job orchestration + wiring → build verification.

## Code layout

Every file this plan creates or changes, and the step that owns it. `(new)` = added by WEB-1527, `(edit)` = existing file changed, `(replaces …)` = supersedes a WEB-1526 file. Unmarked existing files are untouched and shown only for context.

```
Tofu.AI.Backend/
└─ src/
   ├─ Analyses/
   │  ├─ Analyses.Domain/                                 # (new project) pure contracts + options — no Mongo/BigQuery types   [Step 2]
   │  │  ├─ MetricsOptions.cs                             # (new) Analyses:Metrics knobs (Enabled/Cadence + sizing)    [1.3]
   │  │  ├─ Repositories/IAccountMetricsRepository.cs     # (new) + AccountMetricsRow (all-nullable); Upsert(Many) + GetExpiredAsync + ExceptExistingAsync
   │  │  ├─ Services/IMetricsCollector.cs                 # (new) BuildBatchAsync
   │  │  └─ Services/IAccountDiscovery.cs                 # (new) SweepActiveAccountsAsync + FilterEligibleAsync
   │  ├─ Analyses.Infrastructure/                         # (new project) Mongo read side; +MongoDB.Driver; refs Domain only   [Steps 3–5]
   │  │  ├─ DependencyInjection.cs                        # (new) AddAnalysesInfrastructure — skips collectors when Mongo absent   [3.3]
   │  │  ├─ Mongo/MongoDatabaseFactory.cs                 # (new) one IMongoDatabase; DB name from the connection-string URL   [3.1]
   │  │  ├─ Mongo/BsonReads.cs                            # (new) null-tolerant BsonDocument readers                   [3.2]
   │  │  └─ Metrics/
   │  │     ├─ MetricWindow.cs                            # (new) 30d/12mo/90d anchors from analyzedAt                 [4.1]
   │  │     ├─ AccountDiscovery.cs                        # (new) invoices sweep + accounts eligibility                [5.1]
   │  │     └─ Collectors/
   │  │        ├─ InvoiceMetricsCollector.cs              # (new) 30d volume + 12mo repeat aggregations                [4.2]
   │  │        ├─ EstimateMetricsCollector.cs             # (new) 12mo estimate conversion                             [4.3]
   │  │        ├─ ClientMetricsCollector.cs               # (new) B2B regex + address normalisation                   [4.4]
   │  │        ├─ AccountMetricsCollector.cs              # (new) business_name projection                            [4.5]
   │  │        └─ MetricsCollector.cs                     # (new) façade — fan-out + compose AccountMetricsRow         [4.6]
   │  ├─ Analyses.Application/                            # (existing)
   │  │  ├─ DependencyInjection.cs                        # (edit) owns MetricsOptions (bind + concrete singleton) + RegisterAnalysesRecurringJobs   [1.3/8]
   │  │  └─ Jobs/MetricsRefreshJob.cs                     # (edit) replace stub body — expired + discovery (every tick) → batched aggregate → CDC upsert   [8.1]
   │  └─ Analyses.Persistence/                            # (existing) BigQuery write/read side; +Storage Write API/Protobuf   [Steps 6–7]
   │     ├─ DependencyInjection.cs                        # (edit) register repo + writer; swap migration V001_Bootstrap→V001_CreateAccountMetrics   [7.2]
   │     ├─ Protos/account_metrics.proto                  # (new) account-only row message (no master/platform fields)   [6.1]
   │     ├─ BigQuery/StorageWriteApiHelper.cs             # (new) default-stream AppendRows, _CHANGE_TYPE=UPSERT       [6.2]
   │     ├─ BigQuery/BigQueryMappings.cs                 # (new) AccountMetricsRow → proto (null → unset ⇒ NULL)      [6.3]
   │     ├─ Repositories/BigQueryAccountMetricsRepository.cs  # (new) CDC upsert + GetExpiredAsync + ExceptExistingAsync (pull-once, in-memory)   [6.3]
   │     └─ Migrations/Modules/BigQuery/
   │        ├─ V001_Bootstrap.cs                          # (delete) replaced
   │        └─ V001_CreateAccountMetrics.cs               # (new, replaces V001_Bootstrap) account_metrics DDL, PK(account_id)   [7.1]
   └─ Tofu.AI.Api/                                        # (existing) composition root
      ├─ Program.cs                                       # (edit) + .AddAnalysesInfrastructure(config); + .AddChatStorage(); + partial Program test seam   [8.2]
      ├─ Services/ChatStorageRegistration.cs              # (new) AddChatStorage — config-driven GCS credential (ADC by default)
      ├─ Settings/StorageSettings.cs                      # (new) `Storage` section bind (optional ServiceAccountKeyPath)
      └─ appsettings.json                                 # (edit) +ConnectionStrings:Mongo, +Storage, expand Analyses:Metrics   [1.4]
```

## Implementation

### Step 1: New projects, options, config

**Files:** `src/Analyses/Analyses.Domain/MetricsOptions.cs`, `src/Tofu.AI.Api/appsettings.json`, `appsettings.Development.json` — plus the two new projects below (project-file/solution setup is mechanical and not detailed here).

Scaffolding must compile green with empty project bodies before any logic lands.

#### 1.1 Two new projects
- **`Analyses.Domain`** (`Tofu.AI.Analyses.Domain`) — pure contracts; depends on nothing.
- **`Analyses.Infrastructure`** (`Tofu.AI.Analyses.Infrastructure`) — Mongo read side; depends on `Analyses.Domain` only.
- Dependency direction: `Analyses.Application`, `Analyses.Persistence`, and `Analyses.Infrastructure` all reference `Analyses.Domain` only; `Tofu.AI.Api` references `Analyses.Infrastructure` (it already wires Application + Persistence). `MetricsOptions` lives in `Analyses.Domain`, so no layer depends on `Analyses.Application`. All `net8.0`, nullable + `TreatWarningsAsErrors`, matching the existing `Analyses.*` projects.

#### 1.2 New package dependencies
- `Analyses.Infrastructure` → **MongoDB.Driver** (latest 2.x, for driver-API stability).
- `Analyses.Persistence` → **Google.Cloud.BigQuery.Storage.V1** + **Google.Protobuf** + **Grpc.Tools** (for the `.proto` in Step 6).

#### 1.3 `MetricsOptions` (in `Analyses.Domain`)
Lives in `Analyses.Domain` (so Infrastructure/Persistence need no Application reference); `AddAnalysesApplication` is its sole registrar (bind + concrete singleton). Add to the existing `{Enabled, Cadence}` (each knob documented with why it exists — sizing levers only, never used to gate logic):
```csharp
// Row freshness: written rows get expires_at = analyzedAt + RefreshTtl; drives the re-refresh cadence (expired-row pass picks rows up after this).
public TimeSpan RefreshTtl { get; set; } = TimeSpan.FromHours(24);

// Caps the expires_at < NOW() scan per tick — bounds BQ read + how much work one tick enqueues, so a large expired backlog drains over several ticks instead of one huge run.
public int ExpiredScanBatchSize { get; set; } = 500;

// Accounts per batched Mongo $in/$group aggregation — bounds the $in list size and the per-batch $group working set (too large risks slow pipelines / memory pressure even with allowDiskUse).
public int AggregationBatchSize { get; set; } = 300;

// How many batches aggregate + upsert concurrently within one tick — caps simultaneous Mongo load and Storage Write API appends; the in-tick fan-out limit.
public int MaxConcurrentBatches { get; set; } = 4;

// Lookback for the daily invoices discovery sweep — the proof-of-life window (only accounts that invoiced within this many days are candidates).
public int DiscoveryWindowDays { get; set; } = 90;
```
All additive with defaults — existing config keeps binding.

#### 1.4 Config
`appsettings.json`:
- `ConnectionStrings:Mongo` — empty `""` locally; resolved per-env from GSM in prod/stage. **The logical DB name is part of this connection string** (e.g. `mongodb://host/invoicesDB`) — no separate DB-name config (the factory reads it from the URL).
- Expand `Analyses:Metrics` with the new knobs (`RefreshTtl`, `ExpiredScanBatchSize`, `AggregationBatchSize`, `MaxConcurrentBatches`, `DiscoveryWindowDays`).

**NOT changed:** `Analyses:BigQuery` (keep `DatasetId = ai_analysis_v2` — migration uses the configured value), `Analyses:Hangfire`, `ChatSettings`.

---

### Step 2: Domain contracts

**Files (all new, `Analyses.Domain`):**
- `Repositories/IAccountMetricsRepository.cs`
- `Models/AccountMetricsRow.cs` (all-nullable)
- `Services/IMetricsCollector.cs`
- `Services/IAccountDiscovery.cs`

Pure contracts — no Mongo / BigQuery types leak in. **No `SubjectRef`** — the table is account-only, so `account_id` strings are used throughout (simplification beyond the reference; see `overview.md` § Decisions).

#### 2.1 `AccountMetricsRow`
- Flat record keyed on `string AccountId` (+ business_name + 8 numeric + 2 bool + distinct_addresses + expires_at). **All metric fields nullable** (`int?`/`double?`/`bool?`) — null = "no signal", preserved end-to-end (reference §2). Full shape in `overview.md` § Data contracts.

#### 2.2 Repository interface
One interface covers all `account_metrics` access — writes, the expired-row scan, and net-new isolation (the reference's separate `IAccountMetricsReader` is folded in).
```csharp
public interface IAccountMetricsRepository      // all account_metrics access (BigQuery)
{
    Task UpsertManyAsync(IReadOnlyCollection<AccountMetricsRow> rows, CancellationToken ct);  // one AppendRows per call (only write path; no single-row method — unused)
    Task<IReadOnlyList<string>> GetExpiredAsync(int batchSize, CancellationToken ct);         // expires_at < NOW()
    // net-new = candidates minus existing account_metrics.account_id; pull existing once, subtract in-memory.
    Task<IReadOnlyList<string>> ExceptExistingAsync(IReadOnlyCollection<string> candidateAccountIds, CancellationToken ct);
}
```

#### 2.3 Signal + discovery interfaces
`IAccountDiscovery` is split into sweep + eligibility (reference §2); the job orchestrates the `EXCEPT` between them.
```csharp
public interface IMetricsCollector
{
    Task<IReadOnlyList<AccountMetricsRow>> BuildBatchAsync(IReadOnlyCollection<string> accountIds, DateTimeOffset analyzedAt, CancellationToken ct);
}

public interface IAccountDiscovery
{
    Task<IReadOnlyList<string>> SweepActiveAccountsAsync(int windowDays, CancellationToken ct);          // invoices sweep
    Task<IReadOnlyList<string>> FilterEligibleAsync(IReadOnlyCollection<string> accountIds, CancellationToken ct);  // accounts eligibility
}
```

---

### Step 3: Mongo connection + read helpers + Infrastructure DI shell

**Files (all new, `Analyses.Infrastructure`):**
- `Mongo/MongoDatabaseFactory.cs`
- `Mongo/BsonReads.cs`
- `DependencyInjection.cs` (`AddAnalysesInfrastructure`)

> `Analyses.Infrastructure` references `Analyses.Domain` only — `MetricsOptions` lives in Domain and is registered by `AddAnalysesApplication`; the collectors inject the concrete instance.

#### 3.1 `MongoDatabaseFactory`
- Static factory: `Create(connectionString)` builds **one** `IMongoDatabase` via `MongoClient(MongoUrl.Create(connStr)).GetDatabase(url.DatabaseName)`. **The DB name comes from the connection-string URL** (no separate `MongoOptions` — reference shape); throws if the URL omits it. **No `MongoClientSettings` tuning** — read-preference etc. ride the URI.
- Mongo-absent is handled in DI (skip registration when the connection string is empty), **not** in the factory — so the factory can assume a valid string. See `overview.md` § Concerns "No Mongo in local dev".

#### 3.2 `BsonReads`
Null-tolerant static readers over `BsonDocument` for aggregation result docs: `Double`/`Int`/`Bool`/`Str`, treating `BsonNull`/missing as C# null. Centralises the "older docs omit fields" rule (null = "no signal", never coerced to 0).

#### 3.3 `AddAnalysesInfrastructure(IServiceCollection, IConfiguration)`
DI shell. (Filled in Steps 4–5) registers the `IMongoDatabase` + the collectors + `IMetricsCollector` + `IAccountDiscovery`. Does **not** touch `MetricsOptions` — that's owned by `AddAnalysesApplication` (the collectors inject the concrete `MetricsOptions` singleton it registers).
- **Mongo is a required dependency** — the `IMongoDatabase` is registered **lazily** (built on first resolve) so a Mongo-less boot or the `migrate` CLI never opens it; the collectors + discovery are always registered. The tick is scheduled purely on `Analyses:Metrics:Enabled` (Step 8), so a Mongo-less env just leaves it disabled.

---

### Step 4: Signal collectors (batched) — the read path core

**Files (all new):**
- `Analyses.Infrastructure/Metrics/MetricWindow.cs`
- `Analyses.Infrastructure/Metrics/Collectors/`: `InvoiceMetricsCollector.cs`, `EstimateMetricsCollector.cs`, `ClientMetricsCollector.cs`, `AccountMetricsCollector.cs` (each with its own `*MetricsResult` record + static `Empty`, co-located — no separate `Results.cs`)
- `Analyses.Infrastructure/Metrics/Collectors/MetricsCollector.cs` (façade, implements `IMetricsCollector`)

Batched form throughout: parameterised `$match {AccountId: {$in: batch}}` (typed `Builders`) + static spec pipeline stages (`BsonDocument.Parse`) + `$group {_id: "$AccountId"}` + `ToListAsync` → `Dictionary<accountId, result>`. Pipeline shapes transcribed verbatim from `Tofu.Docs/.../analyses/metrics.md` § Per-metric query plan (group-by-account form). `AllowDiskUse = true` on every aggregate.

#### 4.1 `MetricWindow`
`static MetricWindow From(DateTimeOffset analyzedAt)` exposing `Start30d`, `Start12mo`, `End` (= analyzedAt), `Start90d` (discovery). Window is `analyzedAt - N ≤ field < analyzedAt`.

#### 4.2 `InvoiceMetricsCollector` — `invoices`
Two aggregations (both batched, grouped by `$AccountId`):
- **30d volume:** `$match` (`AccountId ∈ batch`, `IsDeleted ∈ [false,null]`, `Date` in 30d) → `$group` count/`$avg TotalAmount`/`$stdDevPop`/`$avg $size Items` → `$project` `invoice_count_30d` / `avg_invoice_amount` / `invoice_amount_variance_cv` (`sd/mean`, null when mean≤0) / `avg_line_items_per_invoice`.
- **12mo repeat:** group by `{account, clientId}` (coalesce `ClientId` ?? `Client.CatalogId`, drop null-client rows), then re-group by account → `repeat_customer_ratio`, `avg_days_between_repeats`.
Returns `Dictionary<string, InvoiceMetricsResult>`.

#### 4.3 `EstimateMetricsCollector` — `estimates`
12mo window; `$match` (`AccountId ∈ batch`, `IsDeleted ∈ [false,null]`, Date) → `$group` total + converted (`InvoiceId != null`) → `estimate_count`, `estimate_to_invoice_rate` (null when no estimates).

#### 4.4 `ClientMetricsCollector` — `clients`
`$match` (`AccountId ∈ batch`, `DeletedAt: null`) → per-doc B2B regex over `Info[].Name` (`LLC|Inc|Corp|Property Management|LLP|Ltd`, case-insensitive) + address normalisation (`$trim`/`$toLower`/collapse) → `$group _id:$AccountId` → `b2b_clients_present`, `distinct_addresses`, `multi_address_work` (≥2). Carry `AccountId` through `$project` before grouping.

#### 4.5 `AccountMetricsCollector` — `accounts`
`Find {_id: {$in: batch}}` projecting `BusinessName` → `Dictionary<accountId, string?>`. No aggregation. (`accounts._id` is a **string**, not an ObjectId — confirmed against `Invoices.Backend` `Account.Id`; see `overview.md` § Risk Points, so the account-id strings filter `_id` directly.)

#### 4.6 `MetricsCollector` façade
`BuildBatchAsync(IReadOnlyCollection<string> accountIds, …)`: run the four collectors concurrently (`Task.WhenAll`), then compose one `AccountMetricsRow` per requested account id, substituting `*MetricsResult.Empty` for misses (null metrics) — preserves the null-vs-zero rule and guarantees one row per account with **no cross-account bleed**. `ExpiresAt = analyzedAt + RefreshTtl`.

---

### Step 5: Discovery funnel

**Files (all new, `Analyses.Infrastructure/Metrics/`):**
- `AccountDiscovery.cs` (implements `IAccountDiscovery`)

#### 5.1 `AccountDiscovery` (split — sweep + eligibility)
Two methods; the `EXCEPT` step between them is orchestrated by the job (Step 8), not here (reference §2):
- `SweepActiveAccountsAsync(windowDays)` → `invoices` sweep: `$match {CreatedTime ≥ now-windowDays, IsDeleted ∈ [false,null]}` → `$group {_id: "$AccountId"}`. Comment the `CreatedTime`-vs-`Date` choice inline (spec open question; default `CreatedTime`).
- `FilterEligibleAsync(accountIds)` → batched `accounts` lookup filtering `_id ∈ accountIds` (string `_id` — see §4.5), alive (`IsDeleted ∈ [false,null]`), `IsTechnical=false`.
No FSM trim (that's the analyze stage).

> **No daily guard** — the full funnel runs every tick (`MetricsRefreshJob.DiscoverAsync`). Discovery is idempotent (read-only sweep, `EXCEPT` dedupes net-new, CDC upsert is repeat-safe) and cheap at current volume, so hourly is fine. Re-throttle (durable Postgres claim, or a dedicated daily Hangfire recurring job) only if the sweep cost grows.

---

### Step 6: BigQuery write path (Storage Write API CDC)

**Files (all new, `Analyses.Persistence`):**
- `Protos/account_metrics.proto`
- `BigQuery/StorageWriteApiHelper.cs`
- `BigQuery/BigQueryMappings.cs`
- `Repositories/BigQueryAccountMetricsRepository.cs` (implements `IAccountMetricsRepository`)

Heaviest step — isolate it. This is where the **CDC NULL-PK risk** (`overview.md`) is verified.

#### 6.1 `account_metrics.proto` + codegen
Proto message mirroring the **account-only** table columns (`account_id` + business_name + 11 metrics + 3 timestamps; **no** `master_user_id`/`platform_user_id`), snake_case → proto fields, compiled via `Grpc.Tools` `<Protobuf Include="Protos\*.proto" GrpcServices="None" />` (glob — picks up future BQ protos too). Include the `_CHANGE_TYPE` handling per BQ CDC (pseudo-column set on the append, not a table column). Field types: `int64`/`double`/`bool`/`string`, all `optional` (proto2) so unset ≠ 0 for nullable metrics.

#### 6.2 `StorageWriteApiHelper`
Wraps `BigQueryWriteClient` default-stream `AppendRows`: builds the `ProtoSchema`/`ProtoRows` from the generated descriptor, one `AppendRows` call per batch (default stream auto-commits; `_CHANGE_TYPE = "UPSERT"` is set per row by the mapper, not here). Signature: `Task AppendManyAsync(string projectId, string datasetId, string tableId, IReadOnlyList<IMessage> rows, DescriptorProto descriptor, CancellationToken ct)` — no-op on empty; throws if the append response carries an error.

#### 6.3 `BigQueryAccountMetricsRepository`
Implements the full `IAccountMetricsRepository` — writer, expired scan, and net-new `ExceptExistingAsync`. Row→proto mapping is delegated to `BigQueryMappings.ToProto` (null metric → unset field ⇒ NULL; timestamps → INT64 micros) — a pure static mapper, unit-testable without BigQuery. `UpsertManyAsync` stamps a single `updated_at` for the batch and makes one `StorageWriteApiHelper.AppendManyAsync` call (no single-row method). `GetExpiredAsync(batchSize)` runs the `expires_at < CURRENT_TIMESTAMP()` query → `account_id` strings; `ExceptExistingAsync(candidates)` pulls existing ids once and subtracts in-memory (sidesteps IN-list limits). Table path from `BigQuerySettings` (`{ProjectId}.{DatasetId}.account_metrics`).

> **No NULL-PK verification needed** (single `account_id` PK — see `overview.md` § Concerns). The CDC upsert key is one non-null column, so matching is unambiguous; the reference's 3-column-NULL-PK verify-then-fallback task is dropped.

---

### Step 7: `account_metrics` migration + Persistence DI

**Files:**
- `Migrations/Modules/BigQuery/V001_CreateAccountMetrics.cs` (new) — **replaces** `V001_Bootstrap.cs` (delete the bootstrap file)
- `Analyses.Persistence/DependencyInjection.cs`

> `ExceptExistingAsync` and the expired scan both live on `BigQueryAccountMetricsRepository` (Step 6.3) — no separate reader class/interface.

#### 7.1 `V001_CreateAccountMetrics` (replaces `V001_Bootstrap`)
DDL = the `account_metrics` `CREATE TABLE IF NOT EXISTS` from `overview.md` § Data contracts: **`account_id STRING NOT NULL` as the sole subject column** (`master_user_id`/`platform_user_id` **dropped** — override of `storage.md` § Q1; account-only table, multi-subject deferred to a separate table) + business_name + 8 numeric + 2 bool + distinct_addresses + expires_at/updated_at (no `analyzed_at` — dropped; see `overview.md` § Data contracts), **`PRIMARY KEY (account_id) NOT ENFORCED`** (single-column — removes the reference's 3-column NULL-PK risk; see `overview.md` § Concerns), `PARTITION BY DATE_TRUNC(updated_at, MONTH)` (spec-faithful — **not** the reference's `DATE(analyzed_at)`), `CLUSTER BY account_id`, `OPTIONS(max_staleness = INTERVAL {settings.MaxStaleness}, description=…)`. Keep `Name = "V001_CreateAccountMetrics"` and follow the `V001_Bootstrap` class shape (`IOptions<BigQuerySettings>` ctor, `ExecuteQueryAsync(ddl)`).

> **`V001_Bootstrap` replacement note** (`overview.md` § Internal Breaking Changes): renaming means a fresh DB applies cleanly. Any dev DB that already ran `V001_Bootstrap` keeps a stale `schema_bootstrap` table + history row — drop both manually. Confirm no environment has applied it before relying on the clean path (WEB-1526 is unmerged, so this should hold).

#### 7.2 Persistence DI
In `AddAnalysesPersistence`: register `IAccountMetricsRepository` → `BigQueryAccountMetricsRepository`, the `BigQueryWriteClient`/`StorageWriteApiHelper`, and **swap** `AddTransient<IBigQueryMigration, V001_Bootstrap>()` → `V001_CreateAccountMetrics`. (Registration detail implied.)

---

### Step 8: Job orchestration + composition root

**Files:**
- `src/Analyses/Analyses.Application/Jobs/MetricsRefreshJob.cs`
- `src/Analyses/Analyses.Application/DependencyInjection.cs` (only if new deps need explicit registration; the job is already `AddScoped`)
- `src/Tofu.AI.Api/Program.cs`

#### 8.1 `MetricsRefreshJob.RunAsync`
Replace the stub body. Inject `IAccountMetricsRepository` (upsert + expired scan + `ExceptExistingAsync`), `IAccountDiscovery`, `IMetricsCollector`, the concrete `MetricsOptions` singleton, `ILogger`. Keep `[AutomaticRetry(Attempts=3)]` + `[DisableConcurrentExecution(600)]`. The discovery funnel (sweep → EXCEPT → eligibility) is orchestrated here, in a private `DiscoverAsync`, run every tick (reference §2).
```text
RunAsync(ct):
    expired    = repository.GetExpiredAsync(ExpiredScanBatchSize)         # account_id[]
    discovered = await DiscoverAsync(ct)                                  # account_id[] (every tick)
    queue      = distinct(expired ∪ discovered)                          # account_id strings
    Parallel.ForEachAsync(queue.Chunk(AggregationBatchSize), MaxConcurrentBatches, batch =>
        rows = collector.BuildBatchAsync(batch, now)
        repository.UpsertManyAsync(rows))                                # one AppendRows per batch

DiscoverAsync(ct):
    active  = discovery.SweepActiveAccountsAsync(DiscoveryWindowDays)
    netNew  = repository.ExceptExistingAsync(active)                     # pull existing once, subtract in-memory
    return  discovery.FilterEligibleAsync(netNew)                        # account_id[]
```
Bound concurrency with `Parallel.ForEachAsync` (`MaxDegreeOfParallelism = MaxConcurrentBatches`); `ct` is observed per batch for a clean SIGTERM abort. Structured per-tick + per-batch logs. A failed tick logs + rethrows → Hangfire retry. `RegisterAnalysesRecurringJobs` schedules the tick when `Analyses:Metrics:Enabled` (Mongo is a required dependency, registered lazily — see Step 3.3).

#### 8.2 Composition root
`Program.cs` — add `.AddAnalysesInfrastructure(builder.Configuration)` to the existing `AddAnalysesPersistence().AddAnalysesApplication()` chain (line ~93–95). Recurring-job registration is already wired (line 121); no change. CLI `migrate` short-circuit already skips Hangfire — unchanged.

---

### Step 9: Build verification

```bash
dotnet build -warnaserror
```
Verify the solution builds clean under `TreatWarningsAsErrors` — all new/changed projects compile and references/packages resolve. A smoke `dotnet run -- migrate --dryrun` is a useful extra check that the composition root is valid and the migration runner resolves.

---

## Execution Checklist

| # | Task | Files | Status |
|---|------|-------|--------|
| 1 | New projects (Domain + Infrastructure) + packages + `MetricsOptions` + config (1.1–1.4) | `Analyses.Domain/*`, `Analyses.Infrastructure/*`, `MetricsOptions.cs`, `appsettings*.json` | ✅ done |
| 2 | Domain contracts (AccountMetricsRow, repo/service/discovery interfaces) | `Analyses.Domain/Repositories`, `/Models`, `/Services` | ✅ done |
| 3 | Mongo factory + BsonReads + `AddAnalysesInfrastructure` shell | `Analyses.Infrastructure/Mongo/*`, `DependencyInjection.cs` | ✅ done |
| 4 | Batched metric collectors + `MetricWindow` + results + façade (4.1–4.6) | `Analyses.Infrastructure/Metrics/Collectors/*`, `Metrics/MetricWindow.cs` | ✅ done |
| 5 | `AccountDiscovery` (sweep + eligibility) | `Analyses.Infrastructure/Metrics/*` | ✅ done |
| 6 | BigQuery write path: proto + `StorageWriteApiHelper` + `BigQueryMappings` + repository | `Analyses.Persistence/Protos/*`, `/BigQuery/*`, `/Repositories/*` | ✅ done |
| 7 | `V001_CreateAccountMetrics` (replaces `V001_Bootstrap`) + Persistence DI | `/Migrations/Modules/BigQuery/*`, `DependencyInjection.cs` | ✅ done |
| 8 | `MetricsRefreshJob` orchestration + `Program.cs` `AddAnalysesInfrastructure` | `Analyses.Application/Jobs/MetricsRefreshJob.cs`, `DependencyInjection.cs`, `Program.cs` | ✅ done |
| 9 | Build verification (`dotnet build -warnaserror`) | — | |

## Decisions → Steps traceability

| Decision (overview) | Step(s) |
|---|---|
| Port-and-adapt from `feature/WEB-1523_metrics`, batched collectors | 4, 5, 6, 8 |
| **Account-only table: drop `master_user_id`/`platform_user_id`, single `account_id` PK** (override of reference + storage.md; multi-subject → separate table later) | 6.1, 6.3, 7.2 |
| Metrics stage only (no fsm_fit/view/LLM) | 7 (only `account_metrics`), absence elsewhere |
| Two new projects (Domain + Infrastructure) | 1 |
| Storage Write API CDC | 6 |
| All-nullable `AccountMetricsRow` (ref §2) | 2.1 |
| Single `IAccountMetricsRepository` (writes + expired scan + `ExceptExistingAsync`); no separate reader interface | 2.2, 6.3 |
| **Drop `SubjectRef` — `account_id` strings throughout** (simplification beyond reference) | 2, 4.6, 6.3, 8.1 |
| Discovery split `Sweep` + `FilterEligible`, funnel in job (ref §2) | 2.3, 5.1, 8.1 |
| `account_id` queue element (no per-account `BuildAsync` — batched only) | 2.3, 4.6, 8.1 |
| Mongo-absent → skip collector/discovery registration (ref §2) | 3.3, 8.1 |
| `MetricsOptions` in Domain, owned by `AddAnalysesApplication` (bind + concrete singleton); Infrastructure refs Domain only | 1.3, 3.3 |
| Run discovery every tick — no daily guard (revised) | 5.1, 8.1 |
| Mongo required; tick scheduled on `Enabled` only (revised) | 3.3, 8.1 |
| Spec-faithful `updated_at`/MONTH partition + table `description` (ref §4) | 7.2 |
| Keep `Enabled`/`Cadence` on `MetricsOptions` (diverge from ref §5; WEB-1526 needs them) | 1.4 |
| `V001_Bootstrap` → `V001_CreateAccountMetrics` | 7.2 |
| Plan files in `Tofu.AI.Backend/Docs/features/WEB-1527` | n/a (doc location) |
