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

**Bridge — match the subz `account_id` (PublicId) on UserId, NOT device identifiers.**
- **`tofu_account_id`** (invoices account): **accountIdentifiers** first — `account_id` (= invoices `_id`) where
  `SUBSTR(user_id,1,25) = subz account_id` — else the **masterUser first-link** owned account (`platform_user_accounts`).
- **`platform_user_id`**: the **canonical IsFirstLink identity** via `platform_user_canonical` (table 3b) — it maps
  ANY link's `public_id` → the master's first-link platform user, so a **non-first-link UserId still resolves to the
  first-link identity/subscription** — else the raw accountIdentifiers `user_id`. `master_user_id` comes from the same map.

`resolved_via` ∈ {`accountIdentifiers`, `masterUser-firstLink`}; `user_resolved_via` ∈ {`masterUser`,
`accountIdentifiers`}. **One platform user owns N invoices accounts** (~70K own 2+), so `tofu_account_id` is a single
representative account; expand to all accounts by joining `master_user_id` → `platform_user_accounts` (or
`master_users.accounts`). `account_subscriptions` is **one row per subscription**.
(Coverage figures below predate this change — re-measure after the next rebuild.)

## 3. masterUser-derived tables (source: Atlas `masterUser`, loaded by **tofu-ai SA** via [`reload_master_user.sh`](reload_master_user.sh))

⚠️ **No auto-refresh** (snapshot path is a daily folder, nested-array docs) → re-run the loader periodically. One
nested snapshot produces three objects:

**3a. `master_users` — nested source of truth** (clustered by `master_user_id`). One row per master user, no fan-out:
`master_user_id, user_deleted, links ARRAY<STRUCT<platform_user_id, public_id (= PlatformId[:25]), platform
(1=mobile,3=web), product, is_first_link, created_at>>, accounts ARRAY<STRUCT<account_id, assigned_by_platform_id>>`.
All first-link / by-product / canonical policy is applied downstream via `UNNEST` — change a view/query, not the table.

**3b. `platform_user_canonical` — VIEW.** `UNNEST`s the links so ANY link's `(platform_user_id, public_id)` maps to its
master's **IsFirstLink** identity (`first_link_platform_user_id`, `first_link_public_id`, `master_user_id`). This is what
lets a non-first-link UserId (e.g. from accountIdentifiers) resolve to the first-link platform user's subscription.

**3c. `platform_user_accounts` — materialized first-link bridge** (clustered by `platform_user_id`), derived from
`master_users` = canonical IsFirstLink link × owned accounts. Columns: `master_user_id, platform_user_id, public_id,
platform, product, account_id, user_deleted`. Kept materialized for clustering/compat. The `masterUser` model only
covers authenticated/linked users → not all subscribers present (hence the accountIdentifiers path).

## 4. `ai_analysis_us.account_identifiers` — fallback bridge (device ids + UserId)

Loaded from the Atlas `accountIdentifiers` collection by the **tofu-ai SA**. Columns:
`account_id (= _id, invoices account), user_id, firebase_id (UPPER), idfa (UPPER), appsflyer_id, vendor_id`.
8.19M rows. Now the **primary** resolver: `SUBSTR(user_id,1,25) = subz account_id` yields both `tofu_account_id`
(= `account_id`) and `platform_user_id` (= `user_id`); masterUser is the fallback. Device-id columns
(firebase/appsflyer/idfa) are no longer used for matching (kept on `account_subscriptions` as informational only).
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

### First-run shape (2026-06-18, pre-change — resolved-via numbers below are from the old device-id path)
918,876 subs / 766,609 store accounts; status: expired · refunded 31,393 · active 24,138 · trial 1,403
(`is_active` = 25,540). Resolved to invoices account: **888,961 (96.7%)** — via appsflyer 447,987 ·
firebase 431,839 · idfa 9,135 · unresolved 29,915.

## 5. Current-plan derivation — mirror of Invoices.Backend `PlansController.Current`

`account_subscriptions` is **one row per subscription**. The BFF collapses a platform user's subscriptions into a
single **current plan** (tier + active + expiry). To compute the same in BQ (per `platform_user_id`), replicate the
BFF algorithm below. Source: `Invoices.Backend/Src/Invoices.Implementation.Services/Plans/` + `Subscription/`.

### 5.1 Per-subscription `is_active`
BFF reads `IsActive` straight from the Subz service; semantics (`SubscriptionService`):
`now < ExpirationTime AND (CancellationTime IS NULL OR now < CancellationTime)` — **no grace period**.
Our event-derived `is_active` / `status` (§"Status / active semantics") already approximate this; `expires_at`,
`refunded_at` (= cancellation) and `expired_at` are the equivalents. Use `is_active` directly.

### 5.2 Product tier (`ProductType`) — the piece our tables are missing
`PlanInfoProvider.GetProductType` (`Plans/PlanInfoProvider.cs:23-85`) maps `product_id` → tier, in order:
1. **offer `product_type` metadata** (`plus|premium|invoicing|fsm_solo|fsm_team|fsm_business`) — *not present in our
   analytics events*; would need to come from `sku_mapping` if we add it.
2. **duration + adapter** rules: `Duration.Week ⇒ Plus`; Stripe `PlusProductId ⇒ Plus`, else metadata, else `Premium`.
3. **`product_id` exact-match lists** (iOS/Android) — `Invoices.Core/Consts/PlansConstants.cs`:
   `PremiumProductIds, InvoicingProductIds, FsmSoloProductIds, FsmTeamProductIds, FsmBusinessProductIds`; default `Plus`.

**Tier priority** (`Invoices.Core/Models/ProductTypePriority.cs`): `FsmBusiness=6, FsmTeam=5, FsmSolo=4, Invoicing=3,
Premium=2, Plus=1, Unknown=0`. **Duration** from `product_id` string (`PlansExtensions.cs`): contains `week`→Week,
`month`→Month, `annual|year`→Year. → For BQ, add a `product_id → product_type` column to `sku_mapping` (port the
PlansConstants lists), since events carry no offer metadata.

### 5.3 Primary-subscription selection (precedence)
`AccountSubscriptionExtensions.GetPrimarySubscription` (`Subscription/AccountSubscriptionExtensions.cs:9-18`):
1. filter to `IsActive`; 2. order by **tier priority DESC**; 3. then **`ExpirationTime` DESC** (NULL = `MaxValue`);
4. take first. **If none active**, fall back to the subscription with the **max `StartTime`**.

```sql
-- current plan per platform user (BQ port). Assumes a product_type/priority mapping (5.2).
SELECT * EXCEPT(rn) FROM (
  SELECT s.platform_user_id, s.product_id, s.product_type, s.is_active, s.expires_at,
         s.auto_renew_enabled, s.started_at, s.status,
         ROW_NUMBER() OVER (PARTITION BY s.platform_user_id ORDER BY
           s.is_active DESC,                              -- active first
           tier_priority(s.product_type) DESC,           -- highest tier
           IFNULL(s.expires_at, TIMESTAMP '9999-12-31') DESC,  -- longest expiry (NULL = never)
           s.started_at DESC) AS rn                       -- fallback: newest start
  FROM account_subscriptions s
) WHERE rn = 1
```

### 5.4 Derived plan flags (`PlansService.cs:109-213`)
- **No primary at all** ⇒ plan `IsActive=false, ProductType=Unknown`, **`IsTrialAvailable = (sub count == 0)`**.
- **`HasDuplicateSubscriptions`** = ≥2 subs are *renewing* (`IsActive AND IsAutoRenewEnabled != false`;
  our `auto_renew_enabled` ≠ FALSE).
- Returned `Duration` is parsed from `product_id` (5.2), **not** from `sub_length_days`.

### 5.5 Gaps to be aware of when porting
- No **offer `product_type` metadata** or **adapter type** in our event tables → tier relies on `product_id` lists +
  duration only (step 1 above unavailable); add the mapping to `sku_mapping`.
- BFF `IsActive` is authoritative (live Subz); ours is **computed from events** — small drift expected (esp. grace,
  late renewals). Treat `account_subscriptions` as analytical, not billing-authoritative.

## Permissions note
The SA can CREATE tables, run DML, and CREATE scheduled queries in `inv-project` (the create call must omit
an explicit runner SA — naming itself triggers `iam.serviceAccounts.actAs`/org-policy denial). It CANNOT
list transfers (`transfers.get` on list denied) — fetch a config by full name instead. Auth/REST mechanics:
see [`README.md`](README.md) §"How to run things".
