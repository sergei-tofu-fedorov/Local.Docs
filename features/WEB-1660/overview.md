# WEB-1660 — RED-метрики для gateway (Invoices.Backend) — implementation overview

**Сложность:** Medium (один репо, но требует структурной доработки `MetricReporter`: лейблы + distribution).
**Подход:** push через существующий `MetricReporter` → `Google.Cloud.Monitoring.V3`. БЕЗ GMP/Prometheus scrape, БЕЗ изменений кластера.

---

## 1. Что делаем (одним абзацем)

Эмитим из `RequestLoggingMiddleware` на каждый HTTP-запрос одну метрику-гистограмму длительности с лейблами `route` / `method` / `status_class`. Из неё выводится весь RED: **Rate** (count гистограммы за интервал), **Errors** (count с `status_class=5xx`/`4xx` к общему), **Duration** (перцентили p50/p95/p99 из бакетов). Чтобы это поехало через текущий push-пайплайн, дорабатываем `MetricReporter`: учим его (а) хранить значения с учётом тегов, (б) агрегировать `Histogram` в бакеты и слать в Cloud Monitoring как `DISTRIBUTION`, (в) эмитить все собранные серии generic-циклом (сейчас захардкожена одна метрика). Дальше — дашборд RED и алерты в Cloud Monitoring с нотификацией в Slack `invoices-core-alerts`.

## 2. Как это устроено сейчас (исходная точка)

Поток метрик в Invoices.Backend уже существует и **работает в API**, но используется только для одной метрики (Chrome-память):

```
DiagnosticsConfig.MeterRoot (Invoices.Common/ConfigurationManagerExtensions.cs:13)
      │  Instrument.Record(...)
      ▼
MetricReporter  (Invoices.Common/Services/Metrics/MetricReporter.cs)
  • MeterListener слушает MeterRoot                                  :44-88
  • measurement callbacks складывают значение в _metricValues        :58-85
        ConcurrentDictionary<string,long>  ← ключ = ТОЛЬКО имя инструмента
  • ReportMetricsAsync(): берёт snapshot, шлёт ТОЛЬКО puppeteer-метрику :207-260
  • AddMetric(): пишет custom.googleapis.com/dotnet/{name}, GAUGE DoubleValue :181-205
      ▼
GcpMetricsBackgroundService — цикл каждые ReportingIntervalInSec
  • API:    зарегистрирован в Invoices.Api/DI/ExternalServicesConfiguration.cs:70
  • Worker: Invoices.Worker/DI/InfrastructureConfiguration.cs:57
  • IMetricReporter→MetricReporter: CommonServicesConfiguration.cs:222 (API)
  • интервал = MetricsConfiguration.ReportingIntervalInSec = 10s (appsettings.json:26)
      ▼
Cloud Monitoring (resource type k8s_pod), project = текущий GCP-проект пода
```

**Три структурных ограничения, которые надо снять (это и есть основной объём):**

| # | Ограничение | Где | Почему мешает RED |
|---|-------------|-----|-------------------|
| L1 | Нет лейблов: `_metricValues` ключуется только именем инструмента; теги измерения **отбрасываются** (`(instrument, measurement, _, _)`) | `MetricReporter.cs:22,58-85` | RED требует разрезов по `route`/`method`/`status` |
| L2 | Нет гистограмм: `AddMetric` пишет только скалярный `DoubleValue` (GAUGE) | `MetricReporter.cs:181-205` | без `DISTRIBUTION` нет p50/p95/p99 |
| L3 | Эмит захардкожен: шлётся только `puppeteer.*` | `MetricReporter.cs:230-234` | новые серии не доедут |

## 3. Схема метрики (контракт)

Одна метрика-гистограмма (паттерн «RED из одного инструмента»):

- **Имя инструмента (.NET):** `red.request.duration` на `DiagnosticsConfig.MeterRoot`.
- **Тип в Cloud Monitoring:** `custom.googleapis.com/dotnet/red/request-duration`
  (munging: `_`→`-`, `.`→`/`), **`MetricKind=DELTA`**, `ValueType=DISTRIBUTION`. Дескриптор создаётся явно (`EnsureRedDescriptorAsync`, идемпотентно через `ALREADY_EXISTS`) — авто-создание сделало бы GAUGE, что ломает Rate/Errors и необратимо. Точки пишутся с `Interval{StartTime=windowStart, EndTime=now}`; окно сдвигается каждый репорт (delta, contiguous).
- **Метод-лейбл нормализован** к фиксированному набору verb'ов (`NormalizeMethod`) — `request.Method` клиент-контролируемый, verbatim → unbounded cardinality/OOM.
- **Единица:** миллисекунды (как `stopwatch.Elapsed.TotalMilliseconds`).
- **Лейблы (низкая кардинальность — критично для цены):**
  | Лейбл | Источник в middleware | Значения |
  |-------|----------------------|----------|
  | `route` | `EndpointName` (`RequestLoggingMiddleware.cs:65`) | matched display name контроллера/экшена; `(unmatched)` если endpoint == null |
  | `method` | `request.Method` | GET/POST/… |
  | `status_class` | `context.Response.StatusCode` → `2xx`/`3xx`/`4xx`/`5xx` | 4 значения (не сырой код — экономит цену) |
- **Бакеты (explicit, ms):** `5,10,25,50,75,100,250,500,750,1000,2500,5000,7500,10000`
  (= дефолт OTel в секундах ×1000; подгоняется под SLO — урезание бакетов = прямая экономия).

> Решение по `status_class`, а не сырому `status_code`: ограничивает кардинальность 4 значениями вместо ~6–10, сохраняя возможность Errors (4xx/5xx). Если позже понадобится сырой код для точечной диагностики — добавить отдельным дешёвым `Counter`, не на гистограмме.

## 4. Изменения в коде (по файлам)

Всё в одном репо — **Invoices.Backend**.

### 4.1 Определить инструмент — `Invoices.Common/ConfigurationManagerExtensions.cs`
Добавить в `DiagnosticsConfig` статический `Histogram<double>`:
```csharp
// RED: единственный инструмент, из него выводятся Rate/Errors/Duration. Бакеты — в ms.
public static readonly Histogram<double> HttpRequestDuration =
    MeterRoot.CreateHistogram<double>("red.request.duration", unit: "ms");
```

### 4.2 Точка эмита — `Invoices.Api/Middleware/RequestLoggingMiddleware.cs`
Сразу после `stopwatch.Stop()` (`:105`), перед/рядом с финальным логом (`:136`):
```csharp
// RED: единственная точка эмита — здесь уже посчитаны route/status/elapsed.
// Health-checks и OPTIONS (lowLevelPriority) исключаем, чтобы не зашумлять Rate/Duration.
if (!lowLevelPriority)
{
    DiagnosticsConfig.HttpRequestDuration.Record(
        stopwatch.Elapsed.TotalMilliseconds,
        new("route", endpoint?.DisplayName ?? "(unmatched)"),   // EndpointName, не RequestPath — RequestPath содержит id → взрыв кардинальности
        new("method", request.Method),
        new("status_class", $"{context.Response.StatusCode / 100}xx"));
}
```
Комментарии обязательны: причина выбора `EndpointName` и исключения low-priority — неочевидны.

### 4.3 Доработка `MetricReporter` — `Invoices.Common/Services/Metrics/MetricReporter.cs` (ядро задачи)

**L1 — лейблы.** Заменить `ConcurrentDictionary<string,long> _metricValues` на структуру с ключом «имя + отсортированные теги». Эскиз:
```csharp
private readonly record struct SeriesKey(string Name, string LabelsKey);   // LabelsKey = "method=GET;route=...;status_class=2xx"
// скаляры (counter/gauge):
private readonly ConcurrentDictionary<SeriesKey, ScalarAcc> _scalars = new();
// гистограммы (delta за интервал):
private readonly ConcurrentDictionary<SeriesKey, HistogramAcc> _hist = new();
```
В measurement-callbacks захватывать `tags` (сейчас `_`), строить `LabelsKey` детерминированно (сортировка по ключу). Сохранить лейблы и для итогового `Metric.Labels`.

**L2 — гистограмма → DISTRIBUTION.** Сами агрегируем по фиксированным бакетам (не полагаемся на внутреннюю агрегацию .NET) и **сбрасываем каждый интервал** (delta-семантика — каждый push = распределение за интервал, без cumulative-bookkeeping):
```csharp
private sealed class HistogramAcc       // фикс. границы из DiagnosticsConfig
{
    public long[] Buckets;              // counts по бакетам
    public long Count;
    public double Sum;
    public void Record(double v) { /* найти бакет, ++; Count++; Sum+=v */ }
    public DistributionSnapshot SnapshotAndReset() { /* копия + обнуление */ }
}
```
Различать инструмент по типу: callback `SetMeasurementEventCallback<double>` для `red.request.duration` (тип `Histogram<double>`) → в `_hist`; прочие double/long/int → как раньше в `_scalars`.

Новый `AddDistribution(...)` рядом с `AddMetric` — пишет `TypedValue.DistributionValue`:
```csharp
new Distribution {
    Count = snap.Count, Mean = snap.Count > 0 ? snap.Sum / snap.Count : 0,
    BucketOptions = new() { ExplicitBuckets = new() { Bounds = { /* границы */ } } },
    BucketCounts = { snap.Buckets }
}
```
`MetricKind=GAUGE`, `ValueType=DISTRIBUTION`. Cloud Monitoring считает перцентили из distribution-gauge через aligner `ALIGN_PERCENTILE_{50,95,99}`.

**L3 — generic-эмит.** В `ReportMetricsAsync` заменить захардкоженный puppeteer-блок на цикл по `_scalars` и `_histograms`. Puppeteer-метрика продолжает работать как скаляр без тегов (регресса нет).

**Hardening из code-review (high-effort workflow):**
- **Cardinality/OOM:** метод нормализован (выше) — без этого клиент минтит unbounded серии → OOM.
- **Bucket-контракт:** индексация `value >= bounds[i]` (lower-inclusive, как у GCP ExplicitBuckets), не `>`.
- **DELTA + StartTime:** см. §3 — иначе Rate/Errors неверны и дескриптор залочен GAUGE.
- **Потеря данных:** histogram-снапшот при сбое отправки возвращается в аккумулятор (`HistogramAcc.Merge`) — интервал не теряется; per-chunk try/catch без rethrow (не убивает chrome-метрику).
- **200-series limit:** отправка чанками по `MaxTimeSeriesPerRequest=200`.
- **Аллокации:** `LabelsKey` на hot-path без Dictionary/LINQ; словарь строится только на cache-miss.

> Важно: `MetricReporter` отключается, если `Platform.Instance().ProjectId` пуст (`:28-36`) — локально без GKE метрики не шлются. Это ок: агрегацию тестируем юнитами в изоляции (см. §7).

### 4.4 Чего НЕ трогаем
- `GcpMetricsBackgroundService`, DI-регистрация, интервал 10s — уже корректны для API.
- OTel tracing, Serilog — без изменений.
- Кластер, манифесты, пермишены пода — запись custom-метрик у пода уже есть (puppeteer-метрика идёт).

## 5. GCP-сторона (вне репо — ops)

1. **Метрика появится автоматически** после деплоя как `custom.googleapis.com/dotnet/red/request-duration` под resource `k8s_pod`. Дескриптор создаётся при первом `CreateTimeSeries` — отдельный шаг не нужен.
2. **Дашборд RED — сначала на stage** (`invoicesapp-project-test`, где доступ полный): `gcloud monitoring dashboards create --config-from-file=red-dashboard.json --project=invoicesapp-project-test` (JSON храним в этой папке). 3 виджета: Rate, Error-rate, Duration p50/p95/p99. После проверки на stage — тот же JSON в prod (`inv-project`) силами devops/prod SA.
3. **Алерты** → канал Slack `invoices-core-alerts` (id берём из `gcloud alpha monitoring channels list`): (а) error-rate 5xx выше порога N% за 5m; (б) p95 latency выше T ms за 10m. **Пороги T берём из РЕАЛЬНОГО p95 после первого сбора метрики** (на stage), а не из статичного 2s (`http_requests_gt_2s`) — снимаем фактический baseline и ставим порог с запасом над ним. Закрывает раннее обнаружение [[project_invoices_api_oom_502]].

> ⚠️ Пермишены: создание дашбордов/алертов в prod (`inv-project`) требует `monitoring.admin`, которого у `s.fedorov` нет (есть только logging-read). Дашборд/алерты в prod создаёт devops или через prod SA. В test (`invoicesapp-project-test`) доступ полный — там настраиваем и валидируем первыми.

## 6. Где смотреть метрики

- **Metrics Explorer** (основное):
  - test: `https://console.cloud.google.com/monitoring/metrics-explorer;project=invoicesapp-project-test`
  - prod: `https://console.cloud.google.com/monitoring/metrics-explorer;project=inv-project`
  - Metric: `custom.googleapis.com/dotnet/red/request-duration`; Resource: `k8s_pod`; фильтр `cluster_name=tofu-cluster`, `namespace_name=default`.
  - **Duration:** aligner `ALIGN_PERCENTILE_95` (и 50/99), group by `route`.
  - **Rate:** aligner `ALIGN_RATE` по полю `count` distribution, sum по всем `route`.
  - **Errors:** `ALIGN_RATE` с фильтром `status_class="5xx"` / сумму всех → доля.
- **RED-дашборд** (после создания) — Monitoring → Dashboards → «Invoices.Backend RED».
- **MQL-пример (p95 по маршрутам):**
  ```
  fetch k8s_pod
  | metric 'custom.googleapis.com/dotnet/red/request-duration'
  | align delta(1m) | every 1m
  | group_by [metric.route], [value_p95: percentile(value.request_duration, 95)]
  ```
- Контроль стоимости/кардинальности: Monitoring → **Metrics Management** (ingestion volume и cardinality по метрике).

## 7. Test plan

- **Unit (`Invoices.Tests`):** `HistogramAcc` — раскладка по бакетам, `Count`/`Sum`, `SnapshotAndReset` обнуляет (delta); `LabelsKey` детерминированен при перестановке тегов; `MetricReporter` собирает раздельные серии на разные теги; puppeteer-скаляр не сломан.
- **Integration (`Invoices.Tests.Integration`):** запрос к реальному endpoint → измерение зарегистрировано на `MeterRoot` (проверяем через свой `MeterListener` в тесте, минуя GCP-экспорт); health-check/OPTIONS — измерения НЕ создают.
- После тестов прогнать **`/tests`** по новым тест-файлам (конвенции проекта).
- **Manual:** деплой в `invoicesapp-project-test` → потрогать эндпоинты → метрика видна в test Metrics Explorer с разрезами `route`/`status_class` → собрать дашборд → потом prod.

## 8. Стоимость (из расчёта по факту, см. память)

2 реплики (без HPA) × ~200 label-комбо × (≈15 бакетов + count) → push раз в 10s. Распределение по `status_class` мало (трафик ~99% 2xx). Ориентир — **низкие десятки $/мес**. Рычаги: урезать бакеты под SLO; при необходимости повысить `ReportingIntervalInSec` (10s→30/60s) — линейно режет число точек.

## 9. Breaking changes
**None — additive only.** Новый инструмент + доработка внутреннего репортера; внешних контрактов (gRPC/REST/DTO/БД) не трогаем. Риск — только рост ingest-стоимости custom-метрик (управляется бакетами/интервалом).

## 10. Decisions & open questions

**Решено:**
- ✅ **Пороги алертов** — из реального p95 после первого сбора на stage (снять baseline, поставить порог с запасом), НЕ статичный 2s.
- ✅ **Дашборд — сначала на stage** (`invoicesapp-project-test`), затем тем же JSON в prod.

**Открыто:**
- [ ] `status_class` достаточно, или нужен сырой `status_code` (доп. дешёвый Counter) для диагностики?
- [ ] Дашборд/алерты в **prod** — кто исполняет (devops vs prod SA), раз у `s.fedorov` нет `monitoring.admin`?
- [ ] Эмитить ли те же метрики из Worker (фоновые задачи) или только из API (gateway)? Тикет — про gateway, по умолчанию только API.
