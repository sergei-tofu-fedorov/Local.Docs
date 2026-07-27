# backend-notifications — лента уведомлений о работе команды

Владелец аккаунта получает ленту уведомлений о действиях воркеров по **визитам**: воркер начал визит, закончил визит, не начал вовремя, принял приглашение в команду. Лента живёт в существующем модуле `Invoices.Backend/Src/Notifications` — новых таблиц не появляется, добавляются два поля к `Notification`, группировка по визиту на чтении, ручка колокольчика, `mark all read` и четыре типа событий. Отправка пушей, оффлайн-режим и персональная прочитанность в аккаунте с несколькими пользователями в этот этап не входят.

Related ClickUp tasks: _TBD — тикет на момент написания не заведён; груминг «Грумминг нотификаций» 2026-07-22, [запись](https://app.fireflies.ai/view/01KY4MA65FCVFNDYQ3E21VS41X)._

Входные документы: требования и макет — [`README.md`](README.md), состояние модуля — [`current-state.md`](current-state.md), исследование — [`web-spike.md`](web-spike.md), ключ схлопывания — [`collapse-key.md`](collapse-key.md), связь с таймлайном — [`activity-impact.md`](activity-impact.md).

## Scope

**In scope**

- Четыре типа событий: начало визита, конец визита, визит не начат вовремя, воркер принял приглашение. Все — только по действиям воркера.
- Группировка «одна карточка на визит» с показом последнего события.
- `mark as read` по карточке и `mark all read` по аккаунту.
- Ручка для колокольчика: признак наличия непрочитанного и счётчик для таба `Unread N`.
- Поля `EntityType` / `EntityId` у записи ленты и индексы под группировку и непрочитанные.
- Отложенный процесс «визит не начат вовремя» на существующей Hangfire-машинерии.

**Out of scope**

- Пуши и бейдж на иконке приложения (решено на груминге, 18:23, 20:37).
- Оффлайн: клиент показывает заглушку, серверной поддержки не требуется.
- Персональная прочитанность в аккаунте с несколькими пользователями — принято ограничение «общая на аккаунт».
- Дайджесты, preferences, выбор канала, ML-релевантность.
- Retention-партиционирование; чистка старых записей — отдельной задачей.
- SSE и любой push-транспорт: колокольчик обновляется опросом (обоснование — в [`web-spike.md`](web-spike.md)).
- Типы событий по инвойсам и эстимейтам.

## High-level approach

Модуль `Notifications` уже содержит всё ядро ленты: сущность с `ReadAt` и jsonb-payload, курсорную пагинацию с фильтрами, `POST /{id}/read`, REST-контроллер на api-version 3.0 и Hangfire-движок отложенных процессов с проверенными механиками (транзакционная постановка, арбитраж гонок через уникальный частичный индекс, staleness guard). План — минимальные дельты к нему, без новых таблиц и без нового инфраструктурного слоя.

Четыре решения, каждое выбрано в пользу простоты:

- **Группировка на чтении (`DISTINCT ON`), не на записи.** Пишем каждое событие отдельной строкой, в ленте отдаём последнюю на визит. Так не нужны ни upsert, ни уникальный индекс с NULL-нюансом, ни правила «оповестить заново», а курсор по `(CreatedAt, Id)` остаётся стабильным — при коллапсе на записи с подъёмом карточки наверх keyset-курсор начинает терять и дублировать строки. Цена — чуть сложнее запрос ленты и подсчёт непрочитанных.
- **`hasn't started yet` на существующем Hangfire-процессе, а не периодическим сканом.** Процесс per-visit по образцу `PaymentReminder`: `NotificationScheduler.RescheduleAsync` при изменении расписания, `CompleteIfActive` при старте визита или удалении. Готовые staleness guard и арбитраж гонок снимают именно те проблемы (осиротевшие wake-ups, двойная отправка), которые в самописном скане пришлось бы решать заново.
- **Инлайн-вызов диспетчера из хендлеров после коммита, а не outbox.** Повторяет уже существующий путь `Invoices.Payments/PaymentsService.cs:301`. Ценой принимается риск: при сбое вставки уведомление теряется, но ложных уведомлений не бывает никогда — вызов идёт после успешного коммита джоба.
- **Прочитанность общая на аккаунт.** `TargetMasterUserId = NULL`, одна строка на событие. Владелец прочитал — у менеджера тоже погасло; зафиксировано как известное ограничение MVP.

| Решение | Выбрано | Отклонено, потому что |
|---|---|---|
| Место коллапса | на чтении, `DISTINCT ON` | на записи — дрейф keyset-курсора и правила renotify |
| Просрочка визита | Hangfire-процесс per-visit | скан — свой дедуп, свой обход таймзон, свои гонки |
| Проводка событий | инлайн после коммита | outbox — таблица + релей + задержка 15 с |
| Прочитанность | общая на аккаунт | fan-out на запись — список получателей из `Tofu.Auth`, строк в N раз больше |

Прочитанность при группировке на чтении определяется просто: **отметка карточки прочитанной помечает все строки этого визита**. Тогда «есть непрочитанная строка» тождественно «есть непрочитанная карточка», и колокольчику достаточно `EXISTS` по частичному индексу — без пересчёта схлопнутого набора.

## Data model

Новых таблиц нет. Расширяется `notifications."Notifications"` (`Notifications.Domain/Models/Notification.cs`, конфигурация `Notifications.Infrastructure/Database/Configurations/NotificationConfiguration.cs`).

| Column | Type | Notes |
|---|---|---|
| `EntityType` | `integer NOT NULL DEFAULT 0` | enum `NotificationEntityType`: `None = 0`, `Visit = 1`, `Worker = 2`. `None` = карточка не схлопывается (текущие платёжные типы), поэтому дефолт безопасен для существующих строк |
| `EntityId` | `text NULL` | id сущности: `Visit.Id` (Guid как строка) либо worker id. `NULL` ⟺ `EntityType = None`; CHECK `("EntityType" = 0) = ("EntityId" IS NULL)` |

Индексы (существующие два под курсорную пагинацию остаются без изменений):

- `("TargetAccountId", "EntityType", "EntityId", "CreatedAt" DESC, "Id" DESC)` — покрывает `DISTINCT ON (EntityType, EntityId)` в ленте: выражения группировки идут слева, поэтому индекс отдаёт строки уже в нужном порядке и позволяет перескакивать к следующей группе без сортировки.
- `("TargetAccountId") WHERE "ReadAt" IS NULL` — частичный, под `EXISTS` для точки на колокольчике и под массовый `mark all read`. Частичный, а не полный, потому что непрочитанные — заведомо малая доля таблицы.
- `("TargetAccountId", "EntityType", "EntityId") WHERE "ReadAt" IS NULL` — под «пометить прочитанными все строки визита» и под счётчик уникальных непрочитанных карточек для таба `Unread N`.

### Migration

```powershell
dotnet ef migrations add FS-XXXX_NotificationEntityRef `
    -c NotificationsDbContext `
    -p "Invoices.Backend\Src\Notifications\Notifications.Infrastructure" `
    -s "Invoices.Backend\Src\Invoices.Api" `
    -o Migrations
```

Применяется не через `dotnet ef database update`, а автоматически модульным мигратором `NotificationsModuleMigrator` (`Notifications.Infrastructure/Migrations/NotificationsModuleMigrator.cs`).

## Domain integration

### Каталоги и модель

- `Notifications.Domain/NotificationType.cs` — четыре значения: `VisitStarted`, `VisitFinished`, `VisitNotStartedOnTime`, `WorkerJoinedTeam`. Значения добавляются **в конец** enum, чтобы не сдвинуть уже записанные в базу числа.
- `Notifications.Domain/NotificationSource.cs` — добавить `Jobs` (события визитов) и `Team` (приглашения).
- `Notifications.Domain/NotificationEntityType.cs` — новый enum (`None`, `Visit`, `Worker`).
- `Notification.Create(...)` (`Notification.cs:17-38`) получает два параметра — `entityType`, `entityId`; существующие два вызова в платежах передают `None`/`null`.
- `NotificationEvent` (`Notifications.Domain/Models/NotificationEvent.cs`) — те же два поля, чтобы диспетчер их протаскивал без изменения логики (`NotificationDispatcher.cs:37-45`).

### Payload

Payload собирается **в момент эмиссии**, когда джоб и визит уже загружены в память хендлера — дополнительных запросов не требуется, кроме телефона воркера. Сериализация camelCase уже настроена в `NotificationDispatcher.cs:58-69`.

```csharp
// Notifications.Contracts/Notifications/Payloads/VisitNotificationPayload.cs
public sealed record VisitNotificationPayload
{
    public required string VisitId { get; init; }
    public required string JobId { get; init; }          // клик по карточке ведёт в визит внутри джоба
    public required string WorkerName { get; init; }     // "Mike J." — форма имени определяется клиентом
    public string? WorkerPhone { get; init; }            // отсутствует → клиент рисует "Open visit" вместо "Call"
    public required DateTimeOffset ScheduledStart { get; init; }
    public required DateTimeOffset ScheduledEnd { get; init; }
    public string? ServiceName { get; init; }
    public string? Address { get; init; }
}

// Notifications.Contracts/Notifications/Payloads/WorkerJoinedPayload.cs
public sealed record WorkerJoinedPayload
{
    public required string WorkerName { get; init; }
    public string? WorkerId { get; init; }
}
```

Чип `24 min late` считает клиент как разницу текущего времени и `ScheduledStart` — иначе значение, записанное на момент события, устареет в открытой ленте.

### Продюсеры

| Событие | Точка эмиссии | Условие |
|---|---|---|
| `VisitStarted` | `Jobs.Application/Worker/Commands/WorkerUpdateVisitStatusCommandHandler.cs:52-57`, после `SaveChangesAsync` | переход `VisitStatus.Scheduled → InProgress` |
| `VisitFinished` | там же | переход в `VisitStatus.Completed` |
| `WorkerJoinedTeam` | `Invoices.Api/Controllers/AuthorizationController.cs:79`, рядом с существующим `SendWorkerJoinedPushAsync` | воркер принял приглашение |
| `VisitNotStartedOnTime` | новый Hangfire-процессор (ниже) | визит всё ещё `Scheduled` спустя порог после `ScheduledStart` |

Эмиссия только из воркерского хендлера (`WorkerUpdateVisitStatusCommandHandler`), не из `UpdateVisitStatusCommandHandler` — этим фильтр «только действия воркера» из груминга (22:25) обеспечивается выбором точки вызова, без проверки актора в рантайме.

Телефон воркера берётся через существующий `IJobWorkerService.GetTeamMember(accountId, memberId, ct)` (`Jobs.Application/Services/Workers/IJobWorkerService.cs:11`).

### Процесс «визит не начат вовремя»

Полностью по образцу `PaymentReminder` — чистая машина состояний плюс верификатор, без I/O внутри:

- `Notifications.Contracts/.../VisitLate/VisitLateContext.cs` — `record` с `AccountId`, `VisitId`, `JobId`, `ScheduledStartUtc`; реализует `INotificationContext` и `IWithEntityId` (`EntityId = VisitId`), `ProcessType = "visit-late"`.
- `Notifications.Domain/VisitLate/VisitLateProcess.cs` — на пробуждении: если визит всё ещё не начат, отдать `ProcessResult` с терминальным состоянием и одной «доставкой» в ленту; иначе — терминал без доставки. Состояние одно (`VisitLateState.Pending`), потому что серии, в отличие от reminder'ов, нет.
- `Notifications.Domain/VisitLate/IVisitLateVerifier.cs` + реализация в `Notifications.Application` — читает текущий статус визита и его расписание.
- Регистрация keyed-сервисом в `Notifications.Application/NotificationsModule.cs:49-54` — по образцу двух существующих процессоров, правки `NotificationProcessHandler` не требуются.

Важно: `ProcessResult.Deliveries` сейчас описывает только email и пуш (`NotificationProcessHandler.cs:107-140`). Для этого процесса результатом должна быть **запись в ленту**, поэтому в `ScheduleDeliveries` добавляется третья ветка — либо процессор вызывает `INotificationDispatcher` напрямую в своём `Process`, что короче и не меняет общий контракт доставок. Выбрано второе.

Планирование и отмена — существующим `INotificationScheduler`:

| Триггер | Вызов |
|---|---|
| визит создан или расписание изменено | `RescheduleAsync(accountId, new VisitLateContext(...))` из `Jobs.Application/Commands/UpdateVisitCommandHandler.cs` и `UpsertJobCommandHandler.cs` |
| воркер начал визит | `CompleteIfActive(accountId, "visit-late", visitId)` из `WorkerUpdateVisitStatusCommandHandler` |
| визит или джоб удалён | `CompleteIfActive(...)` из `DeleteJobCommandHandler.cs` |

Порог просрочки — новый ключ конфигурации `Notifications:VisitLate:Threshold` (по умолчанию 15 минут), рядом с существующей секцией `Notifications:Hangfire`.

### Репозиторий

Дополнения к `INotificationsRepository` / `NotificationsRepository.cs`:

- `GetPagedCollapsed(...)` — заменяет `GetPaged` в пути ленты: `DISTINCT ON ("EntityType", "EntityId")` для строк с `EntityType <> None`, объединённый с построчной выдачей для `None`, поверх — существующая курсорная логика `(CreatedAt, Id)` и фильтры `unread` / `type`.
- `ExistsUnread(accountId, masterUserId, ct)` — `EXISTS` по частичному индексу.
- `CountUnreadCards(accountId, masterUserId, ct)` — `COUNT(DISTINCT ("EntityType","EntityId"))` по непрочитанным плюс число непрочитанных строк с `EntityType = None`.
- `MarkEntityRead(accountId, entityType, entityId, ct)` — массовый `UPDATE ... SET "ReadAt" = now() WHERE "ReadAt" IS NULL` по строкам сущности.
- `MarkAllRead(accountId, masterUserId, readUpTo, ct)` — то же по аккаунту с отсечкой `"CreatedAt" <= readUpTo`.

## Endpoints

```
GET  /api/notifications                 (существует; поведение чтения меняется на схлопнутое)
GET  /api/notifications/unread-summary  (новый)
POST /api/notifications/{id}/read       (существует; расширяется до всех строк сущности)
POST /api/notifications/read            (новый — mark all read)
```

Все — `[ApiVersion("3.0")]` в `Invoices.Api/Controllers/NotificationsController.cs`, `AccountId` и `AuthenticationInfo` из `BaseController`.

### DTOs

```csharp
// Invoices.Api/Dto/Notifications/NotificationResponseDto.cs — добавляются два поля
public NotificationEntityTypeDto EntityType { get; set; }
public string? EntityId { get; set; }

// новый
public sealed record UnreadSummaryResponseDto
{
    public required bool HasUnread { get; init; }  // питает точку на колокольчике: EXISTS, без подсчёта
    public required int Count { get; init; }       // питает таб "Unread N": число карточек, не строк
}

// новый
public sealed record MarkAllReadRequestDto
{
    // Отсечка по времени: помечаются только записи, созданные не позже этого момента.
    // Без неё уведомление, пришедшее за время полёта запроса, погасло бы непрочитанным.
    public DateTimeOffset? ReadUpTo { get; init; }
}
```

`NotificationTypeDto` и `NotificationSourceDto` (`Invoices.Api/Dto/Notifications/NotificationResponseDto.cs:26-51`) получают camelCase-значения новых членов: `visitStarted`, `visitFinished`, `visitNotStartedOnTime`, `workerJoinedTeam`, `jobs`, `team`. Новый `NotificationEntityTypeDto` — `none` / `visit` / `worker`.

### Алгоритмы

- **`GET /api/notifications`** — как сейчас (`NotificationsController.cs:24-62`), но через `GetPagedCollapsed`. Лимит по-прежнему зажимается в `[DefaultLimit = 50, MaxLimit = 100]` (`GetNotificationsQuery.cs:13-14`); макет запрашивает 10–15 в поповере и больше на полном экране, отдельного серверного лимита под поповер не вводим.
- **`GET /api/notifications/unread-summary`** — `ExistsUnread` + `CountUnreadCards`. Считается на каждом открытии ленты и на навигации в вебе, поэтому оба запроса опираются на частичные индексы.
- **`POST /{id}/read`** — находит запись по `(AccountId, Id)` как сейчас (`MarkNotificationReadCommandHandler.cs:31-41`); если у неё `EntityType <> None`, помечает прочитанными **все** строки этой сущности, иначе только её саму.
- **`POST /read`** — `MarkAllRead` с `ReadUpTo ?? DateTimeOffset.UtcNow`.

### Validation and errors

- Неизвестный `id` → `EntityNotFoundException` из существующего хендлера, наружу превращается в 404 middleware'ом.
- Битый или чужой `cursor` → `Cursor.Decode` логирует и возвращает `null`, то есть выдача начинается с начала (существующее поведение, не меняется).
- `ReadUpTo` в будущем — принимается как есть: отсечка «не позже» и так ограничена существующими записями.

## Authorization

Сейчас у `NotificationsController` нет ни одного `[AuthorizeAction]`, то есть ленту может запросить любой держатель токена с контекстом аккаунта — включая воркера, которому предназначен worker-app. Лента же по требованиям груминга адресована владельцу и менеджерам. Предлагается закрыть все четыре эндпоинта существующим ключом `PermissionKeys.Worker.View` (`Tofu.Permissions.Shared/Domain/PermissionKeys.cs:46`) — он уже означает «может видеть команду», что ровно совпадает с содержанием ленты, и не требует новых ключей в `Tofu.Auth`.

| Action | Owner / Manager | Worker | Client |
|---|---|---|---|
| Читать ленту | Yes | No | — |
| Колокольчик (`unread-summary`) | Yes | No | — |
| Пометить карточку прочитанной | Yes | No | — |
| `mark all read` | Yes | No | — |

_TBD — verify: подтвердить, что у роли Worker нет `worker.view` в текущем сиде permissions, прежде чем опираться на этот ключ._

## Lifecycle

| Trigger | Behaviour |
|---|---|
| Расписание визита изменено | активный `visit-late` процесс переставляется (`RescheduleAsync`); уже созданные карточки не меняются — решение груминга (42:28) |
| Воркер начал визит | `visit-late` снимается (`CompleteIfActive`); карточка «не начат вовремя» остаётся в ленте, новая строка `VisitStarted` становится последней в группе и вытесняет её из выдачи |
| Визит переназначен другому воркеру | активный `visit-late` снимается: причина алярма исчезла вместе с назначением. Новый процесс ставится, если у нового назначения расписание в будущем |
| Джоб или визит удалён | `visit-late` снимается; карточки визита помечаются прочитанными и перестают влиять на колокольчик (полное удаление строк — отдельной задачей вместе с retention) |
| Воркер удалён из команды | карточки не удаляются: событие «принял приглашение» уже произошло |
| Запись старше 30 дней | вне скоупа этого этапа; ориентир и обоснование — в [`web-spike.md`](web-spike.md) |

## Docs to Update

- `Local.Docs/Backend/Api/NOTIFICATIONS_API_REFERENCE.md` — два новых эндпоинта, два новых поля в `NotificationResponseDto`, новые значения enum'ов.
- `Local.Docs/Backend/Storage/` — таблица `notifications."Notifications"`: две колонки и три индекса.
- `Invoices.Backend/Docs/API/openapi/Invoices.Api_v3.json` — регенерировать: `dotnet build Src/Invoices.Api -c Release -t:GenerateOpenApi`.
- [`current-state.md`](current-state.md) — после реализации обновить as-is описание модуля.
