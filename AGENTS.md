# Local.Docs — documentation index

Cross-product and platform documentation for Tofu. **Start here** — this is the canonical navigation index (imported by `CLAUDE.md`). The authoring/placement rules live in [`README.md`](README.md).

## Layout

| Path | What's there | Index |
|---|---|---|
| `Backend/` | Backend platform — architecture, REST API refs, flows, how-tos, domain notes, per-service docs, data-store inventory | [`Backend/AGENTS.md`](Backend/AGENTS.md) |
| `IOS/` | iOS ↔ backend integration notes | [`IOS/AGENTS.md`](IOS/AGENTS.md) |
| `Web/` | Web ↔ backend integration notes | [`Web/AGENTS.md`](Web/AGENTS.md) |
| `features/` | Cross-product / cross-repo feature docs & plans (one folder per feature) | [`features/AGENTS.md`](features/AGENTS.md) |
| `Claude/` | Canonical store of Claude Code skills (synced to workspace `.claude/skills/` via `scripts/sync-claude-skills.ps1`) | [`Claude/AGENTS.md`](Claude/AGENTS.md) |
| `scripts/` | Doc tooling (`commit-docs.ps1`, `sync-claude-skills.ps1`) | — |

## Fast paths

- **Where does data live?** (datasets / collections / schemas / config keys / write paths) → [`Backend/Storage/AGENTS.md`](Backend/Storage/AGENTS.md)
- **Backend architecture overview** → [`Backend/HowTo/Architecture.md`](Backend/HowTo/Architecture.md)
- **A REST API contract** → `Backend/Api/<NAME>_API_REFERENCE.md` (list in the Backend index)
- **A service's internals** → `Backend/Services/<Service>/AGENTS.md`
- **A feature's plan** → `features/<TASK>/README.md`

## Index convention (for agents)

- Every directory's navigation index is **`AGENTS.md`** — read it first to learn what the folder holds and where to start.
- `README.md` is reserved for **(a)** this repo's root rules doc and **(b)** a feature's own plan (`features/<TASK>/README.md`).
- Each doc should open with a one-line purpose so its relevance is greppable without a full read.
