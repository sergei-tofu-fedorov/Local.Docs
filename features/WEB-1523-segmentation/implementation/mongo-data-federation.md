# WEB-1523 — Mongo snapshot export → GCS → Data Federation

Operational setup for the read plane locked in [`../investigation/mongo-read-isolation.md`](../investigation/mongo-read-isolation.md) § Decision: `Tofu.AI.Api` reads `invoices` / `estimates` / `clients` / `accounts` from **periodic Atlas Cloud-Backup snapshots exported to a GCS bucket**, queried through an **Atlas Data Federation** endpoint — the live prod replica sets are never touched. This doc is the how-to for standing that up: the GCS bucket + IAM, the snapshot-export policy on each prod cluster, the Data Federation instance + storage config, and the partitioning/cost practices that keep federated scan billing sane.

> **Scope guardrail.** Infra wiring only — buckets, IAM, export policies, federation storage config. *What* gets aggregated (per-metric query plan, eligibility funnel, refresh cadence) is owned by [`../analyses/metrics.md`](../analyses/metrics.md); the *destination* BigQuery layout by [`storage.md`](storage.md); the service-side connection-string config by [`service.md`](service.md) § Q1. Those win on conflict. Collection names and aggregation pipelines are **unchanged** by anything here — only the connection string differs.

> **Status: DRAFT — needs review.** GCP project name, bucket name, the snapshot-inventory facts, and the billing owner are all still open (see [`../investigation/mongo-read-isolation.md`](../investigation/mongo-read-isolation.md) § Open questions). Commands below are templates, not yet run.

## ⚠️ Correction to read-isolation § Option 6

`mongo-read-isolation.md` framed the snapshot path as **"Atlas Data Lake snapshot + Data Federation"** — i.e. *Data Lake Pipelines*, which auto-extracted cluster snapshots into partition-indexed **Parquet** and queried them via federation. **Atlas Data Lake / Data Lake Pipelines is deprecated — end-of-life 2025-09-30** ([MongoDB docs](https://www.mongodb.com/docs/datalake/)). It is not an option for a service shipping after that date.

The supported replacement is two separate, GA building blocks wired together:

1. **Export Cloud Backup Snapshot** → writes each snapshot to a GCS bucket as **gzip Extended-JSON v2** (`.json.gz`), *not* Parquet, with **no automatic partition index**.
2. **Atlas Data Federation** → a federated instance maps the bucket paths to virtual collections you query over MQL.

Consequence for the plan: the "cheap batched-sweep over Parquet" economics in Option 6's pricing section **do not transfer** — exported JSON.gz is bulkier and lacks Parquet's columnar pushdown, so the per-TB-scanned concern is *worse*, not better. Partitioning is entirely on us (see § Best practices). This strengthens, not weakens, the scan-cost open question.

## Decision

- **Snapshot source.** Atlas **Export Cloud Backup Snapshot** on each prod cluster (`InvoicesCluster`, `Tofu.Invoices.Backend` Mongo), automated via an **export policy** (daily — matches the hourly-refresh / 24h-TTL budget in `analyses/metrics.md`). Format is fixed: gzip Extended-JSON v2.
- **One GCS bucket, cluster-prefixed.** Both clusters export into a single regional bucket in the WEB-1523 GCP project; Atlas's export path already namespaces by `<clusterName>`, so one bucket holds both cleanly. Region = same region as the Data Federation instance (colocation is required and avoids egress).
- **Atlas reaches GCS via Cloud Provider Access**, not static keys. Atlas generates a Google service account; we grant it `roles/storage.objectAdmin` on the bucket for the **export** side and the Data Federation instance reads with `roles/storage.objectViewer`. Same Atlas-managed SA can carry both grants.
- **Query the latest snapshot only.** Each export lands in a new `.../<snapshotTimestamp>/...` folder; a naïve federation path would union *every retained snapshot* → duplicate accounts × multiplied scan. We extract the snapshot timestamp as a **partition attribute** and the aggregator filters to the most recent — see § Pointing federation at the current snapshot. **Open question — load-bearing.**
- **GCS lifecycle rule** expires exported snapshots after N days (proposed 7) — caps storage cost and bounds the worst-case scan if a query forgets the timestamp filter.
- **Stage gets none of this.** Per `service.md` § Q1, stage `Tofu.AI.Api` uses a plain connection string to prod Mongo. Federation, export, and this whole doc are **prod-only**.

Everything below is supporting detail.

## Flow

```
┌──────────────────────┐   daily export policy    ┌─────────────────────────────┐
│ InvoicesCluster      │ ───────────────────────▶ │ GCS bucket                  │
│ (Atlas, Cloud Backup)│                           │ tofu-ai-mongo-snapshots-prod│
└──────────────────────┘                           │                             │
┌──────────────────────┐   daily export policy     │ /exported_snapshots/<org>/  │
│ Tofu.Invoices Mongo  │ ───────────────────────▶ │   <proj>/<cluster>/<initDate>/│
│ (Atlas, Cloud Backup)│                           │   <ts>/<db>/<coll>/*.json.gz │
└──────────────────────┘                           └──────────────┬──────────────┘
                                                                   │ Atlas-managed GCP SA
                                                                   │ (storage.objectViewer)
                                                                   ▼
                                              ┌─────────────────────────────────────┐
                                              │ Atlas Data Federation instance (GCP) │
                                              │ stores[] → databases[] → virtual     │
                                              │ collections: invoices/estimates/...  │
                                              └──────────────┬──────────────────────┘
                                                             │ mongodb:// FDI conn string
                                                             ▼
                                              ┌─────────────────────────────────────┐
                                              │ Tofu.AI.Api  IPayloadBuilder<T>      │
                                              │ (unchanged aggregation pipelines)    │
                                              └─────────────────────────────────────┘
```

## Part 1 — GCS bucket + Cloud Provider Access (IAM)

1. **Create the bucket** in the WEB-1523 GCP project, regional, in the region the Data Federation instance will live:
   ```bash
   gcloud storage buckets create gs://tofu-ai-mongo-snapshots-prod \
     --project=<WEB-1523-GCP-PROJECT> \
     --location=<REGION> \
     --uniform-bucket-level-access
   ```
2. **Create a GCP Cloud Provider Access role in Atlas** (Project Settings → Integrations → Configure Google Cloud → Create Google Cloud Service Account). Atlas provisions and manages a Google service account on its side and shows you its email. Via API:
   ```bash
   # create
   curl -s --digest -u "$PUB:$PRV" -X POST \
     "https://cloud.mongodb.com/api/atlas/v2/groups/$GROUP/cloudProviderAccess" \
     -H 'Content-Type: application/json' -d '{"providerName":"GCP"}'
   # → returns roleId + the Atlas-managed gcpServiceAccountForAtlas email
   ```
3. **Grant the Atlas SA access to the bucket.** Export needs write, federation needs read — both can hang off the same Atlas SA:
   ```bash
   # write — snapshot export
   gcloud storage buckets add-iam-policy-binding gs://tofu-ai-mongo-snapshots-prod \
     --member="serviceAccount:<ATLAS_GCP_SA_EMAIL>" --role="roles/storage.objectAdmin"
   # read — Data Federation (objectViewer is sufficient; objectAdmin already implies it,
   # so this explicit line is only needed if you split read/write across two SAs)
   gcloud storage buckets add-iam-policy-binding gs://tofu-ai-mongo-snapshots-prod \
     --member="serviceAccount:<ATLAS_GCP_SA_EMAIL>" --role="roles/storage.objectViewer"
   ```
4. **Authorize the role in Atlas** so it starts using the SA:
   ```bash
   curl -s --digest -u "$PUB:$PRV" -X PATCH \
     "https://cloud.mongodb.com/api/atlas/v2/groups/$GROUP/cloudProviderAccess/$ROLE_ID" \
     -H 'Content-Type: application/json' -d '{"providerName":"GCP"}'
   ```

> Prefer least privilege: if the platform team objects to `objectAdmin`, split into `roles/storage.objectCreator` (+ `objectViewer`) for the export SA and `objectViewer` for the federation SA.

## Part 2 — Snapshot export policy (per prod cluster)

Prereqs: cluster is a **paid tier** (export is unavailable on Free/Flex) with **Cloud Backup enabled**; acting user has **Project Owner** or **Project Backup Manager**. The export cannot include views or system collections — fine, we only read `invoices` / `estimates` / `clients` / `accounts`.

1. **Register the bucket as a Snapshot Export Bucket** (once per project), tying it to the Cloud Provider Access role from Part 1:
   ```bash
   curl -s --digest -u "$PUB:$PRV" -X POST \
     "https://cloud.mongodb.com/api/atlas/v2/groups/$GROUP/backup/exportBuckets" \
     -H 'Content-Type: application/json' -d '{
       "cloudProvider":"GCP",
       "bucketName":"tofu-ai-mongo-snapshots-prod",
       "roleId":"'"$ROLE_ID"'"
     }'   # → returns exportBucketId
   ```
2. **Attach an automated export policy** to each cluster's backup schedule (daily; `exportBucketId` from step 1). This makes Atlas auto-export every snapshot matching the frequency — no manual trigger. Set `useOrgAndGroupNamesInExportPrefix` deliberately (names are human-readable but mutable; UUIDs are stable — pick one and pin the federation path to it).
3. **Repeat for the second cluster.** Both point at the same `exportBucketId`; the `<clusterName>` path segment keeps them apart in the bucket.

**Exported layout** (this is the contract the federation config keys off — verify after the first export lands):
```
/exported_snapshots/<org>/<project>/<cluster>/<snapshotInitiationDate>/<timestamp>/
    <dbName>/<collectionName>/<shard>.<increment>.json.gz
    <dbName>/<collectionName>/metadata.json
  .complete                         # written last — marks the snapshot fully exported
```

## Part 3 — Data Federation instance + storage config

1. **Deploy a federated database instance on GCP**, in the **same region** as the bucket (colocation required; cross-cloud federation over GCS is not allowed). Project Owner required. The instance reads the bucket through the Atlas-managed GCP SA granted `objectViewer` in Part 1.
2. **Apply a storage config** mapping the bucket paths to virtual collections. Skeleton (per-collection `dataSources`; partition the snapshot timestamp out of the path so we can filter to the latest):
   ```jsonc
   {
     "stores": [
       {
         "name": "mongo-snapshots",
         "provider": "gcs",
         "region": "<REGION>",
         "bucket": "tofu-ai-mongo-snapshots-prod",
         "prefix": "exported_snapshots/<org>/<project>",
         "delimiter": "/"
       }
     ],
     "databases": [
       {
         "name": "invoices_db",
         "collections": [
           {
             "name": "invoices",
             "dataSources": [
               {
                 "storeName": "mongo-snapshots",
                 // capture cluster + snapshot timestamp as partition attributes so
                 // predicates on _snapshotTs prune to a single snapshot folder
                 "path": "/{_cluster string}/{_snapshotDate date}/{_snapshotTs date}/invoices_db/invoices/*",
                 "defaultFormat": ".json.gz"
               }
             ]
           }
           // estimates, clients, accounts → same shape, different trailing path
         ]
       }
     ]
   }
   ```
   Validate before applying: `db.runCommand({ storageValidateConfig: <config> })`, then `storageSetConfig`. (Atlas UI Visual Editor works too, but `provenanceFieldName`/partition attributes are easier via the JSON editor.)
3. **Hand `Tofu.AI.Api` the FDI connection string** (`mongodb://...@<fdi>.<region>.gcp.mongodb.net/...`) as the prod Mongo connection string. Aggregation code is untouched — virtual DB/collection names mirror the live cluster.

### Pointing federation at the *current* snapshot — open, load-bearing

Each export creates a new `<timestamp>/` folder; the federation path globs them all unless constrained. Without handling this, every query unions all retained snapshots → duplicate `accountId`s and N× scan cost. Candidate approaches, **to decide during implementation**:

- **(a) Partition + filter (sketched above).** Extract `_snapshotTs` as a `date` partition; the worker resolves the latest snapshot timestamp once per refresh cycle (cheap `metadata`/`.complete` listing) and adds `_snapshotTs: <latest>` to every pipeline's leading `$match`. Predicate pushdown then prunes to one folder. Most flexible; puts a "find latest snapshot" step in the worker.
- **(b) Lifecycle + tight retention.** GCS lifecycle expires snapshots after ~2 days so at most 1–2 exist; combined with `.complete`-gated reads this bounds the union. Simpler, but racy around export windows and still double-counts during overlap.
- **(c) Stable "current" prefix.** A tiny scheduled GCS step copies/relinks the newest completed snapshot under a fixed `current/` prefix the federation path points at. Cleanest query side, but adds a moving part outside Atlas.

Leaning **(a)** — keeps everything declarative in the federation config + worker query, no extra infra. Needs the worker to read the `.complete` marker to avoid querying a half-exported snapshot.

## Best practices (and where the snapshot path fights them)

| Practice | Applies here? |
|---|---|
| **Parquet over JSON** for columnar pushdown + 30–50% smaller scans | ❌ Not available — snapshot export only emits gzip Extended-JSON. To get Parquet we'd need an ETL step (Dataflow / scheduled job) converting JSON.gz → Parquet, which re-introduces compute we chose snapshots to avoid. Out of scope for v1; revisit only if scan cost runs away. |
| **Partition by path so predicates prune folders** | ✅ Critical here — the `_snapshotTs` (and `_cluster`) partition is what stops full-bucket unions. Align any other hot filter (e.g. date windows) to path segments where the export layout allows. |
| **Filter early in `$match` on partition attributes** | ✅ The aggregation's leading `$match` must constrain `_snapshotTs` (and cluster) or pushdown can't prune. |
| **Validate pushdown** with `$queryHistory` / bytes-scanned | ✅ Wire bytes-scanned-per-cycle into observability (already an item in `service.md`); it's the gate between staying on this path vs. pivoting to a batched sweep into `account_metrics`. |
| **Aggressive retention** to bound scan + storage | ✅ GCS lifecycle rule (proposed 7d). |
| **Federated instance colocated with bucket** | ✅ Same GCP region — required, and avoids egress. |

**Cost shape.** Federation bills ~per-TB-scanned (region-dependent). The dominant risk is unchanged from `mongo-read-isolation.md` § Caveat: **per-account targeted reads × ~100k accounts/day** against JSON.gz can multiply scan billing. The escalation path stays the same — if first-month measurement shows runaway scan, flip the refresh from per-account to a **single batched per-snapshot sweep** that lands intermediate rows in `account_metrics`, after which per-analysis code reads from BigQuery (the Layer A / Layer B split in [`../architecture.md`](../architecture.md)).

## Open questions

- [ ] **Snapshot inventory.** Do `InvoicesCluster` / `Tofu.Invoices.Backend` Mongo already have Cloud Backup + any export policy? Which collections, what cadence? (`clients` snapshot is known-missing per read-isolation doc.) → blocks Part 2 scoping.
- [ ] **Latest-snapshot strategy** — pick (a)/(b)/(c) above. Load-bearing for correctness *and* cost.
- [ ] **Snapshot window coverage.** Export is full-collection per snapshot, so 30d/12mo windows are satisfied by document content, not retention — but confirm no TTL/archival on source removes in-window docs before export.
- [ ] **Federation billing owner** + the WEB-1523 GCP project name + final bucket name. → blocks Part 1.
- [ ] **`objectAdmin` vs least-privilege split** — platform-team call.
- [ ] **`useOrgAndGroupNamesInExportPrefix`** — names vs UUIDs in the export path; pin before writing the federation `prefix`/`path`.
- [ ] **Two clusters, one FDI vs two** — single instance with two `stores`/path roots is simpler; confirm no per-cluster region split forces two instances.

## Cross-references

- [`../investigation/mongo-read-isolation.md`](../investigation/mongo-read-isolation.md) — the decision this doc operationalizes (and the § Option 6 framing this doc corrects re: Data Lake deprecation).
- [`../analyses/metrics.md`](../analyses/metrics.md) — per-metric query plan / refresh cadence (unchanged by the read plane).
- [`service.md`](service.md) § Q1 — connection-string config; prod-vs-stage split.
- [`storage.md`](storage.md) — BigQuery `account_metrics` destination.
- MongoDB docs: [Export Cloud Backup Snapshot](https://www.mongodb.com/docs/atlas/backup/cloud-backup/export/) · [GCS data store for Data Federation](https://www.mongodb.com/docs/atlas/data-federation/config/config-gcp-bucket/) · [Deploy FDI on GCP](https://www.mongodb.com/docs/atlas/data-federation/deployment/deploy-gcp/) · [Set up GCP access](https://www.mongodb.com/docs/atlas/security/set-up-gcp-access/) · [Data Lake deprecation](https://www.mongodb.com/docs/datalake/)
