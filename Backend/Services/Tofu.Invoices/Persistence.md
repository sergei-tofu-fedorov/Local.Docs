Tofu.Invoices Persistence
=========================

This file describes how the Tofu.Invoices service stores data. It follows
the shared backend persistence template and lists entities, fields, and
relations in a compact form.

Service Overview
----------------

- **Repository**: `https://github.com/m-unicorn/Tofu.Invoices.Backend`
- **Primary stores**:
  - MongoDB - main store for invoices, estimates, accounts, and related
    aggregates.
  - SQL (via Entity Framework Core) - event history for invoices and estimates
    (`InvoiceEvent`, `EstimateEvent`).

Common Base Fields
------------------

MongoDB entities in this service share common base fields:

- From `Entity<TEntity>`:
  - `Id` (`string`, not null) - entity identifier (Mongo `_id` counterpart).
- From `VersionedEntity<TEntity>`:
  - `Version` (`int`, not null) - optimistic concurrency / version number.
  - `CreatedTime` (`datetime`, not null, UTC) - creation timestamp.
  - `ModifiedTime` (`datetime`, not null, UTC) - last modification timestamp.
- From `AccountScopedEntity<TEntity>`:
  - `AccountId` (`string`, not null) - owning account identifier.
  - `UniqueId` (`string`, computed) - `AccountId|Id`, used for cross-account
    uniqueness; not persisted as a separate field.

MongoDB: Account
----------------

Collection: `accounts`

| Field       | Type      | Null | Key/Index | Description                                 |
| ----------- | --------- | ---- | --------- | ------------------------------------------- |
| Id          | string    | No   | PK        | Account identifier                          |
| AccountId   | string    | No   | index     | Owning account; same as Id in this context  |
| Version     | int       | No   |           | Version number                              |
| CreatedTime | datetime  | No   |           | Creation time (UTC)                         |
| ModifiedTime| datetime  | No   |           | Last modification time (UTC)                |
| Timezone    | string    | Yes  |           | Offset in seconds as string                 |
| Store       | string    | Yes  |           | Source store (`appstore`, etc.)             |

Relations:

- `Account` is the root for all account-scoped entities (invoices, estimates).

MongoDB: Invoice
----------------

Collection: inferred from `Invoice.ClassifyCollection()` - `invoices`.

| Field                     | Type                | Null | Key/Index | Description                                      |
| ------------------------- | ------------------- | ---- | --------- | ------------------------------------------------ |
| Id                        | string              | No   | PK        | Invoice identifier                               |
| AccountId                 | string              | No   | index     | Owning account                                   |
| Version                   | int                 | No   |           | Version number                                   |
| CreatedTime               | datetime            | No   |           | Creation time (UTC)                              |
| ModifiedTime              | datetime            | No   |           | Last modification time (UTC)                     |
| ProductKey                | string              | No   |           | Product / app key                                |
| CreatedOn                 | datetime            | Yes  |           | Original creation timestamp                      |
| Client                    | object (`Client`)   | Yes  |           | Embedded client details                          |
| JobId                     | string              | Yes  |           | Related job identifier                           |
| Date                      | date                | No   |           | Invoice date                                     |
| DueDays                   | int                 | Yes  |           | Days until due                                   |
| Number                    | string              | Yes  |           | Human-readable invoice number                    |
| Status                    | enum `InvoiceStatus`| No   | index     | Business status                                  |
| MailStatus                | enum `EmailStatusType` | Yes |         | Last email status                                |
| MailStatusErrorMessage    | string              | Yes  |           | Last email error message                         |
| DueDateStatus             | enum `DueDateNotificationStatus` | Yes |  | Due date notification status                     |
| Items                     | array `InvoiceItem` | No   |           | Line items                                       |
| PaymentDetails            | string              | Yes  |           | Free-form payment details                        |
| Notes                     | string              | Yes  |           | Internal or customer-visible notes               |
| Discount                  | object `DiscountDescriptor` | Yes |     | Invoice-level discount                           |
| Tax                       | object `TaxDescriptor` | Yes |         | Invoice-level tax                                |
| SubtotalAmount            | decimal             | No   |           | Sum before discount and tax                      |
| DiscountAmount            | decimal             | No   |           | Total discount amount                            |
| TaxAmount                 | decimal             | No   |           | Total tax amount                                 |
| TotalAmount               | decimal             | No   |           | Final total amount                               |
| ReceivedPayments          | array decimal       | Yes  |           | Individual received payment amounts              |
| TotalDue                  | decimal             | No   |           | Outstanding amount                               |
| ReceiptInfo               | object `ReceiptInfo`| Yes  |           | Receipt-related information                      |
| IsDeleted                 | bool                | Yes  | index?    | Soft-delete flag                                 |
| MarkAsPaidDate            | datetime            | Yes  |           | When user marked invoice as paid                 |
| PaidDate                  | datetime            | Yes  |           | When payment was fully received                  |
| PaymentInfo               | object `PaymentInfo`| Yes  |           | Provider-specific payment info                   |
| CurrencyCode              | string              | Yes  |           | ISO currency code                                |
| RefundInformation         | object `RefundInformation` | Yes |     | Refund information                               |
| Attachments               | array `Attachment`  | No   |           | Associated files / documents                     |

Relations:

- `Invoice.AccountId -> Account.AccountId` (N:1, required).
- Events table `InvoiceEvent.EntityId` points back to `Invoice.Id`.

MongoDB: Estimate
-----------------

Collection: inferred from `Estimate.ClassifyCollection()` - `estimates`.

| Field                  | Type                   | Null | Key/Index | Description                                  |
| ---------------------- | ---------------------- | ---- | --------- | -------------------------------------------- |
| Id                     | string                 | No   | PK        | Estimate identifier                          |
| AccountId              | string                 | No   | index     | Owning account                               |
| Version                | int                    | No   |           | Version number                               |
| CreatedTime            | datetime               | No   |           | Creation time (UTC)                          |
| ModifiedTime           | datetime               | No   |           | Last modification time (UTC)                 |
| ProductKey             | string                 | No   |           | Product / app key                            |
| CreatedOn              | datetime               | Yes  |           | Original creation time                       |
| Client                 | object `Client`        | Yes  |           | Embedded client details                      |
| Date                   | date                   | No   |           | Estimate date                                |
| DueDays                | int                    | Yes  |           | Days until expiration                        |
| Number                 | string                 | Yes  |           | Human-readable estimate number               |
| MailStatus             | enum `EmailStatusType` | Yes  |           | Last email status                            |
| MailStatusErrorMessage | string                 | Yes  |           | Last email error                             |
| Items                  | array `InvoiceItem`    | No   |           | Line items                                   |
| PaymentDetails         | string                 | Yes  |           | Free-form payment details                    |
| Notes                  | string                 | Yes  |           | Notes                                        |
| Discount               | object `DiscountDescriptor` | Yes |       | Estimate-level discount                      |
| Tax                    | object `TaxDescriptor` | Yes  |           | Estimate-level tax                           |
| SubtotalAmount         | decimal                | No   |           | Sum before discount and tax                  |
| DiscountAmount         | decimal                | No   |           | Total discount amount                        |
| TaxAmount              | decimal                | No   |           | Total tax amount                             |
| TotalAmount            | decimal                | No   |           | Final total amount                           |
| IsDeleted              | bool                   | Yes  | index?    | Soft-delete flag                             |
| CurrencyCode           | string                 | Yes  |           | ISO currency code                            |
| Attachments            | array `Attachment`     | No   |           | Associated files / documents                 |
| Status                 | enum `EstimateStatus`  | Yes  | index     | Effective status (null/Unknown => Draft)     |
| SentMethod             | enum `EstimateSentMethod` | Yes |         | How estimate was sent                        |

Relations:

- `Estimate.AccountId -> Account.AccountId` (N:1, required).
- Events table `EstimateEvent.EntityId` points back to `Estimate.Id`.

SQL: EstimateEvent
------------------

Table: `EstimateEvents`

| Field         | Type              | Null | Key/Index        | Description                                    |
| ------------- | ----------------- | ---- | ---------------- | ---------------------------------------------- |
| Id            | bigint            | No   | PK (identity)    | Technical identifier                           |
| AccountId     | nvarchar          | No   | index            | Owning account                                 |
| EntityId      | nvarchar          | No   | index            | Estimate Id                                    |
| MasterUserId  | nvarchar          | Yes  |                  | User who triggered the change                  |
| CreatedAt     | datetimeoffset    | No   |                  | Record creation time (UTC)                     |
| OccurredAt    | datetimeoffset    | No   |                  | When the underlying event occurred             |
| EventType     | int (EventType)   | No   | index            | Domain event type                              |
| ActorType     | int (ActorType)   | No   |                  | Source of the change (system/user/external)    |
| Payload       | nvarchar(max)     | No   |                  | Serialized event payload                       |
| Hash          | nvarchar(64)      | No   | unique index     | Deterministic hash for deduplication           |
| EntityVersion | int               | No   |                  | Version of the aggregate at event time         |

Relations:

- `EstimateEvent.AccountId -> Account.AccountId` (logical, not enforced).
- `EstimateEvent.EntityId -> Estimate.Id` (logical, not enforced).

SQL: InvoiceEvent
-----------------

Table: `InvoiceEvents`

| Field         | Type                   | Null | Key/Index        | Description                                    |
| ------------- | ---------------------- | ---- | ---------------- | ---------------------------------------------- |
| Id            | bigint                 | No   | PK (identity)    | Technical identifier                           |
| AccountId     | nvarchar               | No   | index            | Owning account                                 |
| EntityId      | nvarchar               | No   | index            | Invoice Id                                     |
| MasterUserId  | nvarchar               | Yes  |                  | User who triggered the change                  |
| CreatedAt     | datetimeoffset         | No   |                  | Record creation time (UTC)                     |
| OccurredAt    | datetimeoffset         | No   |                  | When the underlying event occurred             |
| EventType     | int (InvoiceEventType) | No   | index            | Domain event type                              |
| ActorType     | int (ActorType)        | No   |                  | Source of the change                           |
| Payload       | nvarchar(max)          | No   |                  | Serialized event payload                       |
| Hash          | nvarchar(64)           | No   | unique index     | Deterministic hash for deduplication           |
| EntityVersion | int                    | No   |                  | Version of the aggregate at event time         |

Relations:

- `InvoiceEvent.AccountId -> Account.AccountId` (logical, not enforced).
- `InvoiceEvent.EntityId -> Invoice.Id` (logical, not enforced).

