---
name: plan
description: Write overview.md — a file-path-anchored backend implementation plan for a scaffolded feature (/plan write <TASK>). Requires Local.Docs/features/<TASK>/README.md; no tests, not for frontend.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## What this skill is

Produce an **`overview.md`-style** implementation plan for a feature whose folder already exists in `Local.Docs/features/<TASK>/` (scaffolded by `/feature plan <TASK>`). The output replaces vague stubs and bullet research with a file-path-anchored, DDL-complete, DTO-complete, auth-and-lifecycle-explicit plan that an engineer can implement against without re-doing the design work.

**Reference shape:** `Local.Docs/features/WEB-1469-notes/overview.md`. Every `/plan` output should match its depth, conventions, and section ordering.

This skill is the design-deepening step. It runs **after** `/feature plan` (which scaffolds folder + thin README) and **before** code starts. It is purely a writing skill — it does not branch, lint, build, or open PRs.

## Scope: backend features

`/plan` is calibrated for **backend feature implementation** in this workspace's repos (`Invoices.Backend`, `Tofu.Invoices.Backend`, `Tofu.Auth.Backend`, `Tofu.Common.Backend`). It assumes the feature touches one or more of:

- PostgreSQL + Entity Framework Core (DbContext, migrations, configurations, CHECK constraints, partial indexes).
- MongoDB collections accessed through the existing `MongoDbContext` + `IConfigureMongoDbIndexesService` pattern.
- gRPC contracts in `*.proto` files plus their consumer-side mappers (e.g., `Invoices.Backend\Src\Tofu.Invoices\Mapping\Mapper.cs`).
- ASP.NET Core controllers inheriting from `BaseController`, decorated with `[AuthorizeAction(PermissionKeys.…)]`.
- Domain events / event-log channels (`JobDomainEvent`, `JobEventType`, `JobEvents`).
- Permission keys in `Tofu.Auth.Backend` and `Tofu.Permissions.Shared`.

`/plan` does **not** describe tests. Test design lives outside this skill — use `/tests` when ready to write them. The plan focuses on the implementation surface (data model, domain, endpoints, auth, lifecycle).

For features that are primarily frontend (Web, iOS) or pure documentation, do not use `/plan` — the question batches and section template are backend-shaped and will produce noise. Use the existing `/feature` workflow with a hand-written README instead.

## Slug / Branch Convention

Same as `/feature`:
- `<TASK>` is `WEB-NNNN`, `INVC-NNNN`, `FS-NNNN`, etc.
- Doc folder is `Local.Docs/features/<TASK>/`.
- If `<TASK>` is omitted, infer from the current branch (`feature/WEB-1234` → `WEB-1234`). If no branch matches, ask before guessing.

## Operations

| Op | Usage | Description |
|---|---|---|
| **write** | `/plan write <TASK>` (or `/plan <TASK>`) | Produce or overwrite `overview.md` in the feature folder. Interactive. Default op. |
| **check** | `/plan check <TASK>` | Read existing `overview.md` and audit it for stale file paths / line numbers / migration commands that drifted from the codebase. Read-only. |

If the user types just `/plan <TASK>` with no verb, treat it as `write`.

`/plan` refuses to operate when `Local.Docs/features/<TASK>/README.md` does not exist — it is not a folder-creating skill. Suggest `/feature plan <TASK>` first.

---

## Operation: `write`

Heart of the skill. Read what exists, anchor everything against the actual codebase, ask only what cannot be inferred, then write.

### Step 1 — Pull and read the feature folder

1. `cd Local.Docs` and best-effort fast-forward pull (same rules as `/feature load`: skip if dirty, on a non-default branch, or has unpushed commits; report what was pulled or skipped).
2. Read **everything** under `Local.Docs/features/<TASK>/`:
   - `README.md` — the seed plan from `/feature plan`. Extract title, `Affected repos`, `Goal`, `Scope`, `Plan`, `Open questions`. Ignore the `Test plan` section — `/plan` does not describe tests.
   - `web-spike.md` (when present) — output of `/web-spike`: vendor / pattern / library research with authoritative sources. Treat findings here as inputs to architectural choices; the web-spike's `Implications for the design` section often answers questions `/plan write` would otherwise have to ask. **Do not re-run web research** — consume what `/web-spike` captured.
   - Any other `research-*.md` / `overview-*.md` / `*-research.md` companion files — older vendor surveys, prior options analyses, decisions already made.
   - `implementation-plan.md` if present — older artifact; flag drift if its conclusions disagree with the README. Treat README as source of truth.
3. If `README.md` is missing, abort with the message: *"No `Local.Docs/features/<TASK>/README.md` found — run `/feature plan <TASK>` first to scaffold the folder."*

### Step 2 — Anchor against the codebase

For each repo listed in the README's `Affected repos` section, grep enough to make every later claim citable:

- Locate the entities, controllers, repositories, EF configurations, migrations folder, and DI registration files the feature touches.
- Capture **current line numbers** of the methods, fields, decorators, and routes the plan will reference.
- Note the project's existing patterns:
  - Domain method return shape (e.g., `Result<List<JobDomainEvent>>` from FluentResults).
  - EF config naming (`*Configuration.cs`).
  - Migration filename prefix (`<timestamp>_<TICKET>_<Description>.cs`).
  - DTO style (`public sealed record`, `init`-only, `[JsonPropertyName]` if used).
  - DI lifetime conventions (`Scoped` vs `Singleton`).
- For multi-repo features, do this per repo. Producer-side and consumer-side conventions can differ — record them separately.

**Never invent file paths or line numbers.** If a claim cannot be anchored, write `TBD — verify <path or symbol>` and surface it in Step 7 (Report).

### Step 3 — Assess complexity *(do this first)*

Before mapping gaps or asking questions, calibrate the depth of the plan to the size of the feature. The same template at the same depth for a 3-line config refactor and a multi-repo gRPC contract change wastes the user's time on one and underspecifies the other.

Score the feature against this rubric — count points, then bucket. **Do this internally; don't surface the score in the output.**

| Signal | +1 each |
|---|---|
| Touches more than one repo | +1 per additional repo beyond the first |
| Introduces a new entity / table / Mongo collection | +1 per entity |
| Adds new HTTP / gRPC routes | +1 per controller-or-service touched |
| Changes a `.proto` contract or shared DTO | +1 (additive) / +2 (breaking) |
| Adds a cross-store reference (Postgres ↔ Mongo) | +1 |
| Adds new permission keys or changes role / access semantics | +1 |
| Introduces a state machine, status transitions, or workflow | +1 |
| Has lifecycle behaviour to specify (cascade, archive, ownership, soft-delete) | +1 |
| Genuinely competing architectural shapes the user has not yet picked | +1 per option beyond the obvious one |
| Has a pricing-tier or paywall decision pending | +1 |

Bucket the score:

| Score | Tier | What the plan looks like |
|---|---|---|
| 0–1 | **Trivial** | Pure refactor, config move, single-file fix. Sections 1–4 + 6 only. High-level approach is **1–3 sentences** stating the chosen approach; no comparison table; trade-off bullets only if a real alternative was rejected, capped at one line each. Domain integration may be a single sub-section (config class + DI registration). Skip Authorization, Lifecycle, Docs-to-Update unless they have real content. |
| 2–4 | **Small** | One repo, one new entity *or* one new endpoint, no cross-store. Sections 1–6 + the relevant slice of 7–10. High-level approach: **2–4 trade-off bullets**, no comparison table unless ≥3 alternatives were considered. Lifecycle and Authorization optional per the gap-mapping rule. |
| 5–8 | **Medium** | Typical feature — new entity + endpoints, possibly cross-store. Sections 1–13 selectively. High-level approach: **3–5 trade-off bullets** + a small comparison table where useful. Full Authorization matrix and Lifecycle table when they apply. |
| 9+ | **Large** | Multi-repo, contract change, multiple entities, lifecycle, auth shifts. **Full WEB-1469 treatment** — every applicable section, full comparison tables, explicit producer/consumer rollout, breaking-change callouts. |

**Calibration examples:**
- WEB-1469 (notes on visits + clients): 2 entities + 5 endpoints + 1 controller + cross-store reference + new permission keys + lifecycle = score ~8 → Medium-Large.
- INVC-3608 (configurable owner-only product list): 0 entities + 0 new routes + 0 contracts + 0 permissions = score 0 → Trivial.

The complexity score determines which sections appear **and** how deep the trade-off treatment goes in the High-level approach. Don't over-engineer the doc for a refactor; don't under-engineer it for a CRUD feature.

### Steps 4–5 — Map the gaps, ask, and generate

**Read [`references/output-spec.md`](references/output-spec.md) in full before asking questions or writing.** It holds the section-by-section gap-mapping table (which sections are Always vs Only-if, and where each answer comes from), the word-count calibration per tier, the question-batching rules, the fixed section ordering, and the enforced style rules (anchoring, DDL tables, migration commands, DTO style, authorization matrix, lifecycle table, inline rationale). Deviations from that spec need a reason.

### Step 6 — Write the file

- Path: `Local.Docs/features/<TASK>/overview.md`.
- If the file already exists, do **not** silently overwrite. Read it, summarize the diff (sections changing, sections added, sections removed), and ask the user before replacing. If the user wants to merge rather than replace, fall back to producing a unified-diff-style proposal in chat and let them apply by hand.
- **Never auto-commit.** After writing, tell the user the file is on disk and print the commit command:
  ```
  pwsh Local.Docs/scripts/commit-docs.ps1 -ShortDescription "<TASK> overview"
  ```

### Step 7 — Report

After writing, print:

- Word count + section count of the produced doc.
- Any `TBD — verify` markers that survived (places the codebase grep couldn't anchor — these need the user's eyes).
- Any open questions punted to product or lead (deferred decisions captured but not resolved).
- The exact docs-commit command above.
- Reminder that `/feature review` (which calls `/review-gw --branch`) will audit the code against this plan once implementation starts.

---

## Operation: `check`

Read-only audit — useful weeks/months later when the codebase has drifted but the plan is still being implemented.

1. Read `Local.Docs/features/<TASK>/overview.md`.
2. Extract every `*.cs:line` reference and every PowerShell migration command's `-p` / `-s` project paths.
3. Verify each:
   - File exists at the claimed path.
   - Line number falls within the file.
   - The symbol the doc claims is at that line is actually there (best-effort fuzzy match against surrounding text).
   - Project paths in migration commands resolve to current `.csproj` files.
4. Report:
   - Drifted references (file moved, symbol renamed, line number off by N).
   - Missing files.
   - Stale migration commands.
   - Anything in the doc's `Lifecycle` table that contradicts current `*Controller.cs` behavior (best-effort, surface as warning not error).

Do not modify the doc. The user fixes drift manually or re-runs `/plan write` to regenerate.

---

## Conventions

- **One overview per feature.** Multi-repo features still get a single `overview.md`. Per-repo slices live as sub-sections under each section (e.g., the data model section has a sub-section per repo when each repo owns its own tables).
- **Never edits anything but `overview.md`.** README.md, research files, implementation-plan.md are inputs only — `/plan` reads them but does not modify them.
- **Never auto-commits.** Same convention as `/feature` and `/docs commit`.
- **Refuses to operate without a feature folder.** `/feature plan <TASK>` is a hard prerequisite.
- **Prefers existing terminology.** When the codebase calls something `RoleLevel.Admin` and the product calls it "Manager", the doc says both: *"the product term 'Manager' in the UI maps to `RoleLevel.Admin`"*. The plan is read by both engineers and PMs.
- **Trade-offs over decisions.** Every architectural choice gets a comparison block against the rejected alternatives. The reader needs to understand *why*, not just *what*.

## Notes

- This skill does not branch, build, lint, or open PRs. Branching/linting are `/feature start` and `/feature lint`. PR creation is always manual — the user pushes and opens PRs themselves; `/feature` has no `pr` op. `/plan` is design-only.
- For the doc-side commit flow, `/plan` defers to `/docs commit` (or the workspace's `Local.Docs/scripts/commit-docs.ps1` helper) — same as the rest of the doc workflow.
- The reference example (`Local.Docs/features/WEB-1469-notes/overview.md`) is the **Large**-tier calibration target. For other tiers, calibrate against the word-count and section-set bands in Step 3 and `references/output-spec.md`. If a Medium or Large feature ends up materially shallower than its tier suggests, the skill is under-asking — review the complexity score in Step 3 and the question batches.
