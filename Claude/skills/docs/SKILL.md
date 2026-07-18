---
name: docs
description: Search, read, update, or create documentation in the Local.Docs repo (Backend/HowTo, Services, features, the timeline TSV). ALWAYS invoke before creating or editing ANY file under Local.Docs, and for "search the docs", "document this", "update the persistence doc", or "what do our docs say about X". Never auto-commits — committing is the explicit `commit` op.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Workspace Layout

This skill lives at the workspace root `C:\Git\Work\Backend\`. The workspace contains several **independent sibling git repositories** (Local.Docs is no longer a submodule):

| Folder | Purpose |
|--------|---------|
| `Invoices.Backend/` | BFF — main repo we work in |
| `Tofu.Invoices.Backend/` | Invoices backend service |
| `Tofu.Auth.Backend/` | Auth backend service |
| `Tofu.Common.Backend/` | Shared backend library |
| `Local.Docs/` | Documentation (sibling repo, **not** a submodule) |
| `Investigations/` | Spikes / proof-of-concept / investigations (see the `investigate` skill) |

All paths in this skill are **relative to the workspace root** (`C:\Git\Work\Backend\`).

## Project Configuration

Detect project from working directory or user hint:

| Folder Name | Project Type | Primary Doc Path | Service Path |
|-------------|--------------|------------------|--------------|
| `Invoices.Backend` (default) | BFF (main) | `Local.Docs/Backend/` | `Local.Docs/Backend/Services/Invoices.Backend/` |
| `Tofu.Auth.Backend` | Auth Service | `Local.Docs/Backend/` | `Local.Docs/Backend/Services/Tofu.Auth/` |
| `Tofu.Invoices.Backend` | Invoices Domain | `Local.Docs/Backend/` | `Local.Docs/Backend/Services/Tofu.Invoices/` |
| `Tofu.Common.Backend` | Shared Library | `Local.Docs/Backend/` | `Local.Docs/Backend/Services/Tofu.Common/` |
| `Android` or `*-android` | Android App | `Local.Docs/Android/` | `Local.Docs/Android/` |
| `IOS` or `*-ios` | iOS App | `Local.Docs/IOS/` | `Local.Docs/IOS/` |

If working directory is the workspace root (`Backend/`), default to `Invoices.Backend` (the BFF / main repo).

### Quick Shortcuts

| Shortcut | Resolves To |
|----------|-------------|
| `@service` | `<PrimaryDocPath>/Services/<ProjectName>/` |
| `@platform` | `<PrimaryDocPath>/` |
| `@howto` | `<PrimaryDocPath>/HowTo/` |
| `@features` | `Local.Docs/features/` |
| `@jobs` | `Local.Docs/features/jobs/` |

## Operations

| Operation | Usage | Description |
|-----------|-------|-------------|
| **search** | `/docs search <query>` | Search docs for topic/keyword |
| **read** | `/docs read <path>` | Read a specific file |
| **update** | `/docs update <path>` | Update existing file |
| **create** | `/docs create <path>` | Create new documentation |
| **api** | `/docs api <feature>` | Generate/update API reference from code |
| **sync** | `/docs sync` | Sync docs with code changes |
| **nav** | `/docs nav` | Show documentation structure |
| **timeline** | `/docs timeline <action>` | Edit Timeline Events.tsv with auto-verification |
| **commit** | `/docs commit <desc>` | Commit documentation changes |
| **pull** | `/docs pull` | Pull latest from remote |
| **context** | `/docs context` | Show project context |

If no operation specified, infer from arguments or ask user.

**Documentation Root**: `Local.Docs/` (sibling folder of the working repo, separate git repository)

---

## Operation: `search`

1. Expand shortcuts in query
2. Search in priority order: Service docs → Platform docs → HowTo → Features → Other
3. Present results grouped by tier (limit 10)

## Operation: `read`

1. Expand shortcuts, resolve path (prepend `Local.Docs/` if relative)
2. Read and display content
3. For `AGENTS.md`/`README.md`, also list directory files

## Operation: `update`

1. First read `Local.Docs/README.md` for rules
2. Read existing file, apply changes following doc principles
3. Show diff, inform user to commit with `/docs commit`

## Operation: `create`

1. Read `Local.Docs/README.md` for rules
2. Suggest location: `@service/` for service-specific, `@howto/` for guides, `@features/` for cross-product
3. Create with clear headings, inform user to commit

## Operation: `api`

Generate or update API reference from source code.

**Usage**: `/docs api <feature>` or `/docs api update <feature>`

**Process**:
1. Find controller + DTOs for feature (under the relevant repo, e.g., `Invoices.Backend/Src/Invoices.Api/`)
2. Extract endpoints (method, route, params, response types)
3. Extract DTO properties, enums, validation attributes
4. For shared DTOs: link to owner's API reference instead of duplicating
5. Generate markdown following `JOBS_API_REFERENCE.md` format
6. Save to `Local.Docs/features/{feature}/{FEATURE}_API_REFERENCE.md`

**Update mode**: Compare code vs existing docs, show discrepancies, apply updates with confirmation.

**DTO Linking Rule**: If DTO is owned by another API (e.g., `InvoiceDto` → Invoices API), link to it rather than documenting fully.

## Operation: `sync`

1. Check git status (in the relevant code repo, e.g., `cd Invoices.Backend && git status`) for modified controllers/DTOs
2. Find affected docs in `Local.Docs/`
3. Show what needs updating, apply with confirmation

## Operation: `nav`

Display `Local.Docs/` structure tree.

## Operation: `context`

Show detected project, service path, shortcuts, search priorities.

## Operation: `timeline`

Edit the timeline events catalogue at `Local.Docs/features/timeline/Timeline Events.tsv`.

**Usage**: `/docs timeline add <event>` or `/docs timeline update <event>`

**TSV File**: `Local.Docs/features/timeline/Timeline Events.tsv`

**Process**:
1. Read the current TSV file
2. Apply the requested changes (add rows, update existing rows, etc.)
3. **Auto-verify TSV format** after every edit by running the bundled checker (column counts, RFC 4180 quoting, strict-CSV parse, per-EntityType tally). It exits non-zero on any failure, so it can gate the follow-up commit:
   ```bash
   python .claude/skills/docs/scripts/verify_timeline_tsv.py "Local.Docs/features/timeline/Timeline Events.tsv"
   ```
   (The path argument is optional — it defaults to that same canonical location when run from the workspace root.)
4. If verification fails, fix the broken rows before proceeding
5. Show summary of changes, inform user to commit with `/docs commit`

**Column structure** (9 columns, tab-separated):
`EntityType | Тип события | Действие | Создается offline | Payload | Текст в job | Текст в invoice | Текст в estimate | Условия показа`

**EntityType values**: `Job` (job/visit events), `Estimate` (estimate events), `Invoice` (invoice events)

**Scoping by EntityType**:
- The first column (`EntityType`) identifies which entity a row belongs to: `Job`, `Estimate`, or `Invoice`
- When user says "for invoice" / "invoice events" → filter/edit only rows where `EntityType = Invoice`
- When user says "for estimate" → filter/edit only rows where `EntityType = Estimate`
- When user says "for job" / "for visit" → filter/edit only rows where `EntityType = Job`
- Always use the `EntityType` column (not the event name) to determine which rows to target

**Rules**:
- Every data row must have exactly the same number of tab-separated columns as the header
- Empty cells must still have their tab separators (trailing tabs for empty trailing columns)
- EntityType for new rows is determined by the event type prefix: `job*`/`visit*` → Job, `estimate*` → Estimate, `invoice*` → Invoice
- **RFC 4180 quoting**: Any Payload cell containing `"` MUST be wrapped in outer `"…"` with every interior `"` escaped as `""`. Example: `"{ ""key"": ""value"" }"`. A bare unescaped `"` — whether inside a quoted field or in an unquoted field — breaks GitHub's TSV parser

**Marking events obsolete**:
- Use the `Условия показа` column (9th) to mark an event as obsolete
- Format: `OBSOLETE → replacementEventName`
- Example: `OBSOLETE → estimateInvoiceCreated`
- Keep the obsolete row in place (do not delete) so the history is preserved
- The replacement event name should match an existing `Тип события` value in the TSV

## Operation: `commit`

Run: `pwsh Local.Docs/scripts/commit-docs.ps1 -ShortDescription "<description>"`

Local.Docs is its own git repo — the commit lands in the Local.Docs repo, not in any backend repo.

## Operation: `pull`

Run: `cd Local.Docs; git pull origin main`

---

## Documentation Rules

**Content Guidelines**:
- Keep docs short, structured, single-topic
- Prefer incremental changes over rewrites
- Don't invent domain knowledge
- Avoid duplication; link to sources of truth
- **Implementation plans must NOT include**: tests, DI registration, MongoDbContext collection/index registration, or other infrastructure boilerplate — these are implied and handled separately

**File Organization**:
- Platform docs: `Local.Docs/Backend/`, `Local.Docs/Android/`, `Local.Docs/IOS/`
- Service docs: `Local.Docs/<Platform>/Services/<ServiceName>/`
- Cross-product: `Local.Docs/features/<feature>/`
- How-to guides: `Local.Docs/<Platform>/HowTo/`

**API Documentation**:
- Document all DTO fields with types
- Link to canonical DTO docs when owned by another API
- Keep JSON examples in sync with field tables

## Notes

- **NEVER commit automatically** - only on explicit `/docs commit`
- Always read `Local.Docs/README.md` before changes
- `AGENTS.md` files are navigation indexes for LLM agents
- Local.Docs is a **separate git repository** (sibling of the backend repos), not a submodule — its commits and pushes are independent of the backend repos
