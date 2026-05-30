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
