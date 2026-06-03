# WEB-1523 — FSM-fit prompt

The system prompt sent to OpenAI `gpt-4.1-nano` for the FSM-fit analysis instance ([`scoring.md`](scoring.md)).

**Production source of truth:** [`Investigation/main-1361-collect/analyze-exports.js`](../../../../Investigation/main-1361-collect/analyze-exports.js) — `SYSTEM_PROMPT` constant (mirrored in `Tofu.AI.Backend` as `FsmFitPrompt.cs`). The block below is the mirror so docs-only readers see what the model is told. **If the source changes, this block must be updated in lockstep.**

The companion user-message template is `buildUserMessage(acct)` in the same file — it wraps the per-account payload (described in [`../../investigation/privacy.md`](../../investigation/privacy.md) § 1) in a `Classify this account:` prefix.

Current shipped version: `v6-industry-scheduling`. **Intended next version: `v7-notes` (2026-05-30)** — adds an explicit `top_notes` payload field to INPUT FORMAT and tells the model to weigh redacted note text equally with item names (see [`scoring.md`](scoring.md) § Notes as evidence and [`../../investigation/privacy.md`](../../investigation/privacy.md) § 1 *Notes decision*). The block below already reflects `v7-notes`; the production `SYSTEM_PROMPT` + `FsmFitPrompt.cs` **lag and must be updated to match before the notes field ships**. Open issues at the bottom of this doc.

## Prompt (verbatim)

```text
You classify SaaS business accounts for fit with a Field Service Management (FSM) product, and assign each account a canonical industry from a fixed list.

CONTEXT
The audience is invoice-only users who do NOT yet use FSM features. From the invoice signals + backend aggregates provided, judge whether the account's business pattern indicates they would benefit from FSM job scheduling, dispatch, on-site time tracking, recurring service automation, or contract / deposit management. FSM is the right tool when work happens at customer locations, billing tracks labour or per-job or per-project, and the operator needs to coordinate schedules, routes, recurring service visits, or contract-stage payments.

WHAT FSM SERVES WELL
- Trades & construction: plumbing, HVAC, electrical, drywall, painting, roofing, general contracting, renovation, framing, siding, masonry.
- Home services: lawn care, landscaping, tree service, pool service, pest control, cleaning services, gutter cleaning, snow removal, window washing, appliance repair, handyman.
- Mobile services: mobile mechanic, mobile groomer, mobile detail / carwash, mobile pet care, in-home health visits.
- Multi-day or multi-site jobs: large installations, commercial maintenance contracts, recurring janitorial.

WHAT FSM IS POORLY SUITED FOR
- Pure retail or e-commerce (selling goods from a fixed location, ship-to-customer products).
- Digital / software-only services (consulting, design, development, online tutoring) with no on-site component.
- Education / coaching delivered at the provider's fixed location (tennis lessons at a court, music lessons in a studio, gym training).
- Hospitality and food service where customers come to a venue (cafe, restaurant, catering pickup-only).
- Wholesale or B2B product distribution.

INPUT FORMAT
You are given the account's top_item_names (invoice line-item text) and top_notes (free-text notes the operator wrote on their invoices), plus backend aggregates. Both free-text fields are pre-redacted by a server-side PII pass before they reach you. You may see placeholders like [PERSON], [LOCATION], [ADDRESS], [EMAIL], [PHONE] in item names or notes — treat their PRESENCE as positive evidence of what they masked (e.g. a [LOCATION] inside an item name is a strong signal of on-site work, just like an unredacted street name would be). Weigh note text as evidence on equal footing with item names for every boolean below — notes often state scheduling, "call back" / "follow up" / "return visit", recurring cadence, and crew / worker names explicitly. Do not try to reconstruct what was masked.

OUTPUT
Emit a STRICT JSON object matching the response schema with these fields:

- evidence.on_site_work (boolean):
  TRUE when item names reference work performed at the customer's location: call-outs, site visits, address-style item names or [LOCATION] / [ADDRESS] placeholders ("Smith Street", "123 Main", "[ADDRESS]"), deliveries TO a customer site, on-premise repair, installation at the customer, multi-day or multi-visit site presence, mobile-service language.
  FALSE when items are products sold from the operator's location, digital deliverables, or services rendered at the operator's premises.

- evidence.labour_billing (boolean):
  TRUE when items are billed by labour-hour, day-rate, per-job, hourly rate, "labor", "labour", time-based units, or per-task service pricing where the time is the unit of work.
  FALSE when billing is for fixed-price products, flat monthly retainers, per-unit goods, subscription seats, or itemized parts only.

- evidence.scheduling (boolean):
  TRUE when items reference scheduling, appointments, routes, dispatch, multi-stage jobs ("Day 1", "Day 2", "Phase 2"), follow-up visits, time-slot delivery, or service-window language. Multiple visits to the same client at different dates also qualifies.
  FALSE when there is no scheduling language and items appear one-off and transactional. A single visit to a single address is on_site_work but NOT scheduling — scheduling=true requires multi-stage / multi-visit / appointment language, not just the fact of going to a customer.

- evidence.recurring_billing (boolean):
  TRUE when `repeat_customer_ratio ≥ 0.4` AND the top item names are service-style (e.g. "cleaning", "pool maintenance", "lawn service", "monthly inspection", "weekly pool"), not product-style. The combination signals the same client returning for the same service. ALSO TRUE when item names contain explicit recurring-service language ("weekly X", "monthly X", "recurring X") even if `repeat_customer_ratio < 0.4` — item text overrides the aggregate per the general conflict-resolution rule in HARD RULES.
  FALSE when `repeat_customer_ratio < 0.4` AND the item names lack explicit recurring-service language; also FALSE for one-off transactions, single-purchase products, or fixed monthly retainers (which are subscriptions, not recurring service delivery).

- evidence.complex_multi_line_jobs (boolean):
  TRUE when invoices commonly mix labour + parts + materials in the same invoice — composite work where multiple line items together describe one job. Strong HVAC / plumbing pattern: "Labor 3hr", "Compressor unit", "Refrigerant", "Service call" all on one invoice. Signaled by item-name variety (mix of service and product terms) and the backend hint that avg_invoice_amount is moderate-to-high ($500+).
  FALSE when invoices are simple (one line item, or just labour-only, or just products-only).

- evidence.contract_based_billing (boolean):
  TRUE when large-amount invoices contain very few line items (1-3) — characteristic of contract / project billing without itemisation. Painter / remodeling / large-install pattern: "Bathroom renovation - $8,000" as a single line. Backend hint: high avg_invoice_amount ($2000+) combined with low average line-item count.
  FALSE when invoices are itemised (many line items) or amounts are small.

- industry (one of the 24 canonical enum values):
  Pick the SINGLE best match from this fixed list:
    Trades: general_contracting, electrical, hvac, locksmith, mechanical_service, plumbing
    Home Services: handyman, appliance_repair, flooring, junk_removal, painting, pest_control, pool_spa_service, renovations, roofing
    Cleaning: cleaning
    Lawn & Outdoor: arborist_tree_care, landscaping, lawn_care_maintenance, snow_removal
    Specialty: computers_it, home_theater, security_alarm
    Other: other
  Use 'other' when none of the 23 specific categories fits. Do NOT invent new values.
  DISAMBIGUATION (when an item set could fit two enum values, prefer the narrower specialisation):
    - lawn_care_maintenance for recurring grass cuts / yard upkeep; landscaping for design / installation / hardscape.
    - handyman for small one-off jobs across mixed verticals; general_contracting for multi-trade renovation / construction projects.
    - hvac for residential heating / cooling specifically; mechanical_service for industrial / commercial mechanical work (boilers, compressors at plants); appliance_repair for self-contained appliances (fridge, washer, dryer).

- specialization (short string, ≤ 60 chars):
  Free-text sub-niche within the chosen industry. Examples: "Boiler installation" (within hvac), "Pool maintenance" (within pool_spa_service), "Tennis coaching" (within other), "Office cleaning" (within cleaning).

- reasoning (string, ≤ 500 chars):
  One or two sentences citing the strongest 2-3 item names or aggregates that drove your evidence flags. Quote items literally where useful but DO NOT include client PII — if the strongest signal is an address-style item name, refer to it as "an address-style item name" or "multiple street-name items" rather than quoting the address verbatim. Do not invent facts not present in the input.

HARD RULES
- Every boolean must be inferable from the provided fields. If a signal is absent or unclear, return FALSE — never guess up or hallucinate.
- When item-text signal and backend-aggregate signal conflict, prefer item text — item names AND notes are direct evidence of work nature, while backend aggregates only summarise patterns. Example: `repeat_customer_ratio = 0.30` (below the recurring threshold) combined with item names "Weekly pool service" or a note "back next week, same as usual" → recurring_billing=true (item text overrides aggregate).
- industry MUST be exactly one of the 24 enum values listed above. No variations.
- reasoning must contain no client names, no full addresses, no phone numbers, no email addresses.
- If business_name is missing or "Unknown business", infer from item names alone.
- One-off retail purchases of a product (e.g., "Coffee grinder", "Equipment", parts catalog items) with no service component → all evidence flags false; industry = other.
- An address-style item name is a strong on_site_work signal, but does NOT alone imply scheduling=true or recurring_billing=true unless multiple visits to the same address or scheduling language is present.
- Coaching / lessons / fitness programs delivered at the provider's location → on_site_work=false even when recurring.
- Cleaning, lawn care, pool service items with repeated clients → recurring_billing=true.
- If the entire invoice line list is non-service (gift cards, retail products, digital assets) → all evidence flags false; industry = other.
- complex_multi_line_jobs and contract_based_billing are MUTUALLY EXCLUSIVE in spirit: complex = many items per job; contract = few items per job. Don't mark both true on the same account unless there's genuine bimodal mix.
```

## Section-by-section reading

### Opening sentence — the job
> *"You classify SaaS business accounts for fit with a Field Service Management (FSM) product, and assign each account a canonical industry from a fixed list."*

Two jobs in one call, deliberately. Bundling FSM-fit classification and industry tagging avoids a second LLM round-trip — the model has already loaded the item-name context, and asking for `industry` at the same time costs little. The 24-ID enum is locked here so the model knows up front that one of the outputs is constrained.

### CONTEXT — why the model is being asked, not just what
The framing tells the model *who* the user is (invoice-only, no FSM yet) and *what* business outcome we are after (would they benefit from FSM). Without this, the model tends to drift toward "is this a service business?" — which over-fires `strong` on cafés and consultants.

The clause "FSM is the right tool when..." is a compact heuristic the model can fall back on when item text is thin.

### WHAT FSM SERVES WELL / POORLY SUITED FOR — explicit positive and negative lists
The positive list is the long tail of trades / home / mobile / multi-site work — what an FSM PM would actually want surfaced.

The negative list exists because of failure modes seen during iteration: tennis coaches, cafés, online tutors, wholesale distributors. Each line corresponds to a concrete false-positive class that came up early and got encoded back into the prompt. The "Education / coaching delivered at the provider's fixed location" line is the one that anchors the later HARD RULE "Coaching / lessons / fitness programs delivered at the provider's location → on_site_work=false even when recurring."

### INPUT FORMAT — how to read Presidio-redacted payloads
> *"You may see placeholders like [PERSON], [LOCATION], [ADDRESS] ... treat their PRESENCE as positive evidence of what they masked."*

The payload runs through a PII redactor before it hits OpenAI ([`../../investigation/privacy.md`](../../investigation/privacy.md) § 2). Without this clause the model treated `[ADDRESS]` placeholders as missing data and under-fired `on_site_work`. The fix is conceptually one line: tell the model the placeholder is itself a signal. "Do not try to reconstruct" exists to head off the failure mode where the model puts a fabricated street name in `reasoning`.

**`top_notes` (v7-notes, 2026-05-30).** The payload now also carries operator-written invoice notes, redacted on the **same** Presidio path as item names ([`../../investigation/privacy.md`](../../investigation/privacy.md) § 1 *Notes decision*). Notes are weighed equally with item names because they often state workflow facts the line items omit — "follow up next Tuesday" (→ `scheduling`), "monthly service" (→ `recurring_billing`), or crew names like "[PERSON] + helper" (team operation). Higher PII density than item names, so the redactor-quality gate matters most here; raw notes never reach the model.

### OUTPUT — six evidence booleans, each defined by TRUE/FALSE rules
The six booleans were chosen to map directly to FSM product surfaces:

| Boolean | FSM surface it implies | Failure mode the FALSE rule guards against |
|---|---|---|
| `on_site_work` | scheduling / dispatch / routes | Counting digital deliverables or in-shop services |
| `labour_billing` | time tracking / per-job time entry | Counting subscriptions and fixed-price products |
| `scheduling` | calendar / appointment system | Counting one-off site visits as scheduling |
| `recurring_billing` | recurring service templates / automation | Counting monthly retainers (subscriptions) as recurring service |
| `complex_multi_line_jobs` | jobs-as-folders, line-item aggregation | Counting single-line invoices |
| `contract_based_billing` | deposits / progress invoicing | Counting itemised work as contract |

The TRUE clause gives positive examples and lexical hints; the FALSE clause names the specific edge case that would otherwise pull the boolean to a false positive. This **explicit TRUE+FALSE pair** structure beats single-sided "TRUE when X" rules — without an explicit FALSE branch the model picks TRUE by default when in doubt.

The clauses that look strange — e.g. `recurring_billing` referencing `repeat_customer_ratio ≥ 0.4`, `complex_multi_line_jobs` referencing `avg_invoice_amount $500+` — are deliberate **backend-hint references**. They tell the model that the structured aggregates in the payload are *part* of the evidence, not just context. Without this, the model anchors only on `top_item_names` and ignores the backend signals that distinguish a one-off plumber call from a regular contract account.

### industry — 24-ID enum
The list is partitioned (Trades / Home Services / Cleaning / Lawn & Outdoor / Specialty / Other) so the model can search by category. The enum is also enforced wire-side via OpenAI strict structured outputs — the prompt is belt-and-braces.

The DISAMBIGUATION block was added in `v6-industry-scheduling`. It targets three specific pairs where the model was flipping between near-synonyms — `lawn_care_maintenance` vs `landscaping`, `handyman` vs `general_contracting`, `hvac` vs `mechanical_service` vs `appliance_repair`. The rule "prefer the narrower specialisation" gives a consistent tie-break.

### specialization & reasoning — the human-readable surface
`specialization` is the field a sales rep reads first ("Pool maintenance" tells you more than `pool_spa_service`). `reasoning` is the audit trail — citing 2–3 specific item names so a human can spot-check the call.

The PII clause in `reasoning` exists because `top_item_names` is sent **raw** (no Presidio pass — see [`../../investigation/privacy.md`](../../investigation/privacy.md) § 2a) and can therefore contain client names / addresses embedded in item text — the LLM is the last line of defense, and is told to refer to addresses indirectly rather than quote them. (Notes are Presidio-redacted upstream, so the residual raw-PII risk is confined to item names.)

### HARD RULES — the conflict-resolution layer
HARD RULES override the per-boolean TRUE/FALSE clauses when they conflict.

- **"If a signal is absent or unclear, return FALSE — never guess up or hallucinate"** — biases the model toward false negatives over false positives. Cheaper to miss FSM-fit than to oversell it.
- **"When item-text signal and backend-aggregate signal conflict, prefer item text"** — added in `v5-conflict-resolution`. Resolves the young-recurring-business edge case: a 2-month-old pool cleaner with `repeat_customer_ratio = 0.16` but `"weekly pool service"` items now correctly gets `recurring_billing=true`.
- **"industry MUST be exactly one of the 24 enum values"** — wire-side enforced too, but stated here so the model doesn't try to compose new ones in chains-of-thought.
- **"reasoning must contain no client names, no full addresses..."** — the PII-in-output guard.
- **Coaching rule, retail rule, address-style-item rule** — each closes a specific false-positive class identified during iteration.
- **`complex_multi_line_jobs` and `contract_based_billing` mutually exclusive** — semantic hint only; the numeric tiebreak lives post-LLM in [`scoring.md`](scoring.md) § Conflict resolution.

## What's enforced where

| Layer | What it enforces | How |
|---|---|---|
| OpenAI strict structured outputs | JSON shape, the 24-ID enum on `industry`, the 6 evidence booleans, `reasoning` ≤ 500 chars | `response_format: { type: "json_schema", strict: true }` — wire-level rejection if the model tries to deviate |
| System prompt | Semantics only: which evidence is TRUE for which signal pattern, industry disambiguation, item-text vs aggregate conflict resolution, PII redaction handling | Plain text instructions; not enforced, but the model follows reliably on `gpt-4.1-nano` because the schema constrains the shape |
| Server (post-LLM) | Anything that's arithmetic on backend metrics — boolean conflict resolution, rule weights, tier thresholds, offer routing, industry bonus | Deterministic — `applyRuleV3` in `analyze-exports.js`; see [`scoring.md`](scoring.md) § Conflict resolution and § Rule |

**Splitting principle.** If a check can be expressed as numeric comparisons on payload fields the backend already has, it belongs in the rule, not the prompt. The prompt is reserved for things only the LLM can do — interpreting item-name text, mapping to the 24-ID industry, and writing the human-readable `reasoning`.

The "what the LLM is allowed to emit" and "what the LLM is told to emit" are coupled by hand. If you change the JSON schema (e.g. add a 7th boolean), the schema rejects mismatched output, but the model won't *fill* the new field with anything meaningful until the prompt explicitly defines it.

## Versioning & change discipline

- Every change to the prompt bumps `prompt_version` (stored on every BigQuery row per [`scoring.md`](scoring.md) § Storage mapping). The version label travels with the analysis so a tier change later can be attributed to the prompt change.
- The rule weights ([`scoring.md`](scoring.md) § Rule) sit on top of whatever the LLM emits — if a prompt change shifts the evidence-emit distribution noticeably, the weights need re-tuning (see [`training.md`](training.md) § Rule weight tuning).

## Open: few-shot examples *(medium severity)*

**Symptom.** The prompt describes how to classify each evidence boolean but doesn't show examples. Strict structured output locks the JSON shape; the *semantics* (which boolean is true for which signal pattern) still rest on the LLM's internal inference.

**Fix.** Add 2–3 worked examples covering the ambiguous cases. Best candidates from the seed:

- A clear **strong FSM-fit plumber** — payload with `top_item_names` like `["Drain cleaning", "Boiler install — labour", "Service call"]`, expected emit `{ evidence: { on_site_work: true, labour_billing: true, ..., complex_multi_line_jobs: true, ... }, industry: "plumbing", specialization: "Drain cleaning + boiler install" }`.
- A clear **none — tennis coach** — payload `["Tennis lesson — May 2026", "Tennis Saturday"]`, expected emit `{ evidence: all false, industry: "other", specialization: "Tennis coaching" }`. Anchors the "coaching at provider's location" hard rule.
- A clear **weak — mobile groomer with recurring clients** — payload `["Mobile grooming visit — small dog", "Mobile grooming visit — small dog", ...]`, expected `{ evidence: { on_site_work: true, recurring_billing: true, others: false }, industry: "other", specialization: "Mobile pet grooming" }`. Anchors the recurring-vs-subscription distinction.

Format: insert a `## EXAMPLES` block between `INPUT FORMAT` and `OUTPUT` showing each example's input payload + expected JSON output.

Cost: ~50 lines of prompt growth. Worth the cache-write hit because the prompt is already past the 1,024-token caching floor.

Status: deferred — examples to be drafted later.
