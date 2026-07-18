BigQuery agent guide — `ai_analysis_us` / `amplitude_us` / `payments_us` / `stripe_us`
=====================================================================================

**Purpose:** the fast path for an AI agent composing SQL against our analytics storage in prod `inv-project`. Structure: common rules first (apply to every query), then the routing table, then per-dataset reference tables, then the cookbook. Verified live on prod 2026-07-13; refined via six agent evaluation runs.

1. Common rules
---------------

### 1.1 Cost & execution

- Metadata is free (`bq ls` / `bq show`); scans bill per **column**-bytes. Select only needed columns; `SELECT *` on JSON-column tables reads gigabytes. Always `bq query --dry_run` before a real scan.
- Always filter the partition column on partitioned tables (types in §1.2 — a wrong type errors or scans everything). Unpartitioned tables don't prune — their cost is purely the columns touched.
- Clustering prunes only equality/`IN` **filters** on the clustered column (cheap point lookups). It does NOT reduce bytes for JOINs or GROUP BYs.
- Prod = `inv-project`; the stage copy (`invoicesapp-project-test`) has stubs and gaps. Benchmarks and repeated experiments → test project only.
- On Windows run `bq query` from **bash** (heredoc/stdin), not PowerShell — PowerShell mangles quotes in inline SQL.
- JSON prop columns (`event_properties`) are the fattest by far (~10+ GB per 90-day full scan) — restrict date ranges tightly and batch prop extractions into one pass.

### 1.2 Partition columns

| Table | Partition column | Type / granularity |
|---|---|---|
| `src_invoices`, `src_estimates`, `mart_invoice_line_items` | `date` | **TIMESTAMP**, month — filter `DATE(date) = '…'` |
| `amplitude_us.src_amplitude_events` | `event_time` | TIMESTAMP, day |
| `payments_us.src_payment_orders` | `updated_at` | TIMESTAMP, day |
| `mart_subscription_periods` | `valid_from` | **DATE**, day (the only DATE-partitioned table) |
| everything else | — | not partitioned |

All time columns across the datasets are TIMESTAMP unless the table map says otherwise.

### 1.3 Data conventions

- **Int enums.** Mongo-sourced enums are stored as int ordinals or pre-decoded labels; inside raw JSON they arrive as Extended-JSON `{"$numberInt":"N"}` — read via `COALESCE(JSON_VALUE(x,'$.F."$numberInt"'), JSON_VALUE(x,'$.F'))`, never bare `JSON_VALUE`. Complete decode tables live next to each dataset below.
- **NULL ≠ 0.** Money/flag columns are NULL when absent (`client_fee_amount`, `fee_amount`, `expired_at`) — wrap in `COALESCE` for AVG/ratios and period closing.
- **Amounts are dirty.** `src_invoices.total_amount` (and similar user-entered amounts) contain extreme junk — report medians/percentiles (`APPROX_QUANTILES`) or apply a sanity cap; never plain SUM/AVG for "typical" values.

### 1.4 Interpretation principles

- **Every source sees a slice — cross-check.** Warehouse = daily state of documents (all platforms, full history). Amplitude = per-event actions (iOS only, rolling 90 days, lossy-by-design). Payments = PSP orders only (~3% of all payments). Numbers that matter should reconcile across two sources; name the blind spot of the one you used.
- **Actions ≠ documents.** Amplitude counts send/pay ACTIONS (no `invoice_id` on send events); the warehouse counts unique invoices dated by invoice date. Resends inflate one, backdated documents shift the other — the totals are not directly comparable, reconcile by month ranges and say so.
- **Lower bounds.** Backend-visible sends (`sent_method_derived`) cover ~17% of invoices — on iOS ~66% of sends go through the share sheet and leave no Mongo trace. Similarly, manual payments (~97% of paid invoices) have no method detail anywhere in BQ.
- **iOS-only extrapolation.** `amplitude_us` is the iOS project only; web-product events live only in the Amplitude REST API. Never present iOS channel shares as "all users" without saying so.
- **Grain discipline.** Person-grain default = `platform_user_id` (1:1 per account, merges the ~12% multi-account users). Account grain fans out: one owner subscription covers ~2.1 accounts. "Paying users" comes from subscription grain, "covered accounts" from account grain — never swap them. `master_user_id` covers only ~11% of users — group by it only for explicitly master/web questions.
- **Snapshot shares drift.** Distribution numbers quoted in this guide (channel shares etc.) are ~90-day snapshots from 2026-07 — recompute for your report window.

### 1.5 Identity model

```
account (business) ──1:1── platform user (person on a device) ──0..1── master user (web identity)
   8.3M                        4.0M  (~12% own >1 account)          429K linked (~11% of users)
```

| Id | Format | Where it appears |
|---|---|---|
| `account_id` (full) | 76-char `prefix10-32hex-32hex` (rare 36-char GUID) | `ai_analysis_us.src_*`, `payments_us.src_payment_orders` |
| `account_short` | `SUBSTR(account_id, 1, 25)`, collision-free (ASSERT-guarded) | Amplitude `account_id`; legacy (≤1.7.x app) Amplitude `user_id` |
| `platform_user_id` (full) | same family; 1:1 with account | `src_account_identifiers.user_id` |
| `user_short` | `SUBSTR(platform_user_id, 1, 25)`, collision-free (ASSERT-guarded) | Amplitude `user_id` (modern builds; 99.5% of events resolve) |
| `master_user_id` | 36-char GUID | master marts; web-Amplitude `user_id` |

Canonical joins:

```sql
-- Amplitude events -> identity: use the pre-resolved view
FROM `inv-project.amplitude_us.v_events_resolved`      -- platform_user_id, account_id_full, master_user_id inside

-- warehouse / payments fact (full account id) -> identity
JOIN `inv-project.ai_analysis_us.dim_account_identity` d USING (account_id)

-- raw Amplitude short id -> account (only when bypassing the view)
ON COALESCE(e.account_id, e.user_id) = d.account_short
```

### 1.6 Document relations & join keys

Business-entity joins (invoice ↔ client ↔ estimate ↔ line-items ↔ PSP payment). All are **account-scoped** — these foreign keys are not globally clustered, so always add `account_id` to the join. `src_invoices.id` is a bare GUID; the keys pointing at it (`client_id`, estimate `invoice_id`, payment `entity_id`) carry inconsistent dashes, so normalize **both sides** with `REPLACE(LOWER(x),'-','')`.

```
account ─┬─< src_invoices ──< mart_invoice_line_items      (line_items.invoice_id → invoices.id)
         │        │  └───────< src_estimates               (estimates.invoice_id → invoices.id, convert link)
         │        └─> src_clients                          (invoices.client_id → clients client-guid)
         └─< payments_us.src_payment_orders                (orders.entity_id → invoices.id WHEN entity_type=1)
```

| From → To | Key | Notes |
|---|---|---|
| `src_invoices` → `src_clients` | `invoices.client_id` (bare guid) → client-guid portion of `clients.id` (= `<account_id>\|<client_guid>` composite) | strip dashes + account scope; `client_id` NULL for clientless invoices |
| `src_estimates` → `src_invoices` | `estimates.invoice_id` → `invoices.id` | the convert-to-invoice link; NULL until the estimate is converted |
| `mart_invoice_line_items` → `src_invoices` | `line_items.invoice_id` → `invoices.id` | line grain; row also carries `account_id` + `date` (TIMESTAMP partition — filter it) |
| `payments_us.src_payment_orders` → `src_invoices` | `orders.entity_id` → `invoices.id` **when `entity_type = 1`** | `entity_type = 2` = PaymentRequest (no invoice); strip dashes + account scope |
| any `src_*` / payments fact → identity | `USING (account_id)` → `dim_account_identity` | person / master grain — see §1.5 |

```sql
-- invoice ↔ client, account-scoped + dash-normalized (clients.id is <account_id>|<client_guid>)
FROM `inv-project.ai_analysis_us.src_invoices` i
JOIN `inv-project.ai_analysis_us.src_clients` c
  ON c.account_id = i.account_id
 AND REPLACE(LOWER(SPLIT(c.id, '|')[OFFSET(1)]), '-', '') = REPLACE(LOWER(i.client_id), '-', '')

-- PSP payment ↔ invoice (only entity_type = 1)
FROM `inv-project.payments_us.src_payment_orders` p
JOIN `inv-project.ai_analysis_us.src_invoices` i
  ON i.account_id = p.account_id
 AND p.entity_type = 1
 AND REPLACE(LOWER(p.entity_id), '-', '') = REPLACE(LOWER(i.id), '-', '')
```

### 1.7 Stripe linkage (two distinct flows — don't conflate)

Tofu touches Stripe on two separate axes. Keep them apart:

- **Web subscriptions** — money **Tofu bills its own users** (the `stripe_us` dataset, §3.4). A Stripe **customer** (`cus_…`) ↔ Tofu account.
- **Built-in PSP / Connect** — money an **account collects from its clients** (`payments_us` + `src_authenticated_payment_types`). A Tofu account ↔ its Stripe **connected account** (`acct_…`).

```
-- web-subscription customer / transaction -> Tofu account (the ONLY reliable bridge, ~80%)
stripe_us.src_stripe_transactions.customer (cus_)
  = stripe_us.src_stripe_customers.id (cus_)
  = mart_account_subscriptions.subz_account_id   -- WHERE subz_account_id LIKE 'cus_%'  (Stripe-provider subs)
    -> mart_account_subscriptions.account_id      -- full Tofu id -> USING(account_id) everywhere
-- NOT stripe_us.*.account_id — that column is dead (ingest reads a metadata key no customer carries).

-- account -> its collecting Stripe connected account (PSP side)
ai_analysis_us.src_authenticated_payment_types   -- account_id ↔ provider_account_id (acct_), one row per (account × provider)
```

2. Routing: question shape → source
-----------------------------------

| Question shape | Source |
|---|---|
| Current state or multi-year history of documents (counts, statuses, amounts, sent/paid state) | `ai_analysis_us.src_*` |
| User actions and behaviour (how often users do X, funnels, UI context, channels) | `amplitude_us.v_events_resolved` |
| Money through the built-in PSP: online payments, fees, fee passthrough | `payments_us` |
| Tofu's own **web-subscription** Stripe billing (its customers, charges, refunds) | `stripe_us` (§3.4) — link to account via `mart_account_subscriptions.subz_account_id`, §1.7 |
| Which accounts connected a Stripe/PayPal payout account, connection status | `ai_analysis_us.src_authenticated_payment_types` (account ↔ `acct_`, §1.7) |
| Paying users, plans, trials, subscription history | `mart_account_subscriptions` / `mart_account_current_plan` / `mart_subscription_periods` |
| Per-account behavioural aggregates (invoice cadence, repeat customers) | `mart_account_metrics` |
| Segments: industry / trade / size | `dim_account` (+ `mart_account_fsm_fit`) |
| "Who is this id" / account ↔ user ↔ master | `dim_account_identity`, `dim_platform_user_identity` |

Workflow: route → open the dataset section → draft from cookbook → `--dry_run` → run → sanity-check against §1.4.

3. Dataset reference
--------------------

### 3.1 `ai_analysis_us` — warehouse (Mongo snapshot mirror + marts)

Rebuilt daily when the Atlas snapshot changes (~16:1x UTC); deploying SQL does not rebuild by itself. Layers: `src_` (typed Mongo mirror) / `mart_` / `dim_` / `sys_` / `v_`.

| Table (rows) | Cluster | Contents |
|---|---|---|
| `src_invoices` (10.7M) | `account_id` | `id` (bare GUID), `doc_number`, `date`, `total_amount`, `status`, `source`, `client_id`, `currency_code`, `mail_status`, `sent_method`, `sent_at`, `sent_method_derived` |
| `src_estimates` (668K) | `account_id` | `id`, `date`, `invoice_id` (convert link), `status`, `mail_status`, `sent_method`, `sent_method_derived` |
| `src_accounts` (5.2M) | `account_id` | `business_name`, `is_deleted`, `is_technical`, `created_time` — alive accounts only |
| `src_clients` (5.2M) | `account_id` | `info` = ARRAY<STRUCT<name, address>> |
| `src_account_identifiers` (8.3M) | `account_id` | account ↔ `user_id` (platform) ↔ `firebase_id` / `idfa` / `appsflyer_id` / `vendor_id` |
| `src_items` (12.8M) | `account_id` | saved catalog: `name`, `price`, `item_type`, `unit_type`, `taxable`, `created_at` |
| `src_business_profiles` (10.9K) | `account_id` | onboarding poll: `onboarding_industry`, `team_size`, `job_mix` |
| `src_authenticated_payment_types` (631K) | `account_id` | PSP (Connect) connections, one row per (account × provider): `provider` (Stripe/PayPal), `provider_account_id` (Stripe `acct_…` / PayPal merchant), `status`, `enabled`, `payouts_enabled`, `currency_code`, `country`, `product_key`, `payment_by_card_enabled` — see §1.7 |
| `mart_invoice_line_items` (25M) | `account_id` | per-line, keyed to `invoice_id` (→ `src_invoices.id`, see §1.6): `item_name`, `quantity`, `unit_price`, `item_gross`, `item_discount_*` |
| `mart_master_owned_accounts` (476K) | `account_id` | master ↔ account: `role` (owned/member), `tenant_role`, `user_deleted` |
| `mart_master_platform_links` (438K) | `platform_user_id` | master ↔ platform user: `platform`, `public_id`, `is_first_link`, `created_at` |
| `mart_account_metrics` (3.6M) | `account_id` | `invoice_count_30d`, `avg_invoice_amount`, `repeat_customer_ratio`, `estimate_to_invoice_rate`, `b2b_clients_present`, `distinct_addresses`, `top_item_names` |
| `mart_account_fsm_fit` (98K) | `account_id` | `industry`/`specialization`, six boolean signals, `score`/`tier`, `reasoning` |
| `mart_account_subscriptions` (927K) | `account_id` | subscription grain: `product_id`/`product_type`, `status`, `is_active`, `is_trial`, `started_at`/`expired_at`/`expires_at`, `sub_length_days`, `paid_count`, `store_country`, resolved `platform_user_id`/`master_user_id` |
| `mart_subscription_periods` (904K) | `platform_user_id` | SCD-2 daily periods: `valid_from`/`valid_to`, `is_current`, `is_active`, `product_type` |
| `mart_account_current_plan` (1.1M) | `account_id` | account grain: `product_type`, `status`, `is_active`, `is_trial`, `expires_at`, `master_user_id` |
| `dim_skus` (73) | — | `product_id` → `sub_length`, `trial_period`, prices |
| `dim_account` (3.6M) | `account_id` | `industry`, `specialization`, `trade`/`sub_trade`, `business_size`, `team_size`, `is_recurring`, `job_mix`, `state` |
| `user_links` (7.5K) | `user_id` | append-only unified ↔ platform id map (WEB-1525) |
| `dim_account_identity` (8.3M) | `account_id` | identity hub: `account_short`, `platform_user_id`, `in_accounts_snapshot`, `master_via_owner`, `master_via_platform_link` |
| `dim_platform_user_identity` (4M) | `platform_user_id` | `user_short`, `master_user_id` (+count), `account_count`, `sole_account_id`, `account_ids` |

**Decode tables** (labels are pre-decoded strings in the tables above):

| Column | Values |
|---|---|
| `src_invoices.status` | NotPaid · **Paid** (= marked paid manually) · **PaidByCard** (= paid via PSP) · Refunded · PartialRefunded · Dispute |
| `src_estimates.status` | Unknown · Draft · Sent · Approved · Canceled · Done |
| `mail_status` (both) | Sent · InProgress · Opened · MarkedAsSent · Error |
| `sent_method` (both) | Email · Manual |
| `mart_master_platform_links.platform` | 0 Unknown · 1 IOS · 2 Android · 3 Web |
| `*_subscriptions / current_plan .status` | active · trial · expired · refunded |
| `product_type` | Invoicing (95%+) · FsmSolo · FsmTeam · FsmBusiness · Unknown |
| `src_authenticated_payment_types.status` | Unknown · InProgress · Verification · **Connected** · InformationIsRequired · Rejected |

**Dataset caveats:**

- `sent_method_derived` = raw `SentMethod`, else `MailStatus ∈ (Sent, Opened)` → Email, `MarkedAsSent` → Manual. Field ages (no backfill): invoice `sent_method`/`sent_at` since 2026-06, estimate `sent_method` since 2025-11, `mail_status` — years. Email is trustworthy across history; Manual is essentially a 2026-06+ web signal.
- `src_clients.id` = `<account_id>|<client_guid>` composite while `src_invoices.client_id` is a bare guid with inconsistent dashes — join via `REPLACE(LOWER(x),'-','')` + account scope. Same normalization for `payments_us.entity_id` → `src_invoices.id`.
- Deleted accounts are absent from `src_accounts` but present in `dim_account_identity` (`in_accounts_snapshot = FALSE`).
- `src_business_profiles` covers ~0.2% of accounts — never a general dimension. `dim_account.state` is empty for ALL rows; `trade`/`sub_trade` exist only for fsm-scored accounts. `user_links` is a tiny verified subset, not a universal spine.
- `src_authenticated_payment_types` is the **collecting** (Connect) side — an account's payout account, not Tofu's billing of that account (that's `stripe_us`, §3.4). ~77% of its accounts match `src_accounts`; `Connected` status ≈ 23K live Stripe payout accounts. All Stripe rows carry `acct_…`; PayPal rows carry a merchant id.
- Subscriptions: "paying users" = `COUNT(DISTINCT platform_user_id) WHERE is_active` on `mart_account_subscriptions` (≈59K); `mart_account_current_plan WHERE is_active` (~136K) = covered accounts (see §1.4 grain discipline). ~16% of expired subs have `expired_at` NULL — close periods via `COALESCE(expired_at, refunded_at, expires_at)`. `product_type='Unknown'` = regex-unparsed web-Stripe product ids. `mart_subscription_periods` was initialized 2026-07-01 — history accumulates forward only; earlier trends reconstruct from `mart_account_subscriptions` dates (cookbook #8). `mart_account_current_plan` on stage is a static stub.

### 3.2 `amplitude_us` — product events bridge (iOS prod 213333 only)

Loaded daily 04:00 UTC (hours of lag — query full days ≤ yesterday). Rolling **90-day** partition expiration. Web project (586241) is NOT in BQ — reachable only via the Amplitude REST API.

| Table | Cluster | Contents |
|---|---|---|
| `src_amplitude_events` (~25M) | `event_type, user_id` | one row per event: `event_time`, `event_type`, `user_id`/`account_id` (25-char short ids), `device_id`, `session_id`, `country`, `app_version`, `event_properties`/`user_properties` (JSON), `source_project` |
| `v_events_resolved` | (same pruning) | base table + `platform_user_id`, `account_id_full`, `master_user_id` — **the preferred entry point** (resolution: user 99.6%, account 96.8%) |
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

### 3.3 `payments_us` — Tofu Payments orders mirror (PSP only)

Ingested daily 01:00 UTC from Tofu Payments Postgres (watermark MERGE). History since **2024-04**; fee passthrough as a feature exists since **2024-08**.

| Table | Cluster | Contents |
|---|---|---|
| `src_payment_orders` (222K) | `account_id` | `account_id` (FULL id), `amount`, `fee_amount` (platform take), `client_fee_amount` (surcharge on the client — the fee-passthrough axis), `status`, `payment_provider`, `entity_type`/`entity_id`, `psp_account_id`, `currency_code`, `created_at`/`updated_at` |
| `dim_currency` (156) | — | `ordinal` ↔ ISO `code`; join `ON dim_currency.ordinal = src_payment_orders.currency_code` |

**Decode tables:**

| Column | Values |
|---|---|
| `status` | 0 Unknown · 1 NotStarted · 2 IsProcessing · **3 Succeeded (= paid)** · 4 Failed |
| `payment_provider` | 0 Unknown · 1 Stripe (effectively 100% Stripe) |
| `entity_type` | 0 Unknown · 1 Invoice · 2 PaymentRequest |

**Dataset caveats:**

- Filter `status = 3` for real payments — `NotStarted` = abandoned payment link, ~40% of rows.
- PSP-only: ~3% of all "payments received"; the manual ~97% is visible only as `src_invoices.status = 'Paid'` (see §1.4). Stripe-internal method detail lives only in Amplitude `Payment received`.
- The live table's BQ description mentions a `mart_payment_orders` — dropped before release; ignore.

### 3.4 `stripe_us` — Tofu's own Stripe billing (web subscriptions)

Ingested by the `stripe-ingest` Hangfire tick (daily 03:00 UTC) from the Stripe REST API of the **direct-charge** account `acct_1Orm4F…` ("TOFU web") — money **Tofu bills its own users** for web subscriptions. NOT the built-in PSP (that's `payments_us` + `src_authenticated_payment_types`, the Connect side — §1.7). REST-sourced, so amounts are Stripe-clean (not user-entered junk).

| Table (rows) | Cluster | Contents |
|---|---|---|
| `src_stripe_customers` (~16K) | `email` | `id` (`cus_…`), `email`, `name`, `currency`, `delinquent`, `created`, `metadata`/`raw` (JSON), `source_account` |
| `src_stripe_transactions` (~91K, 2025→) | `customer` | charge+refund unified: `id` (`ch_`/`re_`), `type`, `customer` (`cus_`), `amount` (**minor units**, integer), `currency`, `status`, `charge_id`, `payment_intent_id`, `invoice_id` (Stripe `in_`), `refunded`, `amount_refunded`, `reason`, `created` |
| `src_stripe_connected_accounts` (0) | `account_id` | Connect-platform importer — disabled, empty |
| `sys_stripe_event_state` | — | per-resource ingest watermark |

**Caveats / joins:**
- **`account_id` column is dead** (both tables) — the ingest reads `metadata.AccountId`, a key no customer carries (the real link is `subs_public_id` / `public_id` in metadata, a master-user GUID). Do NOT join on it.
- **To a Tofu account:** go through subscriptions — `customer/id (cus_)` = `mart_account_subscriptions.subz_account_id` (`WHERE subz_account_id LIKE 'cus_%'`) → `account_id`. Covers ~80% of transactions (§1.7). The remaining ~20% are `cus_` with no subscription row (churned / refund-only).
- `amount` is **minor units** (cents) → `amount/100`. `status`: charge `succeeded`/`failed`/`pending`, refund `succeeded`/`pending`/`canceled`.
- `src_stripe_transactions` is backfilled from **2025-01-01** (floor); charges dense, refunds sparse. Windowed backfill (30-day windows) — first fill takes a few Hangfire retries.

4. Query cookbook
-----------------

```sql
-- 1) Sends per day by channel (email vs share sheet), person-grain
SELECT DATE(event_time) d,
       IF(JSON_VALUE(event_properties,'$.application')='mail_server','email','share') AS channel,
       COUNT(*) sends, COUNT(DISTINCT platform_user_id) senders
FROM `inv-project.amplitude_us.v_events_resolved`
WHERE event_type = 'Send invoice'
  AND DATE(event_time) BETWEEN '2026-07-01' AND '2026-07-11'   -- partition filter: mandatory
GROUP BY 1,2 ORDER BY 1,2;

-- 2) Backend-visible sent share & method (full history)
SELECT DATE_TRUNC(DATE(date), MONTH) m, sent_method_derived, COUNT(*) c
FROM `inv-project.ai_analysis_us.src_invoices`
WHERE date >= '2025-01-01'
GROUP BY 1,2 ORDER BY 1;

-- 3) Sent docs per person per month (warehouse, person-grain)
SELECT d.platform_user_id, DATE_TRUNC(DATE(i.date), MONTH) m, COUNT(*) sent
FROM `inv-project.ai_analysis_us.src_invoices` i
JOIN `inv-project.ai_analysis_us.dim_account_identity` d USING (account_id)
WHERE i.sent_method_derived IS NOT NULL AND i.date >= '2026-01-01'
GROUP BY 1,2;

-- 4) PSP payments + fee passthrough share per month
SELECT DATE_TRUNC(DATE(updated_at), MONTH) m,
       COUNT(*) paid_orders,
       ROUND(AVG(IF(COALESCE(client_fee_amount,0) > 0, 1, 0)) * 100, 1) AS fee_on_client_pct,
       ROUND(SUM(amount), 0) AS volume
FROM `inv-project.payments_us.src_payment_orders`
WHERE status = 3                                                -- Succeeded only; NotStarted = abandoned links
  AND updated_at >= '2025-07-01'
GROUP BY 1 ORDER BY 1;

-- 5) Payments per person with currency
SELECT d.platform_user_id, SUM(p.amount) paid, ANY_VALUE(c.code) currency
FROM `inv-project.payments_us.src_payment_orders` p
JOIN `inv-project.ai_analysis_us.dim_account_identity` d USING (account_id)
JOIN `inv-project.payments_us.dim_currency` c ON c.ordinal = p.currency_code
WHERE p.status = 3 AND p.updated_at >= '2026-06-01'
GROUP BY 1;

-- 6) Point lookup: who is this Amplitude short id? (clustering makes this cheap)
SELECT * FROM `inv-project.ai_analysis_us.dim_account_identity`
WHERE account_short = 'awkj83060a-c18ec586fb814a';

-- 7) Paying accounts by plan right now (account grain! paying USERS -> mart_account_subscriptions)
SELECT product_type, COUNT(*) FROM `inv-project.ai_analysis_us.mart_account_current_plan`
WHERE is_active GROUP BY 1;

-- 8) Active-subscription trend. mart_subscription_periods has history only from 2026-07-01;
--    for earlier trends reconstruct from subscription start/end dates:
WITH months AS (
  SELECT m FROM UNNEST(GENERATE_DATE_ARRAY('2025-07-01', '2026-07-01', INTERVAL 1 MONTH)) m
)
SELECT m, COUNT(*) active_subs
FROM months
JOIN `inv-project.ai_analysis_us.mart_account_subscriptions` s
  ON DATE(s.started_at) <= m
 AND COALESCE(DATE(s.expired_at), DATE(s.refunded_at), DATE(s.expires_at), '2099-01-01') > m
GROUP BY 1 ORDER BY 1;
-- (from 2026-07 onward: mart_subscription_periods WHERE is_active GROUP BY valid_from)

-- 9) Trial share of new subscriptions per month + subscription length
SELECT DATE_TRUNC(DATE(started_at), MONTH) m,
       COUNTIF(is_trial OR trial_started_at IS NOT NULL) / COUNT(*) AS trial_share,
       APPROX_QUANTILES(sub_length_days, 2)[OFFSET(1)] AS median_sub_length_days
FROM `inv-project.ai_analysis_us.mart_account_subscriptions`
WHERE started_at >= '2025-07-01'
GROUP BY 1 ORDER BY 1;

-- 10) What do accounts of a given trade sell, at what prices (line-item grain)
SELECT li.item_name, COUNT(*) lines,
       APPROX_QUANTILES(li.unit_price, 2)[OFFSET(1)] AS median_price
FROM `inv-project.ai_analysis_us.mart_invoice_line_items` li
JOIN `inv-project.ai_analysis_us.dim_account` d USING (account_id)
WHERE d.trade = 'plumbing'                       -- trade only for fsm-scored accounts!
  AND li.date >= '2026-01-01'
GROUP BY 1 HAVING lines > 50 ORDER BY lines DESC LIMIT 30;

-- 11) Generic behaviour counter: any Amplitude event per week per person
SELECT DATE_TRUNC(DATE(event_time), WEEK) w, COUNT(*) events,
       COUNT(DISTINCT platform_user_id) users
FROM `inv-project.amplitude_us.v_events_resolved`
WHERE event_type = 'Create estimate'             -- swap for any of the 113 event types
  AND DATE(event_time) >= '2026-05-01'
GROUP BY 1 ORDER BY 1;

-- 12) Web-subscription Stripe transactions -> Tofu account (charges, net of refunds, USD-minor->units)
WITH sub AS (
  SELECT DISTINCT subz_account_id AS cus, account_id
  FROM `inv-project.ai_analysis_us.mart_account_subscriptions`
  WHERE subz_account_id LIKE 'cus_%'
)
SELECT s.account_id,
       SUM(IF(t.type='charge', t.amount, -t.amount)) / 100 AS net_amount,   -- minor units -> units
       COUNTIF(t.type='charge') charges, COUNTIF(t.type='refund') refunds
FROM `inv-project.stripe_us.src_stripe_transactions` t
JOIN sub s ON s.cus = t.customer                  -- ~80% link; unmatched cus_ have no subscription row
WHERE t.status = 'succeeded'
GROUP BY 1 ORDER BY net_amount DESC LIMIT 50;

-- 13) Accounts with a connected Stripe payout account (PSP/Connect side — NOT #12's billing side)
SELECT country, COUNT(*) connected
FROM `inv-project.ai_analysis_us.src_authenticated_payment_types`
WHERE provider = 'Stripe' AND status = 'Connected'
GROUP BY 1 ORDER BY connected DESC LIMIT 20;
```

5. Freshness
------------

| Dataset | Cadence | Rule |
|---|---|---|
| `ai_analysis_us` | daily ~16:1x UTC (snapshot-driven) | state as of yesterday's Mongo snapshot |
| `amplitude_us` | daily 04:00 UTC | query full days ≤ yesterday; rolling 90 days only |
| `payments_us` | daily 01:00 UTC | yesterday complete; history since 2024-04 |
| `stripe_us` | daily 03:00 UTC (`stripe-ingest`) | customers full-snapshot; transactions incremental, history from 2025-01 |

