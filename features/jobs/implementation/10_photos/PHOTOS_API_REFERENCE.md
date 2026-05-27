# Photos & Attachments API Reference

API endpoints for managing visit-level photo attachments on jobs.

**Target Audience**: Frontend Developers, Mobile Developers, QA Engineers

## Base Path

`/api/v3/jobs`

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| PUT | `/api/v3/jobs/{jobId}/visits/{visitId}` | [Update visit](#1-update-visit) (with optional attachments diff) |
| POST | `/api/v3/jobs/{jobId}/visits/{visitId}/attachments` | [Add attachments](#2-add-attachments) |
| DELETE | `/api/v3/jobs/{jobId}/visits/{visitId}/attachments/{attachmentId}` | [Delete attachment](#3-delete-attachment) |
| PATCH | `/api/v3/jobs/{jobId}/visits/{visitId}/attachments/{attachmentId}` | [Update attachment tags](#4-update-attachment-tags) |

All endpoints require API version 3.0. All write endpoints use optimistic concurrency via `jobVersion`.

> Upsert Job (`PUT /api/v3/jobs`) also supports attachments in the `visits[].attachments` array using full-state diff. See [JOBS_API_REFERENCE.md](../../../Backend/Api/JOBS_API_REFERENCE.md#1-upsert-job).

---

## Common Response

All endpoints return `JobCommandResponseDto`:

```json
{
  "jobVersion": 4
}
```

| Field | Type | Description |
|-------|------|-------------|
| `jobVersion` | integer | Updated job version. Use this value in subsequent requests. |

---

## 1. Update Visit

Update visit properties and optionally diff attachments.

**Endpoint**: `PUT /api/v3/jobs/{jobId}/visits/{visitId}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `jobId` | Guid | Job ID |
| `visitId` | Guid | Visit ID |

**Request Body**:

```json
{
  "jobVersion": 3,
  "dateTime": "2025-10-28T14:30:00Z",
  "assignedWorkerId": "worker_123",
  "status": "inProgress",
  "attachments": [
    {
      "id": "a1b2c3d4-0000-0000-0000-000000000001",
      "content": { "id": "content_abc" },
      "order": 0,
      "tags": ["Before"],
      "capturedAt": "2025-10-28T14:25:00Z"
    }
  ]
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `jobVersion` | integer | Yes | Job version for optimistic concurrency |
| `dateTime` | string (ISO 8601) | Yes | Planned visit time (UTC) |
| `assignedWorkerId` | string | No | Worker assigned to this visit |
| `status` | string | Yes | Visit status: `scheduled`, `inProgress`, `completed` |
| `attachments` | array | No | Full-state attachments array. Server diffs against current state. `null` or omitted means "don't touch". Empty array `[]` removes all attachments. See [AttachmentInput](#reference-attachmentinput). |

**Response**: `200 OK` — [JobCommandResponseDto](#common-response)

**Business Rules**:
- Updates visit properties (dateTime, status, worker) and optionally diffs attachments in a single operation
- Attachments use full-state diff: the server compares incoming array against current state to determine additions and removals
- Sends `null` attachments to leave existing photos untouched (backward compatible with older clients)
- Creates timeline events for photo additions/deletions
- Adding or removing attachments is rejected with `InvalidOperationException` when the job is in `Paid` status (existing tags can still be updated through this endpoint because tag-only changes do not count as add/remove)
- For attachments that already exist in the visit, only `tags` can be modified; client-supplied `order` is ignored and the server-assigned order is preserved

---

## 2. Add Attachments

Append one or more attachments to a visit without affecting existing ones.

**Endpoint**: `POST /api/v3/jobs/{jobId}/visits/{visitId}/attachments`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `jobId` | Guid | Job ID |
| `visitId` | Guid | Visit ID |

**Request Body**:

```json
{
  "jobVersion": 3,
  "attachments": [
    {
      "id": "a1b2c3d4-0000-0000-0000-000000000001",
      "content": { "id": "content_abc", "properties": { "orientation": "landscape" } },
      "order": 0,
      "tags": ["Before"],
      "capturedAt": "2025-10-28T14:25:00Z"
    },
    {
      "id": "a1b2c3d4-0000-0000-0000-000000000002",
      "content": { "id": "content_def" },
      "order": 1,
      "tags": ["After"]
    }
  ]
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `jobVersion` | integer | Yes | Job version for optimistic concurrency |
| `attachments` | array | Yes | Attachments to add. See [AttachmentInput](#reference-attachmentinput). |

**Response**: `200 OK` — [JobCommandResponseDto](#common-response)

**Business Rules**:
- Appends to existing attachments (no diffing, no removals)
- Server auto-assigns `order` (within a batch the first input gets the highest order, so the response — sorted by `capturedAt`/`createdAt` then `order` descending — preserves submission order on ties); client-supplied `order` is ignored
- Each photo creates a `photoAdded` timeline event
- Content must be uploaded to GCS before calling this endpoint (see [Upload Flow](#upload-flow))
- Soft limit of 20 attachments per visit — exceeding it is logged as a warning but the request still succeeds
- Rejected with `InvalidOperationException` when the job is in `Paid` status

---

## 3. Delete Attachment

Remove a single attachment from a visit.

**Endpoint**: `DELETE /api/v3/jobs/{jobId}/visits/{visitId}/attachments/{attachmentId}?jobVersion={version}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `jobId` | Guid | Job ID |
| `visitId` | Guid | Visit ID |
| `attachmentId` | Guid | Attachment ID |

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `jobVersion` | integer | Yes | Job version for optimistic concurrency |

**Request Body**: None

**Response**: `200 OK` — [JobCommandResponseDto](#common-response)

**Business Rules**:
- Removes the attachment and unlinks content from GCS
- Creates a `photoDeleted` timeline event
- Succeeds silently if the attachment does not exist on the visit (idempotent)
- Rejected with `InvalidOperationException` when the job is in `Paid` status

---

## 4. Update Attachment Tags

Update the tags on a specific attachment (e.g., Before/After labels).

**Endpoint**: `PATCH /api/v3/jobs/{jobId}/visits/{visitId}/attachments/{attachmentId}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `jobId` | Guid | Job ID |
| `visitId` | Guid | Visit ID |
| `attachmentId` | Guid | Attachment ID |

**Request Body**:

```json
{
  "jobVersion": 4,
  "tags": ["After"]
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `jobVersion` | integer | Yes | Job version for optimistic concurrency |
| `tags` | string[] | No | New tags array. Replaces existing tags entirely. Valid values: `Before`, `After` (case-insensitive on input). Send `[]` to clear. Send `null` to leave unchanged. |

**Response**: `200 OK` — [JobCommandResponseDto](#common-response)

**Business Rules**:
- Tags are fully replaced (not merged) with the provided array
- Unknown tag values are dropped server-side (logged as a warning); only `Before` and `After` are persisted
- Before and After are conceptually mutually exclusive — a photo should not have both (not enforced server-side)
- No timeline event for tag changes
- Allowed at any job status, including `Paid` (tag updates are not gated by job status)

---

## Upload Flow

Photos must be uploaded to GCS before attaching to a visit:

```
1. POST /api/contents/generate-upload-link → signed GCS URL
2. PUT  <signed URL>                       → upload file to GCS
3. POST /api/v3/jobs/{jobId}/visits/{visitId}/attachments
   → attach using the content ID from step 1
```

The `content.properties.orientation` field should be provided during upload if known — the backend never reads image binary, so the client must supply orientation at upload time.

---

## Timeline Events

Photo operations generate events visible in the job timeline (`GET /api/v3/jobs/{id}/timeline`).

| Event Type | Trigger | Payload |
|------------|---------|---------|
| `photoAdded` | Photo added to a visit | `{ "visitId": "...", "photoId": "..." }` |
| `photoDeleted` | Photo deleted from a visit | `{ "visitId": "...", "photoId": "..." }` |

- One event per photo — bulk add of 3 photos produces 3 `photoAdded` events
- Tag updates do not generate timeline events
- See [Job Timeline](../../../Backend/Api/JOBS_API_REFERENCE.md#7-get-job-timeline) for full timeline API

---

## Attachments in Upsert Job

The existing `PUT /api/v3/jobs` endpoint supports attachments in the `visits[].attachments` array. The server diffs against current state (full-state diff):

```json
{
  "id": "job-guid",
  "version": 3,
  "clientId": "client_123",
  "visits": [
    {
      "id": "visit-guid",
      "dateTime": "2025-10-28T14:30:00Z",
      "status": "inProgress",
      "attachments": [
        { "id": "...", "content": { "id": "content_abc" }, "order": 0, "tags": ["Before"] }
      ]
    }
  ]
}
```

- `attachments: null` or omitted = don't touch existing attachments (backward compatible)
- `attachments: []` = remove all attachments from this visit
- `attachments: [...]` = server computes additions/removals by comparing with current state

---

## Attachments in Read Endpoints

| Endpoint | Attachments Included | Notes |
|----------|:--------------------:|-------|
| `GET /api/v3/jobs/{id}` | Yes | Full attachments per visit |
| `PUT /api/v3/jobs` response | Yes | Fresh state after upsert |
| `GET /api/v3/jobs/paged` | No | List view, no attachments |
| `GET /api/v3/jobs/sync` | No (`null`) | High-volume sync |

---

## Reference: AttachmentInput

Input structure for creating attachments (used in Add Attachments and Update Visit).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | Guid | Yes | Client-generated attachment ID |
| `content` | object | Yes | Content reference. See [Content Input](#reference-content-input). |
| `order` | integer | No | Ignored on input. Server auto-assigns the order for new attachments and preserves it for existing ones. |
| `tags` | string[] | No | Tag labels: `Before`, `After` (case-insensitive). Unknown values are dropped server-side. Default: empty. |
| `capturedAt` | string (ISO 8601) | No | When the photo was captured (client timestamp) |

## Reference: Content Input

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Content ID from the upload flow |
| `properties` | object | No | Additional content metadata |
| `properties.orientation` | string | No | Image orientation: `unknown`, `landscape`, `portrait` |

## Reference: AttachmentResponse

Attachment as returned in visit responses (e.g., `GET /api/v3/jobs/{id}` → `visits[].attachments[]`).

```json
{
  "id": "a1b2c3d4-0000-0000-0000-000000000001",
  "type": "photo",
  "content": {
    "id": "content_abc",
    "url": "https://storage.googleapis.com/bucket/content_abc",
    "properties": { "orientation": "landscape" }
  },
  "order": 0,
  "tags": ["before"],
  "capturedAt": "2025-10-28T14:25:00Z",
  "createdAt": "2025-10-28T14:30:00Z",
  "createdBy": "master_user_123"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | Guid | Attachment identifier |
| `type` | string | Attachment type: `photo` |
| `content` | object | Content details (nullable if content not yet uploaded) |
| `content.id` | string | Content ID |
| `content.url` | string | Signed download URL (nullable) |
| `content.properties` | object | Content metadata (nullable) |
| `content.properties.orientation` | string | `unknown`, `landscape`, `portrait` |
| `order` | integer | Display order within the visit (server-assigned) |
| `tags` | string[] | Tag labels, always lowercased on output: `"before"`, `"after"` |
| `capturedAt` | string (ISO 8601) | When captured (nullable) |
| `createdAt` | string (ISO 8601) | Server timestamp when attachment was created |
| `createdBy` | string | Master user ID of the actor who created the attachment (nullable) |

Within a visit response, attachments are sorted by `capturedAt` (falling back to `createdAt`) descending, then by `order` descending.

Note: `jobId` and `visitId` are NOT included in the API response DTO
(`AttachmentResponseDto`). They are present in the contracts-level
`AttachmentDto` but stripped at the API mapping layer.

## Reference: Concurrency

All write endpoints require `jobVersion` matching the current `Job.Version`. On mismatch the server returns `409 Conflict`. Every successful write response includes the updated `jobVersion` — use it for subsequent calls. For DELETE endpoints, `jobVersion` is passed as a query parameter; for all others it is in the request body.

## Reference: Editability Rules

Editability is gated by the job's effective status, not by user role:

| Operation | Allowed When | Behavior on `Paid` |
|-----------|--------------|--------------------|
| Add attachments (POST, or new entries via UpdateVisit / UpsertJob) | Job not in `Paid` status | Rejected with `InvalidOperationException` ("Cannot modify attachments on a paid job.") |
| Delete attachment (DELETE, or removed entries via UpdateVisit / UpsertJob) | Job not in `Paid` status | Rejected with `InvalidOperationException` |
| Update tags (PATCH, or tag changes on existing entries via UpdateVisit / UpsertJob) | Any status | Allowed |

Role-based access (e.g. who can call these endpoints at all) is enforced by the global authorization layer and is out of scope for this document.
