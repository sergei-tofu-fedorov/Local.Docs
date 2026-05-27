Visit Photo Attachments — Web Implementation Plan
===================================================

Web-only endpoints for adding, deleting, and retagging visit-level
attachments. These are **not used by mobile** — mobile uses
`PUT /api/jobs` (see [implementation_common.md](implementation_common.md)).

Based on [attachments_manager_web.md](../../flows/attachments_manager_web.md)
flow doc.

Goal
----

Give the web app dedicated endpoints for attachment management:
- **PUT** — update a visit (properties + optional attachment diff)
- **POST** — add photos to a visit (after GCS upload)
- **DELETE** — remove a single photo
- **PATCH** — retag a photo (Before/After)

These avoid the full job PUT for single-attachment operations, and
match the Stripe/GitHub pattern of sub-resource CRUD.

---

Step 1: Commands + Contracts
-----------------------------

**Project:** Jobs.Contracts

All four commands extend `CommandBase(AccountId, MasterUserId)` and
return a shared **`JobUpdateResult(int JobVersion)`** — the minimum
the client needs for optimistic concurrency on subsequent requests.
`ActorType` is inherited from `CommandBase`.

### UpdateVisitCommand

| Field | Type | Notes |
|-------|------|-------|
| AccountId | string | From CommandBase |
| JobId | Guid | |
| Version | int | Job.Version for 409 check |
| Visit | VisitInputDto | Includes optional attachments array |
| OccurredAt | DateTimeOffset? | Client event time |
| MasterUserId | string? | From CommandBase |

### AddVisitAttachmentsCommand

| Field | Type | Notes |
|-------|------|-------|
| AccountId | string | |
| JobId | Guid | |
| VisitId | Guid | Target visit |
| Version | int | Job.Version for 409 check |
| MasterUserId | string? | |
| Attachments | AttachmentInputDto[] | Client-pregenerated IDs |

### DeleteAttachmentCommand

| Field | Type | Notes |
|-------|------|-------|
| AccountId | string | |
| JobId | Guid | |
| VisitId | Guid | |
| AttachmentId | Guid | |
| Version | int | |
| MasterUserId | string? | |

### UpdateAttachmentTagsCommand

| Field | Type | Notes |
|-------|------|-------|
| AccountId | string | |
| JobId | Guid | |
| VisitId | Guid | |
| AttachmentId | Guid | |
| Version | int | |
| Tags | string[] | Full replacement (empty = clear) |
| MasterUserId | string? | |

---

Step 2: Command Handlers
-------------------------

**Project:** Jobs.Application

### UpdateVisitHandler

```
FUNCTION Handle(command)
    job ← LOAD job for update
    job.ValidateVersion(command.version)
    IF visit has attachments THEN
        CALL TagParser.SanitizeTags(logger, visit.attachments)

    visitInput ← command.Visit.ToDomain()

    ── Content linking: diff → link → remove skipped ──
    contentDiff ← job.ComputeContentDiff([visitInput])
    skippedContentIds ← contentService.LinkContentAsync(contentDiff.Added)
    visitInput ← visitInput.RemoveSkippedContent(skippedContentIds)

    ── Domain: update visit properties + optional attachment diff ──
    team ← workerService.GetTeam(accountId, masterUserId)
    job.UpdateVisit(visitId, visitInput, team, occurredAt, actorId: masterUserId)
        .LogWarnings(logger)

    CALL repository.Update(job)
    CALL domainEventService.Save(job, masterUserId, actorType, occurredAt)
    CALL unitOfWork.SaveChanges()
    CALL contentService.UnlinkContentAsync(contentDiff.Removed)

    RETURN JobUpdateResult(job.Version)
```

### AddVisitAttachmentsHandler

```
FUNCTION Handle(command)
    job ← LOAD job for update
    job.ValidateVersion(command.version)
    CALL TagParser.SanitizeTags(logger, command.attachments)

    inputs ← command.Attachments mapped to domain AttachmentInput[]

    ── Content linking: collect entries → link → remove skipped ──
    newContentEntries ← inputs WHERE content IS NOT NULL
    skippedContentIds ← contentService.LinkContentAsync(newContentEntries)
    inputs ← inputs.RemoveSkippedContent(skippedContentIds)

    ── Domain: directly append new attachments ──
    CALL job.AddVisitAttachments(visitId, inputs, masterUserId ?? "")
        .LogWarnings(logger)
        ← validates paid, appends with auto-order, raises PhotoAdded events

    CALL repository.Update(job)
    CALL domainEventService.Save(job, masterUserId, actorType, utcNow)
    CALL unitOfWork.SaveChanges()

    RETURN JobUpdateResult(job.Version)
```

### DeleteAttachmentHandler

```
FUNCTION Handle(command)
    job ← LOAD job for update
    job.ValidateVersion(command.version)

    ── Domain: remove attachment, get removed entity back ──
    removed ← job.RemoveAttachment(visitId, attachmentId)
        ← validates paid, raises PhotoDeleted, returns Attachment?

    CALL repository.Update(job)
    CALL domainEventService.Save(job, masterUserId, actorType, utcNow)
    CALL unitOfWork.SaveChanges()

    ── Unlink content after successful save ──
    IF removed?.GetContentEntry() IS NOT NULL THEN
        CALL contentService.UnlinkContentAsync([entry])

    RETURN JobUpdateResult(job.Version)
```

### UpdateAttachmentTagsHandler

```
FUNCTION Handle(command)
    job ← LOAD job for update
    job.ValidateVersion(command.version)

    ── Parse and sanitize tags ──
    parsedTags ← TagParser.ParseTags(logger, command.tags)
        ← returns List<AttachmentTag>, unknown tags logged as warning and skipped

    ── Domain: update tags via aggregate root ──
    job.UpdateAttachmentTags(visitId, attachmentId, parsedTags)
        ← Job finds visit, Visit finds attachment (throws if not found)

    CALL repository.Update(job)
    CALL unitOfWork.SaveChanges()

    RETURN JobUpdateResult(job.Version)
```

No domain event service call — tag changes don't produce timeline events.

---

Step 3: Controller Endpoints
------------------------------

**Project:** Invoices.Api (JobsController)

All four endpoints return **`JobCommandResponseDto { jobVersion: int }`**.
Clients use the version for optimistic concurrency and re-fetch via
`GET /jobs/{id}` when they need updated state.

### PUT — update visit (properties + optional attachments)

```
PUT /api/jobs/{jobId}/visits/{visitId}

Request {
  version:        int
  dateTime:       DateTimeOffset
  status:         VisitStatusDto
  assignedWorkerId?: string
  attachments?:   AttachmentInputDto[]    ← null = don't touch
}

Response (200) { jobVersion: int }
```

### POST — add attachments

```
POST /api/jobs/{jobId}/visits/{visitId}/attachments

Request {
  version:      int
  attachments:  [{
    id:         Guid                  ← required, client-pregenerated
    content:    { id: string, properties?: { orientation? } }
    tags:       string[]              ← default []
    capturedAt?: DateTimeOffset
  }]
}

Response (200) { jobVersion: int }
```

Order is **server-assigned** — appended after existing, in array order.

### DELETE — remove attachment

```
DELETE /api/jobs/{jobId}/visits/{visitId}/attachments/{attachmentId}

Request { version: int }
Response (200) { jobVersion: int }
```

### PATCH — update tags

```
PATCH /api/jobs/{jobId}/visits/{visitId}/attachments/{attachmentId}

Request {
  version:  int
  tags?:    string[]              ← ["Before"], ["After"], or [] to clear; null = no change
}

Response (200) { jobVersion: int }
```

`tags` is nullable — `null` leaves tags unchanged, `[]` clears them.
No timeline event for tag changes (low-impact).

---

Step 4: Domain — Methods on Job Aggregate
-------------------------------------------

POST uses `Visit.AddAttachments` (direct append, no diff roundtrip).
DELETE and PATCH use targeted methods on Job that delegate to Visit.

`AttachmentsEditable` is a computed property: `EffectiveStatus != Paid`.

### AddVisitAttachments

```
FUNCTION AddVisitAttachments(visitId, inputs[], actorId)

    CALL ValidateAttachmentsEditable (THROW if paid)
    visit ← FIND visit by visitId (THROW if not found)
    events ← visit.AddAttachments(inputs, actorId)
        ← directly appends with auto-order, no diff
    RAISE events
```

### RemoveAttachment → Attachment?

```
FUNCTION RemoveAttachment(visitId, attachmentId) → Attachment?

    CALL ValidateAttachmentsEditable (THROW if paid)
    visit ← FIND visit by visitId (THROW if not found)
    (event, attachment) ← visit.DeleteAttachment(attachmentId)
    IF event IS NOT NULL THEN RAISE event
    RETURN attachment
```

Returns the removed `Attachment` entity (or `null` if not found).
The handler uses `removed.ContentId` for unlinking — no need to
navigate aggregate internals before removal.

### UpdateAttachmentTags

```
FUNCTION UpdateAttachmentTags(visitId, attachmentId, tags) → Attachment

    visit ← FIND visit by visitId (THROW if not found)
    attachment ← visit.UpdateAttachmentTags(attachmentId, tags)
        ← returns null if not found
    IF attachment IS NULL THEN THROW "Attachment not found"
    RETURN attachment
```

`Visit.UpdateAttachmentTags` returns `Attachment?` — the `Job`
aggregate root owns the exception. `Visit` (child entity) does not
depend on `Invoices.Core.Exceptions`.

---

Step 5: Domain Warnings
-------------------------

Attachment limit checking uses the FluentResults warning system
instead of throwing exceptions — exceeding the limit is non-fatal.

`Visit.AddAttachments` and `Visit.UpdateAttachments` call
`WithAttachmentLimitCheck()` which adds an `AttachmentLimitWarning`
to the result when attachment count exceeds `MaxAttachmentsPerVisit`
(= 20). The warning flows up through the FluentResults `Result`
to the handler, which logs it via `.LogWarnings(logger)`.

```
DomainWarning (abstract, extends FluentResults.Success)
  └── AttachmentLimitWarning { VisitId, Count, Limit }

ResultLoggingExtensions.LogWarnings<T>(result, logger)
  ← iterates result.Successes.OfType<DomainWarning>() and logs each
```

This keeps domain validation in the domain layer and logging in
the application layer. The result remains successful (warnings are
`Success` subclasses, not errors).

---

Key Design Decisions
---------------------

| Decision | Reason |
|----------|--------|
| All endpoints return `JobUpdateResult(Version)` | CQRS: commands return acknowledgment, not query data. Clients re-fetch via GET. Simplifies handlers (no content map resolution) |
| POST uses `AddAttachments` (direct append) | No diff roundtrip — directly appends with auto-order. Simpler than merging existing + new and running full-state diff |
| DELETE returns removed `Attachment` internally | Handler uses `removed.ContentId` for unlinking — no aggregate traversal needed before removal |
| PATCH is tags-only | Order changes go through PUT full-state diff |
| Server-assigned order on POST | New photos appended after existing — no client ordering on add |
| Version required on all writes | Same 409 concurrency model as PUT upsert |
| `TagParser` sanitization | Unknown tags logged and silently dropped in all handlers. `ParseTags` returns `List<AttachmentTag>` enum values |
| `Visit` does not throw exceptions | `Visit.UpdateAttachmentTags` returns `null` if not found — `Job` (aggregate root) owns the exception. Keeps `Visit` free of `Invoices.Core` dependency |
| `AttachmentLimitWarning` via FluentResults | Non-fatal — save succeeds, handler logs warning. Domain exposes `WithAttachmentLimitCheck()` on Visit, handler calls `.LogWarnings(logger)` |
| `ComputeContentDiff` as extension method | Extension on `Job?` in `ContentDiff.cs`. Returns `ContentEntry` objects with `AttachmentId` (not VisitId), enabling content properties passthrough |
| `tags` nullable in PATCH request | `null` means "don't change" vs `[]` means "clear all" — same semantics as attachments array in upsert |
| All handlers save domain events | Except UpdateAttachmentTags — tag changes are silent (no timeline event) |
