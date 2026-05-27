# WEB-1402: Visit Numbering

## Visit Numbering

Each visit within a job now receives a sequential `Number` (1-based). The number is used to identify visits in activity/timeline entries and when displaying all attachments of a job to distinguish which visit each attachment belongs to.

### How numbering works

The job computes the next number on demand:

```
NextVisitNumber = Max(existing visit numbers) + 1
```

- If no visits exist, the first visit gets number `1`.
- The number is assigned at creation time inside `Job.UpdateVisits()`.
- `VisitInput.Number` can override the auto-calculated value; if omitted, `NextVisitNumber()` is used.
- Once assigned, a visit's number is never updated.

### Migration

The `AddVisitNumber` migration adds a non-nullable `Number` column to visits and backfills existing rows using `ROW_NUMBER()` ordered by `DateTime` per job.

A SQL update of all existing records was chosen over lazy assignment on read because the current number of visit records is small enough to handle in a single migration. With a larger dataset this approach would be impractical and we would need to assign numbers lazily on read (treating `0`/`null` as "not yet numbered"), which adds complexity to every query path.

### Corner case: deleted visit number reuse

When the last visit is deleted and a new visit is created, the new visit **will receive the same number** as the deleted one.

**Example:**
1. Job has visits #1, #2, #3.
2. Visit #3 is deleted (removed from the collection).
3. `NextVisitNumber()` computes `Max(1, 2) + 1 = 3`.
4. The newly created visit gets number **#3** again.

This is by design. The numbering is based on the maximum number among currently existing visits, not a monotonically increasing counter. Numbers are not guaranteed to be unique across the lifetime of a job -- only unique among visits that exist at the same time.