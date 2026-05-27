Visit Photo Attachments — Implementation Plan
===============================================

Stage 10.1: visit-level photo attachments via `PUT /api/jobs` upsert.
Based on overview.md, db_structure.md, ordering.md, and
[attachments_manager.md](../../flows/attachments_manager.md) flow doc.

Goal
----

Allow workers and managers to attach photos to visits as proof of
work (before/after shots). Photos flow through the existing job
upsert — no new endpoints, no new sync mechanism. The client sends
photos as part of the full `visits[].attachments[]` array in
`PUT /api/jobs`, and the server diffs against current state.

### Why these approaches

| Choice | Why |
|--------|-----|
| Single `Attachments` table | One table for all attachment types (photo, future notes). `Type` discriminator keeps it extensible without schema changes |
| `smallint[]` for tags | GIN-indexed array column — compact, type-safe, fast containment queries. Avoids JSONB complexity for a simple enum list. [Reference](https://www.crunchydata.com/blog/tags-aand-postgres-arrays-a-purrfect-combination) |
| Full-state diff via PUT | Client sends desired state, server diffs. No partial updates, no merge conflicts. Same pattern as visits — consistent mental model |
| Client-pregenerated IDs | Enables idempotent retries and offline queuing — client can re-send the same PUT without creating duplicates. JobId and VisitId generated at API mapping boundary when not provided by client |
| Client-owned ordering + tags | Server stores what the client sends. No server-side reordering or tag logic — keeps domain simple, UI flexibility on the client |
| `JobContentService` for content ops | Content linking/unlinking extracted to a dedicated application service. Handler orchestrates: compute diff → link → remove skipped from input → apply domain → save → unlink |
| `ContentDiff` extension method | Pre-mutation content diff computed via `Job.ComputeContentDiff()` / `Job.ComputeVisitContentDiff()` extension methods. Returns `ContentDiff(Added, Removed)` |
| Link after domain, unlink after save | Domain applies first (records changes in `JobChanges`). New content linked after. Skipped content filtered from domain via `RemoveSkippedAttachments`. Removed content unlinked after `SaveChanges` — prevents dangling references |
| Skip missing content silently | If a photo's temp GCS blob is not found during link, the attachment input is removed from the input list via `RemoveSkippedContent` extension. Logged as warning. No hard failure — the client can retry on next PUT |
| `TagParser` sanitization | Unknown tag strings logged and dropped before mapping to domain. Mapping layer uses `Enum.Parse` safely — always runs after sanitization |
| Attachment diff inside UpdateVisits | Attachments are carried on `VisitInput` and diffed inside `Job.UpdateVisits()` via `ApplyAttachmentUpdates`. No separate handler method for attachment diffing |
| `DomainResult` for warnings | Domain methods return `DomainResult` carrying non-fatal `IDomainWarning` list. `AttachmentLimitWarning` is a domain warning, logged by application layer via `.LogWarnings()` extension |
| Soft 20-photo limit | `MaxAttachmentsPerVisit` constant in domain, `AttachmentLimitWarning` returned in `DomainResult`. No hard block — save proceeds |
| Null actorId → empty string | `ResolveActorId` falls back to `string.Empty` for accountId+signature auth where master user is not available. No exception thrown |
| Enrichment at API layer | Content URLs and creator names are resolved after save, not stored on the attachment. Avoids stale data and keeps the domain model clean |

---

Step 1: Database — Attachments Table
-------------------------------------

New `Attachments` table in Jobs PostgreSQL. Tags stored as `smallint[]`
with GIN index. No JSONB metadata — tags are a first-class column.

```sql
CREATE TABLE jobs."Attachments" (
    "Id"            UUID            PRIMARY KEY,
    "JobId"         UUID            NOT NULL,
    "VisitId"       UUID            NOT NULL REFERENCES jobs."Visits"("Id") ON DELETE CASCADE,
    "Type"          SMALLINT        NOT NULL,
    "ContentId"     TEXT,
    "Order"         INTEGER         NOT NULL DEFAULT 0,
    "Tags"          SMALLINT[]      NOT NULL DEFAULT '{}',
    "CapturedAt"    TIMESTAMPTZ,
    "CreatedBy"     TEXT,
    "CreatedAt"     TIMESTAMPTZ     NOT NULL DEFAULT now()
);

CREATE INDEX ix_attachments_job   ON jobs."Attachments" ("JobId");
CREATE INDEX ix_attachments_visit ON jobs."Attachments" ("VisitId");
CREATE INDEX ix_attachments_tags  ON jobs."Attachments" USING GIN ("Tags");
```

### Why `smallint[]` for tags

Backed by `AttachmentTag` enum (Before=1, After=2). GIN index enables
fast containment queries (`@>` operator). EF Core 8 + Npgsql maps
`List<AttachmentTag>` → `smallint[]` natively.
See [Tags and Postgres Arrays](https://www.crunchydata.com/blog/tags-aand-postgres-arrays-a-purrfect-combination).

### ContentEntities enum

Uses existing `JobAttachment = 3` for content linking (AttachmentId as EntityId).

---

Step 2: Domain Model
---------------------

### Attachment entity

| Field | Type | Notes |
|-------|------|-------|
| Id | Guid | PK, client-pregenerated |
| JobId | Guid | Always set (denormalized) |
| VisitId | Guid | FK → Visit, non-nullable |
| Type | AttachmentType | Photo=1 |
| ContentId | string? | Cross-DB ref to MongoDB Content |
| Order | int | Client-owned display order |
| Tags | List\<AttachmentTag\> | Before=1, After=2. Client-owned |
| CapturedAt | DateTimeOffset? | When taken |
| CreatedBy | string? | MasterUserId (nullable) |
| CreatedAt | DateTimeOffset | Server timestamp |

### VisitInput

`VisitInput` carries optional attachments for the diff:

| Field | Type | Notes |
|-------|------|-------|
| Id | Guid | Non-nullable — generated at API mapping boundary |
| DateTime | DateTimeOffset | |
| Status | VisitStatus | |
| AssignedWorkerId | string? | |
| Attachments | AttachmentInput[]? | `null` = don't touch, `[]` = delete all |

### Enums

```
AttachmentType: Unknown=0, Photo=1
AttachmentTag:  Unknown=0, Before=1, After=2
```

### ContentEntry

```
ContentEntry(AttachmentId: Guid, ContentId: string, Properties?: ContentAdditionalProperties)
```

Used for content linking/unlinking. `AttachmentId` is the EntityId
passed to `ContentEntities.JobAttachment`.

### Navigation properties

- `Visit.Attachments` — `required ICollection<Attachment>`, visit-level

---

Step 3: Domain Logic — Full-State Diff
----------------------------------------

Attachment diff is inlined in `Job.UpdateVisits()`. For each
visit with attachments, the method calls `ApplyAttachmentDiff`
in the same loop as visit create/update. `attachments: null` =
don't touch (backward compat). `attachments: []` = delete all.

Content diff is computed before domain mutations via extension
methods (`ComputeContentDiff`, `ComputeVisitContentDiff`), not
tracked inline during mutations. The handler orchestrates:
compute diff → link → remove skipped from input → apply domain
→ save → unlink.

```
FUNCTION UpdateVisits(incomingVisits[], team, occurredAt, actorId?) → DomainResult

    existingById ← INDEX visits BY id
    incomingIds ← COLLECT ids from incomingVisits

    FOR EACH input IN incomingVisits
        IF input.id IN existingById THEN
            CALL ApplyVisitUpdate(existing, input, team, occurredAt)
        ELSE
            CALL AddVisit(input, team, occurredAt)

        CALL ApplyAttachmentUpdates(visit, input.attachments, actorId, result)

    FOR EACH visit WHERE id NOT IN incomingIds
        REMOVE visit

    CALL RefreshComputedFields
    RETURN result with accumulated warnings
```

`Job.ApplyAttachmentUpdates` is a private method that delegates
to `Visit.UpdateAttachments` when attachments is not null:

```
FUNCTION ApplyAttachmentUpdates(visit, attachments?, actorId, result) → Result

    IF attachments IS NULL THEN RETURN result (don't touch)

    visitResult ← visit.UpdateAttachments(attachments, actorId, AttachmentsEditable)
    RAISE domain events from visitResult
    RETURN merged result with warnings
```

`Visit.UpdateAttachments` diffs existing vs incoming by ID using
inline LINQ (dictionary + set lookup):

```
FUNCTION Visit.UpdateAttachments(incoming[], actorId, attachmentsEditable) �� Result<events[]>

    existingById ← INDEX attachments BY id
    incomingIds ← COLLECT ids from incoming

    IF has new or removed AND NOT attachmentsEditable THEN THROW

    FOR EACH input IN incoming WHERE id IN existingById
        SET existing.order ← input.order
        SET existing.tags ← input.tags

    FOR EACH input IN incoming WHERE id NOT IN existingById
        CREATE attachment FROM input
        IF type = Photo THEN ADD PhotoAdded event

    FOR EACH attachment WHERE id NOT IN incomingIds
        REMOVE attachment
        IF type = Photo THEN ADD PhotoDeleted event

    RETURN events + attachment limit warning if exceeded
```

`Visit.AddAttachments` directly appends new attachments with
auto-assigned order (no roundtrip through `UpdateAttachments`):

```
FUNCTION Visit.AddAttachments(newInputs[], actorId) → Result<events[]>

    maxOrder ← MAX order from existing attachments (or -1)

    FOR EACH (input, index) IN newInputs
        CREATE attachment FROM input WITH order = maxOrder + 1 + index
        IF type = Photo THEN ADD PhotoAdded event

    RETURN events + attachment limit warning if exceeded
```

---

Step 4: Domain Events (stub)
-----------------------------

Events are emitted **per photo** (one `PhotoAdded` per added photo,
one `PhotoDeleted` per removed photo). Payloads are minimal stubs.
Full payloads (visit date, actor info, etc.) will be designed when
the Activity Feed rendering is implemented.

### Event types

```
PhotoAdded  = 30
PhotoDeleted = 31
```

### Payloads (stub — full payload TBD)

```
PhotoAddedPayload:   { visitId: string, photoId: string }
PhotoDeletedPayload: { visitId: string, photoId: string }
```

### Mapping chain

```
JobEventType.PhotoAdded   → EventType.PhotoAdded (300)   → "photoAdded"
JobEventType.PhotoDeleted → EventType.PhotoDeleted (301) → "photoDeleted"
```

Registered under `AggregateCursorEntityType.Job`.

---

Step 5: EF Core Configuration
-------------------------------

- Table: `"Attachments"`, PK on `Id` (ValueGeneratedNever)
- `Tags` → `smallint[]`, default `'{}'`
- Cascade delete on Visit FK only (no direct Job FK)
- Indexes: `ix_attachments_job` (JobId), `ix_attachments_visit` (VisitId), `ix_attachments_tags` (GIN)

Repository: eager-load attachments in `GetJobForUpdate`:

```
Include(job.Visits)
    ThenInclude(visit.Attachments)
```

---

Step 6: Command Handler — Validate, Sanitize, Apply, Link, Save, Unlink
------------------------------------------------------------------------

Content operations are extracted to `JobContentService`
(`IJobContentService`). Tag sanitization is handled by `TagParser`.
The handler orchestrates the flow:

```
FUNCTION Handle(command)

    ── 1. Validate + sanitize ──

    CALL ValidateCommand(command)
        THROW IF ClientId is empty

    CALL TagParser.SanitizeTags(logger, command.visits)
        FOR EACH attachment DTO with unrecognised tags
            LOG WARNING "Ignoring unknown attachment tag: {Tag}"
            REMOVE invalid tags from DTO in-place

    ── 2. Load existing job ──

    existingJob ← LOAD from repository (may be null for new jobs)

    ── 3. Compute content diff (before domain mutations) ──

    contentDiff ��� existingJob.ComputeContentDiff(incomingVisits)
    skippedContentIds ← contentService.LinkContentAsync(contentDiff.Added)
        FOR EACH entry IN new content
            TRY upload content
            CATCH ContentException → add to skipped, log warning

    visitInputs ← visitInputs.RemoveSkippedContent(skippedContentIds)
        FILTER OUT attachment inputs with failed content from each visit

    ── 4. Apply domain updates ──

    job ← ApplyUpdates(existingJob, command, occurredAt)
        job.UpdateVisits(visits, team, occurredAt, actorId)
            ← visit diff + attachment diff happen here
        job.UpdateManualStatus(...)
        job.UpdateItems(...)

    ── 5. Persist ──

    repository.Insert/Update(job)
    eventService.Save(job, ...)
    unitOfWork.SaveChangesAsync()

    ── 6. Unlink removed content (after successful save) ──

    contentService.UnlinkContentAsync(contentDiff.Removed)
```

### ContentDiff

`ContentDiff` is a sealed record returned by extension methods on
`Job`. It computes which content will be added/removed by comparing
incoming visit inputs against current state — **before** domain
mutations are applied.

```
ContentDiff(Added: IReadOnlyList<ContentEntry>, Removed: IReadOnlyList<ContentEntry>)
```

Two extension methods:

- `Job?.ComputeContentDiff(IEnumerable<VisitInput>)` — for multi-visit flows (upsert, update visit)
- `Job.ComputeVisitContentDiff(Guid visitId, IReadOnlyList<AttachmentInput>)` — for single-visit flows (worker update)

Both compare content IDs before vs after and return `ContentEntry`
objects that carry `AttachmentId`, `ContentId`, and optional
`ContentAdditionalProperties` for upload.

### RemoveSkippedContent

Extension methods on `List<AttachmentInput>`, `VisitInput`, and
`IEnumerable<VisitInput>` that filter out attachment inputs whose
content failed to link. Called after `LinkContentAsync` and before
applying domain mutations — ensures the domain never sees
attachments with failed content.

### TagParser

`TagParser` sanitizes tag strings on DTOs **before** mapping to
domain. Three overloads:

- `ParseTags(logger, string[])` → `List<AttachmentTag>` — for raw tag arrays
- `SanitizeTags(logger, AttachmentInputDto[])` — mutates DTOs in-place
- `SanitizeTags(logger, VisitInputDto[])` — extracts attachments from visits

Unknown tags are logged as warnings and silently dropped. The
mapping layer (`JobsMappings.ToAttachmentInput`) uses `Enum.Parse`
safely — it always runs after sanitization.

### DomainResult + AttachmentLimitWarning

Domain methods return `DomainResult` (or `DomainResult<T>`) carrying
non-fatal `IDomainWarning` list. `AttachmentLimitWarning` is a domain
warning emitted by `Visit.UpdateAttachments` / `Visit.AddAttachments`
when attachment count exceeds `MaxAttachmentsPerVisit`.

The handler calls `.LogWarnings(logger)` extension on the result to
log all warnings. No hard failure — save proceeds.

### Why this order

- **Validate + sanitize first** — fail fast, clean invalid tags before mapping
- **Compute diff before domain** — `ContentDiff` compares incoming vs current state before mutations
- **Link before domain** — content linked first so failures can be filtered from input
- **RemoveSkippedContent** — filters failed content from attachment inputs before domain applies
- **Apply domain** — domain sees only inputs with valid content
- **Unlink after save** — prevents dangling references on rollback.
  Orphaned blobs (link succeeded, save failed) are harmless.

---

Step 7: DTOs — Contracts and API
---------------------------------

### Contract DTOs (Jobs.Contracts)

**UpsertJobCommand**:

| Field | Type | Notes |
|-------|------|-------|
| JobId | Guid | Non-nullable — generated at API mapping boundary |
| ... | | Other fields unchanged |

**VisitInputDto**:

| Field | Type | Notes |
|-------|------|-------|
| Id | Guid | Non-nullable — generated at API mapping boundary |
| Attachments | AttachmentInputDto[]? | `null` = don't touch |
| ... | | Other fields unchanged |

**AttachmentDto** (contracts response):

| Field | Type | Notes |
|-------|------|-------|
| Id | Guid | |
| JobId | Guid | |
| VisitId | Guid | |
| Type | AttachmentTypeDto | `Photo=1` |
| Content | ContentDto? | `{ Id, Url?, Properties? }` Resolved from MongoDB |
| Order | int | |
| Tags | string[] | `["before"]`, `["after"]`, `[]` (lowercase) |
| CapturedAt | DateTimeOffset? | |
| CreatedAt | DateTimeOffset | |

**AttachmentResponseDto** (API response):

| Field | Type | Notes |
|-------|------|-------|
| Id | Guid | |
| Type | AttachmentTypeDto | `"photo"` (string enum) |
| Content | { Id, Url?, Properties? }? | No JobId/VisitId in API response |
| Order | int | |
| Tags | string[] | |
| CapturedAt | DateTimeOffset? | |
| CreatedAt | DateTimeOffset | |

**AttachmentInputDto** (request):

| Field | Type | Notes |
|-------|------|-------|
| Id | Guid | Required, client-pregenerated |
| Content | ContentInputDto | `{ Id, Properties? }` (required) |
| Order | int | Client-owned |
| Tags | string[] | Default `[]` |
| CapturedAt | DateTimeOffset? | |

Tags: `AttachmentTag` enum in domain ↔ `string[]` in contracts/API.
Tags are serialized as lowercase strings (e.g. `"before"`, `"after"`).

### API DTOs (Invoices.Api)

Same shape as contracts. `AttachmentTypeDto` uses `[EnumMember]` +
`StringEnumConverter` (serializes as `"photo"`).

ID generation: API mapping layer generates `Guid.NewGuid()` for
`JobId` and `VisitId` when the client sends null/empty.

---

Step 8: Enrichment — URL Resolution
-------------------------------------

`JobDetailsService.EnrichAttachments` runs after save, before response:

```
FUNCTION EnrichAttachments(job, accountId)

    attachments ← COLLECT all attachments from job.visits

    ┌─ Resolve content URLs from MongoDB ───────────────────┐
    │                                                        │
    │  contentIds ← DISTINCT contentIds from attachments     │
    │  contents ← FindByContentIds(accountId, contentIds)    │
    │  contentMap ← MAP contents BY id                       │
    │                                                        │
    │  FOR EACH attachment IN attachments                     │
    │      IF contentId IN contentMap THEN                    │
    │          SET content.url ← contentMap[id].url           │
    │          SET content.properties ← contentMap[id].props  │
    │      ELSE                                              │
    │          LOG ERROR "Content not found for attachment"   │
    │          MARK attachment as skipped                     │
    │                                                        │
    └────────────────────────────────────────────────────────┘

    REMOVE skipped attachments from response
```

`CreatedBy` is stored on the entity (nullable) for audit but not
returned in responses. No creator name resolution needed.

### Batch content lookup (MongoDB)

`FindByContentIds` — uses `$in` on `_id` field (always indexed).
Single query for all attachments across all visits.

---

Key Design Decisions
---------------------

| Decision | Reason |
|----------|--------|
| `smallint[]` for tags | GIN-indexed, type-safe enum, compact. [Reference](https://www.crunchydata.com/blog/tags-aand-postgres-arrays-a-purrfect-combination) |
| Client-pregenerated ID | Idempotent retries, offline-friendly. Generated at API boundary |
| Client-owned ordering | Server doesn't know UI — see ordering.md |
| Client-owned tags | Server replaces as-is. Before/After mutually exclusive, enforced by client |
| Full-state diff (PUT) | Single round-trip, desired state, no merge conflicts |
| `null` = don't touch | Backward compat — legacy clients don't send attachments |
| `JobContentService` | Content linking/unlinking isolated from handler. Single responsibility |
| `ContentDiff` pre-mutation | Content diff computed before domain mutations via `ComputeContentDiff`/`ComputeVisitContentDiff` extension methods. Returns `ContentEntry` with `AttachmentId` (not VisitId) |
| `TagParser` sanitization | Unknown tags logged and dropped before mapping. Mapping layer uses safe `Enum.Parse` — always runs after sanitization |
| `DomainResult` + `AttachmentLimitWarning` | Domain methods return `DomainResult` with non-fatal warnings. `AttachmentLimitWarning` is a domain concern, logged by handler via `.LogWarnings()` |
| Soft 20-photo limit | `MaxAttachmentsPerVisit` constant in domain, warning returned in `DomainResult`. Not enforced — save proceeds |
| Null actorId → empty string | `MasterUserId ?? string.Empty` in handler for accountId+signature auth. No `MasterUserRequiredException` — supports non-master auth schemes |
| Paid job throws | `ValidateAttachmentsEditable()` in domain — explicit error on paid jobs |
| Per-photo events (stub) | `PhotoAdded`/`PhotoDeleted` per photo. Batching deferred to Activity Feed rendering |
| Enrichment at API layer | URLs resolved after save, not stored on attachment. CreatedBy stored for audit but not returned in responses |
| Inline LINQ diff (no utility) | Visit/attachment diffing uses `ToDictionary` + `ToHashSet` inline — no generic `CollectionDiff` utility. Domain-specific, readable at call site |
