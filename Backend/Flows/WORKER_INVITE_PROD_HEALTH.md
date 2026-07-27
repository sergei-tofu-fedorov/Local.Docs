# Инвайт-флоу воркера в PROD — сводное расследование

> Сводное состояние инвайт-флоу воркера в проде (BFF ↔ Tofu.Auth ↔ Tofu.Invoices): вердикты по интеграции, воронка принятия, TTL/magic-login, `account_access_denied`, email-case баг. Спецификация флоу (диаграммы, эндпоинты, схема БД) — в [`INVITATION_FLOWS.md`](INVITATION_FLOWS.md); здесь — наблюдаемое поведение и числа, а не контракт. (Документ на русском по запросу владельца — отклонение от англоязычного правила Local.Docs.)

**Дата:** 2026-07-23 · **Окно:** последние 30 дней (email-case — окно 13–22 июля) · **Env:** PROD `inv-project`
**Scope:** Invoices.Backend BFF (`invoices-api`) + `invoices-worker` + Tofu.Auth (`auth-api`) + Tofu.Invoices core. Внешняя доставка пушей — OnePush.
**Первоисточник (сырьё запросов):** `Investigations/investigations/worker-invite-prod-integration-recheck/` (`queries/`).

## Задеплоенное состояние (prod)

| Репо | Ветка / HEAD | Дата |
|---|---|---|
| Invoices.Backend (BFF) | `origin/master` @ `cccff3d` | 2026-07-22 |
| Tofu.Auth.Backend | `origin/main` @ `a636e44` | 2026-07-21 |
| Tofu.Invoices.Backend (core) | `origin/main` @ `222d048` | 2026-07-07 |

> У BFF **нет** ветки `origin/main` — прод крутится с `origin/master`. BFF `Tofu.Auth.Api.Client` = `0.9.0-preview004`.
> (Auth HEAD обновился до `a636e44` после мержа email-case фикса 2026-07-21; ранее был `c3667cc` от 07-16.)

---

## Проблемы, которые у нас есть (сводка)

Ядро инвайта (create / accept / workerUserId pre-provision) в проде **здорово** — бизнес-ошибок нет. Реальные проблемы — точечные, в пушах и на клиенте:

| # | Проблема | Серьёзность | Где чинить | Импакт |
|---|---|---|---|---|
| 1 | worker-joined push **ненаблюдаем** (нет логов happy-path, ошибки глушатся) + шлётся нетаргетированно и режется гейтом `Platform.IOS`-only / `AccountNotFound` | **высокая** (потери не видим) | бэкенд `TeamNotificationService` | владелец может не получать «воркер присоединился», и мы этого не замечаем |
| 2 | Таргетированного **worker-push (job/visit) в проде НЕТ** (FS-1371 не смёржен) | средняя (если фича ожидается) | смёржить/задеплоить FS-1371 | воркеры не получают push о назначении работ; сейчас polling/sync |
| 3 | Клиент **magic-login дублирует вызов** (конкурентный дубль) → шум `magic_link_used` | низкая (косметика) | клиент (worker-app): in-flight guard | воркеров не теряет; замусоривает 400-метрику |
| 4 | Клиент **`tofu` шлёт чужой `Account-Id` на `/accept`** → 403 `account_access_denied` | низкая | клиент (`tofu` iOS) | 3 случая/30д (2 внутренних, 1 клиент) |
| 5 | Латентно: `MarkUserAsAccountOwnerIfRequired` **авто-присваивает владение** безхозным аккаунтом из заголовка `Account-Id` | потенциальная (security) | бэкенд `AuthApiAuthenticationService` | сейчас спасает наличие владельца; при безхозном аккаунте — риск угона |
| 6 | 403 «Jwt required» на `GET /api/invitations` — клиент без сессии, один аккаунт зациклен на 20+ | низкая | клиент | шум, не бэкенд-баг |
| — | ~~case-sensitive email lookup~~ | **закрыто** | — | пофикшено 2026-07-21 (PR #62) |

Подробности каждого — в разделах ниже.

---

## 1. Вердикты по интеграционным швам

| Шов | Вердикт | Суть |
|---|---|---|
| Отправка инвайта (email/sms) | ✅ здоров | `InvitationsController.CreateInvitation`/`CreateSmsInvitation`; `workerUserId` pre-provision серверный в Auth `TenantInvitationService.CreateAsync` (миграция FS-1324 на месте). |
| Принятие + workerUserId binding | ✅ здоров | `AcceptAll`/`AcceptInvitation` → `InvitationProcessingService`; `WorkerUserId` протянут по цепочке DTO. |
| WEB-1734 регрессия worker-joined | ✅ пофикшена в проде | `bb3b02b`: `isCreated = string.IsNullOrEmpty(existing?.Name)` (`TenantService.cs:122`) — штамп accept-time (`ccbe72d`) больше не ломает гейт. |
| worker-joined push доставка | ⚠️ ненаблюдаем + нетаргетирован | `TeamNotificationService.SendWorkerJoinedPushAsync:28-50` не логирует happy-path, глушит ошибки, шлёт нетаргетированно (`AccountId` + `tofu-fieldservice`), тихий `return` если у владельца нет **iOS**-`PlatformUserLink`. 0 строк worker-joined за 30д. |
| Таргетированный worker-push (job/visit) | ❗ в проде НЕТ | Нет `JobNotificationService` / продюсера с `TargetMasterUserId`+`tofu-fieldservice-worker` (строка только в OpenAPI-enum). FS-1371 не смёржен → воркеры на polling/sync. |

В prod-логах массово `Account not found in the Push service` и `Platform user link not found for products [tofu, tofu-fieldservice]` (×10) — оба ломают адресацию owner-пуша.

---

## 2. Воронка принятия инвайта (30д)

Уникальные воркеры (`MasterUserId`) на accept-эндпоинтах (`AcceptAll` + `AcceptInvitation`):

| Метрика | Значение |
|---|---|
| Воркеров **пытались** принять | **64** |
| Воркеров **успешно** (≥1×200) | **56** (≈88%) |
| Не приняли ни разу | 8 |

Разбивка не-GET invitation-POST по endpoint×status:

| Endpoint | 200 | 204 | 400 | 403 |
|---|--:|--:|--:|--:|
| CreateInvitation | 188 | — | 3 | 14 |
| CreateSmsInvitation | 2 | — | — | — |
| AcceptAll | 65 | — | 36 | — |
| AcceptInvitation (single) | 13 | — | 1 | 3 |
| MagicLogin | 26 | — | 27 | — |
| RevokeInvitation | — | 18 | 1 | 3 |

Разрыв 66% (запросы) ↔ 88% (воркеры) = ретраи: `AcceptAll` воркер-апп зовёт рутинно, 400 = уже член, не провал.

### Итоговая таблица исходов вступления (30д)

**Attempt-level** (по эндпоинтам, категории succeeded / error-но-вступил / failed):

| Стадия | Категория | N | Код/причина | Деталь |
|---|---|--:|---|---|
| magic-login | ✅ succeeded | 26 | — | токен обменян на сессию |
| accept-all | ✅ succeeded | 65 | — | принял pending-инвайт |
| accept-invitation | ✅ succeeded | 13 | — | принял по токену |
| accept-all | ⚠️ error, но вступил | 36 | `user_already_in_tenant` | уже член — повторный вызов |
| accept-invitation | ⚠️ error, но вступил | 1 | `user_already_in_tenant` | уже член |
| magic-login | ⚠️ error, но вступил | 15 | `invitation_token_already_accepted` | инвайт уже принят |
| magic-login | ⚠️ error, но вступил | 6 | `magic_link_used` | дубль-гонка, принят первым вызовом (4 токена) |
| accept-invitation | ❌ failed | 3 | `account_access_denied` (403) | клиент `tofu` шлёт чужой `Account-Id` (2 внутр. + 1 клиент) |
| magic-login | ❌ failed | 3 | `invitation_token_not_found` | битая/чужая ссылка |
| magic-login | ❌ failed | 2 | `magic_link_expired` | >12ч |
| magic-login | ❌ failed | 1 | `invitation_token_revoked` | инвайт отозван |

**Worker-level** (уникальные на accept-эндпоинтах):

| Исход | Воркеров | Как определено |
|---|--:|---|
| ✅ Вступили в окне | 56 | ≥1 ответ 200 на accept |
| ⚠️ Уже были членами | 7 | только `user_already_in_tenant` |
| ❌ Проваленная попытка `/accept` | 3 события | `account_access_denied` (`sarah` + `tanya`/`zudwa` внутр.) |
| ⚠️ Заблокированы на lookup (email-case, до фикса 07-21) | 7 email (~4 внешних) | mixed-case `worker/summary` → «нет приглашений» тихо (200); **отдельная стадия — в accept-метрики не попадают** |

**Итог:** из 63 уникальных воркеров на accept-эндпоинтах членами являются все 63 (56 приняли в окне + 7 уже были). Единственные неуспешные попытки на accept — 3× `account_access_denied` на `/accept` (клиентский Account-Id, 2 внутр. + 1 клиент), не блокер. Из 64 всех 400 по инвайт-флоу **58 доброкачественные** (37 `user_already_in_tenant` + 15 `already_accepted` + 6 `magic_link_used`).

**Отдельная (невидимая в accept) категория — email-case до фикса 07-21:** 7 email-вариантов дёргали `worker/summary` с заглавной буквой и молча получали «нет приглашений» (см. §5). Из них ~4 реальных внешних (`strongarmlawnservice71`+опечатка `strongarmservice71`, `krystal.campbell10`, `ahmadindustries1`, `umaridrisayuba`), `a.gorshkova+wrk@tofu.com` (внутр.), `aeg6608+work` (тестер с алиасами). `strongarmlawnservice71` повторял 4× за 07-13…07-17 (застревал). Эти воркеры **не видны в accept-таблице** — их блокировало на стадии поиска. Финальный факт вступления по логам не закрыть (accept-all не логирует email/invitationId) — нужен статус приглашения в auth Postgres (`InvitationToken.AcceptedAt`) или членство в BFF Mongo.

---

## 3. TTL-настройки и magic-login

`Tofu.Auth.Domain/Configuration/InvitationConfig.cs` (дефолты; в `appsettings*.json` НЕ переопределены; env/k8s не проверялся):

| Настройка | Значение | Смысл |
|---|---|---|
| `InvitationTokenTtl` | **7 дней** | инвайт-токен (окно на accept) |
| `MagicTokenTtl` | **12 часов** | magic-login токен (обмен ссылки на сессию) |
| `MaxInvitationsPerTenantPerHour` | 20 | рейт-лимит создания |

Magic-токен одноразовый (`InvitationMagicToken.MarkAsUsed`), генерится 1× при отправке/resend, вшит в ссылку (`?token=…&ml=…`).

**Раскладка 27 magic-login 400 по коду ошибки:**

| Код (wire) | N | % | Значение |
|---|--:|--:|---|
| `invitation_token_already_accepted` | 15 | 56% | инвайт уже принят — повторное обращение |
| `magic_link_used` | 6 | 22% | одноразовый токен уже использован |
| `invitation_token_not_found` | 3 | 11% | токен не найден (битая/чужая ссылка) |
| `magic_link_expired` | 2 | 7% | реально протух (>12ч) |
| `invitation_token_revoked` | 1 | 4% | инвайт отозван |

**Вывод:** истечение почти ни при чём (2/27). 78% — повторы к уже израсходованному инвайту/токену. **Крутить `MagicTokenTtl` не нужно.** Коды `already_accepted`/`revoked` — из `EnsurePending()`→`InvitationNotPendingException`; `magic_link_*`/`not_found` — из `MagicLoginException` (`InvitationToken.cs:250-277`).

> ⚠️ Наблюдаемые wire-коды ≠ внутренним именам enum из `INVITATION_FLOWS.md` (`TokenNotFound`/`TokenExpired`/…). Клиент по сети видит именно коды из таблицы.

### «Почему второй запрос» (magic-login) — Sentry + последовательности

По 53 POST magic-login (31 уникальный токен): **17 токенов — один вызов** (15×200 успешно), **14 токенов — ≥2 вызова**, из них **11 начинаются с 200** (первый успешен), последующие 400 — дубли/переоткрытия. Два подпаттерна:

1. **Немедленный дубль (200 → 400 через ~5–95 сек):** клиент шлёт magic-login дважды подряд; первый обменял одноразовый токен, второй → `magic_link_used`. Доминирует.
2. **Отложенный повтор (часы/дни):** переоткрытие той же invite-ссылки после входа → `invitation_token_already_accepted` (напр. `200 → 400+5s → 400+25.3h → 400+50.2h`).

**Sentry (org getpaid-inc):** в воркер-проектах (`fieldservice-worker-ios/android`) — **0 issue** про invite/magic/accept; по `magic` — ноль во всей орге. Единственное invite-related — `INVOICE-MAKER-IOS-30Q` = **HTTP 502 на `GET /api/invitations`** (инфра-blip основного iOS-app, 23 юзера), к magic-login не относится. → Клиент второй запрос как ошибку **не репортит** ⇒ это **не краш/ретрай-на-ошибку**, а тихий дубликат вызова (двойная обработка deep-link / двойной тап / нет in-flight-guard) + переоткрытие ссылки. Онбординг здоров.

**`magic_link_used` (6) ≠ `already_accepted` (15).** По коду `magic_link_used` возможен **только пока инвайт ещё `Pending`**: `FindAndValidateInvitationAsync` вызывается до `UseMagicToken` и на статусе `Accepted` кидает `invitation_token_already_accepted` раньше. Значит на момент USED-вызова инвайт **не был принят** — второй вызов просто обогнал приёмку. Все 6 — это **4 токена**, каждый = первый magic-login `200` + `USED` через 11–147 сек (конкурентный дубль, а не потеря воркера); приёмка идёт следом через accept-all (не логирует invitationId → по логам не подтверждается). Из 4: `IcVE5y4…` принят (уже член — тот же аккаунт дал `user_already_in_tenant`/`InvitationAlreadyAcceptedException`), `8HXrE1H…`/`PrDfcn…` — внутренние (`tanya@tofu.com`/`zudwa87@yandex.ru`, они же дали `/accept`-403), `QL1Qqx…` (внешний, tenant `b134f9db`) — по логам не закрыт. Явно «застрявших» нет.

---

## 4. `account_access_denied` (403) на `/accept` — механизм

3 события `POST /api/invitations/{token}/accept`, продукт **`tofu`** (owner-app, НЕ воркер-апп):

| Trace | Дата | Юзер | MasterUserId | Присланный чужой Account-Id |
|---|---|---|---|---|
| `2d07c72e…` | 2026-07-09 19:36 | `sarah@mssarahshousekeeping.co` (реальный клиент) | `90f6c6d0…` | `pb4k7aafus-…` |
| `415be48d…` | 2026-07-09 12:23 | `tanya@tofu.com` (внутр.) | `81eb50e2…` | `a6cn7j796c-…` |
| `f47e7df8…` | 2026-07-02 08:51 | `zudwa87@yandex.ru` (внутр. dev) | `f1b7ea0b…` | `36f4j91z02-…` |

**Механизм** (подтв. стектрейсом): клиент `tofu` шлёт заголовок `Account-Id` приглашающего бизнеса на `/accept`, но юзер ещё не член этого аккаунта. `MarkUserAsAccountOwnerIfRequired`: аккаунта нет в `AllAccountIds` → пытается сделать юзера владельцем → `AccountHasAnotherOwnerException` (у аккаунта уже есть владелец) → лог `Account '…' has another owner` → далее `AccountAccessDeniedException` (`AuthApiAuthenticationService.cs:68/71`) → **403 до контроллера accept**. `/accept` авторизуется токеном+JWT, заголовок `Account-Id` ему не нужен.

**Фикс — клиентский** (`tofu` iOS): не слать чужой `Account-Id` на `/accept`. Импакт крошечный (2/3 внутренние, 1 реальный клиент). Латентно: `MarkUserAsAccountOwnerIfRequired` авто-присваивает владение любым **безхозным** аккаунтом из заголовка — здесь спасло наличие владельца.

---

## 5. Case-sensitive email lookup — тихий баг (пофикшен 2026-07-21)

**Баг:** email хранится нормализованным (lowercase, `Email.NormalizeEmail()`), а поиск `ByEmail(...)` до фикса шёл по сырому регистру → приглашение пользователя **не находилось** в путях worker-summary / accept-all / list-by-email. Проявление — **HTTP 200 с пустым списком** («нет приглашений»), **НЕ исключение**.

**Сколько ошибок:** по error-логам — **0** (баг тихий; за окно 13–22 июля `WorkerController.GetSummary` 172×200 без единой ошибки, ни одного 5xx/403 email-mismatch; в `auth-api` case-ошибок нет).

**Реальная экспозиция (верхняя оценка):** из 172 worker-summary вызовов в окне **15 пришли с mixed-case email** → молча получили «нет приглашений». Уникальных ~7–8 адресов (часть повторы), 1 внутренний тест (`A.Gorshkova+wrk@tofu.com`). Примеры: `Krystal.campbell10@…`, `Aeg6608+work@…`, `Ahmadindustries1@…`, `Umaridrisayuba@…`, `Strongarmlawnservice71@…`. Характерно — **заглавная первая буква** (авто-капитализация мобильной клавиатуры). Это верхняя оценка: наличие pending-инвайта у каждого из 15 по БД не подтверждалось.

**Фикс:** `5c7d296` «Fix case-sensitive email matching on invitation lookup» (нормализация через `Email`/`Email.TryParse` перед `ByEmail`), смёржен в `origin/main` **2026-07-21 09:37** (PR #62, `a636e44`). Вероятно проявился с деплоем WEB-1734 (07-16) → «около недели»; сам case-sensitive поиск мог существовать и раньше.

---

## Что НЕ является причиной

- **WEB-1734 регрессия worker-joined** — пофикшена `bb3b02b` в проде.
- **Регистрация токена воркера / dual-key routing (FS-1371)** — это dev2, не prod.
- **403 «Jwt required to request Auth API»** на `GET /api/invitations` (34× за 30д, один аккаунт `wtmjjhg60w` зациклен на 20+) — клиентский (iOS дёргает JWT-only эндпоинт без сессии), не бэкенд-баг.

---

## Рекомендации

1. **Логирование `SendWorkerJoinedPushAsync`** — happy-path + причина раннего return + результат enqueue (сейчас путь ненаблюдаем).
2. **Продуктовое решение по гейту `Platform.IOS`** — worker-joined режет Android/Web-владельцев.
3. **Ожидание push у воркеров** — зафиксировать: push о назначении работ в проде нет (FS-1371 не задеплоен).
4. **Клиент — magic-login:** in-flight guard от повторного вызова + гасить обработку deep-link после успешного онбординга (убирает дубли/`already_accepted`).
5. **Клиент `tofu` — /accept:** не слать чужой `Account-Id`.
6. **Email-case** — уже пофикшено (2026-07-21); отдельных действий не требуется.

---

## Limitations

- Exact `=` по `RequestPath`/`StatusCode` ненадёжен — использованы substring `:` / negation. GET-список упирался в cap 2000 → исключён из endpoint-таблиц.
- worker-joined / targeted-push выводы — по substring-поиску в `jsonPayload.message`; иное логирование могло быть пропущено. `set_identifiers` не логирует product → нельзя доказать регистрацию токенов воркерами (XA-App-Type пуст на ~82% строк).
- email-case: 15 — верхняя оценка экспозиции (наличие pending-инвайта у каждого не подтверждалось по БД); точная дата регрессии по логам не устанавливается.
- Sentry: клиентских .NET-проектов нет; backend-ошибки — только в GCP.
- env/k8s override `MagicTokenTtl` не проверялся (подтверждены дефолты кода).

## Источники
- Первоисточник + сырьё запросов: `Investigations/investigations/worker-invite-prod-integration-recheck/` (`queries/`).
- Коммиты: `bb3b02b` (isCreated fix), `ccbe72d` (WEB-1734 stamp), `5c7d296`/`a636e44` (email-case fix, PR #62).
- Sentry: `INVOICE-MAKER-IOS-30Q` (502 на GET /api/invitations, инфра).
