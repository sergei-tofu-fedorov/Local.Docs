# Items API Reference

Complete reference for all Items API endpoints with request/response examples.

**Target Audience**: Frontend Developers, Backend Developers, QA Engineers

## Base Path

`/api/v3/items`

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v3/items` | [Create or update item](#1-create-or-update-item) |
| GET | `/api/v3/items` | [Get all items](#2-get-all-items) |
| GET | `/api/v3/items/paged` | [Get paginated items](#3-get-paginated-items) |
| GET | `/api/v3/items/{itemId}` | [Get single item](#4-get-single-item) |
| GET | `/api/v3/items/summary` | [Get items summary](#5-get-items-summary) |
| DELETE | `/api/v3/items/{itemId}` | [Delete item](#6-delete-item) |

---

## Write Operations

### 1. Create or Update Item

Create a new item or update an existing one.

**Endpoint**: `POST /api/v3/items`

**Request Body**:

```json
{
  "id": "item_abc123",
  "version": 0,
  "createdAt": null,
  "info": {
    "name": "Faucet Installation",
    "price": 120.00,
    "unitType": "hours",
    "taxable": true,
    "type": "service",
    "description": "Standard faucet installation service"
  }
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Item identifier. |
| `version` | integer | Yes | Item version for optimistic concurrency. Use `0` for new items. |
| `createdAt` | string (ISO 8601) | No | Creation timestamp. When `null`, defaults to current UTC time on create. |
| `info` | object | Yes | Item details. See fields below. |
| `info.name` | string | Yes | Item name. |
| `info.price` | decimal | No | Unit price. Defaults to `0`. |
| `info.unitType` | string | Yes | Unit of measurement: `none`, `hours`, `days`. |
| `info.taxable` | boolean | Yes | Whether tax applies to this item. |
| `info.type` | string | Yes | Item type: `none`, `service`, `material`. |
| `info.description` | string | No | Item description (nullable). |

**Response**: `200 OK`

```json
{
  "id": "item_abc123",
  "version": 1,
  "createdAt": "2026-03-05T10:00:00Z",
  "updatedAt": null,
  "info": {
    "name": "Faucet Installation",
    "price": 120.00,
    "unitType": "hours",
    "taxable": true,
    "type": "service",
    "description": "Standard faucet installation service"
  }
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Item identifier |
| `version` | integer | Current item version |
| `createdAt` | string (ISO 8601) | When the item was created |
| `updatedAt` | string (ISO 8601) | When the item was last updated (nullable) |
| `info` | object | Item details (see request fields above) |

---

### 6. Delete Item

Delete an item by ID.

**Endpoint**: `DELETE /api/v3/items/{itemId}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `itemId` | string | Item ID |

**Response**: `204 No Content`

---

## Read Operations

### 2. Get All Items

Get all items for the account.

**Endpoint**: `GET /api/v3/items`

**Response**: `200 OK`

```json
{
  "items": [
    {
      "id": "item_abc123",
      "version": 1,
      "createdAt": "2026-03-05T10:00:00Z",
      "updatedAt": null,
      "info": {
        "name": "Faucet Installation",
        "price": 120.00,
        "unitType": "hours",
        "taxable": true,
        "type": "service",
        "description": "Standard faucet installation service"
      }
    },
    {
      "id": "item_def456",
      "version": 2,
      "createdAt": "2026-02-15T08:30:00Z",
      "updatedAt": "2026-03-01T14:00:00Z",
      "info": {
        "name": "Copper Pipe",
        "price": 25.50,
        "unitType": "none",
        "taxable": true,
        "type": "material",
        "description": "1/2 inch copper pipe per foot"
      }
    }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | List of items. Each element is a full item object (see [Create or Update Item](#1-create-or-update-item) response). |

---

### 3. Get Paginated Items

Get items with cursor-based pagination and optional filtering.

**Endpoint**: `GET /api/v3/items/paged`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `limit` | integer | No | Items per page (default: `10`) |
| `token` | string | No | Pagination cursor from previous response |
| `itemTypeDto` | string | No | Filter by item type: `none`, `service`, `material` |
| `itemName` | string | No | Filter by item name (substring match) |

**Example Request**:

```
GET /api/v3/items/paged?limit=20&itemTypeDto=service
```

**Response**: `200 OK`

```json
{
  "items": [
    {
      "id": "item_abc123",
      "version": 1,
      "createdAt": "2026-03-05T10:00:00Z",
      "updatedAt": null,
      "info": {
        "name": "Faucet Installation",
        "price": 120.00,
        "unitType": "hours",
        "taxable": true,
        "type": "service",
        "description": "Standard faucet installation service"
      }
    }
  ],
  "nextToken": "eyJpZCI6Iml0ZW1fYWJjMTIzIn0=",
  "totalCount": null
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | List of items. Each element is a full item object (see [Create or Update Item](#1-create-or-update-item) response). |
| `nextToken` | string | Pagination cursor for next page (null if no more pages) |
| `totalCount` | integer | Total count (currently always null) |

---

### 4. Get Single Item

Get a single item by ID.

**Endpoint**: `GET /api/v3/items/{itemId}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `itemId` | string | Item ID |

**Example Request**:

```
GET /api/v3/items/item_abc123
```

**Response**: `200 OK`

```json
{
  "id": "item_abc123",
  "version": 1,
  "createdAt": "2026-03-05T10:00:00Z",
  "updatedAt": null,
  "info": {
    "name": "Faucet Installation",
    "price": 120.00,
    "unitType": "hours",
    "taxable": true,
    "type": "service",
    "description": "Standard faucet installation service"
  }
}
```

**Response Fields**: See [Create or Update Item](#1-create-or-update-item) response.

---

### 5. Get Items Summary

Get a summary of item counts grouped by type.

**Endpoint**: `GET /api/v3/items/summary`

**Example Request**:

```
GET /api/v3/items/summary
```

**Response**: `200 OK`

```json
{
  "total": 15,
  "byType": {
    "service": 8,
    "material": 7
  }
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `total` | integer | Total number of items |
| `byType` | object | Item count per type. Keys are item type values: `none`, `service`, `material`. Values are counts. |

---

## Reference: Enums

### Item Type

| Value | Description |
|-------|-------------|
| `none` | No type specified |
| `service` | Service item |
| `material` | Material item |

### Unit Type

| Value | Description |
|-------|-------------|
| `none` | No unit |
| `hours` | Hourly rate |
| `days` | Daily rate |
