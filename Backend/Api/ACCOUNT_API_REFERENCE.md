# Account API Reference

Complete reference for all Account API endpoints with request/response examples.

**Target Audience**: Frontend Developers, Backend Developers, QA Engineers

## Base Path

`/api/v3/account`

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v3/account` | [Get account](#1-get-account) |
| PUT | `/api/v3/account` | [Update account (legacy)](#2-update-account-legacy) |
| PUT | `/api/v3/account/{accountId}/update` | [Update account](#3-update-account) |
| PUT | `/api/v3/account/set_identifiers` | [Set identifiers](#4-set-identifiers) |
| DELETE | `/api/v3/account` | [Delete account](#5-delete-account) |
| GET | `/api/v3/account/all-by-account-id` | [Get accounts by account ID](#6-get-accounts-by-account-id) |
| GET | `/api/v3/account/all` | [Get all accounts with activity](#7-get-all-accounts-with-activity) |
| GET | `/api/v3/account/all-by-platform-user` | [Get accounts by platform user](#8-get-accounts-by-platform-user) |
| POST | `/api/v3/account/claim-email` | [Claim email](#9-claim-email) |
| GET | `/api/v3/account/subscription` | [Get subscription](#10-get-subscription) |
| PUT | `/api/v3/account/receipt` | [Put receipt](#11-put-receipt) |
| GET | `/api/v3/account/features` | [Get features](#12-get-features) |
| GET | `/api/v3/account/currencies` | [Get currencies](#13-get-currencies) |
| GET | `/api/v3/account/pricing` | [Get pricing](#14-get-pricing) |
| GET | `/api/v3/account/export` | [Export account data](#15-export-account-data) |

---

## Read Operations

### 1. Get Account

Retrieve the current account details.

**Endpoint**: `GET /api/v3/account`

**Response**: `200 OK`

```json
{
  "id": "abc123def456",
  "version": 3,
  "businessName": "Johnson Plumbing LLC",
  "contacts": {
    "name": "Mike Johnson",
    "phone": "(310) 555-1234",
    "email": "mike@johnsonplumbing.com",
    "address": "123 Main St, Los Angeles, CA 90001"
  },
  "intercom": {
    "userId": "pub_abc123",
    "hash": "a1b2c3d4e5f6..."
  },
  "culture": "en_US",
  "isDeleted": false,
  "currencyCode": "USD",
  "businessInfo": {
    "businessTaxNumber": "12-3456789",
    "businessNumber": "BN-001"
  }
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Account ID. |
| `version` | integer | Account version for optimistic concurrency. |
| `businessName` | string? | Business display name. |
| `contacts` | object? | Account contact information. See [AccountContacts](#reference-accountcontacts). |
| `intercom` | object? | Intercom integration info. See [IntercomInfo](#reference-intercominfo). |
| `culture` | string? | Locale code (underscore format, e.g. `en_US`). |
| `isDeleted` | boolean | Whether the account has been soft-deleted. |
| `currencyCode` | string? | ISO currency code. See [CurrencyCodeType](#reference-currencycodetype). |
| `businessInfo` | object? | Business identification numbers. See [BusinessInfo](#reference-businessinfo). |

---

### 6. Get Accounts by Account ID

Retrieve all accounts belonging to the same user as the current account.

**Endpoint**: `GET /api/v3/account/all-by-account-id`

**Response**: `200 OK`

```json
{
  "info": [
    {
      "id": "abc123def456",
      "version": 3,
      "businessName": "Johnson Plumbing LLC",
      "contacts": {
        "name": "Mike Johnson",
        "phone": "(310) 555-1234",
        "email": "mike@johnsonplumbing.com",
        "address": "123 Main St, Los Angeles, CA 90001"
      },
      "intercom": {
        "userId": "pub_abc123",
        "hash": "a1b2c3d4e5f6..."
      },
      "culture": "en_US",
      "isDeleted": false,
      "currencyCode": "USD",
      "businessInfo": {
        "businessTaxNumber": "12-3456789",
        "businessNumber": "BN-001"
      }
    }
  ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `info` | array | Collection of [AccountDto](#1-get-account) objects. |

---

### 7. Get All Accounts with Activity

Retrieve all accounts for the authenticated master user, with optional activity metrics.

**Endpoint**: `GET /api/v3/account/all`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `includeActivity` | boolean | No | When `true`, includes last activity timestamps and totals. Defaults to `false`. |

**Response**: `200 OK`

```json
{
  "info": [
    {
      "id": "abc123def456",
      "name": "Johnson Plumbing LLC",
      "logoUrl": "https://storage.example.com/logos/abc123.png",
      "createdAt": "2024-01-15T08:30:00Z",
      "lastInvoiceActivity": "2025-10-28T14:30:00Z",
      "lastEstimateActivity": "2025-10-20T09:15:00Z",
      "totalInvoices": 142,
      "totalEstimates": 37
    }
  ]
}
```

**Response Fields** (AccountInfoWithActivityDto):

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Account ID. |
| `name` | string? | Business name. |
| `logoUrl` | string? | URL to the account logo image. |
| `createdAt` | datetime | Account creation timestamp. |
| `lastInvoiceActivity` | datetime? | Timestamp of the most recent invoice activity. Only populated when `includeActivity` is `true`. |
| `lastEstimateActivity` | datetime? | Timestamp of the most recent estimate activity. Only populated when `includeActivity` is `true`. |
| `totalInvoices` | integer? | Total number of invoices. Only populated when `includeActivity` is `true`. |
| `totalEstimates` | integer? | Total number of estimates. Only populated when `includeActivity` is `true`. |

---

### 8. Get Accounts by Platform User

Retrieve all accounts for a given platform user ID. Does not require authentication.

**Endpoint**: `GET /api/v3/account/all-by-platform-user`

**Authentication**: None (AllowAnonymous)

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `platformUserId` | string | Yes | The platform user ID to look up. |

**Response**: `200 OK`

Returns the same [AccountsInfoWithActivityDto](#7-get-all-accounts-with-activity) structure. Activity data is always included.

---

### 10. Get Subscription

Retrieve the current subscription status for the account.

**Endpoint**: `GET /api/v3/account/subscription`

**Response**: `200 OK`

```json
{
  "isActive": true,
  "currentTime": "2025-10-28T14:30:00Z",
  "productId": "com.getpaidapp.invoices.premium_plan_annual",
  "expirationTime": "2026-10-28T14:30:00Z",
  "cancellationTime": null,
  "isAutoRenewEnabled": true,
  "firstPurchaseDate": "2024-10-28T14:30:00Z",
  "adapterType": 3
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `isActive` | boolean | Whether the subscription is currently active. |
| `currentTime` | datetime | Server time at the moment of the response. |
| `productId` | string? | Subscription product identifier. Omitted when no subscription exists. |
| `expirationTime` | datetime? | When the subscription expires. Omitted when no subscription exists. |
| `cancellationTime` | datetime? | When the subscription was cancelled. Omitted if not cancelled. |
| `trialExpirationTime` | datetime? | When the trial period expires. Omitted when not in trial or subscription is active. |
| `isAutoRenewEnabled` | boolean? | Whether auto-renewal is enabled. Omitted when no subscription exists. |
| `firstPurchaseDate` | datetime? | Date of the initial subscription purchase. Omitted when no subscription exists. |
| `adapterType` | integer? | Payment adapter type. `0` = None, `1` = AppleStore, `2` = GooglePlay, `3` = Stripe, `4` = Braintree, `5` = Purple, `6` = Paddle. |

---

### 12. Get Features

Retrieve A/B test feature flags for the current account based on IP and OS version.

**Endpoint**: `GET /api/v3/account/features`

**Response**: `200 OK`

When a feature is found:
```json
{
  "result": {
    "id": "campaign_abc123",
    "type": "premium_upsell"
  }
}
```

When no feature is found:
```json
{
  "result": null
}
```

---

### 13. Get Currencies

Retrieve the full list of supported currencies.

**Endpoint**: `GET /api/v3/account/currencies`

**Response**: `200 OK`

```json
{
  "currencies": [
    {
      "code": "USD",
      "symbol": "$",
      "name": "United States dollar"
    },
    {
      "code": "EUR",
      "symbol": "\u20ac",
      "name": "Euro"
    },
    {
      "code": "GBP",
      "symbol": "\u00a3",
      "name": "Pound sterling"
    }
  ]
}
```

**Response Fields** (CurrencyItem):

| Field | Type | Description |
|-------|------|-------------|
| `code` | string | ISO currency code. See [CurrencyCodeType](#reference-currencycodetype). |
| `symbol` | string | Currency symbol for display. |
| `name` | string | Full currency name. |

---

### 14. Get Pricing

Retrieve subscription product pricing information. Results are filtered by the current product key.

**Endpoint**: `GET /api/v3/account/pricing`

**Response**: `200 OK`

```json
{
  "products": [
    {
      "productId": "com.getpaidapp.invoices.premium_weekly",
      "price": 5.99
    },
    {
      "productId": "com.getpaidapp.invoices.premium_monthly",
      "price": 9.99
    },
    {
      "productId": "com.getpaidapp.invoices.premium_annual",
      "price": 99.99
    }
  ]
}
```

**Response Fields** (SubscriptionPrice):

| Field | Type | Description |
|-------|------|-------------|
| `productId` | string | Platform-specific product identifier. |
| `price` | decimal | Product price. |

---

### 15. Export Account Data

Export all account data including invoices and estimates.

**Endpoint**: `GET /api/v3/account/export`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `accountId` | string | Yes | The account ID to export. Must be at least 10 characters. |

**Response**: `200 OK`

```json
{
  "account": { },
  "invoices": [ ],
  "estimates": [ ]
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `account` | object | The account data as an [AccountDto](#1-get-account). |
| `invoices` | array | All invoices belonging to the account. |
| `estimates` | array | All estimates belonging to the account. |

---

## Write Operations

### 2. Update Account (Legacy)

Create or update account details. This is the legacy V1 endpoint also available on V3.

**Endpoint**: `PUT /api/v3/account`

**Request Body**:

```json
{
  "version": 3,
  "businessName": "Johnson Plumbing LLC",
  "contacts": {
    "name": "Mike Johnson",
    "phone": "(310) 555-1234",
    "email": "mike@johnsonplumbing.com",
    "address": "123 Main St, Los Angeles, CA 90001"
  },
  "culture": "en_US",
  "currencyCode": "USD",
  "businessInfo": {
    "businessTaxNumber": "12-3456789",
    "businessNumber": "BN-001"
  }
}
```

**Request Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | integer | Yes | Account version for optimistic concurrency. Send `0` or omit on first creation (server assigns IP-based geolocation). |
| `businessName` | string | No | Business display name. |
| `contacts` | object | No | Contact info. See [AccountContacts](#reference-accountcontacts). |
| `culture` | string | No | Locale code (e.g. `en_US`). Stored internally with hyphens. |
| `currencyCode` | string | No | ISO currency code. See [CurrencyCodeType](#reference-currencycodetype). |
| `businessInfo` | object | No | Business identification. See [BusinessInfo](#reference-businessinfo). |

**Response**: `200 OK`

Returns the full [AccountDto](#1-get-account).

---

### 3. Update Account

Create or update account details via the V3 endpoint. Requires account ID in the path.

**Endpoint**: `PUT /api/v3/account/{accountId}/update`

**Path Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `accountId` | string | Yes | The account ID to create or update. |

**Request Body**:

```json
{
  "version": 3,
  "businessName": "Johnson Plumbing LLC",
  "contacts": {
    "name": "Mike Johnson",
    "phone": "(310) 555-1234",
    "email": "mike@johnsonplumbing.com",
    "address": "123 Main St, Los Angeles, CA 90001"
  },
  "culture": "en_US",
  "currencyCode": "USD",
  "businessInfo": {
    "businessTaxNumber": "12-3456789",
    "businessNumber": "BN-001"
  },
  "platformUserId": "user_abc123"
}
```

**Request Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | integer | Yes | Account version for optimistic concurrency. Send `0` or omit on first creation (server assigns IP-based geolocation). |
| `businessName` | string | No | Business display name. |
| `contacts` | object | No | Contact info. See [AccountContacts](#reference-accountcontacts). |
| `culture` | string | No | Locale code (e.g. `en_US`). Stored internally with hyphens. |
| `currencyCode` | string | No | ISO currency code. See [CurrencyCodeType](#reference-currencycodetype). |
| `businessInfo` | object | No | Business identification. See [BusinessInfo](#reference-businessinfo). |
| `platformUserId` | string | No | Platform user ID. Required only when not authenticated via master user. |

**Response**: `200 OK`

Returns the full [AccountDto](#1-get-account).

---

### 4. Set Identifiers

Set or update account identifiers including user ID, push token, and tracking identifiers.

**Endpoint**: `PUT /api/v3/account/set_identifiers`

**Request Body**:

```json
{
  "userId": "platform_user_abc123",
  "idfa": "6D92078A-8246-4B32-AE96-7B5F3E25A81C",
  "appsflyerId": "1234567890123-1234567",
  "firebaseId": "firebase_abc123",
  "pushToken": "fcm_token_abc123...",
  "publicUserId": "pub_abc123"
}
```

**Request Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `userId` | string | Yes | Platform user identifier. Auto-populated from auth context if empty. |
| `idfa` | string | No | Identifier for Advertisers (iOS). |
| `appsflyerId` | string | No | AppsFlyer attribution identifier. |
| `firebaseId` | string | No | Firebase analytics identifier. |
| `pushToken` | string | No | Push notification token for the device. |
| `publicUserId` | string | No | Public-facing user identifier. Auto-generated from `userId` if omitted. |

**Response**: `200 OK`

```json
{
  "userId": "platform_user_abc123",
  "publicUserId": "pub_abc123"
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `userId` | string | The stored platform user identifier. |
| `publicUserId` | string | The public-facing user identifier. |

---

### 5. Delete Account

Soft-delete the specified account.

**Endpoint**: `DELETE /api/v3/account`

**Query Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `accountId` | string | Yes | The account ID to delete. |

**Response**: `200 OK` (empty body)

---

### 9. Claim Email

Claim an email address for subscription purposes, linking it to the current account.

**Endpoint**: `POST /api/v3/account/claim-email`

**Request Body**:

```json
{
  "email": "mike@johnsonplumbing.com"
}
```

**Request Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `email` | string | Yes | A valid email address to claim. |

**Response**: `200 OK`

```json
{
  "vendorProfileId": "vendor_abc123",
  "externalUserId": "ext_user_456"
}
```

**Response Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `vendorProfileId` | string | The vendor profile ID associated with the claimed email. |
| `externalUserId` | string | The external user ID associated with the claimed email. |

---

### 11. Put Receipt

Submit a purchase receipt to verify and update the account subscription status.

**Endpoint**: `PUT /api/v3/account/receipt`

**Request Body**:

```json
{
  "receiptData": "MIIT...",
  "transactions": [
    {
      "transactionId": "txn_1000000123456789",
      "productId": "com.getpaidapp.invoices.premium_annual",
      "countryCode": "US",
      "currencyCode": "USD",
      "price": 99.99
    }
  ],
  "context": "ios",
  "productId": "com.getpaidapp.invoices.premium_annual",
  "purchaseToken": "purchase_token_abc123..."
}
```

**Request Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `receiptData` | string | No | Raw receipt data (Apple receipt base64 or equivalent). |
| `transactions` | array | No | Array of transaction details. See [ReceiptTransaction](#reference-receipttransaction). |
| `context` | string | No | Payment context identifier (e.g. `ios`, `android`). |
| `productId` | string | No | The purchased product identifier. |
| `purchaseToken` | string | No | Google Play purchase token. |

**Response**: `200 OK`

Returns a [SubscriptionDto](#10-get-subscription).

---

## Reference: Shared Structures

### Reference: AccountContacts

| Field | Type | Description |
|-------|------|-------------|
| `name` | string? | Contact person name. |
| `phone` | string? | Phone number. |
| `email` | string? | Email address. |
| `address` | string? | Mailing or business address. |

### Reference: BusinessInfo

| Field | Type | Description |
|-------|------|-------------|
| `businessTaxNumber` | string? | Tax identification number (e.g. EIN, VAT). |
| `businessNumber` | string? | General business registration number. |

### Reference: IntercomInfo

| Field | Type | Description |
|-------|------|-------------|
| `userId` | string? | Intercom user identifier (public account ID). |
| `hash` | string? | Intercom identity verification HMAC hash. |

### Reference: ReceiptTransaction

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `transactionId` | string | Yes | Unique transaction identifier from the store. |
| `productId` | string | Yes | Product identifier for the purchased item. |
| `countryCode` | string | Yes | ISO country code of the purchase. |
| `currencyCode` | string | Yes | ISO currency code of the transaction. |
| `price` | decimal | No | Transaction price amount. |

### Reference: CurrencyCodeType

ISO 4217 currency code enum. Common values: `USD`, `EUR`, `GBP`, `CAD`, `AUD`, `JPY`, `CHF`, `CNY`, `INR`, `BRL`, `MXN`, `KRW`, `SEK`, `NOK`, `DKK`, `PLN`, `CZK`, `HUF`, `RON`, `BGN`, `TRY`, `ZAR`, `ILS`, `AED`, `SAR`, `SGD`, `HKD`, `TWD`, `THB`, `MYR`, `PHP`, `IDR`, `VND`, `NZD`, `ARS`, `CLP`, `COP`, `PEN`, `NGN`, `KES`, `EGP`, `PKR`, `BDT`, `UAH`, `KZT`, `GEL` (and 100+ more).

### Reference: AdapterType

Integer enum representing the subscription payment adapter:

| Value | Name | Description |
|-------|------|-------------|
| `0` | None | No adapter / no subscription. |
| `1` | AppleStore | Apple App Store (StoreKit). |
| `2` | GooglePlay | Google Play Billing. |
| `3` | Stripe | Stripe payments. |
| `4` | Braintree | Braintree payments. |
| `5` | Purple | Purple (internal). |
| `6` | Paddle | Paddle payments. |
