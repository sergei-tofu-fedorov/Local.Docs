# FS-1352 — Current state (investigation 2026-07-08)

Карта текущего состояния кода/пайплайнов по трём осям задачи. Источник для `/plan write`. Все ссылки — `file:line`.

## TL;DR

- Нужные данные либо лежат в **SQL-таймлайне** (не в BQ), либо в **Amplitude-событиях** (не в BQ), либо **вообще не эмитятся** (факт отправки; сумма surcharge).
- Выбранный приёмник для FS-1352 — **путь B (Amplitude)**: расширяем/добавляем продуктовые analytics-события в BFF.

## Три событийных механизма (не путать)

| # | Механизм | Приёмник | Заметки |
|---|---|---|---|
| A | Domain Events → SQL | Postgres `InvoiceEvents`/`EstimateEvents` | Таймлайн/аудит. Богато, но не выгружается в BQ. |
| B | Analytics Events → HTTP → `analytics-api-service` → Amplitude | Amplitude (lossy, fire-and-forget) | Продуктовые события. **Выбран для FS-1352.** |
| C | Subz → Pub/Sub → BigQuery `analytics.events` | BQ (внешний репо `Subz`) | Только billing-lifecycle. |

- Warehouse `ai_analysis_us` (`inv-project`) строит `Tofu.AI.Backend` из **ежедневных Mongo-снапшотов**, не из B/C.
- Amplitude → BQ только через маркетинговый `playfair-project` (не `ai_analysis_us`).
- Карта: `Local.Docs/Backend/Flows/ANALYTICS_EVENTS_FLOWS.md`; инвентарь: `Backend/Storage/bigquery.md`, `bigquery-sources.md`.

### Механизм B — детали (точки для FS-1352)

- BFF абстракции: `Invoices.Core/Analytics/` — `Event.cs:3`, `IAnalytics.cs:5`, `IAnalyticsService.cs:5`, `Context.cs:3`.
- Буфер/флаш per-request: `Invoices.Analytics/Analytics.cs:11` (резолв userId — `ResolveUserId:133`).
- Sink (HTTP `POST /api/events`): `Invoices.Analytics/AnalyticsService.cs:9` (envelope :35-41).
- Endpoint: `ConnectionStrings:AnalyticsService = http://analytics-api-service`.
- Существующие события: `Invoices.Common/Analytics/Events/` — `InvoicePaid`, `PaymentReceived`, `PayoutReceived`, `EmailNotificationSent`, `ReminderSent`, `PushEvent` (+`EmailSent`/`EmailError` и др.).
- Ядро (`Tofu.Invoices.Backend`) имеет аналог `IAnalyticsApiGateway` (`Infrastructure/Analytics/AnalyticsApiGateway.cs:9`), но эмитит **только** `OverdueInvoice` из воркера (`SendPastDueDatePushJob.cs:147,207`).

## Ось 1 — Отправка инвойсов/эстимейтов

- Каналы: `InvoiceSentMethod {Unknown, Email, Manual}` — `Tofu.Invoices.Domain/Models/Invoices/InvoiceSentMethod.cs:3`; аналог `EstimateSentMethod.cs:3`. BFF-зеркала: `Invoices.Core/Models/InvoiceSentMethod.cs:3`, `EstimateSentMethod.cs:3`.
- Метод хранится на агрегате: `Invoice.SentMethod`+`SentAt`, `EnrichedInvoice.SetSentMethod` (`EnrichedInvoice.cs:162`); авто-промоут в `Email` при первой успешной отправке (`EnrichedInvoice.cs:153`). Эстимейт: `EnrichedEstimate.SetStatus` (`EnrichedEstimate.cs:78`).
- Поток отправки (нет `SendInvoiceCommand`): BFF `EmailController` (`V3/EmailController.cs:50` `POST api/email/send`) → `Tofu.Email/Service/EmailService.cs:60 Send` → провайдер (SendGrid→Sendinblue) → `SetEmailStatus(InProgress)` → gRPC ядра `InvoicesService.cs:287 SetEmailStatus`. Финальный `Sent` — по callback: `SendGridCallbackController` → `EmailCallbackService`.
- Mail state machine: `MailStatusStateMachine.cs`, `EmailStatusType {Sent=0, InProgress=1, Opened=2, MarkedAsSent=3, Error=4}`.
- SQL-таймлайн: `SentMethodChanged`, `EmailStatusChanged` (без recipient/счётчика).
- **Пробел:** analytics-события на факт отправки НЕТ. `EmailSent` (BFF) шлётся на open-callback (`EmailCallbackService.cs:303`), не на отправку, без метода/сущности.
- Готча: легаси-инвойсы с `MailStatus=Sent`, но `SentMethod=null` — метод выводится как `Email` на чтении (`InvoicesServiceMapping.cs:217`), т.е. историческая атрибуция частично inferred.

## Ось 2 — Приём оплаты (методы + сумма)

- Методы = провайдеры (строковые константы): `PaymentProviders.cs:5` — `Stripe, PayPal, Cash, Check, Bank, Venmo, Cash App, Zelle, Card`. Хранится в `Invoice.PaymentInfo.PaidByProvider`.
- Статус: `InvoiceStatus {NotPaid, Paid(ручной), PaidByCard(PSP), Refunded, PartialRefunded, Dispute}` (`InvoiceStatus.cs`); переходы — `InvoiceStatusStateMachine.cs:23`.
- Отдельный словарь `PaymentRequest.PaymentMethod {Unknown, QrCode, TapToPay, WebLink}` (`Invoices.Core/Models/PaymentRequests/PaymentRequest.cs:44`) — как собран payment request, не провайдер.
- Суммы: `ReceivedPayments[]` (частичные), `TotalAmount/TotalDue/CurrencyCode`, `PaidDate` (`Invoice.cs:38`). Proto: `V1/InvoicesApi.proto:235`.
- Два пути записи оплаты:
  - PSP: BFF `PaymentIntentsService.cs` — `TrySuccessPayment:80`/`CapturePayment:234` → `ProcessPaymentEntity:482` → `InvoicePaymentSuccess:522` (Status=PaidByCard, gRPC upsert :557).
  - Ручной mark-as-paid: обычный invoice PUT → ядро `EnrichedInvoice.CheckPaymentReceived:215` → `InvoicePaymentReceivedDomainEvent`. ⚠️ Гард `EnrichedInvoice.cs:236`: изменения `< $1` игнорируются.
- События:
  - Ядро (SQL): `InvoicePaymentReceivedDomainEvent` → payload `{From, To(amount), ByPsp, Provider, CurrencyCode, DocNumber}` (`InvoiceEventsFactory.cs:76`). **Без комиссии.**
  - BFF (Amplitude): `PaymentReceived` (`Invoices.Common/Analytics/Events/PaymentReceived.cs`) — `amount, invoiceAmount, currency, payment_method, payment_source, payment_provider, application_fee_amount, payment_fee_paid_by`. Эмит только на PSP-пути (`PaymentIntentsService.cs:619`).
- **Пробел:** по ручным Cash/Check/... BFF-события `PaymentReceived` НЕТ вовсе (только SQL-событие ядра).
- Вебхуки: Stripe `POST /callback/hooks/stripe/events` (`PaymentsController.cs:321`, подпись `StripeEventHookMapper.cs:21`). PayPal — без вебхука, capture+redirect (`PaymentsController.cs:258`).

## Ось 3 — Surcharge (перекладывание комиссии на клиента)

- Буквального `surcharge`/`processingFee` в коде НЕТ. Фича = **`ClientPaysFeeEnabled`** (тумблер) + **`ClientFeeAmount`** (сумма надбавки).
- Тумблер: `AuthenticatedPaymentTypeSettings.ClientPaysFeeEnabled`; set через `POST payments/connections/{providerType}/set-settings` (`PaymentsController.cs:134` → `PaymentsService.cs:234`). Отдаётся на web-payment page (`WebLinkViewService.cs:163`).
- Расчёт: `PaymentIntentsService.CalcFees:850` → `CalcClientFee:375` (гросс-ап: `finalAmount = (amount + FixedFee + feeAmount) / (1 - PercentFee)`). Ставки: `CustomerFeesByCountry` (`Config.cs:46`, значения `appsettings.json:293`, US card 0.30+2.9%). Только Stripe card + Tap-to-Pay.
- Хранится на `PaymentOrder`: `FeeAmount`(платформенная) + `ClientFeeAmount`(surcharge) (`PaymentOrder.cs:16,19`).
- **Пробел:** долларовое `ClientFeeAmount` НЕ попадает ни в одно analytics-событие. `PaymentReceived` несёт лишь флаг `payment_fee_paid_by = client/business` (`PaymentIntentsService.cs:634`) и платформенную `application_fee_amount`, а не сумму surcharge.

## Точки эмиссии для реализации (путь B)

- Отправка: `Tofu.Email/Service/EmailService.cs` (email) + ручной mark-as-sent (invoice/estimate PUT в BFF).
- Оплата/surcharge: `Invoices.Payments/PaymentIntentsService.cs` (PSP) + ручной mark-as-paid путь (`InvoicesController` PUT / ядро `InvoicePaymentReceivedDomainEvent`).
- Новые события/props: `Invoices.Common/Analytics/Events/`.
