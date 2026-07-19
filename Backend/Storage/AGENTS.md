Storage — data-store inventory
==============================

**Purpose.** A fast, agent-first inventory of **every data store** across the backend workspace: what exists, in which environment/project, who writes it, how it's migrated, and the key objects + conventions. Read this index first, then open the per-type file for detail.

**Scope vs. other docs.**
- *This folder* = store-level infra inventory (datasets, databases, schemas, buckets; env/location; config keys; write paths; key objects + conventions). Optimised for "where does X live and how do I read/write it?"
- *`Backend/Persistence.md`* = the template for **deep per-entity field schemas**. When you need full field lists, follow the per-service link / code, not this folder.
- Don't duplicate field-level schemas here — link to the owning code.

**How to use (agent).** Scan the index → open `bigquery.md` / `mongo.md` / `postgres.md` / `gcs.md` → jump to the store's section. Each store section: header (type · env/location · owner · config key · write path) → objects table → links.

**Composing BigQuery analytics queries?** Go straight to [`bigquery-agent-guide.md`](bigquery-agent-guide.md) — the query-first **core guide** to `ai_analysis_us` / `amplitude_us` / `payments_us` / `stripe_us`: identity joins (account ↔ platform user ↔ master), document & Stripe join keys, partition/cluster cost rules, routing table, ready SQL cookbook. The heavy per-dataset column catalogs + enum decodes + caveats are split into one file each — [`-ai_analysis_us`](bigquery-agent-guide-ai_analysis_us.md) · [`-amplitude_us`](bigquery-agent-guide-amplitude_us.md) · [`-payments_us`](bigquery-agent-guide-payments_us.md) · [`-stripe_us`](bigquery-agent-guide-stripe_us.md) — read only the one the core routing table points you to.

**Confidence.** Verified against repo code on 2026-05-30 with `file:line` citations in each file. `TODO` = genuinely unconfigured/unknown (e.g. prod hosts supplied at deploy time). Re-verify against code before relying on a `TODO` line.

Index
-----

| Store | Type | Env / location | Owner (writer) | Config key | Detail |
|---|---|---|---|---|---|
| `ai_analysis_us` | BigQuery | prod=`inv-project` · stage=`invoicesapp-project-test` | `Tofu.AI.Backend` | `Analyses:BigQuery` | [`bigquery.md`](bigquery.md) · [query guide](bigquery-agent-guide.md) |
| `amplitude_us` (Amplitude events bridge, iOS 213333, rolling 90d) | BigQuery | prod=`inv-project` · stage=`invoicesapp-project-test` | `Tofu.AI.Backend` (amplitude-export tick) | `Analyses:Amplitude` + `BigQuery:AmplitudeDatasetId` | [query guide](bigquery-agent-guide.md) |
| `payments_us` (Tofu Payments orders mirror) | BigQuery | prod=`inv-project` | `Tofu.AI.Backend` (payment-orders tick) | `Analyses:PaymentOrders` | [query guide](bigquery-agent-guide.md) |
| `ml_training_us` (ML training data, task-prefixed tables) | BigQuery | prod=`inv-project` (pipeline) · test=prototype sandbox | FS-1335 pipeline (future: `Tofu.AI.Backend`) | — | [`bigquery.md`](bigquery.md) |
| BQ live survey (all datasets in `inv-project` / test, incl. analytics, GA4, pubsub_audit) | BigQuery | prod=`inv-project` · test=`invoicesapp-project-test` | mixed (analytics pipelines, Firebase, Pub/Sub, Tofu.AI) | — | [`bigquery-sources.md`](bigquery-sources.md) |
| `invoicesDB` (BFF) | MongoDB | dev=`localhost:27017` · prod=TODO | `Invoices.Backend` | `ConnectionStrings:MongoDb` | [`mongo.md`](mongo.md) |
| `invoicesDB` (Tofu.Invoices) | MongoDB | dev=`localhost:27017` · prod via Data Federation | `Tofu.Invoices.Backend` | `ConnectionStrings:MongoDb` | [`mongo.md`](mongo.md) |
| `jobs` schema (FSM) | PostgreSQL | dev=`localhost:5432/postgres` · prod=TODO | `Invoices.Backend` | `Jobs:ConnectionString` | [`postgres.md`](postgres.md) |
| `notifications` schema | PostgreSQL | dev=`localhost:5432/postgres` · prod=TODO | `Invoices.Backend` | `Notifications:ConnectionString` | [`postgres.md`](postgres.md) |
| `tofu_invoices` (event store) | PostgreSQL | dev=`localhost:5432/tofu_invoices` · prod=TODO | `Tofu.Invoices.Backend` | `ConnectionStrings:pgsql_db` | [`postgres.md`](postgres.md) |
| `tofu_ai` / `analyses` schema (Hangfire) | PostgreSQL | dev=`localhost:5432/tofu_ai` · prod=TODO | `Tofu.AI.Backend` | `ConnectionStrings:Analyses` | [`postgres.md`](postgres.md) |
| `tofu_ai` / `investigations` schema (FS-1111) | PostgreSQL | dev=`localhost:55333/tofu_ai` (compose) · prod=not deployed | `Tofu.AI.Backend` | `ConnectionStrings:Investigations` | [`postgres.md`](postgres.md) |
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
- `ai_analysis_us` config defaults to `invoicesapp-project-test` (`appsettings.json:29`); prod `ProjectId` is supplied at deploy time (secret/env). Stage-only `ai_analysis`/`ai_analysis_v2` are obsolete predecessors pending deletion (see `bigquery.md`).

Maintenance
-----------

- Update the per-type file when a store/dataset/collection/schema/bucket is added, renamed, or its migration path changes.
- Keep entries store-level; push field-level detail to the linked code.
- Clear a `TODO` only with a code/config citation.
