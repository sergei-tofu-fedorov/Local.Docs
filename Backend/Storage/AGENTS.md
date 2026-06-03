Storage — data-store inventory
==============================

**Purpose.** A fast, agent-first inventory of **every data store** across the backend workspace: what exists, in which environment/project, who writes it, how it's migrated, and the key objects + conventions. Read this index first, then open the per-type file for detail.

**Scope vs. other docs.**
- *This folder* = store-level infra inventory (datasets, databases, schemas, buckets; env/location; config keys; write paths; key objects + conventions). Optimised for "where does X live and how do I read/write it?"
- *`Backend/Persistence.md`* = the template for **deep per-entity field schemas**. When you need full field lists, follow the per-service link / code, not this folder.
- Don't duplicate field-level schemas here — link to the owning code.

**How to use (agent).** Scan the index → open `bigquery.md` / `mongo.md` / `postgres.md` / `gcs.md` → jump to the store's section. Each store section: header (type · env/location · owner · config key · write path) → objects table → links.

**Confidence.** Verified against repo code on 2026-05-30 with `file:line` citations in each file. `TODO` = genuinely unconfigured/unknown (e.g. prod hosts supplied at deploy time). Re-verify against code before relying on a `TODO` line.

Index
-----

| Store | Type | Env / location | Owner (writer) | Config key | Detail |
|---|---|---|---|---|---|
| `ai_analysis_v2` | BigQuery | test=`invoicesapp-project-test` · prod=deploy-time (not in config) | `Tofu.AI.Backend` | `Analyses:BigQuery` | [`bigquery.md`](bigquery.md) |
| `invoicesDB` (BFF) | MongoDB | dev=`localhost:27017` · prod=TODO | `Invoices.Backend` | `ConnectionStrings:MongoDb` | [`mongo.md`](mongo.md) |
| `invoicesDB` (Tofu.Invoices) | MongoDB | dev=`localhost:27017` · prod via Data Federation | `Tofu.Invoices.Backend` | `ConnectionStrings:MongoDb` | [`mongo.md`](mongo.md) |
| `jobs` schema (FSM) | PostgreSQL | dev=`localhost:5432/postgres` · prod=TODO | `Invoices.Backend` | `Jobs:ConnectionString` | [`postgres.md`](postgres.md) |
| `notifications` schema | PostgreSQL | dev=`localhost:5432/postgres` · prod=TODO | `Invoices.Backend` | `Notifications:ConnectionString` | [`postgres.md`](postgres.md) |
| `tofu_invoices` (event store) | PostgreSQL | dev=`localhost:5432/tofu_invoices` · prod=TODO | `Tofu.Invoices.Backend` | `ConnectionStrings:pgsql_db` | [`postgres.md`](postgres.md) |
| `tofu_ai` / `analyses` schema (Hangfire) | PostgreSQL | dev=`localhost:5432/tofu_ai` · prod=TODO | `Tofu.AI.Backend` | `ConnectionStrings:Analyses` | [`postgres.md`](postgres.md) |
| `tofu_auth` | PostgreSQL | dev=`localhost/tofu_auth` · prod=TODO | `Tofu.Auth.Backend` | `ConnectionStrings:pgsql_db` | [`postgres.md`](postgres.md) |
| `tofu_payments` (PaymentOrders) | PostgreSQL | prod=TODO | Tofu Payments (external) | — | [`postgres.md`](postgres.md) |
| GCS — `contents`/`temp_contents`/`tofu-bdui*` | Object storage | buckets | `Invoices.Backend` | `ContentsService:*` | [`gcs.md`](gcs.md) |
| GCS — chat context | Object storage | bucket | `Tofu.AI.Backend` | `Storage:ServiceAccountKeyPath` | [`gcs.md`](gcs.md) |

Cross-service reads
-------------------

Stores one service **reads but does not own** (worth knowing for blast-radius):
- `Tofu.AI.Backend` → the four source Mongo collections (Federation in prod), via `ConnectionStrings:Mongo`.

GCP projects
------------

- **prod** = `inv-project` · **test** = `invoicesapp-project-test`.
- `ai_analysis_v2` is wired to `invoicesapp-project-test` (`appsettings.json`); **no prod project is configured** in code — prod is supplied at deploy time (ADC / env).

Maintenance
-----------

- Update the per-type file when a store/dataset/collection/schema/bucket is added, renamed, or its migration path changes.
- Keep entries store-level; push field-level detail to the linked code.
- Clear a `TODO` only with a code/config citation.
