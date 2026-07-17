# FS-1335 — Web Spike: on-device Core ML модель подсказки цены (обучение на Vertex AI)

Исследование фундамента для FS-1335: обучить малую **линейную регрессию** (TensorFlow) на Vertex AI на данных из BigQuery, сконвертировать её в **Core ML** и раздавать iOS-приложению для **on-device** инференса (вход: geohash + items×qty + номер месяца → тотал инвойса). Ниже — что говорят авторитетные источники по пяти ключевым развилкам: конвертация TF→Core ML (со встраиванием препроцессинга), инфраструктура обучения/переобучения на Vertex, feature engineering, дистрибуция модели на устройство и валидация регрессии.

> **Оговорки по свежести.** Google Cloud docs теперь отдаются как JS-SPA (`docs.cloud.google.com`, ребрендинг «Gemini Enterprise Agent Platform») — часть Vertex-фактов взята из search-excerpt'ов, не из полного тела страницы (помечено ниже). coremltools Issue #1049 — 2021 г. (TF `experimental.preprocessing`), поведение конвертации категориальных слоёв надо перепроверять на пиннутых версиях. Vertex-блоги — 2022–2023 гг. Перед реализацией сверить сигнатуры API в живой документации.

## Questions

1. Конвертация TF-линейной-регрессии → Core ML через `coremltools`; встраивание препроцессинга в граф модели (против train/serve skew).
2. Обучение/переобучение TF-модели на Vertex AI; артефакт, Model Registry, расписание retraining, чтение данных из BigQuery.
3. Feature engineering входов: geohash, items+quantity, номер месяца — для **линейной** модели.
4. Дистрибуция on-device модели: manifest/version endpoint, раздача через GCS/CDN, ATS, offline-first.
5. Валидация регрессии: метрики, временной бэктест, срезы по регионам, train/serve skew и **паритет Core ML ↔ TF**.

## Sources

**Core ML / coremltools**
- [TensorFlow 2 Workflow — coremltools](https://apple.github.io/coremltools/docs-guides/source/tensorflow-2.html) — конвертация TF2/Keras через `ct.convert`.
- [Convert Models to ML Programs — coremltools](https://apple.github.io/coremltools/docs-guides/source/convert-to-ml-program.html) — ML Program vs neural network, deployment targets, дефолт в 7.0+.
- [Unified conversion API — coremltools 8.1](https://apple.github.io/coremltools/source/coremltools.converters.convert.html) — полная сигнатура `ct.convert`, `TensorType`, именование.
- [Quantization Overview — coremltools](https://apple.github.io/coremltools/docs-guides/source/opt-quantization-overview.html) — сжатие весов (8/4-бит, палетизация).
- [coremltools Issue #1049 — string input / StringLookup](https://github.com/apple/coremltools/issues/1049) — поломка конвертации строковых категориальных слоёв.
- [Working with preprocessing layers — TensorFlow](https://www.tensorflow.org/guide/keras/preprocessing_layers) — встраивание препроцессинга, `adapt()`, снижение train/serve skew.
- [Model Prediction / TF1 Workflow — coremltools](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html) — верификация паритета предсказаний с допуском.

**Vertex AI**
- [Choose a serverless training method](https://cloud.google.com/vertex-ai/docs/training/custom-training-methods), [Create training pipelines](https://cloud.google.com/vertex-ai/docs/training/create-training-pipeline), [Prebuilt containers](https://cloud.google.com/vertex-ai/docs/training/pre-built-containers) — CustomJob vs pipeline, prebuilt TF-контейнер, `BASE_OUTPUT_DIRECTORY/model/`.
- [Vertex AI Model Registry (blog, 2022-10-08)](https://cloud.google.com/blog/products/ai-machine-learning/vertex-ai-model-registry) + [Model versioning](https://cloud.google.com/vertex-ai/docs/model-registry/versioning) — версионирование, `PARENT_MODEL`, default alias.
- [Schedule a pipeline run](https://cloud.google.com/vertex-ai/docs/pipelines/schedule-pipeline-run), [Continuous training tutorial](https://cloud.google.com/vertex-ai/docs/pipelines/continuous-training-tutorial), [Best practices for Vertex Pipelines (blog)](https://cloud.google.com/blog/topics/developers-practitioners/best-practices-managing-vertex-pipelines-code/) — `create_schedule(cron=...)`, Cloud Scheduler+Pub/Sub.
- [Reading & storing data for custom training (blog, 2023-01-12)](https://cloud.google.com/blog/topics/developers-practitioners/reading-and-storing-data-custom-model-training-vertex-ai), [Using managed datasets](https://cloud.google.com/vertex-ai/docs/training/using-managed-datasets) — BigQuery Storage API → `tf.data`.

**Feature engineering**
- [Geohash — Wikipedia](https://en.wikipedia.org/wiki/Geohash) — префикс=близость, иерархия, precision-vs-length.
- [TargetEncoder — scikit-learn](https://scikit-learn.org/stable/modules/generated/sklearn.preprocessing.TargetEncoder.html) — таргет-энкодинг high-cardinality, fallback на `target_mean_`, smoothing, cross-fitting.
- [One-hot encoding — Google ML Crash Course](https://developers.google.com/machine-learning/crash-course/categorical-data/one-hot-encoding) — multi-hot, sparse, вес на элемент.
- [CyclicalFeatures — feature-engine](https://feature-engine.trainindata.com/en/latest/user_guide/creation/CyclicalFeatures.html) + [Cyclical feature engineering — scikit-learn](https://scikit-learn.org/stable/auto_examples/applications/plot_cyclical_feature_engineering.html) — sin/cos кодирование месяца.
- [High-cardinality categoricals (arXiv 2501.05646, 2025-01-10)](https://arxiv.org/html/2501.05646v1) + [Regularized target encoding (Springer, 2022)](https://link.springer.com/article/10.1007/s00180-022-01207-6) — недостатки one-hot, регуляризация.

**On-device дистрибуция**
- [MLModelCollection — Apple (DEPRECATED iOS 17.4)](https://developer.apple.com/documentation/coreml/mlmodelcollection) — устаревший путь Core ML Model Deployment.
- [Downloading and Compiling a Model on the User's Device — Apple](https://developer.apple.com/documentation/coreml/downloading-and-compiling-a-model-on-the-user-s-device) — канонический OTA-паттерн (URLSession → compile → load).
- [MLModel.compileModel(at:) — Apple](https://developer.apple.com/documentation/coreml/mlmodel/compilemodel(at:)) — iOS 16+, sync-вариант устарел.
- [Background Assets — Apple](https://developer.apple.com/documentation/backgroundassets) — рекомендованная замена для управляемой фоновой загрузки.
- [GCS object metadata](https://docs.cloud.google.com/storage/docs/metadata), [Signed URLs](https://docs.cloud.google.com/storage/docs/access-control/signed-urls) — Cache-Control, CRC32C/MD5/ETag, TTL ≤7 дней.
- [Preventing Insecure Network Connections (ATS) — Apple](https://developer.apple.com/documentation/security/preventing-insecure-network-connections) — HTTPS/TLS 1.2+ обязателен.

**Валидация**
- scikit-learn метрики: [MAE](https://scikit-learn.org/stable/modules/generated/sklearn.metrics.mean_absolute_error.html), [RMSE](https://scikit-learn.org/stable/modules/generated/sklearn.metrics.root_mean_squared_error.html), [R2](https://scikit-learn.org/stable/modules/generated/sklearn.metrics.r2_score.html), [MAPE](https://scikit-learn.org/stable/modules/generated/sklearn.metrics.mean_absolute_percentage_error.html), [pinball loss](https://scikit-learn.org/stable/modules/generated/sklearn.metrics.mean_pinball_loss.html), [TimeSeriesSplit](https://scikit-learn.org/stable/modules/cross_validation.html).
- [Rules of ML — Google](https://developers.google.com/machine-learning/guides/rules-of-ml), [Monitoring](https://developers.google.com/machine-learning/crash-course/production-ml-systems/monitoring), [Fairness](https://developers.google.com/machine-learning/crash-course/fairness/evaluating-for-bias), [High-quality ML solutions](https://docs.cloud.google.com/architecture/guidelines-for-developing-high-quality-ml-solutions) — train/serve skew, срезы.
- [statworx — What the MAPE is FALSELY blamed for (2019-08-16)](https://www.statworx.com/en/content-hub/blog/what-the-mape-is-falsely-blamed-for-its-true-weaknesses-and-better-alternatives).

## Findings

### 1. TF → Core ML + встраивание препроцессинга в граф

Конвертация — через unified `ct.convert`; для TF проще всего передать объект `tf.keras.Model`:

```python
import coremltools as ct
mlmodel = ct.convert(tf_model, convert_to="mlprogram")
```

Формат по умолчанию с coremltools 7.0+ — **ML Program** (`.mlpackage`), таргет iOS15/macOS12, веса **float16**:

> «In Core ML Tools 7.0 and newer versions, the `convert()` method produces an `mlprogram` by default.»
> — [Convert Models to ML Programs](https://apple.github.io/coremltools/docs-guides/source/convert-to-ml-program.html)

> «The `minimum_deployment_target` value can override default behavior — for instance, specifying `minimum_deployment_target=target.iOS14` produces a neural network instead.»
> — [coremltools API Reference 8.1](https://apple.github.io/coremltools/source/coremltools.converters.convert.html)

**Главное — препроцессинг встраивается в граф модели**, что убирает train/serve skew (iOS не воспроизводит нормализацию/энкодинг вручную). Официальная формулировка — со стороны TF/Keras:

> «The key benefit to doing this is that it makes your model portable and it helps reduce the training/serving skew. … other people can load and use your model without having to be aware of how each feature is expected to be encoded & normalized.»
> — [TensorFlow — preprocessing layers](https://www.tensorflow.org/guide/keras/preprocessing_layers)

Механизм: собрать **одну** Keras-модель = препроцессинг-слои + линейная голова, затем конвертировать её целиком:

```python
normalizer = layers.Normalization(); normalizer.adapt(x_train)  # mean/std → константы графа
inputs  = keras.Input(shape=input_shape)
x       = normalizer(inputs)
outputs = layers.Dense(1)(x)                                     # линейная голова (регрессия)
model   = keras.Model(inputs, outputs)
```

**Резкий разрыв в том, что переживает конвертацию:**

| Класс препроцессинга | Конвертируется? | Основание |
|---|---|---|
| Numeric `Normalization` (mean/std), scaling, `Concatenate` | **Да** — сводится к арифметике/core-ops | [preprocessing layers](https://www.tensorflow.org/guide/keras/preprocessing_layers) + аналогия с image scale/bias |
| **String** `StringLookup` + `CategoryEncoding`/`Hashing` | **Нет / ломается** | Issue #1049 |
| Integer-indexed `IntegerLookup`/`CategoryEncoding`/`Hashing` | Вероятно да (нет string-`resource`), но **не проверено** | вывод из #1049 |

> «Cannot convert a Tensor of dtype resource to a NumPy array.»
> — [coremltools Issue #1049](https://github.com/apple/coremltools/issues/1049) (строковый lookup-table — это `resource`-тензор, ломается при freeze)

Escape hatch для неконвертируемых op — MIL composite operator:

> «As a workaround, you may want to write a translation function from the missing op to the existing MIL ops.»
> — [coremltools FAQs](https://apple.github.io/coremltools/docs-guides/source/faqs.html)

**Размер и типизация:** линейная модель — килобайты (веса ≈ N+1 float); float16 по умолчанию уже 2× экономии, при желании — 8-бит квантизация («reduces the disk size to one fourth of the float 32 model»), но для крошечной модели доминирует overhead `.mlpackage`. Числовые входы отдаются как `TensorType` → MLMultiArray; **имена Keras-входов/выходов становятся Swift-facing API** — задавать явно. Предпочтительны **именованные пофичевые входы**, а не один упакованный вектор (упакованный вектор = скрытый контракт порядка колонок = риск skew).

### 2. Vertex AI: обучение, артефакт, retraining, BigQuery

**Примитив обучения** — `CustomJob` в **prebuilt TensorFlow-контейнере** (тренировочный код пакуется как Python-пакет); для CPU-модели этого достаточно и дёшево (serverless, без idle-кластера). Важно не путать два продукта:

> «A training pipeline orchestrates serverless training jobs … accepts an input Vertex AI managed dataset … and returns the model after the training job completes.»
> — [Create training pipelines](https://cloud.google.com/vertex-ai/docs/training/create-training-pipeline) *[search-excerpt]*

«Training pipeline» (ресурс `TrainingPipeline`: managed-dataset-in → registered-model-out) ≠ «Vertex AI **Pipelines**» (KFP/TFX DAG — именно им делают recurring retraining).

**Артефакт** экспортируется в `AIP_MODEL_DIR` (= `BASE_OUTPUT_DIRECTORY/model/` в GCS):

> «Vertex AI expects to find model artifacts in `BASE_OUTPUT_DIRECTORY/model/`.»
> — [Create training pipelines](https://cloud.google.com/vertex-ai/docs/training/create-training-pipeline) *[search-excerpt]*

**Model Registry** версионирует; `PARENT_MODEL` при upload делает retrain новой версией под одной моделью:

> «The Vertex AI Model Registry is the central repository where you can manage the lifecycle of all your ML models. … you can organize, label, evaluate, and version models. … the first version automatically gets assigned the default alias.»
> — [Model Registry blog (2022-10-08)](https://cloud.google.com/blog/products/ai-machine-learning/vertex-ai-model-registry)

**Retraining по расписанию** — нативный scheduler:

```python
pipeline_job.create_schedule(display_name="...", cron="TZ=CRON",
    max_concurrent_run_count=..., max_run_count=...)
```
> «You can schedule one-time or recurring pipeline runs in Vertex AI using the scheduler API, which lets you implement continuous training.»
> — [Schedule a pipeline run](https://cloud.google.com/vertex-ai/docs/pipelines/schedule-pipeline-run) *[search-excerpt]*

Альтернатива — на приход новых данных: Cloud Scheduler+Pub/Sub или Cloud Function на изменение BigQuery/GCS («Both can be triggered using a fixed schedule (Cloud Scheduler + Pub/Sub), or triggered from a Pub/Sub event» — [Best practices blog](https://cloud.google.com/blog/topics/developers-practitioners/best-practices-managing-vertex-pipelines-code/)).

**Чтение BigQuery** — напрямую через BigQuery Storage API → `tf.data`, без промежуточного экспорта:

> «If you're a TensorFlow user, you can use the BigQuery Connector to read training data. The BigQuery connector relies on the BigQuery Storage API … hides the complexity associated with decoding serialized data rows into Tensors.»
> — [Reading & storing data blog (2023-01-12)](https://cloud.google.com/blog/topics/developers-practitioners/reading-and-storing-data-custom-model-training-vertex-ai)

**IAM (least privilege) для training SA:** `aiplatform.user`, write на training-бакет (scope, не полный `storage.admin`), `roles/bigquery.readsessionuser` + dataViewer на датасет. Регион обучения, GCS-бакет и BQ-датасет — колокейтить. **Vertex не умеет Core ML нативно** — конвертация TF→Core ML это отдельный пост-training шаг (в идеале — шаг того же пайплайна после регистрации модели).

### 3. Feature engineering (для линейной модели)

Домен почти буквально линеен: `total ≈ Σ(price_sku × qty_sku) + региональный эффект + сезонный эффект`.

**Items+quantity → quantity-weighted multi-hot** над словарём SKU (sparse, фикс-ширина = |SKU|). Линейная модель учит один вес на SKU = выученная цена за единицу:

> «In a variant known as multi-hot encoding, multiple values can be 1.0. … The model learns a separate weight for each element of the feature vector.»
> — [Google — one-hot encoding](https://developers.google.com/machine-learning/crash-course/categorical-data/one-hot-encoding)

Embeddings — только запасной вариант при очень высокой кардинальности («When the number of categories is high, one-hot encoding is usually a bad choice»), но линейная модель не потребляет raw embeddings так чисто, как multi-hot.

**Месяц → sin/cos** (обе функции обязательны):

> «var_sin = sin(variable * (2. * pi / max_value))» / «Adding the cosine function … breaks the symmetry and assigns a unique codification.»
> — [feature-engine CyclicalFeatures](https://feature-engine.trainindata.com/en/latest/user_guide/creation/CyclicalFeatures.html)

Причина — линейная модель на raw-целом месяце может дать только монотонный наклон и ставит декабрь далеко от января; sin/cos даёт гладкий wrap-around сезонный базис. (scikit-learn: деревья «can learn a non-monotonic relationship … This is not the case for linear regression models.»)

**Geohash → target-encoding** (кардинальность огромна, one-hot взрывается):

> «Categories that are not seen during fit are encoded with the target mean, i.e. `target_mean_`.» / smoothing: «A larger `smooth` value will put more weight on the global target mean.» / «uses a cross fitting scheme to prevent target leakage.»
> — [scikit-learn TargetEncoder](https://scikit-learn.org/stable/modules/generated/sklearn.preprocessing.TargetEncoder.html)

**Cold-start / редкий geohash** — эксплуатировать префиксную иерархию: откат на более короткий префикс (грубее ячейка) → в пределе global mean. Свойство geohash:

> «the longer a shared prefix between two geohashes is, the spatially closer they are together» / «5 digits: ±2.4 km», «8 digits: ±19 m».
> — [Geohash — Wikipedia](https://en.wikipedia.org/wiki/Geohash)

Можно строить **multi-resolution** префиксные фичи (длины 3/4/5), чтобы модель смешивала крупно-региональный и мелко-ячеечный сигнал. Осторожно с артефактами границ (экватор/меридиан/полюса — соседние точки могут не иметь общего префикса). **High-cardinality + linear → регуляризация** (Ridge/LASSO); «Regularized target encoding outperforms traditional methods … with high cardinality features» ([Springer 2022](https://link.springer.com/article/10.1007/s00180-022-01207-6)). Масштабировать собранную матрицу фич перед регуляризованной регрессией.

### 4. Дистрибуция on-device модели

**НЕ использовать `MLModelCollection`** — устарел с iOS 17.4:

> «Use Background Assets or NSURLSession instead.»
> — [MLModelCollection](https://developer.apple.com/documentation/coreml/mlmodelcollection)

**Поддерживаемый паттерн** — скачать `.mlmodel` самому → скомпилировать → загрузить:

> «Download the model definition file (ending in `.mlmodel`) … by using URLSession … Then compile the model definition by calling `compileModel(at:)`. … Create a new MLModel instance by passing the compiled model URL to its initializer.»
> — [Downloading and Compiling a Model](https://developer.apple.com/documentation/coreml/downloading-and-compiling-a-model-on-the-user-s-device)

`MLModel.compileModel(at:)` — iOS 16+, **sync-вариант устарел**, использовать `try await`. Компиляцию делать вне main-thread; скомпилированный `.mlmodelc` сохранять в Application Support (или Caches с `isExcludedFromBackup`), не перекомпилировать на каждый запуск. Более высокоуровневая альтернатива — **Background Assets** (self-hosted CDN или Apple-hosted; «system downloads essential asset packs before launch»).

**Manifest / version endpoint** (схемы у Apple нет — это дело BFF). Значимые поля: `version`, `url` (HTTPS), `sha256`/`md5` (целостность — GCS бесплатно даёт CRC32C/MD5/ETag), `minAppVersion` (гейт несовместимых клиентов), `sizeBytes`, `createdAt`. Клиент качает только когда `version` отличается от сохранённой.

**Раздача из GCS/CDN:** использовать **immutable versioned имена объектов** (`model-v7.mlpackage`) + длинный `Cache-Control: public, max-age`; manifest указывает на текущее имя. Иначе — стейл-кеш:

> «If you allow caching, downloads might continue to receive earlier versions of an object, even after uploading a newer version.»
> — [GCS object metadata](https://docs.cloud.google.com/storage/docs/metadata)

Public CDN URL — если модель не секретна; иначе short-TTL signed URL (≤7 дней). **ATS работает из коробки** по `https://` к `storage.googleapis.com`/Cloud CDN (TLS 1.2+) — Info.plist-исключения не нужны. **Offline-first:** предпочесть **bundled baseline модель** (работает офлайн / если бэкенд недоступен) + фоновый OTA-апгрейд с проверкой хеша и атомарным swap+rollback.

### 5. Валидация регрессии

**Главная денежная метрика — MAE** (в долларах, устойчива к выбросам):

> «The mean absolute error is a non-negative floating point value, where best value is 0.0.» ([scikit-learn MAE](https://scikit-learn.org/stable/modules/generated/sklearn.metrics.mean_absolute_error.html)) / «Choose MAE: If your dataset has significant outliers … MAE is more robust.» ([Google — Loss](https://developers.google.com/machine-learning/crash-course/linear-regression/loss))

RMSE — вторичная (те же единицы, но тянется к выбросам). **MAPE — с оговорками**, взрывается у нуля:

> «bad predictions can lead to arbitrarily large MAPE values, especially if some `y_true` values are very close to zero.»
> — [scikit-learn MAPE](https://scikit-learn.org/stable/modules/generated/sklearn.metrics.mean_absolute_percentage_error.html)

**Квантильная (pinball) ошибка** для хвостов (P90 недооценки крупных инвойсов); при alpha=0.5 = MAE.

**Валидация строго по времени** (месяц — фича, данные накапливаются) — walk-forward backtest, не random k-fold:

> «classical cross-validation techniques such as KFold … would result in unreasonable correlation between training and testing instances … on time series data.» / «evaluate our model … on the 'future' observations … one solution is provided by TimeSeriesSplit.»
> — [scikit-learn — cross-validation](https://scikit-learn.org/stable/modules/cross_validation.html)

**Срезы обязательны** — по региону (geohash) и по бакетам суммы инвойса:

> «Great model performance overall … may mask poor performance on a minority subset.» ([Fairness](https://developers.google.com/machine-learning/crash-course/fairness/evaluating-for-bias)) / «Test model quality on important data slices … you avoid a problem where fine-grained performance issues are masked by a global summary metric.» ([High-quality ML solutions](https://docs.cloud.google.com/architecture/guidelines-for-developing-high-quality-ml-solutions))

**Два разных вида проверки:**
- **Train/serve skew** (данные/фичи): логировать serving-фичи и переиспользовать в обучении (Rule #29), переиспользовать код train/serve (Rule #32), мониторить train↔holdout↔live (Rule #37), детектить дрейф сравнением статистик. Наш выбор «встроить препроцессинг в Core ML граф» (§1) закрывает основной источник feature skew.
- **Паритет Core ML ↔ TF** (арифметика предсказаний конвертированной модели) — **отдельный обязательный тест**:

> «verify that the predictions made by the Core ML model match the predictions made by the source model.» ([Model Prediction](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html)) / `np.testing.assert_allclose(tf_out, coreml_out, rtol=1e-3, atol=1e-2)` ([TF1 Workflow](https://apple.github.io/coremltools/docs-guides/source/tensorflow-1-workflow.html))

## Implications for the design

- **Архитектура модели (anchor: serving-контракт backend↔iOS).** Собирать **одну Keras-модель = препроцессинг + линейная голова** и конвертировать целиком → препроцессинг едет внутри Core ML-графа, отдельный «контракт фич для iOS» почти исчезает. НО: строковые категориальные слои (`StringLookup`) ломают конвертацию — **делать geohash- и SKU-энкодинг на integer-индексах** (маппинг string→int держать вне графа, версионировать вместе с моделью), либо готовить MIL composite operator. Каждый категориальный слой прогнать через `ct.convert` на пиннутых версиях **до** фиксации дизайна.
- **Формат/таргет (anchor: iOS min-version).** Дефолты coremltools ≥7.0 → `.mlpackage` ML Program, iOS15+, float16. Понижать `minimum_deployment_target` только если реально нужна legacy `.mlmodel`.
- **Инфра обучения (anchor: dataset job + pipeline в Tofu.AI.Backend).** `CustomJob` в prebuilt TF-контейнере (CPU) → export в `AIP_MODEL_DIR` → **шаг конвертации TF→Core ML** → upload в Model Registry (`PARENT_MODEL` = новая версия). Всё завернуть в Vertex Pipeline и повесить `create_schedule(cron=...)` для переобучения. Данные — прямой BigQuery Storage API → `tf.data` из `ai_analysis_us.invoices`.
- **Дистрибуция (anchor: REST-контракт в backend + iOS integration doc).** `GET /models/{name}/manifest` → `{version, url, sha256, minAppVersion, sizeBytes, createdAt}`; артефакт — immutable versioned имя в GCS/CDN, длинный Cache-Control. iOS: URLSession download → `try await compileModel` → сохранить в App Support → атомарный swap. Bundled baseline для offline/first-launch. Решить в `/plan write`, в каком репозитории живёт manifest endpoint (BFF `Invoices.Backend` vs домен).
- **Валидация (anchor: gate переобучения + приёмка).** Метрики: **MAE (primary)** + RMSE + pinball(P90), считать **per-slice** (geohash, бакеты суммы). Валидация — **time-based walk-forward** (holdout по будущим месяцам). В CI перед выкаткой on-device модели — **gate паритета Core ML↔TF** (`assert_allclose rtol=1e-3 atol=1e-2` на фиксированной выборке).
- **Переиспользуемость (anchor: 3 модели).** Пайплайн training→convert→registry→manifest должен быть параметризуем по «модели» — FS-1335 первая из трёх ценовых.

## Open questions / follow-ups

- [ ] **BQ-аудит `ai_analysis_us.invoices`** (работа `/plan write`): есть ли geo/адрес для вычисления geohash, line items + qty, тотал, дата; покрытие и качество; сколько инвойсов на регион (для выбора длины geohash и порога cold-start).
- [ ] **string→int маппинги SKU и geohash-словаря**: где хранить, как версионировать вместе с артефактом модели, как iOS их получает (в manifest? встроить индекс в граф?).
- [ ] Перепроверить на пиннутых версиях `tensorflow` + `coremltools`: конвертируются ли integer `CategoryEncoding`/`Hashing`/`IntegerLookup` (Issue #1049 — про строки, 2021).
- [ ] Приватность: не утекают ли точные адреса пользователей через geohash-словарь/веса в артефакт, раздаваемый на устройства (juридически — target-encoded агрегаты, не адреса, но проверить длину geohash).
- [ ] Репозиторий manifest-endpoint: `Invoices.Backend` (BFF) vs `Tofu.Invoices.Backend` (домен) — зависит от того, где iOS удобнее его дёргать.
- [ ] Порог «новый пользователь»: подсказка только для новых — как определяется когорта и где применяется гейт (клиент vs backend).
- [ ] Свежесть Vertex-фактов: сверить сигнатуру `create_schedule`, `AIP_MODEL_DIR` и имена IAM-ролей в живой документации перед реализацией.
