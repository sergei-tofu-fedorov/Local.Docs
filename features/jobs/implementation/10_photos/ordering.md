Attachment Ordering
===================

How display order works for visit-level attachments within the
`PUT /api/jobs` full-state upsert.

Overview
--------

Each attachment has an `Order` column (`integer`, default 0). The
client sends the full attachments array per visit with the desired
order values. The server stores them as-is — no reindexing, no
gap-filling, no server-side reordering.

Ordering is **client-owned**. The server is a dumb store for the
`Order` value. All reordering logic lives on the client.

How it works
------------

The client sends `PUT /api/jobs` with `visits[].attachments[]`. Each
attachment in the array carries an `order` field. The server diffs
the incoming array against the current state per visit:

- **Matching ID** → update `order` (and `tags` if provided)
- **New ID** → create attachment with the given `order`
- **Missing ID** → delete attachment

### Add new photos

The client appends new attachments after existing ones:

```
Existing:  [{ id: "a", order: 0 }, { id: "b", order: 1 }]
PUT:       [{ id: "a", order: 0 }, { id: "b", order: 1 },
            { id: "c", order: 2 }, { id: "d", order: 3 }]
Result:    [a:0, b:1, c:2, d:3]
```

### Reorder

The client sends all attachments with reassigned order values:

```
Before:    [{ id: "a", order: 0 }, { id: "b", order: 1 }, { id: "c", order: 2 }]
PUT (swap a and b):
           [{ id: "b", order: 0 }, { id: "a", order: 1 }, { id: "c", order: 2 }]
Result:    [b:0, a:1, c:2]
```

### Delete

Omit the attachment from the array. Remaining attachments keep their
order values — gaps are fine:

```
Before:    [a:0, b:1, c:2]
PUT (omit b):
           [{ id: "a", order: 0 }, { id: "c", order: 2 }]
Result:    [a:0, c:2]          ← gap at 1 is fine
```

The client may re-compact order values, but it is not required.

### Don't touch

Send `attachments: null` on the visit to leave attachments unchanged.
This is the default for clients that don't manage photos.

Response ordering
-----------------

All read endpoints return attachments sorted by `Order` ascending:

```csharp
visit.Attachments?.OrderBy(a => a.Order).Select(...)
```

If two attachments share the same `Order`, their relative order is
undefined. Clients should avoid duplicate order values.

Domain code — full-state diff
------------------------------

`Visit.UpdateAttachments` receives the full desired array from the
client (called via `Job.ApplyAttachmentUpdates`). It diffs against
the current state: matching IDs are updated (order + tags), new IDs
are added, missing IDs are deleted.

Order is always taken from `input.Order` — no server-side logic.

The method signature:
```csharp
internal Result<List<JobDomainEvent>> UpdateAttachments(
    IReadOnlyList<AttachmentInput> attachments,
    string? actorId,
    bool attachmentsEditable)
```

The diff logic:
1. Build dictionary of existing attachments by ID
2. For each incoming: if exists → update Order + Tags; if new → add attachment
3. For each existing not in incoming → remove
4. Return domain events (PhotoAdded/PhotoDeleted) + attachment limit warning

### Diff walkthrough — reorder + add + delete in one PUT

```
Existing:  [{ id: "a", order: 0 }, { id: "b", order: 1 }, { id: "c", order: 2 }]

Client sends (swap a↔b, delete c, add d):
Incoming:  [{ id: "b", order: 0 }, { id: "a", order: 1 }, { id: "d", order: 2 }]

Step 1 — iterate incoming:
  "b" found in existing → update order 1→0, add to seenIds
  "a" found in existing → update order 0→1, add to seenIds
  "d" not found          → create with order 2, PhotoAdded event

Step 2 — find missing:
  "c" not in seenIds     → remove, PhotoDeleted event

Result:    [b:0, a:1, d:2]
```

Design decisions
----------------

| Decision | Reason |
|----------|--------|
| Client-owned ordering | Server doesn't know the UI — drag-and-drop, manual sort, etc. |
| No server-side reindexing | Avoids conflicts when multiple clients edit simultaneously |
| Gaps allowed | Simpler than re-compacting on every delete |
| Full-state diff only | Single PUT with the complete desired array — no partial updates, no merge conflicts |
| `integer` type | Plenty of range, simple to reassign sequentially |
| Default 0 | New attachments without explicit order appear first |
