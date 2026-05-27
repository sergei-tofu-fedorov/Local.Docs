# Double Charge Notifications — Overview

**Task**: [WEB-1226](https://app.clickup.com/t/24553599/WEB-1226) | **Initiative**: [WEB-1207](https://app.clickup.com/t/869cgd2mr)

## Overview

When users migrate from Invoice Maker (IM) to FSM/Tofu, they can end up with two active subscriptions — the old one (Apple Store via IM) and a new one (Stripe or FSM iOS). Apple and Google do not auto-cancel old subscriptions. This feature adds:

1. **Duplicate subscription alerts** — `plans/current` and `plans/active` endpoints return data for clients to show a double-charge warning
2. **Scheduled notifications** — email and push reminders sent on a schedule to users who ignore the alert

## API Contract Changes

### `GET /plans/current` — Response

New field added to `PlanDto`:

```json
{
  "isActive": true,
  "planId": "fsmSolo",
  "expirationTime": "2026-04-05T00:00:00Z",
  "adapterType": 3,
  ...
  "hasDuplicateSubscriptions": true     // NEW — true if 2+ active renewing subscriptions exist
}
```

### `GET /plans/active` — Request

No request changes. `CustomerPortalLink` is resolved server-side from the calling app's `ProductKey` header — no client parameter needed.

| ProductKey | Portal return URL | Notes |
|-----------|-------------------|-------|
| `invoices` (IM iOS) | `invoices://close_managment` | Deep link back to IM app |
| `tofu` / `tofu-fieldservice` | `tofu://close_managment` | Deep link back to Tofu app |
| `invoices.web`, `invoices-android`, other | `null` | Web uses existing `subscription-management-link` endpoint |

### `GET /plans/active` — Response

New fields added to each `ActivePlanDto`:

```json
[
  {
    "productType": "fsmSolo",
    "duration": "month",
    "adapterType": "Stripe",
    "productKey": "tofu",
    "expirationTime": "2026-04-05T00:00:00Z",           // NEW
    "originProductId": "com.getpaidapp.fsm.solo",        // NEW
    "isPrimary": true,                                    // NEW
    "isAutoRenewEnabled": true,                            // NEW
    "customerPortalLink": "https://billing.stripe.com/p/session/..."  // NEW — Stripe/Paddle only
  },
  {
    "productType": "plus",
    "duration": "week",
    "adapterType": "AppleStore",
    "productKey": "invoices",
    "expirationTime": "2026-03-28T00:00:00Z",
    "originProductId": "com.getpaidapp.invoices.plus.weekly",
    "isPrimary": false,
    "isAutoRenewEnabled": true,
    "customerPortalLink": null                            // Apple — no portal
  }
]
```

| Field | Type | New? | Description |
|-------|------|------|-------------|
| `expirationTime` | `DateTime?` | **New** | Subscription renewal/expiration date |
| `originProductId` | `string?` | **New** | External product identifier |
| `isPrimary` | `bool` | **New** | `true` for the subscription selected by `GetPrimarySubscription()` |
| `isAutoRenewEnabled` | `bool?` | **New** | `true` if auto-renews, `false` if cancelled. Cancelled subs are not treated as duplicates. |
| `customerPortalLink` | `string?` | **New** | Stripe/Paddle management URL. `null` for Apple/Google or unsupported platforms. |

## Notification Schedule

Timing is relative to **billing switch** (`newSubscription.StartTime`), not detection time.

**Normal flow** (old sub charges in >= 48h from billing switch):

| Rule | Timing | Channels |
|------|--------|----------|
| 1 | 24h after billing switch | Email |
| 2 | 3 days after billing switch | Email + Push |
| 3 | 48h before old subscription charge | Critical Email + Push |
| 5 | 48h before each subsequent charge (recurring) | Email + Push |

**Urgent flow** (old sub charges in < 48h from billing switch):

| Rule | Timing | Channels |
|------|--------|----------|
| 4 | 1h after billing switch | Email + Push |
| 5 | 48h before each subsequent charge (recurring) | Email + Push |

**Late detection**: when detection happens after some rules are already overdue, send only the latest overdue notification and wait for next pending.

Push leads to the alert screen in Invoice Maker.

### Email Templates ([WEB-1248](https://app.clickup.com/t/869cjuybk))

Single SendGrid template `d-e71e8740b455461394c60d524ad7846d` (Brevo `#32`) with `type` parameter selecting the variant:

| Rule | `type` | `subject` |
|------|--------|-----------|
| 1 (24h) | `24hNotice` | Action needed: Avoid double charges |
| 2 (3d) | `3dReminder` | Reminder: Cancel your Apple subscription |
| 3 (48h before charge) | `preCharge` | Urgent: Avoid double charges |
| 5 (recurring) | `recurring` | Notice: Active Apple subscription detected |

Params: `{ type, subject, subscription_name, date }`

Designs: [Figma](https://www.figma.com/design/9B37t6gnYeC52eZ9vaSErf/Multi-platform-subs?node-id=1439-6552&m=dev)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Phase 1: Invoices.Api                                           │
│                                                                  │
│  GET /plans/current  (iOS + Web)                                 │
│    ↓ detects duplicates among active renewing subs               │
│    ↓ returns HasDuplicateSubscriptions in PlanDto                │
│    ↓ INotificationScheduler.ScheduleAsync (atomic)               │
│                                                                  │
│  GET /plans/active                                               │
│    ↓ returns ExpirationTime, OriginProductId, IsPrimary,         │
│      IsAutoRenewEnabled, CustomerPortalLink                      │
└──────────────────────────┬──────────────────────────────────────┘
                           │ Phase 2: Hangfire picks up on Worker
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  NotificationProcessHandler (generic state machine engine)       │
│    state + context from job params, job_id check for retry guard │
│    builds NotificationProcess model → model.Advance()            │
│    enqueues deliveries + schedules next job (atomic)             │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  NotificationProcess (Phase 3 — rich domain model)               │
│    stateless state machine inside                                │
│    Init → Rules → AwaitingRenewal → Recurring                    │
│    re-verifies from Subz at each step                            │
│    returns new state + deliveries + next wake time               │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  EmailDeliveryJob / PushDeliveryJob (generic, reusable)          │
│    EmailService (SendGrid) + PushService (OnePush)               │
│    correlation ID logged for duplicate detection                 │
└─────────────────────────────────────────────────────────────────┘
```

**Four layers:**
1. **Detection** (PlansService) — detects duplicates, schedules process via `INotificationScheduler`
2. **Engine** (NotificationProcessHandler) — generic driver. State + context from job params, `notification_job` table for idempotency + retry guard (job_id check). Builds model, executes transitions atomically.
3. **Model** (NotificationProcess) — rich domain model with `stateless` state machine. Pure logic, no side effects. Validates transitions.
4. **Delivery** (EmailDeliveryJob / PushDeliveryJob) — sends email/push with correlation ID. No knowledge of subscriptions.

**Detection approach**: Lazy — triggered by `GET /plans/current`. No background scanning. Idempotency via `INSERT ... ON CONFLICT DO NOTHING` on `process_state` table.

**State machine approach**: Rich domain model with `stateless` library. One Hangfire job active at a time per account. State + context in job params. `notification_job` table for idempotency + retry guard (`hangfire_job_id`). Sequential by design — no overlapping rules, no ordering issues. Invalid transitions throw.

## Client API Usage

| Platform | `plans/current` | `plans/active` | Notes |
|----------|----------------|----------------|-------|
| iOS (IM + FSM) | On launch, foreground, login, purchase (30min cache) | No | Primary detection surface |
| Web | On init, account selection, payment status checks | On paywall open | Both endpoints |
| Android | No — uses `GET /api/account/subscription` | No | Out of scope |

## Sub-documents

| Phase | Doc | Topic |
|-------|-----|-------|
| 1 | [Alerts](1_alerts.md) | API contract changes: `plans/current` + `plans/active` enrichment |
| 2.1 | [Hangfire Infrastructure](2_1_hangfire_infrastructure.md) | Hangfire setup, CorrelationIdFilter, TransactionalJobBase, `notification_job` table, generic delivery jobs |
| 2.2 | [Notification Scheduler](2_2_notification_scheduler.md) | INotificationScheduler — entry point for starting notification processes |
| 2.3 | [Process Handler](2_3_notification_process_handler.md) | NotificationProcessHandler — state machine engine, retry guard, ProcessResult |
| 3 | [Duplicate Notification Flow](3_duplicate_notification_flow.md) | Rich domain model with `stateless`: detection → Init → Rules → Renewal → Recurring cycle |

## Implementation Order

1. **Phase 1: Alerts** — API contract changes. `HasDuplicateSubscriptions` on `plans/current`, new fields on `plans/active`. Pure response enrichment, no side effects. *(Done — deployed to dev2)*
2. **Phase 2: Notification Infrastructure** — split into two sub-docs:
   - **2.1 Hangfire Infrastructure** — Hangfire setup, `CorrelationIdFilter`, `TransactionalJobBase`, `notification_job` table (idempotency + retry guard), generic delivery jobs with `CorrelationId`.
   - **2.2 Notification Scheduler** — `INotificationScheduler` entry point (insert job + enqueue, atomic).
   - **2.3 Process Handler** — `NotificationProcessHandler` (state + context in job params, job_id retry guard), `ProcessResult`.
3. **Phase 3: Duplicate Notification Flow** — `NotificationProcess` rich domain model with `stateless` library + detection trigger in `PlansService`. States: Init → Rule1/2/3 → AwaitingRenewal → Recurring → Resolved.

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| Lazy detection on `plans/current` | Zero extra Subz calls; natural coverage via iOS foreground + web init |
| Exclude cancelled subs from duplicate detection | `IsAutoRenewEnabled == false` means sub will expire naturally — no double charge risk |
| Rich domain model with `stateless` | Invalid transitions throw. Model is pure logic — testable without mocking. `stateless` validates transition graph at runtime. |
| State + context in job params, table as retry guard | Minimal table (no state, no JSONB). `hangfire_job_id` provides retry safety (stale job_id → skip). No DB reads for state on each wake-up. |
| Universal `notification_job` table | Reusable for any future notification process (trial expiry, dunning, onboarding). One table, one handler framework, many models. |
| DB-level idempotency (INSERT ON CONFLICT) | Single DB roundtrip, consistent across API instances, no cache invalidation. Atomic with Hangfire enqueue via TransactionScope. |
| Correlation ID on deliveries | Links email + push from same trigger. Enables duplicate detection in logs. Each handler error = potential duplicate — correlation ID makes it measurable. |
| Each state re-verifies from Subz | Self-resolving: if user cancels at any point, next wake-up detects and terminates. Costs one Subz call per state transition. |
| `billingSwitchAt` = `newSubscription.StartTime` | Schedule anchored to actual purchase time, not detection time |
| Hardcoded portal return URLs per app | Backend resolves from `ProductKey`. No client parameter needed. |
