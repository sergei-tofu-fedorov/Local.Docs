_Research compiled 2026-05-10. Split out of `provider.md` on 2026-05-18 — this doc owns PII payload shape, redaction, and the legal stack (us↔provider + us↔users). The LLM model / cost / integration decision lives in [`provider.md`](provider.md)._

# WEB-1523 — Privacy (PII payload, redaction, legal posture)

Decides **what data we send to the LLM**, **how it is redacted** before it leaves our infrastructure, and **which legal hurdles apply** at both axes — us↔provider (DPA, ZDR, region) and us↔users (privacy policy, sub-processor disclosure, AI Act). [`provider.md`](provider.md) picks the model under the constraints set here.

## Decision

- **Minimum payload (FSM-fit v1):** business name + Presidio-redacted top-N invoice item names + invoice/client aggregates + repeat-client pattern + currency/timezone/account age. **Raw invoice notes are excluded from v1.**
- **Redaction:** Microsoft Presidio over item-name strings server-side before serialization. No raw client names/addresses/phones ever on the wire.
- **Region constraint:** EU-resident processing for EU accounts (PRC-jurisdiction providers are disqualified regardless of contract terms — see § 3).
- **Allow-list:** the per-analysis PII allow-list at § 3a is the authoritative source. New analyses add a row and get legal sign-off before they ship.
- **Customer-side disclosure:** privacy-policy + sub-processor list updates cover the **full catalog** (FSM-fit v1; v2 `churn_risk` + `suspicious_user`) in one cycle, not per-analysis. See § 4.

## 1. Minimum payload — FSM-fit instance

> **Framework note.** Each `analysis_type` declares its own minimum payload via its `IPayloadBuilder<T>`. This section is the **FSM-fit instance** — the payload that builder produces, as observed in the 2026-05-13 1,000-account sweep. The per-analysis PII allow-list in § 3a stays in this doc; the FSM-fit payload below is one row of that allow-list expanded.

> **FSM-fit scope:** target users are **invoice-only** users (we are proposing the FSM/jobs feature to them). `jobs` / `visits` / technician-assignment data is **excluded from the payload** — these users have none, and existing job-using users are not the audience. FSM-fit must be inferred from invoice-only signal.

Goal: enough signal to score FSM-fit, **with as little PII as possible**. Drawn from the data inventory in [`../analyses/data-sources.md`](../analyses/data-sources.md) Part A. Each row below is a field that **leaves the backend in the LLM request body** — verified against the 2026-05-13 payload shape.

| Group | Fields | Source | PII sensitivity |
|---|---|---|---|
| Account identity | `account_id` (opaque hash), `business_name` | `Account` | `account_id` = quasi-identifier (random hash); `business_name` = **direct PII for sole proprietors** |
| Geo / lifecycle | `currency_code`, `timezone`, `created_time`, `account_age_days`, `last_modified_time` | `Account` | Quasi-identifiers + lifecycle aggregates |
| Invoice activity (envelope) | `invoice.count`, `invoice.total_revenue`, `first_created_at`, `last_created_at`, `count_last_7_days`, `status_counts` | aggregated from `invoices` | None — aggregates |
| **Invoice item names** | `invoice.top_item_names[].name + count` (top-N by frequency) | `Invoice.Items[].Name` | **High at source** — item text can contain client names, addresses, project detail. **Designed to be Presidio-redacted before send — verify on real payloads, the 2026-05-13 dump does not show obvious redaction markers** |
| **Invoice notes** ⚠ | `invoice.top_notes[].note + count` (top-N by frequency) | `Invoice.Notes` | **High and currently raw on the wire.** Sample payloads contain personal names, bank-account numbers, branch info, emails. **This contradicts § 2's commitment to exclude notes from v1** — see "Open privacy issue" below. |
| Estimate activity | `estimate.count`, `first_created_at`, `last_created_at`, `count_last_7_days`, `status_counts` | aggregated from `estimates` | None — aggregates |
| Clients (counts only) | `clients.count`, `distinct_billed`, `repeat_clients_2plus`, `invoices_per_client_avg` | aggregated from `Invoice.ClientId` + `clients` | None — aggregates; raw client names/emails/phones never on the wire |
| Email engagement | `email_engagement` (sent / delivered / opened / clicked / bounced rates) | aggregated from `EmailStatus` | None when populated as aggregates |
| Subscription | `subscription` (plan id, tenure / start) | `AccountSubscription` | None alone; quasi-identifier joined to others |
| Backend metrics (8 numeric) | `backend_metrics.invoice_count_30d`, `avg_invoice_amount`, `invoice_amount_variance_cv`, `avg_line_items_per_invoice`, `repeat_customer_ratio`, `avg_days_between_repeats`, `estimate_to_invoice_rate`, `estimate_count` | server-side aggregates over `invoices` + `estimates` | None — pure aggregates |
| Backend bools / derived count | `backend_bools.b2b_clients_present` (regex over `Client.Name`), `multi_address_work`, `distinct_addresses` (count-distinct over `Client.Address`) | server-side from client identity fields | None — only the booleans + count leave the backend; raw client names / addresses never do |
| PM-filter outcomes | `pm_filters.invoice_count_30d_under_5`, `subscription_paid_days_under_2` | derived booleans over metrics + subscription | None — derived booleans (also gate whether the LLM call happens at all) |

### Open privacy issue — invoice notes on the wire ⚠

The current payload shape sends `invoice.top_notes[].note` **unredacted** — sample notes contain personal names, bank-account numbers, branch info, and email addresses. § 2 of this doc states notes are excluded from v1; the current implementation does not match that statement. Three ways to resolve:

1. **Drop `top_notes` from the payload entirely** (matches the original § 2 stance; safest legally, smallest analytical loss — notes barely move the rule's score given item names are present).
2. **Keep notes but Presidio-redact them server-side** the same way item names are (or are supposed to be). Requires explicit legal sign-off + a redactor-quality test on a real sample.
3. **Promote notes to an allowed field** in § 3a with an updated commitment and a new sub-processor disclosure if notes meaningfully change the analysis's risk profile.

The redaction commitment for `top_item_names` should also be verified — the sample payload shows item strings as raw collected text; no `[REDACTED]` markers are visible.

### What never leaves the backend

- Raw `Client.Name` / `Client.Phone` / `Client.Email` / `Client.Address` — only the derived count + boolean (`distinct_addresses`, `b2b_clients_present`) cross the wire.
- Bank / payment details from `Invoice.Notes` if option (1) is chosen above.
- Full invoice line lists, dates, amounts per row — only the aggregates above leave.

**Sensitivity ladder used:**

- **None** — pure aggregate (counts, sums, percentiles, derived booleans).
- **Quasi-identifier** — narrows but does not identify alone.
- **Direct PII** — names, emails, phones, addresses, sole-proprietor business names.
- **High at source** — unstructured free-text; allowed on the wire only after server-side redaction.

## 2. Payload-design rules

With jobs data out of scope, FSM-fit must come from invoice-only signal. Most of the table above is **aggregates and derived booleans** — invoice counts, ratios, variance, the two field-service proxies (`b2b_clients_present` boolean + `distinct_addresses` count). Those carry no PII. The PII surface lives in the unstructured fields — item names and notes — and in `business_name`.

1. **Invoice item text** (`top_item_names`) — the **central FSM-fit signal**. Item descriptions like "Plumbing service", "HVAC install", "Drywall labor" are the strongest tell. **Design intent:** cluster item names server-side, send only the top-N normalised strings, with Microsoft Presidio redaction applied to each name before serialisation [[Source](https://github.com/microsoft/presidio)]. **Current state:** the redaction step is not visibly applied (sample names are raw collected text). Verify the redactor is actually wired into the payload builder before production rollout.
2. **Invoice notes** (`top_notes`) — high free-text PII risk; the current payload sends them raw. See § 1 *"Open privacy issue"* for the three resolution options. Until one is picked, **production rollout is blocked** on this — sending bank-account numbers and personal names to an external LLM without explicit legal sign-off would breach our existing customer DPA.
3. **Identity fields** (client names, addresses, phones, emails) — never on the wire. The two field-service proxies (`distinct_addresses` count, `b2b_clients_present` boolean) are computed server-side from these fields, and only the resulting integer / boolean leaves the backend.

The intended v1 payload — `business_name` + redacted top-N item names + envelope aggregates + 8 backend metrics + 2 derived booleans + 1 derived count — keeps the on-wire PII surface to "business identifier + already-public business activity." The current implementation exceeds this by also sending raw notes; closing that gap is the precondition for shipping.

## 2a. Presidio — what it does and how it shapes LLM decisions

**Microsoft Presidio** ([github.com/microsoft/presidio](https://github.com/microsoft/presidio)) is the open-source PII redaction library that handles the last server-side step before any free-text field is serialised into the LLM request body. It runs **inside our process** — no third-party call, no network hop. The text reaches OpenAI already redacted.

### What it detects

Out of the box, Presidio's analyser recognises (most also work in EU languages):

| Category | Examples |
|---|---|
| Identity | `PERSON`, `EMAIL_ADDRESS`, `PHONE_NUMBER`, `DATE_OF_BIRTH` |
| Financial | `CREDIT_CARD`, `IBAN_CODE`, `US_BANK_NUMBER`, `CRYPTO` |
| Government IDs | `US_SSN`, `US_DRIVER_LICENSE`, EU country IDs |
| Geographic | `LOCATION` (cities, regions, countries, street addresses, landmarks) |
| Network | `IP_ADDRESS`, `URL`, `DOMAIN_NAME` |
| Custom | Regex / ML recognisers you wire in |

Each detection has a confidence score (0–1) and a character span. The companion Presidio Anonymizer replaces each span with a placeholder of your choice — usually `[ENTITY_TYPE]` — before serialisation.

### How this affects FSM-fit decisions

Most of the patterns the rule depends on are **vocabulary, not identity**, so they survive redaction cleanly:

| Item-text signal | Survives Presidio? |
|---|---|
| `"plumbing service"`, `"HVAC install"`, `"drywall labour"` — vertical vocabulary | ✅ Yes — common-noun vocabulary is never matched as PII |
| `"call-out fee"`, `"site visit"`, `"emergency"` — on-site indicators | ✅ Yes |
| `"by the hour"`, `"day rate"`, `"per visit"` — billing-pattern indicators | ✅ Yes |
| `"weekly"`, `"monthly"`, `"contract"` — cadence words | ✅ Yes |
| `"Boston HVAC service"` — city-prefixed vertical | ⚠ Partially — "Boston" → `[LOCATION]`; "HVAC service" survives. Geo signal lost but redundant with `timezone` / `currency_code`. |
| `"Repair at Marriott Hotel"` — venue-named job | ⚠ Partially — "Marriott Hotel" gets tagged. Venue-type cue weakens but is redundant with `b2b_clients_present`. |
| `"John's repair at 456 Maple St"` — full identity-rich description | ⚠ Heavy — becomes `"[PERSON]'s repair at [LOCATION]"`. The structural "repair / at" vocabulary survives, which is what the rule grades on. |

**Net effect on rule output is small** because:

1. The rule's primary signals are vocabulary-level (item type, billing language, cadence) — these are preserved.
2. The identity-level signals the LLM might otherwise infer (which addresses, which clients) are **already encoded server-side** as the 8 backend metrics + `multi_address_work` + `distinct_addresses` + `b2b_clients_present`. The LLM doesn't need to read "Maple St" to know there are six addresses — that count is already in the payload.
3. The `industry` enum the LLM emits is a fixed 24-ID list ([`../analyses/fsm-fit/scoring.md`](../analyses/fsm-fit/scoring.md) § Emit schema) — strict structured outputs prevent the LLM from improvising city- or person-named industries even when it sees them.

### Where it can strip signal we'd want

Two edge cases worth watching once Presidio is wired in:

1. **City names embedded in industry strings** — `"Boston HVAC"`, `"NYC handyman"`. Presidio drops the city; the vertical noun survives. Mostly harmless.
2. **Common-noun false positives** — `"Pool"` (read as a person name), month names like `"May"` (read as a person), or generic words that match Presidio's NER thresholds. Tuned out by raising the confidence threshold or by an allow-list.

### Tuning levers

If a redaction class is too aggressive, three knobs:

1. **Disable the recogniser** — drop `LOCATION` entirely if cities are valuable.
2. **Raise the confidence threshold** — only redact at ≥ 0.8 (default 0.5).
3. **Allow-list** — pre-seed industry / vertical strings that should never be redacted.

**Validation method.** Run the rule against the 30-account seed twice — once with Presidio applied to the free-text inputs, once without — and compare tier macro-F1. If the with-Presidio number is within ~3 points of the without-Presidio number, ship the default config; if it drops further, tune.

## 3. PII routing constraints (legal layer 1 — us ↔ provider)

Before scoring providers in [`provider.md`](provider.md) § 2, the rules of the game.

### Can we send PII to LLM providers at all?

**Yes — conditionally.** GDPR does not ban using third-party processors; it requires four things to be true:

1. **Lawful basis** (Art. 6) — typically legitimate interest or contract performance for SaaS analytics over your own users; consent for anything customer-facing.
2. **Signed DPA** with the provider (see below) — without it, you legally cannot route personal data to that provider.
3. **Cross-border transfer rules respected** (Chapter V) — if the data leaves the EU/EEA, you need a Standard Contractual Clause (SCC), an adequacy decision (e.g. EU-US Data Privacy Framework), or another transfer mechanism.
4. **Data minimization** (Art. 5) — only send what is strictly necessary. This is why § 1 of this spike matters: smaller payload → smaller PII risk → easier compliance.

You **cannot** send PII to a provider with no DPA, no transfer mechanism, or one located in a jurisdiction with no compatible data-protection regime (China, Russia, etc.).

### DPA — Data Processing Agreement

Contract between you (the **controller**) and the provider (the **processor**) per **GDPR Art. 28**. Specifies:

- Purpose and scope of processing.
- Security measures the processor commits to.
- **Sub-processor flowdown** — if the LLM provider uses subcontractors, the same obligations apply to them.
- Breach-notification timing.
- Data return / deletion at end of contract.

Every major LLM provider (OpenAI, Anthropic, Google, Microsoft, AWS, Mistral, Cohere) publishes a standard DPA. You sign it once per vendor; without it the integration is not GDPR-compliant.

### ZDR — Zero Data Retention

Provider commits **not to log or store your prompts and responses** beyond the in-flight time needed to fulfill the request. Without ZDR, providers default to ~30-day retention for abuse monitoring; staff may have access for safety reviews.

ZDR matters because:
- Reduces breach blast radius — there's nothing for an attacker to steal at the provider.
- Eliminates risk of your prompts feeding training data.
- Often required for HIPAA-covered or contractually-sensitive data.
- Makes data-deletion / "right to erasure" requests trivial — there's nothing to delete.

ZDR availability today: OpenAI Enterprise + approved API customers, Anthropic ZDR endpoints, Vertex AI per-model ZDR, Azure OpenAI configurable retention, AWS Bedrock by default (Bedrock does not retain prompts/completions).

### Why region matters

The region the provider processes your data in determines:

1. **Which legal regimes apply.** Data physically in `eu-central-1` (Frankfurt) is governed by GDPR + German law. Data in `us-east-1` (Virginia) is governed by US federal + Virginia state law, plus subject to FISA 702 / CLOUD Act access. Data in PRC infrastructure is subject to PRC national security and data-sharing laws — this is why **DeepSeek's hosted API is disqualified** for EU/US user data regardless of contract terms.
2. **Whether you need SCCs.** EU → EU = no transfer mechanism needed. EU → US = needs DPF (adequacy) or SCCs. EU → China = no available mechanism, illegal.
3. **Latency.** First-token latency for EU users hitting US endpoints is typically 80-200 ms higher than EU-region equivalents.
4. **Regulator expectations.** German, French, Italian DPAs have aggressively investigated US-cloud LLM use over the past two years; staying EU-resident lowers regulator-attention risk dramatically.

**Rule of thumb for our payload:** any prompt that includes business names + invoice item text from EU users should be processed in an EU region by default. The Anthropic subscription routes through US infra by default — for EU accounts we should route through Bedrock `eu-central-1` instead of the direct Anthropic API.

## 3a. Per-analysis PII allow-list (framework)

The catalog's analyses send different payload shapes; each has its own PII budget. This table is the **central authority** — what an analysis is allowed to put on the wire to the LLM. New analyses add a row here as part of their design doc and get legal sign-off before they ship.

| `analysis_type` | Allowed fields on the wire | Redaction strategy | `reasoning` audience | Notes |
|---|---|---|---|---|
| `fsm_fit` (v1) | `account_id` (hash); `business_name`; geo / lifecycle (`currency_code`, `timezone`, `account_age_days`, etc.); invoice / estimate / client envelope aggregates; top-N invoice item names (intended Presidio-redacted); 8 backend metrics + 2 backend booleans + `distinct_addresses` count + PM-filter outcomes — full detail in § 1. **Notes (`top_notes`) currently in the payload raw — pending resolution per § 1 *Open privacy issue*.** | Presidio over item-name strings before serialisation (verify); notes either dropped, redacted, or formally promoted before production; client names / addresses / phones / emails never sent (only the count + boolean derived from them) | end-user (in-app — proposal copy may quote `reasoning`) | Reasoning user-visibility forces an extra check: rerun-with-other-account input must never bleed redacted item names across `business_name` boundaries. |
| `churn_risk` (v2) | `business_name`, login-recency aggregates, invoice-volume trend, payment-failure counts, subscription tenure, plan id | None needed — payload is already aggregates + metadata. No item text. | ops-only | Stricter on the `reasoning` field even though audience is internal: must not leak any field not in the allow-list. |
| `suspicious_user` (v2) | `business_name`, IP, payment-failure metadata, signup→first-invoice delta, anomaly flags | None automatic — but **explicit legal review required** before first call; IP-handling and anomaly-flag content may push the analysis past the existing sub-processor disclosure scope. | ops-only (legal-adjacent) | Most likely to require an addendum to the DPA / sub-processor list. Brief legal early. |
| future analyses | TBD per design doc | TBD | TBD | New row + legal sign-off before any production traffic. |

**Default disposition:** anything not in an analysis's row is *not allowed* on the wire for that analysis. There is no implicit allow-list; the payload builder must enforce this.

**Verification (Phase D):** for FSM-fit, the pre-launch PII check and a redactor sanity-check on a representative payload are the gates — sample rows must show no raw client names, addresses, phones, or emails (only the derived `distinct_addresses` count + `b2b_clients_present` boolean), no unredacted notes, and Presidio markers visible on item-name strings that originally contained PII. For each v2 analysis, the same gates apply at its own pre-launch review.

**Sub-processor scope.** Brief legal **once** with the full intended catalog above (not just FSM-fit) so the Anthropic sub-processor disclosure covers the strictest case (`suspicious_user`) from the start. Re-disclosing per analysis multiplies legal review cost without much benefit.

## 4. Our obligations to users (legal layer 2 — us ↔ our users)

The LLM-provider DPA covers the **us ↔ provider** axis. There is a second axis: **us ↔ our users**, who haven't been told yet that we're going to analyze their data with AI.

**Required regardless of how the feature is surfaced:**

- **Privacy policy update** — GDPR Art. 13/14 + CCPA require disclosure of the AI feature, its purpose, and the LLM sub-processor (with link to their privacy policy).
- **Sub-processor list update + customer notice** — if our customer DPA publishes a sub-processor list (most B2B DPAs do), Anthropic / Bedrock / whoever must be added with the standard advance-notice window (often 30 days) and right to object. **Disclose the catalog scope, not just FSM-fit** — see § 3a; v2 analyses (`churn_risk`, `suspicious_user`) shouldn't require a second notice cycle.
- **Customer DPA flowdown** — our existing DPA with B2B users says we'll only use sub-processors meeting equivalent standards. The LLM's DPA + ZDR + EU-residency posture must satisfy what we already promised our customers — not just the direct GDPR baseline.
- **Legitimate Interest Assessment (LIA)** — internal document recording why legitimate interest is the lawful basis (Art. 6(1)(f)), and that we balance-tested it. Required if we don't take consent.

**Required additionally if the feature is user-facing** (users see the AI output, or it triggers actions affecting them):

- **GDPR Art. 22 review** — if AI output drives decisions with "legal or similarly significant effect" on the user (auto-cancel, gating, pricing), we need explicit consent, human-review right, and contest mechanism. Internal-only scoring usually falls below this threshold.
- **EU AI Act transparency (Art. 50)** — users must be told when they're interacting with AI / receiving AI-generated content.
- **Per-tenant opt-out** — strongly recommended even when not strictly required; reduces regulator-attention risk.

**Not required:** per-individual consent for analytics over contract data (legitimate interest covers it), re-signing existing customer contracts (existing DPA's sub-processor clause covers it).

**Path of least resistance for v1:** ship as **internal-only** (sales / CS see scores, users don't) — needs only the four "regardless" items above. User-facing exposure adds the three "additionally" items and meaningfully more legal/privacy review work. Privacy/legal owner sign-off is a precondition before any rollout regardless of which path.

## Sources

- [Microsoft Presidio](https://github.com/microsoft/presidio) — the chosen redaction library for invoice item text.
- [GDPR Art. 28](https://gdpr-info.eu/art-28-gdpr/) — DPA / processor obligations (the legal floor).
- [Azure OpenAI — Data, privacy, security](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/data-privacy) — the canonical "no-train + EU residency" reference; matched by Anthropic / Vertex / Bedrock equivalents.
