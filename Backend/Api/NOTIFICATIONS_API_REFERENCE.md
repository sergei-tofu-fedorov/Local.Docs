# Notifications API Reference

Complete reference for notification endpoints with request/response examples.

**Target Audience**: Frontend Developers, Backend Developers, QA Engineers

## Base Path

`/api/v3/notifications`

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v3/notifications` | List notifications (polling) |
| POST | `/api/v3/notifications/{id}/read` | Mark a notification as read |

---

## Read Operations

### 1. List Notifications (Polling)

Fetch notifications in reverse chronological order with keyset pagination.
The list includes account-wide notifications (`master_user_id` is null) plus
user-scoped notifications for the current master user.

**Endpoint**: `GET /api/v3/notifications`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `unread` | boolean | No | When `true`, returns only unread notifications |
| `type` | NotificationType | No | Filter by notification type enum (e.g., `firstPaymentReceived`) |
| `limit` | integer | No | Items per page (default 50, max 100) |
| `cursor` | string | No | Pagination cursor from previous response |

**NotificationType Values**: `unknown`, `firstPaymentReceived`, `pspOnboardingCompleted`

**Cursor Format**:

The cursor is an opaque string built from `(createdAt, notificationId)`.
Recommended format: `createdAt|notificationId` using ISO 8601 for `createdAt`,
then base64-encode the full string.

**Example Request**:

```
GET /api/v3/notifications?unread=true&limit=20
```

**Response**: `200 OK`

```json
{
  "items": [
    {
      "id": 1001,
      "type": "firstPaymentReceived",
      "payload": "{\"amount\":120.50,\"currencySign\":\"$\",\"clientName\":\"Emily Johnson\",\"documentNumber\":\"1001\"}",
      "createdAt": "2026-01-12T16:30:00Z",
      "readAt": null,
      "source": "payments"
    }
  ],
  "nextCursor": "MjAyNi0wMS0xMlQxNjozMDowMFp8MTAwMQ=="
}
```

**NotificationSource Values**: `unknown`, `payments`, `stripe`

> **Note**: The `payload` field contains a JSON-encoded string. Clients must parse it to access notification-specific data.

**Errors**:
| Status | Reason |
|--------|--------|
| 401 | Unauthorized |
| 403 | Forbidden |
| 400 | Validation error (invalid query params) |

---

## Write Operations

### 2. Mark Notification as Read

Marks a single notification as read (idempotent). A user can only read
account-wide notifications or those scoped to their `master_user_id`.

**Endpoint**: `POST /api/v3/notifications/{id}/read`

**Example Request**:

```
POST /api/v3/notifications/1001/read
```

**Response**: `204 No Content`

**Errors**:
| Status | Reason |
|--------|--------|
| 401 | Unauthorized |
| 403 | Forbidden |
| 404 | Notification not found |

---

## Future Endpoints (Not Yet Implemented)

The following endpoints are planned for future implementation:

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v3/notifications/read` | Mark multiple notifications as read (bulk) |
| GET | `/api/v3/notifications/stream` | Stream notifications via SSE |
