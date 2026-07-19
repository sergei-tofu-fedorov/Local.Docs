`stripe_us` — dataset reference (schema · joins · caveats)
==========================================================

Per-dataset appendix to [`bigquery-agent-guide.md`](bigquery-agent-guide.md). Read this **only when the routing table (guide §2) sends you to `stripe_us`**. The two-flow Stripe model (web-subscription billing here vs the PSP/Connect collecting side in `payments_us` + `src_authenticated_payment_types`) and the `cus_` → account bridge live in core guide §1.7; cost rules in §1.1.

`stripe_us` — Tofu's own Stripe billing (web subscriptions)
-----------------------------------------------------------

Ingested by the `stripe-ingest` Hangfire tick (daily 03:00 UTC) from the Stripe REST API of the **direct-charge** account `acct_1Orm4F…` ("TOFU web") — money **Tofu bills its own users** for web subscriptions. NOT the built-in PSP (that's `payments_us` + `src_authenticated_payment_types`, the Connect side — core guide §1.7). REST-sourced, so amounts are Stripe-clean (not user-entered junk).

| Table (rows) | Cluster | Contents |
|---|---|---|
| `src_stripe_customers` (~16K) | `email` | `id` (`cus_…`), `email`, `name`, `currency`, `delinquent`, `created`, `metadata`/`raw` (JSON), `source_account` |
| `src_stripe_transactions` (~91K, 2025→) | `customer` | charge+refund unified: `id` (`ch_`/`re_`), `type`, `customer` (`cus_`), `amount` (**minor units**, integer), `currency`, `status`, `charge_id`, `payment_intent_id`, `invoice_id` (Stripe `in_`), `refunded`, `amount_refunded`, `reason`, `created` |
| `src_stripe_connected_accounts` (0) | `account_id` | Connect-platform importer — disabled, empty |
| `sys_stripe_event_state` | — | per-resource ingest watermark |

**Caveats / joins:**
- **`account_id` column is dead** (both tables) — the ingest reads `metadata.AccountId`, a key no customer carries (the real link is `subs_public_id` / `public_id` in metadata, a master-user GUID). Do NOT join on it.
- **To a Tofu account:** go through subscriptions — `customer/id (cus_)` = `mart_account_subscriptions.subz_account_id` (`WHERE subz_account_id LIKE 'cus_%'`) → `account_id`. Covers ~80% of transactions (core guide §1.7). The remaining ~20% are `cus_` with no subscription row (churned / refund-only).
- `amount` is **minor units** (cents) → `amount/100`. `status`: charge `succeeded`/`failed`/`pending`, refund `succeeded`/`pending`/`canceled`.
- `src_stripe_transactions` is backfilled from **2025-01-01** (floor); charges dense, refunds sparse. Windowed backfill (30-day windows) — first fill takes a few Hangfire retries.
