# Authorization API Reference

Complete reference for all Authorization (current user) API endpoints with request/response examples.

**Target Audience**: Frontend Developers, Backend Developers, QA Engineers

## Base Path

`/api/v3/me`

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v3/me/permissions` | [Get my permissions](#1-get-my-permissions) |
| GET | `/api/v3/me/contact` | [Get my contact](#2-get-my-contact) |
| PUT | `/api/v3/me/contact` | [Update my contact](#3-update-my-contact) |

---

## Read Operations

### 1. Get My Permissions

Get permissions for the current user in the current tenant.

**Endpoint**: `GET /api/v3/me/permissions`

**Response**: `200 OK`

```json
{
  "abilities": [
    {
      "object": "invoice",
      "action": "view"
    },
    {
      "object": "invoice",
      "action": "create"
    },
    {
      "object": "job",
      "action": "edit"
    }
  ]
}
```

---

### 2. Get My Contact

Get contact information for the current user in the current tenant.

**Endpoint**: `GET /api/v3/me/contact`

**Response**: `200 OK`

```json
{
  "name": "John Smith",
  "phoneNumber": "+1234567890"
}
```

---

## Write Operations

### 3. Update My Contact

Update contact information for the current user in the current tenant.

**Endpoint**: `PUT /api/v3/me/contact`

**Request Body**:

```json
{
  "name": "John Smith",
  "phoneNumber": "+1234567890"
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | No | Display name for the current user in the tenant. Max 200 characters. |
| `phoneNumber` | string | No | Phone number for the current user in the tenant. Max 20 characters. |

**Response**: `204 No Content`

---

## DTOs

### PermissionsResponse

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `abilities` | Ability[] | No | List of permissions the user has in the tenant |

### Ability

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `object` | string | No | Resource type (e.g., "invoice", "job", "user") |
| `action` | string | No | Action allowed on the resource (e.g., "view", "create", "edit") |

### MyContactResponseDto

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Display name for the current user in the tenant |
| `phoneNumber` | string | Yes | Phone number for the current user in the tenant |

### UpdateTeamMemberContactRequestDto

Shared with [Teams API](TEAMS_API_REFERENCE.md#3-update-member-contact) — same request body.
