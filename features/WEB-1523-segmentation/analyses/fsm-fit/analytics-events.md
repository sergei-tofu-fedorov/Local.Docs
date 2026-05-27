# WEB-1523 — Analytics events (FSM-fit proposal surface)

> **Why this exists.** The forward A/B design in [`forward-ab.md`](forward-ab.md) requires the BFF to emit a fixed event set so PM can pick the primary metric from a concrete menu instead of inventing it. This doc is the engineering pre-commit — what fires, when, with what properties. Locked.

Stage-1 (BigQuery writes only) ships without these events. Stage-2 (BFF proposal surface) wires them in. Schema is locked here so PM's decision in `forward-ab.md` can be made before stage-2 starts.

## Event set

### `fsm_fit.cohort_assigned`

Fires the first time the BFF evaluates a user against the experiment, per [`forward-ab.md`](forward-ab.md) § Cohort. Recovers the denominator for any metric (control users never fire `proposal_shown`, so without this event the control arm is invisible).

| Property | Type | Notes |
|---|---|---|
| `account_id` | string | |
| `cohort` | string | `treatment` or `control` |
| `experiment_id` | string | `fsm_fit_rollout_v1` until PM declares the rollout over |
| `assigned_at` | timestamp | |

### `fsm_fit.proposal_shown`

Fires when the BFF renders the proposal surface to a `treatment`-cohort user with `tier ∈ {strong, weak}`. Fires once per surface render — dedupe at the warehouse.

| Property | Type | Notes |
|---|---|---|
| `account_id` | string | |
| `analysis_type` | string | always `"fsm_fit"` for v1 |
| `tier` | string | `strong` / `weak` from `v_fsm_fit` (typed column, materialised at write) |
| `recommended_offer` | string | first offer from the `recommended_offers ARRAY<STRUCT<offer,weight>>` column on `account_fsm_fit` — drives copy variant (see [`copy.md`](copy.md)) |
| `analyzed_at` | timestamp | from `account_fsm_fit.analyzed_at` — joins back to the source row |
| `prompt_version` | int64 | provenance |
| `rule_version` | string | provenance |
| `surface` | string | `dashboard_card` / `banner` / `inbox` — locked by misha § 1 once PM picks |
| `fired_at` | timestamp | client-side; server timestamp added by the analytics gateway |

### `fsm_fit.proposal_clicked`

Fires when the user activates the proposal CTA. Same property bag as `proposal_shown`.

### `fsm_fit.proposal_dismissed`

Fires when the user explicitly dismisses. Same property bag + optional `dismiss_reason` (only present if surface UI offers reasons).

### `fsm_trial_started`

Fires from the existing subscription / plan flow when the user enters an FSM-product trial. Attribution to FSM-fit is joined at the warehouse — see § Attribution. **Not** emitted by the BFF proposal surface; emitted by whichever code already owns the trial-start event.

| Property | Type | Notes |
|---|---|---|
| `account_id` | string | |
| `plan_id` | string | `FsmSolo` / `FsmTeam` / `FsmBusiness` |
| `started_at` | timestamp | |
| `entry_path` | string | `fsm_fit_proposal` / `direct` / `marketing_link` / `other` — soft attribution hint from the BFF when detectable |

## Cohort assignment

Deterministic per `account_id`:

```
hash(account_id || cohort_seed) mod 100 < HOLDOUT_PCT → control
otherwise                                              → treatment
```

`HOLDOUT_PCT` and `cohort_seed` are configured server-side per [`forward-ab.md`](forward-ab.md). Assignment is **stable for the experiment's lifetime** — the same account stays in the same arm across re-scores and re-renders.

**Control cohort behaviour.** The BFF computes cohort on every proposal-surface request; control users receive a no-op response and **no** `proposal_shown` event fires. The `cohort_assigned` event captures the denominator regardless of arm.

## Attribution

`fsm_trial_started` is attributed to FSM-fit when **both** hold:

1. There exists a `fsm_fit.proposal_shown` event for the same `account_id` with `fired_at ∈ [fsm_trial_started.started_at − OBSERVATION_WINDOW, fsm_trial_started.started_at]`.
2. The user is in the `treatment` cohort.

`OBSERVATION_WINDOW` is configured per [`forward-ab.md`](forward-ab.md) (engineering default: 30 days).

`entry_path = "fsm_fit_proposal"` is a soft override — if the BFF can detect the trial flow was entered via the proposal CTA, it sets this flag and the warehouse trusts it over the time-window join.

## Joining back to source

Every event carries `analyzed_at` so the warehouse can join to the `account_fsm_fit` row that produced the verdict via `(account_id, analyzed_at)`. This lets retrospective analyses ask "did proposals driven by `prompt_version = 6` convert better than `prompt_version = 5`?" without a second source-of-truth.

## What's not emitted

- **No** `proposal_impression_blocked` (surface suppressed because the user already dismissed) — the absence of `proposal_shown` for an eligible `cohort_assigned` user is itself the signal.
- **No PII** in any property. `account_id` is the only identity reference; `business_name`, contact info, item text never leave the BFF in an event property.

## Status

**Locked — engineering pre-commit.** Stage-1 ships without these events (no BFF surface yet). Stage-2 wires them into the BFF proposal-surface code; the implementation task will be tracked in ClickUp when stage-2 tickets are created. PM's decisions in [`forward-ab.md`](forward-ab.md) reference this fixed menu.
