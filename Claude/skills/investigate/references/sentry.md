# Sentry reference (org: getpaid-inc) — single source of truth

REST recipes for investigation collectors AND for the `sentry` skill. **GET only — never POST/PUT/DELETE** (don't resolve issues, don't update tags). Keep calls to a handful per investigation (rate limits unpublished).

**Contents:** Auth + command shape · Projects · Decoding an alert URL · Issues and events · Searching · accountId cross-referencing with backend logs · Client source repos · Conventions for findings

## Auth + command shape (sandbox-safe — the ONLY approved form)

```bash
curl -s "https://sentry.io/api/0/..." -H @.tofu-ai/sentry-header.txt
```

- Auth comes from the pre-materialized header file `.tofu-ai/sentry-header.txt` (run from the workspace root). The token inside is a personal user auth token — never echo it to chat, never write it into captured output (redact to `<SENTRY_TOKEN>`).
- ⚠️ NEVER reference `$SENTRY_ACCESS_TOKEN` (or any env var) inside commands — the sandbox rejects commands containing variable expansion. The `-H @file` form exists precisely to avoid that.
- ⚠️ Use the **Bash tool** (not PowerShell) and keep the exact shape above — the permission allowlist matches this literal prefix; reordered flags or other tools get gated.
- ⚠️ Every URL must start exactly `https://sentry.io/api/0/` — the org-subdomain form `getpaid-inc.sentry.io` **will be blocked** by the allowlist.

## Projects (slugs)

`invoices-backend`, `invoices-web`, `invoice-generator`, `invoice-maker-ios`, `fieldservice-ios`, `fieldservice-worker-ios`, `fieldservice-worker-android`, `tofu-web-frontend`. Some endpoints need the **numeric** project id — discover via `GET /api/0/organizations/getpaid-inc/projects/`.

## Decoding an alert URL

`https://getpaid-inc.sentry.io/alerts/rules/details/<RULE_ID>/?alert=<INCIDENT_ID>&…`

```bash
# The rule definition — project, aggregate/query, thresholds, window. Do this FIRST: it tells you what is monitored.
curl -s "https://sentry.io/api/0/organizations/getpaid-inc/alert-rules/<RULE_ID>/" -H @.tofu-ai/sentry-header.txt

# The incident — when it fired, status, the values that tripped it
curl -s "https://sentry.io/api/0/organizations/getpaid-inc/incidents/<INCIDENT_ID>/" -H @.tofu-ai/sentry-header.txt
```

With the rule in hand, attribute the alert by querying that project's issues within the rule's window — don't guess from org-wide spikes.

## Issues and events

```bash
# Issue by short-id (INVOICE-MAKER-IOS-2Z6 style) → numeric id, counts, status
curl -s "https://sentry.io/api/0/organizations/getpaid-inc/issues/?query=<SHORT_ID>&project=-1" -H @.tofu-ai/sentry-header.txt

# Latest full event for an issue (tags, user, breadcrumbs, exception, contexts)
curl -s "https://sentry.io/api/0/issues/<NUMERIC_ISSUE_ID>/events/latest/" -H @.tofu-ai/sentry-header.txt

# Specific event by 32-char hex id; resolve its project first if unknown:
curl -s "https://sentry.io/api/0/organizations/getpaid-inc/eventids/<EVENT_ID>/" -H @.tofu-ai/sentry-header.txt
curl -s "https://sentry.io/api/0/projects/getpaid-inc/<project>/events/<EVENT_ID>/" -H @.tofu-ai/sentry-header.txt

# Event counts over time — spike-onset timestamps
curl -s "https://sentry.io/api/0/organizations/getpaid-inc/issues/<NUMERIC_ISSUE_ID>/stats/?stat=count&statsPeriod=24h" -H @.tofu-ai/sentry-header.txt
```

## Searching

```bash
# Raw issue search (Sentry query syntax: is:unresolved, release:, environment:, title:"...")
curl -s "https://sentry.io/api/0/organizations/getpaid-inc/issues/?query=<QUERY>&statsPeriod=14d" -H @.tofu-ai/sentry-header.txt

# By end-user
...issues/?query=user.email:foo@bar.com&statsPeriod=14d

# Per-event hits (not aggregated issues): the events endpoint with explicit fields
curl -s "https://sentry.io/api/0/organizations/getpaid-inc/events/?query=user.email:foo@bar.com&statsPeriod=14d&field=id&field=timestamp&field=title&field=project" -H @.tofu-ai/sentry-header.txt
```

Sentry query syntax: https://docs.sentry.io/concepts/search/

## Cross-referencing with backend logs — the accountId gotcha

Sentry's `accountId` tag stores **only the first segment** of the backend `AccountId` (up to the first `-`); confirmed in `Investigations/investigations/sentry-fieldservice-ios-2026-05-26/`.

- Sentry side: `...issues/?query=accountId:<prefix>&statsPeriod=30d`
- Backend side (full value): `jsonPayload.properties.AccountId=~"^<prefix>"` — see `gcp-logs.md`.

Canonical correlation: Sentry event → `tags.accountId` / `user.email` + `dateCreated` → backend request logs in a tight window around that timestamp; if the event has `contexts.trace.trace_id`, use the LB/app trace join directly.

⚠️ `tags.environment` (`development` vs `production`) is **not** the GCP project — check it before assuming prod, then pick the matching project.

## Client source repos (resolving stack frames)

When an event names a client-side function/file, the source is a sibling repo **outside this workspace** — read-only context, never edit/commit there:

| Sentry project(s) | Repo | Notes |
|---|---|---|
| `invoice-maker-ios`, `fieldservice-ios` | `C:\Git\Work\Invoices.Apps.iOS` | iOS monorepo (Tuist), dual-app: InvoiceMaker (`com.getpaidapp.invoices`) + FieldService (`com.getpaidapp.fieldservice`). `fastlane/Matchfile` also signs `com.getpaidapp.worker.iosApp` but its source is NOT here |
| `fieldservice-worker-ios`, `fieldservice-worker-android` | GitHub `m-unicorn/Tofu.FieldService.WorkerApp` → clone to `C:\Git\Work\Tofu.FieldService.WorkerApp` (ask before cloning) | Kotlin Multiplatform; gitlive Firebase wrapper (`dev.gitlive.firebase.auth.*`); unhandled Kotlin exceptions cross the Swift boundary as `NSException` |
| `tofu-web-frontend`, `invoice-generator` | `C:\Git\Work\Tofu.Web.Frontend` | Vue/pnpm |

Use them to resolve a frame to source, check whether a fix already shipped in a newer release, or diff the failing-release tag to scope a regression window.

## Conventions for findings

- Always cite the **issue short-id** (e.g. `INVOICE-MAKER-IOS-2Z6`) as a `sentry-issue` citation — it is the cross-investigation dedupe key.
- Quote occurrence/user counts and first-seen/last-seen — they distinguish "chronic" from "new regression".
