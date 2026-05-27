# Accounts and Ownership

Scope: backend view of **accounts**, how they are linked to master/platform users, and how ownership and invitations work in the Invoices.Backend service.

For the user model (master vs platform users and first-link semantics), see `Backend/Services/Invoices.Backend/Users.md`.

## Account Concepts

- **Account**
  - Business entity (company/profile) that invoices and estimates belong to.
  - Identified by an internal account id.

- **Account identifiers**
  - Metadata attached to an account that describes who created/uses it from the client side.
  - Includes:
    - `UserId` – the platform user id that owns the account from the device perspective.
    - Additional metadata (vendor id, app version, platform).

- **Owned accounts on master user**
  - Each master user keeps a list of account ids it owns or can access.
  - Entries can optionally carry a tenant role (for invited users).

## Linking Accounts to Users

When a client saves or updates an account:

1. The backend stores or updates the account data itself.
2. It writes or updates the **account identifiers** with:
   - The platform user id (`UserId`) from the request context.
   - Other client-side metadata as available.
3. If the request is associated with a master user:
   - The account id is added to that master user’s owned accounts.
   - The assignment records which platform and product performed the link.

This gives two complementary ways to find the account later:

- From the client side via `UserId` → accounts.
- From the backend side via master user → owned accounts.

## Ownership and Invitations

Ownership is represented via how an account appears in a master user’s owned accounts list:

- **Owner/admin entries**
  - Have no tenant role set.
  - Represent the primary owner of the account.
  - Only one master user can be the owner; the system prevents conflicting owners.

- **Invited members**
  - Have a tenant role set (for example, team member roles).
  - Represent users who can access the account without changing who owns it.
  - Used by team and permissions flows when managing account members.

## Reading Accounts for a User

When serving account-related APIs, the service typically:

- Uses the master user (when available) as the primary source of truth:
  - Reads the list of owned account ids from the master user.
  - Loads account details and related information (logos, activity, subscriptions) for those ids.

- Falls back to account identifiers when needed:
  - If only an account id is known (no master user context), the service can:
    - Look up the platform user id for that account.
    - Use that id to discover other accounts associated with the same platform user.

This allows both authenticated flows (via master users) and more limited flows (via single accounts or platform user ids) to work consistently.

## Related Endpoints and Behaviour

This document stays at the concept level. For concrete behaviour, see:

- Account and team APIs:
  - Endpoints that list or manage accounts for the current user.
  - Endpoints that invite or remove team members for an account.
- Plans and subscriptions:
  - Endpoints that rely on master-user-owned accounts and “first link” product users to determine which subscriptions apply.

Implementation details (DTOs, repository contracts, and exception types) live in the Invoices.Backend codebase and should be treated as the source of truth. This document is meant to outline how account-related concepts fit together.

