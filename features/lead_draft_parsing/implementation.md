# Lead Parsing — Implementation

> Phase 2 of the Lead Parsing plan. For the problem analysis, system overview,
> API contracts and decisions, see [`plan.md`](./plan.md).

Bottom-up: config → types → OpenAI client → validators → service → API → error+DI → eval tool → full test run → new tests.

Все новые namespaces:

- `Invoices.Common.Services.LeadParsing` — интерфейсы, records, prompt constants, settings
- `Invoices.Implementation.Services.LeadParsing` — OpenAiClient, LeadParsingService, TimeAnchorResolver, FieldValidator
- `Invoices.Api.Controllers.LeadParsingController`, DTOs в `Invoices.Api/Dto/LeadParsing/`
- Eval tool: новый проект `Src/Invoices.Tools.LeadParsingEval/`

## Step 1: Configuration & Feature Flags

**Files (new):**

- `Src/Invoices.Common/Services/LeadParsing/OpenAiSettings.cs`
- `Src/Invoices.Common/Services/LeadParsing/LeadParsingSettings.cs`

**Files (modified):**

- `Src/Invoices.Api/appsettings.json` — добавить секции `OpenAi` и `LeadParsing` (секретный `ApiKey` = `""`, реальный через GSM / env var)
- `Src/Invoices.Api/appsettings.Development.json` — локальные dev-значения (пустой `ApiKey`, `TextEnabled=true`, `VoiceEnabled=true`)

DI wiring делаем в Step 7 вместе с остальной регистрацией сервисов.

`OpenAiSettings` — структура с вложенными `Extraction` / `Transcription` / `Retry` как в JSON из Phase 1. Все duration-поля — `TimeSpan`, сериализация строковая (`"00:00:10"`). `[Required]` аннотации + `[Range]` для `Temperature`, `MaxOutputTokens`, `MaxAttempts`.

`LeadParsingSettings` — `TextEnabled`, `VoiceEnabled` + вложенные `Text` (MinWords, MaxChars) и `Audio` (MaxBytes, AllowedContentTypes).

**NO changes** to `Invoices.DIConfig` — там installer только для Push сейчас; OpenAI installer ставим в Step 7 в `ExternalServicesConfiguration.cs`.

## Step 2: Domain Types (Common layer)

**Files (new), namespace `Invoices.Common.Services.LeadParsing`:**

### 2.1 Value objects и records (один файл на тип, C# `sealed record`)

- `UserContext.cs` — `UserContext(DateTimeOffset? ClientNow)` — в v1 один field, extensible
- `TimeAnchor.cs` — `TimeAnchor(string AnchorDate, string AnchorTime, string TimezoneOffset, string? TimezoneName, TimeAnchorSource Source)`; `TimeAnchorSource` enum `{ Unknown = 0, Client = 1, ServerFallback = 2 }`
- `ExtractionContext.cs` — `ExtractionContext(string Text, TimeAnchor TimeAnchor)`

### 2.2 Input/output payloads

- `ParseTextCommand.cs` — `(string Text, UserContext User)`
- `ParseVoiceCommand.cs` — `(Stream AudioStream, string ContentType, long ContentLength, UserContext User)`
- `ParseTextResult.cs` / `ParseVoiceResult.cs` — с полями из Phase 1 («Key Structures»)

### 2.3 Extracted-field envelope

- `FieldStatus.cs` — enum `{ Unknown = 0, Valid = 1, Invalid = 2, SuspectedHallucination = 3 }` (доменный enum — требуется `Unknown = 0` по CodeStyle.md)
- `ExtractedField.cs` — `sealed record ExtractedField<T>(T? Value, string? RawText, FieldStatus Status, string? Reason)` + static helpers `Valid(...)`, `Invalid(...)`, `Hallucinated(...)` для удобства в validator-е
- `ExtractedAddress.cs` — `(string? Street, string? City, string? State, string? Zip)`
- `ParsedLeadFields.cs` — 7 полей по Phase 1, все `ExtractedField<T>?`

### 2.4 Enums + OpenAI payloads

- `ParseWarningCode.cs` — domain enum с `Unknown = 0`, затем `AddressPartial`, `AddressZipInvalid`, `AddressStateInvalid`, `WorkTimeInverted`, `VisitDateOutOfRange`
- `LlmExtractionResult.cs` — финальный deserialized LLM JSON + `ExtractionUsage(int InputTokens, int OutputTokens)` + `ModelVersion` string
- `TranscriptionResult.cs` — `(string TranscriptText, TranscriptionUsage Usage, string ModelVersion)` + `TranscriptionUsage(int InputTokens, int OutputTokens)`

**Принципы:**

- All records `sealed`, `record` с positional ctor + `init` где нужна flexibility
- Никакой JSON-сериализации здесь (Newtonsoft converters / `[JsonPropertyName]`) — это domain layer; сериализационные атрибуты только на DTO (Step 6)
- Нет default-значений в ctor-parameters — явность важнее (kроме `TimeAnchor.TimezoneName` = null)

## Step 3: OpenAI Integration

**Files (new):**

- `Src/Invoices.Common/Services/LeadParsing/IOpenAiClient.cs` — интерфейс (оба метода)
- `Src/Invoices.Common/Services/LeadParsing/LeadParsingPrompts.cs` — `public static class` с:
  - `ExtractionSystemV1` — фиксированный multi-line string (из Phase 1)
  - `BuildExtractionSystemPrompt(TimeAnchor)` — static helper, подставляет `{{anchorDate}}`, `{{anchorTime}}`, `{{offset}}`, `{{timezoneName|unknown}}` через `string.Replace`
  - `ExtractionJsonSchema` — `string` с JSON-схемой (see 3.2)
  - `ExtractionPromptVersion = "v1"` (пока константа — versioning в Known Gaps)
- `Src/Invoices.Implementation.Services/LeadParsing/OpenAiClient.cs` — реализация

### 3.1 Interface (Common layer)

```csharp
public interface IOpenAiClient
{
    Task<TranscriptionResult> TranscribeAsync(
        Stream audio, string contentType, CancellationToken ct);

    Task<LlmExtractionResult> ExtractAsync(
        ExtractionContext context, CancellationToken ct);
}
```

### 3.2 JSON schema constant

`ExtractionJsonSchema` — raw string literal с полной schema для `ChatResponseFormat.CreateJsonSchemaFormat(name: "lead_fields", ...)`. Schema объявляет 7 полей из `ParsedLeadFields`; для `visitDate` / `workStartTime` / `workEndTime` — string + pattern (ISO-формат + 24-hour time). Nullable поля = `["string", "null"]`. Поле `strict: true` на schema-уровне.

### 3.3 OpenAI SDK client impl

- NuGet dependency: `OpenAI` v2.x (добавить в `Invoices.Implementation.Services.csproj`)
- `OpenAiClient` constructor: injected `IHttpClientFactory` (via named client `"openai"`), `IOptions<OpenAiSettings>`, `ILogger<OpenAiClient>`
- `ExtractAsync`:
  1. Build system prompt через `LeadParsingPrompts.BuildExtractionSystemPrompt(context.TimeAnchor)`
  2. Build user message: `context.Text` as-is
  3. `ChatResponseFormat.CreateJsonSchemaFormat(name: "lead_fields", jsonSchema: BinaryData.FromString(LeadParsingPrompts.ExtractionJsonSchema), jsonSchemaIsStrict: true)`
  4. Вызвать `ChatClient.CompleteChatStreamingAsync` (итерируем `IAsyncEnumerable<StreamingChatCompletionUpdate>`, аккумулируем `ContentUpdate` в `StringBuilder`)
  5. Полный JSON → `JsonSerializer.Deserialize<LlmExtractionRaw>` (Newtonsoft.Json) → mapping в `LlmExtractionResult`
  6. Usage — из финального чанка (`StreamingChatCompletionUpdate.Usage` в последнем update)
  7. Два timeout-а через `CancellationTokenSource.CreateLinkedTokenSource` — `FirstTokenTimeout` сбрасывается на первом полученном delta, `OverallTimeout` живёт от начала до конца
- `TranscribeAsync`:
  1. `AudioClient.TranscribeAudioAsync(audio, fileName, options)` где options = `{ Language = "en", Temperature = 0, ResponseFormat = AudioTranscriptionFormat.Json }`
  2. `fileName` — derived from `contentType` mapping (`audio/m4a → "audio.m4a"` и т.д.)
  3. Result → `TranscriptionResult` с usage из ответа
  4. Один `Timeout` через `CancellationTokenSource.CreateLinkedTokenSource`

### 3.4 Polly + HttpClient registration (ставим здесь, в Step 3, а не в Step 7 — т.к. это внутренняя деталь OpenAI-клиента)

Registration вынести в приватный helper внутри `ExternalServicesConfiguration.AddAi(...)` или отдельный installer `OpenAiInstaller.cs` в `Invoices.DIConfig/Installers/` (по аналогии с `PushServicesInstaller`). Финальный call — в Step 7. Здесь только готовим код.

**NOT changes:** не трогаем существующий `AddAi` (он про `Tofu.AI.Api` — отдельный сервис); новый installer — отдельный.

### 3.5 Error mapping (internal)

`OpenAiClient` ловит `ClientResultException` от SDK и кидает доменные exceptions:

- `LeadParseRateLimitedException` — 429 после retry
- `LeadParseUnavailableException` — 5xx после retry
- `LeadParseTimeoutException` — timeout через `OperationCanceledException` (и не `ct.IsCancellationRequested` — то caller-cancel пропускаем)
- `LeadParseContentRejectedException` — OpenAI content policy (`error.type == "invalid_request_error"` + keyword в message)
- `LeadParseInternalException` — всё остальное (bad JSON после repair, 401, unknown)

Exception-типы живут в `Invoices.Common/Services/LeadParsing/Exceptions/` (MVP достаточно; если отдельная мапа будет для Core — сделаем позже).

## Step 4: Validation Helpers

**Files (new), namespace `Invoices.Implementation.Services.LeadParsing`:**

- `TimeAnchorResolver.cs` — `ITimeAnchorResolver` + impl
- `LeadFieldValidator.cs` — `ILeadFieldValidator` + impl

Интерфейсы и impl лежат в Implementation.Services (по аналогии с другими helpers — `OnboardingStatusCalculator`, `PlanInfoProvider`). Интерфейсы — `public interface ITimeAnchorResolver` / `ILeadFieldValidator` — видимы из Common через DI.

Либо intefaces в `Invoices.Common/Services/LeadParsing/` для симметрии с остальным — **так и сделаем** (консистентность с текущим проектом).

### 4.1 `TimeAnchorResolver`

```csharp
public interface ITimeAnchorResolver
{
    TimeAnchor Resolve(UserContext user);
}
```

Логика (по Phase 1 «Как собирается TimeAnchor»):

1. If `user.ClientNow != null` → `AnchorDate = ClientNow.Value.ToString("yyyy-MM-dd")`, `AnchorTime = ClientNow.Value.ToString("HH:mm")`, `Offset = ClientNow.Value.Offset.ToString("+hh\\:mm" / "-hh\\:mm")`, `TimezoneName = null`, `Source = Client`
2. Else → `DateTimeOffset.UtcNow` translated в `America/New_York` (через `TimeZoneInfo.FindSystemTimeZoneById` с `"America/New_York"`, `"Eastern Standard Time"` fallback для Windows через `TimeZoneInfo.TryConvertIanaIdToWindowsId`), offset из этого TZ, `TimezoneName = "America/New_York"`, `Source = ServerFallback`

Inject `IClock` (уже есть в проекте) для deterministic testing.

### 4.2 `LeadFieldValidator`

```csharp
public interface ILeadFieldValidator
{
    (ParsedLeadFields Fields, IReadOnlyList<ParseWarningCode> Warnings) ValidateAndNormalize(
        LlmExtractionResult raw,
        string sourceText);
}
```

Логика по полям — как в Phase 1 «Components» → `ILeadFieldValidator`:

- `ClientName`: trim, whitespace collapse → substring-match (case-insensitive, нормализация multi-space) против `sourceText` → `Valid` или `SuspectedHallucination` (с `Value = null`, `RawText` сохранён)
- `Address`: parse `raw.Street/City/State/Zip`; state — regex `^[A-Z]{2}$` (uppercase); zip — regex `^\d{5}(-\d{4})?$`; каждый компонент отдельно валидируется; если street present но city/state пустые → warning `AddressPartial`; если state не прошёл → null + warning `AddressStateInvalid`; если zip не прошёл → null + warning `AddressZipInvalid`; substring-match против `sourceText` по `raw.RawText`
- `VisitDate`: `DateOnly.TryParseExact("yyyy-MM-dd")`; sanity = within `[IClock.Today.AddYears(-1), IClock.Today.AddYears(5)]`; если fail → `Value = null`, `Status = Invalid`, warning `VisitDateOutOfRange`
- `WorkStartTime` / `WorkEndTime`: `TimeOnly.TryParseExact("HH:mm")`; если `end < start` — swap + warning `WorkTimeInverted`
- `Title`: trim, cap at 120 chars; всегда `Status = Valid` if non-null
- `AdditionalInfo`: trim, cap at 1000 chars; всегда `Status = Valid` if non-null

Substring-match helper — private static method с нормализацией whitespace + `CultureInfo.InvariantCulture.CompareInfo.IndexOf(..., CompareOptions.IgnoreCase)`.

## Step 5: LeadParsingService

**Files (new):**

- `Src/Invoices.Common/Services/LeadParsing/ILeadParsingService.cs`
- `Src/Invoices.Implementation.Services/LeadParsing/LeadParsingService.cs`

```csharp
public interface ILeadParsingService
{
    Task<ParseTextResult> ParseTextAsync(ParseTextCommand command, CancellationToken ct);
    Task<ParseVoiceResult> ParseVoiceAsync(ParseVoiceCommand command, CancellationToken ct);
}
```

### 5.1 `LeadParsingService` implementation

Ctor: injected `IOpenAiClient`, `ITimeAnchorResolver`, `ILeadFieldValidator`, `IOptionsMonitor<LeadParsingSettings>` (hot-reload для feature flags), `ILogger<LeadParsingService>`.

```csharp
public async Task<ParseTextResult> ParseTextAsync(ParseTextCommand command, CancellationToken ct)
{
    var settings = _settings.CurrentValue;
    if (!settings.TextEnabled) throw new LeadParseUnavailableException("Text parsing disabled");

    ValidateTextLength(command.Text, settings.Text);  // throws LeadParseInputTooShort / TooLong

    var pipeline = await RunExtractionAsync(command.Text, command.User, feature: "text", ct);

    return new ParseTextResult(
        Fields: pipeline.Fields,
        SourceText: command.Text,
        TimeAnchor: pipeline.TimeAnchor,
        ParseWarnings: pipeline.Warnings,
        ModelVersion: pipeline.ExtractionModelVersion,
        ExtractionUsage: pipeline.ExtractionUsage);
}
```

```csharp
public async Task<ParseVoiceResult> ParseVoiceAsync(ParseVoiceCommand command, CancellationToken ct)
{
    var settings = _settings.CurrentValue;
    if (!settings.VoiceEnabled) throw new LeadParseUnavailableException("Voice parsing disabled");

    ValidateAudio(command.ContentLength, command.ContentType, settings.Audio);  // throws TooLarge / Unsupported

    var transcription = await _openAi.TranscribeAsync(command.AudioStream, command.ContentType, ct);

    var pipeline = await RunExtractionAsync(transcription.TranscriptText, command.User, feature: "voice", ct);

    return new ParseVoiceResult(
        Fields: pipeline.Fields,
        TranscriptText: transcription.TranscriptText,
        TranscriptionModelVersion: transcription.ModelVersion,
        TimeAnchor: pipeline.TimeAnchor,
        ParseWarnings: pipeline.Warnings,
        ModelVersion: pipeline.ExtractionModelVersion,
        ExtractionUsage: pipeline.ExtractionUsage,
        TranscriptionUsage: transcription.Usage);
}
```

### 5.2 Shared `RunExtractionAsync` helper

```csharp
private async Task<ExtractionPipelineResult> RunExtractionAsync(
    string sourceText, UserContext user, string feature, CancellationToken ct)
{
    var sw = Stopwatch.StartNew();
    var anchor = _timeAnchorResolver.Resolve(user);
    var context = new ExtractionContext(sourceText, anchor);

    var llm = await _openAi.ExtractAsync(context, ct);
    var (fields, warnings) = _validator.ValidateAndNormalize(llm, sourceText);

    _logger.LogInformation(
        "LeadParsing extraction completed feature='{Feature}' model='{Model}' inputTokens={InputTokens} outputTokens={OutputTokens} latencyMs={LatencyMs}",
        feature, llm.ModelVersion, llm.Usage.InputTokens, llm.Usage.OutputTokens, sw.ElapsedMilliseconds);

    return new ExtractionPipelineResult(fields, warnings, anchor, llm.Usage, llm.ModelVersion);
}
```

`ExtractionPipelineResult` — private record внутри файла.

### 5.3 Input validation helpers

- `ValidateTextLength(text, textSettings)` — throws `LeadParseInputTooShortException` if `< MinWords`, `LeadParseInputTooLongException` if `> MaxChars`
- `ValidateAudio(contentLength, contentType, audioSettings)` — `LeadParseAudioTooLargeException` / `LeadParseAudioUnsupportedException`

Exceptions — в `Invoices.Common/Services/LeadParsing/Exceptions/` (созданы в Step 3 для OpenAI; здесь добавляем ещё 4).

**NO PII logging** — никогда не логируем `command.Text` / `transcription.TranscriptText` / `command.User.ClientNow` на INFO. Только metadata.

## Step 6: API Layer

**Files (new):**

- `Src/Invoices.Api/Controllers/LeadParsingController.cs`
- `Src/Invoices.Api/Dto/LeadParsing/ParseTextRequestDto.cs`
- `Src/Invoices.Api/Dto/LeadParsing/ParseTextResponseDto.cs`
- `Src/Invoices.Api/Dto/LeadParsing/ParseVoiceResponseDto.cs`
- `Src/Invoices.Api/Dto/LeadParsing/ParsedLeadFieldsDto.cs`
- `Src/Invoices.Api/Dto/LeadParsing/ExtractedFieldDto.cs`
- `Src/Invoices.Api/Dto/LeadParsing/ExtractedAddressDto.cs`
- `Src/Invoices.Api/Dto/LeadParsing/TimeAnchorDto.cs`
- `Src/Invoices.Api/Dto/LeadParsing/FieldStatusDto.cs`
- `Src/Invoices.Api/Dto/LeadParsing/ExtractionUsageDto.cs`
- `Src/Invoices.Api/Dto/LeadParsing/TranscriptionUsageDto.cs`
- `Src/Invoices.Api/Mappers/LeadParsingMapper.cs`

### 6.1 Controller

- Наследуется от `Controller` (не `BaseController`) — endpoint public, no auth context; parallel to `PromoController`
- `[ApiController]`, `[Route("v1/leads")]`, `[ApiVersion("1.0")]`
- `[HttpPost("parse-text")]` и `[HttpPost("parse-voice")]`
- Controller thin — delegate to `ILeadParsingService`, map через `LeadParsingMapper`
- Для voice — `[DisableRequestSizeLimit]` на action (size guard делаем в service) + read `IFormFile audio` + `[FromForm] DateTimeOffset? clientNow`
- `ValidateModel()` helper реализуем локально (маленький клон из `BaseController`) или просто `if (!ModelState.IsValid) throw new ArgumentException(...)`

Public-endpoint обоснование — Phase 1 Decision «Public endpoints в v1». `[Authorize]` в Known Gaps.

### 6.2 DTOs

- DTO-enum `FieldStatusDto` — **без** `Unknown`, `Valid = 1`, `Invalid = 2`, `SuspectedHallucination = 3`, с `[JsonConverter(typeof(JsonStringEnumConverter))]` и `Newtonsoft.Json.JsonConverter(typeof(StringOnlyEnumConverter))`
- `ExtractedFieldDto<T>` — generic; сериализуется как nullable — если envelope null, свойство не попадает в JSON (`[JsonProperty(NullValueHandling = Ignore)]`)
- Все response DTOs — `sealed class`, все свойства `required`
- В request DTO — валидация `[Required]`, `[StringLength(10_000, MinimumLength = 1)]` на `Text`

### 6.3 Mapper

`LeadParsingMapper` — `public static class` с `.Select(...)`-friendly методами (правило из CodeStyle.md):

- `ToDto(ParsedLeadFields) → ParsedLeadFieldsDto`
- `ToDto(ExtractedField<T>?, Func<T, TDto> valueMapper) → ExtractedFieldDto<TDto>?`
- `ToDto(ExtractedAddress) → ExtractedAddressDto`
- `ToDto(FieldStatus) → FieldStatusDto` (exhaustive switch, throws on `Unknown`)
- `ToDto(TimeAnchor)`, `ToDto(ExtractionUsage)`, `ToDto(TranscriptionUsage)`
- `ToDto(ParseWarningCode) → string` — camelCase (`addressPartial`, и т.д.); `ParseWarnings` в response — `IReadOnlyList<string>`

Перечисление enum-значений — единое место, switch здесь и нигде больше (CodeStyle.md).

## Step 7: Error Handling & DI Wiring

**Files (modified):**

- `Src/Invoices.Api/Middleware/ErrorCode.cs` — добавить 7 новых значений:
  - `leadParseInputTooShort`, `leadParseInputTooLong`, `leadParseAudioTooLarge`, `leadParseAudioUnsupported`, `leadParseLlmTimeout`, `leadParseRejected`, `leadParseUnavailable`, `leadParseInternal`, (зарезервированный `leadParseAudioTooLong` — добавляем для forward-compat)
- `Src/Invoices.Api/Middleware/ApiExceptionHandlingMiddleware.cs` — добавить `Map<>` entries (порядок — перед fallback `Map<Exception>`):
  - `LeadParseInputTooShortException` → 422 / `leadParseInputTooShort` / Information
  - `LeadParseInputTooLongException` → 422 / `leadParseInputTooLong` / Information
  - `LeadParseAudioTooLargeException` → 413 / `leadParseAudioTooLarge` / Information
  - `LeadParseAudioUnsupportedException` → 415 / `leadParseAudioUnsupported` / Information
  - `LeadParseTimeoutException` → 504 / `leadParseLlmTimeout` / Warning
  - `LeadParseContentRejectedException` → 422 / `leadParseRejected` / Information
  - `LeadParseRateLimitedException` → 503 / `leadParseUnavailable` / Warning (`additionalPropsFunc` → `{ RetryAfterSeconds = 30 }`)
  - `LeadParseUnavailableException` → 503 / `leadParseUnavailable` / Warning
  - `LeadParseInternalException` → 500 / `leadParseInternal` / Error

**Files (new):**

- `Src/Invoices.DIConfig/Installers/LeadParsingInstaller.cs` — единая точка регистрации (по аналогии с `PushServicesInstaller`):

  ```csharp
  public static IServiceCollection AddLeadParsing(
      this IServiceCollection services, IConfiguration configuration)
  {
      services.AddOptions<OpenAiSettings>()
          .Bind(configuration.GetSection("OpenAi"))
          .ValidateDataAnnotations()
          .ValidateOnStart();

      services.AddOptions<LeadParsingSettings>()
          .Bind(configuration.GetSection("LeadParsing"))
          .ValidateDataAnnotations()
          .ValidateOnStart();

      services.AddHttpClient("openai", client =>
          {
              client.Timeout = Timeout.InfiniteTimeSpan; // Polly controls timeouts
          })
          .AddPolicyHandler((sp, _) =>
              Policies.GetOpenAiRetryPolicy(sp.GetRequiredService<ILogger<OpenAiClient>>()));

      services.AddSingleton<IOpenAiClient, OpenAiClient>();
      services.AddSingleton<ITimeAnchorResolver, TimeAnchorResolver>();
      services.AddSingleton<ILeadFieldValidator, LeadFieldValidator>();
      services.AddScoped<ILeadParsingService, LeadParsingService>();
      return services;
  }
  ```

**Files (modified):**

- `Src/Invoices.Common/Polly/Policies.cs` (если существует; иначе — расширить) — добавить `GetOpenAiRetryPolicy(ILogger)` с retry 2x exponential (1s, 3s) на 429 / 5xx / `HttpRequestException` / `TaskCanceledException`
- `Src/Invoices.Api/DI/ExternalServicesConfiguration.cs` — вызов `builder.Services.AddLeadParsing(builder.Configuration);` в `AddExternalServices(...)` (рядом с `AddPushServices`)

**NO changes** to `CommonServicesConfiguration.cs` — новые сервисы регистрируются через `LeadParsingInstaller`.

**NO changes** to authentication middleware — endpoint public, `AccountAuthenticationMiddleware` skip patterns остаются как есть (controller в `/v1/leads/*` и так не требует auth, middleware не стоит `[Authorize]`).

## Step 8: Evaluation Harness

**Files (new):**

- `Src/Invoices.Tools.LeadParsingEval/Invoices.Tools.LeadParsingEval.csproj` — .NET 8 console, ref-ит `Invoices.Common`, `Invoices.Implementation.Services`, `Invoices.DIConfig`
- `Src/Invoices.Tools.LeadParsingEval/Program.cs` — тонкий CLI: `dotnet run --project Invoices.Tools.LeadParsingEval -- --dataset <path> [--openai-key <key>]`
- `Src/Invoices.Tests/LeadParsing/evaluation-dataset.json` — начальный файл с 5 seed cases (happy path + relative date + partial address). Полный 30–50 dataset — follow-up до ship (DoD); здесь scaffold.

Program.cs — простой:
1. Parse args (`--dataset`, `--openai-key`)
2. Build `ServiceCollection` с `AddLeadParsing(configuration)`; ApiKey переопределить из CLI
3. Load dataset, для каждого case: call `ILeadParsingService.ParseTextAsync` (без voice — evaluation dataset начинается с text; voice — manual smoke)
4. Compare `parsed.Fields.*` с `expected.*`, aggregate metrics (exact-match rate per field)
5. Print summary → stdout

**Почему в этом шаге:** инструмент нужен по DoD (Phase 1), но не блокирует API-endpoints. Scaffold + 5 cases — достаточно для Step 3 validation; fill dataset до 30–50 — follow-up.

## Step 9: Run full test suite

Verification gate — запустить все существующие unit + integration тесты, убедиться что Steps 1–8 не сломали ничего.

```bash
cd Src
dotnet test
```

Если хоть один fail — fix before Step 10.

## Step 10: Write new tests (via `/tests sync`)

Expected coverage:

### Unit tests — `Invoices.Tests/LeadParsing/`

- `TimeAnchorResolverTests` — client-now path vs server-fallback path; offset formatting; Windows-IANA TZ conversion
- `LeadFieldValidatorTests`:
  - Per-field: clientName substring match, address component validation (state format, zip format, partial), visitDate sanity range, workTime swap, title/additionalInfo length cap
  - Per-warning: each `ParseWarningCode` emits on right conditions, none otherwise
  - Hallucination: `clientName` absent in source → `SuspectedHallucination`; present → `Valid`
- `LeadParsingMapperTests` — each `ToDto` overload, `FieldStatus.Unknown` throws
- `LeadParsingPromptsTests` — `BuildExtractionSystemPrompt` substitutes all 4 placeholders; `{{timezoneName}}` → `"unknown"` when null
- `OpenAiClientTests` — `MockHttpMessageHandler`-based: streaming accumulation, timeout behavior, error → exception mapping
- `LeadParsingServiceTests` — fake `IOpenAiClient` + `ITimeAnchorResolver` + `ILeadFieldValidator`: feature-flag disabled → throws, text too short → throws, voice too large → throws, happy path propagates fields+warnings, transcript correctly forwarded to extraction

### Integration tests — `Invoices.Tests.Integration/LeadParsing/`

`FakeOpenAiClient` (test double) registered в TestServer, возвращает canned responses:

- `POST /v1/leads/parse-text` happy path → 200 + expected fields
- `POST /v1/leads/parse-text` text too short → 422 `leadParseInputTooShort`
- `POST /v1/leads/parse-text` text too long → 422 `leadParseInputTooLong`
- `POST /v1/leads/parse-voice` happy path (sample m4a blob) → 200 + transcript + fields
- `POST /v1/leads/parse-voice` audio > 5 MB → 413 `leadParseAudioTooLarge`
- `POST /v1/leads/parse-voice` content-type unsupported → 415
- Feature flag `TextEnabled=false` → 503 `leadParseUnavailable`
- Feature flag `VoiceEnabled=false` → 503
- OpenAI throws `LeadParseTimeoutException` → 504
- OpenAI throws `LeadParseContentRejectedException` → 422 `leadParseRejected`
- `clientNow` → response `timeAnchor.source == "client"`; absent → `"server-fallback"`

> Step 10 делегирует в `/tests sync` — тот умеет project conventions (naming, factory methods, FluentAssertions, AutoFixture).

---

## Execution Checklist

| #  | Task | Files | Status |
|----|------|-------|--------|
| 1  | Configuration & feature flags (`OpenAiSettings`, `LeadParsingSettings`, appsettings) | `Invoices.Common/Services/LeadParsing/*Settings.cs`, `Invoices.Api/appsettings*.json` | done |
| 2  | Domain types (UserContext, TimeAnchor, ExtractionContext, commands/results, `ExtractedField<T>`, `ParsedLeadFields`, enums, usage records) | `Invoices.Common/Services/LeadParsing/*.cs` | done |
| 3  | OpenAI integration: `IOpenAiClient`, `LeadParsingPrompts` (system prompt + JSON schema), `OpenAiClient` impl with streaming + structured output + Polly, domain exception family | `Invoices.Common/Services/LeadParsing/IOpenAiClient.cs` + `LeadParsingPrompts.cs` + `Exceptions/*`, `Invoices.Implementation.Services/LeadParsing/OpenAiClient.cs` | done |
| 4  | Validation: `TimeAnchorResolver`, `LeadFieldValidator` (per-field + cross-field warnings) | `Invoices.Common/Services/LeadParsing/ITimeAnchorResolver.cs` + `ILeadFieldValidator.cs`, `Invoices.Implementation.Services/LeadParsing/*` | done |
| 5  | `ILeadParsingService` + `LeadParsingService` (shared `RunExtractionAsync` pipeline, input guards, logging) | `Invoices.Common/Services/LeadParsing/ILeadParsingService.cs`, `Invoices.Implementation.Services/LeadParsing/LeadParsingService.cs` | done |
| 6  | API layer: `LeadParsingController`, request/response DTOs, `LeadParsingMapper` | `Invoices.Api/Controllers/LeadParsingController.cs`, `Invoices.Api/Dto/LeadParsing/*.cs`, `Invoices.Api/Mappers/LeadParsingMapper.cs` | done |
| 7  | Error handling & DI wiring: `ErrorCode` additions, `ApiExceptionHandlingMiddleware` maps, `LeadParsingInstaller`, OpenAI HttpClient + Polly policy, `ExternalServicesConfiguration` call | `Invoices.Api/Middleware/ErrorCode.cs`, `Invoices.Api/Middleware/ApiExceptionHandlingMiddleware.cs`, `Invoices.DIConfig/Installers/LeadParsingInstaller.cs`, `Invoices.Common/Polly/Policies.cs`, `Invoices.Api/DI/ExternalServicesConfiguration.cs` | done |
| 8  | Evaluation harness (new tool project + seed dataset) | `Src/Invoices.Tools.LeadParsingEval/*`, `Invoices.Tests/LeadParsing/evaluation-dataset.json` | done |
| 9  | Run full test suite (verification gate) | — | done |
| 10 | Write new tests (via `/tests sync`) — unit (resolver/validator/mapper/prompts/service/OpenAiClient) + integration (`FakeOpenAiClient` based controller tests) | `Invoices.Tests/LeadParsing/*`, `Invoices.Tests.Integration/LeadParsing/*` | done (unit only; OpenAiClient + integration deferred) |
