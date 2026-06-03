# Slack ⇄ Claude Code agent on GKE — architecture & implementation plan

**Status:** planning
**Created:** 2026-05-30
**Owner:** eddy
**Scope:** New service. A Slack bot that drives a full Claude Code agent (repo/file access, tools) running in a container on GKE (`tofu-cluster`). Each Slack thread maps to a resumable agent session.

> Specifics below were verified against current Anthropic docs (May 2026). Key finding: the **Claude Managed Agents API** (beta header `managed-agents-2026-04-01`) is the official "Claude Code as a service" path — models **Agent → Environment → Session**, sessions are server-side and resumable by ID, and an Environment can be **`self_hosted`** so the agent's tools execute inside *your* container/VPC. Sources at the bottom.

## Decisions (locked)

- **Capability:** full Claude Code agent (read/edit repos, run tools).
- **Host:** GKE (`tofu-cluster`).
- **Slack transport:** Socket Mode (outbound WebSocket — no public ingress).
- **Environment:** `self_hosted` for v1 (tools run in our pod / VPC); `cloud` for the v0 proof.

## Architecture

```
Slack workspace
   │  (Socket Mode WebSocket — no public ingress needed)
   ▼
┌─────────────────────────────┐     Managed Agents control plane
│  Slack Gateway (GKE Deploy) │ ──► api.anthropic.com  (create/resume
│  • Bolt, Socket Mode        │ ◄── session, send user.message,
│  • thread_ts ⇄ session.id   │     stream agent.* events)
│  • streams events → Slack   │            │
└─────────────────────────────┘            │ dispatches tool work to:
   │ stores thread→session                 ▼
   ▼                              ┌──────────────────────────────┐
 MongoDB Atlas (existing)         │ EnvironmentWorker (GKE pod)   │
                                  │ • self_hosted environment     │
                                  │ • workdir = repo checkout     │
                                  │ • runs bash/read/edit IN our  │
                                  │   VPC (gcloud, mongosh, etc.) │
                                  └──────────────────────────────┘
```

Two roles — two Deployments, or two containers in one pod:

| Component | Responsibility | Key APIs / config |
|---|---|---|
| **Slack Gateway** | Receive mentions/DMs; map each thread to a session; drive the conversation; relay streamed progress | Bolt (Socket Mode) + `client.beta.sessions.{create,events.send,events.stream}`; `agent.message` / `agent.tool_use` / `session.status_idle` events |
| **EnvironmentWorker** | Execute the agent's tools inside our container (repo edits, shell, queries) | `EnvironmentWorker(...).run()` or `ant beta:worker poll --workdir /workspace`; env `ANTHROPIC_ENVIRONMENT_KEY` + `ANTHROPIC_ENVIRONMENT_ID` |
| **Agent definition** | Reusable config: model, system prompt, toolset, permission policy | `client.beta.agents.create({ model:"claude-opus-4-8", tools:[{type:"agent_toolset_20260401", default_config:{permission_policy:...}}] })` |
| **Thread↔session store** | Persist `slack_thread_ts → session.id` so a fresh pod resumes context | MongoDB Atlas, collection `{thread_ts, channel, session_id, updated}` |

## Message flow (per Slack thread)

1. `app_mention` / DM arrives → **ack within 3s**: post a thread reply ("on it"), keep its `ts` to edit live.
2. Look up `thread_ts` → **resume** that `session.id`, or `sessions.create({agent, environment_id})` for a new thread and save the id.
3. `sessions.events.send(sessionId, { events:[{type:"user.message", content:[{type:"text", text}]}] })`.
4. Stream events and relay to Slack:
   - `agent.tool_use` → append a breadcrumb (`bash: git diff`).
   - `agent.message` text blocks → `chat.update` the placeholder so it streams.
   - `session.status_idle` + `stop_reason:"requires_action"` → render **Approve / Deny** buttons; on click send `user.tool_confirmation`.
   - plain `status_idle` → finalize the message.
5. `session.error` (e.g. `mcp_authentication_failed_error`) → surface in-thread, retry on next idle→running.

## Permissions & safety (full agent — treat as production)

- **Who can invoke:** allowlist Slack user IDs / restrict to specific channels in the gateway; reject others before touching the agent.
- **Tool gating** via permission policy: `always_allow` only safe/read tools; keep `bash` / network / destructive on `always_ask` (handled by the Slack-button confirmation) or disable with per-tool `configs: [{ name:"web_search", enabled:false }]`.
- **Scope the workspace:** `EnvironmentWorker` `workdir` = a dedicated checkout; don't mount prod credentials by default.
- **Test vs prod:** run the worker against test (`invoicesapp-project-test`) first; gate prod behind explicit confirmation — same rule as the `/gcp` and `/mongo` skills (read-only by default).
- **Audit:** log every `user.message`, tool_use, and confirmation to the thread + a persistent log.

## GKE specifics

- **No Ingress/Service for inbound** — Socket Mode is an outbound WebSocket; the gateway only needs egress.
- **Deployment:** `replicas: 1` to start (single Socket Mode connection), `min` always-on, modest CPU/mem.
- **Secrets** via Secret Manager + Workload Identity (already used on `tofu-cluster`): `ANTHROPIC_API_KEY`, `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `ANTHROPIC_ENVIRONMENT_KEY`, `ANTHROPIC_ENVIRONMENT_ID`.
- **Workspace:** ephemeral `emptyDir` + `git clone` on startup, or a PVC for warm checkouts.
- **Image/CI:** reuse the existing Cloud Build / `Tofu.GitHubActions` pipeline; deploy into a dedicated namespace.

## Build order

- **v0 — prove the loop (cloud environment, local):** Bolt Socket-Mode gateway + a `cloud` environment (Anthropic-managed sandbox, zero infra), single allowlisted user, in-memory thread map, stream Q&A + simple tool use. Run locally.
- **v1 — self-hosted on GKE:** switch to a `self_hosted` environment + `EnvironmentWorker` in a pod with a repo checkout; Mongo-backed thread↔session store; Slack-button permission gating; Secret Manager; deploy to `tofu-cluster`.
- **v2 — power features:** expose existing tooling as **MCP servers** (a `/gcp` and `/mongo` MCP would let the agent run the read-only presets natively), multi-repo, per-channel scoping, cost tracking, audit log.

## Open decisions

| Decision | Lean | Why |
|---|---|---|
| Cloud vs self-hosted environment | **Self-hosted** (v1) | Agent must act inside our GKE container/VPC on our repos. Cloud is fine for the v0 proof. |
| Gateway language | **TypeScript** | Tightest fit for `@anthropic-ai/sdk` streaming + Bolt. Python equally viable. Not .NET (no first-class SDK). |
| Thread↔session store | **MongoDB Atlas** | Already in the stack. |
| Code home | new repo | New service, not a change to an existing backend repo. |

## Gotchas

- Beta API — header `anthropic-beta: managed-agents-2026-04-01`; toolset id `agent_toolset_20260401`.
- **Cost:** as of 2026-06-15, Agent SDK usage draws from a *separate* monthly credit pool on subscription plans — budget for it.
- MCP toolsets default to `always_ask`; supply credentials via **vaults** at session create (`vault_ids`).
- CLI-headless fallback (instead of the SDK): `claude -p --bare --output-format stream-json --resume <id>` — `--bare` skips auto-discovery for reproducible runs.

## Next steps

- [ ] Scaffold v0: TypeScript Bolt Socket-Mode gateway + Managed Agents session loop (Q&A + simple tool use).
- [ ] Stand up a `self_hosted` environment + `EnvironmentWorker` with a repo checkout.
- [ ] Mongo-backed thread↔session store + Slack-button permission gating.
- [ ] GKE manifests (Deployment, Secret Manager/Workload Identity) in a dedicated namespace.

## Sources

- Managed Agents quickstart — https://platform.claude.com/docs/en/managed-agents/quickstart.md
- Sessions / multi-turn — https://platform.claude.com/docs/en/managed-agents/sessions.md
- Events & streaming — https://platform.claude.com/docs/en/managed-agents/events-and-streaming.md
- Permission policies — https://platform.claude.com/docs/en/managed-agents/permission-policies.md
- Agent setup — https://platform.claude.com/docs/en/managed-agents/agent-setup.md
- MCP connector — https://platform.claude.com/docs/en/managed-agents/mcp-connector.md
- Self-hosted sandboxes — https://platform.claude.com/docs/en/managed-agents/self-hosted-sandboxes.md
- Headless CLI mode — https://code.claude.com/docs/en/headless
