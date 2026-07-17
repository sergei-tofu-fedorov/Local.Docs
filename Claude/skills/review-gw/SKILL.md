---
name: review-gw
description: Review a PR (or local branch diff) against Local.Docs how-to guides and architecture patterns. Invoke on /review-gw <PR#> and from /feature review (--branch mode). Runs gh inside the target repo.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Workspace Layout

This skill is registered at the workspace root `C:\Git\Work\Backend\`. The workspace contains independent sibling git repos:

- `Invoices.Backend/` — BFF, **default** target for PR reviews (main repo)
- `Tofu.Invoices.Backend/`, `Tofu.Auth.Backend/`, `Tofu.Common.Backend/` — backend services / shared lib
- `Local.Docs/` — documentation (separate git repo, **not** a submodule), referenced by all backend repos

When invoked:
- A PR number always belongs to a single repo. Determine the target repo from the user (e.g., `--repo Tofu.Auth.Backend`) or from current working directory. Default to `Invoices.Backend` if unspecified.
- All `gh` commands must run inside the target repo's folder so `gh` picks up the correct GitHub remote.
- All how-to references resolve into `Local.Docs/...` at the workspace root (sibling folder), not inside the target repo.

## Overview

| Operation | Usage | Description |
|-----------|-------|-------------|
| **pr** | `/review-gw <PR#>` | Full PR review (default, runs against `Invoices.Backend`) |
| **pr** | `/review-gw <PR#> --repo <name>` | Run against a specific backend repo |
| **pr** | `/review-gw <PR#> --basic` | How-to + best practices only |
| **pr** | `/review-gw <PR#> --file <path>` | Review specific file in PR |
| **pr** | `/review-gw <PR#> --gh` | Output in GitHub markdown |
| **pr** | `/review-gw <PR#> --verbose` | Detailed output with code examples |

If no PR number specified, show usage help.

## Severity Levels

| Level | Icon | Criteria |
|-------|------|----------|
| **Critical** | :red_circle: | Security vulnerabilities, data loss risks, breaking API changes |
| **Major** | :orange_circle: | Architecture violations, missing tests for critical paths |
| **Minor** | :yellow_circle: | Minor how-to deviations, error handling gaps |
| **Suggestion** | :green_circle: | Optimizations, readability improvements, nice-to-haves |
| **Style** | :blue_circle: | Code style, formatting, naming conventions, missing newlines, XML docs |

**Note:** Style issues are lowest priority and should NOT block merge.

## How-To Mapping

Map changed files to relevant Local.Docs guides. All paths relative to workspace root (`Local.Docs/...` is a sibling folder).

### HowTo Guides (`Local.Docs/Backend/HowTo/`)

| File Pattern | Guides |
|--------------|--------|
| `*Controller.cs` | `Local.Docs/Backend/HowTo/Architecture.md` (thin controllers, layers), `Local.Docs/Backend/HowTo/Authorization.md` (permissions, roles), `Local.Docs/Backend/HowTo/CodeStyle.md` (controllers section) |
| `*Service.cs` | `Local.Docs/Backend/HowTo/Architecture.md` (layers, validation), `Local.Docs/Backend/HowTo/CodeStyle.md` (mapping methods) |
| `*Repository.cs`, `*MongoDb*` | `Local.Docs/Backend/HowTo/Transactions.md` (MongoDB transactions), `Local.Docs/Backend/Persistence.md` (shared template) |
| `*Tests.cs`, `*Tests/*` | `Local.Docs/Backend/HowTo/CodeStyle.md` (unit test patterns), `Local.Docs/Backend/HowTo/IntegrationTests.md` (fixtures, mocks, structure) |
| `*Dto.cs`, `*Request.cs`, `*Response.cs` | `Local.Docs/Backend/HowTo/Architecture.md` (DTOs, enums, validation), `Local.Docs/Backend/HowTo/CodeStyle.md` (enums, DTOs, mapping) |
| `*Email*`, `*EmailService*` | `Local.Docs/Backend/HowTo/EmailSending.md` (providers, templates, fallback) |
| `*OperationHandler*`, `*Worker*` | `Local.Docs/Backend/HowTo/UnitOfWork.md` (outbox, domain events), `Local.Docs/Backend/HowTo/Transactions.md` |
| `*EventType*`, `*DomainEvent*`, `*Timeline*`, `*Mapper.cs` (with EventType changes) | `Local.Docs/features/timeline/Timeline Events.tsv` (event catalogue) |

### Service-Specific Docs (`Local.Docs/Backend/Services/Invoices.Backend/`)

| File Pattern | Guides |
|--------------|--------|
| `*Controller.cs`, `*.Api/*` | `Local.Docs/Backend/Services/Invoices.Backend/CodeStyle.md` (DTO validation, enum serialization) |
| `*Repository.cs`, `*MongoDb*` | `Local.Docs/Backend/Services/Invoices.Backend/Persistence.md` (collections, relations) |
| `Jobs.*`, `*Job*.cs` | `Local.Docs/Backend/Services/Invoices.Backend/Jobs-Application-Services.md` (command handlers, cross-BC orchestration) |
| `*Account*`, `*User*` | `Local.Docs/Backend/Services/Invoices.Backend/Accounts.md`, `Local.Docs/Backend/Services/Invoices.Backend/Users.md` |

For PRs in other backend repos (`Tofu.Auth.Backend`, `Tofu.Invoices.Backend`, `Tofu.Common.Backend`), substitute the matching service-specific docs folder (e.g., `Local.Docs/Backend/Services/Tofu.Auth/`).

## Execution Flow

### 1. Parse Arguments

- Extract PR number (required)
- Detect flags: `--basic`, `--gh`, `--verbose`, `--file <path>`, `--repo <name>`
- Default: full analysis, console output, standard verbosity, repo = `Invoices.Backend`

### 2. Fetch PR Information

Run from inside the target repo so `gh` resolves the right remote:

```bash
cd <target-repo>

# Get PR diff
gh pr diff <PR#>

# Get changed files list
gh pr view <PR#> --json files --jq '.files[].path'

# Get PR title and description
gh pr view <PR#> --json title,body
```

### 3. Load Relevant How-To Guides

1. Determine changed file patterns
2. Map to how-to guides using table above
3. Read each relevant guide from `Local.Docs/Backend/HowTo/` (sibling of the target repo, at workspace root)
4. Also check `Local.Docs/Backend/Services/<ServiceName>/` for service-specific patterns

### 4. Analyze Changes

For each changed file:

1. **Read the diff** - understand what changed
2. **Read full file** - understand context (file lives inside the target repo)
3. **Check against how-to guides**:
   - Architecture patterns (layering, dependencies)
   - Naming conventions
   - Error handling patterns
   - Security practices
   - Test coverage expectations
4. **Check general best practices** (unless `--basic`):
   - Security: injection risks, auth checks, data exposure
   - Performance: N+1 queries, unnecessary allocations
   - Maintainability: complexity, duplication

### 5. Classify Issues

Group findings by severity:

- **Critical**: Must fix before merge
- **Major**: Should fix before merge
- **Minor**: Can fix later, note for author
- **Suggestion**: Optional improvements

### 6. Generate Output

#### Standard Output (Console)

```markdown
# PR Review: #<PR#> - <Title>

**Repo:** <target-repo> | **Files reviewed:** X | **Issues found:** Y

## :red_circle: Critical (N)
- **[Category]** Brief description
  `file.cs:line` - Explanation
  -> See: @howto/Guide.md#section

## :orange_circle: Major (N)
- **[Category]** Brief description
  `file.cs:line` - Explanation
  -> See: @howto/Guide.md#section

## :yellow_circle: Minor (N)
- **[Category]** Brief description
  `file.cs:line`
  -> See: @howto/Guide.md#section

## :green_circle: Suggestions (N)
- `file.cs:line` - Suggestion text

## :blue_circle: Style (N)
- `file.cs:line` - Style issue (does not block merge)

---
:white_check_mark: **Passed:** List of checked areas with no issues
```

#### GitHub Output (`--gh`)

Same structure but with:
- GitHub-compatible emoji (`:red_circle:` etc.)
- Collapsible sections for long lists
- File links: `[file.cs#L45](../blob/<sha>/path/file.cs#L45)`

#### Verbose Output (`--verbose`)

Add to each issue:
- Full code snippet showing the problem
- Example of correct implementation from how-to
- Link to how-to section

## Categories

| Category | Severity | Description |
|----------|----------|-------------|
| **Security** | Critical/Major | Auth, injection, data exposure, secrets |
| **Architecture** | Major/Minor | Layering, dependencies, patterns |
| **Performance** | Major/Minor | N+1, allocations, async |
| **Testing** | Major | Coverage, quality, patterns |
| **ErrorHandling** | Minor | Exceptions, logging, validation |
| **API** | Major/Minor | Versioning, contracts, responses |
| **Style** | Style | Naming, formatting, conventions, newlines, XML docs |
| **Documentation** | Style | Missing docs, outdated comments |

## Review Checklist

For each file type, verify:

### Controllers
- [ ] Inherits from `BaseController`
- [ ] Uses `[MapToApiVersion]` correctly
- [ ] No business logic (delegates to services)
- [ ] Proper authorization attributes
- [ ] Returns appropriate status codes

### Services
- [ ] Interface defined in Core/Common
- [ ] Implementation in Implementation.Services
- [ ] No direct repository calls from controllers
- [ ] Proper exception handling

### Repositories
- [ ] Uses parameterized queries (no SQL injection)
- [ ] Proper async/await patterns
- [ ] No N+1 queries

### Tests
- [ ] Follows naming convention: `{Method}_{Scenario}_{ExpectedBehavior}`
- [ ] Uses FluentAssertions
- [ ] Has factory methods for test data
- [ ] Proper regions structure

### Timeline Events (when `EventType`, `EventTypeDto`, `Mapper.cs`, or `DomainEvent` files change)

Cross-reference these layers + documentation to verify consistency. **Source-code paths are relative to the target backend repo (e.g., `Invoices.Backend/Src/...`); the TSV catalogue lives in the sibling `Local.Docs` repo.**

1. **Core enum** `Invoices.Core/Models/Timeline/EventType.cs` — source of truth for internal event types
2. **API DTO enum** `Invoices.Api/Models/Timeline/EventTypeDto.cs` — serialized names sent to BFF
3. **API mapping** `Invoices.Api/Models/Timeline/Mapping.cs` — `EventType → EventTypeDto` switch
4. **gRPC mapping** `Tofu.Invoices/Mapping/Mapper.cs` — proto `InvoiceEventType`/`EstimateEventType` → `EventType` switch
5. **Entity-type registry** `EventTypesByEntityType` dict in `EventType.cs` — groups events by entity (Job/Invoice/Estimate)
6. **TSV catalogue** `Local.Docs/features/timeline/Timeline Events.tsv` (workspace-root sibling repo) — documents all events with payloads and display text

Checks:
- [ ] Every `EventType` enum value has a matching `EventTypeDto` value
- [ ] Every `EventType` ↔ `EventTypeDto` pair has a mapping arm in `Mapping.cs`
- [ ] Every proto event type value (non-Unknown) has a mapping arm in `Mapper.cs` (not falling through to `Unknown`)
- [ ] Every new `EventType` is registered in `EventTypesByEntityType` under the correct entity
- [ ] Every `EventTypeDto` serialized name (the `EnumMember` Value) has at least one row in `Timeline Events.tsv`
- [ ] New domain events (e.g., `JobDomainEvent.Created`) have corresponding `EventType` enum values

**Severity:**
- Missing mapping arm (event arrives as `unknown` to BFF) → :orange_circle: Major
- EventType exists but missing from `EventTypesByEntityType` → :orange_circle: Major
- EventType exists but missing from TSV documentation → :yellow_circle: Minor
- TSV has event not backed by code → :green_circle: Suggestion (may be planned)

## Notes

- Always fetch the actual diff, don't assume changes
- Read how-to guides fresh each time (they may have updated) — they live in the **sibling** `Local.Docs` repo
- Be constructive - suggest fixes, not just problems
- If unsure about a pattern, check existing code for precedent
- Focus on the changed code, not pre-existing issues
- Each backend folder is its **own git repo with its own GitHub remote** — `gh` commands must be run inside the target repo
