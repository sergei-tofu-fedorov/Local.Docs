# Amplitude для новичков — как это работает у нас

Ознакомительный документ: что такое Amplitude, как в нём думать про события, какие есть best practices и дашборды, и **как именно устроена наша интеграция** (Path 1 → `Tofu.Analytics.Backend` → Amplitude). Читать перед тем, как добавлять события в рамках FS-1352.

> Кратко: Amplitude — это продуктовая аналитика «по событиям». Мы шлём в него факты о действиях пользователя (отправил инвойс, получил оплату), а аналитики строят по ним воронки, ретеншн и сегменты. У нас доставка **lossy** (может терять) и с задержкой ~5 минут — это ОК для «как часто / каким образом», но не для финансовой сверки до цента.

---

## 1. Что такое Amplitude и зачем он нужен

Amplitude — SaaS для **product analytics**. В отличие от логов и BI-отчётов по БД, он заточен под вопросы вида:

- Как часто пользователи делают действие X? (частота, тренд во времени)
- Каким путём они доходят до ценного действия? (воронки: создал инвойс → отправил → получил оплату)
- Возвращаются ли они? (retention / lifecycle)
- Чем отличается поведение разных сегментов? (по стране, плану, методу оплаты)

Ключевая идея: ты **шлёшь события**, а вопросы задаёшь **потом**, в UI, без изменения кода. Поэтому важно с самого начала слать правильные события с правильными свойствами — переспросить «задним числом» то, что не залогировал, нельзя.

---

## 2. Базовые понятия (модель данных Amplitude)

| Понятие | Что это | Пример у нас |
|---|---|---|
| **Event** | Факт «что-то произошло». Имеет имя (`event_type`) и время. | `"Payment received"`, `"Invoice Paid"` |
| **Event properties** | Свойства конкретного события (контекст этого действия). | `payment_provider = Stripe`, `amount = 120.00`, `currency = USD` |
| **User properties** | Свойства пользователя «сейчас» (перезаписываются). Живут на профиле, не на событии. | план, страна (у нас — `GetUserProps()`) |
| **user_id** | Стабильный идентификатор известного пользователя. Склеивает сессии/устройства в одного человека. | наш резолв через master-user / platform-link |
| **device_id** | Идентификатор устройства до логина (анонимная сессия). | клиентские SDK |
| **Identify** | Спец-операция обновления user properties без «события-действия». | Subz шлёт `is_trial`, `ltv` и т.п. |

Мысленная модель: **event_type = глагол-действие**, **event properties = обстоятельства этого действия**, **user properties = состояние человека**. Не путать: «какой план был в момент оплаты» — это event property (снимок), «какой план сейчас» — user property (перезаписывается).

---

## 3. Как события попадают в Amplitude У НАС

В Amplitude данные приходят **двумя независимыми путями** (проверено BQ-аудитом; полная карта — `../../../Backend/Flows/ANALYTICS_EVENTS_FLOWS.md`):

### Path 1 — продуктовые события (это наш код, это трогаем в FS-1352)

```
Бизнес-код BFF                         Tofu.Invoices (ядро)
  _analytics.WithContext(ctx)            IAnalyticsApiGateway (только OverdueInvoice)
  _analytics.Log(event)
       │  буфер per-request
       ▼  на Dispose запроса → IOffloadQueue → резолв userId
  AnalyticsService.Send → POST /api/events  (fire-and-forget, ошибки глотаются)
       ▼
  Tofu.Analytics.Api  /api/events
       ▼
  Postgres outbox
       │  SendingAnalyticsWorker — раз в ~5 мин: батч → отправка → удаление; ≤3 ретрая, потом DROP
       ▼
  AmplitudeProvider → POST https://api.amplitude.com/2/httpapi
```

Точки в коде (`Invoices.Backend`):
- Абстракции: `Src/Invoices.Core/Analytics/` — `IAnalytics`, `IAnalyticsService`, `Context(AccountId, ProductKey)`, `Events/Event.cs`.
- Буфер и флаш: `Src/Invoices.Analytics/Analytics.cs` (`Log:32`, `FlushAll:62`, резолв `ResolveUserId:133`).
- Sink (HTTP): `Src/Invoices.Analytics/AnalyticsService.cs` (`Send:20`, конверт `:25`, `POST /api/events :41`).
- DI/endpoint: `Src/Invoices.Analytics/AnalyticsServicesInstaller.cs` (`ConnectionStrings:AnalyticsService = http://analytics-api-service`).
- Каталог событий: `Src/Invoices.Common/Analytics/Events/*`.
- Микросервис `Tofu.Analytics.Backend` — **вне этого воркспейса**; описан только во flow-doc.

**Конверт события** (`AnalyticsService.cs:25-38`):
```json
{ "productKey": "...", "eventType": "Payment received",
  "payload": { "occuredAt": "...", "userId": "...", "accountId": "...",
               "properties": { ...GetEventProps(), "environment": "prod" },
               "userProperties": { ...GetUserProps() } },
  "id": "<guid>" }
```

**Резолв `user_id`** (`Analytics.cs:133-156`) — почему это важно: сервер-сайд событие должно лечь в тот же Amplitude-стрим, что и клиентские события этой платформы. Логика:
- есть master-user → platform-link по `productKey` → `GetShortUserId(link.PlatformId, link.Platform)` (Web — полный masterUserId; iOS — device-id, обрезанный до 25 символов);
- нет master (легаси/аноним) → фолбэк на `AccountIdentifiers`;
- ничего не нашли → событие **тихо дропается**.
- **Вывод: без корректного `productKey` в `Context` атрибуция поедет или событие потеряется.**

### Path 2 — billing lifecycle (Subz, НЕ наш код)

Внешний репо `C:\Git\Work\Subz` публикует нормализованные события подписок в Pub/Sub, откуда они расходятся в Amplitude + GA4 + AppsFlyer + **BigQuery `analytics.events`**. События вида `SubscriptionPaidEvent`, `AccountCreatedEvent` и т.п. **Пересечения с Path 1 нет** (0 общих типов). Мы этот путь в FS-1352 не трогаем.

### Важное следствие про хранилище

**В BigQuery пишет только Path 2 (Subz).** Наши продуктовые события (Path 1) идут **только в Amplitude**, а в организацию возвращаются через маркетинговый DWH `playfair-project`, не в `ai_analysis_us`. Если аналитикам нужны key-actions именно в BQ-хранилище — Amplitude-путь их туда напрямую не донесёт (см. Open questions в README).

---

## 4. Best practices инструментирования (как слать события правильно)

Эти правила — не про наш код, а про то, как не испортить данные в Amplitude. Дешевле соблюсти сразу, чем чистить потом.

1. **Единая схема имён (taxonomy).** Пример распространённой схемы — `Object Action` («Invoice Sent», «Payment Received»). У нас исторически смесь стилей (`"Payment received"`, `"Invoice Paid"`, `"Push sent"`) — **для новых событий FS-1352 держись одного стиля и согласуй имена с аналитиками до релиза** (переименовать событие задним числом = разрыв воронок).
2. **Не плоди события — параметризуй свойствами.** НЕ `InvoiceSentByEmail` / `InvoiceSentManually` как два события, а одно `Invoice Sent` со свойством `sent_method = email|manual`. Так строятся сегменты одним чартом.
3. **Свойства — консистентные по типам и значениям.** `amount` всегда число-строка в одном формате, `currency` — ISO-код, enum-значения из фиксированного словаря (у нас провайдеры: `Stripe/PayPal/Cash/Check/Bank/Venmo/Cash App/Zelle/Card`). Разнобой значений раздувает легенды и ломает группировки.
4. **Никакого PII в свойствах.** Не слать email, ФИО, телефоны, номера карт. Мы и так шлём обрезанные id (`GetShortUserId`) — держим этот принцип.
5. **Считабельность.** Одно бизнес-действие = одно событие (идемпотентно, без дублей на ретраях). Помни: у нас доставка lossy, поэтому событие — это «сигнал частоты», а не «источник истины по деньгам».
6. **Tracking plan / governance.** Заведи/обнови описание нового события (имя, свойства, типы, кто потребитель) вместе с аналитиками. Amplitude Data (tracking plan) умеет валидировать входящие события против плана.
7. **Осторожно с user properties.** Они перезаписываются последним значением — если нужно «как было в момент действия», клади в event property.

---

## 5. Дашборды и чарты (что аналитики строят поверх событий)

Ты шлёшь события — аналитик собирает из них ответы. Основные типы чартов Amplitude:

| Чарт | Отвечает на вопрос | Пример под FS-1352 |
|---|---|---|
| **Segmentation** (Event Segmentation) | Как часто? Сколько? В разбивке по свойству. | Кол-во `Invoice Sent` в неделю с разбивкой по `sent_method` |
| **Funnel** | Какая доля доходит от шага к шагу? | `Invoice Created → Invoice Sent → Payment Received` |
| **Retention** | Возвращаются ли пользователи делать действие? | Повторные отправки инвойсов по когортам |
| **Lifecycle** | New / Current / Resurrected / Dormant по действию. | Активность по выставлению счетов |
| **Journeys / Pathfinder** | Какими путями пользователи ходят? | Что делают между созданием и оплатой |
| **User Composition** | Из кого состоит аудитория по user property. | По стране / плану |

Вокруг чартов:
- **Cohorts** — сохранённые сегменты пользователей («те, кто включил surcharge»), переиспользуются в любом чарте.
- **Dashboards** — набор чартов на одной странице (напр. «Invoicing health»); шарятся команде.
- **Notebooks** — чарты + текст для сторонней/разбора гипотез.
- **Alerts** — оповещения на аномалии метрики.

**Как обычно строят дашборд:** выбрать событие → задать метрику (uniques / totals / property sum, напр. сумма `amount`) → разбить по свойству (`group by sent_method`) → задать интервал/фильтры → сохранить чарт на дашборд. Всё в UI, код не меняется — при условии что нужное свойство было в событии.

---

## 6. Как это ложится на FS-1352

Что нам нужно от событий, чтобы аналитики построили требуемые чарты:

| Ось задачи | Событие (предложение) | Ключевые свойства | Что построят |
|---|---|---|---|
| Отправка инвойсов | `Invoice Sent` | `sent_method (email/manual)`, `invoice_id` | Segmentation частоты по методу; Funnel до оплаты |
| Отправка эстимейтов | `Estimate Sent` | `sent_method`, `estimate_id` | То же для эстимейтов |
| Приём оплаты | расширить `Payment Received` | `payment_provider`, `amount`, `currency` — **включая ручные Cash/Check** | Суммы (property sum) и разбивка по методу |
| Surcharge | те же события оплаты | `client_fee_amount`, `payment_fee_paid_by` | Adoption surcharge и объём переложенной комиссии |

Дизайн-принципы отсюда: одно событие на действие + `sent_method`/`payment_provider` как свойства (best practice #2); согласовать имена (`Invoice Sent` vs текущий стиль) с аналитиками (#1); чинить/добавлять свойства, а не плодить события.

---

## 7. Готчи именно нашей реализации (держать в голове при добавлении событий)

1. **Lossy + задержка ~5 мин.** BFF глотает HTTP-ошибки, воркер дропает событие после 3 фейлов. Годится для частоты/паттернов, **не** для сверки денег до цента.
2. **Флаш на `Dispose` запроса.** `Analytics` — scoped `IDisposable`; события вне request-scope (фоновые джобы, некоторые callback-пути) могут не улететь. Проверять точку эмиссии.
3. **`productKey` обязателен и должен быть верным** — иначе `ResolveUserId` промахнётся/дропнет (см. §3).
4. **Amplitude — единственный реализованный провайдер;** `environment` в событии выбирает sandbox vs prod ключ. Тестировать против dev/sandbox.
5. 🐞 **Баг рядом:** в `PaymentReceived.GetEventProps()` ключ свойства — `"application_fee_amount "` с **хвостовым пробелом** (`Src/Invoices.Common/Analytics/Events/PaymentReceived.cs:26`). Раз FS-1352 трогает это событие — стоит починить, но учесть: существующие Amplitude-чарты ссылаются на поле именно с пробелом → это **поведенческое breaking для дашбордов**, согласовать с аналитиками.
6. **Ядро (`Tofu.Invoices.Backend`) шлёт в Amplitude только `OverdueInvoice`** через отдельный `IAnalyticsApiGateway` (воркер). Если событие удобнее эмитить из ядра — механизм есть, но по FS-1352 всё нужное доступно в BFF.

---

## Ссылки

- Карта пайплайнов: `../../../Backend/Flows/ANALYTICS_EVENTS_FLOWS.md`
- Текущее состояние по FS-1352: `./current-state.md`
- Инвентарь хранилищ / BQ: `../../../Backend/Storage/bigquery.md`, `bigquery-sources.md`
- Код Path 1: `Invoices.Backend/Src/Invoices.Analytics/`, `Src/Invoices.Core/Analytics/`, `Src/Invoices.Common/Analytics/Events/`
