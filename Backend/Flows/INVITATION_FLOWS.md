# Invitation System — Workflow Diagrams

> Complete reference for invitation operations: creation, magic login,
> acceptance, revocation, and listing. Shows the BFF layer
> (Invoices.Backend) proxying to Tofu.Auth.Backend.

## Architecture Overview

```mermaid
flowchart LR
    Client[Mobile / Web Client] --> BFF[Invoices.Backend<br/>BFF Layer]
    BFF --> Auth[Tofu.Auth.Backend<br/>Auth Service]
    Auth --> DB[(PostgreSQL<br/>tofu_auth)]
    Auth --> SG[SendGrid<br/>Email]
    Auth --> FB[Firebase<br/>Auth]

    BFF -. ITofuAuthApiClient .-> Auth
```

Invoices.Backend exposes simplified endpoints under `/api/invitations`,
`/api/team`, and `/api/worker`. These proxy to Tofu.Auth.Backend's
`/v1/` endpoints via `ITofuAuthApiClient` (NuGet package).

---

## 1. Create Invitation

**BFF:** `POST /api/invitations`
**Auth:** `POST /v1/tenants/{tenantId}/invitations`

```mermaid
sequenceDiagram
    participant C as Client
    participant BFF as Invoices.Backend
    participant Auth as Tofu.Auth
    participant DB as PostgreSQL
    participant Email as SendGrid

    C->>BFF: POST /api/invitations<br/>{email, role, baseUrl?}
    BFF->>BFF: Validate role != Admin/Unknown
    BFF->>BFF: Fetch BusinessName from local DB

    BFF->>Auth: POST /v1/tenants/{tenantId}/invitations<br/>{email, roleLevel, businessName, baseUrl}

    Auth->>DB: Count invitations last hour for tenant
    alt Rate limit exceeded (>= 20/hour)
        Auth-->>BFF: 429 Rate Limit Exceeded
        BFF-->>C: 429
    end

    Auth->>DB: Validate Role exists
    Auth->>DB: Check user doesn't already have role in tenant
    alt User already has role
        Auth-->>BFF: 409 Already Accepted
        BFF-->>C: 409
    end

    Auth->>Auth: Generate token (32 bytes, Base64Url)
    Auth->>Auth: SHA256 hash token

    Auth->>DB: BEGIN TRANSACTION
    Auth->>DB: Revoke existing pending invitation<br/>for same email + tenant (resend)
    Auth->>DB: INSERT InvitationToken<br/>(hash, email, tenantId, roleId, 7d TTL)
    Auth->>DB: INSERT InvitationMagicToken<br/>(hash, invitationId, 12h TTL)
    Auth->>DB: COMMIT

    Auth->>Email: Send invitation email<br/>(SendGrid template)

    Auth-->>BFF: 201 {invitation, link}
    BFF-->>C: 201 {invitation, link}
```

### Invitation Link Format

```
{baseUrl}?token={invitationToken}&ml={magicToken}
```

- `token` — invitation token (Base64Url, 32 bytes)
- `ml` — magic login token (Base64Url, 32 bytes, 12h TTL)

### Resend Semantics

Creating an invitation for the same email + tenant revokes the
previous pending invitation and issues a new one with fresh tokens.

---

## 2. Magic Login (Anonymous)

**BFF:** `POST /api/invitations/{token}/magic-login`
**Auth:** `POST /v1/invitations/{token}/magic-login`

Allows unauthenticated users to sign in directly from the invitation
email link.

```mermaid
sequenceDiagram
    participant C as Client
    participant BFF as Invoices.Backend
    participant Auth as Tofu.Auth
    participant DB as PostgreSQL
    participant FB as Firebase

    C->>BFF: POST /api/invitations/{token}/magic-login<br/>{magicToken}
    BFF->>Auth: POST /v1/invitations/{token}/magic-login<br/>{magicToken}

    Auth->>Auth: SHA256 hash invitation token
    Auth->>DB: Find InvitationToken by hash
    alt Not found or revoked or expired
        Auth-->>BFF: 400 Invalid Token
        BFF-->>C: 400
    end

    Auth->>Auth: SHA256 hash magic token
    Auth->>DB: Find InvitationMagicToken by hash
    alt Not found / expired / used / wrong invitation
        Auth-->>BFF: 400 MagicLoginException<br/>(reason code)
        BFF-->>C: 400
    end

    Auth->>FB: Find or create ExternalUserLogin<br/>for invitation email
    Auth->>FB: Generate custom auth token

    Auth->>DB: Mark magic token as used<br/>(UsedAt = now)

    Auth-->>BFF: 200 {customToken}
    BFF-->>C: 200 {customToken}

    Note over C: Client uses customToken<br/>to sign in via Firebase
```

### Magic Login Error Reasons

| Reason | Description |
|--------|-------------|
| `TokenNotFound` | Magic token hash not in DB |
| `TokenExpired` | Magic token past 12h TTL |
| `TokenAlreadyUsed` | Magic token already exchanged |
| `TokenMismatch` | Magic token doesn't match invitation |

---

## 3. Accept Invitation (Single)

**BFF:** `POST /api/invitations/{token}/accept`
**Auth:** `POST /v1/invitations/{token}/accept`

Requires authentication. User must be signed in with the same email
as the invitation.

```mermaid
sequenceDiagram
    participant C as Client
    participant BFF as Invoices.Backend
    participant Auth as Tofu.Auth
    participant DB as PostgreSQL

    C->>BFF: POST /api/invitations/{token}/accept<br/>(authenticated)
    BFF->>Auth: POST /v1/invitations/{token}/accept

    Auth->>Auth: SHA256 hash token
    Auth->>DB: Find InvitationToken by hash

    alt Revoked
        Auth-->>BFF: 400 Invalid Token
    end
    alt Already accepted
        Auth-->>BFF: 409 Already Accepted
    end
    alt Expired
        Auth-->>BFF: 400 Invalid Token
    end

    Auth->>Auth: Get current user from JWT
    alt User email != invitation email
        Auth-->>BFF: 403 Email Mismatch
        BFF-->>C: 403
    end

    Auth->>DB: BEGIN TRANSACTION
    Auth->>DB: Check user not already in tenant with role
    Auth->>DB: INSERT UserTenantRole<br/>(userId, tenantId, roleId)
    Auth->>DB: UPDATE InvitationToken<br/>AcceptedAt=now, AcceptedBy=userId
    Auth->>DB: COMMIT

    Auth-->>BFF: 200 {invitation}

    BFF->>BFF: AddOrUpdateInvitedAccount<br/>(link user to tenant in local DB)
    BFF-->>C: 200 {invitation}
```

---

## 4. Accept All Invitations

**BFF:** `POST /api/invitations/accept-all`
**Auth:** `POST /v1/tenants/invitations/accept`

Accepts all pending invitations for the authenticated user's email.

```mermaid
flowchart TD
    A[POST /api/invitations/accept-all] --> B[Get current user email]
    B --> C[Query all InvitationTokens<br/>where Email = user email]
    C --> D[Filter to Pending only]
    D --> E{Any pending?}
    E -->|No| F[Return empty list]
    E -->|Yes| G[For each invitation]
    G --> H[InternalAcceptInvitationAsync]
    H --> I[Assign UserTenantRole]
    I --> J[Mark invitation accepted]
    J --> G
    G -->|done| K[Return accepted list]
```

---

## 5. Revoke Invitation

**BFF:** `POST /api/invitations/{invitationId}/revoke`
**Auth:** `POST /v1/tenants/{tenantId}/invitations/{invitationId}/revoke`

```mermaid
sequenceDiagram
    participant C as Client
    participant BFF as Invoices.Backend
    participant Auth as Tofu.Auth
    participant DB as PostgreSQL

    C->>BFF: POST /api/invitations/{invitationId}/revoke
    BFF->>Auth: POST /v1/tenants/{tenantId}/invitations/{invitationId}/revoke

    Auth->>DB: Find InvitationToken by ID
    alt Not found
        Auth-->>BFF: 404 Not Found
        BFF-->>C: 404
    end

    Auth->>Auth: Validate invitation.TenantId == tenantId
    alt Wrong tenant
        Auth-->>BFF: 404 Not Found
        BFF-->>C: 404
    end

    Auth->>Auth: Check status == Pending
    alt Not pending
        Auth-->>BFF: 409 Not Pending
        BFF-->>C: 409
    end

    Auth->>DB: UPDATE InvitationToken<br/>RevokedAt = now
    Auth-->>BFF: 204 No Content
    BFF-->>C: 204
```

---

## 6. List Invitations (Tenant View)

**BFF:** `GET /api/invitations` or `POST /api/invitations/list`
**Auth:** `POST /v1/tenants/{tenantId}/invitations/list`

```mermaid
flowchart TD
    A["GET /api/invitations<br/>or POST /api/invitations/list<br/>{statuses?: [Pending, Accepted, ...]}"] --> B[BFF forwards to Auth]
    B --> C["POST /v1/tenants/{tenantId}/invitations/list"]
    C --> D[Query InvitationTokens<br/>WHERE TenantId = tenantId]
    D --> E{Status filter<br/>provided?}
    E -->|Yes| F[Filter by computed status:<br/>Pending/Accepted/Revoked/Expired]
    E -->|No| G[Return all]
    F --> H[Return invitation list<br/>with Role info]
    G --> H
```

---

## 7. Worker Summary (Anonymous)

**BFF:** `GET /api/worker/summary?email={email}`
**Auth:** `GET /v1/workers/summary?email={email}`

Used by the mobile app to check if a worker has pending invitations
or existing tenant memberships before sign-in.

```mermaid
flowchart TD
    A["GET /api/worker/summary<br/>?email=worker@example.com"] --> B[BFF forwards to Auth]
    B --> C[Query pending invitations<br/>for email]
    C --> D{User exists<br/>in DB?}
    D -->|No| E[Return invitations only]
    D -->|Yes| F[Query UserTenantRoles<br/>filter to Worker level]
    F --> G[Return invitations + tenants]
```

---

## 8. Remove Team Member

**BFF:** `DELETE /api/team/members/{userId}`
**Auth:** Calls `RemoveUserFromTenantAsync(tenantId, userId)`

```mermaid
sequenceDiagram
    participant C as Client
    participant BFF as Invoices.Backend
    participant Auth as Tofu.Auth
    participant Jobs as Jobs Module

    C->>BFF: DELETE /api/team/members/{userId}
    BFF->>Jobs: Unassign worker from all visits<br/>(set AssignedWorkerId = null)
    BFF->>Auth: Remove user from tenant<br/>(delete UserTenantRole)
    BFF->>BFF: Remove local member record
    BFF-->>C: 204 No Content
```

---

## Invitation Status State Machine

```mermaid
stateDiagram-v2
    [*] --> Pending: Create invitation

    Pending --> Accepted: User accepts<br/>(email match required)
    Pending --> Revoked: Admin revokes
    Pending --> Expired: TTL exceeded (7 days)
    Pending --> Revoked: Resend (new invitation<br/>revokes previous)

    Accepted --> [*]
    Revoked --> [*]
    Expired --> [*]
```

Status is computed at query time from `AcceptedAt`, `RevokedAt`, and
`ExpiresAt` fields — not stored as a column.

---

## Database Schema (ER Diagram)

```mermaid
erDiagram
    Users {
        uuid Id PK
        varchar_320 Email UK "nullable, unique when not null"
        varchar_300 ExternalUserId UK
        text Name "nullable"
        text PictureUrl "nullable"
        boolean IsAnonymous
        int AuthMethod "0=None, 1=Admin, 2=Worker"
        timestamptz CreatedAt
        timestamptz UpdatedAt "nullable"
    }

    Roles {
        int Id PK "identity"
        varchar_100 Name UK
        int Level "0=Unknown, 1=Admin, 2=Worker"
        varchar_500 Description "nullable"
        timestamptz CreatedAt
        timestamptz UpdatedAt "nullable"
    }

    RolePermissions {
        int Id PK "identity"
        int RoleId FK
        varchar_100 PermissionKey
        timestamptz CreatedAt
        timestamptz UpdatedAt "nullable"
    }

    UserTenantRoles {
        uuid UserId PK "composite PK, FK -> Users"
        varchar_150 TenantId PK "composite PK"
        int RoleId FK
        timestamptz AssignedAt
        jsonb AdditionalInfo "nullable, Name and PhoneNumber"
        timestamptz UpdatedAt "nullable"
    }

    InvitationTokens {
        uuid Id PK
        varchar_64 TokenHash UK "SHA256 hex"
        varchar_320 Email
        varchar_150 TenantId "IX"
        int RoleId FK
        timestamptz ExpiresAt "default 7 days"
        uuid InvitedBy FK "-> Users"
        varchar_512 BaseUrl
        timestamptz AcceptedAt "nullable"
        uuid AcceptedBy FK "nullable -> Users"
        timestamptz RevokedAt "nullable"
        timestamptz CreatedAt
        timestamptz UpdatedAt "nullable"
    }

    InvitationMagicTokens {
        uuid Id PK
        varchar_64 TokenHash UK "SHA256 hex"
        uuid InvitationId FK
        timestamptz ExpiresAt "default 12 hours"
        timestamptz CreatedAt
        timestamptz UsedAt "nullable"
        timestamptz UpdatedAt "nullable"
    }

    Users ||--o{ UserTenantRoles : "belongs to tenants"
    Roles ||--o{ UserTenantRoles : "assigned via"
    Roles ||--o{ RolePermissions : "has permissions"
    Roles ||--o{ InvitationTokens : "grants role"
    Users ||--o{ InvitationTokens : "InvitedBy"
    Users ||--o{ InvitationTokens : "AcceptedBy"
    InvitationTokens ||--o{ InvitationMagicTokens : "has magic tokens"
```

### Key Constraints

| Table | Constraint | Details |
|-------|-----------|---------|
| InvitationTokens | Unique filtered index | `(TenantId, Email)` WHERE `AcceptedAt IS NULL AND RevokedAt IS NULL` — one pending invitation per email per tenant |
| UserTenantRoles | Composite PK | `(UserId, TenantId)` — one role per user per tenant |
| InvitationTokens | FK delete behavior | `RoleId` RESTRICT, `InvitedBy` RESTRICT, `AcceptedBy` SET NULL |
| InvitationMagicTokens | FK delete behavior | `InvitationId` CASCADE — deleted with invitation |

### TenantId Note

`TenantId` is a string reference (varchar 150) with **no foreign key**
to a Tenants table. Tenants are managed externally; the auth service
only tracks role assignments and invitations per tenant ID.

---

## Endpoint Summary

### BFF (Invoices.Backend) → Client-Facing

| Method | Route | Auth | Description |
|--------|-------|------|-------------|
| POST | `/api/invitations` | Yes | Create invitation |
| GET | `/api/invitations` | Yes | List tenant invitations |
| POST | `/api/invitations/list` | Yes | List with status filter |
| POST | `/api/invitations/{token}/accept` | Yes | Accept single invitation |
| POST | `/api/invitations/accept-all` | Yes | Accept all pending |
| POST | `/api/invitations/{token}/magic-login` | No | Magic login exchange |
| POST | `/api/invitations/{id}/revoke` | Yes | Revoke invitation |
| GET | `/api/worker/summary` | No | Worker summary by email |
| GET | `/api/worker/invitations` | Yes | Worker's pending invitations |
| GET | `/api/worker/businesses` | Yes | Worker's tenant list |
| GET | `/api/team/members` | Yes | List team members |
| DELETE | `/api/team/members/{userId}` | Yes | Remove from team |

### Auth Service (Tofu.Auth.Backend) → Internal

| Method | Route | Auth | Description |
|--------|-------|------|-------------|
| POST | `/v1/tenants/{tenantId}/invitations` | Yes | Create invitation |
| POST | `/v1/tenants/{tenantId}/invitations/list` | Yes | List tenant invitations |
| GET | `/v1/users/invitations` | Yes | User's pending invitations |
| GET | `/v1/workers/summary` | No | Worker summary by email |
| GET | `/v1/users/tenants` | Yes | User's tenant list |
| POST | `/v1/invitations/{token}/magic-login` | No | Magic login exchange |
| POST | `/v1/invitations/{token}/accept` | Yes | Accept single |
| POST | `/v1/tenants/invitations/accept` | Yes | Accept all |
| POST | `/v1/tenants/{tenantId}/invitations/{id}/revoke` | Yes | Revoke invitation |

---

## Error Responses

| Error | HTTP | When |
|-------|------|------|
| Rate limit exceeded | 429 | > 20 invitations/hour per tenant |
| Invalid token | 400 | Token not found, expired, or revoked |
| Already accepted | 409 | Invitation already used |
| Email mismatch | 403 | Signed-in user email != invitation email |
| Not pending | 409 | Revoke attempted on non-pending invitation |
| User already in tenant | 409 | User already has this role in tenant |
| Magic token expired | 400 | Magic token past 12h TTL |
| Magic token used | 400 | Magic token already exchanged |
