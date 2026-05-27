Scoped Visit Update — Performance Optimization
================================================

Status: **deferred** — implement only if production metrics show
full aggregate loading is a bottleneck for the photo PATCH path.

Problem
-------

The photo PATCH handler loads the full Job aggregate (Job + ALL
visits + ALL attachments) to update photos on a single visit.
At scale (20 visits x 20 photos = 400 attachment rows), this
loads data the handler never reads.

Current path: `GetJobForUpdate` → full aggregate → mutate one
visit → `_context.Update(job)` → save.

Proposed path: load Job + single Visit + its Attachments only.

Approach
--------

Load the visit directly with its parent job, bypassing the
aggregate root loading pattern.

```csharp
public async Task<Visit> GetVisitForPhotoUpdate(
    string accountId, Guid visitId, CancellationToken ct)
{
    return await _context.Visits
        .Include(v => v.Job)
        .Include(v => v.Attachments)
        .Where(v => v.Id == visitId)
        .Where(v => v.Job.AccountId == accountId)
        .Where(v => !v.Job.IsDeleted)
        .FirstOrDefaultAsync(ct)
        ?? throw new EntityNotFoundException(...);
}
```

The handler works with the Visit directly, not through Job
aggregate methods:

```csharp
var visit = await _repo.GetVisitForPhotoUpdate(...);
var job = visit.Job;

job.ValidateVersion(command.Version);
// ... permission checks, paid/archived check ...

DiffPhotos(visit, command.Photos, command.MasterUserId);

// Touch job row → PG trigger bumps Job.Version
job.UpdatedAt = DateTimeOffset.UtcNow;
_context.Entry(job).State = EntityState.Modified;

await _unitOfWork.SaveChangesAsync(ct);
```

What this saves
---------------

| | Full aggregate | Scoped visit |
|--|:-:|:-:|
| SQL queries | Job + all Visits + all Attachments + Summary | Job + 1 Visit + its Attachments |
| Rows loaded | ~400 (worst case) | ~20 (worst case) |
| Data transferred | ~40KB | ~2KB |
| EF change tracking | Entire graph | 1 Job + 1 Visit + N photos |

Constraints
-----------

**MUST NOT** call any Job aggregate methods on a partially loaded
graph. The following are unsafe with a scoped load:

```
job.UpdateVisits()          — diffs full visits array, would delete unloaded visits
job.RefreshComputedFields() — derives status from all visits
job.Visits.Count            — returns 1 instead of actual count
```

Photo diff logic must be extracted into a standalone method that
operates on a single Visit, not routed through the Job aggregate.

**MUST** touch the job row to bump Job.Version:

```csharp
job.UpdatedAt = DateTimeOffset.UtcNow;
_context.Entry(job).State = EntityState.Modified;
```

Without this, the PG trigger on `jobs."Jobs"` won't fire and
Job.Version won't increment. Sync clients would miss the change.

Domain events must be raised manually (not through
`AggregateRoot.RaiseDomainEvent`) since the Job aggregate isn't
driving the mutation.

DDD considerations
------------------

This breaks the aggregate boundary. Job is the aggregate root;
all mutations should go through it. The scoped approach bypasses
that guarantee.

Acceptable here because:
- Photo updates have no cross-visit invariants
- No business rule depends on the full set of visits during
  a photo mutation
- The aggregate boundary for photos is effectively Visit, not Job
- Job.Version bump is mechanical (trigger), not domain logic

Not acceptable if future rules require cross-visit checks during
photo operations (e.g., "max N photos per job" as a hard limit).

When to implement
-----------------

Trigger: photo PATCH p95 latency exceeds acceptable threshold,
AND profiling confirms the aggregate load (not content URL
enrichment or GCS calls) is the bottleneck.

Until then, the full aggregate path (~40KB, <1ms from PG index)
is simpler and follows existing patterns.
