# Invoices API Reference

Complete reference for all Invoices API endpoints with request/response examples.

**Target Audience**: Frontend Developers, Backend Developers, QA Engineers

## Base Path

`/api/invoices` (V1/V2) · `/api/v3/invoices` (V3)

## Endpoints Overview

| Method | Endpoint | Version | Description |
|--------|----------|---------|-------------|
| PUT | `/api/invoices` | V1+ | [Upsert invoice](#1-upsert-invoice) |
| DELETE | `/api/invoices/{id}:{version}` | V1+ | [Delete invoice](#2-delete-invoice) |
| POST | `/api/invoices/{id}/web-link` | V1+ | [Create web link](#3-create-web-link) |
| GET | `/api/invoices/{id}/pdf` | V1+ | [Get PDF by ID](#4-get-pdf-by-id) |
| GET | `/api/invoices/{id}/html-preview` | V1+ | [Get HTML preview by ID](#5-get-html-preview-by-id) |
| GET | `/api/v3/invoices` | V3 | [Get all invoices](#6-get-all-invoices) |
| GET | `/api/v3/invoices/paged` | V3 | [Get paginated invoices](#7-get-paginated-invoices) (with optional status filter) |
| GET | `/api/v3/invoices/balances` | V3 | [Get invoice balances](#8-get-invoice-balances) (totals by currency) |
| GET | `/api/v3/invoices/stats/paid` | V3 | [Get paid stats (alias)](#get-paid-stats-alias) — alias for `/api/reports/stats/paid` |
| GET | `/api/v3/invoices/{id}` | V3 | [Get single invoice](#9-get-single-invoice) |
| GET | `/api/v3/invoices/pnl-report` | V3 | [Get P&L report](#10-get-pl-report) (paid/unpaid breakdown by period) |
| GET | `/api/v3/invoices/pdf` | V3 | [Get PDF via query string](#11-get-pdf-via-query-string) |
| POST | `/api/v3/invoices/pdf` | V3 | [Get PDF via POST](#12-get-pdf-via-post) |
| POST | `/api/v3/invoices/build-html-preview` | V3 | [Build HTML preview](#13-build-html-preview) |
| POST | `/api/v3/invoices/calculate-table-details` | V3 | [Calculate table details](#14-calculate-table-details) |
| GET | `/api/v3/invoices/timeline` | V3 | [Get invoice timeline](#15-get-invoice-timeline) (cursor-based) |
| GET | `/api/v3/invoices/timeline/{entityId}` | V3 | [Get timeline by invoice](#16-get-timeline-by-invoice) |
| GET | `/api/v3/invoices/sync` | V3 | [Sync invoices](#17-sync-invoices) (cursor-based, change-only) |

---

## Write Operations (V1+)

These endpoints are defined in the V1 controller and available across **all API versions**.

### 1. Upsert Invoice

Create or update an invoice. When the `id` matches an existing invoice, it updates; otherwise it creates.

**Endpoint**: `PUT /api/invoices`

**Request Body**: An [InvoiceDto](#reference-shared-structures) object. All fields are sent in the same format as the response.

```json
{
  "id": "inv_abc123",
  "version": 1,
  "createdOn": "2025-10-15T09:30:00",
  "client": {
    "name": "Emily Johnson",
    "email": "emily.johnson@gmail.com"
  },
  "date": "2025-10-15",
  "dueDays": 30,
  "number": "INV-0042",
  "status": "notPaid",
  "items": [
    {
      "name": "Web Development",
      "unitPrice": 150.00,
      "quantity": 10,
      "isTaxApplied": true
    }
  ],
  "subtotalAmount": 1500.00,
  "discountAmount": 0,
  "taxAmount": 0,
  "totalAmount": 1500.00,
  "totalDue": 1500.00,
  "attachments": []
}
```

**Response**: `200 OK` — Returns the saved [InvoiceDto](#6-get-all-invoices).

**Notes**:
- Attachments are synced automatically — new attachment IDs are linked, removed ones are unlinked.
- The `version` field enables optimistic concurrency; pass the current version on update.

---

### 2. Delete Invoice

Delete an invoice by ID and version.

**Endpoint**: `DELETE /api/invoices/{id}:{version}`

**Path Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Invoice ID |
| `version` | integer | Yes | Invoice version (colon-separated, e.g. `inv_abc123:3`) |

**Response**: `200 OK`

**Notes**:
- All linked content/attachments are automatically unlinked before deletion.
- The colon-separated format `{id}:{version}` prevents accidental deletion of stale data.

---

### 3. Create Web Link

Generate a shareable short URL for an invoice.

**Endpoint**: `POST /api/invoices/{id}/web-link`

**Path Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Invoice ID |

**Response**: `200 OK`

```json
{
  "url": "https://app.example.com/i/abc123",
  "qrCodeUrl": "https://app.example.com/qr/abc123"
}
```

---

### 4. Get PDF by ID

Download a PDF for a specific invoice by its ID.

**Endpoint**: `GET /api/invoices/{id}/pdf`

**Path Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Invoice ID |

**Response**: `200 OK` with `Content-Type: application/pdf`

Returns the PDF file as a binary stream. Supports authentication via query string (`AuthAlsoInQuery`).

---

### 5. Get HTML Preview by ID

Get a rendered HTML preview for a specific invoice.

**Endpoint**: `GET /api/invoices/{id}/html-preview`

**Path Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Invoice ID |

**Response**: `200 OK` with `Content-Type: text/html`

Returns the rendered HTML string. Supports authentication via query string (`AuthAlsoInQuery`).

---

## Read Operations (V3)

> **V1/V2 vs V3 status mapping**: The V1/V2 `GET /api/invoices` endpoint maps both `paidByCard` and `paid` to `paid` in the response. The V3 endpoint preserves the `paidByCard` status separately. Both versions map `refunded`/`partialRefunded` to `paidByCard`.

### 6. Get All Invoices

Retrieve all invoices for the authenticated account.

**Endpoint**: `GET /api/v3/invoices`

**Response**: `200 OK`

Returns an array of **InvoiceDto** objects:

```json
[
  {
    "id": "inv_abc123",
    "version": 3,
    "createdOn": "2025-10-15T09:30:00",
    "client": {
      "name": "Emily Johnson",
      "phone": "(310) 216-1600",
      "email": "emily.johnson@gmail.com",
      "address": "10848 Wagner St, Culver City, CA 90230",
      "catalogId": "client_123"
    },
    "date": "2025-10-15",
    "dueDays": 30,
    "number": "INV-0042",
    "status": "notPaid",
    "mailStatus": "sent",
    "mailStatusErrorMessage": null,
    "items": [
      {
        "name": "Web Development",
        "details": "Frontend implementation",
        "itemType": "service",
        "description": "React dashboard build",
        "unitPrice": 150.00,
        "unitType": "hours",
        "quantity": 10,
        "discount": null,
        "isTaxApplied": true,
        "catalogId": "item-001"
      }
    ],
    "notes": "Payment due within 30 days",
    "discount": {
      "value": 5.0,
      "type": "percent"
    },
    "tax": {
      "percentValue": 8.5,
      "type": "exclusive",
      "name": "Sales Tax"
    },
    "subtotalAmount": 1500.00,
    "discountAmount": 75.00,
    "taxAmount": 121.13,
    "totalAmount": 1546.13,
    "receivedPayments": [500.00],
    "totalDue": 1046.13,
    "markAsPaidDate": null,
    "paidDate": null,
    "acceptedPaymentProviders": ["stripe"],
    "paidByProvider": null,
    "currencyCode": "USD",
    "jobId": "job_456",
    "estimateId": "est_789",
    "source": "job",
    "paymentDetails": {
      "lastReceiptId": "re_abc",
      "lastReceiptUrl": "https://pay.stripe.com/receipts/...",
      "lastPspAccountId": "acct_123"
    },
    "attachments": [
      {
        "id": "att_001",
        "url": "https://storage.example.com/photo.jpg",
        "order": 0,
        "contentProperties": {
          "orientation": "portrait"
        }
      }
    ]
  }
]
```

**Response Fields** (InvoiceDto):

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Invoice identifier |
| `version` | integer | Version for optimistic concurrency |
| `createdOn` | string (datetime) | Local date and time when the invoice was created (nullable) |
| `client` | object | Client snapshot (nullable). See [Client Structure](#reference-client-structure). |
| `date` | string (date) | Invoice date in UTC (date-only format) |
| `dueDays` | integer | Number of days until due (nullable) |
| `number` | string | Invoice number (nullable) |
| `status` | string | Invoice status: `notPaid`, `paid`, `paidByCard`. Note: `refunded` and `partialRefunded` are mapped to `paidByCard` in the API response. |
| `mailStatus` | string | Email delivery status (nullable): `sent`, `inProgress`, `opened`, `markedAsSent`, `error` |
| `mailStatusErrorMessage` | string | Error message when `mailStatus` is `error` (nullable) |
| `items` | array | Line items. See [Item Structure](#reference-item-structure). |
| `notes` | string | Free-text notes (nullable) |
| `discount` | object | Invoice-level discount (nullable). See [Discount Structure](#reference-discount-structure). |
| `tax` | object | Tax configuration (nullable). See [Tax Structure](#reference-tax-structure). |
| `subtotalAmount` | decimal | Subtotal before discount and tax |
| `discountAmount` | decimal | Total discount amount |
| `taxAmount` | decimal | Total tax amount |
| `totalAmount` | decimal | Grand total |
| `receivedPayments` | array of decimal | List of partial payment amounts (nullable) |
| `totalDue` | decimal | Remaining amount due |
| `markAsPaidDate` | string (datetime) | Date the invoice was marked as paid (nullable). Defaults to `date` if status is `paid` or `paidByCard` and no explicit value is set. |
| `paidDate` | string (datetime) | Date the invoice was paid (nullable). For `paidByCard` status, defaults to `markAsPaidDate` if not set. |
| `acceptedPaymentProviders` | array of string | Enabled payment providers (nullable), e.g. `["stripe"]` |
| `paidByProvider` | string | Provider that processed the payment (nullable) |
| `currencyCode` | string | ISO 4217 currency code (nullable), e.g. `USD`, `EUR`, `GBP`. Falls back to the account currency. |
| `jobId` | string | Linked job ID (nullable). Client sends on create to link invoice to a job |
| `estimateId` | string | Linked estimate ID (nullable). Client sends when creating invoice from estimate |
| `source` | string | Creation origin (nullable, read-only). Values: `"none"`, `"estimate"`, `"job"`. Omitted for legacy records |
| `paymentDetails` | object | Payment receipt details (nullable). See [Payment Details Structure](#reference-payment-details-structure). |
| `attachments` | array | Attached files. See [Attachment Structure](#reference-attachment-structure). |

---

### 7. Get Paginated Invoices

Get invoices with cursor-based pagination and optional filtering.

**Endpoint**: `GET /api/v3/invoices/paged`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `limit` | integer | No | Items per page, default: 50 |
| `token` | string | No | Pagination cursor from previous response |
| `clientId` | string | No | Filter by client ID |
| `invoiceStatus` | string | No | Filter by payment status: `notPaid`, `paid` |

**Example Request**:

```
GET /api/v3/invoices/paged?limit=20&invoiceStatus=notPaid
```

**Response**: `200 OK`

```json
{
  "items": [
    {
      "id": "inv_abc123",
      "version": 3,
      "status": "notPaid",
      "number": "INV-0042",
      "totalAmount": 1546.13,
      "totalDue": 1046.13
    }
  ],
  "nextToken": "eyJpZCI6Imludl8xMjMifQ",
  "totalCount": 42
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | Array of [InvoiceDto](#6-get-all-invoices) objects |
| `nextToken` | string | Cursor for the next page (nullable). Pass as `token` to fetch the next page. `null` when no more results. |
| `totalCount` | integer | Total number of matching invoices (nullable) |

---

### 8. Get Invoice Balances

Get aggregated balance totals across all invoices, grouped by currency.

**Endpoint**: `GET /api/v3/invoices/balances`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `clientId` | string | No | Filter balances by client ID |

**Example Request**:

```
GET /api/v3/invoices/balances?clientId=client_123
```

**Response**: `200 OK`

```json
{
  "balances": [
    {
      "currencyCode": "USD",
      "totalPaid": 15000.00,
      "totalDue": 3200.50,
      "totalAmount": 18200.50
    }
  ],
  "paidInvoicesCount": 12,
  "unpaidInvoicesCount": 5
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `balances` | array | Balance totals grouped by currency |
| `balances[].currencyCode` | string | ISO 4217 currency code |
| `balances[].totalPaid` | decimal | Sum of paid amounts |
| `balances[].totalDue` | decimal | Sum of outstanding amounts |
| `balances[].totalAmount` | decimal | Sum of all invoice totals |
| `paidInvoicesCount` | integer | Number of paid invoices |
| `unpaidInvoicesCount` | integer | Number of unpaid invoices |

---

### Get Paid Stats (Alias)

Backwards-compatible alias for `GET /api/reports/stats/paid`. Both routes return the same `InvoicesStatsDto` and share a single server-side implementation; this entry exists so already-shipped clients can keep working until they migrate to the canonical reports route.

**Endpoint**: `GET /api/v3/invoices/stats/paid`

**Canonical equivalent**: `GET /api/reports/stats/paid` (preferred for new integrations).

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `clientId` | string | No | When supplied, restricts the aggregation to this client's invoices. Paid payment requests are excluded from client-filtered stats because the `PaymentRequest` model has no `ClientId` field. |

**Response**: `200 OK`

```json
{
  "byCurrency": [
    {
      "currencyCode": "USD",
      "totalAmount": 10950.00,
      "count": 8,
      "years": [
        {
          "year": 2026,
          "totalAmount": 3700.00,
          "count": 3,
          "months": [
            { "month": 1, "totalAmount": 1200.00, "count": 1 },
            { "month": 2, "totalAmount": 2500.00, "count": 2 }
          ]
        }
      ]
    }
  ]
}
```

**Notes**:
- Aggregates paid invoices (`Paid` / `PaidByCard`) and paid payment requests by `(year, month, currencyCode)`. Same source set as `GET /api/reports/totalsByYears`.
- Years are emitted descending; months ascending within a year. Months with no income are omitted (no zero-fill).
- `totalAmount` at currency / year / month levels is the sum of the level below.
- For `productKey == "Payments"` accounts, only payment requests are included.
- This V3 alias will be retired once external consumers migrate to the canonical `/api/reports/stats/paid` route.

---

### 9. Get Single Invoice

Retrieve a single invoice by ID.

**Endpoint**: `GET /api/v3/invoices/{id}`

**Path Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Invoice ID |

**Response**: `200 OK`

Returns an [InvoiceDto](#6-get-all-invoices) object.

---

### 10. Get P&L Report

Get a profit and loss report for invoices within a date range, broken down into periodic buckets.

**Endpoint**: `GET /api/v3/invoices/pnl-report`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `from` | string (ISO 8601) | Yes | Period start date |
| `to` | string (ISO 8601) | Yes | Period end date |

**Example Request**:

```
GET /api/v3/invoices/pnl-report?from=2025-01-01T00:00:00Z&to=2025-12-31T23:59:59Z
```

**Response**: `200 OK`

```json
{
  "accountId": "acc_xyz789",
  "periodStart": "2025-01-01T00:00:00Z",
  "periodEnd": "2025-12-31T23:59:59Z",
  "totalCount": 48,
  "paidInfo": {
    "amount": 52000.00,
    "count": 35
  },
  "unpaidOverdueInfo": {
    "amount": 4200.00,
    "count": 5
  },
  "unpaidNotOverdueInfo": {
    "amount": 8500.00,
    "count": 8
  },
  "items": [
    {
      "periodStart": "2025-01-01T00:00:00Z",
      "periodEnd": "2025-01-31T23:59:59Z",
      "count": 4,
      "paidInfo": {
        "amount": 4200.00,
        "count": 3
      },
      "unpaidOverdueInfo": {
        "amount": 800.00,
        "count": 1
      },
      "unpaidNotOverdueInfo": {
        "amount": 0,
        "count": 0
      }
    }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `accountId` | string | Account identifier |
| `periodStart` | string (ISO 8601) | Report period start |
| `periodEnd` | string (ISO 8601) | Report period end |
| `totalCount` | integer | Total number of invoices in the period |
| `paidInfo` | object | Aggregate paid invoice info |
| `paidInfo.amount` | decimal | Total paid amount |
| `paidInfo.count` | integer | Number of paid invoices |
| `unpaidOverdueInfo` | object | Aggregate unpaid overdue invoice info |
| `unpaidOverdueInfo.amount` | decimal | Total overdue amount |
| `unpaidOverdueInfo.count` | integer | Number of overdue invoices |
| `unpaidNotOverdueInfo` | object | Aggregate unpaid not-yet-due invoice info |
| `unpaidNotOverdueInfo.amount` | decimal | Total not-yet-due amount |
| `unpaidNotOverdueInfo.count` | integer | Number of not-yet-due invoices |
| `items` | array | Periodic breakdown buckets |
| `items[].periodStart` | string (ISO 8601) | Bucket start date |
| `items[].periodEnd` | string (ISO 8601) | Bucket end date |
| `items[].count` | integer | Invoice count in this bucket |
| `items[].paidInfo` | object | Paid info for this bucket (same structure as above) |
| `items[].unpaidOverdueInfo` | object | Unpaid overdue info for this bucket |
| `items[].unpaidNotOverdueInfo` | object | Unpaid not-yet-due info for this bucket |

---

## PDF & Preview Operations

### 11. Get PDF via Query String

Generate a PDF from a serialized invoice JSON passed as a query parameter.

**Endpoint**: `GET /api/v3/invoices/pdf`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `invoiceJson` | string | Yes | JSON-serialized invoice object (URL-encoded) |

**Response**: `200 OK` with `Content-Type: application/pdf`

Returns the PDF file as a binary stream.

---

### 12. Get PDF via POST

Generate a PDF from an invoice DTO sent in the request body.

**Endpoint**: `POST /api/v3/invoices/pdf`

**Request Body**: An [InvoiceDto](#6-get-all-invoices) object.

**Response**: `200 OK` with `Content-Type: application/pdf`

Returns the PDF file as a binary stream.

---

### 13. Build HTML Preview

Generate an HTML preview of an invoice, optionally with template customization parameters.

**Endpoint**: `POST /api/v3/invoices/build-html-preview`

**Request Body**:

```json
{
  "templateParams": null,
  "invoice": {
    "id": "inv_abc123",
    "version": 1,
    "date": "2025-10-15",
    "number": "INV-0042",
    "status": "notPaid",
    "items": [],
    "subtotalAmount": 0,
    "discountAmount": 0,
    "taxAmount": 0,
    "totalAmount": 0,
    "totalDue": 0,
    "attachments": []
  }
}
```

**Request Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `templateParams` | object | No | Template customization parameters (nullable) |
| `invoice` | object | Yes | An [InvoiceDto](#6-get-all-invoices) object |

**Response**: `200 OK` with `Content-Type: text/html`

Returns the rendered HTML string.

---

### 14. Calculate Table Details

Compute the table-based representation and structure for an invoice document, including headers, rows, and footer data.

**Endpoint**: `POST /api/v3/invoices/calculate-table-details`

**Request Body**: An [InvoiceDto](#6-get-all-invoices) object.

**Response**: `200 OK`

Returns a `TableDetailParam` object containing table headers, rows, and footer data used for template rendering.

---

## Timeline Operations

The invoices timeline shares the same DTO structure documented in the [Timeline API Reference](TIMELINE_API_REFERENCE.md).

### 15. Get Invoice Timeline

Get a cursor-paginated timeline of invoice events across the account.

**Endpoint**: `GET /api/v3/invoices/timeline`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pageSize` | integer | No | Number of events per page, default: 100 |
| `cursor` | string | No | Pagination cursor from previous response |

**Example Request**:

```
GET /api/v3/invoices/timeline?pageSize=50
```

**Response**: `200 OK`

```json
{
  "items": [
    {
      "id": 1042,
      "accountId": "acc_xyz789",
      "entityId": "inv_abc123",
      "masterUserId": "user_456",
      "createdAt": "2025-10-28T14:30:00Z",
      "occurredAt": "2025-10-28T14:30:00Z",
      "eventType": "invoiceStatusChanged",
      "actorType": "user",
      "payload": "{\"oldStatus\":\"notPaid\",\"newStatus\":\"paid\"}",
      "entityVersion": 4
    }
  ],
  "nextCursor": "eyJpZCI6MTA0Mn0",
  "hasMore": true
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | Timeline event items |
| `items[].id` | integer | Sequence ID |
| `items[].accountId` | string | Account identifier |
| `items[].entityId` | string | Invoice ID this event relates to |
| `items[].masterUserId` | string | User who triggered the event (nullable) |
| `items[].createdAt` | string (ISO 8601) | When the event was recorded |
| `items[].occurredAt` | string (ISO 8601) | When the event actually happened |
| `items[].eventType` | string | Event type. Invoice-relevant values: `invoiceStatusChanged`, `invoiceEmailStatusChanged`, `invoicePaymentReceived`, `invoiceCreatedFromEstimate`, `invoiceCreatedFromJob` |
| `items[].actorType` | string | Who triggered the event: `unknown`, `system`, `user`, `external` |
| `items[].payload` | string | JSON-encoded event-specific data |
| `items[].entityVersion` | integer | Entity version at the time of the event |
| `nextCursor` | string | Cursor for the next page. Pass as `cursor` to fetch more. |
| `hasMore` | boolean | Whether more events exist beyond this page |

---

### 16. Get Timeline by Invoice

Get timeline events for a specific invoice.

**Endpoint**: `GET /api/v3/invoices/timeline/{entityId}`

**Path Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `entityId` | string | Yes | Invoice ID |

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `limit` | integer | No | Maximum number of events to return, default: 100 |

**Response**: `200 OK`

```json
{
  "items": [
    {
      "id": 1042,
      "accountId": "acc_xyz789",
      "entityId": "inv_abc123",
      "masterUserId": "user_456",
      "createdAt": "2025-10-28T14:30:00Z",
      "occurredAt": "2025-10-28T14:30:00Z",
      "eventType": "invoiceStatusChanged",
      "actorType": "user",
      "payload": "{\"oldStatus\":\"notPaid\",\"newStatus\":\"paid\"}",
      "entityVersion": 4
    }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | Timeline event items (same structure as [Get Invoice Timeline](#15-get-invoice-timeline)) |

---

## Sync Operations

### 17. Sync Invoices

Returns invoices that changed since the cursor position, paged. Replaces the unbounded `GET /api/v3/invoices` full-collection fetch with incremental, change-only responses keyed by an opaque cursor.

**Endpoint**: `GET /api/v3/invoices/sync`

**Query Parameters**:

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `cursor` | string | No | `null` | Opaque token from a previous response's `nextCursor`. Omit (or null) for the initial full sync. |
| `limit` | integer | No | `100` | Maximum items returned in this page. The server may return fewer. |

**Example Requests**:

```
GET /api/v3/invoices/sync
GET /api/v3/invoices/sync?limit=50
GET /api/v3/invoices/sync?cursor=eyJtb2RpZmllZFRpbWVNcyI6MTc...&limit=100
```

**Response**: `200 OK`

```json
{
  "items": [
    {
      "itemId": "acct_xyz789|inv_abc123",
      "change": "updated",
      "item": {
        "id": "inv_abc123",
        "version": 4,
        "status": "paid",
        "client": { "name": "Emily Johnson", "email": "emily.johnson@gmail.com" },
        "date": "2025-10-15",
        "totalAmount": 1500.00
      }
    },
    {
      "itemId": "acct_xyz789|inv_def456",
      "change": "deleted",
      "item": null
    }
  ],
  "nextCursor": "eyJtb2RpZmllZFRpbWVNcyI6MTc...",
  "hasMore": true,
  "delayNextRequestInSeconds": 30
}
```

**Response Fields** (`SyncResponseDto<InvoiceDto>`):

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | Change items in this page, ordered by `(modifiedTime, uniqueId)` ascending |
| `items[].itemId` | string | Stable identifier of the changed invoice, in the form `<accountId>\|<invoiceId>` |
| `items[].change` | string (enum) | Change type — see [SyncChangeType](#syncchangetype-enum) |
| `items[].item` | object \| null | Full [InvoiceDto](#6-get-all-invoices) for `updated`; `null` when `change = "deleted"` |
| `nextCursor` | string \| null | Opaque cursor for the next page. Pass back as the `cursor` query param. `null` once the client has caught up. |
| `hasMore` | boolean | `true` when more pages are available; `false` when the current page is the last |
| `delayNextRequestInSeconds` | integer | Server hint for how long the client should wait before the next sync poll |

#### `SyncChangeType` enum

| Value | Description |
|-------|-------------|
| `updated` | The invoice was created or modified — `item` carries the current state. |
| `deleted` | The invoice was soft-deleted — `item` is `null`. The client should drop it from local storage. |

#### Cursor semantics

- The cursor is **opaque** to clients — do not parse, log, or persist its inner shape, just pass it back unchanged.
- Internally it encodes `(modifiedTime, uniqueId)` and resolves the next-page predicate as `modifiedTime > c.modifiedTime OR (modifiedTime == c.modifiedTime AND uniqueId > c.uniqueId)`.
- Initial sync: omit the `cursor` query param (or pass `null`). The server returns the oldest page first.
- Steady state: keep calling with `nextCursor` until `hasMore = false`. Then poll again after `delayNextRequestInSeconds`.
- Soft-deleted invoices are returned with `change = "deleted"` and `item = null` — they are **not** filtered out, so the client can synchronize the deletion locally.

#### Notes

- Only available on **API v3**. v1 / v2 keep the legacy non-sync endpoints untouched.
- Items are ordered by `(modifiedTime ASC, uniqueId ASC)` so the cursor stays deterministic across pages.

---

## Reference: Shared Structures

### Reference: Client Structure

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Client name (nullable) |
| `phone` | string | Phone number (nullable) |
| `email` | string | Email address (nullable) |
| `address` | string | Mailing address (nullable) |
| `catalogId` | string | Reference to the client catalog entry (nullable). Omitted from response when null. |

---

### Reference: Item Structure

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Item name (nullable) |
| `details` | string | Additional details (nullable) |
| `itemType` | string | Item type (nullable): `none`, `service`, `material` |
| `description` | string | Item description (nullable). Omitted from response when null. |
| `unitPrice` | decimal | Price per unit |
| `unitType` | string | Unit of measure (nullable): `none`, `hours`, `days` |
| `quantity` | decimal | Quantity |
| `discount` | object | Item-level discount (nullable). See [Discount Structure](#reference-discount-structure). |
| `isTaxApplied` | boolean | Whether tax applies to this item |
| `catalogId` | string | Reference to the item catalog entry (nullable). Omitted from response when null. |

---

### Reference: Discount Structure

| Field | Type | Description |
|-------|------|-------------|
| `value` | decimal | Discount value |
| `type` | string | Discount type: `percent`, `absolute` |

---

### Reference: Tax Structure

| Field | Type | Description |
|-------|------|-------------|
| `percentValue` | decimal | Tax percentage |
| `type` | string | Tax type: `inclusive`, `exclusive` |
| `name` | string | Tax label (nullable), e.g. "Sales Tax". Omitted from response when null. |

---

### Reference: Payment Details Structure

| Field | Type | Description |
|-------|------|-------------|
| `lastReceiptId` | string | Most recent receipt ID (nullable) |
| `lastReceiptUrl` | string | URL to the receipt (nullable) |
| `lastPspAccountId` | string | Payment service provider account ID (nullable) |

---

### Reference: Attachment Structure

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Attachment identifier |
| `url` | string | URL to the file (nullable) |
| `order` | integer | Display order |
| `contentProperties` | object | Additional content metadata (nullable) |
| `contentProperties.orientation` | string | Image orientation (nullable): `unknown`, `landscape`, `portrait` |
