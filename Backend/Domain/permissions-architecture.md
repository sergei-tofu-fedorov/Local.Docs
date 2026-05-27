# Permissions Architecture Options

Cross-platform role and permission system design options for the Tofu platform.

## Context

Role separation (Admin/Manager/Worker) is needed across multiple domains:

| Domain | Admin | Manager | Worker |
|--------|-------|---------|--------|
| **Jobs** | Full access, assign workers | View team jobs | View/update assigned visits |
| **Invoices** | Full access | View invoices, send? | No access / View only? |
| **Estimates** | Full access | Create/send? | No access? |
| **Expenses** | Full access | Approve team expenses? | Submit own expenses? |
| **Payments** | Full access | View? | No access |

The permission system must work **across all domains**, not just Jobs.

## Current State

See [Users Domain Model](users.md) for current implementation details.

**Key issue**: Dual role storage - roles exist in both MongoDB (simple string) and Tofu.Auth (proper model).

---

## Option A: Tofu.Auth as Platform Identity & Permissions Hub

**Approach**: Tofu.Auth becomes the single source of truth for identity, roles, and permissions across all domains.

```
┌──────────────────────────────────────────────────────────────────┐
│                          Tofu.Auth                               │
│                    (Platform Identity Hub)                       │
├──────────────────────────────────────────────────────────────────┤
│  User                        │  Roles                            │
│  ├── Id (Guid)               │  ├── Admin (full access)          │
│  ├── PlatformLinks[] ◄─MOVE  │  ├── Manager (team access)        │
│  └── Profile (name, email)   │  └── Worker (limited access)      │
│                              │                                   │
│  UserTenantRoles             │  Permissions (by domain)          │
│  ├── UserId                  │  ├── job.view, job.edit, ...      │
│  ├── TenantId (AccountId)    │  ├── invoice.view, invoice.send   │
│  └── RoleId                  │  ├── estimate.create, ...         │
│                              │  └── expense.approve, ...         │
│                              │                                   │
│  TeamMembers (NEW)           │  RolePermissions                  │
│  ├── UserId                  │  └── Maps role → permissions      │
│  ├── TenantId                │                                   │
│  ├── ManagerId (nullable)    │                                   │
│  └── Profile (name, phone)   │                                   │
└──────────────────────────────────────────────────────────────────┘
                    │
                    │ Claims/Permissions via API or Token
                    ▼
┌─────────────────────────┐  ┌─────────────────────────┐  ┌────────────────┐
│ Invoices.Backend        │  │ Jobs Domain             │  │ Other Domains  │
├─────────────────────────┤  ├─────────────────────────┤  ├────────────────┤
│ MasterUser (slim)       │  │ Job, Visit              │  │ Estimate       │
│ └── AuthUserId (ref)    │  │ Visit.AssignedTo        │  │ Expense        │
│                         │  │   └── UserId (from Auth)│  │ Payment        │
│ [RequirePermission]     │  │                         │  │                │
│ on all endpoints        │  │ [RequirePermission]     │  │ [Require...]   │
└─────────────────────────┘  └─────────────────────────┘  └────────────────┘
```

### Changes Required

1. Move `PlatformUserLinks` from Invoices.Backend → Tofu.Auth
2. Add domain-specific permissions to Tofu.Auth (`job.*`, `invoice.*`, `estimate.*`)
3. Add `TeamMembers` table for team structure (manager → worker hierarchy)
4. All backends validate permissions via shared middleware/claims
5. `MasterUser` becomes thin - just links to Tofu.Auth UserId

### Pros

- Single source of truth for all identity and permissions
- Any domain can check permissions consistently
- Team structure (manager hierarchy) centralized
- Future roles easy to add

### Cons

- Large migration (moving PlatformUserLinks)
- Tofu.Auth becomes critical path for everything
- Need robust caching strategy

---

## Option B: Tofu.Auth for Permissions, Invoices.Backend Keeps Identity

**Approach**: Keep identity in Invoices.Backend, but use Tofu.Auth for all permission checks.

```
┌─────────────────────────────────────────────────────────────────┐
│                     Invoices.Backend                            │
│                    (Identity + API Gateway)                     │
├─────────────────────────────────────────────────────────────────┤
│  MasterUser (existing)       │  TeamMembers (NEW)               │
│  ├── PlatformUserLinks       │  ├── MasterUserId                │
│  └── OwnedAccounts           │  ├── AccountId                   │
│      └── AccountId           │  ├── ManagerId (nullable)        │
│      └── TenantRole ◄─DEPREC │  ├── DisplayName                 │
│                              │  └── IsActive                    │
│                              │                                  │
│  PermissionsMiddleware       │                                  │
│  └── Fetches from Tofu.Auth  │                                  │
│      and attaches to request │                                  │
└─────────────────────────────────────────────────────────────────┘
          │                              │
          │ Identity                     │ Permissions
          ▼                              ▼
┌─────────────────────────┐     ┌─────────────────────────────────┐
│ Domain Services         │     │ Tofu.Auth                       │
├─────────────────────────┤     ├─────────────────────────────────┤
│ Jobs                    │     │ Roles + RolePermissions         │
│ └── Visit.AssignedTo    │     │ UserTenantRoles                 │
│     └── TeamMemberId    │     │                                 │
│                         │     │ Permissions:                    │
│ Invoices                │◄────│ job.*, invoice.*, estimate.*    │
│ Estimates               │     │                                 │
│ Expenses                │     │                                 │
└─────────────────────────┘     └─────────────────────────────────┘
```

### Changes Required

1. Add `TeamMembers` collection to Invoices.Backend (synced with Tofu.Auth)
2. Deprecate `OwnedAccount.TenantRole` (read from Tofu.Auth instead)
3. Add `PermissionsMiddleware` that enriches requests with claims
4. All domains use `[RequirePermission("domain.action")]` attributes
5. Worker assignment references `TeamMemberId`

### Pros

- Smaller migration (identity stays put)
- Clear separation: identity vs permissions
- TeamMembers gives local data for display/assignment

### Cons

- Some duplication (TeamMembers mirrors Tofu.Auth users)
- Need sync mechanism when users invited/removed

---

## Option C: Federated Permissions with Domain Ownership

**Approach**: Each domain defines its own permissions, Tofu.Auth aggregates them.

```
┌─────────────────────────────────────────────────────────────────┐
│                          Tofu.Auth                              │
│                    (Permission Aggregator)                      │
├─────────────────────────────────────────────────────────────────┤
│  Core:                       │  Aggregated from domains:        │
│  ├── Roles (Admin, Worker)   │  ├── Jobs.Permissions            │
│  ├── UserTenantRoles         │  ├── Invoices.Permissions        │
│  └── RolePermissions         │  └── Estimates.Permissions       │
└─────────────────────────────────────────────────────────────────┘
          ▲                              │
          │ Register permissions         │ Query permissions
          │                              ▼
┌─────────────────────────┐     ┌─────────────────────────────────┐
│ Jobs Domain             │     │ Invoices.Backend                │
├─────────────────────────┤     ├─────────────────────────────────┤
│ Defines:                │     │ MasterUser (unchanged)          │
│ - job.view              │     │                                 │
│ - job.edit              │     │ Defines:                        │
│ - visit.update          │     │ - invoice.view                  │
│ - worker.assign         │     │ - invoice.send                  │
│                         │     │ - estimate.create               │
│ TeamMember (local)      │     │                                 │
│ └── For assignment only │     │                                 │
└─────────────────────────┘     └─────────────────────────────────┘
```

### Changes Required

1. Each domain registers its permissions with Tofu.Auth on startup
2. Tofu.Auth stores role → permission mappings
3. Domains own their permission definitions
4. Each domain can have its own "team member" concept if needed

### Pros

- Domains are autonomous
- Permissions stay close to the code that uses them
- Easy to add new domains

### Cons

- Complex registration/sync mechanism
- Harder to see full permission picture
- Risk of permission naming conflicts

---

## Option D: Claims-Based with Shared Library

**Approach**: Minimal changes - shared library handles permission checks, Tofu.Auth is source of truth.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Tofu.Permissions.Shared                      │
│                       (NuGet Package)                           │
├─────────────────────────────────────────────────────────────────┤
│  PermissionConstants         │  Middleware                      │
│  ├── Jobs.View               │  └── FetchPermissionsMiddleware  │
│  ├── Jobs.Edit               │                                  │
│  ├── Invoice.View            │  Attributes                      │
│  ├── Invoice.Send            │  └── [RequirePermission(...)]    │
│  └── ...                     │                                  │
│                              │  Services                        │
│  TeamFilterService           │  └── IPermissionService          │
│  └── Filters queries by role │                                  │
└─────────────────────────────────────────────────────────────────┘
          │
          │ Referenced by all backends
          ▼
┌─────────────────────────┐  ┌─────────────────────────┐  ┌──────────────┐
│ Invoices.Backend        │  │ Jobs (in Invoices)      │  │ Tofu.Auth    │
├─────────────────────────┤  ├─────────────────────────┤  ├──────────────┤
│ Uses shared middleware  │  │ [RequirePermission]     │  │ Roles        │
│ MasterUser unchanged    │  │ TeamFilterService       │  │ Permissions  │
│                         │  │ Visit.AssignedUserId    │  │ UserTenant   │
└─────────────────────────┘  └─────────────────────────┘  └──────────────┘
```

### Changes Required

1. Create `Tofu.Permissions.Shared` NuGet package
2. Define all permission constants in one place
3. Shared middleware fetches permissions from Tofu.Auth
4. `TeamFilterService` handles role-based query filtering
5. No data model changes initially

### Pros

- Quickest to implement
- Consistent permission checks everywhere
- No migrations needed

### Cons

- Dual storage issue remains
- Need to add TeamMembers concept later
- Shared library versioning complexity

---

## Comparison Matrix

| Factor | Option A | Option B | Option C | Option D |
|--------|----------|----------|----------|----------|
| Migration effort | High | Medium | Medium | Low |
| Single source of truth | Yes | Partial | Partial | No |
| Domain autonomy | Low | Medium | High | Medium |
| Cross-domain consistency | Yes | Yes | Partial | Yes |
| Future extensibility | High | High | High | Medium |
| Quick implementation | No | Partial | No | Yes |
| Team hierarchy support | Yes | Yes | Partial | Needs work |

---

## Recommendation

### Phased Approach

1. **Phase 1**: Shared library + middleware (Option D) - Quick wins
2. **Phase 2**: Add TeamMembers to Invoices.Backend (Option B) - Team management
3. **Phase 3**: Consider moving identity to Tofu.Auth if needed (Option A) - Long-term

### Decision Factors

- **Timeline pressure** → Start with Option D
- **Clean architecture priority** → Go directly to Option A or B
- **Domain team autonomy** → Consider Option C

---

## Related Documentation

- [Users Domain Model](users.md) - Current user/role implementation
- [Tofu.Auth API](../Services/Tofu.Auth/API.md) - Auth service API
- [Worker Users Feature](../../features/jobs/implementation/worker_users/4_0.md) - Jobs-specific implementation
