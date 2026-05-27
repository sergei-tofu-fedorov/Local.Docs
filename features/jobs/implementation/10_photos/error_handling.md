Attachment Error Handling — Client Responses
=============================================

Error scenarios for attachment endpoints and proposed HTTP responses.

---

Hard Errors (operation rejected)
---------------------------------

| Scenario | HTTP | Response | Notes |
|----------|------|----------|-------|
| Job not found | 404 | `{ "error": "Job not found" }` | |
| Visit not found | 404 | `{ "error": "Visit not found" }` | |
| Attachment not found (UpdateTags) | 404 | `{ "error": "Attachment not found" }` | Delete returns success even if not found (idempotent) |
| Version mismatch | 409 | `{ "error": "Version mismatch", "currentVersion": N }` | Client should re-fetch and retry |
| Paid job — add/delete blocked | 400 | `{ "error": "Cannot modify attachments on a paid job" }` | Applies to all write endpoints |
| Missing ClientId (upsert) | 400 | `{ "error": "ClientId is required" }` | |
| Unauthenticated attachment write | 500 | `{ "error": "Authenticated user is required to modify attachments" }` | MasterUserId is null. Should not happen in normal API flow — guard for service-to-service calls without user context |
| Archived client (new job) | 400 | `{ "error": "Client is archived" }` | Only on job creation, not update |

---

Soft Errors (operation succeeds, partial data)
------------------------------------------------

| Scenario | Behavior | What the client sees |
|----------|----------|---------------------|
| Content upload fails (GCS blob missing) | Attachment silently removed from result | Fewer attachments returned than sent. Client can retry on next request |
| Unknown tag value | Tag dropped, valid tags kept | Attachment saved with only recognised tags |
| Attachment limit exceeded (>20 per visit) | Save proceeds | Full result returned. No indication in response (server logs warning) |
| Content not found during enrichment | Attachment removed from response | Attachment missing from response but exists in DB. Appears on next successful read |
| Team member not found (creator name) | N/A — CreatedBy not returned in API responses | CreatedBy stored for audit only |

---

Not Yet Implemented
--------------------

| Scenario | Spec rule | Proposed response |
|----------|-----------|-------------------|
| Tech uploads on Completed job | BR-015 | 403 `{ "error": "Job is completed — tech access is read-only" }` |
| Tech deletes other user's photo after Completed | BR-013 | 403 `{ "error": "Cannot delete photos on a completed job" }` |
| 90-day lock (no invoice) | BR-017 | 400 `{ "error": "Job record is locked" }` |
