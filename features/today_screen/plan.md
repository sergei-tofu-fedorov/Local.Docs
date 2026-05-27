# Today Screen — Backend Implementation Plan

## Summary

The backend provides two endpoints to support the Today screen:

- `GET /api/v3/visits?startsFrom=<utc>` — list of visits from a UTC instant onwards (forward window, no upper bound).
- `PATCH /api/v3/jobs/{jobId}/visits/{visitId}/worker` — targeted worker assign / reassign / unassign on a single visit.

The backend takes the boundary as a UTC `startsFrom` filter and stays timezone-agnostic.

Where it lives:

- Gateway controllers + request/response DTOs — `Src/Invoices.Api/Controllers/`, `Src/Invoices.Api/Dto/`.
- CQRS query/command + handlers — `Src/Jobs/Jobs.Contracts/`, `Src/Jobs/Jobs.Application/`.
- New domain method on the `Job` aggregate — `Src/Jobs/Jobs.Domain/Models/Job.cs`.

## Current State

- **Overdue check on a visit** — already implemented in the domain. `Visit.IsOverdue(now)` returns `Status != Completed && DateTime < now` (`Src/Jobs/Jobs.Domain/Models/Visit.cs:64-71`). No `Duration` field on the entity, so overdue triggers exactly at `Visit.DateTime`. Reused by the new list endpoint.
- **Worker assign/unassign on a visit** — possible today only through a full job upsert. `UpsertJobCommandHandler` (`Src/Jobs/Jobs.Application/Commands/UpsertJobCommandHandler.cs`) detects the worker change inside `Job.UpdateVisits` diff and raises `VisitWorkerChangedEvent` (`JobEventType.VisitWorkerChanged = 22`). No targeted endpoint.
- **Thin point actions on jobs** — there is a precedent for "small payload → dispatch command" actions: `POST /api/v3/jobs/from-estimate` (`Src/Invoices.Api/Controllers/JobsController.cs:246-258`) dispatches via `IHandlerDispatcher`. The new worker action follows the same pattern.
- **Excluding deleted jobs from list queries** — handled by the existing `JobSpecifications` (used by paged/sync queries) reading `Job.IsDeleted` (`Job.cs:55`). Reused as-is.

### Gaps

- **List of visits in a window** — not exposed by the gateway. The dashboard does not render a visit list today; the only existing path that returns visits is `GET /api/v3/jobs/paged` (jobs with nested visits).
- **Targeted worker assign/unassign endpoint** — does not exist.
- **Derived `IsOverdue` on the admin visit DTO** — missing. The current `VisitDto` (`Src/Invoices.Api/Dto/Jobs/VisitDtos.cs:7-18`) has no such field.

## Changes by Layer

Numbered sections also define execution order: each step builds on the previous.

### 1. Application — `GetVisitsQuery` + handler

**New files**:
- `Src/Jobs/Jobs.Contracts/Jobs/Queries/GetVisitsQuery.cs`
- `Src/Jobs/Jobs.Application/Queries/GetVisitsQueryHandler.cs`

```
record GetVisitsQuery(
    string AccountId,
    DateTimeOffset StartsFrom)    // UTC, inclusive
    : IQuery<VisitsResult>

record VisitsResult(IReadOnlyList<VisitListItem> Items)

record VisitListItem(
    Guid VisitId, Guid JobId, int JobVersion,
    string? JobTitle, string ClientId, string? ClientName,
    DateTimeOffset DateTime, string? AssignedWorkerId,
    VisitListItemStatus Status)
    // JobVersion is exposed so the worker-assign PATCH can be issued without a separate Job lookup

enum VisitListItemStatus { Scheduled, InProgress, Completed, Overdue }
```

Handler shape:

```
1. visits = jobsRepo.GetVisitsFrom(accountId, StartsFrom)
   // SQL: !Job.IsDeleted && Visit.DateTime >= StartsFrom,
   //      ORDER BY DateTime, Id
2. resolve client names for items whose Job has no ClientSnapshot
   (batch via IJobClientsService.GetClientsByIds)
3. items = visits.Select(MapToItem)
4. return new VisitsResult(items)
```

`MapToItem` derives status via `Visit.IsOverdue(utcNow) ? Overdue : Map(Visit.Status)` — reusing the existing domain method, no new logic. Aggregate counts (total / completed / overdue) are not returned by the endpoint.

### 2. Application — `AssignWorkerToVisitCommand` + handler + `Job.TryUpdateVisitWorker`

**New files**:
- `Src/Jobs/Jobs.Contracts/Jobs/Commands/AssignWorkerToVisitCommand.cs`
- `Src/Jobs/Jobs.Application/Commands/AssignWorkerToVisitCommandHandler.cs`

**Modified**: `Src/Jobs/Jobs.Domain/Models/Job.cs` — add public `TryUpdateVisitWorker(visitId, workerId, team, occurredAt)` that delegates to the existing private `UpdateAssignedWorker` (raises `VisitWorkerChangedEvent`, refreshes computed fields).

```
record AssignWorkerToVisitCommand(
    string AccountId, Guid JobId, Guid VisitId,
    string? WorkerId, int Version,
    DateTimeOffset? OccurredAt, string? MasterUserId)
    : CommandBase, ICommand<AssignWorkerToVisitResult>

record AssignWorkerToVisitResult(VisitDto Visit)
```

Handler shape — targeted mutation, modelled on `UpdateVisitStatusCommandHandler`:

```
1. if (WorkerId != null && MasterUserId == null)
       throw ArgumentException("MasterUserId required to assign a worker")
2. job = jobsRepo.GetJobForUpdate(accountId, JobSpecifications.ById(JobId))
        ?? throw JobNotFound
3. job.ValidateVersion(command.Version)
4. visit = job.Visits?.FirstOrDefault(v => v.Id == VisitId)
        ?? throw VisitNotFound
5. team = workerService.GetTeam(accountId, MasterUserId)
6. if (job.TryUpdateVisitWorker(VisitId, WorkerId, team, occurredAt)) {
       jobsRepo.Update(job)
       jobDomainEventService.Save(job, MasterUserId, ActorType, occurredAt)
       unitOfWork.SaveChanges()
   }
7. return new AssignWorkerToVisitResult(visit.ToVisitDto())
```

The wrap-`UpsertJobCommand` alternative was rejected — `Job.UpdateVisits` already exposes `UpdateAssignedWorker` which raises `VisitWorkerChangedEvent`; a thin domain method on `Job` is the same machinery without the upsert overhead.

### 3. Api gateway — `VisitsController`

**New files**:
- `Src/Invoices.Api/Controllers/VisitsController.cs`
- `Src/Invoices.Api/Dto/Visits/VisitsResponseDto.cs`
- `Src/Invoices.Api/Dto/Visits/VisitListItemDto.cs`
- `Src/Invoices.Api/Dto/Visits/VisitListItemStatusDto.cs`

```
[ApiVersion("3.0")]
[Route("api/[controller]")]
public class VisitsController : BaseController
    [HttpGet("all")]
    GetVisits([FromQuery] DateTimeOffset startsFrom)
        → DispatchQuery(new GetVisitsQuery(AccountId, startsFrom))
        → ToResponseDto
```

The action lives at `/all` so the bare `/api/v3/visits` route stays free for a future paginated default. This endpoint returns the full forward-window in a single response (no pagination, no server cap); pagination, when needed, will land on the bare route as a separate action with cursor + `pageSize`, without breaking `/all`.

Status is serialised as lower-camelCase (`scheduled | inProgress | completed | overdue`) consistent with other v3 enums.

### 4. Api gateway — `JobsController.AssignWorker`

**Modified**: `Src/Invoices.Api/Controllers/JobsController.cs`.
**New file**: `Src/Invoices.Api/Dto/Jobs/AssignWorkerRequestDto.cs`.

```
[HttpPatch("{jobId:guid}/visits/{visitId:guid}/worker")]
AssignWorker(jobId, visitId, AssignWorkerRequestDto body):
    cmd = new AssignWorkerToVisitCommand(
        AccountId, jobId, visitId, body.WorkerId, body.Version,
        ClientEventTime, MasterUserId)
    result = dispatcher.DispatchCommand(cmd)
    return Ok(result.Visit.ToApi())

class AssignWorkerRequestDto
    string? WorkerId           // null = unassign
    required int Version
```

Returns the updated `VisitDto`.

## Behaviour

### `GET /api/v3/visits/all?startsFrom=<utc>`

- Authenticated. `startsFrom` is a UTC `DateTimeOffset`, inclusive.
- Returns the full forward-window in a single response — no `take`/`pageSize` parameter, no server cap, no `nextToken`.
- Returns visits ordered ASC by `DateTime` (then by `Id` as a stable tie-breaker). Excludes visits whose parent `Job.IsDeleted == true`.
- `status` is derived per item: `Visit.IsOverdue(utcNow) ? overdue : map(Visit.Status)`.
- Adding an `endsBefore` parameter later is a non-breaking extension. Cursor pagination, when needed, will land on the bare `GET /api/v3/visits` route — that segment is reserved.

Example response:

```json
{
  "items": [
    {
      "visitId": "8c2...",
      "jobId": "1d1...",
      "jobVersion": 7,
      "jobTitle": "AC tune-up",
      "clientId": "c1a9...",
      "clientName": "Michael Johnson",
      "dateTime": "2026-04-29T14:30:00Z",
      "assignedWorkerId": null,
      "status": "scheduled"
    }
  ]
}
```

### `PATCH /api/v3/jobs/{jobId}/visits/{visitId}/worker`

- `WorkerId = null` means unassign.
- `Version` is the optimistic-concurrency token from the caller's last `JobDto`.
- Domain side-effects (`VisitWorkerChangedEvent`, activity timeline entry) are emitted via the existing `Job.UpdateVisits` diff.
- Unknown `WorkerId` (e.g. user no longer in team): `Job.UpdateVisits` already silently drops it. The endpoint surfaces this as 200 + visit without worker — consistent with existing behaviour for stale upserts.

Errors follow the existing gateway convention (see `Src/Invoices.Api/Middleware/ApiExceptionHandlingMiddleware.cs`): `EntityNotFoundException` and `VersionMismatchException` are returned as **HTTP 200 with an `error.code` envelope**, not as semantic 404/409. Real 4xx codes are reserved for `ArgumentException` (400).

| Condition | Exception | HTTP | `error.code` |
|---|---|---|---|
| Job not found | `EntityNotFoundException` | 200 | `not_found` |
| Visit not found in job | `EntityNotFoundException` | 200 | `not_found` |
| `Version` is stale | `VersionMismatchException` | 200 | `version_mismatch` (payload includes `actualVersion`, `submittedVersion`) |
| `WorkerId` non-null, `MasterUserId` missing | `ArgumentException` | 400 | `bad_request` |

## Backward Compatibility

- All changes are additive: new controller, new action, new DTOs, new query, new command. No data migrations.
- Existing `VisitDto` is unchanged — derived `status` lives only on the new list-item DTO.
- No new permissions; access mirrors existing job-read / job-write rights.

## Testing

### `Invoices.Backend` — Unit (`tests/Invoices.Backend.UnitTests`)

- `VisitListItemMapperTests` — `Visit.Status` mapping, `IsOverdue` overrides to `overdue`, sort order ASC by `DateTime`.
- `AssignWorkerToVisitCommandHandlerTests` — happy-path assign / unassign / reassign, stale `Version` → `VersionMismatchException`, unknown `VisitId` → `EntityNotFoundException`, unknown `WorkerId` → silently dropped.

### `Invoices.Backend` — Functional (`tests/Invoices.Backend.FunctionalTests`)

- `GET /api/v3/visits?startsFrom=<utc>`:
  - No matching visits → `items=[]`.
  - Mixed statuses (`Scheduled`, `InProgress`, `Completed`) + one past-time visit → `overdue` derivation.
  - Soft-deleted job's visits excluded.
  - Visits strictly before `startsFrom` excluded; visits at exact `startsFrom` included.
- `PATCH /api/v3/jobs/{jobId}/visits/{visitId}/worker`:
  - Assign / reassign / unassign happy paths return the updated `VisitDto`.
  - Stale `Version` → 200 + `error.code=version_mismatch`.
  - Unknown `VisitId` or `JobId` → 200 + `error.code=not_found`.
  - Unknown `WorkerId` → 200, visit returned without worker.
  - `WorkerId` non-null without `MasterUserId` → 400 + `error.code=bad_request`.
