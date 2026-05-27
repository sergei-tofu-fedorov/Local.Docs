# 2.3 Notification Process Handler — State Machine Engine

Generic Hangfire job that advances a notification state machine. State + context travel in job params. The `notification_job` table is only checked for retry guard.

## Handler

```csharp
public class NotificationProcessHandler : TransactionalJobBase
{
    // Generic: TState is the state enum, TContext is the process-specific context
    public async Task ProcessAsync<TState, TContext>(
        string accountId, string processType,
        TState state, TContext context,
        PerformContext hangfireContext,
        CancellationToken ct)
        where TState : struct, Enum
        where TContext : class
    {
        // 1. Retry guard (job_id check)
        // 2. Build model via factory (processType → INotificationProcess<TState, TContext>)
        // 3. model.Advance(now, context, verification) → ProcessResult<TState>
        // 4. TransactionScope: enqueue deliveries, schedule next job, update job_id
        //    Next schedule preserves TState + TContext types:
        //    Schedule<NotificationProcessHandler>(
        //        h => h.ProcessAsync<TState, TContext>(
        //            accountId, processType, result.NewState, nextContext, ...))
    }
}
```

Generic over `TState` (enum) and `TContext` (process-specific data). Hangfire serializes the closed generic method call — type parameters are preserved across serialization. Each process type uses its own state enum + context type.

## Retry Guard

Hangfire marks its current job as "completed" **after** our method returns — outside our `TransactionScope`. Edge case: crash between our commit and Hangfire's mark-complete → Hangfire retries the old job while the next job already exists.

The `hangfire_job_id` in `notification_job` catches this: within our TransactionScope, we update it to the next scheduled job's ID. On stale retry, `myJobId != currentJobId` → skip. No duplicate deliveries.

## ProcessResult

```csharp
public record ProcessResult<TState> where TState : struct, Enum
{
    public required TState NewState { get; init; }
    public bool IsTerminal { get; init; }
    public DateTime? NextWakeTime { get; init; }
    public object? UpdatedContext { get; init; }  // null = keep existing
    public IReadOnlyList<DeliveryRequest> Deliveries { get; init; } = [];
}
```

Generic over `TState` — type-safe enum, no string parsing. For duplicate subscriptions: `ProcessResult<DuplicateSubscriptionState>`. Reusable for future process types with different state enums.

**Key properties:**
- Single job at a time per process — sequential, no overlaps
- Atomic transitions — deliveries + next schedule + job_id update in one transaction
- Rich model drives logic — handler is pure infrastructure
- CorrelationId auto-logged via `CorrelationIdFilter` (see [2.1](2_1_hangfire_infrastructure.md))
