# WEB-1600 — Recurring Jobs — **Option B: Bill-on-Agreement (ServiceTitan-style)**

> **Purpose:** the ServiceTitan-style ("bill on the agreement") alternative to the WEB-1600 period-Job plan, for side-by-side comparison.
>
> The baseline "Option A" plan is the `overview.md` that lives in the **`Invoices.Backend`** repo under `Docs/features/WEB-1600-recurring-jobs/` (branch `feature/WEB-1600_recurring-jobs`) — not in Local.Docs. This doc only describes the **deltas** against it; the [trade-off table](#option-a-vs-option-b) at the end is the decision aid. Same product surface (manager sets up recurring service → automatic per-period draft invoices), different **billing level**: the recurrence **and the invoices** live on a first-class **`ServiceAgreement`** entity, not on a synthetic per-period `Job`.

## Why this option exists

`overview.md` ("Option A") preserves the existing `Job↔Invoice` 1:1 by minting **one `Job` per billing period** as the invoice carrier. That period-Job is a structure **neither ServiceTitan nor Jobber actually has**, and it drags in novel edge cases: long-lived "in-progress for a year" jobs for quarterly/annual billing, re-parenting a visit across the period boundary, and a recurring-revenue/paywall entity (`RecurrenceSchedule`) that isn't the billing entity (the period-Job).

ServiceTitan / Housecall Pro avoid all of that by putting **billing on the agreement**: a durable contract entity owns the recurrence *and* accumulates each period's completed work into one invoice, decoupled from any job's lifecycle. This doc projects that model onto Invoices.Backend.

## The one fact that makes it cheap

The `Job↔Invoice` link is **not** a hard 1:1 constraint. It is stored as a **nullable `JobId` string on the invoice** in `Tofu.Invoices` (`Src/Invoices.Core/Models/Invoice.cs` → `public string? JobId`), and `JobInvoiceService.ClearInvoiceLinks` already sets it to `null`. Invoices are **standalone**; `JobId` is an optional back-reference.

⇒ Agreement-owned invoices are just normal drafts created with `JobId = null`. **No change to the invoice model, no break to the existing ad-hoc 1:1 convention.** Recurring invoices and ad-hoc invoices never collide because recurring ones carry no `JobId`.

## Architecture

```
ServiceAgreement (NEW aggregate)                Job (existing)             Visit (existing)
  ├ AccountId, ClientId                          ONE series-Job/agreement   ├ DateTime (occurrence)
  ├ RecurrenceRule (RRULE, owned VO) ─ when ──►  ├ Origin = Recurrence       ├ Origin = Generated
  ├ TimeZoneId                                   ├ Relations.ScheduleLink    ├ worker (per visit)
  ├ Items[]  (recurring service template)        ├ Visits ◄── all occurrences├ SkippedAt
  ├ BillingTerms (cadence, bill day, per-visit)  └ NO InvoiceLink            └ ScheduleDetachedAt
  ├ Status (Active/Stopped/Ended), EndsAt                                      (status, GPS, attachments…)
  ├ GeneratedThroughUtc  (visit cursor)
  ├ BilledThroughUtc     (billing cursor)
  └ sync: SequenceId / Version / IsDeleted
        │
        └─(1:N)─► AgreementInvoice (NEW child) ──► Invoice (Tofu.Invoices, JobId = null)
                    { AgreementId, PeriodStart, PeriodEnd, InvoiceId?, Status }
                    UNIQUE (AgreementId, PeriodStart)   ← durable idempotency
```

**Billing on the agreement** is realised as a new `ServiceAgreement → AgreementInvoice → Invoice` (1:N) path. The existing `invoice.JobId` path is untouched.

**Relations invariant.** `Job↔Invoice` and `Job↔Visit` are unchanged. The series-Job simply never carries an `InvoiceLink`, so the one-invoice guard holds trivially (0 ≤ 1). The only new cross-entity link is `Job.Relations.ScheduleLink { AgreementId }` (additive in the existing `Relations` jsonb, same precedent as `InvoiceLink`/`EstimateLink`).

**What disappears vs Option A:** the **period-Job is gone.** Its sole purpose was to be the 1:1 invoice carrier. With billing on the agreement you need exactly **one ongoing series-Job per agreement**, purely to host `Visit`s (a `Visit` must have a parent `Job` in this domain). The job layer gets *simpler*.

## Domain (`Src/Jobs/Jobs.Domain/`)

```csharp
ServiceAgreement : aggregate root
  Id, AccountId, ClientId
  RecurrenceRule  RecurrenceRule        // RRULE owned VO — FREQ/INTERVAL/BYDAY/BYMONTHDAY/BYSETPOS/End (Ical.Net)
  string          TimeZoneId            // IANA — DST-correct period math
  JobItem[]       Items                 // recurring services; copied onto each invoice
  BillingTerms    Billing               // { Cadence: Monthly=1|Quarterly=2|Annual=3,
                                         //   BillDay: FirstOfNextPeriod=1|LastDayOfPeriod=2,
                                         //   PricingModel: PerVisit=1 }
  AgreementStatus Status                // Active=1, Stopped=2, Ended=3
  DateTimeOffset? EndsAt                // Stop sets = now
  DateTimeOffset? GeneratedThroughUtc   // visit-generation cursor
  DateTimeOffset? BilledThroughUtc      // billing cursor (independent of generation)
  // sync primitives mirror Note/Job: SequenceId (trigger) + Version + IsDeleted

  IEnumerable<DateTimeOffset> Occurrences(DateTimeOffset from, DateTimeOffset to);   // RRULE expansion

AgreementInvoice : child entity               // the 1:N agreement↔invoice link
  Id, AgreementId, PeriodStart, PeriodEnd
  string?            InvoiceId                 // null while Claimed; set once Created
  AgreementInvoiceStatus Status                // Claimed=1, Created=2, Skipped=3

// existing entities — additive only
Job   += Origin : JobOrigin { Manual=1, Scheduling=2, Recurrence=3 }
       += Relations.ScheduleLink { AgreementId }            // set when Origin = Recurrence
Visit += Origin : VisitOrigin { Manual=1, Generated=2 }
       += SkippedAt, ScheduleDetachedAt : DateTimeOffset?
```

`EffectiveStatus`, `JobSummaryView`, the one-invoice guard, `Visit` (worker assignment, status state machine, GPS/attachments) are **reused unchanged**. Inject `IClock` (`Invoices.Core.Time`) into generation + billing.

## Persistence (`Src/Jobs/Jobs.Infrastructure/`)

| Table | New | Storage |
|---|---|---|
| `ServiceAgreements` (new) | whole table | `RecurrenceRule` + `Billing` + `Items` `jsonb`; `TimeZoneId` `text`; `Status` `int`; `GeneratedThroughUtc`/`BilledThroughUtc`/`EndsAt` `timestamptz NULL`; `Version`/`SequenceId`/`IsDeleted` (sync triggers like `Note`) |
| `AgreementInvoices` (new) | whole table | `(AgreementId, PeriodStart, PeriodEnd, InvoiceId NULL, Status int)` · **`UNIQUE (AgreementId, PeriodStart)`** — the durable idempotency key |
| `Jobs` | `Origin` | `int NOT NULL DEFAULT 1` (Manual); index `(AccountId, Origin)`; backfill existing → `Manual` |
| `Jobs` | `Relations.ScheduleLink` | into existing `Relations` `jsonb` — no new column, no FK |
| `Visits` | `Origin`, `SkippedAt`, `ScheduleDetachedAt` | `int NOT NULL DEFAULT 1` + two `timestamptz NULL`; no backfill |

`Tofu.Invoices` needs **no schema change**. *Optional* UX nicety: add a nullable `AgreementId` (and/or a new `InvoiceSource.Recurring`) to the invoice model so the invoice list can label "recurring" and support reverse lookup — but billing works without it (forward links live on `AgreementInvoices`).

One additive EF migration on `JobsDbContext`. **No `JobSummaryView` / status changes.**

## Generation (Worker)

Reuse the **existing `Invoices.Jobs.Recurring.RecurringJob` interval poller** (the pattern behind the ~11 current recurring tasks — `IndexNowJob`, `Payments/*`, etc.), **not** Hangfire cron. Each task is a `RecurringJob` subclass with `[RecurringJobSettings(sleepIntervalHours: 24)]`.

```csharp
// RecurrenceGenerationTask : RecurringJob — top up visits to the rolling horizon
Process():
  foreach agreement in Active where GeneratedThroughUtc < now + Horizon:
     job = EnsureSeriesJob(agreement)                       // created once; Origin=Recurrence, ScheduleLink set
     foreach occ in agreement.Occurrences(GeneratedThroughUtc .. now + Horizon):
        job.AppendGeneratedVisit(occ)                       // Visit.Origin = Generated, via the Job aggregate
     agreement.GeneratedThroughUtc = now + Horizon          // advanced in the SAME tx
     save(agreement, job)                                   // optimistic concurrency; loser retries past the cursor
```

- **On create:** materialise the near horizon synchronously so the calendar fills immediately.
- **On-read top-up:** a calendar read past the cursor materialises the missing visits up to the requested end (hard cap, e.g. +3 months), then serves real rows. Bound it and never surface concurrency retries to the client.
- **Through the aggregate / idempotency:** append visits via the `Job` root; generate strictly past the cursor; advance it in the same transaction.

## Billing (Worker) — on the **agreement**, idempotent by construction

```csharp
// RecurrenceBillingTask : RecurringJob — one draft invoice per finished, unbilled period
Process():
  foreach agreement in Active:
     foreach period in DuePeriods(agreement.BilledThroughUtc, now, agreement.TimeZoneId):   // tz/DST via IClock
        // 1) claim the period — UNIQUE(AgreementId, PeriodStart) lets exactly one runner proceed
        claim = TryInsert(AgreementInvoice { agreement, period, Status = Claimed })
        if claim is null: continue                                   // already claimed/billed on another pod

        // 2) gather the period's completed, non-skipped visits (by DATE on the agreement)
        visits = CompletedNonSkippedVisits(agreement, period)
        if visits.Count == 0: claim.Status = Skipped; save(claim); continue   // empty period → no invoice

        // 3) per-visit pricing: each agreement item × completed count
        lines = agreement.Items.Select(i => i with { Quantity = i.Quantity * visits.Count })

        // 4) create the draft in Tofu.Invoices with a DETERMINISTIC id → Add is an idempotent upsert
        invoiceId = DeterministicInvoiceId(agreement.Id, period.Start)   // stable across retries
        invoicesGateway.Add(new AddInvoiceRequestModel {
            Invoice = new Invoice {
                Id        = invoiceId,
                AccountId = agreement.AccountId,
                Status    = InvoiceStatus.Draft,
                Items     = lines.ToInvoiceItems(),
                JobId     = null,                       // ← agreement-owned, not job-owned
                ClientId  = agreement.ClientId, /* …client snapshot, currency, etc. */ },
            MasterUserId = SystemUserId,
            OccurredAtMs = now.ToUnixTimeMilliseconds(),
            Source       = InvoiceSource.Recurring })   // optional: label recurring invoices

        // 5) record the link + advance the billing cursor
        claim.InvoiceId = invoiceId; claim.Status = Created; save(claim)
        agreement.BilledThroughUtc = period.End; save(agreement)
```

**Why this closes the double-invoice hole** (the weak point of Option A's `[DisableConcurrentExecution]` + check-before-create across a gRPC boundary):

- **`UNIQUE (AgreementId, PeriodStart)`** — a hard DB constraint, not a best-effort lock. Across pods, restarts, and retries, only one `AgreementInvoice` row per (agreement, period) can exist.
- **Deterministic `Invoice.Id = f(agreementId, periodStart)`** — if step 4 runs twice (crash between create and link), `Add` **upserts the same invoice** rather than creating a second draft.
- **Crash recovery:** a `Claimed` row with `InvoiceId == null` older than N minutes ⇒ a runner died mid-bill ⇒ the next pass re-runs step 4 against the same deterministic id. No orphan drafts, no duplicates.

The gRPC `Add` runs **outside** the local transaction; the determinism + claim row make that safe.

## What the agreement-owned invoice represents — **period billing**

Moving the invoice link onto the agreement *is* the choice of period billing; the two are the same decision. An agreement-owned invoice can only mean "a slice of the agreement's visits," i.e. **one billing period** — never one job, never the whole agreement. The agreement holds **many** such invoices (1:N), one per period:

```
ServiceAgreement (1)
  ├─ AgreementInvoice { May  } → Invoice "Pool service ×4 = $240"
  ├─ AgreementInvoice { June } → Invoice "Pool service ×5 = $300"
  └─ AgreementInvoice { July } → …
```

**Link location and billing meaning are coupled — not independent choices:**

| Invoice link lives on | What an invoice represents |
|---|---|
| The **Job** (existing / per-occurrence) | **per-job billing** — one invoice per work unit (per occurrence if jobs are sliced per occurrence) |
| The **Agreement** (this doc) | **period billing** — one invoice per period, aggregating that period's completed visits |

- **Invoice on Job ⇒ per-job billing.**
- **Invoice on Agreement ⇒ period billing** (aggregation across a period is the only thing an agreement-owned invoice *can* mean).

**Consequence — why this collapses the period-Job.** Once billing is period-based on the agreement, **the Job loses its billing role entirely.** That is exactly why Option A needed a synthetic "one Job per period" (to carry the invoice) and Option B does not: the invoice is carried by `agreement + period`, so Jobs/Visits become **pure scheduling**. Note this does not change *what* is billed versus Option A — both do `items × completed-visit-count` per period — only *who owns* the invoice (the agreement, not a period-Job).

**ST nuance.** ServiceTitan agreement/membership billing is usually **flat dues per period** (a fixed monthly fee). This model's period invoice is **usage-priced** (`per-visit × completed count`). Both are "period billing on the agreement" (same cadence + ownership); they differ only in the line-assembly rule. The agreement-owned period invoice already supports flat-rate plans later — you would only swap the line-assembly step, not the structure.

## Lifecycle & editing

- **Edit recurrence / price / bill day (This and following):** change the `RecurrenceRule` / `Items` / `Billing`; future visits regenerate (only `Generated && Scheduled && ScheduleDetachedAt == null`), **already-billed periods are frozen** (their `AgreementInvoice` rows are immutable), past visits stay. Regeneration must never delete a visit that has acquired child data (photos/GPS) — the `ScheduleDetachedAt` guard plus a "has children" check.
- **Only this visit:** edit the one `Visit`; if `Generated`, set `ScheduleDetachedAt` so regeneration skips it.
- **Skip a visit:** `Status = Completed` + `SkippedAt`; excluded from billing (`Completed && SkippedAt == null`). ⚠️ See open question on Completed-overload.
- **Stop repeating:** `Status = Stopped`, `EndsAt = now` → no new visits; existing visits + issued invoices stay; any already-due-but-unbilled period still bills on the next pass.
- **Cross-period reschedule is a non-issue:** billing reads visits **by date** on the agreement, so moving a visit from May 31 → Jun 1 simply lands it in June's period. No re-parenting (the structural pain Option A's period-Jobs create).

## Cross-BC note

The recurring invoice is an ordinary draft in `Tofu.Invoices` reached through the existing `IInvoicesGateway.Add` — same gateway used by `JobInvoiceService` today, just with `JobId = null`. `Tofu.Invoices` stays unaware of agreements. The forward link lives on `AgreementInvoices`; add an optional `Invoice.AgreementId` only if the invoice list needs to show/reverse-lookup "recurring".

## Option A vs Option B

| Dimension | **A — period-Job** (`overview.md`) | **B — bill-on-agreement** (this doc) |
|---|---|---|
| Recurrence entity | `RecurrenceSchedule` (definition only) | `ServiceAgreement` (definition **+ billing**) |
| Invoice carrier | one **Job per period** (1:1) | the **agreement** (1:N via `AgreementInvoice`) |
| Reference model | none (novel period-Job) | **ServiceTitan / Housecall** |
| Quarterly / annual billing | long-lived "in-progress for a year" Job | trivial — just a wider date range |
| Cross-period visit move | re-parent Job ↔ period | non-issue (billed by date) |
| Recurring-revenue / paywall | revenue entity ≠ billing entity (roll-up needed) | native — query the agreement |
| Double-invoice safety | best-effort lock + check-before-create | **DB unique + deterministic invoice id** |
| Job-layer complexity | period-Jobs (≈12/yr/agreement) | one series-Job/agreement |
| Change to invoice model | none | none (uses nullable `JobId`) |
| Net footprint | smaller (no new aggregate) | **larger** — a first-class `ServiceAgreement` + billing path |

**Take:** A is fewer changes but its simplicity is partly illusory (the period-Job is novel and its edge cases are real). B is more upfront work — a genuine new aggregate — but it is the shape the big FSM platforms converged on, it eliminates the period-Job edge cases, and it makes billing idempotency a DB invariant. Choose B if quarterly/annual billing or recurring-revenue reporting is on the near roadmap.

## Client compatibility

Fully additive. `ServiceAgreement` is a brand-new entity (new endpoints) → no wire-enum changes. The series-Job is `Origin = Recurrence` and filtered out of the default jobs list and `GET /jobs/stats`. **Visits look completely normal to the Worker app.** Recurring invoices are ordinary drafts with `JobId = null` → iOS strict-`Codable`, web, and worker all see nothing unfamiliar. (If `InvoiceSource.Recurring` is added, treat it as a possibly-strict wire enum and verify clients tolerate it — otherwise label via a separate additive field.)

## Open questions

- **Series-Job vs per-occurrence Job.** This doc uses **one series-Job per agreement** (bounded, minimal client/sync/stats blast radius — recommended). The *more ST-literal* mapping is **one Job per occurrence** ("1 visit = 1 job = 1 appointment"), which generates ~52 jobs/client/year and would pollute job tables/sync/stats unless filtered everywhere. Pick per-occurrence only if per-visit jobs must be first-class in the UI.
- **Skip overloads `Completed`.** `Skip = Completed + SkippedAt` is clean for billing but makes a skipped visit read as `Completed` in every status calc / stats. Confirm it isn't inflating "completed work" anywhere user-visible.
- **Worker assignment for generated visits** — where does the assignee come from (agreement default? unassigned)? Not yet in the model.
- **Invoice back-ref** — ship without `Invoice.AgreementId`, or add it for invoice-list UX / reverse lookup?
- **List / paywall** — the `Recurring` tab shows **agreements**; paywall counts the agreement once (it generates no period-Jobs to miscount — a simplification over Option A).
