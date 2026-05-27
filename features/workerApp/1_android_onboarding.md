
Stage 1 – Android Onboarding
============================

Goal
----

Allow the Android Worker App to fetch all **available invitations / businesses** for the authenticated worker, without exposing email in public contracts.

High-Level Flow
---------------

1. Worker installs / opens the Android app and signs in.
2. Android app calls Invoices.Backend to fetch businesses available to the authenticated worker.
3. Invoices.Backend uses the authenticated worker identity (email resolved from auth context) to call Tofu.Auth and internal services.
4. Tofu.Auth returns invitations owned by that worker that are:
   - not expired,
   - not already accepted or revoked,
   - valid for Worker App onboarding.

Backend Changes - Tofu.Auth
---------------------------

- Add a new **query endpoint** in Tofu.Auth to list invitations for the **authenticated user**.
  - Input: none (email is resolved from the authenticated user context).
  - Output: list of invitation DTOs compatible with Worker App onboarding (id, account/tenant, role, status, expiry, etc.).
- Add a new **public query endpoint** in Tofu.Auth to return **short worker info by email** for non-authorized flows (replaces the old non-auth invitations-by-email endpoint).
  - Input: email address (query parameter).
  - Output:
    - `pendingInvitations`: list of invitation DTOs that are still valid for onboarding (pending, not expired, not revoked).
    - `tenants`: list of tenant memberships where the worker has **Worker** role.
- Define / update the **public contract** for this endpoint in Tofu.Auth's API docs:
  - Document request/response schema.
  - Document error cases (for example: invalid email, rate limiting, internal errors).
- Ensure invitation filtering:
  - Only invitations that are still valid for onboarding are returned.
  - Invitations should be scoped to the correct environment / tenant rules.

Integration Changes - Invoices.Backend
--------------------------------------

- Update the **Tofu.Auth client package** used by Invoices.Backend:
  - Add a client method `ListUserInvitationsAsync(CancellationToken cancellationToken)` to list invitations for the authenticated user (no email parameter).
  - Add a client method `GetWorkerSummaryByEmailAsync(string email, CancellationToken cancellationToken)` to list pending invitations and tenant memberships for non-authenticated flows.
  - Implement mapping from Tofu.Auth contract to internal models used by Invoices.Backend.
- Add a new **Invoices.Backend API endpoint** that the Worker App will call:
  - Input: none (relies on authenticated worker).
  - Behaviour:
    - Calls the new Tofu.Auth endpoint via the updated client using the current auth context.
    - Applies any additional domain checks required by Invoices.Backend.
  - Output: list of **businesses** and their invitation / access metadata formatted for the Worker App.

Accept All Pending Invitations
------------------------------

Goal:

- Allow the Worker App to **accept all pending invitations** for the current worker.

High-Level Flow
---------------

1. Worker opens the app and triggers accept of all pending invitations.
2. Android app calls Invoices.Backend to accept all pending invitations.
3. Invoices.Backend calls Tofu.Auth to accept invitations:
   - Resolves the current user email from the authenticated context.
   - Calls Tofu.Auth to accept **all pending invitations** for the worker.
4. Tofu.Auth:
   - Searches for **all active invitations** for the worker (by email).
   - Marks any found, valid invitations as accepted.
   - Returns the list of accepted invitations (or an empty list when none can be accepted).

Backend Changes - Tofu.Auth (Accept)
------------------------------------

- Add a **single command endpoint** in Tofu.Auth to accept all pending invitations for the current user:
  - `POST /v1/tenants/invitations/accept`
  - Request body: none.
  - Behaviour:
    - Resolves current user email from auth context.
    - Finds all **pending invitations** for the current user across all tenants.
    - For each pending invitation:
      - Validates it and accepts it (assigns tenant role + marks invitation as accepted).
  - Response:
    - `TenantInvitationsResponse` with the list of accepted invitations (may be empty).
- Update Tofu.Auth API contract documentation:
  - Add the accept-all endpoint to the invitation section.
  - Document request/response and error semantics.

Integration Changes - Invoices.Backend (Accept)
-----------------------------------------------

- Update the **Tofu.Auth client package** to support accept-all operation:
  - Add / expose `AcceptAllAsync(CancellationToken cancellationToken)`.
  - **Note:** The `accountIds` parameter was removed from the client. The endpoint now accepts all pending invitations for the authenticated user without filtering.
- Add / update the **Invoices.Backend API endpoint** for the Worker App:
  - Input: none.
  - Behaviour:
    - Resolves the worker email from the authenticated principal.
    - Calls the Tofu.Auth accept endpoint via the updated client to accept all pending invitations for the worker.
    - Handles and translates Tofu.Auth errors into appropriate HTTP responses for the app.
  - Output:
    - A list of accepted invitations (or an empty list) mapped into Worker App DTOs.

List Available Businesses for Worker
------------------------------------

Goal:

- Provide the Worker App with a **single list of businesses** that the current worker can access (for example, already linked accounts and those with accepted invitations).

High-Level Flow
---------------

1. Worker authenticates in the Android app.
2. Android app calls an Invoices.Backend endpoint to list all businesses available to the authenticated worker.
3. Invoices.Backend:
   - Uses existing account/membership information.
   - Optionally uses invitations from Tofu.Auth (for example, invitations already accepted for this worker).
4. Response contains a list of businesses that the Worker App can show on the “choose business” screen.

Backend Changes - Tofu.Auth
---------------------------

- Expose a **separate query endpoint** that uses the **user–tenant membership model**, not the invitation table:
  - Use `UserTenantRoleRepository` (or equivalent) to resolve all tenants where the authenticated user has a role.
  - Return, for each tenant, the **business identifier** and the **role** of the user in that tenant.
  - Do not rely on invitation tokens to determine available businesses.

Integration Changes - Invoices.Backend
--------------------------------------

- Add a new **Invoices.Backend API endpoint** for the Worker App:
  - Input: none (relies on the authenticated worker).
  - Behaviour:
    - Resolves the current worker from the authentication context.
    - Calls Tofu.Auth to get tenant memberships (account ids + roles), for example via `ListUserTenantsAsync(CancellationToken cancellationToken)` on the Auth client.
    - For each account id, resolves the **business name** and other display data from Invoices.Backend data (`Accounts`).
  - Output:
    - List of businesses, each with an identifier and minimal display information (for example, business name, logo/branding if available).

Concrete API Shape (Draft)
--------------------------

Tofu.Auth (Auth service)
~~~~~~~~~~~~~~~~~~~~~~~~

- `GET /v1/users/invitations`
  - Request: no body.
  - Auth:
    - Requires authenticated user; **email is taken from the auth context**.
  - Response: `TenantInvitationsResponse`
    - `invitations`: `TenantInvitationResponse[]` (existing contract: id, tenantId, email, roleLevel, status, expiresAt, createdAt, acceptedAt, revokedAt; `tenantId` maps to `AccountId` in Invoices.Backend).

- `GET /v1/workers/summary` (name TBC)
  - Request: no body.
  - Auth:
    - Anonymous access allowed (used by trusted backend services for non-authenticated user flows); should be protected by rate limiting and monitoring at the gateway.
  - Query parameters:
    - `email`: string (worker email address).
  - Behaviour:
    - Returns a short worker summary for onboarding:
      - `pendingInvitations`: all **pending invitations** for the specified email.
      - `tenants`: tenant memberships where the worker has **Worker** role.
  - Response (draft):
    - `WorkerSummaryResponse`
      - `pendingInvitations`: `TenantInvitationResponse[]`
      - `tenants`: `UserTenantMembershipResponse[]` (filtered to Manager/Worker roles).

- `GET /v1/users/tenants` (name TBC)
  - Request: no body.
  - Auth:
    - Requires authenticated user.
  - Behaviour:
    - Uses `UserTenantRoleRepository` (or equivalent) to find all tenant memberships for the current user.
  - Response (draft):
    - `UserTenantsResponse`
      - `tenants`: items with:
        - `accountId`: string (business id)
        - `roleLevel`: enum (`Admin`, `Worker`, etc.).

- `POST /v1/tenants/invitations/accept`
  - Request body: none.
  - Response: `TenantInvitationsResponse`
    - `invitations`: list of accepted invitations for the current user.

Invoices.Backend (Worker-facing API)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

- `GET /api/worker/invitations` (v3.0)
  - Auth:
    - Requires authenticated worker; email resolved from auth context.
  - Request: no body.
  - Behaviour:
    - Calls Tofu.Auth `/v1/users/invitations` for the authenticated user.
    - Returns the invitations relevant for Worker App onboarding (as filtered by Tofu.Auth).
  - Response DTO:
    - `InvitationListResponseDto`
      - `invitations`: `InvitationDto[]`
        - Same shape as existing invitation DTOs used by Invoices.Backend.

- `GET /api/worker/summary` (v3.0)
  - Auth:
    - Anonymous access allowed (non-authenticated endpoint for onboarding flows).
  - Request:
    - Query parameter `email: string` (worker email address).
  - Behaviour:
    - Calls Tofu.Auth `/v1/workers/summary` for the provided email address.
    - Returns two boolean flags indicating whether the worker has pending invitations or existing memberships.
  - Response DTO:
    - `WorkerSummaryResponseDto`
      - `hasPendingInvitations`: bool (true if the worker has pending invitations).
      - `hasWorkerAccount`: bool (true if the worker is a member of any account with Worker role).

- `POST /api/invitations/accept-all` (v3.0)
  - Auth:
    - Requires authenticated worker; email resolved from existing auth context.
  - Request body: none.
  - Behaviour:
    - Calls Tofu.Auth `/v1/tenants/invitations/accept` to accept all pending invitations for the worker.
    - Updates worker–business linkage in Invoices.Backend (master user ↔ account link) for each accepted invitation.
    - Response DTO: `AcceptInvitationsResponseDto`
      - Contains an `invitations: InvitationDto[]` collection with all accepted invitations for the worker.

- `GET /api/worker/businesses` (v3.0, name TBC)
  - Auth:
    - Requires authenticated worker; identity resolved from auth context.
  - Request: no body.
  - Behaviour:
    - Resolves the worker’s master user and existing account links based on current tenant memberships.
  - Response DTO (draft):
    - `WorkerBusinessesResponseDto`
      - `businesses`: `WorkerBusinessDto[]`
        - `id`: string (business / account id)
        - `name`: string
        - `role`: enum (worker’s role in this business, for example `Worker`, `Admin`)
        - `isCurrent`: bool (optional, flags the business currently selected in the app)
        - Optional: minimal extra fields (branding, locale) if needed by the Worker App.

C# DTOs for Tofu.Auth Client
----------------------------

To allow other services to implement compatible clients without referencing the Auth DLL directly, these are the C# contracts used by the new endpoints:

```csharp
namespace Tofu.Auth.Contracts.Invitations;

public enum RoleLevelDto
{
    Unknown = 0,
    Admin = 1,
    Worker = 2
}

public enum InvitationStatusDto
{
    Pending = 0,
    Accepted = 1,
    Revoked = 2,
    Expired = 3
}

public record TenantInvitationResponse(
    Guid Id,
    string TenantId,
    string Email,
    RoleLevelDto RoleLevel,
    InvitationStatusDto Status,
    DateTimeOffset ExpiresAt,
    DateTimeOffset CreatedAt,
    DateTimeOffset? AcceptedAt,
    DateTimeOffset? RevokedAt);

public record TenantInvitationsResponse(List<TenantInvitationResponse> Invitations);

public record UserTenantMembershipResponse(string TenantId, RoleLevelDto RoleLevel);

public record UserTenantsResponse(List<UserTenantMembershipResponse> Tenants);

public record WorkerSummaryResponse(
    List<TenantInvitationResponse> PendingInvitations,
    List<UserTenantMembershipResponse> Tenants);

// Note: AcceptInvitationsByTenantsRequest no longer has parameters.
// The endpoint now accepts all pending invitations without filtering by tenant.
public record AcceptInvitationsByTenantsRequest;
```

Note: In Invoices.Backend docs and BFF contracts, use `AccountId` naming for tenant identifiers.
