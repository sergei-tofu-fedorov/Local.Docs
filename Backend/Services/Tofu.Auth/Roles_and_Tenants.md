User Roles and Tenants
======================

How user roles and tenant membership work in Tofu.Auth, and which
client methods are involved.

Tenant Model
------------

A **tenant** represents a business account. Tofu.Auth does not store
tenant details — it only tracks which users belong to which tenants
and with what role. The tenant ID is an external string (the `AccountId`
from the product service).

Each user can belong to multiple tenants. Each membership is a single
`UserTenantRole` record with a composite key of `(UserId, TenantId)`.

### Tenant-specific contact info

Users can have different display names and phone numbers per tenant,
stored as `UserTenantAdditionalInfo` on the membership record. This
allows the same person to appear with different contact details in
different businesses.

Role System
-----------

### Roles

Two roles exist, seeded in the database:

| Role | RoleLevel | ID | Description |
|------|-----------|-----|-------------|
| Admin | `Admin` (1) | 1 | Account owner / administrator — full access |
| Worker | `Worker` (2) | 2 | Team member — limited access |

A user has **one role per tenant**. The role is assigned when the user
joins the tenant (via invitation acceptance or direct assignment).

- **Admin**: `TenantRole = null` in `OwnedAccount` (legacy) or
  `RoleLevel.Admin` in the Auth API response
- **Worker**: `TenantRole = "Worker"` in `OwnedAccount` or
  `RoleLevel.Worker` in the Auth API response

### Permissions

Each role maps to a fixed set of permission keys:

| Permission Key | Admin | Worker |
|----------------|-------|--------|
| `invoice.view` | Yes | Yes |
| `invoice.list` | Yes | Yes |
| `invoice.create` | Yes | No |
| `invoice.edit` | Yes | No |
| `invoice.delete` | Yes | No |
| `invoice.email.send` | Yes | No |
| `user.roles.assign` | Yes | No |

Workers get read-only access. Admins get full access plus user management.

Permission resolution in Tofu.Auth (`PermissionService`):
1. Look up `UserTenantRole` for the user + tenant
2. If no role found and auto-provisioning is enabled, use the default
   role (currently Admin — for backward compatibility with legacy users)
3. Load all `RolePermission` entries for that role
4. Return as a `HashSet<string>` of permission keys

How Users Join Tenants
----------------------

### Account owner (Admin)

When a user creates a business account, they become the owner.
The product service calls Tofu.Auth to mark ownership, creating a
`UserTenantRole` with `RoleId = 1` (Admin).

### Invited user (Worker or Admin)

1. Admin creates an invitation via
   `CreateTenantInvitationAsync(tenantId, request)` with the target
   email and `RoleLevel`
2. Tofu.Auth creates an `InvitationToken` and sends an email
3. Recipient clicks the link and calls
   `AcceptInvitationAsync(token)` (single) or
   `AcceptInvitationsByBusinessesAsync(request)` (bulk)
4. Tofu.Auth creates a `UserTenantRole` record with the role from
   the invitation
5. Invitation status moves from `Pending` to `Accepted`

**Constraint**: Only one pending invitation per email + tenant pair.
Creating a new invitation for the same email revokes the previous one.

**Constraint**: Admin-role invitations are blocked at the product
service level (`InvitationsController` throws if `Role == Admin`).
Only Worker invitations are currently allowed through the UI flow.

Client Methods by Use Case
--------------------------

### Querying roles and permissions

| Use case | Client method | Returns |
|----------|---------------|---------|
| Get current user's permissions in a tenant | `GetMyPermissionsAsync(tenantId)` | `PermissionsResponse` with `List<Ability>` |
| List tenants the user belongs to (with roles) | `ListUserTenantsAsync()` | `UserTenantsResponse` with `List<UserTenantMembershipResponse>` — each entry has `TenantId` and `RoleLevel` |
| List all users in a tenant | `GetTenantUsersAsync(tenantId)` | `List<TenantUserResponseDto>` — includes `Role.Level` per user |
| Get a specific tenant user | `GetTenantUserAsync(tenantId, userId)` | `TenantUserResponseDto` |

### Managing team members

| Use case | Client method |
|----------|---------------|
| Invite user to tenant | `CreateTenantInvitationAsync(tenantId, request)` — request includes `RoleLevel` |
| List invitations for a tenant | `ListTenantInvitationsAsync(tenantId, request)` — filter by status |
| List invitations for current user | `ListUserInvitationsAsync()` |
| Accept invitation | `AcceptInvitationAsync(token)` |
| Accept all pending invitations | `AcceptInvitationsByBusinessesAsync(request)` |
| Revoke invitation | `RevokeTenantInvitationAsync(tenantId, invitationId)` |
| Remove user from tenant | `RemoveUserFromTenantAsync(tenantId, userId)` |

### Contact info

| Use case | Client method |
|----------|---------------|
| Get own contact info in tenant | `GetMyContactInfoAsync(tenantId)` |
| Update own contact info | `UpdateMyContactInfoAsync(tenantId, request)` |
| Update another user's contact | `UpdateTenantUserContactInfoAsync(tenantId, userId, request)` |

Current Enforcement Status
--------------------------

As of this writing, roles and permissions are **stored and queryable**
but **not enforced** at the API level in Invoices.Backend:

- Authorization middleware exists but is disabled in DI
- `GET /permissions` returns abilities for client-side UI hints
- No server-side checks block workers from calling admin endpoints

Server-side enforcement is planned in
[Stage 5.x — Worker Permissions](../../features/jobs/implementation/5_worker_users/5.x_worker_permissions.md).
