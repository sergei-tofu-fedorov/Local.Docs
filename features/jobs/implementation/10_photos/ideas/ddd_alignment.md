DDD Alignment — Visit Attachments
===================================

DDD analysis of the 10_photos implementation plans. Patterns from:
- **Evans** (DDD, 2003): Aggregates, Entities, VOs, Repositories,
  Bounded Contexts — sourced from "DDD Quickly" PDF
- **Vernon** (IDDD, 2013): Aggregate sizing, child versioning,
  relaxed concurrency — sourced from web research, not the PDF
- **Scooletz** (2016): Relaxed Optimistic Concurrency — web research

Reference: `Backend/HowTo/DDD.md`.

What Aligns Well
----------------

**Aggregate pattern.** Job is the aggregate root, Visit is a child
entity, VisitAttachment is a child of Visit. All mutations go through
the root. External code never holds a direct reference to a child.

**Factory method on root.** `Job.UpdateVisitAttachments()` creates
child entities and enforces invariants. The root controls child
creation — callers don't construct VisitAttachment directly.

**Domain events from the aggregate.** `PhotoAdded`/`PhotoDeleted`
are raised by the Job aggregate during domain mutations, not by the
application handler. Events belong to the domain layer.

**Repository per aggregate root.** One `IJobsRepository`, returns
fully reconstituted aggregates. No `IVisitAttachmentRepository`.

**Value Objects.** `AttachmentMetadata` (tag, text) is a VO — defined
by attributes, no identity, immutable from outside. Correct usage.

**Layered architecture.** Domain model has zero infrastructure
dependencies. Handler (application layer) orchestrates: loads
aggregate, calls domain methods, persists. Content linking
(infrastructure) stays in the handler.

---

Deviations and Improvement Opportunities
-----------------------------------------

### 1. Aggregate is too large **[Vernon]**

**DDD rule:** "Only include entities that MUST be consistent with
each other in the same transaction." (Vernon, IDDD — not in Evans PDF)

**Test:** "If I change child X, does any invariant on root or
sibling Y need to be checked?"

Adding a photo to visit 3 has no invariant relationship with visits
1, 2, 4–20 or with job title/items/status. Yet the current design
loads the entire Job graph (all visits + all attachments + summary +
items). Consequences:

- False concurrency conflicts (two workers, different visits → 409)
- Growing aggregate (20 visits × 20 photos = 400 attachment rows
  loaded for a single-visit mutation)
- Every write path pays the full load cost

The `scoped_visit_update.md` and `visit_aggregate_split.md` address
this at different levels of effort.

### 2. Job.Version bumps on all operations — should relax **[Vernon, Scooletz]**

**Vernon (IDDD Ch.10):** "When child entity changes have no
cross-entity invariants, the child can carry its own version. The
root version does NOT bump for child-only changes."

**Scooletz (Relaxed Optimistic Concurrency):** Skip the version CHECK
for commutative, idempotent operations. In event sourcing, append with
`ExpectedVersion.Any`.

Note: Evans' original book does not discuss versioning mechanics.
These are Vernon's and Scooletz's extensions.

Attachment operations are commutative (add A then B = add B then A)
and idempotent (delete X twice = delete X once). No aggregate-level
invariant governs the attachments collection. Per Vernon:

- `Job.Version` should **not bump** for attachment-only changes
- `Visit` should carry its own `Version` that **does bump**

Current state: worker endpoints already skip the app-level version
check (no version in request body). But EF still enforces
`Job.Version` at `SaveChanges()` because `_context.Update(job)` marks
the entire graph Modified.

### 3. `_context.Update(job)` marks entire graph Modified

Every write flow uses `_jobsRepository.Update(job)`, which marks all
entities in the graph as Modified — including visits and attachments
that weren't touched. EF issues UPDATE statements for unchanged rows.

Effects:
- PG triggers fire on unmodified visit rows (unnecessary SequenceId bumps)
- Job.Version always bumps, even for visit-only changes
- Larger UPDATE statements and more trigger overhead

Per DDD, only modified entities should be persisted. EF change
tracking can handle this if entities are loaded as tracked (not
detached) and mutated through navigation properties.

### 4. Domain events named as Job events, semantically belong to Visit

`JobDomainEvent.PhotoAdded(jobId, ...)` — the event is raised on the
Job aggregate but the action happened on a Visit. The `visitId` is in
the payload, not the event identity.

If Visit becomes its own aggregate (Plan D), these become
`VisitDomainEvent`. The current naming couples events to the wrong
concept. The `visit_aggregate_split.md` already models this transition.

### 5. Cross-database read breaks repository contract

**DDD rule:** "Repository returns fully reconstituted aggregates."

Currently: `JobsRepository` returns Job with attachments that have
`ContentId` but no URL. The handler calls `IContentsService` (MongoDB)
to enrich with URLs. The aggregate is returned incomplete.

This is an acceptable pragmatic compromise — URL is a read concern,
not domain state. The pure DDD approach would use a separate read
model / query service for composing both data sources. Not worth
fixing for v1, but worth noting for future read-model evolution.

### 6. VisitAttachment identity depends on API choice

**DDD rule:** "Does it need unique identity tracked over time? →
Entity. Defined entirely by attributes? → Value Object."

VisitAttachment has an ID, used for API referencing (delete by ID,
update by ID). This makes sense for Option A (granular endpoints).

If Option B (PUT collection) is chosen, individual attachment IDs
become less important — matching by `contentId` suffices. Attachments
could become Value Objects (matched by contentId, replaced as a set),
simplifying the model. Design coupling worth noting.

---

Per-Document Assessment
-----------------------

| Document | Alignment | Key DDD Issue |
|----------|:---------:|---------------|
| `overview.md` | Strong | Aggregate sizing not addressed |
| `db_structure.md` | Good | No Visit.Version column |
| [`attachments_worker.md`](../../../flows/attachments_worker.md) | Good | All ops bump Job.Version |
| `IMPLEMENTATION_PLAN.md` | Strong | `_context.Update(job)` full graph |
| `activity_feed.md` | Clean | Events named Job*, should be Visit* |
| `batch_upload.md` | Practical | Assumes Job.Version, no relaxed concurrency |
| `scoped_visit_update.md` | Correct | Acknowledges DDD boundary breach |
| `visit_sync_split.md` | Good | Solves read path, not write path |
| `visit_aggregate_split.md` | Most pure | Large effort, correctly deferred |

---

Evolution Path
--------------

### Phase 1: Ship v1 as designed

The aggregate is correct enough for the initial feature. Known
deviations are documented here.

### Phase 2: Add Visit.Version + relaxed concurrency

Non-breaking, additive change:

```sql
ALTER TABLE jobs."Visits"
    ADD COLUMN "Version" INTEGER NOT NULL DEFAULT 0;

CREATE TRIGGER visit_version_increment
    BEFORE UPDATE ON jobs."Visits"
    FOR EACH ROW
    EXECUTE FUNCTION jobs.increment_visit_version();
```

- Attachment endpoints check `Visit.Version`, not `Job.Version`
- Stop marking unmodified visits as Modified in EF
- `Job.Version` no longer bumps for attachment-only changes
- Per Vernon: root version unchanged, child version incremented

**Trigger:** When false 409s on concurrent visit operations become
noticeable, or when implementing admin visit-scoped endpoints.

### Phase 3: Visit-level sync split (Plan A)

Add `Visit.SequenceId` for independent sync stream. Natural
consequence of Phase 2 — if the root version doesn't bump for
attachment changes, the root's sync cursor doesn't either. Visit
needs its own cursor.

See `visit_sync_split.md`.

**Trigger:** Sync payload size or frequency becomes a problem
(one photo change re-syncs entire job graph).

### Phase 4: Full aggregate split (Plan D)

Visit as its own aggregate root with independent lifecycle.

See `visit_aggregate_split.md`.

**Trigger:** Version contention between workers is a measurable
production problem — frequent 409s on concurrent visit operations
even after Phase 2.

---

References
----------

- Evans, Eric. "Domain-Driven Design." Addison-Wesley, 2003.
- Vernon, Vaughn. "Implementing Domain-Driven Design." Addison-Wesley, 2013. Ch.10: Aggregates.
- Kulec, Szymon (Scooletz). "Relaxed Optimistic Concurrency." 2016.
- `Backend/HowTo/DDD.md` — compact DDD reference in this repo.
