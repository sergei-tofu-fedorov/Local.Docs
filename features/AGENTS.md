# Features — index

Cross-product / cross-repo feature docs and plans. One folder per feature; `features/<TASK>/README.md` is that feature's plan, with deeper docs beside it. Up: [`../AGENTS.md`](../AGENTS.md).

## Current features

| Feature | What it is | Entry |
|---|---|---|
| `FS-1111` | Service which will use AI for investigating diff issues for our application. | [README](FS-1111/README.md) |
| `FS-1241` | Recurring-invoice offer: backend endpoint (per-screen client/invoices/amount/item + who-to-show list) and the audience side — cohort marts + recurring-pattern funnel sizing. | [README](FS-1241/README.md) |
| `WEB-1523-segmentation` | AI-powered user-analysis platform (FSM-fit) — the framework/spec home; large tree (`analyses/`, `implementation/`, `investigation/`). | [README](WEB-1523-segmentation/README.md) |
| `WEB-1526` | CI/CD changes for the `Tofu.AI.Backend` FSM-fit pipeline. | [README](WEB-1526/README.md) |
| `WEB-1526-prep` | Groundwork: `Tofu.AI.Backend` to canonical form (src/ move, ports/adapters) + `Invoices.Kubernetes` fixes. | [README](WEB-1526-prep/README.md) |
| `WEB-1527` | Account-metrics collection implementation in `Tofu.AI.Backend`. | [README](WEB-1527/README.md) |
| `WEB-1529` | Assign admin role on business-account creation (eager path + backfill). | [README](WEB-1529/README.md) |
| `WEB-1479` | Pass auth from mobile into a Safari web view via Firebase (ID vs custom token); land users on the web-app home. | [README](WEB-1479/README.md) |
| `WEB-1617` | Providing demo access to our application. | [README](WEB-1617/README.md) |
| `WEB-1600-recurring-jobs` | Recurring client service → generated visits + per-period draft invoices. Holds the ServiceTitan-style "bill-on-agreement" design (the Option A period-Job plan lives in the `Invoices.Backend` repo). | [AGENTS](WEB-1600-recurring-jobs/AGENTS.md) |
| `WEB-1625` | Add sync endpoints to clients and items (similar to existing jobs / invoices / estimates). | [README](WEB-1625/README.md) |
| `WEB-1620` | Event-derived SKU catalog (`sku_mapping`) in playfair BigQuery via a daily Scheduled Query; replaces the `tofu_sku_mapping` Google-Doc catalog. | [README](WEB-1620/README.md) |
| `WEB-1638` | Историзация связей master↔platId и признака подписки в `ai_analysis_us` через change-only SCD-2 period-таблицы + master×platId×subscription срез (понимать смену подписки/платформы во времени). Stellan-экспорт — future. | [README](WEB-1638/README.md) |
| `fsm-fit-flashlite-switch` | FSM-fit classifier: switch prod from `gpt-4.1-nano` to `gemini-2.5-flash-lite` (Vertex, cached) + scheduling/automotive prompt fixes. Holds the benchmarks summary, a PII-free eval suite, and a BQ-rebuildable Argilla judging kit. | [README](fsm-fit-flashlite-switch/README.md) |
| `ai_summary` | Earlier AI-Summary / FSM-compatibility exploration (superseded by WEB-1523). | [README](ai_summary/README.md) |
| `WEB-1660` | RED metrics (Rate/Errors/Duration) for the `Invoices.Backend` gateway via the existing push `MetricReporter` → Cloud Monitoring (no GMP/scrape, no cluster change); dashboard + Slack alerts. | [README](WEB-1660/README.md) |
| `FS-1352` | BE-аналитика ключевых действий пользователей: обогащаем аналитическое хранилище данными о том, как часто/каким образом отправляют инвойсы и эстимейты и как получают оплату (методы, сумма, перекладывание комиссии на пользователя). | [README](FS-1352/README.md) |
| `FS-1351` | A/B-тест флаги с бэкенда: раздача варианта через фича-флаги (`overview.md`, `prototype-hosted-embedded.md`) + следующий шаг — свой слой анализа в BQ (`platform.md`, коллекция `experiments`, обобщённые метрики, `experiments_us`). **Доки перенесены в репозиторий `Invoices.Backend`** → `Docs/features/FS-1351-ab-testing/`. | в `Invoices.Backend` |
| `stripe-onboarding-redesign` | Ресёрч к ТЗ редизайна Stripe Connect онбординга (FSM iOS / Invoice Maker): README = рабочая выжимка (hosted vs embedded, префилл, returning users, best practices), research.md = полный след (форумы, 30+ кейсов компаний, конкуренты, верификация), prefill-fields.md = карта «поле → источник → нюанс», проверенная на тестовой платформе, prod-funnel.md = замер воронки по live Stripe API, pre-form-loss.md = разбор 68%, теряемых до формы, in-form-loss.md = разбор потерь внутри формы по экранам, ab-embedded-vs-hosted.md = план A/B embedded против hosted. | [README](stripe-onboarding-redesign/README.md) |
| `FS-1443` | Источник product-key платежа меняем на `Invoice.ProductKey` / `PaymentRequest.ProductKey` (правка только в BFF `Invoices.Backend`); ключ уже в jsonb `PspAdditionalInfos`, Tofu.AI экспорт сделан, PF-маппинг требует правки до раскатки BFF. | [README](FS-1443/README.md) |
| `FS-1335` | ML-подсказка цены позиции по названию айтема + гео клиента (US-only, каскад TF → on-device Core ML); первая из трёх ценовых моделей; данные — `inv-project:ml_training_us`, артефакты — `gs://tofu-ml-models`. Структура папки: README = обзор + компактный план, `explainer-for-newbies.md` = модель без ML-бэкграунда, `explainer-pipeline.md` = система/пайплайн для новичка, `research/` = весь исследовательский след (аудит, итерации, валидация, Core ML, Vertex, impl-design). | [README](FS-1335/README.md) |

## Convention

A feature folder's plan is its `README.md`. Keep this index in sync when a feature folder is added or removed.
