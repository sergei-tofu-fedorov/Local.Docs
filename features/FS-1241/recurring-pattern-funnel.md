# FS-1241 — Recurring-pattern audience funnel

Sizing of candidate audiences for the "recurring invoice" offer, by progressively looser
definitions of *recurrence*. Goal: find **more** clients than the current `fs1241_cohort`
(~1.6k) while keeping the signal meaningful.

- **Source data:** `inv-project.ai_analysis_us` warehouse (`invoices`, `invoice_line_items`,
  `account_current_plan`).
- **Audience gate (hard):** account has an **active subscription** —
  `account_current_plan.is_active AND expires_at >= CURRENT_TIMESTAMP()`. All "accounts"
  numbers below already have this filter applied.
- **Per-invoice base filter:** `total_amount > 0 AND client_id IS NOT NULL`.
- **Audience size (active subscription):** 125,900 accounts.
- Counted on 2026-06-24 against the live warehouse.

## Cohort vs table count (the 1,648 vs 2,942 gap)

`fs1241_cohort` currently holds **2,942** rows, but only **1,648** have an active subscription
right now (`sub_is_active = true`). In `build_fs1241_cohort` the subscription is a **LEFT JOIN
flag, not a hard filter** — the hard cut is 3A industry + recur≥3 + ≥2 clients. Active
subscription is enforced upstream (FSM-fit audience), but `account_fsm_fit` accumulates rows
under a TTL, so accounts whose plan expired after scoring stay in the cohort with
`sub_is_active = false`. **1,648 ≈ the "1,600" targetable number.**

## Funnel (strict → loose, active-subscription accounts)

| # in task | Original ask (RU) | Definition (logic + threshold) | Source: table / fields | Accounts (active sub) | Invoices in pattern |
|---|---|---|---|---|---|
| — | *(current FS-1241 cohort)* | 3A industry **AND** max group repeat ≥3 **AND** ≥2 distinct clients with repetition. Subscription = flag | `fs1241_cohort` ← `recur_groups` + `account_fsm_fit` + `account_current_plan` | **1,648** | — |
| **6** | "инвойсы одному клиенту с какой-то **периодичностью**" | One client: ≥3 invoices, regular cadence — mean gap 5–400 days **AND** coefficient of variation (σ/μ) ≤ 0.5 | `invoices`: `account_id, client_id, date`; gap = `TIMESTAMP_DIFF(date, LAG(date))` | **13,661** | 371,091 |
| **1** | "всё одинаковое (**сумма + названия работ**) у одного клиента" | One client: ≥2 invoices with **same `total_amount` AND same `item_names` set** (full-receipt match). `item_signature = TO_JSON_STRING(item_names)` | `invoices`: `account_id, client_id, total_amount, item_names[]` | **17,333** | 599,561 |
| **4** | "**одинаковые инвойсы с одинаковой ценой**" | One client: ≥2 invoices with **same `total_amount`** (item set not compared — looser than #1) | `invoices`: `account_id, client_id, total_amount` | **24,822** | 1,059,876 |
| **3** | "повторяющийся айтем **с одной ценой**" | One client: same **`item_name` + `unit_price`** pair appears in ≥2 distinct invoices | `invoice_line_items`: `account_id, item_name, unit_price, invoice_id` ⨝ `invoices.client_id` | **25,873** | 1,230,528 |
| **5** | "айтем повторяющийся, но **цена может отличаться**" | One client: same **`item_name`** in ≥2 distinct invoices, price ignored (looser than #3) | `invoice_line_items`: `account_id, item_name, invoice_id` ⨝ `invoices.client_id` | **31,454** | 1,541,117 |
| **2** | "**разные суммы**, но у одного клиента" | One client: ≥2 invoices at all (amounts/items may differ) — effectively "the business has a repeat client" | `invoices`: `account_id, client_id` | **41,664** | 2,487,164 |

> "Invoices in pattern" = invoices **participating** in a repeat, not all of the account's invoices.

### Without the subscription gate (for reference)

| Filter | All accounts | With active subscription |
|---|---|---|
| #6 periodicity | 50,934 | 13,661 |
| #1 same amount + items | 88,730 | 17,333 |
| #4 same amount | 130,016 | 24,822 |
| #2 repeat client | 296,956 | 41,664 |

The subscription gate removes ~70–85% of the raw repeat-pattern accounts.

## Interpretation notes / open definition questions

- **#2** is implemented as "repeat client with ≥2 invoices" (a superset that includes
  identical amounts). For strict "amounts differ", add `COUNT(DISTINCT total_amount) ≥ 2`
  per client — this shrinks the number.
- **#3** is read as item repeat **across invoices of one client**, not a duplicate line
  *within a single invoice*. The intra-invoice reading is a different query.
- **#6** cadence regularity is a proxy (mean gap 5–400 days, CV ≤ 0.5).

## Recommendation

The dominant lever is **not** the recurrence definition but the **dropped gates** (3A industry,
≥2 clients, recur≥3): even the strictest new definition (#1) is ~10× the current 1,648.
For a meaningful "recurring regular billing" audience, build `fs1241_cohort_v2` on **#1 or #3 +
active subscription**, without the 3A / multi-client requirement (~17k–26k accounts), and treat
periodicity (#6) as a premium sub-segment.
