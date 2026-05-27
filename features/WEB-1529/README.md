# WEB-1529 — Assign admin role on business account creation

**Status:** in-progress
**Started:** 2026-05-18
**ClickUp:** https://app.clickup.com/t/WEB-1529
**Affected repos:** `Tofu.Auth.Backend`, `Invoices.Backend`

## Branches

- `Tofu.Auth.Backend` → `feature/WEB-1529` (server + client package `Tofu.Auth.Api.Client 0.8.1-preview002`)
- `Invoices.Backend` → `feature/WEB-1529` (bumped to the same client package)

## Goal

After business-account creation the owner must appear with the admin role in `api/team/members` immediately. Today the admin row is only created lazily when `me/permissions` is called, so a `team/members` hit first returns nothing and breaks FS iOS.

Same change also closes a trust gap: today any authenticated user can self-elevate to admin in any tenant via that lazy provision. Tofu.Auth has no `Tenant` entity, so it cannot verify ownership on its own — `Invoices.Backend` (BFF) must assert it.

## The contract

One new header on every BFF → Tofu.Auth call, riding next to the existing `X-Platform` / `X-Product-Key` / `X-Device-Id` headers on the `AuthUserContext` carrier. No JWT, no signing.

| Header | Set when | Meaning |
|---|---|---|
| `X-Tenant-Owner: true` | BFF determines the caller owns the tenant — `MasterUser.OwnedAccounts` contains the request's account, or it's the legacy signature-auth path (synthesised Admin in `SubjectIdentityProvider`) | The authenticated subject owns the tenant named in the request's `tenantId` route/query parameter |

The tenant identifier is read from the request's existing route/query — no second header. Trust is grounded in the private cluster network; signing is the next step only if that boundary changes.

## How it flows

**Server side (`Tofu.Auth.Backend`).** No new middleware, no new attribute. The gate sits inside `TenantService.ProvisionDefaultRoleIfMissing` — auto-provision fires only when `PermissionsConfig.AutoProvisionDefaultRole` is on **and** the current request's `AuthUserContext.IsTenantOwner == true`. Callers (`PermissionService.GetEffectivePermissions`, `TenantService.GetTenantUsers`) are unchanged.

**BFF side (`Invoices.Backend`).** `AuthUserContextProvider` was extended (not rewritten) with `IHttpContextAccessor`. The existing AsyncLocal seed for Platform / ProductKey / DeviceId is untouched; `GetUserContext()` now also computes `IsTenantOwner` on each call via `ResolveIsTenantOwner()`, which mirrors `SubjectIdentityProvider.ResolveBearerRoles` so there is exactly one definition of "is this the tenant owner":

```csharp
var accountId = httpContext.Items[AccountAuthenticationMiddleware.AccountIdItemKey] as string;
if (string.IsNullOrWhiteSpace(accountId)) return false;

var authInfo = httpContext.Items[AccountAuthenticationMiddleware.AuthenticationInfoKey] as AuthenticationInfo;
if (authInfo?.MasterUser is { } masterUser)
    return masterUser.OwnedAccounts.Any(a => a.AccountId == accountId);

return httpContext.GetAuthenticationType() == AuthenticationType.AccountIdWithSignature;
```

This shape is on-demand because the ownership signal needs `MasterUser` state that's not set until after `AccountAuthenticationMiddleware` runs — a seed-style "set at middleware time" pattern would observe stale values.

## Behaviour by inbound auth shape

| Inbound to BFF | `X-Tenant-Owner` | Tofu.Auth outcome |
|---|---|---|
| Bearer + owner | `true` | Admin row provisioned on first touch |
| Bearer + worker | absent | No-op (worker row already exists from invitation accept) |
| Signature-auth (legacy) | `true` | Treated as owner-equivalent; Admin row provisioned |
| Anonymous | absent | No header attached; no provision |

## What shipped

**`Tofu.Auth.Backend`:**
- `AuthUserContext.IsTenantOwner` (optional ctor param).
- `TofuAuthHeaders.TenantOwner = "X-Tenant-Owner"`; `HttpRequestExtensions.GetIsTenantOwner()`.
- `UserContextProvider` populates the new field from the request.
- `TenantService` takes `IUserContextProvider`; gate inside `ProvisionDefaultRoleIfMissing`. Concurrent-race catch and the existing info-log on successful auto-provision are preserved.
- `TofuAuthApiClient.AddClientContextHeaders` attaches `X-Tenant-Owner: true` when set.

**`Invoices.Backend`:**
- `AuthUserContextProvider` gained `IHttpContextAccessor`; new `ResolveIsTenantOwner()` mirrors `SubjectIdentityProvider.ResolveBearerRoles`. Singleton registration kept (`IHttpContextAccessor` is safe to consume from singletons).

**Tests:**
- Unit: `TenantServiceTests.EnsureUserTenantRole_*` — provision when owner, existing-row pass-through, `[Theory]` covering all gate-closed combinations.
- Functional: `me/permissions` and `tenants/{id}/users` each have a positive test using a new `HttpClient.AsTenantOwner()` helper plus a counter-test asserting no provision when the header is absent.

## Breaking changes

None — additive. New ctor param is optional; missing header keeps the legacy lazy path working through rollout. Lockdown PR will later remove the unconditional `AutoProvisionDefaultRole` branch so the only path that creates an Admin row is header-driven; the DB read for non-asserted callers (workers) stays.

## Trust model

- **Ownership truth** lives in `MasterUser.OwnedAccounts` (BFF). Unchanged.
- **Role membership truth** lives in `Tofu.Auth.Backend.UserTenantRoles`. Unchanged in shape; rows now arrive via the header-gated path.
- **Spoofability:** a direct, non-BFF caller can forge `X-Tenant-Owner: true` against any `tenantId` they put in the route/query. Acceptable because Tofu.Auth is only reachable on the private cluster network — same threat surface as the sibling client-context headers it rides next to. JWT-signing is the upgrade path if that boundary changes.

## Future evolution — worker-membership migration

Worker provisioning and reads are deliberately untouched (invitation accept already writes `UserTenantRole`; `TenantInvitationService.ListUserTenantsAsync` reads them). A follow-up can move worker truth out of Mongo (`MasterUser.IsWorkerIn` / `AllAccountIds`) and into Tofu.Auth, with BFF caching `ListUserTenantsAsync` per session. The split this ticket sets up is symmetric:

- **Owner** truth: BFF → Tofu.Auth via `X-Tenant-Owner` (per-request).
- **Worker** truth: Tofu.Auth → BFF via `ListUserTenantsAsync` (per-session, cached).

Just don't add new `MasterUser.OwnedAccounts`-equivalent Mongo storage for workers in the meantime.
