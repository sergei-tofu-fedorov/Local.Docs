---
name: investigate
description: Backend investigation expert for Tofu/Invoices (BFF, core invoices, auth). ALWAYS invoke FIRST — before any Sentry / Cloud Logging / Mongo / BigQuery query — for an alert or alert URL, an error/500 spike, "why did X fail/break/time out", or a lookup by trace id, account id, Sentry short-id, or error text. It picks which evidence sources can actually answer the ask, in which order, and fans them out read-only. Not for greenfield feature work (use feature) or a one-off warehouse read (use bq).
---

# Investigate (root orchestrator)

Start your first reply with "Investigating...".

**Every investigation starts from scratch.** There is no case store, no known-issue registry, no prior-work recall — do not grep `Investigations/` or `.tofu-ai/` for past cases. Nothing is persisted unless the user explicitly asks for a write-up.

This skill's job is **source selection**: which store can answer this ask, which cannot, and in what order to touch them. Follow the shared fan-out pattern — load the `orchestration` skill if it is not already loaded this session.

## Tier

- **inline** — one identifier to resolve, or one source obviously owns the answer: query it directly through its toolkit skill, answer, done.
- **standard** (default for a real symptom) — 2–3 fork collectors in one parallel batch, then synthesize inline.

Never fan out what one query answers; never answer from one source when the symptom spans client and backend.

## Phase 0 — Frame (inline, always, cheap)

1. **Extract every identifier** and classify it — the routing table keys off identifier type, not off the prose.
2. **Decode alert URLs before chasing symptoms.** `sentry.io/.../alerts/rules/<id>` → resolve the rule definition (what is monitored, threshold) via `sentry`. A GCP Monitoring alert → resolve the policy; its violation events live in Cloud Logging (`monitoring.googleapis.com/ViolationOpenEventv1` names the policy).
3. **Pin environment and window.** Prod = `inv-project`, test = `invoicesapp-project-test`; Sentry `tags.environment` is NOT the GCP project. Both go verbatim into every downstream query.
4. **Read the container name off the evidence.** A log screenshot, an alert, or a pasted row almost always names the container (`auth-api`, `invoices-api`, `tofu-invoices-api`, …). That single token scopes the log query AND selects the repo `inv-code` should open — the container-to-repo table lives in `.claude/skills/gcp/references/gcp-logs.md`. Hand it to both collectors instead of letting each rediscover it; an unscoped search of the whole cluster is slower and noisier for no gain.

## Tool selection

### By what you were handed

| Input | Start with | Then |
|---|---|---|
| Sentry short-id (`INVOICE-MAKER-IOS-2Z6`) or Sentry alert URL | `inv-sentry` | its tags (`accountId`, `release`, `environment`) become the identifiers for `inv-gcp` |
| trace id | `inv-gcp` | the only store keyed on it — and the cheapest deep evidence there is: one `trace=` filter returns the whole request chain across services. Whenever an error entry carries a `TraceId`, pull the trace before anything else |
| HTTP 500 / 4xx spike / timeout on an endpoint | `inv-gcp` — counts and distinct accounts first | walk the log ladder below; `inv-code` only once you can name the exception and the container |
| exception type or literal error text | `inv-gcp` alone | walk the log ladder below before opening any repo |
| account id / user email / "this one customer sees X" | `inv-gcp` + `mongo` | logs = what the request did; Mongo = what the state actually is |
| "the data is wrong" (missing invoice, wrong status, stale subscription) | `mongo` | logs show the write attempt, the document is the truth |
| "what subscription does this user have / is it active" | two different answers — pick deliberately | **user-side** (what the app told them): `ResponseBodyText` of `/api/plans/current` in logs, keyed by `AccountId`. **Server-side** (plan, price, dates, status): `bq` → `ai_analysis_us.mart_account_subscriptions`, truth flag `is_active`. Disagreement between the two IS the finding |
| app crash, ANR, blank screen, client-side error | `inv-sentry` | confirm it is client-side before opening backend logs |
| "how many / how often / since when" over weeks or months | `bq` | Logging retention and per-query caps make trend questions expensive there |
| "did this ship / when did it change / which release" | `inv-code` | deployed state is `origin/<default-branch>` |
| an Amplitude event looks wrong or missing | `amplitude-events` skill | property provenance is already catalogued; only then `bq` / logs |
| Stripe behaviour — coupon, trial, price, Connect onboarding, webhook | `stripe` skill | it owns the config semantics; logs only show the call |

### The log ladder — exhaust it before opening a repo

A log-borne symptom has a fixed cheap path, and each rung is a single bounded query. Source code is the **last** rung, not the first, because the logs carry the runtime values that decide which code path even ran — open a repo and you get everything that *could* happen, which is a much larger space to search.

1. **Find the error row.** Scope by container, match the message text. Project `trace` alongside the message — the row carries it, so this step also hands you the next rung for free.
2. **Pull the whole trace.** `trace="projects/<proj>/traces/<id>"` with no `logName` pin returns the request across every service it touched, in order. This is where causality lives: the 401 in one container and the "Unable to authenticate" in the next are the same request.
3. **Read the rows around the error inside that trace**, not just the error row. The line that names the cause is frequently an INFO one tick earlier — a claims dump, a resolved config value, a chosen branch. An error message states the failure; its neighbours state why.
4. **Widen to the actor's neighbourhood** if the trace is not enough: the same account or device in a window of tens of minutes around the event.
5. **Only now open the repo.** You should arrive with a container, an exception type, a message, and the runtime values. That turns `inv-code` from an exploration into a lookup.

Skip ahead to source only when the logs cannot answer by construction — the question is "when did this change / which release", or the log source is unavailable. Fanning out `inv-code` speculatively alongside the first log query is not free parallelism: in a measured run it cost roughly four times the tokens and time of the log collector, and the deciding evidence still came from a log line.

### What each source can and cannot answer

| Source | Owns | Blind to |
|---|---|---|
| Sentry (`inv-sentry`) | client errors on iOS / Android / web: counts, first- and last-seen, release, device, tags | **anything backend — org `getpaid-inc` has no .NET project.** A .NET stack trace never comes from Sentry |
| Cloud Logging (`inv-gcp`) | every backend request and exception, per container, recent window | client-only failures; long-range trends (retention + caps); document state |
| Mongo (`mongo`) | current document state of accounts / invoices / subscriptions | how the state got there — there is no per-field audit trail |
| BigQuery (`bq`) | volumes, trends, revenue, analytics events, long range | today's fresh data (daily snapshots) and request-level detail |
| Repo checkouts (`inv-code`) | the mechanism: throw site, mapping, config gate, commit | runtime values — code says what *can* happen, not what did |

### Ordering rules

1. **Cheapest source that can falsify the leading hypothesis goes first.** One aggregation often ends the investigation.
2. **Scope before depth** — for a log-borne symptom the first query is always the distinct-`AccountId` aggregation (counts, affected accounts, first-seen); individual entries only where that aggregate points. It separates a retry loop from real breadth before you spend anything.
3. **One known event beats a date range.** As soon as you hold a concrete entry — an error, a trace, a support report — you have a timestamp and an actor. Search their neighbourhood (a window of tens of minutes around the event, filtered to that account or device) before widening. Reaching for "the last 30 days" while a specific failing request is already in hand is the most common way to spend minutes and learn less: the answer is usually in the two minutes surrounding the error, not in the month around it.
4. **Parallel only for independent sources.** If collector B needs an identifier that collector A produces, that is two rounds, not one batch. A second round is normal and still cheaper than a wrong wide fan-out. For a log-borne symptom the sources are *not* independent — code needs the exception and container that logs produce, so it belongs in the second round.
5. **Two or three collectors in the first round**, not five. Skip any source that cannot bear on the ask and record the skip as a limitation.
6. **Mongo, BigQuery, Stripe stay inline** (see below) — their prod and cost gates need the main context.

## Phase 1 — Collect

Fork collectors — invoke via the **Skill tool**, independent ones in the same message. Pass as args: the ask, ALL known identifiers, the time window, and the environment.

| Collector skill | Round | Owns | Reads |
|---|---|---|---|
| `inv-sentry` | first | client issues / events / alert rules: counts, first- and last-seen, tags, stack symbol, release | `.claude/skills/sentry/references/sentry.md` |
| `inv-gcp` | first | backend log scope and the log ladder: aggregations, the error row, the trace, the actor's neighbourhood | `.claude/skills/gcp/references/gcp-logs.md` |
| `inv-code` | **second, by default** | throw site / mapping / commit; deployed state = `origin/<default-branch>`, never checkout | repo checkouts |

`inv-code` earns its cost once you can hand it a container, an exception type and the runtime values the logs revealed — then it answers a question instead of exploring. Send it in the first round only when the ask is inherently about code ("when did this change", "which release") or the log source is down.

Run **inline in the main context**, not as collectors: `mongo` (prod needs an explicit flag and URI), `bq` (every query bills on bytes scanned — the cost gate is interactive), `stripe`, `amplitude-events`. Fallback if fork skills are unavailable: Explore agents with the same reference file and output contract (see `orchestration`).

## Phase 2 — Synthesize (inline)

- **New identifiers loop back through the routing table**, not through a history search — an exception type or account id that a collector surfaced may open a source you skipped.
- Correlate across sources: Sentry event (client view) ↔ backend request logs (`AccountId` prefix gotcha) ↔ Mongo document ↔ source and git history.
- **Name the mechanism, not the symptom** — a finding reaches file:line (the throw site, the mapping, the commit). "Errors went up" is scope, not a finding.
- **Time-box**: two dead-ended approaches to a sub-question → record a limitation and move on. An honest gap beats a guessed answer.

## Triage heuristics (platform)

- The BFF often returns HTTP **200 with an error JSON body** — error envelopes hide from StatusCode filters (search `ResponseBodyText`).
- Auth-gated log fields (`AccountId`, `UserEmail`) are missing on early-pipeline failures — fall back to container-wide `severity>=ERROR`.
- 403 `forbidden` spikes from iOS ⇒ usually the client calling JWT-only endpoints without a session (`AuthenticationInfoMissedException`) before suspecting the backend.
- Identical Sentry counts across two issues ⇒ likely one client screen calling both endpoints.
- High occurrences / few users ⇒ a retry loop, not breadth — check per-account aggregation.
- "Production-only" + the same code healthy in test ⇒ a per-account or state issue, not a code break.

## Report

Answer in chat: symptom → scope (numbers) → mechanism (file:line) → what to do about it. Every finding carries a citation (Sentry short-id, the exact log query, `repo/path:line`, commit sha). List what was not checked as limitations — including the sources you deliberately skipped.

No files are written by default. If the user asks for a write-up, use the `docs` skill and put it where they name.
