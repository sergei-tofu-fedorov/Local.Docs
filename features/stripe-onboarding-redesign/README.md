# Stripe payments onboarding — редизайн флоу (FSM iOS) — рабочая выжимка

Компактная версия исследования к ТЗ `C:\Files\Stripe_payments_onboarding__редизайн_флоу_(FSM_iOS)__ТЗ.pdf`. Полный ресёрч-след (форумы, кейсы 30+ компаний, конкуренты, верификация каждого пункта) — в [research.md](research.md).

**Status:** research · **Repos:** `Invoices.Backend` (BFF), `Invoices.Apps.iOS`
**Scope:** только **hosted** (Account Links) и **embedded** (Account Sessions + StripeConnect SDK). Custom/API-онбординг — не вариант (liability за отрицательные балансы + весь комплаенс на нас; Stripe: «We don't recommend this option unless you're committed to the operational complexity»). Тип аккаунта — **только Standard** (решение 2026-07, см. Рекомендации п. 2).

## Легенда: коды проблем и шагов из ТЗ

Конверсия подключения Stripe ~15% (accepted → `is_stripe_linked=true`; борд `qyubyw4i`, чарт `yhwnmxbk`). Коды ниже используются по всему документу.

> **Замер на проде (2026-07-15) переставляет приоритеты** — [prod-funnel.md](prod-funnel.md), N=21 489. Семантика флагов и требований — [stripe-requirements.md](stripe-requirements.md); карта полей — [prefill-fields.md](prefill-fields.md).
>
> - **Внутри формы** потери разложены по экранам — [in-form-loss.md](in-form-loss.md): identity (C3 из ТЗ) даёт лишь 0.7% нажавших, тогда как business details и банк — по ~3% каждый; половина потерь приходится на два **необъяснённых** состояния.
> - **68% теряются ДО формы** — разбор в [pre-form-loss.md](pre-form-loss.md): **58.2% не печатают ни символа** (аккаунт остаётся пустой скорлупой), ещё **9.8%** регистрируются в Stripe и уходят до формы. Внутри формы теряется 11.5%, конверсия дошедших до формы — 48.2%. Потолок всей работы по префиллу и S4–S7 — 32% общей конверсии.
> - **`business_profile.url` стоит 2.6%**: сайт указывают лишь 7.1% начавших (соседние поля того же экрана — ~51%), и у **564** аккаунтов url — единственный элемент `past_due`; они не приняли ни одного платежа, медианный простой — 90 дней. **Посылка «сайта нет ни у кого» неверна** — 99.9% подключённых сайт указали, причём **треть — это просто Instagram или Facebook**. Спрашивать надо не «Your website», а «где вас найти в интернете». Разбор — [prefill-fields.md](prefill-fields.md).
> - **C1 реален и весит 4.6%**: из отправивших форму и не заряженных **90.1% не приняли ни одного платежа** — это не «ограничены позже», а «никогда не включились».
> - **Документ (photo ID) просят у 0.8%** — S2 пугает всех ради события у одного из ста двадцати. Identity сверяется по базам, документ — фолбэк.
> - **Форма длиннее обещанного**: у дошедших медиана **13.8 мин**; под «About 5 minutes» из S2 укладывается 23%.
>
> - **План A/B «embedded против hosted»** — [ab-embedded-vs-hosted.md](ab-embedded-vs-hosted.md): наши фича-флаги не умеют проценты (только поимённый `AccountId`), нужен бакетинг; на нашем трафике ловится эффект от +3 п.п. за ~1.5 месяца. Гипотеза бьёт в 58%: embedded убирает **прыжок в браузер** (C4/M6 — на iOS, в отличие от web, hosted-вкладка не открывается), а до экрана регистрации эти люди и не доходят — email есть лишь у 14.4% корзины.
>
> ⚠️ Три утверждения ниже по тексту замер **опровергает**: «сайта нет ни у кого», «url — топ-1 непокрытое требование» (обоснование было артефактом базового набора) и оценка C1 как двухминутного окна.

**C1–C4 — находки коридорного теста (критичные):**

| Код | Проблема | Корневая причина |
|---|---|---|
| **C1** | Нет настоящего success-экрана: после сабмита — «verifying»-лимб, в меню всё ещё «Activate» | статус строится без учёта `details_submitted` vs `charges_enabled` |
| **C2** | Email пользователя уже есть в Stripe → стена «пароль + 2FA» посреди онбординга | email не префиллится при создании аккаунта (`individual.email` пустой) |
| **C3** | SSN/DOB/домашний адрес спрашиваются без объяснения — пользователь пугается и бросает | нет explainer-экрана перед хендоффом |
| **C4** | Резкий выброс из приложения в браузер; назад — крошечная ссылка «Return to TOFU» | статическая success-страница без авто-редиректа в приложение |

**M1–M6 — мелкие находки (minor):**

| Код | Проблема |
|---|---|
| **M1** | Email приходится вводить руками (не префиллен) |
| **M2** | Пользователи вписывают placeholder `www.example.com` в поле сайта → аккаунт «Incomplete» |
| **M3** | Product description требует ≥10 символов — неожиданная ошибка валидации |
| **M4** | «Save with Link» выглядит обязательным шагом (это опция Stripe, не наша) |
| **M5** | Вход в тяжёлый KYC-флоу — голый toggle в настройках, без момента ценности |
| **M6** | После завершения окно браузера не закрывается само |

**S1–S7 — целевой флоу из ТЗ:**

| Шаг | Экран |
|---|---|
| **S1** | Payments intro — зачем подключать |
| **S2** | «Before we start» — почему Stripe спросит SSN (лечит C3) |
| **S3** | Connecting bridge — переход с ко-бренд шапкой (смягчает C4) |
| **S4** | Stripe: business details — всё префиллено (лечит M1–M3) |
| **S5** | Stripe: identity (SSN/DOB) |
| **S6** | Stripe: банк для выплат — Link опционален (лечит M4) |
| **S7** | «You're ready to get paid» — success с двухуровневым статусом, «Activate» после сабмита не показывать никогда (лечит C1) |

**Текущее состояние.** Backend: `StripeAccountClient.PreAuth` (`Src/Tofu.Stripe/StripeAccountClient.cs:93`) создаёт голый `Type="standard"` без префилла (корень C2/M1/M2/M3); `CreateAccountSession` (:127) — embedded-половина **уже написана**; return-callback отдаёт статическую страницу с крошечной ссылкой (C4/M6). iOS: hosted-линк в `SFSafariViewController` (легально — это system browser), успех детектится хрупко по URL-substring; `StripeConnect` SDK не подключён (только stripe-terminal); эндпоинт `GET /api/stripe-links/account-session/{type}` клиентом не используется.

## Hosted vs Embedded — расширенное сравнение

| Рычаг | Hosted (Account Links) | Embedded (Session + SDK/ConnectJS) |
|---|---|---|
| Где рендерится | браузер на `connect.stripe.com`; **запрещён в webview** («only supported in web browsers») | внутри приложения; iOS SDK GA с 24.15.0 (06.2025), WKWebView-обёртка над ConnectJS |
| Возврат в приложение | `return_url` (HTTPS-only в live; кастомные схемы отвергаются) → наш HTTPS-трамплин → deep-link; `return_url` **≠ завершение** | нет возврата как класса: `onExit` / `accountOnboardingDidExit` (C4/M6 исчезают) |
| Хрупкость входа | линк одноразовый, TTL «a few minutes», убивается back-кнопкой и превью-ботами; нужен перевыпуск линка по refresh_url | `client_secret` истекает, но SDK сам рефрешит через `fetchClientSecret` |
| Брендинг | имя/цвет/иконка из Connect settings, форма Stripe-branded; кастомный домен невозможен | полная темизация: web `appearance.variables` (десятки переменных), iOS `Appearance` (цвета/шрифты/`CustomFontSource`); auth-попап не темится никогда |
| Локаль | параметра нет (проверено по API) — форсировать нельзя | web: `locale` (47 локалей); iOS: локаль устройства |
| `collection_options.fields` | ✔ (задаётся в линке) | ✔ (на клиенте; default `currently_due`) |
| `requirements.only/exclude` (скоуп шагов) | ✖ | ✔ web и iOS (iOS — подтверждено исходниками); разрешено для наших stripe-collected аккаунтов |
| Пропуск шага банка | ✖ (только Dashboard-настройки) | ✔ `external_account_collection=false` — для наших аккаунтов с API `2026-03-25.dahlia` |
| Стена Stripe-логина (C2) | не отключаема (`disable_stripe_user_authentication` — только application) | так же не отключаема; лечится только префиллом `individual.email` |
| Аналитика воронки | ✖ (только return/refresh) | web: `onStepChange`, 35 имён шагов; **iOS: нет** — только exit/error → воронка через свои экраны + диффы `requirements` |
| Компоненты на iOS | n/a | GA только account onboarding; payments/payouts — preview; `notification_banner` — **нет** (статус-баннеры делаем сами) |
| Ремедиация застрявших | новый линк (форма сама покажет недостающее); `account_update`-линков для нас нет | компонент дособирает сам; точечно — `requirements.only` (мгновенный exit, без summary) |
| Обновления регуляторики | автоматически (Stripe hosted) | автоматически (компонент) — Substack: «не меняли код 4 года» |
| Усилия у нас | фиксы трамплина + префилл (бэкенд) | бэкенд готов (`CreateAccountSession`); iOS: подключить SDK + `.onboarding` |
| Кто так делает | Substack, Kickstarter, Jobber, ServiceM8, Joist | FreshBooks, HoneyBook (white-label), Kajabi (гибрид) — фронтир SMB-категории |

## Префилл (детально)

> Пофайловая карта «поле → наш источник → нюанс», проверенная на тестовой платформе (SSN, длина описания, деление имени, два email, Industry→MCC) — [prefill-fields.md](prefill-fields.md). Инструмент, которым это проверялось, — [`Investigations/stripe-onboarding-prefill`](../../../Investigations/stripe-onboarding-prefill/README.md).

**Главное: префилл живёт в Accounts API и одинаков для обоих вариантов** — форма (hosted и embedded) читает поля с объекта Account. Один код в `PreAuth` обслуживает оба этапа.

**Механика реализации.** Отдельного «prefill API» нет — префилл = обычные поля объекта Account:

1. **При создании**: передать данные прямо в `POST /v1/accounts` — наш случай: расширить `AccountCreateOptions` в `PreAuth` (`StripeAccountClient.cs:93`), который сегодня создаёт голый `Type="standard"`.
2. **Дозаполнение**: пока не выпущен первый Account Link / Account Session — можно дозаполнять через `POST /v1/accounts/{id}` (`accounts/update`).
3. **После первого линка/сессии — точка невозврата**: identity-поля запираются навсегда (см. ниже); значит, **все данные должны быть собраны и положены на Account до того, как `PreAuth` выпустит первый Account Link**. Если пользователь потом сменит email/имя у нас в приложении — пересинхронизировать их в Stripe мы уже не сможем (только сам пользователь через онбординг-форму или свой Stripe-дашборд).

- **Окно одно**: «Prefill any account information **before generating the Account Link** because you can't read or write information for the connected account afterward» ([hosted-onboarding](https://docs.stripe.com/connect/hosted-onboarding)); закрывается первым Account Link **или** Account Session. Identity-поля (`individual`, `company`, `business_type`, `external_account`, `tos_acceptance`) запираются — т.е. становятся для платформы недоступными через API **ни на запись, ни на чтение** (наш API-запрос на update вернёт ошибку). `business_profile`/`metadata`/`settings` — записываемы всегда.
- **Поведение формы**: «The Connect onboarding flow **doesn't ask** your connected account for any information that you prefilled. However, it does ask… to **confirm** the prefilled information before they accept the Connect service agreement» — заполненное не спрашивается, но показывается на подтверждение (редактируемо). Уже **верифицированные** поля не переспрашиваются вовсе.
- **Что префиллим** (всё есть в Mongo/Auth): `Individual.FirstName/LastName/Email/Phone` (из `Account.Contacts` + Tofu.Auth), `Country=US`, `BusinessType=individual`, `BusinessProfile.ProductDescription` (из ниши; ≥10 симв. — M3). **`Individual.Email` ≠ верхнеуровневый `Email`** — в KYC-форму идёт именно первый (лечит C2/M1). `business_profile.url` — только если реальный; сайта у нас нет → официальный путь — `product_description` (Stripe сам это рекомендует; соцпрофиль допустим полным URL).
- **Банк** можно пред-прикрепить токеном `external_account=btok_...` — но полного «невидимого» пропуска шага доки не обещают (остаётся confirm).
- **Не префиллим**: SSN/DOB/адрес (нет данных + комплаенс).
- **⚠ Префилл ↔ networked onboarding — конфликт**: заполнение **любого** поля `individual.*` (а также `company.address`/`individual.address` кроме `country`, флагов owners/directors/executives, Persons и `external_accounts`) отключает предложение переиспользовать существующую legal entity — «By pre-filling a connected account's data… you skip the option to reuse existing legal entities if you provide any of the following fields: … Any `individual` object fields» ([networked onboarding](https://docs.stripe.com/connect/networked-onboarding)). Не дисквалифицируют: `business_profile`, `business_type`, `country`. Возможный выход — развилка «две кнопки» (**предложение, не принято** — см. одноимённый раздел ниже).
- **Куда класть в коде**: расширить `AccountCreateOptions` в `PreAuth`, данные протащить через `StripeAccountRequest` из `PaymentsService.AuthenticatePaymentType` (`PaymentsService.cs:146`) — сегодня он Account/Contacts/User не загружает.

## Returning users

**а) У пользователя уже есть Stripe-аккаунт (C2).** По данным Stripe — **1 из 6** регистрирующихся на платформе ([Sessions 2025](https://stripe.com/blog/top-product-updates-sessions-2025)). Стену «пароль+2FA» убрать нельзя (оба варианта UI); смягчение — префилл `individual.email`, чтобы форма не предлагала «ввести email» и коллизия случалась осознанно. **Networked onboarding** (включён по умолчанию, [docs](https://docs.stripe.com/connect/networked-onboarding)) после логина предлагает переиспользовать верифицированную legal entity существующего аккаунта — Stripe-маркетинг: онбординг «в 3 клика», приём платежей в тот же день. Механика: `business_type`/`country`/`company`/`individual` **синхронизируются между связанными аккаунтами навсегда**; `external_accounts` (банк!), `business_profile`, statement descriptors, branding — копируются один раз. Условия: `requirement_collection=stripe` (наш Standard ✔), hosted или user-authenticated embedded ✔. **Но: префилл `individual.*` отключает это предложение** (см. конфликт в разделе «Префилл») — могло бы разрешаться предлагаемой развилкой «две кнопки» (не принято; см. отдельный раздел ниже). Подводный камень: брошенный недо-онбордженный аккаунт продолжает слать пользователю письма Stripe, удалить его сам пользователь не может ([HN 41431251](https://news.ycombinator.com/item?id=41431251)) — а **live Standard-аккаунт не может удалить и платформа**: «Live-mode accounts that have access to the standard dashboard… cannot be deleted, which includes Standard accounts» ([API delete](https://docs.stripe.com/api/accounts/delete)) → фактическое поведение нашего `deleteOld`-флоу на live Standard **надо проверить** (может фейлить молча); альтернатива удалению — бросать аккаунт и создавать новый (перепривязка `acct_...` через `Metadata[AccountId]`/Mongo).

**б) Возврат для дозаполнения/ремедиации.** Официальное правило: «Send a connected account back through onboarding when it has any `currently_due` or `eventually_due` requirements. **You don't need to identify the specific requirements** — the onboarding interface knows what information it needs to collect». Hosted: просто новый Account Link (перевыпуск по refresh_url уже реализован). Embedded: компонент дособирает сам; точечная ремедиация — `requirements.only` (см. ниже). Текст для нашего UI — готовый: `requirements.errors[].reason` (display-ready), коды типа `verification_document_not_readable`. Драйвить возврат — вебхуком `account.updated` (есть) + `capability.updated`; подводный камень: неактивные аккаунты висят в Pending бесконечно.

## Предложение (не решено): развилка «две кнопки» — «есть Stripe» / «нет Stripe»

> **Статус: предложение, не принято.** Нужно продуктовое решение по первому экрану онбординга — ниже описано, зачем оно и как работало бы.

**Зачем нужно.** Префилл `individual.*` лечит C2/M1 для большинства (**5 из 6** — своего Stripe нет), но **тем же действием** отключает networked onboarding для меньшинства (**1 из 6** — Stripe уже есть), которому реюз как раз даёт «3 клика + банк копируется» (конфликт — в разделе «Префилл»; сам networked — в «Returning users», п. а). Корень в том, что **один payload при создании аккаунта не обслуживает обе группы одновременно**:

- **полный префилл** → выигрывают новые (C2/M1/M2/M3), но у returning пропадает reuse;
- **только safe-поля** → reuse для returning сохраняется, но новые теряют лечение C2/M1.

Развилка снимает противоречие: пользователь сам выбирает ветку **до создания аккаунта**, и каждая когорта получает оптимальный payload. Без развилки придётся зафиксировать один глобальный компромисс, заведомо неверный для одной из двух групп.

**Как это работало бы.** Аккаунт создаётся **в момент выбора кнопки**; payload зависит от ветки (префилл — это просто поля `POST /v1/accounts`, окно закрывается только первым линком/сессией).

| | «У меня нет Stripe» (дефолт, 5 из 6) | «У меня уже есть Stripe» (1 из 6) |
|---|---|---|
| Payload при создании | полный префилл: `individual.*`, `business_type`, `country`, `business_profile.product_description` | только safe-поля: `business_type`, `country`, `business_profile.product_description` |
| Что лечится | C2 (осознанная коллизия) / M1 / M2 / M3 | M2 / M3; после логина — networked reuse: «3 клика», банк копируется из существующего аккаунта |
| Цена | networked reuse недоступен (пользователь сам сказал, что реюзать нечего) | M1 возвращается (имя/email руками) — но после реюза форма почти пуста |

**Ошибся кнопкой:** «нет, а аккаунт есть» → ровно сегодняшний плановый опыт (префилл + стена, без реюза) — мягкая деградация; «есть, а аккаунта нет» → до выпуска первого линка можно дозаполнить `individual.*` через `accounts/update` (кнопка «назад»), после — только бросить аккаунт и создать новый (удалить live Standard нельзя, см. «Returning users», п. а); брошенный аккаунт без введённого email писем слать не должен (UNVERIFIED — проверить на тестовом аккаунте).

**Альтернатива для ветки «есть Stripe»** — [OAuth-подключение существующего Standard-аккаунта](https://docs.stripe.com/connect/oauth-standard-accounts) (без создания нового; так делает Markate, Squarespace с этого мигрировал): подключается *тот самый* аккаунт с его историей, тогда как networked создаёт *новый* с общей legal entity (чище изоляция per-platform). Для MVP networked проще — тот же онбординг-код.

## Федеративная аутентификация (C2) — исследовано, невозможно

Вопрос: можно ли убрать стену Stripe-логина, отдав Stripe наши Firebase-токены (или иной внешний IdP)? **Нет — механизма федерации для connected-аккаунтов у Stripe не существует** (проверено 2026-07: доки до `2026-03-25.dahlia` + форумы).

- «Stripe user authentication» в онбординге — собственная identity-система Stripe; OIDC/внешние IdP/token-exchange для connected-аккаунтов не упоминаются нигде ([embedded-onboarding](https://docs.stripe.com/connect/embedded-onboarding), [account-onboarding](https://docs.stripe.com/connect/supported-embedded-components/account-onboarding)).
- Единственный SSO у Stripe — [SAML 2.0 для team members нашего Dashboard](https://docs.stripe.com/get-started/account/sso); к онбордингу connected-аккаунтов неприменим по построению (там логинится владелец *чужого* Stripe-аккаунта). Firebase к тому же не SAML-IdP.
- Единственный способ снять стену — `disable_stripe_user_authentication=true`, доступен только при `controller.requirement_collection=application` (Custom-подобная конфигурация): liability за отрицательные балансы + весь сбор требований на нас + [теряется networked onboarding](https://docs.stripe.com/connect/supported-embedded-components/account-onboarding) («3 клика» для 1 из 6). Уже отвергнуто (см. Scope).
- Комьюнити-обходов нет: во всех публичных Firebase+Stripe интеграциях Firebase аутентифицирует только в приложении, дальше обычный Account Link ([Medium iOS](https://medium.com/swlh/implementing-stripe-onboarding-to-your-ios-project-swift-firebase-node-js-f855965a3ce5), [dev.to Flutter](https://dev.to/wolfof420street/building-a-payment-system-for-your-flutter-app-a-journey-with-stripe-connect-and-firebase-1hem)); тредов «как обойти логин» на SO/Reddit/HN не находится.
- Попутные находки для этапа 2 (embedded web): первый auth-шаг до сих пор открывает hosted-вкладку ([connect-js #124](https://github.com/stripe/connect-js/issues/124), закрыт без фикса, 2024→2026) и режется popup-блокерами ([react-connect-js #93](https://github.com/stripe/react-connect-js/issues/93)); iOS SDK это не касается.

Итог: лечение C2 остаётся прежним — префилл `individual.email` + networked onboarding как ускоритель для returning users.

## Пропуск/скоуп шагов формы

| Механизм | Что делает | Ограничение |
|---|---|---|
| `fields=currently_due` (default) | короткая форма «только необходимое сейчас» — SSN/банк могут уехать за пороги | потом Stripe дособирает (пороговая модель); наш `IsCollectRequirements=true` сейчас ставит противоположное (`eventually_due`) |
| `fields=eventually_due` | всё сразу, один заход, без последующих блокировок | длиннее форма |
| `future_requirements=include` | собрать и будущую регуляторику | **только platform-collected — нам недоступен** |
| `requirements.only=[...]` (embedded) | показать ровно перечисленные требования; «exits immediately» если всё дано, **без summary** — идеален под статус `InformationIsRequired` | остальные требования остаются висеть на аккаунте |
| `requirements.exclude=[...]` (embedded) | спрятать поля из формы (вкл. confirm-экран) | «doesn't remove information requirements» — **только для гарантированно закрытых префиллом**, иначе неремонтируемый лимб |
| `external_account_collection=false` (embedded) | убрать шаг банка целиком | для наших аккаунтов — с API `2026-03-25.dahlia`, при включённой Stripe-аутентификации ([changelog](https://docs.stripe.com/changelog/dahlia/2026-03-25/relaxed_external_account_collection_account_session)) |
| Префилл поля | шаг не спрашивается (остаётся в confirm) | verified-поля исчезают полностью |
| ToS-шаг | — | убрать нельзя (application-only) |

## Пропуск шага банка (M4/S6)

> Детальный имплементационный план (что менять в `Invoices.Backend`, как это работает для пользователя, риски) — [skip-bank-step.md](skip-bank-step.md).

Шаг банка — второй по «страшности» после SSN, и единственный, который можно вынести из первого захода целиком. Варианты:

1. **Embedded: `components.account_onboarding.features.external_account_collection=false`** — шаг банка исчезает из формы. Для наших stripe-collected аккаунтов доступно **с API-версии `2026-03-25.dahlia`** (раньше — только application) при условии `disable_stripe_user_authentication=false`, т.е. Stripe-логин остаётся ([changelog](https://docs.stripe.com/changelog/dahlia/2026-03-25/relaxed_external_account_collection_account_session)). Требование `external_account` при этом **не снимается** — просто откладывается.
2. **Пред-прикрепить банк токеном** — `external_account=btok_...` при создании аккаунта (до первого линка/сессии): шаг не спрашивается, но остаётся на confirm-экране; полного «невидимого» пропуска доки не обещают.
3. **Hosted**: параметра нет — только Dashboard-настройки external accounts (require ≥1 bank account?, debit cards?, метод сбора Financial Connections vs manual).

Последствия отложенного банка: charges работают, **выплаты копятся и не уходят**, пока банк не добавлен — донабор через повторный вход в онбординг (компонент сам дособирает) или `requirements.only=['external_account']`; мотивация готовая — «$X ждут выплаты». Это уже проверенный категорией паттерн: HoneyBook прямо документирует «clients can make payments before a bank account is connected» ([help](https://help.honeybook.com/en/articles/2209105-bank-business-details-setup-and-verification)).

Про «Save with Link» (M4): в самой форме Link-виджет мы не контролируем; Dashboard-тоггл Link документирован только как управление переиспользованием банк-данных в Financial Connections — убирает ли его выключение промпт, не задокументировано (проверить на тестовом аккаунте). Радикальное решение M4 — как раз пункт 1: нет шага банка — нет и Link.

## Best practices (с пруфами)

1. **Префиллить всё до первого линка/сессии** — официальная рекомендация + форма не спрашивает заполненное ([docs](https://docs.stripe.com/connect/hosted-onboarding)); Stripe сам советует `product_description`, если нет сайта. Наше самое дешёвое преимущество: конкуренты префилл почти не делают ([research.md#55](research.md)).
2. **Не пересобирать KYC-форму — вкладываться вокруг неё**: единственные публичные цифры конверсии — от улучшений самой формы Stripe: **+5.3%** средний аплифт редизайна онбординг-формы, **+17% Qwick** ([Stripe blog 2019](https://stripe.com/blog/connect-express-onboarding)); Kajabi +10% после запуска payments ([Sessions 2024](https://stripe.com/sessions/2024/lessons-from-13-000-platforms)).
3. **Explainer до хендоффа — стандарт категории** (наш S2): Kickstarter коучит «данные должны совпадать с гос. документами — опечатки — причина №1 провала» ([help](https://help.kickstarter.com/hc/en-us/articles/115005139673)); у Jobber отдельная статья [«Why is my Info Required»](https://help.getjobber.com/hc/en-us/articles/360042921653-Why-is-my-Info-Required-for-Jobber-Payments); платформы шьют страницы «Why does Stripe need my SSN» ([Givebacks](https://support.givebacks.com/en/articles/11185166-why-does-stripe-need-my-social-security-number-and-ein)).
4. **Ставить два ожидания: время формы И время первой выплаты.** Бенчмарки: форма «under 15 minutes» (Jobber) / «a few minutes» (HCP, HoneyBook); первый payout 5–7 b.d. Главный источник 1★-отзывов у всех конкурентов — не форма, а неожиданные заморозки выплат (Jobber 120 дней, QuickBooks $100k on hold — [research.md#55](research.md)).
5. **`return_url`/`details_submitted` ≠ готов**: «It doesn't mean that all information has been collected»; готовность = `charges_enabled && details_submitted`, драйвить `account.updated`-вебхуком — общее место всех продакшен-интеграций ([docs](https://docs.stripe.com/connect/hosted-onboarding), [dev.to](https://dev.to/ddm4313/creating-a-marketplace-with-stripe-connect-the-onboard-process-22cj)). Наш C1.
6. **Статус KYC — в приложении, не в почте**: Housecall Pro показывает баннер «Review Info» с resubmit прямо в аккаунте ([help](https://help.housecallpro.com/en/articles/358424-how-do-i-set-my-bank-account-for-payouts)); email-донабор Stripe регулярно теряется (циклы «verification unsuccessful» у Joist/WePay).
7. **KPI: % онбордингов без касания саппорта** — Booksy: **97%** провайдеров онбордятся без участия человека ([case](https://stripe.com/customers/booksy)); Mindbody: −80% ручных ревью ([Coris](https://www.coris.ai/blogs/mindbody-reduces-manual-smb-onboarding-by-80-in-45-countries)).
8. **Линки не пересылать** («Don't email, text, or otherwise send account link URLs») — одноразовые, съедаются превью-ботами; всегда генерировать в момент клика.
9. **Embedded — фронтир SMB-категории, hosted — надёжный мейнстрим**: FreshBooks «within minutes, не покидая платформу» ([case](https://stripe.com/customers/freshbooks)); Substack 4 года не трогал hosted-код ([case](https://stripe.com/customers/substack)). Шероховатости embedded на web: первый auth-шаг открывал hosted-вкладку/попап ([connect-js #124](https://github.com/stripe/connect-js/issues/124)) — проверить на iOS-пилоте.
10. **Deferred onboarding** («принимай сейчас, KYC при деньгах») — широко используемый паттерн (PayPal [after-payment](https://developer.paypal.com/docs/multiparty/seller-onboarding/after-payment/), Shopify, Depop) **без опубликованных A/B-цифр**; переносит трение в «где мои деньги». Для нас безопасная часть — оффер в момент ценности вместо голого toggle (M5). Детали и пороги — [research.md](research.md).

> Убран пункт про **Instant Payouts** как стимул активации: это платформенный рычаг только при liability-модели (`losses=application`) + настроенных Platform controls; на нашем Standard + `losses=stripe` его не surface-нуть из приложения ([instant-payouts](https://docs.stripe.com/connect/instant-payouts)). Про тип аккаунта — Рекомендации п.2.

## Рекомендации (план работ)

1. **Префилл в `PreAuth`** (`StripeAccountClient.cs:93`; данные через `StripeAccountRequest` из `PaymentsService.cs:146`) — лечит C2/M1/M2/M3, переиспользуется этапом 2. Учесть конфликт с networked onboarding (см. предложение «две кнопки» — **не решено**): либо развилка с созданием аккаунта в момент выбора «есть Stripe / нет Stripe» и параметризацией payload, либо один зафиксированный payload-компромисс.
2. **Тип аккаунта — только Standard** (решено 2026-07): `losses.payments=stripe` (отрицательные балансы несёт Stripe, не мы) + полный Stripe Dashboard у подключённого аккаунта. Напоминание: тип перманентен — смена возможна только для новых аккаунтов.
3. **Авто-возврат**: `success_onboarding.html` → мгновенный redirect на `invoices://`/`tofu://finish_stripe_connection` + починить детект успеха на iOS (C4/M6).
4. **Осознанный `collection_options.fields`** вместо текущего флага.
5. **Статусная модель** (C1): success по `details_submitted`, Connected по `charges_enabled` (вебхук есть), «Activate» после сабмита не показывать; ожидание первой выплаты на success-экране.
6. **Этап 2 — embedded**: iOS подключает StripeConnect SDK + `.onboarding` через существующий account-session эндпоинт; воронка — свои экраны (onStepChange на iOS нет); статус-баннеры свои (notification_banner на iOS нет).
7. **Шаг банка**: рассмотреть `external_account_collection=false` (dahlia) + донабор позже.
8. **Ремедиация**: `requirements.only` + `errors[].reason` как текст. Брошенные аккаунты: удалить live Standard через API **нельзя** ([API delete](https://docs.stripe.com/api/accounts/delete)) — проверить фактическое поведение `deleteOld` на live; рабочая схема — бросать аккаунт и создавать новый (перепривязка через `Metadata[AccountId]`).

## Ключевые источники

[hosted-onboarding](https://docs.stripe.com/connect/hosted-onboarding) · [embedded-onboarding](https://docs.stripe.com/connect/embedded-onboarding) · [account-onboarding component](https://docs.stripe.com/connect/supported-embedded-components/account-onboarding) · [API accounts/create](https://docs.stripe.com/api/accounts/create) · [account_links](https://docs.stripe.com/api/account_links/create) · [account_sessions](https://docs.stripe.com/api/account_sessions/create) · [controller](https://docs.stripe.com/connect/migrate-to-controller-properties) · [networked onboarding](https://docs.stripe.com/connect/networked-onboarding) · [dahlia changelog](https://docs.stripe.com/changelog/dahlia/2026-03-25/relaxed_external_account_collection_account_session) · [онбординг-редизайн +5.3%](https://stripe.com/blog/connect-express-onboarding) · [Sessions 2025](https://stripe.com/blog/top-product-updates-sessions-2025) · [stripe-ios CHANGELOG](https://github.com/stripe/stripe-ios/blob/master/CHANGELOG.md) — полный список и весь след: [research.md](research.md)
