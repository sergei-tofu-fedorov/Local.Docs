# backend-notifications — Web Spike: доставка in-app уведомлений в веб

Что исследовалось: чем обновлять колокольчик и ленту в вебе под наш стек (.NET 8 BFF на GKE, Postgres + EF Core, Hangfire), как дешёво отдавать «последнее событие на визит» и «есть ли непрочитанное», и как надёжно связать триггер `JobDomainEvent` с записью в модуль `Notifications`, живущий на отдельном `DbContext`. Спайк нужен потому, что на груминге 2026-07-22 транспорт не обсуждался вообще (решили «фетч при открытии»), а два решения — группировка по визиту и индикатор непрочитанного — упираются в схему, которой в коде ещё нет.

Дата спайка: 2026-07-27.

## Questions

1. Чем обновлять колокольчик в вебе: polling дешёвой ручки vs SSE vs WebSocket/SignalR vs Web Push — что подходит под GKE + .NET 8 и что это стоит в инфраструктуре.
2. Как отдавать «последнее событие на визит» и «есть ли непрочитанное» в Postgres/EF Core: `DISTINCT ON` поверх ленты vs денормализованный агрегат; какие индексы.
3. Как надёжно связать `JobDomainEvent` (UoW модуля Jobs) с `Notification` (отдельный `NotificationsDbContext`): общая транзакция vs outbox; идемпотентность.
4. Смежное: retention ленты, цена `mark all read`, прецеденты группировки и модели прочитанности в чужих notification-системах.

## Sources

**Стандарты и вендорская документация (preferred):**
- [PostgreSQL 18 — 11.8. Partial Indexes](https://www.postgresql.org/docs/current/indexes-partial.html) — определение частичного индекса и когда он даёт выигрыш.
- [PostgreSQL — 5.12. Table Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html) — декларативное партиционирование как механизм retention.
- [Google Cloud — Backend services overview](https://docs.cloud.google.com/load-balancing/docs/backend-service) — backend service timeout, поведение на WebSocket.
- [Google Cloud — Ingress features (BackendConfig)](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/ingress-features) — `timeoutSec` и его дефолт в GKE Ingress.
- [Google Cloud — Troubleshoot external Application Load Balancers](https://docs.cloud.google.com/load-balancing/docs/https/troubleshooting-ext-https-lbs) — keepalive-таймаут LB и 5XX от рассинхрона keepalive.
- [Firebase — Get started with FCM in Web apps](https://firebase.google.com/docs/cloud-messaging/web/get-started) — web push через service worker + VAPID.
- [Firestore — Pricing](https://firebase.google.com/docs/firestore/enterprise/pricing) — как тарифицируются realtime-листенеры.
- [MDN — HTTP conditional requests](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Conditional_requests) и [304 Not Modified](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/304) — `ETag`/`If-None-Match` для дешёвого опроса.
- [microservices.io — Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html) — Chris Richardson, формулировка паттерна и требование идемпотентности.

**Инженерные блоги (acceptable, named authors/teams):**
- [GetStream — Long Polling vs WebSockets](https://getstream.io/blog/long-polling-vs-websockets/) — команда, которая держит feeds-as-a-service; рекомендация именно для notification-фидов.
- [G-Research — Optimising SignalR on Kubernetes](https://www.gresearch.com/news/signalr-on-kubernetes/) — конкретные грабли SignalR за Ingress в K8s.
- [Anton Dev Tips — Real-Time Server-Sent Events in ASP.NET Core](https://antondevtips.com/blog/real-time-server-sent-events-in-asp-net-core) (22.07.2025) — версия .NET, в которой SSE стал встроенным.
- [MagicBell — Notification System Design](https://www.magicbell.com/blog/notification-system-design) — модель прочитанности и tiered retention в продуктовой notification-платформе.
- [Data Egret — Archiving and retention in PostgreSQL](https://dataegret.com/2025/05/data-archiving-and-retention-in-postgresql-best-practices-for-large-datasets/) — DROP партиции против массового DELETE.

**Оговорка по доступу:** страницу Milan Jovanović про SSE (`milanjovanovic.tech`) отдаёт 403 на WebFetch — в спайке она не использована. Раздел про backend service timeout на странице Google Cloud напрямую не извлёкся (fetch вернул только разделы про balancing modes), поэтому две цитаты ниже помечены как взятые из поискового индекса той же страницы, а не из прямого фетча — перед раскаткой транспорта их надо перечитать глазами в консоли.

## Findings

### Q1. Транспорт: polling выигрывает, SSE — разумный второй шаг, SignalR не окупается

Прямая рекомендация от команды, которая продаёт feeds как сервис:

> "For notifications, activity streams, and dashboards that update every few seconds, long polling is simpler to operate and performs well enough."
> — [GetStream, Long Polling vs WebSockets](https://getstream.io/blog/long-polling-vs-websockets/)

Там же — цена постоянного соединения не в памяти, а в эксплуатации: WebSocket требует connection-aware балансировки, рестарт пода рвёт всех клиентов сразу (в отличие от коротких HTTP-запросов), и нужны application-level heartbeat каждые 30–45 секунд, чтобы не ловить idle-таймауты. Экономия трафика при этом реальна, но на нашем масштабе несущественна: ~150–200 байт HTTP-заголовков на доставку против ~2–6 байт в WebSocket-кадре, то есть при 1000 доставок/сек это ~0.15–0.20 MB/s против ~0.002–0.006 MB/s.

**SignalR за Ingress в K8s ломается двумя способами.** Негоциация SignalR — это два последовательных HTTP-запроса, и если Ingress раскидает их на разные поды, второй придёт на под, который «will not recognise the Connection ID», и вернёт 404. Второй способ: под знает только своих клиентов —

> "Pod X doesn't know about Clients C and D since they are connected to a different pod."
> — [G-Research, Optimising SignalR on Kubernetes](https://www.gresearch.com/news/signalr-on-kubernetes/)

Лечится либо отключением негоциации с принудительным WebSocket, либо Redis backplane. То есть SignalR = +Memorystore/Redis и +требование sticky sessions ради односторонней доставки точки на колокольчике. Для нашей задачи это несоразмерно.

**Важное ограничение нашего стека: встроенного SSE в .NET 8 нет.** Поддержка появилась только в .NET 10 —

> ".NET 10 preview 4" introduced built-in SSE support. The official API is `"TypedResults.ServerSentEvents"` for endpoints and `"SseItem"` for individual event objects with identifiers.
> — [Anton Dev Tips, 22.07.2025](https://antondevtips.com/blog/real-time-server-sent-events-in-asp-net-core)

До этого SSE пишется руками: `Content-Type: text/event-stream`, ручной flush, свой cancellation. Мы на .NET 8 (SDK пришпилен в `global.json`), значит SSE — это самописный стриминг-эндпоинт, а не три строки на фреймворке.

**GCP обрежет долгое соединение по умолчанию.** Дефолт backend service timeout — 30 секунд, и на WebSocket он трактуется как предел жизни соединения:

> "For WebSocket traffic sent through a Google Cloud external Application Load Balancer, the backend service timeout is interpreted as the maximum amount of time that a WebSocket connection can remain open, whether idle or not."
> — [Google Cloud, Backend services overview](https://docs.cloud.google.com/load-balancing/docs/backend-service) *(цитата из поискового индекса страницы; прямой фетч раздела не удался — перепроверить)*

В GKE это ровно то поле, которое пришлось бы править у нас:

> The timeoutSec field sets a "backend service timeout period in seconds." If unspecified, the default value is 30 seconds.
> — [Google Cloud, Ingress features](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/ingress-features)

Причём документация GKE **не** говорит, применяется ли `timeoutSec` к WebSocket и стримингу, — это пришлось собирать со страницы LB. Отдельно есть грабля keepalive: бэкенд должен держать keepalive чуть больше 10 минут (рекомендуют 620 секунд), иначе LB получает закрытие соединения не вовремя и отдаёт 5XX ([troubleshooting-ext-https-lbs](https://docs.cloud.google.com/load-balancing/docs/https/troubleshooting-ext-https-lbs)).

**Polling можно сделать почти бесплатным** через условные запросы: клиент присылает `If-None-Match`, сервер отвечает `304 Not Modified` без тела ([MDN](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Conditional_requests)). Для ручки «есть ли непрочитанное» ETag считается из чего-то дешёвого — например, `MAX(CreatedAt)` + факт наличия непрочитанного.

| Вариант | Что требует от инфраструктуры | Цена на .NET 8 / GKE | Годится для колокольчика | Source |
|---|---|---|---|---|
| **Polling + ETag/304** | ничего; обычный REST | ручка + индекс; уже есть контроллер | да, при интервале 15–60 с | [GetStream](https://getstream.io/blog/long-polling-vs-websockets/), [MDN](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Conditional_requests) |
| **SSE** | `timeoutSec` > дефолта 30 с, keepalive-пинги, отключение буферизации на прокси | самописный стриминг (встроенное — только .NET 10) | да, но выигрыш только в задержке | [Anton Dev Tips](https://antondevtips.com/blog/real-time-server-sent-events-in-asp-net-core), [GKE Ingress](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/ingress-features) |
| **WebSocket / SignalR** | Redis backplane + sticky sessions + heartbeat 30–45 с | новый компонент в GCP (Memorystore) | избыточно для односторонней точки | [G-Research](https://www.gresearch.com/news/signalr-on-kubernetes/), [GetStream](https://getstream.io/blog/long-polling-vs-websockets/) |
| **FCM Web Push (VAPID)** | service worker в вебе, регистрация токенов на бэке | бесплатная отправка, но это ОС-уровень уведомлений, не состояние ленты | нет — груминг вынес пуши за скоуп | [Firebase](https://firebase.google.com/docs/cloud-messaging/web/get-started) |
| **Firestore realtime listener** | новый стор + правила доступа; данные придётся дублировать из Postgres | тарифицируется чтением на каждое изменение документа в результате листенера | нет — дублирование источника истины | [Firestore Pricing](https://firebase.google.com/docs/firestore/enterprise/pricing) |

Вывод по Q1: **ничего в GCP добавлять не нужно.** Требование груминга («колокольчик актуален при переходах между страницами и рефрешах», 39:25) закрывается опросом дешёвой ручки с `ETag`; SSE стоит держать как явно описанный второй шаг, если появится требование «в реальном времени», и он не потребует ни Redis, ни sticky sessions — только правку `timeoutSec` и keepalive-пинги.

### Q2. Схема: группировка через `DISTINCT ON`, индикатор через `EXISTS` + partial index

**Индикатор непрочитанного нельзя делать через `COUNT`.** Частичный индекс — ровно инструмент под «непрочитанных мало»:

> A _partial index_ is an index built over a subset of a table; the subset is defined by a conditional expression (called the _predicate_ of the partial index). The index contains entries only for those table rows that satisfy the predicate.
> One major reason for using a partial index is to avoid indexing common values. […] This reduces the size of the index, which will speed up those queries that do use the index. It will also speed up many table update operations because the index does not need to be updated in all cases.
> — [PostgreSQL 18, 11.8. Partial Indexes](https://www.postgresql.org/docs/current/indexes-partial.html)

То есть `CREATE INDEX … ON "Notifications" ("TargetAccountId") WHERE "ReadAt" IS NULL` плюс запрос через `EXISTS` вместо `COUNT(*)`: `EXISTS` останавливается на первой строке, `COUNT` обязан пройти все и проверить видимость версий. Это техническая сторона неразрешённого продуктового вопроса «точка или цифра» — Максим на груминге (43:36) был прав, и разница не «непринципиальная», как он оговорился, а качественная: `exists` по partial-индексу против полного прохода по непрочитанным. *(Порядковые цифры ускорения из бенчмарков в поиске не цитирую — прямой фетч бенчмарка не делал.)*

Оговорка после снятия макета: точка на колокольчике действительно `EXISTS`, но в табах есть `Unread N` — значит `COUNT` тоже нужен, просто не на каждом опросе, а при открытии ленты. Подробности — в разделе «Дизайн» в [`README.md`](README.md).

**Группировка «одна карточка на визит».** В Postgres это `DISTINCT ON (entity_id) … ORDER BY entity_id, created_at DESC`. Ключевые свойства: `DISTINCT ON` умеет ехать index-scan'ом в нужном порядке и перескакивать к следующей группе, поэтому обычно дешевле `ROW_NUMBER()`, но требует, чтобы выражения `DISTINCT ON` были самыми левыми в `ORDER BY` — и это ограничение конфликтует с текущей сортировкой ленты (`CreatedAt DESC, Id DESC`): группировку придётся делать во вложенном запросе, а внешний сортировать по времени. *(Свойства `DISTINCT ON` взяты из документации и обзоров через поисковую выдачу, прямой фетч страницы `queries-select` не делал — перепроверить при написании запроса.)*

Отсюда следствие в схеме: **у `Notification` нет поля сущности.** Ни `EntityId`, ни group key (см. `Notifications.Domain/Models/Notification.cs`) — только `Type`, `Payload` jsonb, `Source`. Группировать по `Payload->>'visitId'` можно, но тогда индекс придётся строить по выражению из jsonb, и курсорная пагинация по `(CreatedAt, Id)` перестанет совпадать с группировкой. Типизированное поле + составной индекс — единственный вменяемый путь. Заодно это ключ дедупа для Q3.

Альтернатива — денормализованный агрегат (одна строка на визит, перезаписываемая при новом событии). Она делает чтение тривиальным и `mark all read` дешёвым, но необратимо выбирает «группировку» в неразрешённом споре «историчность vs группировка» (42:39) и ломает возможность показать историю позже. Прецедент из продуктовой платформы — состояние ведут на самой нотификации, а не на сущности:

> "A visual status: unseen, unread, or read."
> — [MagicBell, Notification System Design](https://www.magicbell.com/blog/notification-system-design)

Это, кстати, совпадает с тем, как уже сделано у нас (`ReadAt` на записи) и с решением груминга считать read по действию в ленте, а не по открытию визита.

### Q3. Триггер: outbox, потому что контексты разные

Модуль `Notifications` конфигурируется своей строкой подключения (`Notifications:ConnectionString` в `Invoices.Api/appsettings.json`) отдельно от `Jobs:ConnectionString`. Значения — секреты, поэтому по репозиторию нельзя сказать, одна это база или две; от ответа зависит выбор. Если базы разные, общей транзакции нет, и остаётся канонический вариант:

> "The solution is for the service that sends the message to first store the message in the database as part of the transaction that updates the business entities."
> — [Chris Richardson, Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html)

и обязательное следствие, которое часто забывают:

> "The Message relay might publish a message more than once… When it restarts, it will then publish the message again." […] "a message consumer must be idempotent, perhaps by tracking the IDs of the messages that it has already processed."
> — там же

Практически: в хендлере уже есть точка, где в одной транзакции с джобом пишется журнал событий (`WorkerUpdateVisitStatusCommandHandler.cs:55-56`), то есть место для транзакционной записи outbox-строки готово. Hangfire в модуле тоже уже поднят (`Notifications:Hangfire`, `SchedulePollingInterval` = 15 секунд), так что инфраструктуры для релея добавлять не надо.

**Уточнение после разбора Activity:** здесь я сначала предложил использовать сам журнал `JobEvents` как outbox. Это один из вариантов, но не единственный и не выбранный — лента тогда начинает зависеть от схемы и семантики журнала аудита. Разбор альтернатив (своя outbox-таблица против проекции журнала в отдельную сущность) — в [`activity-impact.md`](activity-impact.md).

Идемпотентность релея упирается в то же отсутствующее поле: уникальный ключ вида (визит, тип события, версия/время события) — единственный способ не задвоить карточку при ретрае, а ретраи здесь гарантированы (`RetryCount: 3`).

**Отдельный случай — `hasn't started yet`.** Это не событие от действия, а срабатывание таймера, значит либо отложенный job на каждый визит, либо периодический скан. Для отложенного варианта Hangfire позволяет снять запланированный job через `BackgroundJob.Delete`, но с существенной оговоркой: удаление рассчитано на job, который ещё не начал исполняться (у `Delete` есть параметр `fromState` как предохранитель). То есть при старте визита или переносе расписания надо не только удалить старый job, но и защититься от гонки «job уже стартовал». *(Собрано из документации и обсуждений Hangfire через поиск; официальную страницу API прямо не фетчил.)* Периодический скан с гейтом «визит всё ещё не начат на момент исполнения» проще и устойчивее к переносам — и это тот же паттерн, что уже используется в `SendPastDueDatePushJob`.

### Q4. Смежное: retention и `mark all read`

Женя на груминге предсказал, что лента забьётся сплошными `finished` (26:26, 31:34), а retention обсудили и не решили (30/90 дней). Правильный механизм — не `DELETE`, а партиционирование по времени с отбрасыванием партиций:

> Dropping an individual partition using DROP TABLE or ALTER TABLE DETACH PARTITION is far faster than a bulk operation and entirely avoids the VACUUM overhead caused by a bulk DELETE.
> — [PostgreSQL, 5.12. Table Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html)

Массовый `DELETE` старых строк оставляет bloat и грузит autovacuum ([Data Egret](https://dataegret.com/2025/05/data-archiving-and-retention-in-postgresql-best-practices-for-large-datasets/)). Оговорка: партиционирование `Notifications` сейчас преждевременно — таблица маленькая, а партиционирование по `CreatedAt` потребует включить дату в первичный ключ, что заденет и курсор, и `POST /{id}/read`. Разумнее заложить retention-политику как удаление по расписанию сейчас и держать партиционирование как известный следующий шаг.

`mark all read` — это `UPDATE … SET "ReadAt" = now() WHERE "TargetAccountId" = … AND "ReadAt" IS NULL`, то есть ровно тот запрос, который выигрывает от partial-индекса из Q2. Но каждая такая запись инвалидирует ETag колокольчика — значит ETag надо считать так, чтобы `mark all read` его менял (например, включать в него `MAX(ReadAt)`).

## Implications for the design

- **Транспорт: polling + `ETag`/`304`, ничего в GCP не добавляем** (anchor: решение по инфраструктуре и по контракту ручки колокольчика). SSE описываем как следующий шаг с явной ценой: правка `timeoutSec` (дефолт 30 с), keepalive-пинги, самописный стриминг на .NET 8. SignalR отклоняем в плане с обоснованием — Redis + sticky sessions ради односторонней точки.
- **Ручка колокольчика отдаёт и флаг, и счётчик** (anchor: контракт API). Макет (см. [`README.md`](README.md), раздел «Дизайн») требует обе величины: точка на колокольчике — это `EXISTS`, а таб `Unread N` — это `COUNT`. То есть выводом «только `EXISTS`» ограничиться нельзя, но выигрыш partial-индекса сохраняется для обоих запросов, а счётчик считается только при открытии ленты, а не на каждом опросе колокольчика.
- **Добавляем `EntityId` (+ `EntityType`) в `Notification` и составной индекс под группировку** (anchor: миграция Postgres, схема). Без этого поля не реализуемы сразу три требования: одна карточка на визит, дедуп при ретраях релея, и снятие/перезапись карточки `hasn't started yet`.
- **Partial index `WHERE "ReadAt" IS NULL`** (anchor: та же миграция). Обслуживает и индикатор, и `mark all read`.
- **Группировку делаем на чтении (`DISTINCT ON`), а не на записи** (anchor: выбор между историчностью и группировкой). Так неразрешённый продуктовый спор остаётся обратимым: денормализованный агрегат закрыл бы путь к историчности навсегда.
- **Проводка Jobs → Notifications оформляется как outbox-релей поверх уже существующего журнала `JobDomainEvent`** (anchor: выбор паттерна интеграции модулей). Инлайн-вызов `INotificationDispatcher`, как сделано в `PaymentsService.cs:301`, для джобов не годится: другой `DbContext`, значит либо потеря нотификации при сбое, либо ложная нотификация при откате.
- **Релей обязан быть идемпотентным** по (визит, тип, момент события) (anchor: ключ дедупа в схеме) — при `RetryCount: 3` дубли не гипотеза.
- **`hasn't started yet` — периодический скан с проверкой актуальности на момент исполнения**, не отложенный job на визит (anchor: выбор механизма планирования). Отложенный job требует снятия при каждом переносе расписания и уязвим к гонке со стартом исполнения.
- **Retention: сначала плановая чистка, партиционирование — известный следующий шаг** (anchor: решение по эксплуатации). Партиционирование по `CreatedAt` потребует переделки PK и заденет курсорную пагинацию, поэтому не в MVP.

## Open questions / follow-ups

- [ ] `Jobs:ConnectionString` и `Notifications:ConnectionString` — это одна база Postgres или две? Значения в `gateway-api-secret`. Если одна — можно рассмотреть общую транзакцию вместо релея, но outbox всё равно предпочтительнее из-за развязки модулей.
- [ ] Перечитать глазами раздел про backend service timeout в консоли/документации GCP: цитата про WebSocket взята из поискового индекса, прямой фетч раздела не сработал. Актуально только если пойдём в SSE.
- [ ] Проверить, чем именно терминируется трафик BFF в прод-кластере (GKE Ingress + BackendConfig или свой nginx) — от этого зависит, где править таймаут и буферизацию под SSE. Репозиторий `Invoices.Kubernetes` в этом воркспейсе не лежит.
- [ ] Уточнить у продукта интервал опроса колокольчика: «при переходах между страницами» (39:25) — это событийный опрос, а не таймер; нужен ли вообще фоновый таймер, или достаточно опроса на навигацию и на рефреш.
- [ ] Решение «историчность vs группировка» остаётся за продуктом (42:39) — спайк лишь показывает, что чтение через `DISTINCT ON` оставляет оба варианта открытыми.
- [ ] Нужен ли rate-limit на ручку колокольчика, если веб будет опрашивать её с каждой страницы — зависит от выбранного интервала, отдельного источника не искал.

---

# backend-notifications — Web Spike: как устроены notification-системы у крупных продуктов

Второй заход в том же спайке: не транспорт, а устройство самой системы уведомлений у тех, кто уже прошёл этот путь — модель прочитанности, форма разнородного payload, откуда берутся кнопки-действия, как коллапсятся события по одной сущности, и какая обвязка (троттлинг, retention, дайджесты) считается обязательной. Смотрел первоисточники: GitHub REST, LinkedIn ATC, Uber RAMEN, Microsoft Teams (Graph), схему Discourse, спеки W3C, плюс вендорские платформы (Knock, Novu) и Slack.

Дата: 2026-07-27.

## Questions

1. Как моделируют прочитанность: флаг на записи, курсор по времени или трёхстадийный seen/read/archived — и как при этом реализован `mark all read` без гонок.
2. Как типизируют разнородный payload: enum + JSON, ссылка на сущность, шаблон с параметрами или стандартизованная actor/verb/object.
3. Где живут кнопки-действия: в payload с сервера или выводятся из типа на клиенте.
4. Как коллапсят несколько событий по одной сущности в одну карточку.
5. Что считается обязательной обвязкой: троттлинг, дедуп, дайджесты, retention.

## Sources

**Первоисточники (preferred):**
- [GitHub REST — Notifications](https://docs.github.com/en/rest/activity/notifications) — форма thread'а, `reason`-enum, семантика `last_read_at` при mark-all-read.
- [LinkedIn Engineering — Air Traffic Controller](https://www.linkedin.com/blog/engineering/messaging-notifications/air-traffic-controller-member-first-notifications-at-linkedin) — оркестрация: агрегация, фильтрация, rate-limit, выбор канала.
- [Uber — Real-time push platform (RAMEN)](https://www.uber.com/blog/real-time-push-platform/) — TTL сообщений, sequence numbers, дедуп «последнее сообщение своего типа».
- [Microsoft Learn — Best practices for Teams activity feed notifications](https://learn.microsoft.com/en-us/graph/teams-activity-feed-notifications-best-practices) — `chainId` (обновление вместо создания), лимит 20/мин на пользователя, хранение 30 дней.
- [W3C — Activity Streams 2.0 Core](https://www.w3.org/TR/activitystreams-core/) — модель actor/type/object/target и правила расширения типов.
- [WHATWG — Notifications API](https://notifications.spec.whatwg.org/) — `actions` как декларативные кнопки и `data` как произвольный payload.
- [Firebase — Non-collapsible and collapsible messages](https://firebase.google.com/docs/cloud-messaging/customize-messages/collapsible-message-types) — `collapse_key` / `apns-collapse-id`.
- [Slack — `conversations.mark`](https://docs.slack.dev/reference/methods/conversations.mark/) — модель read-курсора и совет по частоте вызовов.
- [Discourse — `app/models/notification.rb`](https://github.com/discourse/discourse/blob/main/app/models/notification.rb) — реальная схема таблицы и консолидация (open source, продукт с 45+ типами уведомлений).

**Вендорские платформы (acceptable):**
- [Knock — Feeds overview](https://docs.knock.app/in-app-ui/feeds/overview) и [React reference](https://docs.knock.app/sdks/react/reference) — seen/read/archived и кнопки в ячейке фида.
- [Novu — Digest step](https://docs.novu.co/platform/workflow/digest) — батчинг событий по subscriber + grouping key.

**Оговорка:** статья Netflix про RENO (`netflixtechblog.com`) отдаёт 307 на логин-редирект Medium — не читал и не цитирую. Формулировки Discourse про консолидацию и Novu про digest получены через извлечение WebFetch, а не дословным копированием исходника, — это отмечено в тексте.

## Findings

### Q1. Прочитанность: флаг остаётся нормой, но `mark all read` везде делают с отсечкой по времени

Три разные модели в проде:

| Продукт | Модель | Как выглядит mark-all-read | Source |
|---|---|---|---|
| Discourse | `read :boolean default(FALSE), not null` на записи | `read_types()` — массовый апдейт по типам | [notification.rb](https://github.com/discourse/discourse/blob/main/app/models/notification.rb) |
| GitHub | `unread` boolean на thread'е + `last_read_at` | `PUT /notifications` с параметром-отсечкой | [GitHub REST](https://docs.github.com/en/rest/activity/notifications) |
| Slack | только курсор `last_read` на канал, флагов на сообщениях нет | сдвинуть курсор одним вызовом | [conversations.mark](https://docs.slack.dev/reference/methods/conversations.mark/) |
| Knock | трёхстадийно: seen / read / archived | отдельные статусы, ортогональные друг другу | [Knock Feeds](https://docs.knock.app/in-app-ui/feeds/overview) |

Самое полезное — как GitHub закрывает гонку «пользователь нажал mark-all-read, а пока запрос летел, пришли новые уведомления»:

> a `last_read_at` parameter that describes "the last point that notifications were checked. Anything updated since this time will not be marked as read. If you omit this parameter, all notifications are marked as read."
> — [GitHub REST, Notifications](https://docs.github.com/en/rest/activity/notifications)

Slack идёт дальше и вообще не хранит признак на сообщении — только позицию курсора:

> "Sets the read cursor in a channel" and "moves the read cursor in a conversation for whomever owns the token used in the request."
> — [Slack, `conversations.mark`](https://docs.slack.dev/reference/methods/conversations.mark/)

и отдельно предупреждает, что клиент не должен дёргать это часто: «A timeout of 5 seconds is a good starting point». Для нас курсорная модель не подходит — груминг требует пометки конкретной карточки по тапу, а не «всё до этого момента», — но параметр-отсечка у mark-all-read нужен.

Knock показывает, что seen и read — разные вещи, и статусы можно комбинировать: «An item can be both unread and archived, and this gives developers flexibility in how they want to model engagement statuses» ([Knock](https://docs.knock.app/sdks/react/reference)). В нашем макете подсветка непрочитанного и точка — это фактически одно состояние, так что тройная модель избыточна, но стоит знать, что «seen при открытии ленты» — отдельная от «read по тапу» вещь, если продукт потом захочет гасить точку без пометки карточек.

#### Timestamp или boolean — что кладут в колонку

Отдельно проверил, потому что у нас уже `ReadAt` (`DateTimeOffset?`), а не флаг. Nullable timestamp — доминирующая конвенция, флаг встречается в основном в более старых библиотеках:

| Кто | Колонка | Тип | Source |
|---|---|---|---|
| Laravel (дефолтная миграция фреймворка) | `read_at` | nullable timestamp | [Laravel Docs](https://laravel.com/docs/12.x/notifications) |
| Rails, гем `noticed` | `read_at` + `seen_at` | `t.datetime` | [noticed README](https://github.com/excid3/noticed) |
| Knock | `read_at`, `seen_at`, `archived_at` | timestamps | [Knock](https://docs.knock.app/in-app-ui/feeds/overview) |
| MagicBell | `read_at` | timestamp (`WHERE read_at IS NULL`) | [MagicBell](https://www.magicbell.com/blog/notification-system-design) |
| Discourse | `read` | boolean | [notification.rb](https://github.com/discourse/discourse/blob/main/app/models/notification.rb) |
| django-notifications | `unread` | BooleanField | [django-notifications](https://github.com/django-notifications/django-notifications) |
| GitHub (уровень API) | `unread` + `last_read_at` | bool + timestamp | [GitHub REST](https://docs.github.com/en/rest/activity/notifications) |

Laravel-конвенция дословно: «the `read_at` column will be `null`» при сохранении, а массовая пометка — `$user->unreadNotifications()->update(['read_at' => now()])`. У гема `noticed` в генерируемой миграции сразу два поля:

> ```ruby
> t.datetime :read_at
> t.datetime :seen_at
> ```
> — [noticed README](https://github.com/excid3/noticed)

*(Строки для django-notifications и Discourse получены из поиска и извлечения файла модели, дословную миграцию django не открывал.)*

Практическая разница не в 8 байтах против 1, а в трёх вещах:

1. **Аналитика бесплатно.** `ReadAt − CreatedAt` даёт time-to-read по типам событий — ровно та метрика, которой Анастасия собиралась мерить гипотезу «будут ли пользоваться» (29:11 груминга). С boolean её нет.
2. **Индексация не страдает.** Частичный индекс работает одинаково: `WHERE "ReadAt" IS NULL` у нас против `WHERE NOT read` у Discourse.
3. **Timestamp решает проблему «карточка схлопнулась после прочтения»** — ту, которую я поднял в разделе про коллапс. С флагом единственный выход — сбросить его в `false`, потеряв факт, что пользователь эту карточку уже видел. С датой сбрасывать ничего не нужно: непрочитанность выражается сравнением
   `ReadAt IS NULL OR ReadAt < LastEventAt`
   то есть «прочитано» означает «прочитано вплоть до этого момента» — тот же принцип read-горизонта, что у курсора Slack и у `last_read_at` в mark-all-read у GitHub, только на уровне отдельной карточки. Это же выражение годится и для `EXISTS`-запроса колокольчика, и оно остаётся индексируемым, если хранить `LastEventAt` колонкой.

Побочно: `seen_at` отдельной колонкой (noticed, Knock) — готовый механизм на случай, если продукт захочет гасить точку при открытии ленты, не помечая карточки прочитанными. Заводить его сейчас не нужно, но место под него в модели с timestamp'ами появляется естественно, а с boolean потребовало бы второго флага.

Оговорка по типу: `DateTimeOffset` в EF Core на Postgres ложится в `timestamptz`, что здесь и нужно — read-горизонт сравнивается с временем события, а события приходят из разных таймзон аккаунтов.

**Подтверждение вывода первой секции из чужого прода.** У Discourse на таблице стоит индекс `idx_notifications_speedup_unread_count` — `(user_id, notification_type) WHERE (NOT read)`. То есть частичный индекс по непрочитанным ровно в той форме, которую я вывел из документации Postgres, стоит в продукте с 45+ типами уведомлений; само имя индекса говорит, что его добавили именно ради счётчика непрочитанных.

### Q2. Payload: типизированный enum + JSON-blob — самый частый выбор, шаблоны — второй

Discourse: `notification_type :integer not null` (45+ типов, включая плагинные) плюс `data :string(1000) not null` под всё остальное, при этом отдельными колонками вынесены только те поля, по которым нужны запросы (`topic_id`, `post_number`, `high_priority`). То есть в точности та схема, что у нас уже есть (`Type` + `Payload` jsonb + `Source`), — с той разницей, что у нас нет колонки под сущность.

GitHub принципиально **не** денормализует контент, а отдаёт ссылку: `subject` с `title`, `url`, `latest_comment_url`, `type` плюс `reason` из закрытого списка (`assign`, `mention`, `review_requested`, `state_change`, `ci_activity`, …). Причина — их UI всё равно грузит thread; наш макет так не умеет, карточка обязана показать время визита, услугу и адрес без дополнительных запросов.

Teams выбирает третий путь — шаблон с параметрами: тип активности объявляется в манифесте с `templateText` вида `"New created task {taskName} for you"`, а в вызове передаются `templateParameters` и `previewText` ([Microsoft Learn](https://learn.microsoft.com/en-us/graph/teams-activity-feed-notifications-best-practices)). Это даёт локализацию и позволяет менять формулировку без миграции данных: в базе лежат только параметры. Для нас это важно, потому что тексты в макете английские и продукт наверняка захочет их править — а если мы положим в payload готовую строку, каждая правка формулировки станет невозможной для уже созданных записей.

W3C Activity Streams 2.0 предлагает канон actor/type/object/target и прямо предупреждает про расширения:

> "While implementations are free to introduce new types of Activites beyond those defined by the Activity Vocabulary, interoperability issues can arise when applications rely too much on extension types that are not recognized by other implementations."
> — [W3C, Activity Streams 2.0 Core](https://www.w3.org/TR/activitystreams-core/)

Нам это не нужно как формат обмена (лента внутренняя, не федеративная), но структура «actor = воркер, type = событие, object = визит» — ровно то, что просят четыре типа с груминга, и удобная рамка для именования полей.

### Q3. Кнопки — это данные, а не логика клиента

Стандарт браузерных уведомлений держит действия декларативно в payload:

> ```
> dictionary NotificationAction {
>   required DOMString action;
>   required DOMString title;
>   USVString navigate;
>   USVString icon;
> };
> ```
> — [WHATWG, Notifications API](https://notifications.spec.whatwg.org/)

Плюс `any data = null` под произвольный структурированный payload, и — важная деталь для дизайна контракта — предел числа кнопок не фиксирован спекой: «The maximum number of actions supported is an implementation-defined integer of zero or more, within the constraints of the notification platform». Knock в in-app фиде делает то же самое: кнопки приходят в ячейке, а клиент лишь вешает обработчик (`onNotificationButtonClick`).

Для нас это прямо применимо: правило «есть телефон воркера → `Call Sarah`, нет → `Open visit`» из макета — серверное знание (телефон в БД у нас, а не у клиента). Значит действия надо отдавать массивом объектов, а не выводить на клиенте по `type`, иначе оба клиента (веб и iOS) продублируют одну и ту же ветку логики и разойдутся.

### Q4. Коллапс по сущности — индустриальный примитив, и делают его чаще на записи

Одна и та же идея под четырьмя именами:

| Продукт | Механизм | Семантика | Source |
|---|---|---|---|
| Teams / Graph | `chainId` | «You can update an existing activity feed notification instead of creating a new notification by using the *chainId* parameter» | [Microsoft Learn](https://learn.microsoft.com/en-us/graph/teams-activity-feed-notifications-best-practices) |
| FCM / APNs | `collapse_key` / `apns-collapse-id` | ключ группы, из которой доставляется только последнее сообщение; **не более 4 ключей на токен** | [Firebase](https://firebase.google.com/docs/cloud-messaging/customize-messages/collapsible-message-types) |
| Discourse | `consolidate_or_create!` + `ConsolidationPlanner` | схлопывание похожих уведомлений вместо создания новых | [notification.rb](https://github.com/discourse/discourse/blob/main/app/models/notification.rb) |
| Uber RAMEN | дедуп по типу | «sending the most recent push message of a given type was enough to satisfy the user experience and this allowed us to reduce the overall data transfer rate» | [Uber](https://www.uber.com/blog/real-time-push-platform/) |
| LinkedIn ATC | отложенная агрегация | «ATC can delay specific notifications, place them in a notifications queue via RocksDB, and then send a group of notifications together as one notification at a later time» | [LinkedIn](https://www.linkedin.com/blog/engineering/messaging-notifications/air-traffic-controller-member-first-notifications-at-linkedin) |

#### Насколько «только последнее событие на визит» — хорошая практика

Практика признанная, но важно не путать две разные механики. **Агрегация однотипных** событий («Alice and 5 others liked your photo») сохраняет количество и ничего не теряет. **State-collapse разнотипных** событий — когда новое состояние затирает предыдущее — именно то, что решили на груминге, и это семантика `collapse_key` у FCM: канонический пример из документации — «a sports app that updates users with the latest score where only the most recent message is relevant».

Самый близкий прецедент — GitHub: уведомление там **не событие, а thread на сущность**. Новые комментарии обновляют существующий thread, а не создают записи, и даже причина уведомления переписывается на месте — `reason` «is modified on a per-thread basis, and can change» ([GitHub REST](https://docs.github.com/en/rest/activity/notifications)). То есть «одна карточка на сущность, в ней последнее состояние» — это модель уведомлений крупнейшего разработческого продукта, а не наша самодеятельность.

Безопасна она при трёх условиях, и все три нужно проверить на нашем случае:

1. **История живёт в другом месте.** Иначе схлопывание — это потеря фактов. У нас условие выполнено: полная история визита остаётся в Activity (см. [`activity-impact.md`](activity-impact.md)). Это, по сути, главный аргумент, почему нам коллапсить не страшно.
2. **Коллапс идёт внутри совместимой группы, а не «любое новое затирает предыдущее».** Слепое latest-wins способно понизить важность: `hasn't started yet` — это красная точка и требование действия, и если её затрёт безобидное событие по тому же визиту, владелец потеряет сигнал. Нужны правила переходов (или приоритет, как `high_priority` у Discourse), а не просто `ORDER BY CreatedAt DESC LIMIT 1`.
3. **Решено, что происходит с прочитанностью при обновлении карточки.** Если карточку прочитали, а потом в неё схлопнулось новое событие — она должна снова стать непрочитанной, иначе новость останется незамеченной. Но тогда «прочитано» означает «пользователь видел предыдущую версию строки», а счётчик непрочитанных вырастет без появления новой строки в списке — с точки зрения пользователя это выглядит как баг, если карточка при этом не поднялась наверх.

**Технический подводный камень, специфичный для нас.** Пункт 3 подводит к нему: если при коллапсе карточка поднимается наверх, значит меняется поле, по которому лента отсортирована. А наша пагинация — keyset-курсор по `(CreatedAt, Id)`. Курсор по изменяемому ключу сортировки — известная ошибка: «when the sort field is mutable (e.g., `updatedAt`, `price`, `score`, `rank`), rows can be skipped, repeated, or shifted between pages», и правило — «use a cursor on something unique, immutable, and indexed» ([Knit, API pagination stability](https://www.getknit.dev/blog/how-to-preserve-api-pagination-stability)). Составной курсор `(sort, id)` спасает только от неуникальности сортировочного поля, но не от его мутации.

Три выхода, и они разной цены:

| Подход | Что с курсором | Цена |
|---|---|---|
| Коллапс на записи, карточка **не** поднимается (сортировка по первому событию визита) | курсор стабилен | свежее событие по старому визиту остаётся в глубине ленты — смысл «обратить внимание» теряется |
| Коллапс на записи, карточка поднимается | курсор «дрейфует»: строки могут пропускаться и повторяться на границах страниц | в поповере на 10 записей почти незаметно, на полноэкранном списке с пагинацией — реальные пропуски |
| Коллапс на чтении (`DISTINCT ON`) | курсор стабилен: строки только добавляются, сортировочный ключ иммутабелен | лента в базе растёт, счётчик непрочитанных надо считать по схлопнутому набору |

Это уточняет вывод предыдущего абзаца. Индустрия действительно коллапсит на записи — но GitHub при этом пагинирует страницами и параметрами `since`/`before`, а не keyset-курсором по изменяемому полю. У нас курсор уже есть и он по `CreatedAt`, поэтому «коллапс на записи с подъёмом наверх» требует либо смены модели пагинации, либо сознательного согласия на аномалии на границах страниц.

Существенное для нас: **все перечисленные коллапсят на записи**, а не на чтении. Teams обновляет существующую запись по `chainId`, Discourse вызывает `consolidate_or_create!` в момент создания. Это корректирует рекомендацию из первой секции спайка, где я предложил `DISTINCT ON` на чтении: у чтения есть своё преимущество (история сохраняется, продуктовый спор «историчность vs группировка» остаётся обратимым), но мейнстрим — upsert по ключу, потому что тогда лента не растёт, счётчик непрочитанных не врёт и `mark all read` дешевле. Выбор остаётся продуктовым, но теперь у обеих альтернатив есть прецеденты, а не только моё предпочтение.

### Q5. Обвязка: троттлинг и retention считаются обязательными, дайджесты — нет

- **Троттлинг с числом.** Teams: «Verify that your app does not send more than 20 notifications per minute, per user. Notifications will be automatically throttled if the count exceeds 20». LinkedIn ставит это в основу: «ATC will rate-limit upstream applications to prevent them from accidentally spamming members».
- **Дедуп на входе.** LinkedIn: «ATC handles the duplicated requests by dropping any request it has already processed» — то есть идемпотентность релея не наша самодеятельность, а норма.
- **Retention с явной цифрой и информированием пользователя.** Teams: «Inform the user about the notifications storage period in the activity feed. In Microsoft Teams, the storage period is 30 days». Это прямой ответ на нерешённый на груминге вопрос про 30/90 дней: 30 дней — рабочий отраслевой дефолт, и о нём принято сообщать в UI.
- **TTL на доставку.** Uber держит TTL «ranging from a few seconds to up to 30 minutes» и sequence numbers, чтобы клиент после реконнекта запросил всё после последнего виденного номера. Для нашей polling-модели это не нужно, но идея «клиент присылает последнее, что видел» — это ровно наш курсор пагинации.
- **Дайджесты/батчинг** (Novu digest: «The Digest step controls how often downstream steps execute by batching multiple workflow trigger events into a single execution», события группируются «per subscriber (and optional grouping key)»; LinkedIn — отложенная агрегация через RocksDB) нужны там, где объём событий велик. У нас 4 типа и события уровня «техник начал визит» — в MVP это лишнее, но знать про grouping key полезно: он тот же самый `EntityId`.
- **Релевантность/ML-фильтрация** (LinkedIn: «predict the likelihood that this member will act on or disable the notification», «5 rights» — right message / member / channel / time / frequency) — заведомо вне нашего скоупа, упоминаю, чтобы не изобретали.

## Implications for the design

- **`mark all read` принимает отсечку по времени** (anchor: контракт API). По образцу GitHub `last_read_at`: помечаем прочитанным только то, что было создано до момента, который клиент видел. Иначе уведомление, пришедшее за время полёта запроса, молча погасится — а по нашему макету это единственный способ обнулить точку, то есть пользователь потеряет событие.
- **Оставляем `ReadAt` на записи, курсорную модель Slack не берём** (anchor: модель прочитанности). Груминг требует пометку конкретной карточки по тапу, что курсором не выражается; наша текущая схема совпадает с Discourse, GitHub и Knock.
- **Partial index по непрочитанным — не гипотеза, а чужой прод** (anchor: миграция). У Discourse индекс так и называется `idx_notifications_speedup_unread_count` и включает тип: `(user_id, notification_type) WHERE NOT read`. Стоит повторить форму с типом, если появится фильтр по типу в ленте.
- **`EntityId` = collapse key, и это отраслевой примитив** (anchor: схема + правило коллапса). Он же `chainId` у Teams, `collapse_key` у FCM, ключ консолидации у Discourse и grouping key у дайджеста Novu. Один и тот же ключ обслуживает три наши задачи: группировку, дедуп релея и перезапись карточки `hasn't started yet`.
- **Пересмотреть «группировку на чтении»** (anchor: выбор между историчностью и группировкой). В первой секции я рекомендовал `DISTINCT ON`; выяснилось, что индустрия схлопывает на записи (upsert), и у этого есть три эксплуатационных плюса: лента не растёт, счётчик непрочитанных не завышается, `mark all read` дешевле. Рекомендация меняется на «продуктовый выбор с двумя реальными прецедентами», а не «делаем на чтении».
- **Текст уведомления не кладём в payload — кладём параметры** (anchor: форма payload + i18n). По образцу `templateText` + `templateParameters` у Teams: в jsonb едут `workerName`, `visitId`, `scheduledStartAt`, `serviceName`, `address`, `workerPhone`, а формулировка живёт в клиенте/шаблоне. Иначе правка текста не достанет уже созданные записи. `SchemaVersion` в модели для этого уже есть.
- **Действия отдаём массивом объектов, а не выводим на клиенте** (anchor: контракт DTO). Форма — по `NotificationAction` из W3C: `action`, `title`, плюс цель перехода. Правило `Call` ↔ `Open visit` зависит от наличия телефона в нашей БД, значит это серверное решение; иначе веб и iOS продублируют ветвление и разойдутся.
- **Ставим лимит на количество уведомлений на аккаунт в единицу времени** (anchor: защита от шторма). Ориентир Teams — 20/мин на пользователя. У нас реальный сценарий шторма: массовое изменение расписания или пакетное обновление визитов породит пачку событий на одного владельца.
- **Retention — 30 дней, и об этом сообщаем в UI** (anchor: закрытие открытого вопроса груминга). Совпадает с дефолтом Teams; снимает опасение Жени про бесконечную ленту `finished` и не требует партиционирования на старте.
- **Дайджесты, ML-релевантность и выбор канала — явно вне MVP** (anchor: границы скоупа). Стоит записать в плане как «сознательно не делаем», чтобы не всплыло как «а почему не как у LinkedIn».

## Open questions / follow-ups

- [ ] Коллапс на записи (upsert по `EntityId`, как Teams/Discourse) или на чтении (`DISTINCT ON`, история сохраняется) — продуктовое решение, упирается в неразрешённое «историчность vs группировка» (42:39 груминга).
- [ ] Нужна ли отдельная стадия `seen` (гасить точку при открытии ленты, не помечая карточки прочитанными) — Knock разделяет seen и read; макет этого не показывает, но поведение точки после закрытия поповера без тапов не описано.
- [ ] Где формируются тексты, если уходим в шаблоны: на клиентах (два раза) или в BFF по локали аккаунта. Локализация лентой не обсуждалась вообще.
- [ ] Netflix RENO не прочитан (Medium требует логин) — если понадобится сравнение hybrid push+pull, брать другой источник.
- [ ] Лимит FCM «не более 4 collapse-ключей на токен» станет ограничением, если позже добавим пуши с коллапсом по визиту — на этапе in-app ленты неактуально.

---

# backend-notifications — Web Spike: состояние стека на середину 2026

Третий заход: часть источников в двух секциях выше — 2025 года, а на дворе июль 2026. Проверял точечно то, что может изменить уже сделанные выводы: версии платформы, консенсус по транспорту, возможности Postgres и состояние рынка готовых решений. Одна находка меняет обоснование рекомендации по транспорту (не саму рекомендацию), вторая делает один из вариантов коллапса дешевле.

Дата: 2026-07-27.

## Findings

### .NET 8 уходит с поддержки через три месяца, и в .NET 10 SSE встроен

Это самое существенное. Первоисточник Microsoft:

> ".NET 8 and .NET 9 will reach end of support on November 10, 2026." […] "No new security updates will be issued for either version." […] Рекомендованный апгрейд — ".NET 10, which is an LTS release supported through November 2028."
> — [.NET Blog](https://devblogs.microsoft.com/dotnet/dotnet-8-9-end-of-support/)

То есть апгрейд на .NET 10 не «когда-нибудь», а до ноября 2026 по причинам безопасности, независимо от этой фичи. А в ASP.NET Core 10 SSE — first-class: `TypedResults.ServerSentEvents` поверх `SseItem<T>` из `System.Net.ServerSentEvents` (сам тип появился в .NET 9 для клиентского парсинга и переиспользован на сервере).

**Что это меняет.** В первой секции я оценивал SSE как «самописный стриминг, потому что мы на .NET 8». Это ограничение истекает вместе с самой версией. Значит в плане SSE стоит описывать не как «дорого, писать руками», а как «бесплатно после обязательного апгрейда» — и тем более не начинать писать свой SSE на .NET 8 за три месяца до его EOL. Рекомендация «polling + ETag сейчас» не меняется; меняется цена шага номер два.

### SSE — консенсусный дефолт для односторонней доставки в 2026

Обзоры 2026 года единогласно ставят SSE дефолтом для one-way, а WebSocket оставляют для случаев, где клиент сам генерирует поток (игры, совместное редактирование, торговые терминалы). Приводимые аргументы: под HTTP/2 стримы мультиплексируются в одном TCP-соединении, поэтому старый лимит 6 соединений на домен перестал быть аргументом; корпоративные прокси ломают WebSocket-upgrade чаще, чем HTTP-стриминг; реконнект в SSE встроен.

Оговорка по качеству: сами обзоры (`flowverify.co`, `procedure.tech`, `blog.rajpoot.dev` и подобные) — SEO-контент без именных авторов, поэтому использую их только как индикатор консенсуса, а не как источник фактов. Проверяемая часть утверждения — что на SSE стоят все стриминговые LLM-API — подтверждается первоисточником:

> When creating a Message, you can set `"stream": true` to incrementally stream the response using [server-sent events](https://developer.mozilla.org/en-US/Web/API/Server-sent_events/Using_server-sent_events) (SSE).
> — [Anthropic, Streaming messages](https://platform.claude.com/docs/en/build-with-claude/streaming)

Практический вывод тот же, что и в первой секции, просто с более уверенным основанием: SSE — правильный второй шаг, а не экзотика; SignalR для односторонней точки на колокольчике остаётся избыточным.

### Postgres 18 делает коллапс на записи дешевле

18.0 вышел 2025-09-25, и две записи в release notes прямо касаются наших решений.

**`RETURNING OLD`/`NEW`** — самое полезное:

> This new syntax allows the `RETURNING` list of `INSERT`/`UPDATE`/`DELETE`/`MERGE` to explicitly return old and new values by using the special aliases `old` and `new`.
> — [PostgreSQL 18.0 Release Notes](https://www.postgresql.org/docs/release/18.0/)

Для коллапса на записи это снимает лишний шаг: upsert карточки визита возвращает и предыдущее состояние (было ли прочитано, какой был тип), и новое — одним запросом, без `SELECT` перед `UPDATE` и без гонки между ними. Пересчёт «стало ли непрочитанным» становится атомарным.

**Skip scan для btree:**

> This allows multi-column btree indexes to be used in more cases such as when there are no restrictions on the first or early indexed columns (or there are non-equality ones), and there are useful restrictions on later indexed columns.
> — там же

Снижает цену ошибки в порядке колонок составного индекса — актуально, потому что у нас два перекрывающихся индекса на `Notifications` (по `TargetAccountId` и по `TargetAccountId` + `TargetMasterUserId`), и добавление `EntityId` в схему потребует решать, куда его ставить.

Ещё две записи упоминаю, чтобы закрыть вопрос: `uuidv7()` («This UUID value is temporally sortable») нам не нужен — ключ ленты `int identity`; асинхронный I/O (`io_method`) — общая производительность, не наша забота.

**Оговорка:** всё это работает только на 18-й версии, а на какой версии Postgres живёт база нотификаций — по репозиторию не видно, строки подключения (`Notifications:ConnectionString`) в секретах. Это надо проверить до того, как план будет опираться на `RETURNING OLD/NEW`.

### Рынок готовых notification-платформ жив и вырос

Knock, Novu, Courier, MagicBell, SuprSend, OneSignal — все на месте, ни одного закрытия не нашёл; появились дополнительные игроки, и у большинства есть drop-in inbox-компоненты для React/Vue/мобильных. Источники — вендорские сравнения (`knock.app`, `courier.com`, `suprsend.com`), то есть заинтересованная сторона: использую только как подтверждение, что рынок существует и активен.

Для нас «купить» — плохой вариант, и это стоит один раз проговорить в плане, чтобы вопрос не поднимался: пришлось бы отдавать наружу данные аккаунтов, визитов и телефонов воркеров, заводить второй источник identity, а сама лента у нас уже написана процентов на восемьдесят (модель, чтение с курсором, mark-as-read, контроллер). Знать про рынок полезно для другого случая — если понадобится мультиканальная доставка с preferences и дайджестами, писать это самим будет заметно дороже, чем взять готовое.

## Implications for the design

- **Не писать самодельный SSE на .NET 8** (anchor: план по транспорту). До EOL версии три месяца; SSE появляется бесплатно после апгрейда на .NET 10, который всё равно обязателен. В плане: polling + ETag сейчас, SSE — как шаг после апгрейда, с ценой «включить и настроить `timeoutSec` + keepalive», а не «написать стриминг руками».
- **Апгрейд платформы становится соседней задачей, а не фоном** (anchor: планирование). Если фича выезжает в конце 2026, она будет разрабатываться на .NET 8, а жить на .NET 10 — стоит избегать решений, которые придётся переделывать после апгрейда.
- **Коллапс на записи технически удобнее, чем казалось** (anchor: выбор места коллапса). На PG18 `RETURNING old/new` даёт атомарный upsert с получением предыдущего состояния карточки. Это ослабляет один из аргументов в пользу коллапса на чтении — но не аргумент про курсорную пагинацию, он остаётся в силе.
- **Порядок колонок в новом составном индексе — не критичное решение на PG18** (anchor: миграция). Skip scan даёт запас, но проверить план запроса всё равно нужно.
- **«Купить готовое» — сознательное «нет», с причиной** (anchor: границы решения). Данные аккаунтов и телефоны воркеров наружу, второй источник identity, при том что лента уже почти написана.

## Open questions / follow-ups

- [ ] **Версия Postgres у базы нотификаций** — от неё зависит доступность `RETURNING OLD/NEW`. Проверять по Cloud SQL, не по репозиторию.
- [ ] Планируется ли апгрейд на .NET 10 до ноября 2026 и в каком порядке относительно этой фичи — вопрос к лиду, влияет на то, закладывать ли SSE вообще.
- [ ] Веб-пуш в Safari/iOS PWA в этом заходе не проверял — понадобится, только если продукт вернётся к бейджу на домашнем экране.

---

# backend-notifications — Web Spike: ключи схлопывания и модели адресации (состояние 2026)

Четвёртый заход, две темы: какие механизмы схлопывания существуют на уровне платформ и стандартов в 2026 году, и как современные notification-платформы моделируют адресата. Обе темы уточняют уже написанное: по ключу выяснилось, что я слил в один три разных понятия, по адресации — что наша текущая модель даёт общее состояние прочитанности на несколько пользователей аккаунта.

Дата: 2026-07-27. Проектное следствие по ключу — в [`collapse-key.md`](collapse-key.md).

## Findings

### Ключей не один, а три: replace, group и re-alert

Стандарт браузерных уведомлений различает схлопывание и повторное оповещение. `tag` — ключ замены:

> "Let oldNotification be the notification in the list of notifications whose tag is not the empty string and is notification's tag, and whose origin is same origin with notification's origin, if any, and null otherwise." […] "Replace oldNotification with notification, in the list of notifications."
> — [WHATWG, Notifications API](https://notifications.spec.whatwg.org/)

А будить пользователя заново или нет — отдельный флаг:

> "A notification has an associated renotify preference (a boolean). It is initially false. When true, indicates that the end user should be alerted after the notification show steps have run with a new notification that has the same tag as an existing notification."
> — там же

Это прямой ответ на вопрос, который я в разделе про коллапс оставил открытым («карточка схлопнулась после прочтения — становится ли она снова непрочитанной?»). В стандарте это не следствие схлопывания, а **отдельное решение на каждое событие**: заменить тихо или заменить и снова привлечь внимание.

APNs идёт ещё дальше и разводит замену и группировку на два независимых идентификатора: `apns-collapse-id` обновляет существующее уведомление вместо отправки нового, а `threadIdentifier` группирует уведомления в Центре уведомлений — «the system groups notifications with the same thread identifier together in Notification Center and other system interfaces» ([Apple Developer](https://developer.apple.com/documentation/usernotifications/unnotificationcontent/threadidentifier)). Причём смешивать их бездумно нельзя: по обсуждениям на форуме разработчиков, одинаковый `apns-collapse-id` при разных `thread-id` схлопывание ломает *(источник — форум Apple, не документация; отношусь как к сигналу, а не к факту)*.

Сводно по 2026 году:

| Механизм | Что делает | Уровень |
|---|---|---|
| `tag` + `renotify` (WHATWG) | замена уведомления с тем же тегом; отдельный флаг «оповестить снова» | стандарт браузера |
| `apns-collapse-id` (Apple) | обновление существующего уведомления | транспорт |
| `threadIdentifier` (Apple) | визуальная группировка в Центре уведомлений | клиент |
| `collapse_key` (FCM) | доставляется только последнее сообщение группы, максимум 4 ключа на токен | транспорт |
| `chainId` (Teams/Graph) | обновление существующей записи фида | серверный API |
| digest `grouping key` (Novu) | батчинг событий в одну отправку | серверный API |

**Что это меняет для нас.** В [`collapse-key.md`](collapse-key.md) я предложил единый ключ «получатель + сущность + семья». Практика 2026 говорит, что это три разные роли, и склеивать их не надо:

1. **ключ замены** — какую строку обновлять (у нас: получатель + тип и id сущности);
2. **ключ группировки** — что визуально показывать вместе (у нас пока не нужен: одна карточка на визит и есть группа, но при переходе на инвойсы понадобится);
3. **флаг повторного оповещения** — гасить ли прочитанность и поднимать ли карточку, решается **на каждое событие**, а не на весь тип. Пример из наших четырёх: `hasn't started yet` в существующую карточку визита — это `renotify = true`, а `finished` после прочитанного `started` — скорее `false`.

Третий пункт снимает ложную дилемму: не нужно выбирать «всегда сбрасывать прочитанность» или «никогда».

### Адресация: индустрия делает получателя первоклассной сущностью, а не wildcard'ом

Knock моделирует три вида адресатов: пользователи, **objects** («a flexible abstraction that you can use to send notifications to non-user recipients») и **tenants** — и описание tenant'а читается как описание нашего аккаунта:

> "Tenants represent segments your users belong to. You might call these 'accounts,' 'organizations,' 'workspaces,' or similar." […] "a tenant can be applied as context to a workflow trigger in order to apply per-tenant branding, per-tenant preferences, and scope in-app feed messages to particular tenants."
> — [Knock, Tenants](https://docs.knock.app/concepts/tenants)

Плюс отдельное понятие **subscriptions** — связь «не-пользовательская сущность ↔ получатель», по которой платформа сама делает fan-out: «When an object is passed to a workflow trigger, Knock will automatically fan out and run a workflow for every subscriber on that object» ([Knock, Objects](https://docs.knock.app/concepts/objects)).

Novu решает ту же задачу через **topics**: ключ группы, по которому триггер разворачивается в отдельное исполнение на каждого подписчика — «When you trigger a workflow using a topic key, Novu performs a fan-out: it resolves all subscribers in the topic and executes the workflow independently for each subscriber» ([Novu, Topics](https://docs.novu.co/platform/concepts/topics)). Подписчик может topic заглушить или отписаться, и у подписки бывают условия.

Общее в обеих моделях: **fan-out на запись** — на каждого получателя своя запись со своим состоянием прочитанности. Групповая сущность (object/topic) служит адресом для триггера, а не единой записью для всех.

**А у нас fan-out на чтение.** `TargetMasterUserId IS NULL` означает «видно всем в аккаунте», и такая запись одна, с одним `ReadAt` (`NotificationsRepository.GetPaged`: `TargetMasterUserId == null || == targetMasterUserId`). Следствие, которого на груминге не касались: **в аккаунте с несколькими пользователями прочитанность общая**. Владелец открыл карточку — у менеджера она тоже погасла, и колокольчик у него потух, хотя он события не видел. Аккаунты с несколькими не-воркерами у нас существуют (владелец плюс менеджер), так что это не гипотетика.

| Модель | Плюсы | Минусы |
|---|---|---|
| **Fan-out на чтение** (наша): одна запись, `null` = всем | одна строка на факт, дешёвая запись, простой коллапс | общее состояние прочитанности; нельзя адресовать «всем кроме владельца»; `NULL` в ключе ломает unique-индекс |
| **Fan-out на запись** (Knock, Novu): строка на получателя | у каждого своё прочитано/не прочитано и свои preferences | строк в N раз больше; коллапс надо делать по каждому получателю; нужен список получателей на момент события |

Ни один вариант не «правильный» — но выбор надо сделать осознанно, потому что миграция с первого на второй означает размножение существующих строк и переделку ключа.

## Implications for the design

- **Развести ключ замены и флаг повторного оповещения** (anchor: схема + правило коллапса). `renotify`-семантика из стандарта решает вопрос «сбрасывать ли прочитанность при схлопывании» по-событийно, а не глобально. В нашей модели это булев признак на правиле перехода, а не колонка.
- **Ключ группировки пока не заводить, но зарезервировать место** (anchor: границы MVP). APNs разделяет collapse-id и thread-id; нам второй понадобится, когда в ленте появятся инвойсы и захочется группировать карточки по клиенту или документу.
- **Решить про общее состояние прочитанности до релиза** (anchor: модель адресации — новое, не обсуждалось на груминге). Сейчас в многопользовательском аккаунте пометка прочитанного одним гасит колокольчик у всех. Если это не то, что нужно продукту, вариант — fan-out на запись по образцу Knock/Novu, и тогда получатель обязан входить в ключ схлопывания (что уже предложено в [`collapse-key.md`](collapse-key.md)).
- **`null` как «всем» — известная слабость** (anchor: индексы). Индустрия вместо wildcard'а вводит явную групповую сущность (object/tenant/topic). У нас минимальный аналог — оставить `TargetMasterUserId IS NULL` для аккаунтных карточек, но не строить на `NULL` уникальность (см. `NULLS NOT DISTINCT` в [`collapse-key.md`](collapse-key.md)).
- **Preferences и подписки — вне MVP, но это следующий структурный слой** (anchor: границы скоупа). И Knock, и Novu вешают на подписку возможность заглушить и условия доставки. Нам это понадобится не раньше, чем появится второй тип получателя (воркер).

## Open questions / follow-ups

- [ ] Должна ли прочитанность быть персональной в аккаунте с несколькими пользователями? Вопрос к продукту, но ответ определяет, fan-out на запись или на чтение.
- [ ] Если персональная — кто список получателей на момент события: все не-воркеры аккаунта, или владелец плюс роли с правом на визиты? Упирается в permissions в `Tofu.Auth`.
- [ ] Нужна ли группировка карточек уровнем выше визита (по клиенту, по джобу) — тогда понадобится второй ключ, как `threadIdentifier` у APNs.
- [ ] Формулировка `renotify`-правил для четырёх типов MVP: какие события гасят прочитанность и поднимают карточку, какие обновляют тихо.
