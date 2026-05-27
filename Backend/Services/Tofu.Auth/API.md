Tofu.Auth API Client and DTOs
=============================

This document describes the C# client interface and DTOs used to call the
Tofu.Auth API from other services.

ITofuAuthApiClient
------------------

The main entry point is `ITofuAuthApiClient`. It includes methods for:

- **User info**
  - Get authenticated user info.
  - Get info for multiple users by IDs.

- **One-time passwords (OTP)**
  - Send an OTP to email.
  - Exchange an OTP for an authentication token.

- **Session management**
  - Exchange session cookies.
  - Create a new session cookie.
  - Logout.

- **Permissions**
  - Fetch permissions of the current user for a given tenant.

- **My profile**
  - Read and update contact info of the current user.

- **Tenant users**
  - List users in a tenant.
  - Get a single tenant user.
  - Update tenant user contact info.
  - Remove a user from a tenant.

- **Invitations and magic links**
  - Create tenant invitations.
  - List invitations.
  - Accept invitations.
  - Perform magic login.
  - Revoke invitations.

Request DTOs
------------

All request DTOs used by `ITofuAuthApiClient` and invitation operations.

- `OneTimePasswordRequest`
  - `Email` (`string`) - email to send the one-time password to.

- `ExchangeOneTimePasswordRequest`
  - `Email` (`string`) - email that received the OTP.
  - `OneTimePassword` (`string`) - one-time password value.

- `UserInfosRequest`
  - `UserIds` (`IReadOnlyCollection<Guid>`) - collection of user identifiers to fetch.

- `UpdateUserContactInfoRequest`
  - `Name` (`string?`) - optional contact name for the current user.
  - `PhoneNumber` (`string?`) - optional contact phone number for the current user.

- `CreateTenantInvitationRequest`
  - `Email` (`string`, required) - invited user email.
  - `RoleLevel` (`RoleLevelDto`, required) - role level to assign on accept.
  - `BusinessName` (`string`) - business name shown in the invitation.
  - `BaseUrl` (`string?`) - optional base URL used to build the invitation link.

- `MagicLoginRequest`
  - `MagicToken` (`string`) - short-lived magic token from the invitation link.

- `ListTenantInvitationsRequest`
  - `Statuses` (`InvitationStatusDto[]?`) - optional list of invitation statuses to filter by.

Response DTOs
-------------

All response DTOs returned by `ITofuAuthApiClient` and invitation endpoints.

- `AuthenticatedUserInfoResponse`
  - `Id` (`Guid`) - user identifier.
  - `Email` (`string?`) - user email (may be absent).
  - `Name` (`string?`) - display name.
  - `PictureUrl` (`string?`) - avatar URL.
  - `IsAnonymous` (`bool`) - whether the user is anonymous.
  - `ExternalUserId` (`string`) - external identity provider user ID.
  - `AuthMethod` (`AuthMethodType`) - authentication method used.
  - `IsRegisteredJustNow` (`bool`) - true if user was just registered.

- `UserInfosResponse`
  - `UserInfos` (`IReadOnlyCollection<AuthenticatedUserInfoResponse>`) - user info list.

- `CreateSessionCookieResponse`
  - `SessionCookie` (`string`) - opaque session cookie value.

- `ExchangeOneTimePasswordResponse`
  - `AuthenticationToken` (`string`) - token obtained from OTP exchange.

- `ExchangeSessionCookieResponseDto`
  - `AuthenticationToken` (`string`) - token obtained from session cookie exchange.

- `MyContactInfoResponse`
  - `Name` (`string?`) - current user contact name.
  - `PhoneNumber` (`string?`) - current user contact phone number.

- `PermissionsResponse`
  - `Abilities` (`List<Ability>`) - list of allowed abilities for the current user.

- `Ability`
  - `Object` (`string`) - protected resource (for example, `invoice`).
  - `Action` (`string`) - allowed action (for example, `view`, `email.send`).

- `TenantUserResponseDto`
  - `UserId` (`Guid`) - user identifier.
  - `Email` (`string?`) - user email.
  - `UserName` (`string?`) - global user name from the auth profile.
  - `ContactName` (`string?`) - tenant-specific contact name.
  - `ContactPhoneNumber` (`string?`) - tenant-specific phone number.
  - `Role` (`Role`) - tenant role assigned to the user.
  - `AssignedAt` (`DateTimeOffset`) - timestamp when the role was assigned.

- `Role`
  - `Level` (`RoleLevelDto`) - role level in the tenant.

- `CreateTenantInvitationResponse`
  - `Invitation` (`TenantInvitationResponse`) - created invitation.
  - `Link` (`string`) - ready-to-use invitation URL.

- `TenantInvitationsResponse`
  - `Invitations` (`List<TenantInvitationResponse>`) - collection of invitations for the tenant.

- `TenantInvitationResponse`
  - `Id` (`Guid`) - invitation identifier.
  - `TenantId` (`string`) - tenant identifier.
  - `Email` (`string`) - invited user email.
  - `RoleLevel` (`RoleLevelDto`) - role level that will be assigned on accept.
  - `Status` (`InvitationStatusDto`) - current invitation status.
  - `ExpiresAt` (`DateTimeOffset`) - expiration timestamp.
  - `CreatedAt` (`DateTimeOffset`) - creation timestamp.
  - `AcceptedAt` (`DateTimeOffset?`) - timestamp when invitation was accepted (if any).
  - `RevokedAt` (`DateTimeOffset?`) - timestamp when invitation was revoked (if any).

- `MagicLoginResponse`
  - `CustomToken` (`string`) - custom token for further authentication.

Enums
-----

- `AuthMethodType`
  - `None` - no authentication method.
  - `Email` - email/OTP based authentication.
  - `Google` - Google identity provider.
  - `Apple` - Apple identity provider.
  - `Anonymous` - anonymous session.

- `RoleLevelDto`
  - `Unknown` - role is not defined.
  - `Admin` - tenant administrator.
  - `Worker` - tenant worker.

- `InvitationStatusDto`
  - `Pending` - invitation is created and not yet used.
  - `Accepted` - invitation has been accepted.
  - `Revoked` - invitation has been revoked.
  - `Expired` - invitation is no longer valid due to expiry.
