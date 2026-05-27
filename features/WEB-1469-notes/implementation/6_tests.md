# Step 6: Tests

> References: [`../overview.md` → Tests](../overview.md#tests),
> [`1_domain_model.md`](1_domain_model.md), [`2_persistence.md`](2_persistence.md),
> [`3_application_layer.md`](3_application_layer.md), [`4_api_layer.md`](4_api_layer.md).

Two test surfaces:

- **Unit tests** for the `Note` aggregate — invariants, factories, mutation rules, version
  check, role / scope predicates. No DB, no HTTP.
- **Integration tests** against the existing TestContainers Postgres + `WebApplicationFactory`
  fixture in `Src/Invoices.IntegrationTests/` — wire-shape contracts, schema (triggers + visit-
  delete cascade), authorization matrix, and the cross-feature guard that `/jobs/sync` does
  not leak notes.

> **Current state.** §6.1 (`NoteTests`) and §6.2 (handler unit tests under
> `Src/Invoices.Tests/Notes/{Commands,Queries}/`) are implemented. §6.4 / §6.5 ship as a
> single consolidated `NotesIntegrationTests.cs` covering the Admin-mode happy paths,
> validation, tombstone surface on `/sync`, and version-mismatch / not-found / bad-request
> error mapping. The Worker-mode end-to-end scenarios (visit-completion lock, own-vs-others
> edit, Private hidden from Worker) are covered at the handler level by §6.2 and are tracked
> as follow-up work at the integration-test level, together with the Postgres schema test
> (§6.3) and the jobs-sync guard (§6.6). The §6.7 client surface ships with test-only
> response wrappers (`NoteResultWrapper`, `GetNotesResponseWrapper`,
> `SyncNotesResponseWrapper`) rather than the generic `TofuResponse<T>` — see the rationale
> in §6.7 below.

---

## 6.1 Domain unit tests

**File:** `Src/Jobs/Jobs.UnitTests/Domain/Models/NoteTests.cs`.

Each scenario is a single arrange / act / assert against the `Note` aggregate (step 1).
FluentAssertions + xUnit; no mocks beyond plain object construction.

| Group | Scenarios |
|---|---|
| `CreateForVisit` | forces `Visibility = Team`; rejects empty / >1000-char message; rejects empty `visitId`; `ClientId` stays null; `Version = 0`; `UpdatedAt = null`; honours the supplied `createdAt`. |
| `CreateForClient` | accepts `Private` and `Team`; rejects `Unknown`; rejects empty / >1000-char message; rejects empty `clientId`; `VisitId` stays null. |
| `SetMessage` | author edits succeed; non-author → `NoteWriteForbiddenException`; empty / >1000 → `ArgumentException`; rejected when `IsDeleted` → `EntityDeletedException`; sets `UpdatedAt`; `isEdited: false` skips the timestamp; Worker on own visit-note allowed; Worker on own client-note → 403 (workers don't own client-notes); Admin on own client-note allowed. |
| `MarkDeleted` | first call sets `DeletedAt` and returns `true`; second call no-ops and returns `false` (idempotent); honours the supplied `now`. Role/author guard: Admin deletes any; Worker deletes own; Worker on non-author note → 403. |
| `ValidateVersion` | returns silently on match; throws `VersionMismatchException(ActualVersion, SubmittedVersion)` on mismatch. |
| `IsVisibleToWorker` | `true` only for `Team` rows; `Private` always `false`. |

Role + author authorization lives inside `SetMessage` and `MarkDeleted` (the earlier
`EnsureCanBe…By` helpers were folded into the mutation methods so the role/author check sits
next to the state change it gates). The visit-completion lock is not exercised at the
aggregate level — it lives in the handler because it needs the `Visit.Status` lookup. See
§6.2 (handler unit tests) and §6.5 (integration tests).

---

## 6.2 Application handler unit tests

Mocked-repository tests against `SaveNoteCommandHandler`, `DeleteNoteCommandHandler`, and the
three query handlers (`GetNoteByIdQueryHandler`, `GetNotesQueryHandler`,
`SyncNotesQueryHandler`). xUnit + Moq + FluentAssertions; no DB, no HTTP. They cover the
orchestration paths that don't reach the integration suite — branch coverage for role + status
combinations is cheaper here than wiring a multi-user auth fixture end-to-end.

**Folder:** `Src/Invoices.Tests/Notes/{Commands,Queries}/`.

| File | Scenarios |
|---|---|
| `Commands/SaveNoteCommandHandlerTests.cs` | create visit-note (success / missing visit → 404); create client-note (Admin success / Worker → 403 / missing client → 404); cross-account or tombstone collision on the create-path id probe → 404; update existing note Admin author → save; update with stale `Version` → `VersionMismatchException` (no save); Worker editing existing visit-note with `Visit.Status = Completed` → 403. |
| `Commands/DeleteNoteCommandHandlerTests.cs` | unknown id → `EntityNotFoundException`; live note → tombstones and saves; already-tombstoned → returns 200 without a save round-trip; Worker on visit-note with `Visit.Status = Completed` → 403. |
| `Queries/GetNoteByIdQueryHandlerTests.cs` | row found → mapped DTO; not found → `null`; Worker role passes `[Team]` visibility set to the repository. |
| `Queries/GetNotesQueryHandlerTests.cs` | maps rows to DTOs; forwards `ClientId` / `VisitId` filters to the repository unchanged. |
| `Queries/SyncNotesQueryHandlerTests.cs` | `null` cursor starts at zero; `pageSize + 1` rows trip `HasMore = true` and the extra row is dropped; cursor advances to the last returned `SequenceId`; empty page holds the cursor at the previous `sinceSequenceId`; tombstone rows emit `Change = Deleted`. |

---

## 6.3 Integration tests — schema

**File:** `Src/Invoices.IntegrationTests/Notes/NoteSchemaIntegrationTests.cs`.

Exercises the migration end-to-end against the real Postgres container:

- `varchar(1000)` rejects a 1001-char `Message` at insert / update.
- Sequence trigger — every INSERT and every UPDATE assigns a fresh `SequenceId`; the value is
  strictly increasing across writes on the same row (insert → edit → soft-delete → next
  cascade soft-delete).
- Version trigger — INSERT leaves `Version = 0`; first UPDATE → `Version = 1`; subsequent
  UPDATEs increment by 1.
- Visit-delete cascade — calling `INotesRepository.SoftDeleteByVisitIds` (§3.7) clears
  `VisitId`, stamps `DeletedAt = now` for live rows, preserves the existing `DeletedAt` on
  rows that were already tombstoned (`COALESCE`), and bumps `SequenceId` on every affected
  row so the next `/sync` page surfaces the tombstone.
- Partial indexes (`ix_notes_account_client_created`, `ix_notes_visit_created`) — covered
  implicitly by query paths in §6.3 (no separate index existence test).

The anchor-XOR and visit-note-is-Team invariants live in the domain factories (step 1) and are
covered by §6.1 — no DB CHECK to test.

---

## 6.4 Integration tests — read paths

Mirror the Jobs / Visits integration suite (`Src/Invoices.IntegrationTests/Jobs/*`). Each test
class derives from `BaseInvoicesIntegrationTest`, calls `UseApiAuthenticationAsync(...)`
in `InitializeAsync`, and talks to the API through a typed `INotesClient` proxy under
`Src/Invoices.IntegrationTests/Clients/`.

**`Src/Invoices.IntegrationTests/Notes/GetNotesIntegrationTests.cs`** — `GET /api/notes/all`:

- no filter → account-wide live rows (client-notes + visit-notes mixed);
- `?clientId=X` → only client-level rows (`VisitId IS NULL`) for X; visit-level rows for X's
  visits are NOT included;
- `?visitId=Y` → only that visit's notes;
- both `?clientId` and `?visitId` → 400;
- Admin sees Private + Team; Worker sees Team only;
- soft-deleted rows never returned;
- response shape is `GetNotesResponseDto { Items }`.

**`Src/Invoices.IntegrationTests/Notes/GetNoteByIdIntegrationTests.cs`** — `GET /api/notes/{id}`:

- happy path returns live `NoteDto`;
- cross-account or unknown id → 200 + `ErrorCode.NotFound`;
- Worker requesting a Private note → 200 + `ErrorCode.NotFound`;
- soft-deleted row → 200 + `ErrorCode.NotFound` (this single-row endpoint does not surface
  tombstones — clients reconcile via `/sync`).

**`Src/Invoices.IntegrationTests/Notes/SyncNotesIntegrationTests.cs`** — `GET /api/notes/sync`:

- empty cursor → first page ordered by `SequenceId ASC`;
- `HasMore = true` past the limit; passing the returned `NextCursor` resumes;
- `NextCursor` is non-null even when the page is empty (resume-from-current-position contract);
- soft-deleted rows appear once with `Change = Deleted`, `Item = null`, then disappear from
  later pages once the cursor passes their `SequenceId`;
- a re-edit on an existing row bumps its `SequenceId`, so the row re-surfaces on a later page
  (latest state wins);
- Admin sees Private + Team; Worker sees Team only (Private rows are filtered at DB level);
- malformed cursor → 400; `limit` outside `[1, 500]` → 400;
- visit-delete cascade surfaces the affected notes as tombstones on the next page (covers
  §2.2.5 end-to-end through `UpsertJobCommand`).

---

## 6.5 Integration tests — write paths

**`Src/Invoices.IntegrationTests/Notes/PutNoteIntegrationTests.cs`** — `PUT /api/notes`:

- caller-supplied id → create via the right factory (response `Version = 0`,
  `UpdatedAt = null`, `IsEdited = false`);
- existing id → update via `Note.SetMessage` (response `Version = old + 1`,
  `UpdatedAt != null`, `IsEdited = true`);
- visit-note with `Visibility = Private` → 400 (`Note.CreateForVisit` rejects it);
- non-author edit on Worker call → 403;
- non-author edit on Admin call → 403 (Admin moderates via delete);
- silently-ignored `ClientId` / `VisitId` / `Visibility` on update (immutable identity) — body
  fields are dropped, response reflects the original row;
- idempotent replay — same `PUT` twice with `body.Version` advancing produces the same row
  state and increments `Version` by 1 per actual change (no-op replay does not double-bump);
- cross-account id collision → 200 + `ErrorCode.NotFound` (`NoteIdExistsAnywhere` probe);
- visit-note round-trip with `ClientId = null` in the body — server stores it as null,
  response carries `ClientId = null`;
- Worker authoring a client-note → 403 (`NoteWriteForbiddenException`);
- referenced visit / client missing → 200 + `ErrorCode.NotFound`;
- version mismatch — `body.Version != current` → 200 + `ErrorCode.VersionMismatch` payload
  `{ ActualVersion, SubmittedVersion }`;
- `XA-Client-Event-Ms` header — when present, drives `CreatedAt` on create and `UpdatedAt` on
  edit (asserted with a small tolerance to absorb the `timestamptz` round-trip);
- visit-completion lock — Worker editing an existing visit-note with `Visit.Status = Completed`
  → 403; Worker creating a brand-new visit-note on the same completed visit → 200; Admin
  editing the same existing note → 200.

**`Src/Invoices.IntegrationTests/Notes/DeleteNoteIntegrationTests.cs`** — `DELETE /api/notes/{id}`:

- happy path → `DeletedAt` set, `SequenceId` bumped, row stays in DB;
- subsequent `GET /api/notes/all` excludes it;
- subsequent `GET /api/notes/sync` surfaces a tombstone exactly once;
- idempotent — second `DELETE` returns 200, no further `SequenceId` bump (the no-op early
  return in `DeleteNoteCommandHandler`);
- Admin deletes any note (own + others, including worker-authored visit-notes — moderation);
- Worker deletes own; other-author delete → 403;
- cross-account delete → 200 + `ErrorCode.NotFound`;
- visit-completion lock — Worker deleting own visit-note on a completed visit → 403; Admin
  deleting the same note → 200. The completion check fires BEFORE the idempotency check, so
  re-deleting a tombstoned note on a completed visit also returns 403 (not a quiet 200).

---

## 6.6 Guard test — jobs sync stays unchanged

**File:** `Src/Invoices.IntegrationTests/Notes/JobsSyncNoNotesIntegrationTests.cs`.

After creating both kinds of notes against an account, asserts:

- `GET /api/v3/jobs/sync` payload (`SyncResponseDto<JobDto, JobSyncRelationsDto>`) carries no
  `Notes` array on `Visit` or `Job`;
- `GET /api/v3/jobs/{id}` and `GET /api/v3/jobs/paged` likewise;
- writing a note does not bump `Job.Version` (snapshot before / after);
- the `/jobs/sync` cursor returned before any note writes resumes with `HasMore = false`
  afterwards — confirming note writes don't leak into the jobs sequence.

Locks the "notes have their own sync, jobs sync is unchanged" contract against accidental
regression.

---

## 6.7 Test client

**File:** `Src/Invoices.IntegrationTests/Clients/INotesClient.cs`.

Refit-style HTTP proxy mirroring `IJobsClient`. Each response uses a test-only wrapper
(`NoteResultWrapper`, `GetNotesResponseWrapper`, `SyncNotesResponseWrapper` —
`Src/Invoices.IntegrationTests/Clients/Responses/NotesResponseWrappers.cs`) instead of the
generic `TofuResponse<T>`: `TofuResponseConverter<T>` inspects the body's `result` for an
`ErrorDetails`-shaped object, and `NoteDto.Message` would otherwise be misclassified as an
error message. Reads return `ApiResponse<...>` so non-success status codes surface as `Error`
on the response object rather than throwing.

```csharp
public interface INotesClient
{
    [Get("/api/notes/sync")]
    Task<ApiResponse<SyncNotesResponseWrapper>> SyncAsync(
        [Query] string? cursor = null,
        [Query] int limit = 100,
        [Header("api-version")] int apiVersion = 3,
        CancellationToken ct = default);

    [Get("/api/notes/{noteId}")]
    Task<ApiResponse<NoteResultWrapper>> GetByIdAsync(
        Guid noteId,
        [Header("api-version")] int apiVersion = 3,
        CancellationToken ct = default);

    [Get("/api/notes/all")]
    Task<ApiResponse<GetNotesResponseWrapper>> GetAllAsync(
        [Query] string? clientId = null,
        [Query] Guid? visitId = null,
        [Header("api-version")] int apiVersion = 3,
        CancellationToken ct = default);

    [Put("/api/notes")]
    Task<ApiResponse<NoteResultWrapper>> SaveAsync(
        [Body] SaveNoteDto body,
        [Header("api-version")] int apiVersion = 3,
        [Header("XA-Client-Event-Ms")] long? clientEventMs = null,
        CancellationToken ct = default);

    [Delete("/api/notes/{noteId}")]
    Task<HttpResponseMessage> DeleteAsync(
        Guid noteId,
        [Header("api-version")] int apiVersion = 3,
        [Header("XA-Client-Event-Ms")] long? clientEventMs = null,
        CancellationToken ct = default);
}
```

Exposed via `ApiClientFactory.CreateClient<INotesClient>(HttpClient)` from
`BaseInvoicesIntegrationTest`.

---

## Execution Checklist

| # | Task | File |
|---|------|------|
| 6.1 | `NoteTests` — domain invariants, factories, `SetMessage` / `MarkDeleted` (with role + author guards folded in), `ValidateVersion`, `IsVisibleToWorker` | `Src/Jobs/Jobs.UnitTests/Domain/Models/NoteTests.cs` |
| 6.2 | Handler unit tests (Save / Delete / GetById / GetNotes / SyncNotes) — orchestration branches, role + completion-lock paths, cursor / `HasMore` semantics | `Src/Invoices.Tests/Notes/{Commands,Queries}/*HandlerTests.cs` |
| 6.3 | `NoteSchemaIntegrationTests` — `varchar(1000)` cap, sequence + version triggers, app-level visit-delete cascade (`SoftDeleteByVisitIds`) | `Src/Invoices.IntegrationTests/Notes/NoteSchemaIntegrationTests.cs` |
| 6.4 | `GetNotesIntegrationTests`, `GetNoteByIdIntegrationTests`, `SyncNotesIntegrationTests` | `Src/Invoices.IntegrationTests/Notes/Get*IntegrationTests.cs`, `SyncNotesIntegrationTests.cs` |
| 6.5 | `PutNoteIntegrationTests`, `DeleteNoteIntegrationTests` (including visit-completion lock + version mismatch + XA-Client-Event-Ms) | `Src/Invoices.IntegrationTests/Notes/{Put,Delete}NoteIntegrationTests.cs` |
| 6.6 | `JobsSyncNoNotesIntegrationTests` — guard against notes leaking into jobs sync | `Src/Invoices.IntegrationTests/Notes/JobsSyncNoNotesIntegrationTests.cs` |
| 6.7 | `INotesClient` Refit proxy + factory hook | `Src/Invoices.IntegrationTests/Clients/INotesClient.cs` |
