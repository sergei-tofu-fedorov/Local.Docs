# WEB-1479 — Implementation plan (этап 1, backend)

Реализация handoff-токена в `Tofu.Auth.Backend` (producer) и `Invoices.Backend` (BFF). Решения зафиксированы в [README](./README.md) и [web-spike](./web-spike.md) (сущность `HandoffToken`, префикс `tht_`, TTL 60–120 с, fragment-транспорт); контракты для клиентов — в [client-flow.md](./client-flow.md). Тесты и клиентские работы (iOS/Web) — вне этого документа.

Все упомянутые файлы-образцы проверены по текущему коду обоих репозиториев (ветки `feature/WEB-1479`).

## 1. Контракты

### 1.1 Tofu.Auth REST (новый контроллер)

| Эндпоинт | Auth | Запрос | Ответ 200 |
|---|---|---|---|
| `POST /v1/handoff-tokens` | `[Authorize]` (Firebase JWT) | пустое тело | `IssueHandoffTokenResponse { Token, ExpiresInSeconds }` |
| `POST /v1/handoff-tokens/exchange` | `[AllowAnonymous]` | `ExchangeHandoffTokenRequest { Token }` | `ExchangeHandoffTokenResponse { CustomToken }` |

- `Token` = `"tht_" + TokenGenerationUtils.GenerateSecureToken()` (32 байта CSPRNG, Base64Url). Хэш — `ComputeTokenHash` от **полной строки с префиксом**. Примитивы существуют (`Tofu.Auth.Domain/Utils/TokenGenerationUtils.cs`), не меняются.
- `uid` для выпуска берётся **только** из JWT текущего пользователя: `IAuthenticatedUserAccessor.GetAuthenticatedUserInfo().User` (паттерн `InvitationProcessingService.GetCurrentUser()`).
- Custom token минтится существующим портом: `IExternalUserLoginPort.GenerateAuthenticationTokenAsync(externalUserId, ct)` → `FirebaseAuth.CreateCustomTokenAsync`.

### 1.2 Ошибки Tofu.Auth (ProblemDetails)

Паттерн — magic-login (`MagicLoginException` → 410 Gone в `ExceptionConfiguration.cs:177`):

| Ситуация | `type` (новые константы в `Tofu.Auth.Common/Errors/AuthErrorTypes.cs`) | HTTP |
|---|---|---|
| Токен не найден / мусор | `invalid_handoff_token` | 410 Gone |
| TTL истёк | `handoff_token_expired` | 410 Gone |
| Уже погашен | `handoff_token_used` | 410 Gone |

Бросает `HandoffTokenException(reason)` с enum-reason `Invalid / Expired / Used` — зеркало `MagicLoginErrorReason`.

### 1.3 BFF REST (новые экшены в существующем `AuthenticateController`, `Route("api/authenticate")`)

Конверт стандартный: успех `{ "result": { … } }`, ошибка `{ "error": { "code", "message", "traceId" } }`.

| Эндпоинт | Auth | Ответ 200 (`result`) |
|---|---|---|
| `POST /api/authenticate/handoff-tokens` | авторизован (как остальные действия BFF) | `{ "token": "tht_…", "expiresInSeconds": 120 }` |
| `POST /api/authenticate/handoff-tokens/exchange` | `[AllowAnonymous]` | `{ "customToken": "<Firebase custom token>" }` |

**Ошибки обмена через BFF — решение open question из client-flow:** следуем прецеденту magic-login. `AuthApiExceptionConverter` конвертирует известные типы в `InvoicesAuthApiException` со статусом **400 BadRequest** (тип НЕ добавляем в `PropagateToClientErrorTypes`), middleware рендерит `error.code` = тот же `type`-string из Tofu.Auth. Контракт для веба — строка `error.code` (`invalid_handoff_token` / `handoff_token_expired` / `handoff_token_used`), не HTTP-статус — ровно как зафиксировано в client-flow.md.

## 2. Tofu.Auth.Backend — раскладка кода

Срез-образец — magic-token: модель `InvitationMagicToken`, сервис `InvitationProcessingService.ExchangeMagicTokenAsync`, контроллер `InvitationsController.MagicLoginAsync`. Отличие: `HandoffToken` — самостоятельный агрегат (FK на `User`), поэтому своя пара репозиториев.

```
src/Tofu.Auth.Domain/
  Models/HandoffToken.cs                 # Id, TokenHash, UserId (FK→User), ExpiresAt, UsedAt, CreatedAt, UpdatedAt
                                         #   private ctor + [SetsRequiredMembers] + static Create(userId, tokenHash, ttl)
                                         #   IsExpired()/IsUsed — образец: InvitationMagicToken.cs (1:1 по стилю)
                                         #   Purpose-дискриминатор отложен до второго сценария (см. §5)
  Repositories/IHandoffTokenRepository.cs        # Insert + FindByTokenHashAsync + атомарный claim (см. Persistence);
                                                 #   единственный запрос — по хэшу, поэтому именованный метод,
                                                 #   без LinqSpecs-спецификаций (прецедент: CountByTenantSinceAsync)
  Configuration/HandoffTokenConfig.cs    # SectionName = "HandoffToken"; HandoffTokenTtl (default 120 c)
                                         #   образец: InvitationConfig.cs (MagicTokenTtl)
  Exceptions/HandoffTokenException.cs    # enum HandoffTokenErrorReason { Invalid, Expired, Used } + exception
                                         #   образец: MagicLoginException.cs
  ExceptionConfiguration.cs              # touch: HandleException<HandoffTokenException> → 410 Gone,
                                         #   reason switch → три новых AuthErrorTypes (образец: MagicLoginException, :177)

src/Tofu.Auth.Common/
  Errors/AuthErrorTypes.cs               # touch: + InvalidHandoffToken / HandoffTokenExpired / HandoffTokenUsed
                                         #   ("invalid_handoff_token" / "handoff_token_expired" / "handoff_token_used")

src/Tofu.Auth.Application/
  Services/IHandoffTokenService.cs       # IssueAsync(ct) / ExchangeAsync(rawToken, ct)
  Services/HandoffTokenService.cs        # Issue: uid из IAuthenticatedUserAccessor; "tht_"+GenerateSecureToken();
                                         #   сохранить хэш, вернуть RAW + ExpiresInSeconds (из конфига)
                                         # Exchange: hash lookup → атомарный claim (репозиторий) →
                                         #   User.ExternalUserId → IExternalUserLoginPort.GenerateAuthenticationTokenAsync
                                         #   reuse-попытку логировать как leak-сигнал (web-spike Q3)
  Dto/Responses/IssueHandoffTokenResponse.cs     # app-уровневый ответ — образец: Dto/Responses/MagicLoginResponse.cs

src/Tofu.Auth.Contracts/
  HandoffTokens/IssueHandoffTokenResponse.cs     # record (string Token, int ExpiresInSeconds)
  HandoffTokens/ExchangeHandoffTokenRequest.cs   # record (string Token)
  HandoffTokens/ExchangeHandoffTokenResponse.cs  # record (string CustomToken)
                                                 #   образец: Invitations/MagicLoginRequest|Response.cs

src/Tofu.Auth.Persistence/
  Database/EntityConfigurations/HandoffTokenConfiguration.cs
                                         # ToTable("HandoffTokens"); HasIndex(TokenHash).IsUnique(); HasIndex(ExpiresAt);
                                         #   FK на Users (uid при exchange достаём join'ом по UserId)
  Database/AuthContext.cs                # touch: DbSet<HandoffToken>
  Repositories/HandoffTokenRepository.cs # атомарный claim: ExecuteUpdate … WHERE TokenHash=@h AND UsedAt IS NULL
                                         #   AND ExpiresAt > now() → rowsAffected==1 = выиграли (web-spike Q4);
                                         #   0 строк → перечитать ряд и бросить Used/Expired/Invalid по состоянию
  Migrations/<ts>_WEB-1479_HandoffTokens.cs      # dotnet ef migrations add WEB-1479_HandoffTokens …

src/Tofu.Auth.Api/
  Controllers/HandoffTokensController.cs # POST v1/handoff-tokens [Authorize] (класс-уровень, как InvitationsController)
                                         # POST v1/handoff-tokens/exchange [AllowAnonymous]
                                         # маппинг app→contract — инлайн в экшене (одна тривиальная проекция;
                                         #   Mappings-файл не заводим — InvitationApiMappings оправдан объёмом)
  appsettings*.json                      # touch: секция "HandoffToken": { "HandoffTokenTtl": "00:02:00" }

src/Tofu.Auth.Api.Client/
  ITofuAuthApiClient.cs                  # touch: + IssueHandoffTokenAsync(ct) / ExchangeHandoffTokenAsync(request, ct)
  TofuAuthApiClient.cs                   # Issue — авторизованный паттерн (AssureJwtExists, как GetTenantInvitationAsync);
                                         # Exchange — анонимный паттерн (как MagicLoginAsync: POST + JsonContent)
```

### 2.1 Структура новых доменных сущностей (`Tofu.Auth.Domain`)

Скелеты без тел методов; стиль и member-набор — 1:1 с magic-token-срезом. DTO/wire-контракты сюда не входят (см. §1).

```csharp
// Models/HandoffToken.cs — самостоятельный агрегат; образец: InvitationMagicToken.cs
public class HandoffToken : IEntity<Guid>
{
    // префикс — часть RAW-токена и хэшируемой строки; greppable при утечке (web-spike)
    public const string TokenPrefix = "tht_";

    [SetsRequiredMembers]
    private HandoffToken(Guid id, string tokenHash, Guid userId, DateTimeOffset expiresAt);

    public required Guid Id { get; init; }
    public required string TokenHash { get; init; }            // SHA-256 hex от "tht_<base64url>"
    public required Guid UserId { get; init; }                 // FK → User; uid берём из User.ExternalUserId
    public required DateTimeOffset ExpiresAt { get; init; }
    public required DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset? UpdatedAt { get; private set; }
    public DateTimeOffset? UsedAt { get; private set; }        // mark-used; реап по ExpiresAt — follow-up

    // Navigation
    public User? User { get; private set; }

    public bool IsExpired();                                   // DateTimeOffset.UtcNow > ExpiresAt
    public bool IsUsed { get; }                                // UsedAt.HasValue

    internal static HandoffToken Create(Guid userId, string tokenHash, TimeSpan ttl);
}
```

> Намеренное отличие от `InvitationMagicToken`: **нет `MarkAsUsed()`** на сущности. Claim обязан быть атомарным (web-spike Q4), поэтому погашение — set-based условный `UPDATE` в репозитории; перечитанная после проигранного claim'а сущность используется только для диагностики (`IsUsed` / `IsExpired` → reason ошибки).

```csharp
// Exceptions/HandoffTokenException.cs — образец: MagicLoginException.cs
public enum HandoffTokenErrorReason
{
    Invalid,
    Expired,
    Used,
}

public class HandoffTokenException(HandoffTokenErrorReason reason, string message)
    : Exception(message)
{
    public HandoffTokenErrorReason Reason { get; } = reason;
}

// Configuration/HandoffTokenConfig.cs — образец: InvitationConfig.cs
public class HandoffTokenConfig
{
    public const string SectionName = "HandoffToken";

    [Required]
    public TimeSpan HandoffTokenTtl { get; set; } = TimeSpan.FromSeconds(120);
}

// Repositories/IHandoffTokenRepository.cs — именованные методы вместо LinqSpecs:
//   запрос ровно один (по хэшу), спецификации не окупаются (прецедент: CountByTenantSinceAsync)
public interface IHandoffTokenRepository
{
    Task InsertAsync(HandoffToken token, CancellationToken ct);

    Task<HandoffToken?> FindByTokenHashAsync(string tokenHash, CancellationToken ct);

    /// Атомарный claim: UPDATE … SET UsedAt = now WHERE TokenHash = @hash
    ///   AND UsedAt IS NULL AND ExpiresAt > now; true ⇔ ровно этот вызов погасил токен.
    Task<bool> TryClaimAsync(string tokenHash, CancellationToken ct);
}
```

Поток exchange по этим контрактам: `TryClaimAsync(hash)` → `true` ⇒ `FindByTokenHashAsync` (ряд уже погашен этим вызовом) → `User.ExternalUserId` → минт custom token; `false` ⇒ `FindByTokenHashAsync` → `null` ⇒ `Invalid`, `IsUsed` ⇒ `Used`, `IsExpired()` ⇒ `Expired`.

Намеренно вне этапа 1: reaper протухших строк (hosted-service-инфраструктуры в сервисе нет, объём строк ничтожный — TTL минуты). Зафиксировать follow-up: одна джоба-чистильщик на оба токен-вида (`InvitationMagicToken` + `HandoffToken`), референс — Duende cleanup (web-spike Q5).

## 3. Invoices.Backend — раскладка кода

Срез-образец — проксирование magic-login: `InvitationsController.MagicLogin` (`:153`) + `TofuAuthApiClientDecorator.MagicLoginAsync` (`:185`) + `AuthApiExceptionConverter`.

```
Src/Invoices.Api/
  Controllers/AuthenticateController.cs  # touch: два новых экшена; ITofuAuthApiClient уже инжектится
                                         # POST handoff-tokens          → декоратор → { token, expiresInSeconds }
                                         # POST handoff-tokens/exchange [AllowAnonymous] → { customToken }
  Models/Authenticate/WebHandoffResponseDto.cs           # { Token, ExpiresInSeconds } — DTO контроллера живут здесь
  Models/Authenticate/ExchangeWebHandoffRequestDto.cs    # { Token } ([Required])
  Models/Authenticate/ExchangeWebHandoffResponseDto.cs   # { CustomToken }
                                         # маппинг contract→DTO тривиальный — инлайн в экшене либо
                                         #   extension рядом (образец: Dto/Invitations/Mapping.cs)

Src/Tofu.Auth/                           # BFF-обёртка над NuGet Tofu.Auth.Api.Client
  TofuAuthApiClientDecorator.cs          # touch: pass-through двух новых методов через существующий
                                         #   конвертирующий враппер (образец: MagicLoginAsync, :185)
  AuthApiExceptionConverter.cs           # touch: три новых AuthErrorTypes → в KnownErrorTypes
                                         #   (НЕ в PropagateToClientErrorTypes → BFF отдаст 400 + error.code)
  Tofu.Auth.csproj                       # touch: bump версии Tofu.Auth.Api.Client после публикации producer'а

Src/Invoices.Api/Middleware/ApiExceptionHandlingMiddleware.cs
                                         # touch: FriendlyAuthErrorMessages — записи для трёх новых кодов
                                         #   (иначе fallback-сообщение; код ошибки клиенту уходит в error.code)
```

## 4. Порядок выката

1. **Tofu.Auth.Backend** (PR в `develop`): домен + миграция + контроллер + Api.Client-методы. Миграция применяется деплоем (additive: одна новая таблица).
2. Merge → `publish-client.yaml` публикует NuGet `Tofu.Auth.Api.Client` → деплой Tofu.Auth.
3. **Invoices.Backend** (PR в `master`): bump NuGet + прокси-экшены + конвертер ошибок. Физически не соберётся раньше публикации пакета — порядок самоконтролируемый.

Всё аддитивно: новая таблица, новые эндпоинты, новые константы ошибок; существующие magic-login / session-cookie флоу не затронуты.

## 5. Зафиксированные в этом плане решения

| Вопрос (из README/client-flow) | Решение |
|---|---|
| HTTP-статус ошибок обмена через BFF | **400** + `error.code` (прецедент magic-login: `KnownErrorTypes` без propagate); 410 остаётся только на стороне Tofu.Auth |
| TTL этапа 1 | **120 с** default в `HandoffTokenConfig` (верх диапазона web-spike — запас на холодный старт браузера), конфигурируемо |
| Атомарный claim | условный `ExecuteUpdate` в репозитории (rowcount==1); `ConcurrentUpdateInterceptor` не задействуем — claim-форма проще и самодокументируема |
| Reaper протухших строк | вне этапа 1, follow-up на оба токен-вида |
| nonce/PKCE | не делаем на этапе 1 (single-use + 120 c + fragment); архитектура C→E расширяема без ломки контракта |
| Имя таблицы при наличии будущих сценариев | **`HandoffTokens` остаётся** (генеричное `OneTimeTokens` отклонено). Граница таблицы: только токены, чей обмен минтит Firebase custom token для **уже аутентифицированного** пользователя (session-handoff-семейство). Другие одноразовые артефакты (verification/reset/invitations) — свои таблицы, по прецеденту сервиса. Даже Supabase `one_time_tokens` скоупит таблицу одним семейством (verification-коды), не смешивая с flow state. Это закрывает open question web-spike «все ли будущие exchange-сценарии — session handoffs»: не handoff → не эта таблица |
| Поле `Purpose` (дискриминатор сценария) | **Отложено до второго сценария.** Строки эфемерны (TTL ≤ 120 c) → поздняя миграция `ADD COLUMN … DEFAULT 1` бесплатна; в wire-контрактах поле не фигурирует; purpose-проверка в claim (`AND Purpose=@expected`, прецедент Keycloak #27357) осмысленна только при ≥2 значениях и приедет тем же PR. Стадия 1 без single-value enum |
| Размещение эндпоинтов: `UsersController` (рядом с session-cookie exchange) vs свой контроллер | **Рассмотрено и отклонено** — остаётся отдельный `HandoffTokensController`. Per-resource контроллеры — действующий паттерн сервиса (`OneTimePasswordsController` — тоже пара issue/exchange, `InvitationsController` с `v1/`-маршрутами); session-cookie в `UsersController` — legacy-размещение без `v1/`. Перенос ломал бы route-префикс `users` либо wire-пути `v1/handoff-tokens`, уже зафиксированные в контрактах и клиенте |
| Общий exception/reason c magic-token | **Рассмотрено и отклонено** — `HandoffTokenException` остаётся отдельным. Wire-строки ошибок всё равно требуют per-kind таблицу (`invalid_magic_token` vs `handoff_token_*`), общий enum связывает эволюцию двух разных агрегатов, а фича перестаёт быть чисто аддитивной (трогает shipped `MagicLoginException`). Прецедент в кодовой базе — два параллельных reason-enum'а (`InvitationTokenErrorReason`, `MagicLoginErrorReason`). Пересмотреть при появлении третьего exchange-флоу (rule of three) |
