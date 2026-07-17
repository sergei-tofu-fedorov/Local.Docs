# Пропуск шага банка в Stripe-онбординге — имплементация в Invoices.Backend

Что нужно сделать, чтобы убрать шаг банковского счёта из первого захода онбординга (M4/S6), как это будет работать и что сможет/не сможет пользователь без банка. Основано на коде `Invoices.Backend` и верификации по докам Stripe (ссылки внизу). Родительский док: [README.md](README.md).

## TL;DR

- **Пользователь без банка сможет принимать оплаты и создавать payment requests** — наш гейт приёма платежей уже сегодня не смотрит на payouts: `IsDone = ChargesEnabled && DetailsSubmitted` (`StripeProvider.cs:76`), `PayoutsEnabled` в нём не участвует. Деньги будут копиться на Stripe-балансе, выплаты — заблокированы до добавления банка.
- Механизм — **embedded-only**: `features.external_account_collection=false` в Account Session. На hosted Account Links такого параметра нет → фича едет вместе с этапом 2 (embedded).
-技нически изменение маленькое (одно место в `CreateAccountSession`), но требует **апгрейда Stripe.net 47.3.0 → ≥51.0.0** (первая версия с пином API `2026-03-25.dahlia`, где `false` разрешён нашим stripe-collected аккаунтам) и **доработки статусной модели** — иначе аккаунт без банка навсегда повиснет у нас в `InformationIsRequired` с «action required»-письмами.

## 1. Механика Stripe (верифицировано)

**Разрешение**: до `2026-03-25.dahlia` `external_account_collection=false` был доступен только platform-collected (Custom) аккаунтам. Changelog ([dahlia](https://docs.stripe.com/changelog/dahlia/2026-03-25/relaxed_external_account_collection_account_session)): «Now, if Stripe is responsible for collecting requirements, you can set `external_account_collection` to false **if you also set `disable_stripe_user_authentication` to false**. The default value is still true». Т.е. нашим standard/express-подобным аккаунтам можно — при включённой Stripe-аутентификации (она у нас и так неотключаема). ⚠️ Текст в API-референсе и XML-доках Stripe.net **не обновлён** под dahlia (до сих пор пишет «only… like Custom accounts») — авторитетен changelog, не пугаться.

**Что происходит с аккаунтом без банка**:
- `external_account` — требование уровня **payouts, не card_payments** («validations aren't run against external accounts because they're only used for payouts»). `charges_enabled=true` достижим без банка; `payouts_enabled=false`; `external_account` висит в `requirements.currently_due`.
- Деньги: «Your account may continue to receive payments while payouts are paused, but you won't be able to transfer the funds» ([support](https://support.stripe.com/express/questions/what-does-it-mean-that-my-payouts-are-paused-or-my-payments-are-blocked)). Лимита суммы/срока накопления в доках нет.
- Дедлайн: фиксированного «N дней/$X для external_account» не документировано; работает общий механизм `current_deadline` — при пропуске Stripe отключает payouts (уже отключены), а charges трогает «только если аккаунт неотзывчив». Мониторить `requirements.current_deadline` (мы его уже сохраняем как `RequirementsDeadline`).
- Рефанды: списываются с available balance, банк не нужен (при недостатке — pending до пополнения баланса).
- Первая выплата: 7-дневный таймер идёт **от первого charge, не от привязки банка** ([support](https://support.stripe.com/questions/delay-for-first-payout-for-connected-accounts)) — если банк добавлен позже, накопленное уходит по расписанию без нового ожидания (инференс из формулировки, проверить на тесте).
- Instant Payouts без банка недоступны в принципе (нужен eligible external account).

**Как дособрать банк потом**: фичи задаются **на каждую Account Session** («The Create Account Session API determines component and feature access… Stripe enforces these parameters for any components that correspond to the account session»). Новая сессия с дефолтным `external_account_collection=true` снова показывает шаг банка; точечно — `requirements.only=['external_account']` (мгновенный exit без summary). `account_management`-компонент тоже умеет банк, но **на iOS его нет** (на мобильных GA только onboarding) — значит, повторный вход через тот же onboarding-компонент.

**iOS**: фича чисто серверная — клиент получает только `client_secret`, менять фичи не может; компонент рендерит форму согласно сессии. На клиенте изменений не требуется (кроме UX-обвязки).

## 2. Что меняется в Invoices.Backend

### 2.1 Апгрейд Stripe.net (пререквизит)

`Src/Tofu.Stripe/Tofu.Stripe.csproj:21` — сейчас `Stripe.net 47.3.0` (единственный PackageReference в solution; API-версия нигде не пиннится, вебхуки терпимы: `throwOnApiVersionMismatch: false`). Свойство `ExternalAccountCollection` в SDK есть с 44.1.0, но **серверная валидация привязана к API-версии запроса** → нужен Stripe.net **≥51.0.0** (пин `2026-03-25.dahlia`, [CHANGELOG](https://raw.githubusercontent.com/stripe/stripe-dotnet/master/CHANGELOG.md)). Это прыжок через 4 мажора — регресс по всем местам использования SDK: `StripeAccountClient`, `StripeTap2PayClient` (RequestOptions.StripeAccount), `WebCheckoutStripeService` (подписки платформы), `StripeEventHookMapper` (типы событий).

### 2.2 `CreateAccountSession` — сам флаг

`Src/Tofu.Stripe/StripeAccountClient.cs`, case `ComponentType.Onboarding` (сейчас `Features` не задаётся вовсе — действует дефолт `external_account_collection=true`):

```csharp
sessionComponentsOptions.AccountOnboarding =
    new AccountSessionComponentsAccountOnboardingOptions
    {
        Enabled = true,
        Features = new AccountSessionComponentsAccountOnboardingFeaturesOptions
        {
            ExternalAccountCollection = collectBank,          // false для первого захода
            DisableStripeUserAuthentication = false           // обязательное условие dahlia
        }
    };
```

- Параметр `collectBank` протащить через цепочку `StripeLinksController.GET account-session/{type}` → `PaymentsService.CreateAccountSession` (`PaymentsService.cs:95`) → `StripeProvider` → `StripeAccountClient` — например, новым значением `{type}` (`onboarding-no-bank`) или query-флагом. Повторный заход за банком = та же ручка с `collectBank=true` (дефолт).
- Соседний `NotificationBanner.Features.ExternalAccountCollection = true` (`StripeAccountClient.cs:185`) **оставить** — он про напоминания «добавьте банк», это web-only и как раз полезен для дособора.

### 2.3 Статусная модель — главная содержательная работа

Проблема: после онбординга без банка у аккаунта `charges_enabled=true, details_submitted=true`, но `currently_due=["external_account"]`. Наш текущий код (`StripeProvider.GetAuthenticationProcess`, `StripeProvider.cs:68-124`):
- `IsDone = ChargesEnabled && DetailsSubmitted` → **true** → `Enabled=true, SoftEnabled=true` → платежи включатся ✅;
- но `isInformationIsRequired = currently_due.Count > 0` → статус **`InformationIsRequired`** → `CalculateStatus` оставит `InformationIsRequired` (`PaymentsService.cs:418-447`) → `SafetySendPushAndAnalyticsByStatus` отправит **«action required»-письмо и пуш** (`PaymentsService.cs:284-351`), а `external_account` ляжет в `ConnectionErrors` и уедет клиенту через `authenticated-types` → в UI будет вечный красный статус.

Нужно:
1. В `GetAuthenticationProcess` распознать случай `currently_due == ["external_account"]` (по аналогии с существующим pattern-match на ssn_last_4/id_number) → новый под-статус вида **`ConnectedNoPayouts`** (или `Connected` + флаг) вместо `InformationIsRequired`.
2. Подавить «action required»-письмо/пуш для этого случая; вместо него — своё сообщение «подключите банк, чтобы получить выплаты» (мотивация: «$X уже ждут» — сумма есть в `GET api/payouts/balance-summary`).
3. **Прокинуть `PayoutsEnabled` в `authenticated-types` DTO** (`Mapping.cs:449-486`) — сейчас он есть только в balance-summary (`AccountsInfo.IsPayoutsEnabled`), а клиенту нужен статус «принимаю, но не выплачивается» прямо в платёжных настройках.
4. Использовать сохранённый `RequirementsDeadline` для «добавьте банк до {даты}», если Stripe его выставит.

### 2.4 Что НЕ меняется

- **Чарджи за инвойсы**: создаются внешним сервисом Tofu.Payments (gRPC `Tofu.PaymentOrders.Protos.V1`; наш `PaymentIntentsService.CreatePayment` лишь собирает order с `PspAccountId`) — от банка не зависят. Гейт кнопки «Pay» на weblink/PDF: `PaymentByCardEnabled && apt != null && total >= $1` + `apt.Enabled` (`HtmlBuilder.cs:178`, `WebLinkViewService.cs:351`, `AuthenticatedPaymentTypesExtensions.cs:19`) — банк не участвует.
- **Вебхук `account.updated`** уже делает полный re-fetch и пересчёт (`PaymentEventsService.cs:55-64` → `FinishAuthenticatePaymentType`); когда пользователь добавит банк, `payouts_enabled=true` подтянется автоматически. События `account.external_account.created/updated` тоже уже обрабатываются (`BalanceSummaryWasUpdated`).
- **Hosted-флоу** (`Authenticate`, Account Links) — не трогаем; на нём пропуск банка невозможен (нет параметра), т.е. **фича активируется только для пользователей embedded-флоу** (этап 2).

## 3. Как это будет работать для пользователя

1. Онбординг (embedded, S1–S5, S7): identity + business, **без экрана банка и без Link** (M4 решается радикально — нет шага, нет и «Save with Link»).
2. Сразу после верификации: `charges_enabled=true` → статус у нас `Connected(NoPayouts)` → пользователь **выставляет инвойсы и payment requests, клиенты платят картой** — всё работает.
3. Деньги копятся на Stripe-балансе; в приложении: «$X заработано — подключите банк, чтобы получить выплаты» (баланс уже доступен через `payouts/balance-summary`).
4. Подключение банка: тот же onboarding-компонент новой сессией с `external_account_collection=true` (или `requirements.only=['external_account']` — один экран, мгновенный exit). `account.updated` → `payouts_enabled=true` → полный `Connected`.
5. Выплата уходит по расписанию; 7-дневный таймер первой выплаты к этому моменту обычно уже истёк (шёл от первого charge).

Ограничения без банка: Instant Payouts недоступны; наш `PayoutsController.CreatePayout` вернёт ошибку (гейтится `SoftEnabled`, но Stripe отклонит без external account — обработать сообщением «сначала подключите банк»).

## 4. Риски и открытые вопросы

| Риск | Оценка |
|---|---|
| Апгрейд Stripe.net 47→51 (4 мажора) | главный технический риск; нужен полный регресс Stripe-интеграций (Tap2Pay, WebCheckout, вебхуки) |
| Внешний сервис Tofu.Payments | создаёт Checkout Sessions своим SDK/версией — проверить, что его API-версия не конфликтует с dahlia-поведением аккаунтов (скорее всего нет: фича влияет только на Account Sessions) |
| «Вечный» баланс без банка | лимит не документирован; продуктово задать свой срок эскалации напоминаний (`current_deadline` может прийти от Stripe — мониторим) |
| Пользователь игнорирует банк → злой саппорт «где деньги» | это осознанный trade-off deferred-паттерна; смягчение — пуш/баннер с суммой |
| dahlia-послабление для `account_management`/`notification_banner` | в changelog не названо — на web-баннер не полагаться, свои баннеры |
| Поведение на реальном standard-аккаунте | API-референс ещё несёт старый текст; **первым шагом — проверить на тестовом аккаунте** (создать сессию с `false` на API 2026-03-25 и пройти онбординг) |

## 5. План работ

1. **Spike (0.5–1 д.)**: тестовый аккаунт в test mode + Stripe.net 51 в песочнице → сессия с `external_account_collection=false, disable_stripe_user_authentication=false` → пройти онбординг, убедиться: банк-шага нет, `charges_enabled=true`, `currently_due=["external_account"]`, тестовый charge проходит, рефанд проходит, повторная сессия с `true` показывает банк.
2. Апгрейд Stripe.net → 51.x + регресс.
3. `CreateAccountSession`: Features + параметр `collectBank` через цепочку контроллер→сервис→клиент.
4. Статусная модель: `ConnectedNoPayouts`, подавление action-required, `PayoutsEnabled` в authenticated-types DTO, мотивационная нотификация с суммой баланса.
5. iOS/клиент: экран «подключите банк» с балансом + вход в дособор (та же ручка account-session).
6. Метрики: конверсия онбординга без банк-шага vs с ним; доля добавивших банк в 7/30 дней; накопленный невыплаченный баланс.

## Источники

[dahlia changelog](https://docs.stripe.com/changelog/dahlia/2026-03-25/relaxed_external_account_collection_account_session) · [account_sessions API](https://docs.stripe.com/api/account_sessions/create) · [payouts paused (funds accumulate)](https://support.stripe.com/express/questions/what-does-it-mean-that-my-payouts-are-paused-or-my-payments-are-blocked) · [first payout 7-day delay](https://support.stripe.com/questions/delay-for-first-payout-for-connected-accounts) · [refunds from balance](https://docs.stripe.com/refunds) · [handling verification / current_deadline](https://docs.stripe.com/connect/handling-api-verification) · [account management component](https://docs.stripe.com/connect/supported-embedded-components/account-management) · [Stripe.net CHANGELOG (51.0.0 = dahlia)](https://raw.githubusercontent.com/stripe/stripe-dotnet/master/CHANGELOG.md) · код: `StripeAccountClient.cs` (:93 PreAuth, :127 CreateAccountSession), `StripeProvider.cs:68-124`, `PaymentsService.cs:95,146,284,353,418`, `PaymentEventsService.cs:55`, `HtmlBuilder.cs:178`, `Mapping.cs:449`
