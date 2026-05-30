MongoDB stores
==============

MongoDB databases across the workspace. Index: [`AGENTS.md`](AGENTS.md). Store-level inventory — full document schemas live in each service's repo.

> Both services use a database named **`invoicesDB`**, but they are **distinct deployments** (separate connection strings / clusters in prod). The WEB-1523 metrics work treats them as two logical sources: `Invoices.Backend` Mongo (accounts, clients) + `Tofu.Invoices.Backend` Mongo (invoices, estimates). Whether they share a physical cluster in prod is **TODO**.

---

## `invoicesDB` — Invoices.Backend (BFF)

**Owner / writer:** `Invoices.Backend` (BFF / main repo) · **Config key:** `ConnectionStrings:MongoDb`
**Env:** dev = `mongodb://localhost:27017` · prod = **TODO**
**Context:** `Src/Invoices.Implementation.MongoDb/Repositories/Shared/MongoDbContext.cs` (db name `invoicesDB`)

### Collections
The BFF owns ~24 collections. Metrics-relevant ones bolded; the rest are listed for inventory.

| Collection | Model | Notes / key indexes |
|---|---|---|
| **`accounts`** | `Account` | SaaS account owners; soft-delete `IsDeleted`, exclude `IsTechnical=true`; no explicit index in Configure |
| **`clients`** | `ManageableClient` | contacts a user invoices; **soft-delete `DeletedAt` (nullable; null⇒alive)** not `IsDeleted`; `ix_clients.accountid`, `ix_clients.clientid`, `ix_clients.accountid.deletedat.infoname.clientid_en` (collation) |
| `items` | `ManageableItem` | catalog items; `ix_items.accountid.deletedat.infoname.itemid_en` |
| `masterUser` | `MasterUser` | owner/account links; `ix_masterusers_v5.owned_accounts.account_id` (unique sparse) + others |
| `subscriptions` / `receipts` | `AccountSubscription` / `AccountReceipt` | subscription state |
| `accountData` / `business_profiles` / `regionalSettings` / `configurations` | — | account profile/config |
| `onboardings` | `Onboarding` | `idx_account_id_unique` |
| `accountIdentifiers` | `AccountIdentifiersEntity` | `idx: UserId` |
| `authenticatedPaymentTypes` | `AuthenticatedPaymentTypes` | payment config; unique sparse on AccountId |
| `contents` / `logos` / `entityTemplates` | — | rendered content / assets |
| `emailStatus` | `EmailStatus` | `ix_emailstatus.accountid_date` |
| `operationsQueue` | `Operation` | TTL 30d on `StartedAt` |
| `featureFlags` / `features` | `FeatureFlag` / `Feature` | `ix_featureflags.key_unique` |
| `bans` / `userAttributes` | — | abuse / attribution |
| `shortUrl` / `funnelFoxIntegration` / `web2waveIntegration` / `checkoutCustomers` | — | integrations |

### Links
- Code: `Invoices.Backend/Src/Invoices.Implementation.MongoDb/Repositories/Shared/MongoDbContext.cs:96-629`
- Metrics read plan: [`features/WEB-1523-segmentation/analyses/metrics.md`](../../features/WEB-1523-segmentation/analyses/metrics.md) § Sources

---

## `invoicesDB` — Tofu.Invoices.Backend

**Owner / writer:** `Tofu.Invoices.Backend` · **Config key:** `ConnectionStrings:MongoDb`
**Env:** dev = `mongodb://root:example@localhost:27017` · prod = **TODO**. In prod, `Tofu.AI.Backend` reads these via a **Mongo Data Federation** snapshot endpoint (live clusters untouched); in stage, a plain connection.
**Context:** `src/Tofu.Invoices.Infrastructure/Database/MongoDbContext.cs:41`

### Collections
| Collection | Model | Key fields | Indexes | Conventions |
|---|---|---|---|---|
| `invoices` | `Invoice` | `AccountId`, `Date`, `TotalAmount`, `Items[]`, `ClientId`/`Client.CatalogId`, `IsDeleted`, `Status`, `CreatedTime` | `ix_invoices.accountid.date.createdtime` (AccountId,IsDeleted,Date,CreatedTime); `ix_invoices.accountid.modifiedtime.uniqueid` | `IsDeleted` nullable → **`IN (false,null)`** never `=false`; `ClientId` (legacy) vs `Client.CatalogId` (newer) — coalesce |
| `estimates` | `Estimate` | `AccountId`, `Date`, `InvoiceId`, `IsDeleted`, `CreatedTime` | `ix_estimates.accountid.date.createdtime`; `ix_estimates.accountid.modifiedtime.uniqueid` | `IsDeleted IN (false,null)`; `InvoiceId != null` ⇒ converted to invoice |
| `accounts` | `Account` | `Id`, `Timezone`, `Store` | none in Configure | — |
| `accountIdentifiers` | `AccountIdentifiersEntity` | `AccountId`, `UserId` | none in Configure | account↔user link |

> **NOTE:** a new partial index `invoices.{CreatedTime:1}` (filter `IsDeleted IN [false,null]`) is **planned by WEB-1523** to speed the discovery sweep — confirm it shipped before relying on it.

### Links
- Code: `Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Database/MongoDbContext.cs:41-101`
- Read-isolation design: [`features/WEB-1523-segmentation/investigation/mongo-read-isolation.md`](../../features/WEB-1523-segmentation/investigation/mongo-read-isolation.md)

---

## WEB-1523 read access

The four collections (`invoices`, `estimates`, `clients`, `accounts`) feed `account_metrics`. Read **batched** (`$match {AccountId:{$in:batch}}` → `$group _id:"$AccountId"`); no writes, no new collections. `Tofu.AI.Backend` uses a single `ConnectionStrings:Mongo` for all four (one `IMongoDatabase`). See [`features/WEB-1523-segmentation/analyses/metrics.md`](../../features/WEB-1523-segmentation/analyses/metrics.md).
