# FS-1352 — iOS уже трекает (client-side Amplitude)

Что мобильный клиент (`C:\Git\Work\IOS\Invoices.Apps.iOS`) **уже** шлёт в Amplitude по нашим четырём осям. Критично, потому что backend-события (FS-1352) рискуют **двойным счётом** с уже существующими клиентскими.

## Где живёт аналитика в iOS

- Три реальных провайдера через composite-трекер: **Amplitude** (основной, client-side напрямую), **Firebase Analytics**, **AppsFlyer** (только attribution/purchase). + Clarity (session replay).
- Amplitude-адаптер: `Invoices/Invoices/Analytics/Adapters/AmplitudeTracker.swift` (init :22, `logEvent` :725-732; `accountId` авто-цепляется к каждому событию :731).
- Fan-out: `CompositeTrackerService.swift:19`; протокол `TrackerService.swift:14` (метод на событие).
- **Два стиля именования сосуществуют:** legacy (sentence-case, verb-first: `"Send invoice"`, props snake_case) и новый (Title-Case «Object Action»: `"Invoice Created"`). Firebase лоуэркейсит + меняет пробелы на `_`.
- ⚠️ Единого enum/констант нет — имена инлайн-строками (система A) либо в per-screen enum-ах `*AnalyticsEvent.swift` (система B).

## По осям — что уже есть

### Отправка инвойса
- `"Tap send invoice"` — **интент по тапу** (до отправки). props `type (email/share/print/save)`, `is_first_time`. `AmplitudeTracker.swift:170`.
- `"Send invoice"` — фичат в `onSuccess`. **Email vs manual различается свойством `application`:** `mail_server` = серверная email-отправка (`InvoiceDetailViewModel.swift:351,393`), иначе `share/<activity>` = ручной share-sheet (`:475`). props `application, template, context, is_first_time, attachments_count`. `AmplitudeTracker.swift:174`.

### Отправка эстимейта
- `"Tap send estimate"` (интент) — `AmplitudeTracker.swift:529`.
- `"Send estimate"` — тот же `mail_server` vs `share` сплит (`EstimateDetailViewModel.swift:351/385`). `AmplitudeTracker.swift:533`.
- `"Estimate status changed"` — `from_status/to_status`. `:525`.

### Приём оплаты
- **Выделенного «Payment received» для инвойсов НЕТ.** Ближайшее — `"Mark invoice"` (`to_status` из `not_paid/marked_as_paid/paid_by_card/paid_by_stripe`, `context`) — **без суммы/валюты**; фичат реактивно из локального DB-change (`AmplitudeUpdaterServiceImpl.swift:147`).
- Payment Requests: `"Create request"` несёт `amount, currency, status, payment_method (tap_to_pay/payment_link/qr_code)` (`:402`); `"Mark request"` — `to_status` (в т.ч. `paid_by_stripe`), без суммы (`:417`).
- `"Choose payment method"` — `payment_method` (`:394`).
- **Сумма есть только на create-событиях, никогда на подтверждении оплаты.**

### Surcharge / client pays fee
- Только тумблер настройки: `"Payment fee changed"` (Amplitude, `is_fee_enabled`) / `"Client fee changed"` (Firebase, `is_enabled`) — фичат после успеха серверного вызова `PaymentServiceImpl.setClientFee` (`:271`). ⚠️ **имя расходится между провайдерами.**
- **Per-transaction суммы надбавки нет** — `ext_client_fee` уходит только в метадату Stripe (`TapToPayServiceImpl.swift:152`).

## Client intent vs backend-confirmed (риск дублей)

- `"Tap send…"` — чистый интент (тап).
- `"Send invoice/estimate"` — **client-observed success**: для `mail_server` фичат после успеха серверной email-отправки → **пересекается** с планируемым backend «invoice sent (email)».
- `"Mark invoice" to_status=paid_by_stripe/paid_by_card` — по сути **backend-подтверждённая оплата**, поднятая на клиент (context `.backend`, `AmplitudeUpdaterServiceImpl.swift:230`).

## User properties (релевантные)

Есть: `is_payments_on, is_payment_requests_on, is_instant_payout_enabled, is_instant_method_linked, cpp_name`, объёмные (`invoices_total/paid/notpaid, estimates_total, …`), `trial_active`.
**Пробелы:** нет явных `plan`/tier и `country`, нет единого флага статуса платёжного аккаунта.

## Вердикт: overlap vs gap

| Backend-событие (FS-1352) | Существующее iOS | Пересечение |
|---|---|---|
| Инвойс отправлен — **email** | `"Send invoice"` `application=mail_server` | **OVERLAP / двойной счёт.** Нужен единый source of truth. |
| Инвойс отправлен — **manual** | `"Send invoice"` `application=share` | Client-only (backend не видит ручной share) → это **другой концепт**, не дубль. |
| Эстимейт отправлен | `"Send estimate"` (тот же сплит) | Как выше. |
| Оплата (метод+сумма) | только `"Mark invoice"`/`"Mark request"` со статусом, **без суммы** | **Почти GAP** (backend добавляет сумму+чистый метод). Следить за дублем по Stripe (`paid_by_stripe` уже backend-originated). |
| Surcharge (сумма) | только тумблер `"Payment fee changed"` | **GAP** — per-transaction события нет. Не переиспользовать имя тумблера. |

## Рекомендации по именованию (под доминирующий клиентский стиль)

- sentence-case verb-first + snake_case props: `"Invoice Sent"` (`method: email/manual`), `"Estimate Sent"`, `"Payment Received"` (`method, amount, currency`), надбавку — отдельным именем (НЕ `"Payment fee changed"`), напр. `"Surcharge Applied"` (`fee_amount, currency`).
- Добавить свойство **`source: "backend"`** ко всем backend-событиям, чтобы аналитики отличали их от клиентских `"Send invoice"`/`"Mark invoice"` и не считали дважды.
- Цеплять `accountId` (клиент так делает на каждом событии).
