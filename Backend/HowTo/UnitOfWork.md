EF Core Unit of Work Pattern
============================

This document describes the Unit of Work pattern for EF Core services, with
emphasis on ensuring external calls (APIs, message queues) execute outside
the database transaction.

The Problem
-----------

When business operations combine database writes with external calls (sending
emails, publishing events, calling APIs), executing everything inside a single
transaction creates issues:

- **Long-running transactions**: External calls can be slow, increasing lock
  duration and deadlock risk.
- **Inconsistent state**: If the transaction commits but the external call
  fails, or vice versa, the system ends up in an inconsistent state.
- **Distributed transaction complexity**: Coordinating commits across databases
  and external services requires MSDTC or saga patterns.

Solution: Outbox Pattern
------------------------

The recommended approach separates concerns:

1. **Domain events** are raised by aggregates during business operations.
2. **SaveChanges** converts domain events to outbox messages and persists
   everything in a single atomic transaction.
3. **Background job** processes outbox messages after commit, making external
   calls outside any transaction.

This ensures:
- Database writes are atomic and fast.
- External calls happen reliably after commit.
- Failed external calls can be retried without affecting the database state.

Architecture Overview
---------------------

```
┌─────────────────────────────────────────────────────────────────┐
│                     Single Transaction                          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐ │
│  │  Aggregate  │───>│  DbContext  │───>│  OutboxMessages     │ │
│  │  (raises    │    │  SaveChanges│    │  (stored in same    │ │
│  │   events)   │    │             │    │   transaction)      │ │
│  └─────────────┘    └─────────────┘    └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (after commit)
┌─────────────────────────────────────────────────────────────────┐
│                  Background Processing                          │
│  ┌─────────────────────┐    ┌─────────────────────────────────┐ │
│  │  ProcessOutbox      │───>│  External Calls                 │ │
│  │  Job (reads outbox) │    │  (email, API, message queue)    │ │
│  └─────────────────────┘    └─────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

Implementation Components
-------------------------

### 1. Domain Events Interface

```csharp
public interface IDomainEvent : INotification
{
    Guid Id { get; init; }
}
```

### 2. Aggregate Root Base Class

```csharp
public abstract class AggregateRoot : Entity
{
    private readonly List<IDomainEvent> _domainEvents = new();

    public IReadOnlyCollection<IDomainEvent> GetDomainEvents() =>
        _domainEvents.ToList();

    public void ClearDomainEvents() => _domainEvents.Clear();

    protected void RaiseDomainEvent(IDomainEvent domainEvent) =>
        _domainEvents.Add(domainEvent);
}
```

### 3. Outbox Message Entity

```csharp
public sealed class OutboxMessage
{
    public Guid Id { get; set; }
    public string Type { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public DateTime OccurredOnUtc { get; set; }
    public DateTime? ProcessedOnUtc { get; set; }
    public string? Error { get; set; }
}
```

### 4. SaveChanges Interceptor

Converts domain events to outbox messages within the same transaction:

```csharp
public sealed class ConvertDomainEventsToOutboxMessagesInterceptor
    : SaveChangesInterceptor
{
    public override ValueTask<InterceptionResult<int>> SavingChangesAsync(
        DbContextEventData eventData,
        InterceptionResult<int> result,
        CancellationToken cancellationToken = default)
    {
        DbContext? dbContext = eventData.Context;
        if (dbContext is null)
            return base.SavingChangesAsync(eventData, result, cancellationToken);

        var outboxMessages = dbContext.ChangeTracker
            .Entries<AggregateRoot>()
            .Select(x => x.Entity)
            .SelectMany(aggregateRoot =>
            {
                var domainEvents = aggregateRoot.GetDomainEvents();
                aggregateRoot.ClearDomainEvents();
                return domainEvents;
            })
            .Select(domainEvent => new OutboxMessage
            {
                Id = Guid.NewGuid(),
                OccurredOnUtc = DateTime.UtcNow,
                Type = domainEvent.GetType().Name,
                Content = JsonConvert.SerializeObject(domainEvent,
                    new JsonSerializerSettings
                    {
                        TypeNameHandling = TypeNameHandling.All
                    })
            })
            .ToList();

        dbContext.Set<OutboxMessage>().AddRange(outboxMessages);

        return base.SavingChangesAsync(eventData, result, cancellationToken);
    }
}
```

### 5. Background Job for Processing

Runs outside any transaction, making external calls safe:

```csharp
[DisallowConcurrentExecution]
public class ProcessOutboxMessagesJob : IJob
{
    private readonly ApplicationDbContext _dbContext;
    private readonly IPublisher _publisher;

    public async Task Execute(IJobExecutionContext context)
    {
        var messages = await _dbContext
            .Set<OutboxMessage>()
            .Where(m => m.ProcessedOnUtc == null)
            .Take(20)
            .ToListAsync(context.CancellationToken);

        foreach (var outboxMessage in messages)
        {
            var domainEvent = JsonConvert.DeserializeObject<IDomainEvent>(
                outboxMessage.Content,
                new JsonSerializerSettings
                {
                    TypeNameHandling = TypeNameHandling.All
                });

            if (domainEvent is null) continue;

            await _publisher.Publish(domainEvent, context.CancellationToken);
            outboxMessage.ProcessedOnUtc = DateTime.UtcNow;
        }

        await _dbContext.SaveChangesAsync();
    }
}
```

### 6. Idempotent Event Handlers

Prevents duplicate processing if a handler is retried:

```csharp
public sealed class OutboxMessageConsumer
{
    public Guid Id { get; set; }        // Domain event ID
    public string Name { get; set; }    // Handler type name
}

public sealed class IdempotentDomainEventHandler<TDomainEvent>
    : IDomainEventHandler<TDomainEvent>
    where TDomainEvent : IDomainEvent
{
    private readonly INotificationHandler<TDomainEvent> _decorated;
    private readonly ApplicationDbContext _dbContext;

    public async Task Handle(TDomainEvent notification, CancellationToken ct)
    {
        string consumer = _decorated.GetType().Name;

        // Check if already processed
        if (await _dbContext.Set<OutboxMessageConsumer>()
            .AnyAsync(c => c.Id == notification.Id && c.Name == consumer, ct))
            return;

        // Process the event
        await _decorated.Handle(notification, ct);

        // Mark as consumed
        _dbContext.Set<OutboxMessageConsumer>().Add(new OutboxMessageConsumer
        {
            Id = notification.Id,
            Name = consumer
        });

        await _dbContext.SaveChangesAsync(ct);
    }
}
```

Unit of Work Interface
----------------------

The Unit of Work abstraction remains simple:

```csharp
public interface IUnitOfWork
{
    Task SaveChangesAsync(CancellationToken cancellationToken = default);
}

internal sealed class UnitOfWork : IUnitOfWork
{
    private readonly ApplicationDbContext _dbContext;

    public UnitOfWork(ApplicationDbContext dbContext) =>
        _dbContext = dbContext;

    public Task SaveChangesAsync(CancellationToken cancellationToken = default) =>
        _dbContext.SaveChangesAsync(cancellationToken);
}
```

Usage in Command Handlers
-------------------------

```csharp
public class CreateMemberCommandHandler : ICommandHandler<CreateMemberCommand>
{
    private readonly IMemberRepository _memberRepository;
    private readonly IUnitOfWork _unitOfWork;

    public async Task<Result> Handle(CreateMemberCommand command, CancellationToken ct)
    {
        var member = Member.Create(command.Email, command.FirstName, command.LastName);

        // Domain event is raised inside aggregate
        // e.g., member.RaiseDomainEvent(new MemberRegisteredDomainEvent(member.Id));

        _memberRepository.Add(member);

        // SaveChanges:
        // 1. Persists member
        // 2. Converts domain events to outbox messages
        // 3. All in single transaction
        await _unitOfWork.SaveChangesAsync(ct);

        return Result.Success();
    }
}
```

Key Benefits
------------

1. **Atomic writes**: Database changes and outbox messages commit together.
2. **External calls outside transaction**: Background job processes events
   after commit, no long-running transactions.
3. **Reliability**: Failed external calls can be retried; outbox persists
   until successfully processed.
4. **Idempotency**: Consumer tracking prevents duplicate processing.
5. **Decoupling**: Handlers don't know about outbox; interceptor handles it.

Related Documentation
---------------------

- `Backend/HowTo/Transactions.md` - General transaction patterns
- `Backend/HowTo/Architecture.md` - Clean architecture overview
