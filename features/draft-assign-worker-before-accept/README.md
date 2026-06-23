# DRAFT — Assign workers before invitation accept (Option A)

**Status:** planning (draft — no ClickUp task yet)
**Started:** 2026-06-22
**ClickUp:** _pending — rename folder to WEB-NNNN once created_
**Affected repos:** `Tofu.Auth.Backend` (producer), `Invoices.Backend` (consumer/BFF), `Local.Docs`

## Goal

Клиент приглашает воркера и сразу назначает его на job/visit, не дожидаясь принятия инвайта.
Достигается пре-провижном стабильного `workerId == Tofu.Auth User.Id` в момент создания
инвайта; реальный аутентифицированный пользователь связывается с placeholder по email на
accept. Инвариант `workerId == User.Id` сохраняется во всех слоях.

## Chosen approach vs alternatives

- **Option A (chosen)** — Pending-membership с пре-провижном `User`. Сохраняет инвариант
  `workerId == User.Id`, новизна локализована в Tofu.Auth (новое состояние `User`/`UserTenantRole`
  = `Pending` + связывание по email на accept). BFF меняется минимально.
- **Option B (rejected)** — назначать по `InvitationId`/email и ре-байндить в `User.Id` на accept.
  Требует две формы `workerId` и data-миграцию назначений на accept; высокий риск рассинхрона,
  т.к. `workerId` жёстко = `User.Id` в фильтрах визитов, доменных событиях и авторизации.
- **Option C (rejected)** — убрать валидацию членства, разрешить любой Guid как `workerId`.
  Ломает инвариант: не резолвится имя воркера (`WorkerInfo`), его нет в списке команды,
  неоткуда взять стабильный id на клиенте.

## Same-email handling

Инвариант: **один глобальный `User` на email, много `UserTenantRole` на него.**
Инвайт = find-or-create `User` по email + добавить pending `UserTenantRole` для тенанта.

- **Один тенант, два инвайта на email** — уже закрыто: уникальный частичный индекс
  `(TenantId, Email)` для pending + resend/revoke в `CreateAsync`. В Option A добавляется
  upsert `UserTenantRole` по композитному PK `(UserId, TenantId)`.
- **Разные тенанты, один email** — штатная мульти-тенантность: `User` переиспользуется,
  добавляется второй `UserTenantRole`. Один `User.Id` ⇒ одинаковый `workerId` в обоих тенантах.
- Тенант-специфичные метаданные (имя/контакт) пишутся только в `UserTenantRole.AdditionalInfo`,
  не на глобальный `User` — это разводит конфликт двух инвайтов.

---

## Phase 1 — Tofu.Auth.Backend (producer, ships first)

### 1.1 Доменные состояния
1. [ ] `src/Tofu.Auth.Domain/Models/User.cs` — `UserStatus { Pending = 0, Active = 1 }` + `Status`.
   Placeholder создаётся `Pending`, без `ExternalUserId`. Идемпотентный
   `Activate(string externalUserId, AuthMethodType method)`: `Pending → Active`, проставляет
   `ExternalUserId`. Запрет обратного перехода (по аналогии с `IsAnonymous`).
2. [ ] `src/Tofu.Auth.Domain/Models/UserTenantRole.cs` — `MembershipStatus { Pending = 0, Active = 1 }`
   + `Status` + `Activate()`.

### 1.2 Репозитории / порты
3. [ ] `IUserRepository.FindByEmail(Email, ct)` — публичный лукап по email (отдельно от auth-пути).
4. [ ] `IUserTenantRoleRepository.Upsert(UserTenantRole, ct)` поверх PK `(UserId, TenantId)` вместо `Add`.

### 1.3 Find-or-create на создании инвайта
5. [ ] `src/Tofu.Auth.Application/Services/TenantInvitationService.cs` `CreateAsync` — в существующей
   транзакции, до сохранения `InvitationToken`, find-or-create по email:

   | Найдено по email | Действие |
   |---|---|
   | ничего | создать `User(Pending)` (email, без `ExternalUserId`) |
   | `User(Pending)` | переиспользовать |
   | `User(Active)` | переиспользовать |

   Затем `Upsert(new UserTenantRole(user.Id, tenantId, roleId){ Status = Pending })`.
6. [ ] **Гонка на insert.** Обернуть create-ветку в retry-on-conflict через существующий
   `UniqueConstraintViolationInterceptor`: на нарушение уникального индекса по `Email` —
   перечитать `FindByEmail` и переиспользовать.
7. [ ] Метаданные инвайта (`Name`/контакты) — только в `UserTenantRole.AdditionalInfo`;
   `BusinessName` — свойство инвайта/тенанта. Глобальный `User` не трогаем.
8. [ ] Вернуть `User.Id` (= будущий `workerId`) в `CreateTenantInvitationResponse`.

### 1.4 Активация на accept / первом входе
9. [ ] `src/Tofu.Auth.Domain/Services/UserRegistrationService.cs` `RegisterOrUpdateUserFor` —
   **ключевой путь**: при первом Firebase-входе найти existing `User` по email; если `Pending`
   без `ExternalUserId` — `Activate(...)`, а не создавать второй `User`. Подтвердить, что лукап
   по email срабатывает раньше создания (защита от дубля и от гонки «логин раньше accept»).
10. [ ] `src/Tofu.Auth.Application/Services/InvitationProcessingService.cs` `AcceptAsync`/`AcceptAllAsync` —
    `UserTenantRole.Status: Pending → Active` (+ существующий `MarkAsAccepted`).
11. [ ] Revoke pending-инвайта — деактивировать/удалить соответствующий pending `UserTenantRole`.
    Placeholder `User` оставлять, если есть другие членства.

### 1.5 gRPC-контракт (аддитивно)
12. [ ] `GetTenantUsers` response — `+ MembershipStatus` (новый tag, аддитивно), начать возвращать
    pending-членов. Дефолт для старых консьюмеров = Active.
13. [ ] Регенерировать прото, опубликовать `Tofu.Auth.Api.Client` NuGet (`publish-client.yaml`).

### 1.6 Миграция (PostgreSQL / EF Core), из `src/`
14. [ ] `dotnet ef migrations add INVC-XXX_PendingMembership -c AuthContext -p "Tofu.Auth.Persistence" -s "Tofu.Auth.Api" -o Migrations`
    — `User.Status` + `UserTenantRole.Status`, бэкофилл существующих строк в `Active`. Аддитивно.

---

## Phase 2 — Invoices.Backend (consumer / BFF, after Phase 1 deploy)

15. [ ] `Src/Jobs/Jobs.Application/Services/Workers/JobWorkerService.cs` `GetTeam` — `GetTenantUsersAsync`
    отдаёт pending-членов; прокинуть `MembershipStatus` в `TeamMember`. Pending-член попадает в `Team`
    ⇒ `Team.GetWorkerOrThrow` проходит ⇒ `AssignWorkerToVisitCommandHandler` назначает без изменений.
16. [ ] `Src/Jobs/Jobs.Domain/Models/Team.cs` `TeamMember` — `+ MembershipStatus` (или `bool IsPending`).
    `Job.UpdateVisitWorker` без изменений — pending разрешён к ассайну.
17. [ ] `Src/Invoices.Api/Services/TeamService.cs` + `GET /api/team/members`
    (`Src/Invoices.Api/Controllers/TeamController.cs`, DTO `Src/Invoices.Api/Dto/Team/TeamMemberListResponseDto.cs`)
    — отдавать pending-членов с флагом статуса.
18. [ ] **Gating воркерской сессии — главный риск-пункт.**
    `Src/Invoices.Api/Controllers/WorkerController.cs` и воркер-facing действия
    (`Job.ValidateVisitUpdateByWorker`) должны отклонять воркера с membership `Pending` —
    проверка по статусу, не по факту членства. При необходимости добавить проверку в
    авторизацию/middleware (`BaseController.AuthenticationInfo`).
19. [ ] Stale-ссылки при revoke/удалении pending-воркера — переиспользовать
    `Job.UnassignWorkerFromAllVisits()` (`Src/Jobs/Jobs.Domain/Models/Job.cs`).

---

## API / DTO changes

- gRPC `GetTenantUsers` response: `+ MembershipStatus` (аддитивно).
- REST `GET /api/team/members`: `+ membershipStatus` / `isPending` в `TeamMemberDto`.
- REST create-invitation response: `+ userId` (workerId для немедленного ассайна).
- `Visit.AssignedWorkerId` — без изменений (text, без FK; уже терпит pending-ссылку).

## Breaking changes

**None — additive only.** Новые enum-поля с дефолтами, новые опциональные поля ответов,
бэкофилл миграции в `Active`, прото-теги не перенумеровываются.

## Data / migration

- Phase 1: одна EF-миграция (`User.Status`, `UserTenantRole.Status`, бэкофилл `Active`).
- Invoices.Backend (Jobs/Postgres): миграций нет — `AssignedWorkerId` уже nullable text.

## Open questions

- [ ] Где в воркерской сессии доступен membership-статус для gating (шаг 18) — токен/сессия
  Tofu.Auth или отдельный лукап в BFF?
- [ ] Судьба placeholder `User` при revoke последнего членства (оставлять vs чистить).
- [ ] Нужен ли TTL/реминдер по pending-членству, чтобы placeholder-ы не копились.
- [ ] Инвайт email активного юзера, уже member этого тенанта — no-op vs смена роли (в рамках
  одного тенанта — upsert роли).

## Test plan

- **Tofu.Auth — integration (`Tofu.Auth.Api.Tests.Functional`, Testcontainers Postgres):**
  - create invite на новый email ⇒ `User(Pending)` + `UserTenantRole(Pending)`, ответ с `userId`.
  - два инвайта на email из разных тенантов ⇒ один `User`, два `UserTenantRole`.
  - повторный инвайт в тот же тенант ⇒ upsert, не дубль/не падение.
  - первый Firebase-вход placeholder-а ⇒ активация того же `User.Id`, без второго `User`.
  - accept ⇒ `UserTenantRole.Status → Active`.
  - конкурентные инвайты на новый email ⇒ retry-on-conflict, один `User`.
- **Invoices.Backend — integration (`Invoices.Tests.Integration`):**
  - ассайн pending-воркера на visit ⇒ успех, `AssignedWorkerId` проставлен.
  - `GET /api/team/members` ⇒ pending-член с флагом.
  - pending-воркер дёргает `WorkerController` ⇒ отказ до accept.
- После тестов — прогнать `/tests` по новым файлам.

## Rollout order

1. Tofu.Auth: миграция → деплой → публикация `Tofu.Auth.Api.Client`.
2. Invoices.Backend: обновить клиент, реализовать Phase 2, деплой.
3. Local.Docs: PR с план-доком (мёржится последним).
