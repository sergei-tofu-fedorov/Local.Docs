# User Model and Workflows

Scope: backend view of **master users** and **platform users** in the Invoices.Backend service. This document focuses on concepts and flows, not implementation details.

For code-level details, see the Invoices.Backend repository (master user model, auth service, and authentication controllers).

## Core Concepts

- **Platform user**
  - Represents a user in an external platform (iOS, Android, Web, etc.).
  - Identified by a platform-specific user id (`platformUserId`).
  - Comes from Tofu.Auth or client apps during authentication.

- **Master user**
  - Backend-level user aggregate that groups all identities (platform users) and accounts for a person.
  - Identified by `MasterUserId` in APIs and logs.
  - Owns:
    - **Platform links** (one per platform/product pair): which platform user ids belong to this master user.
    - **Owned accounts**: which business accounts this user can access (accounts are described in `Accounts.md`).

## First Link Semantics

The system distinguishes two “first” notions:

- **First-ever link for a platform user**
  - Answers: “Has this platform user ever been linked to any master user before?”
  - Used to set the `IsFirstEverLink` flag returned from authentication.
  - Based on whether a platform user id already appears in any master user’s platform links.

- **First link per master user and product**
  - Answers: “Which platform link is the primary one for this product on this master user?”
  - Stored as a boolean flag on the platform link.
  - Only links marked as first are used when the service needs a canonical `(userId, product)` pair (for example, when fetching plans or subscriptions).

In practice, this gives a stable “primary identity” per product while still allowing multiple platform identities (e.g., iOS + Web) for the same person.

## Authentication & Linking Flow

High-level behaviour when a client calls the authentication endpoint:

1. Client authenticates via Tofu.Auth (for example, email, Apple, Google, or anonymous).
2. Invoices.Backend receives:
   - The **platform user id** (from the client or Tofu.Auth).
   - The current **product key** and **platform** (Web, iOS, Android).
3. The auth layer:
   - Finds or creates a **master user** for this identity.
   - Links the platform user to the master user for the given `(platform, product)` combination.
   - Determines whether this is:
     - a completely new master user (`IsNewMaster`),
     - the first-ever link for this platform user (`IsFirstEverLink`),
     - the first sign-in for this master user/product (`FirstSignIn`).
4. The API returns both identifiers:
   - `MasterUserId` – stable backend id.
   - `UserPlatformId` – platform-level id used by client apps.

### Anonymous to identified migration

There is a migration path for anonymous users:

- Anonymous users initially sign in with a platform identity but without a permanent account (for example, “anonymous” auth method).
- When they later sign in with a real identity (email, Apple, Google, etc.), the system can:
  - Move accounts from the anonymous master user to the identified master user.
  - Move platform links as long as there are no conflicting links for the same `(platform, product)` on the target master user.
- Conflicts (for example, non-anonymous source user, missing links, or overlapping links) are reported as migration errors to the client.

## Related Endpoints and Behaviour

This document stays at the concept level. For concrete behaviour, see:

- Authentication and user lifecycle:
  - `POST /api/authenticate/auth` – sign-in / link platform user to master user (and optionally migrate from anonymous).
  - `POST /api/authenticate/logout` – sign-out and clear session cookie.
  - `DELETE /api/authenticate/master` – delete the current master user (debug / support scenarios).

For account ownership, invitations, and how accounts are resolved for requests, see `Backend/Services/Invoices.Backend/Accounts.md`.

Implementation details (DTOs, exception types, repository methods) live in the Invoices.Backend codebase and should be treated as the source of truth. This document is meant to explain how the user-related pieces fit together conceptually.

