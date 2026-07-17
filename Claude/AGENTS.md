# Claude/ — canonical store of Claude Code skills

Source of truth for the workspace's Claude Code skills. The runtime copies live in `C:\Git\Work\Backend\.claude\skills\` and are one-way synced from here by `../scripts/sync-claude-skills.ps1` (run it after every edit in this folder; never edit the `.claude` copies directly — the sync mirrors and will overwrite them). The former `.claude/commands/` folder is gone — everything is a skill now (invocation via `/name` is unchanged).

## skills/

### Investigations

| Skill | Role |
|---|---|
| `investigate/` | Single entry point for investigations: tiered orchestration (inline / fork-collectors / deep Workflow), gate, synthesis, case persistence. Own knowledge in `references/` (history, case-format, deep-workflow); GCP/Sentry knowledge is read from the toolkit skills' `references/`. |
| `inv-history/`, `inv-sentry/`, `inv-gcp/`, `inv-code/` | Fork collectors (`context: fork`, `agent: Explore`, not user-invocable) — one evidence source each, structured-JSON output. Invoked by `investigate`, not directly. |
| `orchestration/` | Reusable multi-agent pattern (tier ladder, phase model, collector contract) — adopt it in any future fan-out skill (e.g. a feature planner). |

### Feature workflow

| Skill | Role |
|---|---|
| `feature/` | Lifecycle ops (plan / load / list / start / status / lint / review / done). Never pushes, commits code, or opens PRs. Heavy ops in `references/` (lint, review + breaking-change scan, multi-repo + PR guidance, implementation rules). |
| `web-spike/` | Time-boxed web research for a feature → `web-spike.md`. Runs between `/feature plan` and `/plan write`; question-set approval is a blocking gate. |
| `plan/` | Deepens a scaffolded feature into `overview.md` (file-path-anchored implementation plan). Section template + style rules in `references/output-spec.md`. |
| `arch-plan/` | Cross-cutting `architecture.md` orientation doc (≤15-min read) for multi-service / framework features. Output spec + review checklist in `references/output-spec.md`. |
| `impl/` | Two-phase gated implementation: `impl-design.md` (abstractions only) → code after explicit approval. Mermaid + pseudocode rules in `references/`. |
| `tests/` | Write/refactor unit & integration tests per project conventions (refactor / unit / integration / sync ops). |
| `review-gw/` | PR (or branch-diff) review against Local.Docs how-to guides; called by `/feature review` in `--branch` mode. |
| `docs/` | Local.Docs operations (search / read / update / create / api / timeline / commit / …). Never auto-commits. |

### Toolkits

| Skill | Role |
|---|---|
| `gcp/`, `sentry/`, `mongo/` | Standalone one-off toolkits (ops + safety gates), usable from anywhere. `gcp`/`sentry` own their domain knowledge in their own `references/` (`gcp/references/gcp-logs.md`, `sentry/references/sentry.md`) — single source; `investigate` collectors read the same files. |
| `bq/` | BigQuery toolkit (analytics warehouse `inv-project`): cost gate (metadata + `--dry_run` before every scan), reads-default-to-prod env rules, SA-key write gate (`tofu-ai-backend` for DDL/DTS). Query-composition knowledge is NOT duplicated here — it points at `Backend/Storage/bigquery-agent-guide.md` (that guide is a Storage-catalog artifact, so it stays in the catalog where humans browse it). |

## Conventions

- One skill = one folder with `SKILL.md`; descriptions are directive trigger conditions ("ALWAYS invoke when…", with a negative trigger), ≤~200 chars.
- `README.md` next to `SKILL.md` is the human quick-reference companion (not loaded by the agent runtime).
- Reference files go one level deep only; files >100 lines start with a `**Contents:**` line.
- No secrets in any file — auth via external files (e.g. `.tofu-ai/sentry-header.txt`). The `amplitude` skill lives only in `.claude/skills/` (its auth files must not enter git).
- No deprecated stubs remain: the old entry points (`/inv`, `investigating`, `be-*` commands and their backups) were deleted from `.claude/` on 2026-07-18. `.claude/skills/` is exactly this canon plus `amplitude`.
