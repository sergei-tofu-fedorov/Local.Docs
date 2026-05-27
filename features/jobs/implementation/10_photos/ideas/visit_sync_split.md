Visit-Level Sync — Plan A
=========================

Status: **proposal** — evaluate after v1 attachment feature ships.

Problem
-------

Every attachment change bumps `Job.SequenceId`, forcing all sync
clients to re-download the entire job graph (visits, items,
attachments). A single photo add on one visit triggers a full
re-sync of a job that may have 20 visits with 20 photos each.

Solution
--------

Add `SequenceId` to Visits. Two independent sync streams:

```
GET /api/jobs/sync?lastSequenceId=X     → jobs without visits
GET /api/visits/sync?lastSequenceId=X   → visits with attachments
```

Client syncs both streams independently, merges by `JobId` locally.

Database Changes
----------------

### Add SequenceId to Visits

```sql
-- Sequence (shared across all visits, monotonically increasing)
CREATE SEQUENCE jobs.visit_sequence_id;

ALTER TABLE jobs."Visits"
    ADD COLUMN "SequenceId" BIGINT NOT NULL DEFAULT 0;

-- Trigger: auto-assign on insert and update
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

Updated schema:

```
jobs."Visits"
├── "Id"                UUID          PK
├── "JobId"             UUID          FK → Jobs(Id)
├── "DateTime"          TIMESTAMPTZ
├── "AssignedWorkerId"  TEXT
├── "Status"            INTEGER
├── "StatusChangedAt"   TIMESTAMPTZ
├── "UpdatedAt"         TIMESTAMPTZ
└── "SequenceId"        BIGINT        auto-increment trigger   ← NEW

Indexes:
├── PK on (Id)
├── IX on (JobId, DateTime)
└── IX on (SequenceId)     ← NEW (for sync queries)
```

### EF Core configuration

```csharp
// VisitConfiguration.cs — add:
builder.Property(v => v.SequenceId)
    .ValueGeneratedOnAddOrUpdate()
    .HasColumnName("SequenceId");
```

### Visit entity

```csharp
// Visit.cs — add:
public long SequenceId { get; private set; }
```

When does Visit.SequenceId bump?
--------------------------------

The PG trigger fires on INSERT and UPDATE to Visits. This covers:

| Operation | Visit.SequenceId bumps? | Why |
|-----------|:----------------------:|-----|
| Visit created | Yes | INSERT trigger |
| Visit status changed | Yes | UPDATE trigger |
| Worker assigned | Yes | UPDATE trigger |
| Attachment added (POST) | Depends | See below |
| Attachment deleted (DELETE) | Depends | See below |
| Attachment metadata updated (PATCH) | Depends | See below |

**Attachment operations and Visit.SequenceId:**

Attachment endpoints use `_jobsRepository.Update(job)` which marks
the entire graph as Modified. EF issues UPDATE on the visit row
(even if only attachments changed) → trigger fires → SequenceId
bumps. This is correct behavior — the visit's content changed, so
sync clients should re-fetch it.

If `_context.Update(job)` is replaced with granular change tracking
(future optimization), the visit row might NOT be updated for
attachment-only changes. In that case, the handler must explicitly
touch the visit:

```csharp
visit.UpdatedAt = DateTimeOffset.UtcNow;  // forces UPDATE → trigger
```

New Endpoint: GET /api/visits/sync
-----------------------------------

```csharp
[HttpGet("visits/sync")]
[MapToApiVersion("3.0")]
public async Task<VisitsSyncResponse> SyncVisits(
    [FromQuery] long lastSequenceId,
    [FromQuery] int pageSize = 50,
    CancellationToken ct = default)
{
    var visits = await _jobsRepository.GetVisitsChangedSince(
        AccountId, lastSequenceId, pageSize, ct);

    return new VisitsSyncResponse
    {
        Visits = visits.Select(v => v.ToSyncDto()).ToArray()
    };
}
```

### Repository method

```csharp
public async Task<IReadOnlyList<Visit>> GetVisitsChangedSince(
    string accountId,
    long lastSequenceId,
    int pageSize,
    CancellationToken ct)
{
    return await _context.Visits
        .Where(v => v.Job.AccountId == accountId)
        .Where(v => v.SequenceId > lastSequenceId)
        .OrderBy(v => v.SequenceId)
        .Take(pageSize)
        .Include(v => v.Attachments)
        .Include(v => v.Job)
        .AsNoTracking()
        .ToListAsync(ct);
}
```

### Sync DTO

```csharp
public class VisitSyncDto
{
    public required Guid Id { get; set; }
    public required Guid JobId { get; set; }
    public required long SequenceId { get; set; }
    public required DateTimeOffset DateTime { get; set; }
    public string? AssignedWorkerId { get; set; }
    public required VisitStatusDto Status { get; set; }
    public DateTimeOffset? StatusChangedAt { get; set; }
    public IReadOnlyList<VisitAttachmentDto>? Attachments { get; set; }
}
```

Changes to Existing Job Sync
-----------------------------

`GET /api/jobs/sync` stops including visits in the response.
Returns job-level data only (title, number, status, items, relations).

```csharp
// Before: job with visits
{ id, sequenceId, title, visits: [{...}, {...}] }

// After: job without visits
{ id, sequenceId, title, visitIds: ["id1", "id2"] }
```

`visitIds` allows client to know which visits belong to the job
without fetching visit details. Visit details come from visit sync.

**Breaking change** — existing mobile clients expect visits in job
sync. Migration options:
- New API version (v4) for split sync, keep v3 as-is
- Feature flag: `?includeVisits=true` (default true, opt-out)
- New endpoint: `GET /api/jobs/sync/v2` alongside existing

Client Sync Flow
----------------

```
Mobile app startup:
1. GET /api/jobs/sync?lastSequenceId=jobCursor    → job changes
2. GET /api/visits/sync?lastSequenceId=visitCursor → visit changes
3. Merge visits into jobs by JobId in local DB
4. Store both cursors for next sync

Periodic refresh:
- Poll both endpoints independently
- Job sync: infrequent (job structure rarely changes)
- Visit sync: frequent (attachments change often)
```

Deleted visits: When `Job.UpdateVisits()` removes a visit, the
visit row is deleted (CASCADE). Client detects missing visits by
comparing local visitIds against `job.visitIds` from job sync.

Limitations
-----------

Plan A only improves the **sync/read** path. The **write** path
is unchanged:

- Worker attachment POST still loads the full Job aggregate
- `_jobsRepository.Update(job)` still marks the entire graph
  as Modified and bumps Job.Version
- Two workers on different visits still conflict on Job.Version
- Adding a photo still loads all 20 visits + all their attachments

To improve the write path, see:
- `scoped_visit_update.md` — load single visit, bypass aggregate
  (incremental optimization, same architecture)
- `visit_aggregate_split.md` (Plan D) — Visit as its own aggregate
  with own Version (full architectural solution)

Impact Assessment
-----------------

| Area | Change |
|------|--------|
| Database | Add SequenceId column + sequence + trigger + index |
| Visit entity | Add SequenceId property |
| EF config | Add SequenceId mapping |
| Repository | Add GetVisitsChangedSince method |
| Controller | Add visits/sync endpoint |
| Job sync | Remove visits from response (breaking) |
| Mobile client | Two sync streams + local merge |
| Web app | No change (doesn't use sync) |
