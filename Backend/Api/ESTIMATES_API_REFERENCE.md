# Estimates API Reference

Complete reference for all Estimates API endpoints with request/response examples.

**Target Audience**: Frontend Developers, Backend Developers, QA Engineers

## Base Path

`/api/estimates` (v1/v2), `/api/v3/estimates` (v3-only endpoints)

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| PUT | `/api/estimates` | [Upsert estimate](#1-upsert-estimate) |
| GET | `/api/estimates` | [Get all estimates](#2-get-all-estimates) |
| GET | `/api/estimates/{id}` | [Get single estimate](#3-get-single-estimate) |
| DELETE | `/api/estimates/{id}:{version}` | [Delete estimate](#4-delete-estimate) |
| GET | `/api/v3/estimates/paged` | [Get paginated estimates](#5-get-paginated-estimates) |
| GET | `/api/v3/estimates/balances` | [Get balances](#6-get-balances) |
| GET | `/api/v3/estimates/balances-by-status` | [Get balances by status](#7-get-balances-by-status) |
| POST | `/api/estimates/{id}/web-link` | [Create web link](#8-create-web-link) |
| GET | `/api/estimates/{id}/pdf` | [Get PDF](#9-get-pdf) |
| GET | `/api/estimates/{id}/html-preview` | [Get HTML preview](#10-get-html-preview) |
| POST | `/api/estimates/build-html-preview` | [Build HTML preview](#11-build-html-preview) |
| GET | `/api/v3/estimates/timeline` | [Get estimates timeline](#12-get-estimates-timeline) |
| GET | `/api/v3/estimates/timeline/{entityId}` | [Get timeline by entity](#13-get-timeline-by-entity) |

---

## Write Operations

### 1. Upsert Estimate

Create or update an estimate. Send the full estimate object; the server will create a new estimate or update an existing one based on the `id`.

**Endpoint**: `PUT /api/estimates`

**Request Body**:

```json
{
  "id": "est_abc123",
  "version": 1,
  "date": "2025-10-20",
  "number": "E-1001",
  "status": "draft",
  "client": {
    "name": "Emily Johnson",
    "phone": "(310) 216-1600",
    "email": "emily.johnson@gmail.com",
    "address": "10848 Wagner St, Culver City, CA 90230",
    "catalogId": "client_123"
  },
  "items": [
    {
      "name": "Faucet installation",
      "details": "Includes parts and labor",
      "itemType": "service",
      "description": "Kitchen faucet replacement",
      "unitPrice": 120.00,
      "unitType": "hours",
      "quantity": 2,
      "discount": {
        "type": "percent",
        "value": 10.0
      },
      "isTaxApplied": true,
      "catalogId": "item-001"
    }
  ],
  "notes": "Valid for 30 days",
  "paymentDetails": "Bank transfer preferred",
  "discount": {
    "type": "percent",
    "value": 5.0
  },
  "tax": {
    "percentValue": 8.5,
    "type": "exclusive",
    "name": "Sales Tax"
  },
  "subtotalAmount": 216.00,
  "discountAmount": 10.80,
  "taxAmount": 17.44,
  "totalAmount": 222.64,
  "currencyCode": "USD",
  "attachments": [
    {
      "id": "att_001",
      "url": "https://storage.example.com/photo.jpg",
      "order": 0,
      "contentProperties": {
        "orientation": "portrait"
      }
    }
  ],
  "sentMethod": "email",
  "jobId": null,
  "invoiceId": null,
  "source": "none"
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Estimate identifier |
| `version` | integer | Yes | Version for optimistic concurrency |
| `createdOn` | string (ISO 8601) | No | Creation timestamp (set by server on create) |
| `date` | string (date) | Yes | Estimate date (date-only, e.g. `2025-10-20`) |
| `number` | string | No | Estimate number |
| `status` | string | No | Estimate status: `unknown`, `draft`, `sent`, `approved`, `canceled`, `done` |
| `client` | object | No | Client snapshot. See [Client Structure](#reference-client-structure) |
| `items` | array | No | Line items. See [Item Structure](#reference-item-structure) |
| `notes` | string | No | Estimate notes |
| `paymentDetails` | string | No | Payment details text |
| `discount` | object | No | Estimate-level discount. See [Discount Structure](#reference-discount-structure) |
| `tax` | object | No | Tax descriptor. See [Tax Structure](#reference-tax-structure) |
| `subtotalAmount` | decimal | No | Subtotal before discount/tax |
| `discountAmount` | decimal | No | Applied discount amount |
| `taxAmount` | decimal | No | Applied tax amount |
| `totalAmount` | decimal | No | Estimate total |
| `currencyCode` | string | No | Currency code (e.g. `USD`, `EUR`) |
| `mailStatus` | string | No | Email delivery status: `sent`, `inProgress`, `opened`, `markedAsSent`, `error` |
| `mailStatusErrorMessage` | string | No | Error message when `mailStatus` is `error` |
| `attachments` | array | No | Estimate attachments. See [Attachment Structure](#reference-attachment-structure) |
| `sentMethod` | string | No | How the estimate was sent: `email`, `manual` |
| `jobId` | string | No | Linked job ID (nullable). Client sends on create to link estimate to a job |
| `invoiceId` | string | No | Linked invoice ID (nullable, read-only). Server-computed from the shared job. Do NOT send on upsert |
| `source` | string | No | Creation origin (nullable, read-only). Values: `"none"`, `"job"`. Omitted for legacy records |

**Response**: `200 OK`

Returns the created/updated `EstimateDto`:

```json
{
  "id": "est_abc123",
  "version": 1,
  "createdOn": "2025-10-20T09:00:00Z",
  "date": "2025-10-20",
  "number": "E-1001",
  "status": "draft",
  "client": {
    "name": "Emily Johnson",
    "phone": "(310) 216-1600",
    "email": "emily.johnson@gmail.com",
    "address": "10848 Wagner St, Culver City, CA 90230",
    "catalogId": "client_123"
  },
  "items": [
    {
      "name": "Faucet installation",
      "details": "Includes parts and labor",
      "itemType": "service",
      "description": "Kitchen faucet replacement",
      "unitPrice": 120.00,
      "unitType": "hours",
      "quantity": 2,
      "discount": {
        "type": "percent",
        "value": 10.0
      },
      "isTaxApplied": true,
      "catalogId": "item-001"
    }
  ],
  "notes": "Valid for 30 days",
  "paymentDetails": "Bank transfer preferred",
  "discount": {
    "type": "percent",
    "value": 5.0
  },
  "tax": {
    "percentValue": 8.5,
    "type": "exclusive",
    "name": "Sales Tax"
  },
  "subtotalAmount": 216.00,
  "discountAmount": 10.80,
  "taxAmount": 17.44,
  "totalAmount": 222.64,
  "currencyCode": "USD",
  "mailStatus": null,
  "mailStatusErrorMessage": null,
  "attachments": [
    {
      "id": "att_001",
      "url": "https://storage.example.com/photo.jpg",
      "order": 0,
      "contentProperties": {
        "orientation": "portrait"
      }
    }
  ],
  "sentMethod": "email",
  "jobId": null,
  "invoiceId": null,
  "source": "none"
}
```

**Business Rules**:
- Attachments are synchronized server-side via the attachments service during upsert.
- The full estimate object is sent on each save (PUT semantics).

---

## Read Operations

### 2. Get All Estimates

Get all estimates for the current account.

**Endpoint**: `GET /api/estimates`

**Response**: `200 OK`

Returns an array of `EstimateDto` objects (same structure as [Upsert Estimate](#1-upsert-estimate) response).

```json
[
  {
    "id": "est_abc123",
    "version": 1,
    "createdOn": "2025-10-20T09:00:00Z",
    "date": "2025-10-20",
    "number": "E-1001",
    "status": "approved",
    "client": { "name": "Emily Johnson", "catalogId": "client_123" },
    "items": [],
    "subtotalAmount": 1200.00,
    "discountAmount": 0,
    "taxAmount": 0,
    "totalAmount": 1200.00,
    "currencyCode": "USD",
    "attachments": [],
    "jobId": null
  }
]
```

---

### 3. Get Single Estimate

Get detailed information about a specific estimate.

**Endpoint**: `GET /api/estimates/{id}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Estimate ID |

**Example Request**:

```
GET /api/estimates/est_abc123
```

**Response**: `200 OK`

Returns a single `EstimateDto` (same structure as [Upsert Estimate](#1-upsert-estimate) response).

---

### 5. Get Paginated Estimates

Get estimates with cursor-based pagination and optional filtering.

**Endpoint**: `GET /api/v3/estimates/paged`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `limit` | integer | No | Items per page (default: `50`) |
| `token` | string | No | Pagination cursor from previous response |
| `clientId` | string | No | Filter by client ID |
| `estimateStatus` | string (repeatable) | No | Filter by status. Can be repeated for multiple values (e.g. `estimateStatus=draft&estimateStatus=sent`). Values: `unknown`, `draft`, `sent`, `approved`, `canceled`, `done` |

**Example Request**:

```
GET /api/v3/estimates/paged?limit=20&estimateStatus=draft&estimateStatus=sent
```

**Response**: `200 OK`

```json
{
  "items": [
    {
      "id": "est_abc123",
      "version": 1,
      "createdOn": "2025-10-20T09:00:00Z",
      "date": "2025-10-20",
      "number": "E-1001",
      "status": "draft",
      "client": { "name": "Emily Johnson", "catalogId": "client_123" },
      "items": [],
      "subtotalAmount": 1200.00,
      "discountAmount": 0,
      "taxAmount": 0,
      "totalAmount": 1200.00,
      "currencyCode": "USD",
      "attachments": [],
      "jobId": null
    }
  ],
  "nextToken": "eyJpZCI6ImVzdF94eXoifQ==",
  "totalCount": 42
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | List of `EstimateDto` objects |
| `nextToken` | string | Pagination cursor for next page (null if no more pages) |
| `totalCount` | integer | Total count of matching estimates (nullable) |

---

### 6. Get Balances

Get aggregate balance totals for estimates, grouped by currency.

**Endpoint**: `GET /api/v3/estimates/balances`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `clientId` | string | No | Filter by client ID |

**Example Request**:

```
GET /api/v3/estimates/balances
```

**Response**: `200 OK`

```json
{
  "balances": [
    {
      "currencyCode": "USD",
      "totalAmount": 14590.00
    },
    {
      "currencyCode": "EUR",
      "totalAmount": 3200.00
    }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `balances` | array | Balance totals grouped by currency |
| `balances[].currencyCode` | string | Currency code (e.g. `USD`) |
| `balances[].totalAmount` | decimal | Sum of estimate totals in this currency |

---

### 7. Get Balances by Status

Get estimate balance totals broken down by status, with overall totals.

**Endpoint**: `GET /api/v3/estimates/balances-by-status`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `clientId` | string | No | Filter by client ID |

**Example Request**:

```
GET /api/v3/estimates/balances-by-status
```

**Response**: `200 OK`

```json
{
  "total": {
    "count": 25,
    "byCurrency": [
      { "currencyCode": "USD", "totalAmount": 14590.00 }
    ]
  },
  "totalOpen": {
    "count": 10,
    "byCurrency": [
      { "currencyCode": "USD", "totalAmount": 6200.00 }
    ]
  },
  "byStatus": {
    "draft": {
      "count": 3,
      "byCurrency": [
        { "currencyCode": "USD", "totalAmount": 1200.00 }
      ]
    },
    "sent": {
      "count": 4,
      "byCurrency": [
        { "currencyCode": "USD", "totalAmount": 2400.00 }
      ]
    },
    "approved": {
      "count": 3,
      "byCurrency": [
        { "currencyCode": "USD", "totalAmount": 2600.00 }
      ]
    },
    "canceled": {
      "count": 5,
      "byCurrency": [
        { "currencyCode": "USD", "totalAmount": 3190.00 }
      ]
    },
    "done": {
      "count": 10,
      "byCurrency": [
        { "currencyCode": "USD", "totalAmount": 5200.00 }
      ]
    }
  }
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `total` | object | Aggregate totals across all statuses |
| `total.count` | integer | Total number of estimates |
| `total.byCurrency` | array | Balance totals grouped by currency |
| `totalOpen` | object | Aggregate totals for open (non-final) estimates |
| `totalOpen.count` | integer | Number of open estimates |
| `totalOpen.byCurrency` | array | Balance totals grouped by currency |
| `byStatus` | object | Breakdown by estimate status. Keys are status values: `draft`, `sent`, `approved`, `canceled`, `done` |
| `byStatus.{status}.count` | integer | Number of estimates in this status |
| `byStatus.{status}.byCurrency` | array | Balance totals grouped by currency |

Each `byCurrency` entry:

| Field | Type | Description |
|-------|------|-------------|
| `currencyCode` | string | Currency code (e.g. `USD`) |
| `totalAmount` | decimal | Sum of estimate totals in this currency |

---

## Delete Operations

### 4. Delete Estimate

Delete an estimate. The ID and version are passed as a single compound path parameter.

**Endpoint**: `DELETE /api/estimates/{id}:{version}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Estimate ID |
| `version` | integer | Estimate version for optimistic concurrency |

**Example Request**:

```
DELETE /api/estimates/est_abc123:3
```

**Response**: `200 OK` (empty body)

**Business Rules**:
- The `id` and `version` are combined in the path as `{id}:{version}` (colon-separated).
- Any linked content is unlinked before deletion. If unlinking fails, the estimate is still deleted.

---

## Utility Endpoints

### 8. Create Web Link

Generate a shareable short URL for an estimate with a QR code.

**Endpoint**: `POST /api/estimates/{id}/web-link`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Estimate ID |

**Example Request**:

```
POST /api/estimates/est_abc123/web-link
```

**Response**: `200 OK`

```json
{
  "qrCode": "data:image/png;base64,iVBOR...",
  "url": "https://app.example.com/e/abc123",
  "urlPersonalized": "https://app.example.com/e/abc123?ref=user",
  "previewUrl": "https://app.example.com/preview/abc123"
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `qrCode` | string | Base64-encoded QR code image |
| `url` | string | Short URL for the estimate |
| `urlPersonalized` | string | Personalized URL variant (nullable) |
| `previewUrl` | string | Preview URL for the estimate (nullable) |

---

### 9. Get PDF

Download the estimate as a PDF file.

**Endpoint**: `GET /api/estimates/{id}/pdf`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Estimate ID |

**Example Request**:

```
GET /api/estimates/est_abc123/pdf
```

**Response**: `200 OK` with `Content-Type: application/pdf`

Returns the binary PDF file content.

**Note**: This endpoint supports authentication via query parameter (`AuthAlsoInQuery` attribute) for use in contexts where headers cannot be set (e.g., browser download links).

---

### 10. Get HTML Preview

Get a rendered HTML preview of an existing estimate.

**Endpoint**: `GET /api/estimates/{id}/html-preview`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Estimate ID |

**Example Request**:

```
GET /api/estimates/est_abc123/html-preview
```

**Response**: `200 OK` with `Content-Type: text/html`

Returns the rendered HTML content as a string.

**Note**: This endpoint supports authentication via query parameter (`AuthAlsoInQuery` attribute).

---

### 11. Build HTML Preview

Generate an HTML preview from an estimate object without saving it. Useful for live preview while editing.

**Endpoint**: `POST /api/estimates/build-html-preview`

**Request Body**:

```json
{
  "estimate": {
    "id": "est_abc123",
    "version": 1,
    "date": "2025-10-20",
    "number": "E-1001",
    "status": "draft",
    "client": { "name": "Emily Johnson" },
    "items": [],
    "subtotalAmount": 0,
    "discountAmount": 0,
    "taxAmount": 0,
    "totalAmount": 0,
    "attachments": []
  },
  "templateParams": {
    "colorScheme": "#4A90D9",
    "templateName": "default"
  }
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `estimate` | object | Yes | Full `EstimateDto` to render (same structure as upsert request) |
| `templateParams` | object | No | Template customization parameters (nullable) |
| `templateParams.colorScheme` | string | Yes (if templateParams provided) | Color scheme hex value |
| `templateParams.templateName` | string | No | Template name: `default`, `formal`, `wide`, `construction`, `beauty`, `two-sided` |

**Response**: `200 OK` with `Content-Type: text/html`

Returns the rendered HTML content as a string.

---

## Timeline Endpoints

### 12. Get Estimates Timeline

Get a paginated timeline of estimate events across all estimates. See also the [Timeline API Reference](TIMELINE_API_REFERENCE.md) for the global aggregated timeline.

**Endpoint**: `GET /api/v3/estimates/timeline`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pageSize` | integer | No | Maximum events per page (default: `100`) |
| `cursor` | string | No | Pagination cursor from previous response's `nextCursor` |

**Example Request**:

```
GET /api/v3/estimates/timeline?pageSize=20
```

**Response**: `200 OK`

```json
{
  "items": [
    {
      "id": 1001,
      "accountId": "acc_xyz789",
      "entityId": "est_abc123",
      "masterUserId": "user_456",
      "createdAt": "2025-10-28T14:00:00Z",
      "occurredAt": "2025-10-28T14:00:00Z",
      "eventType": "estimateStatusChanged",
      "actorType": "user",
      "payload": "{\"previousStatus\":\"draft\",\"newStatus\":\"sent\"}",
      "entityVersion": 2
    }
  ],
  "nextCursor": "eyJjdXJzb3IiOiIyMDI1LTEwLTI4VDE0OjAwOjAwWiJ9",
  "hasMore": false
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | Timeline items ordered by `occurredAt` descending |
| `nextCursor` | string | Cursor for fetching next page (null if no more pages) |
| `hasMore` | boolean | Whether more events exist beyond this page |

Each item in `items` is a **TimelineItemDto**:

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Numeric sequence identifier |
| `accountId` | string | Account identifier |
| `entityId` | string | Estimate identifier |
| `masterUserId` | string | User who triggered the event (nullable) |
| `createdAt` | string (ISO 8601) | When the event was recorded |
| `occurredAt` | string (ISO 8601) | When the event occurred |
| `eventType` | string | Type of event (see [Estimate Event Types](#reference-estimate-event-types)) |
| `actorType` | string | Actor classification: `unknown`, `user`, `system`, `external` |
| `payload` | string | JSON string with event-specific data |
| `entityVersion` | integer | Estimate version when the event was generated |

---

### 13. Get Timeline by Entity

Get the timeline for a specific estimate.

**Endpoint**: `GET /api/v3/estimates/timeline/{entityId}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `entityId` | string | Estimate ID |

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `limit` | integer | No | Maximum events to return (default: `100`) |

**Example Request**:

```
GET /api/v3/estimates/timeline/est_abc123?limit=50
```

**Response**: `200 OK`

```json
{
  "items": [
    {
      "id": 1001,
      "accountId": "acc_xyz789",
      "entityId": "est_abc123",
      "masterUserId": "user_456",
      "createdAt": "2025-10-28T14:00:00Z",
      "occurredAt": "2025-10-28T14:00:00Z",
      "eventType": "estimateStatusChanged",
      "actorType": "user",
      "payload": "{\"previousStatus\":\"draft\",\"newStatus\":\"sent\"}",
      "entityVersion": 2
    }
  ],
  "nextCursor": null,
  "hasMore": false
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | Timeline items for this estimate |
| `nextCursor` | string | Cursor for next page (nullable) |
| `hasMore` | boolean | Whether more events exist |

---

## Reference: Estimate Status Values

| Value | API String | Description |
|-------|------------|-------------|
| `Unknown` | `unknown` | Unknown or unset status |
| `Draft` | `draft` | Estimate is in draft |
| `Sent` | `sent` | Estimate has been sent to the client |
| `Approved` | `approved` | Client approved the estimate |
| `Canceled` | `canceled` | Estimate was canceled |
| `Done` | `done` | Estimate is finalized/done |

---

## Reference: Estimate Sent Method Values

| Value | API String | Description |
|-------|------------|-------------|
| `Email` | `email` | Sent via email |
| `Manual` | `manual` | Marked as sent manually |

Note: `unknown` is used internally and maps to `null` in the API response.

---

## Reference: Estimate Event Types

| Value | Description | Payload Fields |
|-------|-------------|----------------|
| `estimateStatusChanged` | Estimate status changed | `previousStatus`, `newStatus` (estimate status values) |
| `estimateEmailStatusChanged` | Email delivery status changed | (from email service) |
| `estimateInvoiceCreated` | Invoice created from this estimate | (invoice reference) |
| `estimateJobCreated` | Job created from this estimate | (job reference) |

---

## Reference: Client Structure

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Client name (nullable) |
| `phone` | string | Client phone number (nullable) |
| `email` | string | Client email address (nullable) |
| `address` | string | Client address (nullable) |
| `catalogId` | string | Client catalog identifier (nullable) |

---

## Reference: Item Structure

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | No | Item name |
| `details` | string | No | Item details |
| `itemType` | string | No | Item type: `none`, `service`, `material` |
| `description` | string | No | Item description |
| `unitPrice` | decimal | Yes | Price per unit |
| `unitType` | string | No | Unit type: `none`, `hours`, `days` |
| `quantity` | decimal | Yes | Quantity |
| `discount` | object | No | Item-level discount. See [Discount Structure](#reference-discount-structure) |
| `isTaxApplied` | boolean | Yes | Whether tax applies to this item |
| `catalogId` | string | No | Catalog item identifier |

---

## Reference: Discount Structure

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `value` | decimal | Yes | Discount value |
| `type` | string | Yes | Discount type: `percent`, `absolute` |

---

## Reference: Tax Structure

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `percentValue` | decimal | Yes | Tax percentage |
| `type` | string | Yes | Tax type: `inclusive`, `exclusive` |
| `name` | string | No | Tax name (e.g. "Sales Tax") |

---

## Reference: Attachment Structure

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Attachment identifier |
| `url` | string | Attachment URL (nullable) |
| `order` | integer | Display order |
| `contentProperties` | object | Additional properties (nullable) |
| `contentProperties.orientation` | string | Image orientation: `unknown`, `landscape`, `portrait` |

---

## Reference: Email Status Values

| Value | API String | Description |
|-------|------------|-------------|
| `Sent` | `sent` | Email was sent |
| `InProgress` | `inProgress` | Email is being sent |
| `Opened` | `opened` | Email was opened by recipient |
| `MarkedAsSent` | `markedAsSent` | Manually marked as sent |
| `Error` | `error` | Email delivery failed |
