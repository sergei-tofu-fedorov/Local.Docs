# Step 3: Application Layer

> References: [`../overview.md` → Endpoints](../overview.md#endpoints),
> [`../overview.md` → Authorization](../overview.md#authorization),
> [`../overview.md` → Validation and errors](../overview.md#validation-and-errors),
> [`1_domain_model.md`](1_domain_model.md), [`2_persistence.md`](2_persistence.md).

The CQRS surface the controller dispatches into:

- **Commands:** `SaveNoteCommand`, `DeleteNoteCommand`.
- **Queries:** `GetNoteByIdQuery`, `GetNotesQuery`, `SyncNotesQuery`.

Pure aggregate invariants (message length, author-only edit, optimistic-concurrency check,
idempotent delete) stay in `Note` (step 1). The orchestration that combines the existing row
with external state (visit-completion lock, "Worker can't author client-notes") is inlined
into the relevant command handler — v1 has a single caller per surface, so a separate
orchestration service would be over-engineering.

---

## 3.1 Command and query contracts

**Files:** `Jobs/Jobs.Contracts/Notes/Commands/`, `Jobs/Jobs.Contracts/Notes/Queries/`,
`Jobs/Jobs.Contracts/Notes/NoteContractDto.cs`.

```csharp
// Commands
public sealed record SaveNoteCommand(
    string AccountId,
    string CallerMasterUserId,
    TeamMemberRole CallerRole,
    string CallerDisplayName,
    Guid Id,
    int Version,
    string? ClientId,
    Guid? VisitId,
    NoteVisibilityDto Visibility,
    string Message,
    bool IsEdited,
    DateTimeOffset? OccurredAt) : ICommand<SaveNoteResult>;
public sealed record SaveNoteResult(NoteContractDto Note);

public sealed record DeleteNoteCommand(
    string AccountId,
    string CallerMasterUserId,
    TeamMemberRole CallerRole,
    Guid NoteId,
    DateTimeOffset? OccurredAt) : ICommand<DeleteNoteResult>;
public sealed record DeleteNoteResult;

// Queries
public sealed record GetNoteByIdQuery(
    string AccountId, string CallerMasterUserId, TeamMemberRole CallerRole,
    Guid NoteId) : IQuery<GetNoteByIdResult>;
public sealed record GetNoteByIdResult(NoteContractDto? Note);

public sealed record GetNotesQuery(
    string AccountId, string CallerMasterUserId, TeamMemberRole CallerRole,
    string? ClientId, Guid? VisitId) : IQuery<GetNotesResult>;
public sealed record GetNotesResult(IReadOnlyList<NoteContractDto> Items);

public sealed record SyncNotesQuery(
    string AccountId, string CallerMasterUserId, TeamMemberRole CallerRole,
    int PageSize, string? Cursor) : IQuery<SyncNotesResult>;
public sealed record SyncNotesResult(
    IReadOnlyList<SyncChangeItem<NoteContractDto>> Items,
    string NextCursor,                          // non-null by contract — see /sync section
    bool HasMore);
```

`OccurredAt` is sourced by the API layer from the `XA-Client-Event-Ms` header
(`BaseController.GetClientEventTime()`); `null` means "no header" and the domain falls back to
`DateTimeOffset.UtcNow`. `CallerRole` is the shared `Invoices.Core.Models.Team.TeamMemberRole`
enum (`Admin` / `Worker` / `Unknown`); the API layer derives it from Tofu.Auth's `RoleLevel`.
No note-specific role DTO — the role used on the team APIs is reused verbatim. `CallerDisplayName`
is only used on the create path (frozen into `NoteAuthor`); it carries no business meaning on
update / delete / read.

`NoteContractDto` and `NoteAuthorContractDto` mirror the wire DTOs (see
[overview → DTOs](../overview.md#dtos)) but live in `Jobs.Contracts` so handlers stay
unaware of the API DTO types. The API layer (step 4) maps `NoteContractDto` ↔ `NoteDto`.

Handlers register through `Jobs.Application.AddJobsHandlers` (existing Scrutor assembly scan).

---

## 3.2 `SaveNoteCommandHandler`

**File:** `Jobs/Jobs.Application/Notes/SaveNoteCommandHandler.cs`.

The handler owns the full create-or-update orchestration inline — pre-flight checks, the
domain call, persistence. Pseudocode:

```text
Handle(command):
    visibilities = callerRole.GetAllowedVisibilities()        # Admin → [Private, Team]; Worker → [Team]
    existing     = notesRepository.GetById(account, id, visibilities)
    # Workers asking for a Private note get null here (existence is filtered at DB) — the
    # CREATE branch then short-circuits to 404 via NoteIdExistsAnywhere, mirroring the
    # cross-account 404 contract: never leak the existence of a Private row to a Worker.

    if existing is not null:                              # UPDATE path
        # ValidateVersion first — matches the Jobs convention
        # (e.g. UpsertJobCommandHandler, UpdateVisitCommandHandler): version is the cheapest
        # "your snapshot is stale" check, runs immediately after the entity is loaded.
        existing.ValidateVersion(command.Version)
        existing.EnsureCanBeEditedBy(callerRole, callerMasterUserId)
        await EnsureVisitNotCompletedForWorker(existing)
        existing.SetMessage(
            command.Message,
            command.CallerMasterUserId,
            now:      command.OccurredAt,
            isEdited: command.IsEdited)
        note = existing
        # ClientId / VisitId / Visibility on the request are SILENTLY IGNORED on update —
        # domain immutability is enforced by the absence of setters on Note; step 1 records
        # the rationale, step 6 has an integration test asserting the silent-drop behaviour.

    else:                                                 # CREATE path
        if notesRepository.NoteIdExistsAnywhere(id):
            # Cross-account or soft-tombstone collision. 404 mirrors a cross-account GET —
            # never leak existence.
            throw EntityNotFoundException

        author = new NoteAuthor(command.CallerMasterUserId, command.CallerDisplayName)
        note   = await CreateNewNote(command, author)
        notesRepository.Insert(note)

    await unitOfWork.SaveChangesAsync(ct)
    return new SaveNoteResult(note.ToContract())
```

`CreateNewNote` is the single anchor-discriminator method — keeps the "client vs visit" split
in exactly one place and unpacks the non-null anchor so the factories don't need internal
guards:

```text
CreateNewNote(command, author):
    if command.ClientId is not null:
        if callerRole != Admin:
            throw NoteWriteForbiddenException    # workers can't author client-notes in v1
        return await CreateClientNote(command, command.ClientId, author)

    if command.VisitId is { } visitId:
        return await CreateVisitNote(command, visitId, author)

    # Controller (step 4 §`PUT /api/notes`) XOR-validates the anchors, so this throw is a
    # defensive guard against a future internal caller that bypasses the controller.
    throw ArgumentException("Exactly one of ClientId / VisitId must be set.")
```

`DbUpdateConcurrencyException` (raised by EF when `IsConcurrencyToken()` mismatches at
`SaveChanges`) bubbles up uncaught. The API middleware
(`ApiExceptionHandlingMiddleware.Mapping`) maps it to HTTP 200 + `ErrorCode.VersionMismatch` —
same envelope as `Note.ValidateVersion`. The in-memory check + EF check are deliberately
redundant: the first catches the common case without a DB round-trip; the second closes the
residual race between the probe and `SaveChanges`.

The PK race between `NoteIdExistsAnywhere` probe and `INSERT` (two concurrent `PUT`s with the
same caller-supplied `Id`) is **not specially handled** — the window is tiny in practice and
the cost of the catch-and-translate helper (Npgsql reflection + constraint-name string match)
outweighs the benefit. If it does fire, `DbUpdateException` bubbles up to the global middleware
and surfaces as HTTP 500.

### Visit-completion lock (UPDATE path)

```csharp
private async Task EnsureVisitNotCompletedForWorker(Note existing, CancellationToken ct)
{
    if (_command.CallerRole == TeamMemberRole.Admin || existing.VisitId is null)
        return;

    var status = await _visitsRepository.GetVisitStatus(_command.AccountId, existing.VisitId.Value, ct);
    if (status is null || status == VisitStatus.Completed)
        throw new NoteWriteForbiddenException(_command.CallerMasterUserId, existing.Id);
}
```

`null` (visit missing / its job soft-deleted) is treated the same as `Completed` — the worker
loses write access either way. Returning 403 (not 404) matches the "row still exists, you just
can't touch it" semantic; the note itself is reachable via `GET /api/notes/{id}`.

### Visit-note creation

```text
CreateVisitNote(command, visitId, author):
    if not await visitsRepository.VisitExists(account, visitId):
        throw EntityNotFoundException($"Visit '{visitId}' not found.")
        # → middleware maps to HTTP 200 + ErrorCode.NotFound

    # NO completion lock on create — workers can ADD notes any time, even after Completed.
    return Note.CreateForVisit(
        command.Id,
        command.AccountId,
        visitId,
        command.Message,
        author,
        createdAt: command.OccurredAt)
```

`IVisitsRepository.VisitExists` (step 2 §2.4) is the cheap existence + alive-parent-Job probe.
Using it instead of `GetVisitStatus` here avoids the "null = missing OR completed" overloading
on a path that doesn't actually care about the status — see step 2 §2.4 for the rationale.

### Client-note creation

```text
CreateClientNote(command, clientId, author):
    client = await clientsRepository.GetClientById(account, clientId, ct)
    if client is null:
        # Covers "client not found" AND "client belongs to another account" (single shape).
        throw EntityNotFoundException($"Client '{clientId}' not found.")
        # → middleware maps to HTTP 200 + ErrorCode.NotFound

    return Note.CreateForClient(
        command.Id,
        command.AccountId,
        clientId,
        command.Visibility.ToDomain(),
        command.Message,
        author,
        createdAt: command.OccurredAt)
```

`clientsRepository` is the existing `IClientsRepository` in `Invoices.Core.Repositories` (Mongo-
backed `ManageableClient` store); injected through the DI container. Step 3 does not introduce
a new abstraction. `GetClientById` returns archived clients as well as live ones — that is
intentional, the Manager can still annotate an archived client.

---


---

## 3.4 `DeleteNoteCommandHandler`

**File:** `Jobs/Jobs.Application/Notes/DeleteNoteCommandHandler.cs`.

```text
Handle(command):
    visibilities = callerRole.GetAllowedVisibilities()
    note         = notesRepository.GetByIdIncludingDeleted(account, noteId, visibilities)
        ?? throw EntityNotFoundException
    # Same shape as the edit path — a Worker asked to delete a Private note sees 404.

    # Visit-completion lock — same shape as the edit path. Runs BEFORE MarkDeleted so a worker
    # re-deleting a tombstoned note on a completed visit gets 403 (not a quiet 200).
    if callerRole == Worker and note.VisitId is not null:
        status = visitsRepository.GetVisitStatus(account, note.VisitId.Value)
        if status is null or status == Completed:
            throw NoteWriteForbiddenException

    # MarkDeleted folds:
    #   1. role + author authorisation (Admin → any note; Worker → own notes only),
    #   2. idempotent IsDeleted check (returns false when already tombstoned),
    #   3. the actual DeletedAt stamp.
    # Returning false short-circuits SaveChangesAsync so a re-DELETE costs zero DB round-trips.
    if note.MarkDeleted(callerRole, callerMasterUserId, now: command.OccurredAt):
        await unitOfWork.SaveChangesAsync()
    return DeleteNoteResult()
```

`GetByIdIncludingDeleted` (rather than `GetById`) is what keeps the idempotent return path
possible — a second `DELETE` of an already-tombstoned note still loads it, `MarkDeleted`
returns `false`, and the handler short-circuits before `SaveChangesAsync` instead of throwing.

---

## 3.5 Query handlers — flat Worker visibility

All three queries follow the same flat role rule — Admin sees Private + Team; Worker sees only
`Visibility == Team`. **There is no per-visit or per-client assignment scope.** Every query
pushes the filter to the DB via the `visibilities` parameter on the corresponding repository
method (step 2 §2.3) — the application layer never filters by visibility in memory. Each
handler resolves the set via a `GetAllowedVisibilities` extension on
`Invoices.Core.Models.Team.TeamMemberRole`:

```csharp
// File: Jobs/Jobs.Application/Notes/TeamMemberRoleExtensions.cs
internal static class TeamMemberRoleExtensions
{
    private static readonly IReadOnlyCollection<NoteVisibility> AdminVisibilities =
        [NoteVisibility.Private, NoteVisibility.Team];
    private static readonly IReadOnlyCollection<NoteVisibility> WorkerVisibilities =
        [NoteVisibility.Team];

    public static IReadOnlyCollection<NoteVisibility> GetAllowedVisibilities(this TeamMemberRole role) =>
        role == TeamMemberRole.Admin ? AdminVisibilities : WorkerVisibilities;

    // Note.EnsureCanBe…By takes the duplicate Jobs.Domain.Models.TeamMemberRole; this maps the
    // shared Invoices.Core.Models.Team.TeamMemberRole to it. Both enums carry the same values.
    public static Jobs.Domain.Models.TeamMemberRole ToJobsRole(this TeamMemberRole role) => …;
}
```

Used uniformly across `SaveNoteCommandHandler`, `DeleteNoteCommandHandler`, and the three
query handlers — `callerRole.GetAllowedVisibilities()`.

### `SyncNotesQueryHandler`

```text
Handle(query):
    sinceSequenceId = ParseCursor(query.Cursor)         # 0 when query.Cursor is null
    visibilities   = callerRole.GetAllowedVisibilities()

    # +1 row to detect HasMore without a second round-trip. The visibility filter MUST run at
    # DB level — an in-memory filter on a `pageSize+1` slice would skew `HasMore` and let the
    # cursor jump past Private rows the Worker never sees.
    rows    = notesRepository.GetChangedSince(account, sinceSequenceId, pageSize + 1, visibilities)
    hasMore = rows.Count > pageSize
    page    = hasMore ? rows.Take(pageSize) : rows

    items = page.Select(ToChangeItem)

    # NextCursor is non-null by contract on /notes/sync (see overview → DTOs):
    #   - page non-empty → cursor advances to page.Last().SequenceId
    #   - page empty     → cursor holds at sinceSequenceId so the client can resume cleanly
    lastSeq    = page.LastOrDefault()?.SequenceId ?? sinceSequenceId
    nextCursor = CursorSerializer.Serialize(new NotesSyncCursor(lastSeq))

    return SyncNotesResult(items, nextCursor, hasMore)
```

`NotesSyncCursor` is a single-field record (`SequenceId`) base64-encoded via the shared
`Jobs.Domain/Pagination/CursorSerializer`.

`ToChangeItem` emits `SyncChangeType.Deleted` (`Item = null`) for tombstones (`note.IsDeleted`)
and `SyncChangeType.Updated` for live rows (`Item = note.ToContract()`). Private tombstones are
filtered out by the DB-level `Visibility = Team` predicate for Workers — fine, since a Worker
never had a local copy of a Private note to reconcile (`Visibility` is immutable, so the row
was Private from creation).

### `GetNotesQueryHandler` and `GetNoteByIdQueryHandler`

```text
GetNotesQueryHandler.Handle(query):
    visibilities = callerRole.GetAllowedVisibilities()
    notes        = notesRepository.Find(account, query.ClientId, query.VisitId, visibilities)
    return GetNotesResult(notes.Select(ToContract).ToList())

GetNoteByIdQueryHandler.Handle(query):
    visibilities = callerRole.GetAllowedVisibilities()
    note         = notesRepository.GetById(account, query.NoteId, visibilities)
    return GetNoteByIdResult(note?.ToContract())            # controller maps null → 404
```

`Find` already excludes soft-deleted rows. `GetById` returns `null` for missing rows, rows in
another account, or rows whose `Visibility` is outside the caller's `visibilities` set. The
controller (step 4) maps a null result on `/{id}` to HTTP 404, matching the cross-account 404
contract: never leak the existence of a Private note to a Worker.

---

## 3.6 Domain ↔ contract mapping

**File:** `Jobs/Jobs.Application/Notes/NoteMappings.cs`.

```csharp
public static NoteContractDto ToContract(this Note note) => new(
    Id:         note.Id,
    Version:    note.Version,
    ClientId:   note.ClientId,                  // null for visit-notes by domain invariant
    VisitId:    note.VisitId,                   // null for client-notes by domain invariant
    Visibility: note.Visibility.ToContract(),
    Message:    note.Message,
    Author:     new NoteAuthorContractDto(note.Author.MasterUserId, note.Author.DisplayName),
    CreatedAt:  note.CreatedAt,
    UpdatedAt:  note.UpdatedAt,
    IsEdited:   note.UpdatedAt.HasValue);       // wire-only — recomputed every materialisation

public static NoteVisibilityDto ToContract(this NoteVisibility v) => v switch
{
    NoteVisibility.Private => NoteVisibilityDto.Private,
    NoteVisibility.Team    => NoteVisibilityDto.Team,
    _ => throw new InvalidOperationException($"Unsupported visibility '{v}'.")
};

public static NoteVisibility ToDomain(this NoteVisibilityDto v) => v switch
{
    NoteVisibilityDto.Private => NoteVisibility.Private,
    NoteVisibilityDto.Team    => NoteVisibility.Team,
    _ => throw new ArgumentException($"Unsupported visibility '{v}'.")
};
```

`Visibility` round-trips through small extension methods. `IsEdited` is **always** derived
from `UpdatedAt.HasValue` — there is no stored column and no separate flag to keep in sync.

---

## 3.7 Visit-delete cascade — wired into `UpsertJobCommandHandler`

**File:** `Jobs/Jobs.Application/Commands/UpsertJobCommandHandler.cs`.

The FK from `jobs.Notes.VisitId` to `jobs.Visits.Id` is `ON DELETE NO ACTION` (step 2 §2.2.5),
so when a visit is hard-deleted the application layer is responsible for soft-deleting the
linked notes **and** clearing their `VisitId` — otherwise the end-of-statement FK check on
the visit `DELETE` would fail.

In v1 the only path that hard-deletes visits is `Job.UpdateVisits()` inside
`UpsertJobCommandHandler` (visits present on `existingJob` whose `Id` is not in
`command.Visits`). No other endpoint, cleanup job, or admin tool deletes `jobs.Visits` rows
independently, so the cascade only needs one wire-up site.

The handler snapshots the visit ids on `existingJob` BEFORE `Job.UpdateVisits` mutates the
collection, computes the removed-set against `command.Visits`, and calls the bulk repository
helper BEFORE `SaveChangesAsync`:

```text
Handle(command):
    existingJob      = jobsRepository.GetJobForUpdate(...)
    existingVisitIds = existingJob?.Visits.Select(v => v.Id).ToHashSet() ?? []

    job = ApplyUpdates(existingJob, command, ...)        # internally runs Job.UpdateVisits

    removedVisitIds = existingVisitIds.Where(id => command.Visits.All(v => v.Id != id)).ToList()
    await notesRepository.SoftDeleteByVisitIds(command.AccountId, removedVisitIds, occurredAt, ct)

    await unitOfWork.SaveChangesAsync(ct)        # ExecuteUpdateAsync already issued the UPDATE
                                                 # on Notes; SaveChanges now emits DELETE on
                                                 # Visits within the same transaction.
```

`SoftDeleteByVisitIds` (step 2 §2.3) is a no-op when the removed set is empty (the common
case: most upserts edit/add visits, not remove them). When non-empty, it issues a single
`ExecuteUpdateAsync` that sets `VisitId = NULL, DeletedAt = COALESCE(DeletedAt, now)` on every
matching note in one round-trip — no entity load.

`OccurredAt` for the cascade uses the same `command.OccurredAt ?? UtcNow` as the rest of
`UpsertJobCommandHandler`, so the note tombstone time is consistent with the visit-delete
event time. `Job.Delete()` (full-job soft-delete) does **not** hard-delete visits — visits
stay in the DB hidden by the `!v.Job.IsDeleted` filter on `IVisitsRepository.GetVisitStatus` /
`VisitExists`, so no cascade is needed there.

---

## Cross-cutting notes

- **No new abstractions for cross-store reads.** The Mongo-side client lookup used by
  `CreateClientNote` is the existing `Invoices.Core` service — injected through the DI container.
- **Cancellation tokens** are passed through every async call; long-running queries on `/sync`
  honour the request's `CancellationToken`.
- **No separate transaction wrapping the in-memory orchestration + `SaveChangesAsync`.** The
  aggregate is fully in-memory after `SetMessage` / factory; the DB write is a single `SaveChanges`.
  The visit-delete cascade (§3.7) uses `ExecuteUpdateAsync` which auto-enlists in the ambient
  transaction EF opens for `SaveChangesAsync`, so the UPDATE and the subsequent DELETE share
  one atomic transaction — no explicit `BeginTransaction` is needed.
- **`SetMessage`, not `Edit`.** The aggregate method is `Note.SetMessage(...)` — the earlier
  name `Edit` was renamed during step 2 cleanup. Handlers use the new name.
- **One `TeamMemberRole` everywhere on the wire.** Commands / queries carry
  `Invoices.Core.Models.Team.TeamMemberRole` directly — there is no `NoteAuthorRoleDto`. The
  duplicate `Jobs.Domain.Models.TeamMemberRole` (used by `Note.SetMessage` /
  `Note.MarkDeleted` along with `Job` / `Team`) is bridged by the small `ToJobsRole`
  extension in `TeamMemberRoleExtensions`. The duplication is pre-existing legacy; we don't
  fix it as part of WEB-1470.

---

## Execution Checklist

| # | Task | Files |
|---|------|-------|
| 3.1 | `SaveNoteCommand` / `Result`, `DeleteNoteCommand` / `Result` | `Jobs.Contracts/Notes/Commands/*` |
| 3.1 | `GetNoteByIdQuery` / `Result`, `GetNotesQuery` / `Result`, `SyncNotesQuery` / `Result` | `Jobs.Contracts/Notes/Queries/*` |
| 3.1 | `NoteContractDto`, `NoteAuthorContractDto`, `NoteVisibilityDto` (commands/queries carry `Invoices.Core.Models.Team.TeamMemberRole` directly — no note-specific role DTO) | `Jobs.Contracts/Notes/NoteContractDto.cs` |
| 3.2 | `SaveNoteCommandHandler` (inline upsert orchestration + UoW save + visit-completion lock + visit/client factory helpers) | `Jobs.Application/Notes/Commands/SaveNoteCommandHandler.cs` |
| 3.4 | `DeleteNoteCommandHandler` (load → completion-lock → `MarkDeleted` folds role/author check + idempotency + tombstone, returns bool that gates `SaveChangesAsync`) | `Jobs.Application/Notes/Commands/DeleteNoteCommandHandler.cs` |
| 3.5 | `SyncNotesQueryHandler`, `GetNotesQueryHandler`, `GetNoteByIdQueryHandler` — all push the visibility filter to the DB via `callerRole.GetAllowedVisibilities()` | `Jobs.Application/Notes/*QueryHandler.cs` |
| 3.5 | `TeamMemberRoleExtensions.GetAllowedVisibilities` + `ToJobsRole` — role → visibility-set helper + `Invoices.Core` ↔ `Jobs.Domain.Models` role bridge | `Jobs.Application/Notes/TeamMemberRoleExtensions.cs` |
| 3.6 | `NoteMappings` (`ToContract` derives `IsEdited` from `UpdatedAt`; visibility round-trip) | `Jobs.Application/Notes/NoteMappings.cs` |
| 3.7 | Visit-delete cascade: snapshot existing visit ids, compute removed-set, call `INotesRepository.SoftDeleteByVisitIds` before `SaveChangesAsync` | `Jobs.Application/Commands/UpsertJobCommandHandler.cs` |
