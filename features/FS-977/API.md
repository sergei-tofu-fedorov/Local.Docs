# FS-977 — API Reference (new endpoint)

API reference for the token-based estimates sync endpoint introduced by FS-977. The existing `/api/estimates` endpoints (full-collection fetch, paged, single-item, etc.) are documented in `Backend/Api/ESTIMATES_API_REFERENCE.md` and are not repeated here.

**Target Audience**: Frontend Developers, Mobile Developers, Backend Developers, QA Engineers

## Endpoints Overview

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v3/estimates/sync` | [Sync estimates by cursor](#1-sync-estimates) (incremental, change-only) |

---

## 1. Sync Estimates

Returns estimates that changed since the cursor position, paged. Replaces the unbounded `GET /api/estimates` full-collection fetch with incremental, change-only responses keyed by an opaque cursor.

Mirrors the existing `/api/v3/invoices/sync` endpoint — same request shape, response shape, and cursor semantics.

**Endpoint**: `GET /api/v3/estimates/sync`

**Query Parameters**:

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `cursor` | string | No | `null` | Opaque token from a previous response's `nextCursor`. Omit (or null) for the initial full sync. |
| `limit` | integer | No | `100` | Maximum items returned in this page. The server may return fewer. |

**Example Requests**:

```
GET /api/v3/estimates/sync
GET /api/v3/estimates/sync?limit=50
GET /api/v3/estimates/sync?cursor=eyJtb2RpZmllZFRpbWVNcyI6MTc...&limit=100
```

**Response**: `200 OK`

```json
{
  "items": [
    {
      "itemId": "acct_xyz789|est_abc123",
      "change": "updated",
      "item": {
        "id": "est_abc123",
        "version": 4,
        "status": "approved",
        "client": { "name": "Emily Johnson", "email": "emily.johnson@gmail.com" },
        "date": "2025-10-12",
        "totalAmount": 2400.00
      }
    },
    {
      "itemId": "acct_xyz789|est_def456",
      "change": "deleted",
      "item": null
    }
  ],
  "nextCursor": "eyJtb2RpZmllZFRpbWVNcyI6MTc...",
  "hasMore": true,
  "delayNextRequestInSeconds": 30
}
```

**Response Fields** (`SyncResponseDto<EstimateDto>`):

| Field | Type | Description |
|-------|------|-------------|
| `items` | array | Change items in this page, ordered by `(modifiedTime, uniqueId)` ascending |
| `items[].itemId` | string | Stable identifier of the changed estimate, in the form `<accountId>\|<estimateId>` |
| `items[].change` | string (enum) | Change type — see [SyncChangeType](#syncchangetype-enum) |
| `items[].item` | object \| null | Full [EstimateDto](../../Backend/Api/ESTIMATES_API_REFERENCE.md#2-get-all-estimates) for `updated`; `null` when `change = "deleted"` |
| `nextCursor` | string \| null | Opaque cursor for the next page. Pass back as the `cursor` query param. `null` once the client has caught up. |
| `hasMore` | boolean | `true` when more pages are available; `false` when the current page is the last |
| `delayNextRequestInSeconds` | integer | Server hint for how long the client should wait before the next sync poll. Sourced from `TimelineOptions.DelayNextRequestInSeconds`. |

### `SyncChangeType` enum

| Value | Description |
|-------|-------------|
| `updated` | The estimate was created or modified — `item` carries the current state. |
| `deleted` | The estimate was soft-deleted — `item` is `null`. The client should drop it from local storage. |

### Cursor semantics

- The cursor is **opaque** to clients — do not parse, log, or persist its inner shape, just pass it back unchanged.
- Internally it encodes `(modifiedTime, uniqueId)` and resolves the next-page predicate as `modifiedTime > c.modifiedTime OR (modifiedTime == c.modifiedTime AND uniqueId > c.uniqueId)`.
- Initial sync: omit the `cursor` query param (or pass `null`). The server returns the oldest page first.
- Steady state: keep calling with `nextCursor` until `hasMore = false`. Then poll again after `delayNextRequestInSeconds`.
- Soft-deleted estimates are returned with `change = "deleted"` and `item = null` — they are **not** filtered out, so the client can synchronize the deletion locally.

### Notes

- **Versioning**: only available on **API v3**. v1 / v2 keep the legacy non-sync endpoints untouched.
- **Ordering**: items are ordered by `(modifiedTime ASC, uniqueId ASC)` so the cursor stays deterministic across pages.
- **No relations**: this iteration returns only estimates. Related entities (clients, items) are fetched separately. A future iteration may add an optional `relations=<list>` query if mobile asks.
- **Authentication, error responses, and rate limiting** follow the conventions documented in the global Estimates reference.
