# FS-1335 — Протокол конвертации в Core ML (по гайду coremltools, 2026-07-05)

Разбор требований [официального гайда TF2→Core ML](https://apple.github.io/coremltools/docs-guides/source/tensorflow-2.html) применительно к нашим моделям (запрос iOS-разработчика). Пайплайн из overview.md (TF → coremltools → `.mlpackage` → manifest/GCS) подтверждён; ниже — что это диктует нашим артефактам.

## Правила для train-скриптов

1. **Конвертация — в конце train-скрипта, из живого `tf.keras.Model`.** Наши `.keras`-чекпоинты с Lambda-слоями не десериализуются (проверено дважды: `load_model` падает, лечится только rebuild+`load_weights`). Гайд рекомендует передавать объект модели → `ct.convert(model, convert_to="mlprogram")` ставим сразу после обучения, пока модель в памяти. Fallback — экспортированный `saved_model/`.
2. **В графе — только Embedding + арифметика.** Наши Lambda (cell_id = mul+add, sin/cos сезонности) конвертируются, т.к. трассируются в простые TF-опы. Урок v1c: `tf.gather`-LUT в Lambda ломает даже Keras-predict — любые lookup'ы (например, регион из штата) передавать явным входом, не считать в графе.
3. **Входы описывать явно**: `ct.TensorType(shape=(1,), dtype=np.int32)` для `name_id`/`state_id`, float32 для `month`. Имена входов = контракт, который iOS видит в Xcode.
4. **FP16 по умолчанию** у ML Program. Модель живёт в log-пространстве и завершается `exp()` → парити-тест сравнивает **цены после exp**, не логиты; при расхождении — `compute_precision=ct.precision.FLOAT32`.
5. **CQR-поправка** (константа Q) — вписать в bias квантильных голов перед конвертацией или отдать полем manifest'а (решить при сборке финального графа).

## Что НЕ едет в .mlpackage (остаётся в Swift)

- нормализация имени (lower/trim);
- словарный lookup `имя → name_id` (vocab.json);
- potion-токенизация (субтокены → id) и mean-pooling для OOV-ветки;
- kNN-поиск соседей (cosine top-k по таблице векторов — Accelerate/vDSP);
- маршрутизация каскада (словарь → v1b / близкий сосед → kNN / иначе → v3-голова / suppress → молчание).

Следствие: `vocab.json` и `feature_spec.json` — **бинарный контракт**, а не справка. Парити-тест «Swift-препроцессинг == Python-препроцессинг бит-в-бит» — блокирующий шаг перед релизом (запланирован на macOS).

## Упаковка каскада

Не одна модель, а набор + роутер в Swift:

| Артефакт | Содержимое |
|---|---|
| `v1b.mlpackage` | словарная ветка (+ квантильные головы) |
| `oov_head.mlpackage` | голова v3 (256 → log-price) |
| potion-таблица | данные (~30 MB; или 0, если спайк NLContextualEmbedding подтвердится) |
| `vocab.json`, `feature_spec.json` | контракты препроцессинга + suppress-флаги + пороги роутинга (sim ≥ ~0.7) |
| manifest | версии, url, чек-суммы (по overview.md) |

## Окружение и риски

- Конвертация работает на Linux (**подтверждено в WSL2 2026-07-06**); проверка предсказаний `.mlpackage` — только macOS/Xcode (отдано iOS-разработчику). На Linux coremltools ругается `Failed to load libcoremlpython` — это отсутствие predict-рантайма, конверту не мешает.
- **Риск версий — снят (2026-07-06)**: смоук-конверт v1b прошёл на паре **`tensorflow-cpu==2.21.0` + `coremltools==9.0`** (официальная матрица заявляет «tested up to TF 2.12», предупреждение оказалось безобидным для нашего графа из 67 ops). Пин зафиксирован для конверт-окружения/контейнера.

## Смоук-конверт v1b — сделан (2026-07-06, WSL2)

`convert_v1b.py`: `artifacts/saved_model` → `artifacts/v1b.mlpackage` (**0.61 MB** — FP16, даже меньше оценки). Уроки для протокола:

1. **SavedModel от Keras 3 несёт две concrete functions** (`serve`, `serving_default`) → `ct.convert(path)` падает с `Only a single concrete function is supported`; передавать явно: `ct.convert([sm.signatures["serving_default"]])`.
2. **SavedModel-маршрут даёт грязный контракт**: выход называется `Identity`, batch-размерность становится flexible range 1..2 (предупреждение конвертера). Подтверждает правило №1/№3 протокола: в пайплайне конвертировать **живую модель с явными `ct.TensorType`** (чистые имена входов/выходов, фиксированные shape); SavedModel-путь — рабочий fallback для смоуков.
3. Типы входов после конверта: `name_id`/`state_id` INT32, `month` FLOAT16 (FP16-дефолт) — iOS это увидит в Xcode; для месяца ок, точность не страдает.

## Спайк NLContextualEmbedding — закрыт, вердикт «не для v1» (2026-07-06)

Идея: заменить potion-таблицу (~15 MB в дистрибуции) встроенными iOS-эмбеддингами [`NLContextualEmbedding`](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding) (iOS 17+, 512-dim, Latin-модель 20 языков, ассет <100 MB управляется ОС). Desk-research выявил три блокера:

1. **Обучение головы — только на Apple-платформах**: эмбеддинг 3.7M строк нельзя посчитать в Vertex/Linux → обязательная Mac-стадия в training-пайплайне, ломает автоматизацию из `research-vertex-automation.md`.
2. **Ревизии не пинуются нами**: ассет обновляется с ОС (`revision` — read-only свойство); голова, обученная на ревизии N, может встретить векторы ревизии N+1 → нужна матрица совместимости в manifest. У potion версия принадлежит нам.
3. **Живой баг**: [`load()` падает на симуляторе iOS 26](https://developer.apple.com/forums/thread/799951) (permission denied / «model requires compilation», `hasAvailableAssets=false`) с 09.2025, фикса нет на 05.2026 (FB22699606); плюс отдельная загрузка ассета на устройство как failure-mode.

**Решение: остаёмся на potion.** Пересмотр — если Apple Core AI (WWDC26) даст закрепляемые ревизии или 15 MB станет проблемой; тогда на Mac проверить качество на инвойсной лексике и train/device-парити.

## Чеклист первого конверта

- [x] Пин версий: **`tensorflow-cpu==2.21.0` + `coremltools==9.0`** — переобучение не понадобилось, текущий TF совместим (смоук 2026-07-06, WSL2 venv `~/fs1335-convert`).
- [x] Smoke на Linux: конверт без ошибок, 0.61 MB, входы/типы как ожидалось (см. секцию выше).
- [ ] `ct.convert` в конце `train.py` (v1b) с явными TensorType-входами → чистый `v1b.mlpackage` (уйдёт в `train_all.py` пайплайна).
- [ ] macOS: предсказания `.mlpackage` vs Python на 1k случайных входов — расхождение цен < 0.5% (иначе FLOAT32).
- [ ] Swift-препроцессинг парити-тест по vocab.json/feature_spec.json.
