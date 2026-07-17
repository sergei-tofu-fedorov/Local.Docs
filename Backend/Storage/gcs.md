Object storage (GCS)
====================

Google Cloud Storage buckets across the workspace. Index: [`AGENTS.md`](AGENTS.md). Store-level inventory.

---

## Content / asset storage — Invoices.Backend

**Owner / writer:** `Invoices.Backend` (`GoogleBlobStorage` over `Google.Cloud.Storage.V1`)
**Credentials:** prod/stage = `gcs-secrets/gcs-service-account-key.json`; dev = `GoogleCredential.GetApplicationDefault()` (ADC)

### Buckets
| Bucket | Purpose | Config key |
|---|---|---|
| `contents` | main content storage (PDFs, attachments) | `ContentsService:BucketName` |
| `temp_contents` | temporary content staging | `ContentsService:TemporaryBucketName` |
| `tofu-bdui` / `tofu-bdui-production` | BDUI template storage (dev / prod) | hardcoded in `ExternalServicesConfiguration.cs:62` |

### Links
- Code: `Invoices.Backend/Src/Invoices.Api/DI/ExternalServicesConfiguration.cs:45-64`; `Src/Invoices.Implementation.Services/BlobStorage/GoogleBlobStorage.cs`

---

## Chat-context storage — Tofu.AI.Backend

**Owner / writer:** `Tofu.AI.Backend` (`StorageService` over `Google.Cloud.Storage.V1`) — persists ChatGPT-proxy chat context.
**Config key:** `Storage:ServiceAccountKeyPath` (optional; empty ⇒ ADC / Workload Identity). Lazy — credential resolved on first chat request, not at startup.
**Notes:** made config-driven by WEB-1527 (the hardcoded `gcs-secrets/…json` key file was removed). **Bucket name: TODO** (confirm in code).

### Links
- Code: `Tofu.AI.Backend/src/Tofu.AI.Api/DI/StorageConfiguration.cs:16-39`; settings `Settings/StorageSettings.cs`

---

## ML model artifacts — `gs://tofu-ml-models`

**Project:** `inv-project` (created in test 2026-07-06, moved to prod same day — prod-only pipeline revision) · **Location:** `US` · uniform bucket-level access
**Owner / writer:** FS-1335 retraining pipeline (v0: assembled locally by `assemble_archive.py`; future: Vertex CustomJob in `inv-project`). iOS downloads via BFF-served manifest.
**Layout:** `models/price-v1/manifest.json` (single mutable pointer; publish = rewrite, rollback = point back) + `models/price-v1/<version>/` immutable archives (`.mlpackage.zip`s, potion table, `vocab.json`/`feature_spec.json` contracts, `metrics.json`, `training/`) + `datasets/price-v1/<run>/` training parquet. Details: [`features/FS-1335/research/research-vertex-automation.md`](../../features/FS-1335/research/research-vertex-automation.md).
**Access:** prod-SA `tofu-ai-backend@inv-project` covers it via project-level `storage.objectAdmin`; no bucket-level bindings.
