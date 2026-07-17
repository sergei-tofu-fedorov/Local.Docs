# /impl Skill - Quick Reference

Implements a plan in .NET, **abstractions-first and gated**. Phase 1 writes an abstractions-only design doc (contracts + mermaid class diagrams) for sign-off; Phase 2 writes implementation code **only after you approve**. Tests are deferred to `/tests`.

The defining rule: **no production code until you approve the abstractions.**

## Quick start

```
/impl <TASK>            # Phase 1: write impl-design.md (default op), then gate
/impl design <TASK>     # same as above, explicit
/impl build <TASK>      # Phase 2: implement against the approved design
```

If `<TASK>` is omitted, inferred from the current branch (`feature/WEB-1234` → `WEB-1234`).

## The two phases

1. **design** → `Local.Docs/features/<TASK>/impl-design.md` (shape mirrors `…/WEB-1523-segmentation/implementation/metrics.md`)
   - **`## Decision`** (first) — key locked decisions + rationale; the gate's focal point
   - **`## Code layout`** — ASCII tree listing **every** added/modified class, one-line purpose each (always list all — no "~3 DTOs")
   - Contracts (interfaces, DTOs/records) — signatures only
   - Class skeletons — constructor deps + method signatures, **no bodies**
   - **`## Class diagram`** — mermaid `classDiagram` of static structure (new classes, contracts, usage edges)
   - DI wiring
   - **Stops at a gate.** You review, then approve or request changes.
   - *Optional* **`impl-interaction.md`** (separate file) — mermaid `sequenceDiagram` of the runtime flow, written **only for complex flows** (job ticks, multi-service chains, branchy orchestration). Skipped for linear request→service→repo paths; `impl-design.md` links to it when present.
2. **build** → implementation code in the target repo
   - Fills in the bodies against the approved abstractions
   - Wires DI, runs `dotnet build` (warnings-as-errors must pass)
   - If an abstraction turns out wrong, it stops and updates the doc rather than diverging

## Input

- If `Local.Docs/features/<TASK>/overview.md` exists (from `/plan`), it's consumed as the plan.
- Otherwise `/impl` works from your prompt — `/plan` is not required.

## Tests

- **All tests are deferred** — `/impl` writes none, unit or integration.
- After the build is green, hand off to `/tests` (e.g. `/tests sync`).

## What it doesn't do

- Doesn't write production code before you approve the design.
- Doesn't write tests.
- Doesn't branch, commit, push, or open PRs. Doc commits go through `commit-docs.ps1`.
- Doesn't cross repo boundaries — stays in the target repo (default `Invoices.Backend`).

## Workflow fit

```
/plan <TASK>     →  overview.md (what & why)
/impl <TASK>     →  impl-design.md (abstraction surface)  ──gate──▶  code (build phase)
/tests sync      →  unit/integration coverage
```

## Where the skill lives

`C:/Git/Work/Backend/.claude/commands/impl.md` (workspace-scoped, alongside `/plan`, `/feature`, `/docs`, `/inv`, `/tests`, `/review-gw`).
