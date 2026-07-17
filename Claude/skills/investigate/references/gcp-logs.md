# GCP Cloud Logging reference (Invoices platform) — single source of truth

Field paths, projects, and query recipes for `gcloud logging read`. Used by investigation collectors AND by the `gcp` skill (which owns env switching and the write gate — this file is read-only knowledge). Only `gcloud logging read` here — never any mutating gcloud command.

**Contents:** Projects · Command shape · A. Resource selectors (A.1 Tofu.AI) · B. Identity & correlation · C. Client/app context (`XA-*`) · D. Request/response · E. Load-balancer log · Recipes

## Projects

- **prod**: `inv-project` — real traffic; READ-ONLY queries allowed and expected when investigating production issues. Never benchmark against prod.
- **test**: `invoicesapp-project-test` — default for anything exploratory.
- Always pass `--project=<id>` explicitly — never rely on the gcloud config default (it drifts invisibly).
- ⚠️ Test-project gotchas: `dev-gateway-api` / `dev2-gateway-api` are **gateway proxies, not the BFF**; the test project co-locates sibling services (`tofu-invoices-api` = Tofu.Invoices core, `auth-api` = Tofu.Auth) in the same logs. Filter by container explicitly.

## Command shape

```
gcloud logging read '<LQL>' --project=inv-project --limit=50 --freshness=24h --format=json
```

- Always bound with `--limit` (default 50; aggregations ≤2000, max practical ~5000) and `--freshness`. Note in findings when a limit was hit — counts are then partial.
- `entries.list` quota is 60 req/min/project — ask fewer, broader questions and filter locally.
- Quote hyphenated JSON fields: `jsonPayload.properties."XA-App-Type"` — unquoted, LQL parses `-` as subtraction.

## A. Resource selectors — *where* the log comes from

| Concept | LQL selector | Value(s) | Notes |
|---|---|---|---|
| Log type | `resource.type` | `k8s_container` (app) · `http_load_balancer` (LB) | different schemas — B–D are app-only, E is LB-only |
| Cluster | `resource.labels.cluster_name` | `tofu-cluster` | both envs |
| **API container (BFF)** | `resource.labels.container_name` | **`invoices-api`** | main target; same name in test and prod (verified) |
| Worker container | `resource.labels.container_name` | `invoices-worker` | background jobs |
| Static webroot | `resource.labels.container_name` | `invoices-webroot` | |
| Request log stream | `logName` | `projects/<proj>/logs/Invoices.Api.Middleware.RequestLoggingMiddleware` | carries all of B–D |

### A.1 Tofu.AI.Backend (FSM-fit / analyses service)

Separate service on a **different cluster** — do NOT reuse the selectors above:

```
resource.type="k8s_container"
resource.labels.cluster_name="invoices-cluster"
resource.labels.container_name="tofu-ai-api"
resource.labels.namespace_name="default"
-jsonPayload.properties.ResponseBodyText="Healthy"
-jsonPayload.properties.RequestPath="/callback/sendgrid/status_update"
```

The two exclusions strip health probes and SendGrid callbacks — keep them on every tofu-ai query. FSM-fit job signal: tick done-line `AnalyzeFsmFitJob: done … 'J' judged, 'C' cached, 'S' skipped`; a Presidio outage logs `Presidio redaction failed:` at ERROR (fail-closed → `skipped` rises rather than the job erroring).

## B. Identity & correlation (attached *after* auth succeeds)

| Concept | LQL field | Notes / gotcha |
|---|---|---|
| Account | `jsonPayload.properties.AccountId` | ⚠️ NOT `jsonPayload.AccountId`. Sentry stores only the segment before the first `-`; backend has the full value → correlate with `=~"^<prefix>"` |
| Master user | `jsonPayload.properties.MasterUserId` | guid |
| User email | `jsonPayload.properties.UserEmail` | |
| Product (resolved) | `jsonPayload.properties.ProductKey` | resolved copy of `XA-App-Type`; `"unknown"` when header missing/invalid |
| Device / vendor id | `jsonPayload.properties."XA-Vendor-Id"` | ⚠️ client-controlled casing — iOS sends lowercase (`"xa-vendor-id"`) |

> ⚠️ **Auth-gated.** `AccountId`, `MasterUserId`, `UserEmail`, `ProductKey` exist only after auth succeeds — framework/early errors won't carry them; filtering by them silently drops those rows. Fall back to container-wide `severity>=ERROR` + a tight time window.

## C. Client / app context (raw `XA-*` headers, logged verbatim)

| Concept | LQL field | Value(s) / mapping |
|---|---|---|
| App type (raw) | `jsonPayload.properties."XA-App-Type"` | `invoices` (iOS Invoice Maker) · `invoices-android` · `invoices.web` · `demo-invoices` · `tofu` · `tofu-fieldservice` · `tofu-fieldservice-worker` · `expenses` · `web-link` · `taxes` · `mileage` · `payments` |
| OS type | `jsonPayload.properties."XA-OsType"` | `android`→Android, `web`→Web, **anything else or absent ⇒ iOS** |
| App version | `jsonPayload.properties."XA-App-Version"` | logged twice: raw header and computed `AppVersion` |
| OS version / device | `"XA-OS-Version"`, `"XA-Device-Model"` | |
| Store / timezone | `"XA-Store"`, `"XA-Timezone"` | |
| API version | `jsonPayload.properties.ApiVersion` | `1.0` / `2.0` / `3.0` (per-action versioning, `api-version` header) |

> Any key containing `.web` is treated as Web. `invoices`, `invoices-android`, `tofu-fieldservice` are "owner-only" products (`ProductConst.IsOwnerOnlyProduct`). Header-derived keys keep **whatever casing the client sent**.

## D. Request / response (per-request, always present)

| Concept | LQL field | Notes |
|---|---|---|
| Method / path | `RequestMethod`, `RequestPath` | exact `=`, substring `:`, regex `=~` |
| Path + query / query | `RequestPathAndQuery`, `RequestQuery` | |
| Request body | `RequestBodyText` | truncated 10 KB; `"password"` values masked |
| Response body | `ResponseBodyText` | ⚠️ **BFF 200-error envelope** — a "500" in Sentry is often HTTP 200 with an error body at WARNING. Search HERE, not only StatusCode. Empty for PDF/streamed endpoints |
| Status / elapsed | `StatusCode`, `Elapsed` (ms) | compare `Elapsed` to LB `httpRequest.latency` |
| Endpoint | `EndpointName` | controller.action display name |
| Client IP | `RemoteIP` | |
| Rendered message | `jsonPayload.message` | logger-dependent; downstream gRPC-client logs (e.g. `InvoicesApi/Delete`) come from a different logger — match via `message:"…"` substring |

(All of the above under `jsonPayload.properties.*`.)

> ⚠️ `jsonPayload.properties.RequestId` does **not** exist — the middleware stashes it in `context.Items` only. Don't filter on it.

## E. Load-balancer log (`resource.type="http_load_balancer"`)

| Concept | LQL field | Notes |
|---|---|---|
| Latency (edge) | `httpRequest.latency` | e.g. `>"2s"`; `latency >> Elapsed` ⇒ LB/network overhead, `Elapsed ≈ latency` ⇒ in-app slowness |
| Status / size / URL | `httpRequest.status`, `httpRequest.responseSize`, `httpRequest.requestUrl` (substring `:`) | |
| User agent | `httpRequest.userAgent` | |
| Trace | `trace` | **join key** with app logs: `trace="projects/<proj>/traces/<TRACE_ID>"` |

## Recipes

```bash
# Errors on a path, last 24h (remember the 200-error-envelope gotcha)
gcloud logging read 'jsonPayload.properties.RequestPath:"/api/tap2pay" AND (jsonPayload.properties.StatusCode>=500 OR jsonPayload.properties.ResponseBodyText:"error")' --project=inv-project --limit=50 --freshness=24h --format=json

# Aggregate distinct values with counts (who is affected / which endpoints / which versions)
gcloud logging read '<filter>' --project=inv-project --limit=2000 --freshness=24h --format='value(jsonPayload.properties.AccountId)' | awk 'NF==0{print "(empty)"; next} {print}' | sort | uniq -c | sort -rn
# the awk keeps rows where the field was missing — silently dropping them skews percentages

# Multi-field aggregation — | separator survives commas in paths; parse with awk -F'|'
--format='csv[no-heading,separator="|"](jsonPayload.properties.RequestMethod,jsonPayload.properties.EndpointName)'

# Find a user's account + recent activity
gcloud logging read 'jsonPayload.properties.UserEmail="<email>"' --project=inv-project --limit=50 --freshness=7d --format=json

# Container-wide errors when auth-gated fields are missing
gcloud logging read 'resource.labels.container_name="invoices-api" severity>=ERROR' --project=inv-project --limit=50 --freshness=2h --format=json

# LB ↔ app trace correlation (one trace)
gcloud logging read 'trace="projects/<proj>/traces/<TRACE_ID>" logName="projects/<proj>/logs/Invoices.Api.Middleware.RequestLoggingMiddleware"' --project=<proj> --limit=1
```

GCP Monitoring alert URLs: the Monitoring API is not wired here, but violation events land in Cloud Logging — `monitoring.googleapis.com/ViolationOpenEventv1` entries name the policy + condition.
