# SKU Mapping — логика построения из событий (WEB-1620)

Ежедневный BigQuery-джоб собирает каталог SKU — **одна строка на `product_id`** — целиком из аналитических событий. Ручная таблица больше не нужна.

- **Источник:** события в `inv-project` (iOS, Android, Field Service, Web/Stripe).
- **Назначение:** `playfair-project.dbt_external.sku_mapping`.
- **Запуск:** ежедневно 09:00 UTC, под `playfair-invoices@inv-project`.

Используются события `subscription_paid` и `trial_started` из 5 таблиц, каждая помечается своим приложением:

| Таблица событий | `app_name` | Стор |
|---|---|---|
| `analytics.events` | `invoices` | App Store (iOS) |
| `analytics_android.events` | `invoices_android` | Play Store |
| `analytics.events_tofu-fieldservice` | `field_service` | App Store (iOS) |
| `analytics_web.events_invoices_stripe` + `..._tofu_stripe` | `tofu_web` | Stripe (web) |

## Откуда берутся события (Subz)

Таблицы iOS/Android/Field Service наполняет сервис **Subz** (`EventStream.Handler.BigQuery`, репо `C:\Git\Work\Subz`), стримя нормализованные события из Pub/Sub (App Store S2S / Google RTDN → обогащение → BigQuery). Web-таблицы пишет отдельный Stripe-пайплайн. Маппинг полей в `event_params`:

| event_param | Из Subz (`subscription_paid`) | Заметка |
|---|---|---|
| `product_id` | `Details.ProductId` | |
| `subscription_duration` | `Details.Duration.ToString()` | `1w`/`1m`/`1y` |
| `user_price` | `Details.BaseCurrencyPrice` | **нормализована в USD** (`currency_code=USD`); локальная — в `local_user_price` |
| `is_in_intro_offer_period` | `Details.OfferType == Introductory` | bool → `int_value` 0/1 |
| `transaction_id` / `original_transaction_id` / `store_country` / `is_initial_account` / `is_belong_purchaser` | соответств. `Details.*` | |

`trial_started` несёт только `product_id`, `subscription_duration` и флаги — **без цены и без `is_in_intro_offer_period`** (для app-store служит лишь сигналом наличия триала). `offer_metadata.trial_price` и `trial_duration` Subz для iOS/Android **не пишет** (отсюда их разреженность). События несут `Duration`, но не дату окончания.

## ⭐ Ключевой флаг: `is_in_intro_offer_period`

Вся платформенная логика цен строится на одном параметре:

> `= 1` — платёж по **скидочному вводному офферу**; `= 0` или `NULL` — **обычный полный** платёж (условие **no-intro**).

- **no-intro** (`= 0 OR IS NULL`) → реальная прайс-лист цена → идёт в `sub_price` (на обеих платформах).
- **intro** (`= 1`) → скидочная вводная цена. **Смысл флага различается по платформам** (его ставит Subz):
  - **App-store (iOS):** `1` = платный **introductory offer** (вводная цена, напр. $0.99 за первую неделю) → app-store `trial_price` = мода intro-цены.
  - **Stripe/web:** `1` = платёж **с купоном** (`Discount.CouponId`) или мульти-item, **не триал**; ID купона лежит в `promotional_offer_id`. На web `trial_price` этот флаг **не использует** (берётся `offer_metadata.trial_price`/наличие `trial_started`), а из `sub_price` купонные платежи просто исключаются.

⚠️ **Триалы Stripe сюда не попадают вообще:** триальный инвойс не порождает `subscription_paid` (ранний `return` в Subz) — триал виден только как событие `trial_started`. Поэтому `is_in_intro_offer_period=1` на web-строках читать как «купон», а не «триал».

`OR IS NULL` важен: на части событий/платформ флаг отсутствует. Трактуем `NULL` как «не интро» → отсутствующий флаг считается полной ценой, обычный платёж никогда не маркируется скидочным.

## Как используется `trial_started`

Несмотря на «используются события `subscription_paid` и `trial_started`», второй работает у́же — он **не несёт ни цены, ни `is_in_intro_offer_period`**, поэтому на расчёт цен не влияет. Из него берётся только:

- **Флаг бесплатного триала для web** (`tofu_web`): `IF(trial_started > 0, '0', NULL)` — единственное ценовое применение. Отвечает «есть ли у продукта бесплатный триал»: `0` (есть) против `NULL` (нет данных). Саму цену не даёт.
- **Источник `trial_period`** через `trial_duration` (`MAX(trial_dur)`): `trial_duration` приходит почти только на `trial_started` и разреженно → на практике `trial_period` чаще `0`.

Чего он **не** делает: не участвует в `sub_price`/`reg_price`; app-store `trial_price` его игнорирует (там — мода intro-цены из `subscription_paid`). Косвенно: продукт, виденный только в триалах, всё же попадёт в каталог с `sub_length` — но для `tofu_web` такая строка отсеется фильтром `reg_price IS NULL` (работает только для app-store).

## Поля

| Поле | Логика |
|---|---|
| **app_name** | Из какой таблицы пришло событие. |
| **product_id** | ID SKU из события. Ключ мёрджа. |
| **sub_length** | `subscription_duration` → **дни**: число × единица (`d=1, w=7, m=31, y=365`). `1w`→`7`, `1m`→`31`, `1y`→`365`. Неизвестная единица → как есть. |
| **trial_period** | `trial_duration` → дни (та же конвертация); если нет — `0` (**не NULL**). |
| **sub_price** | Полная цена — **зависит от платформы** (ниже). |
| **trial_price** | Интро/триал-цена — **зависит от платформы** (ниже). |

## 🔀 Различия платформ (главное)

### Web (`tofu_web`) — Stripe
Stripe-`product_id` = **одна фиксированная USD-цена**, шума нет — берём напрямую.
- **sub_price** = `MAX` no-intro `user_price` (значение одно).
- **trial_price** = `offer_metadata.trial_price ÷ 100` (центы→$); иначе `0`, если есть `trial_started`; иначе `NULL`.
- **Гард:** если полной (no-intro) цены ещё не видели (`reg_price IS NULL`) — строка **исключается** из источника (`WHERE NOT (tofu_web AND reg_price IS NULL)`). SKU не вставляем, пока не увидим реальную цену.

### App stores (`invoices` / `invoices_android` / `field_service`)
`user_price` варьируется по странам/валютам/промо — прямую цену брать нельзя, берём **моду** (самое частое значение).
- **sub_price** = **мода** no-intro `user_price` (топ по частоте, не-NULL); `NULL`, если no-intro цены не было.
- **trial_price** = **мода** intro `user_price`; иначе `0`.
- **Почему мода, не `MAX`:** `MAX` ловит дорогой валютный выброс; мода даёт реальную прайс-лист цену (сверено 14/14 со старым каталогом).

### Сводка

| | Web (`tofu_web`) | App stores |
|---|---|---|
| Источник цены | Stripe — фикс. USD | `user_price` — варьируется |
| `sub_price` | MAX no-intro | **мода** no-intro |
| `trial_price` | `trial_price/100`, иначе `0`/NULL | **мода** intro, иначе `0` |
| Нет полной цены | строка **выбрасывается** | строка остаётся, `sub_price` = NULL |
| `trial_price` при апдейте | **защищён** (не перетирается) | синхронизируется из событий |

### Купонные цены (web) — не входят в каталог, но извлекаемы

SKU-mapping купонные платежи Stripe игнорирует, но их можно достать из событий напрямую: `user_price` на `subscription_paid` с `is_in_intro_offer_period=1` — это **фактически списанная сумма после купона**, а `promotional_offer_id` = ID купона.

```sql
SELECT product_id, promotional_offer_id AS coupon,
       APPROX_QUANTILES(user_price, 2)[OFFSET(1)] AS coupon_price   -- медиана по (product, coupon)
FROM <web stripe events>  -- subscription_paid
WHERE is_in_intro_offer_period = 1 AND promotional_offer_id IS NOT NULL
GROUP BY product_id, coupon
```

Сравнение с регулярной модой даёт сам дисконт (пример прод-данных: купон `hRnpHxN5` → 17.99 → 1.79 ≈ −90% на первый месяц; `XTkamoax` → 29 → 19).

⚠️ Обязателен фильтр `promotional_offer_id IS NOT NULL`: `is_in_intro=1` ставится в Subz **по двум условиям** — купон **или** мульти-item инвойс (`Items.Count > 1`, в основном proration при смене плана). Второй случай купона не несёт, `promotional_offer_id` там пуст, а `user_price` — рваная прорейтенная сумма (не цена). Брать **медиану/моду** по `(product_id, coupon)`: это реализованная сумма платежа, а не правило купона (% vs fixed), и она плавает по длительности/прорейту.

## Upsert (MERGE), идемпотентность

Ключ — `product_id`. Повторный запуск не дублирует и не затирает данные.
- **NOT MATCHED → INSERT**: новый продукт — новая строка.
- **MATCHED → UPDATE** (строка сохраняется, аккуратная синхронизация без обнуления):
  - `trial_period` ← значение из событий **только если > 0** (`0`/NULL не понижает).
  - `sub_price` ← `COALESCE(event, existing)` — обновляется, но не обнуляется.
  - `trial_price` ← **только app-store**; **`tofu_web` защищён** (хранит ручные/Stripe-значения).

Второй запуск подряд вставляет **0** строк.

## Сервис-аккаунт и расписание

- **Имя джоба:** `Playfair invoices_products daily upsert`.
- **Тип:** BigQuery Scheduled Query, живёт в проекте `inv-project`.
- **Идентичность (runner):** `playfair-invoices@inv-project.iam.gserviceaccount.com`. Джоб исполняется и биллится в `inv-project`, пишет кросс-проектно в `playfair` (US↔US).
- **Расписание:** ежедневно, 09:00 UTC (каждые 24 ч).
- **Назначение в конфиге:** пустое — это DML `MERGE`, он пишет сам (без destination table / write disposition).
- **Доступы:** `roles/bigquery.dataViewer` на `inv-project` (`analytics`, `analytics_android`, `analytics_web`) для чтения событий; WRITER на `playfair-project.dbt_external` для записи в `sku_mapping`.
- **Стоимость:** ~5 ГБ сканируется за запуск (в основном `analytics.events`) ≈ **$0.025/день**.

## Схема

Каталожные колонки: `app_name, product_id, sub_length, trial_period, sub_price, trial_price`.
