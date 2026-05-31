# WEB-1523 — Analyze pipeline (implementation)

How `Tofu.AI.Backend` runs a concrete analysis on top of the shared `account_metrics` BigQuery table that [`metrics.md`](metrics.md) populates: redaction → LLM → deterministic rule → score/tier → per-analysis result table (`account_fsm_fit`). The *what / why* of the analysis contract lives in [`../analyses/scoring.md`](../analyses/scoring.md) (framework) and [`../analyses/fsm-fit/scoring.md`](../analyses/fsm-fit/scoring.md) (FSM-fit instance); the LLM provider mechanics live in [`../investigation/provider.md`](../investigation/provider.md); the PII / redaction contract in [`../investigation/privacy.md`](../investigation/privacy.md). This doc covers *where the analyze pipeline lives in code and how it's wired* — the analyze counterpart to `metrics.md`.

> **Scope guardrail.** No prompt text, no rule weights, no tier vocabulary here — those are locked in `analyses/scoring.md` + `analyses/fsm-fit/scoring.md` and quoted only when an implementation choice depends on them. This doc also does **not** re-cover metrics collection: `account_metrics` is the *input* to the analyze pipeline and is owned entirely by [`metrics.md`](metrics.md).

> **Status — split out 2026-05-24.** The class / DI / cron scaffolding below was originally specified inside `metrics.md` while the two stages shared a doc. It was split out so the metrics read path can ship first as a self-contained stage. The core analyze *logic* (the real `ILlmClient`, `IPromptLoader`, redaction wiring, rule materialisation, and the `account_fsm_fit` writer) is **not yet designed in implementation detail** — it lands here once the metrics stage is green and the Phase A½ PM demo (see `README.md` § Sequenced next moves) locks the prompt and rule. The one analyze-stage piece already built in code is **§ Audience eligibility** (the FSM-using-account exclusion), which also moved here from `metrics.md`.

## Decision

- **The analyze pipeline reads `account_metrics`, never the source Mongo / PG.** `metrics.md` owns all signal collection; `AnalyzeJob<TAnalysis>` consumes the typed `account_metrics` row as its sole input, redacts it, calls the LLM, applies the rule, and writes the per-analysis result. This keeps the analyze stage source-store-agnostic and is why the two stages split cleanly.
- **One generic `AnalyzeJob<TAnalysis>` base + one instantiation per analysis.** v1 ships `AnalyzeFsmFitJob : AnalyzeJob<FsmFit>`. v2 (`churn_risk`, `suspicious_user`) add their own instantiations against the same base — no new infrastructure (per the multi-analysis framework in `analyses/scoring.md` § Decision).
- **Analyze jobs run in the same in-process Hangfire host as `MetricsRefreshJob`.** No separate Deployment — they share the host that `metrics.md` § Decision and [`service.md`](service.md) § Decision establish. Each analyze job is its own recurring job on a per-analysis cron.
- **`SmokeProbeJob` is the deploy-verification one-shot** — fires one LLM call + one BQ write after start so a fresh deploy proves the analyze path end-to-end. Gated behind `Analyses:SmokeProbe:Enabled`.

Everything below is the scaffolding moved out of `metrics.md`; the analyze logic itself is the open work (§ Open questions).

## Job classes — in `Analyses.Application/Jobs/`

These live in the same folder as `MetricsRefreshJob.cs` (see `metrics.md` § Code layout) but are owned by this doc:

| Class | Role |
|---|---|
| `AnalyzeJob.cs` | generic `AnalyzeJob<TAnalysis>` base — the redact → LLM → rule → write tick |
| `AnalyzeFsmFitJob.cs` | FSM-fit instantiation (`AnalyzeJob<FsmFit>`) |
| `SmokeProbeJob.cs` | deploy verification — fires LLM + BQ once after start |

## DI registration

Registered in `AddAnalysesApplication` alongside the metrics job (which is itself owned by `metrics.md`):

| Registration | Lifetime | Module (DI file) | Note |
|---|---|---|---|
| `AnalyzeFsmFitJob`, `SmokeProbeJob` | Scoped | `AddAnalysesApplication` | matches Hangfire job-activator lifetime |
| `ILlmClient`, `IPromptLoader` | Singleton | `AddAnalysesApplication` | **stubs** in the metrics stage; real impls land with this doc |

## Recurring-job + CLI registration

- **Recurring jobs.** `RegisterAnalysesRecurringJobs` (called from `Tofu.AI.Api/Program.cs` after `app.Build()`) registers `AnalyzeFsmFitJob` on its per-analysis cron, and — when `Analyses:SmokeProbe:Enabled = true` — `SmokeProbeJob`. The `MetricsRefreshJob` registration at the same call site is owned by `metrics.md` § DI registration.
- **CLI-mode.** `dotnet Tofu.AI.Api.dll openai-ping` is the LLM-probe CLI; like `migrate` it short-circuits the Hangfire host (see `metrics.md` § DI registration § "CLI-mode short-circuit" and `service.md` § Q2).

## Audience eligibility

`account_metrics` is analysis-agnostic — it holds a row for *every* invoice-active account, including ones already using FSM and ones created only days ago. Deciding which subset a given analysis scores is that analysis's concern. FSM-fit applies **two** audience filters, both inside `AnalyzeFsmFitJob` at scoring time (never in metrics collection):

1. **FSM-using-account exclusion** — don't spend an LLM call telling an account that already runs jobs to adopt FSM. (Moved here from `metrics.md` 2026-05-24.)
2. **Account-maturity gate** — only score accounts **created more than 90 days ago**; brand-new accounts haven't established a billing pattern, so scoring them is noise and the proposal would be premature.

(See `../analyses/metrics.md` § Eligibility, which deliberately leaves *both* gates out — `account_metrics` rows exist for FSM users and <90-day accounts alike.)

### Where it plugs in

`AnalyzeFsmFitJob` selects its candidate set from `account_metrics`, then drops both ineligible subsets *before* scoring:

```text
AnalyzeFsmFitJob tick:
    candidates ← account_metrics rows due for (re)scoring
    fsmUsers   ← IFsmEligibilityProbe.GetAccountIdsWithRecentJobsAsync(candidates)
    tooYoung   ← candidates whose account was created ≤ 90 days ago    # maturity gate
    score      ← candidates − fsmUsers − tooYoung    # invoice-only, established audience
    FOR EACH account IN score:  redact → LLM → rule → write account_fsm_fit
```

### The probe — contract + two implementations

```csharp
// Analyses.Domain/Eligibility/IFsmEligibilityProbe.cs
Task<IReadOnlyCollection<string>> GetAccountIdsWithRecentJobsAsync(
    IReadOnlyCollection<string> candidateAccountIds, CancellationToken ct);
```
Returns the subset of input ids that have a **non-deleted job completed in the last 90 days** — i.e. the accounts to exclude.

| Impl | Location | Behaviour |
|---|---|---|
| `InvoicesJobsEligibilityProbe` | `Analyses.Infrastructure/Eligibility/` | Batched `WHERE "AccountId" = ANY(@ids)` over `Invoices.Backend`'s Postgres `jobs."Jobs"`, filtered to `(IsDeleted IS NULL OR false) AND CompletionTime >= NOW() - INTERVAL '90 days'`. Batch ≤ 10,000 ids/round-trip; runs serially, not under the LLM fan-out. |
| `NoOpFsmEligibilityProbe` | `Analyses.Application/Eligibility/` | Returns `[]` (exclude nobody). Dev / test fallback when `ConnectionStrings:InvoicesJobs` is absent — lets the analyze pipeline run locally without the cross-repo PG. **Never prod:** with it, FSM users are scored. |

> Naming note: the spec narrative in `../analyses/metrics.md` calls these `PgFsmEligibilityProbe` / `JobsDbDataSource`; the shipped code uses `InvoicesJobsEligibilityProbe` / `InvoicesJobsConnectionFactory`. This doc tracks the code.

### Account-maturity gate (created > 90 days ago)

The second audience filter: FSM-fit scores an account only if it was **created more than 90 days ago** (`Account.CreatedTime < analyzedAt.AddDays(-90)`). Brand-new accounts haven't had time to establish a billing pattern, so scoring them yields noise and a premature in-app proposal. Threshold is a uniform **90 days** (not calendar months), exposed as a knob `Analyses:FsmFit:MinAccountAgeDays` (default `90`).

Like the FSM-using exclusion, this runs **inside `AnalyzeFsmFitJob` at scoring time**, not in metrics collection — `account_metrics` still holds rows for <90-day accounts (and a future analysis may well want to score young accounts, e.g. `churn_risk`); FSM-fit just drops them from its own `score` set. This is why the gate is **not** a metrics-eligibility condition — it would wrongly starve other analyses of young-account rows.

**Account-age source (open — resolve when wiring).** `account_metrics` does not currently carry the account creation date, and the candidate query keys off `account_metrics` alone. Two options: (a) add an `account_created_at` column to `account_metrics` — cheap, since the metrics collector already reads the `accounts` doc for `business_name`, and it lets the gate run as a pure BQ predicate in the candidate query; or (b) read `accounts.CreatedTime` for the candidate batch at analyze time — a small extra Mongo lookup mirroring the invoice-signals read, keeping `account_metrics` unchanged. Either way, treat a null/missing `CreatedTime` as **eligible** (it pre-dates the field, so the account is old). Batch the lookup serially, outside the LLM fan-out — same shape as the FSM-using probe.

### Connection wiring — Postgres `jobs` schema in `Invoices.Backend`

`InvoicesJobsConnectionFactory` builds the read-only connection from `ConnectionStrings:InvoicesJobs`:

| Setting | Value |
|---|---|
| `SearchPath` | `jobs` |
| `ApplicationName` | `Tofu.AI.Api/FsmFitEligibility` |
| `CommandTimeout` | `30` |
| parameter logging | off |

**Read-only** — the connection string must reference a role with `SELECT` on `jobs."Jobs"` and nothing else. This is a third read connection, separate from both the Mongo source (`metrics.md`) and the AI service's own Hangfire-state Postgres (`analyses` schema).

### Configuration

```jsonc
{
  "Analyses": {
    "Postgres": {
      "JobsDb": {
        "ConnectionString": "<resolved per env from GSM — read-only role on jobs.Jobs>"
      }
    }
  }
}
```

### DI

| Registration | Lifetime | Module | Note |
|---|---|---|---|
| `IFsmEligibilityProbe → NoOpFsmEligibilityProbe` | Singleton | `AddAnalysesApplication` | default; `Replace`d below when the conn string is present |
| `InvoicesJobsConnectionFactory` + `IFsmEligibilityProbe → InvoicesJobsEligibilityProbe` | Singleton | `AddAnalysesInfrastructure` | **only if** `ConnectionStrings:InvoicesJobs` present — `Replace`s the No-op |

### Cross-repo prerequisites

| Prereq | Owner | Where |
|---|---|---|
| Read-only PG role with `SELECT` on `jobs."Jobs"` in `Invoices.Backend` prod + stage | `Invoices.Backend` | Migration in `Invoices.Backend` repo — separate PR |
| `jobs.Jobs.{AccountId}` index exists | `Invoices.Backend` | Verify before stage cutover |

### Test surface

- **`AnalyzeFsmFitJob_excludes_accounts_with_recent_jobs`** — TestContainers Postgres seeded with `jobs.Jobs` rows; assert an account with a recent non-deleted job is dropped from the scored set and one without is kept. This is the integration test that the FSM-using/PG dimension was removed from `metrics.md`'s tick test to host.

## Observability

LLM-call telemetry — token counts, latency, cost, structured-output parse-failure rate — belongs **here**, on `AnalyzeJob<TAnalysis>`, **not** on `MetricsRefreshJob`. `account_metrics` is rule-free and model-free; the analyze stage is the only place model cost and reliability surface. Wire it when the real `ILlmClient` lands.

## Open questions (analyze-side)

- [ ] **Full analyze-pipeline design.** Redaction wiring (Presidio, per `investigation/privacy.md`), the real `ILlmClient` against OpenAI structured outputs (per `investigation/provider.md`), `IPromptLoader` source (checked-in prompt vs GSM), rule materialisation at write time in C#, and the `account_fsm_fit` Storage Write API CDC writer. Filled in once the metrics stage ships and Phase A½ locks the prompt / rule.
- [ ] **Per-analysis cron cadence** for `AnalyzeFsmFitJob` — relative to `MetricsRefreshJob`'s hourly tick and the cold-start latency budget in `analyses/metrics.md` § Refresh strategy.
- [ ] **Re-score trigger** — does an analyze tick re-run on every refreshed `account_metrics` row, or only on a TTL of its own? Affects LLM cost directly.
