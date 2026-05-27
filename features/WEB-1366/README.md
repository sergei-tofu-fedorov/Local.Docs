# WEB-1366 — Allow revoking expired invitations

**Status:** in-progress
**Started:** 2026-05-07
**ClickUp:** https://app.clickup.com/t/WEB-1366
**Affected repos:** `Tofu.Auth.Backend`

## Branches

- `Tofu.Auth.Backend` — `feature/WEB-1366`

## Goal

Allow admins to revoke an invitation even after it has expired. Previously,
`InvitationToken.Revoke()` (and the corresponding service-level guard in
`TenantInvitationService.RevokeAsync`) required the invitation to be
`Pending` — which meant once an invitation expired, it was stuck in
`Expired` status forever and couldn't be cleaned up by an admin.

## Scope

- In scope:
  - New `InvitationToken.IsRevocable()` — allows revoke iff the invitation
    has not already been revoked or accepted (expiry no longer blocks).
  - `InvitationToken.Revoke()` switches from `EnsurePending()` to the new
    check.
  - `TenantInvitationService.RevokeAsync` switches its status guard to
    `IsRevocable()` for symmetry with the domain.
  - Domain unit test covering the new behavior.
  - API functional test covering the new behavior end-to-end.
- Out of scope:
  - Auto-cleanup / sweeping of expired invitations.
  - Permission changes — existing admin permission still gates the
    endpoint.
  - Any change to magic-token / acceptance flows.

## Affected repos

- `Tofu.Auth.Backend` (single-repo change) — domain rule change, service
  guard update, two new tests.

**Cross-repo notes:** none — single repo, no proto change, no consumer
behavior change.

## Plan

1. [x] Add `InvitationToken.IsRevocable()` and switch `Revoke()` to use it
       (`src/Tofu.Auth.Domain/Models/InvitationToken.cs`).
2. [x] Switch `TenantInvitationService.RevokeAsync` to use `IsRevocable()`
       (`src/Tofu.Auth.Application/Services/TenantInvitationService.cs`).
3. [x] Add domain unit test
       (`tests/Tofu.Auth.Domain.UnitTests/Models/InvitationTokenTests.cs`
       — `Revoke_ShouldSucceed_WhenExpired`).
4. [x] Add API functional test
       (`tests/Tofu.Auth.Api.Tests.Functional/Full/Invitations.cs`
       — `RevokeInvitation_ShouldReturnNoContent_WhenInvitationIsExpired`).
       Uses the existing `CreateInvitationInDbAsync(expired: true)` helper.
       Fails on `main` (old guard threw `InvitationNotPendingException` for
       any non-`Pending` status); passes on `feature/WEB-1366`.

## Breaking changes

None — additive only. The change loosens an existing guard. No proto,
REST shape, DB column, response schema, or permission key changed. Old
callers that relied on the strict guard now succeed where they used to
fail; that's the intended fix, not a regression.

## Data / migration

None.

## Test plan

- **Unit tests** —
  `InvitationTokenTests.Revoke_ShouldSucceed_WhenExpired` already on the
  branch. Asserts `Revoke()` succeeds and `GetStatus(now) == Revoked`
  when the invitation is past its `ExpiresAt`.
- **Integration tests** —
  `Invitations.RevokeInvitation_ShouldReturnNoContent_WhenInvitationIsExpired`
  added in this change. Creates an expired invitation via the existing
  `CreateInvitationInDbAsync(expired: true)` helper (which sets
  `ExpiresAt` one day in the past via raw SQL), hits the revoke endpoint
  with an admin JWT, asserts `204 NoContent`, then re-reads the row and
  asserts `RevokedAt != null` and `GetStatus(now) == Revoked`.
- **Manual verification** — optional. Mark a test invitation expired by
  editing `ExpiresAt` in the DB, hit
  `POST v1/tenants/{tenantId}/invitations/{invitationId}/revoke`,
  expect 204.
