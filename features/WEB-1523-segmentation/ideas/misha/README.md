# WEB-1523 — Notes for the product manager

A running list of items where engineering needs a PM decision (or at least a sanity check) before they harden into code. Anything in this folder is open for input — not yet locked.

The format for each item: **What we need decided** · **Why it matters** · **Engineering default if PM doesn't decide** · **By when**.

---

## Hot — needed before Phase 4 (analysis pipeline) starts

### 1. Proposal surface — where does the FSM-fit suggestion appear in-app?

- **Decide:** banner at the top of the invoices screen / inline card on the dashboard / row in a "Suggestions" inbox / email / push / something else?
- **Why it matters:** drives the prompt copy rubric, the BFF integration (task 5.2), and how the `reasoning` field gets used. Different surfaces have different copy-length budgets and different dismiss/re-show ergonomics.
- **Default if undecided:** dashboard inline card with static copy ("Try the Jobs feature — track recurring work in one place"), `reasoning` kept internal-only.
- **By:** before Phase 4 starts (otherwise we ship something the PM has to redo).

### 2. Is the LLM `reasoning` user-visible?

- **Decide:** show the model's free-text reasoning to the end user (e.g., "We noticed you bill labour-hour items and recurring lawn-care visits — Jobs can help you schedule both"), or keep it internal-only for ops dashboards?
- **Why it matters:** if user-visible, the prompt rubric needs a tighter no-jargon, no-PII, marketing-tone constraint. Also forces a "reasoning never references *another* user's data" guard.
- **Default if undecided:** internal-only. Reasoning shown only in the PM review HTML + Looker dashboards.
- **By:** before Phase 4 (5.7) starts.

### 3. Suppression rules — what happens after a user dismisses?

- **Decide:**
  - Show once, never again?
  - Show, dismissed, re-show after N days / N new invoices?
  - Stop showing if user's tier flips to `weak`/`none` on re-score?
- **Why it matters:** drives a small data model (a `dismissed_at` per (user, analysis_type)) that the BFF needs to read on every page render.
- **Default if undecided:** show-once-and-stop on dismiss; ignore tier flips.
- **By:** before Phase 5 (BFF integration).

### 7. Forward A/B design — how do we prove it worked? **(hard launch gate for stage 2)**

- **Decide:** primary metric, holdout %, observation window, MDE. Engineering has pre-committed: event schema at [`../../analyses/fsm-fit/analytics-events.md`](../../analyses/fsm-fit/analytics-events.md), experiment draft at [`../../analyses/fsm-fit/forward-ab.md`](../../analyses/fsm-fit/forward-ab.md) with `PM TO DECIDE` placeholders.
- **Why it matters:** no historical FSM-conversion data exists — forward A/B is the only validation path. Without this designed BEFORE the BFF surface ships, we'll have no instrumentation, no holdout, no decision rule.
- **Defaults (engineering):** trial-start within 30d as primary; 10% holdout; 30d observation; MDE depends on PM's baseline-rate guess.
- **By:** before any BFF stage-2 proposal-surface work starts. Stage-1 (BigQuery only, no user surface) is not gated. Stage-2 starts only after PM fills in `forward-ab.md`.

---

## Warm — needed before launch (Phase 6)

### 4. Validate the tier definition matches the product intent

- **Decide:** does the 4-evidence-flag definition of "strong" match what PM means by "should be pitched FSM"? On the 1,000-account validation run, **51% landed in `strong`** — higher than the v1 target (~20%). Either the rule weights are too loose, the selection sample over-represents FSM-likely users, or both.
- **Why it matters:** if the rule is too generous, we'll pitch FSM to users who'll see the suggestion as noise. Too tight and we miss the audience.
- **Default if undecided:** keep current weights (0.40 / 0.25 / 0.15 / 0.10 on the 4 flags); PM can adjust later via a `rule_version` bump.
- **Action:** PM eyeballs the validation results (sorted by score, filtered to `strong`), spot-checks ~30 entries. Flag any that "shouldn't be strong" so we can retune the rule.
- **By:** before Phase 6 launch.
- **Partial resolution 2026-05-13:** PM identified 7 top-FSM-candidate verticals from the in-app industry picker (Handyman, Cleaning, HVAC, Plumbing, Painting, Appliance repair, General contractor). The rule now adds **+0.15 bonus** when the LLM's industry/specialization string matches any of those keywords. Applied retroactively to the 1,000-account validation results — bonus fired on 203 accounts (20%); 16 accounts flipped weak→strong, 2 flipped none→weak. New distribution: strong 509→525, weak 117→103, none 374→372. **Still open:** whether the 51% strong rate is acceptable (selection bias may inflate it) — re-eyeball the validation results after the rule is locked.

### 5. Tier vocabulary — internal labels vs user-facing copy

- **Decide:** the database stores `strong | weak | none`. What does the user actually see — if anything? (e.g., the in-app banner just says "Try Jobs" regardless of internal tier, and tier only routes which users see the banner.)
- **Why it matters:** if any tier label leaks into user-facing copy, the words matter. "Weak" is harsh.
- **Default if undecided:** internal labels stay internal; user only sees a single banner state ("show" vs "don't show"), with `strong` and `weak` both triggering "show".
- **By:** before Phase 5.

### 6. Audience scope — who's in the proposal pool?

- **Decide:** the training sample was invoice-only users active in the last 7 days. At launch:
  - Only paid users? Or trial users too?
  - Only users above N invoices ever? Or include thin / new users?
  - Existing FSM-feature users: definitely excluded (audience is invoice-only by design), but should we also exclude users who've previously seen the proposal and ignored it for X days?
- **Why it matters:** affects how many users hit the surface, and the read-side query logic.
- **Default if undecided:** match the training sample's filter — invoice-only users with `account_age_days ≥ 90` and at least one invoice in the last 30 days.
- **By:** Phase 5.

### 7. Forward A/B design — how do we prove it worked?

**Elevated to a hard launch gate — see Hot section § 7 above.** Engineering has pre-committed the event schema at [`../../analyses/fsm-fit/analytics-events.md`](../../analyses/fsm-fit/analytics-events.md); the experiment draft with PM-decision points is at [`../../analyses/fsm-fit/forward-ab.md`](../../analyses/fsm-fit/forward-ab.md).

### 8. Refresh cadence — how often does the FSM-fit score recompute?

- **Decide:** the current default is 90 days (an account is re-analyzed if its previous score is older than 90 days). Reasonable defaults:
  - 90 days (current default) — slow but cheap (~$0.15 per re-score cycle for 50k users).
  - 30 days — picks up business pattern shifts faster, ~3× cost.
  - Event-driven — re-score when a user crosses certain thresholds (e.g., +10 invoices since last score).
- **Why it matters:** business patterns shift slowly for established users; 90 days is fine. But for fast-growing users it could lag. Also drives the LLM bill.
- **Default if undecided:** 90 days, document a re-score trigger if PM observes drift.
- **By:** before Phase 6 deploy.

---

## Cool — can decide after Phase 6 (won't block launch)

### 9. v2 analyses — committed scope?

- **Decide:** the framework is designed to host other analyses (`churn_risk`, `suspicious_user`, `activation`, `expansion`, `lookalike`). Which of these does PM actually want next, and roughly when?
- **Why it matters:** the framework verification gate (task 4.12) is justified by the cost-saving for future analyses. If v2 is genuinely committed, the framework split pays for itself after the second analysis. If not, we built a slightly more abstract pipeline than strictly needed.
- **Default if undecided:** ship FSM-fit only; `churn_risk` and `suspicious_user` are committed v2 candidates.

### 10. Internal-ops surface — who else sees the dashboard?

- **Decide:** beyond the PM, who else gets read access to the BigQuery dashboard? Sales-ops? Support? Marketing?
- **Why it matters:** drives the GCP IAM bindings on the BigQuery dataset (task 6.2) and potentially how broad the privacy-policy disclosure needs to be.
- **Default if undecided:** PM Google Group + engineering on-call only.

### 11. Privacy disclosure — in-app notice wording

- **Decide:** when (or if) we tell end users that an AI is analyzing their account data. GDPR Art. 13/14 + the EU AI Act transparency rules generally require disclosure when the user is interacting with AI output. Even if FSM-fit is internal-only at v1, the moment we surface `reasoning` text to the user we cross that line.
- **Why it matters:** drives privacy-policy text + possibly an in-app notice on first proposal view.
- **Default if undecided:** privacy team drafts standard sub-processor notice (Anthropic added); no in-app notice required if reasoning stays internal.

---

---

# PM detection spec (workshop, 2026-05-13)

PM provided an expanded detection model on 2026-05-13 (source: `AI_Detection.pdf`). Captured here as the PM-stated design; engineering will adopt per item — some additions are straightforward, some need framework decisions (flagged at the bottom).

## A. Signals — extended set (4 existing + 4 new)

| Signal | Description | Weight | Reliability | Status |
|---|---|---:|---|---|
| `on_site_work` | Items reference on-site work, call-outs, site visits, customer location | 0.40 | ★★★ | P0 (live in v1) |
| `labour_billing` | Items billed by labour-hour, day-rate, per-job (vs. fixed monthly fee) | 0.25 | ★★★ | P0 (live in v1) |
| `scheduling` | Multi-stage jobs, appointments, dispatch language in item names | 0.15 | ★★★ | P0 (live in v1) |
| `recurring_billing` | Same-customer same-service repetition (weekly pool, monthly cleaning) | 0.10 | ★★★ | P0 (live in v1) |
| `complex_multi_line_jobs` | Invoices with labour + parts + materials together = composite work (HVAC, plumbing pattern) | 0.15 | ★★★ | **P1 NEW** |
| `contract_based_billing` | Large amount + few line items = project / contract work without itemisation | 0.10 | ★★☆ | **P1 NEW** |
| `b2b_clients_present` | Client names contain LLC, Inc, Property Management, Corp = B2B customers | 0.10 | ★★★ | **P2 NEW** |
| `multi_address_work` | Multiple distinct addresses in client records or invoices = field work | 0.05 | ★★☆ | **P2 NEW** (depends on address data being collected) |

Two additional fragments in the PDF that look incomplete and need PM clarification:
- *"Large invoice amount + many line items = big project"* — possibly a derived signal, possibly a 9th evidence flag. Need to clarify with PM.
- *"Unpaid…"* — sentence cuts off. Likely a payment-status signal. Need to clarify.

## B. Backend-derived metrics (computed without AI)

These come from MongoDB aggregation, not the LLM. They support the rule (boost signals where applicable) and act as filters / persona context.

| Metric | Description | Use in rule | Source |
|---|---|---|---|
| `invoice_count_30d` | Invoice count in last 30 days | **Filter: < 5 → don't show the flow at all** | Backend |
| `total_invoice_count` | Total invoices ever in this account | Persona context | Backend |
| `avg_invoice_amount` | Average invoice amount | FSM sweet spot context | Backend |
| `invoice_amount_variance` | Spread of invoice amounts | High variance → varied job complexity (FSM signal) | Backend |
| `repeat_customer_ratio` | % clients with ≥ 2 invoices | High → recurring FSM (cleaner / pool); Low → project FSM (painter) | Backend |
| `avg_days_between_repeats` | Mean time between repeat invoices for same client | Weekly/monthly = recurring service; random = on-demand | Backend |
| `estimate_to_invoice_rate` | % of estimates converted to invoices | High + long gap = real job lifecycle | Backend |
| `avg_estimate_to_invoice_days` | Mean estimate → invoice gap | ≥ 3 days = real job; instant = quick service | Backend |
| `estimate_count` | Estimates in account | Presence = more formal workflow | Backend |
| `subscription_paid_days` | Days subscription has been paid | **Filter: < 2 days → exclude** | Backend |
| `subscription_type` | Monthly / yearly | Yearly recent = migration risk | Backend |
| *(implied)* | Estimates without invoice | TBD | Backend |

## C. Pain signals — separate analysis_type, **NOT** FSM-fit

PM explicitly scoped these as a different analysis (different output, different audience). Tracks user pain in the current workflow, independent of whether they'd benefit from FSM. Per the multi-analysis framework, this is a **new `analysis_type`** candidate.

| Signal | Description | Source | What it indicates |
|---|---|---|---|
| `evening_invoice_ratio` | % of invoices created after 19:00 | Backend | "Does admin work in the evening" — pain point |
| `weekend_invoice_ratio` | % of invoices created on weekends | Backend | Works on weekends — pain point |
| `time_to_invoice_after_estimate` | Long delays between estimate and invoice | Backend | Forgetting / losing track |
| `draft_invoice_count` | Number of undated draft invoices | Backend | Unfinished work piled up |
| `notes_mention_callback` | Notes contain "call back", "follow up", "return visit" | LLM | Workflow leakage indicator |
| `notes_mention_workers` | Notes mention other names (Jose, Mike, the crew) | LLM | Indicates team management |

## D. Industry taxonomy — canonical enum

PM provided the full industry picker enum. The LLM currently emits free-text `industry` / `specialization`; PM wants this mapped to canonical IDs for routing.

| Category | Display name | `user_industry` ID |
|---|---|---|
| Trades | General Contracting | `general_contracting` |
| Trades | Electrical | `electrical` |
| Trades | HVAC | `hvac` |
| Trades | Locksmith | `locksmith` |
| Trades | Mechanical Service | `mechanical_service` |
| Trades | Plumbing | `plumbing` |
| Home Services | Handyman | `handyman` |
| Home Services | Appliance Repair | `appliance_repair` |
| Home Services | Flooring | `flooring` |
| Home Services | Junk Removal | `junk_removal` |
| Home Services | Painting | `painting` |
| Home Services | Pest Control | `pest_control` |
| Home Services | Pool and Spa Service | `pool_spa_service` |
| Home Services | Renovations | `renovations` |
| Home Services | Roofing | `roofing` |
| Cleaning | Cleaning | `cleaning` |
| Lawn & Outdoor | Arborist / Tree Care | `arborist_tree_care` |
| Lawn & Outdoor | Landscaping | `landscaping` |
| Lawn & Outdoor | Lawn Care & Maintenance | `lawn_care_maintenance` |
| Lawn & Outdoor | Snow Removal | `snow_removal` |
| Specialty Services | Computers & IT | `computers_it` |
| Specialty Services | Home Theater | `home_theater` |
| Specialty Services | Security and Alarm | `security_alarm` |
| Other | Other | `other` |

**Note:** the priority-industry list used by the rule's industry bonus (Handyman, Cleaning, HVAC, Plumbing, Painting, Appliance repair, General contractor — see [`../../analyses/fsm-fit/scoring.md`](../../analyses/fsm-fit/scoring.md) § Rule) is a subset of this enum. PM may want to expand the FSM-suited bonus to cover other categories from the picker (`pool_spa_service`, `lawn_care_maintenance`, `landscaping`, `arborist_tree_care`, `pest_control`, etc.), not just the seven currently flagged.

## E. Offer mapping — which proposal to show per segment

PM specified **six distinct offers** instead of a single generic "Try Tofu" proposal. Each segment sees its own angle.

| Offer | Pain it addresses | Signals required `true` | Signals NOT allowed | Backend metric reinforcement |
|---|---|---|---|---|
| **Schedule & visits** (where to go, when) | "I don't know where to go next, who's next" | `on_site_work` + `scheduling` | — | `repeat_customer_ratio > 0.3` strengthens (route planning) |
| **Jobs as folders** (everything for one job in one place) | "Job details live in my head, things get lost" | `on_site_work` + `complex_multi_line_jobs` | — | `avg_invoice_amount > $500` strengthens (complex work) |
| **Workers / team** (managing the crew) | "Crew keeps calling, I don't know where they are" | `b2b_clients_present` + large amounts + multi-line | — | `avg_invoice_amount > $2000` + `invoice_count_30d > 15` |
| **Estimate → job → invoice workflow** (quote-to-paid) | "Estimates get lost, I forget follow-up" | `labour_billing` + estimate workflow | `recurring_billing = false` (one-off projects) | `estimate_to_invoice_rate < 0.6` (loses estimates) |
| **Recurring service automation** (auto-jobs for regulars) | "Every month I manually invoice the same clients" | `recurring_billing` + `on_site_work` | — | `repeat_customer_ratio > 0.5` + regular `avg_days_between_repeats` |
| **Contract & deposits** (big projects with deposits) | "Deposits aren't tracked, change orders live in texts" | `contract_based_billing` + `on_site_work` | — | `avg_invoice_amount > $5000` + high `invoice_amount_variance` |

## F. Tiebreaker decision tree (when multiple offers match)

Apply in this priority order:

1. **Team signals** (`b2b_clients_present` + big amounts + high volume) → **Workers** offer
2. **Recurring + on-site** (pool / lawn / cleaning) → **Recurring automation** offer
3. **Contract-based + large amounts** → **Contract & deposits** offer
4. **Complex multi-line + on-site** → **Jobs as folders** offer
5. **Scheduling + on-site** → **Schedule** offer (default)
6. **Otherwise** → **Estimate → job → invoice workflow** (generic)

## G. User-segment cross-matrix (sample cases)

| User case | Signals true | Backend metrics | Offer | Industry typically |
|---|---|---|---|---|
| Plumber solo, on-demand | `on_site`, `labour`, `scheduling` | High variance, $200–1500 | Jobs as folders + Schedule | plumber, hvac, appliance_repair |
| HVAC owner with crew | `on_site`, `labour`, `scheduling`, `b2b` | High volume, $1k–5k, B2B clients | Workers + Schedule | hvac, electrical |
| Cleaner solo recurring | `on_site`, `recurring` | $80–300, high repeat, weekly | Recurring service automation | cleaning, pool, lawn |
| Lawn-care solo route | `on_site`, `recurring`, `scheduling` | $50–200, high repeat, monthly | Recurring + Schedule | lawn, pool service |
| Painter project-based | `on_site`, `labour`, `contract_based` | $2k–15k, low repeat, low estimate-to-invoice rate | Contract & Deposits + Estimate workflow | painter, remodeling |
| General contractor (large) | All 8 signals true | $5k–50k, B2B, high variance | Workers + Contract & Deposits | construction, GC |
| Appliance repair | `on_site`, `labour`, `complex_multi_line` | $150–800, varied | Jobs as folders | appliance_repair |
| Handyman mixed | `on_site`, `labour`, `scheduling` | $100–1500, low repeat, no B2B | Jobs as folders + Schedule | handyman |
| Mobile detailing / car wash | `on_site`, `recurring` | $80–300, mixed repeat | Schedule (route) | auto detailing |
| Pool service | `on_site`, `recurring`, `scheduling` | $100–200, very high repeat, weekly | Recurring service automation | pool service |

## H. Per-segment marketing copy (PM-drafted)

The proposal surface (open decision #1) should show a segment-specific message, not a generic one.

**Plumber / HVAC / Appliance — Jobs as folders**
> **Stop losing track of what each customer needs.**
> Job cards hold everything: scope, parts ordered, visit dates, invoice. One card per customer.

**HVAC team / Construction — Workers**
> **Stop being the dispatcher.**
> Assign jobs to your crew. They see what to do. You see when they start and finish.

**Cleaner / Pool / Lawn — Recurring automation**
> **Stop creating the same invoice every month.**
> Set up recurring jobs once. Visits and invoices generate automatically.

**Painter / Remodeling — Contract & Deposits**
> **Stop tracking deposits in your head.**
> Multi-stage payments, change orders, progress tracking — all on one job card.

**Handyman / mixed — Schedule**
> **Know who to see next, where to go, what to do.**
> Your day on a schedule. Tap the job, get the address, start the visit.

## I. Workshop loose ends (PM noted, no detail yet)

- *список скоров* (list of scores) — needs PM clarification
- *на что должны расчитываться* (what they should compute over) — TBD
- *тестовый датасет* (test dataset) — TBD; possibly relates to a labelled validation set
- *мастер юзер ид* (master user id) — confirm whether routing/scoring should key on `master_user_id` (cross-platform) vs `account_id` (per-account). [`../storage.md`](../storage.md) § Q1 already supports both as subject keys.

---

# Open engineering questions raised by the new spec

These need PM input before adoption work starts:

### EQ-1. P1/P2 signals — LLM-emit vs. backend-derived?
The 4 new signals (`complex_multi_line_jobs`, `contract_based_billing`, `b2b_clients_present`, `multi_address_work`) could come from either the LLM (extending the emit schema) or backend aggregation. Some are cleaner as backend (`b2b_clients_present` — regex on client name; `multi_address_work` — distinct-address count). Some are LLM-natural (`complex_multi_line_jobs` — semantic judgement on item-name composition). **Need:** PM to pick the source per signal, or accept engineering's default split.

### EQ-2. Backend-derived metrics — extend the collected payload?
Most of these aren't in the current per-account JSON collected for training. To compute them retroactively we'd re-run the collector with new aggregations. **Cheap** (~5 min, no LLM cost). Worth doing before re-evaluating the rule.

### EQ-3. Pain signals — separate analysis_type per the catalog?
Per the multi-analysis framework, pain signals are a **new analysis_type** (`pain_signals` or `workflow_friction`). They reuse the same pipeline (D-4.12 stub-slot-in proves this works) but emit a different schema and target a different audience (probably user-facing for the FSM-fit case, internal-only or in-app prompt for pain). **Need:** PM intent — is this v2 scope, or do we ship it alongside FSM-fit in v1?

### EQ-4. Industry mapping — extend the LLM emit, or map server-side?
Options:
- **(a)** Constrain the LLM to emit `user_industry` IDs directly (modify the prompt + emit schema to enumerate the 24 IDs). Cleaner, but the LLM may force-fit poor matches into `other`.
- **(b)** Keep free-text LLM output, add a mapping table server-side (string-normalize → canonical ID). More forgiving; slightly more code.
- **Recommendation:** (a) — let the LLM pick from the enum directly. Strict-schema can enforce it. **Need:** PM sign-off.

### EQ-5. Offer routing — where does this logic live?
The decision tree in (F) is a tier-style classifier on top of the evidence flags. Options:
- **(a)** LLM emits a `recommended_offer` enum directly (extends emit schema).
- **(b)** Rule v3 in code: after evidence flags + score, walk the decision tree, set `offer` field.
- **(c)** Push it to the BFF: read evidence flags via gRPC, decide offer at render-time.
- **Recommendation:** (b). The rule is deterministic, recalibratable, and already where v1/v2 lives. BFF only consumes the `offer` field. **Need:** PM sign-off and an updated rule_version (v3).

### EQ-6. Rule v3 weight retune?
With 4 new signals (combined weight 0.40) on top of the 4 existing (0.90 cap), the maximum score is now 1.30 — needs cap/normalization re-think. Options:
- **(a)** Cap at 1.0 (current rule v2 caps via Math.min); tier thresholds stay same but the signal-density required for `strong` drops.
- **(b)** Lower the existing weights proportionally so new total maxes at 0.90.
- **(c)** Move to a normalized score (sum of weights / max possible).
- **Recommendation:** discuss with PM after EQ-2 (new backend metrics collected) — we can then re-calibrate against a relabelled sample. Likely **(b)** since (a) makes strong easier to reach and (c) loses the boolean-summed simplicity.

### EQ-7. The two PDF fragments — clarify
- *"Large invoice amount + many line items = big project"* — is this a 9th evidence flag (call it `big_project`?), or just commentary supporting `contract_based_billing`?
- *"Unpaid…"* — payment-status signal? Or filter? PM to complete the sentence.

---

## How this folder is used

- Add a new file `<topic>.md` here when an item gets enough discussion to outgrow a bullet point above.
- When a decision is made, write the resolution inline in this README under that item (e.g., *"Resolved 2026-05-15: proposal surface = dashboard card, reasoning stays internal."*) and update the linked task/spec doc.
- Strike through resolved items rather than deleting — keeps a history of decisions for future reference.

## Quick reference

- FSM-fit scoring: [`../../analyses/fsm-fit/scoring.md`](../../analyses/fsm-fit/scoring.md)
- Analysis contract (framework): [`../../analyses/scoring.md`](../../analyses/scoring.md)
- FSM-fit training: [`../../fsm-fit/training.md`](../../fsm-fit/training.md)
