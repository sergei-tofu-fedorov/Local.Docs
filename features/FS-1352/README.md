# FS-1352 — BE: Собираем аналитику по ключевым действиям пользователей

**Status:** planning
**Started:** 2026-07-08
**ClickUp:** https://app.clickup.com/t/FS-1352
**Affected repos:** `Invoices.Backend` (BFF, primary)

## Goal

Собираем аналитику по ключевым действиям пользователей — Нам необходимо добогатить данными в нашем аналитическом хранилище информацию о том Как часто и каким образом отправляют инвойсы пользователи. Как часто и каким образом отправляют эстимейты пользователи. Как получают оплату и через какие методы и на какую сумму. (включение перекладывание комиссии на пользователя)

**Chosen approach (после исследования 2026-07-08):** обогащаем **путь B** — продуктовые analytics-события `IAnalytics` / `IAnalyticsService` в BFF, которые уходят в `analytics-api-service` → Amplitude. НЕ трогаем SQL-таймлайн (механизм A) и НЕ строим новый Pub/Sub→BigQuery sink. См. `research/current-state.md` для полной карты трёх событийных механизмов и почему product-события сегодня не доходят до `ai_analysis_us`.

**⚠️ iOS уже трекает эти действия client-side** (Amplitude напрямую) — см. `research/ios-analytics.md`. Backend-события рискуют **двойным счётом**: `"Send invoice"`/`"Send estimate"` (email-кейс = серверная отправка), `"Mark invoice" to_status=paid_by_stripe` (backend-подтверждённая оплата).

**Dedup-стратегия (решено 2026-07-08): backend покрывает ТОЛЬКО пробелы клиента.** Email-отправку и Stripe-оплату оставляем клиенту (не дублируем). Backend эмитит лишь то, чего у iOS/web нет: **ручные оплаты (Cash/Check/Bank/Venmo/CashApp/Zelle) с суммой**, **per-transaction surcharge (`ClientFeeAmount`)**, и **backend-only каналы отправки** (напоминания/автоматические/API-отправки, которых клиент не видит). Это сужает оси 1–2 (см. Scope).

## Scope

Оси задачи остаются те же (отправка инвойсов/эстимейтов, приём оплаты, surcharge), но **вклад backend по каждой оси — только пробел клиента** (см. dedup-стратегию выше и `research/ios-analytics.md`).

- **In scope (пробелы, которые закрывает backend):**
  1. **Приём оплаты — ручные провайдеры** (`Cash/Check/Bank/Venmo/Cash App/Zelle`): событие с методом + суммой + валютой. У клиента нет ни суммы, ни выделенного payment-received события; `PaymentReceived` в BFF сейчас фичат только PSP-путь.
  2. **Surcharge — per-transaction**: долларовое `ClientFeeAmount` + `payment_fee_paid_by` в событии оплаты. У клиента только тумблер настройки, суммы надбавки на транзакции нет.
  3. **Backend-only отправки** (если есть): напоминания/автоматические/API-инициированные отправки инвойсов/эстимейтов, которые клиент не инструментирует. Подтвердить наличие таких путей в `/plan write` — иначе оси 1–2 для backend пустые.
- **Out of scope:**
  - **Email-отправка и Stripe/PSP-оплата** — покрыты клиентом (`"Send invoice"`/`"Send estimate"` `mail_server`, `"Mark invoice" paid_by_stripe`), backend НЕ дублирует.
  - Изменение/выпиливание клиентских событий (это отдельная iOS/web-задача, если позже выберут single-source-of-truth).
  - Новый sink в BigQuery / Pub/Sub (путь C) — приёмник Amplitude (путь B).
  - Обогащение Mongo-снапшотов / `ai_analysis_us`.
  - Новые каналы отправки (SMS/link).

## Affected repos

- `Invoices.Backend` (BFF, primary) — новые/расширенные analytics-события (`Invoices.Common/Analytics/Events/`), эмиссия из `Tofu.Email/Service/EmailService.cs` (отправка) и `Invoices.Payments/PaymentIntentsService.cs` + ручной mark-as-paid путь (оплата/surcharge).
- `Tofu.Invoices.Backend` — **скорее всего не требуется** (send-method и суммы уже приходят в BFF из ядра; события эмитим BFF-side). Подтвердить в `/plan write` — см. Open questions.

**Cross-repo notes:**
- Одно-репо фича (BFF). Контрактных gRPC/proto изменений не ожидается.
- Producer/consumer порядок неприменим, если ядро не трогаем.

## Plan

Numbered, repo-scoped steps that can be ticked off during implementation. _(high-level; детализировать в `/plan write`)_

1. [ ] Событие приёма оплаты по **ручным провайдерам** (Cash/Check/Bank/Venmo/CashApp/Zelle) с `method + amount + currency`; эмиссия на пути ручного mark-as-paid (BFF invoice PUT / ядро `InvoicePaymentReceivedDomainEvent`). Учесть гард «< $1 игнорируется» (`EnrichedInvoice.cs:236`).
2. [ ] Добавить `client_fee_amount` (сумма surcharge = `ClientFeeAmount`) + `payment_fee_paid_by` в событие оплаты PSP-пути (`PaymentIntentsService`). Это единственная surcharge-точка, где сумма известна.
3. [ ] Выяснить наличие **backend-only путей отправки** (напоминания/авто/API). Если есть — событие отправки с `method` + `source:"backend"`; если нет — оси 1–2 вне backend-скоупа.
4. [ ] Ко всем новым событиям — свойство `source:"backend"` и `accountId`; проверить резолв `userId`/`accountId`/`productKey` (`Analytics.ResolveUserId`) в новых точках (особенно фоновые/callback — флаш на `Dispose` request-scope).
5. [ ] Согласовать имена событий/свойств с аналитиками (стиль клиента: sentence-case verb-first, snake_case props).

## API / DTO changes

Нет публичных REST/gRPC изменений — только internal analytics-события (envelope: `productKey, eventType, payload{occuredAt, userId, accountId, properties}`), уходящие в `analytics-api-service`.

## Breaking changes

None — additive only. Новые события / новые свойства в существующих событиях; изменения формы существующих полей не планируются. (Перепроверит `/feature review` по факту диффа.)

## Data / migration

Нет. События идут через существующий HTTP-sink в Amplitude; ни Mongo-коллекций, ни EF-миграций, ни BQ-таблиц не добавляется.

## Open questions

- [x] **Двойной счёт с iOS — РЕШЕНО (2026-07-08):** стратегия (б) — backend покрывает только пробелы клиента (ручные оплаты, per-transaction surcharge, backend-only отправки). Email-отправку и Stripe-оплату не дублируем. См. dedup-стратегию в разделе Goal.
- [ ] **Есть ли backend-only пути отправки?** От этого зависит, остаются ли оси «отправка инвойса/эстимейта» в backend-скоупе вообще (напоминания, авто-отправки, API). Выяснить в `/plan write`.
- [ ] **Именование событий.** Согласовать с клиентским доминирующим стилем (sentence-case verb-first, snake_case props): `"Payment Received"` (`method, amount, currency, source:"backend"`), надбавку — НЕ именем тумблера `"Payment fee changed"`, а отдельным (напр. `"Surcharge Applied"`). Финализировать с аналитиками.
- [x] **Путь до BQ-хранилища — РЕШЕНО (2026-07-09):** строим мост Amplitude → BQ (`inv-project`) через DIY Export-API, хост `Tofu.AI.Backend` (Hangfire-джоб → GCS → BQ `amplitude.src_events` → марты). Отдельный инфраструктурный воркстрим — полный дизайн в [`research/amplitude-bq-bridge.md`](research/amplitude-bq-bridge.md). Блокер: определить целевой Amplitude-проект backend-событий + его export `secret_key` (шаг 0 дизайна).
- [ ] Нужно ли трогать `Tofu.Invoices.Backend`, или все точки эмиссии есть в BFF (send через `EmailService`, ручной mark-as-sent/paid через `InvoicesController` PUT).
- [ ] Единая ли схема события оплаты (расширить `PaymentReceived`) или отдельное событие для ручных провайдеров; как назвать `sent_method` в событиях отправки.
- [ ] Manual-оплаты: где именно перехватывать (BFF invoice PUT / core `InvoicePaymentReceivedDomainEvent`); учесть гард «< $1 игнорируется» в ядре (`EnrichedInvoice.cs:236`).
- [ ] Нормализация словаря провайдеров/методов для аналитики (`PaymentProviders` строки vs `PaymentRequest.PaymentMethod` enum).

## Test plan

- Unit tests: сборка props у новых событий (метод отправки, сумма, `client_fee_amount`, `payment_fee_paid_by`).
- Integration tests: end-to-end — отправка инвойса/эстимейта и приём оплаты (PSP + ручной) проверяют, что событие ушло в sink с ожидаемым envelope/properties.
- Manual verification: прогон в dev против `analytics-api-service` (или локального стаба) — проверить попадание событий и корректность `userId`/`accountId`/`productKey`.
