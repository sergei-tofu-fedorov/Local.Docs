# WEB-1523 — Postgres read-isolation options for the eligibility probe

> ❌ **Removed 2026-06-02 — obsolete.** This doc surveyed how `Tofu.AI.Api` could read `Invoices.Backend`'s Postgres `jobs."Jobs"` table off the primary, to back the FSM-fit **eligibility probe** (the FSM-using-account audience filter in `AnalyzeFsmFitJob`). **That job filtering has been removed — we are not using it at this stage** (see [`../implementation/analyze.md`](../implementation/analyze.md) § Audience eligibility). No cross-service Postgres read remains anywhere in the analyses pipeline, so none of the read-isolation options below apply. The content is retained only as historical record; do not action it.

The only remaining audience filter in `AnalyzeFsmFitJob` is the account-maturity gate, which reads the source `accounts` Mongo collection — covered by [`mongo-read-isolation.md`](mongo-read-isolation.md), not this doc. If a future analysis genuinely needs a cross-service Postgres read, reopen this comparison from git history.

## Cross-references

- [`mongo-read-isolation.md`](mongo-read-isolation.md) — the Mongo-side read-isolation decision (still live; covers the only source reads the pipeline performs).
- [`metrics.md`](metrics.md) — broader sourcing-category investigation.
