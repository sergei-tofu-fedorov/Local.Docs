---
name: impl
description: Turn an agreed plan into working .NET code in two gated phases — first `impl-design.md` (abstractions/signatures only) for sign-off, then the code after explicit approval. Invoke whenever the user wants to implement a feature or ticket in code ("implement WEB-1234", "build this out", "turn the plan into code", "start coding this feature"), especially when an `overview.md` exists. Never writes tests (defer to tests), never commits, branches, or opens PRs.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## What this skill is

`/impl` turns an agreed plan into working .NET code in **two gated phases**:

1. **Design (abstractions first)** — produce `impl-design.md`: the contracts (interfaces, DTOs/records as signatures), class skeletons (method signatures, no bodies), mermaid class diagrams showing the new types and how they're used, file placement, and DI wiring. **No implementation bodies, no behaviour.**
2. **Build** — fill in the implementation in the code repos, **only after the design is explicitly approved.**

The hard rule that defines this skill: **no production code is written until the user signs off on the abstractions.** The design doc is a gate, not a formality.

Tests — unit *and* integration — are **deferred**. `/impl` never writes tests. Once the code lands, point the user to `/tests`.

## Relationship to other skills

- `/plan` produces `overview.md` (the *what* and *why* — data model, endpoints, auth, lifecycle). `/impl` consumes it and produces the *how* (the abstraction surface), then the code.
- If no `overview.md` exists, `/impl` works directly from the user's prompt — it does not require `/plan` to have run.
- `/impl` does not branch, commit, push, or open PRs. Branching is `/feature start`; PRs stay with the user. The `impl-design.md` doc commit defers to `commit-docs.ps1` like every other Local.Docs change.

## Workspace Layout

This skill is registered at the workspace root `C:\Git\Work\Backend\`. The workspace contains independent sibling git repos:

| Folder | Purpose |
|--------|---------|
| `Invoices.Backend/` | BFF — main repo, default target |
| `Tofu.Invoices.Backend/` | Invoices backend service |
| `Tofu.Auth.Backend/` | Auth backend service |
| `Tofu.Common.Backend/` | Shared backend library |

Determine the target repo first:
- If the working directory is **inside** one of the repos, paths are relative to that repo.
- If it is the **workspace root** (`Backend/`), prepend the repo folder to all paths (e.g. `Invoices.Backend/Src/...`).
- Each repo is an **independent git repo** — never cross repo boundaries when grepping, building, or running git.

If the user does not specify a repo and the working directory is the workspace root, default to `Invoices.Backend`.

## Slug / Branch Convention

Same as `/plan` and `/feature`:
- `<TASK>` is `WEB-NNNN`, `INVC-NNNN`, `FS-NNNN`, etc.
- The design doc lives at `Local.Docs/features/<TASK>/impl-design.md`.
- If `<TASK>` is omitted, infer from the current branch (`feature/WEB-1234` → `WEB-1234`). If no branch matches and the user gave a freeform prompt, ask for a `<TASK>` slug before writing the doc (the doc needs a home).

## Operations

| Op | Usage | Description |
|----|-------|-------------|
| **design** | `/impl design <TASK>` (or `/impl <TASK>`) | Phase 1. Produce/refresh `impl-design.md` — abstractions only. Interactive. Default op. |
| **build** | `/impl build <TASK>` | Phase 2. Implement against the approved `impl-design.md`. Refuses if the doc doesn't exist or hasn't been approved. |

`/impl <TASK>` with no verb runs **design**, then — after the user approves in-chat — offers to continue to **build**. It never auto-advances past the gate.

---

## Phase 1 — `design`

### Step 1 — Gather the plan

1. Resolve `<TASK>` (argument → branch → ask).
2. If `Local.Docs/features/<TASK>/overview.md` exists, `cd Local.Docs`, best-effort fast-forward pull (skip if dirty / on a non-default branch / has unpushed commits; report what happened), then read it in full. It is the source of truth for scope, data model, endpoints, auth, and lifecycle.
3. If no `overview.md`, treat `$ARGUMENTS` plus the conversation as the plan. Do **not** invent scope the user didn't state — if the plan is too thin to design against, ask focused questions before writing.

### Step 2 — Anchor against the codebase

For the target repo, grep enough that every type in the design names a real home:
- Where do interfaces, services, repositories, DTOs, controllers, and DI registration live in this repo?
- What are the local conventions: DTO style (`public sealed record`, `init`-only), domain return shape (e.g. `Result<T>` from FluentResults), DI lifetimes (`Scoped` vs `Singleton`), interface placement (Domain ports vs Application services), naming.
- Which **existing** types will the new abstractions touch or depend on? Capture their real paths.

Mirror what exists. Never invent a file path; if a placement is genuinely undecided, write `TBD — confirm placement` and surface it in the report.

### Step 3 — Design the abstraction surface

Define the solution as **pure abstractions, in this order**. The shape mirrors the reference doc `Local.Docs/features/WEB-1523-segmentation/implementation/metrics.md` — read it before writing; it is the calibration target for `## Decision` + `## Code layout`.

1. **Decision** — the key locked decisions, **first**. The architectural shape, where each major piece lives, and the *why* behind every non-obvious pick. One bullet per concrete decision — *"Job class lives at `…/MetricsRefreshJob.cs`"*, *"Three read-only connections, no shared abstraction — wrapping them in `IReadSource<T>` adds nothing"*. This is what the user signs off on at the gate; everything after is supporting detail.
2. **Code layout** — an ASCII file tree of **every** added and modified class/file, each with a one-line `# comment` stating its responsibility. **Always list all classes** — never collapse to a count like "~3 DTOs". Mark modified files distinctly from new ones.
3. **Contracts** — the interfaces and the data shapes (DTOs / records / enums) that cross boundaries. Signatures only.
4. **Class skeletons** — the concrete classes that will implement the contracts, declared with their public/internal method signatures and constructor dependencies. **Bodies elided** (`// implemented in build phase` or `=> throw new NotImplementedException();` placeholder — the doc describes intent in prose, not code).
5. **Wiring** — how the pieces are registered and who resolves whom.
6. **Interaction flow** *(only when the user asks)* — the primary runtime sequence: which class calls which, in what order, across the new types and the stores/services they touch. Goes in a **separate** `impl-interaction.md`, not inline. **Do not produce it by default** — describe the order in one or two prose sentences in `## Decision` and move on; write the diagram only if the user explicitly requests a flow/sequence picture (see Step 4b).

Design rules:
- Depend on abstractions, not concretions — constructor-inject interfaces.
- Keep each contract minimal: only the members callers actually need.
- Name and shape types to match the repo conventions found in Step 2.
- Don't design tests, fixtures, or test doubles — out of scope.

### Step 4 — Write `impl-design.md`

Path: `Local.Docs/features/<TASK>/impl-design.md`. If it already exists, summarize the diff and ask before overwriting (same rule as `/plan`).

Structure (omit any section with no real content — no "Not applicable" headers). It mirrors the reference doc `Local.Docs/features/WEB-1523-segmentation/implementation/metrics.md`:

1. `# <TASK> — <Title> (implementation design)`
2. One-paragraph summary, entity-grounded. State what's being built and the shape of the approach. Add a one-line **scope guardrail** when upstream specs own decisions this doc must not re-litigate (e.g. *"No metric definitions here — those are locked in `analyses/metrics.md`; the spec wins on conflict."*).
3. **Source of plan** — link `overview.md` if consumed, else note "designed from prompt".
4. `## Decision` — **comes first.** The key locked decisions as a bullet list: where each major piece lives + the rationale for non-obvious picks. Close with a line like *"Everything below this section is supporting detail."* This is the gate's focal point — the reader should be able to approve or push back from this section alone.
5. `## Code layout` — an ASCII file tree listing **every** added/modified class and file, each with a one-line `# comment` describing its responsibility. **Always list all classes** — never collapse to a count. Annotate modified files distinctly from new ones (e.g. a trailing `# MODIFIED` or a separate marker). Follow the tree with a short paragraph naming the key seam (which class talks to which, where the boundary is). This section *is* the file-placement record — no separate placement table.
6. `## Contracts` — fenced C#, signatures only. Interfaces first, then DTOs/records/enums. Inline `//` comments for non-obvious members.
7. `## Class skeletons` — fenced C#. Concrete classes with constructor (showing injected dependencies) and method signatures; bodies elided. A one-line prose note per class describing its responsibility.
8. `## Class diagram` — **mermaid `classDiagram`** (required). Show the new interfaces and classes, their members, and the usage edges (static structure). Follow the class-diagram rules in [`references/diagrams-and-pseudocode.md`](references/diagrams-and-pseudocode.md).
9. `## Dependency injection` — the registration lines (`services.AddScoped<IFoo, Foo>()`), with lifetimes and the registration file path. Note any Scrutor assembly-scan that picks it up automatically.
10. `## Open questions` — only if there are unresolved decisions or `TBD` placements.

There is **no `## Tests` section, ever.**

**`## Decision` then `## Code layout` is the fixed opening.** Decision is the locked picks + rationale (what the gate hinges on); Code layout is the exhaustive tree of every class with a one-line purpose each (the build checklist). The contracts, skeletons, and class diagram that follow are the detail behind those two.

**Keep `impl-design.md` lean.** The main doc is the static picture: decisions, layout, contracts, structure. Runtime flow does *not* go inline — it lands in a **separate interaction file** and only when the flow is genuinely complex (see Step 4b). A `sequenceDiagram` in the middle of the design doc bloats it; most readers want the static surface first.

**When an algorithm's shape must be shown**, use structured pseudocode, never runnable C# — house style and example in [`references/diagrams-and-pseudocode.md`](references/diagrams-and-pseudocode.md).

### Step 4b — Interaction file *(only when the user asks)*

Runtime sequencing lives in its own file, **not** inside `impl-design.md`, and is produced **only when the user explicitly asks for a flow / sequence / pipeline diagram**. Default is to skip it — even for a complex flow, describe the order in one or two prose sentences in `## Decision` and move on. Pipelines and runtime flows are opt-in, not automatic: do not draw one unprompted.

**Write `Local.Docs/features/<TASK>/impl-interaction.md` only when the user requests it** — typically for a genuinely complex runtime flow: a multi-step orchestration, a background-job tick with branches and fan-out, a saga / multi-service call chain, or any flow where the *order* and *conditionals* carry the design (e.g. the `MetricsRefreshJob` tick: expired-row pass → daily discovery branch → bounded parallel aggregation across three stores). If you think a flow is complex enough to benefit, *offer* it — don't write it speculatively.

**Skip it** for the common case — a linear `request → controller → service → repository → store` path, simple CRUD, or a pure data/contract change. **Also skip any flow that's standard across the workspace** — the shared CI/CD pipeline (`docker build` → GCR → migrate Job → `kubectl set image` via the `Tofu.GitHubActions` workflow), the Kustomize-overlay deploy, the generic Hangfire recurring-job tick — the team runs these on every repo; name the mechanism in one line and link its canonical doc instead of drawing it. For all of these, a sentence of prose in the Decision section is enough; a sequence diagram adds noise, not signal. When in doubt, skip and ask the user whether the flow warrants one.

When you do write it:
- One `sequenceDiagram` per distinct flow (a second flow gets its own diagram in the same file; never cram two into one).
- Open with a one-line statement of the flow being traced; close with a sentence on anything the diagram can't carry (independent connections, idempotency, error handling).
- Add a link from `impl-design.md`'s `## Code layout` section: *"Runtime flow: see [`impl-interaction.md`](impl-interaction.md)."* — so the design doc points at it without inlining it.
- Follow the interaction-diagram rules in [`references/diagrams-and-pseudocode.md`](references/diagrams-and-pseudocode.md).

### Step 5 — Present the gate

After writing, in chat:
- Summarize the abstraction surface in a few bullets (the contracts introduced, the classes that implement them, the key dependency edges).
- State plainly: **"This is abstractions only — no implementation yet. Review `impl-design.md`. Reply with changes, or approve to start the build."**
- Print the doc-commit command:
  ```
  pwsh Local.Docs/scripts/commit-docs.ps1 -ShortDescription "<TASK> implementation design"
  ```
- **Stop. Do not write any production code.** Iterate on the doc in response to feedback. Only an explicit approval ("approved", "go ahead", "build it", "looks good") opens the gate to Phase 2.

---

## Phase 2 — `build`

Runs only after the design is approved. If invoked as `/impl build <TASK>` directly and no approval is on record, re-read `impl-design.md`, summarize it, and ask the user to confirm before proceeding.

### Step 1 — Re-read the approved design

Read `impl-design.md` and the `overview.md` (if any). The abstractions in the doc are the contract for this phase — implement to them.

### Step 2 — Implement

- Create the contracts and types exactly as designed (file placement per the doc's table).
- Fill in the class bodies. Match the repo conventions confirmed in design (return shapes, error handling, logging, async patterns).
- Wire DI per the doc's Dependency injection section.
- Write code that reads like the surrounding code — match comment density, naming, and idiom of the files you touch.
- **If implementation reveals the abstraction was wrong** (a missing dependency, a contract that can't be satisfied, a shape that doesn't fit): **stop, update `impl-design.md`, and re-confirm the changed surface with the user** before continuing. Do not silently diverge from the approved design.

### Step 3 — Verify the build (not tests)

- Run `dotnet build` for the affected projects/solution **inside the target repo**. `TreatWarningsAsErrors` is on across these repos — warnings fail the build, so the code must be clean.
- Do **not** write or run tests. Tests are deferred.

### Step 4 — Report and hand off

- List the files created and modified, grouped by project.
- Confirm the build is green (or show the errors if not).
- State that **tests were deferred by design** and point to `/tests` (e.g. `/tests sync` to detect the new code and write coverage, or `/tests unit <path>` for a specific file).
- Reminder: branching, committing, pushing, and PRs stay with the user. If on a feature branch under `/feature`, `/feature lint` and `/feature review` are the next steps.

---

## Conventions

- **Abstractions before behaviour, always.** Phase 1 produces interfaces and signatures; Phase 2 produces bodies. Never blur the two.
- **Don't document what's standard across the workspace.** The design doc captures what's *specific or novel* to this feature — not mechanics every backend repo already shares. The CI/CD pipeline (the shared `Tofu.GitHubActions` workflow: `docker build` → GCR → migrate Job → `kubectl set image`), the Kustomize-overlay deploy, and boilerplate Serilog / OpenTelemetry / Hangfire-server wiring are **assumed knowledge** — name the shared mechanism in one line, link its canonical doc if one exists, and spend the doc's space on this feature's own contracts, layout, and decisions. A pipeline-flow diagram for something the team runs on every repo is noise, not signal.
- **No full code blocks in the design doc — use structured pseudocode** (house style + example in [`references/diagrams-and-pseudocode.md`](references/diagrams-and-pseudocode.md)). Class skeletons stay signatures-only (bodies elided); algorithm *shape* is conveyed in a compact, language-neutral block.
- **The gate is real.** No production code before sign-off. When in doubt about whether the user approved, ask.
- **One design doc per task** at `Local.Docs/features/<TASK>/impl-design.md`. Multi-repo work still gets one doc, with file-placement rows tagged by repo.
- **Tests are out of scope** for both phases. `/impl` defers all test work to `/tests`.
- **Never auto-commits, branches, or opens PRs.** Doc commits go through `commit-docs.ps1`; code commits and PRs are the user's.
- **Mirror the codebase.** Discovered conventions (DTO style, DI lifetime, return shapes) win over generic .NET defaults.
- **Anchor every reference** as `` `path/File.cs` `` or `` `File.cs:line` ``. No "see the existing pattern" handwaves.

## Notes

- The design doc is deliberately implementation-free so the user reviews *shape and dependencies* without being distracted by bodies — the cheapest place to catch a wrong abstraction is before any code exists.
- The mermaid `classDiagram` is required because "new classes, contracts, and class usages" are exactly what a reader needs to evaluate the abstraction surface at a glance.
- For the doc-side commit flow, defer to `commit-docs.ps1` (or `/docs commit`) — same as `/plan` and the rest of the doc workflow.
