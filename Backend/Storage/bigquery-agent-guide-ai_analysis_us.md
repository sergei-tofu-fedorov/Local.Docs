`ai_analysis_us` — dataset reference (schema · decode · caveats)
================================================================

Per-dataset appendix to [`bigquery-agent-guide.md`](bigquery-agent-guide.md). Read this **only when the routing table (guide §2) sends you to `ai_analysis_us`** — the common rules, identity model, join keys, routing and cookbook live in the core guide; this file holds the full column catalog, enum decodes, and caveats for this one dataset. Cost gate and prod/test rules: core guide §1.1.

`ai_analysis_us` — warehouse (Mongo snapshot mirror + marts)
------------------------------------------------------------

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
| `src_authenticated_payment_types` (631K) | `account_id` | PSP (Connect) connections, one row per (account × provider): `provider` (Stripe/PayPal), `provider_account_id` (Stripe `acct_…` / PayPal merchant), `status`, `enabled`, `payouts_enabled`, `currency_code`, `country`, `product_key`, `payment_by_card_enabled` — see core guide §1.7 |
| `mart_invoice_line_items` (25M) | `account_id` | per-line, keyed to `invoice_id` (→ `src_invoices.id`, see core guide §1.6): `item_name`, `quantity`, `unit_price`, `item_gross`, `item_discount_*` |
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
- `src_authenticated_payment_types` is the **collecting** (Connect) side — an account's payout account, not Tofu's billing of that account (that's `stripe_us`, see [`bigquery-agent-guide-stripe_us.md`](bigquery-agent-guide-stripe_us.md)). ~77% of its accounts match `src_accounts`; `Connected` status ≈ 23K live Stripe payout accounts. All Stripe rows carry `acct_…`; PayPal rows carry a merchant id.
- Subscriptions: "paying users" = `COUNT(DISTINCT platform_user_id) WHERE is_active` on `mart_account_subscriptions` (≈59K); `mart_account_current_plan WHERE is_active` (~136K) = covered accounts (see core guide §1.4 grain discipline). ~16% of expired subs have `expired_at` NULL — close periods via `COALESCE(expired_at, refunded_at, expires_at)`. `product_type='Unknown'` = regex-unparsed web-Stripe product ids. `mart_subscription_periods` was initialized 2026-07-01 — history accumulates forward only; earlier trends reconstruct from `mart_account_subscriptions` dates (cookbook #8). `mart_account_current_plan` on stage is a static stub.
