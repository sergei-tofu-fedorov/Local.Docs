Jobs Application Services
=========================

Purpose
-------

This note documents the recommended application service layer for Jobs command
handlers, especially where handlers touch Estimates, Invoices, or Clients. The
goal is to keep command handlers thin and isolate cross-bounded-context logic in
application services.

Goals
-----

- Keep Jobs domain logic inside `Jobs.Domain`.
- Move cross-BC orchestration (Estimates/Invoices/Clients) into application services.
- Preserve current synchronous behavior while making the code easier to test.

Non-goals
---------

- Introducing asynchronous event processing or outbox mechanics.
- Changing API contracts or external service APIs.
- Redesigning the Jobs domain model.

Recommended Placement (Invoices.Backend)
----------------------------------------

Application service interfaces and implementations should live in the Jobs
application layer, not in Contracts or Domain:

- Interfaces: `Src/Jobs/Jobs.Application/Services/*`
- Implementations: `Src/Jobs/Jobs.Application/Services/*`

Suggested folders:

- `Src/Jobs/Jobs.Application/Services/Relations/`
- `Src/Jobs/Jobs.Application/Services/Items/`
- `Src/Jobs/Jobs.Application/Services/Clients/`

Contracts and Models
--------------------

- Keep external service contracts and models in their existing assemblies
  (e.g., `Invoices.Common.Services.*`, `Invoices.Core.Models.*`).
- Add new DTOs to `Src/Jobs/Jobs.Contracts` only if they are part of public API
  or message contracts.
- For internal mapping, prefer application-layer helpers or private mappers
  inside the service implementation.

Service Responsibilities
------------------------

`IJobInvoiceRelationsService`

- Link a job to an invoice.
- Clear invoice links when a job is deleted.
- Centralize trace ids, error handling, and logging for external calls.

`IJobEstimateRelationsService`

- Link a job to an estimate.
- Clear estimate links when a job is deleted.
- Centralize trace ids, error handling, and logging for external calls.

`IJobItemsService`

- Copy or append items from an estimate into a job.
- Encapsulate the estimate-to-job item mapping.

`IJobClientsService`

- Resolve client data needed to create or update a job.
- Translate client-not-found errors into a consistent application exception.

Handler Responsibilities
------------------------

Handlers should:

- Load and modify the Job aggregate.
- Persist via the repository.
- Call the application services for cross-BC work.
- Update summaries and persist domain events as they do today.

Error Handling
--------------

- Application services should absorb external service exceptions and log them
  consistently with structured messages.
- Handlers should only throw on core aggregate or validation errors.

Testing Guidance
----------------

- Unit test each application service with mocked external dependencies.
- Keep handler tests focused on orchestration and repository calls.
