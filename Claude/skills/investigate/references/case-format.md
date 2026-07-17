# Case persistence — the Investigations repo (canonical store)

`Investigations/` is a sibling repo (its own git, independent commits) at the workspace root. One folder per case under `Investigations/investigations/<slug>/`. This file owns the lifecycle, the frontmatter schema, and the ops formerly known as `/inv` operations.

## Layout

| Path | Purpose |
|---|---|
| `Investigations/README.md` | top-level cheat sheet |
| `Investigations/investigations/<slug>/` | one case: README, scripts, `queries/` raw captures |
| `Investigations/investigations/README.md` | **generated** index (one row per case) |
| `Investigations/investigations/KNOWN_ISSUES.md` | symptom-keyed early-exit registry of `solved`/`diagnosed` cases (the gate's triage target) |
| `Investigations/investigations/TAGS.md` | controlled tag vocabulary + status lifecycle (⚠️ if missing, fall back to `.tofu-ai/taxonomy.json` and flag it) |

## Case skeleton (frontmatter first — it powers all retrieval)

```markdown
---
title: <Title>
status: open            # open | diagnosed | solved | wont-fix | recurring | duplicate
opened: <YYYY-MM-DD>
closed:
services: []            # backend containers/repos involved; empty if backend not at fault
clients: []             # client app(s), if client-originated
tags: []                # prefix:value from TAGS.md (platform:/topic:/component:/symptom:/cause:)
symptoms:
  - "<observable symptom — how you'd re-encounter this>"
root_cause:             # fill once known
resolution:             # what to tell the user / what was done
related: []             # slugs of related cases
---

# <Title>

**Scope:** <service/component, environment>

## Hypothesis / Question
## How to reproduce
## Findings
## Conclusion
```

`status`, `symptoms` at creation; `root_cause`, `resolution`, `closed` on close — that's what makes the case findable by the next gate.

## Ops

| Op | What it does |
|---|---|
| **new** `<slug> [desc]` | Gate/triage runs first (known-issue early-exit — see `history.md`). Then: kebab-case slug (date only for incident-tied cases), create folder + skeleton, run `reindex`. Never auto-commit. |
| **open** `<slug>` | Read the case README + obvious sub-files; summarize state. The slug becomes the **active case** — subsequent queries capture into it. |
| **list** `[status]` | Show the generated index table; filter by status; flag unindexed folders → offer `reindex`. |
| **search** `<term>` | ripgrep across `investigations/**` (frontmatter + body) — exact tokens. |
| **similar** `<description>` | fuzzy LLM-rank against index + frontmatter — stories, not tokens. |
| **reindex** | Regenerate read surfaces from frontmatter (see below). |
| **note** `<slug> <text>` | Append `- **<YYYY-MM-DD>:** <text>` under `## Findings` (date from system context). |
| **finding** `<slug>` | Add a dated `## Findings — <YYYY-MM-DD>` section for substantive write-ups. |
| **script** `<slug> <name>` | Scratch script in the case folder; header comment (purpose/input/output); small and self-contained. |
| **commit** `<desc>` | `cd Investigations; git add -A; git commit -m "<desc>"` — only on explicit ask. |
| **status** | `cd Investigations; git status`. |

## Query capture (active case in scope)

- Raw output → `investigations/<slug>/queries/<timestamp>-<op>.txt` (`.json` for `--format=json`); redact tokens (`<SENTRY_TOKEN>`).
- The exact command → the case's `## How to reproduce`.
- Sentry events: also pull `tags.accountId`, `tags.environment`, `tags.release`, `user.email`, `dateCreated` into the README.
- No active case → just report; offer to persist.

## `reindex` (hybrid: data generated, curated wording preserved)

1. Scan every case's frontmatter.
2. Rewrite the index table in `investigations/README.md` (status, services/clients, tags, one-line root cause per row).
3. Refresh the **data** columns of `KNOWN_ISSUES.md` for `solved`/`diagnosed` cases (root cause / resolution / status / link); **preserve the hand-curated `Signature` and "What to tell the user" columns**. Add rows for newly-closed cases; flag orphan rows.
4. Never auto-commit.

## Conventions

- Frontmatter is mandatory; tags only from the controlled vocabulary.
- Don't invent findings — report what queries returned even when they don't reproduce the symptom.
- Keep raw output alongside notes (dumps, CSVs, screenshots) in the case folder, not chat-only.
- Closing a case without `reindex` = the next gate won't catch it. Close → reindex, always.
- Default service in scope is `Invoices.Backend` (BFF); name other repos explicitly.
