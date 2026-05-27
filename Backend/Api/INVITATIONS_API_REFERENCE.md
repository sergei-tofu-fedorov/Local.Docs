# Invitations API Reference

Complete reference for all Invitations API endpoints with request/response examples.

**Target Audience**: Frontend Developers, Backend Developers, QA Engineers

## Base Path

`/api/v3/invitations`

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v3/invitations` | [Create invitation](#1-create-invitation) |
| GET | `/api/v3/invitations` | [List invitations](#2-list-invitations) (query parameter filter) |
| POST | `/api/v3/invitations/list` | [List invitations (body)](#3-list-invitations-body) (multi-status filter) |
| POST | `/api/v3/invitations/{token}/accept` | [Accept invitation](#4-accept-invitation) |
| POST | `/api/v3/invitations/accept-all` | [Accept all invitations](#5-accept-all-invitations) |
| POST | `/api/v3/invitations/{token}/magic-login` | [Magic login](#6-magic-login) |
| POST | `/api/v3/invitations/{invitationId}/revoke` | [Revoke invitation](#7-revoke-invitation) |

---

## Write Operations

### 1. Create Invitation

Create a new invitation in the current tenant.

**Endpoint**: `POST /api/v3/invitations`

**Request Body**:

```json
{
  "email": "worker@example.com",
  "role": "worker",
  "baseUrl": "https://app.example.com"
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `email` | string | Yes | Email address of the invitee. Must be a valid email format. |
| `role` | string | Yes | Role to assign. Values: `worker`. The `admin` role is not allowed via invitations. |
| `baseUrl` | string | No | Base URL override for the invitation link. |

**Response**: `200 OK`

```json
{
  "invitation": {
    "id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "accountId": "acc_xyz789",
    "email": "worker@example.com",
    "role": "worker",
    "status": "pending",
    "createdAt": "2026-03-05T10:00:00Z",
    "expiresAt": "2026-03-12T10:00:00Z",
    "acceptedAt": null
  },
  "link": "https://app.example.com/invite/abc123token"
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `invitation` | object | The created invitation. See [Invitation Object](#reference-invitation-object). |
| `link` | string | Full invitation URL to share with the invitee. |

**Business Rules**:
- The `admin` role cannot be assigned via invitations.
- The `unknown` role is rejected as invalid.
- The account must have a business name set; technical accounts without a business name receive an error.

---

### 4. Accept Invitation

Accept an invitation by its token. Links the current user to the inviting tenant.

**Endpoint**: `POST /api/v3/invitations/{token}/accept`

**Path Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `token` | string | Yes | The invitation token. |

**Request Body**: None

**Response**: `200 OK`

```json
{
  "invitation": {
    "id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "accountId": "acc_xyz789",
    "email": "worker@example.com",
    "role": "worker",
    "status": "accepted",
    "createdAt": "2026-03-05T10:00:00Z",
    "expiresAt": "2026-03-12T10:00:00Z",
    "acceptedAt": "2026-03-06T14:30:00Z"
  }
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `invitation` | object | The accepted invitation. See [Invitation Object](#reference-invitation-object). |

**Business Rules**:
- The authenticated user is added to the tenant with the invitation's role.
- The user's platform link is recorded for the invited account.

---

### 5. Accept All Invitations

Accept all pending invitations for the current user.

**Endpoint**: `POST /api/v3/invitations/accept-all`

**Request Body**: None

**Response**: `200 OK`

```json
{
  "invitations": [
    {
      "id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
      "accountId": "acc_xyz789",
      "email": "worker@example.com",
      "role": "worker",
      "status": "accepted",
      "createdAt": "2026-03-05T10:00:00Z",
      "expiresAt": "2026-03-12T10:00:00Z",
      "acceptedAt": "2026-03-06T14:30:00Z"
    }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `invitations` | array | List of accepted invitations. Each element is an [Invitation Object](#reference-invitation-object). |

---

### 6. Magic Login

Perform a magic login for an invitation token. Returns a custom authentication token for client-side use. This endpoint does not require authentication.

**Endpoint**: `POST /api/v3/invitations/{token}/magic-login`

**Path Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `token` | string | Yes | The invitation token. |

**Request Body**:

```json
{
  "magicToken": "eyJhbGciOiJSUzI1NiIs..."
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `magicToken` | string | Yes | The magic login token provided to the invitee. |

**Response**: `200 OK`

```json
{
  "customToken": "eyJhbGciOiJSUzI1NiIs..."
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `customToken` | string | Authentication token for client-side use. |

---

### 7. Revoke Invitation

Revoke an invitation in the current tenant.

**Endpoint**: `POST /api/v3/invitations/{invitationId}/revoke`

**Path Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `invitationId` | GUID | Yes | The invitation ID. |

**Request Body**: None

**Response**: `204 No Content`

---

## Read Operations

### 2. List Invitations

List invitations in the current tenant, optionally filtered by a single status.

**Endpoint**: `GET /api/v3/invitations`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `status` | string | No | Filter by invitation status. Values: `pending`, `accepted`, `revoked`, `expired`. When omitted, returns all invitations. |

**Example Request**:

```
GET /api/v3/invitations?status=pending
```

**Response**: `200 OK`

```json
{
  "invitations": [
    {
      "id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
      "accountId": "acc_xyz789",
      "email": "worker@example.com",
      "role": "worker",
      "status": "pending",
      "createdAt": "2026-03-05T10:00:00Z",
      "expiresAt": "2026-03-12T10:00:00Z",
      "acceptedAt": null
    }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `invitations` | array | List of invitations. Each element is an [Invitation Object](#reference-invitation-object). |

---

### 3. List Invitations (Body)

List invitations in the current tenant using a request body with multiple status filters.

**Endpoint**: `POST /api/v3/invitations/list`

**Request Body**:

```json
{
  "statuses": ["pending", "accepted"]
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `statuses` | array | No | Array of status values to filter by. Values: `pending`, `accepted`, `revoked`, `expired`. When omitted or null, returns all invitations. |

**Response**: `200 OK`

Same response format as [List Invitations](#2-list-invitations).

---

## Reference: Shared Objects

### Reference: Invitation Object

| Field | Type | Description |
|-------|------|-------------|
| `id` | GUID | Unique invitation identifier. |
| `accountId` | string | Tenant (account) ID that the invitation belongs to. |
| `email` | string | Email address of the invitee. |
| `role` | string | Assigned role. Values: `unknown`, `admin`, `worker`. |
| `status` | string | Current invitation status. Values: `pending`, `accepted`, `revoked`, `expired`. |
| `createdAt` | ISO 8601 | When the invitation was created. |
| `expiresAt` | ISO 8601 | When the invitation expires. |
| `acceptedAt` | ISO 8601 or null | When the invitation was accepted. Null if not yet accepted. |
