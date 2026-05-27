Activity Feed — Visit Attachments
==================================

Photo actions are logged as visible entries in the job activity
feed (timeline). This is a product guardrail: managers retain
control over the job record, but that control is never invisible.

Note actions are NOT logged in the activity feed (low-impact,
append-only documentation).

Design principles
-----------------

- **No silent deletions** — every photo delete is a visible feed
  entry, not just an internal audit log
- **Attribution always shown** — who did what, from which visit, when
- **Transparency protects both parties** — prevents silent
  manipulation, useful in disputes
- Visible to both manager and tech

Events
------

Events are emitted **per photo** — each added or deleted photo
produces its own `PhotoAdded` or `PhotoDeleted` event. Payloads
are minimal stubs (`{visitId, photoId}`). Batching for display
(e.g. "added 10 photos") is deferred to the Activity Feed
rendering layer.

### PhotoAdded

Raised for each photo added to a visit.

```
EventType: PhotoAdded
Payload:   { visitId, photoId }
```

Activity feed text: `"[Name] added a photo to Visit [date]"`

Payload is a stub — additional fields (visitDate, tags, etc.) TBD.

### PhotoDeleted

Raised for each photo removed from a visit.

```
EventType: PhotoDeleted
Payload:   { visitId, photoId }
```

Activity feed text: `"[Name] deleted a photo from Visit [date]"`

Payload is a stub — additional fields (visitDate, deletedBy, etc.) TBD.

### Tag changes

No timeline event. Tag mutation is a lightweight edit that does
not warrant a feed entry.

### Note events

No timeline events for notes in v1. Notes are append-only
internal documentation — low audit value compared to photos.

What is NOT logged
------------------

| Action | Why |
|--------|-----|
| Tag change | Low-impact edit, no audit value |
| Photo view | Read-only, no state change |
| Upload retry (Failed → Synced) | Client-side concern |
| Note add/delete | Low-impact, internal documentation |

Implementation
--------------

Domain events emitted by the Job aggregate — one event per photo:

```
Worker PUT /worker/visits/{id}          → PhotoAdded/PhotoDeleted per photo (full-state diff)
Manager POST /jobs/{id}/.../attachments → N PhotoAdded events
Manager DELETE /jobs/.../attachments/{id} → 1 PhotoDeleted event
Manager PATCH /jobs/.../attachments/{id}  → no event (tag change)
Manager PUT /api/jobs (photo diff)      → PhotoAdded/PhotoDeleted per photo per visit
Manager PUT /jobs/{id}/visits/{id}      → PhotoAdded/PhotoDeleted per photo (full-state diff)
```

Deletion rules
--------------

| Role | Can delete | Scope |
|------|:----------:|-------|
| Tech | Own photos | Own assigned visits only |
| Manager | Any photo | Any visit in the job |

Paid jobs: all photo mutations blocked (add + delete).
Both roles see the same feed entries.
