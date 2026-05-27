Authentication in Invoices.Backend
===================================

This document describes the two main authentication scenarios used by
`AccountAuthenticationMiddleware` in Invoices.Backend.

Overview
--------

Every non-anonymous request goes through `AccountAuthenticationMiddleware`.
The middleware tries each strategy in order and stores the result in
`HttpContext.Items` so controllers can read it via `BaseController`:

| Strategy | `AuthenticationType` value | When used |
|---|---|---|
| Bearer JWT token | `AuthenticationApi` | Web and mobile clients that sign in through Tofu.Auth |
| Account-Id + Signature | `AccountIdWithSignature` | Legacy mobile clients, server-to-server calls |
| Anonymous | `Anonymous` | Endpoints marked with `[AllowAnonymous]` |

Required headers common to both authenticated strategies:

| Header | Description |
|---|---|
| `XA-App-Type` | Product key (must be in the configured `AvailableProducts` list) |
| `XA-OsType` | Platform identifier (IOS, Android, Web) |
| `Account-Id` | Target account (optional for Bearer, required for Signature) |

Scenario 1 — Bearer JWT Token (AuthenticationApi)
--------------------------------------------------

This is the primary authentication path for all modern clients.

### Flow

1. Client authenticates with **Tofu.Auth** (email/OTP, Google, Apple, or anonymous).
2. Tofu.Auth issues a **Firebase JWT** signed with RS256.
3. Client sends requests with `Authorization: Bearer <token>` header.
4. Middleware calls `IAuthApiAuthenticationService.AuthenticateWithAuthApi()` which
   forwards the token to Tofu.Auth via `ITofuAuthApiClient.GetAuthenticatedUserInfoAsync()`.
5. Tofu.Auth validates the token:
   - Verifies JWT signature against Firebase public certificates.
   - Checks issuer (`https://securetoken.google.com/{projectId}`) and audience.
   - Validates lifetime (expiration).
   - Checks token revocation (`auth_time` vs `TokensValidAfterTimestamp`).
   - Extracts claims: `sub` (user id), `email`, `email_verified`, `firebase.sign_in_provider`.
6. Invoices.Backend receives the authenticated user info, resolves the **MasterUser**
   from its own database, and resolves the target account.
7. Middleware stores:
   - `AuthenticationType` = `AuthenticationApi`
   - `MasterUserId`, `UserEmail`, `AccountId`, `AuthenticationInfo`

### What controllers receive

```csharp
// BaseController properties available after Bearer auth:
AuthenticationInfo.MasterUser   // full MasterUser entity
AuthenticationInfo.MasterUserId // stable backend user id
AuthenticationInfo.Email        // user email (nullable)
AuthenticationInfo.AccountId    // resolved account id
```

### Auth via query string

Endpoints decorated with `[AuthAlsoInQuery]` accept an alternative token
delivery: the `?Auth=` query parameter containing a Base64-encoded JSON
dictionary with the same header keys. This is used for scenarios where HTTP
headers cannot be set (e.g. direct browser links for PDF/document downloads).

Scenario 2 — Account-Id + Signature (AccountIdWithSignature)
-------------------------------------------------------------

A legacy HMAC-like scheme where the client proves it knows a shared secret
without sending credentials directly.

### Required headers

| Header | Description |
|---|---|
| `Account-Id` | The account to act on (required) |
| `Signature` | MD5 hash proving request integrity |
| `Timestamp` | Unix timestamp of the request (validated as a parseable `long`) |

### Signature computation

The signature is an MD5 hex digest of the concatenation:

```
MD5( AccountId + SerializedRequest + Timestamp + ClientSecret )
```

Where `SerializedRequest` is:

```
{HttpMethod}{Path}{QueryString}{Body}
```

Example for `POST /api/invoices?status=draft` with body `{"name":"test"}`:

```
SerializedRequest = "POST/api/invoices?status=draft{\"name\":\"test\"}"
```

### Verification

1. Middleware checks that `Account-Id`, `Signature`, and `Timestamp` headers are present.
2. It rebuilds the expected signature for each configured `ClientSecret`
   (multiple secrets supported, semicolon-separated in `Authentication:ClientSecret`).
3. If any secret produces a matching MD5, the request is accepted.
4. On mismatch, a 401 is returned.

### Exceptions to signature checking

- Endpoints for `/api/email` and `/api/logo` skip signature verification.
- Endpoints decorated with `[IgnoreSignature]` skip verification.
- In non-production environments a **magic signature** value bypasses the check
  (configured via `AccountAuthenticationMiddlewareOptions.MagicSignature`).

### What controllers receive

Only `AccountId` is set. There is no `MasterUser` or email in this scenario:

```csharp
// BaseController properties available after Signature auth:
AccountId  // from Account-Id header
// AuthenticationInfo is null
```

Middleware priority
------------------

The middleware evaluates in this order:

1. **AllowAnonymous** — if the endpoint has the attribute, set `Anonymous` and
   pass through immediately.
2. **Bearer token** — call `AuthenticateWithAuthApi()`. If it returns a non-null
   `AuthenticationInfo`, set `AuthenticationApi` and pass through.
3. **Signature** — if Bearer auth returned null, fall back to Account-Id +
   Signature verification and set `AccountIdWithSignature`.

If neither strategy succeeds, the middleware throws `AuthenticationException`.
