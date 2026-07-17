---
name: investigate
description: SINGLE entry point for any investigation on the Tofu/Invoices platform — alert links, error spikes, "why did X fail", trace/account/Sentry lookups, incident write-ups. Owns triage, evidence fan-out (history, Sentry, GCP logs, code), synthesis, and case persistence in the Investigations repo. Supersedes /inv and the investigation-* skills.
---

# Investigate (root orchestrator)

Start your first reply with "Investigating...". Follow the shared multi-agent pattern — load the `orchestration` skill if not already loaded this session.

## Reference files (progressive disclosure)

Load only what the current phase needs; collector subagents are pointed at exactly one file each.

| File | Owns |
|---|---|
| `references/history.md` | prior-work recall: Investigations repo (canonical) + `.tofu-ai/` tree (read-only), gate greps, continuous matching |
| `references/gcp-logs.md` | LQL field paths (BFF + tofu-ai), projects, quotas, query/aggregation recipes |
| `references/sentry.md` | Sentry REST recipes (sandbox-safe curl form), alert decoding, client source-repo map |
| `references/case-format.md` | case folder lifecycle, frontmatter schema, reindex, ops (`new`/`note`/`finding`/`commit`/…) |
| `references/deep-workflow.md` | Workflow template for the deep tier |

Mongo evidence: use the `/mongo` skill as-is (no reference file here yet).

## Tier selection

- **inline** — one identifier to look up, a known-issue check, "глянь/quick": run the gate, answer, done.
- **standard** (default for a real symptom) — gate, then 2–4 collectors via Agent tool.
- **deep** — "thorough/audit/post-mortem" wording, contradictory evidence from standard, or a prod incident with unclear blast radius → `references/deep-workflow.md`.

## Phase 0 — Gate (ALWAYS inline, before ANY source query)

In one parallel batch (exact recipes in `references/history.md`):

1. Read both known-issue registries — `Investigations/investigations/KNOWN_ISSUES.md` and `.tofu-ai/known-issues.md`. On a symptom match: verify with 1–2 cheap checks, tell the user it's known, link the case, and **stop unless they insist**.
2. Grep BOTH stores for **every literal identifier in the ask** (trace id, Sentry short-id, account id, path, error text). A bare id won't *feel* familiar — grep it anyway; the hit IS the familiarity check. On a hit, read the matching case/run file before touching live sources.
3. Decode the ask: alert URLs carry ids — resolve the *definition* (what is monitored, thresholds) before chasing symptoms. GCP Monitoring alerts: violation events are in Cloud Logging (`monitoring.googleapis.com/ViolationOpenEventv1` names the policy).

**Continuous matching (standing rule):** the moment any collector or query surfaces a *new* concrete identifier, add its gate-grep to your next parallel batch — a hit means the thread was already walked; reuse and cite it.

## Phase 1 — Collect (standard tier: Agent fan-out)

Launch the applicable collectors in ONE message (Explore agents; prompt contract + output schema from the `orchestration` skill):

| Collector | Reads first | Question shape |
|---|---|---|
| `history` | `references/history.md` | grep both stores for ALL identifiers; return matching case ids + their conclusions |
| `sentry` | `references/sentry.md` | issue/event/alert pulls; counts, first/last-seen, tags, stacktrace symbol + release |
| `gcp-scope` | `references/gcp-logs.md` | scope before depth: counts, affected accounts, window, first-seen (cheap aggregations first) |
| `code` | *(no reference — repo checkouts)* | resolve the throw site / mapping / commit; deployed state = `origin/<default-branch>`, never checkout |

Skip collectors whose source can't bear on the ask; don't fan out what the gate already answered.

## Phases 2–3 — Cross-match, then synthesize (inline)

- Feed new identifiers back through the gate greps (phase-0 rule) before concluding.
- Correlate across sources: Sentry event (client view) ↔ backend request logs (`AccountId` prefix gotcha) ↔ source ↔ git history.
- **Name the mechanism, not the symptom** — a finding reaches file:line (the throw site, the mapping, the commit). "Errors went up" is scope, not a finding.
- **Time-box**: two dead-ended approaches to a sub-question → record a limitation, move on. An honest gap beats a guessed answer.

## Phase 5 — Persist (inline)

Canonical store for NEW cases: the **`Investigations/` repo** (`.tofu-ai/` stays read-only recall). Full lifecycle, frontmatter schema, and ops in `references/case-format.md`. Short form:

- Real symptom investigated → `new` a case folder (triage already ran in the gate), capture raw query outputs into `queries/`, findings into the case README.
- Case resolved → fill `root_cause`/`resolution`/`closed`, run `reindex` so `triage` catches it next time.
- **Never auto-commit** — suggest `commit` when ready.
- Quick inline lookups don't need a folder; report and offer to persist.

## Triage heuristics (platform)

- The BFF often returns HTTP **200 with an error JSON body** — error envelopes hide from StatusCode filters.
- Auth-gated log fields (`AccountId`, `UserEmail`) are missing on early-pipeline failures — fall back to container-wide `severity>=ERROR`.
- 403 `forbidden` spikes from iOS ⇒ usually the client calling JWT-only endpoints without a session (`AuthenticationInfoMissedException`) before suspecting the backend.
- Identical Sentry counts across two issues ⇒ likely one client screen calling both endpoints.
- High occurrences / few users ⇒ a retry loop, not breadth — check per-account aggregation.
- "Production-only" + same code healthy in test ⇒ per-account/state issue, not a code break.

## Report discipline

Citations on every finding (Sentry short-id is the cross-investigation dedupe key). Cite prior case/run ids you built on. Limitations for anything unchecked. Tags from the controlled vocabulary (`references/case-format.md`).
