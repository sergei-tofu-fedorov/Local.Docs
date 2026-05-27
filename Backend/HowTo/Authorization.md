Authorization in Backend
========================

This document describes how authorization is structured in the backend and how
to work with roles and permissions.

Core Concepts
-------------

- **User** – authenticated person with one or more identities.
- **Tenant** – organization or workspace a user belongs to.
- **Role** – set of permissions assigned to a user within a tenant.
- **Permission** – fine‑grained capability (for example, `invoice.view`).

Permission Keys
---------------

- Use the pattern: `{resource}.{action}[.{subaction}][.{detail}]`.
- Use lowercase and dot separators only.
- Keep depth reasonable (up to 4 segments).
- Examples:
  - `invoice.view`
  - `invoice.email.send`
  - `user.roles.assign`

Where Permissions Live
----------------------

- Permission constants are defined in
  `src/Tofu.Auth.Domain/Constants/Permissions.cs`.
- Validation method: `Permissions.IsValidPermissionKey(string key)`.

Roles and Assignments
---------------------

- Default roles: Worker, Manager, Admin (or product‑specific equivalents).
- Roles group permission keys.
- Role assignments are per‑tenant; a user can have different roles in different
  tenants.

Implementation Notes
--------------------

- Keep authorization checks close to the application layer (handlers/services).
- Avoid duplicating permission strings; always use constants.
- Prefer explicit checks (for example, `HasPermission(Permissions.Invoice.View)`)
  over generic ad‑hoc rules.
