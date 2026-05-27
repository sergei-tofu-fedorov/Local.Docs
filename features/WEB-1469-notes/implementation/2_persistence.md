# Step 2: Persistence

> Reference: [../overview.md → Data model](../overview.md#data-model) and
> [`1_domain_model.md`](1_domain_model.md) for the aggregate this step maps.

A single table `jobs.Notes` lives in the existing `jobs` schema (next to `jobs.Jobs` and
`jobs.Visits`), reached through `JobsDbContext` — no per-entity schema override needed. The
migration also creates two Postgres triggers (sequence, version) and partial indexes that
back the read paths. When visits are hard-deleted (from job upsert), the application layer
soft-deletes the linked notes and clears their `VisitId` FK inline before the visit `DELETE`
lands — see §2.2.5 and `3_application_layer.md` §3.7.

Each row carries exactly one anchor: `VisitId` (visit-note) **or** `ClientId` (client-note).
The mutual-exclusion invariant is enforced by the domain factories.

---

## 2.1 EF mapping

**File:** `Jobs/Jobs.Infrastructure/Database/Configurations/NoteConfiguration.cs`

Picked up automatically by `JobsDbContext.OnModelCreating` (`ApplyConfigurationsFromAssembly`).

```csharp
internal sealed class NoteConfiguration : IEntityTypeConfiguration<Note>
{
    public void Configure(EntityTypeBuilder<Note> builder)
    {
        builder.ToTable("Notes");                        // jobs schema is the default for JobsDbContext

        builder.Property(n => n.Id).ValueGeneratedNever();

        // SequenceId is assigned by a BEFORE INSERT OR UPDATE trigger — see migration.
        builder.Property(n => n.SequenceId).ValueGeneratedOnAddOrUpdate();

        builder.Property(n => n.Visibility).HasColumnType("smallint");

        builder.Property(n => n.Message).HasMaxLength(1000);

        // Optimistic-concurrency token. A BEFORE UPDATE trigger bumps it
        // (NEW.Version = OLD.Version + 1). Mirrors jobs.Jobs.Version.
        builder.Property(n => n.Version)
            .HasDefaultValue(0)
            .IsConcurrencyToken()
            .ValueGeneratedOnAddOrUpdate();

        builder.Property(n => n.CreatedAt).HasDefaultValueSql("now()");

        // OwnsOne flattens the value object onto the row.
        builder.OwnsOne(n => n.Author, author =>
        {
            author.Property(a => a.MasterUserId).HasColumnName("AuthorMasterUserId");
            author.Property(a => a.DisplayName).HasColumnName("AuthorDisplayName");
        });

        // NoAction — the application-level cascade in UpsertJobCommandHandler
        // (`INotesRepository.SoftDeleteByVisitIds`) clears VisitId + sets DeletedAt
        // BEFORE the visits DELETE lands, so the end-of-statement FK check passes.
        // See §2.2.5 and `3_application_layer.md` §3.7.
        builder.HasOne<Visit>()
            .WithMany()
            .HasForeignKey(n => n.VisitId)
            .HasPrincipalKey(v => v.Id)
            .OnDelete(DeleteBehavior.NoAction)
            .IsRequired(false);

        // /api/notes/sync — no DeletedAt filter (tombstones must flow through).
        builder.HasIndex(n => new { n.AccountId, n.SequenceId })
            .HasDatabaseName("ix_notes_account_sequence");

        // /api/notes/all?clientId=…
        builder.HasIndex(n => new { n.AccountId, n.ClientId, n.CreatedAt })
            .HasDatabaseName("ix_notes_account_client_created")
            .IsDescending(false, false, true)
            .HasFilter("\"ClientId\" IS NOT NULL AND \"DeletedAt\" IS NULL");

        // /api/notes/all?visitId=…
        builder.HasIndex(n => new { n.VisitId, n.CreatedAt })
            .HasDatabaseName("ix_notes_visit_created")
            .IsDescending(false, true)
            .HasFilter("\"VisitId\" IS NOT NULL AND \"DeletedAt\" IS NULL");
    }
}
```

`JobsDbContext` exposes the entity:

```csharp
public DbSet<Note> Notes => Set<Note>();
```

> **EF round-trip note.** `IsConcurrencyToken().ValueGeneratedOnAddOrUpdate()` on `Version`
> (and the same `ValueGeneratedOnAddOrUpdate()` on `SequenceId`) makes Npgsql append a
> `RETURNING "Version", "SequenceId"` clause to every INSERT / UPDATE. After
> `SaveChangesAsync` returns, the tracked entity already reflects the post-trigger values —
> so a follow-up `note.ValidateVersion(...)` in the same scope sees the bumped `Version`,
> not the stale pre-write one. Integration tests in step 6 assert this explicitly; do not
> rely on a re-fetch.

---

## 2.2 Migration

**File:** `Jobs/Jobs.Infrastructure/Migrations/{timestamp}_WEB-1470_AddNotesTable.cs`

Generated with:

```powershell
dotnet ef migrations add WEB-1470_AddNotesTable `
    -c JobsDbContext `
    -p Src/Jobs/Jobs.Infrastructure `
    -s Src/Invoices.Api `
    -o Migrations
```

### 2.2.1 Table

`CreateTable("Notes", schema: "jobs", …)` with the columns listed in
[overview → Data model](../overview.md#data-model):

| Column | Type | Nullable | Default | Notes |
|---|---|---|---|---|
| `Id` | `uuid` | no | — | PK; caller-supplied |
| `SequenceId` | `bigint` | no | — | trigger-assigned |
| `AccountId` | `text` | no | — | tenant |
| `ClientId` | `text` | yes | — | set on client-notes |
| `VisitId` | `uuid` | yes | — | set on visit-notes; FK to `jobs.Visits.Id` `ON DELETE NO ACTION` |
| `Visibility` | `smallint` | no | — | 1 = Private, 2 = Team |
| `Version` | `integer` | no | `0` | trigger-incremented on UPDATE |
| `Message` | `varchar(1000)` | no | — | length cap enforced by the column type |
| `AuthorMasterUserId` | `text` | no | — | OwnsOne flatten |
| `AuthorDisplayName` | `text` | no | — | OwnsOne flatten |
| `CreatedAt` | `timestamptz` | no | `now()` | |
| `UpdatedAt` | `timestamptz` | yes | — | set on edit |
| `DeletedAt` | `timestamptz` | yes | — | soft-delete tombstone |

No CHECK constraints. Message length is bounded by the `varchar(1000)` column; the
anchor-xor and visit-note-is-Team invariants are enforced by the domain factories.

### 2.2.2 Sequence

```sql
CREATE SEQUENCE IF NOT EXISTS jobs."Notes_SequenceId_seq" AS bigint;
```

### 2.2.3 Sequence trigger

`BEFORE INSERT OR UPDATE` — bumps `SequenceId` on every write (create, edit, soft-delete).
This feeds the `/sync` cursor; tombstones get a fresh `SequenceId` so they flow through
exactly once.

```sql
CREATE OR REPLACE FUNCTION jobs.notes_sequence_function()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$
BEGIN
    NEW."SequenceId" := nextval('jobs."Notes_SequenceId_seq"');
    RETURN NEW;
END;
$$;

CREATE TRIGGER notes_sequence_trigger
BEFORE INSERT OR UPDATE ON jobs."Notes"
FOR EACH ROW
EXECUTE FUNCTION jobs.notes_sequence_function();
```

### 2.2.4 Version trigger

`BEFORE UPDATE` — bumps `Version` on every UPDATE so clients get a new optimistic-concurrency
token after each write. Mirrors the `increment_job_version` trigger on `jobs.Jobs`. INSERT
leaves `Version` at its `DEFAULT 0`; only UPDATE increments.

```sql
CREATE OR REPLACE FUNCTION jobs.notes_version_increment()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$
BEGIN
    NEW."Version" = OLD."Version" + 1;
    RETURN NEW;
END;
$$;

CREATE TRIGGER notes_version_increment_trigger
BEFORE UPDATE ON jobs."Notes"
FOR EACH ROW
EXECUTE FUNCTION jobs.notes_version_increment();
```

### 2.2.5 Soft-delete on visit-delete

The FK from `jobs.Notes.VisitId` to `jobs.Visits.Id` is `ON DELETE NO ACTION`. When a job
upsert hard-deletes visits (the only path that does in v1 — see `3_application_layer.md`
§3.7), the application layer must soft-delete the linked notes **and** clear their `VisitId`
before EF emits the visit `DELETE`. Otherwise the end-of-statement FK check would block the
deletion.

The cascade is a single bulk `UPDATE` issued before `SaveChangesAsync`, in the same
transaction:

```sql
UPDATE jobs."Notes"
SET    "VisitId"   = NULL,
       "DeletedAt" = COALESCE("DeletedAt", :now)
WHERE  "AccountId" = :accountId
  AND  "VisitId"  = ANY(:visitIds);
```

The `COALESCE` preserves the original tombstone time on rows that were already soft-deleted —
clearing their `VisitId` is enough to satisfy the FK. Live rows get tombstoned with `:now`.

**Sync emission is at-least-once, not exactly-once.** The sequence + version triggers (§2.2.3,
§2.2.4) fire on **every** affected row, including the already-tombstoned ones where we only
clear `VisitId`. That bumps their `SequenceId`, so a tombstone that already flowed through
`/api/notes/sync` for a previous cursor position will re-surface on the next sync for clients
whose cursor was past the original `SequenceId` but before the new one. Clients MUST process
`Deleted` change-items idempotently (treat a second `Deleted` for the same `Id` as a no-op).
This was an explicit trade-off — making the trigger conditional on which columns changed adds
PG complexity for a noise issue that clients must be resilient against anyway (offline replay,
retries).

**Why not `ON DELETE CASCADE`.** A plain cascade would hard-delete the notes; `/api/notes/sync`
is a cursor over `SequenceId`-ordered rows, so a row that physically disappears never surfaces
as a tombstone and an offline mobile client keeps its stale local copy until the next full
re-sync. We need tombstones, hence `NoAction` + the app-level soft-delete update.

The repository surface is `INotesRepository.SoftDeleteByVisitIds(accountId, visitIds, now, ct)`
— see §2.3. Implementation uses EF Core's `ExecuteUpdateAsync` so the update doesn't load
notes into memory.

### 2.2.6 Indexes

| Index | Filter | Backs |
|---|---|---|
| `ix_notes_account_sequence` (`AccountId`, `SequenceId`) | none | `GET /api/notes/sync` — tombstones must flow through, no `DeletedAt` filter |
| `ix_notes_account_client_created` (`AccountId`, `ClientId`, `CreatedAt DESC`) | `"ClientId" IS NOT NULL AND "DeletedAt" IS NULL` | `GET /api/notes/all?clientId=…` (client-notes live) |
| `ix_notes_visit_created` (`VisitId`, `CreatedAt DESC`) | `"VisitId" IS NOT NULL AND "DeletedAt" IS NULL` | `GET /api/notes/all?visitId=…` (visit-notes live) |

Account-wide `GET /api/notes/all` (no filter) falls back to a sequential scan — acceptable for
the rare admin-export path.

### 2.2.7 Down migration

Drop the two triggers + their functions, drop the table, drop the sequence. No data preservation.

---

## 2.3 Repository

**Interface:** `Jobs/Jobs.Domain/Interfaces/INotesRepository.cs`

```csharp
public interface INotesRepository
{
    // The `visibilities` parameter is the explicit set of NoteVisibility values the caller is
    // allowed to see. Each read method translates it to a `Visibility = ANY(@visibilities)`
    // WHERE clause — visibility filtering is always at DB level. See behaviour notes below.
    Task<Note?>             GetById(string accountId, Guid noteId, IReadOnlyCollection<NoteVisibility> visibilities, CancellationToken ct);
    Task<Note?>             GetByIdIncludingDeleted(string accountId, Guid noteId, IReadOnlyCollection<NoteVisibility> visibilities, CancellationToken ct);
    Task<IReadOnlyList<Note>> Find(string accountId, string? clientId, Guid? visitId, IReadOnlyCollection<NoteVisibility> visibilities, CancellationToken ct);
    Task<IReadOnlyList<Note>> GetChangedSince(string accountId, long sinceSequenceId, int pageSize, IReadOnlyCollection<NoteVisibility> visibilities, CancellationToken ct);

    // Create-path resurrection guard. Scans across accounts AND soft-deleted rows on purpose.
    Task<bool>              NoteIdExistsAnywhere(Guid noteId, CancellationToken ct);

    // App-level visit-delete cascade — see §2.2.5. MUST be called BEFORE the visits
    // hard-delete in the same transaction (FK is NoAction).
    Task                    SoftDeleteByVisitIds(string accountId, IReadOnlyCollection<Guid> visitIds, DateTimeOffset now, CancellationToken ct);

    void                    Insert(Note note);
}
```

Visit-side reads (existence probe + status for the completion lock) live in a **separate**
`IVisitsRepository` in the same project — see §2.4 below. Keeping note vs. visit access on
separate interfaces lets the Notes handlers be honest about their visit-side dependency and
keeps `INotesRepository` to note-table queries only.

**Implementation:** `Jobs/Jobs.Infrastructure/Repositories/NotesRepository.cs`

Notable behaviours:

- All four read methods (`GetById`, `GetByIdIncludingDeleted`, `Find`, `GetChangedSince`) take
  the same `IReadOnlyCollection<NoteVisibility> visibilities` parameter. The SQL WHERE adds
  `Visibility = ANY(@visibilities)` so rows outside the set never come back. The application
  layer never filters by visibility in memory — every visibility decision lives in the SQL.
  Callers build the set from the caller's role:
  - Admin → `[NoteVisibility.Private, NoteVisibility.Team]`
  - Worker → `[NoteVisibility.Team]`

  Using an explicit set rather than a `bool includePrivate` keeps the signature stable if
  more visibility values are added later (only the caller-side mapping needs an update).
- `GetById` filters out soft-deleted rows (`DeletedAt == null`).
- `GetByIdIncludingDeleted` does not filter on `DeletedAt` — the `DELETE` endpoint uses it so
  a second delete of an already-deleted note is a 200 no-op (idempotent), not a 404.
- `GetChangedSince` does **not** filter on `DeletedAt` either — tombstones must flow through
  so the client can drop its local copy. Since `Visibility` is immutable, a Worker never had a
  Private tombstone in their local store; filtering Private tombstones out at the DB is
  correct. Doing this in memory on a `pageSize+1` fetch would skew the cursor and miscount
  `HasMore` whenever Private rows are interleaved with Team rows in the sequence — hence the
  DB-level filter is mandatory, not just a perf choice.
- `Find` keys off the partial indexes:
  - `?clientId` matches `ClientId == clientId` (anchors are mutually exclusive in the domain, so visit-notes don't carry `ClientId` and can't false-match);
  - `?visitId` matches `VisitId == visitId`.
- `NoteIdExistsAnywhere` deliberately scans across accounts AND soft-deleted rows — it is the
  create-path resurrection guard. Adding a `DeletedAt` filter here would silently re-open the
  vulnerability of resurrecting an id from a tombstone.
- `SoftDeleteByVisitIds` is the bulk app-level visit-delete cascade (see §2.2.5). Uses EF
  Core `ExecuteUpdateAsync` (no entity load) and sets `VisitId = NULL,
  DeletedAt = COALESCE(DeletedAt, now)` for every note whose `VisitId` is in the supplied set
  within the given account. No-op when the set is empty. Called once per `UpsertJobCommand`
  from `3_application_layer.md` §3.7, BEFORE `IUnitOfWork.SaveChangesAsync` so the FK on the
  impending visit `DELETE` is satisfied.
- The probe + INSERT pair is **not atomic**: two concurrent `PUT`s with the same caller-supplied
  `Id` (offline replay + a fresh client) can both pass the probe and then race on the actual
  insert. The second one fails on the `PK_Notes` constraint as a `DbUpdateException`, which
  bubbles up to the global middleware as 500 — v1 leaves the race uncatched since the window
  is tiny in practice.

---

## 2.4 Visits-side reads — `IVisitsRepository`

**Interface:** `Jobs/Jobs.Domain/Interfaces/IVisitsRepository.cs`

```csharp
public interface IVisitsRepository
{
    // Cheap existence probe used by the visit-note create path — true when the visit
    // exists in the account and its parent job is alive (`!v.Job.IsDeleted`).
    Task<bool>              VisitExists(string accountId, Guid visitId, CancellationToken ct);

    // Visit-completion lock: returns the visit's Status if it exists and its job is alive,
    // null otherwise. The application layer compares to VisitStatus.Completed inline.
    Task<VisitStatus?>      GetVisitStatus(string accountId, Guid visitId, CancellationToken ct);
}
```

**Implementation:** `Jobs/Jobs.Infrastructure/Repositories/VisitsRepository.cs` — both methods
hit `_context.Visits` directly with the `Job.AccountId == accountId && !Job.IsDeleted` guard.

Notable behaviours:

- `VisitExists` is the cheap existence check used on the visit-note create path —
  application layer translates `false` into a 404 (`Visit not found`). Used in preference to
  relying on the FK alone because the FK can't see the parent-job soft-delete flag — without
  the pre-check, a note attached to a visit whose Job was soft-deleted would succeed at INSERT
  and silently bypass the "alive job" invariant.
- `GetVisitStatus` is used only by the completion-lock path on the edit / delete handlers —
  returns `Visit.Status` for live visits whose linked job is not soft-deleted, `null`
  otherwise. The application layer treats `null` and `Completed` identically (both forbid the
  write), so the null-overloading is intentional, not a corner case to refactor out.

DI registration sits alongside `INotesRepository` in `Jobs.Infrastructure.ServiceCollectionExtensions`
(`AddScoped<IVisitsRepository, VisitsRepository>`).

---

## Execution Checklist

| # | Task | Files |
|---|------|-------|
| 2.1 | `NoteConfiguration` EF mapping (incl. partial indexes, `OwnsOne` author, concurrency token, FK NoAction) | `Jobs.Infrastructure/Database/Configurations/NoteConfiguration.cs` |
| 2.1 | `JobsDbContext.Notes` DbSet | `Jobs.Infrastructure/Database/JobsDbContext.cs` |
| 2.2 | Migration: `jobs.Notes` table, sequence, 2 triggers (sequence + version), 3 indexes, FK | `Jobs.Infrastructure/Migrations/{ts}_WEB-1470_AddNotesTable.cs` |
| 2.3 | `INotesRepository` interface (note-table reads / writes + `NoteIdExistsAnywhere` + `SoftDeleteByVisitIds`) | `Jobs.Domain/Interfaces/INotesRepository.cs` |
| 2.3 | `NotesRepository` implementation | `Jobs.Infrastructure/Repositories/NotesRepository.cs` |
| 2.4 | `IVisitsRepository` interface (`VisitExists`, `GetVisitStatus`) | `Jobs.Domain/Interfaces/IVisitsRepository.cs` |
| 2.4 | `VisitsRepository` implementation | `Jobs.Infrastructure/Repositories/VisitsRepository.cs` |
| 2.3 / 2.4 | DI registration (`AddScoped<INotesRepository, NotesRepository>`, `AddScoped<IVisitsRepository, VisitsRepository>`) | `Jobs.Infrastructure/ServiceCollectionExtensions.cs` |
