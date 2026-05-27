Visit Photo Attachments — Worker Implementation Plan
=====================================================

Worker-specific endpoint for updating a visit with attachments.
Based on [attachments_worker.md](../../flows/attachments_worker.md)
flow doc and [overview.md](overview.md) for DTOs and business rules.

Shared domain logic (Job aggregate, content services) is in
[implementation_common.md](implementation_common.md).
Web endpoints are in
[implementation_web.md](implementation_web.md).

Product Requirements (from brief)
----------------------------------

### Entry flow

1. Photo upload always in context of the visit
2. Camera capture or device gallery — both supported, camera is default
3. Tagging (Before/After) is optional, can be done at upload or later. Default is untagged — no friction if tech skips
4. Upload happens in background — tech doesn't wait, workflow continues
5. Upload state clearly communicated: Uploading → Synced → Failed. Failed state includes one-tap retry
6. Gentle nudge on visit completion: "Add a photo before finishing?" — dismissible, not a gate

### What the tech sees

- Photos in flat chronological order within the visit (no date grouping)
- Tagged photos (Before/After) grouped within chronological flow
- Tech sees all photos on that visit — own and manager's

### Access rules

Tech's photo access is scoped to visit assignment. Unassign from
visit → lose access to its photos. Photos live inside the visit,
they do not float independently.

### Constraints

- No hard product-level photo limit
- 20 photos soft max — informative notification + analytics event, not a wall

### Design decisions (from brief)

- No grouping by date — chronological ordering as default sort, no date headers
- No Before/After grouping in v1 — tagging is metadata, not workflow. Flat gallery at visit level. Revisit in v1.1 based on tagging adoption data
- Every extra tap costs adoption — upload reachable in 2 taps from visit screen, nudge dismissible in 1 tap

---

Worker-Specific Requirements
-----------------------------

### Access control

Worker can only update visits they are assigned to.
Handler validates `visit.AssignedWorkerId == command.WorkerId`
before any mutation. If the check fails → `WorkerAccessDeniedException` (403).

Additionally, the handler resolves the worker's `TeamMember` via
`team.GetWorkerOrThrow(workerId)` to confirm the caller holds the
**Worker** role in the account team. Admin-role callers are rejected
(they use the manager endpoint instead).

### Mutable fields

Worker can change **only**:

| Field | Mutable | Notes |
|-------|---------|-------|
| Status | Yes | Scheduled → InProgress → Completed |
| Attachments | Yes | Full-state diff (add, remove, retag) |
| DateTime | No | Preserved from current visit state |
| AssignedWorkerId | No | Preserved — worker cannot reassign |

The handler ignores any `DateTime` value sent by the client and
carries over the existing `visit.DateTime` into the `VisitInput`.

### actorId vs TeamMember

`actorId` (`string?`) flows into `Attachment.CreatedBy` on new
attachments. In the worker handler this is `command.WorkerId`.

The `TeamMember` record (`Id`, `Name`, `Role`) is available from the
resolved team. We **do not** replace the domain-level `actorId`
parameter with `TeamMember` because:

| Reason | Detail |
|--------|--------|
| Domain API stability | `Job.UpdateVisit(…, actorId)` is used by manager, worker, and internal flows. Changing the signature touches all callers |
| `CreatedBy` is a string | The attachment stores a plain user ID, not a typed member reference |
| Role check belongs in the handler | The handler calls `team.GetWorkerOrThrow(workerId)` to enforce role. Domain methods stay role-agnostic |

The handler uses `TeamMember` for **validation** (role check) and
`TeamMember.Id` as the `actorId` value — best of both worlds without
domain changes.

---

Goal
----

Give the worker app a single endpoint to update a visit including
its attachments. The worker sends the full desired state of
attachments for the visit — the server diffs against current state,
same full-state diff approach as the manager's `PUT /api/jobs`.

### Why a single update-visit endpoint (not separate POST/DELETE/PATCH)

| Reason | Detail |
|--------|--------|
| Same diff pattern as manager | Full-state `attachments[]` array — server diffs against current. Consistent mental model across both surfaces |
| Simpler client implementation | One endpoint covers add, remove, retag, and reorder. Worker sends desired state after each local change |
| Offline-friendly | Client accumulates local edits, sends final state on sync. No need to queue individual add/delete/retag operations |
| Fewer endpoints to maintain | One worker command + handler instead of three |

### Why a separate worker command (not reusing `UpdateVisitCommand`)

| Reason | Detail |
|--------|--------|
| Different lookup | Worker sends `visitId` (not `jobId`). Handler resolves job via `JobSpecifications.ByVisitId` |
| Worker assignment validation | Domain validates `visit.AssignedWorkerId == workerId` before any mutation. Manager has no such check |
| Different intent | Worker updating "my visit" is a different business operation than manager editing any visit. CQRS recommends separate commands for distinct intents ([reference](https://lostechies.com/jimmybogard/2016/06/01/cqrs-and-rest-the-perfect-match/)) |
| Follows established pattern | `WorkerUpdateVisitStatusCommand` already exists as a separate command from `UpdateVisitStatusCommand` |
| No changes to existing commands | Manager flow untouched. No optional fields, no branching in existing handler |

---

Step 1: Command + Contract
---------------------------

**Project:** Jobs.Contracts

```
WorkerUpdateVisitCommand(
    AccountId:   string,
    WorkerId:    string,
    Visit:       WorkerVisitUpdateDto,
    OccurredAt?: DateTimeOffset
) : ICommand<JobUpdateResult>

JobUpdateResult(JobVersion: int)
```

### WorkerVisitUpdateDto

| Field | Type | Notes |
|-------|------|-------|
| VisitId | Guid | Target visit (in DTO, not top-level command) |
| JobVersion | int | Job.Version for 409 check (in DTO, not top-level command) |
| Status | VisitStatusDto | Scheduled, InProgress, Completed |
| Attachments | AttachmentInputDto[] | Required (non-nullable). Full-state array |

No `DateTime` — worker cannot change visit schedule (preserved from current state).
No `AssignedWorkerId` — worker cannot reassign visits.
`Attachments` is required — worker always sends the full desired state.

---

Step 2: Command Handler
------------------------

**Project:** Jobs.Application (Worker namespace)

Handler reuses the same shared services as `UpdateVisitCommandHandler`:
`IJobContentService`, `IJobWorkerService`, `IJobDomainEventService`.
Content diff + link + unlink logic is identical — the domain methods
and services are shared, only the orchestration differs.

```
FUNCTION Handle(command) → JobUpdateResult

    visitId ← command.Visit.VisitId

    ── 1. Load job by visitId ──

    job ← LOAD job via JobSpecifications.ByVisitId(visitId)
        THROW EntityNotFoundException IF not found

    CALL job.ValidateVersion(command.Visit.JobVersion)

    ── 2. Sanitize tags ──

    CALL TagParser.SanitizeTags(logger, command.Visit.Attachments)

    ── 3. Resolve worker + validate assignment ──

    occurredAt ← command.OccurredAt ?? UtcNow
    worker ← workerService.GetTeamMember(command.AccountId, command.WorkerId)
    updatedStatus ← command.Visit.Status.ToDomain()
    CALL job.ValidateVisitUpdateByWorker(visitId, command.WorkerId, updatedStatus)
        — checks visit exists, worker assignment, status transition rules

    ── 4. Content diff + link ──

    attachments ← command.Visit.Attachments mapped to domain AttachmentInput[]
    contentDiff ← job.ComputeVisitContentDiff(visitId, attachments)
    skippedContentIds ← contentService.LinkContentAsync(contentDiff.Added)
    attachments ← attachments.RemoveSkippedContent(skippedContentIds)

    ── 5. Apply domain update ──

    job.UpdateVisitByWorker(visitId, worker, updatedStatus, attachments, occurredAt)
        .LogWarnings(logger)

    ── 6. Persist ──

    repository.Update(job)
    eventService.Save(job, command.WorkerId, ActorType.User, occurredAt)
    unitOfWork.SaveChangesAsync()

    ── 7. Unlink removed content ──

    contentService.UnlinkContentAsync(contentDiff.Removed)

    ── 8. Return ──

    RETURN JobUpdateResult(job.Version)
```

### Shared logic with UpdateVisitCommandHandler

| Concern | Mechanism | Shared? |
|---------|-----------|---------|
| Content diff | `job.ComputeVisitContentDiff()` | Extension method — shared |
| Content link/unlink | `IJobContentService` | Service — shared |
| Tag sanitization | `TagParser.SanitizeTags()` | Utility — shared |
| Skipped content removal | `attachments.RemoveSkippedContent()` | Extension — shared |
| Job lookup by visitId | `JobSpecifications.ByVisitId` | Specification — shared with `WorkerUpdateVisitStatusCommandHandler` |
| Worker resolution | `IJobWorkerService.GetTeamMember()` | Service — **new** |
| Visit update | `job.UpdateVisitByWorker()` | Domain method — **new** (delegates to `UpdateVisitStatusByWorker` + `ApplyAttachmentUpdates`) |
| Assignment + status validation | `job.ValidateVisitUpdateByWorker()` | Domain method — **new** |

---

Step 3: Worker Controller Endpoint
------------------------------------

**Project:** Invoices.Api (WorkerController)

```
PUT /api/worker/visits/{visitId}

Request {
    jobVersion:     int
    status:         VisitStatusDto
    attachments:    AttachmentInputDto[]    ← required (non-nullable)
}

Response (200) {
    jobVersion:   int
}
```

```
FUNCTION UpdateVisit(visitId, request)
    workerId ← RESOLVE from GetWorkerId()
    command ← MAP request TO WorkerUpdateVisitCommand
        SET WorkerId = workerId
        SET Visit.VisitId = visitId
        SET Visit.JobVersion = request.JobVersion
        SET Visit.Status = request.Status
        SET Visit.Attachments = request.Attachments mapped to contract DTOs
        SET OccurredAt = GetClientEventTime()
    result ← DISPATCH command
    RETURN 200 with { jobVersion }
```

---

Step 4: Read Endpoints — Attachments in Responses
---------------------------------------------------

### GET /api/worker/visits — paged list

Attachments included in paged response for offline support.
Mobile clients cache full visit list with attachments on sync.

```
FUNCTION GetVisits(workerId, query)
    visits ← LOAD visits assigned to worker (with attachments)
    CALL EnrichAttachments(visits.attachments)
    RETURN paged response
```

### GET /api/worker/visits/{id} — detail

```
FUNCTION GetVisitDetails(visitId, workerId)
    visit ← LOAD visit with job + attachments
    IF visit.assignedWorkerId != workerId THEN RETURN 403
    CALL EnrichAttachments(visit.attachments)
    RETURN visit detail
```

### PATCH /worker/visits/{id}/status — includes attachments

Status change response includes attachments for nudge UX
(prompt worker to add photos after completing a visit).

---

Step 5: Worker Request/Response DTOs
--------------------------------------

**Project:** Invoices.Api (Worker.Dto namespace)

### WorkerUpdateVisitRequestDto

| Field | Type | Notes |
|-------|------|-------|
| JobVersion | int | Job.Version for 409 check |
| Status | VisitStatusDto | |
| Attachments | AttachmentInputDto[] | Required (non-nullable). Full-state array |

Reuses existing `AttachmentInputDto` from manager DTOs — same shape,
same contract.

### Worker response

Returns `JobCommandResponseDto { jobVersion }` — same as manager
attachment endpoints. CQRS pattern: command returns acknowledgment,
client re-fetches via GET for updated state.

---

Key Design Decisions
---------------------

| Decision | Reason |
|----------|--------|
| Single PUT visit endpoint (not POST/DELETE/PATCH) | Full-state diff — same pattern as manager. Worker sends desired attachments array, server diffs. Simpler client, fewer endpoints |
| Separate `WorkerUpdateVisitCommand` | Different intent (worker vs manager), different lookup (visitId vs jobId), different validation (assignment check). CQRS recommends separate commands for distinct intents. Follows existing `WorkerUpdateVisitStatus` pattern |
| Shared services, separate domain method | Services (`IJobContentService`) and utilities (`TagParser`, `RemoveSkippedContent`) are shared. Domain has `UpdateVisitByWorker` which delegates to `UpdateVisitStatusByWorker` + `ApplyAttachmentUpdates` |
| visitId in route (not jobId) | Worker thinks in visits, not jobs. Handler resolves job via `JobSpecifications.ByVisitId` — same pattern as `WorkerUpdateVisitStatusCommandHandler` |
| Validation via `ValidateVisitUpdateByWorker` | Domain method validates visit exists, worker assignment, and status transition rules. Called before content diff |
| `GetTeamMember` (not `GetTeam`) | Handler resolves single `TeamMember` via `workerService.GetTeamMember()`. Worker's Id is used as actorId for attachment CreatedBy |
| `actorId` stays as `string?` | Domain uses `actorId` for `Attachment.CreatedBy`. Handler passes `worker.Id` from the resolved `TeamMember`. No domain API change needed |
| `ComputeVisitContentDiff` (not `ComputeContentDiff`) | Single-visit content diff method takes visitId + attachments directly. Avoids building a full `VisitInput` just for content comparison |
| Returns `JobUpdateResult` (not visit) | CQRS: command returns version only. Client re-fetches via GET for updated visit state |
| DateTime preserved from current visit | Worker cannot change visit schedule — only status and attachments. Handler ignores client-sent DateTime and carries over `visit.DateTime` |
| No `AssignedWorkerId` in request | Worker cannot reassign visits — preserved from current state |
| Version required on all writes | Same 409 concurrency model as all other write paths |
| Reuse `AttachmentInputDto` | Same DTO shape for both manager and worker — no duplication of contract types |
| Attachments non-nullable | Worker always sends full state. No `null` = "don't touch" ambiguity |
