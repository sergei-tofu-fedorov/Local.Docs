# Teams API Reference

Complete reference for all Team API endpoints with request/response examples.

**Target Audience**: Frontend Developers, Backend Developers, QA Engineers

## Base Path

`/api/v3/team`

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v3/team/members` | [Get all team members](#1-get-all-team-members) |
| GET | `/api/v3/team/members/{userId}` | [Get a team member](#2-get-a-team-member) |
| PUT | `/api/v3/team/members/{userId}/contact` | [Update member contact](#3-update-member-contact) |
| DELETE | `/api/v3/team/members/{userId}` | [Remove team member](#4-remove-team-member) |

---

## Read Operations

### 1. Get All Team Members

Get all team members in the current tenant.

**Endpoint**: `GET /api/v3/team/members`

**Response**: `200 OK`

```json
{
  "teamMembers": [
    {
      "userId": "7d2a5c8a-6bf7-4c87-9b7c-1e3d8f4f5a12",
      "email": "john@example.com",
      "name": "John Smith",
      "role": "admin",
      "isCurrentUser": true,
      "joinedAt": "2025-01-15T10:00:00Z",
      "phoneNumber": "+1234567890"
    },
    {
      "userId": "3f1a2b3c-4d5e-6f7a-8b9c-0d1e2f3a4b5c",
      "email": "jane@example.com",
      "name": "Jane Doe",
      "role": "worker",
      "isCurrentUser": false,
      "joinedAt": "2025-03-20T14:30:00Z",
      "phoneNumber": null
    }
  ]
}
```

---

### 2. Get a Team Member

Get a specific team member by user ID.

**Endpoint**: `GET /api/v3/team/members/{userId}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `userId` | GUID | The user's unique identifier |

**Response**: `200 OK`

```json
{
  "userId": "7d2a5c8a-6bf7-4c87-9b7c-1e3d8f4f5a12",
  "email": "john@example.com",
  "name": "John Smith",
  "role": "admin",
  "isCurrentUser": true,
  "joinedAt": "2025-01-15T10:00:00Z",
  "phoneNumber": "+1234567890"
}
```

---

## Write Operations

### 3. Update Member Contact

Update contact information for a team member.

**Endpoint**: `PUT /api/v3/team/members/{userId}/contact`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `userId` | GUID | The user's unique identifier |

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
| `name` | string | No | Display name for this user in the tenant. Max 200 characters. |
| `phoneNumber` | string | No | Phone number for this user in the tenant. Max 20 characters. |

**Response**: `204 No Content`

---

### 4. Remove Team Member

Remove a user from the team (revoke tenant access).

**Endpoint**: `DELETE /api/v3/team/members/{userId}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `userId` | GUID | The user's unique identifier |

**Response**: `204 No Content`

---

## DTOs

### TeamMemberDto

| Field | Type | Nullable | Description |
|-------|------|----------|-------------|
| `userId` | GUID | No | User's unique identifier |
| `email` | string | Yes | User's email address |
| `name` | string | Yes | Display name (tenant-specific contact name if set, otherwise username) |
| `role` | RoleLevelDto | No | User's role in this tenant |
| `isCurrentUser` | boolean | No | Whether this user is the current authenticated user |
| `joinedAt` | DateTimeOffset | No | When the user joined this tenant |
| `phoneNumber` | string | Yes | User's phone number (tenant-specific) |

### RoleLevelDto

| Value | Description |
|-------|-------------|
| `unknown` | Unknown role |
| `admin` | Administrator |
| `worker` | Worker |
