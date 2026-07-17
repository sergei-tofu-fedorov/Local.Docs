# /plan output spec — gap mapping, section ordering, style rules

**Contents:** Gap-mapping table (section → Always/Only-if → source) · Calibration by tier · Question batching · Section ordering · Style rules (anchoring, DDL, migrations, DTOs, auth matrix, lifecycle, inline rationale)

Read this file in full before asking the user questions or writing `overview.md` (Steps 4–5 of the `write` op).

## Map the gaps (Step 4)

The `overview.md` shape needs answers across roughly these sections. Some come straight from the README/research; others must be asked.

Sections marked **Always** are produced for every feature. Sections marked **Only if** are produced *only* when they have real content — never as placeholders saying "Not applicable" or "None".

| Section | Always / Only if | Source / question |
|---|---|---|
| Title + 1-paragraph summary | Always | README title + the goal paragraph, rewritten to be entity-grounded ("notes attached to **clients** and **visits** so that office staff and assigned workers …"), not abstract. |
| Related ClickUp IDs | Always | README header. Ask for BE / FE / QA / iOS sub-tickets if absent. |
| Scope: In / Out | Always | README's `In scope` / `Out of scope` lists, copied verbatim. Add anything from research that the user has decided to defer. |
| Pricing tiers | Only if there is plan-tier gating, OR the decision is still pending (then title `Open blocker`) | Ask: universal across plans, or gated? If gated, which? Whether existing data is preserved on downgrade. If universal and no decision is pending, omit. |
| High-level approach | Always | **Ask the user which architectural shape they're committing to** when research hasn't already pinned it down. Trade-off depth scales with the complexity tier from Step 3: **Trivial** → 1–3 sentences, no comparison, trade-off bullets only if a real alternative was rejected (capped at one line each); **Small** → 2–4 trade-off bullets, no comparison table unless ≥3 alternatives; **Medium** → 3–5 bullets + small comparison table where useful; **Large** → full WEB-1469-style treatment with bullets + comparison table. Never pad: a refactor where the chosen approach is obvious gets one sentence, not five. |
| Data model | Only if new tables / collections / columns are introduced | Derived from the chosen shape + entity grepping. For each new table/collection: full column list with type, nullability, CHECK constraints, indexes (with rationale: full vs partial, composite key order), FK behavior (cascade / restrict / set null), and the PowerShell `dotnet ef migrations add` command (under `### Migration`). If purely a code/config refactor, omit the whole section. |
| Domain integration | Only if entities, EF configurations, repositories, or domain events are touched | Mirror existing entity conventions discovered in Step 2. For each entity touched: new collection nav property, internal/public method signatures, `*DomainEvent` factories, `*EventType` enum additions, EF configuration file location, repository interface + DI registration, loading-strategy paragraph (eager / lazy / direct). For configuration-only changes, this section may degenerate to just the configuration class + DI registration sub-sections — fine; still include them under this heading. |
| Endpoints | Only if HTTP / gRPC routes are added or changed | List every route the feature exposes, grouped by controller. Ask the user only if research didn't already pin verbs and shapes. If no new routes and no shape changes, omit the whole section. |
| DTOs *(sub-section of Endpoints)* | Only if there are new DTOs or DTO field changes | Full C# code, real conventions: `public sealed record`, `public required`, `init`-only fields, optional `?` for nullable. Inline `//` comments for fields whose intent isn't obvious from the name. |
| Validation and errors *(sub-section of Endpoints)* | Only if non-trivial rules apply | Standard set: empty/whitespace after trim, length cap, missing required field, immutable-field PATCH attempts, `EntityNotFoundException` middleware behavior, author-only edit, moderation rules. Adapt to the feature's actual rules. |
| Authorization | Only if permissions, roles, or access semantics change | Ask: which permission keys (mirror `PermissionKeys.<Resource>` style), which roles get which keys by default, what role-action matrix applies. Build a role × action matrix table. If access semantics are identical to today, omit and mention briefly in the high-level approach. |
| Lifecycle | Only if entity lifecycle is introduced or changed (deletion cascade, archive, status transitions, ownership change, cross-store orphan handling) | Ask: behavior on parent-deleted, parent-archived, parent-status-change, ownership-change. Build a 2-column `Trigger → Behaviour` table. Pure refactors omit. Configuration-only features may include a tiny lifecycle table covering "config changed at runtime" / "key added or removed" — but only if the answer is non-obvious. |
| Docs to update | Only if there are real reference docs to refresh | Fixed list: `Backend/Api/<Resource>_API_REFERENCE.md` per resource the feature exposes. If endpoint contracts are unchanged and no public surface shifts, omit. |

**Skip:** `/plan` does not produce a `## Tests` section. Tests are designed and written via `/tests` once implementation is underway.

## Calibration by tier

Section set is driven by the complexity tier from Step 3:

- **Trivial** (score 0–1, e.g. INVC-3608 config refactor) → Title + Summary + Related IDs + Scope + 1–3-sentence High-level approach + a slim Domain integration section. ~300–600 words total.
- **Small** (score 2–4) → above + Endpoints (or Data model) for the one new piece. ~600–1200 words.
- **Medium** (score 5–8) → most sections, condensed. ~1200–2500 words.
- **Large** (score 9+, e.g. WEB-1469) → full WEB-1469 treatment. ~2500–4500 words.

Underspecifying a CRUD feature is a smell; padding a refactor with "Not applicable" headers or 5-bullet trade-offs against straw-man alternatives is also a smell. Match the depth to the tier.

## Question batching

For each gap, ask the user via `AskUserQuestion`. **Batch** related questions into single calls (max 4 questions per call); never ask one-at-a-time when 3 questions can fit on one screen.

Tailor the question set to the feature's shape:
- **CRUD over a new entity** — heavy on data model, DTOs, lifecycle.
- **Workflow / state-machine change** — add transitions table; ask for invariants and forbidden transitions.
- **gRPC contract change** — ask producer-vs-consumer rollout order; capture proto field numbering; flag breaking-vs-additive.
- **Cross-store reference** — ask the orphan-handling story (cascade, archive, leave dangling) explicitly; this is where `/feature review`'s breaking-change scan will look.

## Generate `overview.md` (Step 5)

Match the **exact** section headings, table column conventions, and code-block style of the WEB-1469 reference (`Local.Docs/features/WEB-1469-notes/overview.md`). Specific rules below; deviations need a reason.

**Section ordering (when present):** the order below is fixed. Every section is **conditional** — include only those that have real content for this feature; omit anything that would otherwise read "Not applicable" / "None" / "No change".

1. `# <TASK> — <Title>` *(always)*
2. 1-paragraph summary, entity-grounded *(always)*
3. "Related ClickUp tasks: …" — flat link list *(always; at minimum the initiative ticket)*
4. `## Scope` — `**In scope**` / `**Out of scope**` bulleted *(always)*
5. `## Pricing tiers` *(only if the feature has plan-tier gating, or if a product decision is still pending — then title it `## Open blocker`)*
6. `## High-level approach` *(always; chosen model + trade-offs against alternatives + a small comparison table where useful)*
7. `## Data model` — per-table sub-sections with column tables *(only if new tables/collections/columns are introduced)*
8. `### Migration` — fenced PowerShell *(only if a real EF or Mongo migration is required; nest under `## Data model`)*
9. `## Domain integration` *(only if domain entities, EF configurations, repositories, or domain events are touched; include `### Repositories`, `### Loading strategy` sub-sections only when they apply)*
10. `## Endpoints` — fenced route block + `### DTOs` + per-endpoint algorithm sub-sections + `### Validation and errors` *(only if HTTP/gRPC routes are added or changed; sub-sections individually conditional — `### DTOs` only if there are new DTOs, `### Validation and errors` only if there are non-trivial rules)*
11. `## Authorization` — permission keys block + role-action matrix *(only if permissions, roles, or access semantics change; if behaviour is identical to today, omit and say so in the high-level approach)*
12. `## Lifecycle` — 2-column trigger × behaviour table *(only if the feature introduces entity lifecycle that needs documenting — deletion cascades, archival, status transitions, ownership change, cross-store orphan behaviour. Pure refactors with no entity lifecycle omit this entirely)*
13. `## Docs to Update` *(only if there are real `Backend/Api/*_API_REFERENCE.md` or other docs to refresh; if endpoint contracts are unchanged, omit)*

**No placeholder sections.** Writing a section header followed by *"Not applicable"*, *"None"*, or *"No change"* is a smell — drop the section. Pure refactors and configuration-only features will legitimately have only sections 1–6 plus 9 (or just the relevant slice of 9). That is correct, not under-specified.

**No `## Tests` section, ever.** Tests are out of scope for `/plan`. If the reference example contains one, omit it from the generated output.

## Style rules (enforced in output)

1. **Anchor every code reference.** Use `` `Src/Path/File.cs` `` for paths, `` `File.cs:73` `` for path+line, `` `File.cs:73, 114` `` for multiple lines in the same file. Bare phrases like "see the existing pattern" do not survive review.
2. **Mirror existing patterns explicitly.** Write *"Three `internal` methods mirroring the `UpdateAttachments` shape (which returns `Result<List<JobDomainEvent>>` from FluentResults — see `Visit.cs:73, 114`)"* — not *"follow the existing pattern"*.
3. **DDL tables use 3 columns:** `Column | Type | Notes`. Type column carries nullability inline (`uuid NOT NULL`, `text NULL`). Notes column carries CHECK constraints, FK targets + cascade behavior, and "denormalised from X" callouts.
4. **Indexes after the column table**, as a bulleted list. Each entry: index expression + rationale (which read path it covers). Mark partial indexes with `WHERE …`.
5. **Migration commands** in fenced PowerShell with backtick line continuations:
   ```powershell
   dotnet ef migrations add <TICKET>_<Description> `
       -c <DbContext> `
       -p "<Repo>\Src\<Project>" `
       -s "<Repo>\Src\<ApiProject>" `
       -o Migrations
   ```
6. **DTOs** in fenced C#: `public sealed record`, `public required`, `init`-only by default, `?` for nullable. Inline `// comment` for non-obvious intent. Always reference real types from the existing project where possible (`PageDto<T>` from `Src/Invoices.Api/Models/PageDto.cs`).
7. **Authorization matrix** is a single table with columns: `Action | Admin/Manager (Web) | Worker (Worker app, …) | Client | …`. Cells: `Yes` / `No` / `Yes if assignee` / dash. Filter conditions go in the cell (e.g., `Yes if assignee`).
8. **Lifecycle table** has 2 columns: `Trigger | Behaviour`. Always cover: parent-deleted, parent-archived, related-state-change, ownership-change. Include cross-store reference behavior explicitly.
9. **CHECK constraints in the Notes column**, not in prose. They're part of the schema, not commentary.
10. **Justify non-obvious choices inline, in one short clause.** When a decision could reasonably go another way and the reader will wonder *why this and not that*, append a brief rationale to the sentence that records the choice — *not* a separate paragraph, *not* a comparison block (those belong in `## High-level approach` for Medium+ features). The clause should answer "why not the obvious alternative?" in 5–20 words. Examples:
    - *"Inject `IOptions<OwnerOnlyProductsOptions>` directly — no existing product-related service is a natural home, and a new service just to expose options is over-abstraction."*
    - *"`ValueGeneratedNever` on `Id` so the caller can supply it via `Idempotency-Key` for optimistic UI."*
    - *"Default schema set in `OnModelCreating` rather than per-entity attribute — keeps the EF configurations free of `[Table(Schema=…)]` boilerplate."*
    - *"`smallint` for the visibility enum, not `text`, because the value space is closed and we want index-friendly equality."*

    What counts as non-obvious: choosing one of N idiomatic patterns when both exist in the codebase; opting *out* of an obvious pattern (e.g. not using `IOptionsMonitor`); a knob that looks like a default but isn't (`ValueGeneratedNever`, `OnDelete(DeleteBehavior.Restrict)` over the EF default cascade, `Singleton` over `Scoped`); a name that breaks naming convention for a reason. What is obvious and needs no rationale: standard CRUD shapes, `public sealed record` for DTOs, `[Required]` on a non-nullable field, file-path conventions that already exist.

    The rationale lives **next to the decision**, not in a footnote. If the reader has to scroll to find why, the placement is wrong.
