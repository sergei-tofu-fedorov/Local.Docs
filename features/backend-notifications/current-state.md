# backend-notifications — что уже есть в модуле Notifications (as-is)

Фактическое состояние модуля `Invoices.Backend/Src/Notifications` на 2026-07-27: хранилище, эндпоинты, потоки, процессы и механики надёжности. Разбор по коду, без предложений — требования лежат в [`README.md`](README.md), исследование в [`web-spike.md`](web-spike.md), связь с таймлайном в [`activity-impact.md`](activity-impact.md).

Ключевое, что стоит понять сразу: в модуле **два независимых механизма**, и они между собой не связаны.

- **Лента** — персистентные записи `Notification`, читаются REST-эндпоинтом с курсором. Наполняется двумя инлайн-вызовами из платежей.
- **Движок отложенной доставки** — многошаговые Hangfire-процессы, которые отправляют email и пуши по расписанию. В ленту **не пишет ничего**.

История модуля по миграциям: WEB-864 (лента), FS-867 (`NotificationJobs`, процессы), FS-1300 (per-entity процессы для reminder-серий).

## Хранилище

Отдельный `NotificationsDbContext` со своей строкой подключения (`Notifications:ConnectionString`) и схемой по умолчанию `notifications`. Postgres.

| Таблица | Назначение |
|---|---|
| `notifications."Notifications"` | лента: одна строка = одно уведомление |
| `notifications."NotificationJobs"` | реестр активных отложенных процессов |
| схема `hangfire` | служебные таблицы Hangfire, создаются автоматически (`PrepareSchemaIfNecessary = true`), имя схемы из `Notifications:Hangfire:SchemaName` |

### `Notifications` — лента

`Notifications.Domain/Models/Notification.cs`, конфигурация в `Notifications.Infrastructure/Database/Configurations/NotificationConfiguration.cs`.

| Колонка | Тип | Заметки |
|---|---|---|
| `Id` | `int`, identity always | ключ; он же участвует в курсоре |
| `TargetAccountId` | string, required | адресат-аккаунт |
| `TargetMasterUserId` | string, nullable | `null` = уведомление на весь аккаунт |
| `TargetProductKey` | string(64), nullable | продукт |
| `Type` | enum `NotificationType` | `Unknown`, `FirstPaymentReceived`, `PspOnboardingCompleted` |
| `Payload` | `jsonb`, nullable | произвольные данные, camelCase, enum'ы строками |
| `CreatedAt` | `timestamptz`, required | момент события (`OccurredAt`, если передан) |
| `ReadAt` | `timestamptz`, nullable | `null` = не прочитано; `MarkAsRead()` идемпотентен (`??=`) |
| `SchemaVersion` | int, required | сейчас всегда `1` |
| `Source` | enum `NotificationSource` | `Unknown`, `Payments`, `Stripe` |

Два индекса, оба под курсорную пагинацию: `(TargetAccountId, CreatedAt↓, Id↓)` и `(TargetAccountId, TargetMasterUserId, CreatedAt↓, Id↓)`. Частичного индекса по непрочитанным **нет**.

### `NotificationJobs` — реестр процессов

`Notifications.Domain/Models/NotificationJob.cs`: `Id` (Guid, генерируется в коде), `AccountId`, `ProcessType` (string, 128), `EntityId` (nullable — «per-entity discriminator, e.g. invoice id»), `HangfireJobId`, `CreatedAt` (`default now()`), `CompletedAt`.

Главная механика — уникальный частичный индекс:

```
uq_notification_job_active: UNIQUE (AccountId, ProcessType, EntityId) WHERE "CompletedAt" IS NULL
```

То есть на аккаунт (и сущность) может быть только один активный процесс данного типа. Именно этот индекс используется как арбитр гонок.

Миграции применяются не `dotnet ef database update`, а через `NotificationsModuleMigrator` (реализация `IModuleMigration`).

## Эндпоинты

`Invoices.Api/Controllers/NotificationsController.cs`, `[ApiVersion("3.0")]`, маршрут `api/notifications`. Наследует `BaseController`, поэтому `AccountId` и `AuthenticationInfo` берутся из middleware.

| Метод | Параметры | Ответ |
|---|---|---|
| `GET /api/notifications` | `unread` (bool?), `type` (enum?), `limit` (int?), `cursor` (string?) | `NotificationsListResponseDto { items[], nextCursor }` |
| `POST /api/notifications/{id:int}/read` | — | `204 No Content` |

Поведение чтения (`GetNotificationsQueryHandler` + `NotificationsRepository.GetPaged`):

- скоуп: `TargetAccountId = AccountId` И (`TargetMasterUserId IS NULL` ИЛИ `= AuthenticationInfo.MasterUser.Id`) — то есть аккаунтные плюс свои личные;
- `unread=true` → `ReadAt IS NULL`, `unread=false` → `ReadAt IS NOT NULL`, отсутствие параметра → всё;
- `limit` зажимается в `[DefaultLimit, MaxLimit]` из `GetNotificationsQuery`;
- курсор — base64 от `NotificationsPaginationToken { CreatedAt, NotificationId }` (`Notifications.Application/Cursor.cs`), выборка `Take(limit + 1)` для определения `HasMore`;
- сортировка `CreatedAt DESC, Id DESC`.

DTO (`Invoices.Api/Dto/Notifications/`): `id`, `type`, `payload` (строка как есть, не разобранный объект), `createdAt`, `readAt`, `source`. Enum'ы сериализуются camelCase-строками: `unknown` / `firstPaymentReceived` / `pspOnboardingCompleted` и `unknown` / `payments` / `stripe`.

Отметка прочитанного ищет запись по паре `(TargetAccountId, Id)`, то есть чужую пометить нельзя.

Отдельно: **Hangfire-дашборд** поднимается только в воркере (`Invoices.Worker/DI/NotificationsConfiguration.cs`).

## Поток 1: лента

```
PaymentsService / PaymentIntentsService
        ↓ INotificationDispatcher.CreateNotification(NotificationEvent)
   NotificationDispatcher: сериализует Payload в jsonb (camelCase)
        ↓ INotificationsRepository.Insert
   notifications."Notifications"
        ↓ GET /api/notifications (курсор, фильтры)
   клиент
```

Всего два места создания записей:

| Где | Тип | Условие |
|---|---|---|
| `Invoices.Payments/PaymentsService.cs:301` | `PspOnboardingCompleted` (source `Stripe`) | статус подключения PSP сменился на `Connected` |
| `Invoices.Payments/PaymentIntentsService.cs:591` | `FirstPaymentReceived` | — |

`NotificationEvent` (вход диспетчера): `TargetAccountId`, `TargetMasterUserId`, `TargetProductKey`, `Type`, `Payload` (object), `Source`, `OccurredAt`.

## Поток 2: отложенная доставка

Полностью отдельная машинерия, живёт на Hangfire и в ленту не пишет.

```
триггер (InvoiceReminderScheduler / PlansService)
    ↓ INotificationScheduler.Schedule | RescheduleAsync | CompleteIfActive
  NotificationScheduler: enqueue/schedule Hangfire-job + строка в NotificationJobs (в одной транзакции)
    ↓ (wake по расписанию)
  NotificationProcessHandler.Process(accountId, processType, state, context)
    ├── staleness guard: сравнение своего JobId с HangfireJobId в БД
    ├── keyed-разрешение процессора по processType
    ├── processor.Process(...) → ProcessResult { NewState, Deliveries, NextWakeTime, IsTerminal, UpdatedContext }
    ├── ScheduleDeliveries → EmailDeliveryJob | PushDeliveryJob
    └── терминал → CompletedAt; иначе → следующий wake, HangfireJobId обновляется
```

Процессоры регистрируются keyed-сервисами по `ProcessType`, то есть добавление нового процесса не требует правки хендлера (`NotificationsModule.cs:43-54`).

### Два существующих процесса

| Процесс | Уровень | Что делает |
|---|---|---|
| `PaymentReminder` (FS-1300) | per-invoice (`EntityId` = invoice id) | серия напоминаний об оплате: на каждом wake отправляет напоминание номер `ReminderNumber` и планирует следующее на `anchor + IntervalDays × (n+1)`; терминал — после последнего либо как только инвойс перестал быть eligible или сместился anchor |
| `DuplicateSubscription` (WEB-864 / FS-867) | per-account | обработка дублирующихся подписок; состояние `DuplicateSubscriptionState`, стартует с `Init` |

Сами машины состояний — чистые, без I/O: свежие данные считает верификатор (`IPaymentReminderVerifier`, `ISubscriptionVerifier`) и передаёт внутрь. Это прямо заявлено в комментарии к `PaymentReminderProcess`.

### Каналы доставки

`EmailDeliveryJob` (внешние письма, перебор провайдеров с fallback), `InternalEmailDeliveryJob` (внутренние), `PushDeliveryJob`. Ставятся в очередь либо из `ScheduleDeliveries`, либо напрямую через `INotificationEnqueuer` (`EnqueueEmail` / `EnqueueInternalEmail` / `EnqueuePush`).

`EmailDeliveryJob` — единственное место, где модуль касается Activity: после отправки reminder-письма он вызывает `_invoicesGateway.RecordReminderResult(...)`, что порождает событие таймлайна в домене инвойсов. Подробности в [`activity-impact.md`](activity-impact.md).

## Механики надёжности

Это самая продуманная часть модуля, и её стоит переиспользовать, а не изобретать заново.

- **Транзакционная постановка.** `TransactionScopeUnitOfWork`: Hangfire-enqueue делается внутри транзакции, поэтому откат транзакции откатывает и постановку задачи. В коде это отмечено дважды — «Disposing the TransactionScope without Complete() rolls back the Hangfire enqueue too».
- **Арбитраж гонок через уникальный индекс.** `Schedule` сначала проверяет активный процесс (fast path без транзакции), затем `TryInsertActive`; проигравший гонку просто откатывается и возвращает `false`.
- **Staleness guard.** `NotificationProcessHandler.Process` сравнивает свой `BackgroundJob.Id` с `HangfireJobId` активной строки: если они разошлись или строки нет, wake считается осиротевшим и процесс завершается без отправки. Комментарий объясняет цену ошибки — «running it would re-send a reminder after the series already ended». Прямые (не-Hangfire) вызовы с `null` job id гард сознательно обходят.
- **Доставка до терминала.** Deliveries планируются **до** проверки `IsTerminal`, потому что последнее напоминание в серии — терминальный результат, который всё ещё несёт письмо.
- **Best-effort побочные записи.** Запись статуса письма и события таймлайна не пробрасывают исключения: письмо уже отправлено, и падение вызвало бы Hangfire-ретрай с повторной отправкой.
- **Ретраи и корреляция.** `AutomaticRetryAttribute` с `Attempts = RetryCount` (по умолчанию 3), `CorrelationIdFilter`, `correlationId` протаскивается в параметры доставки.

## Где что запускается

| Хост | Что делает |
|---|---|
| `Invoices.Api` | регистрирует модуль (`Program.cs:62` → `builder.AddNotifications()`), отдаёт REST-эндпоинты, **ставит** задачи в Hangfire |
| `Invoices.Worker` | регистрирует модуль + **поднимает Hangfire-сервер** (`AddNotificationsHangfireServer`) и дашборд |

То есть исполнение всех отложенных процессов и доставок происходит в воркере, API только пишет в очередь. Это отвечает на вопрос, где размещать будущий релей job-событий: в воркере, где уже есть Hangfire-сервер.

## Конфигурация

```
Notifications:ConnectionString                    (required)
Notifications:Hangfire:RetryCount                 (default 3)
Notifications:Hangfire:WorkerCount                (default 5)
Notifications:Hangfire:SchedulePollingInterval    (default 00:00:15)
Notifications:Hangfire:SchemaName                 (default "hangfire")
```

В `appsettings.json` значения — плейсхолдеры (`<TODO_NOTIFICATIONS_CONNECTION_STRING>`), реальные приходят из секретов окружения.

## Чего в модуле нет

Кратко, детали и следствия — в разделе «Гэпы» в [`README.md`](README.md).

- Нет `mark all read` и нет ручки для колокольчика (ни `count`, ни `exists`), нет частичного индекса по непрочитанным.
- Нет ссылки на сущность (`EntityId`) у записи ленты и, соответственно, никакого коллапса или группировки.
- В `NotificationType` только два платёжных значения; событий по визитам и команде нет.
- Отложенные процессы в ленту не пишут — обе половины модуля живут независимо.
- Пуш «worker joined» вообще вне модуля: `Invoices.Api/Services/TeamNotificationService.cs` отправляет его напрямую, без записи в ленту.
