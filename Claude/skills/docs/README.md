# /docs Skill - Quick Reference

Work with documentation in the `Local.Docs` repo (sibling folder, separate git repository — no longer a submodule).

## Workspace Layout

This skill is registered at the workspace root `C:\Git\Work\Backend\`. The workspace contains independent sibling repos:

- `Invoices.Backend/` — BFF, main repo
- `Tofu.Invoices.Backend/`, `Tofu.Auth.Backend/`, `Tofu.Common.Backend/` — backend services / shared lib
- `Local.Docs/` — documentation (separate git repo)
- `Investigations/` — spikes / investigations (see `/inv`)

All paths below are relative to the workspace root.

## Commands

| Command | Description |
|---------|-------------|
| `/docs search <query>` | Search docs (prioritizes current project) |
| `/docs read <path>` | Read a documentation file |
| `/docs update <path>` | Edit existing documentation |
| `/docs create <topic>` | Create new documentation |
| `/docs sync` | Sync docs with current code changes |
| `/docs nav` | Show documentation structure |
| `/docs context` | Show current project config |
| `/docs commit <desc>` | Commit documentation changes (commits in Local.Docs repo) |
| `/docs pull` | Pull latest in Local.Docs repo |

## Quick Shortcuts

Use `@` shortcuts for faster navigation (resolve based on detected project):

| Shortcut | Description |
|----------|-------------|
| `@service` | Current service docs (e.g., `Local.Docs/Backend/Services/<Project>/`) |
| `@platform` | Platform root (`Local.Docs/Backend/`, `Local.Docs/Android/`, `Local.Docs/IOS/`) |
| `@howto` | Platform how-to guides |
| `@features` | Cross-product feature docs (`Local.Docs/features/`) |
| `@jobs` | Jobs feature docs |
| `@index` | Service AGENTS.md (navigation index) |

## Examples

```bash
# Search for persistence docs (service docs shown first)
/docs search persistence

# Read service-specific file using shortcut
/docs read @service/Persistence.md

# Read a how-to guide
/docs read @howto/Authorization.md

# Sync docs after code changes
/docs sync

# Show current project context
/docs context

# Create new documentation
/docs create webhooks integration guide

# Commit changes (lands in Local.Docs repo)
/docs commit "Added webhooks guide"
```

## Search Priority

Results are grouped by relevance to current project:

1. **Service Docs** - `Local.Docs/<Platform>/Services/<ProjectName>/`
2. **Platform Docs** - `Local.Docs/<Platform>/`
3. **How-To Guides** - `Local.Docs/<Platform>/HowTo/`
4. **Feature Docs** - `Local.Docs/features/`
5. **Other** - remaining matches

## Project Detection

The skill auto-detects your project from the working directory folder name:

| Folder | Platform | Service Path |
|--------|----------|--------------|
| `Invoices.Backend` (default if at workspace root) | Backend | `Local.Docs/Backend/Services/Invoices.Backend/` |
| `Tofu.Auth.Backend` | Backend | `Local.Docs/Backend/Services/Tofu.Auth/` |
| `Tofu.Invoices.Backend` | Backend | `Local.Docs/Backend/Services/Tofu.Invoices/` |
| `Tofu.Common.Backend` | Backend | `Local.Docs/Backend/Services/Tofu.Common/` |
| `Android`, `*-android` | Android | `Local.Docs/Android/` |
| `IOS`, `*-ios` | iOS | `Local.Docs/IOS/` |

## API Documentation Rules

When documenting APIs:

1. **Include full DTO structure** - All fields with types and descriptions
2. **Link to canonical docs** - Don't duplicate; link if DTO is documented elsewhere
3. **Nested DTOs** - Document if "owned" here, otherwise link to source
4. **Keep examples in sync** - Request/response must match DTO structure
