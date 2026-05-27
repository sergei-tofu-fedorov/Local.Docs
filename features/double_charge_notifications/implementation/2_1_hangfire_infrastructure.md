# 2.1 Hangfire Infrastructure — Setup, Job Tracking, Generic Delivery

Adds Hangfire to Invoices.Backend. Pure reusable infrastructure, no notification-specific logic.

## Hangfire Setup

| Process | Role | Registration |
|---------|------|-------------|
| `Invoices.Api` | Client only — `Enqueue()` / `Schedule()` | `services.AddHangfire(...)` |
| `Invoices.Worker` | Client + Server — processes jobs | `services.AddHangfire(...)` + `services.AddHangfireServer()` |

Both share PostgreSQL storage. `EnableTransactionScopeEnlistment = true` — Hangfire operations participate in `TransactionScope` alongside EF Core. Atomic commits across DB writes + job scheduling.

NuGet: `Hangfire.AspNetCore`, `Hangfire.PostgreSql`.

## CorrelationIdFilter

Hangfire `IServerFilter` that auto-adds `CorrelationId` to log scope for any job whose params implement `IWithCorrelationId`. All logs within the job include correlation ID without manual logging.

```csharp
public interface IWithCorrelationId
{
    Guid CorrelationId { get; }
}

// IServerFilter: OnPerforming finds IWithCorrelationId in job args,
// calls ILogger.BeginScope with CorrelationId. OnPerformed disposes scope.
```

## TransactionalJobBase

```csharp
public abstract class TransactionalJobBase
{
    protected async Task ExecuteInTransactionAsync(Func<Task> action)
    {
        using var scope = new TransactionScope(TransactionScopeAsyncFlowOption.Enabled);
        await action();
        scope.Complete();
    }
}
```

## Notification Job Table

Minimal table — idempotency guard + retry safety. No state, no JSONB — both travel in Hangfire job params.

```sql
CREATE TABLE notifications.notification_job (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id      TEXT NOT NULL,
    process_type    TEXT NOT NULL,
    hangfire_job_id TEXT NOT NULL,        -- retry guard (see 2.3)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at    TIMESTAMPTZ          -- soft delete
);

CREATE UNIQUE INDEX uq_notification_job_active
    ON notifications.notification_job (account_id, process_type)
    WHERE completed_at IS NULL;
```

- One active process per type per account (`INSERT ... ON CONFLICT DO NOTHING`)
- `hangfire_job_id` — updated on each transition, used by handler to detect stale retries (details in [2.3](2_3_notification_process_handler.md))
- Reusable for any `process_type` (duplicate_subscription, trial_expiry, dunning, etc.)

### INotificationJobRepository

```csharp
public interface INotificationJobRepository
{
    Task<bool> TryInsertAsync(string accountId, string processType, string hangfireJobId, CancellationToken ct);
    Task<string?> GetCurrentJobIdAsync(string accountId, string processType, CancellationToken ct);
    Task UpdateJobIdAsync(string accountId, string processType, string newJobId, CancellationToken ct);
    Task CompleteAsync(string accountId, string processType, CancellationToken ct);
}
```

## Generic Delivery Jobs

Two stateless Hangfire jobs — resolve recipient and send. Both implement `IWithCorrelationId` for automatic log scope.

**EmailDeliveryJob**: resolves email from `AccountId`, sends via `IEmailService.SendTemplateAsync(email, templateId, templateParams)`.

**PushDeliveryJob**: calls `IPushService.SendWithParams(accountId, productKey, templateProps, templateKey)`.

```csharp
public record EmailDeliveryParams : IWithCorrelationId
{
    public required string AccountId { get; init; }
    public required string TemplateId { get; init; }
    public required Dictionary<string, object> TemplateParams { get; init; }
    public Guid CorrelationId { get; init; }
}

public record PushDeliveryParams : IWithCorrelationId
{
    public required string AccountId { get; init; }
    public required string ProductKey { get; init; }
    public required string TemplateKey { get; init; }
    public required object TemplateProps { get; init; }
    public Guid CorrelationId { get; init; }
}
```

**Why separate jobs**: independent retry (email failure doesn't block push), reusable across features, each attempt visible in Hangfire dashboard.
