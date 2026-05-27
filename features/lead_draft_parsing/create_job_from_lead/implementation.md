# Create Job from Lead — Implementation

> Phase 2 of the Create Job from Lead plan. For problem analysis, system overview,
> API contracts and decisions see [`plan.md`](./plan.md).

Bottom-up: domain types → service → DTOs → controller → errors/DI → full test run → new tests.

Все новые namespaces:

- `Invoices.Api.Services.LeadCommit` — `ILeadCommitService` + `LeadCommitService` + command/result/value types
- `Invoices.Api.Dto.LeadParsing` — новые DTO + mapping
- `Invoices.Api.Controllers.LeadParsingController` — новый action `Commit`

**Почему Api-layer, а не Common/Impl.Services:** `Invoices.Common` не может ссылаться
на `Jobs.Contracts` (создаст круговую зависимость — `Jobs.Contracts` уже ссылается на
`Invoices.Common`), а `LeadCommitResult.Job = JobDto` приходит именно из `Jobs.Contracts`.
Сервис композирует два bounded contexts (Clients + Jobs) — это классический
application-level orchestrator, паттерн симметричен существующим `IJobDetailsService`
/ `IInvoicesService` / `IEstimatesService` в `Invoices.Api/Services/`.
Разойдётся с parent-фичей (где `ILeadParsingService` живёт в Common) — это
осознанный trade-off: `ILeadParsingService` не пересекает bounded contexts,
`ILeadCommitService` пересекает.

**NO changes** to `LeadParsingSettings` / `appsettings*.json` — commit не имеет отдельного kill-switch в v1. Если понадобится — добавим в follow-up (это ~5 строк на каждое место).

## Step 1: Domain Types (Api layer)

**Files (new), namespace `Invoices.Api.Services.LeadCommit`:**

### 1.1 Command + result

- `LeadCommitCommand.cs`:

  ```csharp
  public sealed record LeadCommitCommand(
      string AccountId,
      string? MasterUserId,
      LeadClientRef Client,
      string? Title,
      LeadVisitInput Visit,
      DateTimeOffset? OccurredAt);
  ```

- `LeadCommitResult.cs`:

  ```csharp
  public sealed record LeadCommitResult(
      JobDto Job,
      ManageableClient Client);
  ```

  Returns `ManageableClient` (domain type from `Invoices.Core.Models.Clients`) — mapping в DTO делается на API-слое.

### 1.2 Value objects

- `LeadClientRef.cs` — **discriminated union**: abstract record + два sealed подтипа. Исключает суппрессоры и null-checks на consumer-стороне, даёт exhaustive pattern matching:

  ```csharp
  public abstract record LeadClientRef
  {
      private LeadClientRef() { }

      public sealed record Existing(string ClientId) : LeadClientRef
      {
          public string ClientId { get; } = !string.IsNullOrWhiteSpace(ClientId)
              ? ClientId
              : throw new ArgumentException(
                  "Existing client id is required.", nameof(ClientId));
      }

      public sealed record New(NewLeadClient Client) : LeadClientRef
      {
          public NewLeadClient Client { get; } = Client
              ?? throw new ArgumentNullException(nameof(Client));
      }
  }
  ```

  Private ctor закрывает внешнее наследование — только два подтипа внутри могут `: LeadClientRef`. Consumer работает через `switch` на типе.

- `NewLeadClient.cs`:

  ```csharp
  public sealed record NewLeadClient(
      string Name,
      string? Phone,
      string? Email,
      string? Address);
  ```

- `LeadVisitInput.cs`:

  ```csharp
  public sealed record LeadVisitInput(
      DateTimeOffset At,
      string? AssignedWorkerId);
  ```

**Принципы:**

- Records — `sealed record` (кроме базового `LeadClientRef` — `abstract record` как единственное исключение под discriminated-union pattern)
- Нет JSON-атрибутов здесь (domain layer) — сериализация живёт на DTO (Step 3)
- Нет default-значений в ctor-parameters

## Step 2: Service Layer

**Files (new):**

- `Src/Invoices.Api/Services/LeadCommit/ILeadCommitService.cs`
- `Src/Invoices.Api/Services/LeadCommit/LeadCommitService.cs`

Placement подтверждён: `Invoices.Api.csproj` уже ссылается на `Jobs.Contracts` (нужен для `UpsertJobCommand`) и на `Invoices.Implementation.Services` (нужен для `IClientsService` bindings).

### 2.1 Interface

```csharp
public interface ILeadCommitService
{
    Task<LeadCommitResult> CommitAsync(LeadCommitCommand command, CancellationToken ct);
}
```

### 2.2 Implementation

Ctor dependencies:

- `IClientsService` — `GetClient` / `UpdateOrCreate`
- `IHandlerDispatcher` — dispatches `UpsertJobCommand`
- `ILogger<LeadCommitService>`

Flow:

```csharp
public async Task<LeadCommitResult> CommitAsync(LeadCommitCommand command, CancellationToken ct)
{
    var sw = Stopwatch.StartNew();

    var client = await ResolveClientAsync(command.AccountId, command.Client, ct);

    var visitId = Guid.NewGuid();
    var upsertCommand = new UpsertJobCommand(
        AccountId: command.AccountId,
        JobId: null,
        Version: 0,
        Number: null,
        Title: command.Title,
        ClientId: client.ClientId,
        InvoiceId: null,
        EstimateId: null,
        Visits: new[]
        {
            new VisitInputDto
            {
                Id = visitId,
                DateTime = command.Visit.At,
                AssignedWorkerId = command.Visit.AssignedWorkerId,
                Status = VisitStatusDto.Scheduled
            }
        },
        Items: Array.Empty<JobItemDto>(),
        OccurredAt: command.OccurredAt,
        MasterUserId: command.MasterUserId,
        ManualStatus: JobManualStatusDto.None);

    var jobResult = await _dispatcher.DispatchCommand<UpsertJobCommand, UpsertJobResult>(
        upsertCommand, ct);

    _logger.LogInformation(
        "LeadCommit succeeded clientPath='{Path}' jobId='{JobId}' latencyMs={LatencyMs}",
        command.Client is LeadClientRef.Existing ? "existing" : "new",
        jobResult.Job.Id, sw.ElapsedMilliseconds);

    return new LeadCommitResult(jobResult.Job, client);
}
```

`ResolveClientAsync` — exhaustive pattern match по подтипам `LeadClientRef`. Никаких `!` / null-checks:

```csharp
private Task<ManageableClient> ResolveClientAsync(
    string accountId, LeadClientRef clientRef, CancellationToken ct)
{
    return clientRef switch
    {
        // GetClient throws ClientNotFoundException (→ 404) if missing.
        // Archived check is enforced downstream by UpsertJobCommandHandler
        // (ClientArchivedException → 400).
        LeadClientRef.Existing existing => _clientsService.GetClient(
            accountId, existing.ClientId, includeCalculations: false, ct),

        LeadClientRef.New newRef => CreateNewClientAsync(accountId, newRef.Client, ct),

        _ => throw new InvalidOperationException(
            $"Unknown LeadClientRef subtype: {clientRef.GetType().Name}")
    };
}

private Task<ManageableClient> CreateNewClientAsync(
    string accountId, NewLeadClient newClient, CancellationToken ct)
{
    var clientId = Guid.NewGuid().ToString("N");
    var manageable = new ManageableClient
    {
        Id = ManageableClient.FormatId(accountId, clientId),
        ClientId = clientId,
        AccountId = accountId,
        Info =
        [
            new ManageableClientInfo
            {
                Name = newClient.Name,
                Phone = newClient.Phone,
                Email = newClient.Email,
                Address = newClient.Address,
                Type = ClientInfoType.Main
            }
        ],
        Version = 0,
        CreatedAt = DateTime.UtcNow
    };

    return _clientsService.UpdateOrCreate(manageable, ct);
}
```

**Logging rules:** в INFO-логах только metadata (`clientPath`, `jobId`, `latencyMs`). **NO PII** — никогда не логируем `NewLeadClient.Name / Phone / Email / Address`, `title`, `visit.At`.

**NO input sanitization / extra validation** — endpoint принимает уже верифицированные пользователем данные. Title fallback, visit sanity, workerId validation — всё уже делает downstream `UpsertJobCommandHandler` и `Job.UpdateVisits` (exceptions пробрасываются наружу через middleware).

## Step 3: API DTOs + Mapping

**Files (new), namespace `Invoices.Api.Dto.LeadParsing`:**

- `CommitLeadRequestDto.cs`
- `CommitLeadClientDto.cs`
- `CommitLeadNewClientDto.cs`
- `CommitLeadVisitDto.cs`
- `CommitLeadResponseDto.cs`
- `CommitLeadMapping.cs` — static class с extension methods

### 3.1 DTO shapes

См. `plan.md` → API Contracts. Ключевое:

- `CommitLeadRequestDto` — `Title?`, `required Client`, `required Visit`
- `CommitLeadClientDto` — `ExistingClientId?`, `NewClient?`. **Атрибут-валидация не поддерживает exactly-one-of** — проверяем в mapper (см. 3.2) и бросаем `ArgumentException` (→ 400 через middleware).
- `CommitLeadNewClientDto` — `[Required][StringLength(200,MinimumLength=1)] Name`, `Phone?`, `Email?`, `Address?`
- `CommitLeadVisitDto` — `required DateTimeOffset At` (через `[JsonConverter(typeof(DateTimeOffsetAsUtcConverter))]`), `AssignedWorkerId?`
- `CommitLeadResponseDto` — `required JobDto Job`, `required ManageableClientDto Client`

Все response DTOs — `sealed class`, свойства `required` / `init`. Request DTOs — обычные `class` с `init` для совместимости с Newtonsoft binder. Naming — camelCase в JSON (default через `UseNewtonsoftJson` resolver).

### 3.2 Mapping

```csharp
public static class CommitLeadMapping
{
    public static LeadCommitCommand ToCommand(
        this CommitLeadRequestDto dto,
        string accountId,
        string? masterUserId,
        DateTimeOffset? clientEventTime)
    {
        var client = BuildClientRef(dto.Client);
        var visit = new LeadVisitInput(dto.Visit.At, dto.Visit.AssignedWorkerId);
        return new LeadCommitCommand(
            AccountId: accountId,
            MasterUserId: masterUserId,
            Client: client,
            Title: dto.Title,
            Visit: visit,
            OccurredAt: clientEventTime);
    }

    private static LeadClientRef BuildClientRef(CommitLeadClientDto dto)
    {
        var existingId = string.IsNullOrWhiteSpace(dto.ExistingClientId) ? null : dto.ExistingClientId;

        return (existingId, dto.NewClient) switch
        {
            (null, null) or (not null, not null) => throw new ArgumentException(
                "Exactly one of client.existingClientId or client.newClient must be provided."),
            ({ } id, _) => new LeadClientRef.Existing(id),
            (_, { } newClient) => new LeadClientRef.New(new NewLeadClient(
                Name: newClient.Name,
                Phone: newClient.Phone,
                Email: newClient.Email,
                Address: newClient.Address))
        };
    }

    public static CommitLeadResponseDto ToDto(this LeadCommitResult result)
    {
        return new CommitLeadResponseDto
        {
            Job = result.Job.ToApi(),           // reuse existing JobsApiMappings.ToApi
            Client = result.Client.Map()        // reuse existing Mapping.Map (ManageableClient → ManageableClientDto)
        };
    }
}
```

Tuple-pattern `({ } id, _)` / `(_, { } newClient)` связывают non-null локальные переменные
— никаких `!` в mapper-е.

**NO separate `NewClientDto.Map()`** — новый клиент создаётся внутри `LeadCommitService`, на DTO-слое нужен только возврат, не приём (возвращается `ManageableClient` целиком).

## Step 4: Controller Action

**Files (modified):**

- `Src/Invoices.Api/Controllers/LeadParsingController.cs` — добавляем action + меняем base class

### 4.1 Base class change

Меняем `: Controller` → `: BaseController`. Это даёт доступ к `AccountId`, `AuthenticationInfo`, `GetClientEventTime()`. Controller-level `[AllowAnonymous]` остаётся — покрывает `ParseText` и `ParseVoice`.

### 4.2 Action

```csharp
[HttpPost("commit")]
[Authorize]   // overrides controller-level [AllowAnonymous]
public async Task<ActionResult<CommitLeadResponseDto>> Commit(
    [FromBody] CommitLeadRequestDto request,
    CancellationToken ct)
{
    ValidateModel();

    var command = request.ToCommand(
        accountId: AccountId,
        masterUserId: AuthenticationInfo?.MasterUser?.Id,
        clientEventTime: GetClientEventTime());

    var result = await _leadCommitService.CommitAsync(command, ct);

    return result.ToDto();
}
```

Ctor extension — добавить `ILeadCommitService _leadCommitService` наряду с существующим `ILeadParsingService`.

**NO changes** к существующим `ParseText` / `ParseVoice` — они `[AllowAnonymous]` сохраняют.

## Step 5: DI Wiring

**Files (modified):**

- `Src/Invoices.Api/DI/CommonServicesConfiguration.cs` — добавить рядом с
  `IJobDetailsService` / `IInvoicesService` / `IEstimatesService` (~line 190–194):

  ```csharp
  builder.Services.AddScoped<ILeadCommitService, LeadCommitService>();
  ```

  Не в `LeadParsingInstaller` — тот ставит сервисы из `Invoices.Common`/`Invoices.Implementation.Services`, а `ILeadCommitService` живёт в Api-слое (как `IJobDetailsService`). Семантически: это Api-level orchestrator.

**NO new error codes / middleware mappings** — все используемые exceptions уже замаплены:

- `ClientNotFoundException` → 404 `notFound`
- `ClientArchivedException` → 400 `clientArchived`
- `ArgumentException` (fallback / exactly-one-of / title missing) → 400

**NO changes** to `AccountAuthenticationMiddleware` — `[Authorize]` на action срабатывает после middleware-а (AccountId уже выставлен для authenticated requests).

## Step 6: Run full test suite

Verification gate — запустить все существующие unit + integration тесты, убедиться что Steps 1–5 не сломали ничего (особенно: парент-фича `LeadParsing`, `JobsController.Upsert`, `ClientsController`).

```bash
cd Src
dotnet test
```

Если хоть один fail — fix before Step 7.

## Step 7: Write new tests (via `/tests sync`)

Expected coverage:

### Unit tests — `Invoices.Tests/LeadParsing/`

- `LeadCommitServiceTests`:
  - `CommitAsync_ExistingClientPath_CallsGetClientSkipsUpdateOrCreate`
  - `CommitAsync_ExistingClientNotFound_PropagatesClientNotFound`
  - `CommitAsync_NewClientPath_CallsUpdateOrCreateWithMainInfo` — verify `ClientInfoType.Main`, все 4 поля (name/phone/email/address) пробрасываются
  - `CommitAsync_NewClientPath_GeneratesFreshClientId` — `clientId` = `Guid.NewGuid().ToString("N")`
  - `CommitAsync_DispatchesUpsertJobCommand_WithSingleScheduledVisit` — verify Items=empty, Visits=1, Status=Scheduled, Version=0
  - `CommitAsync_ForwardsTitleAndOccurredAt`
  - `CommitAsync_ReturnsJobAndClientInResult`
- `CommitLeadMappingTests`:
  - `ToCommand_ExistingClientId_BuildsExistingRef`
  - `ToCommand_NewClient_BuildsNewRef`
  - `ToCommand_BothFieldsSet_ThrowsArgumentException`
  - `ToCommand_NoFieldsSet_ThrowsArgumentException`
  - `ToCommand_WhitespaceExistingClientId_TreatedAsEmpty_AndRequiresNewClient`
  - `ToDto_MapsJobAndClient`
- `LeadClientRefTests`:
  - `Existing_EmptyOrWhitespaceId_ThrowsArgumentException`
  - `New_NullClient_ThrowsArgumentNullException`
  - `Pattern match exhaustiveness` — switch на `LeadClientRef` покрывает оба подтипа

### Integration tests — `Invoices.IntegrationTests/Tests/Controllers/` (или `Invoices.Tests.Integration/LeadParsing/` — по convention проекта)

- `POST /api/leads/commit` happy path, `newClient` → 200 + JobDto + Client
- `POST /api/leads/commit` happy path, `existingClientId` → 200 (использует seed-client)
- `POST /api/leads/commit` без auth → 401
- `POST /api/leads/commit` оба client-поля заданы → 400 (`ArgumentException`)
- `POST /api/leads/commit` ни одно client-поле → 400
- `POST /api/leads/commit` `existingClientId` не существует → 404 `notFound`
- `POST /api/leads/commit` `existingClientId` архивный → 400 `clientArchived`
- `POST /api/leads/commit` `newClient.Name` пустой → 400 (DataAnnotations)
- `POST /api/leads/commit` создаёт именно один Scheduled Visit с переданным `At`
- `POST /api/leads/commit` `title=null` + `newClient.Name="Mike"` → Job.Title = "Mike" (fallback via UpsertJobCommandHandler)
- `POST /api/leads/commit` с `assignedWorkerId` из чужого team → worker silently cleared (per `Job.UpdateVisits` behaviour)

> Step 7 делегирует в `/tests sync` — он знает project conventions (xUnit, FluentAssertions, AutoFixture, factory methods, `BaseInvoicesIntegrationTest`).

---

## Execution Checklist

| # | Task | Files | Status |
|---|------|-------|--------|
| 1 | Domain types (`LeadCommitCommand`, `LeadCommitResult`, `LeadClientRef` as discriminated union, `NewLeadClient`, `LeadVisitInput`) | `Invoices.Api/Services/LeadCommit/*.cs` | done |
| 2 | Service layer: `ILeadCommitService` + `LeadCommitService` (pattern-matched client resolve + `UpsertJobCommand` dispatch) | `Invoices.Api/Services/LeadCommit/ILeadCommitService.cs`, `Invoices.Api/Services/LeadCommit/LeadCommitService.cs` | done |
| 3 | API DTOs + `CommitLeadMapping` (exactly-one-of validation via tuple-pattern) | `Invoices.Api/Dto/LeadParsing/CommitLead*.cs` | done |
| 4 | Controller: `LeadParsingController.Commit` action, switch base to `BaseController`, add `[Authorize]` | `Invoices.Api/Controllers/LeadParsingController.cs` | done |
| 5 | DI wiring: Api-level registration in `CommonServicesConfiguration` | `Invoices.Api/DI/CommonServicesConfiguration.cs` | done |
| 6 | Run full test suite (verification gate) | — | done |
| 7 | Write new tests (via `/tests sync`) — unit (service / mapping / ClientRef) + integration (controller) | `Invoices.Tests/LeadParsing/*`, `Invoices.IntegrationTests/Tests/Controllers/LeadParsing*` | done |

---

## Decisions → Steps Traceability

Проверка: каждое Phase 1 «Decisions Made» ложится хотя бы на один step.

| Decision (Phase 1) | Covered in step |
|---|---|
| Dedicated `POST /api/leads/commit` in `LeadParsingController` | Step 4 |
| Discriminator `existingClientId` XOR `newClient` | Step 1 (`LeadClientRef` as discriminated union), Step 3 (mapper tuple-pattern validation), Step 7 (tests) |
| Drop `workEndTime` and `additionalInfo` on backend | Step 1 (`LeadVisitInput` has only `At`; no notes field on command), Step 3 (DTO has no `WorkEndTime`/`AdditionalInfo`) |
| Endpoint authenticated, not public | Step 4 (`[Authorize]` + `BaseController`) |
| Reuse `UpsertJobCommand` via `IHandlerDispatcher` | Step 2 (service implementation) |
| Client address — plain string, iOS flattens | Step 3 (`CommitLeadNewClientDto.Address: string?`) |
| Response returns both Job and Client | Step 1 (`LeadCommitResult`), Step 3 (`CommitLeadResponseDto`) |
| No feature flag in v1 (dropped per user request) | (no step — deliberate omission; add later if kill-switch needed) |
| No idempotency key in v1 | (no step — deliberate omission) |
| No new `jobCreatedFromLead` activity event | Step 2 (uses existing `UpsertJobCommand` which raises `JobDomainEvent.Created` automatically) |
| No `LeadSource` audit collection | (no step — deliberate omission) |
| Partial-failure = best-effort + iOS retry | (no step — deliberate omission; documented in plan) |
