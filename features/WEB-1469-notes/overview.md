# WEB-1469 — Notes on Visits and Clients — Backend Implementation Plan

Backend plan for short text notes attached to **clients** and **visits** so that office staff and workers keep operational context (gate codes, customer preferences, on-site findings, follow-ups) on the entities they already work with.

Related ClickUp tasks: [WEB-1469](https://app.clickup.com/t/WEB-1469) (initiative), [WEB-1470](https://app.clickup.com/t/WEB-1470) (BE), [WEB-1471](https://app.clickup.com/t/WEB-1471) (Web FE), [WEB-1472](https://app.clickup.com/t/WEB-1472) (QA), [FS-969](https://app.clickup.com/t/FS-969) (iOS initiative).

> **Implementation plan:** see [implementation/overview.md](implementation/overview.md) — step-by-step breakdown (domain, persistence, application, API, authorization, tests).

## Scope

**In scope** (Web Manager flow, v1):

- Two note kinds: client-level and visit-level.
- Client notes carry an immutable visibility — `Private` (manager only) or `Team` (visible to every worker in the account, regardless of visit assignment).
- Visit notes are always `Team`.
- Five endpoints on one `NotesController`:
  - `GET /api/notes/sync?cursor=…&limit=…` — cursor-paginated change feed (mirrors `GET /api/v3/jobs/sync`). The mobile client's primary read path; surfaces both updates and tombstones.
  - `GET /api/notes/{noteId}` — single-row fetch, used by mobile when a sync item points at a note the local store doesn't have (or when reconciling a conflict).
  - `GET /api/notes/all?clientId=…|visitId=…` — Web-only flat list (no cursor, no tombstones). Kept because the Web Manager Client/Visit pages render a simple snapshot, not an offline-replay stream.
  - `PUT /api/notes` — single create-or-update, body carries the id (no id in URL).
  - `DELETE /api/notes/{noteId}` — soft-delete.
  Same API for Web Manager and Worker app; Web mostly uses `/all` + `PUT` + `DELETE`, mobile mostly uses `/sync` + `/{id}` + `PUT` + `DELETE`.
- 1000-character `Message` cap, server-enforced.
- `edited` indicator preserving original `CreatedAt`.
- Frozen author display name (so workers removed from a visit stay attributed on their old notes).
- Single-manager-per-account authorization; manager moderates worker notes via delete (no edit).
- **Visit-completion lock for Worker.** A Worker can `PUT` (create) new visit-notes on a completed visit any time, but cannot `PUT` (edit) or `DELETE` an existing note once the linked visit is marked completed. Admin (Manager) is not subject to this lock — they can still moderate-by-delete post-completion. Server checks `Visit.Status == Completed` directly (the Visit aggregate has no separate `CompletedAt` timestamp — `Status` is the canonical signal).

**Out of scope** (v1):

- Pinning / starred notes.
- Photos or file attachments on notes — kept as a separate proof-of-work concept.
- Activity feed surfacing note operations.
- Soft delete and recovery.
- Multiple managers per account.
- Job-level aggregated notes view.
- Search, filtering, sorting beyond newest-first.
- @-mentions, threads, reactions.

## High-level approach

A single table `jobs.Notes`, reached through `JobsDbContext` (same `jobs` schema as `jobs.Jobs` and `jobs.Visits` — no schema override needed). Each row carries exactly one anchor: either `VisitId` (visit-note — FK to `jobs.Visits`) or `ClientId` (client-note — cross-store reference to Mongo `ManageableClient`). The two anchors are mutually exclusive in v1; the "kind" of note is just whichever column is non-null. Co-locating with the Jobs domain (instead of a neutral `invoices` schema) keeps the FK same-schema and avoids a second schema in the migration history; the cross-store reference to a Mongo client document stays unchanged either way.

| Aspect | Value |
|---|---|
| Table | `jobs.Notes` |
| Anchor | Exactly one per row: Postgres `jobs.Visits` (via nullable `VisitId` FK) **or** Mongo `ManageableClient` (via nullable `ClientId` value reference). Mutually exclusive in v1. |
| Visibility | enum `{ Private, Team }`, immutable. Visit-Private is rejected by the domain factory `Note.CreateForVisit` (not by a DB CHECK — see [Data model](#data-model)). |
| Controller | A single `NotesController` exposing all `/api/notes/*` routes (see [Endpoints](#endpoints)). |
| Audit | No audit log in v1. Notes are a standalone resource — they do not write to `JobEvents` or any other audit channel. If audit is needed later, add a dedicated `NotesEvents` table without touching the Jobs domain. |

Cross-cutting fields on every row: `Message` (1000-char cap), the frozen-author pair (`AuthorMasterUserId`, `AuthorDisplayName`), `Version` for optimistic concurrency (matches `jobs.Jobs.Version`), `UpdatedAt` (non-null after the first edit — also the source of truth for the on-wire `IsEdited` flag), `DeletedAt` for soft-delete, and a caller-supplied `Id` for optimistic UI. Author's role is **not** persisted — all authorization checks use the **caller's** current role from Tofu.Auth at request time. `CreatedAt`, `UpdatedAt`, and `DeletedAt` are sourced from the `XA-Client-Event-Ms` request header when present (offline-replay: the user-action time, not the server-receipt time); they fall back to `now()` when the header is missing.

**`IsEdited` is a wire-only flag, not a stored column.** Inbound on `PUT /api/notes` (UPDATE path) it triggers the server to stamp `UpdatedAt`; outbound on every `NoteDto` it is computed as `UpdatedAt.HasValue`. The persisted truth is the timestamp; the boolean is just a convenience view of it on the wire.

**Two counters, two distinct jobs.** `SequenceId` (long, server-internal, ordered by a Postgres sequence) drives the `/sync` cursor and is **never exposed on the wire**. `Version` (int, exposed on `NoteDto`) is the per-row optimistic-concurrency token clients receive and echo back on `PUT /api/notes`. This mirrors the established pattern on `Job` / `Invoice` / `Estimate` and matches the mobile sync framework's expectation of a "version from server response" on each entity.

## Data model

### `jobs.Notes`

| Column | Type | Notes |
|---|---|---|
| `Id` | `uuid` NOT NULL | PK, `ValueGeneratedNever`. Caller-supplied (UUID v4 generated by the client) — see [Optimistic UI](#optimistic-ui). |
| `SequenceId` | `bigint` NOT NULL | Monotonic per-row version, sourced from a Postgres sequence `jobs."Notes_SequenceId_seq"`. A `BEFORE INSERT OR UPDATE` trigger (or `OnSaveChanges` interceptor) sets `SequenceId = nextval(seq)` on every write — including soft-delete (`DeletedAt` set) and edit. The `GET /api/notes/sync` cursor is `(SequenceId)`. Mirrors `jobs.Jobs.SequenceId` (see `Src/Jobs/Jobs.Infrastructure/Database/Migrations/20260129204322_WEB-744_Jobs_Init.cs`). |
| `AccountId` | `text` NOT NULL | Tenant id (matches the `string AccountId` flowing through `BaseController` and gateway DTOs). |
| `ClientId` | `text` NULL | `ManageableClient.ClientId` value (`string`, see `Invoices.Core/Models/Clients/ManageableClient.cs`). No FK — cross-store reference. Set only on client-notes (rows where `VisitId IS NULL`); always null on visit-notes. Never auto-resolved server-side. |
| `VisitId` | `uuid` NULL | FK to `jobs.Visits.Id`. Set only on visit-notes (rows where `ClientId IS NULL`); always null on client-notes. The two anchors are mutually exclusive in v1. |
| `Visibility` | `smallint` NOT NULL | `Private = 1`, `Team = 2`. Immutable after creation. Visit-notes are always `Team` — enforced by the domain factory, not by a DB CHECK. |
| `Version` | `integer` NOT NULL DEFAULT 0 | Optimistic-concurrency token, mirrors `jobs.Jobs.Version`. EF maps it with `IsConcurrencyToken().ValueGeneratedOnAddOrUpdate()`; a `BEFORE UPDATE` trigger does `NEW.Version = OLD.Version + 1` on every UPDATE. Returned on every `NoteDto`; clients echo it back on `PUT /api/notes` for an existing note — mismatch surfaces as `VersionMismatchException` (translated to HTTP 200 + `ErrorCode.VersionMismatch` with `{ActualVersion, SubmittedVersion}` by `ApiExceptionHandlingMiddleware`). |
| `Message` | `varchar(1000)` NOT NULL | Upper bound enforced by the column type. Min-length 1 (after trim) is enforced by the domain factories — there is no DB CHECK for it. |
| `AuthorMasterUserId` | `text` NOT NULL | `AuthenticationInfo.MasterUser.Id`. |
| `AuthorDisplayName` | `text` NOT NULL | Frozen at creation. |
| `CreatedAt` | `timestamptz` NOT NULL | Default `now()`, immutable. |
| `UpdatedAt` | `timestamptz` NULL | Set on edit; null otherwise. Doubles as the "edited" indicator — `UpdatedAt IS NOT NULL` means the row was edited at least once. |
| `DeletedAt` | `timestamptz` NULL | **Soft-delete tombstone.** Null = live; non-null = deleted, hidden from all reads. `DELETE` endpoints set this column; rows are never physically removed by the application. |

Indexes:

- PK `(Id)` — covers `GET /api/notes/{noteId}`, `PUT /api/notes` (load-by-id), and `DELETE /api/notes/{noteId}`.
- `(AccountId, SequenceId)` — covers `GET /api/notes/sync`. **No** `WHERE DeletedAt IS NULL` partial filter: tombstones (rows with `DeletedAt != null`) must flow through the cursor exactly once so the client can drop them locally.
- `(AccountId, ClientId, CreatedAt DESC) WHERE ClientId IS NOT NULL AND VisitId IS NULL AND DeletedAt IS NULL` — covers `GET /api/notes/all?clientId=…` (single scan returning only client-level live rows for the client). `ClientId IS NOT NULL` keeps the partial index narrow now that the column is nullable.
- `(VisitId, CreatedAt DESC) WHERE VisitId IS NOT NULL AND DeletedAt IS NULL` — covers `GET /api/notes/all?visitId=…` (single scan returning just that visit's live notes).

Account-wide reads (`GET /api/notes/all` with no filter) fall back to a sequential scan — acceptable for the rare admin-export case.

**Visit-delete behaviour.** The FK to `jobs.Visits` is `ON DELETE NO ACTION`; when a Visit is deleted, a Postgres trigger on `jobs.Visits` soft-deletes its notes — `UPDATE jobs.Notes SET DeletedAt = now() WHERE VisitId = OLD.Id AND DeletedAt IS NULL` — so the sequence trigger bumps each row's `SequenceId`, and mobile clients pick up the tombstones on the next `/sync` call. Without this conversion, hard-cascade would leave mobile with orphan rows it can't reconcile.

`Client` itself stays in MongoDB; the cross-store reference on `ClientId` does not cascade. `ClientsController.DeleteClient` already chooses between **archive** (`ArchiveClient`, sets `ManageableClient.ArchivedAt`) when jobs reference the client and **delete** (`_clientsService.DeleteClient`) when they do not — `Notes` rows are not affected by either path because there is no FK to cascade through. Visit-level notes for the same client also remain in place; their `VisitId` FK is unaffected by client lifecycle. (Mobile clients that locally cache notes for archived/deleted clients reconcile via the next `/sync` call — see [Sync](#sync).)

### Migration

```powershell
dotnet ef migrations add INVC-1469_AddNotesTable `
    -c JobsDbContext `
    -p "Invoices.Backend\Src\Jobs\Jobs.Infrastructure" `
    -s "Invoices.Backend\Src\Invoices.Api" `
    -o Migrations
```

Single migration creates: the `jobs.Notes` table, the `jobs."Notes_SequenceId_seq"` sequence, the `BEFORE INSERT OR UPDATE` trigger that assigns `SequenceId = nextval(seq)` on every write, the `BEFORE UPDATE` trigger that does `NEW.Version = OLD.Version + 1` on the `Version` column (mirrors `jobs.increment_job_version`), the `ON DELETE` trigger on `jobs.Visits` that soft-deletes child notes, the four indexes (PK + sync + two `/all` partial indexes), and the FK to `jobs.Visits` (`ON DELETE NO ACTION`). No CHECK constraints — the anchor-XOR and visit-note-is-Team invariants are enforced by the domain factories, and the message-length cap is enforced by the `varchar(1000)` column type. No `EnsureSchema` call — the `jobs` schema already exists from `WEB-744_Jobs_Init`.

## Domain integration

A single entity `Note` (`Src/Jobs/Jobs.Domain/Models/Note.cs`). EF configuration in `Src/Jobs/Jobs.Infrastructure/Database/Configurations/NoteConfiguration.cs` — autoscanned by `JobsDbContext.OnModelCreating` (`ApplyConfigurationsFromAssembly`).

Notes are a **standalone resource**: no `Visit.Notes` navigation, no domain methods on `Visit` / `Job`, no `JobEvents` writes, no `Job.Version` bump. All read and write paths go through `INotesRepository` (`Src/Jobs/Jobs.Application/Notes/`).

The `Note` aggregate owns its own invariants — DDD-style, private setters, mutation through methods. The command handler just dispatches; the entity decides:

```csharp
public sealed class Note
{
    public Guid Id { get; }
    public long SequenceId { get; private set; }    // set by DB trigger on every INSERT/UPDATE — server-internal, NOT on the wire
    public int Version { get; private set; }        // set by DB trigger on UPDATE (NEW.Version = OLD.Version + 1); on wire as the optimistic-concurrency token
    public string AccountId { get; private set; }
    public string? ClientId { get; private set; }   // optional anchor; set only when the caller passed clientId explicitly
    public Guid? VisitId { get; }                   // optional anchor; immutable after creation
    public NoteVisibility Visibility { get; }       // immutable after creation
    public string Message { get; private set; }
    public NoteAuthor Author { get; }               // frozen at creation (MasterUserId + DisplayName) — role is not stored
    public DateTimeOffset CreatedAt { get; }
    public DateTimeOffset? UpdatedAt { get; private set; }
    public DateTimeOffset? DeletedAt { get; private set; }

    private Note(...) { ... }                       // EF only

    public static Note CreateForVisit(Guid id, string accountId, Guid visitId,
                                      string message, NoteAuthor author)
    {
        // Forces Visibility = Team (v1 has no other option for visit-notes).
        // ClientId stays null — visit-notes have only the visit anchor.
        // Validates message length, requires VisitId.
        ...
    }

    public static Note CreateForClient(Guid id, string accountId, string clientId,
                                       NoteVisibility visibility, string message, NoteAuthor author)
    {
        // Allows Private or Team, validates message length, VisitId stays null.
        ...
    }

    public void Edit(string message, string editorMasterUserId)
    {
        // Validates message length, enforces author-only edit, sets UpdatedAt = now.
        // Visibility is NOT a parameter — immutable by design.
        ...
    }

    public void MarkDeleted() => DeletedAt ??= DateTimeOffset.UtcNow;

    public void ValidateVersion(int expectedVersion)
    {
        // Throws VersionMismatchException(actual = Version, submitted = expectedVersion)
        // when the client's Version differs from the row's current Version.
        // Mirrors Job.ValidateVersion (Src/Jobs/Jobs.Domain/Models/Job.cs).
        ...
    }
}
```

All invariants — `Visibility = Team` when `VisitId != null`, `Message` length 1..1000 (after trim), immutable `Visibility`, author-only edit, idempotent delete — live inside these methods and throw `ArgumentException` / `DomainException` on violation (translated to `400` by middleware). The DB layer carries no CHECK constraints — the `varchar(1000)` column type bounds the upper end of `Message`, and every other invariant is domain-only.

The handler's job is narrow: load the existing `Note` (or call the correct factory for a new id), call `ValidateVersion(body.Version)` on the update path (no version check on create — there's no row to race against), invoke `Edit` / `MarkDeleted`, and persist via `INotesRepository`. `Note.Edit`, `Note.MarkDeleted`, and the create factories all take an optional `now` / `createdAt` parameter that the handler populates from `BaseController.GetClientEventTime()` (driven by the `XA-Client-Event-Ms` request header). This means offline mobile writes carry their original user-action time through to `CreatedAt` / `UpdatedAt` / `DeletedAt`, not the server-receipt time. EF's `IsConcurrencyToken` provides a second defence — a concurrent edit between the in-memory check and `SaveChanges` surfaces as `DbUpdateConcurrencyException`, which the same middleware maps to `ErrorCode.VersionMismatch`. For visit-notes the handler also reads the linked `Visit` once:

- `Visit.Status == Completed` — checked on **edit and delete** paths for Worker callers. If the visit is completed and the caller's role is `Worker`, the handler short-circuits with `403`. Admin / Manager is exempt. Create (`PUT` with an unknown id) is always allowed regardless of completion state — this matches the PRD rule "Worker can ADD anytime, but cannot EDIT/DELETE after completion."

The server does NOT denormalise `Visit.JobId` or `Visit.ClientId` onto the note — both anchors come from the caller's payload only, and `JobId` is not stored at all.

If audit becomes a requirement later, a dedicated `jobs.NoteEvents` table can be added next to `jobs.Notes` without touching the rest of the Jobs domain. Not in v1.

### Loading strategy

All read paths go through `INotesRepository` directly — no other aggregate is loaded.

- `GET /api/notes/sync` issues `WHERE AccountId = @account AND SequenceId > @cursor ORDER BY SequenceId LIMIT @limit`, projects each row into `SyncChangeItemDto<NoteDto>` (`Change = Deleted, Item = null` for soft-deleted rows, `Change = Updated` otherwise), and returns the new cursor (`SequenceId` of the last row). See [Sync](#sync) for the full envelope.
- `GET /api/notes/{noteId}` is a PK lookup.
- `GET /api/notes/all` runs the filtered query keyed on the partial indexes — same shape as today.

Visit / Job read paths (`GET /jobs/{id}`, `GET /jobs/paged`, `GET /jobs/sync`) keep their **current shape unchanged** — they do not include notes in the payload. Notes are read only via the `/api/notes/*` routes above.

## Endpoints

All routes live on a single `NotesController` under API version `v3` (`MapToApiVersion("3.0")`) — same pattern as `JobsController`. Both Web Manager and Worker app use these routes; usage differs (Web is `/all`-first, mobile is `/sync`-first), but the surface is shared.

```
# === Cursor-based change feed — primary mobile read path. ===
# Mirrors GET /api/v3/jobs/sync. Returns updates + tombstones in one envelope.
GET     /api/notes/sync
        ?cursor={base64}               # opaque cursor; omit for a fresh full sync
        ?limit={int}                   # page size (default 100, max 500)
        # Authorization: flat role filter (Admin: Private+Team; Worker: every Team note
        # in the account — no assignment scope). Soft-deleted rows appear once as
        # tombstones (Change="deleted", Item=null) then are excluded from later
        # pages once the client's cursor passes their SequenceId.

# === Single-row fetch — used by mobile to repair stale local state. ===
GET     /api/notes/{noteId}            # 200 + NoteDto live or tombstone; 404 cross-account

# === Web-only flat list — kept because Web doesn't need cursor pagination. ===
GET     /api/notes/all
        ?clientId={string}             # filter to this client's client-level notes (VisitId IS NULL); ClientId is a string (Mongo ManageableClient.ClientId), not a GUID
        ?visitId={guid}                # filter to this visit's notes (VisitId = {guid})
        # clientId and visitId are mutually exclusive — pass exactly one, or pass
        # neither for an account-wide read (admin / export path). Passing both → 400.
        # Soft-deleted rows are always excluded (no tombstones on this route).
        # No pagination in v1 — the response is the full filtered list.

# === Write — single upsert; the id lives in the request body, not the URL. ===
PUT     /api/notes                     # body: SaveNoteDto (caller-supplied Id + Version)
                                       # create-if-new (Version ignored), update-if-exists
                                       # (server validates Version against current row).
                                       # Version mismatch → HTTP 200 + ErrorCode.VersionMismatch.
                                       # Idempotent on retry — replay yields the same row state.

# === Soft-delete tombstone — sets DeletedAt and bumps SequenceId. ===
DELETE  /api/notes/{noteId}
```

Notes:

- One set of routes for visit-notes and client-notes — the `VisitId` field on the body / row discriminates. Mobile and Web call the same routes.
- Web Client page preview: `GET /api/notes/all?clientId=X` — returns the client-level live rows (`VisitId IS NULL`) for that client, role-filtered. FE groups by `Visibility` and slices first 4 per section. Visit-level notes are not loaded here.
- Web Visit page: `GET /api/notes/all?visitId=Y` — visit's own live notes only.
- Worker visit screen (mobile, online): same `?visitId=Y` + parallel `?clientId=X` for the client-level Team notes the worker wants in context. (Offline-first mobile uses `/sync` instead — see [Sync](#sync).) Workers can read these regardless of visit assignment.
- Mobile cold start / catch-up: `/sync` with no cursor → walk pages until `HasMore=false`. Cursor is persisted locally; subsequent sessions resume from where they left off.

### DTOs

```csharp
public enum NoteVisibility { Private = 1, Team = 2 }

// Single Note entity at the DTO level too — exactly one anchor per row: `VisitId` set =
// visit-note (ClientId is null), `ClientId` set = client-note (VisitId is null). The wire shape
// reflects whichever the caller used on the create PUT.
public sealed record NoteDto(
    Guid Id,
    int Version,                    // optimistic-concurrency token; clients echo back on PUT (mirrors JobDto.Version)
    string? ClientId,               // populated for client-notes; null on visit-notes
    Guid? VisitId,                  // populated for visit-notes; null on client-notes
    NoteVisibility Visibility,      // visit-notes are always Team in v1 (enforced by Note.CreateForVisit factory)
    string Message,
    AuthorDto Author,
    DateTimeOffset CreatedAt,
    DateTimeOffset? UpdatedAt,      // server-set timestamp of the last edit; null = never edited
    bool IsEdited);                 // wire-only — computed `UpdatedAt.HasValue`. NOT a stored column. DeletedAt is NOT on the wire: soft-deleted rows surface via `SyncChangeType.Deleted` on `/sync`.

// Write body — used by PUT /api/notes. Caller-supplied Id; server validates invariants and
// persists via Note.Edit / CreateForVisit / CreateForClient.
// CreatedAt / UpdatedAt come from the XA-Client-Event-Ms request header (offline-replay
// support — see HeaderKeys.ClientEventTimeMs). When the header is absent, the server falls
// back to its current UTC clock.
public sealed record SaveNoteDto(
    Guid Id,                        // caller-supplied (UUID v4 generated by client for optimistic UI)
    int Version,                    // 0 on create (defaults to 0 if missing — int, not required, matches JobUpsertRequestDto.Version); current row Version for update
    string? ClientId,               // anchor for a client-note; mutually exclusive with VisitId
    Guid? VisitId,                  // anchor for a visit-note; mutually exclusive with ClientId
    NoteVisibility Visibility,      // for client-notes: Private or Team; visit-notes are always Team (server-enforced)
    string Message,
    bool IsEdited = false);         // wire trigger — when true on an UPDATE path, the server stamps `UpdatedAt` (from `XA-Client-Event-Ms` or `now()`). Ignored on the CREATE path. NOT stored as a column — the persisted truth is `UpdatedAt`.

// Author's role is NOT exposed — the caller's current role (from Tofu.Auth) drives every
// authorization decision at request time; persisting the snapshot would only add a stale copy.
public sealed record AuthorDto(
    string MasterUserId,
    string DisplayName);            // frozen at creation
```

**Reads (response envelopes).** `GET /api/notes/all` returns `GetNotesResponseDto { Items: IReadOnlyList<NoteDto> }` — the full list of matching live notes. `GET /api/notes/{noteId}` returns a bare `NoteDto`. `GET /api/notes/sync` reuses the standard `SyncResponseDto<NoteDto>` envelope from `Src/Invoices.Api/Dto/SyncResponseDto.cs` (same shape as `/api/v3/jobs/sync`):

```csharp
public sealed record GetNotesResponseDto(
    IReadOnlyList<NoteDto> Items);

// Reused from Src/Invoices.Api/Dto/SyncResponseDto.cs (already used by /jobs/sync, /invoices/sync).
public class SyncResponseDto<T>
{
    public IReadOnlyList<SyncChangeItemDto<T>> Items { get; init; } = [];
    public string? NextCursor { get; init; }            // base64-encoded NotesSyncCursor; null when no more pages
    public bool HasMore { get; init; }
    public int DelayNextRequestInSeconds { get; init; } // 0 in v1; reserved for back-pressure
}

// Reused from Src/Invoices.Api/Dto/SyncChangeItemDto.cs.
public class SyncChangeItemDto<T>
{
    public string ItemId { get; init; } = "";          // note Id as string (matches existing sync DTO contract)
    public SyncChangeType Change { get; init; }        // Updated = 1, Deleted = 2 — StringEnumConverter on the wire
    public T? Item { get; init; }                       // NoteDto for Updated; null for Deleted (tombstone)
}

// Cursor record — base64 JSON, parsed/emitted by Src/Jobs/Jobs.Domain/Pagination/CursorSerializer.cs.
public sealed record NotesSyncCursor(long SequenceId);

// Response invariant: `NextCursor` on the wire is ALWAYS a non-null base64 string. Even when
// the page is empty (no more rows), the server still emits a cursor pointing at the last
// observed SequenceId so the client can resume from the same position next time. The shared
// `SyncResponseDto<T>.NextCursor` type stays nullable for backward compatibility with other
// sync endpoints, but for `/api/notes/sync` clients can rely on it being non-null. The
// internal `SyncNotesResult.NextCursor` is typed as `string` (non-null) to make this explicit.
```

### Optimistic UI

Every write uses a caller-supplied `Id` (UUID v4 generated by the client). The frontend renders the new note in its list immediately with the local Id, then fires `PUT /api/notes` (single, with the id in the body). The server treats unknown Ids as create and known Ids as update — idempotent on retry (mobile offline replay just re-sends; the second hit yields the same row state). Mirrors the existing `Attachment.Id` precedent (`ValueGeneratedNever`).

### Preview on the Web Client page

The Web Manager Client page renders two preview sections (Private, Team), up to 4 notes each. FE makes one call:

```
GET /api/notes/all?clientId={id}
```

`?clientId=…` returns only the client-level rows (`VisitId IS NULL`) for this client — visit-level notes are addressed separately via `?visitId=…`. FE groups by `Visibility` client-side and slices first 4 per section. "Show all" simply expands the local list (already loaded) — no second request.

If a client accumulates hundreds of client-level notes the FE still loads them all in one call. v1 accepts this; if it becomes a problem, cursor/limit can be added to the same endpoint without contract break (the response is already a wrapper, see DTO above).

The partial index `(AccountId, ClientId, CreatedAt DESC) WHERE ClientId IS NOT NULL AND VisitId IS NULL AND DeletedAt IS NULL` covers the query (single index scan).

### Worker visit screen reads

Worker app on the visit screen needs the visit's own notes plus inherited client-level Team notes. Two parallel calls:

```
GET /api/notes/all?visitId={visitId}     # the visit's own notes (visit-level only)
GET /api/notes/all?clientId={clientId}   # the visit's client — FE keeps the client-level rows
```

Each call is a single indexed scan: `?visitId` uses `(VisitId, CreatedAt DESC) WHERE VisitId IS NOT NULL AND DeletedAt IS NULL`; `?clientId` uses `(AccountId, ClientId, CreatedAt DESC) WHERE ClientId IS NOT NULL AND VisitId IS NULL AND DeletedAt IS NULL`. Both calls are role-filtered server-side (Worker → Team only). The Web Manager Visit page uses the same `?visitId` call; per Business spec §3.3 it shows only the visit's own notes, so the parallel `?clientId` request is Worker-app-only.


### Validation and errors

Applies to `PUT /api/notes`:

- Empty / whitespace-only `Message` after trim → `400`.
- `Message.Length > 1000` → `400`.
- `body.Id` missing or not a valid UUID v4 → `400`.
- Anchor rule: exactly one of `ClientId` / `VisitId` must be non-null on create. Sending both → `400`; sending neither → `400`. (No auto-resolution.)
- `ClientId` supplied but the referenced `ManageableClient` does not exist (missing entirely or outside the caller's `AccountId`) → HTTP 200 + `ErrorCode.NotFound` (`EntityNotFoundException`, mapped by `ApiExceptionHandlingMiddleware`).
- `VisitId` supplied but the referenced visit does not exist (missing entirely, outside the caller's `AccountId`, or its parent job is soft-deleted) → HTTP 200 + `ErrorCode.NotFound`. Same shape as the `ClientId` case above.
- Visit-note (`VisitId != null`) with `Visibility != Team` → `400` (`Note.CreateForVisit` rejects this — visit-notes always use `Team`; the API DTO field is ignored on this path).
- Update attempt that changes `Visibility`, `ClientId`, or `VisitId` on an existing row → `400` (immutable identity).
- Edit on a note authored by someone else, caller is not Admin → `403`.
- Cross-account update (`body.Id` exists but belongs to another `AccountId`) → `404` (not `403`, to avoid leaking existence).
- Worker editing a visit-note whose linked `Visit.Status == Completed` → `403` (visit-completion lock — see [Scope](#scope)). Admin is exempt. Creating a brand-new note on a completed visit is allowed for both roles.
- Update with `body.Version` not matching the stored row's `Version` → HTTP 200 + `ErrorCode.VersionMismatch` with payload `{ ActualVersion, SubmittedVersion }`. Same envelope as Jobs version-mismatch responses. `body.Version` is ignored on create (unknown id).

`GET /api/notes/{noteId}`:

- Cross-account / missing id → `404` (no `EntityNotFoundException` magic — straight 404, matches sync semantics).

`GET /api/notes/sync`:

- Malformed `cursor` (not base64, not deserialisable into `NotesSyncCursor`) → `400`.
- `limit < 1` or `limit > 500` → `400`.

`DELETE /api/notes/{noteId}`:

- Cross-account note → `404`.
- Worker deleting another user's note → `403`.
- Worker deleting any visit-note whose linked `Visit.Status == Completed` → `403` (visit-completion lock — Admin is exempt).
- Already-deleted note → `200` (idempotent; no-op).

## Authorization

The account has a single Admin (Manager in product wording) in v1. Roles come from the existing Tofu.Auth `RoleLevel` enum (`Admin = 1`, `Worker = 2`) — see [`Backend/Services/Tofu.Auth/Roles_and_Tenants.md`](../../Backend/Services/Tofu.Auth/Roles_and_Tenants.md).

**Dedicated permission keys for notes** are added to `Src/Tofu.Permissions.Shared/Domain/PermissionKeys.cs`, mirroring the structure of `PermissionKeys.Client`:

```csharp
public static class Note
{
    public const string View   = "note.view";    // GET /api/notes/sync, GET /api/notes/{id}, GET /api/notes/all
    public const string Manage = "note.manage";  // PUT /api/notes + DELETE /api/notes/{id}
}
```

These keys are seeded into the role-permission map in `Tofu.Auth.Backend` next to the existing role-permission rows (Admin gets both, Worker gets `Note.View` + `Note.Manage` so they can author and edit/delete their own visit notes — own-vs-others moderation is enforced inside the controller, not by a separate permission).

**Pricing tiers:** Notes are available on **all plans** — no plan-tier gating, no paywall. The controllers carry only the standard `[AuthorizeAction(PermissionKeys.Note.View|Manage)]` decorators; nothing extra stacks on top. If the caller is unauthenticated or lacks the permission, the response is the usual `403`, no special "paywall" shape.

All routes on `NotesController` share the same decorators per HTTP verb:

- `GET /api/notes/sync`, `GET /api/notes/{noteId}`, `GET /api/notes/all` — `[AuthorizeAction(PermissionKeys.Note.View)]`.
- `PUT /api/notes`, `DELETE /api/notes/{noteId}` — `[AuthorizeAction(PermissionKeys.Note.Manage)]`.

Beyond the permission keys, the controller layer enforces note-content authorization that the permission system can't express:

| Action | Admin (Manager / Web) | Worker (Worker app) | Notes |
|---|---|---|---|
| `GET /api/notes/sync` / `/all` — Private rows | Yes | No | `Visibility` is not a query parameter — the server filters by the caller's role only: Admin gets `Private` + `Team`, Worker gets `Team`. |
| `GET /api/notes/sync` / `/all` — Team rows | Yes | Yes — every Team note in the account, regardless of visit assignment or client | The visibility model is flat: any Team note in the tenant is readable by any Worker. No assigned-visit / assigned-client scope is applied. |
| `GET /api/notes/{noteId}` | Yes (any note in account) | Yes if `Visibility = Team`; otherwise `404`. | Single-row PK fetch; used to repair stale local state. |
| `PUT /api/notes` create or update **client-note** (`VisitId == null`) | Yes | No (`403`) | Workers don't author client-notes in v1. |
| `PUT /api/notes` create or update **visit-note** (`VisitId != null`) — note is own | Yes | Yes | Caller's `MasterUserId` must match the note's `AuthorMasterUserId` on update; create is always allowed for any authenticated Worker. |
| `PUT /api/notes` update other's note | No (`403`) | No (`403`) | Admin moderates worker notes via delete only, not edit (PRD §3.4). Only the author edits text. |
| `PUT /api/notes` **create new** visit-note when `Visit.Status == Completed` | Yes | Yes | Worker can ADD notes after completion (e.g., to capture a remembered detail). |
| `PUT /api/notes` **edit existing** visit-note when `Visit.Status == Completed` | Yes | No (`403`) | Visit-completion lock — see [Scope](#scope). |
| `DELETE /api/notes/{id}` — any note | Yes (own + others, including worker notes for moderation) | Own only — `AuthorMasterUserId == caller`. Anything else → `403`. | |
| `DELETE /api/notes/{id}` on visit-note when `Visit.Status == Completed` | Yes (moderation always available) | No (`403`) | Visit-completion lock — Admin is exempt. |

Worker visibility is intentionally flat: assignment to a visit is not a prerequisite for reading its Team notes. Frozen `AuthorDisplayName` keeps historical attribution stable even if the original author leaves the team.

## Lifecycle

| Trigger | Behaviour |
|---|---|
| `Visit` deleted | Visit-notes (rows with this `VisitId`) are **soft-deleted by a Postgres `BEFORE DELETE` trigger** on `jobs.Visits` — `VisitId` is cleared and `DeletedAt` is stamped with `COALESCE(DeletedAt, now())`. The notes show up as tombstones in `/sync` exactly once. The FK is `ON DELETE NO ACTION`; there is no hard-cascade. Client-notes for the same client (`VisitId IS NULL`) are untouched. |
| Client archived (`ManageableClient.ArchivedAt` set; `ClientsController.DeleteClient` path) | All `Notes` rows for this `ClientId` are untouched (no FK to cascade through). Client card is hidden from the UI list, so the client-side section is no longer reachable through the standard navigation; data is preserved. Visit-notes for this client remain visible from their visit pages. |
| Visit assignee change | Notes are not touched. The original author's `AuthorDisplayName` stays frozen on every row they wrote; Team notes remain visible to all Workers regardless of who is currently assigned. |

> In practice clients are always archived, never hard-deleted (`_clientsService.DeleteClient` is the rare path for clients with zero referencing jobs). If it does happen, the Mongo `ManageableClient` document is gone but `Notes` rows still survive with their original `ClientId` / `AccountId` — no FK to cascade through and no app-side cleanup is needed.

## Sync

Notes have their **own** cursor-based sync feed; they are not folded into `/jobs/sync`. Jobs sync payloads stay unchanged — no `Visit.Notes[]`, no `Job.Notes[]`, no `Job.Version` bump on note writes.

### Endpoint contract

```
GET /api/notes/sync?cursor={base64}&limit={int}
```

Returns the standard `SyncResponseDto<NoteDto>` envelope (see [DTOs](#dtos)). Mirrors `GET /api/v3/jobs/sync` (`Src/Invoices.Api/Controllers/JobsController.cs:108-150`) — same query params, same envelope, same `SyncChangeType { Updated = 1, Deleted = 2 }`.

### Server-side query

```csharp
// In NotesRepository.SyncAsync(string accountId, long? sinceSequenceId, int limit)
var rows = await dbContext.Notes
    .Where(n => n.AccountId == accountId
             && (sinceSequenceId == null || n.SequenceId > sinceSequenceId))
    .OrderBy(n => n.SequenceId)
    .Take(limit + 1)                                   // +1 to detect HasMore
    .Select(n => new { n.Id, n.SequenceId, n.DeletedAt, n /* full row */ })
    .ToListAsync();

var hasMore = rows.Count > limit;
var page    = rows.Take(limit).ToList();
var items   = page.Select(r => r.DeletedAt == null
    ? SyncChangeItemDto<NoteDto>.Updated(r.Id, ToDto(r.n))
    : SyncChangeItemDto<NoteDto>.Deleted(r.Id));
var nextCursor = page.Count > 0
    ? CursorSerializer.Encode(new NotesSyncCursor(page[^1].SequenceId))
    : cursor;                                          // unchanged if page is empty
```

A flat role filter wraps this query — Workers get every `Team` row in the account, Admins get `Private + Team`. There is no per-visit / per-client assignment scope to apply. The `(AccountId, SequenceId)` index covers the scan.

### Tombstones and visibility transitions

Soft-deleted rows surface once as `{ Change: Deleted, Item: null, ItemId: <noteId> }`. After the client's cursor passes their `SequenceId` they are not re-emitted.

Hard-delete via FK cascade is not used — the `ON DELETE` trigger on `jobs.Visits` converts cascades into soft-deletes (see [Data model → Visit-delete behaviour](#data-model)). This guarantees mobile always sees a tombstone for every row that leaves its visibility window via deletion.

### Write side

Mobile offline-replay just re-fires the regular write routes; the server doesn't have a separate "sync write" path:

- `PUT /api/notes` — single create-or-update with caller-supplied `Id` (idempotent on retry).
- `DELETE /api/notes/{noteId}` — single soft-delete (idempotent on retry).

Each write bumps `SequenceId` via the DB trigger, so other clients pick the change up on their next `/sync` poll.

Server-side these route through `NotesController` → handler validation → `INotesRepository`. The Jobs domain is not touched — no `Job.Version` bump, no `JobEvents` row, no Visit-aggregate load.

## Tests

- `Src/Jobs/Jobs.UnitTests/Domain/NoteTests.cs` — domain unit tests for the `Note` aggregate: `CreateForVisit` forces `Visibility = Team`, rejects empty / 1001-char messages, requires `VisitId`, accepts `ClientId` as nullable (stored as-is); `CreateForClient` accepts `Private` and `Team` and keeps `VisitId` null; `Edit` rejects non-author callers, rejects bad message length, sets `UpdatedAt` (which is the source of truth for the on-wire `IsEdited` flag); `MarkDeleted` is idempotent (second call is a no-op, doesn't move `DeletedAt`); `ValidateVersion` returns silently on match and throws `VersionMismatchException` with `{ActualVersion = Version, SubmittedVersion = expected}` on mismatch.
- `Invoices.IntegrationTests/Notes/NoteSchemaTests.cs` — TestContainers Postgres: the `varchar(1000)` column type rejects a 1001-char message at DB level; the `BEFORE INSERT OR UPDATE` trigger assigns a fresh `SequenceId` on every write (insert, edit, delete); the `BEFORE UPDATE` trigger bumps `Version` by 1 on every update (insert leaves `Version = 0`); the `BEFORE DELETE` trigger on `jobs.Visits` soft-deletes child notes — clears `VisitId`, stamps `DeletedAt`, bumps `SequenceId` (so they appear as tombstones on `/sync`). The anchor-XOR and visit-note-is-Team invariants live in the domain factories and are covered by `NoteTests.cs` (`CreateForVisit` forces `Team`; `CreateForClient` keeps `VisitId` null) — no DB CHECK to test.
- `Invoices.IntegrationTests/Notes/GetNotesAllTests.cs` — `GET /api/notes/all` filter matrix: no filter returns all live notes for the caller's account; `?clientId=X` returns only client-level rows (`VisitId IS NULL`) for that client — visit-level rows for the client's visits are NOT included; `?visitId=Y` returns only the visit's visit-level notes; passing both → `400` (mutually exclusive); Admin sees `Private + Team`, Worker sees every `Team` row in the account (no assignment scope); soft-deleted rows are never returned; response is `GetNotesResponseDto { Items }`.
- `Invoices.IntegrationTests/Notes/GetNoteByIdTests.cs` — `GET /api/notes/{noteId}`: returns the live `NoteDto`; cross-account or unknown id → `404`; Worker requesting a Private note → `404`; soft-deleted row → `404` (single-row endpoint doesn't surface tombstones — clients reconcile via `/sync`).
- `Invoices.IntegrationTests/Notes/SyncNotesTests.cs` — `GET /api/notes/sync`: empty cursor returns first page ordered by `SequenceId ASC`; `HasMore = true` when more rows exist past the page; subsequent call with the returned `NextCursor` resumes correctly; soft-deleted rows appear once with `Change = Deleted` / `Item = null` and disappear from later pages; writes bump `SequenceId` so the same row can reappear in a later page (latest state wins); Worker sees every Team row in the account (no assignment scope); Admin sees Private + Team; malformed cursor → `400`; `limit` clamped to `[1, 500]`; cascade from `jobs.Visits` delete surfaces as a tombstone in the next page (verifies the soft-delete trigger).
- `Invoices.IntegrationTests/Notes/PutNoteTests.cs` — `PUT /api/notes` (single, id in body): caller-supplied id → create via `Note.CreateForVisit` / `CreateForClient` (response carries `Version = 0`); existing id → update via `Note.Edit` (response carries `Version = old + 1`); `Visit-Private` rejected with `400`; non-author edit on Worker call → `403`; immutable `ClientId` / `VisitId` / `Visibility` on update → `400`; idempotent replay (same `PUT` twice yields the same row state and the same final `SequenceId` only differs by one bump); cross-account id collision → `404`. Visit-note round-trip with `ClientId = null` in the request body: server stores `ClientId = null` as-is (no auto-resolution from the visit), and the response shape has `ClientId = null`. **Version mismatch**: update with `body.Version != current` → HTTP 200 + `ErrorCode.VersionMismatch` payload `{ActualVersion, SubmittedVersion}`; `body.Version` is ignored on create. **`XA-Client-Event-Ms` header**: when present on `PUT` (or `DELETE`), drives `CreatedAt` / `UpdatedAt` / `DeletedAt` instead of the server clock — see `NoteWriteServiceTests.Create_ClientNote_WithOccurredAt_UsesItForCreatedAt` and the matching `Update_WithOccurredAt_UsesItForUpdatedAt` unit tests. **Visit-completion lock**: Worker editing an existing visit-note where `Visit.Status == Completed` → `403`; Worker creating a brand-new visit-note on the same completed visit → `201`/`200` (allowed); Admin editing the same existing note → succeeds.
- `Invoices.IntegrationTests/Notes/DeleteNoteTests.cs` — `DELETE /api/notes/{noteId}`: sets `DeletedAt`, bumps `SequenceId`, row stays in DB; subsequent `GET /api/notes/all` excludes it; subsequent `GET /api/notes/sync` surfaces a tombstone exactly once; idempotent (second `DELETE` returns `200`, no further `SequenceId` bump). Admin deletes any note (own + others, including worker-authored visit-notes for moderation). Worker deletes **only** own notes; other-author delete → `403`. Cross-account delete returns `404`. **Visit-completion lock**: Worker deleting own visit-note where `Visit.Status == Completed` → `403`; Admin deleting the same note → succeeds.
- `Invoices.IntegrationTests/Jobs/JobsSyncNoNotesTests.cs` — guard test confirming `GET /api/v3/jobs/sync`, `GET /api/v3/jobs/paged`, and `GET /api/v3/jobs/{id}` payloads do NOT carry any `Notes` array on `Visit` or `Job`. Locks the "notes have their own sync, jobs sync is unchanged" contract against accidental regression.

## Docs to Update

- `Backend/Api/NOTES_API_REFERENCE.md` — new file documenting the five endpoints (`GET /api/notes/sync`, `GET /api/notes/{noteId}`, `GET /api/notes/all`, `PUT /api/notes`, `DELETE /api/notes/{noteId}`), the `NoteDto` / `SaveNoteDto` / `NotesSyncCursor` shapes, the cursor / tombstone semantics for `/sync`, and the authorization decorator pattern. Cross-link to `JOBS_API_REFERENCE.md` for the canonical sync envelope description.
- `Backend/Api/JOBS_API_REFERENCE.md` — no payload changes; add a one-line note that "notes have a separate sync feed at `/api/notes/sync` — they are not embedded on `Visit` or `Job`".
