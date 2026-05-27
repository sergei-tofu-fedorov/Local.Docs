# Phase 2: Full RBAC + Identity Hub in Tofu.Auth

Phase 2 plan will be revisited after Phase 1 implementation — details may change.

## Summary

- Tofu.Auth becomes the single source of truth for identity, roles, and team membership
- `TeamMembers` table added in Tofu.Auth (PostgreSQL)
- `PlatformUserLinks` migrates from MongoDB to Tofu.Auth
- Deprecates `OwnedAccount.TenantRole` — roles resolved from Tofu.Auth only
- Role and permission data embedded in JWT claims

---

## 2.1 Adding New Roles

Phase 1 ships with Admin + Worker only. The system is designed so that adding a new role (e.g., Manager, Subcontractor) requires:

1. **Add role to Tofu.Auth** — new `Role` row in `Roles` table, new `RoleLevel` enum value
2. **Seed permissions** — add `RolePermission` rows mapping the new role to its permission keys (same keys from `PermissionRegistry`)
3. **Update Access Registry** — add the new role to the `roles[]` list of each relevant `AccessRule` in `Tofu.Permissions.Shared`
4. **Publish new NuGet version** — backends pick up the new role on next deploy
5. **No middleware changes needed** — the registry-based approach handles new roles automatically

Example: adding a Manager role that can create/edit jobs and assign workers but cannot manage billing:

```
// Tofu.Auth seed: Manager gets these permission keys
job.view, job.create, job.edit, visit.assign, visit.update,
worker.view, invoice.view, estimate.view, analytics.view, photo.upload

// Access Registry updates in Tofu.Permissions.Shared
AccessRule(key: "job.create", roles: [Admin, Manager], plans: [FsmSolo, FsmTeam, FsmBusiness])
AccessRule(key: "job.view",   roles: [Admin, Manager, Worker], plans: [Starter, FsmSolo, FsmTeam, FsmBusiness])
// billing.manage stays roles: [Admin] — Manager doesn't get it
```

Sources for future role definitions:
- Manager/Dispatcher, Subcontractor: Notion product specs (FSM roles & permissions page)
- [Tofu.Auth Roles & Tenants](../../Backend/Services/Tofu.Auth/Roles_and_Tenants.md), [Worker Roles](../../Backend/Services/Tofu.Auth/WorkerRoles.md)

## 2.2 TeamMembers in Tofu.Auth (PostgreSQL)

TeamMembers lives directly in Tofu.Auth alongside `UserTenantRoles` — single source of truth for identity and team membership. No sync mechanism needed.

```
TeamMember (PostgreSQL table in Tofu.Auth)
├── Id
├── AccountId (TenantId)
├── UserId (Tofu.Auth UserId)
├── DisplayName
├── Phone, Email
├── IsActive
├── CreatedAt
```

Role comes from `UserTenantRole` in the same database — joined by UserId + TenantId. Tofu.Auth exposes team management API:

- `GET /tenants/{tenantId}/members` — list team members with roles
- `POST /tenants/{tenantId}/members` — add team member (invitation acceptance)
- `PUT /tenants/{tenantId}/members/{id}/role` — change member role
- `DELETE /tenants/{tenantId}/members/{id}` — remove team member

## 2.3 Migrate PlatformUserLinks to Tofu.Auth

`PlatformUserLinks` currently lives in `MasterUser` (MongoDB, Invoices.Backend) and maps external identity providers (Firebase, Apple, Google) to internal user IDs. This migration moves it to Tofu.Auth (PostgreSQL) so that Tofu.Auth becomes the single resolver for "Firebase UID → UserId → TenantIds → Roles".

**Target schema** (Tofu.Auth PostgreSQL):

```
PlatformUserLink
├── Id
├── UserId (FK → Users)
├── Platform (Firebase, Apple, Google)
├── ExternalId (Firebase UID, Apple ID, etc.)
├── CreatedAt
└── UNIQUE(Platform, ExternalId)
```

**Migration steps**:

1. **Add new table** in Tofu.Auth via EF migration. Add new API endpoint `GET /users/by-external-id?platform={}&externalId={}` to Tofu.Auth
2. **Dual-write**: update Invoices.Backend to write PlatformUserLinks to both MongoDB and Tofu.Auth on any create/update operation. Tofu.Auth write is fire-and-forget with retry — MongoDB remains primary
3. **Backfill**: one-time batch job reads all `MasterUser.PlatformUserLinks` from MongoDB and inserts into Tofu.Auth PostgreSQL. Run with idempotent upsert to handle duplicates. Verify row counts match
4. **Dual-read**: switch Invoices.Backend to read from Tofu.Auth first, fallback to MongoDB on miss. Log any fallbacks — should drop to zero after backfill
5. **Cutover**: once fallback rate is zero for 1+ week, remove MongoDB reads. Tofu.Auth is now the primary source
6. **Cleanup**: remove `PlatformUserLinks` from `MasterUser` document, remove dual-write code. Slim down `MasterUser` to keep only business/invoice data

## 2.4 Remove OwnedAccount.TenantRole

`TenantRole` is not exposed to external clients — role data comes from `GET /me/permissions` (Tofu.Auth). All internal backend usages (e.g., `AccountAuthenticationMiddleware`) are replaced with Tofu.Auth role resolution in Phase 2.

- Replace all internal `TenantRole` reads with Tofu.Auth calls (via `AccessMiddleware`/`IAuthorizationContext`)
- Remove `TenantRole` field from `OwnedAccount` and `MemberAccount` documents
- Stop writing `TenantRole` on invitation acceptance (Tofu.Auth is the sole writer)
- Clean up any serialization/mapping code that references the field

## 2.5 JWT Claims Enhancement

Embed roles and permissions directly in JWT claims to reduce runtime calls to Tofu.Auth:

- `roles` claim: array of `{ tenantId, role }` objects
- `permissions` claim: flattened permission keys for the current tenant
- Middleware validates JWT claims locally instead of calling Tofu.Auth API
- Cache invalidation triggers token refresh (short-lived tokens or refresh-on-change)
- Once roles are in JWT, `GET /me/permissions` can be deprecated — clients read role from token directly. Currently the Web Frontend uses this endpoint to determine Admin/Worker role for UI routing; with JWT claims this is no longer needed.

> **Reference**: Earlier architectural analysis in `Backend/Domain/permissions-migration-plan.md`.
