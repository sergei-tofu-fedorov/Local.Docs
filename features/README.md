Features Index
==============

This folder contains cross-product feature documentation. Each feature has its
own subfolder under `features/<feature>/` with a focused set of docs.

Current Features
----------------
- `account_filtering` - app-type filtering on account lists (FS/IM return owned accounts only).
- `jobs` - background jobs and related flows.
- `notifications` - notification model and delivery plan.
- `permissions` - permissions and invitations.
- `WEB-1366` - allow admins to revoke expired invitations (Tofu.Auth).
- `WEB-1469` - notes on visits and clients (free-form text per entity).
- `MAIN-1361` - AI-powered user (account) analysis; first surface is FSM-fit scoring for invoice-only users (post-spike, pre-implementation).
- `MAIN-1631` - AI-driven client analysis, stage 1: invoices (planning).
- `MAIN-1632` - zero-downtime deploy for `tofu-invoices-api` and `auth-api` (Invoices.Kubernetes manifests).
- `INVC-3608` - silence worker mutations on shared `tofu` web client (set_identifiers no-op).
- `WEB-1529` - assign admin role on business account creation (eager path + backfill for existing users).
- `WEB-1526` - CI/CD changes for the `Tofu.AI.Backend` FSM-fit analysis platform (review summary of WEB-1523's pipeline work).
- `WEB-1526-prep` - non-segmentation groundwork: `Tofu.AI.Backend` to canonical form (src/ move, ports/adapters layering, host wiring) + `Invoices.Kubernetes` operational fixes.
- `WEB-1527` - metrics collection implementation in `Tofu.AI.Backend` (theory in WEB-1523-segmentation).
- `WEB-874` - scheduling: backend implementation plan for the Web Manager week-view calendar of visits (shared backend with FS-1008 mobile twin) — `DurationMinutes` on `Visit` + denormalised `AccountId` / `IsDeleted` with composite indexes; no new routes.

Start Points
------------
- For a high-level overview of notifications, start with
  `features/notifications/README.md`.
- For permissions, start with `features/permissions/README.txt`.
- For jobs, start with `features/jobs/JOBS_FLOWS.md`.
