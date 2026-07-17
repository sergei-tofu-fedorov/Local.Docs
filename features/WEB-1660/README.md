# WEB-1660 — RED metrics for gateway (Invoices.Backend)

**Status:** planning
**Started:** 2026-06-30
**ClickUp:** https://app.clickup.com/t/WEB-1660
**Affected repos:** `Invoices.Backend` (code) · `Local.Docs` (plan) · GCP `inv-project`/`invoicesapp-project-test` (dashboard + alerts, ops)

## Goal

WEB-1660 Внедрить RED-метрики (Rate/Errors/Duration) для gateway Invoices.Backend через существующий push-пайплайн MetricReporter → Google.Cloud.Monitoring.V3 (БЕЗ GMP/Prometheus scrape, без изменений кластера). Эмитить метрики из RequestLoggingMiddleware: Counter запросов (теги EndpointName/method/status), error-rate (4xx/5xx), и Duration как Histogram/distribution (p50/p95/p99). Доработать MeterListener в MetricReporter под Histogram. Дашборд + алерты в Cloud Monitoring (канал Slack invoices-core-alerts). Цель — ранний сигнал по деградациям (в т.ч. OOM→502 на invoices-api).

> **Full implementation plan:** [`overview.md`](overview.md) — architecture, per-file changes, metric schema, GCP/dashboard/alerts, where to watch, cost.

## Scope

- In scope: эмит RED-метрики из `RequestLoggingMiddleware`; доработка `MetricReporter` под лейблы + `DISTRIBUTION`; RED-дашборд и алерты в Cloud Monitoring (Slack `invoices-core-alerts`).
- Out of scope: GMP/Prometheus scrape; изменения кластера; OTel `WithMetrics()`; метрики из Worker (только gateway/API); миграция puppeteer-метрики.

## Affected repos

- `Invoices.Backend` (BFF / gateway) — `Invoices.Common` (`MetricReporter`, `DiagnosticsConfig`) + `Invoices.Api` (`RequestLoggingMiddleware`).
- `Local.Docs` — этот план (отдельный PR, лэндится последним).
- GCP (ops, не репо) — дашборд + alert policies в `inv-project` и `invoicesapp-project-test`.

**Cross-repo notes:**
- Producer / consumer order: n/a — один код-репо, без contract-границ.
- Contract changes: none.
- Mapper updates: none.

## Plan

1. [x] `DiagnosticsConfig`: добавить `Histogram<double> HttpRequestDuration` (`red.request.duration`, ms) + бакеты.
2. [x] `RequestLoggingMiddleware`: `Record(elapsedMs, route/method/status_class)` после `stopwatch.Stop()`, исключить low-priority.
3. [x] `MetricReporter` L1 — хранить серии с учётом тегов (ключ имя+labels).
4. [x] `MetricReporter` L2 — `HistogramAcc` (фикс. бакеты, delta-reset) + `AddDistribution` (`DISTRIBUTION` gauge).
5. [x] `MetricReporter` L3 — generic-эмит всех серий (puppeteer сохранён через `MetricNameOverrides`).
6. [x] Тесты: middleware-эмит контракт (4 теста, вкл. нормализацию метода) — зелёные. Глубже по `MetricReporter`-агрегации (бакетинг/delta/merge) — опц. `/tests`.
   - [x] Code-review (high-effort workflow): 9 дефектов; исправлены все correctness (cardinality/OOM, data-loss, GAUGE→DELTA, bucket off-by-one, 200-chunking) + аллокации + хрупкость теста.
7. [ ] Деплой в test → проверить метрику в Metrics Explorer.
8. [ ] RED-дашборд (`red-dashboard.json`) на stage → финализировать Rate/Errors aligner → снять реальный p95 baseline → алерты (порог из p95) → Slack `invoices-core-alerts`.
9. [ ] Деплой в prod (после валидации в test).

## API / DTO changes

None — внутренняя телеметрия, публичных эндпоинтов/DTO не добавляется.

## Breaking changes

None — additive only. Внешних контрактов (gRPC/REST/DTO/БД/event) не трогаем; единственный риск — рост ingest-стоимости custom-метрик (управляется числом бакетов и `ReportingIntervalInSec`).

## Data / migration

None.

## Open questions

Решено: пороги алертов из реального p95 (не статичный 2s); дашборд сначала на stage. Открыто (`overview.md` §10): `status_class` vs сырой `status_code`; исполнитель prod-дашборда/алертов (нет `monitoring.admin` у s.fedorov); Worker или только API.

## Test plan

- Unit tests (`Invoices.Tests`): `HistogramAcc` бакеты/Count/Sum/delta-reset; детерминизм `LabelsKey`; раздельные серии по тегам; puppeteer-скаляр цел.
- Integration tests (`Invoices.Tests.Integration`): запрос к endpoint → измерение на `MeterRoot` (через тестовый `MeterListener`); health/OPTIONS не пишут.
- Manual: деплой в `invoicesapp-project-test`, потрогать эндпоинты, увидеть метрику с разрезами `route`/`status_class`, собрать дашборд → затем prod.
