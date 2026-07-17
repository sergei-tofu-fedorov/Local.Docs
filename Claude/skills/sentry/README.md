# /sentry Skill - Quick Reference

Query Sentry (org `getpaid-inc`) for iOS / web / backend client errors. Read-only. Callable directly or from the `investigate` skill.

## Relationship to `investigate` and `/gcp`

- Endpoint shapes, auth (header file `.tofu-ai/sentry-header.txt`), project slugs, the client source-repo map: `.claude/skills/sentry/references/sentry.md` (single source).
- The `investigate` skill owns the **investigation folder + write-up**; its collectors read the same reference.
- `/gcp` owns **backend logs**; `/sentry` hands off (timestamp + `accountId` prefix + `trace_id`) for cross-referencing.

## Commands

| Command | Description |
|---------|-------------|
| `/sentry issue <issue-id>` | Latest event for a Sentry issue (tags, user, breadcrumbs, exception, contexts) |
| `/sentry event <event-id> [<project>]` | A specific event by its 32-char hex ID |
| `/sentry user <email-or-id> [<project>] [<freshness>]` | Events tagged with this end-user (`user.email:` / `user.id:`) |
| `/sentry account <account-prefix> [<project>] [<freshness>]` | Search by `accountId` tag — Sentry stores only the **first segment** of backend `AccountId` |
| `/sentry search <query> [<project>] [<freshness>]` | Raw Sentry issue search syntax |

Default `<freshness>`: `14d` (`user`) / `30d` (`account`/`search`).

## Examples

```bash
# Triage an issue
/sentry issue 7506121527

# All events for a user in the FS iOS app, last 30 days
/sentry user reggiepierre1819@gmail.com fieldservice-ios 30d

# Sentry stores AccountId prefix only — match by first segment
/sentry account tqo3qjs5x5

# Raw search
/sentry search 'is:unresolved release:1.11.0 environment:production'
```

## Cross-reference to backend logs

Pull `tags.accountId` / `user.email` / `dateCreated` (and `contexts.trace.trace_id` if present) → hand to `/gcp` (or `/inv logs` when an investigation is active). Backend logs use the **full** `AccountId`; match the Sentry prefix with `jsonPayload.properties.AccountId=~"^<prefix>"`. ⚠️ `tags.environment` ≠ GCP project — check it before assuming prod.

## Client source repos (for resolving Sentry stack frames)

Read-only context outside this workspace:

| Sentry project(s) | Repo |
|---|---|
| `invoice-maker-ios`, `fieldservice-ios` | `C:\Git\Work\Invoices.Apps.iOS` (Tuist dual-app) |
| `fieldservice-worker-ios`, `fieldservice-worker-android` | KMM — GitHub `m-unicorn/Tofu.FieldService.WorkerApp` (clone to `C:\Git\Work\Tofu.FieldService.WorkerApp`) |
| `tofu-web-frontend`, `invoice-generator` | `C:\Git\Work\Tofu.Web.Frontend` |

Never edit or commit into these repos from this skill.

## Safety

- The auth token is a **personal user token** — treat like a password; redact to `<SENTRY_TOKEN>` in any captured output.
- Read-only by default; no mutations (resolve/assign/tag) without explicit confirmation.

## Where the skill lives

Canon: `Local.Docs/Claude/skills/sentry/` (runtime copy: `C:/Git/Work/Backend/.claude/skills/sentry/`, one-way synced).
