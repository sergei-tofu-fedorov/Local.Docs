# /review-gw Skill - Quick Reference

Review PRs against Local.Docs how-to guides and architecture patterns.

## Workspace Note

This skill is registered at the workspace root `C:\Git\Work\Backend\`. The workspace contains independent sibling repos: `Invoices.Backend/` (BFF, default target), `Tofu.Invoices.Backend/`, `Tofu.Auth.Backend/`, `Tofu.Common.Backend/`, plus `Local.Docs/` (separate repo, **not** a submodule). Each backend repo has its own GitHub remote — `gh` commands run inside the target repo's folder. How-to guides resolve from the sibling `Local.Docs/...` folder.

## Commands

| Command | Description |
|---------|-------------|
| `/review-gw <PR#>` | Full PR review (default repo: `Invoices.Backend`) |
| `/review-gw <PR#> --repo <name>` | Run against another backend repo |
| `/review-gw <PR#> --basic` | How-to + best practices only (faster) |
| `/review-gw <PR#> --file <path>` | Review specific file in PR |
| `/review-gw <PR#> --gh` | GitHub markdown output (for PR comments) |
| `/review-gw <PR#> --verbose` | Detailed output with code examples |

## Examples

```bash
# Full review of PR #123 in the default repo (Invoices.Backend)
/review-gw 123

# Review a PR in a different repo
/review-gw 45 --repo Tofu.Auth.Backend

# Quick review (how-to compliance only)
/review-gw 123 --basic

# Review specific file
/review-gw 123 --file Src/Invoices.Api/Controllers/ClientsController.cs

# Output for GitHub PR comment
/review-gw 123 --gh

# Detailed review with fix examples
/review-gw 123 --verbose

# Combine flags
/review-gw 123 --gh --verbose
```

## Severity Levels

| Icon | Level | Action Required |
|------|-------|-----------------|
| :red_circle: | Critical | Must fix before merge |
| :orange_circle: | Major | Should fix before merge |
| :yellow_circle: | Minor | Can fix later |
| :green_circle: | Suggestion | Optional improvement |
| :blue_circle: | Style | Lowest priority, does not block merge |

## What Gets Checked

### By File Type (mapped to actual Local.Docs guides — sibling folder)

| Pattern | Checks Against |
|---------|----------------|
| `*Controller.cs` | `Local.Docs/Backend/HowTo/Architecture.md`, `Authorization.md`, `CodeStyle.md` |
| `*Service.cs` | `Local.Docs/Backend/HowTo/Architecture.md`, `CodeStyle.md` |
| `*Repository.cs` | `Local.Docs/Backend/HowTo/Transactions.md`, `Persistence.md` |
| `*Tests.cs` | `Local.Docs/Backend/HowTo/CodeStyle.md` (test patterns), `IntegrationTests.md` |
| `*Dto.cs`, `*Request.cs` | `Local.Docs/Backend/HowTo/Architecture.md` (DTOs), `CodeStyle.md` (enums) |
| `*Email*` | `Local.Docs/Backend/HowTo/EmailSending.md` |
| `*OperationHandler*` | `Local.Docs/Backend/HowTo/UnitOfWork.md`, `Transactions.md` |
| `Jobs.*` | `Local.Docs/Backend/Services/Invoices.Backend/Jobs-Application-Services.md` |

### Categories

- **Security** - Injection, auth, data exposure
- **Architecture** - Layering, dependencies, patterns
- **Performance** - N+1 queries, async patterns
- **Testing** - Coverage, naming, structure
- **ErrorHandling** - Exceptions, validation
- **API** - Versioning, contracts
- **Style** - Naming, formatting, newlines, XML docs (lowest priority)

## Output Format

```markdown
# PR Review: #123 - Add client archiving

**Repo:** Invoices.Backend | **Files reviewed:** 5 | **Issues found:** 8

## :red_circle: Critical (1)
- **[Security]** SQL injection risk
  `ClientRepository.cs:45` - Use parameterized queries
  -> See: Local.Docs/Backend/HowTo/Transactions.md

## :orange_circle: Major (2)
- **[Architecture]** Business logic in controller
  `ClientsController.cs:78` - Move to service layer
  -> See: Local.Docs/Backend/HowTo/Architecture.md#layers

## :yellow_circle: Minor (3)
- **[ErrorHandling]** Missing structured logging context
  `ClientService.cs:23`
  -> See: Local.Docs/Backend/HowTo/EmailSending.md#error-handling

## :green_circle: Suggestions (2)
- `GetClient()` - Consider pattern matching

## :blue_circle: Style (1)
- `ClientService.cs:23` - Missing newline at EOF

---
:white_check_mark: **Passed:** Naming, Error handling, Test coverage
```

## Tips

- Run before creating PR to catch issues early
- Use `--gh` to copy output directly into PR description
- `--verbose` helps junior devs understand fixes
- Focus on changed code, not pre-existing issues
- Specify `--repo` when reviewing PRs in non-default backend repos — each repo has its own GitHub remote
