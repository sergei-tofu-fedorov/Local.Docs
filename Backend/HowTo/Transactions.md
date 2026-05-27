Backend Transactions Overview
=============================

This document describes the common approach to database transactions in backend
services.

Core abstractions
-----------------

- `ITransactionProvider` / `ITransaction`  
  Code uses an abstraction that can open a transaction and then explicitly
  `Commit(ct)` or `Rollback(ct)`.

- Ambient transaction context  
  When a transaction is opened, it stores itself in an `AsyncLocal`-backed
  context. Repository base classes read the current transaction from this
  context and expose a `CurrentSession` (for example, a MongoDB client
  session), so repositories automatically participate in the active
  transaction.

- MongoDB implementation  
  The concrete implementation starts a MongoDB client session and a database
  transaction. All repository operations that use the current session are
  executed inside that database transaction.

Typical usage pattern
---------------------

- Services that require atomic updates inject `ITransactionProvider`.
- The recommended pattern is:

  1. Open a transaction inside a `using` block.
  2. Call repositories that rely on the ambient transaction context.
  3. Call `Commit(ct)` at the end to persist changes.
  4. If you detect an error and want to discard changes, call `Rollback(ct)`.

Example: simple commit
----------------------

```csharp
public async Task UpdateSomething(CancellationToken ct)
{
    using var tx = _txProvider.OpenTransaction();

    await _firstRepository.UpdateAsync(..., ct);
    await _secondRepository.InsertAsync(..., ct);

    await tx.Commit(ct);
}
```

- Both repository calls run in the same database transaction.
- If `Commit` completes successfully, all changes become visible together.

Example: manual rollback
------------------------

```csharp
public async Task ProcessWithValidation(CancellationToken ct)
{
    using var tx = _txProvider.OpenTransaction();

    await _repository.SaveDraftAsync(..., ct);

    if (!await _validator.IsValidAsync(..., ct))
    {
        await tx.Rollback(ct);
        return;
    }

    await tx.Commit(ct);
}
```

- Use `Rollback` when you explicitly decide that the work in the transaction
  should not be persisted.

Multi-collection transactions
-----------------------------

- A single transaction can span multiple collections.
- As long as repositories use the ambient session, the following operations
  are either all committed or all rolled back:

  - inserting documents into several collections;
  - updating related documents across collections;
  - deleting from one collection while inserting into another.

Nested transactions
-------------------

- The abstraction supports nested transactions using a stack-like context:

  - opening a new transaction saves the previous one and sets the new one as
    the current transaction;
  - disposing the inner transaction restores the previous one.

- Typical expectations:

  - an inner transaction can be committed independently;
  - a parent transaction can later roll back its own work without affecting
    what the already-committed inner transaction has done.

PostgreSQL / EF Core implementation
-----------------------------------

- For Postgres-backed services that use Entity Framework Core, the same
  abstractions (`ITransactionProvider` / `ITransaction`) are implemented on
  top of `DbContext.Database.BeginTransaction()`.
- All repositories share a scoped `DbContext` instance; opening a transaction
  on that context automatically makes all `SaveChangesAsync` calls participate
  in the same database transaction.
- Unlike Mongo, there is no need for an `AsyncLocal`-backed ambient session,
  because the DI container already ensures a single `DbContext` per request /
  unit of work.
- Usage from services is identical to the examples above:

  ```csharp
  public async Task CreateInvitationAsync(CancellationToken ct)
  {
      await using var tx = _txProvider.OpenTransaction();

      await _invitationRepository.InsertAsync(..., ct);
      await _magicTokenRepository.InsertAsync(..., ct);

      await tx.Commit(ct);
  }
  ```

- This guarantees that all related inserts/updates performed through EF Core
  repositories are committed or rolled back together in a single PostgreSQL
  transaction.

MongoDB implementation details
------------------------------

- For MongoDB-backed services, the transaction abstractions are implemented on
  top of `IMongoClient.StartSession()` and `IClientSessionHandle.StartTransaction()`.
- When a transaction is opened, the current MongoDB session is stored in the
  ambient context, and repositories obtain that session and pass it to driver
  operations.
- As long as repositories use the current session, multi-document operations
  across one or more collections participate in the same MongoDB transaction
  and are committed or rolled back together.

