# Authentication Flow

Complete authentication flow across Invoices.Backend and Tofu.Auth.Backend.

## Overview

The system supports three authentication types:

| Type | Header | MasterUser | Use Case |
|------|--------|------------|----------|
| **AuthenticationApi** | Bearer JWT or Session Cookie | Yes | Mobile apps, web UI |
| **AccountIdWithSignature** | Account-Id + Signature + Timestamp | No | Legacy clients |
| **Anonymous** | None (endpoint allows) | No | Public endpoints (OTP, auth) |

---

## 1. Request Authentication (Middleware)

Every request to `/api/*` or `/web-links/*` passes through `AccountAuthenticationMiddleware`.

```mermaid
flowchart TD
    A[Incoming Request] --> B[Extract headers:<br/>XA-App-Type, XA-OsType,<br/>Account-Id, Signature, Timestamp]
    B --> C{Endpoint has<br/>AllowAnonymous?}
    C -->|Yes| D[AuthType = Anonymous<br/>Skip auth]
    C -->|No| E[Validate ProductKey<br/>against AvailableProducts]
    E -->|Invalid| F[401 AuthenticationException]
    E -->|Valid| G{Account-Id<br/>present?}
    G -->|Yes| H[Check ban status<br/>IBanService.CheckByAccountId]
    G -->|No| I[Skip ban check]
    H -->|Banned| J[403 UserOrAccountIsBannedException]
    H -->|OK| K[Try API Authentication]
    I --> K

    K --> L{Bearer token or<br/>session cookie<br/>present?}
    L -->|Yes| M[Call Tofu.Auth:<br/>GetAuthenticatedUserInfoAsync]
    L -->|No| N[Fall back to<br/>Signature Auth]

    M -->|Success| O[Resolve MasterUser<br/>from database]
    M -->|Fail| N

    O --> P{MasterUser<br/>found?}
    P -->|No| Q[AuthInfo with<br/>null MasterUser]
    P -->|Deleted| R[403 MasterHasBeenDeletedException]
    P -->|Yes| S[Resolve AccountId<br/>from owned/member accounts]

    S --> T[AuthType = AuthenticationApi<br/>Set context: MasterUserId,<br/>Email, AccountId, AuthInfo]

    N --> U{Signature<br/>required?}
    U -->|Skip: /api/email, /api/logo,<br/>IgnoreSignature| V[AuthType = AccountIdWithSignature<br/>No signature check]
    U -->|Yes| W{Magic signature?<br/>non-prod only}
    W -->|Yes| V
    W -->|No| X[Verify MD5 signature:<br/>MD5 AccountId + Request + Timestamp + Secret]
    X -->|Invalid| Y[401 AuthenticationException]
    X -->|Valid| V

    D --> Z[Set HttpContext.Items<br/>→ Controllers via BaseController]
    Q --> Z
    T --> Z
    V --> Z
```

---

## 2. Bearer JWT Authentication (Tofu.Auth side)

When Invoices.Backend calls `GetAuthenticatedUserInfoAsync`, Tofu.Auth validates the JWT.

```mermaid
sequenceDiagram
    participant Client
    participant BFF as Invoices.Backend
    participant Auth as Tofu.Auth
    participant FB as Firebase Auth

    Client->>BFF: Request with Authorization: Bearer <JWT>
    BFF->>Auth: GET /users/authenticated/info<br/>(forwards Bearer token)

    Auth->>FB: Validate JWT signature<br/>against Firebase public keys
    FB-->>Auth: Claims identity

    Note over Auth: Validate:<br/>- Issuer = securetoken.google.com/{projectId}<br/>- Audience = Firebase project ID<br/>- Token not expired<br/>- Required claims present

    Auth->>Auth: Check token revocation<br/>(auth_time vs TokenRevocation.RevokedAt)

    alt Token revoked
        Auth-->>BFF: 401 RevokedTokenException
        BFF-->>Client: 401 Unauthorized
    else Token valid
        Auth->>Auth: RegisterOrUpdateUser<br/>(sync claims to DB)
        Auth-->>BFF: AuthenticatedUserInfoResponse<br/>{userId, email}
        BFF->>BFF: Resolve MasterUser + AccountId
        BFF-->>Client: API Response
    end
```

---

## 3. Session Cookie Flow

Browser clients use session cookies instead of short-lived JWTs.

```mermaid
sequenceDiagram
    participant Client as Browser Client
    participant BFF as Invoices.Backend
    participant Auth as Tofu.Auth
    participant FB as Firebase Auth

    Note over Client: After initial JWT login...

    rect rgb(240, 248, 255)
        Note over Client,FB: Create Session Cookie
        Client->>BFF: POST /authenticate/auth<br/>{setCookie: true}
        BFF->>Auth: GET /users/authenticated/session-cookie<br/>(Bearer JWT)
        Auth->>FB: CreateSessionCookieAsync(jwt, 5 days)
        FB-->>Auth: Session cookie string
        Auth-->>BFF: CreateSessionCookieResponse
        BFF-->>Client: Set-Cookie: session=...<br/>(HttpOnly, Secure, SameSite=Lax, 5 days)
    end

    rect rgb(240, 255, 240)
        Note over Client,FB: Exchange Session Cookie for JWT
        Client->>BFF: POST /authenticate/token<br/>(cookie auto-sent)
        BFF->>Auth: GET /users/session-cookie/exchange<br/>(X-Session-Cookie header)
        Auth->>FB: VerifySessionCookieAsync
        FB-->>Auth: userId + authTime
        Auth->>Auth: Check token revocation
        Auth->>FB: GenerateAuthenticationTokenAsync(userId)
        FB-->>Auth: Fresh JWT
        Auth-->>BFF: ExchangeSessionCookieResponse {jwt}
        BFF-->>Client: Bearer token
    end

    rect rgb(255, 240, 240)
        Note over Client,FB: Logout (Revoke)
        Client->>BFF: POST /authenticate/logout
        BFF->>Auth: POST /users/authenticated/logout
        Auth->>Auth: Create TokenRevocation record<br/>(userId, platform, productKey, revokedAt)
        Auth-->>BFF: OK
        BFF-->>Client: Delete session cookie
    end
```

---

## 4. Email OTP Login Flow

Passwordless authentication via one-time password.

```mermaid
sequenceDiagram
    participant Client
    participant BFF as Invoices.Backend
    participant Auth as Tofu.Auth
    participant FB as Firebase Auth
    participant Email as Email Service

    rect rgb(240, 248, 255)
        Note over Client,Email: Step 1 — Send OTP
        Client->>BFF: POST /api/one-time-passwords/send-to-email<br/>{email}
        BFF->>Auth: POST /one-time-passwords/send-to-email
        Auth->>Auth: Generate 6-digit OTP<br/>Store SHA256 hash in DB<br/>(5-min expiry, max 5 attempts)
        Auth->>Email: Send HTML email with OTP<br/>from noreply@tofu.com
        Auth-->>BFF: 200 OK
        BFF-->>Client: 200 OK
    end

    Note over Client: User reads OTP from inbox

    rect rgb(240, 255, 240)
        Note over Client,Email: Step 2 — Exchange OTP for Token
        Client->>BFF: POST /api/one-time-passwords/exchange<br/>{email, oneTimePassword}
        BFF->>Auth: POST /one-time-passwords/exchange

        Auth->>Auth: Verify OTP:<br/>SHA256(input) == stored hash<br/>Check expiry + attempt count

        alt Invalid OTP
            Auth-->>BFF: 400 InvalidOneTimePasswordException
        else Expired
            Auth-->>BFF: 400 OneTimePasswordExpiredException
        else Too many attempts
            Auth-->>BFF: 429 TooManyPasswordChecksException
        else Valid
            Auth->>FB: FindByEmail or CreateUser
            Auth->>FB: GenerateAuthenticationTokenAsync
            FB-->>Auth: JWT
            Auth-->>BFF: {authenticationToken: JWT}
            BFF-->>Client: {authenticationToken: JWT}
        end
    end

    rect rgb(255, 248, 240)
        Note over Client,Email: Step 3 — Establish Session
        Client->>BFF: POST /api/authenticate/auth<br/>(Bearer JWT)
        BFF->>Auth: GetAuthenticatedUserInfoAsync
        Auth-->>BFF: {userId, email}
        BFF->>BFF: TryRegister MasterUser<br/>Link PlatformUser
        BFF-->>Client: AuthResponse<br/>{masterUserId, isNewMaster, isFirstEverLink}
    end
```

---

## 5. Signature Authentication (Legacy)

HMAC-like scheme for legacy clients that don't use JWT.

```mermaid
flowchart TD
    A[Client builds request] --> B["Serialize request:<br/>Method + Path + QueryString + Body"]
    B --> C["Build content to sign:<br/>AccountId + SerializedRequest + Timestamp"]
    C --> D["Compute signature:<br/>MD5(content + ClientSecret) → hex"]
    D --> E["Send request with headers:<br/>Account-Id, Signature, Timestamp"]
    E --> F[Middleware receives request]
    F --> G{Endpoint excluded?<br/>/api/email, /api/logo,<br/>IgnoreSignature}
    G -->|Yes| H[Skip signature check]
    G -->|No| I{Magic signature?<br/>non-prod only}
    I -->|Yes| H
    I -->|No| J["Recompute MD5 with each<br/>configured ClientSecret"]
    J --> K{Signature match?}
    K -->|No| L[401 AuthenticationException]
    K -->|Yes| M[AuthType = AccountIdWithSignature<br/>AccountId from header<br/>No MasterUser available]
```

---

## 6. Token Revocation

```mermaid
stateDiagram-v2
    [*] --> Active: JWT issued

    Active --> Active: API requests succeed<br/>(auth_time > revokedAt)
    Active --> Revoked: POST /logout<br/>(creates TokenRevocation record)

    Revoked --> Rejected: Any API request<br/>(auth_time < revokedAt)

    state Revoked {
        [*] --> WebRevocation: Platform = Web<br/>Match by ProductKey
        [*] --> MobileRevocation: Platform = iOS/Android<br/>Match by DeviceId
    }

    note right of Revoked
        TokenRevocation stores:
        userId, platform, productKey,
        deviceId, revokedAt
    end note
```

---

## 7. Account ID Resolution

How the middleware determines which account a user is accessing.

```mermaid
flowchart TD
    A[MasterUser found in DB] --> B{How many accounts?<br/>owned + member}
    B -->|0 accounts| C{Account-Id<br/>header present?}
    C -->|Yes| D[Use header value<br/>Mark user as owner]
    C -->|No| E[AccountId = null]

    B -->|1 account| F{Account-Id<br/>header matches?}
    F -->|Yes or no header| G[Use the single account]
    F -->|Different header| H[Use header<br/>Mark as owner if needed]

    B -->|2+ accounts| I{Account-Id<br/>header present?}
    I -->|Yes| J[Use header value<br/>Validate user has access]
    I -->|No| K[Use first account]

    J --> L{User has access?}
    L -->|No| M[Mark as owner<br/>or error]
    L -->|Yes| N[Set AccountId in context]

    D --> N
    G --> N
    H --> N
    K --> N
```

---

## 8. Full Login Sequence (Mobile App)

End-to-end flow for a mobile app user signing in with Email OTP.

```mermaid
sequenceDiagram
    participant App as Mobile App
    participant BFF as Invoices.Backend
    participant Auth as Tofu.Auth
    participant FB as Firebase

    App->>BFF: POST /api/one-time-passwords/send-to-email {email}
    BFF->>Auth: Forward OTP request
    Auth-->>BFF: 200 OK (OTP sent to email)
    BFF-->>App: 200 OK

    Note over App: User enters OTP from email

    App->>BFF: POST /api/one-time-passwords/exchange {email, otp}
    BFF->>Auth: Forward exchange request
    Auth->>FB: Create/find user + generate JWT
    Auth-->>BFF: {authenticationToken: JWT}
    BFF-->>App: {authenticationToken: JWT}

    App->>BFF: POST /api/authenticate/auth<br/>Authorization: Bearer <JWT><br/>XA-App-Type: invoices<br/>XA-OsType: ios
    BFF->>Auth: GetAuthenticatedUserInfoAsync
    Auth->>FB: Validate JWT
    Auth-->>BFF: {userId, email}
    BFF->>BFF: Find/create MasterUser<br/>Link PlatformUser<br/>Resolve AccountId
    BFF-->>App: AuthResponse {masterUserId, isNewMaster}

    Note over App: App stores masterUserId + accountId

    App->>BFF: GET /api/v3/invoices<br/>Authorization: Bearer <JWT><br/>Account-Id: acc_123
    BFF->>Auth: Validate JWT (cached per request)
    Auth-->>BFF: {userId, email}
    BFF->>BFF: Middleware: resolve MasterUser + AccountId
    BFF-->>App: Invoice data
```
