# WEB-1523 — CI/CD

This plan takes `Tofu.AI.Backend`'s delivery pipeline from its chat-proxy-era setup to a single GitHub Actions pipeline with a pre-deploy BigQuery-migration gate, as the service grows from a single-project ChatGPT proxy into the modular FSM-fit analysis platform.

> **Scope guardrail.** Pipeline only — image build, GitHub Actions, K8s rollout, the `migrate` gate. The *runtime* shape (single-pod, in-process Hangfire) is owned by [`service.md` § Q1–Q4](service.md); the *schema/migration mechanics* by [`migrations.md`](migrations.md) + [`storage.md`](storage.md). Those specs win on conflict.

## Previous state

The service ships as a single-project chat proxy with **two overlapping deploy paths** and no schema step:

- **Layout** — one project, `Tofu.AI.Api/`, at the repo root.
- **Dockerfile** — two-stage (SDK build → aspnet runtime), publishing `./Tofu.AI.Api/Tofu.AI.Api.csproj`.
- **Deploy path A — `cloudbuild.yaml` (Cloud Build).** Builds + pushes `gcr.io/$PROJECT_ID/tofu-ai-api:{latest,$COMMIT_SHA}`, then `kubectl set image deployment/tofu-ai-api-deployment` on `invoices-cluster` (zone `us-east1-d`). No production-cluster routing; no migration.
- **Deploy path B — `.github/workflows/publish-deploy.yaml`.** Already calls the shared `m-unicorn/Tofu.GitHubActions/.github/workflows/publish-deploy.yaml@main` with `api-deployment-name` + `image-name`, but with no migration gate wired.
- **K8s** — one `tofu-ai-api-deployment` at chat-proxy resourcing: no readiness gating, no headroom for an analysis workload.

Two pipelines doing the same job, neither aware of the schema-migration step the analysis platform needs.

## Decision (target)

- **Consolidate on the GitHub Actions shared-workflow path; retire Cloud Build** so there is exactly one way to ship.
- **One image, one Deployment.** The Dockerfile publishes only `src/Tofu.AI.Api`; the `Analyses.{Domain,Application,Infrastructure,Persistence}` layers come in transitively via `<ProjectReference>`. Hangfire is co-hosted in the API process (`service.md § Q1`) — no separate Worker image.
- **No `ENTRYPOINT` in the image.** Kubernetes selects the run mode via `command`/`args`: server (`dotnet Tofu.AI.Api.dll`), `… migrate`, `… openai-ping`. One artifact, three modes — the migrate Job and the API pods run a byte-identical image, so they can't drift.
- **Schema migration is a pre-deploy gate**, not a startup side-effect. A one-shot K8s Job runs `dotnet Tofu.AI.Api.dll migrate` (BigQuery DDL) and must succeed before `kubectl set image` rolls the Deployment. CLI mode skips Hangfire so the migrate pod never opens the Postgres connection it is provisioning.
- **Secrets via GSM + CSI driver**, never env vars — `appsettings.Production.json` (incl. the LLM key) mounted from `tofu-ai-api-secret`. NuGet/image-pull auth via `GITHUB_USER` + `GITHUB_TOKEN` Docker build args.
- **Cluster routing lives in the shared workflow**, not the repo: `production → tofu-cluster`, `staging`/`development*` → `invoices-cluster`, zone `us-east1-d`.

## Dockerfile

The build artifact for every run mode. Two stages — a throwaway SDK stage that compiles, a slim aspnet stage that ships:

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
COPY ./. ./
ARG GITHUB_USER
ARG GITHUB_TOKEN
RUN dotnet nuget add source https://nuget.pkg.github.com/m-unicorn/index.json -n m-unicorn -u $GITHUB_USER -p $GITHUB_TOKEN --store-password-in-clear-text
RUN dotnet restore  ./src/Tofu.AI.Api/Tofu.AI.Api.csproj
RUN dotnet publish -c Release -o /app/api --no-restore ./src/Tofu.AI.Api/Tofu.AI.Api.csproj

# K8s Deployments pick the entry point via container args:
#   API:     dotnet /app/api/Tofu.AI.Api.dll
#   Migrate: dotnet /app/api/Tofu.AI.Api.dll migrate
#   Probe:   dotnet /app/api/Tofu.AI.Api.dll openai-ping
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS production
WORKDIR /app
COPY --from=build /app ./
```

- The `GITHUB_*` build args authenticate `dotnet restore` against the private `m-unicorn` feed; they stay in the discarded build stage and never reach the shipped image.
- Publishing only `src/Tofu.AI.Api` pulls the `Analyses.*` projects transitively — the single-pod design made physical.
- **Leave the final stage without an `ENTRYPOINT`.** Adding one breaks the multi-mode arg dispatch in `DatabaseUpdate.cs` (migrate / openai-ping / server). This is deliberate.

## Implementation steps

1. [ ] **Re-point the Dockerfile at the modular layout.** Build `./src/Tofu.AI.Api/Tofu.AI.Api.csproj` (was `./Tofu.AI.Api/...`); keep the two-stage build, the `GITHUB_*` NuGet args, and the no-`ENTRYPOINT` final stage. Add the three-mode comment so the arg contract is discoverable.
2. [ ] **Retire Cloud Build.** Delete `cloudbuild.yaml` and remove its solution-item entry from `Tofu.AI.Backend.sln`. After this, GitHub Actions is the only deploy path — no migration-less `kubectl set image` route remains, and there's no `invoices-cluster`-only path that can't reach prod.
3. [ ] **Wire the migration gate into the deploy workflow.** In `.github/workflows/publish-deploy.yaml`, add `migrate-job-name: tofu-ai-migration-job` to the `env` block and pass it (plus `migrate-job-manifest`) through to the shared workflow. `worker-deployment-name` stays empty (single-pod). Keep `workflow_dispatch` targets `staging` + `production`.
4. [ ] **Add the migration Job manifest.** Create `tofu-ai-migration-job.yaml` in both `Deploy/Invoices.Kubernetes/overlays/{dev,prod}/` — a one-shot `kind: Job` (`metadata.name: tofu-ai-migration-job`, `restartPolicy: Never`, low `backoffLimit`) running `dotnet ./Tofu.AI.Api.dll migrate` from the same image / secret mounts / service account as the Deployment. Register it in each overlay's `kustomization.yaml`, and set the `TOFU_MIGRATION_JOB_MANIFEST` repo variable to its per-target path.
5. [ ] **Size the Deployment for the analysis workload.** Extend the existing `tofu-ai.yaml` overlays (dev + prod) in place — do not add new Deployment objects (full manifest layout in [§ Kubernetes manifests](#kubernetes-manifests-invoiceskubernetes)):
   - Startup + readiness probes on `/health`; `preStop: sleep 10` + `terminationGracePeriodSeconds: 30`.
   - Raise the API container above the chat-proxy baseline to absorb the in-process Hangfire scheduler + payload aggregation + LLM payloads (dev starts ~300Mi/50m; re-tune against a measured backfill batch).
   - Add the Presidio analyzer + anonymizer sidecars (gated by `Analyses:Redaction:Enabled`); pin both images to the same tag.
   - Keep the existing `gcs-service-account-key` volume — the surviving chat-proxy `StorageService` still reads it.
   - Prod: `replicas: 2`. Hangfire's PostgreSQL distributed lock serialises recurring ticks across replicas.
6. [ ] **Provision secrets.** Ensure the GSM secret `tofu-ai-api-secret` holds the full `appsettings.Production.json` (including the LLM key and the `Analyses:BigQuery` block); mount it via the `SecretProviderClass` → CSI driver. No env-var injection.

## Kubernetes manifests (`Invoices.Kubernetes`)

K8s is managed by Kustomize overlays in `Deploy/Invoices.Kubernetes/overlays/{dev,prod}/`; each service owns one YAML registered in that overlay's `kustomization.yaml`. The chat proxy already ships `tofu-ai.yaml` (registered at `overlays/prod/kustomization.yaml:14`, `overlays/dev/kustomization.yaml:13`). This plan **extends those files in place** — no new Deployment objects — and adds one migration Job manifest per overlay (Step 4).

### Resources per overlay

| Resource | Kind | Role |
|---|---|---|
| `tofu-ai-api-secret` | SecretProviderClass | Mounts `appsettings.Production.json` from GSM `projects/<project>/secrets/tofu-ai-api-secret`. |
| `gcs-service-account-key` | SecretProviderClass | Existing — the chat-proxy `StorageService` key. Retained. |
| `tofu-ai-api-service` | Service | ClusterIP, `http` 80→80. |
| `tofu-ai-api-deployment` | Deployment | The single Deployment — HTTP + Hangfire server in-process. |
| `tofu-ai-migration-job` | Job | **Added** — one-shot `dotnet ./Tofu.AI.Api.dll migrate`; gates the rollout (Step 4). |

### Pod shape (`tofu-ai-api-deployment`)

- `serviceAccountName: gsm-accessor-sa` (cluster-wide, Workload Identity).
- Container `tofu-ai-api`, image `gcr.io/<project>/tofu-ai-api`, `workingDir: /app/api`, `command: ["dotnet"]`, `args: ["./Tofu.AI.Api.dll"]`, `containerPort: 80`.
- `startupProbe` + `readinessProbe` on `/health` — no liveness probe (workspace convention).
- `lifecycle.preStop: sleep 10` + `terminationGracePeriodSeconds: 30` — drains HTTP endpoints and gives in-flight Hangfire jobs a grace window before SIGTERM.
- Resources raised above the chat-proxy baseline for the in-process Hangfire + aggregation workload (re-tune against a measured backfill).
- Volumes: `secret-config` (CSI → `tofu-ai-api-secret`, mounted at `/app/api/appsettings.Production.json`) and `gcs-secret-acc-key` (CSI → `gcs-service-account-key`).
- **Presidio sidecars** — two containers in the pod for PII redaction; see [§ Presidio sidecars](#presidio-sidecars).

### Presidio sidecars

PII redaction runs as **two sidecar containers** inside the API pod (not a separate service), reached over `localhost`:

- `presidio-analyzer` (`:3000`) — detects PII spans via its NER model.
- `presidio-anonymizer` (`:5001`) — masks the spans the analyzer reports.

The YAML props that matter:

- **Fixed image version** — both pinned to the same Presidio tag and bumped in lockstep; no `latest` (NER behaviour must stay reproducible across deploys).
- **`PORT` env** — the anonymizer overrides Presidio's default `:3000` so the two sidecars don't collide on a port.
- **`/health` startup + readiness probes** — the analyzer's startup `failureThreshold` is generous (cold NER-model warmup takes minutes).
- **Resources** — the analyzer carries the larger memory limit (~768Mi; a 500Mi limit OOMs during model load); the anonymizer is light.

App-side wiring is config-driven and gated by `Analyses:Redaction` (`Enabled`, `AnalyzerUrl`, `AnonymizerUrl`, `ConfidenceThreshold`, `TimeoutSeconds`) — the real redactor is swapped in only when `Enabled = true`.

### Per-environment differences (legitimate)

| Knob | dev | prod |
|---|---|---|
| GSM `resourceName` / image project | `invoicesapp-project-test` | `inv-project` |
| `replicas` | 1 | 2 |
| Presidio sidecar resourcing | smaller footprint | full footprint |

Cluster routing (`invoices-cluster` vs `tofu-cluster`) is **not** in the manifests — the shared workflow resolves it from `target` (see § Decision).

## Open questions

- [ ] **API container resource budget** — `service.md` references ~1Gi/800m; the working figure is closer to ~300Mi. Settle the target against a measured backfill batch before the first 50k-account run.
- [ ] **Dev-cluster targets** — the shared workflow supports `development`/`development2` (→ `invoices-cluster`, stage project). Expose them in the `workflow_dispatch` choice list, or keep dispatch limited to `staging`/`production`?
