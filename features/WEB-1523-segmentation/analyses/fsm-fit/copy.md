# WEB-1523 — FSM-fit proposal copy

User-facing text shown when an FSM-fit suggestion fires. One message per offer from [`scoring.md`](scoring.md) § Offer routing. PM-drafted on 2026-05-13; source: [`../../ideas/misha/README.md`](../../ideas/misha/README.md) § H.

The offer field on `account_fsm_fit` (see [`../../implementation/storage.md`](../../implementation/storage.md) § Structure) selects which message to render. Consumers — BFF read API (stage 2), product-copy management, internal dashboards — should treat this doc as the source of truth and never hardcode copy elsewhere.

> **Open: proposal surface.** Where this copy appears in-app (banner / dashboard card / suggestion inbox / email / push) is **Misha § Hot #1**, still PM-pending. Copy length is sized for a card-style surface; tighter ones (push, banner) may need PM-trimmed variants once the surface is locked.

## Segment messages

### `workers_team` — HVAC team / Construction with crew

> **Stop being the dispatcher.**
> Assign jobs to your crew. They see what to do. You see when they start and finish.

**Trigger:** `b2b_clients_present` AND `avg_invoice_amount ≥ $2000` AND `invoice_count_30d ≥ 15`. Industries: `hvac`, `electrical`, `general_contracting`, `plumbing` with crew indicators.

### `recurring_automation` — Cleaner / Pool / Lawn

> **Stop creating the same invoice every month.**
> Set up recurring jobs once. Visits and invoices generate automatically.

**Trigger:** `recurring_billing` AND `on_site_work` AND `repeat_customer_ratio ≥ 0.5`. Industries: `cleaning`, `pool_spa_service`, `lawn_care_maintenance`, `landscaping`, `pest_control`.

### `contract_deposits` — Painter / Remodeling

> **Stop tracking deposits in your head.**
> Multi-stage payments, change orders, progress tracking — all on one job card.

**Trigger:** `contract_based_billing` AND `on_site_work` AND `avg_invoice_amount ≥ $2000`. Industries: `painting`, `renovations`, `roofing`, `flooring`, `general_contracting` on large jobs.

### `jobs_as_folders` — Plumber / HVAC / Appliance Repair

> **Stop losing track of what each customer needs.**
> Job cards hold everything: scope, parts ordered, visit dates, invoice. One card per customer.

**Trigger:** `complex_multi_line_jobs` AND `on_site_work`. Industries: `plumbing`, `hvac`, `appliance_repair`, `electrical`, `mechanical_service`.

### `schedule_visits` — Handyman / Mixed (default FSM-fit offer)

> **Know who to see next, where to go, what to do.**
> Your day on a schedule. Tap the job, get the address, start the visit.

**Trigger:** `scheduling` AND `on_site_work` (and no earlier rule matched). Industries: `handyman`, mobile services, anyone without a stronger pattern.

### `estimate_workflow` — Estimate → Job → Invoice (generic fallback)

> *PM has not drafted segment copy for this offer yet.* The proposal surface should fall back to a generic FSM message until PM provides text.
>
> **Engineering placeholder:** *"Estimates getting lost? Job cards keep every quote tied to the work — from first estimate to final invoice."*

**Trigger:** `labour_billing` AND `estimate_to_invoice_rate < 0.6`.

## Editorial conventions

- **Pain-first headline.** Each message opens with the user's pain stated as the user would phrase it ("Stop X" / "Know X"). PM rule: never lead with feature names.
- **Body line is concrete.** What the product *actually does* in two short sentences. No marketing adjectives, no "powerful" / "seamless" / "intelligent".
- **One offer per render.** The rule picks a single winner (`scoring.md` § Offer routing). The proposal surface never stacks multiple offers in one view.
- **Industry name not in copy.** The trigger industry list (`hvac`, `plumbing`, etc.) is for routing only — never substituted into the rendered text (no "Stop X for plumbers"). PM keeps the message universal within a segment.

## Open items

- **Copy for `estimate_workflow`** — PM to draft; engineering placeholder above.
- **Tighter variants** for push / banner / email surfaces once Misha § Hot #1 (proposal surface) is decided.
- **Localization.** v1 ships English-only; localization keys will be added when (and if) the proposal surface goes multi-locale.
