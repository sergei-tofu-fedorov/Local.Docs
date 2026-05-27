# WEB-1523 — Migrations

> **✅ Shipped (WEB-1526), matches code.** The framework as built is exactly this: `IModuleMigration` (`ModuleName` + `ExecuteAsync(bool dryRun, CancellationToken ct)`), `ModuleMigrationsRunner` (resolves all modules, honours `Analyses:Migrations[name].Enabled`, `--dryrun`, rethrows on failure), `AddModuleMigration<T>()`, and the `Modules/BigQuery/` module (`BigQueryModuleMigration` → `BigQueryMigrationsRunner` → `IBigQueryMigration` steps + `migration_history` via `MERGE`). The one shipped step is **`V001_CreateAccountMetrics`** (the bootstrap stub `V001_Bootstrap` was replaced). Two corrections to the layout below: there is no `WebApplicationExtensions.cs` — the `migrate` invocation helper (`RunApplicationOrDatabaseUpdateOnlyAsync` / `RunModuleMigrationsAsync`) lives in `src/Tofu.AI.Api/DatabaseUpdate.cs`; and the BigQuery dataset is `ai_analysis_v2`.

A generic, store-agnostic **module-migration framework** for `Tofu.AI.Backend`, mirroring the `IModuleMigration` pattern already proven in `Invoices.Backend`. One runner applies every owned schema change — BigQuery today, Postgres or Mongo if/when the service owns them — through a single contract and a single `dotnet Tofu.AI.Api.dll migrate` entry point. A migration is "a module's schema change"; the store behind it is an implementation detail of that module, never of the framework.

> **Scope guardrail.** Mechanism only — the contract, the runner, registration, invocation. Schema *semantics* (what the BigQuery tables/views mean) live in [`storage.md`](storage.md); the *deploy wiring* (the migrate Job / gate) in [`ci-cd.md`](ci-cd.md). Those win on conflict.

## Decision

- **Mirror `Invoices.Backend`'s contract verbatim.** `IModuleMigration` = `string ModuleName` + `Task ExecuteAsync(bool dryRun, CancellationToken ct)`. No store type anywhere in the signature — this is the seam that lets any backing store plug in.
- **One stateless runner.** `ModuleMigrationsRunner` resolves every registered `IModuleMigration`, honours a per-module `Enabled` flag, supports `--dryrun`, and calls each. It knows nothing about BigQuery / Postgres / Mongo and tracks no applied state.
- **The store client is constructor-injected**, never in the method signature. Each concrete module migration takes its client (`BigQueryClient`, a `DbContext`, `IMongoDatabase`) via DI — exactly as `Invoices.Backend`'s `JobsModuleMigration` injects its `DbContext`.
- **Applied-tracking is the module's job, per store.** BigQuery → its own `migration_history` table; EF/Postgres → `__EFMigrationsHistory` (via `MigrateAsync`); Mongo → idempotent index creation (+ optional `_migrations` marker). The runner never owns it.
- **Forward-only, idempotent.** No down/rollback; recovery is a new forward migration. Guarded DDL (`IF NOT EXISTS` / `CREATE OR REPLACE`) so a partial re-run is always safe.
- **One registration gesture, one invocation.** `services.AddModuleMigration<T>()` to register; `app.RunModuleMigrationsAsync(args)` from the `migrate` CLI path. Adding a store is *one class + one registration* — no runner or CLI change.
- **BigQuery is the first module, not the framework.** Its fine-grained `V###` DDL steps + `migration_history` stay private inside `BigQueryModuleMigration`; the framework sees one uniform `IModuleMigration`.

Everything below is supporting detail.

## Code layout

```
src/Analyses/Analyses.Persistence/Migrations/
├── IModuleMigration.cs               # contract: ModuleName + ExecuteAsync(dryRun, ct)
├── IModuleMigrationsRunner.cs        # RunAsync(args, ct)
├── ModuleMigrationsRunner.cs         # resolves all IModuleMigration; per-module Enabled; --dryrun; store-agnostic
├── ModuleMigrationsOptions.cs        # Modules[name].Enabled map, bound from config
├── ServiceCollectionExtensions.cs    # AddModuleMigration<T>()
│   # (no WebApplicationExtensions here — the `migrate` invocation helper lives in
│   #  src/Tofu.AI.Api/DatabaseUpdate.cs: RunApplicationOrDatabaseUpdateOnlyAsync → RunModuleMigrationsAsync)
└── Modules/
    ├── BigQuery/                                  # first concrete module
    │   ├── BigQueryModuleMigration.cs             # IModuleMigration "bigquery"; injects BigQueryClient + settings
    │   ├── IBigQueryMigration.cs                  # private DDL step: Name + ExecuteAsync(client, projectId, datasetId, ct)
    │   ├── BigQueryMigrationsRunner.cs            # private: ensure dataset + migration_history; run V### in Name order; record
    │   └── V001_CreateAccountMetrics.cs           # shared metrics table — ships with the framework (v1)
    │   # later, with the fsm_fit analysis feature itself:
    │   #   V002_CreateAccountFsmFit.cs            # fsm_fit result table — not yet in code
    │   #   V003_CreateVFsmFit.cs                  # v_fsm_fit view — not yet in code
    ├── Postgres/                                  # future module — no code until the service owns a relational table
    │   └── <Module>PgModuleMigration.cs           # IModuleMigration; injects DbContext; EF MigrateAsync (≈ JobsModuleMigration)
    └── Mongo/                                     # future module — no code until the service owns a collection/index
        └── <Name>MongoModuleMigration.cs          # IModuleMigration; injects IMongoDatabase; idempotent CreateIndexes
```

The seam is `ModuleMigrationsRunner` → `IModuleMigration`. Each `Modules/<Store>/` folder is a self-contained module; the runner sees a uniform list and never reaches inside one. `Postgres/` and `Mongo/` are reserved by structure — they hold no code until a concrete owned store appears, but they make the framework multi-store by construction, not by retrofit. The CLI entry stays `src/Tofu.AI.Api/DatabaseUpdate.cs` (`migrate` → `RunModuleMigrationsAsync`).

## Contracts

Verbatim parity with `Invoices.Backend` (`Src/Invoices.Common/Modules/Migrations` + `Src/Invoices.Api/Modules/Migrations`); signatures only:

```csharp
// store-agnostic contract — every module migration implements this, whatever its backing store
public interface IModuleMigration
{
    string ModuleName { get; }
    Task ExecuteAsync(bool dryRun, CancellationToken ct);
}

public interface IModuleMigrationsRunner
{
    Task RunAsync(string[] args, CancellationToken ct = default);
}

public sealed class ModuleMigrationsOptions
{
    public Dictionary<string, ModuleMigrationConfig> Modules { get; set; } = new();
}
public sealed class ModuleMigrationConfig { public bool Enabled { get; set; } = true; }

// registration + invocation
services.AddModuleMigration<TMigration>();        // AddScoped<IModuleMigration, TMigration>()
await app.RunModuleMigrationsAsync(args, ct);     // scope → IModuleMigrationsRunner.RunAsync
```

`ModuleMigrationsRunner` behaviour matches `Invoices.Backend`'s: resolve `IEnumerable<IModuleMigration>`; skip any where `Options.Modules[ModuleName].Enabled == false`; detect `--dryrun` from args; `ExecuteAsync` each in turn; log per-module start/finish; rethrow on any failure so the migrate Job fails the deploy.

## Module migrations (one per owned store)

Each store is exactly one `IModuleMigration`; the client is constructor-injected; tracking is the module's own concern.

- **BigQuery (v1)** — `BigQueryModuleMigration` (`ModuleName = "bigquery"`): injects `BigQueryClient` + `BigQuerySettings`; `ExecuteAsync` delegates to the private `BigQueryMigrationsRunner` (ensure dataset → ensure `migration_history` → run unapplied `V###` in `Name` order → record). `dryRun` logs the pending steps without executing DDL.
- **Postgres (future)** — `<Module>PgModuleMigration`: injects the owned `DbContext`; `ExecuteAsync` = `CREATE SCHEMA IF NOT EXISTS` + `Database.MigrateAsync` — a near-copy of `JobsModuleMigration`. Tracking is EF's `__EFMigrationsHistory`. (Hangfire's `analyses` schema is auto-created at startup and is *not* a migration.)
- **Mongo (future)** — `<Name>MongoModuleMigration`: injects `IMongoDatabase`; `ExecuteAsync` creates collections/indexes idempotently (`CreateIndexes` no-ops when the index already exists). `dryRun` lists the intended indexes.

All three implement the same contract, register the same way, and run from the same runner. The framework does not grow when a store is added — only the `Modules/` set does.

## Adding a module migration

1. Add `Modules/<Store>/<Name>ModuleMigration.cs : IModuleMigration`; inject the store client via constructor; pick a stable `ModuleName`.
2. Implement `ExecuteAsync(dryRun, ct)` idempotently; honour `dryRun` (log intent, mutate nothing).
3. Register with `services.AddModuleMigration<T>()` in the persistence DI.
4. *(Optional)* add a `Modules[ModuleName].Enabled` config entry to gate it per environment.

For BigQuery specifically, a new DDL step is `Modules/BigQuery/V00N_<Description>.cs : IBigQueryMigration`, guarded by `IF NOT EXISTS` / `CREATE OR REPLACE`; the `Name` prefix orders it. No change to `BigQueryModuleMigration` or either runner.

## BigQuery best practices

Authoring rules for `V###` steps. BigQuery is a columnar analytical store, **not** a relational OLTP engine — the EF/Postgres migration habits don't transfer. There is no first-class EF Core provider; steps are hand-written GoogleSQL DDL run through `BigQueryClient`. Schema *semantics* still live in [`storage.md`](storage.md); this is mechanism-level guidance only.

- **Double-guard every step.** `migration_history` skips an already-applied `V###`, but the DDL itself must also be idempotent (`CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE VIEW`, `ADD COLUMN IF NOT EXISTS`). The two layers are independent: a step whose DDL succeeded but whose history INSERT failed re-runs on the next deploy, and only the guarded DDL keeps that re-run safe.
- **Forward-only, additive by default.** No down step exists; recovery is a new `V00N`. Favour `ADD COLUMN` and relaxing `REQUIRED`→`NULLABLE`. `DROP COLUMN` / `RENAME COLUMN` are supported now (the older "BQ can't drop/rename" advice is out of date) but they're destructive against historical data — treat them as deliberate, reviewed changes, not routine.
- **Partitioning and clustering are immutable after create.** You cannot `ALTER` the partition key or clustering of an existing table. Changing either means a rebuild: new table → `CREATE TABLE AS SELECT` backfill → swap, expressed as its own `V00N`. Get `PARTITION BY` (usually a date column) and `CLUSTER BY` right in the creating step.
- **Type changes are limited to safe widenings** (e.g. `INT64`→`NUMERIC`→`BIGNUMERIC`). Arbitrary type changes require create-new + backfill, same as the partitioning case.
- **Set cost guards explicitly in the creating DDL** — partition expiration (`partition_expiration_days`) and, where every read legitimately filters by the partition column, `require_partition_filter`. A long-lived metrics table with an `expires_at` is a candidate for partition expiration so old partitions drop automatically.
- **Identifiers can't be parameterized — only values can.** `projectId` / `datasetId` / table names must be string-interpolated into the DDL, so they must come from trusted config (`BigQuerySettings`), never request input. Use `BigQueryParameter` for any data values (as `migration_history` writes already do).
- **Match dataset location on first create.** A location mismatch between dataset and job is a common, hard-to-diagnose migration failure. The runner already creates the dataset with `Location` from settings — keep all `V###` work inside that one dataset.
- **`migration_history` is plain DML at migration volume** — fine, but DML carries per-table quotas, so don't fold high-frequency writes into a migration step. Migrations are low-volume and run at deploy time only.
- **Prefer a real BigQuery dry run for validation.** The job API's `DryRun` flag validates DDL syntax and surfaces schema/permission errors without executing. The current `--dryrun` only logs step names; validating the actual SQL via a dry-run job would catch a broken `V###` before it reaches a deploy gate (see [`ci-cd.md`](ci-cd.md)).
- **Expect transient errors.** BigQuery jobs can return transient `503`/`500`s; a thin retry (Polly) around the DDL/DML calls makes the migrate Job resilient without masking real failures.

## Open questions

- [ ] **View-evolution contract.** A `CREATE OR REPLACE VIEW` step recorded in `migration_history` runs once, so editing the view definition won't re-apply. Decide: views evolve via a new `V00N` step (clean audit trail), or views are excluded from history so they always re-sync (true desired-state). Reflect the choice in [`storage.md`](storage.md) too.
- [x] ~~**Does v1 own any Postgres or Mongo schema**~~ **Resolved (as built):** no. Hangfire auto-creates its `analyses` PG schema at startup; Mongo is read-only. BigQuery is the only migration module — `Modules/Postgres` and `Modules/Mongo` don't exist in code (reserved by design, not scaffolded). The framework is multi-store by contract, single-store in v1.
- [ ] **Concurrency** — BigQuery's `migration_history` has no key; two simultaneous runs could double-record (idempotent DDL keeps it safe; the skip set dedups). The deploy workflow serialises per target (`concurrency: ${{ inputs.target }}`), largely precluding it — accept, or add a uniqueness guard?
