# MAIN-1632 — Zero-downtime deploy for `tofu-invoices-api` and `auth-api`

**Status:** planning
**Started:** 2026-05-09
**ClickUp:** https://app.clickup.com/t/MAIN-1632
**Affected repos:** `Deploy/Invoices.Kubernetes` (manifests only — no app-code changes expected)

## Goal

Replicate the rolling-update / graceful-shutdown changes already applied to
`invoices-api` (BFF) onto the `tofu-invoices-api` and `auth-api` deployments,
so that pod rotations during deploys no longer cause 1–2 minutes of downtime
for upstream services.

## Background

After the GKE node pool was scaled up, deploys sometimes schedule the new pod
of a service onto a different node than the old one. With the current
manifests for `tofu-invoices-api` and `auth-api`:

- `strategy.rollingUpdate.maxUnavailable: 1` — the only ready replica can be
  taken down before a new one is ready.
- No `readinessProbe` — the new pod is added to Service endpoints as soon as
  the container starts, before the app has finished initialising and is
  actually able to serve traffic.
- No `lifecycle.preStop` and default `terminationGracePeriodSeconds` — the
  old pod receives `SIGTERM` and stops accepting connections immediately,
  before kube-proxy / clients have had time to update endpoints.

Net effect: callers (BFF, gRPC clients in sibling services) hit a window
where neither the old nor the new pod is reachable, observed as 1–2 min of
errors per deploy.

The fix landed for `invoices-api` on commit
[`8e81ce8`](#) of `Deploy/Invoices.Kubernetes` introduced the canonical
zero-downtime recipe:

```yaml
spec:
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0          # was 1
  template:
    spec:
      terminationGracePeriodSeconds: 30
      containers:
        - lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]
          readinessProbe:
            httpGet:
              path: /health
              port: 80
            periodSeconds: 5
            failureThreshold: 2
```

## Scope

- In scope:
  - `overlays/prod/auth.yaml` — `auth-api-deployment`.
  - `overlays/prod/tofu-invoices.yaml` — `tofu-invoices-api-deployment` and (decision below) `tofu-invoices-worker-deployment`.
  - Mirroring the same edits in the matching `overlays/dev/...` files (the prod-only fix on `invoices-api` left the dev overlay inconsistent — fix that here too).
- Out of scope:
  - App-code changes in `Tofu.Invoices.Backend` / `Tofu.Auth.Backend` — both already expose `/health` and ASP.NET Core handles `SIGTERM` via the host shutdown pipeline, so no source changes are anticipated. Re-evaluate if a probe target needs to change (e.g. split `/health` into liveness vs readiness).
  - Other deployments in the cluster (`expenses`, `payments`, `taxes`, `mileage`, `analytics`, `tofu-ai`, `webapp*`) — track separately if the same problem is observed; this ticket is scoped to the two services explicitly named in the request.
  - HPA / replica-count tuning.
  - Node pool / autoscaler configuration.

## Affected repos

- `Deploy/Invoices.Kubernetes` (manifests) — apply the same delta to the listed overlays.

**Cross-repo notes:**
- Producer / consumer order: not applicable (manifest-only change). The two services are independently deployable.
- Contract changes: none.
- App-code changes: none expected. Verify the `/health` endpoint already returns quickly and is safe as a readiness target — for `auth-api` the deployment currently has *no* probe at all; for `tofu-invoices-api` only a `startupProbe` is wired, also against `/health`.

## Plan

1. [ ] Confirm reference diff: re-read commit `8e81ce8` on `Deploy/Invoices.Kubernetes` and copy its delta as the canonical patch.
2. [ ] `overlays/prod/auth.yaml` — `auth-api-deployment`:
   - [ ] `strategy.rollingUpdate.maxUnavailable: 1 → 0`.
   - [ ] Add `terminationGracePeriodSeconds: 30`.
   - [ ] Add `lifecycle.preStop` exec `sleep 10`.
   - [ ] Add `readinessProbe` against `/health` (port 80).
   - [ ] Add a `startupProbe` against `/health` while we're here (currently absent — without one, k8s will start sending traffic to the pod before the app finishes booting).
3. [ ] `overlays/prod/tofu-invoices.yaml` — `tofu-invoices-api-deployment`:
   - [ ] `strategy.rollingUpdate.maxUnavailable: 1 → 0`.
   - [ ] Add `terminationGracePeriodSeconds: 30`.
   - [ ] Add `lifecycle.preStop` exec `sleep 10`.
   - [ ] Add `readinessProbe` against `/health` (port `http`, container port 5005).
   - [ ] Existing `startupProbe` stays as-is.
4. [ ] `overlays/prod/tofu-invoices.yaml` — `tofu-invoices-worker-deployment`:
   - [ ] Decide: does the worker take inbound traffic that needs draining, or does it only consume jobs / queues? See *Open questions*.
   - [ ] If yes → apply the same delta. If no → leave the `replicas: 1, maxUnavailable: 1` rolling strategy (downtime on a queue consumer is acceptable as long as the host shuts down cleanly within the grace period).
5. [ ] Mirror the relevant edits into `overlays/dev/auth.yaml` and `overlays/dev/tofu-invoices.yaml` — and, while we're here, into `overlays/dev/invoices.yaml` so dev matches prod (commit `8e81ce8` only touched prod).
6. [ ] If the project has a `dev2` or `staging` overlay set, check those too (verify which overlays exist via `Get-ChildItem overlays`).
7. [ ] Local validation: `kubectl kustomize overlays/prod | kubectl diff -f -` (or `--dry-run=server`) to confirm the rendered YAML is what we expect.
8. [ ] Roll out to dev first; observe at least one rolling update under load to confirm zero error spike on the consumer side.
9. [ ] Roll out to prod.

## API / DTO changes

None — manifest-only.

## Breaking changes

None — additive only. Adding a readiness probe and `preStop` hook does not change the wire-level contract; the only observable effect is a cleaner rollout. Confirmed during `/feature review`.

## Data / migration

None.

## Open questions

- [ ] Does `tofu-invoices-worker` accept any inbound HTTP / gRPC that callers depend on, or is it purely an outbound queue/job consumer? The answer decides whether step 4 applies.
- [ ] `auth-api` currently has **no** probes at all. Should we land a `startupProbe` together with the `readinessProbe` here, or split it off into a separate ticket?
- [ ] Is `/health` cheap enough at high probe rates (`periodSeconds: 5`)? Should we expose a separate `/ready` that excludes external dependencies (DB, Firebase, SendGrid) so the readiness probe doesn't flap when those have transient hiccups?
- [ ] Any other deployments observed to suffer the same downtime (`expenses`, `payments`, `taxes`, `mileage`, `analytics`, `tofu-ai`, `webapp*`)? — out of scope here, but worth a follow-up ticket.
- [ ] `terminationGracePeriodSeconds: 30` matches the BFF; do `tofu-invoices-api` long-running gRPC calls (PDF generation, sync) need a longer grace period?

## Test plan

- Unit tests: n/a (manifest-only).
- Integration tests: n/a.
- Manual verification:
  - Apply to dev. Trigger a rolling update of `auth-api` and `tofu-invoices-api` while a smoke load (curl loop / a synthetic gRPC client) is in flight. Confirm zero 5xx / connection-refused for the duration of the rollout.
  - Confirm `kubectl get endpoints` shows the old pod removed before its container exits (preStop window).
  - After dev is clean for a deploy cycle, repeat in prod during a low-traffic window.
