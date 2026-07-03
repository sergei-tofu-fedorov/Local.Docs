# FS-1335 — Подсказка средней цены по региону при создании инвойса/эстимейта для новых пользователей

**Status:** planning
**Started:** 2026-07-01
**ClickUp:** https://app.clickup.com/t/FS-1335
**Affected repos:** `Tofu.AI.Backend` (ML: dataset job + training/retraining + serving), `Tofu.Invoices.Backend` and/or `Invoices.Backend` (consumer — вызов предсказания при создании инвойса/эстимейта; уточнить на /plan write)

## Goal

Глобальная задача: маленькая ML-модель, предсказывающая примерную цену по названию айтема + гео клиента. Данные собираем из своих инвойсов (названия айтемов + цены) и адресов клиентов. Использование — подсказка средней цены по региону при создании инвойса/эстимейта для новых пользователей. ML-модель (линейная регрессия, TensorFlow предпочтительно). Первая из трёх планируемых ML-моделей для подсказки цены. Нужно: подготовить датасет для обучения, инфраструктуру для запуска обучения/переобучения, подходы к валидации результатов. Проверить BQ на то, что уже есть.

## Revised decisions (2026-07-03)

- **Таргет — цена позиции (unit price), не тотал инвойса.** Вход: название айтема + geohash клиента → выход: примерная цена за единицу. Формулировка 2026-07-01 «вход: geohash + encoded items×qty + месяц → тотал инвойса» **устарела**.
- **Датасет — на уровне line item**, не инвойса: (название айтема, цена, адрес клиента→geohash, дата) из наших инвойсов.
- **Название айтема — свободный текст**, не нормализованный словарь SKU. Пользователи пишут названия как хотят → нужен этап нормализации/энкодинга текста. Схема multi-hot по словарю SKU из web-spike в этой части устарела и требует пересмотра (string-входы к тому же ломают конвертацию в Core ML — см. web-spike §1, Issue #1049).
- **Только US (решение 2026-07-03):** модель и датасет ограничены США — фильтр USD + US-адрес клиента; гео-фича = geohash/state по US-адресам. Остальные рынки — вне скоупа (возможный v2).
- **Generic-«вёдра» (решение 2026-07-03):** обучаемся на всех данных (generic-имена из обучения не удаляются); словарь `name→int` несёт data-driven `suppress`-флаг по разбросу (порог rel IQR ≈ 2.0 на per-name/name×state статистиках, пересчитывается dataset job'ом при каждом retraining; давит ~9.7% head-трафика); квантильные головы p25/p50/p75 (pinball loss) — как апгрейд v1, если влезет: точка при узком интервале, диапазон при среднем, молчим при широком. Детали и замеры — `research-data-audit.md`.
- **Обучение на prod-данных (решение 2026-07-03):** модель учится на реальных данных из `inv-project.ai_analysis_us` (test-warehouse с фейковыми данными не используется). Механизм: очищенная копия материализуется в `invoicesapp-project-test:fs1335_us.training_line_items` (см. `research-data-audit.md`, раздел «Рабочий датасет») — compute в test, данные prod; retraining пере-материализует её перед каждым обучением.
- Инфраструктурные решения 2026-07-01 (Vertex AI, on-device Core ML, дистрибуция через manifest + GCS/CDN, TF-линейная регрессия) остаются в силе.

## Confirmed decisions (2026-07-01)

- **Training / retraining infra:** Vertex AI (Custom Jobs / Pipelines), managed retraining + model registry. Обучение только против `invoicesapp-project-test`.
- **Inference path:** **on-device** — backend выдаёт малую модель как артефакт, инференс выполняется в iOS-приложении. Онлайн-endpoint НЕ используется. Препроцессинг фич (geohash, encoding позиций+qty, номер месяца) выполняется на устройстве → нужен контракт фич между backend-training и iOS.
- **Owner repo:** `Tofu.AI.Backend` владеет dataset job + training + производством/дистрибуцией артефакта модели (serving = раздача модели, не предсказаний).
- **Dataset source:** `ai_analysis_us.invoices` mirror в BQ; на /plan write — аудит доступных полей (total, geo/адрес→geohash, line items+qty, дата→месяц) и покрытия.
- **Model format:** **Core ML** (`.mlpackage`), конвертация TF→Core ML через `coremltools` как шаг пайплайна обучения. (Если позже понадобится Android — добавить TFLite из той же TF-модели.)
- **Distribution:** **runtime-загрузка** iOS'ом через backend/CDN — model version/manifest endpoint (артефакт в GCS/CDN). Обновление модели без релиза приложения (важно для retraining-цикла).
- **Framework:** линейная регрессия на TensorFlow (предпочтительно), экспорт → Core ML.
- **Scope note:** это первая из трёх планируемых ценовых моделей — инфра обучения + конвертация + дистрибуция должны быть переиспользуемыми.

**Новые открытые вопросы от on-device решения:**
- Контракт фич backend↔iOS: geohash-точность, схема encoding позиций+qty, кодирование месяца — iOS должен воспроизвести препроцессинг ровно как при обучении (или его встроить в модель).
- Дизайн model manifest/version endpoint: версия, url, чек-сумма, min-app-version, размер артефакта.
- Триггер и частота retraining → как публикуется новая версия и как iOS её подхватывает.

## Scope

- In scope: только US — датасет фильтруется по USD + US-адресу клиента; гео-фича строится по US-адресам (state/ZIP → geohash).
- Out of scope: все не-US рынки (UK, CA, PH, PK и длинный хвост валют из аудита) — кандидат на v2; мультивалютная нормализация цен.

## Affected repos

For each repo touched, list the area and (if multi-repo) its role.

- `Tofu.Invoices.Backend` (producer) — _e.g., new gRPC method, repository, domain change_
- `Invoices.Backend` (consumer / BFF) — _e.g., new controller endpoint that calls the new gRPC method_
- (others as needed)

**Cross-repo notes:**
- Producer / consumer order: _producer ships first; consumer references new contract after producer is deployed._
- Contract changes: _list any .proto or shared DTO changes; mark additive vs breaking._
- Mapper updates: _which `Mapping/Mapper.cs` arms need new entries._

## Plan

Numbered, repo-scoped steps that can be ticked off during implementation.

1. [ ] …
2. [ ] …

## API / DTO changes

<only if applicable — list new endpoints, request/response shapes, breaking changes>

## Breaking changes

<list anything that could break consumers (other repos, mobile clients, third-party API users) — proto field renumbering, removed/renamed REST endpoints, narrowed types, new required fields, dropped DB columns, changed event payloads, etc. If purely additive, write `None — additive only` so the explicit check is recorded. The `/feature review` op will re-audit this against the actual diff.>

## Data / migration

<only if applicable — new collections, indexes, migrations>

## Open questions

- [ ] Энкодинг свободнотекстового названия айтема для крошечной линейной on-device модели: нормализация (lower/trim/языки?) + словарь по частотным названиям с int-индексами? hashing trick? что делать с названиями вне словаря (fallback на средний по geohash?). Схему multi-hot по SKU из web-spike пересмотреть.
- [ ] Определение unit price в данных: `amount/qty` vs явное поле цены за единицу; фильтрация выбросов, нулевых/отрицательных цен, скидок.
- [ ] Валюта: цены в инвойсах в разных валютах — нормализовать к одной? фильтровать по валюте/стране? (связано с geohash-регионом).
- [ ] Остаются ли qty и номер месяца фичами при таргете «цена позиции» (сезонность цены услуги — возможно; qty — скорее нет, но проверить скидку за объём).
- [ ] Актуально ли предсказывать по нескольким позициям сразу или строго одна позиция за вызов (влияет на форму входа модели).

## Test plan

- Unit tests:
- Integration tests:
- Manual verification:
