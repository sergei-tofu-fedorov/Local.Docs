# FS-1111 — Stage rollout & implementation plan (test features one-by-one via Swagger)

A delivery-sequencing plan to take the existing `Investigations` module from "runs on a dev machine" to "**testable feature-by-feature on stage via Swagger**", culminating in the **real Claude agent running inside the GKE pod via Vertex AI**. Each phase is an independently shippable, Swagger-verifiable slice with its own test checklist.

Design source of truth: [`overview.md`](./overview.md) · [`impl-design.md`](./impl-design.md) · agent context: [`agent-context.md`](./agent-context.md). This doc is the *rollout* plan, not a redesign.

> **Decisions taken (2026-06-10):** build the **real agent on stage** (not a permanent stub); run it **GCP-native via Vertex AI + Workload Identity**; deliver the **plan only** for now (no code yet). An Echo adapter is still used as an early phase — purely to validate the API surface on stage before the heavy runtime work lands.

---

## 0. Current state (verified against `feature/FS-1111`)

| Area | State |
|---|---|
| Module, 5-table schema + `M0001` migration | ✅ built |
| HTTP surface (`start`/`cancel`/`get`/`events`/`report`/`list` + `actions` approve/reject) | ✅ built |
| Pull-context `.tofu-ai/` (`IAgentContextWriter`, prompt-builder pointers) | ✅ built |
| `RestoreAccountActionExecutor` + `AccountReadTools` (Mongo) | ⛔ `TODO(FS-1111)` stubs |
| Two least-privilege Mongo users | ⛔ not provisioned |
| FTS `tsvector` columns + `events.seq` | ⚠️ still created by `M0001` (design treats them as gone) |
| Agent runtime on stage | ⛔ **blocked** — the Dockerfile is a plain `aspnet` image; no `claude` CLI / `gcloud` / workspace |
| Module gate | `Investigations:Enabled = false` by default |
| Auth | none (design assumed localhost-only) |

**Deploy structure** (what the plan must fit into): GKE, single pod `tofu-ai-api-deployment` hosting **both HTTP and the Hangfire server** (image `tofu-ai-api`); migrations run as a separate k8s Job (`dotnet …Tofu.AI.Api.dll migrate`); deploy via the shared `m-unicorn/Tofu.GitHubActions` reusable workflow with **Workload Identity Federation** (OIDC); `staging` and `production` targets. A Postgres already serves Hangfire/Analyses on stage — the `Investigations` connection string can point at the **same** database (the design allows it).

**The core tension:** the agent is a `claude -p …` subprocess. Everything *except* agent execution can be tested on stage today; the agent itself needs the container runtime (Phases 3–4). The Echo adapter (Phase 1) bridges the gap so the whole API + lifecycle + approval flow is Swagger-testable long before the runtime lands.

---

## 1. Agent runtime on GCP — the researched design (Phase 3 detail)

How to run the headless Claude agent inside the GKE pod, GCP-native. Sources at the end.

### 1.1 Model access: Claude via Vertex AI (no API keys)

Run the CLI against **Vertex AI** instead of the Anthropic API — it reuses the cluster's existing Workload Identity and keeps inference inside your GCP boundary.

- Env on the pod: `CLAUDE_CODE_USE_VERTEX=1`, `CLOUD_ML_REGION` (e.g. `global` or `us-east5`), `ANTHROPIC_VERTEX_PROJECT_ID=<project>`. ([Claude Code on Vertex AI](https://code.claude.com/docs/en/google-vertex-ai))
- Auth = **Application Default Credentials → Workload Identity** — "Workload Identity (for GKE)" with "no service account keys required". Claude Code **v2.1.121+** supports X.509 WIF through the same ADC chain. ([Vertex AI docs](https://code.claude.com/docs/en/google-vertex-ai))
- IAM: the pod's GCP service account needs **`roles/aiplatform.user`** ("includes the required permissions … `aiplatform.endpoints.predict`"). ([Vertex AI docs](https://code.claude.com/docs/en/google-vertex-ai))
- One-time: **enable the Vertex AI API** and **request the Claude model(s) in Model Garden** — "Wait for approval (may take 24-48 hours)". ⚠️ **Long lead time — request this first.** ([Vertex AI docs](https://code.claude.com/docs/en/google-vertex-ai))
- **Pin the model** (`ANTHROPIC_DEFAULT_SONNET_MODEL` / `ANTHROPIC_MODEL`) so a deploy can't silently move models; docs explicitly warn to pin for multi-user/CI rollout.
- **Prompt caching** is on automatically on Vertex; MCP **tool search is disabled by default on Vertex** (definitions load upfront) — fine, our MCP surface is tiny (Mongo + Sentry).
- Docs recommend a **dedicated GCP project** for Claude Code to simplify cost tracking and access control — decide test vs a separate project (open question below).

> **PII upside:** because inference runs in **Vertex (in your GCP tenancy)**, this materially improves the PII trade-off `overview.md` flagged for the Anthropic-API path. Worth recording as a reason to prefer Vertex here.

### 1.2 The agent's own tools (read-only) on GKE

- **GCP logs** — `Bash(gcloud logging read …)` authenticated by the **same Workload Identity SA**; grant `roles/logging.viewer` on the target log project (default `invoicesapp-project-test`; prod reads stay explicit + read-only).
- **Sentry** — `sentry-mcp` (or curl) with `SENTRY_AUTH_TOKEN` from **Secret Manager** (read scopes only).
- **Mongo** — the curated `Investigations.Mcp.Mongo` server with the **read-only** connection string (Secret Manager). Spawned by the CLI via the MCP config.
- **Source code** — a **bare-clone cache** of the workspace repos (`git clone --bare` once, `git fetch` at run start, reads via `git show origin/<default>:<path>`); plus the **knowledge repo** `github.com/sergei-tofu-fedorov/investigation-ai` cloned/pulled into `.tofu-ai/` at startup (deploy key in Secret Manager). GitHub MCP is the fallback. Never clone-per-run.

### 1.3 Image & process

- Add to the image (or a dedicated agent image): **Node** + `npm i -g @anthropic-ai/claude-code`, **`gcloud`**, **`git`**. Best-practice notes: prefer `node:*-slim` over Alpine (musl issues), set a `WORKDIR` before install, allocate **≥4 GB** memory to the agent. ([Claude Code with Docker](https://claudecodeguides.com/claude-code-with-docker-containers-guide/), [Headless self-hosting guide](https://amux.io/guides/claude-code-headless/))
- **Invocation** (already the adapter's shape): `claude -p "<prompt>" --output-format stream-json --max-turns <N> --mcp-config <path> --allowedTools "<allowlist>"`. Add **`--bare`** for scripted runs — "the recommended mode for scripted and SDK calls" (skips local hooks/MCP/CLAUDE.md auto-discovery for reproducibility). ([Run Claude Code programmatically](https://code.claude.com/docs/en/headless))
- **Permissions = the security boundary.** Use a locked-down `--permission-mode` (`dontAsk` "denies anything not in your `permissions.allow` rules or the read-only command set") plus the explicit `--allowedTools` allowlist (the read-only `gcloud/git`, `Read/Grep/Glob`, `mcp__sentry__*`, `mcp__mongo__*`). No `Edit/Write`/general `Bash`. ([Headless docs](https://code.claude.com/docs/en/headless))
- **Sandboxing (recommended hardening):** the agent runs Bash; Claude Code ships OS-level sandboxing (Linux `bubblewrap`, open-source `npx @anthropic-ai/sandbox-runtime`) that restricts filesystem + network "at the kernel level, not through trust or prompt engineering," and keeps credentials out of the sandbox. Combine with a restricted node pool + tight egress. ([Configure the sandboxed Bash tool](https://code.claude.com/docs/en/sandboxing), [Anthropic — Claude Code sandboxing](https://www.anthropic.com/engineering/claude-code-sandboxing))
- **Runtime placement:** start with the agent as a **subprocess inside the existing API/Hangfire pod** (matches the single-pod design; `MaxConcurrentRuns=1` keeps it to one agent at a time). A **K8s Job-per-investigation** is the cleaner-isolation alternative for later — more moving parts; defer until concurrency or blast-radius demands it. Set pod CPU/memory requests for the agent headroom and align `RunTimeout` with the pod's limits.

### 1.4 Config / secrets checklist (stage)

| Key | Source | Notes |
|---|---|---|
| `ConnectionStrings:Investigations` | Secret/env | point at the existing stage Postgres |
| `ConnectionStrings:InvestigationsMongoRead` / `…MongoActions` | Secret Manager | two least-privilege users (Phase 2) |
| `Investigations:Enabled` | env | `true` on stage |
| `Investigations:WorkspaceRoot` | env | the bare-clone cache root in the pod |
| `Investigations:KnowledgeRepoPath` | env | local checkout of `investigation-ai` |
| `CLAUDE_CODE_USE_VERTEX` / `CLOUD_ML_REGION` / `ANTHROPIC_VERTEX_PROJECT_ID` | env | Vertex |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` (pin) | env | model pin |
| `SENTRY_AUTH_TOKEN`, knowledge-repo deploy key | Secret Manager | read-only |
| GCP SA (Workload Identity) | platform | `roles/aiplatform.user` + `roles/logging.viewer` |

---

## 2. Phased rollout — Swagger-testable, one feature at a time

Each phase ships independently. The **Swagger test** column is what you run on stage to sign the phase off. Phases 0–2 need **no LLM**; Phase 3 lights up the real agent.

### Phase 0 — Module live & reachable on stage (no working agent)
**Build:** point `ConnectionStrings:Investigations` at the stage Postgres; run the migration Job; set `Investigations:Enabled=true` + a `WorkspaceRoot`; confirm Swagger serves the `Investigations` endpoints; add a **stage access gate** (see §3 — the design assumed localhost).
**Swagger test:**
- `GET /api/investigations` → `200 []`.
- `POST /api/investigations {description}` → `202 {id}`; `GET /{id}` shows `pending`→`running`→**`failed`** (agent missing) with `error` populated — this *proves persistence + Hangfire + lifecycle* end-to-end.
- `GET /{id}/events?afterId=0` → `status_change` rows; `GET /{id}/report` of the failed run; `GET /actions` → `200 []`.
**Done when:** the module is deployed, reachable, persisting, and failing *gracefully* (never a 5xx).

### Phase 1 — Echo agent adapter → full lifecycle + approval testable (no LLM)
**Build:** add an `EchoAgentAdapter` selected by `Investigations:Agent:Type=Echo` (the switch already exists). It returns a canned `AgentRunResult`: 1–2 findings (with citations + an `error` signature so fingerprinting runs), tags, limitations, and a `restore_account` **proposed action**; emits a few `AgentEvent`s. No CLI, no keys.
**Swagger test (the big contract sweep):**
- `POST` → poll `GET /{id}` to **`succeeded`**; findings/tags/limitations present.
- `GET /{id}/events` streams `tool_call`/`agent_message`/`status_change`; verify `?afterId=` paging.
- `GET /{id}/report` (markdown) and `?format=slack` (compact mrkdwn).
- `GET /?citationRef=…` and `?tag=area:payments` filters; run the same ask twice → **same fingerprint** → related-runs derivation.
- Approval: `GET /actions?status=proposed` → `POST /actions/{id}/approve` → `200 executed` (executor is a no-op/dry-run here); **double-approve → `409`**; `reject` records `decision_note`.
**Done when:** every endpoint and the whole propose→approve→execute contract is green on stage, with zero LLM dependency.

### Phase 2 — Real Mongo write path (`restore_account`) + read tools (still no LLM)
**Build:** provision the **two least-privilege Mongo users** (read-only for the MCP server; update-on-accounts-only for the executor). Implement `RestoreAccountActionExecutor.ExecuteAsync` (validate soft-deleted → flip → audit event) and the `AccountReadTools` query bodies — both gated on the account soft-delete semantics (open question). Point at the **test** Mongo cluster.
**Swagger test:** with Echo proposing a restore for a known soft-deleted **test** account → `POST /actions/{id}/approve` → executor flips it in Mongo → confirm via `get_account_deletion_state` / a direct Mongo read. Failure paths: not-found / not-soft-deleted → action `failed` with `error` (run untouched).
> Note: the **Mongo read tools are agent-facing (MCP), not HTTP** — they're not directly Swagger-testable; they get exercised for real in Phase 3 (or via a temporary diagnostic endpoint if you want them verified earlier). The **executor** is fully testable now via `approve`.
**Done when:** the write path is real and verified against stage/test Mongo.

### Phase 3 — Real Claude agent in the GKE pod (Vertex-native) — the big one
**Build:** everything in §1 — image additions (Node + claude CLI + gcloud + git), Vertex auth via Workload Identity (`roles/aiplatform.user`, Model Garden access **requested in advance**), `gcloud` logging via WI, Secret Manager wiring, the bare-clone + knowledge-repo checkout, the MCP config, the `--bare` + locked-down permission/allowlist invocation, sandboxing + resource limits. Flip `Investigations:Agent:Type=ClaudeCli`.
**Swagger test:** `POST {description:"investigate the latest Sentry alerts"}` → `GET /{id}/events` shows **real** `tool_call`s (gcloud / sentry / grep) streaming → `succeeded` with real findings + citations + tokens; `GET /{id}/report` matches the shape of [`sample-report-b88ad28f.md`](./sample-report-b88ad28f.md). Then a narrow ask with a `sentryIssueId` hint; then an ask needing an unconnected source → check it lands in `limitations`.
**Done when:** real investigations complete on stage through Swagger.

### Phase 4 — Hardening & cleanup
**Build:** drop the leftover FTS `tsvector` columns + `events.seq` from `M0001`; **integration tests** (`/tests`, agent port faked) covering Phases 0–2 contracts; `Tofu.AI.Backend/README.md` local-run + a **stage runbook**; finalize the auth story (§3); optional container-phase knowledge-repo push/reconcile ([`agent-context.md`](./agent-context.md)); observability dashboards over events + token counts.
**Swagger test:** regression sweep of Phases 0–3; confirm migration cleanup is non-destructive.

---

## 3. Cross-cutting: stage exposure & auth

The design is "no auth, localhost-only" — **invalid on stage**, where Swagger is network-reachable and the service can read prod logs + mutate Mongo. Before Phase 0 is externally reachable, gate it with **one** of: the platform ingress/IAP auth already used by other stage services; a simple static API key checked in middleware; or network-policy restriction to internal callers. The `Enabled` flag is a kill-switch, not auth. Decide this with whoever owns the stage ingress. (Approve endpoints especially must not be open.)

---

## 4. Open questions / decisions needed

- [ ] **Which GCP project for the agent's Vertex + log reads on stage?** Docs recommend a dedicated project; you have `invoicesapp-project-test` (test) and `inv-project` (prod). Likely test for stage — but **Vertex Model Garden access must be requested there now** (24–48h lead).
- [ ] **Stage access control** (§3) — which gate, and who owns it.
- [ ] **Account soft-delete semantics** — which DB/collection, which fields flip, cascades — blocks Phase 2 (`RestoreAccountActionExecutor` + `AccountReadTools`). Confirm against `Invoices.Backend/Docs/persistence.md` + the accounts repository.
- [ ] **Which Mongo cluster** does stage point at (local/test vs a prod read-replica), and provision the two least-privilege users.
- [ ] **Model choice on Vertex** — Sonnet 4.6 (cheaper/faster, fits lookup-shaped asks) vs Opus; and the region/`global` endpoint that has it enabled.
- [ ] **Runtime placement** — subprocess-in-API-pod (recommended first) vs K8s Job-per-run; sizing for the API pod once it also hosts the agent.
- [ ] **Stage Postgres** — confirm the Investigations schema can share the Hangfire/Analyses database (expected) vs a separate DB.

---

## 5. Sources (runtime research, 2026-06-10)

- [Claude Code on Google Vertex AI](https://code.claude.com/docs/en/google-vertex-ai) — `CLAUDE_CODE_USE_VERTEX`, ADC/Workload Identity (v2.1.121+ X.509 WIF), `roles/aiplatform.user`, Model Garden access (24–48h), region/global endpoints, model pinning, prompt caching, MCP tool-search default.
- [Run Claude Code programmatically (headless)](https://code.claude.com/docs/en/headless) — `-p`, `--output-format stream-json`, `--max-turns`, `--permission-mode` (`dontAsk`/`bypassPermissions`/`acceptEdits`), `--allowedTools`, `--append-system-prompt`, `--mcp-config`, `--bare`.
- [Configure the sandboxed Bash tool](https://code.claude.com/docs/en/sandboxing) + [Anthropic — Claude Code sandboxing](https://www.anthropic.com/engineering/claude-code-sandboxing) — bubblewrap, `@anthropic-ai/sandbox-runtime`, kernel-level FS/network isolation, credentials kept out of the sandbox.
- [Using Claude Code with Docker (2026)](https://claudecodeguides.com/claude-code-with-docker-containers-guide/) + [Claude Code Headless self-hosting guide](https://amux.io/guides/claude-code-headless/) — node-slim base, ≥4 GB memory, WORKDIR before install, key via env not build-arg, `--max-turns`/permission-mode for CI.
- [Securely deploying AI agents (Agent SDK)](https://platform.claude.com/docs/en/agent-sdk/secure-deployment) — production isolation guidance.
