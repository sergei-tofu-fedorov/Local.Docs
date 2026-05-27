# WEB-1523 — Forward A/B design (FSM-fit rollout)

> **Status: draft, blocks stage-2.** Engineering has pre-committed the event schema at [`analytics-events.md`](analytics-events.md). This document is the experiment design.
>
> Sections marked **`PM TO DECIDE`** are PM input. **Engineering will not start BFF stage-2 surface work until they're filled in.**

## Why a forward A/B is the only path

No historical FSM-conversion data exists — we've never proposed FSM to invoice-only users at scale before. The score's actual lift on the business outcome can only be measured by withholding the proposal from a control cohort and comparing.

## Hypothesis

Users in the `treatment` cohort (shown an FSM-fit proposal when their `tier ∈ {strong, weak}`) convert to an FSM trial at a higher rate than users in the `control` cohort (no proposal shown) within the observation window.

## Primary metric · `PM TO DECIDE`

| Candidate | Numerator (over `cohort_assigned` denominator) | Trade-off |
|---|---|---|
| **proposal-CTR** | `proposal_clicked` count | Lighter signal, fires faster; doesn't measure real product adoption |
| **trial-start within 30d** | `fsm_trial_started` attributed within 30d | Aligned with revenue intent; slower to accumulate |
| **trial-start within 60d** | same, 60d window | Higher signal-to-noise; even slower |
| **FSM-feature usage at 60d** | usage events (not in current scope) | Closest to real adoption; needs additional instrumentation |

**Engineering default:** trial-start within 30d. Aligned with the business goal; the event already exists in the schema; no additional instrumentation needed.

**PM input:**
- [ ] Primary metric: __________
- [ ] Secondary metrics (1-2): __________

## Cohort · `PM TO DECIDE` (size only — assignment locked in `analytics-events.md`)

`HOLDOUT_PCT` — **`PM TO DECIDE`**. Engineering default: **10%** (control 10%, treatment 90%). Small holdout maximises treatment exposure; still gives ~5k control accounts at 50k total — enough power for the MDE table below.

`cohort_seed` — engineering-chosen at experiment start, never rotated.

## Minimum detectable effect · `PM TO DECIDE`

Approximate MDE at 80% power, α = 0.05, 5k control + 45k treatment, by baseline trial-start rate:

| Baseline rate | MDE (absolute) | MDE (relative) |
|---|---:|---:|
| 1% | ±0.4 pp | ±40% |
| 3% | ±0.7 pp | ±23% |
| 5% | ±0.9 pp | ±18% |
| 10% | ±1.3 pp | ±13% |

(Engineering's rough estimates assuming binomial variance; PM to validate the baseline-rate assumption.)

**PM input:**
- [ ] Expected baseline trial-start rate for eligible accounts with no proposal: __________
- [ ] Smallest relative lift that makes shipping worthwhile: __________

If MDE expectations + baseline imply a sample > 50k, options: (a) accept lower power, (b) extend the experiment, (c) sequential analysis. Engineering will flag this if it comes up after PM fills in baseline + lift.

## Observation window · `PM TO DECIDE`

Time between `proposal_shown` and `fsm_trial_started` within which we attribute the trial.

Engineering default: **30 days**.

**PM input:**
- [ ] Confirm 30d or override: __________

## Experiment duration

Engineering estimate: ~6-8 weeks from full launch:

- 2-4 weeks for canary → 100% ramp.
- 4 weeks of observation window for the slowest cohort.
- 1 week buffer for analysis and decision.

**PM input:**
- [ ] Patience confirmation (~6-8 weeks for verdict): __________

## Decision rule

- **Win** — primary metric in treatment is significantly higher than control at α = 0.05 AND absolute lift ≥ MDE → keep the feature, expand the rollout to 100%.
- **No effect** — confidence interval includes zero → keep shipped (treatment had it; rolling back is a separate decision), no further investment.
- **Loss** — primary metric significantly *lower* in treatment → kill-switch immediately, investigate before re-trying.

Secondary metrics tie-break borderline cases. Do not switch primary metrics post-hoc.

## Kill switch

Engineering pre-commits a feature flag at the BFF surface that disables the proposal globally without a code deploy. Cohort assignment continues so the experiment can resume.

**PM-pre-committable kill triggers (`PM TO DECIDE`):**
- [ ] `proposal_dismissed / proposal_shown` exceeds __________% → suggests proposal is annoying.
- [ ] Treatment trial-start rate below control by __________ absolute pp → suggests proposal is actively harmful.
- [ ] PM-judgement override, no specific trigger (always available).

## Dependencies on stage-2 work

This experiment cannot start until the BFF:

1. Emits the five events per [`analytics-events.md`](analytics-events.md).
2. Computes cohort assignment + serves a no-op response to control users.
3. Exposes the kill-switch flag.
4. Has the analytics warehouse confirming events land reliably (verified via a dry-run during stage-2).

All four are stage-2 BFF work — none in stage-1 scope. Stage-1 ships internal-only (BigQuery writes, no user surface, no A/B).

## When this doc is unblocked

PM fills in every `PM TO DECIDE` section. Engineering then:

1. Locks the experiment config (holdout %, observation window, kill thresholds) in BFF code.
2. Files the stage-2 implementation tickets (currently deferred).
3. Begins stage-2 BFF surface work.

Status today: **draft, awaiting PM input.**
