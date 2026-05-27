# FS-889: Worker Visit Update Endpoint

## Overview

A new worker-facing endpoint that lets a worker update a visit's status **and** attachments in a single call. The previous PATCH `/status` endpoint only accepted a status flip; updating attachments required separate add/delete/tag calls. The new PUT lets mobile push a coherent batch (e.g. "I just finished, here are the after photos") in one round-trip.

**Mobile clients call this endpoint on every worker visit change.** Any time the worker mutates a visit they own — changing status, adding/removing/retagging photos, or any combination — the mobile app sends a single `PUT /api/worker/visits/{visitId}` with the full desired state of the visit. There is no separate "save status", "save attachments", or "save tags" call from mobile; everything that happens to a visit between syncs is collapsed into one request when the client is back online. This is the only write endpoint mobile uses for the worker visit surface.

The same authorization rules as the existing PATCH apply: only the worker assigned to the visit may update it, and a worker cannot mark a second visit `InProgress` while another of their visits is still `InProgress`.

## What changed

### New endpoint

```
PUT /api/worker/visits/{visitId}
```

Request body (`WorkerUpdateVisitRequestDto`):

| Field | Type | Notes |
|---|---|---|
| `JobVersion` | int | Optimistic concurrency token. |
| `Status` | `VisitStatusDto` | New status (`Scheduled`, `InProgress`, `Completed`). |
| `Attachments` | `AttachmentInputDto[]` | **Full snapshot** of the visit's attachments after the update. Required and non-nullable — see [Why full snapshot, not partial](#why-full-snapshot-not-partial). |

Response: `JobCommandResponseDto { JobVersion }`.

### Domain method

`Job.UpdateVisitByWorker(visitId, worker, status, attachments, occurredAt)` is the new aggregate entry point. It delegates the status portion to the existing `TryUpdateVisitStatusByWorker` so the assignment check, the one-in-progress rule, and the worker-name event payload all live in one place. The method then applies the attachment diff and returns `Result<Visit>` with any warnings (e.g. attachment-limit warnings) propagated to the handler for logging.

Failure modes are translated from `VisitUpdateError` to thrown exceptions inside the aggregate, mirroring `Job.UpdateVisit`:

| `VisitUpdateError` | Exception |
|---|---|
| `NotFound` | `EntityNotFoundException` |
| `Forbidden` | `WorkerAccessDeniedException` |
| `Blocked(blockingVisitId)` | `VisitStatusChangeBlockedException` |

### Worker resolution

`IJobWorkerService.GetTeamMember(accountId, workerId, ct)` resolves the worker to a `TeamMember(Id, Name, Role)` via a single `GetTenantUserAsync` call (not the full `GetTenantUsersAsync` listing). The handler passes this `TeamMember` to the domain so the worker name ends up in the `VisitStatusChanged` event payload, matching the PATCH endpoint's behaviour.

The `AuthRoleLevel → TeamMemberRole` mapping is centralised as a `JobsMappings.ToTeamMemberRole` extension and reused by both `GetTeamMember` and `GetTeam`.

### Attachment tag wire format

Attachment tags now serialise as **lowercase** strings (`"before"`, `"after"`) instead of PascalCase. Inbound parsing already accepts any case, so writes are unaffected; this is a one-way change for clients reading tags.

## Why full snapshot, not partial

The endpoint takes a full snapshot of attachments (`required AttachmentInputDto[]`) rather than a nullable "if-omitted-then-ignore" field. This deliberately avoids the classic PATCH ambiguity where `null` and *omitted* could mean either "clear" or "leave alone". With a required non-null array:

- The client always sends the desired state, the server diffs it against the current state.
- Adding, removing, retagging, and reordering attachments all flow through the same call.
- There is no documented contract around `null` for callers to misinterpret.

The existing PATCH `/api/worker/visits/{visitId}/status` endpoint is kept for callers that only need to flip a status without touching attachments, but mobile no longer uses it — mobile sends every worker visit change through the new PUT.

## Key Design Decisions

| Decision | Reason |
|---|---|
| `Attachments` is `required AttachmentInputDto[]`, not nullable | Eliminates the `null` vs *omitted* PATCH ambiguity. Mobile always sends a full snapshot; the diff happens server-side. |
| Response carries only the new `JobVersion`, not the updated visit | We are not sure how each mobile client would reconcile a richer response with its already-implemented sync mechanism, so we keep the contract minimal. If clients need the updated visit state without round-tripping through sync, the better follow-up is a dedicated `GET /api/worker/visits/{visitId}` rather than fattening this response. |
