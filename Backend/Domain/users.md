# Users Domain Model

Cross-service view of user types and roles in the Tofu platform.

## User Identity

### Master User (Invoices.Backend)

Backend-level user aggregate stored in **MongoDB**. Source of truth for user identity.

```
MasterUser (MongoDB collection: masterUsers)
├── Id                  - MasterUserId (string)
├── PlatformUserLinks[] - Platform identities
│   ├── PlatformId      - Platform-specific user ID
│   ├── Platform        - iOS, Android, Web
│   ├── Product         - Product key
│   ├── IsFirstLink     - Primary identity for this product
│   └── OriginalEmail   - Email at signup (optional)
├── OwnedAccounts[]     - Accounts this user can access
│   ├── AccountId       - Reference to account
│   ├── TenantRole      - Role string (null = Owner/Admin)
│   └── OwnedAccountMeta
├── CreatedAt
├── UpdatedAt
└── DeletedAt
```

**Key insight**: Role is stored as a simple string on `OwnedAccount.TenantRole`:
- `null` → Account Owner/Admin (has full access)
- `"Worker"` → Invited team member with Worker role

→ Details: [Invoices.Backend Users](../Services/Invoices.Backend/Users.md)

### Platform User

External identity from iOS, Android, Web, or other platforms.

| Property | Description |
|----------|-------------|
| `platformUserId` | Platform-specific identifier |
| Platform | iOS, Android, Web |
| Product | Product key (e.g., invoice, estimate) |

## Roles in Invoices.Backend (Current State)

**Simple string-based role on OwnedAccount:**

| TenantRole Value | Meaning | Access Level |
|------------------|---------|--------------|
| `null` | Account Owner/Admin | Full access to all account resources |
| `"Worker"` | Invited team member | Access determined by Tofu.Auth |

**How roles are assigned:**
1. Account creator → `TenantRole = null` (via `MarkUserAsAccountOwner`)
2. Invited user accepts invitation → `TenantRole = "Worker"` (via `AddOrUpdateInvitedAccount`)

**Limitation**: Role is just a string label. Actual permission checks must query Tofu.Auth.

## Roles and Permissions (Tofu.Auth)

Full authorization system in **PostgreSQL** with proper role-permission model.

### Role Levels

```
RoleLevel enum:
├── Unknown (0)  - Default/unspecified
├── Admin (1)    - Full system access
└── Worker (2)   - Basic read-only access
```

### Default Roles

| Role | ID | Level | Description |
|------|----|-------|-------------|
| **Admin** | 1 | Admin (1) | Administrator with full system access |
| **Worker** | 2 | Worker (2) | Basic user with read-only access |

### Permissions

Naming convention: `{resource}.{action}[.{subaction}]`

| Permission | Description |
|------------|-------------|
| `invoice.view` | View invoice details |
| `invoice.list` | View list of invoices |
| `invoice.create` | Create new invoices |
| `invoice.edit` | Modify existing invoices |
| `invoice.delete` | Delete invoices |
| `invoice.email.send` | Send invoices via email |
| `user.roles.assign` | Assign roles to users |

### Role → Permission Mapping

| Role | Permissions |
|------|-------------|
| **Worker** | `invoice.view`, `invoice.list` |
| **Admin** | All 7 permissions |

### User-Tenant-Role Assignment (Tofu.Auth)

```
UserTenantRoles (PostgreSQL table):
├── UserId (Guid)     - Reference to User
├── TenantId (string) - External tenant ID (AccountId)
├── RoleId (int)      - Reference to Role
├── AssignedAt        - Timestamp
└── AdditionalInfo    - JSONB (name, phone for tenant context)
```

**Key constraint**: One role per user per tenant.

### Permission Check Flow

```
1. User authenticates → gets UserId
2. Request includes TenantId (AccountId)
3. Tofu.Auth looks up UserTenantRole for (UserId, TenantId)
4. If no role exists and auto-provisioning enabled → assigns default role
5. Returns permission keys for the user's role
```

**API**: `GET /v1/me/permissions?tenantId={tenantId}`

## Database Schema Comparison

### Invoices.Backend (MongoDB)

```
masterUsers collection:
{
  "_id": "master-user-id",
  "PlatformUserLinks": [...],
  "OwnedAccounts": [
    {
      "AccountId": "acc-123",
      "TenantRole": null,        // null = Admin
      "OwnedAccountMeta": {...}
    },
    {
      "AccountId": "acc-456",
      "TenantRole": "Worker",    // string = invited role
      "OwnedAccountMeta": {...}
    }
  ]
}
```

### Tofu.Auth (PostgreSQL)

```
┌─────────────────────┐      ┌─────────────────────┐
│ Roles               │──────│ RolePermissions     │
├─────────────────────┤      ├─────────────────────┤
│ Id, Name, Level     │      │ RoleId, PermissionKey│
└─────────────────────┘      └─────────────────────┘
         │
┌─────────────────────┐
│ UserTenantRoles     │
├─────────────────────┤
│ UserId, TenantId    │  (composite PK)
│ RoleId, AssignedAt  │
└─────────────────────┘
```

## Jobs Domain Usage

In the Jobs module, users appear as:

| Field | Location | Description |
|-------|----------|-------------|
| `MasterUserId` | Job events | Who triggered the action |
| `assignedWorkerId` | Visit | Worker assigned to a visit (string, not linked to User) |
| `ActorType` | Timeline events | `user`, `system`, `external` |

## Current Limitations

1. **Dual role storage** - Role stored in both MongoDB (string) and Tofu.Auth (proper model)
2. **No role-based filtering in Jobs** - All authenticated users see all jobs in their account
3. **Worker identity is just a string** - `assignedWorkerId` has no link to actual user/role records
4. **No manager role** - Only Admin and Worker exist; no intermediate Manager level
5. **No worker hierarchy** - No concept of which workers report to which managers
6. **Permissions not enforced in Jobs API** - Role checks not yet implemented

## Related Documentation

- [Invoices.Backend Users](../Services/Invoices.Backend/Users.md) - Master user model
- [Tofu.Auth API](../Services/Tofu.Auth/API.md) - Auth service API
- [Authorization HowTo](../HowTo/Authorization.md) - How to use permissions
