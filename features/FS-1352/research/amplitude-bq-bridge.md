# FS-1352 — мост Amplitude → BigQuery (путь B: DIY Export-API)

**Статус:** дизайн (2026-07-09)
**Тип:** инфраструктурный воркстрим, соседний с FS-1352 (не часть «лёгкой» эмиссии событий).

## Зачем

Наши продуктовые события BFF (Path 1 → Amplitude), включая будущие FS-1352 send/payment,
**сегодня в нашу BQ не попадают вообще**. Канонический вью `analytics.all_events` в `inv-project`
юнионит только GA4/Firebase (iOS) + `analytics.events` (пишет Subz, биллинг). Amplitude-данные
доходят до BQ **только** через маркетинговый `playfair-project` (org-side, чужое владение).
Значит продуктовые события не queryable в `ai_analysis_us` и не джойнятся по `account_id`.

Мост даёт им дом в нашем проекте. Польза шире FS-1352 — queryable становятся **все** продуктовые
события, а не только новые.

## Решение (2026-07-09)

- **Путь B — DIY Export-API → BQ.** Нативный экспорт Amplitude (путь A) недоступен: нет org-admin
  и warehouse-export в плане. Read-only Export-ключей достаточно.
- **Хост — `Tofu.AI.Backend`.** Переиспользуем его prod SA (Workload Identity), BQ/GCS-клиенты,
  Hangfire-планировщик, resilient HTTP и GKE-пайплайн вместо нового сервиса.
- **Тянем ВСЕ события** (уточнено 2026-07-09) — под behavioural-анализ (scrolls/taps и т.п.), а не только
  FS-1352-набор. `EventTypes` в конфиге = `[]` (пусто = все); allow-list оставлен дремлющим опциональным
  рубильником (напр. подрезать один сверх-объёмный проект). Курирование/фильтр под FS-1352 — downstream в мартах.
- **Инкремент — только watermark** (уточнено 2026-07-09). `sys_amplitude_export_state.last_hour` на проект =
  курсор «откуда продолжить»; штатный тик тянет строго новые часы, без ре-чтения. Export API — только
  time-windowed (id-курсор невозможен), поэтому резюме по последнему завершённому часу. **Integrity/reconcile
  ре-пул НЕ добавляем** — для behavioural-стора lossy-by-design приемлемо; при необходимости позже добавим
  отдельный `amplitude-reconcile` джоб под флагом (хвост N дней, `MERGE by insert_id` идемпотентен).
- **Дневной цикл + 90-дневное хранение** (уточнено 2026-07-09). Cadence = `0 4 * * *` (раз в сутки, 04:00 UTC),
  **day-granular**: один Export-запрос на день (`start=DT00&end=DT23`, зип из 24 gz-файлов) → один load → **один
  MERGE/день** (вместо 24 почасовых MERGE'ей, каждый из которых full-scan'ит таргет по `insert_id` → на 90-дн. столе
  было бы ~$180/мес; теперь ~$7.5/мес). `MaxCatchUpDays=3` (догон oldest-first, кэп дней/прогон).
  Таблица `src_amplitude_events` c `partition_expiration_days = 90` — rolling-90д, storage кэпится ~40 GB, старые
  партиции авто-дропаются. Watermark = последний обработанный день.
- **Первый прогон = backfill на `BackfillDays` (=90)** (уточнено 2026-07-09). Правило первого запуска: при **пустом
  watermark** джоба тянется назад на `BackfillDays-1` дней от последнего settled-дня (совпадает с 90-дн. retention →
  сразу заполняем весь удерживаемый окно, а не «со вчера»). Backfill идёт **oldest-first**, не больше `MaxCatchUpDays`
  дней за прогон, поэтому на запуске поднимаем `MaxCatchUpDays` (или триггерим повторно), чтобы догнать быстро; при
  90-дн. хранении глубже 90 дней смысла нет. Как только watermark появился — `BackfillDays` игнорируется, идём с
  watermark+1. Проверено на stage job-level live-прогоном (iOS-dev 622476, разреженный → backfill дёшев).
- **GCS убран** (уточнено 2026-07-09). Sink грузит **напрямую** через `BigQueryClient.UploadJsonAsync` (клиент
  сам заливает NDJSON-строки в staging → `MERGE`) — load-job бесплатен, JSON-колонки нативны, минус бакет/IAM/
  lifecycle. Отказались от immutable replay-артефакта: watermark не двигается до успешного MERGE → упавший час
  сам ре-пулится следующим тиком (данные свежих часов у Amplitude есть). Колонка `gcs_uri` и `AmplitudeSinkOptions`
  удалены; тест-бакет `tofu-amplitude-export-test` дропнут.
- **Стриминг + row-батчи** (уточнено 2026-07-09) — день **не материализуется целиком** (иначе iOS-prod ~307K событий ≈
  ~1GB в памяти → OOM на prod-лимите 1024Mi). Парсер `yield`, клиент `StreamDayAsync : IAsyncEnumerable`, sink грузит
  чанками по `BigQueryOptions.AmplitudeBatchSize` (дефолт **50000**): первый чанк `WRITE_TRUNCATE`, остальные
  `WRITE_APPEND` в daily-staging → **один MERGE**. Пик памяти ≈ zip (~70MB) + один батч (~85MB) ≈ ~150MB. Фильтр
  `EventTypes` — на стриме (в джобе, со счётчиком fetched/kept). Идемпотентность цела (watermark после полного MERGE;
  ретрай стартует с TRUNCATE).

## Архитектура

```
Hangfire recurring job (cron "0 * * * *", [AutomaticRetry], [DisableConcurrentExecution])
  AmplitudeExportJob
    │  watermark (last loaded hour per project) → окно [T-lag-1h, T-lag)   (lag ≈ 2h, задержка обработки Amplitude)
    ▼
Amplitude Export API   GET https://amplitude.com/api/2/export?start=YYYYMMDDTHH&end=YYYYMMDDTHH
    │  Basic auth (api_key : secret_key)  ← per-project export-креды (см. блокер ниже)
    │  ответ = zip( *.json.gz ), одна строка = одно событие (NDJSON)
    ▼
GCS raw zone (immutable)   gs://<bucket>/amplitude-export/project=<id>/dt=YYYY-MM-DD/hour=HH/*.json.gz
    │  replay / backfill-friendly
    ▼
BigQuery  inv-project : amplitude  (dataset, US location — обязательно US, иначе join к ai_analysis_us невозможен)
    │  external table ext_events над GCS-префиксом  →  MERGE by insert_id  →
    ▼
amplitude.src_events   (native, partition by DATE(event_time), cluster (event_type, user_id))
    │  scheduled query / view (парсинг event_properties JSON → типизированные колонки; фильтр source='backend')
    ▼
amplitude.mart_document_sends , amplitude.mart_payment_received   ← джойнятся к ai_analysis_us по account_id
```

## Заземление на реальных данных (iOS prod 213333, окно 2026-07-08T12, снято 2026-07-09)

Реальный pull через Export API (`auth.txt`, iOS prod) — **работает нашими read-ключами**, 2.8 MB/час.

- **11 393 события/час, 92 типа.** Схема события = полный Amplitude-export: `$insert_id` (+`event_id`,
  `uuid`), `event_time`/`client_event_time`/`server_received_time`/`processed_time`, `event_type`, `user_id`,
  `device_id`, `amplitude_id`, `session_id`, `event_properties`, `user_properties`, гео/девайс/`idfa`/`adid`/
  `library`/`app`/`platform`/`os_name`/`paying`/`plan`.
- **`accountId` — в `event_properties`** (10820/11393 = 95%; остальное анонимные). Ключ джойна к `ai_analysis_us`.
- **Блокер #1 частично снят:** в проекте 213333 присутствуют BFF-эмитируемые `Payment received`
  (полный набор props) и `Payment account status` → **backend-события Invoices.Backend приземляются в iOS
  prod 213333** (для iOS-admin-инициированных запросов). Export-ключи для него есть. Web-инициированные,
  вероятно, в web-prod 586241 (тоже с ключами) — отсюда требование мульти-проектности.
- FS-1352-события подтверждены: `Send invoice` (props `accountId, application, template, context,
  is_first_time, attachments_count`; `application` = канал mail_server/share), `Send estimate`, `Mark invoice`,
  `Tap send invoice/estimate`.

## Мульти-проектность и реестр проектов

Tool извлекает из **нескольких Amplitude-проектов** и тегает каждое событие проектом-источником.
Реестр проектов (config-driven), одна запись = проект + его export-креды + метаданные:

| Поле | Пример |
|---|---|
| `projectId` | `213333` |
| `name` | `INV / Invoice Maker (iOS)` |
| `platform` | `ios` |
| `env` | `prod` |
| `apiKey` / `secretKey` | export Basic-auth креды (из Secret Manager / GSM prod-appsettings) |
| `enabled` | `true` |

Каждое событие в BQ несёт `_source_project` (= `projectId`) + опционально `_source_platform`/`_source_env`.
Порядок включения: **iOS prod 213333 первым** (креды есть, blocker-free), затем web-prod 586241, затем dev-проекты.

## Схема `amplitude.src_events` (raw, curated + JSON-хвост)

Партиционирование `PARTITION BY DATE(event_time)`, кластеризация `CLUSTER BY event_type, user_id`.

| Колонка | Тип | Источник / назначение |
|---|---|---|
| `insert_id` | STRING | Amplitude `$insert_id` — **ключ дедупа** (MERGE) |
| `event_time` | TIMESTAMP | партиция |
| `event_type` | STRING | имя события |
| `user_id` | STRING | наш resolved userId |
| `device_id` | STRING | |
| `amplitude_id` | INT64 | Amplitude internal id |
| `account_id` | STRING | из `event_properties.accountId` (BFF инжектит) — ключ джойна к `ai_analysis_us` |
| `session_id` | INT64 | |
| `platform`,`os_name`,`app_version`,`country` | STRING | curated контекст |
| `event_properties` | JSON | сырой блоб (schema-on-read для длинного хвоста) |
| `user_properties` | JSON | сырой блоб |
| `_source_project` | STRING | какой Amplitude-проект (lineage) |
| `_gcs_uri` | STRING | файл-источник (lineage/replay) |
| `_ingested_at` | TIMESTAMP | время загрузки |

**Марты** (`mart_document_sends`, `mart_payment_received`) — по схемам из
[`send-events-bq.md`](./send-events-bq.md) и раздела payment; парсят `event_properties` и
фильтруют `source='backend'`, чтобы не задваивать клиентские события.

## Идемпотентность, watermark, backfill

- **Дедуп** по `insert_id` через `MERGE` в `src_events` → перекрытие почасовых окон и ретраи не двоят.
- **Watermark** — последний успешно загруженный час на проект (строка в Postgres, как у существующих
  джобов, либо BQ `sys_amplitude_export_state`). Позволяет догон после простоя и контролируемый backfill.
- **Backfill** — разовый прогон цикла по историческим часам от нужной даты до `now-lag`
  (глубина Export API зависит от плана Amplitude — подтвердить).
- **Lag ≈ 2h** — Export API отдаёт данные после обработки (обычно 1–2 ч), поэтому окно всегда
  отстаёт от now на safety-lag.

## Building blocks: есть vs net-new (по разведке `Tofu.AI.Backend`)

| Нужно | Статус | Точка переиспользования |
|---|---|---|
| Почасовой триггер | ✅ есть | Hangfire `AddOrUpdate` + cron `"0 * * * *"` (`Analyses.Application/DependencyInjection.cs:43`) |
| BQ auth к `inv-project` | ✅ есть | общий `BuildCredential` (ADC/Workload Identity, `Analyses.Infrastructure/DependencyInjection.cs:224`) |
| BQ клиент + запись | ✅ есть | `BigQueryClient` / внешние таблицы над GCS / Storage Write API |
| GCS read/write | ✅ есть | `StorageClient` (`StorageService.cs`, `GcsSnapshotLocator.cs`) |
| Инъекция внешних ключей | ✅ паттерн | options-секция + GSM prod-appsettings (как `OpenAiOptions`) |
| Outbound HTTP + retry | ✅ есть | named `HttpClient` + `AddStandardResilienceHandler` (429/5xx) |
| GKE-деплой в prod | ✅ есть | `publish-deploy.yaml` → GKE, `inv-project` |
| Amplitude Export client (zip→gz→NDJSON) | ❌ net-new | новый typed client + декомпрессия |
| `Amplitude` options/secret секция | ❌ net-new | тривиально, зеркалит `OpenAiOptions` |
| NDJSON→BQ загрузка | ⚠️ частично | у них external-tables/Storage-Write, не `CreateLoadJob` — добавить external-table или load-job шаг |

## 🚩 Блокер #1 — целевой Amplitude-проект + export secret_key

Export API тянет из **конкретного проекта** по Basic `(api_key : secret_key)`. Нужно точно знать,
**в какой Amplitude-проект приземляются backend-события Invoices.Backend**, и есть ли у нас его
`secret_key`.

Известно:
- BFF маршрутизирует по `ProductKey` из конверта → один Amplitude-проект; prod/sandbox — по per-event
  свойству `environment` (`"sandbox"` → sandbox-ключ, иначе prod). Реальный productKey приходит из
  middleware BFF (клиентский продукт: web / iOS-admin / fieldservice).
- В репо `Tofu.Analytics.Backend` — только placeholder ingestion `api_key`; реальный маппинг
  `Products → api_key` живёт в **k8s-секрете `analytics-api-secret`** (`appsettings.Production.json`).
  `secret_key` там **нет** (нужен только для ingestion).
- У нас есть Export read-ключи (api_key+secret_key) для **4 проектов**: iOS prod `213333` / iOS dev
  `622476` / web prod `586241` / web dev `586242` (см. `/amplitude`-скилл).

Нужно резолвнуть: совпадает ли ingestion-проект «Tofu»/web с одним из этих 4 (тогда export-креды у нас
уже есть), или это отдельный 5-й серверный проект (тогда нужен его `secret_key`).

**Как резолвить (шаг 0):** прочитать k8s-секрет `analytics-api-secret` (`appsettings.Production.json`)
в `invoices-cluster` → сопоставить ingestion `api_key` продукта с api_key одного из 4 export-проектов.
Это prod-секрет — читать осознанно.

## Открытые вопросы

- [ ] **Блокер #1** (выше): целевой проект + наличие export `secret_key`.
- [ ] Датасет `amplitude` в `inv-project`, **US location** (join к `ai_analysis_us`). Подтвердить имя/naming
      (`src_/mart_` в отдельном датасете, НЕ в `ai_analysis_us`, который перестраивается warehouse-билдером).
- [ ] Загрузка: external-table над GCS + MERGE (их паттерн) vs classic load job. Рекоменд. — external-table + MERGE.
- [ ] Cron/lag: почасово при lag≈2h vs суточно. Рекоменд. — почасово, watermark-driven.
- [ ] Глубина backfill (retention Export API на нашем плане).
- [ ] Тянем один проект (web-prod) или все релевантные (iOS-admin тоже)? Зависит от того, куда BFF шлёт события.
- [ ] Bucket для raw-зоны (новый префикс в существующем bucket vs новый bucket).

## Реализовано (2026-07-09, срез iOS, `Tofu.AI.Backend`)

Форма — **сразу Hangfire-джоб** (`amplitude-export`, cron hourly), мульти-проектный реестр, iOS 213333 первым.
`dotnet build` + parser-тест зелёные. **Датасет — выделенный `amplitude_us`** (US; создан в prod через
`tofu-ai-backend` SA и в test через s.fedorov), таргетится конфигом `BigQueryOptions.AmplitudeDatasetId`. Изолирован
от snapshot-rebuilt warehouse; префиксы `src_`/`sys_`. (Ранее рассматривался co-locate в `ai_analysis_us` — отвергнут
в пользу изоляции/governance; дата-сет надо pre-create per-env, миграции его не создают.)

Файлы (repo-relative, `Tofu.AI.Backend`):
- Domain `src/Analyses/Analyses.Domain/Amplitude/`: `AmplitudeProject`, `AmplitudeExportEvent`, порты
  `IAmplitudeExportClient`/`IAmplitudeEventSink`/`IAmplitudeExportStateStore`.
- Application: `Amplitude/AmplitudeOptions.cs` (`Analyses:Amplitude`: Enabled/Cadence(daily 04:00)/LagHours/
  MaxCatchUpDays/Projects[]/EventTypes[]), `Jobs/AmplitudeExportJob.cs` (day-loop, per-project изоляция,
  oldest-first догон, стрим-фильтр по EventTypes со счётчиком, watermark после успешной загрузки).
- Infrastructure `Amplitude/`: `AmplitudeExportParser` (лениво `yield` NDJSON→curated; `$insert_id`/`accountId` подъём,
  JSON verbatim), `AmplitudeExportClient` (`StreamDayAsync : IAsyncEnumerable`, Basic auth, zip→gz→NDJSON, resilient
  HttpClient, 404=пусто), `BigQueryAmplitudeSink` (стрим → батч-load `UploadJsonAsync` по `AmplitudeBatchSize` →
  один `MERGE by insert_id` → drop staging), `BigQueryAmplitudeExportStateStore` (`sys_amplitude_export_state`).
  `BigQueryOptions`: `AmplitudeDatasetId=amplitude_us`, `AmplitudeBatchSize=50000`.
- DDL: `V006_CreateSrcAmplitudeEvents` (partition_expiration_days=90), `V007_CreateAmplitudeExportState`
  (`IBigQueryMigration`, таргет `amplitude_us` через `AmplitudeDatasetId`).
- DI: `AddAnalysesApplication`/`RegisterAnalysesRecurringJobs`/`AddAnalysesInfrastructure`/`Program.cs`/`appsettings.json`.
- Test: `tests/Analyses.UnitTests/Amplitude/AmplitudeExportParserTests`.

Дефолты: `Enabled=false` (opt-in), BQ `ProjectId=invoicesapp-project-test`, iOS 213333 с пустыми `ApiKey`/`SecretKey`.

**Export-креды (api_key+secret_key) уже есть в `/amplitude`-скилле** — header-файлы `.claude/skills/amplitude/auth*.txt`
хранят `Authorization: Basic base64(api_key:secret_key)`. Проверено: у всех 4 проектов обе части (32-hex каждая):
`auth.txt`=iOS prod 213333, `auth-ios-dev.txt`=622476, `auth-web-prod.txt`=586241, `auth-web-dev.txt`=586242.
Для **локальной** валидации креды берём отсюда (декод base64 → `key:secret`) в user-secrets — Secret Manager НЕ нужен.
Для **прод-деплоя** те же значения кладём в GSM `appsettings.Production.json` под `Analyses:Amplitude:Projects[]`.

✅ **BQ-сторона провалидирована вживую (2026-07-09, test-проект)** на реальном iOS-часе (2026-07-08T12):
- Фильтр required-событий: **646 из 11393** (Send invoice 387, Mark invoice 198, Send estimate 53, Payment received 7, Payment fee changed 1).
- **JSON-колонки грузятся load-job'ом из NDJSON** (топ-риск снят — фолбэк STRING+PARSE_JSON НЕ нужен); `JSON_VALUE(event_properties,'$.…')` извлекает `payment_provider=Stripe`, `application=mail_server`/share и т.п.
- 646 строк = 646 distinct `insert_id`; `account_id` (646/646) совпадает с `JSON_VALUE(...accountId)`.
- **`MERGE by insert_id` идемпотентен**: прогон 1 → +646, прогон 2 → +0.
- Нюанс: Amplitude группирует export по часу **приёма**, `event_time` = клиентское время → поздние офлайн-события падают в старые партиции (`event_time` 2026-06-17..2026-07-08 в одном часовом экспорте). Корректно; дубли между экспортами снимет MERGE.
- Артефакты валидации: scratch-датасет `invoicesapp-project-test.amplitude_validation` (таблицы `src_amplitude_events`, `merge_target`) + `gs://tofu-amplitude-export-test/src_amplitude/.../part-validation.json.gz`. Можно дропнуть.

Остаётся к проверке только на локальном прогоне сервиса: **живой Export API из C#-клиента** (сам Export API проверен curl'ом — работает) и C#-трансформация (покрыта unit-тестом).

## Порядок работ

0. [x] ~~Резолв блокера #1~~ — частично: backend-события подтверждены в iOS 213333 (export-креды есть). Полный
   маппинг web/productKey — позже (для web-проекта).
1. [x] Датасет **выделенный `amplitude_us`** (US, создан prod+test) + `src_amplitude_events` (partition/cluster/90д) + `sys_amplitude_export_state`; таргет через `AmplitudeDatasetId`.
2. [x] `AmplitudeExportClient` + `AmplitudeOptions`/реестр проектов.
3. [x] `AmplitudeExportJob` (Hangfire, cron, watermark, oldest-first cap) → GCS.
4. [x] Загрузка GCS→BQ: staging load + `MERGE by insert_id` в `src_amplitude_events`.
5. [x] **Живая валидация BQ-стороны** (2026-07-09): JSON-load / MERGE-идемпотентность / фильтр — все зелёные (см. выше). Остаётся e2e через C#-клиент на локальном прогоне.
6. [ ] Марты `mart_document_sends` / `mart_payment_received` (scheduled query/view, `source='backend'`).
7. [ ] Добавить web-проект 586241 в реестр (снять остаточный блокер по productKey-маршрутизации).
8. [x] **Правило первого прогона = backfill 90 дней** (commit 72b8db9, `BackfillDays`), см. секцию выше.
9. [ ] Обновить `Local.Docs/Backend/Storage/bigquery.md` + `ANALYTICS_EVENTS_FLOWS.md` (новый источник).

## Валидация на stage (2026-07-09)

Задеплоен `feature/FS-1352`@72b8db9 на staging (invoicesapp-project-test); GSM `tofu-ai-api-secret` v21
(`MaxCatchUpDays=90`, `BackfillDays=90`; SecretProviderClass монтирует `versions/latest`). Очищен watermark
622476 → триггер джобы через port-forward (`POST …/hangfire/recurring/trigger`, `jobs[]=amplitude-export` → 204).

- **Правило первого прогона подтверждено**: при пустом watermark джоба ушла назад к **2026-04-10** (а не на «вчера»),
  пошла oldest-first, загрузила **497 строк** за 18 «живых» дней окна (04-11..07-06), 38 типов событий, MERGE-дедуп,
  watermark припарковался на 07-08. `account_id` NULL на всех dev-событиях (ожидаемо для iOS-dev; prod 213333 несёт его).
- **Догон и идемпотентность подтверждены**: на ~80-м последовательном дне Export упёрся в таймаут (см. блокер) →
  watermark застрял на 06-28; повторный триггер продолжил с **06-29** (advance-only-after-success → ни один день не
  пропущен) и довёл до 07-08.

### HTTP-таймаут Amplitude-клиента был мал для дневных пуллов — ИСПРАВЛЕНО (commit e337133)

`AddStandardResilienceHandler` на Amplitude-HttpClient (`Analyses.Infrastructure/DependencyInjection.cs`) был
`AttemptTimeout=2m / TotalRequestTimeout=4m` (коммент «per hourly pull» устарел — клиент тянет **целый день**). На
stage дневной запрос при троттлинге завис >4м → `Polly.Timeout.TimeoutRejectedException` (поймано per-project
хендлером, без Hangfire-ретрая) → watermark застрял на 06-28. Поднято до **`AttemptTimeout=10m /
TotalRequestTimeout=20m`**, CircuitBreaker.SamplingDuration=20m (≥2×attempt), backstop HttpClient 21m, retry+backoff
(2) сохранён. Ещё не передеплоено на stage (под крутит 72b8db9; фикс — e337133). **Для прод-backfill:** держать
`MaxCatchUpDays` чанками (или ре-триггерить), чтобы ни один прогон не приближался к `DisableConcurrentExecution
(1800s=30m)` — крупный день теперь может занимать до 20м.
