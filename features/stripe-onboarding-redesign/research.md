# Stripe payments onboarding — редизайн флоу (FSM iOS) — исследование

Ресёрч к ТЗ `C:\Files\Stripe_payments_onboarding__редизайн_флоу_(FSM_iOS)__ТЗ.pdf`: как бэкенд может помочь редизайну Stripe Connect онбординга, что мы используем сейчас (backend + iOS), hosted vs embedded, префилл, мировые практики и статистика.

**Status:** research
**Started:** 2026-07-09
**Repos:** `Invoices.Backend` (BFF, Stripe-интеграция), `Invoices.Apps.iOS` (клиент)

---

## 1. Контекст задачи (из ТЗ)

- Проблема: только **~15%** пользователей, начавших подключение Stripe, доходят до `is_stripe_linked=true` (борд `qyubyw4i`, чарт `yhwnmxbk`). Начинаем с Invoice Maker, затем FSM iOS.
- Находки коридорного теста:
  - **C1** — нет настоящего success-экрана: «verifying»-лимб, в меню всё ещё «Activate».
  - **C2** — email уже есть в Stripe → стена «пароль + 2FA». Корневая причина: email не префиллится при создании аккаунта.
  - **C3** — SSN/DOB/адрес спрашиваются без объяснения, пользователь пугается.
  - **C4** — резкий выброс в браузер, крошечная ссылка «Return to TOFU».
  - **M1** — email вводится руками; **M2** — placeholder `www.example.com` → «Incomplete»; **M3** — product description ≥10 символов, ошибка; **M4** — «Save with Link» выглядит обязательным; **M5** — голый toggle запускает тяжёлый флоу; **M6** — окно не закрывается само.
- Предлагаемый флоу S1–S7: intro → «Before we start» (почему SSN) → bridge с ко-брендом → Stripe business details (всё префиллено) → identity → банк (Link опционален) → success «You're ready to get paid» (двухуровневый статус, никогда не показывать «Activate» после сабмита).
- Инженерные must-have из ТЗ: (1) создавать Stripe Account **с данными до первого Account Link**; (2) починить return_url/deep-link → авто-возврат и программное закрытие webview; (3) корректно обрабатывать тайминг `charges_enabled`.
- Уточнение от 2026-07-09: сайт **не** обязателен; `business_profile.url` — топ-1 непокрытое требование у застрявших аккаунтов; надёжный путь — `product_description`; слабый/фейковый URL хуже честного описания (замечены ~5 диспутов `url_inquiry.form`); требование динамическое — смотреть `requirements.currently_due`.

## 2. Что у нас сейчас

### Backend (`Invoices.Backend`)

- `Src/Tofu.Stripe/StripeAccountClient.cs`
  - `PreAuth` (:93-105) — **единственное** место создания connected-аккаунта: `Type="standard"` + `Metadata[AccountId]`, **ноль префилла** → корневая причина C2/M1/M2/M3.
  - `Authenticate` (:21-60) — Account Link, всегда `type=account_onboarding`; `CollectionOptions.Fields="eventually_due"` только при `IsCollectRequirements`, иначе дефолт (`currently_due`).
  - `FinishAuthenticate` (:62-91) — читает `ChargesEnabled`, `DetailsSubmitted`, `Requirements.*` (CurrentlyDue/EventuallyDue/PendingVerification/DisabledReason/CurrentDeadline), `PayoutsEnabled`.
  - `CreateAccountSession` (:127-203) — **embedded-половина уже написана**: Account Sessions с компонентами AccountOnboarding, Payments, Payouts, PaymentDetails, NotificationBanner.
- `Src/Invoices.Payments/Stripe/StripeProvider.cs` — refresh/return URL из Mongo `PaymentType.Items`; `GetAuthenticationProcess` (:68-124): `IsDone = ChargesEnabled && DetailsSubmitted`; AlmostDone для комбинаций ssn_last_4 / id_number / verification.document; Rejected по `disabled_reason` c префиксом `rejected`.
- `Src/Invoices.Payments/PaymentsService.cs` — `AuthenticatePaymentType` (:146-217) сегодня **не загружает** Account/Contacts/User (данных для префилла в этом месте нет — их надо протащить); статусы Unknown/InProgress/Verification/Connected/InformationIsRequired/Rejected; на переходе в Connected — пуш `PspOnboardingCompleted` + email; Amplitude-событие `PaymentAccountStatus` с prop `requirements`.
- `Src/Invoices.Api/Controllers/PaymentsController.cs` — `POST /api/payments/connections/{providertype}` (старт, флаги deleteOld/isPreConnect/isCollectRequirements); return-callback `GET /callback/payments/auth/{providertype}` (:220-243) отдаёт статическую `assets/success_onboarding.html` (крошечная ссылка на кастомную схему — источник C4/M6); refresh-callback перевыпускает линк; вебхук `POST /callback/hooks/stripe/events`.
- `Src/Invoices.Api/Controllers/StripeLinksController.cs` — `GET /api/stripe-links/{type}` (webLinkUrl) и `GET /api/stripe-links/account-session/{type}` (ClientSecret), permission `Stripe.Manage`.
- Данные для префилла уже есть в Mongo: `Account.BusinessName`, `Account.Contacts` (Name/Phone/Email/Address), `Account.Culture`, `BusinessInfo`, коллекция `BusinessProfiles` (ниша/размер команды); email/имя владельца — через gRPC в Tofu.Auth. Поля Website **нет нигде** (совпадает с уточнением ТЗ — идём через `product_description`).

### iOS (`C:\Git\Work\IOS\Invoices.Apps.iOS`)

- Единственная Stripe-зависимость — `stripe-terminal-ios` (Tap to Pay). **StripeConnect / stripe-ios не подключены** (`Tuist/Package.swift:48`).
- Онбординг сейчас: hosted Account Link в `SFSafariViewController` как child VC (`PaymentConnectionViewController.swift:42-66`); успех детектится по `url.contains(connectionData.successUrl)` в `initialLoadDidRedirectTo` (:70-76) — колбэк срабатывает только на редиректах initial load → вероятная механика M6.
- Возврат: HTTPS success-страница бэкенда → кастомные схемы `invoices://finish_stripe_connection` / `tofu://finish_stripe_connection` (`AppDelegate.swift:268-293`). Universal links — только AppsFlyer OneLink, домена Stripe нет.
- `PaymentApiImpl.swift` ходит в `POST payments/connections/{provider}`, поллит `GET payments/authenticated-types`, embedded-компоненты payouts/payments/payment-details рендерятся в голом WKWebView через `GET {provider}-links/{component}` (webLinkUrl); `PaymentComponentType.onboarding` объявлен, но **никогда не вызывается**; account-session/ClientSecret эндпоинт с клиента не используется.
- Статусы уже поддержаны клиентом: `PaymentItem.swift:49-54` декодирует inProgress/verification/connected/rejected/informationIsRequired; статус перезапрашивается на каждый `AppWillEnterForegroundMessage` (`PaymentServiceImpl.swift:85-89`).

## 3. Два варианта UI и общий префилл

> **Scope-решение: рассматриваем только hosted (Account Links) и embedded (Account Sessions + компоненты). API/custom-онбординг (`requirement_collection=application`, свои формы KYC) — НЕ вариант**: операционная сложность, платформа берёт на себя liability за отрицательные балансы и весь комплаенс; сам Stripe: «We don't recommend this option unless you're committed to the operational complexity required to build and maintain an API onboarding flow». Упоминания custom-возможностей ниже (например, `disable_stripe_user_authentication`) — только чтобы зафиксировать, чего мы осознанно НЕ получаем.

### Ключевой факт: префилл живёт в Accounts API и одинаков для обоих вариантов

Ни в Account Link, ни в Account Session KYC-поля не передаются — форма (hosted и embedded) просто читает их с объекта Account. Поэтому один и тот же код в `PreAuth` обслуживает оба этапа редизайна.

Правила окна:
- Для аккаунтов с `controller.requirement_collection=stripe` префилл возможен **только до первого** Account Link **или** Account Session — после этого identity-поля закрываются для платформы (и на запись, и на чтение). Док-цитата: «When controller.requirement_collection is stripe, you stop receiving updates for identity information after creating an Account Link or Account Session».
- До первого линка можно дозаполнять через `accounts/update`.
- SSN/DOB/адрес не префиллим (у нас их нет; комплаенс).
- Верхнеуровневый `Email` — служебный; в KYC-форму идёт именно `Individual.Email` (это и лечит C2/M1).

Целевой вид `PreAuth` (Stripe.net):

```csharp
var options = new AccountCreateOptions
{
    // выбор типа — см. развилку ниже; пример из ТЗ — express-dashboard:
    Controller = new AccountControllerOptions
    {
        StripeDashboard = new AccountControllerStripeDashboardOptions { Type = "express" },
        RequirementCollection = "stripe"
    },
    Country = "US",
    BusinessType = "individual",
    Email = contacts.Email,
    Individual = new AccountIndividualOptions
    {
        FirstName = firstName,          // из Account.Contacts
        LastName  = lastName,
        Email     = contacts.Email,     // именно этот попадает в KYC-форму
        Phone     = contacts.Phone      // E.164
    },
    BusinessProfile = new AccountBusinessProfileOptions
    {
        // Url — только если реальный; иначе не слать (уточнение ТЗ)
        ProductDescription = productDescription  // из ниши/инвойсов, ≥10 символов
    },
    Metadata = new Dictionary<string, string> { { "AccountId", accountId } }
};
```

Данные надо протащить в `StripeAccountRequest` через `PaymentsService.AuthenticatePaymentType` (Account/Contacts + user из Tofu.Auth).

### Вариант A — hosted (Account Link), этап 1

- Аккаунт с префиллом → `POST /v1/account_links` (`type=account_onboarding`, HTTPS return/refresh); `collection_options` задаются **на сервере в линке**.
- Линки одноразовые, живут минуты, «съедаются» превью-ботами мессенджеров — никогда не слать по email/SMS, перевыпускать по refresh_url.
- Фиксы на нашей стороне: авто-редирект в `success_onboarding.html` на кастомную схему + честный success/verifying экран в приложении (C1/C4/M6).

### Вариант B — embedded (Account Session + StripeConnect iOS SDK), этап 2

- Тот же префилленный аккаунт → `POST /v1/account_sessions` (наш `CreateAccountSession` уже умеет) → `ClientSecret` клиенту.
- iOS: `StripeConnect` SDK — **GA с 24.15.0 (2025-06-02)** (проверено по CHANGELOG stripe-ios); iOS 15+, требует `NSCameraUsageDescription`. Технически это WKWebView-обёртка над удалённо загружаемым ConnectJS, не нативный UI. `EmbeddedComponentManager → createAccountOnboardingController(collectionOptions:) → AccountOnboardingControllerDelegate.accountOnboardingDidExit`. Тюнинг внешнего вида (appearance, кастомные шрифты через `CustomFontSource`).
- `collection_options` в embedded задаются **на клиенте**; плюс только в embedded есть гранулярные `requirements.exclude/only` («useful when you want to prefill information that you don't want the connected account to access during onboarding»).
- C4/M6 исчезают как класс (нет браузера и return_url). Но **стену логина Stripe (C2) embedded не убирает**: при `requirement_collection=stripe` auth-попап неотключаем и не тюнится; его лечит только префилл `individual[email]`. Полное отключение (`disable_stripe_user_authentication`) доступно только custom-like аккаунтам (`requirement_collection=application`, dashboard `none`) — с переносом ответственности за отрицательные балансы на платформу.

### Развилка по типу аккаунта

- Сейчас создаём `Type="standard"`; curl из ТЗ — `controller[stripe_dashboard][type]=express` + `controller[requirement_collection]=stripe`.
- `controller.stripe_dashboard.type` **перманентен** для аккаунта — сменить нельзя, выигрывают только новые аккаунты.
- Продуктовое решение до имплементации: остаёмся на standard-дашборде или переходим на express для новых подключений.

## 4. Статусная модель (C1)

- `details_submitted=true` ≠ готов; готовность = `charges_enabled && details_submitted`; верификация — «minutes or hours».
- `requirements` динамический: `currently_due` / `past_due` / `pending_verification` / `disabled_reason` / `current_deadline`.
- Двухуровневый статус из ТЗ ложится на наши существующие статусы (InProgress/Verification/Connected/InformationIsRequired/Rejected) — клиент их уже декодирует; главное — не показывать «Activate» после сабмита и добавить экран «verifying, обычно до N минут» + пуш `PspOnboardingCompleted` уже есть.

## 5. Веб-ресёрч: как индустрия решает проблему

_(заполняется — параллельный ресёрч: форумы/комьюнити, официальные best practices и статистика, полный перечень рычагов по шагам)_

### 5.1 Официальные best practices и статистика

**Выбор конфигурации** ([docs: onboarding](https://docs.stripe.com/connect/onboarding)):
- Stripe рекомендует hosted или embedded: «We recommend using Stripe-hosted onboarding or Embedded onboarding. These options automatically update to handle changing requirements». API-онбординг: «We don't recommend this option unless you're committed to the operational complexity».
- Hosted/embedded поддерживают new-country support и legal-entity sharing, API — нет.

**Правила префилла** ([hosted-onboarding](https://docs.stripe.com/connect/hosted-onboarding), [marketplace/onboard](https://docs.stripe.com/connect/marketplace/tasks/onboard)):
- «Prefill any account information **before generating the Account Link** because you can't read or write information for the connected account afterward».
- Поведение формы: «The Connect onboarding flow **doesn't ask** your connected account for any information that you prefilled. However, it does ask the connected account to **confirm** the prefilled information before they accept the Connect service agreement» — юзер может отредактировать любое префилленное поле.
- Stripe сам рекомендует префиллить `business_profile.url`, а если сайта нет — `business_profile.product_description` (ровно наш случай, совпадает с уточнением ТЗ).
- `return_url` ≠ завершение: «It doesn't mean that all information has been collected, or that there are no outstanding requirements» — после редиректа обязательно перечитать account (или ловить `account.updated`), иначе метрика конверсии врёт.
- Account Link одноразовый, живёт минуты; «Don't email, text, or otherwise send account link URLs outside of your platform application».
- `controller.stripe_dashboard.type` перманентен: «To change a connected account's dashboard, you must create a new Account object».

**collection_options**:
- Up-front = `fields=eventually_due` (один заход, нет последующих payout-блокировок, «exposes potential risk early»); incremental = `currently_due` (дефолт embedded: `{fields:'currently_due', futureRequirements:'omit'}`) — «accounts can onboard quickly because they don't have to provide as much information».
- `future_requirements=include` — чтобы не возвращать пользователя при смене регуляторики; **только для platform-collected аккаунтов** (подтверждено докой) — в нашей конфигурации недоступен.
- Только в embedded: `requirements.only` (ремедиация конкретного требования; «the account onboarding component exits immediately» если всё уже дано, без summary-шага; wildcard вида `owners.address.*`) и `requirements.exclude` (прячет поле из формы, «it doesn't remove information requirements» — годится только для префилленного).

**Funnel-аналитика — только в embedded**: `setOnStepChange` → `{step}` с именами шагов (`stripe_user_authentication`, `business_type`, `business_details`, `representative_details`, `external_account`, `summary`, `terms_of_service`, `risk_intervention`, …). Каветы: «Steps can appear in any order and can repeat», «The list of valid step names can change at any time, without notice» — только для аналитики, не для логики. В hosted funnel-телеметрии нет вообще.

**Networked onboarding** ([docs](https://docs.stripe.com/connect/networked-onboarding)) — переиспользование верифицированной legal entity между Stripe-аккаунтами (синкаются business_type/country/company/individual; разово копируются external_accounts/business_profile/branding). **Включён по умолчанию**; отключается в Dashboard (только для новых аккаунтов). Это ближайший родственник «Save with Link» (M4): прямой связки Link↔onboarding в доках нет; управляемые точки — `external_account_collection=false` (embedded, отключает сбор банка целиком) и настройка метода сбора банка (Financial Connections vs manual) в Dashboard.

**Статистика (всё, что реально существует)**:
- **+5.3%** среднего прироста конверсии — редизайн Express-онбординга ([Stripe blog, 24.06.2019](https://stripe.com/blog/connect-express-onboarding)): progress bar, крупные мобильные поля, больше брендинга платформы, real-time валидация, доступность, локализация. **+17% у Qwick** — цитата из того же поста («The new UI helped us increase onboarding conversion by 17%»). Других официальных цифр конверсии Connect-онбординга Stripe не публиковал.
- Индустриальный фон: **68%** европейских потребителей бросали финансовый онбординг (Signicat «Battle to Onboard» 2022, 7600 респондентов, 14 стран; среднее время до отказа ~19 мин; 38% — из-за отсутствия документов под рукой). Stripe resources про crypto-IDV: «up to 70% of potential users abandon»; рекомендации — микрокопия («Takes under 2 minutes»), дробление форм, progress bar.
- Кейсы DoorDash/Instacart/Lyft/Shopify/Jobber/Housecall Pro с цифрами именно onboarding-конверсии — **не существуют** (проверено). «Active users of embedded components more than tripled in the past year» — [Stripe blog, 04.12.2025](https://stripe.com/blog/analyzing-how-saas-platforms-are-shipping-payments-and-finance-products-in-days): это **adoption-метрика Stripe** (число платформ, активно использующих embedded components, за 12 мес.), не конверсия и не цифра Squarespace — Squarespace/DoorDash/FreshBooks там лишь перечислены как примеры («platforms such as…»). Полезное из того же поста: FreshBooks использует account-onboarding компонент в 160+ странах с авто-локализацией; Cloudbeds сократил онбординг отелей «с недель до часов»; платформы **in-person индустрий принимают embedded вдвое чаще медианы** (наш сегмент); 71% платформ кастомизируют тему компонентов.

**Конкуренты (фрейминг)**: Adyen for Platforms — hosted onboarding как рекомендованный вариант, гайдлайны прямо про снижение drop-off, большинство платформ выбирает upfront-верификацию; PayPal Multiparty — Partner Referrals API тоже префиллит форму, фирменный приём — «onboard after payment» (продавец начинает продавать до полного KYC); Square — платформенного onboarding-as-a-service нет (OAuth к готовому аккаунту).

### 5.2 Фидбек разработчиков (форумы, GitHub, комьюнити)

_Оговорка по методу: Reddit и insiders.stripe.dev недоступны для краулинга — оттуда только сниппеты; HN через Algolia API; GitHub/Bubble/vendor-блоги прочитаны напрямую._

**Drop-off реален и болезненен**:
- Маркетплейс публично откатился с Connect на PayPal из-за онбординга: «users (esp casual sellers) found their onboarding so intimidating that we lost signups» ([HN 44183145](https://news.ycombinator.com/item?id=44183145), 2025). Второй паттерн — продавцы вовсе отказываются проходить Stripe-онбординг, и платформа прячет их под своим аккаунтом с ручными выплатами ([HN 33144275](https://news.ycombinator.com/item?id=33144275)).
- Вендоры deferred-onboarding-решений описывают то же: «10-15 minute compliance form BEFORE they can sell anything… Most drop off. They haven't made money yet» ([Prometora](https://www.prometora.com/learn/stripe-for-marketplaces), мотивированный источник).

**Verification-лимб — главный саппорт-бремя** (наш C1 — общеотраслевая боль):
- Restricted/pending без понятной ремедиации + циркулярный саппорт («платформа → скажите продавцу написать в Stripe → Stripe → обратитесь к платформе») — [Bubble forum 333906](https://forum.bubble.io/t/stripe-connected-accounts-restricted/333906); рабочий приём оттуда — перевыпуск линка с `collect=currently_due`, чтобы форма показала ровно недостающее.
- Задокументированная гочча: **неактивные аккаунты могут висеть в Pending бесконечно** — Stripe придерживает верификацию аккаунтов без активности ([handling-api-verification](https://docs.stripe.com/connect/handling-api-verification)).
- Продакшен-платформы держат готовые саппорт-плейбуки по застрявшим: у [Posh](https://support.posh.vip/en/articles/11647252-stripe-onboarding-101-common-roadblocks-fixes) топ-блокеры — битый/нерелевантный сайт, банк на другое имя, нечитаемые фото ID; соцпрофиль принимается вместо сайта «as long as it clearly represents your business».

**SSN-страх (наш C3) — настолько типовой, что платформы шьют объяснялки**: pre-handoff страницы «Why does Stripe need my SSN?» ([Givebacks](https://support.givebacks.com/en/articles/11185166-why-does-stripe-need-my-social-security-number-and-ein), Posh) — дешёвая, массово принятая мера; ровно наш экран S2. Факты для копирайта: US individual — имя/DOB/последние-4 SSN; полный 9-значный SSN — только после **$500K** lifetime volume ([support](https://support.stripe.com/questions/date-of-birth-and-social-security-number-(ssn)-requirement-for-us-stripe-accounts)).

**Хрупкость Account Links (подтверждение нашего анализа)**: одноразовые, TTL минуты, убиваются кнопкой «назад» и превью-ботами мессенджеров («many clients automatically visit links, which causes an Account Link to expire»); `return_url` «only means the flow was entered and exited properly» — все продакшен-интеграции сходятся к паттерну `account.updated` webhook + флаги `charges_enabled`/`currently_due` ([dev.to](https://dev.to/ddm4313/creating-a-marketplace-with-stripe-connect-the-onboard-process-22cj), [cjav.dev](https://www.cjav.dev/articles/stripe-connect-onboarding-with-ruby-on-rails)).

**Стена логина/2FA (наш C2)**: прямые треды в основном на Reddit (недоступен), но подтверждено первоисточниками: существование саппорт-страниц [«two-step authentication requirement»](https://support.stripe.com/questions/two-step-authentication-requirement) / «Can't complete two-step authentication»; networked onboarding — собственный ответ Stripe на эту боль (Sessions-маркетинг: existing-Stripe юзеры «can onboard onto your platform in one click»). Бонусная гочча ([HN 41431251](https://news.ycombinator.com/item?id=41431251)): брошенный полу-онбордженный Express-аккаунт продолжает слать пользователю письма, и удалить его может **только платформа** через API — аргумент за наш `deleteOld`-флоу.

**Embedded — рекомендуемый фикс, но с шероховатостями на краях**:
- [connect-js #124](https://github.com/stripe/connect-js/issues/124): первый шаг (email+phone) вопреки докам открывал **новую вкладку с hosted-UI**; [react-connect-js #93](https://github.com/stripe/react-connect-js/issues/93): тот же попап блокируется браузером. Это web-ConnectJS (2024); для нашего iOS-кейса аналог — проверить поведение auth-шага внутри `AccountOnboardingController` на пилоте.
- Агентства оценивают embedded нетто-положительно vs самописный Custom-флоу: авто-обновление комплаенса, тема, мобильная адаптивность ([Echobind](https://echobind.com/post/simplifying-stripe-connect-with-embedded-components)).

**Мобильный флоу — слабейшее звено у всех**:
- Hosted onboarding **запрещён в webview**: «Stripe-hosted onboarding is only supported in web browsers. You can't use it in embedded web views inside mobile or desktop applications» ([docs](https://docs.stripe.com/connect/hosted-onboarding)) — наш `SFSafariViewController` легален (это system browser), но голый WKWebView был бы нарушением.
- Live-mode Account Links отвергают кастомные схемы в return_url ([stripe-react-native #1188](https://github.com/stripe/stripe-react-native/issues/1188)) — все проходят через HTTPS-трамплин, как у нас; запрос нативного онбординга в RN SDK открыт с 2022 ([#842](https://github.com/stripe/stripe-react-native/issues/842)). У iOS-нативного SDK преимущество: сниппет insiders про «private beta» мобильных компонентов устарел — по CHANGELOG stripe-ios SDK GA с 2025-06-02 (см. раздел 3).

**Deferred onboarding — широко используемый паттерн индустрии (но без опубликованных A/B-цифр)**: минимальный connected-аккаунт сразу, продавец начинает работать, полный KYC триггерится, когда появились реальные деньги: «You have $240 waiting. Complete onboarding to receive your payout» (Prometora, [greenmoov](https://greenmoov.app/articles/en/stripe-connect-for-marketplace-payments-explained-account-types-onboarding-and-pricing-2026-guide)). Доказательная база — косвенная, но весомая: ставки продуктами у трёх платёжных гигантов — [PayPal «Onboard Sellers After Payment»](https://developer.paypal.com/docs/multiparty/seller-onboarding/after-payment/) (продавец принимает деньги до создания PayPal-аккаунта, 30 дней на онбординг), пороговая модель самого Stripe ($600/30 дней), Shopify Payments с 2019 ([HN 19469140](https://news.ycombinator.com/item?id=19469140)); плюс вендоры, продающие это как продукт ([Dots Onboard](https://usedots.com/platform/onboard/)). Прямого замера «upfront vs deferred» никто не публиковал. Контрсторона: паттерн переносит трение в момент, когда деньги уже зависли, — продавцы Shopify жалуются на пост-фактум ID-запросы с заморозкой выплат ([GETTRX](https://www.gettrx.com/shopify-uses-payments-ecommerce-sellers-hostage/)), а Adyen отмечает, что большинство платформ выбирает upfront-верификацию, чтобы не дёргать пользователя позже. Для нас безопасная часть паттерна — «предложить подключение в момент, когда клиент готов платить инвойс», а не голым toggle (M5).

### 5.3 Полный перечень рычагов по шагам флоу

_Всё ниже — для нашей конфигурации `controller.requirement_collection=stripe` (custom/API-онбординг вне scope). Помечено UNVERIFIED то, что не подтверждено доками/исходниками._

#### Шаг 0 — создание аккаунта (`POST /v1/accounts`)

- `controller`-комбинации ([migrate-to-controller-properties](https://docs.stripe.com/connect/migrate-to-controller-properties)): Standard = `losses=stripe / fees=account / requirement_collection=stripe / dashboard=full`; Express = `losses=application / fees=application_express / requirement_collection=stripe / dashboard=express`. `dashboard=full` жёстко форсит «чистый Standard»; `requirement_collection=application` несовместим с dashboard full/express (поэтому custom и не совместим с нашим scope).
- `country`, `business_type=individual` (после первого линка/сессии `business_type` заперт), `email`, `default_currency`, `settings.payouts.schedule` (`daily`(default)/`weekly`/`monthly`/`manual`).
- С `requirement_collection=stripe` Stripe **будет** слать письма аккаунту (отключение консента — только у application) — источник гоччи с письмами брошенным аккаунтам (см. 5.2).

#### Шаг 0.5 — префилл (до первого Account Link ИЛИ Account Session)

- Разрешено префиллить **всё**: «You can prefill any account information, including personal and business information, external account information, and so on» ([express-accounts](https://docs.stripe.com/connect/express-accounts)). Группы: `business_profile` (mcc, name, url, product_description, support_*, estimated_worker_count, annual_revenue), `individual` (имя, email, phone, dob, address, ssn_last_4, id_number, verification.document, …), `company` (…), `external_account` (**токен банка `btok_` или дебетовой карты** — можно пред-прикрепить банк), `business_type`, `settings.payouts.*`.
- Окно: identity-поля (`individual`, `company`, `business_type`, `external_account`, `tos_acceptance`) закрываются при первом линке/сессии; `business_profile`, `metadata`, `settings` остаются записываемыми всегда.
- Поведение формы: префилленное **показывается на подтверждение, не скрывается молча**, юзер может отредактировать; уже **верифицированные** поля повторно не спрашиваются («if the dob is already verified, you don't need to provide it again unless it changes»).
- Пред-прикреплённый банк-токен: покрыт общим правилом «doesn't ask for any information that you prefilled», но префилленное остаётся на финальном confirm-экране — полный «невидимый» пропуск банковского шага в доках не заявлен.
- MCC можно префиллить; заново не спрашивается (общее правило префилла), но отдельного заявления «prefilled MCC ⇒ industry-picker пропадает» в доках нет.

#### Шаг 1A — hosted: `POST /v1/account_links`

- `type`: только `account_onboarding`; **`account_update` недоступен** для аккаунтов со Stripe-дашбордом («You can't create them for accounts that have access to a Stripe-hosted Dashboard») — правки данных юзер делает в своём Stripe/Express Dashboard.
- `collection_options.fields = currently_due`(default)`|eventually_due`; `future_requirements=include` — **подтверждено докой: только для platform-collected** («For connected accounts where you're responsible for requirement collection…») — нам недоступен; поведение при передаче для stripe-collected (ошибка или игнор) не задокументировано.
- `refresh_url` (перевыпуск линка) / `return_url` (HTTPS в live; «It doesn't mean that all information has been collected»); одноразовость; TTL — официально только «a few minutes» (в примере API-референса `expires_at - created = 300s`, но числа-контракта нет).
- Параметра locale в Account Links **нет** (проверено по полному списку параметров API) — форсировать язык платформа не может; сам механизм выбора языка (Accept-Language vs страна) не документирован. Кастомный домен **невозможен** — всегда `connect.stripe.com` (custom domain есть только у Checkout/Payment Links/customer portal, [support FAQ](https://support.stripe.com/questions/custom-domain-on-stripe-hosted-surfaces-faq)).
- **Запрещён в webview**: только настоящий браузер (наш `SFSafariViewController` = system browser, ок; голый WKWebView — нарушение).

#### Шаг 1B — embedded: `POST /v1/account_sessions` + компонент

- Сервер: `components.account_onboarding.enabled=true`; features:
  - `external_account_collection` (default true). **Ключевая новинка — changelog `2026-03-25.dahlia`**: для Stripe-collected аккаунтов теперь можно `false` (пропустить шаг банка), если `disable_stripe_user_authentication=false` ([changelog](https://docs.stripe.com/changelog/dahlia/2026-03-25/relaxed_external_account_collection_account_session)). Раньше — только application.
  - `disable_stripe_user_authentication` — для нас **невозможен** («This value can only be true for accounts where controller.requirement_collection is application»): стена логина Stripe остаётся, лечится только префиллом email.
- `client_secret` истекает; ConnectJS/iOS SDK сами перезапрашивают через `fetchClientSecret` — эндпоинт должен всегда минтить свежую сессию.
- Клиентские опции (web `setCollectionOptions` / iOS `AccountCollectionOptions`): `fields`, `futureRequirements`, `requirements.only/exclude` (гранулярный скоуп; `only` — ремедиация одного требования без summary-шага; `exclude` — спрятать префилленное из формы). **iOS поддерживает only/exclude — подтверждено по исходникам `Models/AccountCollectionOptions.swift`**, хотя на doc-странице не описано. **Разрешены и для наших stripe-collected аккаунтов — подтверждено**: раздел «Requirements collection options» не привязан к `requirement_collection`, и в доках есть прямой Express-пример («For Express accounts, if you want to exclude the business_type requirement…»). Нельзя менять после первого рендера.
- Кастомные ToS/privacy URL и skip-ToS — только для application-collected (вне scope).
- Тюнинг: web — `appearance.variables` (десятки переменных: цвета, кнопки, бейджи, типографика) + `overlays: dialog|drawer`, CSS-переопределения не поддерживаются; iOS — `EmbeddedComponentManager.Appearance` (colors как UIColor c dynamic-provider → тёмная тема, typography, `CustomFontSource`), у дефолтной темы **нет** dark-mode цветов. Auth-попап/webview **не темится никогда** — там брендинг из Connect settings.
- Локаль: web — параметр `locale` (47 локалей, default язык браузера); iOS — локаль устройства, оверрайда нет (UNVERIFIED).
- Коллбэки: web — `setOnExit` (обязательный), `setOnLoadError`, `setOnStepChange` (35 документированных имён шагов: `stripe_user_authentication`, `business_type`, `business_details`, `representative_details`, `external_account`, `summary`, `terms_of_service`, `risk_intervention`, …); **iOS — только `accountOnboardingDidExit` и `didFailLoadWithError`, аналога onStepChange нет** (проверено по исходникам master 2026-07) → пошаговую воронку на iOS нативно не собрать, только диффы `requirements` до/после.

#### Брендинг

- Dashboard → Connect settings: имя, цвет, иконка — **обязательны** для hosted; показываются в шапке hosted-формы и в auth-попапах embedded. Public details (statement descriptor, support-контакты) — отдельная настройка.
- Embedded = «highly themeable with limited Stripe branding»; hosted = «Stripe-branded with limited platform branding». Фраза «\<Platform\> partners with Stripe» наблюдается в UI, но точная формулировка в доках не зафиксирована (UNVERIFIED).

#### Пост-сабмит / верификация

- Семантика `requirements`: `currently_due` (дедлайн `current_deadline`, иначе → `past_due`), `eventually_due`, `pending_verification` («Unsuccessful verification moves a requirement to eventually_due, currently_due, alternative_fields_due, or past_due»), `alternatives[]` (альтернативные пути закрытия), `errors[] = {requirement, code, reason}` — `reason` это готовый текст ремедиации для UI (коды: `invalid_url_*`, `verification_document_not_readable`, `verification_failed_name_match`, …).
- `disabled_reason` enum: `requirements.past_due`, `requirements.pending_verification`, `under_review`, `rejected.*`, `platform_paused`, …
- Вебхуки: `account.updated` (основной), `person.updated`, `capability.updated` (статусы `active|pending|inactive|unrequested`).
- Правило повторного входа: «Send a connected account back through onboarding when it has any currently_due or eventually_due requirements. You don't need to identify the specific requirements» — форма сама знает, что собрать.
- Экран «на проверке» — всегда на нашей стороне (`details_submitted && pending_verification≠∅`); в embedded-web новые требования авто-всплывают компонентом `notification_banner`. **На iOS SDK компонента notification_banner НЕТ** (опровергнуто по [supported components, mobile](https://docs.stripe.com/connect/supported-embedded-components)): на мобильных GA — только account onboarding; payments/payouts — public preview; notification banner / account management отсутствуют → статусные баннеры на iOS делаем сами (клиент уже декодирует наши статусы).
- Гочча: неактивные аккаунты могут висеть в Pending бесконечно (Stripe придерживает верификацию до появления активности).

#### Банк / выплаты

- Пред-прикрепление `external_account=btok_...` при создании (до первого линка/сессии).
- Пропуск шага банка: embedded — `external_account_collection=false` (с dahlia доступно и нам); hosted — только Dashboard-настройки external accounts (debit cards allowed?, require ≥1 bank account?, метод сбора: Financial Connections vs manual, **Link-тоггл**). Про Link-тоггл документировано лишь, что он управляет участием Link в Financial Connections внутри hosted/embedded онбординга («Enable your accounts to authenticate in fewer steps by reusing bank account details they've saved to Link», Accounts v1) и бесплатностью верификаций; обещания «выключил — промпт Save with Link исчез» в доках нет (UNVERIFIED — проверять на тестовом аккаунте).
- `settings.payouts.schedule.interval=manual` задаётся платформой; в Express Dashboard видимость payout-контролов управляется платформенными фичами («Your platform sets the payout schedules available to you»; «If you don't see the Pay out button, your platform hasn't enabled this feature»), но «manual ⇒ payout-UI скрыт» нигде не утверждается (UNVERIFIED).

#### Итоговая матрица: рычаг → hosted → embedded web → embedded iOS

| Рычаг | Hosted | Embedded web | Embedded iOS |
|---|---|---|---|
| Префилл до первого линка/сессии | ✔ | ✔ | ✔ |
| `collection_options.fields` | ✔ (в линке) | ✔ (клиент) | ✔ (клиент) |
| `requirements.only/exclude` | ✖ | ✔ | ✔ (по исходникам) |
| Пропуск шага банка (`external_account_collection=false`) | ✖ (только Dashboard-настройки) | ✔ (с 2026-03-25.dahlia) | ✔ (тот же серверный флаг) |
| Отключение Stripe-логина | ✖ | ✖ (только application) | ✖ (только application) |
| Темизация | ✖ (имя/цвет/иконка) | ✔ appearance | ✔ Appearance (auth-webview — нет) |
| Локаль-оверрайд | ✖ | ✔ `locale` | ✖ (локаль устройства) |
| Воронка по шагам (`onStepChange`) | ✖ | ✔ (35 шагов) | ✖ |
| `notification_banner` (авто-баннер новых требований) | n/a | ✔ | ✖ (на мобильных GA только onboarding; payments/payouts — preview) |
| Exit/error коллбэки | через return/refresh_url | ✔ | ✔ |
| `type=account_update` (правка данных) | ✖ (юзер идёт в свой Dashboard) | n/a — компонент сам дособирает | n/a |
| Кастомный домен | ✖ (`connect.stripe.com`) | свой по построению | свой по построению |

### 5.4 Кто как делает: крупные платформы (подтверждённые кейсы)

_Только то, что подтверждено публичными источниками; NOT FOUND-компании опущены (Faire, Glovo — нулевой публичный след; Uber/Airbnb/Etsy/Toast/StockX/Poshmark — Connect для онбординга НЕ используют)._

**Hosted-редирект на масштабе — живой мейнстрим:**
- **Substack** (50k+ платных изданий) — сильнейший публичный эндорсмент hosted: «We haven't had to change the Connect Onboarding code for the past four years»; «we don't have to worry about… adding an extra step because the rules changed — those updates are built in» ([case study](https://stripe.com/customers/substack)). Флоу из их help-центра: кнопка «Connect with Stripe» → редирект → возврат → toggle «Enable payments»; в мобильном приложении — тот же редирект. Плюс пре-хендофф коучинг: предупреждают, что домашний адрес попадёт на receipts (советуют virtual mailbox).
- **Kickstarter** — hosted с явным «Continue to Stripe» и коучингом до передачи: «данные должны точно совпадать с гос. документами — опечатки — причина №1 провала верификации»; hosted+KYC позволил вырасти с 5 до 25 стран ([case study](https://stripe.com/customers/kickstarter), [help](https://help.kickstarter.com/hc/en-us/articles/115005139673)).
- **Kajabi** — hosted onboarding + embedded-компоненты для in-platform фич; фазовый запуск (сначала IA/навигация платежей, потом alpha по waitlist, потом launch) дал «10% conversion uptick»; доклад [Sessions 2024 «Lessons from 13,000 platforms»](https://stripe.com/sessions/2024/lessons-from-13-000-platforms).

**Embedded / white-label — куда движутся SMB-платформы:**
- **FreshBooks** (ближайший к нам продукт; embedded с апреля 2024) — эталонный референс: «We can use Stripe's embedded components to provide a single consistent experience»; «we gain learning without having to do a full API build first»; онбординг «within minutes», пользователь «doesn't leave the FreshBooks platform at any point» ([case study](https://stripe.com/customers/freshbooks)). После growth-воркшопа со Stripe: +22% использования Instant Payouts за 30 дней, +9% retention, +31% revenue.
- **Squarespace** — публичный пример миграции **Standard-OAuth → white-label** (2023, «Squarespace Payments»); оба флоу до сих пор задокументированы в их help-центре.
- **Wix, Lightspeed** — white-label на Connect (Lightspeed: переезд с легаси-payfac за 3 месяца).

**Gig/маркетплейсы (Express + отложенный KYC):**
- **Lyft, DoorDash, Whatnot, Depop** — Express; у DoorDash вход по email-приглашению в Stripe Express; типовой сбой — расхождение данных в Stripe и у платформы → эскалация в саппорт.
- **Depop** — публичный пример «sell first, KYC before payout»: деньги копятся в Depop Balance, верификация+банк запрашиваются пушами уже после первой продажи.
- **Instacart**: «Connect lets us seamlessly onboard merchants, pay shoppers and provide KYC and security» (Payments Partnerships Lead).

**Наша ниша (FSM/beauty/бронирование):**
- **Housecall Pro** — прямой FSM-конкурент, на Stripe: payments → Capital (2022) → Issuing/Treasury (2023) → mobile check deposits (2024), «4x рост вовлечения в финтех-продукты за 4 года» ([case study](https://stripe.com/customers/housecall-pro)); деталей флоу онбординга публично нет.
- **Booksy** — KYC «в приложении Booksy» как пререквизит платёжных фич; **97% провайдеров онбордятся без участия человека**; миграция десятков тысяч аккаунтов за ночь с 97% успеха; верификация «обычно мгновенно, до 24ч» ([case study](https://stripe.com/customers/booksy)).
- **GlossGenius**: «Stripe Connect is really great in onboarding merchants and letting them create their own experiences» (90k+ бизнесов); **SQUIRE** — Tap to Pay для барберов «за минуты».
- **Mindbody** — минус 80% ручных ревью онбординга через автоматизацию риск-проверок ([Coris](https://www.coris.ai/blogs/mindbody-reduces-manual-smb-onboarding-by-80-in-45-countries)).

**Свежее от Stripe (Sessions 2025)**: **1 из 6** пользователей, регистрирующихся на платформе, уже имеет Stripe-аккаунт; networked onboarding превращает это в «3 клика» и приём платежей в тот же день — прямо релевантно нашему C2.

**Выводы уровня «что копировать»:**
1. Не пересобирать KYC-форму — вкладываться в то, что вокруг неё (форма Stripe уже конверсионно-оптимизирована; +5.3% дал именно редизайн формы самим Stripe).
2. Explainer-до-хендоффа — универсальный паттерн (Kickstarter, Substack): самый высоколевереджный копирайтинг — предупреждение «данные должны совпадать с документами».
3. Instant Payouts — главная морковка активации, выносить «get paid same day» на входной экран (Lyft: 40% выплат за 6 мес.; FreshBooks: +22/+9/+31%).
4. KPI, который стоит завести: **% онбордингов без касания саппорта** (Booksy: 97%).
5. Ни одна компания не публикует свою воронку drop-off — единственные публичные конверсионные цифры остаются стайповскими (+5.3%/+17%/Kajabi +10%).

### 5.5 Прямые конкуренты (FSM/инвойсинг): как у них устроен payments-онбординг

_Оговорка: Zendesk-хелпы Jobber/Workiz/FreshBooks/Invoice2go отдают 403 на краулинг — цитаты из поисковых сниппетов их же статей. Тип Connect-аккаунта (Express vs Custom) публично не подтверждён ни у кого._

| Конкурент | Провайдер | Флоу | Заявленное время | Approval / 1-я выплата |
|---|---|---|---|---|
| **Jobber** | Stripe Connect | redirect на Stripe-hosted form из Settings; ACH ON по умолчанию | «under 15 minutes» | charge сразу; 5 b.d. авторизация, 1-й payout до 7 дн. |
| **Housecall Pro** | Stripe (Connect+Capital+Issuing+Treasury) | in-app «My Money → Set up payments» (+ с мобилы); карты только через них | «just a few minutes» | статус-баннер «Review Info» в аккаунте; 1-й payout до 7 b.d. |
| **ServiceTitan** | **Adyen** | sales-assisted: survey → договоры → hosted Adyen portal + PCI questionnaire | не заявлено | email после верификации |
| **Workiz** | Stripe + Adyen | in-app визард: **банк → тип бизнеса → identity/docs** | review «within a few minutes» | «no longer than two business days» |
| **ServiceM8** | Stripe | add-on → Stripe-hosted (новый или существующий аккаунт) | — | 1-й payout 7–14 дн. |
| **FreshBooks** | **Stripe embedded** (ex-WePay) | полностью in-app white-label | «within minutes» | (WePay-эра: плати сразу, KYC за 90 дней) |
| **QuickBooks** | свой (Intuit) | заявка + андеррайтинг с credit check | — | 1–3 b.d. по email |
| **Wave** | свой (payfac) | отдельная заявка, identity + credit review | — | не гарантирован |
| **Invoice2go** | BILL (ex-Stripe) | in-app «a few details» | — | «within 24 hours» |
| **Square Invoices** | свой (Square) | KYC зашит в signup самого аккаунта | минуты | same-day у большинства |
| **Joist** | PayPal или Stripe (ex-WePay) | 7-шаговый Stripe-флоу из Payments section | «a few minutes» | донабор по email |
| **HoneyBook** | Stripe (embedded white-label) | **нативные in-app формы с ветвлением по типу бизнеса**; клиенты могут платить до подключения банка | верификация «just a few minutes» | минуты |
| **Markate** | свой аккаунт юзера (Stripe/Square/PayPal/Authorize.net) | OAuth-connect, только desktop | — | на стороне провайдера |
| **Thumbtack** | Stripe (payouts) | direct deposit в 2 шага; прогрессивный KYC после ~$10k (UNVERIFIED) | минуты | мгновенно до порога |

Детали, важные для нашего дизайна:
- **Jobber** держит отдельную статью [«Why is my Info Required for Jobber Payments?»](https://help.getjobber.com/hc/en-us/articles/360042921653-Why-is-my-Info-Required-for-Jobber-Payments) — прямой аналог нашего S2; собирают **полный 9-значный SSN** представителя; статья «Holds and Reviews» — признак того, где у них болит.
- **Housecall Pro** показывает KYC-статус **в продукте** (красный баннер «Review Info» с resubmit), а не письмом.
- **Workiz** начинает флоу с **банка** («connect the bank account that will receive the payments») — мотивационный якорь «куда придут деньги», SSN позже, когда sunk cost набран; ветвление Individual (без EIN) vs Company на первом шаге.
- **HoneyBook**: «While clients can make payments before a bank account is connected, funds will start getting transferred…» после верификации — паттерн «принимай до банка»; Instant Payouts = 12.5% объёма, 50%+ повторного использования.
- **ServiceTitan** (Adyen, enterprise, sales-assisted, PCI-анкета) — анти-паттерн для solo-сегмента; полезен как контраст.
- Общая боль всех по отзывам (BBB/community): **не сложность формы, а неожиданные заморозки выплат** (Jobber 120 дней, QuickBooks $100k+ on hold, Wave «irreversible» отключения) — честный экран «первая выплата через N дней, дальше 1–2 дня» снимает главный источник 1-звёздочных отзывов.

**8 выводов для редизайна (vs конкуренты):**
1. Embedded > hosted-redirect — текущий фронтир категории (FreshBooks, HoneyBook); Jobber/ServiceM8/Joist с редиректом — «средний» уровень, наш этап 1 нас туда и выводит, этап 2 — на уровень лидеров.
2. Разделять «могу принимать» и «могу получить выплату» (HoneyBook, Jobber, WePay-эра FreshBooks).
3. Explainer перед SSN — стандарт категории, но у конкурентов он в хелп-центре; у нас (S2) — в продукте, это лучше.
4. Ставить **два** ожидания сразу: время формы («~15 минут» у Jobber) и время первой выплаты (5–7 b.d.) — второе важнее для отзывов.
5. Начинать с банка, а не с паспорта (Workiz).
6. Ветвление по типу бизнеса, минимальный набор для Individual: SSN + DOB + home address + банк.
7. Статус заявки — в приложении с deep-link на недостающее поле (HCP), не в почте (Joist/WePay-циклы «verification unsuccessful»).
8. Префилл почти никто не делает хорошо — переиспользование профиля приложения (business name, адрес, телефон, industry) = наше самое дешёвое преимущество; бонус-рычаги attach-rate: ACH по умолчанию (Jobber), кошельки автоматом (HCP), Instant Payouts как крючок (FreshBooks +22%).

## 6. Рекомендации для бэкенда (сводка)

1. **Префилл в `PreAuth`** (данные через `StripeAccountRequest` из `PaymentsService.cs:146-217`) — лечит C2/M1/M2/M3, переиспользуется этапом 2. Website не слать, если его нет — только `product_description`.
2. **Развилка по типу аккаунта** — РЕШЕНО (2026-07): только Standard, Express отвергнут (стоимость + liability за отрицательные балансы); детали — README «Рекомендации» п. 2.
3. **Авто-возврат**: `success_onboarding.html` → мгновенный redirect на `invoices://`/`tofu://finish_stripe_connection` (+ починить детект успеха на iOS) — C4/M6.
4. **Осознанный выбор `collection_options`** (currently_due vs eventually_due) вместо текущего флага.
5. **Статусная модель**: success-экран по `details_submitted`, «Connected» по `charges_enabled` (вебхук `account.updated` уже есть), никогда не «Activate» после сабмита — C1.
6. **Этап 2 — embedded**: бэкенд готов (`CreateAccountSession`); iOS подключает `StripeConnect` SDK и `.onboarding`-компонент через существующий `GET /api/stripe-links/account-session/{type}`. Эндпоинт client_secret должен минтить свежую сессию на каждый вызов (SDK сам рефрешит через `fetchClientSecret`).
7. **Шаг банка (M4/S6)**: с API-версии `2026-03-25.dahlia` в embedded можно `external_account_collection=false` даже для наших Stripe-collected аккаунтов (при включённой Stripe-аутентификации) — банк можно вынести из первого захода и дособрать позже; плюс проверить Dashboard-настройки external accounts и Link-тоггл.
8. **Аналитика воронки**: пошаговая (`onStepChange`, 35 имён шагов) есть только в web-embedded; на iOS SDK её нет — мерить свои экраны S1–S3/S7 + диффы `requirements` до/после выхода из компонента; событие `PaymentAccountStatus` уже шлётся.
9. **Ремедиация застрявших**: перевыпуск линка/`requirements.only` показывает ровно недостающее («форма сама знает, что собрать»); `requirements.errors[].reason` — готовый текст для UI. `account_update`-линков для нас нет — правка данных только через Stripe/Express Dashboard пользователя.
10. **Удалять брошенные полу-онбордженные аккаунты** (наш `deleteOld`): Stripe шлёт письма брошенному аккаунту, и удалить его может только платформа через API.
11. **Продуктовый приём индустрии против M5 (голый toggle)** — deferred onboarding: предлагать подключение в момент реальной ценности («клиент готов оплатить инвойс — подключите выплаты»), а не абстрактным свитчем в настройках.
    Разграничение легальности «deferred onboarding» (три разных вещи под одним термином):
    - **UX-тайминг** (это и есть п.11): никаких Stripe-сущностей заранее, просто момент оффера — юридически стерильно.
    - **Collect-then-verify** (официально поддержано Stripe): incremental onboarding + пороговая модель KYC («Stripe temporarily pauses charges or payouts if the information isn't provided or verified according to the thresholds»). Подтверждённые в актуальных доках US-пороги: для charges достаточно city+state+ZIP из `individual.address`; полный верифицированный адрес — в 30 дней (иначе пауза payouts); EIN для company — 30 дней или $1,500; **$600 надёжно подтверждён только как порог 1099-капабилити** (не универсальный «$600/30 дней» — пороги динамичны, ориентироваться на `requirements`/`current_deadline`) ([identity-verification](https://docs.stripe.com/connect/identity-verification), [required-verification-information](https://docs.stripe.com/connect/required-verification-information), [1099-пороги](https://docs.stripe.com/connect/required-verification-information-taxes)). Легально, но trade-off: саппорт «где мои деньги» токсичнее, чем «не могу подключиться»; непройденный KYC = рефанды плательщикам. В ТЗ этого нет — отдельное продуктовое решение, если захотим.
    - **Прогон продавцов под аккаунтом платформы с ручными выплатами** (паттерн из HN) — нарушение Stripe ToS + риск money-transmitter-лицензирования в US. Не рассматриваем.

## 7. Источники

**Stripe docs (первоисточники)**: [onboarding-варианты](https://docs.stripe.com/connect/onboarding) · [hosted-onboarding](https://docs.stripe.com/connect/hosted-onboarding) · [embedded-onboarding](https://docs.stripe.com/connect/embedded-onboarding) · [account-onboarding component (web/iOS)](https://docs.stripe.com/connect/supported-embedded-components/account-onboarding) · [get-started embedded components](https://docs.stripe.com/connect/get-started-connect-embedded-components) · [appearance options](https://docs.stripe.com/connect/embedded-appearance-options) · [API: accounts/create](https://docs.stripe.com/api/accounts/create) · [API: account_links](https://docs.stripe.com/api/account_links/create) · [API: account_sessions](https://docs.stripe.com/api/account_sessions/create) · [controller-свойства](https://docs.stripe.com/connect/migrate-to-controller-properties) · [handling-api-verification](https://docs.stripe.com/connect/handling-api-verification) · [networked onboarding](https://docs.stripe.com/connect/networked-onboarding) · [payouts-bank-accounts](https://docs.stripe.com/connect/payouts-bank-accounts) · [changelog 2026-03-25.dahlia (external_account_collection)](https://docs.stripe.com/changelog/dahlia/2026-03-25/relaxed_external_account_collection_account_session) · [marketplace/onboard](https://docs.stripe.com/connect/marketplace/tasks/onboard)

**Статистика**: [Stripe blog: Express onboarding redesign, +5.3% / Qwick +17% (2019)](https://stripe.com/blog/connect-express-onboarding) · [Signicat «Battle to Onboard» 2022 (68% abandon)](https://www.signicat.com/the-battle-to-onboard-2022) · [SSN: last-4 → полный при $500K](https://support.stripe.com/questions/date-of-birth-and-social-security-number-(ssn)-requirement-for-us-stripe-accounts)

**Комьюнити/поле**: [HN 44183145 (откат на PayPal из-за онбординга)](https://news.ycombinator.com/item?id=44183145) · [HN 33144275 (отказ продавцов)](https://news.ycombinator.com/item?id=33144275) · [HN 41431251 (письма брошенного Express)](https://news.ycombinator.com/item?id=41431251) · [connect-js #124 (hosted-вкладка из embedded)](https://github.com/stripe/connect-js/issues/124) · [react-connect-js #93 (popup blocked)](https://github.com/stripe/react-connect-js/issues/93) · [stripe-react-native #1188 (custom scheme в return_url)](https://github.com/stripe/stripe-react-native/issues/1188) · [Bubble forum: restricted connected accounts](https://forum.bubble.io/t/stripe-connected-accounts-restricted/333906) · [Posh: support-плейбук по застрявшим](https://support.posh.vip/en/articles/11647252-stripe-onboarding-101-common-roadblocks-fixes) · [Givebacks: «Why does Stripe need my SSN?»](https://support.givebacks.com/en/articles/11185166-why-does-stripe-need-my-social-security-number-and-ein) · [stripe.dev blog: embedded для конверсии](https://stripe.dev/blog/connect-embedded-components-streamline-onboarding) · [stripe-ios CHANGELOG (Connect SDK GA 24.15.0)](https://github.com/stripe/stripe-ios/blob/master/CHANGELOG.md)

**Конкуренты**: [Adyen for Platforms onboarding](https://docs.adyen.com/platforms/quickstart-guide/onboarding-and-kyc) · [PayPal Multiparty Seller Onboarding](https://developer.paypal.com/docs/multiparty/seller-onboarding/)

**Кейсы компаний (раздел 5.4)**: [Substack](https://stripe.com/customers/substack) · [Kickstarter](https://stripe.com/customers/kickstarter) · [FreshBooks](https://stripe.com/customers/freshbooks) · [Booksy](https://stripe.com/customers/booksy) · [Housecall Pro](https://stripe.com/customers/housecall-pro) · [Kajabi](https://stripe.com/customers/kajabi) · [GlossGenius](https://stripe.com/en-gr/customers/glossgenius) · [Mindbody](https://stripe.com/customers/mindbody) + [Coris (−80% ручных ревью)](https://www.coris.ai/blogs/mindbody-reduces-manual-smb-onboarding-by-80-in-45-countries) · [Lyft](https://stripe.com/customers/lyft) · [Instacart](https://stripe.com/customers/instacart) · [Squarespace](https://stripe.com/customers/squarespace) · [Sessions 2024: Lessons from 13,000 platforms](https://stripe.com/sessions/2024/lessons-from-13-000-platforms) · [Sessions 2025 (networked onboarding, «1 из 6»)](https://stripe.com/blog/top-product-updates-sessions-2025)

**Хелп-центры конкурентов (раздел 5.5)**: [Jobber: Set Up Payments](https://help.getjobber.com/hc/en-us/articles/115009571407-How-to-Set-Up-Jobber-Payments) · [Jobber: Why is my Info Required](https://help.getjobber.com/hc/en-us/articles/360042921653-Why-is-my-Info-Required-for-Jobber-Payments) · [Housecall Pro: Payment Processing](https://help.housecallpro.com/en/articles/2046930-housecall-pro-payment-processing-options) · [ServiceTitan: Adyen onboarding](https://help.servicetitan.com/docs/begin-the-adyen-payments-onboarding-process) · [Workiz Pay signup](https://help.workiz.com/hc/en-us/articles/18055821794961-Signing-up-for-Workiz-Pay-to-enable-online-payments) · [ServiceM8 Pay](https://support.servicem8.com/help-center/servicem8-add-ons/servicem8-pay/how-to-get-started-with-servicem8-pay) · [HoneyBook: Bank & Business Details](https://help.honeybook.com/en/articles/2209105-bank-business-details-setup-and-verification) · [Joist: Stripe signup (7 шагов)](https://support.joistapp.com/en/articles/9212798-signing-up-for-joist-payments-with-stripe) · [Square: Verify identity](https://squareup.com/help/us/en/article/8663-verify-your-identity-and-square-business-information) · [Invoice2go → BILL](https://support.2go.com/hc/en-us/articles/4430307214349-Switching-from-Stripe-to-Invoice2go-Card-Payments)

**Верификация спорных пунктов**: [supported embedded components (mobile: GA только onboarding)](https://docs.stripe.com/connect/supported-embedded-components) · [Express Dashboard: payouts](https://support.stripe.com/express/questions/how-do-i-manage-my-payouts) · [1099-пороги ($600)](https://docs.stripe.com/connect/required-verification-information-taxes) · [setting-mcc](https://docs.stripe.com/connect/setting-mcc)
