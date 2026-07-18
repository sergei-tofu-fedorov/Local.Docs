---
name: web-spike
description: Time-boxed web research for a backend feature (vendor APIs, patterns, libraries) → web-spike.md in the feature folder. Requires the feature folder from /feature plan; not for incident response — use investigate.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## What this skill is

Time-boxed web research that informs the design of a backend feature. Pulls authoritative sources (vendor docs, Microsoft Learn, Martin Fowler, IETF/W3C standards, library docs, well-cited posts by named experts) on best practices, design patterns, vendor APIs, library options, and prior art directly relevant to the feature being planned. Output is a single `web-spike.md` in the feature folder.

`/web-spike` runs **after `/feature plan`** (which scaffolds folder + README) and **before `/plan write`** (which reads `web-spike.md` along with the README to deepen into `overview.md`). It is the research step that bridges the two: questions the user can't answer at the time of `/plan write` should usually have been researched via `/web-spike` first.

Reference shape: the WEB-1469 vendor survey at `Local.Docs/features/WEB-1469-notes/research-attachments-vs-notes-in-visits.md`. `/web-spike` output is similar, consolidated into one `web-spike.md` per feature folder.

## Scope: backend features

`/web-spike` is calibrated for backend feature research in this workspace's repos (`Invoices.Backend`, `Tofu.Invoices.Backend`, `Tofu.Auth.Backend`, `Tofu.Common.Backend`). Typical research domains:

- Field-service / SaaS vendor API surveys (ServiceTitan, Jobber, HCP, Salesforce FS, Dynamics 365 FS, etc.).
- Design / integration patterns (CQRS read-model projection, transactional outbox, saga, bounded-context replication, event sourcing).
- ASP.NET Core / EF Core / MongoDB conventions (idempotency keys, partial indexes, `IOptions<>` patterns, CHECK constraints).
- Auth / identity standards (OAuth, OIDC, Firebase JWT specifics, Tofu.Auth role models).
- gRPC contract evolution rules (proto field reservation, additive vs breaking, csharp_namespace conventions).
- Library / framework choices when ≥2 credible options exist.

For frontend, mobile, or pure documentation work, `/web-spike` is the wrong tool — its question batches and source-quality rules are backend-shaped.

## When to use

Run `/web-spike` when the feature involves any of:

- A net-new design pattern the team hasn't shipped before.
- A vendor API surface that needs survey before committing to a contract shape.
- A library / framework choice with multiple credible options.
- A standard / RFC that constrains the contract (OAuth flow, JWT claim shape, idempotency-key semantics).
- A non-obvious "best practice" the team wants to align with industry convention before committing.

Skip `/web-spike` when:

- The feature is a pure refactor or config change (Trivial tier in `/plan`'s rubric).
- The architectural pattern is already established in this workspace and just needs to be repeated.
- External research has already been done and notes are already in the feature folder — `/web-spike` is for net-new research, not for re-running.

## Slug / Branch Convention

Same as `/feature` and `/plan`:
- `<TASK>` is `WEB-NNNN`, `INVC-NNNN`, `FS-NNNN`, etc.
- Web-spike file lives at `Local.Docs/features/<TASK>/web-spike.md`.
- `/web-spike` refuses to operate without `Local.Docs/features/<TASK>/README.md` — it is not a folder-creating skill. Run `/feature plan <TASK>` first.

If `<TASK>` is omitted, infer from the current branch (`feature/WEB-1234` → `WEB-1234`).

## Operations

| Op | Usage | Description |
|---|---|---|
| **write** | `/web-spike write <TASK> [<topic>]` (or `/web-spike <TASK> [<topic>]`) | Run web research and produce or update `web-spike.md`. Default op. |

Default form is `write`. `/web-spike` has only one op in v1; `check` / `refresh` / `list` are deferred until usage demands them.

If `<topic>` is provided as free text after the task ID, it focuses the research narrowly. Otherwise, `/web-spike` derives 2–4 research questions from the README's `Goal` / `Scope` / `Open questions` sections and asks the user to confirm or refine before fetching anything.

---

## Operation: `write`

### Step 1 — Read the feature folder

1. Best-effort fast-forward pull on `Local.Docs` (same rules as `/feature load`: skip if dirty, on a non-default branch, has unpushed commits; report what was pulled or skipped).
2. Read everything under `Local.Docs/features/<TASK>/`:
   - `README.md` — `Goal`, `Scope`, `Open questions`, `Affected repos`. This sets the research scope.
   - Any existing `web-spike.md` — if present, treat as input; you may be appending or refining.
   - Other `research-*.md` / design notes in the folder for additional context.
3. If `README.md` is missing, abort with: *"No `Local.Docs/features/<TASK>/README.md` found — run `/feature plan <TASK>` first."*

### Step 2 — Define, propose, and get approval for the full question set *(blocking gate)*

This is the most important step in the skill. **No `WebSearch` or `WebFetch` runs before the question set is explicitly approved by the user.** A web-spike with the wrong questions wastes the user's tokens and ends up shaped like a tutorial — confidently irrelevant. Rushing to fetch is the failure mode this gate exists to prevent.

#### 2a — Define the full set

Derive **every** question that matters for this feature, not just the obvious 2–4. Cover, in order:

1. **Primary questions** — the core unknowns the feature can't be designed without. Usually 1–3.
2. **Surface-survey questions** — when a vendor / library / pattern *category* is in scope (e.g., "field-service note APIs", "CQRS projection patterns"), enumerate the entities to be surveyed.
3. **Sub-questions per primary** — what specific axes the answer needs (storage shape? wire format? consistency model? cascade behavior?). These shape the comparison-table columns later.
4. **Implication-anchored questions** — for each design decision the next `/plan write` will need to make, what does the web-spike need to answer to inform it?
5. **Adjacent / follow-up questions** — things that aren't strictly required but are cheap to research while we're already fetching from a source.

Be exhaustive at this step. It is much cheaper to drop a question now than to discover mid-fetch that an axis is missing and have to re-run.

If the user provided a `<topic>` argument, treat it as the **anchor** for the primary question, but still derive the full set around it (sub-questions + survey scope + adjacent topics). The argument focuses the web-spike; it does not replace question definition.

#### 2b — Propose the full set to the user

Present the entire question set in chat, structured for easy editing:

```
## Proposed research questions for <TASK>

**Primary (required):**
1. <question 1>
2. <question 2>

**Surface survey (entities to cover):**
- <vendor / library / pattern A>
- <vendor / library / pattern B>
- <vendor / library / pattern C>

**Sub-questions per primary:**
- For Q1: <axis a>, <axis b>, <axis c>
- For Q2: <axis a>, <axis b>

**Implication-anchored (informs design decisions):**
- <question> → informs <which `/plan` decision>
- <question> → informs <which `/plan` decision>

**Adjacent / cheap to grab:**
- <question>
- <question>

**Estimated source count:** ~<N> URLs to fetch
**Estimated time:** ~<N> minutes of WebFetch
```

Then call `AskUserQuestion` with a single confirmation question, e.g. *"Approve this question set as-is, or refine?"* with options:

- *Approve as-is — start fetching.*
- *Refine — drop, add, reorder, or rephrase questions.*
- *Narrow scope — keep only Primary + Implication-anchored, drop the rest.*
- *Expand scope — add more vendors / patterns to the survey.*

#### 2c — Iterate until approved

If the user picks anything other than *Approve as-is*, refine the set, re-propose. Loop until the user explicitly approves. **Do not infer approval from silence or partial agreement** — wait for an unambiguous signal.

Only after explicit approval, proceed to Step 3.

This gate is non-negotiable. Even when the topic seems obvious, surfacing the full question set tends to expose 1–2 axes the user wanted that you would have missed — that's the whole point.

### Step 3 — Fetch authoritative sources

For each research question, gather sources via `WebSearch` + `WebFetch`. **Follow the source-quality tiers in [`references/output-spec.md`](references/output-spec.md)** (preferred / acceptable-only-when-nothing-better / skip) — a deviation needs a stated reason. For each source, capture **verbatim quotes** for load-bearing claims (never paraphrase a fact) and the URL for citation; flag inline when a quote was paraphrased due to access restrictions.

### Step 4 — Synthesize

Produce `web-spike.md` following the **output template and style rules in [`references/output-spec.md`](references/output-spec.md)**. The load-bearing shape: Findings organised **by question** (not by source), each with verbatim quotes for load-bearing claims; a Sources section where **every source carries a URL**; comparison tables when weighing ≥3 options; and a **mandatory Implications-for-the-design section** that links each finding to a concrete decision the next `/plan write` must make. A web-spike with conclusions but no sources is an opinion, not a spike.

### Step 5 — Write the file

- Path: `Local.Docs/features/<TASK>/web-spike.md`.
- If the file already exists:
  - When the new content extends prior research (different topic), **append** under a new top-level section. Preserve existing sections.
  - When the new content supersedes prior conclusions, summarise the diff and ask the user before overwriting.
- **Never auto-commit.** After writing, print:
  ```
  pwsh Local.Docs/scripts/commit-docs.ps1 -ShortDescription "<TASK> web-spike"
  ```

### Step 6 — Report

After writing:

- Word count + section count + source count.
- Any `Open questions / follow-ups` that survived (decisions that still need product / lead input).
- Suggested next step: `/plan write <TASK>` — the web-spike is now an input to `/plan`, which will read `web-spike.md` in its Step 1 and incorporate findings into `overview.md`.

---

## Conventions

- **Web-heavy by design.** `/web-spike` spends most of its time in `WebSearch` + `WebFetch`. Codebase grep is incidental — the goal is external research, not local exploration.
- **One `web-spike.md` per feature folder.** Multiple research topics for the same feature live as multiple top-level sections within the file, separated by `# <TASK> — Web Spike: <topic>` headings.
- **Never edits anything but `web-spike.md`.** README, overview, `research-*.md` companions are read-only inputs.
- **Sources first, conclusions second.** A web-spike with conclusions but no sources is an opinion, not a web-spike. The Sources section is mandatory even when short.
- **Discipline on staleness.** When citing a fast-moving topic (LLM patterns, recent framework releases, evolving cloud services), include the publication date and flag if >1 year old.
- **Refuses to operate without a feature folder.** `/feature plan <TASK>` is a hard prerequisite, same as `/plan`.

## Notes

- `/web-spike` is the canonical research step in the feature workflow:
  `/feature plan <TASK>` → **`/web-spike <TASK>`** *(when needed)* → `/plan write <TASK>` → `/feature start <TASK>`.
- `/web-spike` is **opt-in**. `/feature plan` does not auto-chain into `/web-spike`. Run it when the feature has unresolved architectural / vendor / library questions; skip for refactors and rote CRUD.
- `/web-spike` output (`web-spike.md`) is read by `/plan write` in its Step 1 alongside `README.md` and other companions. `/plan write` does not re-run web research; it consumes what `/web-spike` captured.
- For production-incident investigations (gcloud logs, Mongo queries, repro scripts), use the `investigate` skill instead. `/web-spike` is for technology / pattern research, not for incident response.
