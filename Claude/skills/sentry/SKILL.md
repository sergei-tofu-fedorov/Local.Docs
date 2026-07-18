---
name: sentry
description: Sentry toolkit (org getpaid-inc) for iOS / web / backend client errors. ALWAYS invoke before ANY Sentry API call. Use it whenever the task names a Sentry issue short-id (e.g. `INVOICE-MAKER-IOS-2Z6`), a `sentry.io/.../alerts/rules/` URL, "what's this crash/exception", errors for a given user email or account id, or "search Sentry for X". GET-only via the header-file curl form; never resolves issues, never echoes the token. For a full multi-source investigation start with investigate instead.
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
curl -s "https://sentry.io/api/0/..." -H @.tofu-ai/sentry-header.txt
```

Non-negotiables from the reference (repeated because they gate execution): Bash tool only; auth ONLY via the header file (never env vars, never an inline token — redact any captured output to `<SENTRY_TOKEN>`); URLs start exactly `https://sentry.io/api/0/` (the `getpaid-inc.sentry.io` form is blocked by the allowlist); **GET only**.

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
