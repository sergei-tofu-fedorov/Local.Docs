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

- Always bound with `--limit` (default 50; aggregations ≤2000, max practical ~5000) and a time bound. Note in findings when a limit was hit — counts are then partial.
- **Two ways to bound time, and they are mutually exclusive.** `--freshness` is a relative lookback from now; an explicit `timestamp` clause in the filter is an absolute window. Per `gcloud logging read --help`, `--freshness` "works only with DESC ordering and filters **without a timestamp**" — so the moment your filter contains `timestamp>=…`, the flag is silently inert. Passing both is not an error and not a belt-and-braces bound; it just means the window governs. Verified 2026-07-25: a query for a 4-day-old window returned its rows with `--freshness=1d`.
- `entries.list` quota is 60 req/min/project — ask fewer, broader questions and filter locally.
- Quote hyphenated JSON fields: `jsonPayload.properties."XA-App-Type"` — unquoted, LQL parses `-` as subtraction.
- Timestamps in the filter are RFC3339 **UTC** (`2026-07-21T00:56:17Z`). Screenshots from the Logs Explorer and times quoted by a user in this workspace are usually UTC+3 — subtract 3 hours before pasting them into a filter, or you will search the wrong hour and conclude "no events".

## A. Resource selectors — *where* the log comes from

| Concept | LQL selector | Value(s) | Notes |
|---|---|---|---|
| Log type | `resource.type` | `k8s_container` (app) · `http_load_balancer` (LB) | different schemas — B–D are app-only, E is LB-only |
| Cluster | `resource.labels.cluster_name` | `tofu-cluster` | both envs |
| **API container (BFF)** | `resource.labels.container_name` | **`invoices-api`** | main target; same name in test and prod (verified) |
| Worker container | `resource.labels.container_name` | `invoices-worker` | background jobs |
| Static webroot | `resource.labels.container_name` | `invoices-webroot` | |
| Request log stream | `logName` | `projects/<proj>/logs/Invoices.Api.Middleware.RequestLoggingMiddleware` | carries all of B–D |

### A.2 Container → owning repo

**The container name in a log row is a routing key, not decoration.** It tells you two things at once: the selector to scope every follow-up query with, and which repo to open for the mechanism. A screenshot or an alert that shows `auth-api` has already answered "where do I look" — read it before composing anything, and pin `resource.labels.container_name` on the very first query so you are not searching the whole cluster.

Prod containers verified live 2026-07-25 (`inv-project`), ordered by WARNING-and-above volume over 2 days:

| Container | Service | Repo (`C:\Git\Work\`) |
|---|---|---|
| `invoices-api` | BFF for web + iOS-admin | `Backend\Invoices.Backend` |
| `subs2-api`, `subs-stripe-api`, `subs-android-api`, `subs-event-stream-worker` | subscription/billing service ("subz") | `Subz` |
| `invoices-worker` | BFF background jobs | `Backend\Invoices.Backend` (Worker) |
| `tofu-invoices-api` | core invoices/estimates domain | `Backend\Tofu.Invoices.Backend` |
| `auth-api` | authentication, sessions, permissions | `Backend\Tofu.Auth.Backend` |
| `invoices-webroot` | nginx static content | — (infra; message is in `textPayload`) |
| `expenses-api`, `expenses-worker` | expenses | `Tofu.Expenses.Backend` |
| `payments-api` | payments | `Backend\Tofu.Payments.Backend` |
| `tofu-ai-api` | FSM-fit / analyses / warehouse ingests | `Backend\Tofu.AI.Backend` (selectors in A.1 — different cluster) |
| `tofu-web-app`, `tofu-web-promo` | web front end | `Tofu.Web.Frontend` |
| `gke-metrics-agent`, `metrics-server` | infra | — (plain-text logs) |

An error in one container regularly originates in another — `auth-api` returning 401 surfaced in `invoices-api` as "Unable to authenticate user with authentication API". Follow the chain with the trace join key rather than guessing which service is at fault.

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

**Where the error text lives depends on the container.** BFF/worker (.NET Serilog) logs put it in `jsonPayload.message`; **infra/non-BFF containers do NOT** — nginx (`invoices-webroot`), `gke-metrics-agent`, fluentbit, etc. write plain-text logs where the message is in **`textPayload`**. When reading `severity>=ERROR` across containers, project **both** `jsonPayload.message` and `textPayload` (only one is populated per row), or you'll get blank messages for the infra noise.

> `jsonPayload.properties.RequestId` **does** exist on BFF request rows (ASP.NET connection-scoped form, e.g. `0HNN9E5D10FFA:00000066`) — verified on `invoices-api` prod, 2026-07-25. It is per-connection, not a distributed trace id: to follow a request across services use `TraceId` / `SentryTraceId` or the LB `trace` join key.

## E. Load-balancer log (`resource.type="http_load_balancer"`)

| Concept | LQL field | Notes |
|---|---|---|
| Latency (edge) | `httpRequest.latency` | e.g. `>"2s"`; `latency >> Elapsed` ⇒ LB/network overhead, `Elapsed ≈ latency` ⇒ in-app slowness |
| Status / size / URL | `httpRequest.status`, `httpRequest.responseSize`, `httpRequest.requestUrl` (substring `:`) | |
| User agent | `httpRequest.userAgent` | |
| Trace | `trace` | **the cross-service join key.** Top-level entry field (not under `jsonPayload`), present on LB *and* app rows: `trace="projects/<proj>/traces/<TRACE_ID>"`. Indexed — unlike `jsonPayload.properties.*` filters it works without a resource selector. The app-side copy is also in `jsonPayload.properties.TraceId` (bare hex, no `projects/…` prefix) |

## Recipes

**Always include a resource selector.** A filter on a `jsonPayload.properties.*` field alone can return **zero rows** where the same filter plus `resource.labels.container_name="…"` returns matches — verified 2026-07-25 on `RequestPath="/api/plans/current"`. The empty result is silent and reads as "no such events". Scope the container first, then filter.

**Scope by AccountId before going deep.** For any "who is affected / how bad is it" question the first query is the distinct-AccountId aggregation below, not individual entries: it turns a wall of rows into "N accounts, one of them 90% of the volume" and immediately separates a retry loop (few accounts, many rows) from real breadth. Pull entries only for the accounts that aggregation points at.

**Search outward from a known event, not across the calendar.** Once you hold ONE concrete entry — an error, a trace, a support report — you have a timestamp and an actor, and that pair is worth far more than a wide date range. A `±30 min` window around the event, filtered to the same account or device, reconstructs what the user was actually doing: the screen they came from, the retries, the request that succeeded a minute later. A 30-day sweep for the same question costs minutes of wall-clock, burns the 60 req/min quota, hits `--limit` caps that make counts silently partial, and still buries the answer in noise.

Escalation ladder — each rung only if the one before it came back empty:

| Rung | Bound | Question it answers |
|---|---|---|
| 1 | `±30 min` around the event, same `AccountId` (or `xa-vendor-id` for a device) | what this user was doing around the failure — the usual answer |
| 2 | Widen to `±2-6 h`, same actor | a slow-burning or retry-driven sequence |
| 3 | Same day, drop the actor, keep the container and the error signature | is this one user or everyone |
| 4 | Multi-day with `--freshness`, aggregation only (never entry dumps) | first-seen, trend, blast radius |

Rungs 1-3 are absolute windows; only rung 4 uses `--freshness`. Justify a multi-day entry dump before running one — "I need first-seen" is a reason, "I want to look around" is not.

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

# Email -> AccountId / MasterUserId / ProductKey (the join key for every other store)
gcloud logging read 'jsonPayload.properties.UserEmail="<email>"' --project=inv-project --limit=2000 --freshness=30d --format='csv[no-heading,separator="|"](jsonPayload.properties.UserEmail,jsonPayload.properties.AccountId,jsonPayload.properties.MasterUserId,jsonPayload.properties.ProductKey)' | sort | uniq -c | sort -rn

# Subscription AS THE USER SAW IT — the client-facing answer, straight out of the response body
gcloud logging read 'resource.labels.container_name="invoices-api" AND jsonPayload.properties.AccountId="<id>" AND jsonPayload.properties.RequestPath="/api/plans/current"' --project=inv-project --limit=5 --freshness=7d --format='csv[no-heading,separator="|"](timestamp,jsonPayload.properties.ResponseBodyText)'
# /api/plans/current  -> {"isActive","isTrialAvailable","currentTime","adapterType","isFirstMaster","hasDuplicateSubscriptions"}
# /api/account/subscription -> {"isActive","currentTime","adapterType"}   (thinner; same isActive)

# NEIGHBOURHOOD OF A KNOWN EVENT — the default deep-dive. Anchor = one error's timestamp + its AccountId.
# --order=asc reads the window forward in time, so it plays back as a story instead of in reverse.
# No --freshness here: the timestamp clause makes it inert (see the command-shape notes).
gcloud logging read 'jsonPayload.properties.AccountId="<id>" AND timestamp>="2026-07-21T00:26:17Z" AND timestamp<="2026-07-21T01:26:17Z"' --project=inv-project --order=asc --limit=200 --format='csv[no-heading,separator="|"](timestamp,resource.labels.container_name,jsonPayload.properties.RequestPath,jsonPayload.properties.StatusCode)'
# Shape first when the window is busy — which endpoints were touched at all:
#   --format='value(jsonPayload.properties.RequestPath)' | sort | uniq -c | sort -rn
# Same window by DEVICE instead of account (pre-auth rows, or one device across accounts):
#   'jsonPayload.properties."xa-vendor-id"="<vendor-id>" AND timestamp>=… AND timestamp<=…'
# ⚠️ Web clients send no vendor id (the field is empty; `xa-ostype`="web") — on web, AccountId is the only anchor.

# Container-wide errors when auth-gated fields are missing
gcloud logging read 'resource.labels.container_name="invoices-api" severity>=ERROR' --project=inv-project --limit=50 --freshness=2h --format=json

# LB ↔ app trace correlation (one trace, latency comparison only)
gcloud logging read 'trace="projects/<proj>/traces/<TRACE_ID>" logName="projects/<proj>/logs/Invoices.Api.Middleware.RequestLoggingMiddleware"' --project=<proj> --limit=1

# FULL CAUSAL CHAIN of one request — the highest-value move after you have a TraceId from an error entry.
# Drop the logName pin: one trace spans the LB and EVERY container the request touched (BFF -> auth-api -> core),
# in order, including the INFO rows around the error that name the actual cause.
gcloud logging read 'trace="projects/inv-project/traces/<TRACE_ID>"' --project=inv-project --limit=100 --freshness=30d --format='csv[no-heading,separator="~"](timestamp,resource.labels.container_name,severity,jsonPayload.message)'
# Shape it first if the trace is noisy — which containers/loggers took part:
#   --format='csv[no-heading,separator="|"](resource.labels.container_name,logName,severity)' | sort | uniq -c | sort -rn
# ⚠️ Stack traces contain newlines: parse with awk -F'~' on a record separator, or the rows will look mangled.
# Worked example (2026-07-25): a trace on an auth 401 carried 8 rows across `requests` (LB), invoices-api and auth-api;
# the INFO line "Most important identity claims: 'ProviderId':'anonymous'" one tick BEFORE the error is what
# identified the token shape — the error row alone did not carry it.
```

GCP Monitoring alert URLs: the Monitoring API is not wired here, but violation events land in Cloud Logging — `monitoring.googleapis.com/ViolationOpenEventv1` entries name the policy + condition.
