# FS-1111 — Service using AI for investigating diff issues

**Status:** in-progress
**Started:** 2026-06-06
**ClickUp:** https://app.clickup.com/t/FS-1111
**Affected repos:** `Tofu.AI.Backend` (new `Investigations` module)

## Branches

- `Tofu.AI.Backend` → `feature/FS-1111` (from `origin/develop`)

## Goal

creating service which aill use AI for investigating diff issues for our application

## Docs in this folder

| Doc | What |
|---|---|
| [`web-spike.md`](web-spike.md) | research: buy-vs-build, architecture, per-source survey, fingerprinting/taxonomy/linking |
| [`overview.md`](overview.md) | the Phase-1 plan: schema, endpoints, DTOs, lifecycle |
| [`impl-design.md`](impl-design.md) / [`impl-interaction.md`](impl-interaction.md) | abstractions design + runtime sequence |
| [`agent-context-pull.md`](agent-context-pull.md) | 2026-06-07 redesign: pull-only file-tree context, files-vs-DB division — **not yet implemented** |
| [`sample-report-b88ad28f.md`](sample-report-b88ad28f.md) | real captured output of a successful run |

Current-state service reference (post-implementation): [`Backend/Services/Tofu.AI/Investigations.md`](../../Backend/Services/Tofu.AI/Investigations.md).

## Scope

- In scope (Phase 1): Investigations module in `Tofu.AI.Backend`; REST API; claude CLI agent with read-only GCP logs + Sentry + source code + curated Mongo; Postgres persistence; propose→approve→execute write path (`restore_account`); Slack-bot-shaped contracts.
- Out of scope: the Slack bot itself; agent-executed writes; auth on the API; containerized deploy; ClickUp/Stripe/Amplitude sources.

## Affected repos

- `Tofu.AI.Backend` — new `Investigations` module (`src/Investigations/{Domain,Application,Infrastructure,Agent.ClaudeCli,Mcp.Mongo}`), new `InvestigationsController` in `Tofu.AI.Api`, new `docker-compose.yml` (persistent local Postgres). Single-repo feature — no cross-repo contract changes in Phase 1.

## Plan

1. [x] Investigations module (Domain / Application / Infrastructure / Agent.ClaudeCli) — verified by live run `b88ad28f` (2026-06-06)
2. [x] docker-compose Postgres (named volume) + `investigations` schema migration
3. [x] REST API: start / get / events / report / list / cancel / known-issues
4. [x] Mongo read path: `Investigations.Mcp.Mongo` curated MCP server — plumbing done, tool bodies stubbed
5. [x] Propose → approve → execute infrastructure (`proposed_actions`, approve/reject endpoints, executor stub)
6. [ ] `restore_account` execution logic + Mongo read-tool queries (account domain semantics — user-provided)
7. [ ] Provision the two least-privilege Mongo users (read-only; update-on-accounts)
8. [ ] Implement [`agent-context-pull.md`](agent-context-pull.md) (file-tree context, drop prompt-time recall, schema 8 → 5 tables, events cursor → `id`; container phase: git-checkout knowledge repo)
9. [ ] Integration tests (`/tests`)
10. [ ] `Tofu.AI.Backend/README.md` local-run section (compose, user-secrets, CLI + MCP prerequisites)

## API / DTO changes

<only if applicable — list new endpoints, request/response shapes, breaking changes>

## Breaking changes

<list anything that could break consumers (other repos, mobile clients, third-party API users) — proto field renumbering, removed/renamed REST endpoints, narrowed types, new required fields, dropped DB columns, changed event payloads, etc. If purely additive, write `None — additive only` so the explicit check is recorded. The `/feature review` op will re-audit this against the actual diff.>

## Data / migration

<only if applicable — new collections, indexes, migrations>

## Open questions

- [ ] …

## Test plan

- Unit tests:
- Integration tests:
- Manual verification:
