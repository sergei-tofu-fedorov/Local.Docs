# WEB-1788 — Дизайн проверки купона (coupon check)

Purpose: спроектировать единый переиспользуемый слой «резолюция + проверка применимости купона» для web-checkout, чтобы WEB-1788 (launch-купон из конфига) и существующий ios_migration (купон из URL) шли через один код. Мотивация — сейчас логика купона размазана по 3 расходящимся путям без единой проверки применимости.

Related: [README.md](README.md) (план фичи), взаимодействия с купонами в `Invoices.Backend` (BFF).

## 1. Текущее состояние (as-is)

### 1.1 Точки взаимодействия

| Роль | Где | Замечание |
|---|---|---|
| Источник (config) | `PriceConfig.CouponId`, `WebCheckoutStripeService.cs:482` | доверенный, серверный |
| Источник (state) | `IosMigrationDiscountCalculator.Calculate`, пакуется в `SubsPriceKey` (`Mapping.cs:383`) | вычисляемый из подписки |
| Транспорт | `SubsPriceKey.Encode/Parse` (`price__c=coupon`) | клиент-контролируемый |
| Trust-gate | `IosMigrationDiscountCalculator.IsValidCouponId` (regex whitelist) | только в `subscriptions` |
| Резолюция | 3 разных пути (см. 1.2) | несогласованы |
| Применение | Stripe `Coupon=` (non-Tofu) / Subs (Tofu) | `WebCheckoutStripeService.cs:142/241` |
| Чтение/показ | `_couponService.GetAsync` в `GetConfig` | `coupon.Valid` не проверяется |

### 1.2 Три расходящихся пути резолюции — корень проблемы

- `GET config`: `effectiveCouponId = couponHint ?? priceConfig.CouponId` — берёт **любой** hint из URL, без whitelist.
- `POST subscriptions` (авториз., Tofu-only): `coupon = couponOverride ?? priceConfig.CouponId`; `couponOverride` = hint **только** если прошёл `IsValidCouponId`.
- `POST create-subscription` (аноним., non-Tofu): hint **игнорируется**; купон = `priceConfig.CouponId`, и применяется **только если `!needTrialPeriod`** (купон и триал взаимоисключающи).

Следствия:
1. `config` и `subscriptions` могут разойтись: превью показывает скидку по hint, а списание её отбрасывает (hint не в whitelist) → рассинхрон цены.
2. Нет единой точки «купон применим?»: существование/валидность в Stripe (`Valid`, `redeem_by`, лимиты), применимость к цене (currency/product), применимость к контексту — нигде цельно не проверяется.
3. Trust-политика (`IsValidCouponId`) живёт статиком в `Plans`-неймспейсе и жёстко зашита под ios_migration — не переиспользуема.

## 2. Цель дизайна

Один слой, который на входе принимает (priceId, источник купона, hint, контекст), а на выходе даёт **однозначно разрешённый купон + причину**, и применяется одинаково в `config`, `subscriptions`, `create-subscription`. Разделяем два ортогональных вопроса (не схлопывать):

- **Trust / authorization** — можно ли применять *этот* купон из *этого источника* (config = доверяем; URL = только по политике).
- **Applicability / availability** — существует ли купон, валиден ли, применим ли к цене и к контексту.

## 3. Предлагаемая модель

### 3.1 Контекст и результат

```csharp
// Invoices.Core/WebCheckout/Coupons
public enum CouponSource { Config, Url, Computed }   // откуда пришёл id

public readonly record struct CouponContext(
    string PriceId,
    bool IsTofu,               // выбор Stripe-ключа (TofuSecretKey vs SecretKey)
    string? Currency,          // для amount_off купонов
    CouponSource Source);

public sealed record CouponDecision(
    string? CouponId,                       // разрешённый купон (null = без купона)
    bool Applied,
    CouponRejectionReason? Reason);         // почему отклонён/сброшен

public enum CouponRejectionReason
{
    NotAllowedFromSource,   // trust: hint из URL не прошёл политику
    NotFound,               // availability: нет в Stripe (в нужном аккаунте)
    Invalid,                // Stripe .Valid == false / expired / max redemptions
    CurrencyMismatch,
    ProductNotApplicable,
    ContextNotEligible,     // расширяемый хук (напр. состояние подписки)
    StripeError
}
```

### 3.2 Два интерфейса (trust ⟂ availability)

```csharp
// Trust-политика: per-source, per-feature. НЕ ходит в сеть.
public interface ICouponSourcePolicy
{
    bool IsAllowed(string couponId, CouponSource source);
}

// Availability: generic, ходит в Stripe (с кэшем). Переиспользуемый.
public interface ICouponAvailabilityChecker
{
    Task<CouponDecision> CheckAsync(string couponId, CouponContext ctx, CancellationToken ct);
}
```

- `ICouponSourcePolicy` реализация по умолчанию: `Config`/`Computed` → true; `Url` → делегирует в набор allow-правил. Текущий `IsValidCouponId` (ios_migration regex) переезжает сюда как одно правило `Url`-источника, а не остаётся статиком в `Plans`.
- `ICouponAvailabilityChecker` — один `CouponService.GetAsync` (ключ по `IsTofu`) + правила: `Valid`, `RedeemBy`, `MaxRedemptions vs TimesRedeemed`, `AmountOff.Currency == ctx.Currency`, `AppliesTo.Products ∋ price.Product`. Кэш с коротким TTL (купоны меняются редко; убирает лишний Stripe-вызов на каждый `config`).

### 3.3 Фасад-резолвер (единая точка вместо 3 путей)

```csharp
public interface ICouponResolver
{
    // Возвращает финальное решение: применяет trust → availability, с fallback на config-купон.
    Task<CouponDecision> ResolveAsync(
        string priceId, string? hint, CouponContext ctx, CancellationToken ct);
}
```

Алгоритм (единый для всех эндпоинтов):
1. `candidate = hint ?? priceConfig.CouponId` (hint только когда есть).
2. Если candidate из `Url` и `!policy.IsAllowed(candidate, Url)` → откат на `priceConfig.CouponId` (или без купона), reason=`NotAllowedFromSource`.
3. `availability.CheckAsync(candidate, ctx)` → если не применим, откат на `priceConfig.CouponId`/без купона с соответствующим reason.
4. Вернуть `CouponDecision`. Логировать reason (наблюдаемость вместо опаковых Stripe-исключений).

### 3.4 Расширяемость под контекст

`ContextNotEligible` — точка расширения (напр. «триал уже был» из PRD). В R1 не реализуем сам предикат состояния, но резолвер уже принимает `CouponContext`, так что добавить context-правило позже — без изменения сигнатур. Состояние подписки уже доступно в BFF (`PlansService`, `IsTrialAvailable = subscriptions.Count == 0`, `AccountSubscription.IsTrial`) — источник для будущего context-правила.

## 4. Как это использует WEB-1788 и ios_migration

- **WEB-1788 (launch-купон):** источник = `Config`, trust всегда true; резолвер+availability дают fail-fast если конфиг-купон отсутствует/истёк. Плюс startup-health-check: прогнать все `PriceConfigs[*].CouponId` через `ICouponAvailabilityChecker` при старте — ловим опечатку в конфиге до пользователя.
- **ios_migration (URL-купон):** источник = `Url`; `IsValidCouponId`-правило живёт в `ICouponSourcePolicy`; **добавляется отсутствующая сегодня** availability-проверка (реально ли `ios_migration_XX` заведён/валиден) — тот же код, что для WEB-1788.

## 5. План работ (repo: Invoices.Backend, BFF)

1. [ ] Ввести модель `CouponContext` / `CouponDecision` / `CouponRejectionReason` в `Invoices.Core/WebCheckout/Coupons`.
2. [ ] `ICouponSourcePolicy` + дефолт-реализация; перенести `IsValidCouponId` (ios_migration regex) из `IosMigrationDiscountCalculator` как `Url`-правило (оставить тонкий shim/делегат, чтобы не ломать существующие вызовы).
3. [ ] `ICouponAvailabilityChecker` в `Invoices.Implementation.Services` (Stripe-lookup по `IsTofu`-ключу + правила валидности + кэш).
4. [ ] `ICouponResolver`-фасад; переключить `GetConfig`, `CreateSubscription`, `CreateSubscriptionForAuthorizedUser` на него — убрать 3 расходящихся `?? priceConfig.CouponId`.
5. [ ] Гарантировать согласованность `config` ↔ `subscriptions`: одинаковый резолв → превью и списание не расходятся.
6. [ ] Startup-health-check конфиг-купонов (log-only warning, не падать).
7. [ ] Проброс `ICouponAvailabilityChecker` в ios_migration-путь (может быть отдельным маленьким PR — тот же порт).

## 6. Риски / caution

- **Не смешивать trust и availability** — существование купона в Stripe ≠ право применять его из URL.
- Availability = внешний вызов на горячем пути создания подписки: обязателен кэш + graceful-degradation (при `StripeError` не блокировать оплату жёстко без решения продукта).
- Купоны живут **per-Stripe-account** (`IsTofu ? TofuSecretKey : SecretKey`); чекер обязан резолвить ключ, иначе «NotFound» ложный.
- Subs-путь (Tofu) применяет купон **внутри Subs-микросервиса** — BFF шлёт id в `PaymentIntentAdapterRequest`. Проверить, дублирует ли Subs свою валидацию, чтобы не разъехались две проверки.

## 7. Open questions

- [ ] При `StripeError`/недоступности чекера на создании подписки — блокировать или применять как раньше (best-effort)? Решение продукта.
- [ ] Нужен ли `promotion_code`-слой (customer-facing коды с per-customer/min-amount ограничениями) или только `coupon`? Сейчас в коде только `coupon`.
- [ ] Согласованность `config` ↔ `subscriptions` для URL-купонов, не прошедших trust: показывать ли вообще скидку в превью, если списание её отбросит? (сейчас показывается — баг).
