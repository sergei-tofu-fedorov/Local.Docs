# MAIN-1632 — Rollout downtime benchmark

Reproduces and validates the deploy-time downtime the ticket targets, so we
can prove the manifest fix actually closes it.

## Project guardrail

This benchmark **only** runs against the test environment.

| | Test (allowed) | Prod (forbidden) |
|---|---|---|
| GCP project | `invoicesapp-project-test` | `inv-project` |
| GKE cluster | `invoices-cluster` | `tofu-cluster` |
| Zone | `us-east1-d` | `us-east1-d` |
| Public hostname | `staging.tofu.com` | `app.tofu.com` |
| Manifest overlay | `overlays/dev` | `overlays/prod` |

Every gcloud / kubectl invocation in this runbook explicitly passes
`--project=invoicesapp-project-test` and `--zone=us-east1-d` — never paste a
command that omits them.

## Phases

This benchmark runs **twice** — once to prove the bug, once to prove the fix.

| Phase | Manifest state | Expected k6 result | Purpose |
|---|---|---|---|
| **1. Baseline reproduction** | `overlays/dev` as-is on `master`, no MAIN-1632 changes applied | 1-2 min window of 5xx / connection-refused on `GET /api/Estimates` during the rollout | Confirms the bug actually reproduces in the test cluster — without this, we can't prove the fix did anything |
| **2. Apply fix** | `overlays/dev/auth.yaml` and `overlays/dev/tofu-invoices.yaml` patched per the plan in `README.md` | n/a — just `kubectl apply -k overlays/dev` | Roll the fix into the test cluster only |
| **3. Post-fix validation** | Patched | Zero failed requests across the rollout | Confirms the fix closes the downtime window |

Run Phase 1 first. If the baseline doesn't reproduce, stop and re-think before
spending time on the fix — the runbook below is calibrated to the cross-node
scenario the ticket describes, but the cluster's current load /
configuration may already be masking it.

## What "success" looks like at each phase

- **Phase 1 (baseline):** k6 reports `estimates_downtime` rate > 0 for a
  contiguous 1-2 min window aligned with the rollout. The gcloud log pull
  shows `RpcException` / `connection refused` / `5xx` clusters from
  `invoices-api` over the same window. This is the bug.
- **Phase 3 (post-fix):** same rollout, `estimates_downtime` rate = 0,
  `estimates_success` rate ≥ 0.999, no error clump in the log pull.

## Pre-flight

```powershell
# 1. Pin gcloud to the test project. Refuse to continue otherwise.
gcloud config set project invoicesapp-project-test
$proj = gcloud config get-value project
if ($proj -ne 'invoicesapp-project-test') { throw "Wrong project: $proj" }

# 2. Pull cluster credentials for the TEST cluster only.
gcloud container clusters get-credentials invoices-cluster --zone=us-east1-d --project=invoicesapp-project-test

# 3. Confirm kubectl context points where we expect.
$ctx = kubectl config current-context
if ($ctx -notmatch 'invoices-cluster') { throw "kubectl context isn't the test cluster: $ctx" }

# 4. Sanity-check the curl + token.
$env:K6_AUTH = '<paste fresh Firebase JWT here>'
curl -sS -o $null -w "HTTP %{http_code}`n" `
  -H "accept: text/plain" `
  -H "api-version: 3" `
  -H "XA-App-Type: invoices" `
  -H "Authorization: Bearer $env:K6_AUTH" `
  "https://staging.tofu.com/api/Estimates"
# Expect HTTP 200. If 401 -> token expired (Firebase JWTs are 1h), grab a fresh one.
```

## Step 1 — scale `invoices-cluster` to 3 nodes

The bug only manifests when the new pod can land on a different node than the
old one. Scaling the node pool to 3 makes the cross-node case much more
likely.

```powershell
# Find the node pool name (usually default-pool).
gcloud container node-pools list `
  --cluster=invoices-cluster `
  --zone=us-east1-d `
  --project=invoicesapp-project-test

# Precondition: current node count MUST be 2 — refuse to resize otherwise so
# we don't silently wipe out an in-flight scale-test someone else set up.
$current = [int](gcloud container clusters describe invoices-cluster `
  --zone=us-east1-d `
  --project=invoicesapp-project-test `
  --format='value(currentNodeCount)')
if ($current -ne 2) { throw "Expected 2 nodes before resize, found $current. Aborting." }

# Resize. Replace <POOL> with the name from the previous command.
gcloud container clusters resize invoices-cluster `
  --node-pool=<POOL> `
  --num-nodes=3 `
  --zone=us-east1-d `
  --project=invoicesapp-project-test `
  --quiet

# Wait for nodes to come Ready.
kubectl get nodes -w
# (Ctrl-C once 3 nodes are 'Ready'.)
```

## Step 2 — capture pre-rollout pod placement

```powershell
kubectl get pods -n default -o wide `
  -l 'app in (tofu-invoices-api,auth-api,invoices-api)' `
  --sort-by=.spec.nodeName `
  > .\pods-before.txt
Get-Content .\pods-before.txt
```

Record which node each replica is currently scheduled on. We'll diff this
against post-rollout placement to confirm at least one pod actually moved
nodes (otherwise the benchmark didn't exercise the failure mode).

## Step 3 — start k6 in the background

```powershell
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$k6Out = ".\benchmark-$ts.json"
Start-Process -FilePath k6 `
  -ArgumentList @(
    'run',
    '--env', "DURATION=10m",
    '--env', "RPS=20",
    '--out', "json=$k6Out",
    '.\benchmark.js'
  ) `
  -RedirectStandardOutput ".\k6-$ts.log" `
  -RedirectStandardError  ".\k6-$ts.err" `
  -PassThru | Tee-Object -Variable k6Proc
"k6 PID = $($k6Proc.Id), output = $k6Out"
```

Give k6 ~30s to settle into steady state before triggering the rollout.

## Step 4 — trigger the rollout

```powershell
# Restart both deployments. Order doesn't matter for this benchmark — the BFF
# (invoices-api) talks to both, so either one going unready should surface as
# 5xx on /api/Estimates if the manifests aren't drained correctly.
kubectl rollout restart deployment/tofu-invoices-api-deployment -n default
kubectl rollout restart deployment/auth-api-deployment          -n default

# Watch the rollouts in two panes (or sequentially):
kubectl rollout status deployment/tofu-invoices-api-deployment -n default --timeout=5m
kubectl rollout status deployment/auth-api-deployment          -n default --timeout=5m
```

## Step 5 — watch pod placement during the rollout

In a separate shell, while step 4 is running:

```powershell
# Stream pod state. Look for: old pod Terminating, new pod Pending->ContainerCreating->Running on a DIFFERENT node.
kubectl get pods -n default -o wide `
  -l 'app in (tofu-invoices-api,auth-api)' `
  -w
```

Once both rollouts report `successfully rolled out`, snapshot the new placement:

```powershell
kubectl get pods -n default -o wide `
  -l 'app in (tofu-invoices-api,auth-api,invoices-api)' `
  --sort-by=.spec.nodeName `
  > .\pods-after.txt

# Diff to confirm at least one moved.
Compare-Object (Get-Content .\pods-before.txt) (Get-Content .\pods-after.txt)
```

If every pod stayed on the same node, the benchmark didn't exercise the
cross-node case — repeat step 4 (or `kubectl drain` one of the original nodes
to force rescheduling) before drawing conclusions.

## Step 6 — pull invoices-api error logs for the rollout window

The BFF (`invoices-api`) is the consumer that loses upstream connectivity, so
its logs show the symptom most clearly. Run this *after* both rollouts are
done.

```powershell
# Use --freshness to scope to the rollout window (adjust as needed).
gcloud logging read `
  --project=invoicesapp-project-test `
  --limit=500 `
  --order=asc `
  --freshness=15m `
  --format='value(timestamp, severity, jsonPayload.properties.RequestPath, jsonPayload.message, textPayload)' `
  'resource.type="k8s_container"
   resource.labels.cluster_name="invoices-cluster"
   resource.labels.container_name="invoices-api"
   resource.labels.namespace_name="default"
   -jsonPayload.properties.ResponseBodyText="Healthy"
   -jsonPayload.properties.RequestPath="/callback/sendgrid/status_update"
   severity>=WARNING' `
  > .\invoices-api-errors.txt

Get-Content .\invoices-api-errors.txt | Select-Object -First 50
```

Pre-fix expectation: a clump of `RpcException` / `connection refused` / `5xx`
entries lasting 1-2 min, aligned with the rollout timestamp.
Post-fix expectation: nothing matching during the rollout window.

## Step 7 — wait for k6 and analyze

```powershell
Wait-Process -Id $k6Proc.Id
Get-Content ".\k6-$ts.log" -Tail 80

# Headline metrics from the JSON summary (k6 also prints them inline):
$summary = Get-Content .\benchmark-summary.json | ConvertFrom-Json
"success rate     = $($summary.metrics.estimates_success.values.rate)"
"downtime rate    = $($summary.metrics.estimates_downtime.values.rate)"
"http_req_failed  = $($summary.metrics.http_req_failed.values.rate)"
"p95 latency (ms) = $($summary.metrics.estimates_latency_ms.values.'p(95)')"
"errors total     = $($summary.metrics.estimates_errors.values.count)"
```

**Pass criteria (post-fix):**
- `estimates_downtime` rate = 0.
- `estimates_success` rate = 1.0 (or ≥ 0.999 if a single transient blips).
- No `5xx` / `RpcException` clusters in the gcloud log pull during the rollout window.

## Step 8 — post-run guardrail check

Re-confirm we never strayed off the test project:

```powershell
$proj = gcloud config get-value project
if ($proj -ne 'invoicesapp-project-test') { throw "DRIFTED OFF TEST: $proj" }
"OK: still on $proj"

# Optional: scale back down if you bumped node count just for the test.
# gcloud container clusters resize invoices-cluster --node-pool=<POOL> --num-nodes=2 --zone=us-east1-d --project=invoicesapp-project-test --quiet
```

## Files this benchmark produces

- `benchmark-<ts>.json` — k6 raw output stream.
- `benchmark-summary.json` — k6 end-of-run summary metrics (written by `handleSummary`).
- `k6-<ts>.log` / `k6-<ts>.err` — k6 stdout/stderr.
- `pods-before.txt` / `pods-after.txt` — pod-to-node placement snapshots.
- `invoices-api-errors.txt` — gcloud log dump for the rollout window.

Keep these in `Investigation/MAIN-1632/` (per the `inv` skill convention) — do
not commit them to `Tofu.Docs`.
