# Step 8: Client Archiving

## Goal

Separate client archiving from soft-delete so users can hide inactive clients from lists while preserving their data for existing jobs. Currently clients with jobs cannot be deleted at all (`ClientHasJobsException`).

## Why a Separate Concept

- **Soft-delete** (`DeletedAt`) is a permanent removal — deleted clients are invisible everywhere.
- **Archiving** (`ArchivedAt`) is a user-facing "hide from lists" action — archived clients remain accessible by ID and editable.
- Combining both into one field would break the existing soft-delete contract.

---

## Data Model

New field on `ManageableClient`:

```
ArchivedAt  DateTime?   (default: null)
```

Client states:

| ArchivedAt | DeletedAt | State |
|------------|-----------|-------|
| null | null | Active |
| set | null | Archived |
| * | set | Deleted |

---

## API Contract

### DELETE /api/clients/{clientId}

| Condition | Action | Response |
|-----------|--------|----------|
| No jobs | Soft-delete (`DeletedAt = now`) | **204 NoContent** |
| Has jobs | Archive (`ArchivedAt = now`) | **200 OK** `DeletedResultDto { isArchived: true }` |

### GET /api/clients/{clientId}

Always returns the client regardless of archive status. Only filters `DeletedAt`.

### GET /api/clients

New query parameter: `?includeArchived=true`

| includeArchived | Filter |
|-----------------|--------|
| `false` (default) | `ArchivedAt == null && DeletedAt == null` |
| `true` | `DeletedAt == null` |

### GET /api/clients/paged

Always excludes archived. No additional parameters.

### POST /api/clients (UpdateOrCreate)

- Does **not** filter by `ArchivedAt` — archived clients always editable
- `ArchivedAt` is **not** reset on edit

### DTO

`ManageableClientDto` gets new field: `ArchivedAt` (DateTime?)

---

## Storage

### New operation: Archive

Sets `ArchivedAt = now` on client document (MongoDB `UpdateOne`).
Filter: `Id == FormatId(AccountId, ClientId) && DeletedAt == null`.

### Query filter changes

| Query | ArchivedAt filter |
|-------|-------------------|
| GetClientById | No filter (always returns archived) |
| GetClientsByAccountId | Conditional: `ArchivedAt == null` unless `includeArchived=true` |
| Paged query | Always `ArchivedAt == null` |
| UpdateOrCreate lookup | No filter (archived clients editable) |

---

## Jobs Integration

- **New jobs** for archived clients — **forbidden** (validation on create)
- **Existing jobs** — no changes (`ClientId` is a string reference, `ClientSnapshot` captured on completion)
- **Job details** — `GetClientById` does not filter `ArchivedAt`, so archived client data loads correctly

---

## Business Rules

1. DELETE auto-archives when client has jobs → 200 + `DeletedResultDto { isArchived: true }`
2. DELETE soft-deletes when client has no jobs → 204 NoContent
3. `GET /clients/{id}` always returns archived clients
4. `GET /clients?includeArchived=true` includes archived in list
5. `GET /clients/paged` always hides archived
6. Archived clients editable via `POST /clients`, `ArchivedAt` not reset
7. New jobs for archived clients forbidden
8. Invoices/Estimates unaffected
9. No explicit archive/unarchive endpoints — archiving only through DELETE
