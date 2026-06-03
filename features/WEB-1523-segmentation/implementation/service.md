# WEB-1523 — Service

> **Implementation status (2026-05-27) — built vs. designed.**
> **✅ Built (WEB-1526 + WEB-1527), and matching this doc:** single process / single Deployment (`tofu-ai-api-deployment`); in-process Hangfire (client + server + dashboard) on Postgres schema `analyses`, `WorkerCount = 4`, distributed-lock concurrency; the `migrate` CLI + pre-deploy migrate-Job gate; Cloud Build retired in favour of the shared GitHub Actions `publish-deploy.yaml`; BigQuery dataset **`ai_analysis_v2`** (test project `invoicesapp-project-test`); the four-project `Analyses.{Domain,Application,Infrastructure,Persistence}` split.
> **⬜ Designed, not built (analyze stage):** the multi-analysis **framework abstractions** (`IAnalysis` / `IPayloadBuilder` / `IAnalysisRule` / `AnalysisResult`, `AddAnalysis<T>`, the per-analysis `Analyses:{FsmFit,…}` appsettings shape, `AnalyzeJob<TAnalysis>` / `AnalyzeFsmFitJob` / `SmokeProbeJob`, the `Abstractions/` / `Eligibility/` / `Redaction/` / `Llm/` / `PayloadBuilders/` / `prompts/` trees, the `openai-ping` CLI, and the stage-2 read API). The shipped `Analyses.Domain` holds only the **metrics** contracts (`AccountMetricsRow`, `IMetricsCollector`, `IAccountDiscovery`, `IAccountMetricsRepository`, `MetricsOptions`).
> **Corrections applied below:** there is **no `Tofu.AI.Worker` project** (the solution has exactly the five projects above — the "empty Worker shell" never existed); migrations live in `Analyses.Persistence/Migrations/` (not `Tofu.AI.Infrastructure/Migrations/`); the only shipped migration is `V001_CreateAccountMetrics`; recurring-job registration is `RegisterAnalysesRecurringJobs(IRecurringJobManager, MetricsOptions)`; the app listens on container port **80** (`Program.cs`), gated on `Analyses:Metrics:Enabled` (default false).

This spike picks the runtime shape for WEB-1523's analysis pipeline: where the code lives, how background jobs are triggered and at what cadence, how the GCP and K8s resources get provisioned, and how the new service ships through CI/CD.

The locked-in architectural decisions before this spike opened: (a) **dedicated service** named `Tofu.AI.Backend` — this is an **existing repo** at `C:\Git\Work\Backend\Tofu.AI.Backend` / `github.com/m-unicorn/Tofu.AI.Backend`, currently hosting a single-project ChatGPT-proxy API (`Tofu.AI.Api` with `ChatController` / `ChatGptService`). WEB-1523 **extends it** with the FSM-fit pipeline; existing chat endpoints remain in place; (b) the extended service hosts **both the background-job runtime (write side) and an HTTP/REST API (read side, stage 2)** — at stage 1 both run in the existing `Tofu.AI.Api` process; (c) **Hangfire** for the background-job runtime, embedded in-process. This spike fills in the rest.

> **Stage-1 single-pod design (2026-05-22).** An earlier draft of this doc split the service into `Tofu.AI.Api` + `Tofu.AI.Worker` pods, mirroring `Invoices.Backend`. That split has been collapsed for v1: there is only **one process** (`Tofu.AI.Api`) and **one Kubernetes Deployment** (`tofu-ai-api-deployment`). Hangfire client + server + dashboard all live inside that process. **As built, no `Tofu.AI.Worker` project was ever created** — the solution contains exactly `Tofu.AI.Api` + `Analyses.{Domain,Application,Infrastructure,Persistence}`. All references to "Worker pod" / "Worker Deployment" / "API + Worker split" in the rest of this doc were rewritten against the new shape — if anything in a sibling spike still implies the two-pod split, treat the single-pod shape as authoritative.

## Questions

1. **Service shape.** Repo layout — which projects ship in `Tofu.AI.Backend`? How are background jobs hosted relative to the API? How is the container image built and which K8s Deployments it spawns?
2. **Background-job invocation.** How does Hangfire wire into the new service, what are the recurring jobs, what's the failure-recovery story?
3. **Cadence and triggering.** What drives `analyze account X` — TTL on `expires_at`, wall-clock cron, both? What about cold-start (new accounts) and bursts (50k accounts expiring in one window)?
4. **IaC mechanism.** How do the new GCP resources (BigQuery dataset, tables, service account, IAM bindings) and K8s manifests get provisioned in dev and prod?
5. **CI/CD wiring.** Which GitHub Actions workflow builds the image, where does it push, how does the LLM-provider key reach the running container?

## Decision

**Existing service `Tofu.AI.Backend`** — peer microservice to `Tofu.Invoices.Backend`, extended for analysis. Layout: `Tofu.AI.Api` + `Analyses.{Domain,Application,Infrastructure,Persistence}` + tests, mirroring the four-layer pattern in `Invoices.Backend/Src/Jobs/`. **Single Docker image, one K8s Deployment**: `tofu-ai-api-deployment` (existing — 2 replicas, runs the API surface *and* hosts the Hangfire server in-process). No separate Worker Deployment in v1. Re-evaluating the split is deferred until either (a) Hangfire work demonstrably contends with HTTP latency under load, or (b) we need to scale the read path independently.

The service is built as a **multi-analysis platform**: the v1 ship includes the framework abstractions + the FSM-fit instance only; v2 (`churn_risk`, `suspicious_user`) and future analyses slot in via the abstractions below **without framework code changes**.

- **Read API:** **deferred to stage 2.** Stage 1 consumers read results via existing BigQuery clients (Looker Studio ad-hoc, BQ Web UI, `gcloud bq`) under the PM Google Group's `dataViewer` binding. The HTTP/REST read API (`GET /accounts/{subject}/analyses` + `GET /accounts/{subject}/analyses/{analysis_type}`, JSON responses in the consumer-facing view shape) lands in stage 2 with no schema changes. REST chosen over gRPC because the per-analysis evidence/output JSON cells are inherently variable-shaped — Protobuf typing would degrade to `google.protobuf.Struct` anyway.
- **Background-job runtime:** Hangfire embedded **in-process inside `Tofu.AI.Api`**. Client + server + dashboard all wired from the same `Program.cs`. The three-method shape `AddAnalysesHangfire` / `AddAnalysesHangfireServer` / `UseAnalysesHangfireDashboard` mirrors `Invoices.Backend`'s `Notifications.Infrastructure.Hangfire`, but lives at `src/Tofu.AI.Api/Hangfire/HangfireConfiguration.cs` rather than in a shared package — the AI service uses Postgres schema `analyses` for its Hangfire tables. **Generic `AnalyzeJob<TAnalysis>`** pattern + per-analysis `RecurringJob.AddOrUpdate(...)` registration via `Analyses.Application.DependencyInjection.RegisterAnalysesRecurringJobs(...)`. In-process Hangfire `WorkerCount = 4` (threads, not pods). With API replicas at 2, both pods run the Hangfire server — `Hangfire.PostgreSql`'s distributed-lock support gates cross-replica concurrency by default. CLI modes (`migrate`, `openai-ping`) short-circuit before Hangfire is wired so they don't open a PG connection at startup.
- **Cadence:** `expires_at`-driven per analysis. FSM-fit TTL = 90 days; future analyses set their own (churn_risk likely weekly, suspicious_user hourly). Cold-start = next tick.

### Framework abstractions (locked at the service level — required for multi-analysis support)

> ⬜ **Not built — analyze-stage design.** None of `IAnalysis` / `IPayloadBuilder` / `IAnalysisRule` / `AnalysisResult` / `AddAnalysis<T>` exist in code yet. The shipped `Analyses.Domain` carries only the metrics contracts (`IMetricsCollector`, `IAccountDiscovery`, `IAccountMetricsRepository`, `AccountMetricsRow`, `MetricsOptions`). The interfaces below are the target shape for when the LLM analyze stage lands.

```csharp
// Domain/Analyses/Abstractions/

public interface IAnalysis
{
    string AnalysisType { get; }                  // catalog key — "fsm_fit", "churn_risk", ...
    Type PayloadType { get; }                     // closes IPayloadBuilder<T>
    string PromptTemplateId { get; }              // resolves to prompts/<analysis_type>/v<N>.md
    JsonSchema EmitSchema { get; }                // OpenAI strict-structured-outputs JSON schema
    TimeSpan RefreshTtl { get; }                  // per-analysis (fsm_fit = 90d; churn = 7d; ...)
    string CronExpression { get; }                // per-analysis Hangfire cadence
}

public interface IPayloadBuilder<TPayload>
{
    Task<TPayload> BuildAsync(SubjectRef subject, CancellationToken ct);
}

public interface IAnalysisRule
{
    string RuleVersion { get; }
    AnalysisResult Apply(JsonNode emit);          // (score, tier, reasoning) from the LLM's emit JSON
}

public sealed record AnalysisResult(
    double Score,
    string Tier,                                  // per-analysis vocabulary; just a string in storage
    string Reasoning);
```

**DI registration** (.NET 8 keyed services):
```csharp
services.AddAnalysis<FsmFitAnalysis>();           // registers IAnalysis + IPayloadBuilder + IAnalysisRule, keyed by "fsm_fit"
// v2: services.AddAnalysis<ChurnRiskAnalysis>();
// v2: services.AddAnalysis<SuspiciousUserAnalysis>();
```

The LLM client, BigQuery CDC writer, and HTTP read API are **analysis-agnostic** — they read `IAnalysis` via DI and resolve the right payload builder / prompt / rule by `analysis_type`. The only per-analysis code is the `<AnalysisType>Analysis` class, its `IPayloadBuilder<T>` impl, its `IAnalysisRule<T>` impl, its `IModuleMigration` (creates the per-analysis table + view), and its prompt file.

### Per-analysis appsettings shape

> ⬜ **Not built.** The shipped config is a **single** `Analyses:Metrics` block (`Enabled` / `Cadence` / `RefreshTtl` / `ExpiredScanBatchSize` / `AggregationBatchSize` / `MaxConcurrentBatches` / `DiscoveryWindowDays`) plus `Analyses:{Hangfire,BigQuery}`. The per-analysis `Analyses:{FsmFit,ChurnRisk,…}` shape below arrives with the analyze stage.

```jsonc
{
  "Analyses": {
    "FsmFit":         { "Enabled": true,  "Cadence": "0 3 * * 0",  "Model": "gpt-4.1-nano", "BatchSize": 200, "LlmConcurrency": 10 },
    "ChurnRisk":      { "Enabled": false, "Cadence": "0 4 * * 0",  "Model": "gpt-4.1-nano", "BatchSize": 200, "LlmConcurrency": 10 },
    "SuspiciousUser": { "Enabled": false, "Cadence": "0 */1 * * *", "Model": "gpt-4.1-nano", "BatchSize": 50,  "LlmConcurrency": 5 }
  }
}
```

Adding an analysis at the code level = one class + one prompt file + one config block. **No service-wide changes.**

**K8s** (existing Kustomize manifest at `Deploy/Invoices.Kubernetes/overlays/{dev,prod}/tofu-ai.yaml` — today contains only `tofu-ai-api-deployment` for the ChatGPT proxy; WEB-1523 **extends the same Deployment in-place** — no new Deployment objects added in v1):

| Resource | Name |
|---|---|
| Image | `gcr.io/inv-project/tofu-ai-api` *(single image, single Deployment)* |
| SecretProviderClass | `tofu-ai-api-secret` |
| Service | `tofu-ai-api-service` (HTTP 80→5005) |
| API Deployment | `tofu-ai-api-deployment` — runs `dotnet Tofu.AI.Api.dll`; 2 replicas, **hosts Hangfire server + dashboard in-process** |
| K8s SA on pods | `gsm-accessor-sa` (existing, cluster-wide) |
| API replicas | 2 (`maxSurge:1`, `maxUnavailable:0`) |
| Probes | startup + readiness on `/health` |
| Lifecycle | `preStop` `sleep 10`, `terminationGracePeriodSeconds: 30` |
| Resources (API) | chat-proxy baseline (~700Mi mem + 800m CPU req) bumped to **~1Gi mem + 800m CPU req** — accommodates the in-process Hangfire scheduler + payload aggregation + Presidio + LLM payloads. Re-tune after observing real usage. |
| Pre-deploy `migrate` Job | `tofu-ai-migrate-<sha>` — one-shot Job running `dotnet Tofu.AI.Api.dll migrate`; gates the Deployment rollout |

- **GCP-side IAM (one-time per env):** `scripts/bootstrap-gcp-iam.sh` provisions the GCP service account + project-level role bindings + Workload Identity. **Does not create the dataset or tables** — those are applied by the migration runner on every deploy. No Terraform. (The existing GCS bucket used by the chat-proxy `StorageService` is unrelated and untouched.)
- **GCP-side schema (every deploy):** `IBigQueryMigration` steps under `Analyses.Persistence/Migrations/Modules/BigQuery/` create the `ai_analysis_v2` dataset + the shared `account_metrics` table. **As built that is one step — `V001_CreateAccountMetrics`;** the per-analysis `account_<type>` tables (`account_fsm_fit`) + `v_<type>` views are later `V###` steps in the unbuilt analyze stage. Tables declare `PRIMARY KEY ... NOT ENFORCED` + `max_staleness` for Storage Write API CDC ingestion (no staging tables). Mirrors the `Invoices.Backend` migration pattern — see [`migrations.md`](migrations.md) + [`storage.md` § Structure](storage.md).
- **Workload Identity:** GCP SA `tofu-ai-bq-writer@<project>.iam` (new, `dataEditor` on `ai_analysis_v2` dataset + `jobUser` at project) bound to K8s SA `gsm-accessor-sa`. No JSON key file. No `gcs-secret-acc-key` volume (BFF-specific for PDF/GCS).
- **Secrets:** GSM + GKE Secret-Store CSI driver mounting `appsettings.Production.json`. LLM API key inside the same JSON.
- **CI/CD:** **`publish-deploy.yaml` already exists** in `.github/workflows/` and correctly calls `m-unicorn/Tofu.GitHubActions/.github/workflows/publish-deploy.yaml@main` with `api-deployment-name: tofu-ai-api-deployment`, `image-name: tofu-ai-api`. `worker-deployment-name` stays empty (single-pod design — Hangfire is co-hosted in the API). Set `migrate-job-name: tofu-ai-migrate` so the shared workflow runs the migration Job before rolling the API. Add `publish-client.yaml` (NuGet for `Tofu.AI.Api.Client`). **Drop the legacy `cloudbuild.yaml`** from the repo root — the shared GitHub Actions workflow does image build + push + `kubectl set image` end-to-end, making `cloudbuild.yaml` redundant. GKE cluster routing in the shared workflow: `tofu-cluster` (prod), `invoices-cluster` (staging/dev), zone `us-east1-d`.
- **Dev environment:** GCP project `invoicesapp-project-test`, dataset name `ai_analysis_v2`.

Rationale: see § Q1-Q5.

## Findings

### Q1 — Service shape

> **Note on data input.** v1 payload builders read MongoDB collections directly via `IPayloadBuilder<T>`, but **shared backend metrics now land in the `account_metrics` table from day one** (per [`storage.md`](storage.md) § Decision — the split-layer design unified the previously-deferred `account_signals` cache with the storage layer). `MetricsRefreshJob` aggregates from Mongo into `account_metrics` on a daily cadence; per-analysis `IPayloadBuilder<T>` impls read pre-computed metrics from there plus any analysis-specific signals direct from Mongo. Multiple analyses share the metrics layer without re-aggregating.

> **Mongo read routing (resource isolation from `Invoices.Backend`).** AI signal aggregation must not compete with the BFF for primary-shard CPU/IO. Per-env approach:
>
> **Prod — Mongo Data Federation over snapshots.** `Tofu.AI.Api` (Hangfire jobs in-process) connects to a Federation endpoint backed by periodic snapshots of `invoices`, `estimates`, `clients`, `accounts`. Prod replica sets are not touched at all — no contention with the BFF, even under sustained aggregation bursts. Collection names match the live cluster, so the aggregation pipelines run unmodified. Snapshot inventory must include `clients` (add as part of WEB-1523 Phase 1 if missing); confirm the snapshot windows cover the 30d and 12mo metric horizons. Rationale and rejected alternatives in [`../investigation/mongo-read-isolation.md`](../investigation/mongo-read-isolation.md) § Decision.
>
> **Stage — plain default connection to prod Mongo.** No Federation endpoint on stage. The same code runs against the live prod Mongo with a plain connection string, as the other services use — no enforced read preference or read concern. Acceptable because (a) stage's aggregation volume is negligible (reads may land on the prod primary; the load is irrelevant at stage volume), (b) collection names match, so only the connection string differs by env, and (c) end-to-end correctness testing against real prod schema is the point of stage.
>
> **Escalation triggers (move off the snapshot path):** Federation scan cost runaway after first-month measurement → batch-sweep refresh that lands intermediate results in `account_metrics`; or a future analysis needs <1h freshness → re-evaluate Analytics Node / mongosync. v1 commits to the snapshot path; these are deferred.
>
> **What v1 must not do:** read from any prod Mongo replica-set member in prod, even by accident. The signal-collector base class takes its connection string from config only — no per-call override allowed. The prod connection string resolves to the Federation endpoint; the stage one resolves to prod Mongo with a plain default connection. Connection-string config is the single source of truth for which env points where.

**Repo and project layout.** Single-process layout, single executable. `Tofu.AI.Api` hosts both HTTP and Hangfire in the same image. There is no `Tofu.AI.Worker` project.

> **As-built layout (the rest of this tree is the analyze-stage target).** What actually exists today:
> ```
> src/
> ├── Tofu.AI.Api/                 # chat proxy + Hangfire host + migrate CLI (Program.cs, DatabaseUpdate.cs, Hangfire/, DI/, Settings/, Telemetry/, Controllers/, Services/, Data/)
> └── Analyses/
>     ├── Analyses.Domain/         # Models/AccountMetricsRow, Repositories/IAccountMetricsRepository, Services/{IMetricsCollector,IAccountDiscovery}, MetricsOptions
>     ├── Analyses.Application/     # Jobs/MetricsRefreshJob, DependencyInjection
>     ├── Analyses.Infrastructure/  # Metrics/{Collectors,MetricWindow,AccountDiscovery}, Mongo/*, DependencyInjection
>     └── Analyses.Persistence/     # BigQuery/{StorageWriteApiHelper,BigQueryMappings,BigQuerySettings}, Protos/account_metrics.proto, Migrations/* , Repositories/BigQueryAccountMetricsRepository
> ```
> No `Abstractions/`, `Eligibility/`, `Redaction/`, `Llm/`, `PayloadBuilders/`, `Signals/`, `prompts/`, or per-analysis `FsmFit/` folders yet — those land with the analyze stage. The tree below is the multi-analysis **end-state design**:

```
Tofu.AI.Backend/
├── Dockerfile                                       # multi-stage: build → publish Tofu.AI.Api → final aspnet:8.0
├── docker-compose.yaml                              # dev only
├── README.md
├── CLAUDE.md
├── Tofu.AI.Backend.sln
├── global.json                                      # pinned .NET 8 SDK
├── scripts/
│   └── bootstrap-gcp-iam.sh                         # one-time IAM + Workload Identity setup (no dataset/table creation)
├── src/
│   ├── Tofu.AI.Api/                                 # HTTP entry point + Hangfire server (single-pod, in-process)
│   │   ├── Hangfire/HangfireConfiguration.cs        # AddAnalysesHangfire + AddAnalysesHangfireServer + UseAnalysesHangfireDashboard
│   │   ├── Controllers/                             # chat-proxy controllers (untouched) + stage-2 analyses controllers
│   │   └── ...
│   ├── Analyses/                                    # module folder — mirrors `Src/Jobs/` in Invoices.Backend; groups analyses code + BA/PM briefs
│   │   ├── README.md                                # framework overview for PMs / BAs: what's an analysis, lifecycle, catalog status table
│   │   ├── Analyses.Domain/
│   │   │   ├── Abstractions/                        # IAnalysis, IAnalysisRule, IPayloadBuilder, AnalysisResult, SubjectRef
│   │   │   ├── FsmFit/                              # v1 — FsmFitAnalysis, FsmFitPayload, FsmFitEmitSchema, FsmFitRuleV1, FsmFitPayloadBuilder
│   │   │   │   └── README.md                        # one-page brief for PMs / BAs: goal, audience, status, decisions, links → Tofu.Docs
│   │   │   ├── ChurnRisk/                           # v2 — empty placeholder folder
│   │   │   │   └── README.md                        # empty placeholder brief until v2 ticket lands
│   │   │   ├── SuspiciousUser/                      # v2 — same
│   │   │   │   └── README.md                        # empty placeholder brief until v2 ticket lands
│   │   │   ├── Redaction/                           # Presidio port + shared value objects
│   │   │   ├── Repositories/                        # IAccountMetricsRepository, IAnalysisResultRepository
│   │   │   └── Analyses.Domain.csproj
│   │   ├── Analyses.Application/
│   │   │   ├── Jobs/                                # MetricsRefreshJob, AnalyzeJob<T>, AnalyzeFsmFitJob, SmokeProbeJob — Hangfire entry points
│   │   │   ├── Llm/                                 # ILlmClient + IPromptLoader + stubs
│   │   │   └── DependencyInjection.cs               # AddAnalysesApplication + RegisterAnalysesRecurringJobs
│   │   ├── Analyses.Infrastructure/
│   │   │   ├── Llm/                                 # real OpenAI client (swapped in when Analyses:OpenAi:Enabled = true)
│   │   │   ├── PayloadBuilders/                     # per-analysis IPayloadBuilder<T> implementations
│   │   │   ├── Redaction/                           # Presidio HTTP adapter (swapped in when Analyses:Redaction:Enabled = true)
│   │   │   ├── Signals/                             # signal collectors composed by per-analysis payload builders
│   │   │   │   ├── InvoiceSignals/                  # reads via Mongo Data Federation in prod (live cluster untouched) / plain connection to prod Mongo in stage
│   │   │   │   ├── AuthSignals/                     # v2 — HTTP client into Tofu.Auth.Backend (login recency, sessions)
│   │   │   │   └── PaymentSignals/                  # v2 — payment-failure history
│   │   │   └── Analyses.Infrastructure.csproj
│   │   └── Analyses.Persistence/
│   │       ├── BigQuery/                            # Storage Write API CDC writers (metrics + per-analysis) — analysis-agnostic
│   │       ├── Migrations/                          # IModuleMigration classes — table DDLs + view DDL assembly, applied via `dotnet Tofu.AI.Api.dll migrate`
│   │       ├── Repositories/                        # AccountMetricsRepository, AnalysisResultRepository
│   │       └── Analyses.Persistence.csproj
│   └── prompts/
│       ├── fsm_fit/
│       │   └── v1.md                                # winning prompt from Training/fsm_fit/results/<...>
│       ├── churn_risk/                              # v2 — populated when training cycle completes
│       └── suspicious_user/                         # v2
├── .github/
│   └── workflows/                                   # publish-deploy.yaml + publish-client.yaml
└── Tofu.Docs/                                       # gitignored sibling clone (per workspace convention)
```

**Per-analysis folder discipline.** Each `Analyses/<AnalysisType>/` folder owns its analysis end-to-end: the `IAnalysis` registration, payload builder, emit schema, rule, and any per-analysis tests. Cross-analysis dependencies go through `Analyses/Abstractions/` only. If a future analysis needs to add infrastructure (e.g., a new signal collector), it goes under `Infrastructure/Signals/` so multiple analyses can compose it.

**Analyses catalog (non-engineering audience).** The `src/Analyses/` module doubles as the doc surface for PMs, BAs, and sales-ops. Two README layers carry the business framing alongside the code:

- `src/Analyses/README.md` — framework-level overview: what's an analysis, the lifecycle (planning / training / building / shipped), and the catalog status table (one row per `analysis_type`).
- `src/Analyses/Analyses.Domain/<AnalysisType>/README.md` — per-analysis one-page brief: goal in one paragraph, audience, current lifecycle status, success metric, decision log with dates, and links into Tofu.Docs for the engineering detail.

**Tofu.Docs remains the single source of truth** for design decisions; the briefs are an index + business framing, not duplicated content. Colocating the briefs with the per-analysis C# folder (rather than a separate `analyses-catalog/` tree at repo root) means adding a new analysis adds **one** folder (`src/Analyses/Analyses.Domain/<NewType>/`) that contains both the engineering code and the BA/PM brief — no parallel path to maintain. The module structure mirrors `Src/Jobs/` in `Invoices.Backend` (`Jobs.Domain/`, `Jobs.Application/`, `Jobs.Infrastructure/`, `Jobs.Contracts/` as sibling projects under a module folder), adapted to the analyses domain.

**Cross-repo signal sources.** v1 reads Mongo via the BFF-style aggregator pattern, but routed to the Federation endpoint (prod) or a plain default connection to prod Mongo (stage), as the other services use (see "Mongo read routing" note above). v1 opens **no** cross-repo Postgres connection — `AnalyzeFsmFitJob`'s audience filter (Layer B, **not** metrics collection) is the account-maturity gate, which reads only the source `accounts` Mongo collection (see [`analyze.md`](analyze.md) § Audience eligibility). The earlier FSM-using-account exclusion over `Invoices.Backend`'s `jobs.Jobs` was removed — job filtering is not used at this stage. No new gRPC client in v1. v2 brings the `Tofu.Auth.Api.Client` gRPC dependency for `churn_risk` / `suspicious_user` login/session signals — flagged here so the v1 design doesn't preclude wiring it in.

**Single image, single K8s Deployment.** The `Dockerfile` publishes `Tofu.AI.Api` (with `Analyses.Domain` + `Analyses.Application` + `Analyses.Infrastructure` + `Analyses.Persistence` pulled in transitively via `<ProjectReference>`). K8s declares one Deployment off that image — API (2 replicas, HTTP entry point **and** Hangfire server + dashboard in-process). The closest peer template is `Deploy/Invoices.Kubernetes/overlays/prod/tofu-invoices.yaml`'s `invoices-api-deployment` block, minus the BFF-specific PDF/GCS plumbing. The earlier `tofu-ai.yaml` overlay (chat-proxy era) is the file extended in-place; resource sizing is bumped to absorb the Hangfire workload, but the probe + lifecycle pattern stays workspace-standard.

Concrete naming:

| Resource | Name |
|---|---|
| Docker image | `gcr.io/inv-project/tofu-ai-api` (single image, single Deployment) |
| SecretProviderClass | `tofu-ai-api-secret` → mounts `appsettings.Production.json` from GSM |
| Service | `tofu-ai-api-service` (ClusterIP, `http` port 80→5005) |
| API Deployment | `tofu-ai-api-deployment` (app label `tofu-ai-api`) — 2 replicas, runs `dotnet Tofu.AI.Api.dll`, hosts Hangfire server + dashboard in-process |
| Pre-deploy migration Job | `tofu-ai-migrate` — runs `dotnet Tofu.AI.Api.dll migrate` against BigQuery before the Deployment rolls |
| K8s SA on the pods | `gsm-accessor-sa` (existing, cluster-wide) |
| Workload Identity binding (GCP SA) | `tofu-ai-bq-writer@<project>.iam.gserviceaccount.com` (new, dataset-scoped) |

**Pod conventions** (single Deployment — `tofu-ai-api-deployment`):

- Replicas: 2; rolling-update `maxSurge: 1`, `maxUnavailable: 0` (zero-downtime).
- `terminationGracePeriodSeconds: 30`; `lifecycle.preStop: sleep 10` — handles both the kube-proxy endpoint-removal propagation window for HTTP traffic and the in-flight Hangfire job's grace window before SIGTERM. Per [`Deploy/Invoices.Kubernetes/README.md`](../../../Deploy/Invoices.Kubernetes/README.md).
- Probes: `startupProbe` + `readinessProbe` on `/health`. No liveness probe — workspace convention.
- Hangfire dashboard reachable at `/hangfire` behind an auth filter for admin use, not for liveness probing.
- Resources: ~1Gi memory, 800m CPU — chat-proxy baseline (~700Mi) bumped to absorb the in-process Hangfire scheduler + payload aggregation + Presidio redaction (sidecar) + LLM payloads. Re-tune after observed memory on a sample backfill batch.

No `gcs-secret-acc-key` volume — that's an `Invoices.Backend` BFF concern (PDF rendering against GCS). As built, the chat-proxy GCS client is **config-driven** via `AddChatStorage` (`StorageConfiguration.cs`): ADC / ambient service account by default, an explicit key file only when `Storage:ServiceAccountKeyPath` is set, and resolved lazily (the credential is built on first `IStorageService` use), so the `migrate` CLI builds the DI graph without opening it. The hardcoded `gcs-secrets/…json` key file the chat proxy previously used is gone — envs that relied on it must run under Workload Identity / ADC or set the path. BigQuery access for the analyses pipeline likewise uses Workload Identity / ADC (or an optional inline `Analyses:BigQuery:ServiceAccountKeyJson`), no key file.

**Why single Deployment in v1 (deferred split):** the canonical peer pattern in `Invoices.Backend` is `invoices-api-deployment` + `invoices-worker-deployment`, justified by orthogonal scaling and failure isolation. WEB-1523 deliberately defers that split for v1: at expected load (~100k subjects refreshed daily, see [`../analyses/metrics.md`](../analyses/metrics.md) § Performance budget) the Hangfire workload fits comfortably inside the 2-replica API pod's spare headroom, and the operational cost of standing up a second Deployment (separate manifest block, separate resource tuning, separate rollout coordination) outweighs the benefit. `Hangfire.PostgreSql`'s distributed lock handles the 2-replica concurrency case natively. **Re-evaluate when:** Hangfire job duration starts showing up in API request P99 (head-of-line via shared thread pool / GC pressure), or the read path scales independently of write volume, or a v2 analysis ships with sub-hourly cadence that swamps the in-process scheduler. Until then, single pod wins on simplicity.

**Read-side surface — deferred to stage 2.** Stage 1 ships write-side only; consumers read results via existing BigQuery clients (Looker Studio ad-hoc views, BQ Web UI, `gcloud bq`) under the PM Google Group's `dataViewer` binding (see [`storage.md`](storage.md) § IAM matrix). Stage 2 adds an HTTP/REST API — same image, new controllers under `Tofu.AI.Api`, no infrastructure changes. When that lands, the read API will expose:

- `GET /accounts/{account_id}/analyses` — returns the full nested `analyses` array per the BQ schema in [`storage.md` § Q1](storage.md). Generic JSON envelope; each element tagged with `analysis_type` carries its per-analysis evidence/output inside a JSON object.
- `GET /accounts/{account_id}/analyses/{analysis_type}` — targeted single-analysis read, saves the BFF from filtering client-side when only one type is needed.

**Do not add per-analysis-type endpoints** (`GET /accounts/.../fsm-fit`, `GET /accounts/.../churn-risk`, ...) when stage 2 lands — adding new analyses must not require new routes or DTO classes. That's the multi-analysis contract; future analysis types are additive inside the existing generic response shape.

**Why REST instead of gRPC** (the prior draft proposed gRPC): the per-analysis `evidence` / `output` cells are intrinsically variable-shaped per `analysis_type`. Protobuf typing degrades to `google.protobuf.Struct` or string-encoded JSON to handle that, which negates the strong-typing advantage of gRPC. REST + JSON maps the response shape 1:1 to the BigQuery view's `JSON` columns with zero ceremony. Tofu.Auth is REST too — the workspace pattern is mixed, not gRPC-exclusive.

### Q2 — Background job invocation (Hangfire in the API process)

**Reference pattern.** Mirrors `Invoices.Backend`'s `Notifications.Infrastructure.Hangfire` setup (`Src/Notifications/Notifications.Infrastructure/Hangfire/HangfireConfiguration.cs`) in shape, but lives at `src/Tofu.AI.Api/Hangfire/HangfireConfiguration.cs` and is **embedded directly in the API process** rather than imported as a shared package. Three extension methods on `IServiceCollection` / `WebApplication`: `AddAnalysesHangfire(connectionString)` → `UseSimpleAssemblyNameTypeSerializer` + `UseSerilogLogProvider` + `UsePostgreSqlStorage` with `PrepareSchemaIfNecessary = true` + `EnableTransactionScopeEnlistment = true` + `SchemaName = "analyses"`; `AddAnalysesHangfireServer()` → `WorkerCount = 4` (in-process threads), `ServerName = $"tofu-ai-{Environment.MachineName}"`; `UseAnalysesHangfireDashboard()` → mounts `/hangfire` behind an auth filter. The bespoke wrapping over importing the Notifications package directly is required because that package hard-codes `SchemaName = "hangfire"`, and the AI service uses `analyses` so its job tables are clearly owned if the Postgres instance is ever shared.

**Hangfire is the background-job runtime, hosted in-process inside `Tofu.AI.Api`.** The write-side workload runs as Hangfire recurring jobs (concrete jobs live in `Analyses.Application/Jobs/`: `MetricsRefreshJob`, `AnalyzeFsmFitJob`, `AnalyzeJob<T>`, `SmokeProbeJob`). Registration is split: `AddAnalysesApplication` registers the job class (`AddScoped<MetricsRefreshJob>()`) + binds `MetricsOptions`; `RegisterAnalysesRecurringJobs(IRecurringJobManager, MetricsOptions)` is called from `Program.cs` after `app.Build()`. **As built it registers exactly one job** — `MetricsRefreshJob` on `MetricsOptions.Cadence`, gated on `MetricsOptions.Enabled` (`AddOrUpdate` when true, `RemoveIfExists` when false). The analyze-stage jobs (`AnalyzeFsmFitJob`, `AnalyzeJob<T>`, `SmokeProbeJob`) are added to the same call site later. Two layers per [`storage.md`](storage.md) § Q2: (a) `MetricsRefreshJob` aggregates backend metrics from Mongo secondaries and streams them into `account_metrics` daily via Storage Write API CDC (`_CHANGE_TYPE = 'UPSERT'`); (b) per-analysis `AnalyzeJob<TAnalysis>` builds the payload, calls the LLM, runs `IAnalysisRule<T>.Apply()` to materialise `score` / `tier` / `recommended_offers`, and streams into `account_<type>` via the same CDC mechanism. No staging tables, no scheduled MERGE — CDC ingestion handles upserts natively.

**CLI-mode short-circuit.** `dotnet Tofu.AI.Api.dll migrate` is detected pre-DI in `Program.cs` (via `DatabaseUpdate.IsMigrateCommand`, a case-insensitive `args` check) and **skips the Hangfire registration** entirely. (The analyze-stage `openai-ping` probe CLI is not yet implemented; when it lands it short-circuits the same way.) Reason: `UseHangfireDashboard` calls `ThrowIfNotConfigured` which opens a Postgres connection at startup — the migration runner is the thing that creates the `analyses` schema, so it must not depend on it existing first. Recurring-job registration is also gated behind the same `!isCliMode` branch.

**Storage backing — Postgres, schema `analyses`.** Hangfire persists job state + retry queue + dashboard history across pod restarts in a Postgres schema dedicated to the AI service. Connection string at `ConnectionStrings:Analyses` in `appsettings.json` → GSM secret `tofu-ai-api-secret`. With `PrepareSchemaIfNecessary = true`, the schema + Hangfire tables are created on first API startup outside CLI mode — no separate migration step. With the API at 2 replicas, **both pods run the Hangfire server**; `Hangfire.PostgreSql`'s distributed lock (`SET LOCAL lock_timeout` + `pg_advisory_xact_lock` under the hood) serialises recurring-job execution across replicas so the same tick is not processed twice. `[DisableConcurrentExecution]` on long-running job methods enforces the same guarantee at the job level — `MetricsRefreshJob.RunAsync` already declares it with a 600s timeout.

**Data-store landscape for `Tofu.AI.Backend`.** The service talks to three logical stores via three connection types:

| Connection | Role | Owner | Mode |
|---|---|---|---|
| Mongo — **prod**: Data Federation endpoint over snapshots of `invoicesDB` from both `Invoices.Backend` and `Tofu.Invoices.Backend` clusters. **stage**: a plain default connection to the live prod Mongo clusters, as the other services use (same collection names; only the connection string differs). | Signal aggregation (`MetricsRefreshJob`, `AnalyzeJob<T>` payload builders) | `Invoices.Backend` + `Tofu.Invoices.Backend` (snapshot owners TBD) | Read-only |
| Postgres — `tofu-ai-backend` schema `analyses` (`ConnectionStrings:Analyses`) | Hangfire job state + retry queue + dashboard history | `Tofu.AI.Backend` (owned) | Read/write |
| BigQuery dataset `ai_analysis_v2` | Analysis output (`account_metrics`, `account_<type>`, `v_<type>`) | `Tofu.AI.Backend` (owned) | Write from the API pod, read from stage-2 controllers in the same pod |

> The read-only Postgres connection to `Invoices.Backend`'s `jobs` schema (`ConnectionStrings:InvoicesJobs`) that once backed the `AnalyzeFsmFitJob` FSM-using-account exclusion has been **removed** — job filtering is not used at this stage (see `analyze.md` § Audience eligibility). No cross-service Postgres read remains.

Pick a shared workspace Postgres instance for the Hangfire schema at deploy time — no dedicated provisioning in v1.

**Specific job decomposition is deferred to implementation.** Whether the workload is one job, two (analyze + merge), or N (per-trigger-type, per-analysis-type) is a tactical choice that depends on what feels clean once the code is being written. Hangfire supports either shape with the same primitives — `RecurringJob.AddOrUpdate(...)` + `BackgroundJob.Enqueue(...)`. Lock the decomposition during implementation or in a follow-up spike if the choice turns out to matter; don't over-design it here.

What's locked by this spike at the runtime level:
- **Concurrency.** `[DisableConcurrentExecution(timeoutInSeconds: 600)]` on `MetricsRefreshJob.RunAsync` (and equivalent on the analyze jobs) prevents overlapping runs of the same recurring job across replicas; `WorkerCount = 4` caps in-process parallelism per replica. With API at 2 replicas, `Hangfire.PostgreSql`'s distributed advisory lock keeps the recurring-tick fan-out single-threaded across the cluster.
- **Idempotency.** The aggregator + LLM call are idempotent on the same input by design ([`storage.md` § Q2](storage.md)); Storage Write API CDC upserts deduplicate on `PRIMARY KEY` natively. Safe to re-run any job.
- **Retries.** Hangfire default — `[AutomaticRetry(Attempts = 3)]` with exponential backoff; jobs that exhaust retries land in the Failed queue and surface in the dashboard. The Failed queue *is* the DLQ — no separate DLQ design needed.
- **Manual trigger surface.** Hangfire dashboard's "Enqueue now" is the admin escape hatch, mounted at `/hangfire` behind `HangfireDashboardAuthFilter` (placeholder — currently allows all in-cluster traffic; replace with the workspace-standard `IsAuthorizedHangfireDashboardAuthorizationFilter` once that filter is available outside the Notifications package). Until then, front the dashboard with ingress-level auth.
- **Read-write co-location.** HTTP read path (stage-2) and Hangfire write path share the same process and the same `WorkerCount = 4` thread budget. Acceptable for v1 because (a) stage-1 has no HTTP read traffic, (b) Hangfire ticks are bounded by `DisableConcurrentExecution` + cadence so they cannot starve HTTP threads under any cadence we'd configure, (c) the LLM call inside `AnalyzeJob<T>` is await-bound, not CPU-bound. Re-evaluate (see § Q1 § "Why single Deployment in v1") if observed P99 HTTP latency correlates with Hangfire tick boundaries.

### Q3 — Cadence and triggering

**Refresh model: per-layer `expires_at` + LLM-side `input_hash` drift.** Both physical tables carry their own `expires_at` ([`storage.md` § Decision](storage.md)). Candidate queries on each layer:

- `MetricsRefreshJob` — `expires_at < CURRENT_TIMESTAMP()` (expired scan) plus the every-tick discovery funnel for net-new accounts — **hourly** cadence, single TTL across all analyses (default 24h).
- `AnalyzeJob<TAnalysis>` — `WHERE account_<type>.expires_at < CURRENT_TIMESTAMP() OR input_hash drifted OR row missing` against the per-analysis table — per-analysis cadence, per-analysis TTL.

The `input_hash` (SHA256 over canonicalised payload + prompt_version + model_id) is the primary invalidation trigger; the TTL is the safety net. Re-judgement fires when the payload meaningfully changes even before the LLM TTL lapses.

**Per-analysis TTL.** Declared on the `IAnalysis` implementation (`RefreshTtl` property) — *not* in the rule class. The rule (`IAnalysisRule<T>.Apply()`, C#) runs at write time, materialising `score` / `tier` / `recommended_offers` into typed columns on `account_<type>`. The `IAnalysis` only carries cadence. `AnalyzeJob<TAnalysis>` reads `RefreshTtl` from the registered analysis and writes `expires_at = analyzed_at + RefreshTtl` on every UPSERT row streamed into `account_<type>`. Views do no rule computation — they're projection + join only.

For `fsm_fit` the recommendation is **90 days** — business patterns shift slowly, and the LLM cost model in [`../investigation/provider.md`](../investigation/provider.md) § Decision is built around this cadence. v2 analyses set their own: `churn_risk` likely 7d, `suspicious_user` ~1h.

**Cold-start.** New accounts get their first analysis the next time the Hangfire job runs (their row simply doesn't exist yet — the candidate query catches them as "no row → analyze now"). No threshold of N invoices required for v1 — even a thin signal is useful for the LLM ("no invoices yet" *is* a signal). If the LLM cost on near-empty accounts becomes a problem in practice, gate cold-start on `invoice_count >= 3` as a follow-up.

**Burst handling — backfill window.** At v1 launch all 50k accounts start with no row → all expire immediately → the first run would face the whole 50k at once. Two controls (concrete sizing picked during implementation against the LLM provider's RPM tier):
- **Batch cap per tick** — process at most N accounts per scheduling tick to spread the backfill over a few days.
- **LLM API rate-limit guard** — fan out within each tick at a concurrency bounded by the chosen provider's RPM tier.

**Manual re-analysis.** Admin needs the ability to force-refresh a single account (sales-ops asks "why is this account marked `weak`?"). Hangfire dashboard's "Enqueue now" can fire a one-off parameterised job, or the read-side API exposes `ForceReanalyze(account_id)` → enqueues. Pick during implementation.

### Q4 — IaC mechanism

**Workspace convention** (`Deploy/` folder). K8s resources are managed declaratively via **Kustomize overlays in `Deploy/Invoices.Kubernetes/overlays/{dev,prod}/`**. Each service owns a single YAML file under each overlay; the file is registered in that overlay's `kustomization.yaml` resource list. No Terraform. No Helm. GKE clusters are pre-existing (`invoices-cluster` for staging/dev, `tofu-cluster` for prod) — service onboarding does not include cluster provisioning.

GCP-side resources split into two categories with different provisioning patterns:

| Resource class | Frequency of change | Privilege required | Pattern |
|---|---|---|---|
| GCP service account, IAM role bindings, Workload Identity | Rare (once per env, then stable) | High (`iam.serviceAccountAdmin`) | **One-time `scripts/bootstrap-gcp-iam.sh`** — committed to repo, idempotent, run by the engineer shipping the service |
| BigQuery dataset, tables, schema changes | Per feature / migration | `bigquery.dataEditor` (the runtime SA itself) | **`IModuleMigration` classes** applied via `dotnet Tofu.AI.Api.dll migrate` as a K8s Job before the Deployment rolls |

Peer microservices (`Tofu.Invoices.Backend`, `Tofu.Auth.Backend`) have no committed IaC today — provisioning has been done manually with no audit trail beyond Cloud Audit Logs. The two-pattern split above is a workspace-pattern *improvement*: small idempotent IAM script for the rare-change high-privilege bits, app-resident migrations for the frequent-change low-privilege bits.

**K8s manifest files for this feature** — extend the existing two overlay files:
- `Deploy/Invoices.Kubernetes/overlays/dev/tofu-ai.yaml`
- `Deploy/Invoices.Kubernetes/overlays/prod/tofu-ai.yaml`

These overlays currently declare only `tofu-ai-api-deployment` (and its associated resources) for the ChatGPT-proxy service that is **already running in production**. WEB-1523 extends them per [§ Q1](#q1--service-shape): add the `tofu-ai-migrate` K8s Job manifest, bump API resources to absorb the in-process Hangfire workload, and bring probes / `preStop` / sizing in line with `tofu-invoices.yaml`. No new Deployment objects are added in v1 — the Hangfire server is co-hosted in the existing `tofu-ai-api-deployment`. **Do not delete the existing overlay** — it is not an orphan; it is live infrastructure for the chat-proxy endpoints, which keep running unchanged.

**One-time IAM bootstrap (`scripts/bootstrap-gcp-iam.sh`).** ~30 lines of `gcloud`. Per environment, run once by the engineer with `iam.serviceAccountAdmin`:
1. Create GCP SA `tofu-ai-bq-writer@<project>.iam`.
2. Grant `roles/bigquery.dataEditor` on `ai_analysis_v2` (created later by the migration runner) — predefined role, dataset-scoped.
3. Grant `roles/bigquery.jobUser` at project level (needed for DML + DDL job submission).
4. Bind GCP SA → K8s SA `gsm-accessor-sa` via Workload Identity.

The script is idempotent (re-run is a no-op once resources exist) and gives the next service-owner a working template to copy. Sees no traffic after first-run-per-env.

**Per-deploy schema migrations (`IModuleMigration`).** Reuse `Invoices.Backend`'s migration runner — see [`storage.md` § Schema deployment](storage.md) for the full pattern. The deploy pipeline runs the `tofu-ai-migrate` K8s Job (executing `dotnet Tofu.AI.Api.dll migrate`) and waits for it to succeed before `kubectl set image` on the Deployment. Failed migrations abort the deploy cleanly — live pods never see a half-applied schema.

**Dev environment.** Use the GCP project `invoicesapp-project-test` — same dataset name `ai_analysis_v2`. The shared workflow's staging target already routes to `invoices-cluster`, which lives in the staging project. Engineers running locally can either point at the test dataset via service-account impersonation or use BigQuery sandbox (no billing account required).

### Q5 — CI/CD wiring

**Shared workflow.** Peer microservices (`Tofu.Invoices.Backend`, `Tofu.Auth.Backend`) ship three GitHub Actions workflows that call the shared workflow in `Deploy/Tofu.GitHubActions/.github/workflows/`. Current state of `Tofu.AI.Backend/.github/workflows/`:

| Workflow | Status in repo today | Action for WEB-1523 |
|---|---|---|
| `publish-deploy.yaml` | **Already exists** — `workflow_dispatch` calling `m-unicorn/Tofu.GitHubActions/.github/workflows/publish-deploy.yaml@main`. Env sets `api-deployment-name: tofu-ai-api-deployment`, `image-name: tofu-ai-api`; `worker-deployment-name` referenced but empty; `migrate-job-name` empty. | **Update** — `worker-deployment-name` stays empty (single-pod design; Hangfire is co-hosted in the API). Set `migrate-job-name: tofu-ai-migrate` + `migrate-job-manifest:` pointing at the migration Job YAML so the shared workflow runs schema migrations before rolling the API Deployment. |
| `publish-client.yaml` | **Missing** | **Add (stage 2)** — publishes the `Tofu.AI.Api.Client` NuGet (HTTP client generated from controllers via NSwag/Refit, or hand-written DTOs co-located with `Analyses.Domain`) to GitHub Packages. Not needed in v1; activate when the BFF stage-2 read-API integration ships. |
| `cloudbuild.yaml` (root, not under `.github/workflows/`) | **Already exists** — legacy Cloud Build path duplicating image build + `kubectl set image` against `tofu-ai-api-deployment`. | **Delete** — redundant with the shared GitHub Actions composite, matches peer-microservice pattern. |

**The shared `publish-deploy.yaml`** (`Deploy/Tofu.GitHubActions/.github/workflows/publish-deploy.yaml`) does both steps internally via composite actions in the same repo:
- **`m-unicorn/Tofu.GitHubActions/.github/actions/build-and-publish@main`** — Docker build + push to GCR using the per-target GCP project SA via OIDC federation. No Cloud Build YAML in the service repo (`Invoices.Backend`'s `cloudbuild.{dev,prod}.yaml` are a legacy pattern specific to the BFF + its Puppeteer base image; **peer microservices don't ship cloudbuild yamls**).
- **`m-unicorn/Tofu.GitHubActions/.github/actions/deploy@main`** — `gcloud container clusters get-credentials` → `kubectl set image deployment/<name> <container>=<image>:<sha>`.

**Inputs the existing `publish-deploy.yaml` passes to the shared workflow** (post-WEB-1523 shape — `worker-deployment-name` stays empty since Hangfire is in-process in the API; `migrate-job-*` is wired up so schema migrations run before the Deployment rolls):

```yaml
uses: m-unicorn/Tofu.GitHubActions/.github/workflows/publish-deploy.yaml@main
with:
  api-deployment-name: tofu-ai-api-deployment                 # 2 replicas, runs `dotnet Tofu.AI.Api.dll`; hosts Hangfire server + dashboard in-process
  worker-deployment-name: ''                                  # empty — no separate Worker Deployment in v1
  image-name: tofu-ai-api                                     # GCR repo + image tag base
  migrate-job-name: tofu-ai-migrate                           # K8s Job that runs `dotnet Tofu.AI.Api.dll migrate` against BigQuery
  migrate-job-manifest: Deploy/Invoices.Kubernetes/overlays/${{ inputs.target }}/tofu-ai-migrate-job.yaml
  target: ${{ inputs.target }}                                # staging | production | development | development2
secrets: inherit
```

**GKE cluster routing** is in the shared workflow — `production` → `tofu-cluster`, `staging`/`development*` → `invoices-cluster`, zone `us-east1-d` for both. The repo doesn't need to know about cluster names; it only picks the target.

**Secrets injection.** LLM provider API key lives in Google Secret Manager under `projects/inv-project/secrets/tofu-ai-api-secret/versions/latest`. Mounted by `SecretProviderClass` → CSI driver → `appsettings.Production.json` inside the container; read by the standard `IConfiguration` pipeline. No env-var injection. The same GSM secret holds the `appsettings.Production.json` for the entire pod — adding the LLM key as a top-level field in that JSON is the cheapest path.

**Image-build credentials.** GitHub PAT for NuGet (`GITHUB_USER` + `GITHUB_TOKEN` Dockerfile build args) — matches the workspace Dockerfile pattern. The shared `build-and-publish` action wires these from `${{ secrets.GITHUB_TOKEN }}` automatically.

**Image promotion model.** Tagged `:latest` and `:$COMMIT_SHA` per build; `kubectl set image` uses `:$COMMIT_SHA` for atomic rollouts. Workflow-dispatch only — no on-push autoscaling deploy; same as every peer microservice.

## Sources

**Workspace conventions** (the load-bearing templates):
- `Deploy/Invoices.Kubernetes/overlays/{dev,prod}/tofu-invoices.yaml` — peer-microservice K8s manifest template (probes, lifecycle, ports, per-pod SecretProviderClass, resource sizing).
- `Deploy/Tofu.GitHubActions/.github/workflows/publish-deploy.yaml` + composite actions `build-and-publish@main` / `deploy@main` — the shared CI/CD pipeline every peer microservice calls.
- `Invoices.Backend/Src/Invoices.Worker/DI/NotificationsConfiguration.cs` — Hangfire reference implementation using the `Notifications.Infrastructure.Hangfire` package. WEB-1523 mirrors the three-method shape but inlines the wiring inside the API process at `src/Tofu.AI.Api/Hangfire/HangfireConfiguration.cs`.
- `Deploy/Invoices.Kubernetes/README.md` — documented Deployment knobs (pod lifecycle, rolling update, probes, resources).

**External:**
- [Hangfire — Recurring Jobs](https://docs.hangfire.io/en/latest/background-methods/performing-recurrent-tasks.html) — recurring-job semantics, `[DisableConcurrentExecution]`, `[AutomaticRetry]`.
- [GKE — Secret Manager CSI Driver](https://cloud.google.com/secret-manager/docs/secret-manager-managed-csi-component) — the `secrets-store.csi.x-k8s.io/v1` provider used by every `*-secret.yaml`.
