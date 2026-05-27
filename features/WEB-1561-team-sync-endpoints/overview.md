# WEB-1561 — Team/Invitations Sync Endpoints — Implementation Plan

## Problem

- `GET /api/team/members` and `GET /api/invitations` carry `[AuthorizeAction(PermissionKeys.Worker.View)]`; `TeamController.GetTeamMembers` also calls `GetRequiredMasterUser()`.
- The signature-auth branch of `AccountAuthenticationMiddleware` (`Src/Invoices.Api/Middleware/AccountAuthenticationMiddleware.cs:148-160`) sets only `AccountIdItemKey`, not `AuthenticationInfoKey`.
- Any signature-only call to these endpoints → `MasterUserNotFoundException("Should call auth first")` → 403 `master_not_found`. Prod: ≥6 accounts in 24 h.
- The downstream `TofuAuthApiClient.GetTenantUsersAsync` / `ListTenantInvitationsAsync` (`Tofu.Auth.Backend/src/Tofu.Auth.Api.Client/TofuAuthApiClient.cs:163,225`) calls `AssureJwtExists()` and throws `AuthenticationInfoMissedException` without a Bearer JWT — so a signature-only request cannot fetch real data at all.

## Fix

Two new endpoints, additive, no breaking change:

| New endpoint | Same shape as | Signature-only call | JWT call |
|---|---|---|---|
| `GET /api/team/members/sync` | `GET /api/team/members` | 200 with empty `teamMembers` | 200 with real list; `IsCurrentUser=false` for every row |
| `GET /api/invitations/sync`  | `GET /api/invitations`   | 200 with empty `invitations`  | 200 with real list |

Precedent for sync endpoints without `[AuthorizeAction]`: `Src/Invoices.Api/Controllers/EstimatesController.cs#Sync`.

## Changes

### 1. `Src/Invoices.Api/Controllers/TeamController.cs`

```
[HttpGet("members/sync")]
public async Task<TeamMemberListResponseDto> SyncTeamMembers(CancellationToken ct)
    if (AuthenticationInfo == null)
        return new TeamMemberListResponseDto { TeamMembers = [] }

    members = await _teamService.GetTeamMembers(AccountId, ct)
    return new TeamMemberListResponseDto
        TeamMembers = members.Select(m => m.ToDto(Guid.Empty)).ToList()
```

- `AuthenticationInfo == null` ⇔ signature-only request → return empty list, skip the gRPC call that would throw `AssureJwtExists()`.
- With a Bearer JWT, `AuthenticationInfo` is populated by the middleware; the original code path runs.
- `Guid.Empty` is passed to the existing `TeamMember.ToDto(Guid currentUserId)` so `IsCurrentUser` is `false` for every row.

### 2. `Src/Invoices.Api/Controllers/InvitationsController.cs`

```
[HttpGet("sync")]
public async Task<InvitationListResponseDto> SyncInvitations(
    [FromQuery] Dto.Invitations.InvitationStatusDto? status, CancellationToken ct)
    if (AuthenticationInfo == null)
        return new InvitationListResponseDto { Invitations = [] }

    request = status.ToAuthListTenantInvitationsRequest()
    response = await _tofuAuthApiClient.ListTenantInvitationsAsync(AccountId, request, ct)
    return new InvitationListResponseDto
        Invitations = response.Invitations.ToInvitationResponseDtos()
```

### 3. Middleware

- No change. The signature-auth branch (`AccountAuthenticationMiddleware.cs:148-160`) already runs without setting `AuthenticationInfo`. The controllers handle the null case explicitly.

## Behaviour

| Request | Middleware path | Controller behaviour |
|---|---|---|
| No `Account-Id`, no JWT, no signature | rejected at middleware (`AuthenticationException`) | never reached |
| `Account-Id` + valid signature, no JWT | `AccountIdWithSignature`, `AuthenticationInfo = null` | early-return empty list (200) |
| Valid Bearer JWT | `AuthenticationApi`, `AuthenticationInfo` populated | calls `_authClient` / `_teamService`, returns the same shape as the non-sync endpoint |

Failure modes are identical to the non-sync endpoints, minus the signature-branch `master_not_found` 403.

## Backward Compatibility

- `GET /api/team/members`, `GET /api/team/members/{userId}`, `GET /api/invitations`, `POST /api/invitations/list`, `GET /api/invitations/{id}` — unchanged.
- No changes to DTOs, services, gRPC, or `Tofu.Auth`.

## Testing

`Src/Invoices.IntegrationTests/Tests/Controllers/TeamControllerTests`:

- `SyncTeamMembers_WithoutAuth_ShouldReturnForbidden` — no headers → 403 from middleware.
- `SyncTeamMembers_WithSignatureAuth_ShouldReturnEmptyAndSkipAuthApi` — signature-only → 200 with `[]`; `MockSetup.AuthApiClient.GetTenantUsersAsync` is verified to **never** be called.
- `SyncTeamMembers_WithApiAuthentication_ShouldReturnMembers` — JWT → 200 with seeded members.

`Src/Invoices.IntegrationTests/Tests/Controllers/InvitationsControllerTests`:

- `SyncInvitations_WithoutAuth_ShouldReturnForbidden` — no headers → 403.
- `SyncInvitations_WithSignatureAuth_ShouldReturnEmptyAndSkipAuthApi` — signature-only → 200 with `[]`; `ListTenantInvitationsAsync` is verified to never be called.
- `SyncInvitations_WithApiAuthentication_ShouldReturnInvitations` — JWT → 200 with seeded invitations.

## Acceptance

- New endpoints return 200 on signature-only auth (empty list) and on JWT auth (real data) on dev/staging/prod.
- After clients switch URLs: zero `MasterUserNotFoundException` events on `/api/team/members/sync` and `/api/invitations/sync`.
- No regression on existing UI endpoints.
