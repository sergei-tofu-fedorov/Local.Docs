# Backend — documentation index

Backend documentation that applies across services. Up: [`../AGENTS.md`](../AGENTS.md).

## Where to start
- Architecture overview → [`HowTo/Architecture.md`](HowTo/Architecture.md)
- Persistence overview → [`Persistence.md`](Persistence.md) · **data-store inventory** → [`Storage/AGENTS.md`](Storage/AGENTS.md)
- Auth scenarios → [`HowTo/Authentication.md`](HowTo/Authentication.md), [`HowTo/Authorization.md`](HowTo/Authorization.md)
- Code style → [`HowTo/CodeStyle.md`](HowTo/CodeStyle.md)

## Services (`Services/`)
Per-service deep docs — each has its own `AGENTS.md`:
- [`Services/Invoices.Backend/AGENTS.md`](Services/Invoices.Backend/AGENTS.md) — BFF / gateway exposed to web + mobile clients.
- [`Services/Tofu.Invoices/AGENTS.md`](Services/Tofu.Invoices/AGENTS.md) — core invoices + estimates service.
- [`Services/Tofu.Auth/AGENTS.md`](Services/Tofu.Auth/AGENTS.md) — authentication / authorization (sessions, OTP, permissions).

## REST API references (`Api/`)
`Api/<NAME>_API_REFERENCE.md`: ACCOUNT, AUTHORIZATION, CLIENTS, ESTIMATES, INVITATIONS, INVOICES, ITEMS, JOBS, NOTIFICATIONS, PAYMENTS, TEAMS, WORKER.

## Flows (`Flows/`)
AUTHENTICATION_FLOW, INVITATION_FLOWS, JOB_FROM_ESTIMATE_FLOWS, NOTIFICATIONS_FLOWS, OTP_FLOW, WORKER_FLOWS.

## How-to guides (`HowTo/`)
Architecture, Authentication, Authorization, CodeStyle, DDD, EmailSending, IntegrationTests, OneLink, PushNotifications, Transactions, UnitOfWork.

## Domain notes (`Domain/`)
permissions-architecture, permissions-migration-plan, plans-stripe, reports, users.

## Data stores (`Storage/`)
Inventory of every dataset / collection / schema / bucket → [`Storage/AGENTS.md`](Storage/AGENTS.md) (BigQuery, Mongo, Postgres, GCS).

## Ideas / proposals (`Ideas/`)
caller_context, ddd_results, plan_upgrades, and `pdf_export_service/` (proposal + benchmark).

## Conventions
New backend doc → `HowTo/` (task guides), `Services/<Service>/` (service internals), `Domain/` (cross-service domain notes), or `Api/`/`Flows/` (contracts & sequences). Each folder's index is `AGENTS.md`.
