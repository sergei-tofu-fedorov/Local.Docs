# WEB-1638 — Историзация связей master↔platId и признака подписки в `ai_analysis_us`

**Status:** implemented (branch `feaature/WEB-1638`), pending smoke test on `invoicesapp-project-test`
**Started:** 2026-06-29
**ClickUp:** https://app.clickup.com/t/WEB-1638
**Affected repos:** `Tofu.AI.Backend` (warehouse routines only — no BQ migration), `Local.Docs` (plan)

> Detailed authoritative design lives in [`overview.md`](overview.md). Final table names are
> `mart_master_platform_link_periods` / `mart_subscription_periods` (the `*_history` names below were the
> early draft). Historising `mart_account_current_plan` was dropped in favour of the subscription-grain
> `mart_subscription_periods`.

## Goal

Историзация связей master↔platId и признака подписки в `ai_analysis_us` через change-only
period-таблицы (SCD-2), плюс срез master×platId×subscription. Цель — понимать смену
подписки/платформы во времени. Stellan-экспорт в playfair `external_stellans` — отдельным
последующим шагом (в этот план только BQ-марты, экспорт упомянут как future step).

## Scope

- In scope:
  - SCD-2 (change-only) историзация `mart_master_platform_links` → новая period-таблица.
  - SCD-2 историзация `mart_account_current_plan` (признак подписки/плана во времени).
  - Срез **master×platId×subscription** — подписка на грани `(master_user_id, platform_user_id, platform)`, не схлопнутая в один primary-план (чего сейчас нет — `mart_account_current_plan` сводит до `account_id`).
  - Дневная гранулярность смены (между snapshot N и N+1); MERGE-дельта по хешу смысловых колонок.
- Out of scope:
  - Stellan-экспорт в `playfair-project.external` под роль `external_stellans` (отдельный future step — см. ниже).
  - Доменное событие при перелинковке в `Invoices.Backend` (точный момент-в-момент) — осознанно отвергнуто в пользу дневной гранулярности.

## Affected repos

- `Tofu.AI.Backend` — warehouse-рутины в `src/Analyses/Analyses.Infrastructure/Warehouse/Sql/Routines/` (`build_master_marts.sql`, `build_account_current_plan.sql`, `rebuild_warehouse.sql`) + BigQuery-миграция (`Analyses.Persistence/Migrations/Modules/BigQuery/`) для новых period-таблиц.
- `Local.Docs` — этот план.

**Cross-repo notes:**
- Однорепный (BQ-warehouse). Кросс-сервисных контрактов/proto в этой фазе нет.
- `account_current_plan` собирается отдельным scheduled query (event-sourced, после `account_subscriptions`), master-марты — в `rebuild_warehouse` (Mongo-snapshot). Историзация каждой таблицы привязывается к её собственной каденции.

## Plan

1. [x] Зафиксировать набор «отслеживаемых» колонок для row-hash каждой period-таблицы (исключить волатильные служебные: `updated_at`, build-time, `expires_at`-тик).
2. [x] DDL: `mart_master_platform_link_periods` (self-owned `CREATE TABLE IF NOT EXISTS` внутри `build_master_platform_link_periods`; `PARTITION BY valid_from CLUSTER BY platform_user_id`).
3. [x] DDL: `mart_subscription_periods` (заменяет отвергнутый `mart_account_current_plan_history` — грань подписки, не account-primary; hash по `master_user_id/product_type/status/is_active/is_trial/auto_renew_enabled`).
4. [x] Ежедневная MERGE-логика (change-only, close→insert): закрыть исчезнувшие/изменённые версии (`valid_to=today`), вставить новые/открытые; без изменений → ноль строк (идемпотентно на повторном прогоне того же снимка).
5. [x] Срез master×platId×subscription — несёт сама `mart_subscription_periods` (`master_user_id` + `platform_user_id` + денормализованные `product_type/status/is_active/platform`).
6. [x] Доступ к «текущему» / «состоянию на дату D» — без новых вьюх: «текущее» отдают существующие снимок-марты; «на дату D» = фильтр `valid_from <= D AND (valid_to IS NULL OR valid_to > D)` по period-таблице (примеры в `overview.md`).
7. [x] Запросы-детекторы смены (каждая history-строка = событие смены с датой) — задокументированы в `overview.md` §Consumer-facing shape.
8. [x] Wire: `CALL build_master_platform_link_periods()` в `rebuild_warehouse.sql` (после `build_master_marts`); `CALL build_subscription_periods()` в `refresh_account_subscriptions.sql` (после `build_account_subscriptions`). **Без `IBigQueryMigration`** — MERGE-цели владеют своим DDL (`IBigQueryMigration` run-once застрял бы на правке схемы).
9. [ ] Smoke test на `invoicesapp-project-test.ai_analysis_us`: прогон MERGE дважды на одном снимке → 0 новых строк; искусственная смена → ровно 1 новая версия. **Требует prod-обновления DTS scheduled-query body** для `build_subscription_periods` (см. ниже).
10. [ ] (future / отдельный тикет) Stellan-экспорт в playfair `external_stellans`.

## API / DTO changes

Не применимо (BQ-warehouse only).

## Breaking changes

None — additive only. Новые period-таблицы и вьюхи; существующие `mart_*` снимки (текущее состояние) не меняют грань. Подтвердить при `/feature review`.

## Data / migration

- Новые BQ-таблицы: `mart_master_platform_link_periods`, `mart_subscription_periods`. DDL — **self-owned** `CREATE TABLE IF NOT EXISTS` внутри build-процедуры (как `dim_skus`), **не** отдельная `IBigQueryMigration`: цели MERGE нельзя `CREATE OR REPLACE`, а run-once миграция застряла бы на правке схемы (процедуры деплоятся repeatable).
- Сборка — change-only MERGE (close→insert), не `CREATE OR REPLACE`.
- Рост ∝ числу реальных смен, а не `дни × строки` (см. обоснование SCD-2 vs snapshot-append в `overview.md`).
- **Ops-шаг (прод):** тело DTS scheduled-query подписок (`transferConfig 6a54e8ab-…`) надо вручную дополнить строкой `CALL build_subscription_periods();` — файл `refresh_account_subscriptions.sql` это зеркало, но сам DTS-config не деплоится из репо. `build_master_platform_link_periods` идёт через `rebuild_warehouse` и деплоится автоматически.

## Open questions

- [ ] Историзировать `mart_account_current_plan` (account-grain primary) или сразу строить историю на более широком master×platId×subscription срезе, а primary выводить из него?
- [ ] Каденция MERGE для master-history: внутри `rebuild_warehouse` или отдельным scheduled query?
- [ ] Нужна ли ретенция на history-партиции, или хранить бессрочно (SCD-2 и так растёт медленно)?

## Test plan

- Unit/функциональные: TestContainers BQ недоступен; проверка SQL-рутин — на тест-датасете `invoicesapp-project-test.ai_analysis_us` (smoke: вставка → изменение → закрытие версии; «без изменений → ноль строк»).
- Manual verification: прогон MERGE два дня подряд на одном снимке → 0 новых строк (идемпотентность); искусственная смена линка → ровно 1 новая history-строка.
