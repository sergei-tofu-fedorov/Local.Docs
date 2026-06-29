# 3A industry classification quality — leak investigation & prompt A/B

Follow-up to [top-items-3a-industries.md](./top-items-3a-industries.md). Question raised: the
`landscaping` bucket looks full of lawn-care items (`lawn service`, `mowing`, `weekly maintenance`)
— are lawn-care accounts leaking into `landscaping` (and lawn/cleanup into `cleaning`), and can a
prompt tweak fix it?

- **Date:** 2026-06-26
- **Classifier:** `gpt-4.1-nano`, temperature 0, strict json_schema (prod `OpenAiFsmFitClient`)
- **Prompt:** `FsmFitPrompt.cs` PromptVersion 7
- **Data:** `inv-project.ai_analysis_us` (`account_metrics`, `account_fsm_fit`, `invoice_line_items`)

## Step 1 — keyword-regex leak estimate (later shown to be inflated)

Tagging items by regex (lawn-words vs design/install-words vs clean-words):

- `cleaning` (4,452 acct): 637 (14%) with any lawn item, 78 (1.8%) lawn-dominant, 17 lawn-majority.
- `landscaping` (3,076 acct): 1,229 (40%) lawn-dominant, 374 (12%) lawn-majority, **679 (22%) with
  zero design/install item**.

These numbers **overstate** the real error — see Step 3.

## Step 2 — prompt A/B (positive rewrite vs current)

Per web best practice ([OpenAI GPT-4.1 guide](https://developers.openai.com/cookbook/examples/gpt4-1_prompting_guide),
[LaunchDarkly](https://launchdarkly.com/blog/prompt-engineering-best-practices/)): stacking hard
"NOT X" rules is an anti-pattern (literal-following models get last-rule-wins conflicts; negation
raises error rate). So the candidate edit was **positive**: replace the weak lawn/landscaping
disambiguation line with positive INDUSTRY BOUNDARIES definitions + contrastive few-shot examples.

39 accounts, 4 groups, **one account per LLM call** (no batching — batching cross-contaminates on
nano), old prompt and new prompt as two independent calls each.

| Group | n | old correct | new correct | flips |
|---|---|---|---|---|
| A: `landscaping`, regex-tagged lawn | 15 | 2 | 3 | 2 |
| B: `cleaning`, regex-tagged lawn | 8 | 0 | 0 | 0 |
| C: control — genuine `landscaping` | 8 | 8 | **7** | 1 (regression) |
| D: control — genuine `cleaning` | 8 | 7 | 7 | 0 |

**The new prompt does not help.** Net ≈ 0: +1 true flip in A (`Jehiah's Landscapes`, items = only
"Yard work" → lawn_care_maintenance), 0 in B, and a **control regression** in C — real landscaping
`Sod Installation | Zero Scape | Black Dye mulch | Stump grinder | Tree Trimming` wrongly moved to
lawn_care. nano anchors hard on the word "landscaping"/"maintenance"; a disambiguation-section edit
does not override it.

## Step 3 — the "leak" is mostly a regex artifact

Inspecting the actual items of the "misclassified" accounts, the model is usually right or the case
is genuinely ambiguous:

- **Group A** (regex said lawn, but really landscaping/mixed): `Fence & Exterior Restoration`;
  `Carpentry | Tree Work | Haul Off`; `artificial trees | topiary`; `Boulder Removal | Pathway
  Restoration`; `Top soil | Aeration | Plants | Rock`.
- **Group B** is not about lawn at all: `music school | Hotel Marriot | Wayfair` (commercial
  cleaning → other), `Church-Janitorial | School Cleaning`, `Exterior and Flybridge weekly` (boat
  wash → other). They fell into the "lawn" bucket only because the regex counted the generic word
  **`maintenance`** as a lawn signal.

So the earlier "40% / 22% leak" figures are an artifact of keyword tagging, not the real error rate.

## Step 4 — human adjudication (Argilla) settles it

65 contested 3A accounts hand-labelled in Argilla dataset `fsm-fit-3a-contested` (2026-06-26).
nano label vs human truth:

**nano accuracy on the contested set = 59/65 = 90.8%** (and these are the *hardest* boundary cases;
population accuracy is higher).

| Contested group | n | nano correct | corrected |
|---|---|---|---|
| `cleaning_has_lawn` | 20 | **20** | 0 |
| `landscaping_has_lawn` | 30 | **28** | 2 |
| `lawn_has_design` | 15 | 11 | 4 |

All 6 real errors are themselves borderline:
- `landscaping → lawn_care` (2): K&D Property Maint, Emerald landscaping.
- `lawn_care → landscaping` (3): Yard Work By M.E., Payne Land Management, Biven Grounds Crew (all "mowing + landscaping/maintenance").
- `lawn_care → cleaning` (1): Matt's Home Services (snow/lawn/cleanup — the human call is itself debatable).

Errors are **symmetric** (lawn→landscaping 3 vs landscaping→lawn 2) — boundary noise, not a one-way leak.

## Conclusion

1. **No leak to cleaning** — 20/20 cleaning accounts confirmed; the "cleaning leak" was 100% a regex
   artifact (`maintenance`/`cleanup` keywords).
2. **No material leak to landscaping** — 28/30 confirmed; the earlier "40% / 22%" figures were
   keyword-tagging artifacts, not real errors.
3. **Remaining disagreements are symmetric, few, and genuinely ambiguous.** nano is ~91% even on the
   worst boundary cases.
4. **Do not tune the prompt for this.** The positive rewrite gave net-zero with a control regression
   (Step 2), and the real error rate is already low and not systematic. Effort is better spent
   elsewhere.

Repro for this step: `load_3a_contested.py` (loads the sample) + `export_3a_contested.py` (pulls
adjudications → `gold_3a.jsonl` / `_stats_3a.json`). Argilla local server at `C:\Git\_scratch\argilla`.

## Step 5 — "strong business_name" A/B (also net-zero)

Hypothesis: business_name should carry more weight (the prompt currently calls it a "weak hint" and
says to trust line items on conflict). A/B vs the 65 hand-labelled gold, one account per call,
NEW = OLD with business_name promoted to a STRONG signal (tie-breaker when items are generic/split;
items still override only when they describe clearly different work).

**Result: OLD 53/65 vs NEW 53/65 — exactly zero net change, 3 flips:**
- FIX (+1): `Jehiah's Landscapes`, item = only "Yard work" → name pushed lawn_care → landscaping.
- REGRESS (−1): `Jajuan Morris` (name has NO industry word) → mowing-heavy went lawn_care → landscaping.
- neutral: `1342580 B.C. LTD.` (numeric name) other → locksmith (both wrong).

The one fix needs the name to literally contain the vertical word; the regression fired on a name
with no industry word at all — i.e. the edit mostly perturbs nano rather than systematically using
the name. Same +1/−1 net-zero pattern as the positive rewrite (Step 2). **Do not reweight
business_name.**

Caveat: this live OLD run scores 53/65 (81.5%) vs the 59/65 (91%) of the stored prod label in Step 4,
because the live re-run is non-deterministic and omits `top_notes` (PII). The valid signal is the
old↔new delta under identical conditions = 0, not the absolute number. Repro: scratchpad `run_bn.py`.

## Repro

- Sample export SQL + A/B runner: scratchpad (`sample.sql`, `run_ab.py`) — runner extracts the live
  `FsmFitPrompt.SystemPrompt`, builds the positive variant, calls OpenAI per account, writes
  `ab_results.json`. Key from `C:\Files\tofu-ai-api-secret.prod.json` → `Analyses:OpenAi:ApiKeyUs`.
