# FS-1109 — working status & resume notes

> Live working state for the Sentry → LB → backend trace-propagation work. Read this to resume.
> Companion to [`overview.md`](overview.md) (original plan) and [`README.md`](README.md). Last updated: 2026-06-16.

## TL;DR — where we are

- **Goal:** make one user request a single distributed trace with the **Sentry trace-id** as the root,
  correlated across Sentry → GCP load balancer → BFF (`Invoices.Backend`) → `Tofu.Invoices`. **Web only** for now.
- **Currently deployed on stage (test project `invoicesapp-project-test`) and VERIFIED working** for the
  backend chain: a web pageload's Sentry trace-id propagates across all its API calls and into
  `tofu-invoices-api` + `auth-api` (one trace, many spans). See "Verification" below.
- **Two open items:** (1) decide the final web mechanism — **traceparent-only** vs **X-Cloud-Trace-Context**;
  (2) the **LB request log** is still on its own id — bridge it if we want LB↔backend log correlation.
- **The frontend working tree is mid-transition** (uncommitted X-Cloud-Trace-Context experiment that
  conflicts with the traceparent-only direction). Must be reconciled before the next web deploy. See "Repo state".

## Key findings (corrected vs the original plan — these are the valuable bits)

The original `overview.md` plan was wrong on several points. Confirmed facts:

1. **`propagateTraceparent` IS a real `@sentry` JS option — but only since v10.10.0** (not v9, and absent in
   the v8 the app was on). Verified in `@sentry/core@10.58` `types/options.d.ts`. (An earlier "it doesn't
   exist" conclusion was a false negative — pnpm symlinks `node_modules/@sentry/*` into `.pnpm/`, and
   `grep -r` doesn't follow symlinked dirs. Grep the real `.pnpm` path, not the symlink.)
2. **The GCP load balancer does NOT honor a client `traceparent`** for its own request log — it generates
   its own `X-Cloud-Trace-Context` and only *forwards* `traceparent` untouched. Confirmed empirically
   (client `traceparent b642f6b5…` → LB log keyed on `c5479a25…`) and by Google issue
   [401141843](https://issuetracker.google.com/issues/401141843); native support is an open feature request
   ([253419736](https://issuetracker.google.com/issues/253419736)).
3. **The GCP LB DOES honor a client-supplied `X-Cloud-Trace-Context`** — "if the header already exists, it
   passes through the load balancers unmodified" ([external ALB docs](https://docs.cloud.google.com/load-balancing/docs/https)).
   So a web-built `X-Cloud-Trace-Context` is the *only* way to put the **LB log itself** on the Sentry id.
4. **The LB forwards its `X-Cloud-Trace-Context` to the backend** (that's how the BFF's GCP `trace` field
   picked up the LB id) — so the LB id is readable at the BFF for a logging bridge.
5. **GCP tooling prefers `X-Cloud-Trace-Context` over `traceparent`** when both are present
   ([google-cloud-go #7264](https://github.com/googleapis/google-cloud-go/issues/7264)).
6. **`TraceContextPropagator.Extract` short-circuits** if a valid `ActivityContext` already exists — so in a
   composite, propagator **order is precedence** and the first-to-match wins (the LB always injects
   `X-Cloud-Trace-Context`, so a Google-first composite made the LB id always win until reordered/removed).
7. **The LB never emits a Cloud Trace *span*** — it only writes a request *log* with a `trace` field
   ([community thread](https://www.googlecloudcommunity.com/gc/Google-Cloud-s-operations-suite/Google-Cloud-Trace-is-missing-all-spans-from-Cloud-Load-Balancer/m-p/717381)).
   So "LB on the Sentry id" only ever means the LB *log row* joins by id — there's no LB span to gain.
8. CORS is already fine — BFF uses `.AllowAnyHeader()` (`ApiCommonConfiguration.cs:86`), so `traceparent` /
   `X-Cloud-Trace-Context` preflights pass.

## The two viable designs

| | Web change | Backend change | LB log on Sentry id? | Notes |
|---|---|---|---|---|
| **B. traceparent-only** *(currently deployed)* | v10 + `propagateTraceparent: true` | `CompositeTextMapPropagator([TraceContextPropagator])` | ❌ no | Clean W3C. LB log stays on its own id → needs a bridge (Option 1 below) to join LB↔backend logs. |
| **A. X-Cloud-Trace-Context** | ~15-line helper in `wrappers.ts` (build `<traceId>/<spanId-decimal>;o=<0/1>` from active Sentry span); **no SDK upgrade (works on v8)**; no `propagateTraceparent` | none (existing `GoogleCloudTracePropagator` parses it) | ✅ **yes** | Legacy GCP header + hex→decimal span footgun, but "with the grain" of GCP and unifies the LB too. |

**LB↔backend log bridge (needed only for design B):** log the inbound `X-Cloud-Trace-Context` value as a
property (e.g. `LbTraceId`) in `RequestLoggingMiddleware`. The BFF row then carries both the Sentry id
(`TraceId`/`traceparent`) and the LB id → pivot: LB log → BFF row (by `LbTraceId`) → BFF/Tofu.Invoices/Sentry
(by Sentry id). One line, no client/LB change. (Alternative: set the LB id as an OTel span attribute
`gcp.lb.trace_id`; heavier, Cloud-Trace-native.)

## Repo state (as of 2026-06-16)

### `Invoices.Backend` — branch `feature/FS-1109`, **tree clean (committed) & deployed**
- `Src/Invoices.Api/DI/InfrastructureConfiguration.cs` — composite is now **`[TraceContextPropagator]` only**
  (GoogleCloudTracePropagator removed from the list). ⚠️ The **comment block above it is STALE** — it still
  describes the X-Cloud-Trace-Context/Google path. Fix the comment to match design B, or re-add the
  propagator if switching designs.
- `Src/Invoices.Api/Middleware/RequestLoggingMiddleware.cs` — logs inbound `traceparent`.
- `Src/Invoices.Api/Middleware/GoogleCloudTracePropagator.cs` — **now unused** (not in the composite). Dead
  code under design B; still needed under design A. Decide keep vs remove.
- ⚠️ **Regression to weigh:** with Google removed, **non-web traffic** (cron/internal that only carries
  `X-Cloud-Trace-Context`) no longer correlates — those requests start fresh root traces. If that matters,
  use `[TraceContextPropagator, GoogleCloudTracePropagator]` **and** give `GoogleCloudTracePropagator` a
  `if (context.ActivityContext.TraceId != default) return context;` short-circuit so traceparent still wins
  when present but X-Cloud-Trace-Context is the fallback.

### `Tofu.Web.Frontend` — branch `feature/FS-1109`
- **Committed & deployed:** commit `1fa735aa` = `@sentry/react` v8.55→**v10.58** + `propagateTraceparent: true`
  in `src/shared/lib/crash-reporting/index.ts`. This is what's live and producing the verified traces.
- **Uncommitted working tree (the X-Cloud-Trace-Context experiment — NOT deployed):**
  - `package.json` / `pnpm-lock.yaml` / `crash-reporting/index.ts` — **reverted to v8.55 baseline** (staged
    via `git checkout HEAD~1 -- …`); `node_modules` re-synced to v8.
  - `src/shared/lib/http/wrappers.ts` — adds `getGcpTraceHeader()` building `X-Cloud-Trace-Context` from
    `getActiveSpan()` (v8-compatible imports `getActiveSpan`, `spanIsSampled`).
  - Also pre-staged unrelated files to keep OUT of any commit: `.claude/settings.local.json`,
    `vite.config.ts.timestamp-*.mjs`.
- ⚠️ **This working tree is design A, but the deployed code + backend are design B.** Reconcile before any
  web deploy: either (A) commit the working tree and revert the backend to keep Google in the composite, or
  (B) `git checkout -- src/shared/lib/http/wrappers.ts && git restore --staged . && git checkout -- .` to
  drop the X-CTC experiment and keep the deployed v10+propagateTraceparent.

### Deploy repos — no change
- `Deploy/Invoices.WebRoot` (nginx passes the headers; not on the API path) and
  `Deploy/Invoices.Kubernetes` (ALB honors/forwards; FrontendConfig only does `redirectToHttps`) — verified,
  no code change. Both already on branch `feature/FS-1109`.

## Verification (stage = test project `invoicesapp-project-test`)

- **End-to-end confirmed:** a web pageload's Sentry trace-id propagates to the BFF and onward. Example trace
  `719990dfd5ee49559010a016146369b1`: ~2.7s burst, one account, ~dozen endpoints across `invoices-api`,
  `tofu-invoices-api`, `auth-api` — **same trace-id, distinct span-id per request** (correct trace tree,
  not a stuck id). Different pageloads get different ids (`eb5113f5…`, `cad2a36a…`, `b642f6b5…`).
- **Sentry side confirmed:** sampled ids exist in Sentry project `tofu-web-frontend`, env `staging`
  (`eb5113f5…` = txn `/`, `cad2a36a…` = txn `/documents/invoices`), timestamps aligned with the backend rows.
  Only `-01` (sampled) traces appear in Sentry; `-00` reach the backend but Sentry drops them
  (`tracesSampleRate: 0.5`) — expected.
- **SPA caveat:** a Sentry trace can be long-lived if the user doesn't navigate; one id spanning *minutes*
  across separate actions is the SPA long-trace effect, not a backend bug.

### Useful commands

```bash
# gcloud reads need the user account (default SA is denied)
ACC=--account=s.fedorov@tofu.com; PROJ=invoicesapp-project-test

# Did a traceparent reach the BFF? (sampled = ends in -01)
gcloud logging read 'logName="projects/'$PROJ'/logs/Invoices.Api.Middleware.RequestLoggingMiddleware"
 jsonPayload.properties.traceparent:"-01"' --project=$PROJ $ACC --limit=10 --freshness=3h \
 --format='csv[no-heading,separator="|"](timestamp,jsonPayload.properties.traceparent,jsonPayload.properties.RequestPath)'

# All rows on one trace (across services)
gcloud logging read 'trace="projects/'$PROJ'/traces/<TRACE_ID>"' --project=$PROJ $ACC --limit=40 --freshness=6h \
 --format='csv[no-heading,separator="|"](timestamp,resource.labels.container_name,jsonPayload.properties.RequestPath)'

# Is a trace-id in Sentry? (org getpaid-inc; token in /sentry skill)
curl -sS -H "Authorization: Bearer <SENTRY_TOKEN>" \
 "https://getpaid-inc.sentry.io/api/0/organizations/getpaid-inc/events/?dataset=transactions&statsPeriod=24h&field=trace&field=transaction&field=project&field=environment&query=trace:<TRACE_ID>"
```

## Next steps to resume

1. **Decide design A vs B** (the only real open decision). Recommendation: **B + the LB-log bridge** if a
   clean W3C trace is the priority and an exact-id LB↔backend join via the BFF row is acceptable; **A** if
   having the LB log itself on the Sentry id (and no SDK upgrade) matters more.
2. **Reconcile the frontend working tree** to the chosen design (see Repo state warnings).
3. **Fix the stale backend comment** in `InfrastructureConfiguration.cs`; decide keep/remove
   `GoogleCloudTracePropagator` and whether to restore the non-web fallback.
4. If design B: implement the **`LbTraceId` bridge** in `RequestLoggingMiddleware`, redeploy backend, verify
   the LB log → BFF row → Sentry pivot.
5. **Commit** backend + frontend, push, open PR(s). (Frontend commit must exclude the two pre-staged
   unrelated files.)
6. Out of scope / later phases: iOS + Android enablement, `sentry-trace`/`baggage` legacy bridge,
   `Tofu.Auth` OpenTelemetry, two-way Sentry↔Cloud-Trace linking.
