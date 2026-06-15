# FS-1109 — End-to-end trace propagation (Sentry → balancer → backend)

A user action in the frontend opens a Sentry trace and attaches trace-context headers to its
API calls. Today that trace-id is lost at the backend edge: the BFF (`Invoices.Backend`) only
understands Google Cloud's `X-Cloud-Trace-Context`, and it forwards **no** trace context onward
over gRPC, so `Tofu.Invoices` starts a fresh root trace. This feature makes the **Sentry
trace-id the single id across the whole request** — frontend, load balancer, BFF, and
`Tofu.Invoices` — using the standard W3C `traceparent` header, correlated in Google Cloud Trace
/ Logging by that shared id.

Related ClickUp tasks:
- [FS-1109](https://app.clickup.com/t/FS-1109) — backend trace propagation
- Frontend prerequisite (Sentry `propagateTraceparent` + `tracePropagationTargets`) — *TBD, link when filed*

## Scope

**In scope** (all backend/deploy; see *Implementation* for code)
- BFF: new `SentryTracePropagator` + extend the default propagator chain (W3C `TraceContextPropagator`
  + `BaggagePropagator` + `SentryTracePropagator` + existing `GoogleCloudTracePropagator`) so it
  extracts `traceparent`/`sentry-trace`/`baggage` inbound and injects `traceparent` outbound (HTTP + gRPC).
- BFF: log `sentry-trace`/`traceparent` in `RequestLoggingMiddleware` (old-client LB↔backend bridge + verification hook).
- Verify the load balancer passes `traceparent` through and keys its request log on it (deploy repos — no code change).
- Confirm `Tofu.Invoices` continues the propagated trace (it already uses the W3C default).

**Out of scope (but required for the chain to light up)**
- **Frontend Sentry config** — enable `propagateTraceparent: true`. This is the enabler; without
  it no W3C `traceparent` reaches the backend. Current client state (verified June 2026):
  - **Web (`Tofu.Web.Frontend`)** — `@sentry/react` **8.55.0**. Already sends `sentry-trace` +
    `baggage` to the API (`browserTracingIntegration` + `tracePropagationTargets: [APP_URL,
    API_URL]` in `src/shared/lib/crash-reporting/index.ts:12-21`), but `propagateTraceparent`
    **does not exist in v8** (0 hits in `node_modules/@sentry/*`). ⚠️ Enabling it requires a
    **major SDK upgrade (v9/v10)** — not a one-line change for web.
  - **iOS (`Invoices.Apps.iOS`)** — `sentry-cocoa` **8.58.0** (`AppDelegate.swift:70`
    `SentrySDK.start`, `tracesSampleRate 0.1`; networking is **Alamofire over URLSession**, so
    Sentry's URLSession swizzling auto-attaches headers on iOS 16+). Already sends
    `sentry-trace`/`baggage` (no `tracePropagationTargets` → Cocoa default = all). The stable
    option is `options.enablePropagateTraceparent = true`, **documented since cocoa 9.0.0** →
    requires bumping cocoa **8.58 → 9.x**, then two lines (`enablePropagateTraceparent` +
    `tracePropagationTargets`). Not a no-upgrade change.
  - **Android (`Tofu.FieldService.WorkerApp`)** — Kotlin Multiplatform, **Ktor** HTTP client in
    `core/network/.../KtorClient.kt`, Sentry **KMP SDK 0.23.0** (`SentryTracker.kt`). Tracing is
    **not even enabled** (no `tracesSampleRate`), and the KMP SDK does **not** auto-instrument
    Ktor. Enabling needs: turn on tracing + **manual trace-header injection in a Ktor plugin /
    the existing `DefaultRequest` block** (the KMP SDK's official Ktor integration is JVM-only,
    not commonMain). Heaviest of the three; see *Client enablement* below.
  Tracked under its own FE/iOS/Android ticket(s).
- `Tofu.Auth.Backend` — has no OpenTelemetry today; adding it is deferred to a follow-up.
- Two-way linking (surfacing the backend trace-id back into Sentry).

## High-level approach

Use **W3C Trace Context (`traceparent`)** as the single trace lingua franca — the format all
three parties already speak — rather than a custom backend parser or the legacy Google header.

1. **Sentry emits `traceparent` itself.** The frontend SDK option `propagateTraceparent: true`
   (default `false`, opt-in) makes it send `traceparent: 00-<traceId>-<spanId>-<sampled>`
   alongside its native `sentry-trace`/`baggage`, carrying the **same** trace-id as `sentry-trace`.
   It is sent only when the option is on **and** the request matches `tracePropagationTargets`.
2. **The GCP load balancer honors `traceparent`** — Google explicitly recommends it over
   `X-Cloud-Trace-Context`. A client-supplied `traceparent` is adopted as the LB's own trace-id
   (so the LB request log's `trace` field becomes the Sentry id) and forwarded downstream. If
   absent, the LB generates its own — i.e. existing non-Sentry traffic is unaffected.
3. **The backend continues it on OTel's default propagator** — W3C `TraceContext`. `Tofu.Invoices`
   is already on the OTel default, and the BFF gets W3C added to its composite (below) — which we
   need anyway to inject the trace across the gRPC hop.

Result: one trace-id across **Sentry → LB log → BFF → Tofu.Invoices**, joined in Cloud Trace /
Logging, using the standard mechanism — no custom parsing code, no hand-built legacy header.

**Why this over the alternatives considered:**

| Approach | Frontend change | LB on same id | Cleanliness |
|---|---|---|---|
| **`traceparent` (`propagateTraceparent`)** — chosen | one flag + `tracePropagationTargets` | **Yes** | W3C standard, nothing custom |
| Hand-built `X-Cloud-Trace-Context` | build the header, hex→decimal span-id | Yes | legacy header, decimal-span-id footgun |
| `SentryTracePropagator` parsing `sentry-trace` on the backend | none | **No** | custom parser, and the LB log stays on its own id |

The `traceparent` route is the only one that is both standard *and* puts the LB on the Sentry
id. But the client fleet is **mixed and will stay mixed for a while**: today no client sends
`traceparent` (web `@sentry/react` 8.55.0 can't until a v9/v10 upgrade; iOS `sentry-cocoa`
8.58.0 can but isn't), yet both already send `sentry-trace`/`baggage`. So we build the backend
to accept **both**, with a single precedence rule, and never touch it again as clients migrate.

### Backward compatibility — one backend, both client generations

The BFF composite carries extractors for every header generation; `CompositeTextMapPropagator.Extract`
runs them in order and **last-with-a-match wins**, so precedence is encoded by ordering:

| Client sends | Backend root trace-id from | LB on same id? | When |
|---|---|---|---|
| `traceparent` (+ `sentry-trace`) | `TraceContextPropagator` (W3C) | **Yes** (LB honors `traceparent`) | future clients |
| `sentry-trace` only | `SentryTracePropagator` (parse `sentry-trace`) | No (LB doesn't grok it) → bridge via logged ids | today's web/iOS |
| neither (cron, internal, non-Sentry) | `GoogleCloudTracePropagator` (LB `X-Cloud-Trace-Context`) | Yes (LB-generated) | non-user traffic |

In every case the BFF then injects a single W3C `traceparent` onward, so `Tofu.Invoices` and
Cloud Trace correlation are uniform regardless of which generation the client is. The only thing
that varies is whether the **LB log** shares the id — and that upgrades automatically, per client,
the moment a client starts sending `traceparent`, with **no backend redeploy**. For old clients,
the LB↔backend gap is closed by logging both ids on the BFF request row (see Verification).

## Implementation — backend + deploy

Concrete, ordered changes for the repos we own. **All required code lives in one repo
(`Invoices.Backend`); `Tofu.Invoices.Backend` and the deploy repos need no code change**, only
the noted verification.

### Repo 1 — `Invoices.Backend` (BFF) — the only code changes

#### Step 1 — New file `Src/Invoices.Api/Middleware/SentryTracePropagator.cs`

A `TextMapPropagator` modelled on `GoogleCloudTracePropagator.cs`. Note the format difference vs
the Google header: `sentry-trace` is `{traceId:32hex}-{spanId:16hex}[-{sampled:0|1}]` — span-id
is **hex** (not decimal like `X-Cloud-Trace-Context`), so no numeric conversion. `Inject` is a
no-op (outbound is W3C, see Step 2); `Extract` returns `context` unchanged on any malformed input.

```csharp
using System.Diagnostics;
using OpenTelemetry.Context.Propagation;

namespace Invoices.Api.Middleware;

public class SentryTracePropagator : TextMapPropagator
{
    private const string SentryTraceHeader = "sentry-trace";

    private readonly ILogger<SentryTracePropagator> _logger;

    public SentryTracePropagator(ILogger<SentryTracePropagator> logger) => _logger = logger;

    public override ISet<string> Fields => new HashSet<string> { SentryTraceHeader };

    // Outbound propagation is W3C traceparent, emitted by TraceContextPropagator — nothing to do here.
    public override void Inject<T>(PropagationContext context, T carrier, Action<T, string, string> setter) { }

    public override PropagationContext Extract<T>(PropagationContext context, T carrier,
        Func<T, string, IEnumerable<string>> getter)
    {
        var header = getter(carrier, SentryTraceHeader)?.FirstOrDefault();
        if (string.IsNullOrEmpty(header))
            return context;

        try
        {
            // {trace_id:32hex}-{span_id:16hex}[-{sampled:0|1}]
            var parts = header.Split('-');
            if (parts.Length < 2 || parts[0].Length != 32 || parts[1].Length != 16)
                return context;

            var flags = parts.Length > 2 && parts[2] == "1"
                ? ActivityTraceFlags.Recorded
                : ActivityTraceFlags.None;

            var traceContext = new ActivityContext(
                ActivityTraceId.CreateFromString(parts[0]),
                ActivitySpanId.CreateFromString(parts[1]),
                flags,
                isRemote: true);

            return new PropagationContext(traceContext, context.Baggage);
        }
        catch
        {
            return context;
        }
    }
}
```

#### Step 2 — Edit `Src/Invoices.Api/DI/InfrastructureConfiguration.cs:59-64`

Replace the single-entry composite (today only `GoogleCloudTracePropagator`, whose `Inject` is a
no-op — `GoogleCloudTracePropagator.cs:19-22` — which is why the BFF injects nothing into gRPC):

```csharp
// BEFORE (lines 59-64)
builder.Services.ConfigureOpenTelemetryTracerProvider((sp, tp) => {
    Sdk.SetDefaultTextMapPropagator(new CompositeTextMapPropagator(
        new List<TextMapPropagator>() {
            new GoogleCloudTracePropagator(sp.GetRequiredService<ILogger<GoogleCloudTracePropagator>>())
        }));
});

// AFTER  (order = precedence; CompositeTextMapPropagator.Extract runs in order, last-with-a-match wins)
builder.Services.ConfigureOpenTelemetryTracerProvider((sp, tp) => {
    Sdk.SetDefaultTextMapPropagator(new CompositeTextMapPropagator(
        new List<TextMapPropagator>() {
            new GoogleCloudTracePropagator(sp.GetRequiredService<ILogger<GoogleCloudTracePropagator>>()), // base: LB X-Cloud-Trace-Context
            new BaggagePropagator(),                                                                       // W3C + Sentry baggage
            new SentryTracePropagator(sp.GetRequiredService<ILogger<SentryTracePropagator>>()),            // old clients: sentry-trace
            new TraceContextPropagator(),                                                                  // future clients: traceparent + ONLY injector
        }));
});
```

`TraceContextPropagator` / `BaggagePropagator` are from `OpenTelemetry.Context.Propagation`
(already imported at `InfrastructureConfiguration.cs:4`). Only `TraceContextPropagator` injects,
so regardless of inbound generation the BFF emits a single clean W3C `traceparent` — and gRPC
forwarding is automatic via `AddGrpcClientInstrumentation` (`InfrastructureConfiguration.cs:47`).

#### Step 3 — Edit `Src/Invoices.Api/Middleware/RequestLoggingMiddleware.cs` (the bridge + verification hook)

Today only `XA-`-prefixed headers are logged (`RequestLoggingMiddleware.cs:43-46`), so trace
headers are invisible in logs. Add `sentry-trace` and `traceparent` to the logged scope so (a)
old-client requests carry both the Sentry id and the resolved GCP `TraceId` on one row (the
LB↔backend bridge), and (b) we can verify headers arrive. Mirror the existing `AppVersion` /
`ApiVersion` blocks (`RequestLoggingMiddleware.cs:67-77`):

```csharp
foreach (var traceHeader in new[] { "sentry-trace", "traceparent", "baggage" })
{
    if (request.Headers.TryGetValue(traceHeader, out var traceValue))
        logProperties.Add(traceHeader, traceValue.ToString());
}
```

`TraceId`/`SpanId` are already emitted by `Serilog.Enrichers.Span` (`InfrastructureConfiguration.cs:35`),
so the GCP-side id needs nothing extra — this only adds the Sentry-side id.

#### Not changing

- `Src/Invoices.Api/Middleware/SetMetadataInterceptor.cs` — forwards `X-Account-Id` only
  (`:8, :28`); gRPC trace injection is automatic via the default propagator. Hand-forwarding
  `traceparent` here would double-inject.
- **Sampling stays `AlwaysOnSampler`** (`InfrastructureConfiguration.cs:52`) → 100% of backend
  traces recorded, independent of the client's sampled flag. *Optional:* switch to
  `ParentBasedSampler(new AlwaysOnSampler())` if you want the backend to honor the client's
  sample decision (cuts Cloud Trace volume but drops backend spans for unsampled client traces).
  Flag, don't do, unless cost requires it.

### Repo 2 — `Tofu.Invoices.Backend` — no code change

`src/Tofu.Invoices.Api/Configurations/OpenTelemetryTracingConfiguration.cs` never calls
`SetDefaultTextMapPropagator`, so it uses OTel's default (W3C TraceContext + Baggage) and will
extract the `traceparent` the BFF now injects, continuing the same trace. *Optional hardening:*
set an explicit `CompositeTextMapPropagator(TraceContextPropagator + BaggagePropagator)` there so
a future edit can't silently drop it. Flag, don't do.

### Repo 3 — Deploy repos — no code change, verify only

The API request path is **GCP HTTP(S) Load Balancer → `invoices-api-service` (the BFF)** — it
does *not* traverse `Deploy/Invoices.WebRoot/nginx/nginx.conf` (that nginx fronts the marketing
site, Webflow proxy, and `/swagger` only — `upstream api_app` at `nginx.conf:33-34` is used by
the `/swagger` location `nginx.conf:320` and the dev/support gateways, not app API traffic).

- **`Deploy/Invoices.Kubernetes`** — no change. GCP Application Load Balancers honor a
  client-supplied `traceparent` (recommended over `X-Cloud-Trace-Context`): they adopt its
  trace-id into the LB request log's `trace` field and forward it downstream. **Verify** there is
  no header-stripping `BackendConfig`/`headerAction` on the LB (default passes custom headers
  through). Note: live K8s/LB manifests are gitignored (`Deploy/Invoices.Kubernetes/README.md`),
  so any LB tweak — if a strip is found — is applied cluster-side, not committed here.
- **`Deploy/Invoices.WebRoot`** — no change. nginx passes request headers to upstream by default;
  `underscores_in_headers off` (nginx default) would drop underscore headers, but `traceparent` /
  `baggage` / `sentry-trace` use hyphens or no separator, so they survive. Relevant only if
  `/swagger` ever needs trace continuity.

## Verification

- **Headers reaching the BFF:** confirm `traceparent` / `sentry-trace` / `baggage` arrive on API
  requests (browser DevTools → Network, or temporarily log them in `RequestLoggingMiddleware` —
  it captures only `xa-*` headers today, so trace headers are invisible in logs until added).
- **End-to-end (both client generations):** the Sentry trace-id appears on the BFF app log
  (`TraceId`) and on the `Tofu.Invoices` spans, joinable in Cloud Trace — regardless of whether
  the client sent `traceparent` or `sentry-trace`.
- **LB on the Sentry id (future clients only):** for a `traceparent`-sending client, the LB
  request-log `trace` field == the Sentry event trace-id.
- **Old-client LB bridge:** for `sentry-trace`-only clients the LB keeps its own id. To keep
  LB↔backend correlatable, **log both ids on the BFF request row** — add `sentry-trace` (and the
  resolved `TraceId`) to the captured set in `RequestLoggingMiddleware`. The BFF row then carries
  the Sentry id *and* the LB/GCP id, so the pivot is: Sentry event → BFF log (by sentry id) →
  read its GCP `trace` → LB log. Cheap, no client dependency, and useful as the verification hook
  above too.

## Docs to Update

- `Invoices.Backend/Docs/howto/` — add a short "distributed tracing / trace propagation" note
  describing the W3C `traceparent` chain and the Sentry → GCP correlation flow.
- `Local.Docs` observability notes (if any) — record that the Sentry trace-id is the root id in
  GCP Trace and how to pivot Sentry ↔ Cloud Trace.

## References

- Sentry — Distributed Tracing / `propagateTraceparent`: https://develop.sentry.dev/sdk/telemetry/traces/distributed-tracing/
- Sentry — Set Up Distributed Tracing (`tracePropagationTargets`): https://docs.sentry.io/platforms/javascript/guides/connect/tracing/distributed-tracing/
- Google Cloud — Trace context (`traceparent` vs `X-Cloud-Trace-Context`): https://docs.cloud.google.com/trace/docs/trace-context
- Google Cloud — Link log entries with traces: https://docs.cloud.google.com/trace/docs/trace-log-integration
