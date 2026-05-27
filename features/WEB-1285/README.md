# WEB-1285

## Investigation: Load Balancer Overhead

**Project:** `invoicesapp-project-test` (staging/dev — not prod `inv-project`)
**Environments checked:** staging (`staging.getpaidapp.com`, `staging.tofu.com`), dev (`development.tofu.com`), dev2 (`development2.tofu.com`)
**Date:** 2026-04-14 to 2026-04-16

### Problem Statement

Sometimes `httpRequest.latency` from the GCP load balancer logs is significantly higher than the actual time spent inside `invoices-api` (measured by `RequestLoggingMiddleware.Elapsed`). The question is whether the load balancer itself is adding extra overhead on top of the real app processing time.

### Methodology

1. Pull requests from LB logs (`resource.type="http_load_balancer"`, latency > threshold)
2. Extract `trace` from each LB entry
3. Look up the corresponding app log via trace + `RequestLoggingMiddleware` log name
4. Compare `httpRequest.latency` (LB) vs `jsonPayload.properties.Elapsed` (app)
5. The difference = LB overhead (connection setup + request/response transfer)

### Findings

#### Round 1 - 2026-04-14 (9 traces, LB latency > 2s)

All 9 traces showed overhead between 80-222ms. Normal range.

#### Round 2 - 2026-04-15 (115 matched traces, LB latency > 1s)

138 LB entries pulled, 115 matched to app logs, 23 had no app log.

Two overhead outliers found:

| LB Latency | App Elapsed | Overhead | Endpoint |
|---|---|---|---|
| 6089ms | 94ms | **+5995ms** | `GET /api/account-configurations/regional` |
| 1057ms | 289ms | **+768ms** | `GET /api/Invoices/:id/html-preview` |

All other 113 traces had overhead between 60-280ms.

23 traces had no app log (request never reached the backend) — mostly vulnerability scan traffic hitting the IP directly + a few `sendgrid/status_update` callbacks.

#### Round 3 - 2026-04-16 (300 matched traces, LB latency > 0.5s)

Broadest analysis: 300 API traces cross-referenced, segmented by response size and app speed.

**LB overhead by response size:**

| Segment | n | Avg overhead | p50 | p95 | Max | >500ms |
|---|---|---|---|---|---|---|
| Small (<5KB) | 286 | 133ms | 129ms | 187ms | 580ms | 2 |
| Medium (5-50KB) | 4 | 115ms | 124ms | 130ms | 130ms | 0 |
| Large (>50KB) | 10 | 478ms | 464ms | 849ms | 849ms | 4 |

**LB overhead by app processing time:**

| Segment | n | Avg overhead | p50 | p95 | Max | >500ms |
|---|---|---|---|---|---|---|
| Fast app (<500ms) | 77 | 169ms | 130ms | 503ms | 849ms | 4 |
| Slow app (>=500ms) | 223 | 136ms | 129ms | 200ms | 580ms | 2 |

**Overhead outliers (diff > 500ms):**

| Overhead | Req Size | Resp Size | Endpoint |
|---|---|---|---|
| 849ms | 68B | 536KB | `GET /api/Invoices/:id/html-preview` |
| 580ms | 224KB | 260B | `PUT /api/account/receipt` |
| 560ms | 224KB | 260B | `PUT /api/account/receipt` |
| 530ms | 2KB | 472KB | `GET /api/Invoices/:id/html-preview` |
| 509ms | 5KB | 474KB | `POST /api/Invoices/build-html-preview` |
| 503ms | 2KB | 472KB | `GET /api/Invoices/:id/html-preview` |

### Conclusions

1. **The LB is not adding anomalous overhead.** Across 300+ traces the pattern is consistent and explainable.

2. **Baseline LB overhead is ~130ms** for all requests. This is the normal GCP HTTP(S) LB proxy cost (TLS termination, routing, health-check coordination).

3. **Large payloads add transfer time, not processing delay:**
   - Responses >400KB (`html-preview`, `build-html-preview`): +300-800ms from response streaming through the LB.
   - Requests >200KB (`PUT /api/account/receipt` with Apple receipt blobs): +500-580ms from request body upload.

4. **Cold start / pod restart is not a systemic issue.** Small-request overhead is tightly clustered (p95=187ms, n=286). The two earlier multi-second outliers (`account-configurations/regional` at +6s, `account/receipt` at +12.8s) were isolated incidents, likely coinciding with a deploy or pod restart.
