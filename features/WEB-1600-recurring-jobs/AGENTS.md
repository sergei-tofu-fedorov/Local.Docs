# WEB-1600 — Recurring Jobs

Design docs for the recurring-jobs feature (a manager sets up recurring client service → visits are generated and a draft invoice is produced per billing period).

## Contents

| Doc | What it covers |
|---|---|
| [`option-b-bill-on-agreement.md`](option-b-bill-on-agreement.md) | The ServiceTitan-style **"bill on the agreement"** design — a first-class `ServiceAgreement` owns recurrence **and** invoices (1:N, one per period), Jobs/Visits become pure scheduling, the period-Job is eliminated. Includes the A-vs-B trade-off table and the billing-semantics (period billing) note. |

## Note on the baseline plan

The original **Option A** plan (`overview.md`, period-Job model) lives in the **`Invoices.Backend`** repo under `Docs/features/WEB-1600-recurring-jobs/` on branch `feature/WEB-1600_recurring-jobs` — **not** in Local.Docs. The doc here is the agreement-billing alternative, written as deltas against it.
