# 2.2 Notification Scheduler — Entry Point

Encapsulates process creation: insert `notification_job` row + enqueue handler atomically via `TransactionScope`. Callers just provide account, process type, and typed context.

## INotificationScheduler

```csharp
public interface INotificationScheduler
{
    /// Idempotent: returns false if active process already exists.
    Task<bool> ScheduleAsync<TContext>(string accountId, string processType,
        TContext context, CancellationToken ct) where TContext : class;
}

public class NotificationScheduler : INotificationScheduler
{
    private readonly INotificationJobRepository _repo;

    public async Task<bool> ScheduleAsync<TContext>(string accountId, string processType,
        TContext context, CancellationToken ct) where TContext : class
    {
        using var scope = new TransactionScope(TransactionScopeAsyncFlowOption.Enabled);

        // State enum + context travel in Hangfire job params
        var jobId = BackgroundJob.Enqueue<NotificationProcessHandler>(
            h => h.ProcessAsync(accountId, processType, DuplicateSubscriptionState.Init, context, ...));

        var inserted = await _repo.TryInsertAsync(accountId, processType, jobId, ct);

        // If not inserted — active process already exists.
        // TransactionScope rollback removes the Hangfire job too.
        if (!inserted)
            return false;

        scope.Complete();
        return true;
    }
}
```

**Atomicity**: both the `notification_job` row and the Hangfire job are created in the same `TransactionScope`. If the DB insert fails (duplicate), the Hangfire job is also rolled back. If Hangfire enqueue fails, the DB insert is rolled back.

**Idempotency**: relies on the partial unique index `(account_id, process_type) WHERE completed_at IS NULL` in the `notification_job` table. `INSERT ... ON CONFLICT DO NOTHING` — no error on duplicate, just returns `false`.

Reusable for any process type — callers provide `accountId`, `processType`, and typed context.
