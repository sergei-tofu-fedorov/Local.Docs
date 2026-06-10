# FS-1111 — AI service for investigating issues

**Status:** in-progress
**Started:** 2026-06-06
**ClickUp:** https://app.clickup.com/t/FS-1111
**Affected repos:** `Tofu.AI.Backend` (new `Investigations` module)

## Branches

- `Tofu.AI.Backend` → `feature/FS-1111` (from `origin/develop`)

## Goal

Give the team an AI-driven way to investigate production issues without hand-correlating tools. A REST API takes a free-form ask ("checkout 500s spiked at 14:00 — why?"), a background job hands it to a headless Claude agent with **read-only** access to GCP logs, Sentry, source code, and curated MongoDB, and the run + findings + a tool-call timeline are persisted. The contract is shaped for a future Slack bot (async, compact summaries, incremental progress). Phase 1 runs on a developer machine; the design keeps the seam for a containerized deploy later.

## Reading order

Start here, then:

| Doc | What | Read when |
|---|---|---|
| [`overview.md`](overview.md) | **The design (source of truth):** 5-table schema, endpoints, DTOs, lifecycle, fingerprinting, module layout | first, for the full picture |
| [`agent-context.md`](agent-context.md) | The agent's `.tofu-ai/` knowledge tree + the files-vs-DB read path | when touching recall / prompt context |
| [`impl-design.md`](impl-design.md) | Abstraction surface — ports, class skeletons, DI wiring | when implementing |
| [`impl-interaction.md`](impl-interaction.md) | Runtime sequence of one end-to-end run | alongside impl-design |
| [`web-spike.md`](web-spike.md) | The three research spikes backing the design choices | for the "why" behind a decision |
| [`sample-report-b88ad28f.md`](sample-report-b88ad28f.md) | A real captured run (Slack-mrkdwn report) | to see the output shape |

Current-state service reference (kept in sync with the code): [`Backend/Services/Tofu.AI/Investigations.md`](../../Backend/Services/Tofu.AI/Investigations.md).

## Scope

- **In scope (Phase 1):** the `Investigations` module in `Tofu.AI.Backend`; REST API; claude-CLI agent with read-only GCP logs + Sentry + source code + curated Mongo; Postgres persistence; propose→approve→execute write path (`restore_account`); Slack-bot-shaped contracts; the `.tofu-ai/` pull-context knowledge tree.
- **Out of scope:** the Slack bot itself; agent-executed writes; auth on the API; containerized deploy; ClickUp/Stripe/Amplitude sources. (Rationale and phasing in [`overview.md`](overview.md) and [`web-spike.md`](web-spike.md).)

## Affected repos

- `Tofu.AI.Backend` — new `Investigations` module (`src/Investigations/{Domain,Application,Infrastructure,Agent.ClaudeCli,Mcp.Mongo}`), new `InvestigationsController` in `Tofu.AI.Api`, new root `docker-compose.yml` (persistent local Postgres). **Single-repo feature** — no cross-repo contract changes in Phase 1.

## Plan

1. [x] Investigations module (Domain / Application / Infrastructure / Agent.ClaudeCli) — verified by live run `b88ad28f` (2026-06-06)
2. [x] docker-compose Postgres (named volume) + `investigations` schema migration
3. [x] REST API: start / cancel / get / events / report / list + actions (approve/reject)
4. [x] Mongo read path: `Investigations.Mcp.Mongo` curated MCP server — plumbing done, tool bodies stubbed (`TODO(FS-1111)`)
5. [x] Propose → approve → execute infrastructure (`proposed_actions`, approve/reject endpoints, executor registry)
6. [x] Pull-only `.tofu-ai/` file-tree context (`IAgentContextWriter` / `AgentContextFilesWriter`, prompt-builder pointer lines, no recall queries) + 5-table schema + `afterId` events cursor
7. [ ] **`restore_account` execution logic + Mongo read-tool query bodies** — currently `TODO(FS-1111)` stubs in `RestoreAccountActionExecutor` and `AccountReadTools`; blocked on the account soft-delete domain semantics (see Open questions)
8. [ ] Provision the two least-privilege Mongo users (read-only for the MCP server; update-on-accounts-only for the executor)
9. [ ] Schema cleanup leftover: drop the unused FTS `tsvector` columns + `investigation_events.seq` from `M0001` (the design treats them as gone; the migration still creates them)
10. [ ] Integration tests (`/tests`)
11. [ ] `Tofu.AI.Backend/README.md` local-run section (compose, user-secrets, claude CLI + MCP prerequisites, Mongo user provisioning)
12. [ ] *(Phase 2)* Container-phase deploy: git-checkout knowledge repo + reconcile (see [`agent-context.md`](agent-context.md))

## API / DTO changes

Net-new and **additive** — a brand-new `InvestigationsController` under `/api/investigations` (start, cancel, get, events, report, list, and the `actions` approve/reject queue). No existing `Tofu.AI` endpoint is changed. Full endpoint table and DTO records are in [`overview.md`](overview.md) § Endpoints / § DTOs. Notable shapes: `POST` returns `202` + `InvestigationStartedDto`; events page by an `afterId` cursor; the report endpoint returns `text/plain` (`?format=slack` for compact mrkdwn). There are deliberately **no known-issues endpoints** — `known-issues.md` is a git-versioned source file.

## Breaking changes

**None — additive only.** A new module, new `investigations` Postgres schema, and a new controller; no proto, no existing REST surface, no existing collection/table is touched. The `M0001` migration is additive and idempotent ("ensure schema"). No mobile/web/third-party consumer is affected.

## Data / migration

- New **`investigations` schema, 5 tables** (`investigation_runs`, `investigation_findings`, `investigation_tags`, `investigation_events`, `proposed_actions`) via `M0001_CreateInvestigationsSchema` (`IModuleMigration`, raw SQL, idempotent). Schema detail in [`overview.md`](overview.md) § Data model.
- New **local Postgres container** (`docker-compose.yml`, named volume `tofu-ai-pgdata` — survives restarts).
- The `.tofu-ai/` file tree is a **regenerable projection** of Postgres + git-versioned source files (`taxonomy.json`, `known-issues.md`), not a migration — see [`agent-context.md`](agent-context.md).
- Storage inventory updated: [`Backend/Storage/postgres.md`](../../Backend/Storage/postgres.md).
- **Pending cleanup** (plan item 9): the migration still creates the unused FTS `tsvector` columns and `investigation_events.seq`; the design treats both as removed.

## Open questions

- [ ] **What does "restore account" mean concretely?** Which DB/collection, which soft-delete fields flip, any cascades — must be confirmed against `Invoices.Backend/Docs/persistence.md` + the accounts repository before `RestoreAccountActionExecutor` and the `AccountReadTools` query bodies are written (blocks plan item 7).
- [ ] **Which Mongo cluster does Phase 1 point at** (local dev vs prod Atlas read replica), and provision the two least-privilege users — Atlas custom role for prod, plain users for local (blocks plan item 8).
- [ ] **`Investigations.Mcp.Mongo` packaging:** the CLI's MCP config needs a stable command — `dotnet run --project … --no-build` (requires a prior build) vs a published exe path. Revisit when the tool bodies land.
- [ ] **`IModuleMigration` location:** currently referenced from `Analyses.Infrastructure`; extract the runner to a shared project when a third module appears, or sooner if the reference grates.

## Test plan

Per the testing requirement, the feature is not done until at least one integration test exercises the real boundary; run `/tests` on new test files to align with conventions.

- **Unit tests:** `ErrorFingerprinter` (priority order + Datadog message normalization + version stamping); `FencedReportParser` (valid report, malformed → one retry → fail); tag validation against `taxonomy.json` (unknown tags dropped + logged); proposed-action payload validation + the conditional double-approve guard.
- **Integration tests** (functional, TestContainers Postgres): start → poll → succeeded lifecycle; `events?afterId=` incremental paging; approve/reject with the `409`-on-second-decide guard; `list` `citationRef` + repeatable `tag` filters; `StaleRunSweep` marking orphaned `running` rows failed at host start. The agent port is faked at this layer (no live claude CLI).
- **Manual verification:** a live end-to-end run against the test GCP project + Sentry — `b88ad28f` (captured in [`sample-report-b88ad28f.md`](sample-report-b88ad28f.md)) is the reference.
