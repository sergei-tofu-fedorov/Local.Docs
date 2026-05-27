# FSM-fit — industry enum expansion

> **Status:** PROPOSAL — pending PM/eng review. First-pass clustering complete (`industry-expansion/llm-proposal.json`, 2026-05-20); the Candidates table below is populated and the open questions are the live decision surface.

## Decision

_PROPOSAL — pending PM/eng review of the Candidates table._

First-pass outcome (`industry-expansion/llm-proposal.json`, 2026-05-20):

- **21 candidate clusters** identified at threshold `count ≥ 5`, covering **791 accounts** — moves the enum from 24 → up to 45 ids if all are accepted.
- **16 of 21 clusters proposed as FSM-suited (`yes`)** — would grow the bonus list from 7 ids to 23. **Likely requires a bonus-rate retune** (drop +0.15 → +0.10 or +0.08) to avoid further inflating the `strong` rate beyond the 51%+ Misha already flagged in [`scoring.md`](scoring.md) § Rule.
- **5 clusters flagged `borderline`** (auto_body_repair, auto_repair, event_catering, welding_fabrication, + property_management's adjacent ambiguity) — PM call on whether they ship with or without bonus.
- **Coverage caveat:** the proposal moves ~14% of `strong+other` accounts into named ids. The remaining ~85% live below threshold and don't get an enum upgrade from this pass alone.

Default direction (subject to revision):

- Extend the FSM-fit `industry` emit-schema enum from the current **24 ids** to ~30–40 ids, naming the dominant patterns that today land in `other`.
- The full list lands as a single prompt-version bump (`v6-industry-scheduling` → `v7-industry-expansion`) plus a corresponding rule-config update (which new ids get the FSM-suited bonus, and at what rate).
- No BigQuery DDL — `industry` is a free STRING column on `account_fsm_fit`; only the strict-outputs schema in [`prompt.md`](prompt.md) needs the new ids.

## Goal

Reduce the `industry = "other"` bucket — currently **53%** of all v3 emits — by naming the patterns that already cluster strongly inside it, so FSM-fit dashboards, the +0.15 industry bonus, and downstream proposal-copy can key off a more meaningful industry signal.

The bonus mechanic is the load-bearing part: today, every `strong+other` account is denied the +0.15 even when its specialization clearly belongs to an FSM-suited trade. Naming those clusters lets the bonus rule see them.

## Cohort

Filter applied to [`../../prototype/v3/results.jsonl`](../../prototype/v3/results.jsonl):

```
prompt_version == "v3-with-backend"
tier           == "strong"
industry       == "other"
```

| Slice | Count |
|---|---:|
| v3 rows total | 46,235 |
| v3 `industry = other` | 24,438 (53%) |
| v3 `tier = strong` | 26,619 |
| **v3 `strong ∩ other`** (target cohort) | **6,231** |
| ↳ with non-empty `specialization` | 5,544 |
| ↳ empty `specialization` | 534 |
| ↳ literal `"unspecified"` | 153 |
| Unique `specialization` strings in the cohort | 4,362 |

**The long tail dominates.** At threshold `count ≥ 5`, only **74 specs survive**, covering **814 accounts (14.7%)** of the 5,544-account non-empty-spec cohort. The remaining 85% live in specs that appear 1–4 times — too sparse to defend their own enum id from this data alone. This is the most important finding of this pass: industry expansion at threshold `≥ 5` is a partial fix, not a comprehensive one. To dent the residual `other` further, the next move is either (a) a prompt-side change pushing the LLM toward broader categorisation upfront, or (b) a lower threshold with manual review of the long tail.

## Method — long-tail truncation + LLM clustering

### Step 1 — input artifact

Produce `industry-expansion/strong-other-specs.tsv` containing one row per `specialization` that appears in the cohort with `count ≥ 5`. Columns:

| count | specialization | example_business_names | example_top_items |
|---:|---|---|---|

- `count` — number of accounts in the cohort emitting that exact `specialization` string.
- `example_business_names` — up to 5 distinct `business_name` values for accounts emitting that spec.
- `example_top_items` — up to 5 representative item-name strings from those accounts' Presidio-redacted top items (helps the clustering call disambiguate ambiguous specs like `"installation and repair"`).

**Threshold rationale.** `count ≥ 5` is the working default — yields ~150–300 surviving specs, which fits in one `gpt-4.1-nano` call with room for the response. Alternative `count ≥ 10` (~60–100 specs) would be tighter but risks dropping legitimate sub-trades. **PM/eng pick before the run.**

Specs with `count < 5` are not lost — they stay in the residual `other` bucket. Anything that doesn't make `count ≥ 5` is by definition too small to justify its own enum id today.

### Step 2 — clustering call

Single LLM call (`gpt-4.1-nano`, strict structured outputs). System prompt asks the model to:

1. Group the input specs into ≤ 15 clusters by **business pattern**, not by surface wording. (`Garage door installation and repair` and `Garage door repair and installation` belong to the same cluster.)
2. For each cluster, emit:
   - `proposed_id` — `snake_case`, ≤ 32 chars, aligned with existing enum naming (`auto_services`, not `automotive`).
   - `member_specs` — verbatim specs that fold into the cluster.
   - `account_count` — sum of `count` across member specs.
   - `example_business_names` — up to 5, copied from the input.
   - `fsm_suited` — `true | false | borderline`, with one-line justification keyed to FSM-fit signals (on-site work? labour billing? scheduling? recurring billing? multi-address?). This is a **recommendation**, not a decision — PM has final call on the bonus list.
   - `rationale` — ≤ 200 chars.
3. Emit a residual `unclustered` array — specs that don't fold into any cluster.

Output saved verbatim as `industry-expansion/llm-proposal.json` for reproducibility.

### Step 3 — review & decide

- Eng folds the proposal into a table in § "Candidates" below.
- PM picks which clusters become real enum ids vs. stay folded into `other`, and which of those carry the +0.15 bonus.
- The locked list lands in [`scoring.md`](scoring.md) § Emit schema and § FSM-suited industry bonus, plus the strict-outputs schema in [`prompt.md`](prompt.md).

### What this method does **not** do

- No embedding-based clustering. The dataset is small enough that a single LLM pass handles it; embeddings add complexity without a clear win at this size.
- No re-classification of existing `strong+other` rows in BigQuery. Re-scoring requires a fresh sweep with the new prompt — that's a downstream ticket.
- No automatic merger of new ids into existing ids (e.g., should `solar` collapse into `electrical`?). The model proposes; humans decide.

## Candidates

First-pass clustering output. Raw model JSON at [`industry-expansion/llm-proposal.json`](industry-expansion/llm-proposal.json) (`model: claude-opus-4-7`, threshold `≥ 5`, 74 specs in, 21 clusters out, 791 accounts promoted out of `other` — 33 accounts stay above threshold but unclustered).

**Final id naming, granularity, and bonus eligibility are eng/PM calls — the table is a starting point, not a decision.**

| Proposed id | Acc. | Example specs (top 3 by count) | Example business names (3) | LLM `fsm_suited` | Eng/PM decision |
|---|---:|---|---|---|---|
| `auto_body_repair` | 73 | `auto body repair and painting`, `auto body repair and collision repair`, `auto body repair and paint` | A-1 Auto Body, Jorges Auto Body And Paint, Mauricios Collision Repair | borderline | _TBD_ |
| `auto_repair` | 32 | `auto repair and maintenance`, `auto repair and diagnostics`, `auto repair and tire services` | Automatic Car Service, Prairie Grove Automotive, BryMobile Tires | borderline | _TBD_ |
| `auto_detailing` | 75 | `auto detailing`, `auto detailing and paint correction`, `auto detailing and car cleaning` | Kings Detailing, DVO Detailing, Refine Detailing | yes | _TBD_ |
| `auto_glass` | 12 | `auto glass repair and replacement` | AJ Windshield Repair, Cruz Auto Glass, Scissortail Auto Glass | yes | _TBD_ |
| `towing_roadside` | 58 | `towing and roadside assistance`, `vehicle towing and roadside assistance`, `towing services` | Epic Towing LLC, Kingdom Towing, AMJ TOWING | yes | _TBD_ |
| `event_decoration` | 174 | `Event decoration and setup`, `Event decoration and planning`, `Event decoration and balloon art` | A Touch Of Love, Balloons Galore and Decor, Emalya Events | yes | _TBD_ |
| `event_rental` | 57 | `Event equipment rental and setup`, `event equipment rental and setup`, `Party rental equipment and event setup` | Djmppartyrental, Savage Events, Dorado Party Rentals | yes | _TBD_ |
| `event_catering` | 33 | `Catering and event food service`, `Catering and event food services`, `Catering and event services` | Canapes Haven Catering, Hermanas Catering, Chef Annes 5 Star Catering Services | borderline | _TBD_ |
| `garage_door` | 70 | `Garage door repair and installation`, `Garage door installation and repair` | All Seasons Garage Door Service, Okie Overhead Door, South Valley Garage Doors | yes | _TBD_ |
| `moving_relocation` | 42 | `Moving and relocation services`, `Moving services`, `Moving and delivery services` | Always In Motion LLC, City Crown Transport Pty Ltd, Apollos Moving | yes | _TBD_ |
| `windows_doors` | 23 | `window and door installation and repair`, `Window and door installation and repair` | Esteban Windows And doors Inc., JS Windows and Doors LLC, Warrior Windows & Doors | yes | _TBD_ |
| `drywall` | 24 | `Drywall installation and repair`, `Drywall installation and finishing`, `drywall installation and finishing` | DJ's Drywall LLC, Bbc Drywall Llc, CLRDRYWALL.LLC | yes | _TBD_ |
| `gutters` | 14 | `Gutter installation and repair`, `Gutter installation and maintenance` | B&B GUTTERS LLC, Pitch Perfect Seamless Gutters, Valley Rain Gutters | yes | _TBD_ |
| `fence` | 13 | `Fence installation and repair` | Classic Fence Company LLC, Empire State Fence LLC, Prestige Fence Company | yes | _TBD_ |
| `solar` | 16 | `solar energy system installation and components` | ABD Abdulhadi Trading, J&T SOLAR ENERGY, JAVID SOLAR ENERGY | yes | _TBD_ |
| `pressure_washing` | 14 | `pressure washing and exterior cleaning` | Diamond Pressure Powerwash, Pacific Pressure Pros, Riggs Pressure Washing Solutions | yes | _TBD_ |
| `pet_services` | 12 | `Dog walking and pet sitting services` | Biscuit Tin Adventures, Caring Cats & Canines, Kelly K9 | yes | _TBD_ |
| `countertops` | 8 | `countertop fabrication and installation` | D'Amico Stone Design LLC, Jano's Countertops Llc, Platinum Stones LLC | yes | _TBD_ |
| `welding_fabrication` | 19 | `metal fabrication and welding`, `welding and fabrication`, `welding and metal fabrication` | Precsion Fabrications, DENOVAN WELDING INC., Red River Welding & Fabrication | borderline | _TBD_ |
| `glass_install` | 7 | `Glass installation and repair` | ACE GLASS WORKS, Infinity Glass, Master Pro Glass & Mirror LLC | yes | _TBD_ |
| `property_management` | 5 | `property management and maintenance` | A.D.S Properties CC, All County First Property Management, Rex Estates Management LTD | yes | _TBD_ |

### Cluster-level notes worth raising in review

- **Auto group (4 ids, 192 accounts):** proposed as four separate ids so the +0.15 bonus rule can rate them differently. PM may prefer a single `auto_services` umbrella if dashboards / offer-routing don't need the granularity — the trade-off is bonus precision vs. enum size.
- **Event group (3 ids, 264 accounts):** `event_decoration` alone is the **single largest new cluster** in the proposal. Splitting décor / rental / catering matches their different FSM-fit profiles (catering is the most equivocal — see `fsm_suited: borderline`).
- **Existing-enum overlap candidates:** `drywall` and `gutters` sit naturally next to existing `painting` / `roofing`. `solar` could plausibly fold into `electrical`. `fence` could fold into a hypothetical `exterior_install` umbrella with `gutters` + `windows_doors`. None of these collapses change cost; all change bonus precision.
- **Bonus list growth:** if all 16 LLM-`yes` clusters become bonus-eligible, the bonus list grows from 7 ids to 23. The 51%+ `strong` rate Misha already flagged in [`scoring.md`](scoring.md) § Rule ("Validation aftermath") will rise further — likely requires a **bonus-rate retune** (drop +0.15 → +0.10 or +0.08) before this lands. Track in `scoring.md` § Open #4.

## Residual `other`

**Above threshold, unclustered (33 accounts, 6 specs).** Reasoning attached.

| Spec | Count | Reason to keep in `other` |
|---|---:|---|
| `transportation and logistics` | 7 | Freight/courier — not customer-facing FSM. |
| `vehicle rental and transportation services` | 6 | Rental fleet — not FSM. |
| `transportation and logistics services` | 5 | Same as freight/courier. |
| `transportation/logistics` | 5 | Same as freight/courier. |
| `Car audio installation and customization` | 5 | Mostly in-shop custom install — borderline FSM, too small alone to justify its own id. |
| `event videography and photography` | 5 | Creative service — not classic FSM scheduling/labour pattern. |

**Below threshold (4,730 accounts in 4,286 distinct specs).** Long-tail singletons / pairs / triples. Not promoted today. Worth a follow-up pass if PM wants to push `other` below ~20% of the cohort — that pass would need either (a) a prompt-level change to encourage broader categorisation upstream, or (b) hand-curation, since the data alone doesn't justify enum entries below `count ≥ 5`.

**Empty / `unspecified` specs (687 accounts).** No signal to cluster on. Stay in `other` until a prompt-side fix raises emit quality on these rows.

## Downstream impact

| Layer | Change |
|---|---|
| **[`prompt.md`](prompt.md)** § Emit schema | Add the new enum ids to the `industry` enum in the strict-outputs schema. Prompt-version bumps (current `v6-industry-scheduling` → `v7-industry-expansion`). |
| **[`scoring.md`](scoring.md)** § Emit schema | Update the "24-ID enum" line to the new count + list. |
| **[`scoring.md`](scoring.md)** § FSM-suited industry bonus | Add new bonus-eligible ids to the 7-id list. Re-state the bonus rate (`+0.15`) — no change. |
| **BigQuery `account_fsm_fit`** | **No DDL.** `industry` is `STRING`; the new values flow through transparently. |
| **Re-scoring** | Existing rows in `account_fsm_fit` keep their old `other` label until re-analysed. Plan a one-shot re-sweep over the `strong+other` cohort (~6.2k accounts × ~$0.0002 ≈ **$1.30**) under the new prompt — cheap enough not to need a budget gate. |
| **Dashboards** (stage-2, unbuilt — no `dashboards.md` yet) | `industry` breakdown chart picks up the new ids automatically — no schema update. Tier-distribution-by-industry becomes more informative once `other` shrinks. |

## Open questions

- [x] ~~**Threshold.** `count ≥ 5` (default, ~150–300 specs) vs. `count ≥ 10` (tighter, ~60–100 specs).~~ — **Resolved (2026-05-20):** ran at threshold `≥ 5`. The actual surviving-spec count was **74** (much smaller than the pre-run estimate of 150–300, because the long tail is heavier than expected — see § Cohort). Whether to re-run at `≥ 3` to widen coverage is now a follow-up decision, captured below.
- [ ] **Bonus eligibility + rate retune.** 16 of 21 proposed clusters carry LLM `fsm_suited: yes`; adopting all of them would more than triple the bonus list. Combined with Misha's already-open question on the +0.15 rate, this likely needs a coupled decision: pick the new bonus ids **and** the new bonus rate together, so the `strong` distribution post-rollout is predictable. Eng/PM to decide.
- [ ] **Merge vs. split.** Concrete calls to make:
  - Auto group → 4 separate ids (`auto_body_repair`, `auto_repair`, `auto_detailing`, `auto_glass`) vs. one umbrella `auto_services`? Trade-off: bonus precision vs. enum size.
  - Event group → 3 ids (`event_decoration`, `event_rental`, `event_catering`) vs. one `event_services`? Catering has a different FSM profile; lean toward splitting.
  - Collapse candidates: `solar` → `electrical`; `drywall`/`gutters`/`fence`/`windows_doors` → new `exterior_install` umbrella? Final call sits with PM.
- [ ] **Long-tail coverage.** Threshold `≥ 5` leaves 4,730 cohort accounts (~85%) below the bar. Options to push that down: (a) re-run clustering at threshold `≥ 3` (would surface ~150 more specs but adds noise); (b) prompt-side change asking the LLM for broader categorisation upfront; (c) accept the ~14% coverage as a v1 win and revisit after the bonus retune. **PM to pick** before the prompt-version bump.
- [ ] **Prompt-cost regression.** A longer `industry` enum slightly increases prompt tokens (each new id is a few tokens in the JSON schema declaration). Estimated impact: < 1% on the current ~1,400-tok prompt. Worth re-measuring after the prompt-version bump.
- [ ] **Cross-analysis applicability.** If future analyses (`churn_risk`, `suspicious_user`) want their own `industry` field, do they reuse this FSM-fit enum, or define their own? Out of scope for this doc — capture in the framework-level [`../scoring.md`](../scoring.md) when v2 analyses land.

## Companion artifacts

| File | Purpose |
|---|---|
| [`industry-expansion/strong-other-specs.tsv`](industry-expansion/strong-other-specs.tsv) | Input to the clustering call — 74 specs with `count ≥ 5` plus their `business_name` + `top_items` exemplars. |
| [`industry-expansion/llm-proposal.json`](industry-expansion/llm-proposal.json) | Raw output of the clustering call (`model: claude-opus-4-7`, 2026-05-20). 21 clusters + unclustered residuals. |
| [`industry-expansion/extract-cohort.py`](industry-expansion/extract-cohort.py) | Reproducible extractor — reads `prototype/v3/results.jsonl` + `prototype/v3/accounts/*.json`, emits the TSV. |
