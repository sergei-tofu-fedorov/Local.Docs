# WEB-1625 — Sync endpoints for Clients and Items

Add `GET /api/clients/sync` and `GET /api/items/sync` so web/iOS clients keep a local cache of **clients** and **items** in sync — same cursor-paged, tombstone-carrying protocol as jobs, invoices, and estimates. Each call returns a page of changes (created/updated + tombstones for deletes), an opaque `NextCursor`, `HasMore`, and a `DelayNextRequestInSeconds` throttle hint.

Single repo: **`Invoices.Backend`** (BFF). Clients and items live **locally in MongoDB** (no gRPC round trip), so unlike invoices/estimates this is built end-to-end in this repo against the existing Mongo repositories.

**Proven precedent — replicate, don't reinvent.** Invoice/estimate sync was built in the producer `Tofu.Invoices.Backend` over MongoDB (**INVC-3561** invoices, `fbd97eb`; **FS-977** estimates, `874816e`). This plan mirrors it field-for-field: a `(ModifiedTime, UniqueId)` keyset cursor, server-stamped modified time, a soft-delete flag included in the changed-since read, and a `(AccountId, ModifiedTime, UniqueId)` index — **no counter, no outbox**. Only the location differs: it lives in the BFF's own Mongo repositories (not behind gRPC), since the BFF owns this data.

Producer reference files (read these alongside this plan):

- `Tofu.Invoices.Backend/src/Tofu.Invoices.Domain/Queries/SyncInvoices/InvoiceSyncCursor.cs` — cursor record + helpers (we mirror the `(ModifiedTimeMs, UniqueId)` shape; for the base64 serializer itself we reuse the workspace-shared `Invoices.Common.Pagination.CursorSerializer`, not a copy of the producer's)
- `…/Queries/SyncInvoices/SyncInvoicesQueryHandler.cs` — page+1 / hasMore / tombstone derivation
- `…/Infrastructure/Repositories/InvoicesRepository.cs:186` — `GetChangedSince` keyset filter+sort
- `…/Infrastructure/Repositories/Shared/VersionedEntityRepository.cs:61` — `.CurrentDate(ModifiedTime)` server stamp
- `…/Infrastructure/Database/MongoDbContext.cs:63` — `(AccountId, ModifiedTime, UniqueId)` index

Related ClickUp tasks:

- https://app.clickup.com/t/WEB-1625 (this initiative)
- Producer precedent: INVC-3561 (invoice sync), FS-977 (estimate sync) — in `Tofu.Invoices.Backend`

## Code layout

The map of what changes. Single repo: `Invoices.Backend`. New files unmarked; `# touch:` marks edits to existing files. Detail on each piece is in the sections below.

```
Src/Invoices.Api/
  Controllers/ClientsController.cs            # touch: + GET clients/sync action; inject IOptions<TimelineOptions>; body is `return result.ToDto(c => c.Map(), delay)`  [Client.View]
  Controllers/ItemsController.cs              # touch: + GET items/sync action;   inject IOptions<TimelineOptions>; body is `return result.ToDto(i => i.Map(), delay)`  [Item.Manage]
  Models/Mapping.cs                           # touch: + the generic SyncChangeItem<T>.ToDto(mapItem) + SyncResponseModel<T>.ToDto(mapItem, delay)

Src/Invoices.Common/
  Pagination/CursorSerializer.cs              # MOVED here from Jobs.Domain.Pagination (base64 camelCase JSON); now shared by jobs + clients/items
  Pagination/ClientSyncCursor.cs              # record (long ModifiedTimeMs, string UniqueId) + Create/GetModifiedTimeUtc/Serialize/Deserialize (uses CursorSerializer; Deserialize -> null on empty/bad token)
  Pagination/ItemSyncCursor.cs                # same shape for items
  Models/SyncResponseModel.cs                 # generic record (IReadOnlyList<SyncChangeItem<T>> Items, string? NextCursor, bool HasMore) — shared by clients/items only
  Services/Clients/IClientsService.cs         # touch: + SyncClients(...) : SyncResponseModel<ManageableClient>
  Services/Items/IItemsService.cs             # touch: + SyncItems(...) : SyncResponseModel<ManageableItem>

Src/Invoices.Core/
  Models/Clients/SyncClientsRequestModel.cs   # AccountId/Cursor/Limit + Min/Default/Max = 1/100/500
  Models/Items/SyncItemsRequestModel.cs       # same
  Repositories/IClientsRepository.cs          # touch: + GetChangedSince(accountId, modifiedTimeExclusive, uniqueIdExclusive, limit, ct)
  Repositories/IItemsRepository.cs            # touch: + GetChangedSince(...)

Src/Invoices.Implementation.Services/
  Clients/ClientsService.cs                   # touch: implement SyncClients — cursor (de)serialize + change-type derivation
  Items/ItemsService.cs                       # touch: implement SyncItems

Src/Invoices.Implementation.MongoDb/
  Extensions/MongoCollectionExtensions.cs     # touch: + FindWithSession(FilterDefinition) overload (existing one took only Expression)
  Repositories/ClientsRepository.cs           # touch: + GetChangedSince (keyset, via FindWithSession); .CurrentDate(UpdatedAt) in Delete, Archive, BulkDeleteInternal, DeleteAllByAccountId
  Repositories/ItemsRepository.cs             # touch: + GetChangedSince (keyset, via FindWithSession); .CurrentDate(UpdatedAt) in DeleteItem, BulkDeleteInternal
  Repositories/Shared/MongoDbContext.cs       # touch: + (AccountId, UpdatedAt, _id) index on clients & items in Configure()
```

No new DI registration — every interface above is already registered; only methods are added.

**Shared refactors (reach wider than clients/items).** Two consolidations done as part of this work touch the other sync features:

- `CursorSerializer` was **moved** from `Jobs.Domain.Pagination` to `Invoices.Common.Pagination` (`Jobs.Domain` already references `Invoices.Common`) and is now the single serializer for jobs, notes, and clients/items. The 9 Jobs/Notes consumers (handlers + tests) gain `using Invoices.Common.Pagination;`; their cursor records stay in `Jobs.Domain.Pagination`. The earlier-planned `SyncCursorSerializer` copy was dropped in favour of reusing this one.
- The generic `SyncChangeItem<T>.ToDto(mapItem)` extension replaces the hand-written change-item mapping in **every** sync controller — jobs / invoices(V3) / estimates / notes now do `result.Items.Select(i => i.ToDto(mapItem)).ToList()`; clients/items use the response-level `result.ToDto(mapItem, delay)`.

## Scope

**In scope**

- `GET /api/clients/sync` and `GET /api/items/sync`, API version 3.0, mirroring the existing sync response envelope (`SyncResponseDto<T>`).
- Cursor-paged `GetChangedSince` reads over the `clients` and `items` Mongo collections, **including soft-deleted records** so clients can prune their local cache.
- Bumping the modified-time field on every delete/archive write path (required for the cursor to observe deletions — see High-level approach).
- New `(AccountId, UpdatedAt, _id)` Mongo indexes on both collections (mirroring the producer's `(AccountId, ModifiedTime, UniqueId)` index).

**Out of scope**

- Adding a monotonic `SequenceId` to clients/items — the producer rejected a counter for the same reason; the keyset cursor needs none.
- Any change to `Tofu.Auth.Backend` or to permission keys (both gating keys already exist).
- Relations expansion (the jobs `includeRelations` knob). Clients and items are leaf resources with no related entities to hydrate.
- Real-time push / websockets. Polling only, same as the existing sync endpoints.

## High-level approach

Mirror the **invoices/estimates** shape (controller → app service → repository, returning a `Sync…ResponseModel`), not the **jobs** CQRS-dispatcher shape. Clients and items already run as plain services (`IClientsService`, `IItemsService`) over Mongo repositories (`IClientsRepository` / `IItemsRepository`); adding the dispatcher just for sync would bolt on a layer the module doesn't use.

**Cursor = `(ModifiedTimeMs, UniqueId)` keyset, exactly as the producer.** The producer's `InvoiceSyncCursor` is `(long ModifiedTimeMs, string UniqueId)` — epoch-millis of the server-stamped modified time, plus the unique composite id as same-millisecond tie-breaker. The BFF already has both fields: modified time is `UpdatedAt` (`DateTime?`); the unique id is the composite `Id` (`AccountId|ClientId` / `AccountId|ItemId`), which *is* the Mongo `_id`. No new field, no counter, no backfill.

| | `(ModifiedTime, UniqueId)` keyset (chosen — producer's pattern) | Mongo `SequenceId` counter (rejected — producer rejected it too) |
|---|---|---|
| New persisted field | none (reuse `UpdatedAt` + `Id`) | `long SequenceId` on both docs |
| Write-path cost | stamp modified time (already done on upsert) | extra `findAndModify $inc` per write |
| Backfill of existing docs | none | required |
| Robustness | server-stamped time + id tie-break; no skew if stamped via `.CurrentDate()` | exact, monotonic |

The keyset's one cost: **the modified-time field must advance on every mutation, including soft-delete and archive.** Today it doesn't — `Delete` (`ClientsRepository.cs:199`) and `Archive` (`:183`) set `DeletedAt` / `ArchivedAt` but **not** `UpdatedAt`; same for `BulkDeleteInternal` (`:42`), `DeleteAllByAccountId` (`:211`), and `ItemsRepository.DeleteItem` (`:179`) / `BulkDeleteInternal` (`:98`). Without the fix, a deleted record's `UpdatedAt` is unchanged and its tombstone is **never** emitted. Hard requirement, not polish.

**Stamp the modified time server-side.** The producer uses Mongo's `.CurrentDate(e => e.ModifiedTime)` (`VersionedEntityRepository.cs:61`) — server clock, skew-proof. The BFF's upserts use app-side `.Set(x => x.UpdatedAt, DateTime.UtcNow)` (`ClientsRepository.cs:107`, `ItemsRepository.cs:31`). Stamp the new delete/archive bumps with **`.CurrentDate(x => x.UpdatedAt)`** to avoid create-vs-delete clock skew. (Migrating the upserts to `.CurrentDate` too is optional — NTP skew between instances is sub-millisecond, and the `Id` tie-break absorbs equal timestamps.)

Change-type derivation in the app service mirrors the producer's `ToChangeItem` (`SyncInvoicesQueryHandler.cs`) using the BFF contract `SyncChangeItem<T>` (`Src/Invoices.Common/Models/SyncChangeItem.cs`):

- `DeletedAt != null` → `SyncChangeType.Deleted`, body `null` (tombstone) — the producer keys off its `IsDeleted` bool; here the soft-delete marker is the `DeletedAt` timestamp.
- otherwise → `SyncChangeType.Updated`, body carries the record (archived clients ride along here with `ArchivedAt` populated).

## Persistence changes

No new collection. Two changes per collection.

### 1. Advance the modified-time on delete/archive (correctness prerequisite)

Add `.CurrentDate(x => x.UpdatedAt)` (server-stamped, matching the producer's `VersionedEntityRepository.cs:61`) to every update builder that currently sets only `DeletedAt` / `ArchivedAt`:

| File | Method | Line |
|---|---|---|
| `ClientsRepository.cs` | `Delete` | `:199` |
| `ClientsRepository.cs` | `Archive` | `:183` |
| `ClientsRepository.cs` | `BulkDeleteInternal` | `:42` |
| `ClientsRepository.cs` | `DeleteAllByAccountId` | `:211` |
| `ItemsRepository.cs` | `DeleteItem` | `:179` |
| `ItemsRepository.cs` | `BulkDeleteInternal` | `:98` |

The upsert paths already stamp `UpdatedAt` (`ClientsRepository.cs:107`, `ItemsRepository.cs:31`), so creates/updates need no change.

### 2. New indexes

Add to `MongoDbContext.Configure(...)` (`Src/Invoices.Implementation.MongoDb/Repositories/Shared/MongoDbContext.cs`, alongside the existing per-collection `#region` blocks):

- `clients`: `{ AccountId: 1, UpdatedAt: 1, _id: 1 }` — covers `GetChangedSince` ordering + filter. `_id` ascending matches the cursor tie-breaker.
- `items`: `{ AccountId: 1, UpdatedAt: 1, _id: 1 }` — same.

No EF migration (Mongo, index created at startup by the existing `Configure` hook).

## Domain integration

### Repositories

Add a `GetChangedSince` to each repository interface — a near-verbatim copy of the producer's `InvoicesRepository.GetChangedSince` (`Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Repositories/InvoicesRepository.cs:186`) — returning **all** matching docs (deleted included), keyset-ordered by `(UpdatedAt, Id)`, capped at `limit`.

`Src/Invoices.Core/Repositories/IClientsRepository.cs`:

```csharp
// Returns clients changed since the cursor, INCLUDING soft-deleted ones, for sync.
// Keyset on (UpdatedAt, Id); Id (the composite _id == producer's UniqueId) breaks same-ms ties.
Task<IReadOnlyList<ManageableClient>> GetChangedSince(
    string accountId,
    DateTime? modifiedTimeExclusive,
    string? uniqueIdExclusive,
    int limit,
    CancellationToken ct);
```

`Src/Invoices.Core/Repositories/IItemsRepository.cs` — identical signature returning `ManageableItem`.

Mongo implementation (`ClientsRepository` / `ItemsRepository`), filter/sort modelled on the producer (`InvoicesRepository.cs:186`); uses the repo's `FindWithSession` helper for the optional transaction session:

```csharp
var fb = Builders<ManageableClient>.Filter;
var filter = fb.Eq(x => x.AccountId, accountId);
if (modifiedTimeExclusive.HasValue && uniqueIdExclusive != null)
{
    // (UpdatedAt > t) OR (UpdatedAt == t AND _id > uniqueId) — keyset pagination
    filter &= fb.Or(
        fb.Gt(x => x.UpdatedAt, modifiedTimeExclusive.Value),
        fb.And(fb.Eq(x => x.UpdatedAt, modifiedTimeExclusive.Value),
               fb.Gt(x => x.Id, uniqueIdExclusive)));
}
var sort = Builders<ManageableClient>.Sort.Ascending(x => x.UpdatedAt).Ascending(x => x.Id);
return await Collection.FindWithSession(CurrentSession, filter).Sort(sort).Limit(limit).ToListAsync(ct);
```

`FindWithSession` is the existing `MongoCollectionExtensions` session helper; a `FilterDefinition` overload was added there (the prior overload only took an `Expression`), and the inline `if (CurrentSession is not null) Find(session, …) else Find(…)` blocks in these repos were collapsed onto it.

Note no `DeletedAt == null` clause — sync deliberately includes tombstones, unlike `GetClientsByAccountId` (`ClientsRepository.cs:157`) / `GetItems` (`ItemsRepository.cs:154`). This matches the producer, whose `GetChangedSince` likewise does not filter `IsDeleted`.

### Application services

Add `SyncClients` / `SyncItems` to the service interfaces and implementations, mirroring `InvoicesService.SyncInvoices` (`Src/Invoices.Api/Services/InvoicesService.cs:119`). The service owns cursor (de)serialization and change-type derivation.

`IClientsService` (`Src/Invoices.Common/Services/Clients/IClientsService.cs`):

```csharp
Task<SyncResponseModel<ManageableClient>> SyncClients(SyncClientsRequestModel request, CancellationToken ct);
```

`ClientsService` implementation (`Src/Invoices.Implementation.Services/Clients/ClientsService.cs`, uses the already-injected `_clientsRepository`):

```csharp
public async Task<SyncResponseModel<ManageableClient>> SyncClients(SyncClientsRequestModel request, CancellationToken ct)
{
    var limit = request.Limit > 0
        ? Math.Min(request.Limit, SyncClientsRequestModel.MaxLimit)
        : SyncClientsRequestModel.DefaultLimit;

    // A malformed or empty token deserializes to null -> fresh sync, never wedging the client.
    var cursor = ClientSyncCursor.Deserialize(request.Cursor);

    var page = await _clientsRepository.GetChangedSince(
        request.AccountId, cursor?.GetModifiedTimeUtc(), cursor?.UniqueId, limit + 1, ct); // +1 to detect HasMore

    var hasMore = page.Count > limit;
    var kept = (hasMore ? page.Take(limit) : page).ToList();

    var items = kept.Select(c => new SyncChangeItem<ManageableClient>(
        c.ClientId, // payload ItemId is the logical client id, not the composite _id
        c.DeletedAt != null ? SyncChangeType.Deleted : SyncChangeType.Updated,
        c.DeletedAt != null ? null : c)).ToList();

    // Advance to the last kept item whenever the page is non-empty (producer parity), not only on hasMore.
    var last = kept.Count > 0 ? kept[^1] : null;
    var nextCursor = last is { UpdatedAt: not null }
        ? ClientSyncCursor.Serialize(ClientSyncCursor.Create(last.UpdatedAt.Value, last.Id))
        : request.Cursor;

    return new SyncResponseModel<ManageableClient>(items, nextCursor, hasMore);
}
```

`ItemsService` (`Src/Invoices.Implementation.Services/Items/ItemsService.cs`) is identical over `ManageableItem` / `ItemId`. Items have no `ArchivedAt`, so only `DeletedAt` drives tombstones.

### Cursor + models

- **Cursor serializer — reuse the shared `CursorSerializer`.** Instead of copying the producer's, `CursorSerializer` is **moved** from `Jobs.Domain.Pagination` to `Invoices.Common.Pagination` (`Src/Invoices.Common/Pagination/CursorSerializer.cs`) and shared by jobs, notes, and clients/items (`Jobs.Domain` already references `Invoices.Common`). It's base64 of **camelCase** JSON; `Deserialize<T>` returns **`null`** on an empty/malformed token (it doesn't throw). Casing is the jobs serializer's, not the producer's PascalCase — clients/items sync is brand-new, so producer token-parity isn't needed, and one shared serializer beats a second copy.
- `ClientSyncCursor(long ModifiedTimeMs, string UniqueId)` and `ItemSyncCursor(…)` — `sealed record`s modelled on `InvoiceSyncCursor`, with `Create`, `GetModifiedTimeUtc`, `Serialize`, `Deserialize` delegating to `CursorSerializer`. `ModifiedTimeMs` is epoch-millis of `UpdatedAt`; `UniqueId` is the composite `Id`. `Deserialize` returns **`null`** for an empty/malformed token or missing `UniqueId` → the service treats it as a fresh sync (no try/catch needed).
- Request models (mirror `SyncInvoicesRequestModel` at `Src/Invoices.Core/Models/Invoices/SyncInvoicesRequestModel.cs`); limit constants `Default=100, Max=500, Min=1`:

```csharp
public sealed record SyncClientsRequestModel
{
    public const int MinLimit = 1;
    public const int DefaultLimit = 100;
    public const int MaxLimit = 500;

    public required string AccountId { get; init; }
    public string? Cursor { get; init; }
    public int Limit { get; init; } = DefaultLimit;
}
```

- **Response model — one generic for clients and items.** A single `SyncResponseModel<T>` (`Src/Invoices.Common/Models/SyncResponseModel.cs`) replaces the per-resource `SyncClientsResponseModel`/`SyncItemsResponseModel`:

```csharp
public sealed record SyncResponseModel<T>(IReadOnlyList<SyncChangeItem<T>> Items, string? NextCursor, bool HasMore)
    where T : class;
```

`SyncClients` returns `SyncResponseModel<ManageableClient>`, `SyncItems` returns `SyncResponseModel<ManageableItem>`. Invoices/estimates/jobs keep their own response models (their handlers and fields differ), so the generic is scoped to clients/items only.

No new DI registration — `IClientsService`/`IItemsService`/`IClientsRepository`/`IItemsRepository` are already registered; we only add methods to existing interfaces.

## Endpoints

```
GET /api/clients/sync?cursor={opaque}&limit={int=100}   -> SyncResponseDto<ManageableClientDto.WithCalc>
GET /api/items/sync?cursor={opaque}&limit={int=100}     -> SyncResponseDto<ManageableItemDto>
```

Both: `[ApiVersion("3.0")]` + `[MapToApiVersion("3.0")]`, added to the existing `ClientsController` / `ItemsController`. `AccountId` comes from `BaseController` (`Src/Invoices.Api/Controllers/BaseController.cs`).

Controller body mirrors `InvoicesController.Sync` (`Src/Invoices.Api/Controllers/V3/InvoicesController.cs:267`) — inject `IOptions<TimelineOptions>` for the throttle hint:

```csharp
[HttpGet("sync")]
[MapToApiVersion("3.0")]
[AuthorizeAction(PermissionKeys.Client.View)]   // see Authorization
public async Task<ActionResult<SyncResponseDto<ManageableClientDto.WithCalc>>> Sync(
    [FromQuery] string? cursor = null,
    [FromQuery] int limit = SyncClientsRequestModel.DefaultLimit,
    CancellationToken ct = default)
{
    var result = await _clientsService.SyncClients(
        new SyncClientsRequestModel { AccountId = AccountId, Cursor = cursor, Limit = limit }, ct);

    // SyncResponseModel<T>.ToDto maps the envelope + each change body (tombstones stay null).
    // client.Map() returns ManageableClientDto.WithCalc — same shape as GetAll; calc fields stay null.
    return result.ToDto(client => client.Map(), _timelineOptions.DelayNextRequestInSeconds);
}
```

Items controller is identical: `return result.ToDto(item => item.Map(), _timelineOptions.DelayNextRequestInSeconds);` (`Src/Invoices.Api/Models/Items/ItemsMapping.cs:9`) with `PermissionKeys.Item.Manage`.

The mapping itself is the generic `ToDto` added to the `Mapping` class (`Src/Invoices.Api/Models/Mapping.cs`): a single-item `SyncChangeItem<T>.ToDto(mapItem)` plus a response-level `SyncResponseModel<T>.ToDto(mapItem, delay)`. Both fill `ItemId` + `Change.ToDto()` and apply `mapItem` only to a non-null body. The other sync controllers (jobs/invoices/estimates/notes) reuse the single-item form via `result.Items.Select(i => i.ToDto(...)).ToList()`.

### DTOs

Reuse the existing envelope and resource DTOs — **no new DTO types**:

- `SyncResponseDto<T>` — `Src/Invoices.Api/Dto/SyncResponseDto.cs`.
- `SyncChangeItemDto<T>` + `SyncChangeType` + `.ToDto()` — `Src/Invoices.Api/Dto/SyncChangeItemDto.cs`.
- `ManageableClientDto.WithCalc` — `Src/Invoices.Api/Models/Clients/ManageableClientDto.cs` (carries `ArchivedAt`; clients sync returns this richer DTO, same as `GetAll`).
- `ManageableItemDto` — `Src/Invoices.Api/Models/Items/ManageableItemsDto.cs`.

Client mapping: clients sync reuses the **existing** `Map()` (`Mapping.cs:55`), which returns `ManageableClientDto.WithCalc` — the same DTO shape `GetAll` returns. Sync does not compute balances, so the calc fields (`BalanceDue`, `BalancePaid`, …) are `null`. Items' `Map()` returns `ManageableItemDto`.

### Validation and errors

- `limit` clamped to `[MinLimit, MaxLimit]` = `[1, 500]` with `DefaultLimit = 100`; non-positive `limit` → default. The **service** clamps when handling the request (`request.Limit > 0 ? Math.Min(request.Limit, MaxLimit) : DefaultLimit`).
- An empty or malformed cursor (or one missing `UniqueId`) → `CursorSerializer.Deserialize` returns `null` → the service starts a **fresh first page**. A client holding a stale/garbage token self-heals instead of getting wedged on a 400. (Diverges from the producer, whose serializer throws.)
- No body, no write — no validation surface beyond the query params.

## Authorization

Both keys already exist in `Src/Tofu.Permissions.Shared/Domain/PermissionKeys.cs`; **no new keys, no `Tofu.Auth.Backend` change** either way.

| Endpoint | Permission | Rationale |
|---|---|---|
| `GET /api/clients/sync` | `PermissionKeys.Client.View` (`PermissionKeys.cs:66`) | Matches the sibling read endpoints on `ClientsController` (`:47, :72, :83`). |
| `GET /api/items/sync` | `PermissionKeys.Item.Manage` (`PermissionKeys.cs:78`) | `Item` has **no** `View` key; `Item.Manage` is the only gate `ItemsController` uses today (class-level `:15`). |

> **Decision note (re-confirm with product):** the `/feature plan` answer selected "reuse Manage keys" for both. That answer rested on a false premise I introduced — `Client.View` **already exists** and gates the other client reads, so using `Client.Manage` for the *read-only* clients sync would be **stricter** than the existing client reads (a regression for view-only roles). This plan therefore uses `Client.View` for clients and `Item.Manage` for items (per-controller consistency). Flag if you'd rather force `Client.Manage`.

## Lifecycle

How each mutation surfaces to a syncing client. Requires the modified-time-on-delete fix (Persistence changes §1) to hold.

**Archived/deleted semantics match the existing mobile "get all".** Mobile pulls clients/items via the catalog snapshot in `DataController.Get` (`Src/Invoices.Api/Controllers/DataController.cs`), reading with **`includeDeleted: false, includeArchived: true`** for clients (`:160, :195`) and `includeDeleted: false` for items (`:175, :208`). So today archived clients are returned (kept, with `ArchivedAt`) and deletes simply vanish from the snapshot. Sync preserves both: archived → `updated`, deleted → tombstone (the incremental equivalent of "absent"). So `GetChangedSince` returns deleted **and** archived rows — it does **not** reuse the `includeDeleted/includeArchived` filters; change-type is derived per row.

| Trigger | Behaviour in sync stream | Matches today's get-all |
|---|---|---|
| Client/item created | next page: `change=updated`, body present (`UpdatedAt` set on upsert) | present in snapshot |
| Client/item updated | next page: `change=updated`, body present | present in snapshot |
| Client/item soft-deleted (`DeletedAt` set) | next page: `change=deleted`, body `null` (tombstone) — **only after the modified-time fix** | absent from snapshot (`includeDeleted: false`) |
| Client archived (`ArchivedAt` set, not deleted) | next page: `change=updated`, body present with `ArchivedAt` populated | **included** (`includeArchived: true` in `DataController:160,195`) |
| Deleted client restored (version-0 upsert clears `DeletedAt`) | next page: `change=updated`, body present (resurrection) | reappears in snapshot |
| Account-wide delete (`DeleteAllByAccountId`) | each affected client emitted once as `change=deleted` (needs the modified-time fix on that path too) | absent from snapshot |

## Docs to Update

- [x] `Invoices.Backend/Docs/API/CLIENTS_API_REFERENCE.md` — documented `GET /api/clients/sync` (+ added missing `archivedAt` to the `ManageableClientDto` table).
- [x] `Invoices.Backend/Docs/API/ITEMS_API_REFERENCE.md` — documented `GET /api/v3/items/sync`.
- [ ] `Invoices.Backend/Docs/persistence.md` — note the two new Mongo indexes and the modified-time-on-delete invariant.
