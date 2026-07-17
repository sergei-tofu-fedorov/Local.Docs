# WEB-1660 — RED-метрики через GMP scrape (implementation design, вариант D — as built)

RED-метрики gateway реализованы **стандартным стеком**: встроенная гистограмма ASP.NET Core `http.server.request.duration` → OTel `MeterProvider` (View шейпит теги/бакеты) → Prometheus-endpoint на выделенном порту **9464** → **GMP managed collection** (PodMonitoring) → Cloud Monitoring (`prometheus.googleapis.com/...`, PromQL). Самописный push-пайплайн (`MetricReporter` + `MeterListener` + `GcpMetricsBackgroundService`) **полностью удалён**.

> **История решения.** Вариант B (свой `BaseExporter<Metric>` без изменений кластера) был спроектирован первым, но после снятия ограничения «без изменений манифестов» выбран канонический GKE-путь D: нулевой собственный код метрик против ~300 строк своего экспортёра. Вариант C-direct (OTLP → `telemetry.googleapis.com`) проверен по вебу и отклонён: в .NET OTLP-экспортёре нет gRPC call-credentials, token-refresh пришлось бы делать вручную через `DelegatingHandler`, API молодой.

**Source of plan:** [`overview.md`](overview.md) — §1 (цель), §5 (GCP-сторона, stage-first), §8 (стоимость) в силе; §3 (контракт `custom.googleapis.com/dotnet/red/request-duration`) и §4 (доработка `MetricReporter`) **заменены** этим документом: метрики теперь живут под `prometheus.googleapis.com/...`, дашборд/алерты пишутся в PromQL.

## Decision

- **Источник RED — встроенная `http.server.request.duration`** (метр `Microsoft.AspNetCore.Hosting`, .NET 8): `http.route` = matched template, method нормализует фреймворк (неизвестные verb'ы → `_OTHER`). Ручной emit в `RequestLoggingMiddleware` и `NormalizeMethod` удалены.
- **Шейпинг — декларативный View** в `Invoices.Api/DI/InfrastructureConfiguration.cs`: бакеты `0.005…10` s (секунды — родная единица инструмента) + whitelist тегов `http.route` / `http.request.method` / `http.response.status_code`; `error.type`, `url.scheme`, `network.protocol.version` отброшены (кардинальность). Сырой `status_code` вместо прежнего `status_class`: в PromQL классы выражаются `code=~"5.."`, View не умеет трансформировать значения.
- **Экспорт — `OpenTelemetry.Exporter.Prometheus.AspNetCore` 1.9.0-beta.2** (beta — осознанно: единый OTel-пайплайн; альтернатива prometheus-net отклонена как второй стек). Endpoint отвечает **только на выделенном порту `DiagnosticsConfig.MetricsPort` = 9464** (предикат по `Connection.LocalPort`), который не публикуется через Service/ingress — /metrics недоступен снаружи.
- **Scrape-запросы не шумят**: в API прометеус-middleware стоит первым в пайплайне и short-circuit'ит до `RequestLoggingMiddleware` — 30s-скрейпы не попадают ни в логи, ни в RED-серии.
- **Puppeteer chrome-memory gauge сохранён** через `AddMeter(DiagnosticsConfig.MeterRoot.Name)` в обоих приложениях; **оба скрейпятся** — отдельные PodMonitoring для invoices-api и invoices-worker (у worker'а chromium работает в PDF-генерации, его память нужна для OOM-мониторинга).
- **Push-пайплайн удалён целиком**: `MetricReporter`, `IMetricReporter`, обе копии `GcpMetricsBackgroundService`, `MetricsOptions` (+ appsettings-секция `MetricsConfiguration`), `DiagnosticsConfig.HttpRequestDuration`/`BucketsMs`, пакет `Google.Cloud.Monitoring.V3` (оба csproj), mock в `MockSetup`, хак в `InvoicesWebApplicationFactory`.
- **K8s — stage-only** (`Invoices.Kubernetes`, ветка `feature/tofu-support`, overlay `dev` → `invoices-cluster`): containerPort 9464 `metrics` у invoices-api **и** invoices-worker + два `PodMonitoring` (interval 30s) + запись в `kustomization.yaml`. Managed collection на `invoices-cluster` **включён** (2026-07-02, `enabled: true`, gmp-operator + 3 collector-пода Running). Prod overlay не тронут.

Всё ниже — supporting detail.

## Code layout

```
Invoices.Backend/Src/                                   (ветка feature/WEB-1660)
├── Invoices.Common/
│   ├── ConfigurationManagerExtensions.cs        # MODIFIED — MeterRoot остался; + const MetricsPort=9464; histogram/buckets удалены
│   ├── Invoices.Common.csproj                   # MODIFIED — минус Google.Cloud.Monitoring.V3
│   ├── Options/MetricsOptions.cs                 # DELETED
│   └── Services/Metrics/                         # DELETED — MetricReporter, IMetricReporter, GcpMetricsBackgroundService
├── Invoices.Api/
│   ├── Program.cs                               # MODIFIED — Kestrel-листенер 9464; UseOpenTelemetryPrometheusScrapingEndpoint (первым, предикат по порту)
│   ├── Invoices.Api.csproj                      # MODIFIED — + Exporter.Prometheus.AspNetCore 1.9.0-beta.2; − Monitoring.V3
│   ├── DI/InfrastructureConfiguration.cs        # MODIFIED — .WithMetrics: AddAspNetCoreInstrumentation + AddMeter(MeterRoot) + View(red) + AddPrometheusExporter
│   ├── DI/{CommonServices,ExternalServices,Common}Configuration.cs  # MODIFIED — сняты регистрации IMetricReporter / hosted-service / MetricsOptions
│   ├── Middleware/RequestLoggingMiddleware.cs   # MODIFIED — RED-emit и NormalizeMethod удалены (вернулся к master-виду)
│   ├── Metrics/GcpMetricsBackgroundService.cs    # DELETED
│   └── appsettings.json                         # MODIFIED — секция MetricsConfiguration удалена
├── Invoices.Worker/
│   ├── Program.cs                               # MODIFIED — Urls +9464; scrape-endpoint (предикат по порту)
│   ├── Invoices.Worker.csproj                   # MODIFIED — + Exporter.Prometheus.AspNetCore
│   └── DI/{Infrastructure,WorkerCommon}Configuration.cs  # MODIFIED — .WithMetrics(AddMeter+Prometheus); сняты hosted-service/IMetricReporter/MetricsOptions
├── Invoices.Tests/Middleware/RequestLoggingMiddlewareRedMetricsTests.cs  # DELETED
└── Invoices.IntegrationTests/Setup/{MockSetup,InvoicesWebApplicationFactory}.cs  # MODIFIED — mock и вырезание hosted-service удалены

Deploy/Invoices.Kubernetes/overlays/dev/                (ветка feature/tofu-support; prod НЕ тронут)
├── invoices.yaml                                # MODIFIED — containerPort 9464 name: metrics у invoices-api и invoices-worker
├── invoices-podmonitoring.yaml                  # NEW — два PodMonitoring: invoices-api и invoices-worker (port metrics, 30s)
└── kustomization.yaml                           # MODIFIED — + invoices-podmonitoring.yaml
```

Шов: единственный «наш» вклад в код — конфигурация `MeterProvider` (View + AddMeter + exporter) и предикат порта; всё остальное — фреймворк и GMP. Новых типов нет вообще.

## Метрики в Cloud Monitoring (новый контракт)

| Было бы (push, вар. B) | Стало (GMP) |
|---|---|
| `custom.googleapis.com/dotnet/red/request-duration` (DELTA/DISTRIBUTION, ms) | `prometheus.googleapis.com/http_server_request_duration_seconds/histogram` (секунды) |
| labels `route/method/status_class` | labels `http_route` / `http_request_method` / `http_response_status_code` (сырой код; классы — `code=~"5.."`) |
| `custom.googleapis.com/dotnet/puppeteer/chrome-total-working-set-bytes` | `prometheus.googleapis.com/puppeteer_memory_chrome_total_working_set_bytes/gauge` |

PromQL p95 по маршрутам: `histogram_quantile(0.95, sum by (http_route, le) (rate(http_server_request_duration_seconds_bucket[5m])))`.

⚠️ `red-dashboard.json` (в этой папке) написан под старый контракт — переписать на PromQL при настройке дашборда на stage (`overview.md` §5 остаётся планом: stage → prod).

## Sequencing / риски

1. ~~**Test-кластер:** включить managed collection~~ — **сделано 2026-07-02**: `--enable-managed-prometheus` применён к `invoices-cluster`, gmp-operator + 3 collector-пода Running.
2. **Prod-блокер:** ветка WEB-1660 удаляет push-путь. Деплой этого кода в prod **до** включения GMP на `tofu-cluster` = потеря puppeteer-метрики (и отсутствие RED) в prod. Prod overlay **уже подготовлен** (ветка `feature/WEB-1660` в Invoices.Kubernetes: порт 9464 + 2 PodMonitoring, зеркально dev). Порядок: включить GMP на `tofu-cluster` (**строго до** apply overlay — иначе CRD PodMonitoring не существует и `kubectl apply -k` упадёт) → merge/apply prod overlay → проверить/мигрировать prod-дашборды и алерты со старого имени `custom.googleapis.com/dotnet/puppeteer/chrome-total-working-set-bytes` (у `s.fedorov` нет monitoring-доступа в prod — проверка за devops; в test консьюмеров старого имени нет, проверено) → только затем деплой кода в prod.
3. **Beta-экспортёр:** `Exporter.Prometheus.AspNetCore` 1.9.0-beta.2 — следить за стабилизацией при апгрейде OTel.
4. **GMP-биллинг:** samples-based; текущий объём (~200 серий × 2 пода × 30s) — низкие десятки $/мес, паритет с push-оценкой (`overview.md` §8).

## Open questions

- [x] ~~Нужен ли scrape Worker'а~~ — да, `invoices-worker` PodMonitoring добавлен (chrome-memory для OOM-мониторинга PDF-генерации).
- [ ] Пороги алертов — по-прежнему из реального p95 на stage (`overview.md` §10), теперь в PromQL.
