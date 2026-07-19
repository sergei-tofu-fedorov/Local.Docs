BigQuery agent guide — `ai_analysis_us` / `amplitude_us` / `payments_us` / `stripe_us`
=====================================================================================

**Purpose:** the fast path for an AI agent composing SQL against our analytics storage in prod `inv-project`. Structure: common rules first (apply to every query), then the routing table, then the cookbook. The heavy per-dataset schema/decode/caveat tables live in **separate files** (`bigquery-agent-guide-<dataset>.md`) — load only the one your question routes to (§2/§3), to keep context small. Verified live on prod 2026-07-13; refined via agent evaluation runs.

1. Common rules
---------------

### 1.1 Cost & execution

- Metadata is free (`bq ls` / `bq show`); scans bill per **column**-bytes. Select only needed columns; `SELECT *` on JSON-column tables reads gigabytes. Always `bq query --dry_run` before a real scan.
- Always filter the partition column on partitioned tables (types in §1.2 — a wrong type errors or scans everything). Unpartitioned tables don't prune — their cost is purely the columns touched.
- Clustering prunes only equality/`IN` **filters** on the clustered column (cheap point lookups). It does NOT reduce bytes for JOINs or GROUP BYs.
- **`--dry_run` does NOT reflect cluster pruning — it reports the PRE-prune upper bound.** For an equality filter on a cluster key (e.g. one `user_id`/`account_id` on a clustered table), the estimate looks large (a point lookup on `src_amplitude_events` over 90 days can dry-run at ~3–4 GB) but the actual billed scan is a small fraction of it. Do NOT narrow the date window or abandon the query in a panic over a big dry-run number on a cluster-key point lookup — the partition filter is a correctness requirement here, not the cost lever. (For non-clustered filters, GROUP BYs, and JOINs the dry-run estimate is accurate — trust it there.)
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

- **Int enums.** Mongo-sourced enums are stored as int ordinals or pre-decoded labels; inside raw JSON they arrive as Extended-JSON `{"$numberInt":"N"}` — read via `COALESCE(JSON_VALUE(x,'$.F."$numberInt"'), JSON_VALUE(x,'$.F'))`, never bare `JSON_VALUE`. Complete decode tables live in each dataset's schema file (§3).
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
-- retrieving ONE account's own events? bypass the view — raw table + thin cols is cheaper (cookbook #14)
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

- **Web subscriptions** — money **Tofu bills its own users** (the `stripe_us` dataset — [`bigquery-agent-guide-stripe_us.md`](bigquery-agent-guide-stripe_us.md)). A Stripe **customer** (`cus_…`) ↔ Tofu account.
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

| Question shape | Source | Schema file to read |
|---|---|---|
| Current state or multi-year history of documents (counts, statuses, amounts, sent/paid state) | `ai_analysis_us.src_*` | `-ai_analysis_us.md` |
| User actions and behaviour (how often users do X, funnels, UI context, channels) | `amplitude_us.v_events_resolved` | `-amplitude_us.md` |
| Money through the built-in PSP: online payments, fees, fee passthrough | `payments_us` | `-payments_us.md` |
| Tofu's own **web-subscription** Stripe billing (its customers, charges, refunds) | `stripe_us` — link to account via `mart_account_subscriptions.subz_account_id`, §1.7 | `-stripe_us.md` |
| Which accounts connected a Stripe/PayPal payout account, connection status | `ai_analysis_us.src_authenticated_payment_types` (account ↔ `acct_`, §1.7) | `-ai_analysis_us.md` |
| Paying users, plans, trials, subscription history | `mart_account_subscriptions` / `mart_account_current_plan` / `mart_subscription_periods` | `-ai_analysis_us.md` |
| Per-account behavioural aggregates (invoice cadence, repeat customers) | `mart_account_metrics` | `-ai_analysis_us.md` |
| Segments: industry / trade / size | `dim_account` (+ `mart_account_fsm_fit`) | `-ai_analysis_us.md` |
| "Who is this id" / account ↔ user ↔ master | `dim_account_identity`, `dim_platform_user_identity` | `-ai_analysis_us.md` |

Workflow: route → **check the cookbook (§4) first**; if a recipe already covers your question end-to-end, draft from it and **skip the dataset file** → otherwise **read that dataset's schema file** (`bigquery-agent-guide-<dataset>.md`, §3) for columns/decodes → draft → `--dry_run` → run → sanity-check against §1.4. Read a dataset file only when you actually need a column, enum value, or caveat the core doesn't give you — don't open it "to confirm" a recipe that's already complete.

3. Dataset reference (per-dataset schema files)
-----------------------------------------------

The full column catalog, cluster keys, enum **decode tables**, and per-dataset **caveats** live in one file per dataset, next to this guide in `Backend/Storage/`. Load only the one your routing (§2) landed on:

| Dataset | Schema file |
|---|---|
| `ai_analysis_us` — warehouse (docs, marts, dims, identity) | [`bigquery-agent-guide-ai_analysis_us.md`](bigquery-agent-guide-ai_analysis_us.md) |
| `amplitude_us` — iOS product events | [`bigquery-agent-guide-amplitude_us.md`](bigquery-agent-guide-amplitude_us.md) |
| `payments_us` — built-in PSP orders | [`bigquery-agent-guide-payments_us.md`](bigquery-agent-guide-payments_us.md) |
| `stripe_us` — Tofu's web-subscription billing | [`bigquery-agent-guide-stripe_us.md`](bigquery-agent-guide-stripe_us.md) |

**Read the matching file before composing a query that touches specific columns, enum values, or that dataset's caveats** — e.g. the payments `status=3` filter, the stripe dead-`account_id` trap, the invoice `sent_method_derived` semantics all live in those files. The critical **join keys** and the most dangerous gotchas are already in §1 above, so a query built straight from a cookbook recipe below may not need the file; anything beyond it does.

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

-- 14) Latest events for ONE account — cheap point retrieval. SELF-CONTAINED: you do NOT need the
--     amplitude dataset file for this. Do NOT use v_events_resolved here — for a single account the raw
--     table + thin columns is cheaper. Filter both id columns; the cluster is (event_type,user_id) so the
--     user_id branch prunes but account_id does not — a date bound is still mandatory (partitioned table).
--     Use the FULL 90-day horizon so "latest" can't miss recent activity (the id filter keeps cost low).
SELECT event_time, event_type, app_version, country, device_id
FROM `inv-project.amplitude_us.src_amplitude_events`
WHERE COALESCE(account_id, user_id) = SUBSTR('<full-account_id>', 1, 25)  -- Amplitude keeps only the 25-char prefix (§1.5)
  AND DATE(event_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)       -- full retained horizon (table is 90-day rolling)
ORDER BY event_time DESC LIMIT 50;

-- 15) Latest events for ONE person by master_user_id — two steps (master has no Amplitude column of its own).
--     SELF-CONTAINED: you do NOT need the amplitude dataset file for this.
--     Step 1: master -> user_short via dim_platform_user_identity. A master_user_id filter does NOT prune
--     (dim is clustered by platform_user_id) — select ONLY user_short here; never account_ids (fat repeated col).
--     If step 1 returns a single user_short, substitute it as a literal into step 2 (skip the JOIN — cheaper).
--     Step 2: feed user_short into the raw events table exactly like #14 — do NOT use v_events_resolved.
WITH pu AS (
  SELECT user_short
  FROM `inv-project.ai_analysis_us.dim_platform_user_identity`
  WHERE master_user_id = '<master-guid>'                                 -- 36-char GUID
)
SELECT e.event_time, e.event_type, e.app_version, e.country, e.device_id, e.account_id  -- account_id = which of the master's accounts
FROM `inv-project.amplitude_us.src_amplitude_events` e
JOIN pu ON e.user_id = pu.user_short                                     -- modern builds put user_short in Amplitude user_id (§1.5)
WHERE DATE(e.event_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)    -- full retained horizon (table is 90-day rolling); user_id cluster prune keeps it cheap
ORDER BY e.event_time DESC LIMIT 50;

-- 16) Dormant payers: ACTIVE subscription but no in-app activity last 30d (renewal charge excluded).
--     CRITICAL grain/blind-spot (§1.4): amplitude is iOS-only + rolling 90d, so a "no activity" result
--     is polluted by web/Android subscribers who simply are NOT in amplitude. Gate on sub_paid>=1 — a
--     `Subscription paid` event PROVES the person is iOS-tracked, so "only the renewal fired, nothing else"
--     is a genuine dormant-iOS-payer, not an untracked user. (Anti-join via LEFT JOIN + COUNTIF, one pass.)
--     STRICTER variant ("no server/billing event of ANY kind counts as activity"): swap the single
--     'Subscription paid' test for the full server-emitted event list (Subz billing + BFF) — the exact
--     iOS event_type strings are in bigquery-agent-guide-amplitude_us.md (§ Subz pipeline). Don't
--     filter by account_id IS NULL — many pure-client events are null too (that file explains why).
WITH active_subs AS (
  SELECT DISTINCT platform_user_id                                       -- person grain = "paying users" (§1.4)
  FROM `inv-project.ai_analysis_us.mart_account_subscriptions`
  WHERE is_active
),
amp AS (
  SELECT platform_user_id,
         COUNTIF(event_type = 'Subscription paid')  AS sub_paid,        -- server-emitted renewal, not activity
         COUNTIF(event_type != 'Subscription paid') AS other_events
  FROM `inv-project.amplitude_us.v_events_resolved`
  WHERE DATE(event_time) BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY) AND DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
  GROUP BY 1
)
SELECT COUNT(*) AS dormant_ios_payers                                    -- provably iOS-tracked, renewal-only
FROM active_subs s
LEFT JOIN amp a USING (platform_user_id)
WHERE a.sub_paid >= 1 AND a.other_events = 0;
-- (a.other_events IS NULL catches subscribers with ZERO amplitude rows — that's the untracked web/Android
--  upper bound, NOT dormant iOS; report it separately, never as the headline.)
```

5. Freshness
------------

| Dataset | Cadence | Rule |
|---|---|---|
| `ai_analysis_us` | daily ~16:1x UTC (snapshot-driven) | state as of yesterday's Mongo snapshot |
| `amplitude_us` | daily 04:00 UTC | query full days ≤ yesterday; rolling 90 days only |
| `payments_us` | daily 01:00 UTC | yesterday complete; history since 2024-04 |
| `stripe_us` | daily 03:00 UTC (`stripe-ingest`) | customers full-snapshot; transactions incremental, history from 2025-01 |
