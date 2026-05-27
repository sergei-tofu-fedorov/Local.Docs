# Step 9: Visit Timestamps — Implementation Plan

> Add `UpdatedAt` and `StatusChangedAt` fields to the Visit model to track
> when a visit was last modified and when its status last changed.

## Motivation

Currently the Visit model has no audit trail for modifications.
`UpdatedAt` records any property change (server time); `StatusChangedAt` records
the most recent status transition (**client-provided time** to support offline workers).

### Current problem

`WorkerUpdateVisitStatusCommand` does not have an `OccurredAt` field —
the handler always uses `DateTimeOffset.UtcNow`. This means if a worker
changes status offline and syncs later, the recorded time is wrong.
The Jobs endpoint command (`UpdateVisitStatusCommand`) already has `OccurredAt`
but the controller hardcodes `null`. Both paths need to be fixed.

### Timestamp semantics

| Field | Source | Why |
|-------|--------|-----|
| `UpdatedAt` | Server (`DateTimeOffset.UtcNow`) | Tracks when the DB record changed — always reliable |
| `StatusChangedAt` | Client (via `OccurredAt` from `XA-Client-Event-Ms` header) | Worker may change status offline; real time matters for SLA/analytics |

If the client does not provide `OccurredAt`, fall back to server time.

---

## Phase 1: Domain Model

### 1.1 Add fields to `Visit`

**File:** `Jobs/Jobs.Domain/Models/Visit.cs`

- Add `public DateTimeOffset? UpdatedAt { get; private set; }` — server time
- Add `public DateTimeOffset? StatusChangedAt { get; private set; }` — client time

Both are nullable — `null` means the visit predates this feature.

### 1.2 Update `Visit.Update()`

**File:** `Jobs/Jobs.Domain/Models/Visit.cs`

Add `DateTimeOffset occurredAt` parameter. `UpdatedAt` is set to `DateTimeOffset.UtcNow`
internally (server time). `StatusChangedAt` is set from `occurredAt` only when status changes.

```csharp
internal bool Update(DateTimeOffset dateTime, VisitStatus status, string? assignedWorkerId, DateTimeOffset occurredAt)
{
    var statusChanged = Status != status;

    DateTime = dateTime;
    Status = status;
    AssignedWorkerId = assignedWorkerId;
    UpdatedAt = DateTimeOffset.UtcNow;

    if (statusChanged)
        StatusChangedAt = occurredAt;

    return statusChanged;
}
```

### 1.3 Update `Visit.UpdateStatus()`

**File:** `Jobs/Jobs.Domain/Models/Visit.cs`

Add `DateTimeOffset occurredAt` parameter. Always sets both timestamps —
`UpdatedAt` from server, `StatusChangedAt` from client.

```csharp
internal void UpdateStatus(VisitStatus status, DateTimeOffset occurredAt)
{
    Status = status;
    UpdatedAt = DateTimeOffset.UtcNow;
    StatusChangedAt = occurredAt;
}
```

### 1.4 Update `Visit.Create()`

**File:** `Jobs/Jobs.Domain/Models/Visit.cs`

Add `DateTimeOffset occurredAt` parameter. Sets both `StatusChangedAt = occurredAt`
(creating a visit with a status is the first status assignment) and
`UpdatedAt = DateTimeOffset.UtcNow`.

```csharp
public static Visit Create(
    Guid id, Job job, DateTimeOffset dateTime,
    VisitStatus status, string? assignedWorkerId,
    DateTimeOffset occurredAt)
{
    return new Visit
    {
        Id = id, JobId = job.Id, DateTime = dateTime,
        Status = status, AssignedWorkerId = assignedWorkerId,
        Job = job,
        StatusChangedAt = occurredAt,
        UpdatedAt = DateTimeOffset.UtcNow
    };
}
```

---

## Phase 2: Job Aggregate (Caller Updates)

### 2.1 Update `Job.UpdateVisits()`

**File:** `Jobs/Jobs.Domain/Models/Job.cs`

This method already receives `DateTimeOffset occurredAt`. Pass it to:
- `Visit.Create(..., occurredAt)` — new visits
- `visit.Update(..., occurredAt)` — existing visits

### 2.2 Update `Job.TryUpdateVisitStatus()`

**File:** `Jobs/Jobs.Domain/Models/Job.cs`

Already accepts `DateTimeOffset occurredAt`. Pass it to `visit.UpdateStatus(newStatus, occurredAt)`.

### 2.3 Update `Job.TryUpdateVisitStatusByWorker()`

**File:** `Jobs/Jobs.Domain/Models/Job.cs`

Same as 2.2 — pass `occurredAt` to `visit.UpdateStatus(newStatus, occurredAt)`.

---

## Phase 3: Jobs Endpoint — Thread `OccurredAt` from Header

`UpdateVisitStatusCommand` already has `OccurredAt`, but the controller hardcodes `null`.
The client time comes from the `XA-Client-Event-Ms` header via `GetClientEventTime()`.

### 3.1 Pass `GetClientEventTime()` in Jobs controller

**File:** `Invoices.Api/Controllers/JobsController.cs`

Change `OccurredAt: null` to `OccurredAt: GetClientEventTime()`.

No changes to the request DTO — `OccurredAt` comes from the header, not the body.

### 3.2 Handler — fix `_jobsRepository.Update()` time parameter

**File:** `Jobs/Jobs.Application/Commands/UpdateVisitStatusCommandHandler.cs`

Change `_jobsRepository.Update(job, occurredAt)` to `_jobsRepository.Update(job, DateTimeOffset.UtcNow)`.
The repository's `Update` sets the job-level `UpdatedAt` which must be server time,
not client time.

---

## Phase 4: Worker Endpoint — Add `OccurredAt` Support

`WorkerUpdateVisitStatusCommand` currently has **no `OccurredAt`** field.
The handler hardcodes `DateTimeOffset.UtcNow`, which breaks offline scenarios.

### 4.1 Add `OccurredAt` to `WorkerUpdateVisitStatusCommand`

**File:** `Jobs/Jobs.Contracts/Worker/WorkerUpdateVisitStatusCommand.cs`

Add `DateTimeOffset? OccurredAt` parameter to the record.

No changes to the Worker request DTO — `OccurredAt` comes from the
`XA-Client-Event-Ms` header via `GetClientEventTime()`.

### 4.2 Pass `GetClientEventTime()` in Worker controller

**File:** `Invoices.Api/Controllers/WorkerController.cs`

Pass `GetClientEventTime()` as the `OccurredAt` argument when constructing `WorkerUpdateVisitStatusCommand`.

### 4.3 Update `WorkerUpdateVisitStatusCommandHandler`

**File:** `Jobs/Jobs.Application/Worker/Commands/WorkerUpdateVisitStatusCommandHandler.cs`

- Rename `cmd` to `command` for consistency
- Resolve client time: `var occurredAt = command.OccurredAt ?? DateTimeOffset.UtcNow`
- Pass `occurredAt` (client time) to `job.TryUpdateVisitStatusByWorker()`
- Pass `DateTimeOffset.UtcNow` (server time) to `_jobsRepository.Update()`
- Pass `occurredAt` (client time) to `_jobDomainEventService.Save()`

---

## Phase 5: Database Configuration

### 5.1 Add column mappings

**File:** `Jobs/Jobs.Infrastructure/Database/Configurations/VisitConfiguration.cs`

```csharp
builder.Property(v => v.UpdatedAt)
    .HasColumnType("timestamptz");

builder.Property(v => v.StatusChangedAt)
    .HasColumnType("timestamptz");
```

### 5.2 Generate EF Core migration

```bash
dotnet ef migrations add AddVisitTimestamps --project Jobs/Jobs.Infrastructure --startup-project Invoices.Api --context JobsDbContext
```

Migration adds two nullable `timestamptz` columns to `jobs.Visits` table.
No data migration needed — existing rows get `NULL`.

---

## Phase 6: DTOs & Mapping (Response)

Only `StatusChangedAt` is exposed in API responses. `UpdatedAt` is internal only
(stored in DB for audit, not sent to clients).

### 6.1 Add `StatusChangedAt` to contract DTOs

**Files:**
- `Jobs/Jobs.Contracts/Jobs/VisitDtos.cs` — `VisitDto`
- `Jobs/Jobs.Contracts/Worker/WorkerVisitDtos.cs` — `WorkerVisitDto`

```csharp
public DateTimeOffset? StatusChangedAt { get; set; }
```

### 6.2 Add `StatusChangedAt` to API response DTOs

**Files:**
- `Invoices.Api/Dto/Jobs/VisitDtos.cs` — `VisitDto`
- `Invoices.Api/Worker/Dto/WorkerVisitsPagedResponse.cs` — `WorkerVisitResponse`

```csharp
public DateTimeOffset? StatusChangedAt { get; set; }
```

### 6.3 Add `StatusChangedAt` to `WorkerVisitData` projection

**File:** `Jobs/Jobs.Domain/Models/WorkerVisitData.cs`

```csharp
public DateTimeOffset? StatusChangedAt { get; init; }
```

### 6.4 Update mapping logic

Map `StatusChangedAt` in all Visit → DTO mapping methods:
- `JobsMappings.ToVisitDto()` — contract mapping
- `JobsApiMappings.ToApi()` — API response mapping
- `WorkerMappings.ToDetails()` / `ToListItem()` — worker contract mapping
- `WorkerApiMappings.ToResponse()` — worker API response mapping
- `JobsRepository` worker visit projection query

---

## Phase 7: Tests

Tests are in `Jobs/Jobs.UnitTests/Domain/Models/JobTests.cs` (61 existing tests).
Existing tests already compile with new signatures — `Visit.Create` and `visit.Update`
receive `occurredAt` through `Job.UpdateVisits(inputs, workerNames, occurredAt)`.

### 7.1 New tests — Visit timestamp behavior

Add tests that assert on `StatusChangedAt` and `UpdatedAt` values:

#### Visit creation timestamps

```
UpdateVisits_NewVisit_SetsStatusChangedAtFromOccurredAt
```
Create a job, call `UpdateVisits` with a new visit input, verify
`visit.StatusChangedAt == occurredAt` (the `DefaultOccurredAt` value passed to `UpdateVisits`).
Also verify `visit.UpdatedAt` is set (not null, approximately `DateTimeOffset.UtcNow`).

#### Status change timestamps via UpdateVisits

```
UpdateVisits_StatusChanged_SetsStatusChangedAtFromOccurredAt
```
Create a job with a `Scheduled` visit, call `UpdateVisits` with `InProgress` status
and a specific `occurredAt`. Verify `visit.StatusChangedAt == occurredAt`.

```
UpdateVisits_StatusUnchanged_DoesNotUpdateStatusChangedAt
```
Create a job with a `Scheduled` visit. Call `UpdateVisits` with the same status
but a different `occurredAt`. Verify `visit.StatusChangedAt` is still the original value
(from creation), not the new `occurredAt`. Verify `visit.UpdatedAt` IS updated
(since properties were still written).

#### Status change timestamps via TryUpdateVisitStatus

```
TryUpdateVisitStatus_SetsStatusChangedAtFromOccurredAt
```
Create a job with a `Scheduled` visit. Call `TryUpdateVisitStatus(visitId, InProgress, occurredAt)`.
Verify `visit.StatusChangedAt == occurredAt`.

#### Status change timestamps via TryUpdateVisitStatusByWorker

```
TryUpdateVisitStatusByWorker_Success_SetsStatusChangedAtFromOccurredAt
```
Create a job with a `Scheduled` visit. Call `TryUpdateVisitStatusByWorker`.
Verify `visit.StatusChangedAt == occurredAt`.

```
TryUpdateVisitStatusByWorker_Blocked_DoesNotChangeTimestamps
```
Create a job with two visits (one InProgress, one Scheduled). Try to set the
second to InProgress (blocked). Verify `StatusChangedAt` and `UpdatedAt` on
the blocked visit are unchanged.

### 7.2 Test patterns

All new tests follow existing patterns in `JobTests.cs`:
- Use `CreateJob()` and `CreateVisitInput()` helpers
- Use `DefaultOccurredAt` for `occurredAt` parameter
- Use FluentAssertions (`Should().Be()`, `Should().NotBeNull()`)
- Group assertions per visit with `job.Visits!.Single()` or `job.Visits!.Single(v => v.Id == TestVisitId)`

For `UpdatedAt` assertions, use `Should().NotBeNull()` and
`Should().BeCloseTo(DateTimeOffset.UtcNow, precision: TimeSpan.FromSeconds(5))`
since it is set internally by `DateTimeOffset.UtcNow`.

---

## Execution Checklist

| # | Task | Files | Status |
|---|------|-------|--------|
| 1.1 | Add `UpdatedAt`, `StatusChangedAt` to `Visit` | `Visit.cs` | done |
| 1.2 | Update `Visit.Update()` — single `occurredAt` param | `Visit.cs` | done |
| 1.3 | Update `Visit.UpdateStatus()` — single `occurredAt` param | `Visit.cs` | done |
| 1.4 | Update `Visit.Create()` — set both timestamps | `Visit.cs` | done |
| 2.1 | Pass `occurredAt` in `Job.UpdateVisits()` | `Job.cs` | done |
| 2.2 | Thread `occurredAt` in `Job.TryUpdateVisitStatus()` | `Job.cs` | done |
| 2.3 | Thread `occurredAt` in `Job.TryUpdateVisitStatusByWorker()` | `Job.cs` | done |
| 3.1 | Pass `GetClientEventTime()` in Jobs controller | `JobsController.cs` | done |
| 3.2 | Fix `_jobsRepository.Update()` to use server time | `UpdateVisitStatusCommandHandler.cs` | done |
| 4.1 | Add `OccurredAt` to `WorkerUpdateVisitStatusCommand` | `WorkerUpdateVisitStatusCommand.cs` | done |
| 4.2 | Pass `GetClientEventTime()` in Worker controller | `WorkerController.cs` | done |
| 4.3 | Update Worker handler — use `command.OccurredAt` | `WorkerUpdateVisitStatusCommandHandler.cs` | done |
| 5.1 | Add EF Core column mappings | `VisitConfiguration.cs` | done |
| 5.2 | Generate migration | `20260211124924_AddVisitTimestamps.cs` | done |
| 6.1 | Add `StatusChangedAt` to contract DTOs | `VisitDtos.cs`, `WorkerVisitDtos.cs` | done |
| 6.2 | Add `StatusChangedAt` to API response DTOs | `VisitDtos.cs`, `WorkerVisitsPagedResponse.cs` | done |
| 6.3 | Add `StatusChangedAt` to `WorkerVisitData` + repository | `WorkerVisitData.cs`, `JobsRepository.cs` | done |
| 6.4 | Update mapping logic | mapping files | done |
| 7.1 | Visit timestamp unit tests | `JobTests.cs` | todo |
