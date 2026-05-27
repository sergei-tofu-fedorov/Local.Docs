# Invoice Sync — Cursor-Based Incremental Synchronization

## Problem

Mobile clients currently call `GetAll` to sync invoices. For accounts with many invoices, this causes unbounded response times — the entire collection is fetched from MongoDB, materialized into memory, and serialized. Need a cursor-based incremental sync endpoint that returns only changes since the last sync.

## Current State

```
Mobile Client → Invoices.Backend (REST) → Tofu.Invoices.Backend (gRPC) → MongoDB
```

| Aspect | Current |
|--------|---------|
| Endpoint | `GET /api/invoices` (v1/v2/v3) |
| Behavior | Fetches ALL non-deleted invoices for account |
| Pagination | None |
| Change detection | None — client replaces entire local dataset |
| Deleted invoices | Filtered out in-memory, never synced to client |

### Current Query (the bottleneck)

```csharp
// InvoicesRepository.cs:60-66
var cursor = await Collection.FindAsync(e => e.AccountId == accountId, null, token);
var invoices = await cursor.ToListAsync(token);
return invoices.Where(i => !(i.IsDeleted ?? false)).ToList();
```

## Reference: Jobs Sync Pattern

The Jobs module already has a cursor-based sync endpoint (`GET /api/jobs/sync`) built on a PostgreSQL sequence:

- **SequenceId** (bigint) — auto-incremented by a DB trigger on every INSERT/UPDATE
- **Cursor** — base64-encoded JSON `{sequenceId: N}`
- **Query** — `WHERE AccountId = @acct AND SequenceId > @N ORDER BY SequenceId LIMIT pageSize+1`
- **Change types** — `Updated` (full JobDto) or `Deleted` (item: null)
- **Generic DTOs** — `SyncResponseDto<T>`, `SyncChangeItemDto<T>`, `CursorSerializer` — all reusable

## Proposed Design for Invoices

### Why we can't copy Jobs exactly

Jobs use a **PostgreSQL sequence + trigger** — the database atomically assigns a monotonically increasing `SequenceId` on every write. MongoDB has no native sequences or triggers.

### Cursor strategy: ModifiedTime + UniqueId compound cursor

Use the existing `ModifiedTime` field (already updated on every write) as the ordering field, with `UniqueId` (MongoDB `_id`) as a tiebreaker for same-millisecond writes.

**Cursor structure:**
```json
{"modifiedTime": "2026-03-05T12:00:00.123Z", "uniqueId": "abc123|inv456"}
```

Base64-encoded using existing `CursorSerializer`.

**Sync query:**
```
WHERE AccountId = @acct
  AND ((ModifiedTime > cursor.modifiedTime)
    OR (ModifiedTime == cursor.modifiedTime AND UniqueId > cursor.uniqueId))
ORDER BY ModifiedTime ASC, UniqueId ASC
LIMIT pageSize + 1
```

### Correctness: $currentDate vs application-level timestamp

Currently `ModifiedTime` is set at the **application level** before the MongoDB write:

```csharp
// VersionedEntityRepository.cs:25-27
var now = DateTime.UtcNow;
updatedEntity.ModifiedTime = now;
updatedEntity = await Collection.FindOneAndUpdateAsync(...);
```

This creates a **visibility gap**: Thread A computes `DateTime.UtcNow = T=100` then makes a slow MongoDB call. Thread B computes `T=102` and commits first. A sync reader at T=103 sees B's document, advances cursor past T=102. When A commits at T=105 with ModifiedTime=T=100, it's behind the cursor — **permanently missed**.

**Fix:** Use MongoDB's `$currentDate` operator, which assigns the timestamp at the server side during the atomic write:

```csharp
// Instead of: .Set(e => e.ModifiedTime, updatedEntity.ModifiedTime)
// Use:        .CurrentDate(e => e.ModifiedTime)
```

With `$currentDate`, the timestamp is assigned when the write is processed by the MongoDB server. If B is processed before A, B gets an earlier (or equal) timestamp. The ordering of timestamps matches the ordering of visibility, eliminating the gap.

**Residual risk:** Two writes in the same millisecond — handled by the UniqueId tiebreaker.

### Required index

```
{AccountId: 1, ModifiedTime: 1, UniqueId: 1}
```

No existing index covers this query — the current index is `{AccountId: -1, IsDeleted: -1, Date: -1, CreatedTime: -1}`.

## Prerequisites: Bug Fixes

Several write paths bypass `VersionedEntityRepository` and do NOT update `ModifiedTime`:

| Method | File | Issue |
|--------|------|-------|
| `SetIsDeletedAsync` | InvoicesRepository.cs:160-169 | Only sets `IsDeleted = true` |
| `SoftDelete` | InvoicesRepository.cs:90-113 | Delegates to `SetIsDeletedAsync` |
| `UpdateDueDateStatus` | InvoicesRepository.cs:149-158 | Only sets `DueDateStatus` |

Without fixing these, deleted invoices and status updates would never appear in sync results. Each must also update `ModifiedTime` (via `$currentDate`) and increment `Version`.

## Implementation Plan

### Phase 1: Base Repository Changes (Tofu.Invoices.Backend)

1. **Switch `VersionedEntityRepository.DefineInsertOrUpdate`** to use `$currentDate` for ModifiedTime
2. **Fix `SetIsDeletedAsync`** — add `.CurrentDate(s => s.ModifiedTime).Inc(s => s.Version, 1)`
3. **Fix `UpdateDueDateStatus`** — same treatment
4. **Add compound index** `{AccountId: 1, ModifiedTime: 1, UniqueId: 1}` on `invoices` collection

### Phase 2: Sync Query (Tofu.Invoices.Backend)

5. **Define cursor** — `InvoiceSyncCursor` record with `ModifiedTime` + `UniqueId`
6. **Add repository method** — `GetChangedSince(accountId, modifiedTime, uniqueId, pageSize)`
7. **Add query** — `SyncInvoicesQuery` + handler (same pattern as `SyncJobsQueryHandler`)
8. **Add proto RPC** — `SyncInvoices` in `InvoicesApi.proto`
9. **Add gRPC handler** — in `InvoicesService.cs`

### Phase 3: REST Endpoint (Invoices.Backend)

10. **Add gRPC client method** — `InvoicesService.SyncInvoices()`
11. **Add REST endpoint** — `GET /api/v3/invoices/sync?cursor=&limit=100`
12. **Reuse** `SyncResponseDto<T>`, `SyncChangeItemDto<T>`, `CursorSerializer` from Jobs

### Phase 4: Initial Sync Optimization

13. When cursor is null (first sync), return all invoices paginated by `ModifiedTime ASC` — same query, just starting from the beginning. Deleted invoices (`IsDeleted = true`) are included with `Change = Deleted` so the client can handle them.

## API Contract

### Request

```
GET /api/v3/invoices/sync?cursor={base64}&limit=100
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `cursor` | string | null | Opaque cursor from previous response. Null = full initial sync |
| `limit` | int | 100 | Page size (max items per response) |

### Response

```json
{
  "items": [
    {
      "itemId": "invoice-id",
      "change": "updated",
      "item": { /* full InvoiceDto */ }
    },
    {
      "itemId": "deleted-invoice-id",
      "change": "deleted",
      "item": null
    }
  ],
  "nextCursor": "eyJtb2RpZmllZFRpbWUiOi4uLn0=",
  "hasMore": true,
  "delayNextRequestInSeconds": 30
}
```

Reuses `SyncResponseDto<T>` and `SyncChangeItemDto<T>`.

## Reusability

The approach is generic for any MongoDB entity inheriting `VersionedEntity<T>` + `AccountScopedEntity<T>`:

| Entity | Collection | Next candidate |
|--------|------------|----------------|
| Invoice | `invoices` | This task |
| Estimate | `estimates` | Natural next — same service, same hierarchy |
| Client | `clients` | Invoices.Backend (direct MongoDB) |
| Item | `items` | Invoices.Backend (direct MongoDB) |

The `$currentDate` fix in `VersionedEntityRepository` benefits all entities. Each new sync endpoint only needs: a compound index, a `GetChangedSince` method, and a query handler + endpoint.

## Design Notes

- **No schema migration** — `ModifiedTime` and `UniqueId` already exist on all documents
- **Only new index** — `{AccountId: 1, ModifiedTime: 1, UniqueId: 1}`
- **Backward compatible** — new endpoint, existing endpoints unchanged
- **Soft deletes included** — documents with `IsDeleted = true` returned as `Change = Deleted`
- **No message queues** — stays consistent with platform's pull-based sync architecture
- **Polling interval** — controlled by `DelayNextRequestInSeconds` (configurable, default 30s)
