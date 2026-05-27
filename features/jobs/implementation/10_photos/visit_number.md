Visit Number — Auto-Incrementing Identifier
=============================================

Add a human-readable `Number` (int) to visits, auto-assigned per job.

Goal
----

Visits need a stable, sequential label for UI display and timeline
messages (e.g. "Visit 3"). The number is assigned on creation and
never changes — even if earlier visits are deleted.

Domain Model
------------

| Field | Type | Notes |
|-------|------|-------|
| Number | int | 1-based, per-job, immutable after creation |

**Assignment rule**: `max(existing visit numbers) + 1`, or `1` if no
visits exist. Gaps are allowed (Visit 1, 2, 5 is valid after
deletions). Number is never reused or reassigned.

### Limitation: no soft-delete for visits

Visits are hard-deleted (removed from the collection during upsert).
This means if the last visit (e.g. Visit 3) is deleted and a new visit
is added, it will also receive number 3 — the server has no memory of
the deleted visit's number.

This is acceptable because visit numbers are only used on the visit
edit page as a human-readable label. They do not appear in activity
feed events or timeline history, so a recycled number cannot cause
confusion in historical context.

Introducing soft-delete solely for visit numbering would require
changes across all clients (mobile upsert must filter out soft-deleted
visits, paged endpoints must exclude them, etc.) — disproportionate
effort for a cosmetic label.

Implementation
--------------

### Visit entity

Add `Number` property to `Visit`:

```
public int Number { get; private set; }
```

Set in `Visit.Create()` — requires the next number as parameter.

### Job.UpdateVisits — number assignment

```
── In the "new visit" branch of UpdateVisits ──
SET number ← input.Number ?? NextVisitNumber()
newVisit ← Visit.Create(..., number: number)

FUNCTION NextVisitNumber
    RETURN (Visits.Count > 0 ? Visits.Max(Number) : 0) + 1
```

If the client provides a number (upsert), use it. Otherwise
auto-assign `max + 1` (web endpoints that create visits implicitly).
Existing visits keep their number — it is never updated.

Note: `Job.Visits` is non-nullable (`ICollection<Visit>` with field
initializer `= new List<Visit>()`). All null-forgiving operators (`!`)
and null-conditional access (`?.`) on `Visits` have been removed.

### Database

Add column to Visits table:

```sql
ALTER TABLE jobs."Visits" ADD COLUMN "Number" integer NOT NULL DEFAULT 0;
```

Backfill existing visits (order by DateTime within each job):

```sql
WITH numbered AS (
    SELECT "Id",
           ROW_NUMBER() OVER (PARTITION BY "JobId" ORDER BY "DateTime") AS rn
    FROM jobs."Visits"
)
UPDATE jobs."Visits" v
SET "Number" = n.rn
FROM numbered n
WHERE v."Id" = n."Id";
```

Migration: `20260403090649_AddVisitNumber`.

### DTOs

Add `number` field to:
- `VisitDto` (response) — `int`, always present
- `VisitInputDto` (contract, upsert request) — `int?`, optional; when provided, used as-is (client is source of truth for upsert). When omitted, server auto-assigns
- `VisitInputDto` (API) — `int?`, optional; mapped through to contract layer

### EF Configuration

```
builder.Property(v => v.Number)
    .HasColumnType("integer")
    .IsRequired();
```

Key Design Decisions
--------------------

| Decision | Reason |
|----------|--------|
| Client-provided on upsert, auto-assigned otherwise | Upsert is the client's full-state sync — client owns the number. Web endpoints (UpdateVisit, etc.) don't create visits, so auto-assign is the fallback for edge cases |
| Per-job scope (not global) | "Visit 3" is meaningful in context of a job |
| Hard-delete, no soft-delete for visits | Soft-delete would guarantee unique numbers but requires client-side changes across all platforms. Visit numbers are only shown on the edit page (not in activity feed), so occasional reuse after deleting the last visit is acceptable |
| Max + 1 (not count + 1) | Handles gaps from deletions correctly |
| Immutable after creation | Number is a stable reference — renumbering would break timeline history |
| Backfill by DateTime | Best approximation of creation order for existing visits |
| `Visits` collection non-nullable | All query paths use `.Include()`, constructor initializes to `new List<Visit>()` — eliminates null-forgiving/conditional operators across the codebase |
