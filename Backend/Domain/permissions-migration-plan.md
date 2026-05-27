# Permissions Migration Plan

Phased migration from current state to unified permissions architecture.

## Overview

```
Current State ──► Phase 1 (Option B) ──► Phase 2 (Option A)
                  Permissions Hub        Full Identity Hub
```

**Timeline**: Phase 1 can be implemented independently. Phase 2 is optional future work.

---

## Phase 1: Migrate to Option B

**Goal**: Tofu.Auth handles all permissions, Invoices.Backend keeps identity.

### 1.1 Add Domain Permissions to Tofu.Auth

**Location**: Tofu.Auth.Backend

Add new permissions for all domains:

```
Jobs Permissions:
├── job.view          - View job details
├── job.list          - List jobs
├── job.create        - Create new jobs
├── job.edit          - Edit existing jobs
├── job.delete        - Delete jobs
├── visit.update      - Update visit status
└── worker.assign     - Assign workers to visits

Invoice Permissions:
├── invoice.view      - View invoice details
├── invoice.list      - List invoices
├── invoice.create    - Create invoices
├── invoice.edit      - Edit invoices
├── invoice.delete    - Delete invoices
└── invoice.send      - Send invoices via email

Estimate Permissions:
├── estimate.view
├── estimate.list
├── estimate.create
├── estimate.edit
├── estimate.delete
└── estimate.send

Expense Permissions:
├── expense.view
├── expense.list
├── expense.create
├── expense.approve
└── expense.delete

Team Permissions:
├── team.view         - View team members
├── team.manage       - Add/remove team members
└── team.roles        - Assign roles to members
```

**Tasks**:
- [ ] Add permissions to seed data
- [ ] Create migration for new permissions
- [ ] Map permissions to roles (Admin, Manager, Worker)

### 1.2 Create Shared Permissions Library

**Location**: New project `Tofu.Permissions.Shared`

```
Tofu.Permissions.Shared/
├── Constants/
│   ├── JobPermissions.cs
│   ├── InvoicePermissions.cs
│   ├── EstimatePermissions.cs
│   ├── ExpensePermissions.cs
│   └── TeamPermissions.cs
├── Middleware/
│   └── PermissionsMiddleware.cs
├── Attributes/
│   └── RequirePermissionAttribute.cs
├── Services/
│   ├── IPermissionService.cs
│   └── PermissionService.cs
└── Extensions/
    └── ServiceCollectionExtensions.cs
```

**Tasks**:
- [ ] Create NuGet package project
- [ ] Define permission constants
- [ ] Implement middleware to fetch permissions from Tofu.Auth
- [ ] Implement `[RequirePermission]` attribute
- [ ] Add caching for permissions (per request or short TTL)

### 1.3 Add TeamMembers to Invoices.Backend

**Location**: Invoices.Backend (MongoDB)

```csharp
public class TeamMember
{
    public string Id { get; set; }
    public string AccountId { get; set; }
    public string MasterUserId { get; set; }
    public string? ManagerId { get; set; }      // References another TeamMember
    public string DisplayName { get; set; }
    public string? Phone { get; set; }
    public string? Email { get; set; }
    public bool IsActive { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? DeactivatedAt { get; set; }
}
```

**Tasks**:
- [ ] Create TeamMember model
- [ ] Create TeamMember repository
- [ ] Create TeamMember service (CRUD operations)
- [ ] Sync TeamMember on user invite/accept
- [ ] API endpoints for team management

### 1.4 Deprecate OwnedAccount.TenantRole

**Location**: Invoices.Backend

**Tasks**:
- [ ] Mark `TenantRole` as `[Obsolete]`
- [ ] Update code to read role from Tofu.Auth instead
- [ ] Keep field for backwards compatibility (read-only)
- [ ] Migration to sync existing TenantRole values to Tofu.Auth

### 1.5 Integrate Permissions in Domains

**Jobs Domain**:
- [ ] Add `[RequirePermission]` to all endpoints
- [ ] Update `Visit.AssignedWorkerId` to reference `TeamMemberId`
- [ ] Add query filtering based on role (workers see only assigned)

**Invoices Domain**:
- [ ] Add `[RequirePermission]` to all endpoints
- [ ] Filter based on permissions

**Other Domains**:
- [ ] Estimates, Expenses, Payments - add permission checks

### 1.6 Testing

- [ ] Unit tests for permission middleware
- [ ] Integration tests for role-based access
- [ ] Test worker can only see assigned jobs
- [ ] Test admin can see all jobs
- [ ] Test permission caching

---

## Phase 2: Migrate to Option A

**Goal**: Tofu.Auth becomes single source of truth for identity and permissions.

**Prerequisite**: Phase 1 complete and stable.

### 2.1 Extend Tofu.Auth User Model

**Location**: Tofu.Auth.Backend

Add PlatformLinks to User:

```csharp
public class UserPlatformLink
{
    public Guid UserId { get; set; }
    public string PlatformId { get; set; }
    public Platform Platform { get; set; }      // iOS, Android, Web
    public string Product { get; set; }
    public bool IsFirstLink { get; set; }
    public string? OriginalEmail { get; set; }
    public DateTimeOffset LinkedAt { get; set; }
}
```

**Tasks**:
- [ ] Add UserPlatformLink entity
- [ ] Add migration
- [ ] Create API endpoints for platform linking
- [ ] Update authentication flow to use Tofu.Auth for platform resolution

### 2.2 Move TeamMembers to Tofu.Auth

**Location**: Tofu.Auth.Backend

```csharp
public class TeamMember
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public string TenantId { get; set; }        // AccountId
    public Guid? ManagerId { get; set; }
    public string DisplayName { get; set; }
    public string? Phone { get; set; }
    public bool IsActive { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
}
```

**Tasks**:
- [ ] Create TeamMember entity in Tofu.Auth
- [ ] Add migration
- [ ] Create API endpoints
- [ ] Migrate data from Invoices.Backend TeamMembers

### 2.3 Data Migration: PlatformUserLinks

**Tasks**:
- [ ] Create migration script to copy PlatformUserLinks from MongoDB to PostgreSQL
- [ ] Verify data integrity
- [ ] Update Invoices.Backend to read from Tofu.Auth
- [ ] Remove PlatformUserLinks from MasterUser (after transition period)

### 2.4 Slim Down MasterUser

**Before** (Current):
```csharp
public class MasterUser
{
    public string Id { get; set; }
    public List<PlatformUserLink> PlatformUserLinks { get; set; }
    public List<OwnedAccount> OwnedAccounts { get; set; }
    // ...
}
```

**After** (Option A):
```csharp
public class MasterUser
{
    public string Id { get; set; }
    public Guid AuthUserId { get; set; }        // Reference to Tofu.Auth
    // PlatformUserLinks - REMOVED (in Tofu.Auth)
    // OwnedAccounts - REMOVED (in Tofu.Auth UserTenantRoles)
}
```

**Tasks**:
- [ ] Add `AuthUserId` to MasterUser
- [ ] Update all code to fetch identity from Tofu.Auth
- [ ] Deprecate and remove PlatformUserLinks
- [ ] Deprecate and remove OwnedAccounts

### 2.5 Update Authentication Flow

**Tasks**:
- [ ] Platform login resolves user via Tofu.Auth (not Invoices.Backend)
- [ ] Tofu.Auth returns unified identity + permissions
- [ ] Invoices.Backend receives AuthUserId in token/header
- [ ] Update middleware to use new flow

### 2.6 Remove Deprecated Code

**Tasks**:
- [ ] Remove TeamMembers from Invoices.Backend
- [ ] Remove PlatformUserLinks from MasterUser
- [ ] Remove OwnedAccounts from MasterUser
- [ ] Remove TenantRole handling code
- [ ] Clean up unused repositories/services

---

## Migration Checklist

### Phase 1 Readiness

- [ ] All permissions defined in Tofu.Auth
- [ ] Shared library created and tested
- [ ] TeamMembers collection working
- [ ] All endpoints have permission checks
- [ ] Workers can only access assigned resources
- [ ] No breaking changes to existing APIs

### Phase 2 Readiness

- [ ] Phase 1 stable in production
- [ ] Tofu.Auth can handle increased load (identity queries)
- [ ] Migration scripts tested
- [ ] Rollback plan documented
- [ ] Client apps updated if needed

---

## Rollback Strategy

### Phase 1 Rollback

If issues occur:
1. Disable permission middleware (fall back to no checks)
2. TenantRole still exists as backup
3. No data loss - additive changes only

### Phase 2 Rollback

If issues occur:
1. Re-enable PlatformUserLinks reads from MongoDB
2. Tofu.Auth data remains (no deletion during transition)
3. Dual-read period allows safe rollback

---

## Related Documentation

- [Permissions Architecture Options](permissions-architecture.md) - Architecture comparison
- [Users Domain Model](users.md) - Current implementation
- [Worker Users Feature](../../features/jobs/implementation/worker_users/4_0.md) - Jobs-specific goals
