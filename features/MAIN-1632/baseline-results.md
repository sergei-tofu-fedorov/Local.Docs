# MAIN-1632 — Phase 1 baseline reproduction results

Run: `2026-05-09 11:24:21 +03:00` (k6 5 min, 20 RPS constant arrival rate).
Target: `https://staging.tofu.com/api/Estimates`.
Cluster: `invoices-cluster` in `invoicesapp-project-test`, scaled 2 → 3 nodes.

## Verdict: bug reproduces

k6 thresholds **`estimates_success > 0.995`** and **`http_req_failed < 0.005`** both breached.
20.18% of requests failed during the 5-min window covering two rolling restarts.

## Headline metrics

| Metric | Value |
|---|---|
| Total iterations (requests fired) | 4,211 |
| Iterations dropped (VU saturation) | 1,790 |
| Success rate (2xx) | **79.10%** (3,331 / 4,211) |
| Network errors (status 0) | 841 |
| 5xx | 9 |
| `estimates_downtime` rate | **20.18%** |
| `estimates_errors` count | 880 |
| Median latency (steady-state) | 264 ms |
| p90 / p95 / p99 latency | **15.0 s** (= client timeout cap) |
| Max latency | 15.0 s |
| Effective RPS | 14.0 (vs 20 target — short by hung VUs) |

## Timeline

| Time (local +03:00) | Time (UTC) | Event |
|---|---|---|
| 11:24:21 | 08:24:21 | k6 starts (5 min run, 20 iters/s) |
| 11:24:55 | 08:24:55 | `kubectl rollout restart deployment/tofu-invoices-api-deployment` |
| 11:25:09 | 08:25:09 | Rollout #1 done (14 s) — new pod on **new** node `...b6p3` |
| 11:25:36 | 08:25:36 | `kubectl rollout restart deployment/auth-api-deployment` |
| 11:25:45 | 08:25:45 | Rollout #2 done (9 s) — new pod on **new** node `...b6p3` |
| 11:25:46–48 | 08:25:46–48 | `Connection refused (auth-api-service:80)` clusters in BFF logs (12, 11, 7 per second) |
| 11:29:23 | 08:29:23 | k6 ends — exit 99 (thresholds failed) |

## Pod placement (cross-node case triggered)

| App | Before | After |
|---|---|---|
| `auth-api` | `gke-...rwrv` | `gke-...b6p3` (new node) |
| `tofu-invoices-api` | `gke-...b841` | `gke-...b6p3` (new node) |
| `invoices-api` (BFF, consumer) | `gke-...rwrv` | `gke-...rwrv` (unchanged) |

Both target deployments moved to the brand-new third node, forcing the BFF
to re-establish HTTP / gRPC connections across nodes — exactly the failure
scenario the ticket describes.

## Two failure signatures observed

1. **HTTP path (`auth-api`)** — `HttpRequestException: Connection refused (auth-api-service:80)`. Logged at `ERROR` from `Tofu.Auth.Api.Client.TofuAuthApiClient.GetMyPermissionsAsync`. Brief (3 s window) because the .NET HTTP client returns the connection-refused immediately.
2. **gRPC path (`tofu-invoices-api`)** — *no* `WARNING+` log entries from the BFF during rollout #1's window. Instead, requests **hang** until k6's 15 s client-side timeout fires (visible as VUs ramping 5 → 58 while completed-iter count stays flat). The `Grpc.Net.Client` channel queues calls while it tries to re-resolve the new pod IP; nothing surfaces as an error in the BFF logs at WARNING+ until the call's own timeout (which appears longer than k6's 15 s).

The plan doc's `Open questions` should pick up the asymmetry — the `terminationGracePeriodSeconds: 30` we copy from the BFF fix may be sufficient for HTTP but **may need to be longer for `tofu-invoices-api`** to give the gRPC client time to resolve and reconnect to the new pod before the old one's TCP RST hits a long-running call.

## Files produced

- `pods-before.txt` — pre-rollout pod placement.
- `pods-after.txt` — post-rollout pod placement.
- `invoices-api-errors.txt` — `severity>=WARNING` BFF logs across the rollout window (30 connection-refused errors).
- `benchmark-20260509-112421.json` — k6 raw output stream.
- `benchmark-summary-20260509-112421.json` — k6 end-of-run metrics summary.
- `k6-20260509-112421.log` — k6 stdout (timeline of VU/iteration counts).

> Per the `inv` skill convention these artifacts should live in
> `Investigation/MAIN-1632/`, not `Tofu.Docs`. They've been left here for
> in-flight reference and should be moved before the Tofu.Docs commit.

## Next: Phase 2 (apply fix) and Phase 3 (validate)

Patch `overlays/dev/auth.yaml` and `overlays/dev/tofu-invoices.yaml` per the
diff in `README.md`, `kubectl apply -k overlays/dev`, then re-run this
benchmark. Expected post-fix result: `estimates_downtime` rate = 0,
`estimates_success` ≥ 99.9%, no `Connection refused` clusters in the BFF
log pull.
