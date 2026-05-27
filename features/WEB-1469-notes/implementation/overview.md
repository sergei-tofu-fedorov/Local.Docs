# WEB-1470 — Notes Backend — Implementation Plan

> Reference: [../overview.md](../overview.md) for the full design and product rules.

This folder breaks the [Notes overview](../overview.md) into ordered backend implementation steps.
Each document is a self-contained chunk of work scoped to a single layer (domain, persistence, …).

> **Status (current iteration):** All six step docs are aligned with the latest design
> (mutually exclusive `ClientId` / `VisitId` anchors, no `JobId`, no stored `IsEdited`, flat
> Worker visibility, no assignee checks, app-level visit-delete cascade in place of the
> dropped Postgres trigger, `Invoices.Core.Models.Team.TeamMemberRole` carried verbatim on
> commands / queries).

## Layout

```
implementation/
  overview.md                 — this file (orchestration + order)
  1_domain_model.md           — Note aggregate + NoteAuthor + enums; invariants and DDD shape
  2_persistence.md            — EF mapping + migration (table, sequence/version triggers, indexes) + repository
  3_application_layer.md      — Commands/Queries + handlers + NoteWriteService + persistence-error guard
  4_api_layer.md              — NotesController + DTOs + mappings + NotesAuthorService
  5_authorization.md          — Permission keys + AccessRegistry + role visibility filter on reads
  6_tests.md                  — Unit tests + integration tests (TestContainers Postgres)
```

## Sub-documents

| Step | Doc | Topic |
|---|---|---|
| 1 | [Domain Model](1_domain_model.md) | `Note` aggregate, `NoteAuthor` value object, `NoteVisibility`, invariants, version check, role/scope helpers |
| 2 | [Persistence](2_persistence.md) | `NoteConfiguration` EF mapping, single migration with two triggers (sequence, version), partial indexes, `INotesRepository` + `NotesRepository`. Visit-delete cascade is an application-level bulk update wired into step 3 §3.7 |
| 3 | [Application Layer](3_application_layer.md) | Commands / Queries / handlers, inline upsert orchestration (existence probe + role / completion checks + version check + factories) |
| 4 | [API Layer](4_api_layer.md) | `NotesController` (5 endpoints), API DTOs, contract↔domain↔API mappings, `NotesAuthorService` (role + display-name resolution) |
| 5 | [Authorization](5_authorization.md) | `PermissionKeys.Note.View` / `Note.Manage`, `AccessRegistry` entries, role-driven visibility filter inside handlers |
| 6 | [Tests](6_tests.md) | `NoteTests` (domain unit tests) + Integration tests for schema, GET `/all`, GET `/{id}`, `/sync`, PUT, DELETE, plus a "jobs sync does not include notes" guard test |

## Implementation Order

1. **Step 1 — Domain Model.** Build `Note` first. It owns all invariants — message length, visibility ↔ visit rules, author-only edit, idempotent delete, version check, role-driven edit/delete/read predicates. The rest of the system orbits around the aggregate's public surface.
2. **Step 2 — Persistence.** Map the aggregate to `jobs.Notes` (same schema as `jobs.Jobs` and `jobs.Visits`). The migration introduces two triggers — sequence bump (sync cursor) and version bump (optimistic concurrency). The visit-delete cascade is an app-level bulk update (`INotesRepository.SoftDeleteByVisitIds`) executed from `UpsertJobCommandHandler` before the visit `DELETE` lands (step 3 §3.7). Repository surface stays narrow: read by id (live / including deleted), filtered find for `/all`, cursor scan for `/sync`, plus the slim visit projection the write path needs for the completion check, plus the bulk cascade helper.
3. **Step 3 — Application Layer.** Wire up the CQRS surface that the controller dispatches into: commands (`SaveNoteCommand`, `DeleteNoteCommand`) and queries (`GetNoteByIdQuery`, `GetNotesQuery`, `SyncNotesQuery`). `SaveNoteCommandHandler` carries the upsert orchestration inline: existence probe → role / completion checks → version check → `Note.SetMessage` or factory. The visit-delete cascade lives in `UpsertJobCommandHandler` §3.7 — bulk soft-delete + `VisitId` clear via `INotesRepository.SoftDeleteByVisitIds` before `SaveChangesAsync`.
4. **Step 4 — API Layer.** `NotesController` exposes the five v3 routes; `NotesAuthorService` resolves the caller's `(MasterUserId, Role, DisplayName)` triple from Tofu.Auth once per request; mapping converts between API DTO, contract DTO, and domain types.
5. **Step 5 — Authorization.** Register `note.view` / `note.manage` permission keys; both are granted to `AdminAndWorker` on `AllPlans` in `AccessRegistry`. Visibility filtering (Private rows hidden from Worker; Team rows scoped to assigned visits / clients) lives inside the query handlers, not in the permission system — see step 3 + step 5 for the split.
6. **Step 6 — Tests.** Domain unit tests cover the `Note` aggregate's invariants in isolation. Integration tests cover wire-shape contracts, schema constraints (triggers + CHECKs), and visit-completion / cross-account / version-mismatch matrices. A guard test on `/jobs/sync` locks in the "notes are NOT folded into jobs sync" contract.

## Cross-Cutting Conventions

- Single migration only — `WEB-1470_AddNotesTable` creates the table, sequence, two triggers (sequence + version), indexes, and FK in one transaction.
- `XA-Client-Event-Ms` header drives `CreatedAt` / `UpdatedAt` / `DeletedAt` (offline-replay). Header absent → `DateTimeOffset.UtcNow`.
- Optimistic-concurrency pattern mirrors `jobs.Jobs.Version`: `IsConcurrencyToken().ValueGeneratedOnAddOrUpdate()` on the EF property plus a `BEFORE UPDATE` trigger that does `NEW.Version = OLD.Version + 1`.
- Soft-delete via `DeletedAt`; tombstones flow through `/sync` exactly once, then disappear after the client's cursor moves past their `SequenceId`.
- `SequenceId` (`bigint`, server-internal) vs `Version` (`int`, on the wire) — two distinct counters, two jobs.

## Out of Scope (v1)

Pinning, attachments on notes, search/filter beyond newest-first, multi-manager, @-mentions, threads, audit log, job-level aggregate notes view. See [overview.md → Out of scope](../overview.md#scope).
