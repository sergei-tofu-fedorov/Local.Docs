# Step 1: Domain Model

> Reference: [../overview.md → Domain integration](../overview.md#domain-integration).

The `Note` aggregate is the single source of truth for note invariants. The application layer
just dispatches; the entity decides. All check methods either return silently or throw
`ArgumentException` / `NoteWriteForbiddenException` / `VersionMismatchException` — the API
middleware maps these to the right HTTP shape.

---

## 1.1 `NoteVisibility` enum

**File:** `Jobs/Jobs.Domain/Models/Enums/NoteVisibility.cs`

```csharp
public enum NoteVisibility
{
    Unknown = 0,
    Private = 1,   // Manager only
    Team    = 2    // Manager + every worker in the account (assignment is not consulted)
}
```

Starts at 1 (project convention — see private CLAUDE.md). `Unknown = 0` exists as a guard against
"forgot to set visibility on deserialisation"; factories reject it.

---

## 1.2 `NoteAuthorRole` enum

**File:** `Jobs/Jobs.Domain/Models/Enums/NoteAuthorRole.cs`

```csharp
public enum NoteAuthorRole
{
    Unknown = 0,
    Admin   = 1,
    Worker  = 2
}
```

The role is **not** persisted on the note — it is supplied at request time by the application
layer (resolved from Tofu.Auth) and fed into `Note.EnsureCanBeEditedBy` / `EnsureCanBeDeletedBy`.
A local enum (rather than reusing `Tofu.Auth.RoleLevel` directly) keeps `Jobs.Domain`
self-contained — domain code does not take a dependency on the auth library. The application
layer is responsible for translating the caller's `RoleLevel` into a `NoteAuthorRole`.

---

## 1.3 `NoteAuthor` value object

**File:** `Jobs/Jobs.Domain/Models/NoteAuthor.cs`

```csharp
public sealed class NoteAuthor
{
    public string MasterUserId  { get; private set; }
    public string DisplayName   { get; private set; }

    public NoteAuthor(string masterUserId, string displayName) { ... }   // validates non-empty
    private NoteAuthor() { ... }                                          // EF only (OwnsOne)
}
```

Frozen at creation. EF mapping (`OwnsOne`, column names) lives in step 2 — see [`2_persistence.md`](2_persistence.md).

---

## 1.4 `Note` aggregate

**File:** `Jobs/Jobs.Domain/Models/Note.cs`

### State

| Property | Source | Notes |
|---|---|---|
| `Id` | Caller-supplied (UUID v4) | `ValueGeneratedNever` — optimistic UI + idempotent replay. |
| `SequenceId` | DB trigger | Server-internal `bigint`. Drives the `/sync` cursor. Never on the wire. |
| `Version` | DB trigger | `int`, starts at 0; `BEFORE UPDATE` trigger increments. Optimistic-concurrency token on the wire. |
| `AccountId` | Factory | Tenancy. |
| `ClientId` | Factory | **Optional** cross-store reference to `ManageableClient`. Stored as-is when the caller passes it; server never auto-resolves it from the visit. |
| `VisitId` | Factory | **Optional** FK to `jobs.Visits`. Set only when the caller explicitly attaches the note to a visit. Immutable after creation. |
| `Visibility` | Factory | Immutable after creation. Visit-notes are forced to `Team`. |
| `Message` | Factory / `Edit` | 1..1000 chars after trim. |
| `Author` | Factory | `NoteAuthor` value object, frozen. |
| `CreatedAt` | Factory (header) | From `XA-Client-Event-Ms`; `DateTimeOffset.UtcNow` fallback. |
| `UpdatedAt` | `Edit` (header) | Null until first edit. Non-null means the row was edited; on the wire it surfaces as the boolean `IsEdited` flag (computed). |
| `DeletedAt` | `MarkDeleted` (header) | Null = live. Once set, row is a tombstone. |

`IsDeleted => DeletedAt.HasValue` — computed.

`IsEdited` (on `NoteDto`) is a **wire-only** convenience: outbound it is computed as `UpdatedAt.HasValue`; inbound on `SaveNoteDto` (UPDATE path) it is a trigger telling the server to stamp `UpdatedAt`. The aggregate does not own a separate `IsEdited` property and the table does not carry a column for it — the timestamp is the persisted truth.

### Factories

```csharp
public static Note CreateForVisit(
    Guid id, string accountId, Guid visitId,
    string message, NoteAuthor author,
    DateTimeOffset? createdAt = null)
{
    // Validates id / accountId / author non-empty.
    // Validates message 1..1000 after trim.
    // visitId non-empty.
    // Visibility is hardcoded to Team — visit-notes are always Team in v1; no parameter.
    // ClientId stays null — visit-notes are anchored only to the visit; there is no
    // parallel client link on this row. (Client-notes use CreateForClient.)
    ...
}

public static Note CreateForClient(
    Guid id, string accountId, string clientId,
    NoteVisibility visibility, string message, NoteAuthor author,
    DateTimeOffset? createdAt = null)
{
    // visibility must be Private or Team (not Unknown).
    // VisitId stays null.
    ...
}
```

### Mutation

```csharp
public void Edit(
    string message, string editorMasterUserId,
    DateTimeOffset? now = null, bool isEdited = true)
{
    // Reject if IsDeleted.
    // Reject if editorMasterUserId != Author.MasterUserId → NoteWriteForbiddenException.
    // Validate message length.
    // Always set Message.
    // Stamp UpdatedAt = now ?? UtcNow only when isEdited == true. When isEdited == false,
    // leave UpdatedAt as-is — this lets idempotent replays of a non-edit (rare) avoid
    // bumping the "was edited" signal that the client sees on the next /sync.
    ...
}

public void MarkDeleted(DateTimeOffset? now = null)
{
    if (IsDeleted) return;          // idempotent
    DeletedAt = now ?? UtcNow;
}
```

The `isEdited` parameter on `Edit` is the inbound signal from `SaveNoteDto.IsEdited`. The
application layer forwards it as-is; the domain decides whether `UpdatedAt` gets stamped. The
common case is `isEdited == true` (a genuine edit), and outbound mapping always derives
`NoteDto.IsEdited` from `UpdatedAt.HasValue` — there is no separate stored flag to keep in sync.

`Edit` deliberately does **not** accept `Visibility` / `ClientId` / `VisitId`. Immutability of
those fields after creation is enforced at the API layer: the handler ignores any value the
client puts in the corresponding `SaveNoteDto` fields on the UPDATE path. The alternative —
accepting them in `Edit` and throwing on change — was rejected because it adds parameter noise
for a case that never reaches the domain in v1. Integration tests in step 6 assert the handler
silently drops those fields on update.

### Optimistic concurrency

```csharp
public void ValidateVersion(int expectedVersion)
{
    if (expectedVersion != Version)
        throw new VersionMismatchException(
            $"Note version mismatch. Expected '{expectedVersion}', actual '{Version}'",
            actualVersion: Version,
            submittedVersion: expectedVersion);
}
```

Mirrors `Job.ValidateVersion`. The application layer calls this *before* `Edit` so the failure
mode is uniform between the in-memory check and EF's `DbUpdateConcurrencyException` (the
middleware maps both to `ErrorCode.VersionMismatch`).

### Caller-identity checks (domain-only)

`EnsureCanBeEditedBy` and `EnsureCanBeDeletedBy` live on the aggregate because they depend only
on the note and the caller. The only external-state rule left in the application layer is the
visit-completion lock (a Worker cannot edit / delete a note on a completed visit; Admins are
exempt).

```csharp
public void EnsureCanBeEditedBy(NoteAuthorRole callerRole, string callerMasterUserId)
{
    // Workers cannot write client-notes (defends against data-drift).
    if (callerRole != Admin && VisitId is null)
        throw new NoteWriteForbiddenException(...);

    // Only the author may edit. Admins moderate via delete.
    if (callerMasterUserId != Author.MasterUserId)
        throw new NoteWriteForbiddenException(...);
}

public void EnsureCanBeDeletedBy(NoteAuthorRole callerRole, string callerMasterUserId)
{
    // Admin may delete anything (moderation).
    if (callerRole == Admin) return;

    // Worker may delete only own.
    if (callerMasterUserId != Author.MasterUserId)
        throw new NoteWriteForbiddenException(...);
}
```

### Worker read visibility

```csharp
public bool IsVisibleToWorker() => Visibility == Team;
```

Sync and `/all` handlers call this to filter Worker reads. The rule is flat: Workers see every
`Team` note in the account; `Private` notes are silently dropped. Admins see both `Private`
and `Team`.

---

## 1.5 Exceptions

**File:** `Invoices.Core/Exceptions/NoteWriteForbiddenException.cs`

```csharp
public sealed class NoteWriteForbiddenException : ApiAuthorizationException
{
    public NoteWriteForbiddenException(string callerMasterUserId, Guid noteId)
        : base($"Caller '{callerMasterUserId}' cannot write note '{noteId}'.") { }
}
```

Extends `ApiAuthorizationException` so the middleware emits `403`.

`VersionMismatchException` already exists from the Jobs feature; the middleware maps it to
HTTP 200 + `ErrorCode.VersionMismatch` with `{ ActualVersion, SubmittedVersion }`.

---

## Execution Checklist

| # | Task | Files |
|---|------|-------|
| 1.1 | `NoteVisibility` enum (`Unknown = 0`, `Private = 1`, `Team = 2`) | `Jobs.Domain/Models/Enums/NoteVisibility.cs` |
| 1.2 | `NoteAuthorRole` enum (`Unknown = 0`, `Admin = 1`, `Worker = 2`) | `Jobs.Domain/Models/Enums/NoteAuthorRole.cs` |
| 1.3 | `NoteAuthor` value object (`MasterUserId`, `DisplayName`) | `Jobs.Domain/Models/NoteAuthor.cs` |
| 1.4 | `Note` aggregate with state + factories + `Edit` / `MarkDeleted` / `ValidateVersion` / `EnsureCanBe…By` / `IsVisibleToWorker` | `Jobs.Domain/Models/Note.cs` |
| 1.5 | `NoteWriteForbiddenException` | `Invoices.Core/Exceptions/NoteWriteForbiddenException.cs` |
