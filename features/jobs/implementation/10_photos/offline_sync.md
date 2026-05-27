Offline Photo Sync — Design
===========================

How the mobile app syncs photos taken offline back to the server,
without blocking job sync on slow binary uploads.

Problem
-------

Current flow is sequential:

```
come online → generate upload URL → upload binary to GCS → call API to link → next photo → ...
```

Worker takes 20+ photos offline during the day. Coming online means
a long blocking sync — job data can't sync until all photos upload.
Other users don't see the job updates until the last photo finishes.

Goal: **decouple job/attachment metadata sync from binary upload**
so job state syncs instantly and photos trickle in the background.

Current Flow
------------

```
1. POST /api/contents/generate-upload-link → signed GCS URL
2. PUT signed URL → upload binary to GCS temp
3. POST /api/worker/visits/{visitId}/attachments
   [{ id, contentId, type, tags, ... }]
```

Everything is sequential. Step 2 (binary upload) blocks step 3
(metadata link). Job sync waits for all photos.

Proposed Flow — Two-Phase Sync
-------------------------------

### Phase 1: Fast metadata sync (blocks job sync, milliseconds)

```
POST /api/worker/visits/{visitId}/attachments
[{
  id: "client-uuid",
  type: "photo",
  status: "pending_upload",
  contentChecksum: "sha256:abc...",
  sizeBytes: 4200000,
  tags: ["Before"],
  capturedAt: "2026-03-31T14:30:00Z"
}]

Response: {
  jobVersion: 6,
  attachments: [{
    id: "client-uuid",
    status: "pending_upload",
    uploadSessionUri: "https://storage.googleapis.com/upload/...?upload_id=..."
  }]
}
```

Server creates the attachment record with `status: pending_upload`.
No binary exists yet — other users see "uploading..." placeholder.
Server generates a GCS resumable upload session URI and returns it
in the response. **Job sync completes here.**

### Phase 2: Background binary upload (non-blocking)

```
Client upload queue picks up pending items:
1. Upload binary via resumable session URI (chunked)
2. POST /api/attachments/{id}/confirm
   { contentId: "gcs-object-id" }
3. Server links content, updates status: pending_upload → available
```

Upload happens in the background. The job is already synced.
Other users see the photo appear when upload completes.

Attachment Status Lifecycle
----------------------------

```
pending_upload → available     (normal flow)
pending_upload → upload_failed (all retries exhausted)
pending_upload → expired       (server cleanup after 7 days)
```

| Status | Visible to others | Binary in GCS | Content linked |
|--------|:-:|:-:|:-:|
| pending_upload | Yes (placeholder) | No | No |
| available | Yes (full) | Yes | Yes |
| upload_failed | Yes (error indicator) | No | No |
| expired | No (cleaned up) | No | No |

GCS Resumable Uploads
----------------------

GCS resumable uploads are designed for unreliable connections:

- Server creates session URI via GCS API (one-time, valid 7 days)
- Client uploads in chunks (256KB–5MB each)
- On network failure, client queries progress and resumes from last byte
- Session URI acts as authentication — no re-signing needed per chunk

```
Create session:
  POST /upload/storage/v1/b/{bucket}/o?uploadType=resumable
  Headers: x-goog-resumable: start
  → Location: {session_uri}

Upload chunk:
  PUT {session_uri}
  Content-Range: bytes 0-262143/4200000

Query progress (after failure):
  PUT {session_uri}
  Content-Range: bytes */*
  → 308 Resume Incomplete, Range: bytes=0-262143

Resume:
  PUT {session_uri}
  Content-Range: bytes 262144-4199999/4200000
```

References:
- https://cloud.google.com/storage/docs/resumable-uploads
- https://cloud.google.com/storage/docs/performing-resumable-uploads

Client Upload Queue
--------------------

SQLite-backed queue on the mobile device:

| Field | Type | Notes |
|-------|------|-------|
| id | uuid | Client-generated |
| attachmentId | uuid | From server (phase 1 response) |
| localFilePath | string | Local photo file |
| uploadSessionUri | string | GCS resumable URI from server |
| status | enum | queued, uploading, paused, failed |
| bytesUploaded | long | Resume point |
| totalBytes | long | File size |
| retryCount | int | Exponential backoff |
| nextRetryAt | datetime | null = ready now |
| priority | int | 1=critical, 2=normal |
| jobId | uuid | For grouping/UI |
| visitId | uuid | For grouping/UI |

### Priority

- **P1 (immediate)**: Job metadata sync, status updates
- **P2 (normal)**: Photo binary uploads — FIFO within priority

### Retry strategy

```
Attempt 1: immediate
Attempt 2: 5 seconds
Attempt 3: 30 seconds
Attempt 4: 2 minutes
Attempt 5: 10 minutes
Attempt 6+: 30 minutes cap
Max: 10 attempts → status: failed (manual retry)
```

Retryable: network timeout, 429, 500, 503.
Permanent failure (401, 403, 404): don't retry, mark failed.

### Concurrency

- 1–2 concurrent uploads (battery/bandwidth)
- Android: `WorkManager` with network constraint
- iOS: `BGProcessingTask` for large uploads

Job Version Conflict Avoidance
-------------------------------

Phase 1 (metadata sync) bumps `Job.Version` as usual — this
is the normal attachment creation flow.

Phase 2 (binary upload + confirm) operates on the **attachment
entity**, not the job. The confirm endpoint updates the
attachment's content link and status — no `Job.Version` bump.
This means binary uploads never conflict with other job edits.

Server-Side Changes Needed
---------------------------

| Change | Scope |
|--------|-------|
| Add `status` field to Attachment model | Domain |
| Accept `status: pending_upload` in POST attachments | Existing endpoint |
| Generate resumable session URI on attachment creation | Handler + GCS service |
| New endpoint: `POST /api/attachments/{id}/confirm` | Controller + handler |
| Background cleanup: expire `pending_upload` > 7 days | Worker/cron job |

### Confirm endpoint

```
POST /api/attachments/{id}/confirm

Request: { contentId: string }
Response: { status: "available" }
```

Links the uploaded GCS content to the attachment record.
No job version validation — operates on attachment only.

How Other Apps Solve This
--------------------------

| App | Pattern |
|-----|---------|
| Slack | Metadata first, binary async, blurred placeholder until done |
| Procore | Two-phase: create record → upload binary. Attachments are independent sub-resources |
| PlanGrid | Offline queue with sync engine, content-addressable storage |
| Fieldwire | SQLite queue, priority-based upload, separate "critical sync" from "media sync" |
| Google Photos | Compressed version first, original later. Resumable uploads |

All use the same core pattern: **sync metadata fast, upload binaries in background**.

Open Questions
--------------

### Thumbnail generation
Should the client generate a small thumbnail locally and include
it in phase 1 (base64 or as a fast upload)? This would let other
users see a preview immediately without waiting for the full upload.

### Checksum dedup
If two workers photograph the same thing, `contentChecksum` could
detect duplicates and skip the upload. Worth it for v1?

### Expired attachment cleanup
How aggressive? 7 days is standard for GCS resumable sessions.
Match that for pending_upload cleanup. Notification to the worker
before cleanup?

### Compression
Should the client compress photos before upload? Original for
invoice PDF, compressed for gallery? Upload compressed first
(fast), original later (background)?

Key Design Decisions
---------------------

| Decision | Reason |
|----------|--------|
| Two-phase sync (metadata first, binary later) | Job sync completes in milliseconds. Binary upload is decoupled and non-blocking |
| GCS resumable uploads | Survives network drops, resumes from last byte, session valid 7 days. Designed for mobile |
| Server generates resumable session URI | Client doesn't need GCS credentials. URI returned in attachment creation response |
| Confirm endpoint on attachment (not job) | No job version conflict. Binary upload is an attachment-level operation |
| SQLite upload queue on client | Persistent across app restarts, queryable for UI (progress, retry), survives crashes |
| Exponential backoff with cap | Prevents hammering server on repeated failures, respects mobile battery |
| 1–2 concurrent uploads | Mobile bandwidth/battery constraint. More parallelism hurts more than helps |
| pending_upload visible to others | Team sees "uploading..." — signals work is happening, prevents duplicate photo-taking |
