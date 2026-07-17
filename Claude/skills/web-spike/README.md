# /web-spike Skill - Quick Reference

Time-boxed web research for backend feature implementation. Pulls authoritative sources (vendor docs, Microsoft Learn, Martin Fowler, IETF, library docs) on best practices, design patterns, vendor APIs, and library options directly relevant to the feature. Output: single `web-spike.md` in the feature folder.

Reference shape: [`Local.Docs/features/WEB-1469-notes/research-attachments-vs-notes-in-visits.md`](../../Local.Docs/features/WEB-1469-notes/research-attachments-vs-notes-in-visits.md).

## Quick start

```
/web-spike <TASK> [<topic>]            # write web-spike.md (default op)
/web-spike write <TASK> [<topic>]      # explicit
```

If `<TASK>` is omitted, inferred from the current branch (`feature/WEB-1234` → `WEB-1234`).

## Workflow position

```
/feature plan <TASK>         # scaffold README.md + folder
/web-spike <TASK> [<topic>]  # web research → web-spike.md (opt-in; this skill)
/plan write <TASK>           # reads README + web-spike.md → overview.md
/feature start <TASK>        # branch
```

## When to use

- Net-new design pattern (CQRS, outbox, saga, etc.).
- Vendor / SaaS API surface survey.
- Library or framework choice with ≥2 credible options.
- Standard / RFC that constrains the contract.
- Non-obvious "best practice" the team wants to align on before committing.

## Skip

- Pure refactors / config changes (Trivial tier in `/plan`).
- Patterns already established in this workspace.
- Research already done and dropped in the folder.

## How it runs

1. **Reads the feature folder** (`README.md`, prior `web-spike.md`, other research files).
2. **Defines, proposes, and waits for explicit approval of the full question set** *(blocking gate — no fetches until approved)*. The proposed set covers primary questions, surface-survey scope, per-primary sub-questions / axes, implication-anchored questions linked to specific `/plan` decisions, and adjacent topics. The user can approve, refine, narrow, or expand.
3. **Fetches authoritative sources** via `WebSearch` + `WebFetch`. Verbatim quotes for load-bearing claims.
4. **Synthesizes** into `web-spike.md`.
5. **Reports** word count, source count, open questions, suggested next step.

## What it produces

`Local.Docs/features/<TASK>/web-spike.md` with sections:

- Title + 2–3-sentence framing.
- Questions — what the web-spike asked.
- Sources — authoritative URLs + one-line characterisations.
- Findings — organised by question; verbatim quotes for load-bearing claims; comparison tables for ≥3 options.
- **Implications for the design** — mandatory link from research to feature decisions.
- Open questions / follow-ups.

## Source quality

- **Preferred:** vendor docs (`developer.*`, `learn.microsoft.com`), standards bodies (IETF, W3C), cited authors (Fowler, Richardson, Vernon, Evans), Azure / AWS architecture centers, major library docs.
- **Acceptable when nothing better:** named-author Medium / dev.to / engineering blogs (Confluent, Decodable, Datadog), high-rep Stack Overflow.
- **Skip:** anonymous aggregators, untraceable tutorials, anything >5 years old in fast-moving areas, LinkedIn / Twitter as primary.

## Style rules in output

1. Verbatim quotes for load-bearing claims; never paraphrase facts.
2. Every source has a URL.
3. Comparison tables for ≥3 options; one row per option, last column is the per-row Source link.
4. Findings organised by question, not by source.
5. Implications section is mandatory — connects findings to design choices.
6. Caveats inline (paywalled, JS-rendered, >1 year old).
7. No conjecture without sources — drop or move to follow-ups.

## What it doesn't do

- Doesn't auto-commit. Prints `pwsh Local.Docs/scripts/commit-docs.ps1 -ShortDescription "<TASK> web-spike"` instead.
- Doesn't edit `README.md`, `overview.md`, or any other file in the folder.
- Doesn't run lint, build, branch, or open PRs.
- Doesn't operate without `Local.Docs/features/<TASK>/README.md` — refuses with a pointer to `/feature plan <TASK>`.
- Doesn't do production-incident investigation — that's `/inv`.

## Where the skill lives

`C:/Git/Work/Backend/.claude/commands/web-spike.md` (workspace-scoped, alongside `/feature`, `/plan`, `/docs`, `/inv`, `/tests`, `/review-gw`).
