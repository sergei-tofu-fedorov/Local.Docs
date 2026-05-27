Photos & Attachments — Overview
================================

Context
-------

Structured documentation for jobs and visits: photos (proof of work).
Attachments live in the `Attachments` table with a non-nullable
`VisitId` — all attachments are currently visit-scoped.

Scope (v1)
----------

**In**: photos on visits (chronological, optional Before/After tags),
visit execution notes (append-only), nudge on visit completion.

**Out**: client-facing gallery, required photo gate (v1.1), annotation,
voice notes, messaging, workflow enforcement gates.

Domain Model
------------

```
Job (aggregate root, Version, SequenceId)
├── Visits[] (child entities)
│   ├── Id, JobId, Number, DateTime, AssignedWorkerId
│   ├── Status (Scheduled → InProgress → Completed)
│   └── Attachments[] ← visit-level (VisitId always set)
├── Items[]
└── ClientSnapshot
```

**Attachment** (entity, visit-scoped):

| Field | Type | Notes |
|-------|------|-------|
| Id | Guid | PK, client-pregenerated |
| JobId | Guid | Always set (denormalized from Visit) |
| VisitId | Guid | FK to Visit, always set (non-nullable) |
| Type | AttachmentType | Photo=1 (discriminator) |
| ContentId | string? | Links to Content entity (GCS) |
| Order | int | Display order within visit |
| Tags | smallint[] | Enum-backed: Before=1, After=2. Multiple per attachment |
| CapturedAt | DateTimeOffset? | When taken/recorded |
| CreatedBy | string? | MasterUserId (nullable for accountId+signature auth) |
| CreatedAt | DateTimeOffset | Server timestamp |

**AttachmentType**: Unknown=0, Photo=1

**Scope**: Currently visit-level only (`VisitId` is always set).
Job-level attachments (VisitId = NULL) are planned for stage 10.3
but not yet implemented.

**Tags**:
- Photo: `{1}` (Before), `{2}` (After), `{}` (untagged)
- Before and After are mutually exclusive by convention (client-enforced)

Attachments live in a single `Attachments` table. The `Type`
discriminator separates content types. `ContentId` is nullable.
Tags stored as `smallint[]` with GIN index for fast containment queries.

Permissions
-----------

### Visit-level attachments

| Action | Technician | Manager |
|--------|-----------|---------|
| View attachments | Assigned visits | All visits |
| Add photos/notes | Own assigned visits | Any visit |
| Update tags | Own assigned visits | Any visit |
| Delete | Own attachments, own visits | Any attachment |

Worker loses upload/delete access at Completed (ReadyForInvoice and beyond).
Manager retains full access until invoice Paid.
Paid → all attachments read-only for all roles.
Unassign from visit → lose access to that visit's attachments.

Business Rules
--------------

- **BR-001**: Visit-level photos attach to a visit; job-level photos attach to the job
- **BR-005/006**: Tech deletes own visit attachments; manager deletes any
- **BR-007**: Every deletion logged in Activity Feed (visible)
- **BR-008**: Attribution (name + timestamp) always shown, immutable.
  Name is not stored on the attachment — resolved at read time from team info
- **BR-009**: Tags are a client-owned collection (Before, After). The client
  sends the full desired tags array — the server replaces the stored value.
  Adding, removing, or switching tags is the client's responsibility.
  Before and After are mutually exclusive by convention (client-enforced,
  server stores whatever the client sends)
- **BR-011**: Worker: Completed (ReadyForInvoice) → upload/delete blocked.
  Manager: Paid → upload/delete blocked
- **BR-012**: No product-level photo limit (engineering ceiling only)
- **BR-015**: Upload states: Uploading → Synced → Failed (client-side)
- 20 attachments/visit soft limit (warn in UI, save allowed; enforced in `Job.UpdateVisitAttachments`, `MaxAttachmentsPerVisit = 20`)
- 20 visits/job soft limit (notification + analytics)

Activity Feed (per-photo events):
- `"[Name] added a photo to Visit [date]"` (one event per photo)
- `"[Name] deleted a photo from Visit [date]"` (one event per photo)

Storage
-------

See `db_structure.md` for full schema (PostgreSQL DDL, MongoDB
Content schema, EF Core configuration, cross-database read pattern,
and migration SQL).

API Design
----------

### Two API surfaces, one domain

| Surface | Controller | Reads | Writes |
|---------|-----------|-------|--------|
| Manager (web) | `JobsController` | `GET /api/jobs/{id}` → Visits[].Attachments[] | Dedicated PUT/POST/DELETE/PATCH per visit (see below) + `PUT /api/jobs` full-state diff |
| Worker (mobile) | `WorkerController` | `GET /api/worker/visits/{id}` → Attachments[] | `PUT /api/worker/visits/{visitId}` → full-state diff |

Both go through the Job aggregate internally. Attachments stored
in `Attachments` table. All current attachments are visit-level
(VisitId always set). Supports photos (Type=1).

### Attachments loading by endpoint

| Endpoint | Attachments | Why |
|----------|:------:|-----|
| `GET /api/jobs/{id}` | Full | Detail page |
| `PUT /api/jobs` response | Full | Fresh state |
| `GET /api/jobs/paged` | No | List page |
| `GET /api/jobs/sync` | `null` | High-volume |
| `GET /api/worker/visits` | Full | Offline support |
| `GET /api/worker/visits/{id}` | Full | Detail + upload |
| `PATCH /worker/.../status` response | Full | Nudge UX |

### Worker endpoint

Single PUT endpoint for visit updates (status + attachments):

```
PUT /api/worker/visits/{visitId}
```

Worker sends the full desired state of attachments — server diffs
against current state. Same full-state diff approach as the manager's
`PUT /api/jobs`. Requires `jobVersion` in the request (409 on
mismatch). Response includes the updated `jobVersion`.

**Why a single endpoint (not separate POST/DELETE/PATCH):**
- Same diff pattern as manager — consistent mental model
- Simpler client — one endpoint covers add, remove, retag, reorder
- Offline-friendly — client accumulates local edits, sends final state
- Fewer endpoints to maintain

### Upload flow (photos)

```
1. POST /api/contents/generate-upload-link → signed GCS URL
2. PUT signed URL → upload directly to GCS
3. POST /api/worker/visits/{visitId}/attachments
   [{ "type": "photo", "contentId": "abc", "order": 0, "tags": ["Before"] }]
```

Orientation (`ContentAdditionalProperties`) is passed during content
upload (via `UploadContentFromSignedUrl`) and returned in attachment
response DTOs. The backend never reads the image binary, so the client
must provide orientation at upload time. It is stored on the `Content`
entity in MongoDB and returned to clients that need it (WASM rendering,
invoice PDF generation).

### Worker PUT request — update visit

```json
{
  "jobVersion": 5,
  "status": "inProgress",
  "attachments": [
    { "id": "guid-1", "content": { "id": "abc" }, "order": 0, "tags": ["Before"], "capturedAt": "..." },
    { "id": "guid-2", "content": { "id": "def" }, "order": 1, "tags": ["After"], "capturedAt": "..." }
  ]
}
```

Returns `{ jobVersion }`. Attachments array is required (non-nullable).
Send current attachments array to keep them unchanged.

### Manager write pattern

Manager uses the existing `PUT /api/jobs` with attachments in the
Visits[].Attachments[] array. Server diffs against current state
(full-state diff — same as visits). This is the only path that
uses the diff pattern; worker endpoints are individual operations.

### DTOs

```
AttachmentResponseDto: Id, Type, Content?: { Id, Url?, Properties?: { Orientation? } },
                       Order, Tags: string[], CapturedAt?, CreatedAt
AttachmentInputDto:    Id, Content: { Id, Properties? }, Order, Tags: string[], CapturedAt?
```

`CreatedBy` is stored on the attachment entity (MasterUserId, nullable)
but not returned in API responses. On update, existing `CreatedBy`
is preserved.

All write requests include `jobVersion` (validated, 409 on mismatch).
All responses include updated `jobVersion`:

```
Manager PUT visit     request  → { jobVersion, dateTime, status, assignedWorkerId?, attachments? }
                      response → { jobVersion }
Manager POST add      request  → { jobVersion, attachments: AttachmentInputDto[] }
                      response → { jobVersion }
Manager DELETE        query    → ?jobVersion=N
                      response → { jobVersion }
Manager PATCH tags    request  → { jobVersion, tags? }
                      response → { jobVersion }
Worker PUT visit      request  → { jobVersion, status, attachments: AttachmentInputDto[] }
                      response → { jobVersion }
```

Tags are stored as `smallint[]` in PostgreSQL, serialized as
lowercase `string[]` in API responses (e.g. `["before"]`, `["after"]`).

### Backward compatibility

Worker `PUT /api/worker/visits/{visitId}` is **new** — no old clients
call it. Existing endpoints unchanged:
- `PATCH /worker/visits/{id}/status` → still validates Job.Version
- Read DTOs gain new fields (Attachments) — old
  clients safely ignore unknown JSON fields

### Timeline events

See `activity_feed.md` for events (PhotoAdded, PhotoDeleted),
payloads, and deletion rules.

Existing infrastructure reused:
- `POST /api/contents/generate-upload-link` (unchanged)
- `ContentEntities.JobAttachment` for content linking (`AttachmentId` as EntityId)
- `ContentsService.UploadContentFromSignedUrl()` / `UnlinkContent()`
- Content operations orchestrated by `JobContentService`

Implementation Stages
---------------------

| Stage | Description |
|-------|-------------|
| 10.1 | Visit photos — domain model, API, storage |
| 10.2 | Visit notes — same table, Type=Note, no ContentId |
| 10.3 | Job-level photo/note aggregation |
| 10.4 | Nudge on visit completion |

Open Questions
--------------

### Content entity linking (resolved)
All attachments use `ContentEntities.JobAttachment = 3` with
`AttachmentId` as EntityId.

### Note deletion policy
Notes are append-only. Can a note be deleted if added by mistake?
Can a manager delete a worker's note?

### Paid/archived job reopening
Can a manager reopen a paid/archived job to add/delete photos?

### Photo deletion cutoff
Same as paid/archived lock, or earlier restriction?

### iOS offline capture
Upload requires internet. Offline option: capture locally, queue
uploads on reconnect. Server treats as normal POSTs (`capturedAt`
preserves original time). Questions: local queue size limit,
conflict handling if visit deleted while queued.

### Tags evolution
Tags are stored as `smallint[]` backed by `AttachmentTag` enum
(Before=1, After=2). The array supports multiple tags, but Before
and After are mutually exclusive — a photo is either Before, After,
or untagged, never both. Future tag types may coexist (e.g. Interior,
Exterior). Adding new tag values requires a code change (new enum value).

Tags are a **client-owned collection** — the server always replaces
the stored array with whatever the client sends. The client is
responsible for the full lifecycle: set a tag, switch Before↔After,
or clear all. The server does no merge or diffing on the tags array
itself. Mutual exclusivity of Before/After is enforced by the client.

### `CreatedBy` — stored but not returned
`CreatedBy` (MasterUserId) is set on attachment creation and never
overwritten on updates. It is **not included in API responses** —
clients don't need it currently. The field remains in the domain
entity for audit/internal purposes.
