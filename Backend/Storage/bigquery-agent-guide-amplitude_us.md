`amplitude_us` — dataset reference (schema · events · caveats)
==============================================================

Per-dataset appendix to [`bigquery-agent-guide.md`](bigquery-agent-guide.md). Read this **only when the routing table (guide §2) sends you to `amplitude_us`**. Identity model (`account_short` / `user_short` = `SUBSTR(...,1,25)`), the cheap single-account / single-master retrieval recipes (cookbook #14/#15), and cost rules live in the core guide; this file holds the event schema, key-event props, channel inventory, and denominators.

`amplitude_us` — product events bridge (iOS prod 213333 only)
-------------------------------------------------------------

Loaded daily 04:00 UTC (hours of lag — query full days ≤ yesterday). Rolling **90-day** partition expiration. Web project (586241) is NOT in BQ — reachable only via the Amplitude REST API.

| Table | Cluster | Contents |
|---|---|---|
| `src_amplitude_events` (~25M) | `event_type, user_id` | one row per event: `event_time`, `event_type`, `user_id`/`account_id` (25-char short ids), `device_id`, `session_id`, `country`, `app_version`, `event_properties`/`user_properties` (JSON), `source_project` |
| `v_events_resolved` | (same pruning) | base table + `platform_user_id`, `account_id_full`, `master_user_id` — **the preferred entry point for aggregate / cohort queries** (resolution: user 99.6%, account 96.8%). For a single account's or one person's own events it is the WRONG choice — bypass it and hit `src_amplitude_events` directly (core cookbook #14/#15). |
| `sys_amplitude_export_state` | — | ingest watermark |

**Key events** (113 types total; props via `JSON_VALUE(event_properties,'$.…')`):

| Event | Key props | Notes |
|---|---|---|
| `Send invoice` / `Send estimate` | `application` (channel), `context`, `attachments_count`, `template`, `is_first_time` | completed channel pick; no `invoice_id`; `is_first_time` = first-ever send (activation), not a resend flag |
| `Tap send invoice` | `context`, `type` | intent tap BEFORE the share sheet — don't count as sends |
| `Payment received` | `payment_method` (Tap to Pay / Payment Link), `payment_provider`, `payment_provider_method_type` (card/link/us_bank_account/…), `payment_fee_paid_by`, `amount`, `currency` | per-payment fee passthrough |
| `Payment fee changed` | `is_fee_enabled` | user toggled fee onto the client |
| `Invoice Paid` | `invoice_id`, `payment_provider` | one of the few events WITH invoice_id |
| `Mark invoice` | `to_status`, `context` | paid-status changes only; there is NO mark-as-sent event on iOS |
| `Server error` | `traceId`, `error_code`, `url` | bridge to GCP request logs |
| `Sign in` | `master_id`, `is_new_master`, `auth_method` | master identity linkage |
| `Subscription paid` | (see Subz note) | Subscription renewal charge. One of the server-emitted **Subz billing events** below — a store charge, not an app action. |

**Server-emitted billing events (Subz pipeline) — present here, but NOT in-app activity.** A separate billing service **Subz** (repo `C:\Git\Work\Subz`, deploys to `inv-project`; no code in this workspace) publishes subscription/account lifecycle events to Pub/Sub, and its `Handler.Amplitude` posts **13 event types** straight to the Amplitude HTTP API — independent of whether the user opened the app. They land in `amplitude_us` **mixed in with client events**.

**Exact `event_type` strings present in `amplitude_us` (iOS project, verified live 2026-07) — treat as NON-activity when measuring what a user *did* in the app:**
- **Subz billing** (`account_id` NULL): `Subscription paid`, `Subscription expired`, `Subscription restored`, `Subscription cancelled`, `Renew state changed`, `Renew product changed`, `Billing retry`, `Trial started`, `Account created`, `Account platform linked`. The Amplitude strings do **not** match the business/contract names (`Renew state changed` = renewal-changed; `Subscription restored`/`cancelled` = restore/refund) and most don't contain "subscription" — a `LIKE '%subscri%'` search **misses** `Trial started`, `Renew …`, `Account …`, `Billing retry`. Match the explicit names. (The Subz contract set also has `Account updated` + 3× one-time-purchase, but those route to non-iOS products' Amplitude projects — not present here.)
- **BFF server-emitted** (`account_id` SET): `Push sent`, `Payment received`, `Payout received`, `Payment account status` (`Invoices.Backend`, `Src/Invoices.Common/Analytics/Events/*` — a push/email/payment fired, not a user tap).
- **Do NOT use `account_id IS NULL` as the "server" filter** — many pure-client events are also null (`session_start`, `Page Shown`, `[Amplitude] …` autocapture, `Server Error Occurred`). Use the explicit name lists above.

Authoritative source (business↔Amplitude name map + per-event fields): `Local.Docs/Backend/Flows/ANALYTICS_EVENTS_FLOWS.md` (Path 2) and `C:\Git\Work\Subz\docs\analytics-events.md`.

How Subz sets identity/routing (from `Subz…AmplitudeEvent` / `AmplitudeTracker`):
- **`user_id` = the account's `PublicId`** — same platform-user id-space as client events, so these events resolve to the same person via §1.5 (`user_short`). A `Subscription paid` appears under the same `user_id` as that person's app events (empirically confirmed).
- **No `account_id` and no `device_id` are sent** → `account_id` is NULL in the mirror and Amplitude synthesizes a per-event `device_id` (why it differs from the user's real device). Their presence still proves the person is Amplitude-tracked.
- **Amplitude project** is chosen by `productKey` → a per-product API key (`ApiKeyProduction`/`ApiKeySandbox`, env picks which). Billing events go to the same per-product project as that product's client events.
- For subscription **state** (active/expired/plan) use `ai_analysis_us.mart_account_subscriptions`, not these events — they are triggers, not state (Subz enriched events don't even carry an expiration time, only a duration).

**Send channel inventory** (`Send invoice.application`, iOS 90d snapshot 2026-07):

| Channel | Share | Meaning |
|---|---|---|
| `mail_server` | ~34% | our backend email — the only backend-visible channel |
| `com.apple.UIKit.activity.Message` | ~20% | iMessage / SMS |
| WhatsApp (+SMB extension) | ~13% | |
| `com.apple.UIKit.activity.Print` | ~11% | paper / print-to-PDF |
| third-party mail apps (Mail.app, Gmail, Outlook, Yahoo) | ~10% | still email, but outside our service |
| `…SaveToFiles` / `…CopyToPasteboard` | ~9% | export / link copy |
| rest (AirDrop, Telegram, Messenger, Drive…) | ~3% | long tail |

**Denominator recipe:** MAU = `COUNT(DISTINCT platform_user_id)` over any events in the month via `v_events_resolved` (~185–190K iOS); senders ≈ 18–19% of MAU; sender activity has a heavy tail (median 3–4 sends/month, p90 ≈ 17–19) — report medians.
