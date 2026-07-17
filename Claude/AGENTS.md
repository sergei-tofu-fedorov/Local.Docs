# Claude/ — canonical store of Claude Code skills

Source of truth for the workspace's Claude Code skills. The runtime copies live in `C:\Git\Work\Backend\.claude\skills\` and are one-way synced from here by `../scripts/sync-claude-skills.ps1` (run it after every edit in this folder; never edit the `.claude` copies directly — the sync mirrors and will overwrite them).

## skills/

| Skill | Role |
|---|---|
| `investigate/` | Single entry point for investigations: tiered orchestration (inline / fork-collectors / deep Workflow), gate, synthesis, case persistence. Knowledge in `references/` (history, gcp-logs, sentry, case-format, deep-workflow) — each file self-sufficient for one collector. |
| `inv-history/`, `inv-sentry/`, `inv-gcp/`, `inv-code/` | Fork collectors (`context: fork`, `agent: Explore`, not user-invocable) — one evidence source each, structured-JSON output. Invoked by `investigate`, not directly. |
| `orchestration/` | Reusable multi-agent pattern (tier ladder, phase model, collector contract) — adopt it in any future fan-out skill (e.g. a feature planner). |
| `gcp/`, `sentry/`, `mongo/` | Standalone one-off toolkits (ops + safety gates). Their source knowledge lives in `investigate/references/` — update it there, once. |

## Conventions

- One skill = one folder with `SKILL.md`; descriptions are directive trigger conditions ("ALWAYS invoke when…", with a negative trigger), ≤~200 chars.
- Reference files go one level deep only; files >100 lines start with a `**Contents:**` line.
- No secrets in any file — auth via external files (e.g. `.tofu-ai/sentry-header.txt`).
- Deprecated entry points (`investigating` skill, `/inv` command) are stubs in `.claude/` only, muted via `skillOverrides` in `.claude/settings.json`; they are not stored here.
