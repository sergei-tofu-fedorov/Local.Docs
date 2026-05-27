# FS-977: Token-Based Sync for Estimates

**Status:** in-progress
**Started:** 2026-05-02

## Branches

| Repo | Branch | Base |
|---|---|---|
| `Tofu.Invoices.Backend` | `feature/FS-977` | `main` |
| `Invoices.Backend` | `feature/FS-977` | `master` |

## Goal

Add a cursor (token) based incremental sync endpoint for estimates, mirroring the existing invoices sync. Replaces the unbounded `GET /api/estimates` full-collection fetch with paged, change-only responses keyed by an opaque cursor.

## Why

`EstimatesController.GetAll` (`Src/Invoices.Api/Controllers/EstimatesController.cs:87`) returns every non-deleted estimate for the account in one response, same shape as the legacy invoices endpoint. For accounts with many estimates this becomes the slowest sync call mobile makes. The invoices sync (FS-977 — invoices variant) already proved the pattern; this ticket is the second entity to adopt it.

## Reference: how invoices sync is wired

Server (Repo B = `Tofu.Invoices.Backend`):

| Concern | File:line |
|---|---|
| Proto RPC | `src/Tofu.Invoices.Protos/V1/InvoicesApi.proto:95-99` |
| gRPC handler | `src/Tofu.Invoices.Api/Grpc/V1/InvoicesService.cs:296-307` |
| Query + handler | `src/Tofu.Invoices.Domain/Queries/SyncInvoices/SyncInvoicesQuery.cs`, `SyncInvoicesQueryHandler.cs` |
| Cursor record | `src/Tofu.Invoices.Domain/Queries/SyncInvoices/InvoiceSyncCursor.cs` |
| Repository method | `src/Tofu.Invoices.Infrastructure/Repositories/InvoicesRepository.cs:186-219` (`GetChangedSince`) |
| Proto-to-domain map | `src/Tofu.Invoices.Api/Grpc/Mapping/InvoicesServiceMapping.cs:717-735` |
| Mongo index | `src/Tofu.Invoices.Infrastructure/Database/MongoDbContext.cs:63-71` |

REST + client (Repo A = `Invoices.Backend`):

| Concern | File:line |
|---|---|
| Endpoint | `Src/Invoices.Api/Controllers/V3/InvoicesController.cs:240-269` |
| Service interface | `Src/Invoices.Common/Services/Invoices/IInvoicesService.cs:44` |
| Gateway gRPC call | `Src/Tofu.Invoices/InvoicesGateway.cs:172-183` |
| Proto ↔ model map | `Src/Tofu.Invoices/Mapping/Mapper.cs:1231-1259` |
| Request / response models | `Src/Invoices.Core/Models/Invoices/SyncInvoicesRequestModel.cs`, `Src/Invoices.Common/Models/SyncInvoicesResponseModel.cs` |

Estimates work follows the exact same shape; nothing in this ticket is novel architecture.

## Reusable building blocks (no work needed)

- `SyncResponseDto<T>` / `SyncChangeItemDto<T>` / `SyncChangeType` (Repo A, `Src/Invoices.Api/Dto/`) — generic, already used by jobs and invoices.
- `Estimate` already inherits `AccountScopedEntity<Estimate>` → has `ModifiedTime`, `Version`, `UniqueId = AccountId|Id`.
- `VersionedEntityRepository.DefineInsertOrUpdate` already writes `ModifiedTime` via `$currentDate` (`src/Tofu.Invoices.Infrastructure/Repositories/Shared/VersionedEntityRepository.cs:54-62`), so the `InsertOrUpdate` write path is already correct.
- `EstimatesController`, `IEstimatesService`, `EstimatesService`, `EstimatesGateway`, gRPC client registration — all in place; only new methods are added.

## Cursor strategy

Identical to invoices:

```
{ modifiedTimeMs: <long>, uniqueId: "<AccountId>|<EstimateId>" }
```

Base64-encoded JSON. Order-by `(ModifiedTime ASC, UniqueId ASC)`. Cursor predicate:

```
ModifiedTime > c.modifiedTime
  OR (ModifiedTime == c.modifiedTime AND UniqueId > c.uniqueId)
```

Soft-deleted estimates (`IsDeleted = true`) are returned with `Change = Deleted, Item = null` — not filtered out.

## Prerequisite bug fix

`EstimatesRepository.SetIsDeletedAsync` (`src/Tofu.Invoices.Infrastructure/Repositories/EstimatesRepository.cs:118-127`) currently does a direct `Collection.UpdateOneAsync` that only sets `IsDeleted`. It does **not** update `ModifiedTime` or increment `Version`, so deleted estimates would be invisible to a `ModifiedTime`-keyed cursor and stale on clients with older versions.

Fix as the very first step:

```csharp
var update = Builders<Estimate>.Update
    .Set(s => s.IsDeleted, true)
    .CurrentDate(s => s.ModifiedTime)
    .Inc(s => s.Version, 1);
```

Cross-reference: invoices got the same fix at `InvoicesRepository.cs:160-169`. Without this change `SyncEstimatesApiTests.SoftDeletedEstimatesAppearInSync` would fail.

## Required index

```
{ AccountId: 1, ModifiedTime: 1, UniqueId: 1 }
```

The current estimates index is `{AccountId desc, IsDeleted desc, Date desc, CreatedTime desc}` (`MongoDbContext.cs:74-88`) — does **not** cover the sync filter. Naming convention: `ix_estimates.accountid.modifiedtime.uniqueid` (mirrors the invoices index name).

## Implementation plan

### Phase 1 — `Tofu.Invoices.Backend` (server)

1. **Fix `EstimatesRepository.SetIsDeletedAsync`** — add `.CurrentDate(s => s.ModifiedTime).Inc(s => s.Version, 1)`. Verify `EstimatesRepository.SoftDelete` (line 74-104) goes through it; no other write path bypasses `VersionedEntityRepository`.

2. **Add cursor record** — `src/Tofu.Invoices.Domain/Queries/SyncEstimates/EstimateSyncCursor.cs`. Same shape and serialization as `InvoiceSyncCursor` (base64 JSON, parse-or-throw with explicit invalid-cursor exception).

3. **Add `GetChangedSince` to `IEstimatesRepository`** — signature:
   ```csharp
   Task<IReadOnlyList<Estimate>> GetChangedSince(
       string accountId,
       DateTime? modifiedTimeExclusive,
       string? uniqueIdExclusive,
       int limit,
       CancellationToken ct);
   ```
   Implement on `EstimatesRepository` mirroring `InvoicesRepository.cs:186-219`:
   - filter `AccountId == accountId`
   - cursor predicate as above (skip when `modifiedTimeExclusive` is null → initial sync)
   - sort `ModifiedTime ASC, UniqueId ASC`
   - `.Limit(limit)` (caller passes `pageSize + 1` to detect `hasMore`)

4. **Add query + handler** — `src/Tofu.Invoices.Domain/Queries/SyncEstimates/{SyncEstimatesQuery,SyncEstimatesQueryHandler}.cs`. Mirror `SyncInvoicesQueryHandler` exactly:
   - Decode cursor → `(modifiedTimeMs, uniqueId)` (or `(null, null)` when input cursor is null/empty).
   - Call `GetChangedSince(accountId, ..., limit + 1, ct)`.
   - If returned count > limit, drop the last item, set `hasMore = true`, encode `nextCursor` from the last *kept* item's `(ModifiedTime, UniqueId)`.
   - Map each `Estimate` to `SyncChangeItem(ItemId = UniqueId, Change = IsDeleted ? Deleted : Updated, Item = IsDeleted ? null : estimate)`.

5. **Add `EstimateSyncRelations` only if needed** — invoices sync has no relations dto. Estimates might want `Clients` populated like jobs sync does for partial entity hydration. **Default: no relations** in this ticket; clients fetched separately. Open follow-up only if mobile asks.

6. **Proto** — extend `src/Tofu.Invoices.Protos/V1/EstimatesApi.proto`:
   ```proto
   rpc SyncEstimates (SyncEstimatesRequest) returns (SyncEstimatesResponse) {
       option (google.api.http) = { get: "/v1/estimates/sync" };
   }

   message SyncEstimatesRequest {
       string account_id = 1;
       google.protobuf.StringValue cursor = 2;
       int32 limit = 3;
   }
   message SyncEstimatesResponse {
       repeated SyncEstimateChangeItem items = 1;
       google.protobuf.StringValue next_cursor = 2;
       bool has_more = 3;
   }
   message SyncEstimateChangeItem {
       string item_id = 1;
       SyncChangeType change = 2;
       EstimateObj item = 3;
   }
   ```
   Reuse `SyncChangeType` enum from `InvoicesApi.proto:491-495` if shared, otherwise define a parallel one in `EstimatesApi.proto`. Check existing `EstimatesApi.proto` for the existing `EstimateObj` message and reuse it for `item`.

7. **gRPC handler** — extend `src/Tofu.Invoices.Api/Grpc/V1/EstimatesService.cs`:
   ```csharp
   public override async Task<SyncEstimatesResponse> SyncEstimates(
       SyncEstimatesRequest request, ServerCallContext context)
   {
       var query = new SyncEstimatesQuery(
           AccountId: request.AccountId,
           Cursor: request.Cursor?.Value,
           Limit: request.Limit);
       var result = await _syncEstimatesQueryHandler.Handle(query, context.CancellationToken);
       return EstimatesServiceMapping.MapToSyncResponse(result);
   }
   ```

8. **Mapping** — add `MapToSyncResponse(SyncEstimatesResult)` in (or alongside) `EstimatesServiceMapping`. Mirror `InvoicesServiceMapping.cs:717-735`. Include `MapEstimateToObj` reuse — the existing estimate-to-proto mapper from `GetAll` is the right one; do not duplicate.

9. **Index** — add the `{AccountId, ModifiedTime, UniqueId}` compound index for the `estimates` collection alongside the existing one.

### Phase 2 — `Invoices.Backend` (REST + gRPC client)

10. **Request / response models:**
    - `Src/Invoices.Core/Models/Estimates/SyncEstimatesRequestModel.cs` — fields `AccountId`, `Cursor` (nullable string), `Limit`.
    - `Src/Invoices.Common/Models/SyncEstimatesResponseModel.cs` — fields `Items` (`List<SyncChangeItem<Estimate>>`), `NextCursor`, `HasMore`. Reuse the existing `SyncChangeItem<T>` from `Src/Invoices.Common/Models/SyncChangeItem.cs`.

11. **Service contract** — add `SyncEstimates(SyncEstimatesRequestModel, CancellationToken)` to `IEstimatesService` (`Src/Invoices.Common/Services/Invoices/IEstimatesService.cs`) and `IEstimatesGateway`. Implement on `EstimatesService` (delegate to gateway, single-line) and `EstimatesGateway` (gRPC call mirroring `InvoicesGateway.cs:172-183`).

12. **Mappers** — extend `Src/Tofu.Invoices/Mapping/Mapper.cs` with `MapToRequest(SyncEstimatesRequestModel)` and `MapToModel(SyncEstimatesResponse)`. Use the existing estimate-from-proto mapper for the `item` field; mirror invoices implementation at lines 1231-1259.

13. **REST endpoint** — add to `EstimatesController.cs`:
    ```csharp
    [MapToApiVersion("3.0")]
    [HttpGet("sync")]
    public async Task<ActionResult<SyncResponseDto<EstimateDto>>> Sync(
        [FromQuery] string? cursor = null,
        [FromQuery] int limit = 100,
        CancellationToken ct = default)
    ```
    Body mirrors `InvoicesController.cs:240-269` exactly: build request model, call service, map each `SyncChangeItem<Estimate>` to `SyncChangeItemDto<EstimateDto>` using the existing `Estimate → EstimateDto` mapper, surface `DelayNextRequestInSeconds` from `_timelineOptions`. **Note**: only `[MapToApiVersion("3.0")]` — do not add to v1/v2.

## API contract

### Request

```
GET /api/v3/estimates/sync?cursor={base64}&limit=100
```

| Param | Type | Default | Description |
|---|---|---|---|
| `cursor` | string | null | Opaque token from previous response. Null = full initial sync. |
| `limit` | int | 100 | Max items per response. Server may return fewer. |

### Response

```json
{
  "items": [
    { "itemId": "acct|est-1", "change": "updated", "item": { /* EstimateDto */ } },
    { "itemId": "acct|est-7", "change": "deleted", "item": null }
  ],
  "nextCursor": "eyJtb2RpZmllZFRpbWVNcyI6MTc...",
  "hasMore": true,
  "delayNextRequestInSeconds": 30
}
```

Reuses `SyncResponseDto<EstimateDto>` and `SyncChangeItemDto<EstimateDto>`.

## Out of scope

- Deprecating `GET /api/estimates` (v1/v2/v3 non-sync) — keep until mobile clients have migrated.
- Sync for `clients`, `items` — same recipe, separate tickets.
- Including `EstimateSyncRelations` (clients/jobs hydrated alongside) — only if mobile asks.

## Related

- Invoices sync (predecessor / template): [`features/invoices/sync_overview.md`](../invoices/sync_overview.md)
- Jobs sync (Postgres-sequence variant; reference for cursor token UX): `Src/Jobs/Jobs.Application/Queries/SyncJobsQueryHandler.cs`
