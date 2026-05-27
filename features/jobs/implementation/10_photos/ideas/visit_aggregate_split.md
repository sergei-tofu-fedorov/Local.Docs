Visit as Separate Aggregate — Plan D
=====================================

Status: **proposal** — long-term architectural direction. Evaluate
after v1 attachment feature and sync split (Plan A) ship.

Problem
-------

Visit is a child entity of the Job aggregate. Every visit mutation
loads the full Job graph, bumps Job.Version, and goes through
`_jobsRepository.Update(job)`. This creates:

- **Unnecessary coupling** — photo add on visit 3 loads all 20 visits
- **Version contention** — worker A adds photo, worker B changes
  status → conflict on Job.Version even though they touch different
  visits
- **Growing aggregate** — attachments make the Job graph heavier
  with each photo, increasing load times for all write paths

Solution
--------

Extract Visit into its own aggregate root. Job and Visit become
peers with a foreign key relationship but independent lifecycles.

```
Before:
  Job (aggregate root)
  ├── Visits[] (child entities)
  │   └── Attachments[]
  ├── Items[]
  └── Relations

After:
  Job (aggregate root)         Visit (aggregate root)
  ├── Items[]                  ├── Attachments[]
  ├── Relations                ├── JobId (FK, not navigation)
  └── VisitIds[] (read-only)   ├── Version (own concurrency token)
                               └── SequenceId (own sync cursor)
```

Domain Model Changes
--------------------

### Visit as aggregate root

```csharp
// Visit.cs — becomes aggregate root
public class Visit : AggregateRoot
{
    public required Guid Id { get; init; }
    public required Guid JobId { get; init; }
    public int Version { get; private set; }
    public long SequenceId { get; private set; }
    public DateTimeOffset DateTime { get; private set; }
    public string? AssignedWorkerId { get; private set; }
    public VisitStatus Status { get; private set; }
    public DateTimeOffset? UpdatedAt { get; private set; }
    public DateTimeOffset? StatusChangedAt { get; private set; }
    public ICollection<VisitAttachment>? Attachments { get; internal set; }

    // No Job navigation property — only JobId reference

    public void ValidateVersion(int expectedVersion)
    {
        if (Version != expectedVersion)
            throw new ConcurrencyException(
                $"Visit {Id} version mismatch: expected {expectedVersion}, actual {Version}");
    }

    public static Visit Create(
        Guid id, Guid jobId, DateTimeOffset dateTime,
        VisitStatus status, string? workerId, DateTimeOffset occurredAt)
    {
        var visit = new Visit
        {
            Id = id,
            JobId = jobId,
            DateTime = dateTime,
            Status = status,
            AssignedWorkerId = workerId,
            StatusChangedAt = occurredAt,
            UpdatedAt = DateTimeOffset.UtcNow
        };

        visit.RaiseDomainEvent(VisitDomainEvent.Created(id, jobId, dateTime, workerId));
        return visit;
    }

    public bool UpdateStatus(VisitStatus newStatus, DateTimeOffset occurredAt)
    {
        if (Status == newStatus) return false;
        var previous = Status;
        Status = newStatus;
        UpdatedAt = DateTimeOffset.UtcNow;
        StatusChangedAt = occurredAt;
        RaiseDomainEvent(VisitDomainEvent.StatusChanged(Id, JobId, previous, newStatus));
        return true;
    }

    public void AddAttachments(
        IReadOnlyList<VisitAttachmentInput> inputs,
        string createdBy)
    {
        Attachments ??= new List<VisitAttachment>();

        foreach (var input in inputs)
        {
            var attachment = new VisitAttachment
            {
                Id = Guid.NewGuid(),
                VisitId = Id,
                Visit = this,
                Type = input.Type,
                ContentId = input.ContentId,
                CapturedAt = input.CapturedAt,
                CreatedBy = createdBy
            };

            if (input.Metadata is { } meta)
                attachment.UpdateMetadata(meta);

            Attachments.Add(attachment);

            if (input.Type == AttachmentType.Photo)
                RaiseDomainEvent(VisitDomainEvent.PhotoAdded(
                    Id, JobId, attachment.Id, DateTime, input.Metadata?.Tag));
        }
    }

    public void RemoveAttachment(Guid attachmentId, string deletedBy)
    {
        var attachment = Attachments?.FirstOrDefault(a => a.Id == attachmentId)
            ?? throw new InvalidOperationException($"Attachment {attachmentId} not found");

        Attachments!.Remove(attachment);

        if (attachment.Type == AttachmentType.Photo)
            RaiseDomainEvent(VisitDomainEvent.PhotoDeleted(
                Id, JobId, attachment.Id, DateTime, deletedBy));
    }

    public void UpdateAttachmentMetadata(Guid attachmentId, AttachmentMetadata metadata)
    {
        var attachment = Attachments?.FirstOrDefault(a => a.Id == attachmentId)
            ?? throw new InvalidOperationException($"Attachment {attachmentId} not found");

        attachment.UpdateMetadata(metadata);
    }
}
```

### Visit domain events

```csharp
public sealed class VisitDomainEvent : IDomainEvent
{
    public Guid VisitId { get; }
    public Guid JobId { get; }
    public VisitEventType EventType { get; }
    public object Payload { get; }

    // Factory methods
    public static VisitDomainEvent Created(...);
    public static VisitDomainEvent StatusChanged(...);
    public static VisitDomainEvent WorkerChanged(...);
    public static VisitDomainEvent PhotoAdded(...);
    public static VisitDomainEvent PhotoDeleted(...);
}

public enum VisitEventType
{
    Created = 1,
    StatusChanged = 2,
    WorkerChanged = 3,
    PhotoAdded = 10,
    PhotoDeleted = 11
}
```

### Simplified Job aggregate

```csharp
public class Job : AggregateRoot
{
    // No Visits collection — only visit management via IDs
    public required Guid Id { get; init; }
    public string AccountId { get; init; }
    public int Version { get; private set; }
    public long SequenceId { get; private set; }
    public string? Title { get; private set; }
    public string? Number { get; private set; }
    public JobManualStatus ManualStatus { get; private set; }
    public JobItem[]? Items { get; set; }
    public JobRelations Relations { get; set; }
    public ClientSnapshot? ClientSnapshot { get; set; }

    // Job no longer manages visits directly
    // Visit creation/deletion coordinated by application service
}
```

Database Changes
----------------

### Visit gets own Version + SequenceId

```sql
ALTER TABLE jobs."Visits"
    ADD COLUMN "Version" INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN "SequenceId" BIGINT NOT NULL DEFAULT 0;

-- Version trigger
CREATE OR REPLACE FUNCTION jobs.increment_visit_version()
RETURNS TRIGGER AS $$
BEGIN
    NEW."Version" = OLD."Version" + 1;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER visit_version_increment
    BEFORE UPDATE ON jobs."Visits"
    FOR EACH ROW
    EXECUTE FUNCTION jobs.increment_visit_version();

-- SequenceId trigger
CREATE SEQUENCE jobs.visit_sequence_id;

CREATE OR REPLACE FUNCTION jobs.set_visit_sequence_id()
RETURNS TRIGGER AS $$
BEGIN
    NEW."SequenceId" = nextval('jobs.visit_sequence_id');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER visit_sequence_id_trigger
    BEFORE INSERT OR UPDATE ON jobs."Visits"
    FOR EACH ROW
    EXECUTE FUNCTION jobs.set_visit_sequence_id();
```

### EF configuration

```csharp
// VisitConfiguration.cs — Visit is now its own aggregate root
builder.Property(v => v.Version)
    .HasDefaultValue(0)
    .IsConcurrencyToken()          // YES — Visit has own concurrency now
    .ValueGeneratedOnAddOrUpdate()
    .HasColumnName("Version");

builder.Property(v => v.SequenceId)
    .ValueGeneratedOnAddOrUpdate()
    .HasColumnName("SequenceId");
```

Visit.Version IS a concurrency token here (unlike Plan A) because
Visit is its own aggregate — `_context.Update(visit)` only marks
the visit and its attachments as Modified, not the entire job graph.

Repository Changes
------------------

### New IVisitsRepository

```csharp
public interface IVisitsRepository
{
    Task<Visit?> GetById(string accountId, Guid visitId, CancellationToken ct);
    Task<Visit?> GetForUpdate(string accountId, Guid visitId, CancellationToken ct);
    void Insert(Visit visit);
    void Update(Visit visit);
    void Delete(Visit visit);

    Task<IReadOnlyList<Visit>> GetByJobId(
        string accountId, Guid jobId, CancellationToken ct);

    Task<IReadOnlyList<Visit>> GetChangedSince(
        string accountId, long lastSequenceId, int pageSize, CancellationToken ct);

    // Worker-specific
    Task<Visit?> GetWorkerVisit(
        string accountId, Guid visitId, string workerId, CancellationToken ct);
    Task<WorkerVisitsPagedData> GetWorkerVisitsPaged(
        string accountId, string workerId, int pageSize,
        VisitStatus[]? statusFilter, DateTimeOffset? cursorDateTime,
        Guid? cursorVisitId, CancellationToken ct);
}
```

### Simplified IJobsRepository

```csharp
public interface IJobsRepository
{
    Task<Job?> GetById(string accountId, Guid jobId, CancellationToken ct);
    Task<Job?> GetJobForUpdate(string accountId, Specification<Job> spec, CancellationToken ct);
    void Insert(Job job);
    void Update(Job job);
    // No visit-related methods — moved to IVisitsRepository
}
```

Handler Changes
---------------

### Worker attachment handlers — much simpler

```csharp
public class AddVisitAttachmentsHandler
    : ICommandHandler<AddVisitAttachmentsCommand, AddVisitAttachmentsResult>
{
    private readonly IVisitsRepository _visitsRepository;
    private readonly IContentsService _contentsService;
    private readonly IVisitDomainEventService _eventService;
    private readonly IUnitOfWork _unitOfWork;

    public async Task<AddVisitAttachmentsResult> Handle(
        AddVisitAttachmentsCommand command, CancellationToken ct)
    {
        // Load ONLY the visit — not the entire job
        var visit = await _visitsRepository.GetForUpdate(
            command.AccountId, command.VisitId, ct)
            ?? throw new EntityNotFoundException(...);

        // Permission check
        if (visit.AssignedWorkerId != command.WorkerId)
            throw new WorkerAccessDeniedException(...);

        // Domain logic on Visit aggregate directly
        visit.AddAttachments(command.Inputs, command.WorkerId);

        // Content linking
        foreach (var input in command.Inputs.Where(i => i.ContentId != null))
            await _contentsService.LinkExistingContent(
                command.AccountId, visit.Id.ToString(),
                ContentEntities.Visit, input.ContentId!, ct);

        // Save — only visit + attachments, NOT job
        _visitsRepository.Update(visit);
        _eventService.Save(visit, command.WorkerId, ActorType.User);
        await _unitOfWork.SaveChangesAsync(ct);

        return new AddVisitAttachmentsResult(visit.ToDto());
    }
}
```

Key difference: `_visitsRepository.Update(visit)` marks only the
visit entity as Modified. No job loading, no Job.Version bump.

### Job upsert handler — orchestrates visits separately

```csharp
public async Task<UpsertJobResult> Handle(UpsertJobCommand command, CancellationToken ct)
{
    // 1. Upsert job (without visits)
    var job = await UpsertJob(command, ct);

    // 2. Sync visits separately
    var existingVisits = await _visitsRepository.GetByJobId(
        command.AccountId, job.Id, ct);
    var visitChanges = DiffVisits(existingVisits, command.Visits, job.Id);

    foreach (var added in visitChanges.ToAdd)
        _visitsRepository.Insert(added);
    foreach (var updated in visitChanges.ToUpdate)
        _visitsRepository.Update(updated);
    foreach (var removed in visitChanges.ToRemove)
        _visitsRepository.Delete(removed);

    // 3. Save all in one transaction (same DbContext/UnitOfWork)
    await _unitOfWork.SaveChangesAsync(ct);

    return new UpsertJobResult(job.ToDto());
}
```

Job and visits saved in the same transaction but with independent
version tracking. Job.Version only bumps if job fields changed.
Visit.Version bumps per-visit.

API Changes
-----------

### Sync endpoints

```
GET /api/jobs/sync?lastSequenceId=X     → jobs (no visits)
GET /api/visits/sync?lastSequenceId=X   → visits with attachments
```

### Worker endpoints — scoped to Visit aggregate

```
GET    /api/worker/visits                        → list (unchanged)
GET    /api/worker/visits/{id}                   → detail (unchanged)
PATCH  /api/worker/visits/{id}/status            → uses Visit.Version
POST   /api/worker/visits/{id}/attachments       → no version needed
DELETE /api/worker/visits/{id}/attachments/{id}   → no version needed
PATCH  /api/worker/visits/{id}/attachments/{id}   → no version needed
```

Worker status PATCH now validates Visit.Version instead of
Job.Version — scoped to the visit being modified.

### Manager endpoints

```
PUT  /api/jobs                     → job fields + visit diff
GET  /api/jobs/{id}                → job + visits (read-only join)
GET  /api/jobs/{id}/timeline       → merged job + visit events
```

Job status derivation
---------------------

Currently `Job.EffectiveStatus` is computed from visits in
`RefreshComputedFields()`. With split aggregates, two options:

**A. Computed on read (query-time):**

```csharp
// Query handler joins job + visits to derive status
var visits = await _visitsRepository.GetByJobId(accountId, jobId, ct);
var effectiveStatus = JobStatusCalculator.Calculate(job.ManualStatus, visits);
```

No stored status on Job — computed fresh each time.

**B. Eventual consistency (event-driven):**

When a visit status changes, it raises `VisitStatusChanged` event.
An event handler updates `Job.ComputedStatus` asynchronously:

```csharp
public class VisitStatusChangedHandler : INotificationHandler<VisitStatusChanged>
{
    public async Task Handle(VisitStatusChanged notification, CancellationToken ct)
    {
        var visits = await _visitsRepository.GetByJobId(notification.JobId, ct);
        var job = await _jobsRepository.GetForUpdate(notification.JobId, ct);
        job.RefreshStatus(visits);
        _jobsRepository.Update(job);
        await _unitOfWork.SaveChangesAsync(ct);
    }
}
```

Option A is simpler. Option B avoids loading visits on every job
read but introduces eventual consistency lag.

Concurrency — What Changes
----------------------------

| Scenario | Before (one aggregate) | After (split) |
|----------|----------------------|---------------|
| Two workers, different visits | Conflict on Job.Version | No conflict — independent Visit.Versions |
| Two workers, same visit | Conflict on Job.Version | Conflict on Visit.Version |
| Worker + manager on same visit | Conflict on Job.Version | Conflict on Visit.Version |
| Worker photo + manager title | Conflict on Job.Version | No conflict — different aggregates |
| Manager renames job while worker adds photo | 409 (Job.Version) | Both succeed (different aggregates) |

Timeline / Activity Feed
-------------------------

Visit events stored with `JobId` for aggregation. The job timeline
endpoint queries both job events and visit events:

```csharp
// GetJobTimelineQueryHandler — merge two event sources
var jobEvents = await _jobEventsRepo.GetByJobId(jobId, ct);
var visitEvents = await _visitEventsRepo.GetByJobId(jobId, ct);
var merged = jobEvents.Concat(visitEvents)
    .OrderByDescending(e => e.OccurredAt);
```

Migration Strategy
------------------

This is a large refactor. Recommended phased approach:

**Phase 1: Dual-write**
- Add Version + SequenceId to Visits
- Visit handlers update BOTH job and visit
- No behavior change, just infrastructure

**Phase 2: Read split**
- Sync endpoints read from Visit.SequenceId
- Job sync stops including visits
- Mobile client updated to dual-sync

**Phase 3: Write split**
- Visit handlers stop updating Job
- `_visitsRepository.Update(visit)` replaces
  `_jobsRepository.Update(job)` for visit operations
- Job.Version stops bumping for visit changes

**Phase 4: Cleanup**
- Remove visit navigation from Job entity
- Remove visit loading from Job repository
- Job becomes lightweight

Impact Assessment
-----------------

| Area | Effort | Risk |
|------|:------:|:----:|
| Visit entity → aggregate root | Medium | Low |
| New IVisitsRepository | Medium | Low |
| Worker handlers refactor | Medium | Low |
| Job upsert handler refactor | High | Medium |
| Job status derivation | Medium | Medium |
| Timeline event merge | Low | Low |
| Mobile client dual-sync | High | Medium |
| Existing test rewrite | High | Low |
| Migration (phased) | High | Medium |

**Total effort: Large (2-3 sprints)**

When to Implement
-----------------

Trigger: version contention between workers becomes a measurable
problem — frequent 409s on concurrent visit operations, or job sync
payload size exceeds acceptable threshold.

Don't implement preemptively. Plan A (visit-level SequenceId)
solves the sync problem without the aggregate split. Plan D is for
when the concurrency model itself becomes the bottleneck.
