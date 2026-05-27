# Account List Filtering by App Type

## Problem

When a user is both an admin of their own business and an invited worker in someone else's business, all account-listing endpoints return the full set of accounts regardless of which app is making the request. Field Service and Invoice Maker are standalone apps for managing your own businesses — showing worker accounts in these apps is confusing and not a supported workflow.

## Background

### Account ownership model

A master user has two collections of accounts:

- **OwnedAccounts** — accounts the user created. The user is the owner/admin (`TenantRole` is not set).
- **MemberAccounts** — accounts the user was invited to as a worker. Each entry carries a `TenantRole` (e.g. `"Worker"`).

Both collections are documented in `Backend/Services/Invoices.Backend/Accounts.md`.

### App type detection

Each request carries an `XA-App-Type` header with a product key. The middleware extracts this value and makes it available to controllers.

Product keys relevant to this feature:

| Product key | App |
|-------------|-----|
| `tofu-fieldservice` | Field Service |
| `invoices` | Invoice Maker (iOS) |
| `invoices-android` | Invoice Maker (Android) |
| `tofu` | Tofu (Worker App / Web) |
| `invoices.web` | Invoices Web |

Product keys are defined in `ProductConst` (`Invoices.Core/Models/ProductConst.cs`).

### Affected endpoints

All account-listing endpoints on the V3 account controller (`Invoices.Api/Controllers/V3/AccountController.cs`):

| Endpoint | Description |
|----------|-------------|
| `GET /api/account/all-by-account-id` | Accounts linked to the current account via user id lookup |
| `GET /api/account/all` | All accounts for the authenticated master user |
| `GET /api/account/all-by-platform-user` | Accounts for a given platform user id (anonymous) |

---

## Behaviour

### Current behaviour

All three endpoints return the full set of accounts — both `OwnedAccounts` and `MemberAccounts` — for the requesting user, regardless of which app is calling.

### New behaviour

- **Field Service and Invoice Maker apps** (`tofu-fieldservice`, `invoices`, `invoices-android`): return only `OwnedAccounts`. Exclude `MemberAccounts`.
- **All other apps**: no change. Continue returning the full set (owned + member).

### Anonymous endpoint is safe by design

The `GET /api/account/all-by-platform-user` endpoint is anonymous (uses only a platform user id, no master user). This endpoint cannot return member accounts because a non-authorized user can never have them — accepting an invitation (`POST /api/invitations/{token}/accept` and `POST /api/invitations/accept-all`) requires an authenticated master user. Without authorization, a user only has accounts they created themselves, so filtering is not needed for this endpoint.

### Example

A user is admin of "My Plumbing Co" and an invited worker in "Big Corp":

| App | Accounts returned |
|-----|-------------------|
| Field Service | My Plumbing Co |
| Invoice Maker (iOS) | My Plumbing Co |
| Tofu Worker App | My Plumbing Co, Big Corp |
| Invoices Web | My Plumbing Co, Big Corp |

---

## Implementation Notes

### Where to filter

The filtering should happen when resolving which account ids to load, before calling the account-loading service. The product key is already available in the controller via the middleware.

### Key files

| File | Role |
|------|------|
| `Invoices.Api/Controllers/V3/AccountController.cs` | Account listing endpoints |
| `Invoices.Core/Models/MasterUser.cs` | `OwnedAccounts`, `MemberAccounts`, `AllAccountIds` |
| `Invoices.Core/Models/ProductConst.cs` | Product key constants |
| `Invoices.Api/Middleware/AccountAuthenticationMiddleware.cs` | Extracts product key from `XA-App-Type` header |
| `Invoices.Implementation.Services/Authentication/AuthService.cs` | `GetOwnedAccountInfos()` |
| `Invoices.Api/Controllers/BaseController.cs` | Base controller with auth info and product key access |

### Other endpoints investigated

iOS apps also call these endpoints which could potentially return account data:

| Endpoint | Returns accounts? | Needs filtering? | Why |
|----------|-------------------|-------------------|-----|
| `GET /api/authenticate?platformUserId` | Yes — business names | No | Already uses only `OwnedAccounts` internally (`FindBusinessNames` iterates `masterUser.OwnedAccounts`). Response DTO is named `OwnedAccountInfos`. |
| `POST /api/account-configurations/set` | No | No | Operates on a single account by `AccountId`. |
| `PATCH /api/account-configurations/regional` | No | No | Operates on a single account by `AccountId`. |
| `GET /api/account-configurations/regional` | No | No | Operates on a single account by `AccountId`. |
| `GET /api/worker/businesses` | Yes — all tenants | No | Dedicated worker endpoint. Returns all tenants (owned + invited) with `RoleLevel` from Tofu.Auth. Used by Worker App only. |

### Scope

This change is limited to the three account-listing endpoints on the V3 account controller. It does not affect:

- Account creation or update flows.
- Single-account retrieval (`GET /api/account`).
- Authentication endpoints (already scoped to owned accounts).
- Account configuration endpoints (single-account operations).
- Worker-specific endpoints (`/api/worker/*`).
- Worker invitation or acceptance flows.
- Any Tofu.Auth behaviour.

---

## Related Documentation

- `Backend/Services/Invoices.Backend/Accounts.md` — account ownership model
- `Backend/Services/Invoices.Backend/Users.md` — master user and platform user concepts
- `features/jobs/implementation/5_worker_users/overview.md` — admin vs worker role split
