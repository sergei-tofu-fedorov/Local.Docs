---
name: arch-plan
description: Write architecture.md — a ≤15-min cross-cutting orientation doc for a feature that spans services or adds a framework. Skip for single-repo CRUD/refactors — use /plan instead.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## What this skill is

Produce an **`architecture.md`-style** cross-cutting overview for a feature whose folder already exists in `Local.Docs/features/<TASK>/`. The output is the doc a **new backend developer** reads *first* to orient themselves — service shape, data flow, key boundaries, conventions, where to read next.

**Reading-time budget:** a dev unfamiliar with the feature should be oriented in **≤15 minutes** of reading. If the doc can't be skimmed for shape in 2 minutes and read in full in 15, the structure is wrong — split, defer, or tighten before shipping.

**Reference shape:** `Local.Docs/features/MAIN-1361/architecture.md`.

This is **not** `/plan`. The distinction:
- `/plan` produces `overview.md` — implementation-grade plan with DDL, DTOs, file:line anchors. Audience: the dev about to write code.
- `/arch-plan` produces `architecture.md` — cross-cutting overview with diagrams, conventions, glossary, deep-link map. Audience: a dev who has *never seen this feature before* and needs to get oriented in 15 minutes.

Both can coexist. `architecture.md` is the front door; `overview.md` is the workshop floor.

**Stay high-level.** The default register is conceptual: shape, boundaries, flow, vocabulary. Drop into low-level detail — concrete interface names (`IAnalysis<T>`, `IFooHandler`), method signatures, class hierarchies, DDL, config keys, file:line anchors, library API calls — **only in exceptional cases** where the concept genuinely cannot be conveyed without naming the artifact (e.g., a contract whose *name* is the convention a reader must grep for). When in doubt, describe the role (*"the per-analysis rule, run at write time"*) and leave the symbol for the linked deep-dive. If a reader needs the symbol to navigate code, the Doc map link is the right hop, not a name-drop in the narrative.

## Scope: feature-level cross-cutting overviews

Use `/arch-plan` when:
- The feature spans multiple services, layers, or repos.
- It introduces a framework / pattern / extension point that other developers will need to extend.
- It has non-trivial data flow worth a diagram.
- A new dev assigned to the feature would otherwise have to read 5+ docs to get oriented.

Do **not** use `/arch-plan` for:
- Single-repo CRUD features with no new patterns — `/plan` alone is enough.
- Pure refactors.
- Configuration-only changes.

If unsure, write `/plan` first and revisit `/arch-plan` only if the overview gap becomes real.

## Slug / Branch Convention

Same as `/feature` and `/plan`:
- `<TASK>` is `WEB-NNNN`, `MAIN-NNNN`, etc.
- Doc folder: `Local.Docs/features/<TASK>/`.
- Output path: `Local.Docs/features/<TASK>/architecture.md`.
- If `<TASK>` is omitted, infer from current branch.

## Operations

| Op | Usage | Description |
|---|---|---|
| **write** | `/arch-plan write <TASK>` (or `/arch-plan <TASK>`) | Produce or overwrite `architecture.md`. Interactive. Default op. |
| **review** | `/arch-plan review <TASK>` (or `<path>`) | Audit an existing arch doc against the developer-friendliness checklist. Read-only — outputs critique, does not edit. |

If the user types just `/arch-plan <TASK>` with no verb, treat it as `write`.

Refuses to operate when `Local.Docs/features/<TASK>/README.md` does not exist. Suggest `/feature plan <TASK>` first.

---

## Operation: `write`

### Step 1 — Pull and read the feature folder

1. `cd Local.Docs` and best-effort fast-forward pull (same rules as `/feature load`).
2. Read **everything** under `Local.Docs/features/<TASK>/`:
   - `README.md` — title, `Affected repos`, `Goal`, `Scope`, status.
   - `overview.md` (if present) — the implementation plan. Mine it for entities, services, endpoints, framework names.
   - `web-spike.md` and any `research-*.md` — vendor/pattern choices already made.
   - Any `infrastructure/`, `analyses/`, `investigation/`, `ideas/` subfolders — these become the **Doc map**.
3. If `README.md` is missing, abort and point to `/feature plan <TASK>`.

### Step 2 — Anchor against the codebase

For each repo in `Affected repos`:
- Locate solution layout (`src/<Project>/`, `tests/`).
- Identify entry points (API host, worker, migrations).
- Note new framework concepts the feature introduces — *roles* and *responsibilities* (e.g., "a per-analysis rule that runs at write time"), not specific C# type names. Symbol names are captured for your own anchoring and to inform the deep-dive link in the Doc map, **not** for paste-through into the narrative (see Style rule 10 in the output spec).
- Capture the **delta vs. existing backends** — what's new in this service that a dev familiar with `Invoices.Backend` / `Tofu.Invoices.Backend` won't already know (new persistence tech, new infra dependencies, new patterns).

Never invent file paths. If a claim cannot be anchored, write `TBD — verify <symbol>` and surface in Step 7.

### Step 3 — Identify shape, then assess scope

**3a. Pick the shape archetype.** Naming the shape early tells you which diagrams matter and which sections will carry weight. Pick one (occasionally two):

| Archetype | Signals | Sections that earn their keep |
|---|---|---|
| **Request-response** | Sync HTTP/gRPC, single round-trip per call | Services interaction (compact); skip Data flow if there's nothing async |
| **Pipeline** | Multi-stage transformation, often async (jobs, streams) | Data flow (one diagram per stage); failure-isolation bullets |
| **Event-driven** | Pub/sub, fan-out, eventual consistency | Topology diagram + invariants; idempotency notes |
| **Framework-with-extensions** | Pluggable contract (`IAnalysis<T>`, handlers, strategies) | Extension contract slot table + **mandatory worked example** |
| **Batch / scheduled** | Cron-driven, daily/hourly cadence | Per-cadence diagrams; trigger conditions |

A feature can be more than one (e.g., MAIN-1361 is *framework-with-extensions* + *pipeline*). Surface the chosen archetype(s) implicitly through section emphasis — don't write "this is a pipeline" in the doc.

**3b. Score and bucket.** Size the doc. Score, then bucket. **Internal — don't surface.**

| Signal | +1 each |
|---|---|
| Touches more than one service / deployment | +1 |
| Introduces a new persistence store (BigQuery, new DB, new bus) | +1 per store |
| Introduces a framework / pluggable extension point | +2 |
| Has multi-stage or async data flow worth diagramming | +1 |
| Introduces new operational concerns (cron jobs, retries, quotas, IAM) | +1 |
| Has cross-service boundary rules (who-writes-what, who-reads-what) | +1 |
| Adds vocabulary that won't be obvious to other devs | +1 |
| Has deferred / out-of-v1 follow-ons worth flagging | +1 |

Bucket:

| Score | Tier | Doc shape |
|---|---|---|
| 0–2 | **Light** | TL;DR + Getting started + one diagram + Doc map. ~400–800 words. Skip framework / boundaries if no real content. |
| 3–5 | **Standard** | All core sections (TL;DR, Getting started, Implementation approach, Services interaction, Data flow, Data structures, Doc map). One worked example if a framework exists. ~1000–2000 words. |
| 6+ | **Comprehensive** | Full MAIN-1361 treatment — every section, multiple diagrams, framework worked example, conventions & glossary, boundary invariants. ~2000–3500 words. |

### Steps 4–5 — Map the gaps, ask, and generate

**Read [`references/output-spec.md`](references/output-spec.md) in full before asking questions or writing.** It holds the section-by-section table (which sections are Always vs Only-if and what each contains), the fixed section ordering, the style rules (jargon, ASCII diagrams, stack delta, anchor discipline, high-level register), and the question-tailoring guidance. Deviations need a reason.

### Step 6 — Write the file

- Path: `Local.Docs/features/<TASK>/architecture.md`.
- If the file exists, summarize the diff before overwriting and ask the user. Offer merge-via-chat as a fallback.
- **Never auto-commit.** Print:
  ```
  pwsh Local.Docs/scripts/commit-docs.ps1 -ShortDescription "<TASK> architecture"
  ```

### Step 7 — Report

After writing, print:
- Word count + section count.
- Tier bucket (Light / Standard / Comprehensive).
- Any `TBD — verify` markers left.
- Any open questions punted to product or lead.
- The commit command above.
- Suggestion: run `/arch-plan review <TASK>` later if the doc ages or other devs find friction.

---

## Operation: `review`

Read-only audit against the developer-friendliness checklist. Useful before sharing the doc with a new dev, or after the codebase has drifted.

1. Read `Local.Docs/features/<TASK>/architecture.md` (or the path the user supplied).
2. Score against the checklist in [`references/output-spec.md`](references/output-spec.md) (section "Review checklist"). **Surface gaps as a prioritized list** (biggest gaps first); do not edit the doc.
3. Output a critique modeled on the one we did for MAIN-1361 — organized by category, with concrete suggestions. Offer to apply the fixes via `write` if the user wants.

---

## Conventions

- **One `architecture.md` per feature folder.** Multi-repo features still get one doc — repo-specific details live in sub-sections or in `overview.md`.
- **Never edits anything but `architecture.md`.** README, research files, overview.md are inputs only.
- **Never auto-commits.**
- **Refuses to operate without a feature folder.** `/feature plan <TASK>` is a hard prerequisite.
- **Architecture > implementation.** When in doubt about whether something belongs in `architecture.md` or `overview.md`: if it answers *"how is this shaped?"* it belongs here; if it answers *"how do I build it?"* it belongs in `overview.md`.

## Notes

- This skill does not branch, build, lint, or open PRs. Pairs naturally with `/plan` (deeper implementation plan) and `/feature` (lifecycle ops). PR creation is always manual.
- For the doc-side commit flow, defer to `Local.Docs/scripts/commit-docs.ps1`.
- The MAIN-1361 reference is the **Comprehensive**-tier calibration target. For Light and Standard, calibrate against the word-count and section-set bands in Step 3.
