# WEB-1479 — Добавить проброс авторизации в web view из мобилки

**Status:** planning
**Started:** 2026-06-03
**ClickUp:** https://app.clickup.com/t/WEB-1479
**Affected repos:** `Tofu.Auth.Backend` (producer), `Invoices.Backend` (BFF) — clients: iOS app, Web app

## Goal

Авторизованный пользователь в мобильном приложении должен иметь возможность открыть веб-приложение в **Safari** (внешний браузер) уже залогиненным под **тем же аккаунтом**, без повторного ввода логина. Для этого сервер выдаёт короткоживущий одноразовый токен для уже аутентифицированного пользователя; мобилка открывает Safari, передавая токен; веб обменивает его на **Firebase custom token** и логинится через Firebase SDK (`signInWithCustomToken`). На первом этапе — простой флоу: после логина пользователь попадает на **главную страницу веб-аппа**.

> Оригинальная формулировка задачи: «Добавить проброс авторизации в web view из мобилки. Изучить варианты передачи токенов (ID токен vs кастомный токен), исследовать механизмы безопасности и сделать технический план реализации авторизации через Firebase. Хотим авторизовывать в Safari браузере. Продумать, где будет храниться роутинг переходов на финальные страницы. Сначала делаем простой флоу с тем, что пользователи попадают на главную веб-аппа.»

## Key finding — most of this already exists

Tofu.Auth уже содержит почти весь нужный примитив (фича **WEB-795**, миграция `20251210112335_WEB-795_InvitationMagicTokens`):

- **`InvitationMagicToken`** — одноразовый токен: Base64Url(32 байта), в БД хранится только **SHA256-хэш**, TTL по умолчанию **12 часов**, поле `UsedAt` для single-use.
  - Модель: `Tofu.Auth.Domain/Models/InvitationMagicToken.cs`; утилиты — `Tofu.Auth.Domain/Utils/TokenGenerationUtils.cs` (`GenerateSecureToken`, `ComputeTokenHash`).
- **Анонимный обмен** `POST /v1/invitations/{token}/magic-login` → возвращает **Firebase custom token** (`MagicLoginResponse { CustomToken }`).
  - Сервис: `Tofu.Auth.Application/Services/InvitationProcessingService.ExchangeMagicTokenAsync`.
  - Уже проксируется через BFF: `Invoices.Backend/Src/Invoices.Api/Controllers/InvitationsController.cs`.
- Сервер **умеет минтить** Firebase custom tokens: `Tofu.Auth.Firebase/FirebaseUserLoginPort.GenerateAuthenticationTokenAsync` → `FirebaseAuth.CreateCustomTokenAsync`. Сервис-аккаунт Firebase загружается в `Tofu.Auth.Firebase/DependencyInjection.cs`.
- Существует и второй путь: ID-токен → **session cookie** (`POST /users/authenticated/session-cookie`, 5 дней) → **обмен на custom token** (`GET /users/session-cookie/exchange`, анонимный). См. `SessionCookieService`.

**Вывод:** для WEB-1479 не нужен новый механизм — нужно **обобщить magic-token** с «приглашения» на «хендофф уже аутентифицированного пользователя»: добавить эндпоинт, который для текущего (по JWT) пользователя выпускает одноразовый handoff-токен, и обмен, который отдаёт Firebase custom token для **его собственного** `uid`.

## Options comparison (исследование)

Пять вариантов реализации проброса авторизации, по всем измерениям. **C — рекомендуемый таргет этапа 1**; E — его усиленный вариант.

| | **A · ID-token passthrough** | **B · Custom token in URL** | **C · One-time opaque code** ⭐ | **D · Session cookie** | **E · Code + nonce/PKCE** |
|---|---|---|---|---|---|
| **Суть** | ID-токен мобилки отдаём в веб как есть | сервер минтит custom token, кладём в URL, веб `signInWithCustomToken` | сервер выдаёт одноразовый код (magic-token); веб обменивает его на сервере на custom token | ID-токен → `createSessionCookie` (httpOnly), веб едет на cookie | C + app-генерируемый nonce, привязанный к коду |
| _Mechanics_ | | | | | |
| Сервер минтит | ничего | custom token | одноразовый код → custom token при обмене | session cookie | код + custom token |
| Веб вызывает | — (войти нельзя) | `signInWithCustomToken` | exchange → `signInWithCustomToken` | ничего (cookie авто) | exchange(code,verifier) → `signInWithCustomToken` |
| Логинит Firebase JS SDK | ❌ нет пути | ✅ | ✅ | ❌ (cookie ≠ SDK sign-in) | ✅ |
| _Security_ | | | | | |
| Ценный JWT в URL | ❌ (ID-токен) | ❌ **да (custom token)** | ✅ нет — только opaque код | ✅ нет | ✅ нет |
| Окно replay при утечке URL | ~1 ч, весь аккаунт | ≤1 ч, **полный вход** | секунды–мин, single-use | n/a (httpOnly) | **≈нет** (нужен verifier) |
| Single-use | нет | нет (JWT реплеится) | ✅ да (`UsedAt`) | нет | ✅ да |
| Хранение at-rest | n/a | n/a | только SHA256-хэш | Firebase-managed | только SHA256-хэш |
| Подделать клиентом | n/a | нет (подпись сервис-аккаунта) | нет | нет | нет |
| Отзыв | revoke refresh-token | трудно (до exp) | сжечь код | ✅ revoke сессии | сжечь код |
| Радиус поражения при утечке | **высокий** | **наивысший** | низкий | низкий | **минимальный** |
| _Cost & fit_ | | | | | |
| Бэкенд-усилие | низкое | низкое | **низ–сред (обобщить magic-token)** | низкое (reuse) | среднее |
| iOS-усилие | низкое | низкое | низкое | низкое | сред (хранить verifier) |
| Веб-усилие | n/a (сломано) | низкое | низ–сред (+1 POST) | низкое | среднее |
| Нужна миграция | нет | нет | возможно (nullable `InvitationId` или новая таблица) | нет | возможно |
| Переиспользует код Tofu.Auth | — | частично (`CreateCustomTokenAsync`) | **высоко — `InvitationMagicToken`** | **высоко — `SessionCookieService`** | средне (расширить magic-token) |
| Ложится на существующий паттерн | — | слабо | **сильно (`magic-login`)** | сильно (`session-cookie/exchange`) | средне |
| _Outcome_ | | | | | |
| Работает во внешнем Safari | ❌ | ✅ | ✅ | ✅ | ✅ |
| Долговечность веб-сессии | <1 ч, умирает | durable (refresh) | durable | durable (≤2 нед cookie) | durable |
| Подходит client-side Firebase JS аппу | ❌ | ✅ | ✅ | ❌ mismatch | ✅ |
| **Корректность (работает вообще?)** | ❌ **нет** | ✅ | ✅ | ⚠️ только server-rendered web | ✅ |
| Подходит этапу 1 («на главную») | — | ✅ | ✅ | ✅ | ✅ |
| **Вердикт** | ✗ нельзя залогинить веб | ⚠️ работает, но кладёт мощный JWT в URL | ✅ **рекомендуется** | ✗ не подходит client-side JS аппу | ✅ C + защита от replay (нужно ли на эт.1 — open question) |

**Решение:** **C** — выдавать **одноразовый opaque handoff-token** (как `magic-token`), который веб обменивает по HTTPS на Firebase custom token, и только потом `signInWithCustomToken`. Сам custom token в URL не кладём. E (nonce/PKCE) — апгрейд C, оценить необходимость для этапа 1.

### Sub-decisions (независимы от выбора A–E)

**Транспорт токена в Safari**

| Транспорт | Утечка через history/logs/`Referer` | Сервер видит | Вердикт |
|---|---|---|---|
| Query `?t=` | ❌ да (OWASP / CWE-598; HTTPS не лечит) | да | ✗ избегать |
| **Fragment `#t=`** | ✅ нет (не уходит на сервер, не в Referer) | нет | ✓ **рекомендуется** + `history.replaceState` |
| POST после загрузки | ✅ нет | да (намеренно) | ✓ для вызова exchange |

> **Почему не как в существующем magic-link.** Текущий invitation-флоу кладёт токен в **query** диплинка (`?token=…&ml=…`). Это осознанный компромисс с компенсирующими контролями (single-use + TTL 12 ч + хэш-at-rest), и в email-контексте выбор частично вынужден — фрагмент не переживает часть email-переписывателей ссылок. Но у query там остаётся реальное окно утечки **до погашения** токена: он попадает в access-логи сервера/CDN, в `Referer` к сторонним скриптам и в **сканеры/префетчеры ссылок** почтовиков (SafeLinks/Gmail/AV) — последние умеют даже **сжечь** single-use токен раньше пользователя. Single-use спасает только *после* погашения, не внутри этого окна.
>
> Для WEB-1479 контекст другой и более выгодный: **оба конца наши** — приложение само формирует URL и само открывает Safari, нет почты, нет сканеров, нет переписывателей. Поэтому **фрагмент** здесь — бесплатный апгрейд: убирает всю строку «логи/Referer/сканеры», работает с universal links, а `history.replaceState` стирает токен сразу после чтения. Наследовать query-паттерн смысла нет — ничто к нему не принуждает.

**Хранение handoff-токена**

| Модель | Плюсы | Минусы |
|---|---|---|
| **Reuse `InvitationMagicToken`** (nullable `InvitationId` + `type`) | минимум кода, проверенный путь | пачкает домен приглашений; миграция на ослабление FK |
| **Новая таблица `WebHandoffToken`** | чистое разделение домена | новая таблица + repo + конфиг, дублирование |
| **Stateless signed JWT** (без БД) | нет хранилища и миграции | **нельзя обеспечить single-use** → теряем ключевое свойство |

**iOS browser surface** (решение клиента, влияет на SSO)

| Поверхность | Cookie-store | SSO с Safari пользователя | Для чего |
|---|---|---|---|
| Полный Safari | общий | ✅ да | постоянный логин в реальном браузере |
| `SFSafariViewController` | изолированный (iOS 11+) | ❌ нет | контейнер без Safari SSO |
| `ASWebAuthenticationSession` | общий / ephemeral | ✅ / опц. | purpose-built auth-редирект с callback |

## Recommended flow (этап 1 — iOS открывает главную веб-аппа)

Роутинг финальных страниц — **на стороне iOS**: приложение само выбирает целевую страницу и дописывает handoff-токен во фрагмент; сервер страницу не возвращает (детали и краевые случаи — в [client-flow.md](./client-flow.md)).

```
iOS (logged in, Firebase JWT)
  └─► POST  BFF: /api/authenticate/handoff-tokens   (Authorization: Bearer <Firebase JWT>)
        └─► Tofu.Auth: выпускает одноразовый handoff-token для текущего uid,
            хранит SHA256-хэш + TTL(секунды) + UsedAt, возвращает RAW token
  ◄── { token }
  └─► выбирает целевую страницу (этап 1 — главная) и открывает внешний браузер:
      https://app.../<путь>#t=<token>            (токен во ФРАГМЕНТЕ, не в query)
        Web (бутстрап, на любой странице):
          1. читает токен из location.hash, сразу history.replaceState (вычищает URL)
          2. POST BFF: /api/authenticate/handoff-tokens/exchange { token }  (анонимный, HTTPS)
                └─► Tofu.Auth: валидирует (не использован, не истёк), помечает UsedAt,
                    минтит Firebase custom token для uid, возвращает его
          3. firebase.auth().signInWithCustomToken(customToken)
          4. остаётся на открытой странице
```

## Доработки по сторонам

Чек-лист по компонентам (вариант **C**). Основной код — в Tofu.Auth (переиспользуем magic-token), остальное тонкое.

### Tofu.Auth.Backend (producer) — основная работа
- [ ] **Выпуск** handoff-токена: эндпоинт под `[Authorize]`, берёт `uid` из Firebase JWT, генерирует одноразовый opaque-токен (`TokenGenerationUtils.GenerateSecureToken`), хранит **SHA256-хэш** + `UserId` + `ExpiresAt` (2–5 мин) + `UsedAt=null`, возвращает RAW-токен.
- [ ] **Обмен** (анонимный): RAW-токен → поиск по хэшу → проверка «не истёк / не использован» → пометить `UsedAt` → минт Firebase custom token (`FirebaseUserLoginPort.GenerateAuthenticationTokenAsync` уже есть) → вернуть.
- [ ] **Хранилище + миграция**: обобщить `InvitationMagicToken` (nullable `InvitationId` + `type`) **или** новая таблица `WebHandoffToken` (open question).
- [ ] **Тесты**: unit (генерация/валидация) + functional (выпуск; обмен → custom token; повторный обмен → 410; истёкший → ошибка).

### Invoices.Backend (BFF / consumer) — проксирование
- [ ] `POST /api/authenticate/handoff-tokens` (с JWT) → зовёт Tofu.Auth, отдаёт `{ token }` — новый экшен в существующем `AuthenticateController` (решено, см. Code layout). Целевую страницу сервер не возвращает — роутинг на стороне iOS.
- [ ] `POST /api/authenticate/handoff-tokens/exchange` (анонимный) → зовёт Tofu.Auth, отдаёт `{ customToken }`.
- [ ] Транспорт BFF↔Auth — REST через NuGet `Tofu.Auth.Api.Client` (resolved, см. Code layout).
- [ ] Integration-тест в `Invoices.IntegrationTests` (`IAuthenticateClient` + `AuthenticateControllerTests`).

### iOS (клиент — вне backend-репозиториев, в плане; краевые случаи — в [client-flow.md](./client-flow.md))
- [ ] Перед открытием браузера вызвать `POST /api/authenticate/handoff-tokens` со своим Firebase JWT (новый токен на каждый тап).
- [ ] Выбрать целевую страницу (этап 1 — главная) и сформировать URL **с токеном во фрагменте**: `https://app.tofu.com/<путь>#t=<token>`.
- [ ] Открыть внешний браузер (полный Safari / `ASWebAuthenticationSession` — см. таблицу iOS-surface; фактически откроется браузер по умолчанию).

### Web app (клиент — вне backend-репозиториев, в плане; краевые случаи — в [client-flow.md](./client-flow.md))
- [ ] Бутстрап приложения (любая страница): читать `location.hash` → сразу `history.replaceState` (стереть токен, сохранив path/query).
- [ ] `POST /api/authenticate/handoff-tokens/exchange { token }` по HTTPS (once-guard от двойного вызова).
- [ ] `firebase.auth().signInWithCustomToken(customToken)` → остаться на открытой странице (этап 1 — iOS открывает главную).

## Code layout

Раскладка нового кода по репозиториям (имена — по решению из [web-spike](./web-spike.md): сущность **`HandoffToken`**, таблица `HandoffTokens`, enum `Purpose` для будущих сценариев обмена на custom token). Структура выверена по существующему magic-token-срезу. Важное отличие от прецедента: `InvitationMagicToken` — дочерняя сущность агрегата `InvitationToken` (без своего репозитория), а `HandoffToken` — самостоятельный агрегат (FK на `User`), поэтому получает собственную пару репозиториев.

### Tofu.Auth.Backend (producer)

```
src/Tofu.Auth.Domain/
  Models/HandoffToken.cs                                  # Id, TokenHash, UserId, Purpose, ExpiresAt, UsedAt, CreatedAt
                                                         #   private ctor + static Create(...) — образец: InvitationMagicToken.cs
  Models/HandoffTokenPurpose.cs                           # enum { WebHandoff } — точка расширения для будущих сценариев
  Repositories/IHandoffTokenRepository.cs                 # самостоятельный агрегат → свой порт
  Configuration/HandoffTokenConfig.cs                     # TTL (60–120 с) — образец: Configuration/InvitationConfig.cs
  Exceptions/InvalidHandoffTokenException.cs              # образец: Exceptions/MagicLoginException.cs
  Utils/TokenGenerationUtils.cs                          # СУЩЕСТВУЕТ — GenerateSecureToken + ComputeTokenHash, без изменений;
                                                         #   префикс tht_ дописывается при выпуске (в HandoffToken.Create/сервисе),
                                                         #   хэш считается от полной строки с префиксом
  DependencyInjection.cs                                 # touch: регистрация нового

src/Tofu.Auth.Application/
  Services/IHandoffTokenService.cs                        # issue (uid через IAuthenticatedUserAccessor) + exchange
  Services/HandoffTokenService.cs                         #   exchange: атомарный claim → минт custom token (существующий Firebase-порт)
  Dto/Responses/IssueHandoffTokenResponse.cs              # образец: Dto/Responses/MagicLoginResponse.cs
  DependencyInjection.cs                                 # touch

src/Tofu.Auth.Contracts/
  HandoffTokens/IssueHandoffTokenResponse.cs               # wire-контракты, общие с Api.Client —
  HandoffTokens/ExchangeHandoffTokenRequest.cs             #   образец: Invitations/MagicLoginRequest|Response.cs
  HandoffTokens/ExchangeHandoffTokenResponse.cs            #   { customToken }

src/Tofu.Auth.Persistence/
  Database/EntityConfigurations/HandoffTokenConfiguration.cs  # ToTable("HandoffTokens"); UNIQUE(TokenHash); index(ExpiresAt)
  Database/AuthContext.cs                                # touch: DbSet<HandoffToken>
  Repositories/HandoffTokenRepository.cs                  # вкл. атомарный claim (conditional UPDATE WHERE UsedAt IS NULL)
  Migrations/<ts>_WEB-1479_HandoffTokens.cs               # dotnet ef migrations add WEB-1479_HandoffTokens …
  DependencyInjection.cs                                 # touch: AddRepositories

src/Tofu.Auth.Api/
  Controllers/HandoffTokensController.cs                  # POST /v1/handoff-tokens [Authorize]
                                                         # POST /v1/handoff-tokens/exchange [AllowAnonymous]
  appsettings*.json                                      # touch: секция TTL
  (HostedServices/ExpiredHandoffTokenCleanup.cs)          # НОВОЕ, если этап 1 включает reaper — hosted-service-инфраструктуры
                                                         #   в сервисе сейчас нет (проверено); решить на /plan write

src/Tofu.Auth.Api.Client/
  TofuAuthApiClient.cs                                   # touch: IssueHandoffTokenAsync / ExchangeHandoffTokenAsync

tests/
  Tofu.Auth.Domain.UnitTests/Models/HandoffTokenTests.cs
  Tofu.Auth.Application.UnitTests/Services/HandoffTokenServiceTests.cs
  Tofu.Auth.Api.Tests.Functional/Full/HandoffTokensTests.cs   # issue→exchange; повтор→ошибка; истёкший→ошибка;
                                                             #   ПАРАЛЛЕЛЬНЫЙ двойной exchange → ровно один custom token
```

### Invoices.Backend (BFF / consumer)

Транспорт BFF↔Tofu.Auth — **REST через NuGet `Tofu.Auth.Api.Client`** (`ITofuAuthApiClient` + `TofuAuthApiClientDecorator` в `Src/Tofu.Auth/`) — это закрывает open question про REST/gRPC.

```
Src/Invoices.Api/
  Controllers/AuthenticateController.cs                  # touch: два новых экшена в существующем контроллере
                                                         #   (Route("api/authenticate"), ITofuAuthApiClient уже инжектится)
                                                         # POST /api/authenticate/handoff-tokens  [авторизован] → { token }
                                                         # POST /api/authenticate/handoff-tokens/exchange [аноним, AllowAnonymous] → { customToken }
  Models/Authenticate/WebHandoffResponseDto.cs           # DTO этого контроллера живут в Models/Authenticate/,
  Models/Authenticate/ExchangeWebHandoffRequestDto.cs    #   не в Dto/ — следуем его конвенции
  Models/Authenticate/ExchangeWebHandoffResponseDto.cs

Src/Tofu.Auth/                                           # BFF-модуль Auth — обёртка над NuGet Tofu.Auth.Api.Client
  TofuAuthApiClientDecorator.cs                          # touch: pass-through для двух новых методов клиента
  AuthApiExceptionConverter.cs                           # touch: маппинг ошибок handoff-токена (invalid/expired/used → 4xx)
  Tofu.Auth.csproj                                       # touch: bump Tofu.Auth.Api.Client после публикации producer'а

Src/Invoices.IntegrationTests/
  Clients/IAuthenticateClient.cs                         # touch: два новых метода в существующем Refit-клиенте api/authenticate
  Tests/Controllers/AuthenticateControllerTests.cs       # touch/новые тесты — образец: InvitationsControllerTests.cs
  Setup/MockSetup.cs                                     # touch: моки новых методов ITofuAuthApiClient
```

**Порядок выката:** PR в Tofu.Auth → merge → `publish-client.yaml` публикует клиентский NuGet → деплой Tofu.Auth → PR в BFF (bump пакета + прокси). BFF физически не соберётся раньше публикации NuGet.

## Scope

- **In scope (этап 1):**
  - Backend-примитив выдачи + обмена handoff-токена для **уже аутентифицированного** пользователя (обобщение magic-token).
  - Возврат Firebase custom token; логин в Safari через Firebase SDK.
  - Роутинг финальных страниц — **на стороне iOS** (сервер целевую страницу не возвращает); на этапе 1 iOS открывает **главную веб-аппа**.
  - Передача токена через **URL-фрагмент**, single-use, короткий TTL.
- **Out of scope (последующие этапы):**
  - Новые целевые страницы за пределами главной — добавляются на стороне iOS без изменений бэкенда.
  - Привязка к nonce/PKCE-style (defense-in-depth) — оценить, нужно ли на этапе 1.
  - `ASWebAuthenticationSession` vs полноценный Safari (решение на стороне iOS).

## Affected repos

- `Tofu.Auth.Backend` (**producer**) — новый эндпоинт выдачи handoff-токена (требует JWT, берёт `uid` из токена) + анонимный эндпоинт обмена, возвращающий Firebase custom token. Реализация переиспользует/обобщает `InvitationMagicToken`-инфраструктуру (генерация, хэширование, single-use, TTL).
- `Invoices.Backend` (**consumer / BFF**) — проксирующие эндпоинты `handoff-tokens` (выпуск) и `handoff-tokens/exchange` (обмен), по образцу существующего проксирования `magic-login` в `InvitationsController`.

**Cross-repo notes:**
- Producer/consumer порядок: сначала Tofu.Auth (эндпоинты + миграция, если нужна отдельная таблица), затем BFF-прокси.
- Контрактные изменения: новые REST-эндпоинты + (возможно) gRPC между BFF и Tofu.Auth — **аддитивно**.
- Решить: расширять существующую таблицу/модель `InvitationMagicToken` (магик-токен без `InvitationId`) или завести отдельную сущность `WebHandoffToken`. Развязка по чистоте домена vs переиспользование (см. Open questions).

## API / DTO changes

Предварительно (уточнить на `/plan write`):
- `POST /api/authenticate/handoff-tokens` (BFF, **требует JWT**) → `{ token }` — новые экшены в существующем `AuthenticateController`; целевую страницу выбирает iOS, сервер её не возвращает.
- `POST /api/authenticate/handoff-tokens/exchange` (BFF, **анонимный**) `{ token }` → `{ customToken }`.
- Полные контракты (конверт `result`/`error`, коды ошибок) — в [client-flow.md](./client-flow.md).
- Соответствующие эндпоинты в Tofu.Auth.Api.
- Всё **аддитивно** — новые эндпоинты, существующие не меняются.

## Breaking changes

None — additive only. Новые эндпоинты и (возможно) новая таблица/поле; существующие контракты, magic-login и session-cookie флоу не затрагиваются. `/feature review` переаудитит против реального диффа.

## Security considerations (исследование)

- **Не класть секрет в query string.** URL утекает через историю браузера, логи серверов/прокси, заголовок `Referer`, аналитику — HTTPS это **не** лечит (OWASP, CWE-598). Класть токен во **фрагмент** (`#`), плюс `Referrer-Policy: no-referrer`, и сразу затирать через `history.replaceState`.
- **Передавать opaque одноразовый код, а не сам Firebase JWT** — высокоценный токен не должен попадать в URL/историю.
- **Single-use + очень короткий TTL** (минуты), хранить только SHA256-хэш — как уже сделано для `InvitationMagicToken`. Рассмотреть привязку к **nonce**, генерируемому приложением (replay-protection, PKCE-style по образцу RFC 8252).
- **Firebase custom token** минтит только сервис-аккаунт с правом подписи (`roles/iam.serviceAccountTokenCreator`) — это якорь доверия; клиент `uid` не подделает.
- **iOS-поверхность (решение клиента):** полноценный Safari = общая сессия (SSO); `SFSafariViewController` — изолированный cookie-store; `ASWebAuthenticationSession` — purpose-built для auth-редиректов. Влияет на то, попадёт ли сессия в постоянный Safari пользователя.
- **Firebase web persistence:** после `signInWithCustomToken` JS SDK по умолчанию хранит сессию в IndexedDB (origin-scoped) — один хендофф даёт долгоживущую веб-сессию; повторно гонять токены не нужно.

Источники: Firebase Admin (create-custom-tokens, manage-cookies, auth-state-persistence), OWASP query-string exposure / CWE-598, RFC 8252 (OAuth for Native Apps) + PKCE.

## Data / migration

- Если переиспользуем `InvitationMagicToken` без `InvitationId` — нужна миграция (сделать `InvitationId` nullable + поле «тип»/назначение токена).
- Если отдельная сущность `WebHandoffToken` — новая таблица: `Id, TokenHash (unique), UserId, ExpiresAt, UsedAt, CreatedAt`.
- Решение — в Open questions.

## Open questions

- [x] **Где хранится роутинг переходов на финальные страницы?** — **Решено: на стороне iOS.** Приложение само выбирает целевую страницу и строит URL; сервер страницу не возвращает. Новые цели добавляются без изменений бэкенда (ограничения на целевые пути — без редиректов, вне `applinks` — см. [client-flow.md](./client-flow.md)).
- [ ] Переиспользовать таблицу `InvitationMagicToken` (nullable `InvitationId` + тип) **или** завести отдельный `WebHandoffToken`? (чистота домена vs переиспользование).
- [ ] TTL handoff-токена на этапе 1 (предлагаю **2–5 минут**, single-use) — подтвердить.
- [ ] Нужен ли уже на этапе 1 nonce/PKCE-style binding, или достаточно single-use + short TTL + fragment?
- [ ] Транспорт BFF↔Tofu.Auth: REST или gRPC (как существующие вызовы)? Уточнить по текущему паттерну `InvitationsController`.
- [ ] Какой Firebase-проект/origin у веб-аппа и совпадает ли он с мобильным (один Firebase tenant для `uid`)?

## Test plan

- **Unit tests (Tofu.Auth):** генерация handoff-токена (формат, хэширование), валидация обмена — истёкший / уже использованный / неизвестный токен, выпуск только для `uid` из JWT.
- **Integration tests:** end-to-end через реальный эндпоинт — (1) выпуск с валидным JWT, (2) обмен → получаем custom token, (3) повторный обмен тем же токеном → 410/ошибка (single-use), (4) обмен по истечении TTL → ошибка, (5) BFF-прокси проксирует корректно. Functional-проект Tofu.Auth (Testcontainers + Postgres) + `Invoices.Tests.Integration` для BFF.
- **Manual:** iOS открывает Safari → веб логинится под тем же аккаунтом → попадает на главную; проверить, что токен не остаётся в URL/истории.

## References

Паттерн «backend минтит custom token → клиент `signInWithCustomToken`» — стандартный для Firebase; примеров переноса сессии между приложением и вебом много.

**Firebase (официально):**
- [Create custom tokens (Admin SDK)](https://firebase.google.com/docs/auth/admin/create-custom-tokens) — минт custom token сервером, ограничение «≤1 ч до погашения», требования к сервис-аккаунту.
- [Authenticate with Firebase in JS using a custom auth system](https://firebase.google.com/docs/auth/web/custom-auth) — веб-сторона: `signInWithCustomToken`.
- [Auth state persistence (web)](https://firebase.google.com/docs/auth/web/auth-state-persistence) — где JS SDK хранит сессию после входа (IndexedDB/localStorage, origin-scoped).
- [Manage session cookies (Admin SDK)](https://firebase.google.com/docs/auth/admin/manage-cookies) — альтернативный путь (вариант D в таблице), для server-rendered веба.

**Похожие реализации (mobile ↔ web/webview handoff):**
- [react-native-firebase — login via token between web & native (Discussion #5800)](https://github.com/invertase/react-native-firebase/discussions/5800) — обмен custom token между нативом и вебом.
- [Expo WebView auth with Firebase (Medium)](https://medium.com/swlh/expo-webview-facebook-authentication-with-firebase-2b864c031340) — `postMessage`/bridge + Firebase токен в webview.
- [Firebase Authentication using a custom token (Telerik)](https://www.telerik.com/blogs/firebase-authentication-using-custom-token) — end-to-end пример выпуска и использования custom token.
- [Custom token authentication with Firebase (Fcode Labs)](https://www.fcodelabs.com/blogs/custom-token-authentication-with-firebase) — разбор флоу custom-token.

**Безопасность (токен в URL / native-app auth):**
- [OWASP — Information exposure through query strings in URL](https://owasp.org/www-community/vulnerabilities/Information_exposure_through_query_strings_in_url) — почему секрет в query утекает (логи/Referer), и HTTPS это не лечит.
- [CWE-598 — Use of GET request method with sensitive query strings](https://cwe.mitre.org/data/definitions/598.html).
- [RFC 8252 — OAuth 2.0 for Native Apps](https://www.rfc-editor.org/rfc/rfc8252.html) + [PKCE / native apps (oauth.net)](https://oauth.net/2/native-apps/) — модель authorization-code + PKCE, на которую опирается вариант E.

### Что берём из примеров / что адаптируем

Все источники описывают **один примитив**, расходятся только транспортом токена.

**Единодушное ядро (берём как есть):**
- Custom token минтит **только бэкенд** через Admin SDK `createCustomToken(uid, claims)` — на клиенте нельзя (RN #5800, Telerik, Fcode).
- Клиент делает `signInWithCustomToken` → обмен на ID + refresh токены, дальше SDK ведёт сессию сам.
- Custom token = подписанный JWT (ключ сервис-аккаунта), **≤1 ч до погашения**; нужен сервис-аккаунт с ролью **«Service Account Token Creator»** + IAM Service Account Credentials API (Fcode, Telerik). У нас уже есть (`FirebaseUserLoginPort.GenerateAuthenticationTokenAsync`).
- Claims (≤1000 байт) доезжают в ID-токен; persistence после входа — IndexedDB, origin-scoped.

**Что адаптируем под наш контекст:**
- Примеры — это в основном **webview *внутри* приложения с JS-мостом** (`postMessage` / RN bridge): RN #5800, Medium/Expo. У нас — **внешний Safari, моста нет**.
- Поэтому транспорт у нас другой: **одноразовый opaque-код в URL-фрагменте → серверный обмен на custom token** (вариант C). Это закрывает то, что блоги почти не трогают, — **безопасность доставки** токена во внешний браузер (OWASP/CWE, RFC 8252/PKCE).
- Итог: источники дают «**что** минтить и **чем** логиниться», наш план добавляет «**как безопасно довезти**» — единственную часть, не покрытую примерами с webview-мостом.
