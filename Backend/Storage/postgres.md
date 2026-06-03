PostgreSQL stores
=================

PostgreSQL databases/schemas across the workspace. Index: [`AGENTS.md`](AGENTS.md). Store-level inventory — full table schemas live in each service's EF migrations.

> Several services use the **schema-per-module** pattern (each module owns a PG schema + its own connection-string key + an `IModuleMigration`). Don't assume one DB per service.

---

## `jobs` schema (FSM) — Invoices.Backend

**Owner / writer:** `Invoices.Backend` · **Config key:** `Jobs:ConnectionString` (NOT `ConnectionStrings:*`)
**Env:** dev = `Host=localhost;Port=5432;Database=postgres` · prod = **TODO**
**Migration:** EF Core via `JobsModuleMigration` (`IModuleMigration`); also installs a version-increment trigger.

### Objects
| Table | Purpose | Key indexes |
|---|---|---|
| `Jobs` | FSM jobs | `(AccountId,Id) WHERE IsDeleted=false`; `(AccountId,CreatedAt desc)`; `(AccountId,SequenceId)` |
| `JobEvents` | job event log | `(AccountId,Id)`; `(AccountId,EntityId)` |
| `Visits` | job visits | `(JobId,DateTime)` |
| `Attachments` | job/visit attachments | `JobId`; `VisitId`; `Tags` (gin) |
| `Notes` | job/client notes | `(AccountId,SequenceId)`; `(AccountId,ClientId,CreatedAt)` partial; `(VisitId,CreatedAt)` partial |
| `JobSummaryView` | view | — |

### Links
- Code: `Invoices.Backend/Src/Jobs/Jobs.Infrastructure/Database/JobsDbContext.cs:24`; options `JobsOptions.cs:5`

---

## `notifications` schema — Invoices.Backend

**Owner / writer:** `Invoices.Backend` · **Config key:** `Notifications:ConnectionString`
**Env:** dev = `Host=localhost;Port=5432;Database=postgres` · prod = **TODO**
**Migration:** EF Core via `NotificationsModuleMigrator` (`IModuleMigration`).

### Objects
| Table | Purpose | Key indexes |
|---|---|---|
| `Notifications` | per-account notifications | `(TargetAccountId,CreatedAt desc,Id desc)`; `(TargetAccountId,TargetMasterUserId,CreatedAt,Id)` |
| `NotificationJobs` | notification scheduling jobs | `uq_notification_job_active (AccountId,ProcessType) WHERE CompletedAt IS NULL` |

### Links
- Code: `Invoices.Backend/Src/Notifications/Notifications.Infrastructure/Database/NotificationsDbContext.cs:18`; options `NotificationsOptions.cs:7`

---

## `tofu_invoices` (event store) — Tofu.Invoices.Backend

**Owner / writer:** `Tofu.Invoices.Backend` (`ApplicationDbContext`) · **Config key:** `ConnectionStrings:pgsql_db`
**Env:** dev = `Server=localhost;Port=5432;Database=tofu_invoices` · prod = **TODO**
**Migration:** EF Core, `src/Tofu.Invoices.Infrastructure/Database/Migrations/`. Event-sourcing tables (append-only domain events).

### Objects
| Table | Purpose | Notes |
|---|---|---|
| `EstimateEvents` | estimate change events | cols incl. `EntityId`, `EventType`, `Payload jsonb`, `Hash`, `EntityVersion`; `(AccountId,Id)`, `(AccountId,EntityId)` |
| `InvoiceEvents` | invoice change events | same shape as above |

### Links
- Code: `Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Database/ApplicationDbContext.cs:15-16`

---

## `tofu_ai` / `analyses` schema (Hangfire) — Tofu.AI.Backend

**Owner / writer:** `Tofu.AI.Backend` (`Tofu.AI.Api`, in-process Hangfire) · **Config key:** `ConnectionStrings:Analyses`
**Env:** dev = `Host=localhost;Port=5432;Database=tofu_ai` · prod = **TODO**. Single-pod design (distributed lock serialises the recurring tick across replicas).
**Migration / write path:** **not** a migration module — Hangfire's PG adapter auto-creates the schema at startup (`PrepareSchemaIfNecessary=true`). Schema name `analyses` (config `Analyses:Hangfire:SchemaName`). Holds Hangfire job storage only — no domain tables.

### Links
- Setup: `Tofu.AI.Backend/src/Tofu.AI.Api/Hangfire/HangfireConfiguration.cs:33-38`; options `AnalysesHangfireOptions.cs`
- Service layout: [`features/WEB-1523-segmentation/implementation/service.md`](../../features/WEB-1523-segmentation/implementation/service.md)

---

## `tofu_auth` — Tofu.Auth.Backend

**Owner / writer:** `Tofu.Auth.Backend` (`AuthContext`) · **Config key:** `ConnectionStrings:pgsql_db`
**Env:** dev = `Host=localhost;Username=postgres;Password=postgres;Database=tofu_auth` · prod = **TODO**
**Migration / write path:** EF Core (`AuthContext`), `src/Tofu.Auth.Persistence/Migrations/`; interceptors `UniqueConstraintViolationInterceptor`, `ConcurrentUpdateInterceptor`. Data Protection keys persisted here.

### Objects
| Table | Purpose |
|---|---|
| `Users` | authenticated users (Google/OTP; anonymous → de-anonymised) |
| `EmailSignInAttempts` | OTP attempts + rate limiting |
| `TokenRevocations` | revoked JWTs (per user/platform/product/device) |
| `Roles` / `RolePermissions` | roles (Worker/Manager/Admin) + permission keys |
| `UserTenantRoles` | per-tenant role assignment; composite key `(UserId,TenantId)`; tenant info as JSONB |
| `PermissionRegistry` | registry of valid permission keys (title/description/category) |
| `InvitationTokens` / `InvitationMagicTokens` | tenant invitation + passwordless magic tokens |
| `DataProtectionKeys` | ASP.NET Data Protection keys |

> **No `Tenant` table** — `TenantId` is a string property on `UserTenantRoles` / `InvitationTokens` referencing external tenant IDs (no FK).

### Links
- Code: `Tofu.Auth.Backend/src/Tofu.Auth.Persistence/Database/AuthContext.cs:8-50`
- Service docs: [`Backend/Services/Tofu.Auth/AGENTS.md`](../Services/Tofu.Auth/AGENTS.md)

---

## `tofu_payments` (PaymentOrders) — external

**Owner / writer:** **Tofu Payments service** (external; not a workspace repo) · **Env:** prod = **TODO**
**Notes:** external store; potential revenue/subscription signal source per `account_id`. Not consumed by the workspace today.

### Objects
| Table | Purpose | Notes |
|---|---|---|
| `public."PaymentOrders"` | payment orders | `status=3` ⇒ paid; `fee_amount` = Tofu's take; `account_id` FK → Mongo `accounts._id` |
