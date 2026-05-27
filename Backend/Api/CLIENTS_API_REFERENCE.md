# Clients API Reference

Complete reference for all Clients API endpoints.

## Base Path

`/api/clients` (API version 3.0)

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/clients` | [Get all clients](#1-get-all-clients) |
| GET | `/api/clients/paged` | [Get clients (paginated)](#2-get-clients-paginated) |
| GET | `/api/clients/{clientId}` | [Get single client](#3-get-single-client) |
| POST | `/api/clients` | [Add client](#4-add-client) |
| DELETE | `/api/clients/{clientId}` | [Delete client](#5-delete-client) |

---

## Read Operations

### 1. Get All Clients

Returns all clients for the current account.

**Endpoint**: `GET /api/clients`

**Query Parameters**:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `includeCalculations` | bool | `false` | Include invoice/estimate balance calculations |

**Response**: `200 OK`

```json
{
  "manageableClients": [
    {
      "id": "client_123",
      "info": {
        "name": "John Doe",
        "email": "john@example.com",
        "phone": "+1-555-0100",
        "address": "123 Main St"
      },
      "version": 1,
      "createdAt": "2025-01-15T10:00:00Z",
      "updatedAt": "2025-02-01T14:30:00Z",
      "balanceDue": 500.00,
      "balancePaid": 1200.00,
      "paidInvoices": 3,
      "unpaidInvoices": 1,
      "createdEstimates": 2,
      "balances": [
        {
          "currencyCode": "USD",
          "totalPaid": 1200.00,
          "totalDue": 500.00,
          "totalAmount": 1700.00
        }
      ]
    }
  ]
}
```

**Note**: Balance fields (`balanceDue`, `balancePaid`, `paidInvoices`, `unpaidInvoices`, `createdEstimates`, `balances`) are only populated when `includeCalculations=true`.

---

### 2. Get Clients (Paginated)

Token-based pagination for large client lists.

**Endpoint**: `GET /api/clients/paged`

**Query Parameters**:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `limit` | int | `50` | Page size |
| `token` | string | `null` | Continuation token from previous page |
| `clientName` | string | `null` | Filter by client name (partial match) |

**Response**: `200 OK`

```json
{
  "items": [
    {
      "id": "client_123",
      "info": {
        "name": "John Doe",
        "email": "john@example.com",
        "phone": null,
        "address": null
      },
      "version": 1,
      "createdAt": "2025-01-15T10:00:00Z",
      "updatedAt": null
    }
  ],
  "nextToken": "eyJsYXN0SWQiOiJjbGllbnRfMTIzIn0=",
  "totalCount": null
}
```

**Note**: Paginated results do not include calculation fields. `totalCount` is always `null`.

---

### 3. Get Single Client

**Endpoint**: `GET /api/clients/{clientId}`

**Query Parameters**:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `includeCalculations` | bool | `false` | Include invoice/estimate balance calculations |

**Response**: `200 OK` — returns a single `ManageableClientDto.WithCalc` (same shape as items in [Get All Clients](#1-get-all-clients)).

---

## Write Operations

### 4. Add Client

Creates a new client or updates an existing one (upsert by `id`).

**Endpoint**: `POST /api/clients`

**Request Body**:

```json
{
  "id": "client_123",
  "info": {
    "name": "John Doe",
    "email": "john@example.com",
    "phone": "+1-555-0100",
    "address": "123 Main St"
  },
  "version": 1,
  "createdAt": "2025-01-15T10:00:00Z"
}
```

**Response**: `200 OK` — returns the created/updated `ManageableClientDto.WithCalc`.

---

### 5. Delete Client

Deletes a client. Fails if the client has associated jobs.

**Endpoint**: `DELETE /api/clients/{clientId}`

**Response**: `204 No Content`

**Business Rules**:
- If the client has jobs, throws `ClientHasJobsException` (checked via `CheckJobsExistForClientQuery`).

---

## DTOs

### ManageableClientDto

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Client ID |
| `info` | ManageableClientInfoDto | Yes | Client contact information |
| `version` | int | Yes | Optimistic concurrency version |
| `createdAt` | DateTime? | No | Creation timestamp |
| `updatedAt` | DateTime? | No | Last update timestamp |

### ManageableClientDto.WithCalc

Extends `ManageableClientDto` with calculation fields (populated when `includeCalculations=true`):

| Field | Type | Description |
|-------|------|-------------|
| `balanceDue` | decimal? | Total outstanding balance |
| `balancePaid` | decimal? | Total paid amount |
| `paidInvoices` | int? | Count of paid invoices |
| `unpaidInvoices` | int? | Count of unpaid invoices |
| `createdEstimates` | int? | Count of created estimates |
| `balances` | InvoiceBalanceDto[]? | Per-currency balance breakdown |

### ManageableClientInfoDto

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Client name |
| `email` | string? | No | Email address |
| `phone` | string? | No | Phone number |
| `address` | string? | No | Street address |

### InvoiceBalanceDto

| Field | Type | Description |
|-------|------|-------------|
| `currencyCode` | string | ISO currency code |
| `totalPaid` | decimal | Total paid in this currency |
| `totalDue` | decimal | Total due in this currency |
| `totalAmount` | decimal | Total amount in this currency |

### PageDto\<T\>

| Field | Type | Description |
|-------|------|-------------|
| `items` | T[] | Page of results |
| `nextToken` | string? | Token for next page (`null` if last page) |
| `totalCount` | long? | Total count (always `null` for clients) |
