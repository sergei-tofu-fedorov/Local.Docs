# FS-1335 — Автоматизация retraining через Vertex AI (схема, 2026-07-06)

Модель обучается секунды-минуты на CPU → Vertex AI нужен не ради мощности, а ради **воспроизводимости, расписания и артефакт-дисциплины**.

> **Ревизия 2026-07-06: весь пайплайн живёт в prod (`inv-project`).** Это осознанно отменяет решение overview.md «Vertex-джобы в `invoicesapp-project-test`»: prod-only убирает всю кросс-проектную механику (три IAM-гранта, перенос данных между проектами) ценой копеечного compute в prod (~10 мин CPU на эпизод — это не benchmark-workload, дух правила «тяжёлое только в test» не нарушен). Test-датасет `ml_training_us` остаётся песочницей прототипа.

## Пайплайн (всё в `inv-project`, всё под SA `tofu-ai-backend@inv-project`)

```
Hangfire job (Tofu.AI.Backend, prod)    ← триггер: расписание или ручной запуск
  │ 1. re-materialize snapshot: ai_analysis_us → ml_training_us.src_price_line_items
  │    (+ dim_price_names с пересчётом suppress-флагов, mart_price_rows_vocab, mart_price_rows_text)
  │ 2. BQ extract → gs://tofu-ml-models/datasets/price-v1/<run>/ (parquet)
  │ 3. submit Vertex AI CustomJob (inv-project)
  ▼
Vertex CustomJob (prebuilt TF-CPU контейнер, n1-standard-8)
  │ 4. train: v1b + квантильные головы + v3-голова (скрипты прототипа почти as-is)
  │ 5. CQR-калибровка на калибровочном фолде (research-prototype.md, раунд 3)
  │ 6. gate: регрессионные тесты — holdout-метрики + golden-suite
  │    (validate_external / validate_geo / oov_probes: не хуже прошлой версии − допуск)
  │ 7. ct.convert → .mlpackage (Linux-конвертация валидна — research-coreml.md)
  │ 8. upload: gs://tofu-ml-models/models/price-v1/<version>/ (артефакты + метрики + контракты)
  ▼
manifest: staged-запись новой версии; публикация — РУЧНАЯ (решение v1)
```

## Ключевые решения и почему

- **Prod-only, один проект и один SA**: у `tofu-ai-backend@inv-project` уже есть всё нужное project-level (BQ `dataEditor`+`jobUser`, `storage.objectAdmin`, `aiplatform.user` — см. пререквизиты); данные не покидают prod-периметр до публикации артефактов. Бонус iOS-дистрибуции: бакет в одном проекте с BFF.
- **Стоимость эпизода — центы**: CPU-машина ~10 минут + BQ-скан снапшота (~2 GB из партиционированной mart-таблицы).
- **Триггер — Hangfire, не Cloud Scheduler**: у Tofu.AI.Backend уже есть паттерн «Hangfire job → BQ» для warehouse; retraining — ещё один джоб рядом, без нового вида инфраструктуры.
- **Один CustomJob, не Vertex Pipelines (KFP)**: пайплайны оправданы для многочасовых DAG'ов; наши шаги — один скрипт-контейнер, на порядок проще в поддержке.
- **Golden-suite как автоматический гейт** — джоб сам отклоняет модель, у которой просели holdout-метрики или калибровка против рынка (golden-диапазоны едут в контейнер как данные), и оставляет прошлую версию в manifest.
- **Версионирование**: артефакты иммутабельны (`<version>` = дата+git-sha), manifest указывает на активную версию; откат = переключение manifest.
- **Контейнер читает parquet из GCS, не BQ напрямую** — поэтому `bigquery.readSessionUser` не нужен; заодно вход обучения зафиксирован как файл (воспроизводимость).

## Формат артефактов в бакете

```
gs://tofu-ml-models/                      (inv-project, US, uniform access)
├── datasets/price-v1/<run>/              ← parquet-вход обучения (шаг 2)
└── models/price-v1/
    ├── manifest.json                     ← единственный мутируемый файл (стабильный путь)
    └── 2026-07-20_a1b2c3d/               ← иммутабельная версия: дата + git-sha
        ├── device/                       ← ВСЁ, что качает iOS (готовое; ревизия 2026-07-06)
        │   ├── v1b.mlpackage.zip         ← словарная ветка + квантильные головы
        │   ├── oov_head.mlpackage.zip    ← голова v3 (256 → log-price)
        │   ├── potion_table.f16.bin      ← таблица векторов: плоский LE float16, ~15 MB
        │   ├── potion_tokenizer.json     ← словарь субтокенов + правила токенизации (Swift)
        │   ├── vocab.json                ← имя → id, suppress, медианы; штаты
        │   └── feature_spec.json         ← нормализация, роутинг-пороги (sim ≥ 0.7), CQR-Q
        ├── device-bundle.zip             ← тот же device-набор одним блобом (~16 MB, один sha):
        │                                    простой клиент качает только его; per-file вариант
        │                                    остаётся для будущей оптимизации (potion-таблица
        │                                    меж версиями почти не меняется)
        ├── metrics.json                  ← holdout + golden-gate (для человека при publish)
        ├── oov_head.npz (+spec)          ← ops: скоринг головы вне устройства
        └── training/                     ← ops: веса для воспроизводимости
```

Manifest.staged несёт три списка: `deviceBundle` (один объект), `deviceArtifacts` (per-file с sha256), полный `artifacts`.

- `.mlpackage` — bundle-директория → дистрибутируется зипом (один blob, один sha256); iOS распаковывает и компилирует MLModel локально.
- Potion-таблица — сырой бинарь, не Core ML-модель: её читают обе ветки (kNN через Accelerate и вход v3-головы). Спайк NLContextualEmbedding (замена таблицы встроенными iOS-эмбеддингами) закрыт 2026-07-06 с вердиктом «не для v1» — в т.ч. потому, что он ломает этот Linux-пайплайн Mac-стадией (см. `research-coreml.md`).
- `manifest.json` — поля по overview.md: активная version, url+sha256+size каждого артефакта, minAppVersion, дата обучения. Publish = переписать manifest, откат = вернуть прошлую version.
- Клиент качает ~16–17 MB на версию (с Apple-эмбеддингами — <2 MB); `metrics.json` и `training/` iOS не скачивает.

## Что автоматизируется НЕ полностью

1. **Публикация** — по решению v1 retraining ручной: джоб готовит staged-версию, человек смотрит metrics-diff и жмёт publish (переключение manifest).
2. **macOS-парити** `.mlpackage` — Linux конвертирует, проверка предсказаний только на macOS. Кандидат на автоматизацию: GitHub Actions macos-runner с parity-тестом по staged-версии.
3. **Обновление golden-диапазонов** — раз в год руками (гайды переиздаются ежегодно).

## Пререквизиты

- [x] Имя GCS-бакета: **`gs://tofu-ml-models`**. Создан 2026-07-06 в test, **2026-07-06 же перенесён в prod `inv-project`** (имя глобально уникально → test-бакет удалён, одноимённый создан в prod, US, uniform access; архив v0 перезалит).
- [x] Имя BQ-датасета: **`ml_training_us`** (переименован из per-тикетного `fs1335_us` 2026-07-06; один датасет на все training-задачи). Имена таблиц = слой-префикс warehouse-конвенции (`src_/dim_/mart_/sys_`, как в `ai_analysis_us`) + префикс задачи: `src_price_line_items`, `dim_price_names`, `mart_price_rows_vocab`, `mart_price_rows_text`. Рабочий экземпляр пайплайна — **prod `inv-project:ml_training_us`** (создан пустым 2026-07-06); test-двойник — песочница прототипа. Новые ML-задачи добавляют свой префикс задачи, без новых датасетов и грантов.
- [x] **IAM-грант для actAs** (Vertex требует `actAs` на SA CustomJob'а даже от него самого): выдан админом 2026-07-06 как `roles/iam.serviceAccountUser` **на уровне проекта** `inv-project` (шире, чем нужно: даёт actAs на любой SA проекта; least-privilege вариант — перевесить биндинг на сам SA `tofu-ai-backend@inv-project` и снять project-level). Всё остальное у prod-SA уже было (аудит 2026-07-06): BQ `dataEditor`+`jobUser`, `storage.objectAdmin`, `aiplatform.user` — project-level. Vertex service agent провиженится автоматически при первом CustomJob.
- [x] Пин версий контейнера: **`tensorflow-cpu==2.21.0` + `coremltools==9.0`** — подтверждён смоук-конвертом v1b в WSL2 (2026-07-06, детали и гочи — research-coreml.md). Официальное «tested up to TF 2.12» для нашего графа не блокер.

## Первый архив (v0, 2026-07-06)

Собран локально из артефактов прототипа (`assemble_archive.py`) и загружен: **`gs://tofu-ml-models/models/price-v1/2026-07-06_47c5b24/`** (13 файлов, 43.5 MB; potion-таблица 29,528×256 f16 = 15.1 MB) + staged-manifest на стабильном пути. Статус в manifest: `staged-no-mlpackage` (конвертация — на WSL2-шаге), `activeVersion: null` — ничего не опубликовано. `feature_spec.json` впервые собран полным: нормализация, штаты, спека potion-таблицы, роутинг-пороги каскада (sim ≥ 0.7, kNN k=10/min 0.35), CQR-поправка (q_log=+0.1948). Обучен на снапшоте prod-данных от 2026-07-03, материализованном тогда в test-датасете (свежая материализация не гонялась — для v0-архива не критично, зафиксировано в manifest.trainedOn).

Постоянные джобы (Hangfire + датасет-рутины) — шаги 2–3 плана имплементации ниже; ветка для них — `feature/FS-1335` в Tofu.AI.Backend.

## План имплементации (когда дойдём)

1. [x] Упаковать скрипты прототипа в один `train_all.py` + Dockerfile — **сделано 2026-07-06**: пакет `ml/price_model/` в Tofu.AI.Backend (`feature/FS-1335`). Продакшн-граф v1b впервые получил квантильные головы: shown p50 MdAPE 0.490 (= точечному v1b), CQR coverage 51.2% на shown (Q=+0.1035; Mondrian, похоже, не нужен). GATE PASS всеми 6 проверками (external 90.2%, geo 4/4, kNN-пробы 94.3%). WSL-прогон с конвертацией: `v1b.mlpackage.zip` 0.59 MB + `oov_head.mlpackage.zip` 35 KB из живых моделей с явными TensorType; архив 10 файлов / 20.6 MB, статус staged. iOS-набор итого ~16.2 MB. Новая Keras-гоча: pandas-Series во входах predict() отравляет tf.function-кэш → numpy-фиды + eager-вызовы в гейте.
2. [ ] Датасет-джоб в Tofu.AI.Backend (SQL-рутины материализации по паттерну warehouse, целевой датасет `ml_training_us` — prod).
3. [ ] Hangfire-джоб submit'а CustomJob + мониторинг статуса.
4. [ ] Staged-manifest и ручная публикация (endpoint/CLI).
5. [ ] (позже) macos-runner parity в CI.
