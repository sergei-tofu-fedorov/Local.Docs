# План реализации модуля Notifications

## Обзор

Реализация модуля Notifications по архитектуре модуля Jobs.

| Phase | Описание | Каналы | Сложность |
|-------|----------|--------|-----------|
| **Phase 1** | InApp уведомления (MVP) | InApp | Низкая |
| **Phase 2** | Outbox + Multi-Channel | InApp, Push, Email | Средняя |
| **Phase 3** | Advanced Features | + SSE, Preferences | Высокая |

---

# PHASE 1: InApp Notifications (MVP)

## 1.1 Цель и Scope

**Цель:** Базовая функциональность InApp уведомлений.

**Что входит:**
- ✅ Хранение уведомлений в PostgreSQL
- ✅ API для получения списка уведомлений
- ✅ API для пометки как прочитанное
- ✅ Курсорная пагинация
- ✅ Фильтрация по статусу (read/unread) и типу
- ✅ Target scoping (account-wide / user-specific)

**Что НЕ входит:**
- ❌ Outbox pattern
- ❌ Push notifications
- ❌ Email notifications
- ❌ Worker для доставки
- ❌ Retry logic

---

## 1.2 Структура проектов Phase 1

```
Src/
└── Notifications/
    ├── Notifications.Contracts/      # DTO, команды, запросы
    ├── Notifications.Domain/         # Модели, интерфейсы, сервисы
    ├── Notifications.Application/    # Обработчики, маппинги
    ├── Notifications.Infrastructure/ # Репозитории, БД
    └── Notifications.Tests/          # Unit тесты
```

---

## 1.3 Notifications.Contracts (Phase 1)

### Структура

```
Notifications.Contracts/
├── Notifications.Contracts.csproj
└── Notifications/
    ├── NotificationDto.cs
    ├── NotificationType.cs
    ├── NotificationSource.cs
    ├── Commands/
    │   ├── MarkNotificationReadCommand.cs
    │   └── MarkNotificationsReadBatchCommand.cs
    └── Queries/
        └── GetNotificationsQuery.cs
```

### Зависимости

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="..\..\Invoices.Common\Invoices.Common.csproj" />
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />
  </ItemGroup>
</Project>
```

### NotificationType.cs

```csharp
using System.Runtime.Serialization;

namespace Notifications.Contracts.Notifications;

/// <summary>
/// Типы уведомлений (camelCase для API сериализации).
/// </summary>
public enum NotificationType
{
    // Payment
    [EnumMember(Value = "firstPaymentReceived")]
    FirstPaymentReceived,

    // PSP Onboarding
    [EnumMember(Value = "pspOnboardingCompleted")]
    PspOnboardingCompleted,

    [EnumMember(Value = "pspOnboardingActionsRequired")]
    PspOnboardingActionsRequired,

    [EnumMember(Value = "pspOnboardingVerificationCompleted")]
    PspOnboardingVerificationCompleted
}
```

### NotificationSource.cs

```csharp
using System.Runtime.Serialization;

namespace Notifications.Contracts.Notifications;

/// <summary>
/// Источники уведомлений (модули/сервисы).
/// </summary>
public enum NotificationSource
{
    [EnumMember(Value = "Payments")]
    Payments,

    [EnumMember(Value = "Stripe")]
    Stripe
}
```

### NotificationDto.cs

```csharp
using Newtonsoft.Json.Linq;

namespace Notifications.Contracts.Notifications;

public sealed record NotificationDto(
    long Id,
    NotificationType Type,
    JObject Payload,
    DateTime CreatedAt,
    DateTime? ReadAt,
    NotificationSource Source);

public sealed record NotificationListDto(
    List<NotificationDto> Items,
    string? NextCursor);
```

### Commands

```csharp
using Invoices.Common.Cqrs;

namespace Notifications.Contracts.Notifications.Commands;

// Mark single notification as read
public sealed record MarkNotificationReadCommand(
    string TargetAccountId,
    long NotificationId,
    string? TargetMasterUserId) : CommandBase(TargetAccountId, TargetMasterUserId), ICommand<MarkNotificationReadResult>;

public sealed record MarkNotificationReadResult;

// Mark multiple notifications as read (batch)
public sealed record MarkNotificationsReadBatchCommand(
    string TargetAccountId,
    long[] Ids,
    string? TargetMasterUserId) : CommandBase(TargetAccountId, TargetMasterUserId), ICommand<MarkNotificationsReadBatchResult>;

public sealed record MarkNotificationsReadBatchResult(int UpdatedCount);
```

### Queries

```csharp
using Invoices.Common.Cqrs;

namespace Notifications.Contracts.Notifications.Queries;

// Get paginated notifications
public sealed record GetNotificationsQuery(
    string TargetAccountId,
    string? TargetMasterUserId,
    bool? Unread,
    NotificationType? Type,
    int Limit,
    string? Cursor) : IQuery<GetNotificationsResult>;

public sealed record GetNotificationsResult(
    List<NotificationDto> Items,
    string? NextCursor);
```

---

## 1.4 Notifications.Domain (Phase 1)

### Структура

```
Notifications.Domain/
├── Notifications.Domain.csproj
├── Models/
│   ├── Notification.cs
│   └── NotificationEvent.cs
├── Interfaces/
│   ├── INotificationsRepository.cs
│   └── INotificationDispatcher.cs
├── Services/
│   └── NotificationDispatcher.cs
└── ServiceCollectionExtensions.cs
```

### Зависимости

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="..\..\Invoices.Common\Invoices.Common.csproj" />
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.Extensions.DependencyInjection.Abstractions" Version="8.0.0" />
    <PackageReference Include="Microsoft.Extensions.Logging.Abstractions" Version="8.0.0" />
    <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />
  </ItemGroup>
</Project>
```

### Notification.cs

```csharp
using Notifications.Contracts.Notifications;

namespace Notifications.Domain.Models;

public class Notification
{
    public long Id { get; set; }
    public required string TargetAccountId { get; set; }
    public string? TargetMasterUserId { get; set; }
    public string? TargetProductKey { get; set; }
    public required NotificationType Type { get; set; }
    public required string PayloadJson { get; set; }
    public required DateTime CreatedAt { get; set; }
    public DateTime? ReadAt { get; set; }
    public required int SchemaVersion { get; set; }
    public required NotificationSource Source { get; set; }

    public static Notification Create(
        string targetAccountId,
        string? targetMasterUserId,
        string? targetProductKey,
        NotificationType type,
        string payloadJson,
        NotificationSource source,
        DateTime? occurredAt = null)
    {
        return new Notification
        {
            TargetAccountId = targetAccountId,
            TargetMasterUserId = targetMasterUserId,
            TargetProductKey = targetProductKey,
            Type = type,
            PayloadJson = payloadJson,
            CreatedAt = occurredAt ?? DateTime.UtcNow,
            ReadAt = null,
            SchemaVersion = 1,
            Source = source
        };
    }

    public void MarkAsRead()
    {
        ReadAt ??= DateTime.UtcNow;
    }
}
```

### NotificationEvent.cs

```csharp
using Notifications.Contracts.Notifications;

namespace Notifications.Domain.Models;

/// <summary>
/// Событие для создания уведомления (используется другими модулями).
/// </summary>
public class NotificationEvent
{
    public required string TargetAccountId { get; init; }
    public string? TargetMasterUserId { get; init; }
    public string? TargetProductKey { get; init; }
    public required NotificationType Type { get; init; }
    public required object Payload { get; init; }
    public DateTime? OccurredAt { get; init; }
    public required NotificationSource Source { get; init; }
}
```

### INotificationsRepository.cs

```csharp
using Notifications.Contracts.Notifications;

namespace Notifications.Domain.Interfaces;

public interface INotificationsRepository
{
    Task<Notification> Insert(Notification notification, CancellationToken ct);

    Task<Notification?> GetById(
        string targetAccountId,
        long notificationId,
        CancellationToken ct);

    Task<(List<Notification> Items, string? NextCursor)> GetPaged(
        string targetAccountId,
        string? targetMasterUserId,
        bool? unread,
        NotificationType? type,
        int limit,
        string? cursor,
        CancellationToken ct);

    Task MarkAsRead(
        string targetAccountId,
        long notificationId,
        string? targetMasterUserId,
        CancellationToken ct);

    Task<int> MarkMultipleAsRead(
        string targetAccountId,
        long[] ids,
        string? targetMasterUserId,
        CancellationToken ct);
}
```

### INotificationDispatcher.cs

```csharp
namespace Notifications.Domain.Interfaces;

/// <summary>
/// Сервис для создания уведомлений (используется другими модулями).
/// </summary>
public interface INotificationDispatcher
{
    Task<Notification> CreateNotification(NotificationEvent notificationEvent, CancellationToken ct);
}
```

### NotificationDispatcher.cs (Phase 1 - простая версия)

```csharp
using Microsoft.Extensions.Logging;
using Newtonsoft.Json;
using Notifications.Domain.Interfaces;
using Notifications.Domain.Models;

namespace Notifications.Domain.Services;

public class NotificationDispatcher : INotificationDispatcher
{
    private readonly INotificationsRepository _repository;
    private readonly ILogger<NotificationDispatcher> _logger;

    public NotificationDispatcher(
        INotificationsRepository repository,
        ILogger<NotificationDispatcher> logger)
    {
        _repository = repository;
        _logger = logger;
    }

    public async Task<Notification> CreateNotification(
        NotificationEvent notificationEvent,
        CancellationToken ct)
    {
        _logger.LogInformation(
            "Creating notification {Type} for account {AccountId}, user {UserId}, source {Source}",
            notificationEvent.Type,
            notificationEvent.TargetAccountId,
            notificationEvent.TargetMasterUserId,
            notificationEvent.Source);

        var payloadJson = JsonConvert.SerializeObject(notificationEvent.Payload);

        var notification = Notification.Create(
            notificationEvent.TargetAccountId,
            notificationEvent.TargetMasterUserId,
            notificationEvent.TargetProductKey,
            notificationEvent.Type,
            payloadJson,
            notificationEvent.Source,
            notificationEvent.OccurredAt);

        var saved = await _repository.Insert(notification, ct);

        _logger.LogInformation(
            "Notification {NotificationId} created successfully",
            saved.Id);

        return saved;
    }
}
```

### ServiceCollectionExtensions.cs

```csharp
using Microsoft.Extensions.DependencyInjection;
using Notifications.Domain.Interfaces;
using Notifications.Domain.Services;

namespace Notifications.Domain;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddNotificationsDomain(this IServiceCollection services)
    {
        services.AddScoped<INotificationDispatcher, NotificationDispatcher>();
        return services;
    }
}
```

---

## 1.5 Notifications.Infrastructure (Phase 1)

### Структура

```
Notifications.Infrastructure/
├── Notifications.Infrastructure.csproj
├── NotificationsOptions.cs
├── Database/
│   ├── NotificationsDbContext.cs
│   ├── NotificationsDbContextFactory.cs
│   └── Configurations/
│       └── NotificationConfiguration.cs
├── Repositories/
│   └── NotificationsRepository.cs
├── Pagination/
│   └── NotificationsPaginationToken.cs
├── Migrations/
│   └── NotificationsModuleMigrator.cs
└── ServiceCollectionExtensions.cs
```

### Зависимости

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="..\Notifications.Domain\Notifications.Domain.csproj" />
    <ProjectReference Include="..\..\Invoices.Common\Invoices.Common.csproj" />
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.EntityFrameworkCore" Version="8.0.0" />
    <PackageReference Include="Microsoft.EntityFrameworkCore.Design" Version="8.0.0" />
    <PackageReference Include="Npgsql.EntityFrameworkCore.PostgreSQL" Version="8.0.0" />
    <PackageReference Include="Microsoft.Extensions.Configuration.Binder" Version="8.0.0" />
  </ItemGroup>
</Project>
```

### NotificationsOptions.cs

```csharp
namespace Notifications.Infrastructure;

public class NotificationsOptions
{
    public const string SectionName = "Notifications";

    public string ConnectionString { get; set; } = null!;
    public int RetentionDays { get; set; } = 90;

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(ConnectionString))
            throw new InvalidOperationException($"{SectionName}:{nameof(ConnectionString)} is required");
    }
}
```

### NotificationsDbContext.cs

```csharp
using Microsoft.EntityFrameworkCore;
using Notifications.Domain.Models;

namespace Notifications.Infrastructure.Database;

public class NotificationsDbContext : DbContext
{
    public DbSet<Notification> Notifications => Set<Notification>();

    public NotificationsDbContext(DbContextOptions<NotificationsDbContext> options)
        : base(options)
    {
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasDefaultSchema("notifications");
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(NotificationsDbContext).Assembly);
    }
}
```

### NotificationsDbContextFactory.cs

```csharp
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace Notifications.Infrastructure.Database;

public class NotificationsDbContextFactory : IDesignTimeDbContextFactory<NotificationsDbContext>
{
    public NotificationsDbContext CreateDbContext(string[] args)
    {
        var optionsBuilder = new DbContextOptionsBuilder<NotificationsDbContext>();
        optionsBuilder.UseNpgsql("Host=localhost;Database=invoices;Username=postgres;Password=postgres");
        return new NotificationsDbContext(optionsBuilder.Options);
    }
}
```

### NotificationConfiguration.cs

```csharp
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using Notifications.Contracts.Notifications;
using Notifications.Domain.Models;

namespace Notifications.Infrastructure.Database.Configurations;

public class NotificationConfiguration : IEntityTypeConfiguration<Notification>
{
    public void Configure(EntityTypeBuilder<Notification> builder)
    {
        builder.ToTable("Notifications");

        builder.HasKey(n => n.Id);

        builder.Property(n => n.Id)
            .HasColumnName("Id")
            .UseIdentityAlwaysColumn();

        builder.Property(n => n.TargetAccountId)
            .HasColumnName("TargetAccountId")
            .IsRequired()
            .HasMaxLength(64);

        builder.Property(n => n.TargetMasterUserId)
            .HasColumnName("TargetMasterUserId")
            .HasMaxLength(64);

        builder.Property(n => n.TargetProductKey)
            .HasColumnName("TargetProductKey")
            .HasMaxLength(64);

        builder.Property(n => n.Type)
            .HasColumnName("Type")
            .IsRequired();

        builder.Property(n => n.PayloadJson)
            .HasColumnName("Payload")
            .HasColumnType("jsonb")
            .IsRequired();

        builder.Property(n => n.CreatedAt)
            .HasColumnName("CreatedAt")
            .IsRequired();

        builder.Property(n => n.ReadAt)
            .HasColumnName("ReadAt");

        builder.Property(n => n.SchemaVersion)
            .HasColumnName("SchemaVersion")
            .IsRequired();

        builder.Property(n => n.Source)
            .HasColumnName("Source")
            .IsRequired();

        // Indexes
        // Основной для пагинации (account-wide)
        builder.HasIndex(n => new { n.TargetAccountId, n.CreatedAt, n.Id })
            .IsDescending(false, true, true);

        // Для user-specific уведомлений
        builder.HasIndex(n => new { n.TargetAccountId, n.TargetMasterUserId, n.CreatedAt, n.Id })
            .IsDescending(false, false, true, true);
    }
}
```

### NotificationsPaginationToken.cs

```csharp
using System.Globalization;
using System.Text;

namespace Notifications.Infrastructure.Pagination;

public class NotificationsPaginationToken
{
    public DateTime CreatedAt { get; set; }
    public long NotificationId { get; set; }

    public string Encode()
    {
        var raw = $"{CreatedAt:O}|{NotificationId}";
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(raw));
    }

    public static NotificationsPaginationToken? Decode(string? cursor)
    {
        if (string.IsNullOrWhiteSpace(cursor))
            return null;

        try
        {
            var raw = Encoding.UTF8.GetString(Convert.FromBase64String(cursor));
            var parts = raw.Split('|');

            if (parts.Length != 2)
                return null;

            return new NotificationsPaginationToken
            {
                CreatedAt = DateTime.Parse(parts[0], null, DateTimeStyles.RoundtripKind),
                NotificationId = long.Parse(parts[1])
            };
        }
        catch
        {
            return null; // Invalid cursor - start from beginning
        }
    }
}
```

### NotificationsRepository.cs

```csharp
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using Notifications.Contracts.Notifications;
using Notifications.Domain.Interfaces;
using Notifications.Domain.Models;
using Notifications.Infrastructure.Database;
using Notifications.Infrastructure.Pagination;

namespace Notifications.Infrastructure.Repositories;

public class NotificationsRepository : INotificationsRepository
{
    private readonly NotificationsDbContext _context;
    private readonly ILogger<NotificationsRepository> _logger;

    public NotificationsRepository(
        NotificationsDbContext context,
        ILogger<NotificationsRepository> logger)
    {
        _context = context;
        _logger = logger;
    }

    public async Task<Notification> Insert(Notification notification, CancellationToken ct)
    {
        _context.Notifications.Add(notification);
        await _context.SaveChangesAsync(ct);
        return notification;
    }

    public async Task<Notification?> GetById(
        string targetAccountId,
        long notificationId,
        CancellationToken ct)
    {
        return await _context.Notifications
            .FirstOrDefaultAsync(n =>
                n.TargetAccountId == targetAccountId &&
                n.Id == notificationId, ct);
    }

    public async Task<(List<Notification> Items, string? NextCursor)> GetPaged(
        string targetAccountId,
        string? targetMasterUserId,
        bool? unread,
        NotificationType? type,
        int limit,
        string? cursor,
        CancellationToken ct)
    {
        var token = NotificationsPaginationToken.Decode(cursor);

        var query = _context.Notifications
            .Where(n => n.TargetAccountId == targetAccountId);

        // User scope: account-wide (null) OR user-specific
        query = query.Where(n =>
            n.TargetMasterUserId == null ||
            n.TargetMasterUserId == targetMasterUserId);

        // Filters
        if (unread == true)
            query = query.Where(n => n.ReadAt == null);
        else if (unread == false)
            query = query.Where(n => n.ReadAt != null);

        if (type.HasValue)
            query = query.Where(n => n.Type == type.Value);

        // Cursor pagination
        if (token != null)
        {
            query = query.Where(n =>
                n.CreatedAt < token.CreatedAt ||
                (n.CreatedAt == token.CreatedAt && n.Id < token.NotificationId));
        }

        var items = await query
            .OrderByDescending(n => n.CreatedAt)
            .ThenByDescending(n => n.Id)
            .Take(limit + 1)
            .ToListAsync(ct);

        string? nextCursor = null;
        if (items.Count > limit)
        {
            items.RemoveAt(items.Count - 1);
            var last = items[^1];
            nextCursor = new NotificationsPaginationToken
            {
                CreatedAt = last.CreatedAt,
                NotificationId = last.Id
            }.Encode();
        }

        return (items, nextCursor);
    }

    public async Task MarkAsRead(
        string targetAccountId,
        long notificationId,
        string? targetMasterUserId,
        CancellationToken ct)
    {
        await _context.Notifications
            .Where(n =>
                n.TargetAccountId == targetAccountId &&
                n.Id == notificationId &&
                n.ReadAt == null &&
                (n.TargetMasterUserId == null || n.TargetMasterUserId == targetMasterUserId))
            .ExecuteUpdateAsync(s => s.SetProperty(n => n.ReadAt, DateTime.UtcNow), ct);
    }

    public async Task<int> MarkMultipleAsRead(
        string targetAccountId,
        long[] ids,
        string? targetMasterUserId,
        CancellationToken ct)
    {
        return await _context.Notifications
            .Where(n =>
                n.TargetAccountId == targetAccountId &&
                ids.Contains(n.Id) &&
                n.ReadAt == null &&
                (n.TargetMasterUserId == null || n.TargetMasterUserId == targetMasterUserId))
            .ExecuteUpdateAsync(s => s.SetProperty(n => n.ReadAt, DateTime.UtcNow), ct);
    }
}
```

### NotificationsModuleMigrator.cs

```csharp
using Invoices.Common.Modules.Migrations;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using Notifications.Infrastructure.Database;

namespace Notifications.Infrastructure.Migrations;

public class NotificationsModuleMigrator : IModuleMigration
{
    private readonly NotificationsDbContext _context;
    private readonly ILogger<NotificationsModuleMigrator> _logger;

    public NotificationsModuleMigrator(
        NotificationsDbContext context,
        ILogger<NotificationsModuleMigrator> logger)
    {
        _context = context;
        _logger = logger;
    }

    public string ModuleName => "Notifications";

    public async Task MigrateAsync(CancellationToken ct)
    {
        _logger.LogInformation("Running migrations for Notifications module");
        await _context.Database.MigrateAsync(ct);
        _logger.LogInformation("Notifications module migrations completed");
    }
}
```

### ServiceCollectionExtensions.cs

```csharp
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Invoices.Common.Modules.Migrations;
using Notifications.Domain.Interfaces;
using Notifications.Infrastructure.Database;
using Notifications.Infrastructure.Repositories;
using Notifications.Infrastructure.Migrations;

namespace Notifications.Infrastructure;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddNotificationsInfrastructure(
        this IServiceCollection services,
        IConfiguration configuration,
        IHostEnvironment environment)
    {
        var options = new NotificationsOptions();
        configuration.GetSection(NotificationsOptions.SectionName).Bind(options);
        options.Validate();

        services.Configure<NotificationsOptions>(
            configuration.GetSection(NotificationsOptions.SectionName));

        services.AddDbContext<NotificationsDbContext>(opts =>
        {
            opts.UseNpgsql(options.ConnectionString);

            if (environment.IsDevelopment())
            {
                opts.EnableSensitiveDataLogging();
                opts.EnableDetailedErrors();
            }
        });

        services.AddScoped<INotificationsRepository, NotificationsRepository>();
        services.AddScoped<IModuleMigration, NotificationsModuleMigrator>();

        return services;
    }
}
```

---

## 1.6 Notifications.Application (Phase 1)

### Структура

```
Notifications.Application/
├── Notifications.Application.csproj
├── NotificationsModule.cs
├── NotificationsMappings.cs
├── Commands/
│   ├── MarkNotificationReadCommandHandler.cs
│   └── MarkNotificationsReadBatchCommandHandler.cs
├── Queries/
│   └── GetNotificationsQueryHandler.cs
└── ServiceCollectionExtensions.cs
```

### Зависимости

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="..\Notifications.Contracts\Notifications.Contracts.csproj" />
    <ProjectReference Include="..\Notifications.Domain\Notifications.Domain.csproj" />
    <ProjectReference Include="..\Notifications.Infrastructure\Notifications.Infrastructure.csproj" />
    <ProjectReference Include="..\..\Invoices.Common\Invoices.Common.csproj" />
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="Scrutor" Version="4.2.2" />
  </ItemGroup>
</Project>
```

### NotificationsModule.cs

```csharp
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Notifications.Domain;
using Notifications.Infrastructure;

namespace Notifications.Application;

public static class NotificationsModule
{
    public static IServiceCollection AddNotificationsModule(
        this IServiceCollection services,
        IConfiguration configuration,
        IHostEnvironment environment)
    {
        services.AddNotificationsDomain();
        services.AddNotificationsHandlers();
        services.AddNotificationsInfrastructure(configuration, environment);

        return services;
    }
}
```

### NotificationsMappings.cs

```csharp
using Newtonsoft.Json.Linq;
using Notifications.Contracts.Notifications;
using Notifications.Domain.Models;

namespace Notifications.Application;

public static class NotificationsMappings
{
    public static NotificationDto ToDto(this Notification notification)
    {
        return new NotificationDto(
            Id: notification.Id,
            Type: notification.Type,
            Payload: JObject.Parse(notification.PayloadJson),
            CreatedAt: notification.CreatedAt,
            ReadAt: notification.ReadAt,
            Source: notification.Source);
    }

    public static List<NotificationDto> ToDtoList(this IEnumerable<Notification> notifications)
    {
        return notifications.Select(n => n.ToDto()).ToList();
    }
}
```

### Command Handlers

```csharp
// MarkNotificationReadCommandHandler.cs
using Invoices.Common.Cqrs;
using Microsoft.Extensions.Logging;
using Notifications.Contracts.Notifications.Commands;
using Notifications.Domain.Interfaces;

namespace Notifications.Application.Commands;

public class MarkNotificationReadCommandHandler
    : ICommandHandler<MarkNotificationReadCommand, MarkNotificationReadResult>
{
    private readonly INotificationsRepository _repository;
    private readonly ILogger<MarkNotificationReadCommandHandler> _logger;

    public MarkNotificationReadCommandHandler(
        INotificationsRepository repository,
        ILogger<MarkNotificationReadCommandHandler> logger)
    {
        _repository = repository;
        _logger = logger;
    }

    public async Task<MarkNotificationReadResult> Handle(
        MarkNotificationReadCommand command,
        CancellationToken ct)
    {
        _logger.LogInformation(
            "Marking notification {NotificationId} as read for account {AccountId}",
            command.NotificationId, command.TargetAccountId);

        await _repository.MarkAsRead(
            command.TargetAccountId,
            command.NotificationId,
            command.TargetMasterUserId,
            ct);

        return new MarkNotificationReadResult();
    }
}

// MarkNotificationsReadBatchCommandHandler.cs
public class MarkNotificationsReadBatchCommandHandler
    : ICommandHandler<MarkNotificationsReadBatchCommand, MarkNotificationsReadBatchResult>
{
    private const int MaxBatchSize = 100;

    private readonly INotificationsRepository _repository;
    private readonly ILogger<MarkNotificationsReadBatchCommandHandler> _logger;

    public MarkNotificationsReadBatchCommandHandler(
        INotificationsRepository repository,
        ILogger<MarkNotificationsReadBatchCommandHandler> logger)
    {
        _repository = repository;
        _logger = logger;
    }

    public async Task<MarkNotificationsReadBatchResult> Handle(
        MarkNotificationsReadBatchCommand command,
        CancellationToken ct)
    {
        if (command.Ids is not { Length: > 0 })
            throw new ArgumentException("Ids cannot be empty", nameof(command.Ids));

        if (command.Ids.Length > MaxBatchSize)
            throw new ArgumentException($"Cannot mark more than {MaxBatchSize} notifications at once", nameof(command.Ids));

        _logger.LogInformation(
            "Marking {Count} notifications as read for account {AccountId}",
            command.Ids.Length, command.TargetAccountId);

        var count = await _repository.MarkMultipleAsRead(
            command.TargetAccountId,
            command.Ids,
            command.TargetMasterUserId,
            ct);

        return new MarkNotificationsReadBatchResult(count);
    }
}

```

### Query Handlers

```csharp
// GetNotificationsQueryHandler.cs
using Invoices.Common.Cqrs;
using Microsoft.Extensions.Logging;
using Notifications.Contracts.Notifications.Queries;
using Notifications.Domain.Interfaces;

namespace Notifications.Application.Queries;

public class GetNotificationsQueryHandler
    : IQueryHandler<GetNotificationsQuery, GetNotificationsResult>
{
    private const int MaxLimit = 100;
    private const int DefaultLimit = 50;

    private readonly INotificationsRepository _repository;
    private readonly ILogger<GetNotificationsQueryHandler> _logger;

    public GetNotificationsQueryHandler(
        INotificationsRepository repository,
        ILogger<GetNotificationsQueryHandler> logger)
    {
        _repository = repository;
        _logger = logger;
    }

    public async Task<GetNotificationsResult> Handle(
        GetNotificationsQuery query,
        CancellationToken ct)
    {
        var limit = query.Limit switch
        {
            <= 0 => DefaultLimit,
            > MaxLimit => MaxLimit,
            _ => query.Limit
        };

        _logger.LogDebug(
            "Getting notifications for account {AccountId}, unread: {Unread}, type: {Type}",
            query.TargetAccountId, query.Unread, query.Type);

        var (items, nextCursor) = await _repository.GetPaged(
            query.TargetAccountId,
            query.TargetMasterUserId,
            query.Unread,
            query.Type,
            limit,
            query.Cursor,
            ct);

        return new GetNotificationsResult(
            Items: items.ToDtoList(),
            NextCursor: nextCursor);
    }
}
```

### ServiceCollectionExtensions.cs

```csharp
using Invoices.Common.Cqrs;
using Microsoft.Extensions.DependencyInjection;
using Notifications.Application.Queries;

namespace Notifications.Application;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddNotificationsHandlers(this IServiceCollection services)
    {
        services.Scan(scan => scan
            .FromAssemblyOf<GetNotificationsQueryHandler>()
            .AddClasses(classes => classes.AssignableTo(typeof(ICommandHandler<,>)))
            .AsImplementedInterfaces()
            .WithScopedLifetime());

        services.Scan(scan => scan
            .FromAssemblyOf<GetNotificationsQueryHandler>()
            .AddClasses(classes => classes.AssignableTo(typeof(IQueryHandler<,>)))
            .AsImplementedInterfaces()
            .WithScopedLifetime());

        return services;
    }
}
```

---

## 1.7 API Integration (Phase 1)

### API DTO

```csharp
// Invoices.Api/Dto/Notifications/NotificationResponseDto.cs
using Notifications.Contracts.Notifications;

namespace Invoices.Api.Dto.Notifications;

public class NotificationResponseDto
{
    public long Id { get; set; }
    public NotificationType Type { get; set; }
    public object Payload { get; set; } = null!;
    public DateTime CreatedAt { get; set; }
    public DateTime? ReadAt { get; set; }
    public NotificationSource Source { get; set; }
}

public class NotificationsListResponseDto
{
    public List<NotificationResponseDto> Items { get; set; } = new();
    public string? NextCursor { get; set; }
}

public class MarkMultipleReadRequestDto
{
    public long[] Ids { get; set; } = [];
}

public class MarkMultipleReadResponseDto
{
    public int UpdatedCount { get; set; }
}
```

### NotificationsController.cs

```csharp
// Invoices.Api/Controllers/NotificationsController.cs
using Invoices.Api.Dto.Notifications;
using Invoices.Common.Cqrs;
using Microsoft.AspNetCore.Mvc;
using Notifications.Contracts.Notifications;
using Notifications.Contracts.Notifications.Commands;
using Notifications.Contracts.Notifications.Queries;

namespace Invoices.Api.Controllers;

[ApiVersion("3.0")]
[ApiController]
[Route("api/[controller]")]
public sealed class NotificationsController : BaseController
{
    private readonly IHandlerDispatcher _dispatcher;

    public NotificationsController(IHandlerDispatcher dispatcher)
    {
        _dispatcher = dispatcher;
    }

    /// <summary>
    /// Get paginated list of notifications.
    /// </summary>
    [HttpGet]
    [MapToApiVersion("3.0")]
    public async Task<NotificationsListResponseDto> GetNotifications(
        [FromQuery] bool? unread,
        [FromQuery] NotificationType? type,
        [FromQuery] int? limit,
        [FromQuery] string? cursor,
        CancellationToken ct)
    {
        var query = new GetNotificationsQuery(
            targetAccountId: AccountId,
            targetMasterUserId: AuthenticationInfo?.MasterUser?.Id,
            unread: unread,
            type: type,
            limit: limit ?? 50,
            cursor: cursor);

        var result = await _dispatcher.DispatchQuery<GetNotificationsQuery, GetNotificationsResult>(query, ct);

        return new NotificationsListResponseDto
        {
            Items = result.Items.Select(i => new NotificationResponseDto
            {
                Id = i.Id,
                Type = i.Type,
                Payload = i.Payload,
                CreatedAt = i.CreatedAt,
                ReadAt = i.ReadAt,
                Source = i.Source
            }).ToList(),
            NextCursor = result.NextCursor
        };
    }

    /// <summary>
    /// Mark a single notification as read.
    /// </summary>
    [HttpPost("{id:long}/read")]
    [MapToApiVersion("3.0")]
    public async Task<IActionResult> MarkAsRead(long id, CancellationToken ct)
    {
        var command = new MarkNotificationReadCommand(
            TargetAccountId: AccountId,
            NotificationId: id,
            TargetMasterUserId: AuthenticationInfo?.MasterUser?.Id);

        await _dispatcher.DispatchCommand<MarkNotificationReadCommand, MarkNotificationReadResult>(command, ct);

        return NoContent();
    }

    /// <summary>
    /// Mark multiple notifications as read.
    /// </summary>
    [HttpPost("read")]
    [MapToApiVersion("3.0")]
    public async Task<MarkMultipleReadResponseDto> MarkMultipleAsRead(
        [FromBody] MarkMultipleReadRequestDto request,
        CancellationToken ct)
    {
        var command = new MarkNotificationsReadBatchCommand(
            targetAccountId: AccountId,
            ids: request.Ids,
            targetMasterUserId: AuthenticationInfo?.MasterUser?.Id);

        var result = await _dispatcher.DispatchCommand<MarkNotificationsReadBatchCommand, MarkNotificationsReadBatchResult>(command, ct);

        return new MarkMultipleReadResponseDto { UpdatedCount = result.UpdatedCount };
    }
}
```

### DI Configuration

```csharp
// Invoices.Api/DI/NotificationsConfiguration.cs
using Notifications.Application;

namespace Invoices.Api.DI;

public static class NotificationsConfiguration
{
    public static WebApplicationBuilder AddNotifications(this WebApplicationBuilder builder)
    {
        builder.Services.AddNotificationsModule(builder.Configuration, builder.Environment);
        return builder;
    }
}

// В Program.cs добавить:
// builder.AddNotifications();
```

### appsettings.json

```json
{
  "Notifications": {
    "ConnectionString": "Host=localhost;Database=invoices;Username=postgres;Password=postgres;SearchPath=notifications",
    "RetentionDays": 90
  }
}
```

---

## 1.8 Database Schema (Phase 1)

```sql
-- Создание схемы
CREATE SCHEMA IF NOT EXISTS notifications;

-- Таблица Notifications
CREATE TABLE notifications."Notifications" (
    "Id" BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "TargetAccountId" TEXT NOT NULL,
    "TargetMasterUserId" TEXT NULL,
    "TargetProductKey" TEXT NULL,
    "Type" INT NOT NULL,
    "Payload" JSONB NOT NULL,
    "CreatedAt" TIMESTAMPTZ NOT NULL,
    "ReadAt" TIMESTAMPTZ NULL,
    "SchemaVersion" INT NOT NULL,
    "Source" INT NOT NULL
);

-- Индексы
-- Основной для пагинации (account-wide)
CREATE INDEX "IX_Notifications_TargetAccountId_CreatedAt_Id"
    ON notifications."Notifications" ("TargetAccountId", "CreatedAt" DESC, "Id" DESC);

-- Для user-specific уведомлений
CREATE INDEX "IX_Notifications_TargetAccountId_TargetMasterUserId_CreatedAt_Id"
    ON notifications."Notifications" ("TargetAccountId", "TargetMasterUserId", "CreatedAt" DESC, "Id" DESC);
```

### EF Core миграции

```bash
cd Notifications/Notifications.Infrastructure
dotnet ef migrations add WEB-864_InitialCreate --context NotificationsDbContext
dotnet ef database update --context NotificationsDbContext
```

---

## 1.9 Usage Examples (Phase 1)

```csharp
// Пример 1: Первый платёж получен
using Notifications.Contracts.Notifications;
using Notifications.Domain.Interfaces;
using Notifications.Domain.Models;

public class PaymentService
{
    private readonly INotificationDispatcher _notificationDispatcher;

    public PaymentService(INotificationDispatcher notificationDispatcher)
    {
        _notificationDispatcher = notificationDispatcher;
    }

    public async Task ProcessFirstPayment(Payment payment, CancellationToken ct)
    {
        // ... payment processing ...

        await _notificationDispatcher.CreateNotification(new NotificationEvent
        {
            TargetAccountId = payment.AccountId,
            TargetMasterUserId = null, // account-wide
            Type = NotificationType.FirstPaymentReceived,
            Payload = new
            {
                amount = payment.Amount.ToString("F2"),
                currency = payment.Currency,
                clientName = payment.ClientName,
                invoiceNumber = payment.InvoiceNumber
            },
            OccurredAt = DateTime.UtcNow,
            Source = NotificationSource.Payments
        }, ct);
    }
}

// Пример 2: PSP онбординг завершён
public class PspOnboardingService
{
    private readonly INotificationDispatcher _notificationDispatcher;

    public async Task NotifyOnboardingCompleted(string accountId, string provider, CancellationToken ct)
    {
        await _notificationDispatcher.CreateNotification(new NotificationEvent
        {
            TargetAccountId = accountId,
            TargetMasterUserId = null,
            Type = NotificationType.PspOnboardingCompleted,
            Payload = new
            {
                provider = provider, // e.g. "stripe", "paypal"
                completedAt = DateTime.UtcNow
            },
            OccurredAt = DateTime.UtcNow,
            Source = NotificationSource.Stripe
        }, ct);
    }

    // Пример 3: PSP онбординг требует действий
    public async Task NotifyActionsRequired(string accountId, string[] missingFields, CancellationToken ct)
    {
        await _notificationDispatcher.CreateNotification(new NotificationEvent
        {
            TargetAccountId = accountId,
            TargetMasterUserId = null,
            Type = NotificationType.PspOnboardingActionsRequired,
            Payload = new
            {
                missingFields = missingFields,
                provider = "stripe"
            },
            OccurredAt = DateTime.UtcNow,
            Source = NotificationSource.Stripe
        }, ct);
    }

    // Пример 4: PSP верификация пройдена
    public async Task NotifyVerificationCompleted(string accountId, string verificationType, CancellationToken ct)
    {
        await _notificationDispatcher.CreateNotification(new NotificationEvent
        {
            TargetAccountId = accountId,
            TargetMasterUserId = null,
            Type = NotificationType.PspOnboardingVerificationCompleted,
            Payload = new
            {
                verificationType = verificationType, // e.g. "identity", "business"
                provider = "stripe",
                completedAt = DateTime.UtcNow
            },
            OccurredAt = DateTime.UtcNow,
            Source = NotificationSource.Stripe
        }, ct);
    }
}
```

---

## 1.10 Phase 1 Checklist

- [ ] Создать структуру проектов (5 проектов)
- [ ] Notifications.Contracts реализован
- [ ] Notifications.Domain реализован
- [ ] Notifications.Infrastructure реализован
- [ ] Notifications.Application реализован
- [ ] NotificationsController создан
- [ ] API DTO созданы
- [ ] DI регистрация настроена
- [ ] appsettings.json обновлен
- [ ] Миграции созданы и применены
- [ ] Unit тесты написаны
- [ ] Integration тесты написаны

---

# PHASE 2: Outbox Pattern & Multi-Channel Delivery

## 2.1 Цель и Scope

**Цель:** Добавить надежную доставку через Outbox pattern и поддержку Push/Email каналов.

**Что добавляется:**
- ✅ NotificationOutbox таблица
- ✅ NotificationDeliveryWorker
- ✅ Транзакции (Unit of Work)
- ✅ Exponential backoff retry
- ✅ Pessimistic locking
- ✅ IdempotencyKey
- ✅ NotificationDefinitionProvider
- ✅ Push notifications (OnePush)
- ✅ Email notifications

---

## 2.2 Новые модели (Phase 2)

### NotificationOutbox.cs

```csharp
namespace Notifications.Domain.Models;

public class NotificationOutbox
{
    public required long NotificationId { get; set; }
    public required NotificationChannel Channel { get; set; }
    public required DeliveryStatus Status { get; set; }
    public required int Attempts { get; set; }
    public required DateTime NextAttemptAt { get; set; }
    public required DateTime CreatedAt { get; set; }
    public required DateTime UpdatedAt { get; set; }
    public string? LastError { get; set; }
    public string? IdempotencyKey { get; set; }

    public Notification? Notification { get; set; }

    public static NotificationOutbox Create(
        long notificationId,
        NotificationChannel channel,
        string? idempotencyKey = null)
    {
        var now = DateTime.UtcNow;
        return new NotificationOutbox
        {
            NotificationId = notificationId,
            Channel = channel,
            Status = DeliveryStatus.Pending,
            Attempts = 0,
            NextAttemptAt = now,
            CreatedAt = now,
            UpdatedAt = now,
            IdempotencyKey = idempotencyKey
        };
    }
}

public enum NotificationChannel { InApp, Push, Email }
public enum DeliveryStatus { Pending, Sent, Failed, DeadLetter }
```

### NotificationDefinition.cs

```csharp
namespace Notifications.Domain.Models;

public class NotificationDefinition
{
    public required string Type { get; init; }
    public required NotificationChannel[] Channels { get; init; }
    public string? IdempotencyKeyTemplate { get; init; }
}
```

---

## 2.3 Новые интерфейсы (Phase 2)

### INotificationOutboxRepository.cs

```csharp
namespace Notifications.Domain.Interfaces;

public interface INotificationOutboxRepository
{
    Task InsertMany(IEnumerable<NotificationOutbox> items, CancellationToken ct);
    Task<List<NotificationOutbox>> GetPendingWithLock(int limit, CancellationToken ct);
    Task MarkAsSent(long notificationId, NotificationChannel channel, CancellationToken ct);
    Task MarkAsFailed(long notificationId, NotificationChannel channel, int attempts, string error, CancellationToken ct);
    Task<bool> ExistsByIdempotencyKey(string key, CancellationToken ct);
}
```

### INotificationsUnitOfWork.cs

```csharp
namespace Notifications.Domain.Interfaces;

public interface INotificationsUnitOfWork : IDisposable
{
    INotificationsRepository Notifications { get; }
    INotificationOutboxRepository Outbox { get; }
    Task BeginTransactionAsync(CancellationToken ct);
    Task CommitAsync(CancellationToken ct);
    Task RollbackAsync(CancellationToken ct);
}
```

### INotificationDefinitionProvider.cs

```csharp
namespace Notifications.Domain.Interfaces;

public interface INotificationDefinitionProvider
{
    NotificationChannel[] GetChannels(string type);
    string? GetIdempotencyKeyTemplate(string type);
}
```

---

## 2.4 Обновленный NotificationDispatcher (Phase 2)

```csharp
public class NotificationDispatcher : INotificationDispatcher
{
    private readonly INotificationsUnitOfWork _unitOfWork;
    private readonly INotificationDefinitionProvider _definitionProvider;
    private readonly ILogger<NotificationDispatcher> _logger;

    public async Task<Notification> CreateNotification(
        NotificationEvent notificationEvent,
        CancellationToken ct)
    {
        // 1. Check idempotency
        var idempotencyKey = BuildIdempotencyKey(notificationEvent);
        if (idempotencyKey != null)
        {
            if (await _unitOfWork.Outbox.ExistsByIdempotencyKey(idempotencyKey, ct))
            {
                _logger.LogWarning("Duplicate notification: {Key}", idempotencyKey);
                throw new DuplicateNotificationException(idempotencyKey);
            }
        }

        // 2. Begin transaction
        await _unitOfWork.BeginTransactionAsync(ct);

        try
        {
            // 3. Create notification
            var notification = Notification.Create(...);
            var saved = await _unitOfWork.Notifications.Insert(notification, ct);

            // 4. Create outbox tasks
            var channels = _definitionProvider.GetChannels(notificationEvent.Type);
            var outboxTasks = channels.Select(ch =>
                NotificationOutbox.Create(saved.Id, ch, idempotencyKey));

            await _unitOfWork.Outbox.InsertMany(outboxTasks, ct);

            // 5. Commit
            await _unitOfWork.CommitAsync(ct);
            return saved;
        }
        catch
        {
            await _unitOfWork.RollbackAsync(ct);
            throw;
        }
    }
}
```

---

## 2.5 NotificationDeliveryWorker (Phase 2)

```csharp
using Invoices.Jobs;

public class NotificationDeliveryWorker : RecurringJob
{
    private readonly IServiceProvider _serviceProvider;
    private readonly NotificationsOptions _options;

    public override TimeSpan SleepInterval =>
        TimeSpan.FromSeconds(_options.WorkerIntervalSeconds);

    public override async Task Process(CancellationToken token)
    {
        using var scope = _serviceProvider.CreateScope();
        var outboxRepo = scope.ServiceProvider.GetRequiredService<INotificationOutboxRepository>();

        var pending = await outboxRepo.GetPendingWithLock(_options.WorkerBatchSize, token);

        foreach (var task in pending)
        {
            try
            {
                await ProcessTask(task, scope.ServiceProvider, token);
                await outboxRepo.MarkAsSent(task.NotificationId, task.Channel, token);
            }
            catch (Exception ex)
            {
                await outboxRepo.MarkAsFailed(
                    task.NotificationId,
                    task.Channel,
                    task.Attempts + 1,
                    ex.Message,
                    token);
            }
        }
    }

    private async Task ProcessTask(NotificationOutbox task, IServiceProvider services, CancellationToken ct)
    {
        switch (task.Channel)
        {
            case NotificationChannel.InApp:
                // Already stored
                break;
            case NotificationChannel.Push:
                var pushService = services.GetRequiredService<IPushService>();
                await pushService.Send(task.Notification!, ct);
                break;
            case NotificationChannel.Email:
                var emailService = services.GetRequiredService<IEmailService>();
                await emailService.Send(task.Notification!, ct);
                break;
        }
    }
}
```

---

## 2.6 Database Schema (Phase 2)

```sql
-- Добавить таблицу NotificationOutbox
CREATE TABLE notifications."NotificationOutbox" (
    "NotificationId" BIGINT NOT NULL,
    "Channel" TEXT NOT NULL,
    "Status" TEXT NOT NULL,
    "Attempts" INT NOT NULL DEFAULT 0,
    "NextAttemptAt" TIMESTAMPTZ NOT NULL,
    "CreatedAt" TIMESTAMPTZ NOT NULL,
    "UpdatedAt" TIMESTAMPTZ NOT NULL,
    "LastError" TEXT NULL,
    "IdempotencyKey" TEXT NULL,
    PRIMARY KEY ("NotificationId", "Channel"),
    FOREIGN KEY ("NotificationId") REFERENCES notifications."Notifications"("Id") ON DELETE CASCADE
);

CREATE INDEX "IX_NotificationOutbox_Status_NextAttemptAt"
    ON notifications."NotificationOutbox" ("Status", "NextAttemptAt")
    WHERE "Status" = 'Pending';

CREATE UNIQUE INDEX "IX_NotificationOutbox_IdempotencyKey"
    ON notifications."NotificationOutbox" ("IdempotencyKey")
    WHERE "IdempotencyKey" IS NOT NULL;
```

---

## 2.7 NotificationsOptions (Phase 2)

```csharp
public class NotificationsOptions
{
    public const string SectionName = "Notifications";

    public string ConnectionString { get; set; } = null!;
    public int RetentionDays { get; set; } = 90;

    // Worker settings (Phase 2)
    public int WorkerBatchSize { get; set; } = 100;
    public int WorkerIntervalSeconds { get; set; } = 30;
    public int MaxRetryAttempts { get; set; } = 5;
}
```

---

## 2.8 Phase 2 Checklist

- [ ] NotificationOutbox модель добавлена
- [ ] NotificationChannel и DeliveryStatus enums
- [ ] INotificationOutboxRepository реализован
- [ ] INotificationsUnitOfWork реализован
- [ ] NotificationDefinitionProvider создан
- [ ] NotificationDispatcher обновлен
- [ ] NotificationOutbox таблица (миграция)
- [ ] NotificationOutboxRepository с pessimistic locking
- [ ] NotificationDeliveryWorker создан
- [ ] Worker зарегистрирован в WorkerCommonConfiguration
- [ ] Push notifications интегрированы
- [ ] Email notifications интегрированы
- [ ] Exponential backoff реализован
- [ ] Тесты обновлены

---

# PHASE 3: Advanced Features

## 3.1 Scope

- **User preferences** - настройки каналов доставки per user
- **SSE (Server-Sent Events)** - real-time уведомления
- **Retention policy** - автоудаление старых уведомлений
- **Delete notification endpoint** - удаление уведомлений пользователем

---

# Примечания

## Target Scoping

| TargetMasterUserId | Видимость |
|--------------------|-----------|
| `null` | Account-wide (все пользователи аккаунта) |
| `"user123"` | Только user123 |

## Безопасность

- Пользователь видит: свои (user-scoped) + account-wide уведомления
- Фильтрация через WHERE в репозитории
- AccountId и MasterUserId из BaseController

## Exponential Backoff (Phase 2)

| Attempt | Delay |
|---------|-------|
| 1 | 1 min |
| 2 | 2 min |
| 3 | 4 min |
| 4 | 8 min |
| 5 | 16 min |
| 6+ | 30 min (max) |

После MaxRetryAttempts → DeadLetter status.
