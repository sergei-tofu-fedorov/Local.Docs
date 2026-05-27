# WEB-874 — Scheduling — Backend Implementation Plan

[ClickUp WEB-874 (initiative)](https://app.clickup.com/t/869bt2kwj) · [WEB-1509 (BE)](https://app.clickup.com/t/869da2vaj) / [FS-1029 (FS BE)](https://app.clickup.com/t/869dagcp8) — single BE stream for Web + FS Mobile.

## Summary

- Week-view calendar for the Web Manager rides on the existing visit surface — no new routes:
  - Read: `GET /api/v3/visits/all?startsFrom&endsBefore` (`VisitsController.cs`).
  - Quick-add / edit job: `PUT /api/v3/jobs`.
  - Reschedule / edit single visit: `PUT /api/v3/jobs/{jobId}/visits/{visitId}`.
  - Status change: `PATCH /api/v3/jobs/{jobId}/visits/{visitId}/status`.
  - Worker assign / unassign: `PATCH /api/v3/jobs/{jobId}/visits/{visitId}/worker`.
- Single new field on `Visit`: `DurationMinutes` (nullable int). FE renders the time range as `start … start + duration`.
- Denormalize `AccountId` + `IsDeleted` onto `Visits` to remove the JOIN with `Jobs` from per-tenant date-window queries. Backfill in the same migration.
- Two new composite indexes on `Visits` to back week view, worker calendar, and future conflict detection.
- Cascade `Job.IsDeleted` → `Visit.IsDeleted` in the `Job` aggregate (`Job.MarkDeleted()`), no DB triggers.
- 4 DTOs gain `DurationMinutes`. No new permission keys.

## What changes

**Domain (`Src/Jobs/Jobs.Domain/Models/`):**
- `Visit.cs` — add `DurationMinutes (int?)`, `AccountId (string)`, `IsDeleted (bool)`; `MarkDeleted()` method; validation in setter / factory.
- `Job.cs` — `Job.MarkDeleted()` iterates `Visits` and calls `Visit.MarkDeleted()` on each; `Job.AddVisit(...)` and `Job.UpdateVisits(...)` propagate `AccountId` + `DurationMinutes` onto new / updated visits.
- `Visit.IsOverdue(now)` — **no change**. `Status == Scheduled` already excludes started visits, so `DurationMinutes` does not belong in the formula.

**Persistence (`Src/Jobs/Jobs.Infrastructure/`):**
- `Database/Configurations/VisitConfiguration.cs` — map three new columns; add `(AccountId, DateTime)` for date-window scans and partial `(AccountId, AssignedWorkerId, DateTime) WHERE AssignedWorkerId IS NOT NULL` for per-worker reads; keep existing `(JobId, DateTime)`.
- `Repositories/JobsRepository.GetVisitsFrom(...)` — swap filter from `v.Job.AccountId == accountId && !v.Job.IsDeleted` to `v.AccountId == accountId && !v.IsDeleted`. JOIN with `Jobs` remains only for projection (`JobTitle`, `ClientSnapshot`).
- New EF migration `WEB-874_Scheduling_VisitDenormalization` (see [Migration](#migration)).

**Application (`Src/Jobs/Jobs.Contracts/` + `Jobs.Application/`):**
- `Jobs.Contracts/Jobs/Queries/GetVisitsQuery.cs:VisitListItem` — add `DurationMinutes (int?)`.
- `Jobs.Contracts/Jobs/Commands/...VisitInput` — add `DurationMinutes (int?)`.
- `Jobs.Contracts/Jobs/Commands/UpdateVisitCommand` — add `DurationMinutes (int?)`.
- Handlers — pass-through, no logic.

**API gateway (`Src/Invoices.Api/`):**
- `Dto/Visits/VisitListItemDto.cs` — add `DurationMinutes (int?)`.
- `Dto/Jobs/VisitDtos.cs:VisitDto` + `VisitInputDto` — add `DurationMinutes (int?)`.
- `Dto/Jobs/UpdateVisitRequestDto.cs` — add `DurationMinutes (int?)`.
- Mappers — pass-through.
- No new controller actions. Existing `[AuthorizeAction]` decorators preserved.

## Data model

### `Visits` table — new columns

| Column | Type | Notes |
|---|---|---|
| `DurationMinutes` | `integer NULL` | Validation `> 0, ≤ 1440` if non-null. Existing rows = `NULL`. |
| `AccountId` | `text NOT NULL` | Backfilled from `Jobs.AccountId` in the same migration. Immutable after creation. |
| `IsDeleted` | `boolean NOT NULL DEFAULT false` | Backfilled from `Jobs.IsDeleted`. Synced via `Job.MarkDeleted()` cascade. |

### Indexes

| Index | Definition | Purpose |
|---|---|---|
| `IX_Visits_AccountId_DateTime` | `(AccountId, DateTime)` | Week view, Today, any account-scoped date-window scan. |
| `IX_Visits_AccountId_AssignedWorkerId_DateTime` | `(AccountId, AssignedWorkerId, DateTime) WHERE AssignedWorkerId IS NOT NULL` | Per-worker calendar, future conflict detection. Partial — keeps it compact. |
| `IX_Visits_JobId_DateTime` (existing) | `(JobId, DateTime)` | Kept — backs per-job reads (job page). |

### Cascade rule (`IsDeleted`)

App-layer, inside `Job.MarkDeleted()`:

```csharp
public void MarkDeleted()
{
    if (IsDeleted) return;
    IsDeleted = true;
    foreach (var visit in Visits)
        visit.MarkDeleted();
    // existing domain event raise…
}
```

No PG triggers. `EF Core` saves both `Jobs` and child `Visits` updates in one transaction.

## Migration

```powershell
cd Src
dotnet ef migrations add WEB-874_Scheduling_VisitDenormalization `
    -c JobsDbContext `
    -p "Jobs.Infrastructure" `
    -s "Invoices.Api" `
    -o Database/Migrations
```

Scaffold gives `ADD COLUMN` skeletons; handcraft the backfill between `ADD COLUMN` and `ALTER COLUMN SET NOT NULL`:

```sql
-- 1. New optional duration column. Existing rows stay NULL — FE falls back to a fixed-height card.
ALTER TABLE "Visits" ADD COLUMN "DurationMinutes" integer NULL;

-- 2. Denormalize AccountId from Jobs. Add nullable → backfill → set NOT NULL.
ALTER TABLE "Visits" ADD COLUMN "AccountId" text NULL;
UPDATE "Visits" v
SET "AccountId" = j."AccountId"
FROM "Jobs" j
WHERE v."JobId" = j."Id";
ALTER TABLE "Visits" ALTER COLUMN "AccountId" SET NOT NULL;

-- 3. Denormalize IsDeleted from Jobs. Default false covers future inserts; backfill syncs existing rows with their parent Job.
ALTER TABLE "Visits" ADD COLUMN "IsDeleted" boolean NOT NULL DEFAULT false;
UPDATE "Visits" v
SET "IsDeleted" = j."IsDeleted"
FROM "Jobs" j
WHERE v."JobId" = j."Id";

-- 4. Primary read index for account-scoped date-window scans (week view, Today).
CREATE INDEX "IX_Visits_AccountId_DateTime"
    ON "Visits" ("AccountId", "DateTime");

-- 5. Partial index for per-worker reads (worker calendar, future conflict detection). Stays compact by skipping unassigned visits.
CREATE INDEX "IX_Visits_AccountId_AssignedWorkerId_DateTime"
    ON "Visits" ("AccountId", "AssignedWorkerId", "DateTime")
    WHERE "AssignedWorkerId" IS NOT NULL;
```

Backfill is bounded by current Visits volume — runs once at deploy time. Existing `(JobId, DateTime)` index is left in place.

## Files changed

| File | Change |
|---|---|
| `Src/Jobs/Jobs.Domain/Models/Visit.cs` | + `DurationMinutes`, `AccountId`, `IsDeleted`, `MarkDeleted()`, validation |
| `Src/Jobs/Jobs.Domain/Models/Job.cs` | cascade in `MarkDeleted()`; propagate `AccountId` + `DurationMinutes` in `AddVisit` / `UpdateVisits` |
| `Src/Jobs/Jobs.Infrastructure/Database/Configurations/VisitConfiguration.cs` | map 3 columns + 2 indexes |
| `Src/Jobs/Jobs.Infrastructure/Database/Migrations/<timestamp>_WEB-874_Scheduling_VisitDenormalization.cs` | new migration (see [Migration](#migration)) |
| `Src/Jobs/Jobs.Infrastructure/Repositories/JobsRepository.cs` | `GetVisitsFrom` filters by `Visits.AccountId` / `Visits.IsDeleted` directly |
| `Src/Jobs/Jobs.Contracts/Jobs/Queries/GetVisitsQuery.cs` | `VisitListItem.DurationMinutes` |
| `Src/Jobs/Jobs.Contracts/Jobs/Commands/*.cs` | `VisitInput.DurationMinutes`, `UpdateVisitCommand.DurationMinutes` |
| `Src/Invoices.Api/Dto/Visits/VisitListItemDto.cs` | + `DurationMinutes` |
| `Src/Invoices.Api/Dto/Jobs/VisitDtos.cs` | + `DurationMinutes` on `VisitDto` and `VisitInputDto` |
| `Src/Invoices.Api/Dto/Jobs/UpdateVisitRequestDto.cs` | + `DurationMinutes` |
| `Src/Invoices.Api/Mapping/*` | mapper passthrough for new field |

## Tests

**Unit (`Invoices.Backend.UnitTests` / `Jobs.UnitTests`):**
- `Visit.SetDurationMinutes` — accept `null`, accept `> 0`, reject `0` / `-1` / `> 1440` → `ArgumentException`.
- `Job.MarkDeleted()` cascades `IsDeleted = true` to every child `Visit`; second call is no-op.
- `Job.AddVisit(...)` propagates `AccountId` from job to new `Visit`.
- `Visit.IsOverdue(now)` unchanged when `DurationMinutes` is set or null.

**Migration (`Invoices.IntegrationTests`):**
- Fixture: seed `Jobs` + `Visits` in pre-migration schema with mixed `Jobs.IsDeleted` values.
- After migration: `Visits.AccountId` matches `Jobs.AccountId`; `Visits.IsDeleted` matches `Jobs.IsDeleted`; `Visits.DurationMinutes IS NULL` on every row; both new indexes present.

**Integration (`Invoices.IntegrationTests`):**
- `PUT /api/v3/jobs` with `Visits[].DurationMinutes` → round-trips through `GET /api/v3/jobs/{id}` and `GET /api/v3/visits/all`.
- `PUT /api/v3/jobs/{jobId}/visits/{visitId}` accepts and returns `DurationMinutes`.
- `PATCH .../status` and `PATCH .../worker` do not touch `DurationMinutes`.
- `DELETE /api/v3/jobs/{id}` (soft-delete) → child visits' `IsDeleted = true` in storage (raw query) and excluded from `GET /api/v3/visits/all`.
- Backwards compat: a request omitting `DurationMinutes` on update keeps the stored value (snapshot semantics — caller is expected to re-send).

## Backward compatibility

- `DurationMinutes` is nullable additive — old clients ignoring it keep working with the previous fixed-height card rendering.
- `AccountId` / `IsDeleted` are internal storage fields, not on the wire. No client contract impact.
- No removed routes, no field renumbering.
- FS Mobile (FS-1029) picks up the wire field on the same release boundary as Web; uncoordinated rollouts cause no regression (mobile keeps current rendering).
- Coordination with Today (WEB-1441): same `VisitListItemDto` — field lands once for both screens.

## Docs to update

- `Backend/Api/JOBS_API_REFERENCE.md` — add `DurationMinutes` to `VisitDto` and `VisitInputDto` schema rows.
- `Backend/Api/WORKER_API_REFERENCE.md` — same on worker visit DTOs (mobile reads the same field).
- `features/today_screen/plan.md` — note that `VisitListItemDto.DurationMinutes` will be present once WEB-874 ships; Today consumers can start reading it without any extra work.
