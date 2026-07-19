---
name: sentry
description: Sentry toolkit (org getpaid-inc) for iOS / Android / web CLIENT errors (there is no backend/.NET project in Sentry — backend errors live in GCP Cloud Logging, use the gcp skill). ALWAYS invoke before ANY Sentry API call. Use it whenever the task names a Sentry issue short-id (e.g. `INVOICE-MAKER-IOS-2Z6`), a `sentry.io/.../alerts/rules/` URL, "what's this crash/exception", errors for a given user email or account id, or "search Sentry for X". GET-only via the header-file curl form; never resolves issues, never echoes the token. For a full multi-source investigation start with investigate instead.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Purpose

`/sentry` is the Sentry **operations** toolkit: the op → endpoint mapping and inference rules for one-off lookups.

**Endpoints, curl shapes, auth, project slugs, the alert-decoding flow, the accountId gotcha, and the client source-repo map live in ONE place:** `.claude/skills/sentry/references/sentry.md`. **Read it before composing any Sentry call** and use its exact command form:

```bash
curl -s "https://sentry.io/api/0/..." -H @C:/Git/Work/Backend/.tofu-ai/sentry-header.txt
```

Non-negotiables from the reference (repeated because they gate execution): Bash tool only; auth ONLY via the header file (never env vars, never an inline token — redact any captured output to `<SENTRY_TOKEN>`); URLs start exactly `https://sentry.io/api/0/` (the `getpaid-inc.sentry.io` form is blocked by the allowlist); **GET only**.

**Project the response — never dump the whole event.** A latest-event payload (`issues/{id}/events/latest/`) is large (breadcrumbs, contexts, full stacktrace — tens of KB) and is re-read into context on every later tool turn. **`jq` is NOT installed in this environment** — pipe the curl through `python` to keep only what you need:

```bash
curl -s "https://sentry.io/api/0/.../events/latest/" -H @C:/Git/Work/Backend/.tofu-ai/sentry-header.txt \
 | python -c "import json,sys; e=json.load(sys.stdin); exc=[{'type':v.get('type'),'value':v.get('value')} for x in e.get('entries',[]) if x.get('type')=='exception' for v in x['data']['values']]; print(json.dumps({'title':e.get('title'),'culprit':e.get('culprit'),'user':(e.get('user') or {}).get('email'),'trace':((e.get('contexts') or {}).get('trace') or {}).get('trace_id'),'exception':exc},indent=1))"
```

For the **events search** endpoint, project **server-side** with `&field=…` (as in the reference examples) — no jq/python needed. Dump the raw JSON into the transcript only when the user explicitly asks for the full event. **Use the header file by absolute path** (`@C:/Git/Work/Backend/.tofu-ai/sentry-header.txt`) so the command works regardless of the Bash tool's current directory — the relative `@.tofu-ai/…` form only resolves from the workspace root.

For investigations (folder + write-up workflow) use the `investigate` skill; `/sentry` is for one-off lookups.

## Operations

| Op | Usage | Description |
|---|---|---|
| **issue** | `/sentry issue <issue-id-or-short-id>` | Latest event for an issue (tags, user, breadcrumbs, exception, contexts). Short-id → resolve numeric id first. |
| **event** | `/sentry event <event-id> [<project>]` | Specific event by 32-char hex id; resolve its project via the `eventids` endpoint if unknown. |
| **alert** | `/sentry alert <rule-id> [<incident-id>]` | Decode an alert URL: rule definition FIRST (what is monitored), then the incident. |
| **user** | `/sentry user <email-or-id> [<project>] [<freshness>]` | Issues/events tagged with an end-user. Default freshness `14d`. |
| **account** | `/sentry account <account-id-prefix> [<project>] [<freshness>]` | Search by `accountId` tag — Sentry stores **only the first segment** of the backend `AccountId`. Default `30d`. |
| **search** | `/sentry search <query> [<project>] [<freshness>]` | Raw pass-through of Sentry query syntax. Default `30d`. |

If no operation is given, infer — numeric id → `issue`, 32-char hex → `event`, `@`-containing → `user`, an `alerts/rules/details/` URL → `alert`; otherwise ask.

## Cross-reference to backend logs

Canonical pattern: event → `tags.accountId` prefix / `user.email` + `dateCreated` → backend request logs in a tight window (`jsonPayload.properties.AccountId=~"^<prefix>"`, see the gcp-logs reference); `contexts.trace.trace_id` present → straight to `/gcp trace`. ⚠️ `tags.environment` ≠ GCP project — check it before assuming prod.

## Safety

- Read-only: no `POST`/`PUT`/`DELETE` (don't resolve issues, don't update tags) without explicit user confirmation.
- The token (inside `.tofu-ai/sentry-header.txt`) is a personal auth token — never paste it into chat, PRs, or captured output.
- Client source repos (for stack frames) are read-only context — never edit or commit into them; map in the reference file.
- When the endpoint, auth, or repo map changes, update `.claude/skills/sentry/references/sentry.md` once, not this file.
