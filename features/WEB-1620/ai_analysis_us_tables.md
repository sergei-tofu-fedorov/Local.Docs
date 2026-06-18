# ai_analysis_us — sku_mapping clone + account_subscriptions (WEB-1620)

**Status:** deployed 2026-06-18. Two daily Scheduled Queries live in `inv-project` (US), runner
`playfair-invoices@inv-project.iam.gserviceaccount.com`. Both write inside `inv-project` (no cross-project).

Companion to [`README.md`](README.md) (the playfair `dbt_external.sku_mapping` job). This doc covers the
two tables added in **`inv-project.ai_analysis_us`**.

## 1. `ai_analysis_us.sku_mapping` — event-derived SKU catalog (clone)

Identical build logic to the playfair `dbt_external.sku_mapping` job; only the MERGE target changed to
`inv-project.ai_analysis_us.sku_mapping`. Because the job already runs/bills in `inv-project`, no
cross-project write is involved. Per-column logic: see [`sku-mapping-logic.md`](sku-mapping-logic.md) and
[`fields.md`](fields.md).

- **SQL:** [`sku_mapping_merge_ai_analysis_us.sql`](sku_mapping_merge_ai_analysis_us.sql) (insert-only MERGE).
- **Schema:** `app_name, product_id, sub_length, trial_period, sub_price, trial_price, first_seen_date`.
- **Rows:** 69 (the event-derived set). The playfair copy has 91 because it was seeded from the manual
  `tofu_sku_mapping` catalog first; this fresh table holds only what events produce.
- **Schedule:** `sku_mapping daily upsert (ai_analysis_us)` — `transferConfigs/6a62cdb1-0000-29a5-a256-3c286d38a092`, every 24h.
- **Cost:** ~5 GB/run ≈ $0.025/day.

## 2. `ai_analysis_us.account_subscriptions` — active subscription + expiration

Per-subscription snapshot, **rebuilt daily** (`CREATE OR REPLACE TABLE … AS SELECT`). **Clustered by `platform_user_id`.**

- **Grain:** one row per `(app_name, account_id, original_transaction_id)`. Trials included.
- **SQL:** [`account_subscriptions_rebuild.sql`](account_subscriptions_rebuild.sql).
- **Schedule:** `account_subscriptions daily rebuild (ai_analysis_us)` — `transferConfigs/6a54e8ab-0000-27f6-a17e-94eb2c0451f8`, every 24h.
- **Cost:** ~5.3 GB/run ≈ $0.026/day.

### account_id is the SUBSCRIBER, resolved to the PLATFORM USER (who owns N invoices accounts)
`analytics.events.account_id` is the account's **PublicId** — written by the Subz per-store analytics writers
(`Subz.IOS…/BigQuery/BigQueryEvent.cs:102`, `Subz.Android…/Tracking/BigQueryEvent.cs:84`: `account_id =
_account.PublicId`). PublicId = the **first 25 chars of the platform user id** (`Invoices.Core/Models/Account.cs:72`
`GetShortUserId`, used in `AccountController.cs:190`). It is a Subz/platform-user id, NOT the invoices account
id (`10char-32hex-32hex`), and is not stored on the invoices `accounts` collection.

**Correct bridge — via the platform user (table 3, `platform_user_accounts`):**
`events.account_id (PublicId) == SUBSTR(masterUser…PlatformId, 1, 25)` → `master_user_id` → `OwnedAccounts[].AccountId`
(**one platform user owns N invoices accounts** — ~70K users own 2+). Resolution order used in
`account_subscriptions`:
1. **masterUser** first → `platform_user_id` + `master_user_id` (and owned accounts via `platform_user_accounts`).
2. **accountIdentifiers** fallback (table 4) → recovers the full `platform_user_id` from its `UserId`
   (since PublicId = `SUBSTR(UserId,1,25)`) when the user has no masterUser doc (anonymous/unlinked).

Coverage: masterUser alone ~31% all / ~63% last-30d (authenticated users only); **masterUser + accountIdentifiers
fallback = 96.5% of subs** (masterUser 202K, fallback 684K, unresolved 3.5%). `user_resolved_via` records the source.
`account_subscriptions` is **one row per subscription** (per platform user); expand to accounts by joining
`master_user_id` → `platform_user_accounts`.

## 3. `ai_analysis_us.platform_user_accounts` — platform-user ↔ owned-accounts bridge (primary)

Loaded from the Atlas snapshot `masterUser` collection by the **tofu-ai SA**. **Clustered by `platform_user_id`.**
One row per `(PlatformUserLink × OwnedAccount)`: `master_user_id, platform_user_id, public_id (= PlatformId[:25]),
platform (1=mobile,3=web), product, account_id, user_deleted`. ~468K pairs / ~351K users / ~459K accounts.
- The `masterUser` model only covers authenticated/linked users → not all subscribers are present (hence the
  accountIdentifiers fallback).
- ⚠️ **No auto-refresh** (snapshot path is a daily folder, nested-array docs) → re-run
  **[`reload_master_user.sh`](reload_master_user.sh)** periodically.

## 4. `ai_analysis_us.account_identifiers` — fallback bridge (device ids + UserId)

Loaded from the Atlas `accountIdentifiers` collection by the **tofu-ai SA**. Columns:
`account_id (= _id, invoices account), user_id, firebase_id (UPPER), idfa (UPPER), appsflyer_id, vendor_id`.
8.19M rows. Used here only as the **fallback** to recover `platform_user_id` from `SUBSTR(user_id,1,25)`.
(The earlier interim `tofu_account_id` columns on `account_subscriptions` — a direct device-id→account guess —
are kept for reference but superseded by the platform-user path.)
- ⚠️ **No auto-refresh** → re-run **[`reload_account_identifiers.sh`](reload_account_identifiers.sh)** periodically.
- Both Atlas loads handle **MongoDB Extended JSON** (`$numberInt`/`$oid`) by staging each line as one raw STRING
  and parsing with `JSON_VALUE` (autodetect fails on `$`-prefixed field names).

### Expiration is computed (Subz never emits an expiry timestamp)
Confirmed in Subz code (`EnrichedSubscriptionExpiredEventHandler` carries only `Duration`). Mirrors the
Playfair DWH `subs_user_subscriptions_periods` pattern:
- `expires_at` = `last subscription_paid.event_time + sub_length_days` (trial-only:
  `trial_started.event_time + trial_period_days`, fallback **7 days** when trial length unknown — never the
  full sub length).
- Overridden by an explicit `subscription_expired` (natural expiry) or `subscription_cancelled` (= refund,
  per Subz this event maps from the **Refunded** handler with a negative price).

### Status / active semantics
- `status` ∈ {`active`, `trial`, `expired`, `refunded`}; `refunded` wins, then explicit `expired`, then
  `expires_at < now` ⇒ `expired`, else `trial` (paid_count=0 & has trial) / `active`.
- `is_active` BOOL = not refunded, not explicitly expired, computed `expires_at >= now`. (Grace periods are
  not separately modelled; Subz treats grace as active — events don't expose the grace window.)
- `auto_renew_enabled` = latest `renew_state_changed.renew_enabled` (NULL if never emitted).

### Columns
`app_name, account_id, platform_user_id, master_user_id, user_resolved_via, tofu_account_id, resolved_via,
original_transaction_id, product_id, store_country, firebase_id, appsflyer_id, idfa, sub_length_days,
trial_len_days, paid_count, is_trial, started_at, trial_started_at, last_paid_at, last_event_at, expired_at,
refunded_at, auto_renew_enabled, expires_at, status, is_active, updated_at`.

Join to invoices accounts via `master_user_id` → `platform_user_accounts.account_id` →
`accounts`/`invoices`/`account_metrics` (one subscription → potentially several accounts).
`platform_user_id` is the full id sent to Subz; `user_resolved_via` ∈ {masterUser, accountIdentifiers, NULL}.

### First-run shape (2026-06-18)
918,876 subs / 766,609 store accounts; status: expired · refunded 31,393 · active 24,138 · trial 1,403
(`is_active` = 25,540). Resolved to invoices account: **888,961 (96.7%)** — via appsflyer 447,987 ·
firebase 431,839 · idfa 9,135 · unresolved 29,915.

## Permissions note
The SA can CREATE tables, run DML, and CREATE scheduled queries in `inv-project` (the create call must omit
an explicit runner SA — naming itself triggers `iam.serviceAccounts.actAs`/org-policy denial). It CANNOT
list transfers (`transfers.get` on list denied) — fetch a config by full name instead. Auth/REST mechanics:
see [`README.md`](README.md) §"How to run things".
