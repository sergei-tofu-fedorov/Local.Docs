# iOS — обработка `adapterType` подписки/плана

> Как iOS декодирует поле `adapterType` (енум адаптера биллинга) из ответов бэкенда и что бывает с новыми/нестандартными значениями. Вверх: [`AGENTS.md`](AGENTS.md).

Бэкенд отдаёт `adapterType` как целочисленный енум: `None=0, AppleStore=1, GooglePlay=2, Stripe=3, Braintree=4, Purple=5, Paddle=6` (далее могут добавляться, напр. `Comp=7`).

## Декод неизвестного значения — безопасно

`AccountSubscriptionAdapterType` (`Invoices.Apps.iOS/.../Subscriptions/AccountSubscriptionType.swift`) — Swift `enum: Int` с кастомным `init(rawValue:)`, где `default: self = .none`. Любое неизвестное значение (`7`, …) → `.none`, декод **не падает**. Плюс `@DecodableDefault` и `LossyDecodableArray` гасят сбои элементов.

**Следствие:** новое серверное значение енума для iOS = `.none`. Forward-compatible; нормализация `unknown → None` на сервере для iOS ничего не меняет (а вот для web — обязательна, см. web-док).

## Активный план без stripe/apple-адаптера (`.none`) — рендер ок, кнопки — нет

Состояние плана определяется по `isActive` (`SubscriptionServiceImpl.swift`), не по адаптеру → активный план с `.none` показывается корректно (тариф, дата). Profile прячет «Manage» для `.none` (`ProfileViewModel.swift`).

**Но** `SubscriptionInfo` (`SubscriptionInfo.swift:223-245`) ветвит `if .appleStore … else {Manage web / Upgrade AppStore}` — `.none` уходит в `else` («web-подписка»). Для активного `.none` (напр. comp/grant) показываются manage-кнопки, которых быть не должно.

**Деградация мягкая, без краша.** Тап «Manage web» (`SubscriptionInfoViewModel.didTapManageWeb()`): кэш `customerPortalLink` для `.none` = `nil` → live `GET plans/active` → `primary.customerPortalLink` тоже `nil` → `guard … else { viewState = .error }` → generic error-алерт (retry/cancel). Анврапы безопасные. Эндпоинт `users/authenticated/subscription-management-link` для не-Stripe/Paddle и так бросает `UserHasNoSubscriptionsException` (4xx) → iOS `catch` → тот же алерт.

Edge: если ранее был Stripe-саб, в кэше мог остаться **stale** portal-link → тап откроет старый портал.

**Полиш-тикет:** не показывать manage-кнопки на `SubscriptionInfo` для активного `.none` плана. Контекст — [`features/comp-plan-grants`](../features/comp-plan-grants/plan.md) / FS-1241.
