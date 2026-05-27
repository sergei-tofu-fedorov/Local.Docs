# iOS App Backend Integration Documentation

## Overview

This document describes the backend integration for user authentication, account management, and subscription handling in the Invoices iOS app.

**Base URLs:**
- Production: `https://getpaidapp.com/`
- Staging: `https://staging.getpaidapp.com/`
- Development: `https://development.tofu.com/`

---

## Key Concepts: Master User vs Platform User

### Relationship Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         BACKEND                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    Master User                           │   │
│  │                  (Firebase UID)                          │   │
│  │                                                          │   │
│  │   ┌──────────┐  ┌──────────┐  ┌──────────┐              │   │
│  │   │ Account1 │  │ Account2 │  │ Account3 │  ...         │   │
│  │   │ (Biz A)  │  │ (Biz B)  │  │ (Biz C)  │              │   │
│  │   └──────────┘  └──────────┘  └──────────┘              │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
              ▲                              ▲
              │ Link                         │ Link
              │                              │
┌─────────────┴───────────┐    ┌─────────────┴───────────┐
│      DEVICE A           │    │       DEVICE B          │
│  ┌───────────────────┐  │    │  ┌───────────────────┐  │
│  │   Platform User   │  │    │  │   Platform User   │  │
│  │   (Device ID)     │  │    │  │   (Device ID)     │  │
│  └───────────────────┘  │    │  └───────────────────┘  │
└─────────────────────────┘    └─────────────────────────┘
```

---

## Authentication Flags

### Response Flags from `POST /authenticate/auth`

| Flag | Type | Description |
|------|------|-------------|
| `masterUserId` | String | Firebase user identifier |
| `isNewMaster` | Bool | `true` = First ever login to backend (new user registration) |
| `isFirstEverLink` | Bool | `true` = First account linked for this Platform User |

### Local Storage Flags

| Key | Type | Description |
|-----|------|-------------|
| `isFirstMaster` | Bool? | Mirrors `isFirstEverLink` - determines subscription purchase availability |
| `authMasterUserId` | String? | Stored Master User ID after authentication |
| `userAuthEmail` | String? | Email used for authentication |

### Flag Usage Scenarios

```
Scenario 1: New User on New Device
─────────────────────────────────────
isNewMaster = true      → First time this email is used
isFirstEverLink = true  → First account for this device

Scenario 2: Existing User on New Device
─────────────────────────────────────────
isNewMaster = false     → User has logged in before
isFirstEverLink = true  → But this device is new

Scenario 3: Existing User on Same Device (Re-login)
───────────────────────────────────────────────────
isNewMaster = false     → User exists
isFirstEverLink = false → Device already linked

Scenario 4: Different User on Same Device
─────────────────────────────────────────
ERROR: platform_already_taken
→ Device cannot switch to different Master User
```

---

## API Endpoints

### Authentication Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `authenticate/auth` | POST | JWT | Main authentication - links Platform User to Master User |
| `authenticate/master` | DELETE | JWT | Delete master user account (soft delete supported) |
| `authenticate` | GET | None | Get auth profiles for Platform User |
| `one-time-passwords/send-to-email` | POST | None | Request OTP for email login |
| `one-time-passwords/exchange` | POST | None | Exchange OTP for Firebase custom token |

### Account Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `account` | GET | JWT + Account-Id | Get current account details |
| `account/all?includeActivity=true` | GET | JWT | Get all accounts for Master User |
| `account/all-by-platform-user?platformUserId={id}` | GET | None | Get accounts by Platform User |
| `account?accountId={id}` | DELETE | JWT | Delete specific account |
| `account/pricing` | GET | None | Get product pricing |
| `account/features` | GET | JWT | Get feature flags |
| `account/set_identifiers` | PUT | JWT | Update account identifiers |
| `account/claim-email` | POST | JWT | Claim email ownership |
| `account-configurations/set` | POST | JWT | Set account configurations |
| `account-configurations/regional` | PATCH | JWT | Update regional settings |

### Subscription Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `account/receipt` | PUT | JWT | Upload App Store receipt with transactions |
| `plans/current` | GET | JWT | Get current subscription plan |

---

## Authentication Flow

### Sign-In Methods
1. **Google Sign-In** - OAuth via Firebase
2. **Apple Sign-In** - Apple ID via Firebase
3. **Email OTP** - Custom token via backend

### Authentication Sequence Diagram

```
┌────────┐     ┌──────────┐     ┌──────────┐     ┌─────────┐
│  App   │     │ Firebase │     │ Backend  │     │ Storage │
└───┬────┘     └────┬─────┘     └────┬─────┘     └────┬────┘
    │               │                │                │
    │ 1. Sign In    │                │                │
    │──────────────>│                │                │
    │               │                │                │
    │ 2. JWT Token  │                │                │
    │<──────────────│                │                │
    │               │                │                │
    │ 3. POST /authenticate/auth     │                │
    │   {userPlatformId, JWT}        │                │
    │───────────────────────────────>│                │
    │               │                │                │
    │ 4. AuthResultDTO               │                │
    │   {masterUserId,               │                │
    │    isNewMaster,                │                │
    │    isFirstEverLink}            │                │
    │<───────────────────────────────│                │
    │               │                │                │
    │ 5. Store credentials           │                │
    │────────────────────────────────────────────────>│
    │               │                │                │
    │ 6. GET /account/all            │                │
    │───────────────────────────────>│                │
    │               │                │                │
    │ 7. [AccountInfo]               │                │
    │<───────────────────────────────│                │
    │               │                │                │
    │ 8. Select/Create Account       │                │
    │────────────────────────────────────────────────>│
    │               │                │                │
```

### Email OTP Flow

```
┌────────┐              ┌─────────┐              ┌──────────┐
│  App   │              │ Backend │              │ Firebase │
└───┬────┘              └────┬────┘              └────┬─────┘
    │                        │                        │
    │ 1. POST /one-time-passwords/send-to-email      │
    │   {email}              │                        │
    │───────────────────────>│                        │
    │                        │                        │
    │ 2. OTP sent to email   │                        │
    │<───────────────────────│                        │
    │                        │                        │
    │  [User enters OTP]     │                        │
    │                        │                        │
    │ 3. POST /one-time-passwords/exchange           │
    │   {email, oneTimePassword}                     │
    │───────────────────────>│                        │
    │                        │                        │
    │ 4. {authenticationToken}                       │
    │<───────────────────────│                        │
    │                        │                        │
    │ 5. signIn(withCustomToken)                     │
    │───────────────────────────────────────────────>│
    │                        │                        │
    │ 6. Firebase User + JWT │                        │
    │<───────────────────────────────────────────────│
    │                        │                        │
    │ 7. Continue with standard auth flow...         │
    │                        │                        │
```

---

## Subscription Management

### Subscription Response Model

```json
{
  "isActive": true,
  "planId": "premium",
  "isTrialAvailable": false,
  "duration": "week|month|year",
  "expirationTime": "2024-12-31T23:59:59Z",
  "currentTime": "2024-01-01T00:00:00Z",
  "isAutoRenewEnabled": true,
  "firstPurchaseDate": "2024-01-01T00:00:00Z",
  "adapterType": 1,
  "originProductId": "com.app.subscription.weekly"
}
```

### Receipt Upload Flow

```
┌────────┐     ┌───────────┐     ┌─────────┐
│  App   │     │ App Store │     │ Backend │
└───┬────┘     └─────┬─────┘     └────┬────┘
    │                │                │
    │ 1. Purchase    │                │
    │───────────────>│                │
    │                │                │
    │ 2. Receipt     │                │
    │<───────────────│                │
    │                │                │
    │ 3. PUT /account/receipt         │
    │   {receiptData (base64),        │
    │    transactions: [{             │
    │      transactionId,             │
    │      productId,                 │
    │      countryCode,               │
    │      currencyCode,              │
    │      price                      │
    │    }],                          │
    │    context}                     │
    │───────────────────────────────->│
    │                │                │
    │ 4. SubscriptionResponse         │
    │<────────────────────────────────│
    │                │                │
    │ 5. GET /plans/current           │
    │───────────────────────────────->│
    │                │                │
    │ 6. SubscriptionPlanApi          │
    │<────────────────────────────────│
    │                │                │
```

---


## Account Selection Logic

After authentication, account selection follows this priority:

```
1. If current accountId matches server account → Keep it
2. If no match → Select account with:
   - Most invoices/estimates
   - Most recent activity
   - Non-empty business name
3. If no valid accounts → Create new account locally
```

---

## Endpoint Use Cases

This section documents all scenarios when each API endpoint is called by the iOS app, how response data is used, and what the backend should expect.

---

### Authentication Endpoints

---

#### `POST /authenticate/auth`

**Purpose**: Links Platform User (device) to Master User (Firebase account) after successful OAuth/Email authentication.

**When Called**:

| # | Scenario | Description | Expected Behavior |
|---|----------|-------------|-------------------|
| 1 | First-time Google Sign-In | User taps "Sign in with Google" during onboarding or on login screen | New master user created, `isNewMaster=true`, `isFirstEverLink=true` |
| 2 | First-time Apple Sign-In | User taps "Sign in with Apple" during onboarding or on login screen | New master user created, `isNewMaster=true`, `isFirstEverLink=true` |
| 3 | Returning user on new device (Google) | Existing user logs in with Google on a different device | `isNewMaster=false`, `isFirstEverLink=true` (new device) |
| 4 | Returning user on new device (Apple) | Existing user logs in with Apple on a different device | `isNewMaster=false`, `isFirstEverLink=true` (new device) |
| 5 | Re-login on same device | User logs back in after logging out | `isNewMaster=false`, `isFirstEverLink=false` |
| 6 | Email OTP authentication complete | After user confirms 6-digit OTP code | Same flags logic as OAuth |
| 7 | Account switching | User chooses to add/switch account while already logged in | Called with new JWT, may get `platform_already_taken` error |

**How Response is Used**:

| Field | Usage |
|-------|-------|
| `masterUserId` | Stored locally as `authMasterUserId`. Used to identify the authenticated user across sessions. |
| `isNewMaster` | If `true`, triggers new user analytics events. Indicates first-ever login to the system. |
| `isFirstEverLink` | Stored locally as `isFirstMaster`. **Critical for subscription logic** - determines if user is eligible for trial/purchase offers. If `false`, user may have subscription from another device. |

**After Successful Response**:
1. App stores `masterUserId` locally
2. App stores `isFirstEverLink` as `isFirstMaster` flag
3. App immediately calls `GET /account/all` to fetch user's accounts
4. App calls `GET /plans/current` to sync subscription status
5. Analytics event fired with `isNewMaster` and `isFirstEverLink` flags

**Error Cases**:

| Error Code | When | App Behavior |
|------------|------|--------------|
| `platform_already_taken` | Platform User already linked to a different Master User | User is logged out, shown error that device is linked to another account |
| `master_deleted` | The Master User was previously soft-deleted | User is logged out, shown "account deleted" message |

---

#### `DELETE /authenticate/master`

**Purpose**: Soft-delete the Master User account. Always called with `softDelete=true` from iOS.

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | User requests account deletion | User navigates to Settings → Delete Account → Confirms deletion |

**Backend Expectations**:
- Always called with `softDelete=true` from iOS
- Should mark Master User as deleted but preserve data for potential recovery
- All linked Platform Users should receive `master_deleted` error on next auth attempt

**After Successful Response**:
1. All local account data is cleared
2. User is logged out from Firebase
3. App navigates to authentication screen
4. On next app launch, `GET /authenticate` will return empty list

---

#### `GET /authenticate?platformUserId={id}`

**Purpose**: Check if this device (Platform User) has any previously authenticated profiles. Called **without JWT authentication**.

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | App launch - authentication state check | Called immediately after app starts to determine if device was previously authenticated |

**How Response is Used**:

| Response | App Behavior |
|----------|--------------|
| Empty array `[]` | Device has never been authenticated → Show onboarding/login screen |
| Non-empty array | Device was previously authenticated → Can show quick login or account selection |
| Array with deleted accounts | Backend deleted all masters → Switch to non-authorized flow |

---

#### `POST /one-time-passwords/send-to-email`

**Purpose**: Request OTP code to be sent to user's email for passwordless authentication.

**When Called**:

| # | Scenario | Description | Rate Limiting Note |
|---|----------|-------------|-------------------|
| 1 | Initial email entry | User enters email on login screen and taps "Continue" | First request, no limit |
| 2 | Resend OTP | User taps "Resend" button on OTP input screen | App enforces 30-second cooldown client-side |

**Backend Expectations**:
- Send 6-digit OTP to provided email
- OTP should have reasonable expiration (e.g., 5-10 minutes)
- Return `password_sending_temporary_forbidden` if rate limit exceeded

**Error Cases**:

| Error Code | When | App Behavior |
|------------|------|--------------|
| `password_sending_temporary_forbidden` | Too many OTP requests | Show cooldown message to user |

---

#### `POST /one-time-passwords/exchange`

**Purpose**: Exchange valid OTP code for Firebase custom authentication token.

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | OTP verification | User enters all 6 digits of OTP code received via email |

**How Response is Used**:
1. `authenticationToken` is used to authenticate with Firebase: `Firebase.signIn(withCustomToken: token)`
2. After Firebase authentication succeeds, app calls `POST /authenticate/auth` with the new JWT
3. Standard authentication flow continues

**Error Cases**:

| Error Code | When | App Behavior |
|------------|------|--------------|
| `invalid_one_time_password` | OTP code is incorrect or expired | Show error, allow user to retry or resend |
| `master_deleted` | Account associated with email was deleted | Logout, show "account deleted" error |
| `platform_already_taken` | Device already linked to different account | Logout, show error about device linking |

---

### Account Endpoints

---

#### `GET /account`

**Purpose**: Retrieve full business data for a specific account.

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | Account restore | When user initiates account restore process to recover business data |

**How Response is Used**:
- Full account business data (business name, contacts, logo, settings) is loaded into local database
- Used for account recovery/restore scenarios

---

#### `GET /account/all?includeActivity=true`

**Purpose**: Get all accounts owned by the authenticated Master User with activity statistics.

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | Immediately after authentication | After `POST /authenticate/auth` succeeds, app fetches all accounts to select one |
| 2 | Account cache refresh | Periodic refresh when cache becomes stale (authorized users) |
| 3 | After account data changes | When backend sends notification that account data was modified |

**How Response is Used**:

| Field | Usage |
|-------|-------|
| `id` | Used as `Account-Id` header for subsequent requests |
| `name` | Displayed in account switcher UI |
| `totalInvoices`, `totalEstimates` | Used to auto-select "most active" account after login |
| `lastInvoiceActivity`, `lastEstimateActivity` | Used for account selection priority (most recent activity preferred) |
| `logoUrl` | Displayed in account list and profile |

**Account Selection Logic After Login**:
1. If locally stored `accountId` matches one from response → Use that account
2. Otherwise, select account with: most invoices/estimates + most recent activity + non-empty name
3. If no valid accounts → Create new local account

---

#### `GET /account/all-by-platform-user?platformUserId={id}`

**Purpose**: Get accounts linked to a device without requiring authentication. Called **without JWT**.

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | Non-authorized app launch | When app starts and user is not logged in, to check if device has any linked accounts |

---

#### `GET /account/pricing`

**Purpose**: Get product pricing information from server for analytics.

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | After subscription purchase | To get server-side price for analytics/tracking purposes |

**How Response is Used**:
- Price for specific `productId` is extracted from response
- Used for purchase analytics and tracking (not for display to user - that comes from App Store)

---

#### `GET /account/features`

**Purpose**: Get feature flags/configuration for the current account.

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | App startup | Called once during app initialization to load feature flags |

**How Response is Used**:
- Feature flags are stored locally
- Used to enable/disable features, show/hide UI elements
- Allows backend-controlled feature rollouts

---

#### `PUT /account/set_identifiers`

**Purpose**: Update account identifiers for analytics and push notifications.

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | App comes to foreground | Periodic sync of identifiers when app becomes active |
| 2 | App startup | During app initialization |
| 3 | After account change | When user switches to different account |
| 4 | After push token refresh | When APNS token is updated |

**Backend Expectations**:
- Store identifiers for analytics integration (AppsFlyer, etc.)
- Store push token for push notification delivery
- Called frequently (every app foreground), should be idempotent

---

#### `POST /account/claim-email`

**Purpose**: Claim email ownership for web-to-app account linking.

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | Web-to-app deep link | When user clicks link from web to connect web account with mobile app |

---

#### `PATCH /account-configurations/regional`

**Purpose**: Update regional settings (locale/culture). Sends device locale identifier (e.g., "en_US", "de_DE").

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | App startup | Called once during initialization to sync device locale with backend |

**Backend Expectations**:
- Used to set default currency, date formats, etc. for the account

---

### Subscription Endpoints

---

#### `PUT /account/receipt`

**Purpose**: Upload App Store receipt to validate and synchronize subscription status.

**When Called**:

| # | Scenario | Description | `transactions` | `context` |
|---|----------|-------------|----------------|-----------|
| 1 | Purchase completed | User successfully purchases subscription in App Store | Contains transaction details | Paywall location (e.g., "onboarding", "settings", "limit_reached") |
| 2 | Subscription restored | User restores previous purchase | Contains restored transaction | May be null |
| 3 | App comes to foreground | Periodic sync to verify subscription status | Empty array `[]` | `null` |
| 4 | Force refresh | User pulls to refresh or app needs to verify status | Empty array `[]` | `null` |
| 5 | Migration | One-time migration from old receipt format | Empty or transaction data | `null` |

**Context Values** (for analytics):
- `"paywall_onboarding"` - Purchase from onboarding flow
- `"paywall_settings"` - Purchase from settings/profile
- `"paywall_limit_reached"` - Purchase when hitting free tier limits
- `null` - Sync/refresh scenarios

**Backend Expectations**:
- Validate receipt with Apple's servers
- Extract subscription status from receipt
- Store transaction details for analytics
- Return current subscription status

**Important Notes**:
- Called **frequently** (every app foreground) with empty transactions for sync
- Called with transaction details only after actual purchases
- `receiptData` is always the full App Store receipt (base64 encoded)

---

#### `GET /plans/current`

**Purpose**: Get current subscription plan status.

**When Called**:

| # | Scenario | Description |
|---|----------|-------------|
| 1 | After successful login (Google) | Immediately after authentication to sync subscription status |
| 2 | After successful login (Apple) | Immediately after authentication to sync subscription status |
| 3 | After successful login (Email OTP) | Immediately after authentication to sync subscription status |
| 4 | App comes to foreground | Periodic check when app becomes active |
| 5 | After identifiers synced | After `PUT /account/set_identifiers` completes |
| 6 | After receipt upload | To confirm subscription status after `PUT /account/receipt` |
| 7 | User pulls to refresh | Manual refresh on profile/subscription screen |
| 8 | Cache expired | When local cache is older than 30 minutes |
| 9 | Migration flag set | When backend requires subscription data refresh |
| 10 | TestFlight sandbox testing | Additional check on welcome screen for sandbox purchases |

**How Response is Used**:

| Field | Usage |
|-------|-------|
| `isActive` | **Primary flag** - determines if user has premium access |
| `planId` | Identifies subscription tier |
| `expirationTime` | Displayed to user, used for expiration warnings |
| `isTrialAvailable` | If `true`, user can start trial; if `false`, already used trial |
| `isAutoRenewEnabled` | Shown in subscription management UI |
| `adapterType` | Determines subscription source: 0=None, 1=AppStore, 2=GooglePlay, 3=Stripe, etc. |
| `currentTime` | Server time, used to calculate time differences reliably |
| `duration` | `"week"`, `"month"`, or `"year"` - subscription period |

**Caching Behavior**:
- Response is cached locally for 30 minutes
- After cache expires, fresh data is fetched from server
- Manual refresh bypasses cache

**Backend Note**: This endpoint is called **very frequently** (every app foreground, after every login, after every purchase). Responses should be fast and cacheable.

