# Playfair DWH — existing Tofu data in BigQuery

How the Playfair data warehouse (`C:\Git\Work\Playfair.DWH.BigQuery`) currently ingests, transforms, and consumes Tofu-related data. Investigated 2026-05-21.

This matters to WEB-1523 because (a) some of the signals FSM-fit needs may already be in BigQuery, (b) the `account_id → user_id` bridge Playfair maintains could let us join FSM-fit results back to attribution / LTV cohorts, and (c) the team has already solved the "load Mongo invoices into BQ" plumbing — currently disabled but the code exists.

**Stack:** Dagster (orchestration) + dbt (transformations) + BigQuery (storage). Project lives at `C:\Git\Work\Playfair.DWH.BigQuery`. BigQuery project is `playfair-project`, dataset `data_layer` is the landing zone for source data.

---

## Decision (summary, before the detail)

**What we can reuse from Playfair DWH today, without changes:**
- Account → user identity bridge (`data_layer.mongo_invoices_account_identifiers`): maps `accounts._id` ↔ `UserId / Idfa / AppsflyerId / FirebaseId / VendorId`. Refreshed daily. **Directly usable** if FSM-fit ever needs to cross-reference attribution/LTV cohorts by accountId.
- Tofu Payments postgres dump (`data_layer.tofu_postgres_payment_orders`): full PaymentOrders table, refreshed daily. **Directly usable** for revenue / subscription signal per account.

**What is schema-defined in Playfair but currently NOT loaded** (the loaders are commented out in `mongo_source.py:354-364`):
- `invoices` (item text, totals, status, dates, Client struct) — **the core FSM-fit signal source**
- `accounts` (currency, timezone, store)
- `accountData` (catalog items)
- `estimates`
- `payments` (received payments inside invoices)
- `authenticatedPaymentTypes`

**Implication for WEB-1523:** the signal aggregation in `Tofu.AI.Backend` is doing roughly what the disabled Mongo streams would have done — reading the same collections directly from `invoicesDB`. If we wanted to avoid duplicating that read path, an alternative architecture is to **enable the dormant Playfair streams** and have `Tofu.AI.Api`'s Hangfire jobs consume from BigQuery `data_layer.mongo_invoices_*` tables instead of from Mongo directly. Not recommended for v1 (extra coupling to the Playfair pipeline, daily refresh instead of on-demand, harder to PII-redact per-analysis) — but worth knowing the option exists.

---

## Data sources — what is ingested

### 1. Tofu Payments (Postgres) → BigQuery

**Loader:** `src/dagster/jobs/tofu_postgres_job.py` + `src/dagster/resources/sources/tofu_postgres/tofu_postgres_source.py`

| Aspect | Value |
|---|---|
| Source DB | Postgres, `tofu_payments` database, schema `public` (Tofu Payments service backend) |
| Source table | `public."PaymentOrders"` (camelCase column names — converted to snake_case on load) |
| Strategy | Incremental, cursor-based on `UpdatedAt`; 2-day lookback window when run for today |
| Schedule | Daily at 3:05 UTC (`tofu_postgres` Dagster job, `tofu_postgres_factory`) |
| Destination | BigQuery `playfair-project.data_layer.tofu_postgres_payment_orders` |
| Write mode | DELETE-then-APPEND for the partition window (no MERGE) |
| Job tag | `tofu_postgres` (used as dbt selector for downstream models) |

**Columns ingested** (from `TofuPostgresPaymentOrdersStream.get_schema`):

```
id              integer    External payment-order PK
external_id     text
status          integer    (3 = "paid" — see stripe_connect_like_subz_events filter)
account_id      text       FK to Mongo accounts._id (linkage column)
payment_provider integer
psp_account_id  text       The Stripe Connect connected-account id (per merchant)
psp_id          text       PSP transaction id (used as _unique_key downstream)
entity_type     integer
entity_id       text
amount          numeric    Gross amount (charged to client)
currency_code   integer
psp_additional_infos jsonb  Contains product-key ∈ {invoices, payments} mapped → app_name
created_at      timestamp
updated_at      timestamp  Cursor column
fee_amount      numeric    Tofu's take (used as `revenue_net` downstream)
product_description text
product_name    text
client_fee_amount   numeric
_requested_at   datetime   Added by loader
```

### 2. MongoDB invoicesDB → BigQuery

**Loader:** `src/dagster/jobs/mongo_invoices_job.py` + `src/dagster/resources/sources/mongo/mongo_source.py`

| Aspect | Value |
|---|---|
| Source DB | MongoDB, `invoicesDB` (the Tofu invoices Mongo cluster) |
| Strategy | Incremental for most streams, keyed on `CreatedTime` OR `ModifiedTime` (records can have modified < created, so cursor is dual) |
| Schedule | Daily at 00:05 PT (`mongo_invoices` Dagster job) |
| Destination prefix | `playfair-project.data_layer.mongo_invoices_*` |
| Grant | `SELECT` granted to `analyst` role on load |
| dbt selector | `mongo_invoices` |

**Streams defined in code** (`src/dagster/resources/sources/mongo/mongo_source.py`):

| Stream class | Collection | Status today | PII redaction in loader |
|---|---|---|---|
| `MongoAccountIdentifiersStream` | `accountIdentifiers` | **ENABLED — actively loaded** | none (no PII in this collection) |
| `MongoAccountDataStream` | `accountData` | DISABLED (commented out) | excludes `Data.items.{address,email,name,phone}` |
| `MongoAccountsStream` | `accounts` | DISABLED | excludes `BusinessName`, `Contacts` |
| `MongoAuthenticatedPaymentTypesStream` | `authenticatedPaymentTypes` | DISABLED | excludes `Items.Items.{Email,AccountId}` |
| `MongoEstimatesStream` | `estimates` | DISABLED | excludes `Client.{Address,Email,Name,Phone}`, `Notes`, `Items` |
| `MongoInvoicesStream` | `invoices` | DISABLED | `Client` struct values are MD5-hashed (except `CatalogId`) before write |
| `MongoPaymentsStream` | `payments` | DISABLED | none |

Only `MongoAccountIdentifiersStream` is in the active streams list (`mongo_source.py:354-364`). The other six are uncommented historical streams. Schemas are still maintained in `schemas_mongo/*.py`, suggesting they were loaded in the past and could be re-enabled.

**`mongo_invoices_account_identifiers` schema** (the one that is actively loaded):

```
_id           str   Mongo _id (= accounts._id in invoicesDB)
UserId        str   The user-facing Tofu user id (used as linkage in downstream user_id_pairs)
Idfa          str   iOS advertising id
AppsflyerId   str   AppsFlyer device id
FirebaseId    str   Firebase install id
VendorId      str   iOS vendor id
```

**`mongo_invoices_invoices` schema** (defined but NOT loaded today; would deliver if enabled):

```
_id, Id, Version, AccountId, Date, Number, Status, PaymentDetails, Notes,
SubtotalAmount, DiscountAmount, TaxAmount, TotalAmount,
CreatedTime, ModifiedTime, DueDays, TotalDue, CreatedOn, DueDateStatus,
IsDeleted, MailStatus, MailStatusErrorMessage, ProductKey,
Tax: { Type, PercentValue, Name },
Client: { Phone, CatalogId, Email, Address, Name },     # MD5-hashed on load (except CatalogId)
Discount: { Type, Value },
ReceivedPayments: [string],
Items: [ { UnitType, UnitPrice, Quantity, Name, IsTaxApplied,
           Discount: {...}, Details, Description, CatalogId } ]
```

This is essentially the FSM-fit input shape — `Items[].Name/Description/Details`, `Client.CatalogId`, totals, status, dates, `ProductKey`. If we ever wanted FSM-fit's signal aggregation to read from BigQuery instead of Mongo, this is the table to re-enable.

### 3. Other Tofu-adjacent tables referenced

- `data_layer.mongo_invoices_account_to_stripe_ids` — referenced by `dbt/models/stripe_connect/src/src_mongo_invoices_account_to_stripe_ids.sql`. Source loader is **not** in the visible Mongo streams — likely populated by Fivetran or a historical job. Maps Mongo `account_id ↔ stripe_id`.

---

## Flow — how the data moves

```
Tofu Payments PG (PaymentOrders)              MongoDB invoicesDB
        │                                         │
        │ tofu_postgres Dagster job               │ mongo_invoices Dagster job
        │ (daily 03:05 UTC, cursor=updated_at)    │ (daily 00:05 PT)
        ▼                                         ▼
data_layer.tofu_postgres_payment_orders   data_layer.mongo_invoices_account_identifiers
        │                                  │  (other mongo_invoices_* tables DISABLED)
        │                                  │
        └────────────┬─────────────────────┘
                     ▼
       dbt: stripe_connect_like_subz_events
       (JOIN orders.account_id = identifiers._id,
        filter status=3, extract product-key from psp_additional_infos,
        emit as subscription_paid events in subz_events schema)
                     │
                     ▼
              dbt: subz_events
   (UNION of subz_events_original + stripe_connect_like_subz_events + subs_events_from_af)
                     │
        ┌────────────┼──────────────────────────┬──────────────────────┐
        ▼            ▼                          ▼                      ▼
   LTV cohorts   user_payments_invoices   amplitude_users_in_   periodic_data_checks
   (daily/wk/mo)  (attributed revenue,   experiments_clean      (data quality per
                  apps: invoices,         (AB testing)            app_name)
                  invoices_android,
                  tofu_web,
                  field_service)
                     │
                     ▼
           finance_invoices_reports job
           (monthly, exports costs+paids per app to Google Sheets,
            apps: tofu_web, tofu_ios, tofu_pay_ios, expenses_ios,
                  mileage_ios, invoices_ios, invoices_android,
                  field_service_ios)
```

**Diagram source:** `src/dagster/dbt/models/bigquery_import/bigquery_import_dependency_diagram.md` — section "STRIPE CONNECT PATH" (lines 233-263) shows the canonical flow.

---

## Key transform: `stripe_connect_like_subz_events.sql`

The load-bearing dbt model that turns Tofu Payments postgres data into Playfair's canonical event shape. Located at `src/dagster/dbt/models/bigquery_import/stripe_connect/stripe_connect_like_subz_events.sql`.

What it does:

1. **JOIN** `tofu_postgres_payment_orders` to `mongo_invoices_account_identifiers` on `account_id = _id` — this is how the account-keyed PaymentOrders gets resolved to a Playfair-style `user_id` (with the Idfa/AppsflyerId attached for attribution).
2. **FILTER** `status = 3` (paid orders only).
3. **EXTRACT** the `product-key` field from `psp_additional_infos` JSONB to determine which Tofu product the payment is for:
   - `product-key = 'invoices'` → `app_name = 'invoices'`, `app_id = 'id1314873764'`
   - `product-key = 'payments'` → `app_name = 'tofu_pay'`, `app_id = 'id6469622086'`
   - any other value → row dropped (`WHERE app_name is not null`)
4. **EMIT** rows in the `subz_events` schema with `event_name = 'subscription_paid'`, `revenue = fee_amount` (Tofu's take, not the gross), gross stored as `_stripe_connect_fee_amount` in `event_params`.
5. **UNION** with the rest of `subz_events` (App Store / Play Store events from `subz_events_original`, AppsFlyer events from `subs_events_from_af`).

From there it flows into the rest of the LTV / retention / AB testing pipeline like any other subscription event.

---

## Downstream consumers — the "results"

What the Tofu data actually drives in Playfair:

| Consumer | Where | What it does |
|---|---|---|
| **LTV cohort marts** | `dbt/models/ltv_cohorted_layer/ltv_cohorted_data_{daily,weekly,monthly}.sql` and `dbt/models/ltv_sbg_layer/*` | Per-cohort LTV curves; Tofu apps appear as `app_bundle ∈ {tofu, tofu_pay, invoices, invoices_android, tofu_web, field_service}`. Used in Looker Studio dashboards. |
| **Attributed revenue** | `dbt/models/user_id_pairs/post_group/attributed_revenue/user_payments_invoices.sql` | Filters revenue events to `app_name in ('invoices', 'invoices_android', 'tofu_web', 'field_service')`. Materialized in `external` schema, granted to `external_stellans` role. Joins campaign/ad-group/ad metadata. Likely the model that feeds the per-app revenue dashboards. |
| **AB testing** | `dbt/models/amplitude_daily/invoices_experiments.sql` | Filters `amplitude_users_in_experiments_clean` to invoice apps. Materialized in `external` schema, granted to `external_stellans`. |
| **Periodic data checks** | `dbt/models/periodic_data_checks/per_date/per_app/compare_metrics_per_date_{tofu,tofu_pay,invoices,invoices_android}.sql` (×2 variants) | Per-app data quality / drift checks; auto-generated. |
| **Finance reports** | `src/dagster/jobs/finance_invoices_reports.py`, monthly cron | Per-app costs + paid-users export to two Google Sheets (`TOFU_COSTS_SPREEDSHEET_ID`, `TOFU_PAIDS_SPREEDSHEET_ID`). Covers `tofu_web`, `tofu_ios`, `tofu_pay_ios`, `expenses_ios`, `mileage_ios`, `invoices_ios`, `invoices_android`, `field_service_ios`. Queries `ods_layer.ad_spend_low_level` (costs) and `dev_analyst.subz_user_payments` (paid users). |
| **Google Ads / MS Ads conversions** | `dbt/models/google_clicks/google_clicks_conversions_unpivot_invoices.sql`, `invoices_conversion.sql`, `subselects_to_display_tests_in_elementary/google_clicks_conversions_shares_{tofu,tofu_pay,invoices,invoices_android}.sql` | Tofu/invoices conversions exported to Google Ads (paid attribution loop). |

---

## App taxonomy (Playfair's view of Tofu apps)

From `dbt/models/dictionaries/app_names.sql`. The IDs Playfair uses everywhere:

| `app_name_root` | `app_name` | Display | `app_id` | Platform |
|---|---|---|---|---|
| tofu | tofu | Tracker | id6444800065 | ios |
| tofu_pay | tofu_pay | Tofu Pay | id6469622086 | ios |
| tofu_web | tofu_web | Tofu Web | tofu_web | web |
| invoices | invoices | Invoices | id1314873764 | ios |
| invoices | invoices_android | Invoices Android | com.tofu.invoices | android |
| field_service | field_service | Tofu Field Service | id6748010839 | ios |
| expenses | expenses | Expenses | id6443700019 | ios |
| mileage | mileage | Mileage | id6448111470 | ios |

Note `tofu` (Tracker) is the Time Tracker app, separate from `tofu_pay` and the FSM (Field Service) app. The WEB-1523 audience — "invoice-only users to be proposed FSM" — is users on `invoices` / `invoices_android` / `tofu_web` who are not yet on `field_service`.

---

## What is NOT in Playfair DWH (gaps for WEB-1523)

For FSM-fit specifically, the signals we need that Playfair does **not** currently surface in BigQuery:

- **Invoice line items** (`Items[].Name/Description/Details`) — schema-defined in `MongoInvoicesStream` but stream is DISABLED. This is the load-bearing signal for FSM-fit (item text → industry inference + service-vs-product cues).
- **Account business profile** (`accounts.BusinessName`, `accounts.Contacts`) — actively excluded from the existing `MongoAccountsStream` (PII), and that stream is DISABLED anyway.
- **Catalog items** (`accountData.Data.items.*`) — schema defined, stream DISABLED.
- **Repeat-client patterns** — derivable from invoices but the underlying invoice rows are not in BQ.
- **Estimate behavior** — `MongoEstimatesStream` DISABLED.

Per [`analyses/data-sources.md`](analyses/data-sources.md) the WEB-1523 plan reads these directly from Mongo via the BFF aggregator embedded in the `Tofu.AI.Api` pod (Hangfire jobs in-process — single-pod design), not from BigQuery. This avoids the 1-day staleness of the Playfair pipeline and the PII-hashing the Mongo loader applies (which would strip the exact item text we need before LLM redaction).

---

## Source files reference

| File | What it is |
|---|---|
| `src/dagster/jobs/tofu_postgres_job.py` | Dagster job pulling PaymentOrders from Tofu Payments PG into `data_layer.tofu_postgres_payment_orders` |
| `src/dagster/jobs/mongo_invoices_job.py` | Dagster job pulling enabled streams from `invoicesDB` Mongo into `data_layer.mongo_invoices_*` |
| `src/dagster/jobs/finance_invoices_reports.py` | Monthly finance export to Google Sheets for Tofu apps |
| `src/dagster/resources/sources/tofu_postgres/tofu_postgres_source.py` | PaymentOrders stream definition (incremental on `updated_at`, schema, 2-day lookback) |
| `src/dagster/resources/sources/mongo/mongo_source.py` | Mongo source + 7 stream classes (only AccountIdentifiers enabled in `mongo_source` instance at lines 354-364) |
| `src/dagster/resources/sources/mongo/schemas_mongo/*.py` | PyArrow schemas for each Mongo collection (incl. PII-hashing rules in `mongo_source.py:300-308`) |
| `src/dagster/resources/database_io.py` | `TofuPaymentsDB(SqlalchemyDatabaseResource)` connection class |
| `src/dagster/config/config.py` | `tofu_payments_db` connection dict (`default_database = 'tofu_payments'`) + `mongo_db_connection_string_invoices` |
| `src/dagster/dbt/models/bigquery_import/stripe_connect/stripe_connect_like_subz_events.sql` | The join+filter+map transform from PaymentOrders → `subz_events` shape |
| `src/dagster/dbt/models/mongo_invoices/src/` | dbt source views over `data_layer.mongo_invoices_*` |
| `src/dagster/dbt/models/stripe_connect/src/src_mongo_invoices_account_to_stripe_ids.sql` | Maps Mongo account ↔ Stripe id (source population path unclear — Fivetran?) |
| `src/dagster/dbt/models/dictionaries/app_names.sql` | Canonical Tofu app taxonomy (8 entries above) |
| `src/dagster/dbt/models/bigquery_import/bigquery_import_dependency_diagram.md` | The dependency diagram used in this doc |

## Open questions for the team

- Who owns the Playfair DWH? Worth a chat to confirm whether the disabled Mongo streams were turned off intentionally (cost? PII concerns? broken?) — affects whether we'd be allowed to re-enable them.
- Is `data_layer.mongo_invoices_account_to_stripe_ids` loaded by Fivetran, a legacy job, or manually? It is referenced but no loader is visible in the current code.
- Does Looker Studio or any PM-facing dashboard already aggregate per-account metrics from `subz_user_payments` that we could surface alongside FSM-fit results (e.g. for an "invoice-only users sorted by revenue × FSM-fit score" view)?
