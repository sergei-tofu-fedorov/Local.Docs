# WEB-1525 — Историзация связей master↔platId и признака подписки в `ai_analysis_us`

**Status:** planning
**Started:** 2026-06-29
**ClickUp:** https://app.clickup.com/t/WEB-1525
**Affected repos:** `Tofu.AI.Backend` (warehouse routines + migration), `Local.Docs` (plan)

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

1. [ ] Зафиксировать набор «отслеживаемых» колонок для row-hash каждой period-таблицы (исключить волатильные служебные: `updated_at`, build-time, `expires_at`-тик).
2. [ ] DDL: `mart_master_platform_links_history` (`valid_from DATE, valid_to DATE, row_hash, deleted`; `PARTITION BY valid_from CLUSTER BY platform_user_id`).
3. [ ] DDL: `mart_account_current_plan_history` (аналогично; hash по `product_type/status/is_active/platform_user_id/product_id`).
4. [ ] Ежедневная MERGE-логика (change-only): закрыть исчезнувшие/изменённые версии (`valid_to=today`), вставить новые/открытые; без изменений → ноль строк.
5. [ ] Срез master×platId×subscription (view или mart) — подписка по `(master_user_id, platform_user_id, platform)`.
6. [ ] Вьюхи доступа: «текущее» (`valid_to IS NULL`) и «состояние на дату D» (`valid_from <= D AND (valid_to IS NULL OR valid_to > D)`).
7. [ ] Запросы-детекторы смены (каждая history-строка = событие смены с датой).
8. [ ] Wire в `rebuild_warehouse` / scheduled query; миграция в `migration_history`.
9. [ ] (future) Stellan-экспорт в playfair `external_stellans`.

## API / DTO changes

Не применимо (BQ-warehouse only).

## Breaking changes

None — additive only. Новые period-таблицы и вьюхи; существующие `mart_*` снимки (текущее состояние) не меняют грань. Подтвердить при `/feature review`.

## Data / migration

- Новые BQ-таблицы: `mart_master_platform_links_history`, `mart_account_current_plan_history` (+ возможный master×platId×subscription mart/view).
- BigQuery-миграция (`IBigQueryMigration` `V00x`) на создание; сборка — change-only MERGE, не `CREATE OR REPLACE`.
- Рост ∝ числу реальных смен, а не `дни × строки` (см. обоснование SCD-2 vs snapshot-append в обсуждении задачи).

## Open questions

- [ ] Историзировать `mart_account_current_plan` (account-grain primary) или сразу строить историю на более широком master×platId×subscription срезе, а primary выводить из него?
- [ ] Каденция MERGE для master-history: внутри `rebuild_warehouse` или отдельным scheduled query?
- [ ] Нужна ли ретенция на history-партиции, или хранить бессрочно (SCD-2 и так растёт медленно)?

## Test plan

- Unit/функциональные: TestContainers BQ недоступен; проверка SQL-рутин — на тест-датасете `invoicesapp-project-test.ai_analysis_us` (smoke: вставка → изменение → закрытие версии; «без изменений → ноль строк»).
- Manual verification: прогон MERGE два дня подряд на одном снимке → 0 новых строк (идемпотентность); искусственная смена линка → ровно 1 новая history-строка.
