`payments_us` — dataset reference (schema · decode · caveats)
=============================================================

Per-dataset appendix to [`bigquery-agent-guide.md`](bigquery-agent-guide.md). Read this **only when the routing table (guide §2) sends you to `payments_us`**. Identity/join keys (account_id is the FULL id; `entity_id` → `src_invoices.id` when `entity_type=1`, dash-normalized) live in core guide §1.6; cost rules in §1.1.

`payments_us` — Tofu Payments orders mirror (PSP only)
------------------------------------------------------

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

- **`amount` / `fee_amount` / `client_fee_amount` are in MAJOR currency units** (dollars/pounds/…), NOT minor units — do **not** divide by 100. This is the opposite of `stripe_us` (which is cents — see `bigquery-agent-guide-stripe_us.md`); don't carry the `/100` habit across. Amounts here are PSP-clean (from Tofu Payments Postgres), so median is still safer than SUM/AVG on outliers.
- `amount` and `client_fee_amount` are separate columns; a fee-passthrough analysis (`client_fee_amount > 0`) and the invoice value (`amount`) don't need to be netted against each other. Whether `amount` already includes the surcharge is not verified here — if a query depends on it, confirm against the Tofu Payments source rather than assuming.
- Filter `status = 3` for real payments — `NotStarted` = abandoned payment link, ~40% of rows.
- PSP-only: ~3% of all "payments received"; the manual ~97% is visible only as `src_invoices.status = 'Paid'` (see core guide §1.4). Stripe-internal method detail lives only in Amplitude `Payment received`.
- The live table's BQ description mentions a `mart_payment_orders` — dropped before release; ignore.
