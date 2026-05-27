# WEB-1526-prep — `Tofu.AI.Backend` to canonical form

**Status:** planning · for review
**Part of:** [WEB-1526](../WEB-1526/README.md) — the non-segmentation groundwork it builds on.
**Affected repos:** `Tofu.AI.Backend`, `Invoices.Kubernetes` (branch `feature/WEB-1526-prep` in both)

## Context

`Tofu.AI.Backend` started as a **flat, single-project ChatGPT-proxy** (`Tofu.AI.Api/` at the repo root, one deploy path, no health gating). This prep brings it to the **canonical workspace shape** the other backends use — `src/` layout + standard host wiring — and hardens its deploy manifest. Pure structural groundwork: no behaviour change, no analysis logic.

## What's on the prep branches

**`Tofu.AI.Backend`** — `feature/WEB-1526-prep`:
- **Move to `src/`** — the chat-proxy code relocates `Tofu.AI.Api/*` → `src/Tofu.AI.Api/*` (pure file moves). The branch ships **only the `Tofu.AI.Api` project**.
- **Canonical host wiring** (`Program.cs`) — Serilog (+ GCP sink), OpenTelemetry tracing, `/health` checks, Kestrel bound to `:80` outside Development.
- **Dockerfile** re-pointed to `./src/Tofu.AI.Api`, kept **without an `ENTRYPOINT`**.

**`Invoices.Kubernetes`** — `feature/WEB-1526-prep`:
- `overlays/dev/tofu-ai.yaml` operational hardening — startup + readiness probes on `/health`, `preStop: sleep 10` + `terminationGracePeriodSeconds: 30`, base resource requests/limits, and `appsettings.Staging.json` → `appsettings.Production.json` config alignment.

## Notes for reviewers

- The `src/Tofu.AI.Api/*` files are **moves of the existing chat proxy** — diff them as renames, not new code.
- The manifest change lands in the **dev overlay only**; `overlays/prod/tofu-ai.yaml` is untouched.
