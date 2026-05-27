# Worker API Reference

API endpoints for the worker (field team) mobile app.

**Target Audience**: Mobile Developers, Backend Developers

**Note**: In the Worker app, "job visits" are displayed as "Jobs".

## Base Path

`/api/worker`

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/worker/businesses` | [List worker businesses](#1-list-worker-businesses) |
| GET | `/api/worker/invitations` | [List worker invitations](#2-list-worker-invitations) |
| GET | `/api/worker/summary` | [Get worker summary by email](#3-get-worker-summary) |
| GET | `/api/worker/visits` | [List worker visits](#4-list-worker-visits) |
| GET | `/api/worker/visits/stats` | [Get visit statistics](#5-get-visit-statistics) |
| GET | `/api/worker/visits/{visitId}` | [Get visit details](#6-get-visit-details) |
| PUT | `/api/worker/visits/{visitId}` | [Update visit](#7-update-visit) |
| PATCH | `/api/worker/visits/{visitId}/status` | [Update visit status](#8-update-visit-status) |

---

## Account Endpoints

### 1. List Worker Businesses

Returns businesses (accounts) the authenticated worker belongs to.

**Endpoint**: `GET /api/worker/businesses`

**Response**: `200 OK`

```json
{
  "businesses": [
    {
      "accountId": "acc_123",
      "name": "Smith Plumbing",
      "role": "worker"
    }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `businesses` | array | List of businesses the worker belongs to |
| `businesses[].accountId` | string | Account/tenant ID |
| `businesses[].name` | string | Business name |
| `businesses[].role` | string | Role level: `admin`, `worker`, `unknown` |

---

### 2. List Worker Invitations

Returns pending invitations for the authenticated worker.

**Endpoint**: `GET /api/worker/invitations`

**Response**: `200 OK`

```json
{
  "invitations": [
    {
      "id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
      "accountId": "acc_456",
      "email": "worker@example.com",
      "role": "worker",
      "status": "pending",
      "createdAt": "2025-10-01T10:00:00Z",
      "expiresAt": "2025-10-08T10:00:00Z",
      "acceptedAt": null
    }
  ]
}
```

---

### 3. Get Worker Summary

Returns a summary for a worker by email. **No authentication required.**

**Endpoint**: `GET /api/worker/summary`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `email` | string | Yes | Worker email address (validated) |

**Response**: `200 OK`

```json
{
  "hasPendingInvitations": true,
  "hasWorkerAccount": false
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `hasPendingInvitations` | boolean | Whether the email has pending invitations |
| `hasWorkerAccount` | boolean | Whether the email has existing tenant memberships |

---

## Visit Read Operations

### 4. List Worker Visits

Get paginated list of visits assigned to the authenticated worker.

**Endpoint**: `GET /api/worker/visits`

**Headers**: Requires `X-Account-Id` header (business selection)

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `status` | string | No | Filter by visit status. If omitted or null, returns all visits (no filtering). See values below. |
| `token` | string | No | Pagination token from previous response. |
| `limit` | integer | No | Items per page (default: 20) |

**Status Filter Values**:

| Value | Description | Includes Visit Statuses |
|-------|-------------|------------------------|
| *(null/omitted)* | All visits | All statuses (no filtering) |
| `scheduled` | Active visits | `scheduled`, `inProgress` |
| `completed` | Completed visits | `completed` |

**Sorting**: Results are sorted by visit `DateTime` ascending (earliest first), then by `Id` for stable ordering.

**Response**: `200 OK`

```json
{
  "items": [
    {
      "visit": {
        "id": "2b1c0c1f-52ee-4b9c-8b1a-71b6b25a9f3c",
        "jobId": "7d2a5c8a-6bf7-4c87-9b7c-1e3d8f4f5a12",
        "dateTime": "2025-10-28T14:30:00Z",
        "assignedWorkerId": "worker_123",
        "status": "scheduled",
        "isOverdue": true,
        "statusChangedAt": "2025-10-28T14:30:00Z"
      },
      "job": {
        "title": "Kitchen Renovation",
        "version": 5
      },
      "client": {
        "address": "10848 Wagner St, Culver City, CA 90230"
      },
      "clientId": "client_123"
    }
  ],
  "nextToken": "eyJpZCI6InZpc2l0NDU2In0=",
  "totalCount": null
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | List of worker visit items |
| `items[].visit` | object | Visit details. See [WorkerVisitDto](#reference-workervisitdto) |
| `items[].job` | object | Job info. See [WorkerJobDto](#reference-workerjobdto) |
| `items[].client` | object | Client info object |
| `items[].client.address` | string | Client address (nullable) |
| `items[].clientId` | string | Client ID |
| `nextToken` | string | Pagination cursor for next page (null if no more) |
| `totalCount` | long | Always `null` for worker endpoints |

---

### 5. Get Visit Statistics

Get visit counts per filter status for the filter UI.

**Endpoint**: `GET /api/worker/visits/stats`

**Headers**: Requires `X-Account-Id` header (business selection)

**Response**: `200 OK`

```json
{
  "items": [
    { "status": "scheduled", "count": 5 },
    { "status": "completed", "count": 12 }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | Statistics for each filter status |
| `items[].status` | string | Filter status: `scheduled` or `completed` |
| `items[].count` | integer | Number of visits matching this filter |

---

### 6. Get Visit Details

Get detailed information about a specific visit.

**Endpoint**: `GET /api/worker/visits/{visitId}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `visitId` | Guid | Visit ID |

**Response**: `200 OK`

```json
{
  "visit": {
    "id": "2b1c0c1f-52ee-4b9c-8b1a-71b6b25a9f3c",
    "jobId": "7d2a5c8a-6bf7-4c87-9b7c-1e3d8f4f5a12",
    "dateTime": "2025-10-28T14:30:00Z",
    "assignedWorkerId": "worker_123",
    "status": "scheduled",
    "isOverdue": false,
    "statusChangedAt": "2025-10-28T14:30:00Z"
  },
  "job": {
    "title": "Kitchen Renovation",
    "version": 5
  },
  "client": {
    "id": "client_123",
    "name": "Emily Johnson",
    "address": "10848 Wagner St, Culver City, CA 90230"
  },
  "items": [
    {
      "name": "Faucet installation",
      "itemType": "service",
      "details": "Includes parts and labor",
      "description": "Kitchen faucet replacement",
      "quantity": 2,
      "unitType": "hour"
    }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `visit` | object | Visit details. See [WorkerVisitDto](#reference-workervisitdto) |
| `job` | object | Job info. See [WorkerJobDto](#reference-workerjobdto) |
| `client` | object | Client data. See [WorkerClientDto](#reference-workerclientdto) |
| `items` | array | Job line items. See [WorkerJobItemDto](#reference-workerjobitemdto) |

---

## Visit Write Operations

### 7. Update Visit

Update a visit with status change and/or attachment modifications.

**Endpoint**: `PUT /api/worker/visits/{visitId}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `visitId` | Guid | Visit ID |

**Request Body**:

```json
{
  "jobVersion": 5,
  "status": "inProgress",
  "attachments": [
    {
      "id": "a1b2c3d4-0000-0000-0000-000000000001",
      "content": {
        "id": "content_abc",
        "properties": { "orientation": "landscape" }
      },
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
| `status` | string | Yes | New visit status: `scheduled`, `inProgress`, `completed` |
| `attachments` | array | No | Full-state attachments array. `null` or omitted means "don't touch". Empty array `[]` removes all attachments. See [AttachmentInput](../../features/jobs/implementation/10_photos/PHOTOS_API_REFERENCE.md#reference-attachmentinput). |

**Response**: `200 OK`

```json
{
  "jobVersion": 6
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `jobVersion` | integer | Updated job version (for next optimistic concurrency check) |

**Business Rules**:

- **Version check**: Uses `jobVersion` for optimistic concurrency; returns `409 Conflict` on mismatch
- **Assignment check**: Worker must be assigned to the visit, otherwise `403 Forbidden`
- **In-progress validation**: If another visit in the same job is already `inProgress`, returns `409 Conflict`
- Attachment changes trigger content linking/unlinking on the server
- Triggers job status recalculation

---

### 8. Update Visit Status

Update the status of a visit.

**Endpoint**: `PATCH /api/worker/visits/{visitId}/status`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `visitId` | Guid | Visit ID |

**Request Body**:

```json
{
  "status": "inProgress",
  "version": 5
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `status` | string | Yes | New visit status: `scheduled`, `inProgress`, `completed` |
| `version` | integer | Yes | Job version from visit details (for optimistic concurrency) |

**Response**: `200 OK`

```json
{
  "visit": {
    "id": "2b1c0c1f-52ee-4b9c-8b1a-71b6b25a9f3c",
    "jobId": "7d2a5c8a-6bf7-4c87-9b7c-1e3d8f4f5a12",
    "dateTime": "2025-10-28T14:30:00Z",
    "assignedWorkerId": "worker_123",
    "status": "inProgress",
    "isOverdue": false,
    "statusChangedAt": "2025-10-28T15:00:00Z"
  },
  "version": 6
}
```

**Response Fields (200)**:

| Field | Type | Description |
|-------|------|-------------|
| `visit` | object | Updated visit. See [WorkerVisitDto](#reference-workervisitdto) |
| `version` | integer | Updated job version (for next optimistic concurrency check) |

**Error Responses**:

| HTTP | Error Code | Condition |
|------|------------|-----------|
| `404` | `not_found` | Visit not found |
| `403` | `forbidden` | Worker not assigned to this visit |
| `409` | `visitStatusChangeBlocked` | Another visit in same job is already in progress |

The `409` response includes `blockingVisitId` in `error.info`:

```json
{
  "error": {
    "code": "visitStatusChangeBlocked",
    "message": "Visit '...' status change blocked by in-progress visit '...'",
    "info": {
      "blockingVisitId": "3c2d1e0f-63ff-5c0d-9c2b-82c7c36b0g4d"
    }
  }
}
```

**Business Rules**:

- **Version check**: Uses job version from visit details for optimistic concurrency
- **Assignment check**: Worker must be assigned to the visit, otherwise `403 Forbidden`
- **In-progress validation**: If another visit in the same job is already `inProgress`, returns `409 Conflict`
- Worker can navigate to the blocking visit using `blockingVisitId` from `error.info`
- Triggers job status recalculation

---

## Reference: WorkerVisitDto

Worker-specific visit DTO with `isOverdue` field.

| Field | Type | Description |
|-------|------|-------------|
| `id` | Guid | Visit ID |
| `jobId` | Guid | Parent job ID |
| `dateTime` | DateTimeOffset | Scheduled visit date/time |
| `assignedWorkerId` | string? | Assigned worker ID (nullable) |
| `status` | string | Visit status: `scheduled`, `inProgress`, `completed` |
| `isOverdue` | boolean | `true` if visit time has passed and status is not `completed` |
| `statusChangedAt` | DateTimeOffset? | When the status was last changed (nullable) |

---

## Reference: WorkerJobDto

Worker-specific job mini model. Used in both list and details responses.

| Field | Type | Description |
|-------|------|-------------|
| `title` | string | Job title |
| `version` | integer | Job version for optimistic concurrency (pass to update status endpoint) |

---

## Reference: WorkerClientDto

Worker-specific client DTO (excludes sensitive contact info).

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Client ID |
| `name` | string? | Client name (nullable) |
| `address` | string? | Client address (nullable) |

**Note**: Phone and email are intentionally excluded for worker privacy.

---

## Reference: WorkerJobItemDto

Worker-specific job line item (excludes financial fields like price, discount, tax).

| Field | Type | Description |
|-------|------|-------------|
| `name` | string? | Item name |
| `itemType` | string | Item type: `none`, `service`, `material` |
| `details` | string? | Item details |
| `description` | string? | Item description |
| `quantity` | decimal | Quantity |
| `unitType` | string? | Unit type (e.g. `hour`, `item`) |

---

## Reference: Visit Status Values

| Value | API String | Description |
|-------|------------|-------------|
| `Scheduled` | `scheduled` | Visit is scheduled but not started |
| `InProgress` | `inProgress` | Visit is currently in progress |
| `Completed` | `completed` | Visit is completed |

---

## Reference: Worker Visit Status Filter

Simplified filter for worker visit list.

| Value | API String | Includes |
|-------|------------|----------|
| `Scheduled` | `scheduled` | `scheduled` + `inProgress` visits |
| `Completed` | `completed` | `completed` visits only |
