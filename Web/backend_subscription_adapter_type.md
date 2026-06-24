# Web — обработка `adapterType` подписки/плана

> Как web декодирует поле `adapterType` из ответов бэкенда. **Важный контракт:** новое значение енума ломает web. Вверх: [`AGENTS.md`](AGENTS.md).

Бэкенд отдаёт `adapterType` как целочисленный енум: `None=0, AppleStore=1, GooglePlay=2, Stripe=3, Braintree=4, Purple=5, Paddle=6` (далее могут добавляться, напр. `Comp=7`).

## ⚠️ Неизвестное значение ломает ответ (Zod-reject)

`src/domain/subscription/schemas.ts` валидирует `adapterType` через **Zod `z.nativeEnum(AccountSubscriptionAdapterType)`** в `subscriptionStatusSchema` и `planSchema`, а `shared/lib/api/subscriptions/index.ts` парсит ответ через `…parseAsync`.

`z.nativeEnum` **отвергает** любое значение не из енума. Неизвестное (`7`, …) → `ZodError` → **весь ответ `plans/current` и `plans/active` не парсится** → `$currentSubscription = null` → биллинг/планы не рендерятся, ошибка в Sentry. Дополнительно `adapterTypeToString` (switch) имеет `default → absurd()`, который бросает.

**КОНТРАКТ:** бэкенд **не должен** отдавать web новые значения `adapterType` без согласованного обновления клиента. Любой внутренний адаптер вне `0..6` нормализуем на сервере в `None (0)` в client-DTO (`Invoices.Api/Models/Mapping.cs`). iOS такое переживает (см. iOS-док), web — нет.

## Активный план с `None (0)` — рендерится корректно

`None=0` входит в енум → Zod принимает. Энтайтлмент и рендер завязаны на `isActive`+`planId`, не на адаптере (`features/subscription/model/subscription.ts`, `shared/lib/ability/ability.ts`, `features/settings/ui/subscription-content`). Кнопка «Manage» гейтится на Stripe/Paddle (`subscription-management-link.ts`) → для `None` скрыта (нужное поведение для comp/grant). Битого экрана нет.

Контекст — [`features/comp-plan-grants`](../features/comp-plan-grants/plan.md) / FS-1241.
