Worker Roles and Invitations
============================

This document describes the worker roles system and invitation flow implemented
in Tofu.Auth. It is intended as a reference for other services (Jobs, Invoices,
etc.) that need to integrate with role-based access control.

For DTO field-level details see [API.md](API.md).

Concepts
--------

### Tenant

A tenant maps to an account (business). Users belong to one or more tenants,
each with a separate role. The `tenantId` in Auth corresponds to `accountId`
in Invoices.Backend.

### Roles

| Level | Name | Description |
|-------|------|-------------|
| 1 | **Admin** | Full access. Manages team, creates/edits resources. |
| 2 | **Worker** | Limited access. Sees only assigned work, updates status. |

Roles are stored in the Auth database. Each role has a set of **permissions**
(string keys like `invoice.view`, `invoice.create`). The `RoleLevel` enum
(`Unknown = 0`, `Admin = 1`, `Worker = 2`) is used across the system.

> The design is extensible — new roles (e.g., Manager) can be added by
> inserting a row with a new `RoleLevel` and assigning permissions to it.

### Permissions

Permissions are stored as `RolePermission` records linked to a role.
Each permission is a dot-separated key: `{object}.{action}`.

Current permission keys:

| Key | Description |
|-----|-------------|
| `invoice.view` | View invoices |
| `invoice.create` | Create invoices |
| `invoice.edit` | Edit invoices |
| `invoice.delete` | Delete invoices |
| `invoice.email.send` | Send invoice emails |
| `invoice.list` | List invoices |
| `user.roles.assign` | Assign roles to users |

Other services can define additional permission keys as needed.
The Auth service stores and returns them; it does not interpret them.

### User-Tenant-Role

`UserTenantRole` links a user to a tenant with a specific role.
Each record also carries optional **tenant-specific contact info**
(`ContactName`, `ContactPhoneNumber`) that can differ from the user's
global profile.

Invitation Flow
---------------

Invitations are the mechanism for adding workers (or admins) to a tenant.

```
Admin creates invitation
    │
    ▼
InvitationToken created (Pending)
    │  ── email sent via SendGrid with invitation link
    ▼
Worker opens link
    │
    ├─ Has account → POST /v1/invitations/{token}/accept
    │                 ── UserTenantRole created, status → Accepted
    │
    └─ No account  → POST /v1/invitations/{token}/magic-login
                      ── Firebase custom token returned
                      ── Worker signs in, invitation auto-accepted
```

### Invitation Lifecycle

| Status | Meaning |
|--------|---------|
| `Pending` | Created, waiting for worker to accept |
| `Accepted` | Worker accepted, `UserTenantRole` created |
| `Revoked` | Admin cancelled the invitation |
| `Expired` | TTL elapsed without acceptance |

### Resend Semantics

Creating a new invitation for the same email **revokes** any existing
pending invitation for that email+tenant, then creates a fresh one.

### Magic Login

For workers who do not yet have an account:
1. Worker opens the invitation link
2. Client calls `POST /v1/invitations/{token}/magic-login` with a `MagicToken`
3. Auth returns a Firebase `CustomToken` for sign-in
4. After sign-in the invitation is automatically accepted

Client Methods for Other Services
----------------------------------

Other services consume `ITofuAuthApiClient` (NuGet package).
Below are the methods relevant to worker roles and team management.

### Permissions

```
GetMyPermissionsAsync(tenantId) → PermissionsResponse
```
Returns the current user's effective permissions for a tenant as a list
of `Ability { Object, Action }` pairs. Use this to check whether the
caller is allowed to perform an action.

### Tenant Users (Team)

```
GetTenantUsersAsync(tenantId) → List<TenantUserResponseDto>
```
Returns all users in a tenant with their roles and contact info.
Use this to list team members for worker assignment.

```
GetTenantUserAsync(tenantId, userId) → TenantUserResponseDto
```
Returns a single tenant user. Use to fetch worker details (name, role)
when enriching job/visit data.

```
RemoveUserFromTenantAsync(tenantId, userId) → void
```
Removes a user from the tenant (revokes their role).

### Contact Info

```
GetMyContactInfoAsync(tenantId) → UserContactInfo { Name, PhoneNumber }
UpdateMyContactInfoAsync(tenantId, request) → void
UpdateTenantUserContactInfoAsync(tenantId, userId, request) → void
```
Workers have tenant-specific contact info separate from their global profile.

### Invitations

```
CreateTenantInvitationAsync(tenantId, request) → CreateTenantInvitationResponse
```
Creates an invitation. `request.RoleLevel` determines the role assigned on accept.

```
ListTenantInvitationsAsync(tenantId, request) → TenantInvitationsResponse
```
Lists invitations for a tenant. Can filter by status.

```
RevokeTenantInvitationAsync(tenantId, invitationId) → void
```
Revokes a pending invitation.

```
GetWorkerSummaryByEmailAsync(email) → WorkerSummaryResponse
```
Anonymous endpoint. Returns pending invitations and existing tenant
memberships for an email. Used during onboarding to check if a worker
has pending invites before they create an account.

### User Tenants

```
ListUserTenantsAsync() → UserTenantsResponse
```
Returns all tenants the current user belongs to, with their role level
in each. Used by the worker app to show the tenant switcher.

Integration Guide for Other Services
-------------------------------------

### Checking Permissions

Call `GetMyPermissionsAsync(tenantId)` and check that the required
`Ability` is present. The Auth client is typically called from middleware
or a service layer — not directly in controllers.

### Listing Workers for Assignment

Call `GetTenantUsersAsync(tenantId)` and filter by `Role.Level == Worker`
to get assignable workers. The response includes `UserId`, `ContactName`,
and `Email` — enough to populate an assignment picker.

### Identifying the Current User's Role

Call `GetMyPermissionsAsync(tenantId)`. The returned abilities implicitly
define what the user can do. Alternatively, call `ListUserTenantsAsync()`
which returns `RoleLevel` directly for each tenant.

### Worker-Specific Data Filtering

Workers should only see resources assigned to them (e.g., visits with
`assignedWorkerId == currentUserId`). This filtering is the responsibility
of each service, not Auth. Auth only provides role/permission data.
