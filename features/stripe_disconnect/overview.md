# Stripe Disconnected Account Handling

## Goal

Handle Stripe Connect accounts that lose platform access so that background jobs stop retrying permanently-failed accounts, webhook handlers respond cleanly, and account status reflects reality.

## Background

The platform uses **Stripe Connect Standard** — users link their Stripe accounts via OAuth. When access is lost, Stripe returns `account_invalid` (HTTP 403). Currently:

- Account status remains `Connected` — background jobs keep retrying
- Worker jobs log at Error severity — alerts fire for a permanent, non-actionable condition
- Webhook handlers return HTTP 500 — Stripe retries for up to 72 hours
- Balance update jobs retry 3 times via Hangfire before failing

**Production impact:** 56+ distinct accounts generating ~370 error entries per week.

---

## Phased Approach

### Phase 1: Observability + Retry Prevention (current)

Log warnings and prevent retry storms without modifying account state in the database. This is safe to deploy without testing on web/mobile since no user-facing behavior changes.

- **Stripe client wrappers** — translate `account_invalid` into `PaymentAccountInvalidException`
- **Webhook handlers** — catch access errors, log Warning, return HTTP 200
- **Deauthorization webhook** — handle `account.application.deauthorized`, log Warning
- **Hangfire filter** — catch `PaymentProviderAccountInvalidException`, move job to Deleted state (no retry)
- **Worker jobs** — catch `PaymentAccountInvalidException`, log Warning, skip the account for this run

No `SoftEnabled` changes, no skip guards, no DB writes. Accounts continue to be retried on next scheduled run, but each attempt fails cleanly (Warning log, no Error alerts, no Hangfire retry storms).

### Phase 2: Disable Accounts (future, after testing)

Use the existing `SoftEnabled` flag to mark disconnected accounts as disabled. Requires testing on web + mobile to verify the "paused" UX works correctly for this scenario.

- Set `SoftEnabled = false` when `account_invalid` is detected
- Add skip guards in worker jobs for `SoftEnabled == false`
- Frontend already shows "paused" badge for `softEnabled = false`

### Why `SoftEnabled` (Phase 2)

The APT model already has two flags that control account state:

| Flag | Type | Meaning | UI effect |
|------|------|---------|-----------|
| `Enabled` | `bool` | Authentication completed | Blocks all payment operations |
| `SoftEnabled` | `bool?` | Provider active for use | Shows "paused" badge in frontend |

`SoftEnabled = false` doesn't distinguish "user paused" from "platform lost access." This is acceptable because the user action is the same either way — re-link via OAuth.

---

## Behavioral Contracts (Phase 1)

- **On `account_invalid` detection** — log Warning, do NOT modify account state
- **Webhook handlers** — catch access errors, log Warning, return HTTP 200
- **Background jobs** — if an invalid account is encountered at runtime, log Warning (not Error) and skip for this run
- **Stripe client wrappers** — translate `account_invalid` into a typed domain exception
- **Deauthorization webhook** — handle `account.application.deauthorized`, log Warning
- **Hangfire jobs** — filter catches the exception and moves job to Deleted state (no retry)

### What needs changes

- Stripe client `UpdateAccount()` — has no error handling, needs `account_invalid` catch
- Webhook handlers — need to catch `PaymentAccountInvalidException` and return 200
- Hangfire balance sync — needs filter to prevent retries

---

## API and Client Impact

No API contract changes. `SoftEnabled` is already part of the `AuthenticatedPaymentTypeDto` response. Frontend already handles `softEnabled = false` by showing a "paused" badge. No frontend changes needed.

---

## Implementation Scope

### Phase 1 (current)

| Step | Service | What changes |
|------|---------|-------------|
| 1. Stripe client | Invoices.Backend | Add `account_invalid` handling to `UpdateAccount()` |
| 2. Webhooks | Invoices.Backend | Catch access errors in handlers, log Warning; add `account.application.deauthorized` handler (log only) |
| 3. Worker jobs | Invoices.Backend | Catch `PaymentAccountInvalidException`, log Warning, skip account for this run |
| 4. Balance sync | Tofu.Payments.Backend | Hangfire filter to prevent retries on `PaymentProviderAccountInvalidException` |

### Phase 2 (future — requires web + mobile testing)

| Step | Service | What changes |
|------|---------|-------------|
| 1. Mark disconnected | Invoices.Backend | Set `SoftEnabled = false` when `account_invalid` is caught |
| 2. Skip guards | Invoices.Backend | Skip APTs where `SoftEnabled = false` in worker jobs |

---

## Verification

### Phase 1
- `account_invalid` log entries appear at Warning severity only (not Error)
- No Hangfire retry storms for invalid accounts
- No `SoftEnabled` changes in MongoDB — account state unchanged

### Phase 2
- Affected accounts have `SoftEnabled = false` in MongoDB
- Background jobs skip disabled accounts
- Frontend shows "paused" for disconnected accounts
