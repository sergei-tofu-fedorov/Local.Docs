# FS-1109 — End-to-end trace propagation (Sentry → balancer → backend)

**Affected repos:** `Invoices.Backend` (BFF), `Tofu.Invoices.Backend`, `Deploy/Invoices.WebRoot` (nginx)

## Goal

Make a single user request one continuous distributed trace, from the frontend Sentry
trace through the load balancer and onward into the backend (BFF → gRPC → Tofu.Invoices),
correlated in Google Cloud Trace / Logging by a shared trace-id.

## Scope

- **In:** BFF propagator chain (add W3C `TraceContextPropagator` + `BaggagePropagator` —
  extract `traceparent`/`baggage` inbound, inject `traceparent` onward over gRPC), LB
  `traceparent` pass-through verification, Tofu.Invoices confirmation.
- **Out:** Tofu.Auth (no OpenTelemetry today — deferred), two-way link back into Sentry.
- **FE prerequisite (enabler):** frontend/iOS enable Sentry `propagateTraceparent: true` +
  add the API origin to `tracePropagationTargets`. Tracked separately.

## Open questions

- No client sets it today (verified Jun 2026): **web** `@sentry/react` 8.55.0 (absent in v8 →
  needs v9/v10); **iOS** `sentry-cocoa` 8.58.0 (`enablePropagateTraceparent` is a 9.0.0 option →
  bump to 9.x, Alamofire/URLSession auto-instrumented); **Android** KMP + Ktor, Sentry KMP 0.23.0
  (no Ktor auto-instrumentation, tracing off → manual Ktor-plugin injection). Need FE/iOS/Android tickets.

See `overview.md` for the implementation plan.
