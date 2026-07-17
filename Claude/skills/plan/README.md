# /plan Skill - Quick Reference

Produces a deep, file-path-anchored implementation plan (`overview.md`) for a **backend** feature whose folder was scaffolded by `/feature plan`. Reference shape: [`Local.Docs/features/WEB-1469-notes/overview.md`](../../Local.Docs/features/WEB-1469-notes/overview.md).

Calibrated for the four backend repos in this workspace (`Invoices.Backend`, `Tofu.Invoices.Backend`, `Tofu.Auth.Backend`, `Tofu.Common.Backend`) and their stack: PostgreSQL + EF Core, MongoDB, gRPC, ASP.NET controllers. Not appropriate for frontend or mobile features — the question batches and section template are backend-shaped.

`/plan` does **not** cover tests. Use `/tests` for test design and authoring.

## Quick start

```
/plan <TASK>            # write overview.md (default op)
/plan write <TASK>      # same as above, explicit
/plan check <TASK>      # audit existing overview.md against the codebase
```

If `<TASK>` is omitted, inferred from the current branch (`feature/WEB-1234` → `WEB-1234`).

## Workflow

1. `/feature plan <TASK>` — scaffold folder + thin README *(existing skill)*.
2. *(Do research — vendor surveys, options analyses. Drop them as `research-*.md` next to the README; commit via `/docs commit`.)*
3. `/plan <TASK>` — interactive deep plan, produces `overview.md`.
4. Review the file, edit by hand if needed.
5. `pwsh Local.Docs/scripts/commit-docs.ps1 -ShortDescription "<TASK> overview"` — commit.
6. `/feature start <TASK>` — branch and implement against the plan.

## What it produces

`Local.Docs/features/<TASK>/overview.md` with these sections, in this order:

- Title + 1-paragraph entity-grounded summary
- Related ClickUp IDs (initiative + sub-tickets)
- Scope (In / Out)
- Pricing tiers / open blockers
- High-level approach + trade-offs vs rejected alternatives
- Data model — DDL tables, indexes, FKs, CHECKs, PowerShell migration command
- Domain integration — entity, EF config, methods, events, repositories, loading
- Endpoints — REST routes + DTOs + algorithms + validation
- Authorization — permission keys + role-action matrix
- Lifecycle — trigger × behaviour table
- Docs to update

*(Tests are deliberately out of scope — handled by `/tests`.)*

## What it does

- Reads the feature folder (`README.md`, `research-*.md`).
- Greps the affected repos to anchor every claim to a real `file.cs:line`.
- Asks the user (via `AskUserQuestion`, batched) only what cannot be inferred — chosen architecture, auth model, lifecycle behavior, pricing-tier gating.
- Writes `overview.md` matching the WEB-1469 reference style.

## What it doesn't do

- Doesn't auto-commit. Prints the `commit-docs.ps1` command instead.
- Doesn't edit `README.md`, `research-*.md`, or any other file in the folder.
- Doesn't branch, build, lint, or open PRs.
- Doesn't operate without an existing `Local.Docs/features/<TASK>/README.md` — refuses with a pointer to `/feature plan <TASK>`.

## Style rules enforced in output

1. Every code reference is `file.cs:line`. No "see the existing pattern" handwaves.
2. Architectural choices include a 3–5 bullet trade-off list against rejected alternatives.
3. DDL tables: `Column | Type | Notes`; CHECK constraints + FK behavior live in Notes.
4. Authorization is a matrix, not paragraphs.
5. Lifecycle is a `Trigger | Behaviour` table; covers deletion, archive, ownership change, cross-store cascade behavior.
6. DTOs are real C# (`public sealed record`, `public required`, `init`).

## Where the skill lives

`C:/Git/Work/Backend/.claude/commands/plan.md` (workspace-scoped, alongside `/feature`, `/docs`, `/inv`, `/tests`, `/review-gw`).
