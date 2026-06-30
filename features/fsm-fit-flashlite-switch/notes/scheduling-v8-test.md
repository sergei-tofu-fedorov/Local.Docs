# scheduling re-test: v7 (narrow "multi-visit") → v8 ("would benefit from a visit calendar")

The product meaning of `scheduling` = **the account would benefit from the app's VISIT CALENDAR** (booking /
coordinating visits & appointments), confirmed by the scorer's `Scheduling && OnSiteWork → ScheduleVisits` offer.
The v7 prompt defined it narrowly ("single visit ≠ scheduling; needs multi-stage/multi-visit"). We rewrote ONLY the
scheduling section (→ `prompt_v8.txt`) and re-ran all three arms on the SAME 236 / no-notes input.

## Result — the earlier "flash-lite over-flags scheduling" was an artifact of the wrong definition

`scheduling=TRUE` rate, and accuracy vs the claude reference (re-judged under the same v8 definition):

| arm | TRUE-rate v7 | TRUE-rate v8 | acc vs claude-v8 | error direction (v8) |
|---|---|---|---|---|
| **claude** (reference) | 14% | **90%** | — | — |
| **flash-lite** | 33% | **88%** | **90%** | over 9 / under 14 |
| **nano** | 31% | **50%** | **56%** | over 4 / **under 100** |

**Flip:** under the correct definition flash-lite is the **best** arm on scheduling (90%, tracks the calendar
intent), and **nano is the worst (56%) — it under-flags 100 real visit-calendar businesses**. nano stays literal
even when handed the v8 prompt; flash-lite adopts the broader intent immediately.

- The 86 "nano=FALSE, flash=claude=TRUE" cases are obvious field trades that clearly need a visit calendar:
  carpet cleaning (37 visits), appliance-repair installs, on-site IT setup, electrical labour/material, flooring
  installs. nano wrongly calls these `scheduling=false`.
- flash-lite's residual 9 over-flags are all retail/product/fixed-location edge cases (appliance retail, parts
  resale, license rental, an auto-repair shop) — minor and its known "infers service" lean.

**So:** (1) the scheduling "weakness" of flash-lite was a definition mismatch, not a model flaw — drop it from the
flash-lite-improvement list. (2) Adopting the calendar definition is the right fix, and **flash-lite realises it far
better than nano**. (3) nano would need more than the prompt to follow the broad intent (it resists it).

## Caveats
- "Accuracy" here is concordance to the claude re-judge (broad: 90% TRUE), itself slightly over-eager on name-only
  field-trade accounts (inferred from business_name). The Argilla human pass settles the residual edge; but the
  separation flash 90% vs nano 56% is far larger than that noise.
- labour_billing / contract_based_billing are UNaffected — flash-lite's biases there stand; keep them in the
  Argilla focus set.

## Proposed prod prompt change (FsmFitPrompt.cs) — pending approval (bumps PromptVersion 7→8, re-judges all prod)

Replace the `scheduling` bullet and the address hard-rule (exact text in `prompt_v8.txt` / `build_prompt_v8.py`):
- scheduling = "would the business benefit from a VISIT CALENDAR — visits/appointments booked & coordinated in
  time"; TRUE for visit/appointment-based field work even at one visit per customer; FALSE only for non-visit
  (product/walk-in/digital/one-continuous-project).
- address hard-rule: an address-style item now ALSO supports scheduling=true for visit-based field work.

Artifacts: `prompt_v8.txt`, `nano_v{7,8}_results.json`, `flashlite_v8_results.json`, `batches/batch_*_sched.json`
(claude v8), `compare_scheduling.py` / `compare_scheduling.json`.
