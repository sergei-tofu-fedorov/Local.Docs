# Step 5: Worker Users — Overview

## Overview

Split users into distinct roles with different permissions and access patterns:

| Role | Description |
|------|-------------|
| **Admin** | Full access to account, manages workers, views all jobs |
| **Worker** | Field worker, views/updates assigned visits only |

> **Note**: Additional roles (e.g., Manager) may be added later. The claims system should be designed to be extensible for future role additions.

## Current State

- `OwnedAccount.TenantRole` stores role: `null` = Admin, `"Worker"` = Worker
- `RoleLevelDto` enum exists: `Unknown`, `Admin`, `Worker`
- `assignedWorkerId` on visits references workers but assignment is embedded in full job upsert
- `WorkerController` provides visit-centric view filtered by `assignedWorkerId`
- Auth API returns permissions (`GET /permissions` → `Ability[]`) but they are **not enforced** server-side
- Authorization middleware exists (`AuthorizationInstaller.cs`) but is **disabled** in DI
- Invitations system already prevents inviting Admin-role users

## Sub-documents

| Doc | Topic | Focus |
|-----|-------|-------|
| [5.0 Member Accounts](5.0_owned_accounts_fix.md) | Separate member collection | `MemberAccounts` collection for non-admin roles, fix MongoDB restrictions |
| [5.1 Worker Assignment](5.1_worker_assignment.md) | Assignment in upsert flow | Team validation, `visitWorkerChanged` events |
| [5.2 Worker Endpoints Update](5.2_worker_endpoints_update.md) | Fix existing worker API | Data isolation, missing fields, API reference alignment |
| [5.3 Worker Deletion](5.3_worker_deletion.md) | Visit cleanup on worker removal | Unassign visits (events may be added later) |
| [5.6a Deleted Worker — Forbidden](5.6a_deleted_worker_forbidden.md) | Auth fix: 403 flow | Replace `InvalidOperationException` with `AccountAccessDeniedException`, deferred fallback to signature auth |
| [5.6b Deleted Worker — Middleware](5.6b_deleted_worker_middleware.md) | ~~Exempt endpoint guard~~ | Superseded by 5.6a deferred fallback |
| [5.x Worker Permissions](5.x_worker_permissions.md) | Role-based access control | Enable RBAC, enforce policies, data isolation |

## Goals

### Admin Capabilities

1. **Team Management** - View and manage their team of workers
2. **Worker Assignment** - Assign workers to visits within jobs (see [5.1](5.1_worker_assignment.md))
3. **Full Access** - Continue having full access to all jobs and visits

### Worker Capabilities

1. **View Assigned Jobs** - See only jobs with visits assigned to them
2. **Update Visit Status** - Change status of their assigned visits
3. **Limited Access** - Cannot see or modify unrelated jobs/visits

### Claims/Permissions System

Implement role-based access control so different endpoints/actions are available only to specific roles (see [5.x](5.x_worker_permissions.md)):

| Action | Admin | Worker |
|--------|-------|--------|
| List all jobs | Yes | No |
| List assigned jobs | Yes | Yes |
| View job details | Yes | Yes (assigned only) |
| Create job | Yes | No |
| Edit job | Yes | No |
| Delete job | Yes | No |
| Assign worker to visit | Yes | No |
| Update visit status | Yes | Yes (assigned only) |
| Manage team | Yes | No |

## Open Questions

| # | Question | Status | Notes |
|---|----------|--------|-------|
| 1 | Where are roles stored? | **Answered** | Auth API (source of truth) → `OwnedAccounts` for admins, `WorkerAccountLinks` for workers (see [5.0](5.0_owned_accounts_fix.md)) |
| 2 | Can a user have multiple roles per account? | Open | Recommend: no, one role per account |
| 3 | What visit fields can workers update besides status? | Open | Recommend: status only initially |
| 4 | Should workers see job financial details? | Open | Recommend: no |
| 5 | How to design claims system for future roles? | **Answered** | Auth API already uses abilities pattern; server uses policy-based authorization |

## Implementation Order

Recommended sequence:

1. **5.0 Member Accounts** — `MemberAccounts` collection for non-admin roles (prerequisite for all worker features)
2. **5.2 Worker Endpoints Update** — fix data isolation and align with API reference
3. **5.1 Worker Assignment** — add team validation and assignment events to upsert flow
4. **5.3 Worker Deletion** — clean up visits when a worker is removed from the team
5. **5.x Worker Permissions** — enable RBAC last so the security boundary covers all endpoints
