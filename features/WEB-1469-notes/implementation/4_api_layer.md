# Step 4: API Layer

> References: [`../overview.md` → Endpoints](../overview.md#endpoints),
> [`../overview.md` → DTOs](../overview.md#dtos),
> [`3_application_layer.md`](3_application_layer.md).

Five v3 routes on a single `NotesController` (`Src/Invoices.Api/Controllers/NotesController.cs`),
sharing one set of API DTOs. The controller stays thin: it parses the request, resolves the
caller's author triple (`MasterUserId`, `Role`, `DisplayName`), dispatches a command / query,
and maps the result back. All business rules live in step 3's handlers.

---

## 4.1 API DTOs

**Folder:** `Src/Invoices.Api/Dto/Notes/`.

Wire shape mirrors `NoteContractDto` (step 3 §3.1) exactly — flat field-by-field copy.

```csharp
// NoteDto.cs — read response.
public sealed record NoteDto(
    Guid Id,
    int Version,
    string? ClientId,                       // null on visit-notes
    Guid? VisitId,                          // null on client-notes
    NoteVisibilityDto Visibility,           // reused from Jobs.Contracts.Notes
    string Message,
    NoteAuthorDto Author,
    DateTimeOffset CreatedAt,
    DateTimeOffset? UpdatedAt,
    bool IsEdited);

public sealed record NoteAuthorDto(string MasterUserId, string DisplayName);

// SaveNoteDto.cs — PUT /api/notes body.
public sealed record SaveNoteDto(
    Guid Id,                                // caller-supplied UUID v4
    int Version,                            // 0 on create; current row Version on update
    string? ClientId,                       // anchor for a client-note
    Guid? VisitId,                          // anchor for a visit-note
    NoteVisibilityDto Visibility,           // ignored on visit-notes (forced to Team in domain)
    string Message,
    bool IsEdited = false);

// GetNotesResponseDto.cs — wraps GET /api/notes/all (no cursor).
public sealed record GetNotesResponseDto(IReadOnlyList<NoteDto> Items);
```

`NoteVisibilityDto` is reused from `Jobs.Contracts.Notes` (already string-encoded via
`[JsonConverter(typeof(StringEnumConverter))]`) — no separate API copy.

The sync surface reuses the shared envelopes:

- `SyncResponseDto<NoteDto>` from `Src/Invoices.Api/Dto/SyncResponseDto.cs`.
- `SyncChangeItemDto<NoteDto>` from `Src/Invoices.Api/Dto/SyncChangeItemDto.cs`.

No `Relations` variant — notes have no related-entity needs in v1.

---

## 4.2 Caller resolution

For every action the controller needs `(MasterUserId, Role)`; the **PUT** path additionally
needs `DisplayName` to freeze into `NoteAuthor` on create. The three pieces come from
different sources — all resolved inline inside `NotesController`, no extra service layer:

- `MasterUserId` — `BaseController.GetRequiredMasterUser().Id` (set by
  `AccountAuthenticationMiddleware`, no round-trip).
- `Role` — `IAuthorizationContext.HasRole(Role.Admin | Role.Worker)` from
  `Tofu.Permissions.Shared` (populated by `AccessMiddleware` from the already-cached tenant
  membership). Mapping to `Invoices.Core.Models.Team.TeamMemberRole` is a 1-to-1 match with
  `Unknown` as the safe fallback. No Tofu.Auth call.
- `DisplayName` — `ITofuAuthApiClient.GetTenantUserAsync(accountId, userGuid, ct)` →
  `tenantUser.ContactName ?? tenantUser.UserName ?? "Unknown"`. **PUT only.** This is the one
  place that pays the Tofu.Auth round-trip.

The controller exposes two private helpers — `ResolveCaller()` (the `(MasterUserId, Role)`
pair) and `ResolveDisplayName(masterUserId, ct)` (only called from `Save`). There is no
separate `NotesAuthorService`: the previous draft introduced one, but the indirection didn't
earn its keep — the only call site was a single `Save` line, and the Tofu.Auth client is
already injectable.

---

## 4.3 `NotesController`

**File:** `Src/Invoices.Api/Controllers/NotesController.cs`.

Shape mirrors `JobsController` — `[ApiVersion("3.0")]`, `[ApiController]`,
`[Route("api/notes")]`, inherits `BaseController`.

```csharp
[ApiVersion("3.0")]
[ApiController]
[Route("api/notes")]
public sealed class NotesController(
    IHandlerDispatcher             dispatcher,
    ITofuAuthApiClient             authClient,       // PUT only — fetches DisplayName
    IAuthorizationContext          authContext,      // Role for everything else
    IValidator<SaveNoteCommand>    saveValidator,
    IValidator<DeleteNoteCommand>  deleteValidator,
    IValidator<GetNoteByIdQuery>   getByIdValidator,
    IValidator<GetNotesQuery>      getNotesValidator,
    IValidator<SyncNotesQuery>     syncValidator,
    IOptions<TimelineOptions>      options) : BaseController
{
    private const int DefaultSyncPageSize = 100;

    // Reads + DELETE: pull (MasterUserId, Role) from the auth context — no round-trip.
    private (string MasterUserId, TeamMemberRole Role) ResolveCaller() =>
        (GetRequiredMasterUser().Id, MapRole());

    private TeamMemberRole MapRole() =>
        authContext.HasRole(Role.Admin)  ? TeamMemberRole.Admin  :
        authContext.HasRole(Role.Worker) ? TeamMemberRole.Worker :
        TeamMemberRole.Unknown;

    // PUT only: frozen into NoteAuthor on the create branch. One Tofu.Auth round-trip per save.
    private async Task<string> ResolveDisplayName(string masterUserId, CancellationToken ct)
    {
        if (!Guid.TryParse(masterUserId, out var userGuid))
            throw new MasterUserNotFoundException(...);

        var tenantUser = await authClient.GetTenantUserAsync(AccountId, userGuid, ct);
        return tenantUser.ContactName ?? tenantUser.UserName ?? "Unknown";
    }
    ...
}
```

`TimelineOptions.DelayNextRequestInSeconds` is reused for the sync envelope — same as
`JobsController.Sync()`. Each action builds its command / query, runs
`validator.ValidateAndThrowAsync(...)` against the FluentValidation rule (see
`Jobs.Application/Notes/Validators/*` — page-size bounds, anchor XOR, non-empty Id, etc.),
then dispatches. Validation failures surface as `ValidationException` →
`ApiExceptionHandlingMiddleware` → 400. The controller carries no inline `if limit < 1 ...`
checks — those rules live with the command/query they constrain.

### `GET /api/notes/sync`

```text
[HttpGet("sync")] [MapToApiVersion("3.0")] [AuthorizeAction(PermissionKeys.Note.View)]
Sync(string? cursor, int limit = 100):
    caller = ResolveCaller()
    query  = new SyncNotesQuery(AccountId, caller.MasterUserId, caller.Role, limit, cursor)
    await syncValidator.ValidateAndThrowAsync(query, ct)    # PageSize ∈ [1, 500]

    result = await dispatcher.DispatchQuery<SyncNotesQuery, SyncNotesResult>(query, ct)

    return new SyncResponseDto<NoteDto>
    {
        Items = result.Items.Select(i => new SyncChangeItemDto<NoteDto>
                {
                    ItemId = i.ItemId,
                    Change = i.Change.ToDto(),
                    Item   = i.Item?.ToApi(),
                }).ToList(),
        NextCursor                = result.NextCursor,         // non-null by contract
        HasMore                   = result.HasMore,
        DelayNextRequestInSeconds = options.Value.DelayNextRequestInSeconds,
    }
```

### `GET /api/notes/{noteId}`

```text
[HttpGet("{noteId:guid}")] [MapToApiVersion("3.0")] [AuthorizeAction(PermissionKeys.Note.View)]
GetById(Guid noteId):
    caller = ResolveCaller()
    query  = new GetNoteByIdQuery(AccountId, caller.MasterUserId, caller.Role, noteId)
    await getByIdValidator.ValidateAndThrowAsync(query, ct)  # NoteId not empty

    result = await dispatcher.DispatchQuery<GetNoteByIdQuery, GetNoteByIdResult>(query, ct)
    if result.Note is null: throw EntityNotFoundException     # → 200 + ErrorCode.NotFound
    return result.Note.ToApi()
```

### `GET /api/notes/all`

```text
[HttpGet("all")] [MapToApiVersion("3.0")] [AuthorizeAction(PermissionKeys.Note.View)]
GetAll(string? clientId = null, Guid? visitId = null):
    caller = ResolveCaller()
    query  = new GetNotesQuery(AccountId, caller.MasterUserId, caller.Role, clientId, visitId)
    await getNotesValidator.ValidateAndThrowAsync(query, ct)  # ClientId XOR VisitId

    result = await dispatcher.DispatchQuery<GetNotesQuery, GetNotesResult>(query, ct)
    return new GetNotesResponseDto(result.Items.Select(i => i.ToApi()).ToList())
```

Passing neither filter falls through to the account-wide path (sequential scan — see
[`2_persistence.md` §2.2.6](2_persistence.md#226-indexes)).

### `PUT /api/notes`

```text
[HttpPut] [MapToApiVersion("3.0")] [AuthorizeAction(PermissionKeys.Note.Manage)]
Save([FromBody] SaveNoteDto body):
    ArgumentNullException.ThrowIfNull(body)
    # Save is the only path that needs DisplayName — frozen into NoteAuthor on the create
    # branch — so this is the only action that pays the Tofu.Auth round-trip.
    caller      = ResolveCaller()
    displayName = await ResolveDisplayName(caller.MasterUserId, ct)
    command     = new SaveNoteCommand(
        AccountId, caller.MasterUserId, caller.Role, displayName,
        body.Id, body.Version, body.ClientId, body.VisitId, body.Visibility,
        body.Message, body.IsEdited,
        OccurredAt: GetClientEventTime())
    await saveValidator.ValidateAndThrowAsync(command, ct)   # Id / Message / Version / anchor-XOR

    result = await dispatcher.DispatchCommand<SaveNoteCommand, SaveNoteResult>(command, ct)
    return result.Note.ToApi()
```

`GetClientEventTime()` (inherited from `BaseController`) reads `XA-Client-Event-Ms`; null falls
through to `DateTimeOffset.UtcNow` inside the domain factories. The anchor-XOR contract is
enforced by `SaveNoteCommandValidator` before dispatch (handler factories still hold a
defensive guard, but it's unreachable through this code path).

### `DELETE /api/notes/{noteId}`

```text
[HttpDelete("{noteId:guid}")] [MapToApiVersion("3.0")] [AuthorizeAction(PermissionKeys.Note.Manage)]
Delete(Guid noteId):
    caller  = ResolveCaller()
    command = new DeleteNoteCommand(AccountId, caller.MasterUserId, caller.Role, noteId,
                                    OccurredAt: GetClientEventTime())
    await deleteValidator.ValidateAndThrowAsync(command, ct) # NoteId not empty

    await dispatcher.DispatchCommand<DeleteNoteCommand, DeleteNoteResult>(command, ct)
    # 200 with empty body. Already-tombstoned → idempotent 200 (step 3 §3.4).
```

Cross-account / missing id → `EntityNotFoundException` → HTTP 200 + `ErrorCode.NotFound` via
`ApiExceptionHandlingMiddleware`. Forbidden paths surface as `NoteWriteForbiddenException` →
403.

---

## 4.4 Contract ↔ API mapping

**File:** `Src/Invoices.Api/Dto/Notes/NotesApiMappings.cs`.

Flat field-by-field copy between `NoteContractDto` and `NoteDto`. No computed fields — every
derivation (`IsEdited`) already happened in the contract layer (step 3 §3.6).

```csharp
internal static class NotesApiMappings
{
    public static NoteDto       ToApi(this NoteContractDto c)       => new(c.Id, c.Version, c.ClientId,
                                                                            c.VisitId, c.Visibility,
                                                                            c.Message, c.Author.ToApi(),
                                                                            c.CreatedAt, c.UpdatedAt,
                                                                            c.IsEdited);
    public static NoteAuthorDto ToApi(this NoteAuthorContractDto c) => new(c.MasterUserId, c.DisplayName);
}
```

The wire enum `NoteVisibilityDto` is the same type on both layers — no conversion needed.
`SyncChangeType` reuses the shared `SyncChangeTypeMappings.ToDto` (already present in
`Src/Invoices.Api/Dto/SyncChangeItemDto.cs`).

---

## 4.5 Errors

Wire-shape errors are produced by `ApiExceptionHandlingMiddleware` (existing). The handlers in
step 3 emit the right exceptions; the API layer just lets them bubble:

| Exception | Wire shape |
|---|---|
| `ValidationException` (FluentValidation — anchors, missing id, bad limit, …) | HTTP 400 |
| `ArgumentException` (residual guards, framework-level checks like null body) | HTTP 400 |
| `EntityNotFoundException` (cross-account, unknown id, unknown visit / client) | HTTP 200 + `ErrorCode.NotFound` |
| `NoteWriteForbiddenException` (worker editing other's note, visit-completion lock) | HTTP 403 |
| `VersionMismatchException` (in-memory check) | HTTP 200 + `ErrorCode.VersionMismatch` |
| `DbUpdateConcurrencyException` (EF token race) | HTTP 200 + `ErrorCode.VersionMismatch` |

No try/catch in the controller; no `return NotFound()` / `return BadRequest()`. Per the
project convention, exceptions drive the wire shape end-to-end.

---

## Execution Checklist

| # | Task | Files |
|---|------|-------|
| 4.1 | `NoteDto`, `NoteAuthorDto`, `SaveNoteDto`, `GetNotesResponseDto` | `Src/Invoices.Api/Dto/Notes/*.cs` |
| 4.2 | `ResolveCaller()` + `ResolveDisplayName(...)` private helpers on `NotesController` — no separate service | `Src/Invoices.Api/Controllers/NotesController.cs` |
| 4.3 | `NotesController` with 5 endpoints; injects `IAuthorizationContext` for `(MasterUserId, Role)` on every action, `ITofuAuthApiClient` for the PUT-only `DisplayName` fetch, and `IValidator<...>` per command/query for `ValidateAndThrowAsync` before dispatch | `Src/Invoices.Api/Controllers/NotesController.cs` |
| 4.3 | FluentValidation rules (`SaveNoteCommandValidator`, `DeleteNoteCommandValidator`, `GetNoteByIdQueryValidator`, `GetNotesQueryValidator`, `SyncNotesQueryValidator`) — Id non-empty, anchor XOR on save, page-size bounds on sync, etc. | `Src/Jobs/Jobs.Application/Notes/Validators/*.cs` |
| 4.4 | `NotesApiMappings` (contract → API DTO) | `Src/Invoices.Api/Dto/Notes/NotesApiMappings.cs` |
