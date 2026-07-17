# WEB-1638 — Историзация связей master↔platId и признака подписки в `ai_analysis_us`

Две SCD-2 **change-only** period-таблицы в `inv-project.ai_analysis_us`, которые делают наблюдаемой во времени (а) графа связей `masterUser` ↔ платформенных пользователей (`platformId`) и (б) состояние подписки на грани `(master_user_id, platform_user_id, subscription)`. Сегодня все марты пересобираются `CREATE OR REPLACE` (snapshot) → прошлое состояние затирается каждым ребилдом, поэтому «когда пользователь сменил подписку / сменил платформу» из них восстановить нельзя. Цель WEB-1638 — закрыть это: хранить **только изменения** (строка появляется лишь когда что-то реально поменялось), денормализованно, чтобы аналитик-консьюмер (Playfair `external_stellans`) читал каждую таблицу почти без джойнов.

Related ClickUp tasks:
- https://app.clickup.com/t/WEB-1638 (initiative)
- Зависит от уже задеплоенных WEB-1620 мартов (`mart_master_platform_links`, `mart_master_owned_accounts`, `mart_account_subscriptions`).

## Scope

**In scope**
- `mart_master_platform_link_periods` — SCD-2 история графа связей `master_user_id ↔ platform_user_id` (платформа, продукт, `is_first_link`, появление/исчезновение связи).
- `mart_subscription_periods` — SCD-2 история признака подписки на грани `(master_user_id, platform_user_id, app_name, original_transaction_id)` с денормализованными `product_type / status / is_active / is_trial / platform`.
- Дельта-MERGE логика (close + insert), запускаемая в существующих каденциях (snapshot-rebuild и event-scheduled-query).
- Консьюмер-вьюхи «текущее состояние» и примеры запросов «смена подписки / смена платформы».
- Бессрочная ретенция (без `partition_expiration`).

**Out of scope**
- Экспорт-job в `playfair-project.external` под роль `external_stellans` — **future step** (отдельный тикет): таблицы проектируются Stellan-friendly заранее, но сам трансфер/IAM в Playfair здесь не делаем.
- Историзация `mart_account_current_plan` (per-account primary-план) — осознанно отложена; account-уровень выводится джойном `mart_master_owned_accounts` при необходимости.
- Доменное событие на перелинковку в `Invoices.Backend` (точный timestamp смены) — отвергнуто в пользу дневной гранулярности.

## High-level approach

**SCD-2 change-only (period-таблицы)**, а не daily snapshot-append. Каждый день дельта-MERGE сравнивает свежесобранный текущий снимок (`mart_master_platform_links` / `mart_account_subscriptions`) с открытой версией в history-таблице по `row_hash` отслеживаемых колонок: при изменении — закрывает старую версию (`valid_to = CURRENT_DATE()`) и вставляет новую открытую; без изменений — не пишет ничего.

| Подход | Рост за год (links ~422K / subs ~918K строк) | «Текущее» читается | Смена видна как | Вердикт |
|---|---|---|---|---|
| Daily snapshot-append (partition by `snapshot_date`) | ~154M / ~335M строк (>99% копии) | 1 партиция (pruning) | `LAG` по соседним партициям-снимкам | ❌ пишет/хранит мусор; partition только удешевляет чтение |
| **SCD-2 change-only (выбрано)** | ∝ числу смен (единицы млн) | `WHERE is_current` | **каждая history-строка = событие смены** (есть `valid_from`) | ✅ рост по изменениям; смена — одна строка, без `LAG` |
| Доменное событие на re-link | — | — | точный timestamp | отложено: требует кода в BFF + новый event-stream |

**Две таблицы, а не одна.** Графа связей (источник — Mongo `masterUser` snapshot, каденция `rebuild_warehouse`) и состояние подписки (источник — analytics events, каденция отдельного scheduled query) меняются по-разному и из разных источников. Разделение держит каждую таблицу денормализованной и самодостаточной: «сменил платформу/перелинковка» → `mart_master_platform_link_periods`; «сменил план/истёк» → `mart_subscription_periods`. Обе несут `master_user_id` + `platform_user_id`, поэтому тривиально джойнятся, когда консьюмеру нужно и то и другое. `platform` дублируется в обеих намеренно (в одной — из графа связей, в другой — из событий), чтобы каждая отвечала на свой вопрос без джойна — house-стиль Playfair `subs_user_subscriptions_periods`.

**Footprint: +2 таблицы, 0 удалений.** Обе period-таблицы — чисто аддитивный history-слой. Удалить существующие марты нельзя: `mart_master_platform_links` — вход `build_account_current_plan` + `build_account_subscriptions` + нового period-MERGE; `mart_account_subscriptions` — вход `build_account_current_plan` + period-MERGE; `mart_account_current_plan` — читается `build_recurring_offer_{cohort,groups}`. Каждый снимок-март также служит входом своего ежедневного дельта-MERGE. Легаси `platform_user_accounts`/`platform_user_canonical` уже сняты (cutover завершён). *Возможная будущая консолидация (не сейчас):* свернуть снимок-марты во вьюхи над period-таблицами, чтобы «текущее» не хранилось дважды — но тогда period-MERGE строит рабочий снимок инлайн из `src_master_users`/`mart_account_subscriptions`, а 4 ридера репойнтятся на вьюху; при <1M строк дублирование «текущего» дешевле этой связности.

**Таблицы владеют своим DDL через `CREATE TABLE IF NOT EXISTS` внутри build-процедуры** (как `dim_skus` в `build_sku_mapping`, `build_subscriptions.sql:20`), а не через run-once `IBigQueryMigration` — потому что (1) это MERGE-цели (нельзя `CREATE OR REPLACE`, иначе теряем историю), (2) процедуры деплоятся repeatable (`BigQueryRoutinesModuleMigration`), так что правка схемы переедет с правкой тела, тогда как `IBigQueryMigration` run-once «застрянет» (см. комментарий в `BigQueryRoutinesModuleMigration.cs:8`).

## Data model

Обе таблицы — `PARTITION BY valid_from`, без `partition_expiration` (бессрочно). SCD-2 служебные колонки одинаковы: `valid_from DATE NOT NULL`, `valid_to DATE NULL` (NULL = открытая/текущая версия), `is_current BOOL`, `is_deleted BOOL`, `row_hash STRING`, `built_at TIMESTAMP`.

### `mart_master_platform_link_periods`

SCD-2 история графа связей. Натуральный ключ версии = `(master_user_id, platform_user_id, platform, product)`. Источник свежего снимка: `mart_master_platform_links` (`build_master_marts.sql:41`).

| Column | Type | Notes |
|---|---|---|
| `master_user_id` | STRING NOT NULL | nat key; Mongo `masterUser._id` |
| `platform_user_id` | STRING NOT NULL | nat key; `PlatformUserLink.PlatformId` (полный id, для web не усечён) |
| `platform` | INT64 NOT NULL | nat key; `1=IOS, 2=Android, 3=Web` (`Invoices.Core/Models/MasterUser.cs:6`) |
| `product` | STRING NOT NULL | nat key; `PlatformUserLink.Product` |
| `public_id` | STRING NULL | events `account_id` (`GetShortUserId`): mobile = trunc(25), web = полный |
| `is_first_link` | BOOL | **hashed**; первый-владелец флаг (фидит подписки в `plans/current`) |
| `link_created_at` | TIMESTAMP NULL | `PlatformUserLink.CreatedAt` из Mongo (когда связь создана) |
| `valid_from` / `valid_to` | DATE / DATE NULL | SCD-2 интервал; `valid_to IS NULL` = текущая |
| `is_current` | BOOL | удобный фильтр-синоним `valid_to IS NULL` |
| `is_deleted` | BOOL | TRUE если на закрытии ключ **исчез** из снимка (связь убрана / `masterUser` удалён) |
| `row_hash` | STRING | `TO_HEX(MD5(...))` по отслеживаемым колонкам (см. ниже) |
| `built_at` | TIMESTAMP | время MERGE-прогона |

- **`row_hash` берёт:** `is_first_link`, `public_id` (платформа/продукт уже в ключе; `link_created_at` стабилен). Главный сигнал этой таблицы — **появление/исчезновение** пары `(master, platId)` = смена платформы / перелинковка.
- Partition: `valid_from`. Cluster: `platform_user_id` (доминирующий join-ключ, как у `mart_master_platform_links`).

### `mart_subscription_periods`

SCD-2 история подписки на грани платформенного пользователя. Натуральный ключ версии = `(platform_user_id, app_name, original_transaction_id)` — истинная идентичность подписки. `master_user_id` НЕ в ключе, а **hashed-атрибут**: переход NULL→master (аноним позже слинковал master) отражается как смена-версия, а не новая линия, и нет ловушки NULL-ключа в join. Источник: `mart_account_subscriptions` (`build_subscriptions.sql:296`), отфильтрованный на `platform_user_id IS NOT NULL` (резолвнутые master/accountIdentifiers).

| Column | Type | Notes |
|---|---|---|
| `master_user_id` | STRING NULL | **hashed**; NULL для no-master (резолв через accountIdentifiers); NULL→value = смена-версия |
| `platform_user_id` | STRING NOT NULL | nat key; полный platform user id |
| `app_name` | STRING NOT NULL | nat key; `iOS/android/field_service/tofu_web` |
| `original_transaction_id` | STRING NOT NULL | nat key; store sub id |
| `platform` | INT64 NULL | derive из `app_name` (web=3, иначе mobile) — для симметрии с link-таблицей |
| `product_id` | STRING NULL | текущий product_id подписки |
| `product_type` | STRING | **hashed**; `FsmBusiness/…/Plus/Unknown` (`build_subscriptions.sql:308`) |
| `product_type_priority` | INT64 | tier-приоритет (denormalized, чтобы primary считался без джойна) |
| `status` | STRING | **hashed**; `active/trial/expired/refunded` |
| `is_active` | BOOL | **hashed**; флип при истечении периода — намеренно создаёт новую версию |
| `is_trial` | BOOL | **hashed** |
| `auto_renew_enabled` | BOOL NULL | **hashed** |
| `expires_at` | TIMESTAMP NULL | атрибут, **НЕ hashed** (ежедневный пересчёт не должен «дёргать» версии) |
| `started_at` | TIMESTAMP NULL | начало подписки (атрибут) |
| `subz_account_id` | STRING NULL | events public id (для сверки/резолва) |
| `valid_from`/`valid_to`/`is_current`/`is_deleted`/`row_hash`/`built_at` | — | SCD-2 служебные (как выше) |

- **`row_hash` берёт:** `product_type`, `status`, `is_active`, `is_trial`, `auto_renew_enabled`. Не берёт `expires_at`/`built_at` — иначе каждая строка «меняется» каждый день и мы возвращаемся к snapshot-мусору. `is_active` в хеше ловит флип «истекла», `product_type` — смену плана.
- Partition: `valid_from`. Cluster: `platform_user_id`.

## Consumer-facing shape (Stellan-friendly)

Главное требование — **минимум джойнов** для аналитика в Playfair. Достигается тремя приёмами:

1. **Денормализация внутри каждой period-таблицы.** Всё нужное для вопроса несёт сама таблица: link-таблица — `is_first_link`/`platform`/`public_id`; sub-таблица — `product_type`/`status`/`is_active`/`platform` рядом. `product_type_priority` лежит готовым, primary считается оконкой без отдельного `dim`.
2. **Двойной маркер «текущее»: `valid_to IS NULL` И `is_current BOOL`.** SCD-2-педант фильтрует по `valid_to IS NULL`; аналитик-человек — по `is_current` (читается с листа). Оба эквивалентны; `is_deleted` отделяет «закрыто, потому что исчезло» от «закрыто, потому что сменилось».
3. **Без новых «current»-вьюх.** «Текущее» уже материализовано существующими снимок-мартами (`mart_master_platform_links`, `mart_account_subscriptions`) — они и остаются surface для актуального состояния. Новые period-таблицы добавляют **только историю/смены**. Разделение труда для консьюмера: актуальное → снимок-март; «когда поменялось» → period-таблица (`is_current` фильтр там — для удобства листания истории, не как замена снимку).

**Как консьюмер задаёт типовые вопросы (без джойнов):**

```sql
-- (а) текущая подписка по платформенному пользователю (существующий снимок-март)
SELECT * FROM `…ai_analysis_us.mart_account_subscriptions`
WHERE platform_user_id = @pid AND is_active;

-- (б) состояние подписки на ИСТОРИЧЕСКУЮ дату D
SELECT * FROM `…ai_analysis_us.mart_subscription_periods`
WHERE platform_user_id = @pid
  AND valid_from <= @D AND (valid_to IS NULL OR valid_to > @D);

-- (в) СМЕНА ПОДПИСКИ — каждая строка истории уже и есть смена; план "до/после" одной оконкой
SELECT master_user_id, platform_user_id, valid_from AS changed_on,
       LAG(product_type) OVER w AS from_plan, product_type AS to_plan, status
FROM `…ai_analysis_us.mart_subscription_periods`
WINDOW w AS (PARTITION BY platform_user_id, app_name, original_transaction_id ORDER BY valid_from)
QUALIFY from_plan IS DISTINCT FROM to_plan;

-- (г) СМЕНА ПЛАТФОРМЫ — у мастера появился platId на другой платформе / ушёл старый
SELECT master_user_id, platform, platform_user_id, valid_from AS linked_on, valid_to AS unlinked_on, is_deleted
FROM `…ai_analysis_us.mart_master_platform_link_periods`
WHERE master_user_id = @mid
ORDER BY platform, valid_from;
```

Именование консистентно house-стилю: `mart_*` + суффикс `_periods` = SCD-2 период-таблица (как Playfair `subs_user_subscriptions_periods`); `v_*` = read-вьюха. Никаких `_history` вперемешку с `_periods`.

## Build procedures (warehouse routines)

Транзформ-SQL живёт в embedded `Warehouse/Sql/Routines/*.sql`, деплой repeatable `CREATE OR REPLACE` в ordinal-порядке имён (`build_*` сортируется до `rebuild_warehouse`), потом `CALL` из оркестратора (`BigQueryRoutineDeployer.cs:30`). Добавляем две новые процедуры; обе строят таблицу через `CREATE TABLE IF NOT EXISTS` и затем делают дельту в два шага (close → insert).

### Новые рутины

| Файл (embedded) | Процедура | Источник снимка | Где `CALL` |
|---|---|---|---|
| `Warehouse/Sql/Routines/build_master_platform_link_periods.sql` | `build_master_platform_link_periods` | `mart_master_platform_links` | `rebuild_warehouse` (после `build_master_marts`) — snapshot-каденция |
| `Warehouse/Sql/Routines/build_subscription_periods.sql` | `build_subscription_periods` | `mart_account_subscriptions` | scheduled query (после `build_account_subscriptions`, рядом с `build_account_current_plan`) — event-каденция |

`OPTIONS(strict_mode = FALSE)` на обеих (источники/таблицы резолвятся в CALL-time, как у соседних процедур, `build_master_marts.sql:6`).

### Дельта-логика (одинаковая, на примере link-таблицы)

```sql
CREATE OR REPLACE PROCEDURE `{project}.{dataset}.build_master_platform_link_periods`()
OPTIONS (strict_mode = FALSE)
BEGIN
  -- 1. self-owned DDL (MERGE-цель не может быть CREATE OR REPLACE — иначе теряем историю)
  CREATE TABLE IF NOT EXISTS `{project}.{dataset}.mart_master_platform_link_periods` (
    master_user_id STRING, platform_user_id STRING, platform INT64, product STRING,
    public_id STRING, is_first_link BOOL, link_created_at TIMESTAMP,
    valid_from DATE, valid_to DATE, is_current BOOL, is_deleted BOOL, row_hash STRING, built_at TIMESTAMP
  ) PARTITION BY valid_from CLUSTER BY platform_user_id;

  -- свежий снимок + row_hash отслеживаемых колонок
  CREATE TEMP TABLE snap AS
  SELECT master_user_id, platform_user_id, platform, product, public_id, is_first_link, created_at AS link_created_at,
         TO_HEX(MD5(FORMAT('%t|%t', is_first_link, public_id))) AS row_hash
  FROM `{project}.{dataset}.mart_master_platform_links`;

  -- 2. ЗАКРЫТЬ открытые версии, которые изменились ИЛИ исчезли
  UPDATE `{project}.{dataset}.mart_master_platform_link_periods` T
  SET valid_to = CURRENT_DATE(), is_current = FALSE,
      is_deleted = NOT EXISTS (SELECT 1 FROM snap S
        WHERE S.master_user_id=T.master_user_id AND S.platform_user_id=T.platform_user_id
          AND S.platform=T.platform AND S.product=T.product)
  WHERE T.valid_to IS NULL
    AND NOT EXISTS (SELECT 1 FROM snap S
      WHERE S.master_user_id=T.master_user_id AND S.platform_user_id=T.platform_user_id
        AND S.platform=T.platform AND S.product=T.product AND S.row_hash=T.row_hash);

  -- 3. ВСТАВИТЬ новые открытые версии для новых/изменённых ключей (у изменённых открытая только что закрыта)
  INSERT `{project}.{dataset}.mart_master_platform_link_periods`
  SELECT S.*, CURRENT_DATE() AS valid_from, CAST(NULL AS DATE) AS valid_to,
         TRUE AS is_current, FALSE AS is_deleted, S.row_hash, CURRENT_TIMESTAMP() AS built_at
  FROM snap S
  WHERE NOT EXISTS (SELECT 1 FROM `{project}.{dataset}.mart_master_platform_link_periods` T
    WHERE T.valid_to IS NULL AND T.master_user_id=S.master_user_id AND T.platform_user_id=S.platform_user_id
      AND T.platform=S.platform AND T.product=S.product);
END;
```

Идемпотентность: повторный прогон в тот же день со старым снимком ничего не закрывает (шаг 2: `row_hash` совпадает с уже открытой версией) и ничего не вставляет (шаг 3: открытая версия есть). `build_subscription_periods` — тот же скелет, ключ `(master_user_id, platform_user_id, app_name, original_transaction_id)`, `row_hash` по `product_type/status/is_active/is_trial/auto_renew_enabled`, фильтр `WHERE platform_user_id IS NOT NULL` на снимке.

### Wiring

- `rebuild_warehouse.sql` (`:30`) — добавить `CALL build_master_platform_link_periods();` сразу после `CALL build_master_marts();`.
- Scheduled query подписок (тот, что сейчас `CALL build_sku_mapping(); CALL build_account_subscriptions(); CALL build_account_current_plan();`) — добавить `CALL build_subscription_periods();` после `build_account_subscriptions` (до или после `build_account_current_plan` — независимы).
- **Никаких новых вьюх** — «текущее» отдают существующие снимок-марты; `build_views.sql` не трогаем.

## Lifecycle

SCD-2 переходы (дневная гранулярность). Поведение дельты на каждое изменение исходного снимка:

| Триггер (между прогонами) | Поведение |
|---|---|
| Новый ключ `(master, platId, …)` появился | INSERT открытой версии (`valid_from=today`, `is_current=TRUE`, `is_deleted=FALSE`) |
| Отслеживаемое поле изменилось (`is_first_link`, `status`, `product_type`, `is_active`…) | Закрыть старую открытую (`valid_to=today`, `is_current=FALSE`) + INSERT новой открытой |
| Ключ исчез из снимка (связь убрана / `masterUser.DeletedAt` / подписка перестала резолвиться) | Закрыть открытую (`valid_to=today`, `is_deleted=TRUE`); новой версии нет |
| Изменилось только не-hashed поле (`expires_at`, `link_created_at`) | Ничего — версия не дробится (намеренно, чтобы избежать ежедневного churn) |
| `is_active` флипнул в `FALSE` по истечении периода | Новая версия (флип в hash) — фиксирует дату, когда подписка стала неактивной |
| Повторный прогон в тот же день (тот же снимок) | No-op (идемпотентно) |
| `masterUser` так и не существовал (no-master подписка) | В sub-таблице `master_user_id=NULL`, ключ всё равно валиден через `platform_user_id` |

## Docs to Update

- `Local.Docs/Backend/Storage/bigquery.md` — добавить `mart_master_platform_link_periods` / `mart_subscription_periods` (+ вьюхи) в инвентарь `ai_analysis_us`, с пометкой SCD-2 / бессрочная ретенция.
- `Local.Docs/Backend/Storage/bigquery-sources.md` — упомянуть period-таблицы как источник для будущего Stellan-экспорта.
- `Local.Docs/features/WEB-1638/README.md` — снять чекбоксы Plan по мере реализации; зафиксировать future-step Stellan-экспорта.
