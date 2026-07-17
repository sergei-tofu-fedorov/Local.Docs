# /arch-plan output spec — section table, ordering, style rules, review checklist

**Contents:** Gap-mapping table (section → tier → content) · Question tailoring · Section ordering · Style rules · Review checklist (for the `review` op)

Read this file in full before asking the user questions or writing `architecture.md` (Steps 4–5 of the `write` op). The `review` op scores against the checklist at the bottom.

## Map the gaps (Step 4)

Architecture doc sections, by tier:

| Section | Always / Only if | Source / question |
|---|---|---|
| Title | Always | `# <TASK> — <Title>`. No audience callout, no "this doc covers…" preamble — the section structure speaks for itself. |
| TL;DR | Always | 1–2 paragraphs. What the service does, top-level shape, what ships in v1. **Repo location goes here as a one-clause aside** (e.g., *"Lives in `Tofu.AI.Backend`; bootstrap-only today"*) — not in a dedicated section. No jargon without inline definition. |
| Key decisions | Always (Standard+) | The **highest-leverage** section. Lists the foundational choices that the rest of the design depends on — *which* services, *which* persistence stores, *which* external providers, *which* deployment shape. Each decision gets a **one-line rationale** (the constraint or trade-off that made it the pick) OR a link to the deep-dive doc that justifies it — not both, not a paragraph. Format: short bulleted list or 3-column table (`Decision | Pick | Why / where justified`). Examples: *"Persistence: BigQuery — columnar analytics + native CDC ingestion (`infrastructure/storage.md` § Q2)."* / *"Deployment: API + Worker split — failure isolation between HTTP and Hangfire (`infrastructure/service.md` § Decision)."* If a decision is still open, mark it `TBD` and link to the open question. Do **not** restate framework-internal shapes (slot tables, contract interfaces) here — those belong in Implementation approach further down. |
| Code layout | Only if the source-folder structure encodes architectural intent (framework module, layer separation, etc.); placed near the end, just before Doc map | Pure "where the framework lives in source." A compact top-1-or-2-level tree of `src/`, annotated only where the folder *does* something architectural (e.g. *"`Analyses/` — framework module; one folder per analysis"*). No repo-location prose (that's a TL;DR clause), no dependency lists (those live in Key decisions), no build/run/test commands (those live in `README.md` / `CLAUDE.md`). One link to the full tree in `service.md` / equivalent. If the source structure is unremarkable, **drop this section entirely**. |
| Implementation approach | Always | The shape of the design **conceptually**. If a framework exists, describe the extension contract as a slot table — what each slot *does*, what v1 fills it with. **Do not** name the concrete C# interfaces (`IAnalysis<T>`, `IFooHandler`, etc.), method signatures, or class hierarchies in the narrative — those are implementation detail and belong in the framework-contract spec linked from the Doc map. State v1 scope explicitly. |
| Services interaction | Standard+ | One ASCII diagram showing services, stores, and external dependencies with arrows for who-talks-to-whom. Follow with a `Boundary rules:` bulleted list — who-writes-what, who-reads-what, hardcoded invariants. |
| Data flow | Standard+ | One ASCII diagram per independent flow (e.g., write path, read path). Annotate end-to-end latency and any non-obvious triggers (hash drift, TTL, retry policy). |
| Data structures at a glance | Only if new persistence schemas | Compact ASCII / table summary — not full DDL. Defer DDL to `infrastructure/storage.md` or `overview.md`. |
| Conventions & glossary | Comprehensive (only if vocabulary is dense) | Define jargon used in the doc (subject keys, layer names, hash drift, signal-collector, etc.). Codify naming patterns (`account_<type>`, `Analyze<T>`, etc.). |
| Extend the framework | Only if the feature introduces a pluggable extension point | A worked example walking through "how to add a second `<thing>`" in 4–6 numbered steps, each pointing at the file/contract a dev would touch. |
| Doc map | Always | Table: `Doc | Covers | State`. One row per child doc. Standardize State to `Draft / In-flight / Locked / Blocked-on-PM / Living`. Close with a one-line pointer to where substantive design questions should be raised. |

For each gap, ask the user via `AskUserQuestion`. Batch related questions (max 4 per call).

Tailor the question set:
- **Framework feature** — ask for the extension contract slots (interface name, what's pluggable, what's fixed).
- **Multi-store feature** — ask for the boundary invariants (who writes, who reads, what's source of truth).
- **Async / job-driven** — ask for cadence per layer, failure isolation, idempotency.

## Generate `architecture.md` (Step 5)

Match the **exact** section ordering and style of the MAIN-1361 reference (`Local.Docs/features/MAIN-1361/architecture.md`).

**Section ordering (when present):** the **highest-leverage** section is `## Key decisions` — the foundational service / store / provider / deployment choices that the rest of the design depends on. It leads the body. Then come the three "shape" sections (**Services interaction**, **Data flow**, **Data structures**) that answer "what shape is this system?" visually. Framework contracts, conventions, and getting-started chores follow.

1. `# <TASK> — Architecture & implementation overview` *(always)*
2. `## TL;DR` *(always)* — goes straight in. No audience blockquote, no "this doc covers…" preamble. Headings + the Doc map at the bottom carry the navigation; explanatory intros are noise.
3. `## Key decisions` *(always for Standard+)* — **leads the body**. The foundational choices: which services, which stores, which providers, which deployment shape. Each decision = one-line rationale OR a link to the deep-dive doc, never both. Bulleted list or a compact 3-column table. No restating framework internals (slot tables go later in Implementation approach).
4. `## Services interaction` *(Standard+; ASCII diagram + Boundary rules bullets)* — who talks to whom, what's the writer, what's the reader, what crosses the cluster boundary. Operationalises the decisions above.
5. `## Data flow` *(Standard+; one or more ASCII diagrams)* — write path(s), read path(s). Annotate triggers, latency, failure isolation.
6. `## Data structures at a glance` *(only if new schemas)* — compact summary, not full DDL. Tables/collections, primary keys, partitioning, the one or two clustering choices that matter. Defer column lists and constraints to `infrastructure/storage.md` or `overview.md`.
7. `## Implementation approach` *(always; with `### <Framework name>` and `### v1 scope` sub-sections when applicable)* — comes **after** the shape diagrams, because the framework only makes sense once the reader knows what flows through it.
8. `## Extend the framework` *(only if framework exists; worked example)*
9. `## Conventions & glossary` *(Comprehensive only)*
10. `## Code layout` *(only if the source structure encodes architectural intent — framework module, layer separation; otherwise omit)* — pure "where the framework lives in source." Compact tree + link to the full tree in the deeper spec. No repo-location prose (TL;DR), no dependency listing (Key decisions), no build/run/test commands (README/CLAUDE.md). If the source layout is unremarkable, **drop this section entirely** — don't keep it as a placeholder.
11. `## Doc map` *(always)*

**No placeholder sections.** Drop, don't stub.

## Style rules

1. **Define jargon on first use, inline.** *"`input_hash` — `SHA256(canonicalised payload + prompt_version + model_id)`"* — not *"see glossary"*.
2. **ASCII diagrams over Mermaid** for in-repo readability. Use Mermaid only if the diagram won't render legibly in ASCII (>~15 nodes, dense crossings) — note this in the diagram caption. If a dedicated diagram skill is installed (e.g., `design-doc-mermaid`), delegate complex diagrams to it rather than hand-rolling Mermaid here.
3. **Stack delta, not stack listing.** Don't re-list Serilog / OpenTelemetry / standard .NET tooling. List only what's *new* relative to the other workspace backends.
4. **Every cross-link goes to a section anchor** — `[`storage.md`](infrastructure/storage.md) § Structure`, not just `[`storage.md`](infrastructure/storage.md)`. The reader should land on the exact subsection.
5. **Doc map state column is a closed vocabulary.** `Draft / In-flight / Locked / Blocked-on-PM / Living`. No free text like `—` or `Awaiting`.
6. **Boundary rules go below the services diagram, not inside it.** Diagrams show *what talks to what*; bullets state the invariants.
7. **TL;DR ≤ 2 paragraphs.** If it spills into 3, split the doc.
8. **Worked example for framework features is mandatory.** A framework with no concrete extension walk-through is unverified. Even 10 lines of pseudocode beats prose.
9. **Anchor file paths but not line numbers.** Architecture docs outlive line numbers. `src/Analyses/Analyses.Domain/<NewType>/` is anchored enough; `Foo.cs:42` is for `overview.md`.
10. **Stay high-level by default; drop into low-level detail only in exceptional cases.** Architecture explains *what* a contract does and what each slot means — e.g., "every analysis registers via a 6-slot contract: type, payload, emit, rule, tiers, score range." Concrete interface names (`IAnalysis<T>`, `IFooHandler`), method signatures, class hierarchies, DDL, config keys, library API calls, and file:line anchors are implementation detail — they belong in the framework-contract spec or `overview.md`, linked from the Doc map. Same rule applies to worked examples: pseudocode beats real interface names when the goal is teaching the shape. Exception test: name the symbol only if (a) the *name itself* is the convention the reader must grep for, or (b) the concept cannot be conveyed without it. Otherwise describe the role, link the deep-dive, and move on.
11. **One language per document.** Match what's already in the feature folder.

## Review checklist (for the `review` op)

Each item = pass / partial / fail:

- **Architectural ground-truth** (toolchain belongs in `README.md` / `CLAUDE.md`)
  - Repo location stated as a clause in TL;DR (not in a dedicated section).
  - **Key decisions** section present, with each foundational pick + one-line rationale or link to deep-dive.
  - **Code layout** section present *only if* the source structure encodes architectural intent (framework module, layer separation); otherwise correctly omitted, not stubbed.
  - **Penalize** any section that includes build/run/test commands, unit/integration test setup, local-dev tooling, or stack-delta bullets that duplicate Key decisions — that's chore content or redundancy, not architecture.
- **Operational ground-truth**
  - Environment matrix (dev/test/prod project IDs, dataset names) — present or linked.
  - Failure modes / retry policy — present or linked.
  - Quotas / SLOs / cost ceilings — present or linked.
- **Conventions & glossary**
  - Jargon defined on first use OR a glossary section exists.
  - Naming patterns codified, not just exemplified.
- **Reader experience**
  - TL;DR ≤ 2 paragraphs.
  - At least one ASCII diagram.
  - Doc map present.
  - Doc map State column uses closed vocabulary.
  - Cross-links target section anchors, not bare files.
- **Framework features only** (skip if no framework)
  - Extension contract documented as a slot table.
  - Worked example for adding a second instance.
