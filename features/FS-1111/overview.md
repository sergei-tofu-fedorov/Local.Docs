# FS-1111 — AI Investigation Service, Phase 1 (GCP logs + Sentry + source code + curated Mongo)

A new **`Investigations` module inside `Tofu.AI.Backend`** that runs AI-driven issue investigations: a REST API accepts an investigation request ("checkout 500s spiked at 14:00 — why?"), a background job hands it to a **local Claude agent** (claude CLI headless; containerized in a later phase) with read-only access to **GCP Cloud Logging** (via `gcloud`), **Sentry** (via the official `sentry-mcp` with an auth token), **source code** (local workspace checkouts), and **MongoDB** (curated read tools via an in-house MCP server — never raw queries), and the run + findings + tool-call timeline are persisted to **PostgreSQL in a Docker container with a named volume** so the database survives container restarts and recreations. Contracts are shaped for the real consumer — a future **Slack bot** — even though Phase 1 is REST-only: async run lifecycle, compact Slack-sized summary + expandable details, Slack correlation fields carried on the run.

Related ClickUp tasks: [FS-1111](https://app.clickup.com/t/FS-1111)

Companion docs: [`README.md`](./README.md) (feature seed), [`web-spike.md`](./web-spike.md) (research backing every architecture choice below), [`agent-context-pull.md`](./agent-context-pull.md) (2026-06-07 addendum — supersedes the prompt-time recall below with pull-only file-cached context; not yet implemented).

## Scope

**In scope (Phase 1):**

- New `Investigations` module in `Tofu.AI.Backend` (`src/Investigations/…`), mirroring the `Analyses` module layout.
- REST API: start an investigation, poll status/result, read the progress timeline.
- **Free-form natural-language tasks, not only error RCA** — `description` is the instruction verbatim ("search logs for user X and tell me what failed", "what's account Y's subscription plan?"); the agent answers from whatever connected sources can support, and must report which parts of the ask needed sources that aren't connected yet (→ `limitations`).
- Agent execution via local `claude` CLI in headless mode (`-p` + `--output-format stream-json`), spawned per run by a Hangfire job.
- Four read-only sources: GCP Cloud Logging (`gcloud logging read`), Sentry (`sentry-mcp`, token auth), source code (local checkouts of the workspace repos), MongoDB (curated named tools via the in-house `Investigations.Mcp.Mongo` stdio server — the agent cannot compose raw Mongo queries).
- **Proposed actions (propose → approve → execute):** the agent can *propose* a closed set of write actions in its report (Phase 1: `restore_account`); a human approves via API and the **service** executes — the agent never holds write capability.
- Postgres persistence (runs, findings, events) via the repo's module-migrations pattern; local DB in Docker with a **persistent named volume**.
- Slack-bot-ready contract shape (summary length budget, markdown details, channel/thread correlation fields).

**Out of scope (later phases):**

- The Slack bot itself (Phase 1 only keeps the contracts compatible).
- ClickUp / support tickets (P2), Stripe (P3), Amplitude (P4 — access not yet available; see web-spike).
- Containerized agent + production deploy (Phase 1 runs on the developer machine; the design keeps the seam).
- Write actions *executed by the agent* — it can only propose; execution happens in the service after human approval (see Proposed actions). Auth/permissions on the API (local-only — including the approve endpoint, accepted while the API binds to localhost).
- Embeddings / similarity search over past investigations (web-spike: vector search is an enhancement, not a foundation).

## High-level approach

- **Module in `Tofu.AI.Backend`, not a new repo** — reuses the existing Hangfire-on-Postgres host (`src/Tofu.AI.Api/Hangfire/HangfireConfiguration.cs`), CI, telemetry, and the module conventions of `src/Analyses` (per-layer `DependencyInjection.cs`, options classes with `SectionName` consts, `ValidateOnStart`). Trade-off: couples deploy to FSM-fit — acceptable while the feature is experimental; the module boundary keeps a later repo-extraction cheap.
- **Agent runtime = a physically replaceable module.** `IInvestigationAgentPort` lives in Domain; the claude CLI adapter lives in its **own project** `Investigations.Agent.ClaudeCli` (not folded into the shared Infrastructure project), and the active adapter is selected by config (`Investigations:Agent:Type`, default `ClaudeCli`). The CLI already provides the tool loop, MCP client, Bash/Read/Grep tools, and parallel tool use — we write zero agent-loop code (web-spike: Anthropic endorses thin integrations; the CLI *is* the battle-tested loop). Swapping runtimes later (Agent SDK, containerized CLI, MS Agent Framework) = add a sibling `Investigations.Agent.<X>` project + one DI case — Application, Domain, API, and the DB schema don't change. The swappability rule that makes this real: **no claude-specific type, format, or convention leaks past the adapter boundary** — stream-json parsing, `--allowed-tools` syntax, MCP config files, and session ids are all internal to `Investigations.Agent.ClaudeCli`; the port speaks only `InvestigationRequest` / `AgentEvent` / `AgentRunResult`.
- **Sources are the agent's tools, not pre-ingested** (web-spike Q2: live tool-calling for telemetry): logs via `Bash(gcloud logging read …)` using the developer's existing gcloud auth; code via `Read`/`Grep`/`Glob` over `C:\Git\Work\Backend` checkouts plus read-only git (`fetch`/`log`/`show`/`diff` — history for change↔spike correlation, `git show origin/<default>:<path>` for deployed-ref reads regardless of the dev's current branch; never `checkout`); Sentry via `sentry-mcp` stdio with a user auth token (`event:read`, `project:read`, `org:read` — org tokens are CI-oriented, web-spike Q3). **Container phase swaps the dev workspace for a service-owned bare-clone cache** (`git clone --bare` once per repo, incremental `git fetch` at run start, reads via `git show` at the deployed ref) — never clone-per-run; the GitHub MCP stays a fallback, since per-grep API roundtrips are far slower than disk.
- **Mongo is curated, not free-form — the tool surface is the permission model.** Unlike logs/Sentry, Mongo access goes through a bespoke stdio MCP server (`Investigations.Mcp.Mongo`, official `ModelContextProtocol` C# SDK) exposing named, parameterized, projection-allowlisted read tools (`find_account`, `get_account_deletion_state`) — the agent physically cannot express any other operation, and PII-dense raw documents never reach the model (only allowlisted fields). Second net: the server's connection string uses a dedicated **read-only Mongo user**. Write capability stays out of the agent entirely: the report contract gains `proposedActions`, the job persists them as `proposed` rows, and `POST …/actions/{id}/approve` executes via `IProposedActionExecutor` in the service (Phase 1: `restore_account`, net-new logic owned by this module; executor uses a separate write-capable connection string whose Mongo user is scoped to `update` on the accounts collection only).
- **Async-first contract because Slack is the real consumer**: investigations take ~1–2 min (web-spike speed budget), far beyond Slack's 3-second ack window — so `POST` returns `202` immediately, the bot polls (or Phase 2 adds a callback), progress events let the bot stream "investigating… (checked logs, reading EstimatesController)" updates into the thread, and the finding's `summary` is budgeted to fit one Slack block.
- **No authorization in Phase 1** — the API binds to localhost on the dev machine. A simple API key lands together with containerization; the permission-key story (if it ever joins `Tofu.Auth`) is deliberately deferred.
- **PII trade-off, recorded explicitly:** because the agent pulls tool results itself, the existing Presidio redaction port (`src/Analyses/Analyses.Domain/Redaction`, `src/Analyses/Analyses.Infrastructure/Redaction`) cannot intercept between source and model — log/Sentry payloads reach the Anthropic API unredacted. Accepted for Phase 1 (same class of data already flows to OpenAI in FSM-fit, and runs are developer-triggered); the Phase 2 fix is a thin MCP proxy applying field allowlists + Presidio per source (web-spike Q2/PII). Until then the system prompt instructs the agent to never quote emails/PII into findings, and findings are the only artifact shown to Slack.

## Data model

> **2026-06-07:** target schema simplified to **5 tables** (drop `taxonomy`/`known_issues`/`links`, FTS, `events.seq`) — see [`agent-context-pull.md`](./agent-context-pull.md) for the target ER diagram and rationale. Below is the Phase-1 plan as built.

All Phase-1 tables live in a new **`investigations` schema** in the same local Postgres database Hangfire uses, applied via the repo's module-migrations runner (`src/Analyses/Analyses.Infrastructure/Migrations/IModuleMigration.cs` pattern — raw SQL, ordered, idempotent; this repo deliberately has no EF).

### `investigations.investigation_runs`

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid NOT NULL` | PK, server-generated |
| `description` | `text NOT NULL` | the user's ask; `CHECK (length(description) BETWEEN 1 AND 4000)` |
| `hints` | `jsonb NULL` | optional steering: `sentryIssueId`, `requestPath`, `timeRangeUtc`, `accountId` — free-form, schema owned by the prompt builder |
| `status` | `text NOT NULL` | `CHECK (status IN ('pending','running','succeeded','failed','timed_out'))`; `text` not `smallint` — raw-SQL repo with no enum mapper, tiny row volume, human-debuggable |
| `requested_by` | `text NULL` | free-form in Phase 1; becomes the Slack user id later |
| `slack_channel_id` | `text NULL` | carried opaque for the future bot — API never interprets them |
| `slack_thread_ts` | `text NULL` | 〃 |
| `model` | `text NULL` | model id actually used, recorded from the agent result |
| `agent_session_id` | `text NULL` | opaque session/trace id reported by whichever agent adapter ran the investigation (claude CLI session id in Phase 1) — lets a dev resume/inspect the transcript locally |
| `input_tokens` / `output_tokens` | `bigint NULL` | cost accounting per run (web-spike: agentic runs are token-heavy; visibility from day one) |
| `limitations` | `jsonb NOT NULL DEFAULT '[]'` | agent-reported list of ask-parts that needed unconnected sources ("subscription plan needs Stripe — Phase 3") — the Slack bot renders these as ⚠️ so partial answers are never mistaken for complete ones |
| `error` | `text NULL` | failure detail when `status='failed'` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `started_at` / `completed_at` | `timestamptz NULL` | |

Indexes:
- `(status, created_at)` — the stale-run sweep (`status='running'` older than timeout) and the bot's "anything in flight?" check.
- `(created_at DESC)` — the recent-runs list endpoint.

### `investigations.investigation_findings`

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid NOT NULL` | PK |
| `run_id` | `uuid NOT NULL` | FK → `investigation_runs(id)` `ON DELETE CASCADE` |
| `seq` | `int NOT NULL` | ordering when a run yields several findings; `UNIQUE (run_id, seq)` |
| `summary` | `text NOT NULL` | Slack-ready compact statement; `CHECK (length(summary) <= 2900)` — fits one Slack section block (3001-char limit) without truncation by the bot |
| `details_md` | `text NULL` | full markdown narrative (evidence, reasoning) — thread reply / web view material |
| `confidence` | `smallint NULL` | 0–100, agent-reported; `CHECK (confidence BETWEEN 0 AND 100)` |
| `citations` | `jsonb NOT NULL DEFAULT '[]'` | machine-readable evidence anchors: `{kind: 'log-query'\|'sentry-issue'\|'code'\|'commit', ref: …}` — what makes findings verifiable instead of vibes |
| `fingerprint` | `text NULL` | canonical identity of the underlying error — the cross-run dedupe key (see derivation below) |
| `fingerprint_v` | `smallint NULL` | normalization-algorithm version, so a recipe change can re-fingerprint old rows instead of silently mismatching |

Indexes:
- `(run_id)`.
- `(fingerprint)` — the "same error, different investigation" lookup.
- `GIN (citations jsonb_path_ops)` — exact-ref recall: "which past runs cite Sentry issue X / request path Y?" — the deterministic dedupe path for repeat bugs.
- `GIN (to_tsvector('english', summary || ' ' || coalesce(details_md, '')))` via a generated `tsvector` column — full-text recall over past findings (web-spike: plain FTS before any vector search; pgvector is a Phase 2+ enhancement, not a foundation). A matching FTS index goes on `investigation_runs.description`.

**Fingerprint derivation** (computed at persist time by the job, not trusted from the agent verbatim; priority order mirrors Sentry/Datadog — see web-spike fingerprinting section):
1. Finding cites a Sentry issue → fingerprint = `sentry:<issue-id>` verbatim — Sentry already did the grouping (stack-frame hashing + embedding similarity); never re-derive what it solved.
2. Agent reported a structured error (`error: {type, topFrame}` in the report JSON) → `sha256(error_type + top_in_app_frame)`.
3. Raw log message only → `sha256(normalized message)` using Datadog's published normalization: strip numbers, ids, dates, versions, and anything inside quotes or parentheses — only word-like tokens contribute. (Drain3 is the heavyweight alternative for template mining, but it's Python — a sidecar isn't worth it for Phase 1; the regex normalizer is the in-process approximation.)

### `investigations.investigation_links`

> **Superseded (2026-06-07):** table dropped — related runs are derived from `findings.fingerprint` at read time; nothing about the relationship is stored. See [`agent-context-pull.md`](./agent-context-pull.md).

Typed, reversible edges between runs — "this run found the same root cause as run X". Kept **separate from fingerprints** deliberately (Sentry's merging lesson: manual links must never mutate automatic grouping); fingerprint matches *propose*, a human or the agent *records*.

| Column | Type | Notes |
|---|---|---|
| `from_run_id` / `to_run_id` | `uuid NOT NULL` | both FK → `investigation_runs(id)` `ON DELETE CASCADE`; `UNIQUE (from_run_id, to_run_id, relation_kind)`; `CHECK (from_run_id <> to_run_id)` |
| `relation_kind` | `text NOT NULL` | `CHECK (relation_kind IN ('duplicate_of','related_to','caused_by','supersedes'))` |
| `created_by` | `text NOT NULL` | `agent` or a human identifier — provenance matters when trust differs |
| `rationale` | `text NULL` | one line: why the link exists (e.g. "same fingerprint a1b2…") |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

### `investigations.proposed_actions`

The propose → approve → execute write path. The agent proposes in its report; rows land as `proposed`; a human decides via API; the **service** executes. Kinds are a closed set — a new kind ships only together with its executor (and a migration extending the CHECK).

| Column | Type | Notes |
|---|---|---|
| `id` | `uuid NOT NULL` | PK |
| `run_id` | `uuid NOT NULL` | FK → `investigation_runs(id)` `ON DELETE CASCADE` |
| `kind` | `text NOT NULL` | `CHECK (kind IN ('restore_account'))` — closed set; persist-time validation drops (and logs) proposals with no registered executor, mirroring the taxonomy rule |
| `payload` | `jsonb NOT NULL` | kind-specific args, e.g. `{accountId, reason}`; schema owned by the executor, validated at persist time |
| `rationale` | `text NULL` | agent's one-line why — what the approver reads |
| `status` | `text NOT NULL` | `CHECK (status IN ('proposed','approved','rejected','executed','failed'))`; `approved` is transient (set at decision, before execution completes) |
| `decided_by` | `text NULL` | human identifier; required by the API on approve/reject |
| `decided_at` | `timestamptz NULL` | |
| `executed_at` | `timestamptz NULL` | |
| `error` | `text NULL` | populated when `status='failed'` |
| `created_at` | `timestamptz NOT NULL DEFAULT now()` | |

Indexes:
- `(status, created_at)` — the pending-approval queue.
- `(run_id)`.

Double-approval guard: approve flips status via conditional `UPDATE … SET status='approved' WHERE id=@id AND status='proposed'` — a second concurrent approve sees 0 rows affected and returns `409`.

### `investigations.taxonomy` and `investigations.investigation_tags`

> **Superseded (2026-06-07):** the `taxonomy` table is dropped — the vocabulary is the git-versioned `taxonomy.json` source file; `investigation_tags` stays, validated app-side. See [`agent-context-pull.md`](./agent-context-pull.md).

Closed tag vocabulary + multi-valued tag assignments (a run can carry `area:payments` *and* `area:invoices` — "arrays" are just multiple rows per key). Tags live on the **run**, not per finding — runs rarely have >2 findings and the Slack bot navigates by run; revisit only if multi-finding runs become common.

| Column (`taxonomy`) | Type | Notes |
|---|---|---|
| `key` | `text NOT NULL` | dimension, e.g. `area`, `kind`, `source`, `service` |
| `value` | `text NOT NULL` | PK `(key, value)`; seeded in the migration, extended by plain `INSERT` — new values appear in the next run's prompt automatically, no code change |

| Column (`investigation_tags`) | Type | Notes |
|---|---|---|
| `run_id` | `uuid NOT NULL` | FK → `investigation_runs(id)` `ON DELETE CASCADE` |
| `key` | `text NOT NULL` | |
| `value` | `text NOT NULL` | `UNIQUE (run_id, key, value)`; FK `(key, value)` → `taxonomy` — the closed vocabulary is **DB-enforced**: the agent cannot invent tags; unknown tags are dropped + logged at persist time |
| `source` | `text NOT NULL DEFAULT 'llm'` | `CHECK (source IN ('llm','human'))` — human corrections are distinguishable from agent guesses (Grab's verification-loop pattern in miniature) |

Index: `(key, value)` — tag navigation and `GROUP BY` analytics ("what do we investigate most?").

Initial seed (extend freely): `area: payments|invoices|estimates|auth|notifications|pdf`, `kind: regression|config|data|infra|client-bug|question`, `source: gcp-logs|sentry|code|mixed`, `service: invoices-api|invoices-worker|tofu-invoices|tofu-auth|tofu-ai`.

### `investigations.investigation_events`

The progress timeline — what the Slack bot streams into the thread, and the local audit trail of every tool call (web-spike Q6: persist tool name/args/duration; modeled loosely on the OTel GenAI span vocabulary, which is still experimental, so the vocabulary lives in `kind` + `payload` rather than dedicated columns).

| Column | Type | Notes |
|---|---|---|
| `id` | `bigint GENERATED ALWAYS AS IDENTITY` | PK |
| `run_id` | `uuid NOT NULL` | FK → `investigation_runs(id)` `ON DELETE CASCADE` |
| `seq` | `int NOT NULL` | `UNIQUE (run_id, seq)`; assigned by the adapter as stream-json lines arrive |
| `occurred_at` | `timestamptz NOT NULL` | |
| `kind` | `text NOT NULL` | `CHECK (kind IN ('status_change','tool_call','agent_message','error'))` |
| `payload` | `jsonb NOT NULL` | for `tool_call`: tool name, redacted-args summary, duration ms; for `agent_message`: the visible text |

Index: `(run_id, seq)`.

### Migration

New SQL migration class `src/Investigations/Investigations.Infrastructure/Migrations/M0001_CreateInvestigationsSchema.cs` implementing `IModuleMigration` (`src/Analyses/Analyses.Infrastructure/Migrations/IModuleMigration.cs`), registered with the module-migrations runner the same way the Analyses module registers its own (`src/Analyses/Analyses.Infrastructure/Migrations/ServiceCollectionExtensions.cs`). No `dotnet ef` — this repo runs migrations through `ModuleMigrationsRunner` at startup / via the `DatabaseUpdate` entry point (`src/Tofu.AI.Api/DatabaseUpdate.cs`).

### Local Postgres — persistent Docker container

`Tofu.AI.Backend` has no `docker-compose.yml` today — Phase 1 adds one at the repo root:

```yaml
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    ports:
      - "55433:5432"   # 55433 to avoid clashing with Tofu.Auth's local Postgres on 55432
    environment:
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: tofu_ai
    volumes:
      - tofu-ai-pgdata:/var/lib/postgresql/data

volumes:
  tofu-ai-pgdata:    # named volume — survives `docker compose down`, container recreation, and image upgrades
```

The named volume is the durability guarantee the user asked for: `docker compose up -d postgres` after any restart reattaches the same data; **only `docker compose down -v` (never run it) or `docker volume rm` would destroy it.** Connection strings via user-secrets in `src/Tofu.AI.Api`:

```powershell
dotnet user-secrets set "ConnectionStrings:Investigations" "Host=localhost;Port=55433;Username=postgres;Password=postgres;Database=tofu_ai"
# Hangfire (existing key) can point at the same server/database:
dotnet user-secrets set "ConnectionStrings:Analyses" "Host=localhost;Port=55433;Username=postgres;Password=postgres;Database=tofu_ai"
# Mongo, two separate users (least privilege):
#   read-only user → consumed by Investigations.Mcp.Mongo (the agent's read tools)
dotnet user-secrets set "ConnectionStrings:InvestigationsMongoRead" "<read-only-user connection string>"
#   write user scoped to update on the accounts collection only → consumed by RestoreAccountActionExecutor
dotnet user-secrets set "ConnectionStrings:InvestigationsMongoActions" "<restricted-write-user connection string>"
```

Separate `Investigations` connection-string key even though it targets the same database — keeps the module extractable and lets the container phase split databases without code changes.

## Domain integration

New module mirroring `src/Analyses` (four projects — the three Analyses-style layers plus the swappable agent-adapter project; no Persistence project — Analyses keeps its empty, the convention here is repositories in Infrastructure):

```
src/Investigations/
  Investigations.Domain/             ← entities, status machine, ports (incl. IInvestigationAgentPort, IProposedActionExecutor)
  Investigations.Application/        ← InvestigationService, ProposedActionService, RunInvestigationJob, StaleRunSweep
  Investigations.Infrastructure/     ← Npgsql repository, SQL migrations, options, action executors (Mongo)
  Investigations.Agent.ClaudeCli/    ← THE replaceable runtime module — everything claude-specific lives here
  Investigations.Mcp.Mongo/          ← curated Mongo MCP server (stdio console app) — the agent's only Mongo surface
```

**`Investigations.Domain`**
- `InvestigationRun` aggregate (id, description, hints, status + transitions `Pending→Running→Succeeded|Failed|TimedOut`; invalid transitions throw), `InvestigationFinding`, `InvestigationEvent`, `InvestigationStatus`.
- Ports: `IInvestigationRunRepository` (create, get-with-findings, update-status, append-events, list-recent, find-stale-running), `IInvestigationAgentPort` — single method `RunAsync(InvestigationRequest request, Func<AgentEvent, Task> onEvent, CancellationToken ct) → AgentRunResult` (findings + token usage + session id). Event callback rather than buffering so progress rows land while the run is live — that's what the Slack bot streams.

**`Investigations.Application`**
- `InvestigationService.StartAsync` — validates, persists `pending` run, enqueues the Hangfire job, returns the id.
- `RunInvestigationJob` — Hangfire job (same host as `AnalyzeFsmFitJob`): transition to `running`, build the prompt from description + hints, invoke the agent port, persist events as they stream, persist findings + proposed actions (each proposal validated against the registered executors — unknown kind or invalid payload is dropped + logged, like taxonomy tags), final status. At finding-persist time the job computes fingerprints and, on a match with a prior run's finding, auto-inserts an `investigation_links` row (`relation_kind='related_to'`, `created_by='agent'`, rationale `"same fingerprint <hash>"`) — the link is recorded, surfaced in the result, and reversible; it never merges runs or mutates the fingerprint logic. The prompt builder passes `description` as the task **verbatim** — bug RCA is one shape of task, "search logs for user X / what's account Y's subscription plan" is equally valid; the system-prompt appendix contributes the source inventory, read-only rules, the no-PII-in-findings rule, and the instruction to record parts of the ask that need unconnected sources as `limitations` instead of guessing (e.g. "subscription plan needs Stripe — not connected; inferred `ProductKey=invoices.web` from request logs instead"). Before invoking the agent, the job also performs **recall**: exact citation/hint match (same `sentryIssueId` / `requestPath` / `accountId` in past findings' `citations`), **fingerprint match** (a `sentryIssueId` hint normalizes to `sentry:<id>` and hits the fingerprint index directly), plus FTS over past summaries, and injects the top ~5 hits into the prompt as a *"Related past investigations"* block — the agent verifies prior conclusions instead of rediscovering them. Recall is prompt-time context, not an agent tool, in Phase 1 — no extra MCP plumbing. The prompt builder also injects the current taxonomy (`SELECT key, value FROM taxonomy`) with the instruction to tag the run from exactly that vocabulary, multiple values per key allowed; persist-time validation drops (and logs) anything outside it. Wall-clock timeout from options → `timed_out` + process kill. `[DisableConcurrentExecution]`-equivalent guard: `MaxConcurrentRuns` (default 1) — one local machine, one agent at a time; queued runs simply wait as `pending`.
- `StaleRunSweep` — on host start, mark `running` rows older than the timeout as `failed` (error `"orphaned by service restart"`); mirrors the FSM-fit staleness lesson — a killed host must not leave zombie `running` rows that block the bot's "in flight?" view.

**`Investigations.Agent.ClaudeCli`** — the replaceable runtime module; references only `Investigations.Domain`
- `ClaudeCliAgentAdapter : IInvestigationAgentPort` — spawns `claude -p "<prompt>" --output-format stream-json --max-turns <N> --mcp-config <path> --allowed-tools "Bash(gcloud logging read:*),Bash(git fetch:*),Bash(git log:*),Bash(git show:*),Bash(git diff:*),Read,Grep,Glob,mcp__sentry__*,mcp__mongo__*"` (`mcp__mongo__*` is safe to wildcard — the in-house server only *has* read tools), working directory = `WorkspaceRoot`; the read-only git commands serve two needs: `git log`/`git diff` power the code-change↔error-spike correlation, and `git fetch` + `git show origin/<default>:<path>` let the agent inspect the **deployed** ref even when the developer's checkout sits on a feature branch — `git checkout` is deliberately absent so the agent can never disturb the developer's working tree; parses stream-json lines into `AgentEvent`s; final agent message is instructed (system-prompt appendix) to end with a fenced JSON report `{findings:[{summary, details_md, confidence, citations, error?:{type, message, topFrame}}], limitations:[string], tags:{key:[values]}, proposedActions:[{kind, payload, rationale}]}` (tags multi-valued per key from the injected taxonomy; `error` is the optional structured signal the job fingerprints from — the job, not the agent, computes the canonical fingerprint) which the adapter parses — structured-output-by-convention, validated and retried once on parse failure. Read-only enforcement = the `--allowed-tools` allowlist (no Edit/Write/generic Bash) + read-only tokens; document that allowlist as the security boundary. All claude-isms (stream-json schema, tool-allowlist syntax, MCP config file, session id) stay inside this project — see the swappability rule in High-level approach.
- `ClaudeCliOptions` (`SectionName = "Investigations:Agent:ClaudeCli"`): `CliPath`, `McpConfigPath`, `Model`, `MaxTurns` (default 50). Secrets via environment: `ANTHROPIC_API_KEY`, `SENTRY_AUTH_TOKEN` (referenced from the checked-in `investigations-mcp.json` MCP config, which itself contains no secrets).
- `AddClaudeCliAgent(configuration)` — self-contained DI registration; `AddInvestigationsModule` picks the adapter from `Investigations:Agent:Type` (`ClaudeCli` is the only Phase-1 case; the switch exists so a sibling adapter project is a one-line addition).

**`Investigations.Infrastructure`**
- `NpgsqlInvestigationRunRepository` — raw Npgsql like `BigQueryAccountMetricsRepository`'s style of explicit SQL (no ORM in this repo).
- `Migrations/M0001_CreateInvestigationsSchema.cs` (above).
- `InvestigationsOptions` (`SectionName = "Investigations"`, mirroring `src/Analyses/Analyses.Infrastructure/Llm/OpenAiOptions.cs:9` conventions, `[Required]` + `ValidateOnStart`) — runtime-agnostic settings only: `WorkspaceRoot`, `RunTimeout` (default 10 min), `MaxConcurrentRuns` (1), `GcpProject` (default `invoicesapp-project-test`; prod log reads are read-only and allowed, but the default stays test). Adapter-specific knobs live in the adapter's own options class so a runtime swap doesn't orphan config keys.

**`Tofu.AI.Api`**
- `Controllers/InvestigationsController.cs` next to `Controllers/ChatController.cs`; DI wired through a module-level `AddInvestigationsModule(configuration)` mirroring `src/Analyses/Analyses.Infrastructure/DependencyInjection.cs`.

### Loading strategy

Repository loads are explicit per endpoint: `GET /{id}` loads run + findings (two queries, no joins-into-aggregate magic); the events endpoint pages by `seq` so the Slack bot can poll incrementally (`?afterSeq=`).

## Endpoints

```
POST /api/investigations                  → 202 Accepted {id}
GET  /api/investigations/{id}             → 200 run + findings + proposed actions
GET  /api/investigations/{id}/events      → 200 progress timeline (paged, ?afterSeq=&limit=)
GET  /api/investigations                  → 200 recent runs (?limit=20&q=<FTS over descriptions+findings>&citationRef=<exact ref, e.g. PROD-API-1234>&tag=<key:value, repeatable, ANDed>)

GET  /api/investigations/actions                    → 200 actions (?status=proposed&limit=20) — the approval queue
POST /api/investigations/actions/{actionId}/approve → 200 {status: executed|failed, error?}; body {decidedBy}; 409 if not 'proposed'
POST /api/investigations/actions/{actionId}/reject  → 200; body {decidedBy, reason?}; 409 if not 'proposed'
```

Approve executes the action **synchronously in the request** (a restore is one Mongo update — no job needed); executor failure → action `failed` with `error`, returned in the response body, never a 5xx.

The `q` / `citationRef` params are the "have we seen this before?" surface — the Slack bot checks here before starting a new run, and answers repeat questions from history for free.

### DTOs

```csharp
public sealed record StartInvestigationRequest
{
    public required string Description { get; init; }
    public InvestigationHintsDto? Hints { get; init; }
    public string? RequestedBy { get; init; }
    public SlackContextDto? Slack { get; init; }      // opaque passthrough for the future bot
}

public sealed record InvestigationHintsDto
{
    public string? SentryIssueId { get; init; }
    public string? RequestPath { get; init; }         // e.g. "/api/data/typed/bookCall"
    public string? AccountId { get; init; }
    public DateTimeOffset? FromUtc { get; init; }
    public DateTimeOffset? ToUtc { get; init; }
}

public sealed record SlackContextDto
{
    public required string ChannelId { get; init; }
    public string? ThreadTs { get; init; }
}

public sealed record InvestigationRunDto
{
    public required Guid Id { get; init; }
    public required string Status { get; init; }      // pending|running|succeeded|failed|timed_out
    public required string Description { get; init; }
    public string? Error { get; init; }
    public required DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset? CompletedAt { get; init; }
    public IReadOnlyList<InvestigationFindingDto> Findings { get; init; } = [];
    public IReadOnlyList<string> Limitations { get; init; } = [];  // parts of the ask that needed unconnected sources
    public IReadOnlyDictionary<string, IReadOnlyList<string>> Tags { get; init; } =
        new Dictionary<string, IReadOnlyList<string>>();           // multi-valued: {"area":["payments","invoices"]}
    public IReadOnlyList<ProposedActionDto> ProposedActions { get; init; } = [];
}

public sealed record ProposedActionDto
{
    public required Guid Id { get; init; }
    public required Guid RunId { get; init; }
    public required string Kind { get; init; }        // restore_account (closed set)
    public required JsonElement Payload { get; init; }
    public string? Rationale { get; init; }
    public required string Status { get; init; }      // proposed|approved|rejected|executed|failed
    public string? DecidedBy { get; init; }
    public DateTimeOffset? DecidedAt { get; init; }
    public DateTimeOffset? ExecutedAt { get; init; }
    public string? Error { get; init; }
}

public sealed record InvestigationFindingDto
{
    public required string Summary { get; init; }     // ≤2900 chars, Slack-block-safe
    public string? DetailsMd { get; init; }
    public int? Confidence { get; init; }
    public required IReadOnlyList<CitationDto> Citations { get; init; }
}

public sealed record CitationDto
{
    public required string Kind { get; init; }        // log-query | sentry-issue | code | commit
    public required string Ref { get; init; }         // LQL filter, SENTRY-123, File.cs:42, sha
}

public sealed record InvestigationEventDto
{
    public required int Seq { get; init; }
    public required DateTimeOffset OccurredAt { get; init; }
    public required string Kind { get; init; }        // status_change | tool_call | agent_message | error
    public required JsonElement Payload { get; init; }
}
```

### Validation and errors

- `Description` required, non-whitespace after trim, ≤ 4000 chars → `400` ProblemDetails.
- `Hints.FromUtc > ToUtc` → `400`.
- Unknown id on `GET` → `404` (standard exception-middleware behavior of the host).
- `POST` while `MaxConcurrentRuns` are already `running` → still `202` — the run queues as `pending`; the bot communicates the queue position from the list endpoint. Rejecting would push retry logic into every client.
- Agent process exit ≠ 0, unparseable final report after one retry, or timeout → run `failed`/`timed_out` with `error` populated; never a 5xx at the API (the failure is the run's state, not the request's).

## Lifecycle

| Trigger | Behaviour |
|---|---|
| Service restarts while runs are `running` | `StaleRunSweep` marks them `failed` (`"orphaned by service restart"`) at host start — no zombie runs |
| Run exceeds `RunTimeout` | agent process killed, run → `timed_out`, partial events retained (they're already persisted) |
| Run deleted (manual SQL only in Phase 1 — no DELETE endpoint) | findings + events cascade via FK |
| Postgres container restarted / recreated / upgraded | data intact via the `tofu-ai-pgdata` named volume; only `down -v` / `volume rm` destroys it |
| `claude` CLI missing or `ANTHROPIC_API_KEY` unset | fail fast at startup via options validation + a startup probe, mirroring the OpenAI key fail-fast at `src/Tofu.AI.Api/Program.cs:68` |
| Agent proposes an action with unknown `kind` / invalid payload | dropped + logged at persist time (mirrors the taxonomy rule) — run still succeeds |
| Approve called twice / on a decided action | conditional `UPDATE … WHERE status='proposed'` → second caller gets `409` |
| Executor fails (account not found / not soft-deleted / Mongo error) | action → `failed` with `error`; run untouched; re-propose requires a new investigation (no retry endpoint in Phase 1) |

## Docs to update

- [x] `Local.Docs/Backend/Storage/` — `investigations.*` tables added to [`postgres.md`](../../Backend/Storage/postgres.md) + index row (2026-06-07).
- [x] `Local.Docs/Backend/Services/Tofu.AI/Investigations.md` — current-state service reference created (2026-06-07).
- [ ] `Tofu.AI.Backend/README.md` — local-run section: `docker compose up -d postgres`, user-secrets (incl. the two Mongo connection strings), `claude` CLI prerequisites, Mongo user provisioning (read-only + accounts-update-only).
