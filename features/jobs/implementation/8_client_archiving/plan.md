# Step 8: Client Archiving — Implementation Plan

> Reference: [overview.md](overview.md) for full specification and business rules.

## Implementation Order

Changes are ordered bottom-up: model → repository → service → controller → jobs integration → tests.

---

## Phase 1: Core Model

### 1.1 Add `ArchivedAt` field to `ManageableClient`

**File:** `Invoices.Core/Models/Clients/ManageableClient.cs`

- Add `public DateTime? ArchivedAt { get; set; }` next to `DeletedAt`
- No default value needed (`null` = not archived)

### 1.2 Add `ArchivedAt` to `ManageableClient.WithCalc.From()`

**File:** `Invoices.Core/Models/Clients/ManageableClient.cs` (nested record `WithCalc`)

- Pass `ArchivedAt = client.ArchivedAt` in the `From()` factory method so the field propagates to the calculated view

---

## Phase 2: Repository Layer

### 2.1 Add `Archive` method to `IClientsRepository`

**File:** `Invoices.Core/Repositories/IClientsRepository.cs`

```csharp
Task Archive(string accountId, string clientId, CancellationToken ct);
```

### 2.2 Implement `Archive` in `ClientsRepository`

**File:** `Invoices.Implementation.MongoDb/Repositories/ClientsRepository.cs`

- Filter: `AccountId == accountId && Id == ManageableClient.FormatId(accountId, clientId) && DeletedAt == null`
- Update: `Set(x => x.ArchivedAt, DateTime.UtcNow)`, `Inc(x => x.Version, 1)`
- Use `UpdateOneAsync`, throw `EntityNotFoundException` if `ModifiedCount == 0`

### 2.3 Add `includeArchived` parameter to `GetClientsByAccountId`

**File:** `Invoices.Core/Repositories/IClientsRepository.cs`

Update signature:
```csharp
Task<IReadOnlyCollection<ManageableClient>> GetClientsByAccountId(
    string accountId, bool includeDeleted, bool includeArchived, CancellationToken ct);
```

**File:** `Invoices.Implementation.MongoDb/Repositories/ClientsRepository.cs`

Current logic:
```csharp
var filter = Builders<ManageableClient>.Filter.Eq(x => x.AccountId, accountId);
if (includedeleted == false) filter &= Builders<ManageableClient>.Filter.Eq(x => x.DeletedAt, null);
```

Updated logic:
```csharp
var filter = Builders<ManageableClient>.Filter.Eq(x => x.AccountId, accountId);
if (includeDeleted == false) filter &= Builders<ManageableClient>.Filter.Eq(x => x.DeletedAt, null);
if (includeArchived == false) filter &= Builders<ManageableClient>.Filter.Eq(x => x.ArchivedAt, null);
```

Update all callers to pass the new parameter (see Phase 4.3).

### 2.4 `GetClientById` — NO changes

- `GetClientById` must **not** filter by `ArchivedAt`
- Current filter: `x.Id == id && x.DeletedAt == null` — correct as-is
- Archived clients remain accessible by direct ID (needed for job details, editing)

### 2.5 `Upsert` — NO changes (verify only)

**File:** `Invoices.Implementation.MongoDb/Repositories/ClientsRepository.cs`

- Current `Upsert` uses `SetOnInsert` for Id/ClientId/AccountId/CreatedAt and `Set` for Info/UpdatedAt
- `ArchivedAt` is **not** included in the update — MongoDB preserves existing field values when not mentioned in `$set`
- The `filter` for `Version > 0` is `x.Id == client.Id && x.Version == client.Version && x.DeletedAt == null`
- Does **not** check `ArchivedAt`, so editing archived clients works correctly
- **No code changes needed**

---

## Phase 3: Paged Query

### 3.1 Add `ArchivedAt == null` filter to `ByAccountAndClientName.Predicate()`

**File:** `Invoices.Core/Repositories/PageQueries/ClientsQueries.cs`

Current predicate:
```csharp
public Expression<Func<ManageableClient, bool>> Predicate()
{
    return entity => entity.AccountId == AccountId && entity.DeletedAt == null;
}
```

Updated predicate:
```csharp
public Expression<Func<ManageableClient, bool>> Predicate()
{
    return entity => entity.AccountId == AccountId
        && entity.DeletedAt == null
        && entity.ArchivedAt == null;
}
```

No `IncludeArchived` property needed — paged endpoint always excludes archived clients per spec.

---

## Phase 4: Service Layer

### 4.1 Add `ArchiveClient` to `IClientsService`

**File:** `Invoices.Common/Services/Clients/IClientsService.cs`

```csharp
Task ArchiveClient(string accountId, string clientId, CancellationToken ct);
```

### 4.2 Implement `ArchiveClient` in `ClientsService`

**File:** `Invoices.Implementation.Services/Clients/ClientsService.cs`

- Delegate to `_clientsRepository.Archive(accountId, clientId, ct)`

### 4.3 Add `includeArchived` parameter to non-paged `GetClients`

**File:** `Invoices.Common/Services/Clients/IClientsService.cs`

Update signature:
```csharp
Task<IReadOnlyCollection<ManageableClient.WithCalc>> GetClients(
    string accountId,
    bool includeDeleted,
    bool includeArchived,
    bool includeCalculations,
    CancellationToken ct);
```

**File:** `Invoices.Implementation.Services/Clients/ClientsService.cs`

Pass `includeArchived` through to repository:
```csharp
var clients = await _clientsRepository.GetClientsByAccountId(accountId, includeDeleted, includeArchived, ct);
```

### 4.4 Paged `GetClients` — NO changes

- The paged overload `GetClients(cursor, limit, token, ct)` uses `ClientsQueries.ByAccountAndClientName`
- The predicate already filters `ArchivedAt == null` (Phase 3.1)
- No signature or implementation changes needed

---

## Phase 5: DTO & Mapping

### 5.1 Add `ArchivedAt` to `ManageableClientDto`

**File:** `Invoices.Api/Models/Clients/ManageableClientDto.cs`

- Add `public DateTime? ArchivedAt { get; init; }` to the base `ManageableClientDto`

### 5.2 Update mapping `ManageableClient → ManageableClientDto`

**File:** `Invoices.Api/Models/Mapping.cs`

In `Map(this ManageableClient client)`:
```csharp
return new ManageableClientDto.WithCalc
{
    Id = client.ClientId,
    Info = client.Info.First().Map(),
    Version = client.Version,
    CreatedAt = client.CreatedAt,
    UpdatedAt = client.UpdatedAt,
    ArchivedAt = client.ArchivedAt,  // ← add
};
```

### 5.3 Verify mapping `ManageableClientDto → ManageableClient` (no change)

**File:** `Invoices.Api/Models/Mapping.cs`

In `Map(this ManageableClientDto client, string accountId)`:
- Does NOT set `ArchivedAt` — this is correct
- Creating/editing a client via POST should not touch archive status
- MongoDB `Upsert` preserves existing `ArchivedAt` value (not mentioned in `$set`)

---

## Phase 6: Controller

### 6.1 Update `DeleteClient` endpoint

**File:** `Invoices.Api/Controllers/ClientsController.cs`

Replace current logic:
```
BEFORE: check jobs → throw ClientHasJobsException if exists → delete
AFTER:  check jobs → if exists: archive + return 200 → else: delete + return 204
```

Current code:
```csharp
[HttpDelete("{clientId}")]
public async Task<IActionResult> DeleteClient(string clientId, CancellationToken ct)
{
    var query = new CheckJobsExistForClientQuery(AccountId, clientId);
    var result = await _dispatcher.DispatchQuery<...>(query, ct);

    if (result.Exists)
    {
        throw new ClientHasJobsException(clientId);
    }

    await _clientsService.DeleteClient(AccountId, clientId, ct);
    return NoContent();
}
```

New code:
```csharp
[HttpDelete("{clientId}")]
public async Task<ActionResult<DeletedResultDto>> DeleteClient(string clientId, CancellationToken ct)
{
    var query = new CheckJobsExistForClientQuery(AccountId, clientId);
    var result = await _dispatcher.DispatchQuery<...>(query, ct);

    if (result.Exists)
    {
        await _clientsService.ArchiveClient(AccountId, clientId, ct);
        return Ok(new DeletedResultDto { IsArchived = true });
    }

    await _clientsService.DeleteClient(AccountId, clientId, ct);
    return NoContent();
}
```

**New DTO:**

**File:** `Invoices.Api/Models/DeletedResultDto.cs` (new)

```csharp
public sealed class DeletedResultDto
{
    public required bool IsArchived { get; init; }
}
```

### 6.2 Add `includeArchived` to non-paged `GetClients` endpoint

**File:** `Invoices.Api/Controllers/ClientsController.cs`

Current:
```csharp
[HttpGet]
public async Task<ActionResult<ManageableClientsDto>> GetClients(
    [FromQuery] bool includeCalculations = false, CancellationToken ct = default)
{
    return new ManageableClientsDto
    {
        ManageableClients = (await _clientsService.GetClients(AccountId, false, includeCalculations, ct)).Map()
    };
}
```

Updated:
```csharp
[HttpGet]
public async Task<ActionResult<ManageableClientsDto>> GetClients(
    [FromQuery] bool includeCalculations = false,
    [FromQuery] bool includeArchived = false,
    CancellationToken ct = default)
{
    return new ManageableClientsDto
    {
        ManageableClients = (await _clientsService.GetClients(
            AccountId, false, includeArchived, includeCalculations, ct)).Map()
    };
}
```

### 6.3 `GetItemsPaged` — NO changes

- Paged endpoint always excludes archived clients
- Filtering handled by `ByAccountAndClientName.Predicate()` (Phase 3.1)
- No `includeArchived` query parameter on paged endpoint

### 6.4 `GetClient` (by ID) — NO changes

- Calls `GetClientById` which does not filter `ArchivedAt` (Phase 2.4)
- Archived clients always accessible by direct ID

### 6.5 `AddClient` (POST) — NO changes

- Calls `UpdateOrCreate` → `Upsert` which preserves `ArchivedAt` (Phase 2.5)
- Archived clients editable, archive status preserved

---

## Phase 7: Jobs Integration

### 7.1 Block new job creation for archived clients

`JobClientsService.GetClient()` — **NO changes**. Клиент должен доставаться всегда, включая архивных. Проверка архивации — ответственность хэндлеров при создании нового job.

**Primary path — `UpsertJobCommandHandler`:**

**File:** `Jobs.Application/Commands/UpsertJobCommandHandler.cs`

- In `ApplyUpdates()` (~line 69), client is already fetched via `_jobClientsService.GetClient()`
- After getting the client, when creating a **new** job (`isNew == true`): check `client.ArchivedAt != null` → throw `ClientArchivedException`
- Updating existing job for archived client — allowed (no check)

**Secondary path — `CreateJobFromEstimateCommandHandler`:**

**File:** `Jobs.Application/Commands/CreateJobFromEstimateCommandHandler.cs`

- Creates job from estimate, gets `clientId` from estimate without any client validation
- This is a pre-existing gap (no client existence check at all)
- Add: fetch client via `IJobClientsService.GetClient()` before creating job, check `ArchivedAt`

**New exception + error handling (по аналогии с `ClientHasJobsException`):**

**File:** `Invoices.Core/Exceptions/ClientArchivedException.cs` (new)

```csharp
/// <summary> Thrown when attempting to create a job for an archived client. </summary>
public class ClientArchivedException : Exception
{
    public string ClientId { get; }

    public ClientArchivedException(string clientId)
        : base($"Cannot create job for archived client '{clientId}'")
    {
        ClientId = clientId;
    }
}
```

**File:** `Invoices.Api/Middleware/ErrorCode.cs`

Add new error code:
```csharp
[EnumMember(Value = "clientArchived")]
ClientArchived,
```

**File:** `Invoices.Api/Middleware/ApiExceptionHandlingMiddleware.cs`

Add mapping (рядом с `ClientHasJobsException`):
```csharp
new Map<ClientArchivedException>(HttpStatusCode.BadRequest, ErrorCode.ClientArchived, false,
    e => e.Message, logLevel: LogLevel.Warning),
```

**API error response:**
```json
{
    "errorCode": "clientArchived",
    "message": "Cannot create job for archived client 'abc123'"
}
```

### 7.2 Job details — client loading (verify only)

- Job details loads client data via `GetClientById`
- Since `GetClientById` does NOT filter `ArchivedAt`, archived client data loads correctly
- **No code changes needed** — just verify

---

## Phase 8: Update all callers of `GetClientsByAccountId`

After adding `includeArchived` parameter (Phase 2.3), update all callers:

**File:** `Invoices.Implementation.Services/Clients/ClientsService.cs`

| Caller | Line | Current call | `includeArchived` | Reason |
|--------|------|-------------|-------------------|--------|
| `GetClients` (non-paged) | ~190 | `GetClientsByAccountId(accountId, includeDeleted, ct)` | from controller param | User controls visibility |
| `GetClientsByIds` | ~300 | `GetClientsByAccountId(accountId, false, ct)` | `true` | Used by Jobs/Visits — must see archived clients |
| `MigrateOldData` (1st) | ~100 | `GetClientsByAccountId(accountId, true, ct)` | `true` | Migration needs all clients |
| `MigrateOldData` (2nd) | ~150 | `GetClientsByAccountId(accountId, false, ct)` | `true` | Migration verification needs all clients |

**Test file:** `Invoices.Tests/Services/ClientsServiceTest.cs`

- Update mock setup for `GetClientsByAccountId` to match new signature (`It.IsAny<bool>()` for `includeArchived`)

---

## Phase 9: Tests

### 9.1 Unit tests — ClientsService

- `ArchiveClient_CallsRepositoryArchive` — verify delegation
- `GetClients_Default_ExcludesArchived` — archived clients filtered from list
- `GetClients_IncludeArchived_ReturnsAll` — includeArchived flag works

### 9.2 Unit tests — ClientsController

- `DeleteClient_NoJobs_Returns204_SoftDeletes` — existing behavior preserved
- `DeleteClient_HasJobs_Returns200_Archives` — new auto-archive behavior
- `GetClients_Default_ExcludesArchived` — archived not in default results
- `GetClients_IncludeArchived_ReturnsArchived` — flag works
- `GetItemsPaged_ExcludesArchived` — paged always excludes archived

### 9.3 Unit tests — ClientsRepository

- `Archive_SetsArchivedAt_IncrementsVersion`
- `Archive_DeletedClient_ThrowsEntityNotFound`
- `GetClientsByAccountId_ExcludesArchived_ByDefault`
- `GetClientsByAccountId_IncludesArchived_WhenFlagTrue`
- `GetClientById_ReturnsArchivedClient`
- `Upsert_PreservesArchivedAt`

### 9.4 Unit tests — Job creation

- `UpsertJob_ArchivedClient_NewJob_ThrowsClientArchivedException`
- `UpsertJob_ArchivedClient_UpdateExistingJob_Succeeds`
- `CreateJobFromEstimate_ArchivedClient_ThrowsClientArchivedException`

### 9.5 Integration tests — API level

- DELETE client without jobs → 204, client has DeletedAt
- DELETE client with jobs → 200 `DeletedResultDto { isArchived: true }`, client has ArchivedAt
- GET /clients → archived client not in list
- GET /clients?includeArchived=true → archived client in list
- GET /clients/{id} → returns archived client
- GET /clients/paged → archived client not in list (always)
- POST /clients (edit archived) → success, ArchivedAt preserved
- Create job for archived client → 400 `{ errorCode: "clientArchived" }`
- Update existing job for archived client → success

---

## Execution Checklist

| # | Task | Files | Status |
|---|------|-------|--------|
| 1.1 | Add `ArchivedAt` to `ManageableClient` | `Invoices.Core/Models/Clients/ManageableClient.cs` | |
| 1.2 | Propagate in `WithCalc.From()` | same file | |
| 2.1 | Add `Archive` to `IClientsRepository` | `Invoices.Core/Repositories/IClientsRepository.cs` | |
| 2.2 | Implement `Archive` | `Invoices.Implementation.MongoDb/Repositories/ClientsRepository.cs` | |
| 2.3 | Add `includeArchived` to `GetClientsByAccountId` | `IClientsRepository` + `ClientsRepository` | |
| 2.4 | Verify `GetClientById` (no change) | `ClientsRepository` | |
| 2.5 | Verify `Upsert` preserves ArchivedAt (no change) | `ClientsRepository` | |
| 3.1 | Add `ArchivedAt == null` to paged query predicate | `Invoices.Core/Repositories/PageQueries/ClientsQueries.cs` | |
| 4.1 | Add `ArchiveClient` to `IClientsService` | `Invoices.Common/Services/Clients/IClientsService.cs` | |
| 4.2 | Implement `ArchiveClient` | `Invoices.Implementation.Services/Clients/ClientsService.cs` | |
| 4.3 | Add `includeArchived` to non-paged `GetClients` | `IClientsService` + `ClientsService` | |
| 5.1 | Add `ArchivedAt` to DTO | `Invoices.Api/Models/Clients/ManageableClientDto.cs` | |
| 5.2 | Update model→DTO mapping | `Invoices.Api/Models/Mapping.cs` | |
| 5.3 | Verify DTO→model mapping (no change) | same file | |
| 6.1a | Create `DeletedResultDto` | `Invoices.Api/Models/DeletedResultDto.cs` | |
| 6.1b | Rewrite `DeleteClient` logic | `Invoices.Api/Controllers/ClientsController.cs` | |
| 6.2 | Add `includeArchived` to GET /clients | same file | |
| 7.1a | Create `ClientArchivedException` | `Invoices.Core/Exceptions/ClientArchivedException.cs` | |
| 7.1b | Add `ClientArchived` to `ErrorCode` enum | `Invoices.Api/Middleware/ErrorCode.cs` | |
| 7.1c | Add exception→HTTP mapping in middleware | `Invoices.Api/Middleware/ApiExceptionHandlingMiddleware.cs` | |
| 7.1d | Add archive check in `UpsertJobCommandHandler` (new jobs only) | `Jobs.Application/Commands/UpsertJobCommandHandler.cs` | |
| 7.1e | Add archive check in `CreateJobFromEstimateCommandHandler` | `Jobs.Application/Commands/CreateJobFromEstimateCommandHandler.cs` | |
| 7.2 | Verify job details loads archived client (no change) | Job details service | |
| 8.1 | Update `GetClientsByIds` caller (`includeArchived: true`) | `ClientsService.cs` | |
| 8.2 | Update `MigrateOldData` callers (`includeArchived: true`) | `ClientsService.cs` | |
| 8.3 | Update test mocks for new signature | `ClientsServiceTest.cs` | |
| 9.x | Write tests | `Invoices.Tests/`, `Invoices.Tests.Integration/` | |
