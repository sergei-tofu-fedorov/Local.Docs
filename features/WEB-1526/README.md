# WEB-1526 — FSM-fit analysis layer + CI/CD migrate gate

**Status:** in review
**Parent feature:** [WEB-1523 — AI-powered user analysis](../WEB-1523-segmentation/README.md)
**Repos:** `Tofu.AI.Backend`, `Invoices.Kubernetes`

## Goal

Add the FSM-fit analysis layer to `Tofu.AI.Backend`:

- **`Analyses.*` module** — in-process Hangfire + BigQuery storage.
- **`migrate` CLI mode** — store-agnostic migration framework, **same as `Invoices.Backend`**.
- **Consolidated deploy** — single GitHub Actions path with a pre-deploy migrate gate.
- **Presidio sidecars** — redaction analyzer/anonymizer on the tofu-ai-api pod.

## Why

- **One deploy path.** Cloud Build and the GitHub Actions workflow overlap, and neither runs a migration. Retire Cloud Build; GitHub Actions becomes the only path.
- **A migration step before each rollout.** Analysis data lives in BigQuery; its DDL must apply — and be allowed to fail the deploy — ahead of `kubectl set image`.

## Code layout

```
Tofu.AI.Backend/
├─ src/
│  ├─ Analyses/
│  │  ├─ Analyses.Application/
│  │  │  ├─ DependencyInjection.cs              # AddAnalysesApplication + RegisterAnalysesRecurringJobs
│  │  │  ├─ MetricsOptions.cs                   # Analyses:Metrics (Enabled, Cadence)
│  │  │  └─ Jobs/MetricsRefreshJob.cs           # stub recurring job (logs only)
│  │  └─ Analyses.Persistence/
│  │     ├─ DependencyInjection.cs              # AddAnalysesPersistence: BigQuery client + migrations
│  │     ├─ BigQuery/BigQuerySettings.cs        # Analyses:BigQuery
│  │     └─ Migrations/
│  │        ├─ IModuleMigration.cs              # store-agnostic contract (parity with Invoices.Backend)
│  │        ├─ ModuleMigrationsRunner.cs        # resolves modules, honours Enabled, --dryrun, rethrows
│  │        ├─ ModuleMigrationsOptions.cs       # Analyses:Migrations
│  │        ├─ ServiceCollectionExtensions.cs   # AddModuleMigration<T>()
│  │        └─ Modules/BigQuery/
│  │           ├─ BigQueryModuleMigration.cs    # IModuleMigration "bigquery"
│  │           ├─ BigQueryMigrationsRunner.cs   # ensure dataset → migration_history → run V### → record
│  │           └─ V001_Bootstrap.cs             # stub DDL step
│  └─ Tofu.AI.Api/
│     ├─ Program.cs                             # wiring; Hangfire & routes skipped in CLI mode
│     ├─ DatabaseUpdate.cs                      # `migrate [--dryrun]` dispatch vs RunAsync
│     ├─ appsettings.json                       # ConnectionStrings:Analyses + Analyses:{Hangfire,BigQuery,Metrics}
│     └─ Hangfire/                              # AnalysesHangfireOptions + HangfireConfiguration
├─ Dockerfile                                   # no ENTRYPOINT — one image runs server or `migrate`
├─ cloudbuild.yaml                              # DELETE
└─ .github/workflows/publish-deploy.yaml        # migrate-job-name + migrate-job-manifest passthrough

Invoices.Kubernetes/overlays/dev/tofu-ai.yaml  # + presidio-analyzer (:3000) + presidio-anonymizer (:5001)
```

## Migrations

- **Module approach — same as `Invoices.Backend`.** `dotnet Tofu.AI.Api.dll migrate` runs the store-agnostic framework ported verbatim: `ModuleMigrationsRunner` resolves every registered `IModuleMigration` and runs each. No store type in the contract (that seam lets any store plug in); the runner is stateless, honours a per-module `Enabled` flag (`Analyses:Migrations`), supports `--dryrun`, and **rethrows on failure so the migrate Job fails the deploy**. Each module injects its own client and owns its own applied-tracking. Adding a store = one class + one `AddModuleMigration<T>()`. BigQuery is the only module in v1. Deep dive: [`migrations.md`](../WEB-1523-segmentation/implementation/migrations.md).
- **BigQuery module — raw SQL.** Each `IBigQueryMigration` is one guarded DDL step (`CREATE TABLE IF NOT EXISTS` / `CREATE OR REPLACE VIEW`) run through `BigQueryClient` — no generation tooling. `BigQueryMigrationsRunner` applies steps in `Name` order (`V001`, `V002`, …): forward-only and idempotent, so recovery is a new step, never a rollback. v1 ships one stub (`V001_Bootstrap`, a throwaway placeholder table); real tables/views (`account_metrics`, `account_fsm_fit`, `v_fsm_fit`, …) land as later `V###` steps.
- **History table.** The module owns `migration_history` (`name`, `applied_at`). Each run: ensure dataset + table exist → read applied names → run unapplied steps in order → record each via `MERGE` (not `INSERT`), so a re-run after a partial failure can't add a duplicate row.

## BigQuery config

Bound from `Analyses:BigQuery` → `BigQuerySettings`; real `ProjectId` + the LLM key come from the GSM secret, not `appsettings`.

- **`ProjectId`** _(required)_ — `[Required]` + `ValidateOnStart`.
- **`DatasetId`** (`ai_analysis_v2`) — target dataset.
- **`Location`** (`US`) — dataset region, **immutable after first migrate**; override per env (e.g. `EU`) for data residency.
- **`MaxStaleness`** (`15 MINUTE`) — read-freshness bound on the CDC-upsert tables; `0 MINUTE` = always fresh but pricier.
- **`ServiceAccountKeyJson`** _(empty)_ — inline SA key; empty → Application Default Credentials.

## Hangfire (single-pod)

Server runs in-process (collapsed-Worker design), via the `IOptions` pattern from `Invoices.Backend` (`Notifications.Infrastructure.Hangfire`).

- **Options** — bind from `Analyses:Hangfire` (`SchemaName`, `RetryCount`, `WorkerCount`, `SchedulePollingInterval`); the connection string stays in `ConnectionStrings:Analyses`, pulled in at registration. `[Required]` + `ValidateOnStart()`, server mode only (`migrate` skips Hangfire, which opens PG eagerly).
- **Schema** — the `analyses` PG schema is auto-created at startup (`PrepareSchemaIfNecessary`), not by the migrate gate.

## Hangfire Jobs

Registered in server mode only via `RegisterAnalysesRecurringJobs(IRecurringJobManager, MetricsOptions)`.

- **`MetricsRefreshJob`** — runs on `Analyses:Metrics:Cadence` (default hourly, `0 * * * *`). **Stub: logs only**; real collection lands with that feature.
- **Toggle** — gated by `Analyses:Metrics:Enabled`: `true` → `AddOrUpdate`, `false` → `RemoveIfExists` (de-registers, not just skips).
- **Hygiene** — `[AutomaticRetry(Attempts = 3)]` + `[DisableConcurrentExecution(timeoutInSeconds: 600)]`.

## Implementation plan

1. [ ] **Projects** — add `Analyses.Application` + `Analyses.Persistence` (net8.0); add to `.sln`, reference from `Tofu.AI.Api`. Siblings — neither references the other.
2. [ ] **BigQuery client** — `BigQuerySettings` + a singleton `BigQueryClient` (inline SA key, else ADC) in `AddAnalysesPersistence`.
3. [ ] **Migration framework** — `IModuleMigration`, runner, options, `AddModuleMigration<T>()` (see [Migrations](#migrations)).
4. [ ] **BigQuery module** — `BigQueryModuleMigration` + `BigQueryMigrationsRunner` + `V001_Bootstrap`; register in `AddAnalysesPersistence`.
5. [ ] **Recurring job** — `MetricsOptions` + stub `MetricsRefreshJob`; `AddAnalysesApplication` + `RegisterAnalysesRecurringJobs` (see [Hangfire Jobs](#hangfire-jobs)).
6. [ ] **Hangfire wiring** — `AnalysesHangfireOptions` + `HangfireConfiguration` (see [Hangfire](#hangfire-single-pod)).
7. [ ] **`migrate` CLI** — `DatabaseUpdate.cs` dispatch; `Program.cs` gates Hangfire/routes/jobs behind `!isCliMode`.
8. [ ] **Config** — `ConnectionStrings:Analyses` + `Analyses:{Hangfire,BigQuery,Metrics}` in `appsettings.json`.
9. [ ] **Retire Cloud Build** — delete `cloudbuild.yaml`.
10. [ ] **Migrate gate** — `publish-deploy.yaml` passes `migrate-job-name`/`migrate-job-manifest`; the Job must pass before `kubectl set image`.
11. [ ] **Secrets** — LLM key + `Analyses:BigQuery` in GSM `tofu-ai-api-secret`; migrate Job + API share secret/SA/image tag.
