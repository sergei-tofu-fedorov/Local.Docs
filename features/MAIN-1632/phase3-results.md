# MAIN-1632 — Phase 3 post-fix validation results

Run: `2026-05-09 11:38:42 +03:00` (k6 5 min, 20 RPS).
Same target, same cluster (`invoices-cluster` @ 3 nodes, `invoicesapp-project-test`).
Same scenario as Phase 1 — k6 + restart `tofu-invoices-api-deployment` then `auth-api-deployment`.
Difference: `overlays/dev/auth.yaml` and `overlays/dev/tofu-invoices.yaml` patched with the
`maxUnavailable: 0` + `terminationGracePeriodSeconds: 30` + `lifecycle.preStop sleep 10` +
`readinessProbe /health 5s/2` block from commit `8e81ce8`.

## Verdict: fix works

All k6 thresholds passed, zero failures over 5,948 requests, no `WARNING+` log entries
from the BFF (`invoices-api`) during the rollout window. Both rollouts triggered the
cross-node case (new pods scheduled on a different node than the old ones), which was the
exact failure mode that produced 20% downtime in Phase 1.

## Phase 1 vs Phase 3

| Metric | Phase 1 (no fix) | Phase 3 (fix applied) |
|---|---|---|
| Total iterations | 4,211 | **5,948** |
| Success rate (2xx) | 79.10% | **100.00%** |
| Network errors | 841 | **0** |
| 5xx | 9 | **0** |
| `estimates_downtime` | 20.18% | **0.00%** |
| Dropped iterations | 1,790 | 52 |
| Median latency | 264 ms | 258 ms |
| p95 latency | 15.00 s (timeout) | **293 ms** |
| p99 latency | 15.00 s | 1.41 s |
| Max latency | 15.00 s | 6.3 s |
| Effective RPS | 14.0 | 19.8 |
| BFF `WARNING+` log entries in window | 30 (`Connection refused`) | **0** |
| k6 thresholds | 2 BREACHED | ALL PASSED |
| Rollout #1 duration | 14 s | 12 s |
| Rollout #2 duration | 9 s | **19 s** |

The `Rollout #2` duration jumping from 9 s → 19 s is the expected cost of the new
behaviour: the new pod must pass `readinessProbe` (1 successful `/health` poll, ≤ 5 s)
before it joins the Service, and the old pod sleeps 10 s in `preStop` before SIGTERM.
Net result: the Service endpoint set is never empty, but each rolling step is ~10 s
slower in wall-clock terms.

## Pod placement during Phase 3

| App | Before | After (rollout #1) | After (rollout #2) |
|---|---|---|---|
| `tofu-invoices-api` | `gke-...rwrv` | `gke-...b841` (cross-node) | — |
| `auth-api` | `gke-...b6p3` | — | `gke-...b841` (cross-node) |
| `invoices-api` (BFF, consumer) | `gke-...rwrv` | `gke-...rwrv` (unchanged) | `gke-...rwrv` (unchanged) |

Both target pods moved nodes during their rollout — the same cross-node scenario that
broke Phase 1. The fix held under exactly that pressure.

## What this means for prod

The same patch (`maxUnavailable: 0` + `terminationGracePeriodSeconds: 30` + preStop
sleep 10 + readinessProbe `/health` 5s/2) has been applied to:

- `overlays/prod/auth.yaml` — `auth-api-deployment`
- `overlays/prod/tofu-invoices.yaml` — `tofu-invoices-api-deployment`

These edits are on disk only — **not applied, not committed**. Open the PR against
`Deploy/Invoices.Kubernetes` to ship.

The `tofu-invoices-worker-deployment` was left alone (open question in the plan README:
does the worker need draining? It's a queue consumer, not a request server). Decide
before merging the prod PR.

## Open follow-ups (no longer blocking the prod rollout)

- The Phase 1 gRPC asymmetry (silent hangs on tofu-invoices-api restart with no
  `WARNING+` logs from the BFF) is closed by this fix — but if real prod traffic later
  shows long-running gRPC calls being severed mid-flight, consider bumping
  `terminationGracePeriodSeconds` above 30 s to match call timeouts.
- `auth-api` had no probes at all (no startup, no readiness, no liveness) before this
  ticket. We added a `readinessProbe`. A `startupProbe` is still missing — same gap
  `INVC-3446` closed for the gateway deployments. Open follow-up ticket.
