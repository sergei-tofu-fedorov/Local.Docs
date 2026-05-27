# Payments API Reference

Complete reference for all Payments API endpoints with request/response examples.

**Target Audience**: Frontend Developers, Backend Developers, QA Engineers

## Base Path

`/api/payments`

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/payments/sync-external-payment-data` | [Sync external payment data](#1-sync-external-payment-data) |
| GET | `/api/payments/types` | [Get payment types](#2-get-payment-types) |
| POST | `/api/payments/availability` | [Set payment availability](#3-set-payment-availability) |
| GET | `/api/payments/authenticated-types` | [Get authenticated payment types](#4-get-authenticated-payment-types) |
| POST | `/api/payments/connections/{providerType}` | [Connect payment account](#5-connect-payment-account) |
| POST | `/api/payments/connections/{providerType}/set-settings` | [Set provider settings](#6-set-provider-settings) |
| POST | `/api/payments/connections/{providerType}/enable` | [Enable provider](#7-enable-provider) |
| POST | `/api/payments/disconnect/{providerType}` | [Disconnect payment account](#8-disconnect-payment-account) |

### Callback / Internal Endpoints

These endpoints are used by payment providers (Stripe) or internal redirect flows. They are not called directly by frontend clients.

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/payments/web-link-hooks/{idWithProvider}` | [Payment redirect](#9-payment-redirect) |
| GET | `/callback/payments/auth/{providerType}` | [Auth callback](#10-auth-callback) |
| GET | `/callback/payments/auth/{providerType}/refresh-link` | [Auth refresh link](#11-auth-refresh-link) |
| GET | `/callback/payments/success/{providerType}` | [Payment success callback](#12-payment-success-callback) |
| GET | `/callback/payments/fail/{providerType}` | [Payment failure callback](#13-payment-failure-callback) |
| POST | `/callback/hooks/stripe/events` | [Stripe webhook](#14-stripe-webhook) |

---

## Write Operations

### 1. Sync External Payment Data

Queue a background job to synchronize external payment data for the account.

**Endpoint**: `POST /api/payments/sync-external-payment-data`

**Request Body**: None

**Response**: `200 OK`

```json
{}
```

---

### 3. Set Payment Availability

Enable or disable all authenticated payment types for the account.

**Endpoint**: `POST /api/payments/availability`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `enable` | boolean | Yes | `true` to enable, `false` to disable all authenticated payment types |

**Response**: `204 No Content`

---

### 5. Connect Payment Account

Initiate a connection flow with a payment provider (e.g., Stripe). Returns an authentication flow URL that the user should be redirected to.

**Endpoint**: `POST /api/payments/connections/{providerType}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `providerType` | string | Payment provider name (e.g., `stripe`) |

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `deleteOld` | boolean | No | When `true`, removes the existing connection before creating a new one |
| `isPreConnect` | boolean | No | When `true`, performs a pre-connect check and returns an empty object without initiating the flow |
| `isCollectRequirements` | boolean | No | When `true`, the flow will collect additional onboarding requirements |

**Response**: `200 OK`

When `isPreConnect` is `true`:

```json
{}
```

Otherwise returns a **PaymentTypeAuthenticationFlow**:

```json
{
  "url": "https://connect.stripe.com/setup/s/abc123",
  "items": {
    "accountId": "acct_1234567890",
    "refreshUrl": "https://api.example.com/callback/payments/auth/stripe/refresh-link?accountId=acc_xyz",
    "successUrl": "https://api.example.com/callback/payments/auth/stripe?accountId=acc_xyz"
  },
  "state": "pending"
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `url` | string | URL to redirect the user to for completing the provider connection |
| `items.accountId` | string | Provider-side account identifier |
| `items.refreshUrl` | string | URL for refreshing the onboarding link if it expires |
| `items.successUrl` | string | URL the provider redirects to on success |
| `state` | string | Current state of the authentication flow |

---

### 6. Set Provider Settings

Update settings for a connected payment provider.

**Endpoint**: `POST /api/payments/connections/{providerType}/set-settings`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `providerType` | string | Payment provider name (e.g., `stripe`) |

**Request Body**:

```json
{
  "softEnabled": true,
  "clientPaysFeeEnabled": false
}
```

**Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `softEnabled` | boolean | Yes | Whether the provider is soft-enabled (visible and available for use) |
| `clientPaysFeeEnabled` | boolean | Yes | Whether the client pays the processing fee |

**Response**: `204 No Content`

---

### 7. Enable Provider

Shortcut to soft-enable a payment provider without changing other settings. Sets `softEnabled` to `true` and leaves `clientPaysFeeEnabled` unchanged.

**Endpoint**: `POST /api/payments/connections/{providerType}/enable`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `providerType` | string | Payment provider name (e.g., `stripe`) |

**Response**: `204 No Content`

---

### 8. Disconnect Payment Account

Disconnect a payment provider from the account.

**Endpoint**: `POST /api/payments/disconnect/{providerType}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `providerType` | string | Payment provider name (e.g., `stripe`) |

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `hard` | boolean | No | When `true` or omitted (default), fully removes the provider connection. When `false`, soft-disables the provider (sets `softEnabled = false`) without removing the connection. |

**Response**: `204 No Content`

---

## Read Operations

### 2. Get Payment Types

Get all available payment types (from configuration).

**Endpoint**: `GET /api/payments/types`

**Response**: `200 OK`

```json
{
  "items": [
    {
      "name": "Stripe",
      "enabled": true
    },
    {
      "name": "PayPal",
      "enabled": false
    }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | List of payment types |
| `items[].name` | string | Payment type name |
| `items[].enabled` | boolean | Whether this payment type is enabled in the system configuration |

---

### 4. Get Authenticated Payment Types

Get the payment types that are connected and configured for the current account, including their connection status and settings.

**Endpoint**: `GET /api/payments/authenticated-types`

**Response**: `200 OK`

```json
{
  "paymentByCardEnabled": true,
  "items": [
    {
      "name": "Stripe",
      "enabled": true,
      "softEnabled": true,
      "clientPaysFeeEnabled": false,
      "items": {
        "id": "acct_1234567890",
        "email": "business@example.com",
        "accountId": "acct_1234567890",
        "verificationPending": false,
        "connectionErrors": [],
        "connectionErrorTitle": null,
        "country": "US"
      },
      "status": "connected"
    }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `paymentByCardEnabled` | boolean | Whether card payments are enabled for the account |
| `items` | array | List of authenticated payment providers |
| `items[].name` | string | Provider name |
| `items[].enabled` | boolean | Whether the provider is enabled |
| `items[].softEnabled` | boolean | Whether the provider is soft-enabled (nullable) |
| `items[].clientPaysFeeEnabled` | boolean | Whether the client pays the processing fee |
| `items[].status` | string | Connection status: `unknown`, `inProgress`, `verification`, `connected`, `informationIsRequired`, `rejected` (nullable) |
| `items[].items` | object | Provider connection details (nullable, see below) |

**Provider Connection Details** (`items[].items`):

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Provider-side identifier (nullable) |
| `email` | string | Email associated with the provider account (nullable) |
| `accountId` | string | Provider account ID (nullable) |
| `verificationPending` | boolean | Whether verification is pending (deprecated, use `status` instead) |
| `connectionErrors` | array | List of connection errors, each with a `message` string |
| `connectionErrorTitle` | string | Summary title for connection errors (nullable) |
| `country` | string | Country of the provider account (nullable) |

---

## Callback Endpoints

These endpoints handle redirects and webhooks from payment providers. They are not intended for direct frontend use.

### 9. Payment Redirect

Redirect the payer to the payment provider's checkout page for a specific invoice. If the invoice is already paid, redirects to the invoice web link instead.

**Endpoint**: `GET /api/payments/web-link-hooks/{idWithProvider}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `idWithProvider` | string | Composite identifier in format `{invoiceId}:{providerType}` (e.g., `inv_123:stripe`) |

**Response**: `302 Redirect` to the payment provider checkout URL or the invoice web link.

**Business Rules**:

- If invoice status is `PaidByCard` or `Paid`, redirects to the invoice web link
- Otherwise, creates a payment intent and redirects to the provider's checkout page
- Supports `AuthAlsoInQuery` for authentication via query parameters

---

### 10. Auth Callback

Callback endpoint invoked by the payment provider after the user completes the onboarding/authorization flow.

**Endpoint**: `GET /callback/payments/auth/{providerType}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `providerType` | string | Payment provider name |

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `accountId` | string | Yes | Account identifier |
| `withRedirect` | boolean | No | When `true` and onboarding is almost done, redirects to complete the remaining requirements |

**Response**: Returns an HTML success page, or a `302 Redirect` if `withRedirect` is `true` and onboarding needs additional steps.

---

### 11. Auth Refresh Link

Regenerate an expired onboarding link for a payment provider.

**Endpoint**: `GET /callback/payments/auth/{providerType}/refresh-link`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `providerType` | string | Payment provider name |

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `accountId` | string | Yes | Account identifier |
| `isCollectRequirements` | boolean | No | When `true`, the refreshed link will collect additional requirements |

**Response**: `302 Redirect` to the new onboarding URL.

---

### 12. Payment Success Callback

Callback invoked by the payment provider when a payment succeeds. Marks the payment as successful and redirects the payer back to the appropriate document (invoice or payment request).

**Endpoint**: `GET /callback/payments/success/{providerType}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `providerType` | string | Payment provider name |

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `accountId` | string | Yes | Account identifier |
| `paymentId` | string | Yes | Payment intent identifier |

**Response**: `302 Redirect` to the invoice or payment request web link.

---

### 13. Payment Failure Callback

Callback invoked by the payment provider when a payment fails. Marks the payment as failed and redirects the payer back to the appropriate document.

**Endpoint**: `GET /callback/payments/fail/{providerType}`

**Path Parameters**:

| Parameter | Type | Description |
|-----------|------|-------------|
| `providerType` | string | Payment provider name |

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `accountId` | string | Yes | Account identifier |
| `paymentId` | string | Yes | Payment intent identifier |

**Response**: `302 Redirect` to the invoice or payment request web link.

---

### 14. Stripe Webhook

Receives and processes Stripe event webhooks. Verifies the `Stripe-Signature` header and delegates event handling to the payment events service.

**Endpoint**: `POST /callback/hooks/stripe/events`

**Request Headers**:

| Header | Required | Description |
|--------|----------|-------------|
| `Stripe-Signature` | Yes | Stripe webhook signature for payload verification |

**Request Body**: Raw Stripe event JSON payload.

**Response**: `200 OK`

---

## Reference: PaymentAccountConnectionStatus Values

| Value | Description |
|-------|-------------|
| `unknown` | Status is not yet determined |
| `inProgress` | Onboarding/connection is in progress |
| `verification` | Awaiting verification from the provider |
| `connected` | Successfully connected and active |
| `informationIsRequired` | Additional information is required to complete onboarding |
| `rejected` | Connection was rejected by the provider |
