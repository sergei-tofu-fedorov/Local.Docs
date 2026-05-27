Invoices.Backend Persistence
============================

Overview
--------

This document follows the shared backend persistence template from
`Backend/Persistence.md` and describes how the **Invoices.Backend** service
uses MongoDB collections in the `invoicesDB` database.

Service Summary
---------------

- **Service name in docs**: `Invoices.Backend`
- **Repository**: `https://github.com/m-unicorn/Tofu.Invoices.Backend`
- **Primary store**: MongoDB database `invoicesDB`
- **Context**: invoices and estimates gateway (public API), plus supporting
  accounts, users, subscriptions, and integrations.

Mongo Collections (per Area)
----------------------------

Collections are grouped by responsibility. For field-level details, refer to
the models in `Invoices.Core` and the Mongo repositories in
`Invoices.Implementation.MongoDb`.

### Accounts and Account Data

1. **Account** – collection: `accounts`  
   Business account entity (company/profile) that invoices and estimates belong to.

   | Field           | Type           | Description                                      |
   | --------------- | --------------| ------------------------------------------------ |
   | `Id`            | string        | Internal account id (Mongo `_id` equivalent)     |
   | `BusinessName`  | string?       | Display name used in UI and emails               |
   | `Contacts`      | object?       | Contact details (email, phone, address)          |
   | `CreatedIP`     | string?       | IP address used when the account was created     |
   | `Store`         | string?       | Source store (`ios`, `android`, etc.)            |
   | `Timezone`      | string?       | Account timezone (used for dates and scheduling) |
   | `IsDeleted`     | bool          | Soft-delete flag                                 |
   | `Culture`       | string?       | Optional culture code                            |
   | `CurrencyCode`  | enum?         | Default currency for invoices/estimates          |
   | `BusinessInfo`  | object?       | Optional business metadata                       |
   | `IsTechnical`   | bool?         | Marks technical/system accounts                  |
   | `SchemaVersion` | int?          | Schema version marker for migrations             |

2. **AccountData** – collection: `accountData`  
   Per-account derived data and settings (for example, counters, defaults).
   Stored as an account-scoped entity with a composite id.

   | Field          | Type     | Description                                      |
   | -------------- | -------- | ------------------------------------------------ |
   | `Id`           | string   | Logical key for the data record (`Key`)         |
   | `AccountId`    | string   | Owning account (`accounts.Id`)                  |
   | `UniqueId`     | string   | Physical id: `AccountId|Id`                     |
   | `Version`      | int      | Version for optimistic concurrency              |
   | `CreatedTime`  | datetime | Creation timestamp (UTC)                        |
   | `ModifiedTime` | datetime | Last modification timestamp (UTC)               |
   | `Data`         | jsonb?   | Arbitrary JSON payload for that data key        |

3. **AccountIdentifiersEntity** – collection: `accountIdentifiers`  
   Technical mapping between platform users and accounts. Used to resolve
   which accounts a given platform/master user can access.

   | Field        | Type     | Description                                  |
   | ------------ | -------- | -------------------------------------------- |
   | `AccountId`  | string   | PK, also link to `accounts.Id`               |
   | `UserId`     | string   | Platform user id used by client apps         |
   | `Idfa`       | string?  | Apple IDFA                                   |
   | `AppsflyerId`| string?  | AppsFlyer id                                 |
   | `FirebaseId` | string?  | Firebase id                                  |
   | `VendorId`   | string?  | Vendor/device id                             |
   | `AppVersion` | string?  | Last seen app version                        |
   | `Platform`   | enum?    | Last mobile platform used by the account     |

4. **RegionalAccountSetting** – collection: `regionalSettings`  
   Per-account regional configuration (culture/locale, tax decisions, etc.).
   Unique index on `AccountId`.

   | Field        | Type      | Description                                  |
   | ------------ | --------- | -------------------------------------------- |
   | `Id`         | string    | Technical id                                 |
   | `AccountId`  | string    | Unique link to `accounts.Id`                 |
   | `Current`    | object    | Current regional settings (culture, locale)  |
   | `CreatedAt`  | datetime  | Creation timestamp                           |
   | `UpdatedAt`  | datetime? | Last update timestamp                        |

### Users, Attributes, and Features

5. **MasterUser** – collection: `masterUser`  
   Backend-level aggregate for a person, grouping platform identities and
   owned accounts. Used heavily by authentication and account-ownership flows.

   | Field               | Type      | Description                               |
   | ------------------- | --------- | ----------------------------------------- |
   | `Id`                | string    | Master user id used across backends       |
   | `PlatformUserLinks` | array     | Linked platform ids per (platform,product)|
   | `OwnedAccounts`     | array     | Accounts owned/accessible by this user    |
   | `CreatedAt`         | datetime  | Creation timestamp                        |
   | `UpdatedAt`         | datetime? | Last update timestamp                     |
   | `DeletedAt`         | datetime? | Deletion timestamp (soft delete)          |

6. **UserAttribute** – collection: `userAttributes`  
   Arbitrary attributes attached to users (feature flags, experiments,
   campaign data).

   | Field        | Type      | Description                                  |
   | ------------ | --------- | -------------------------------------------- |
   | `Id`         | ObjectId  | Mongo object id                              |
   | `UserIp`     | string    | IP address for the event                     |
   | `UserAgent`  | string    | User agent string                            |
   | `CampaignId` | string    | Campaign identifier                          |
   | `CreatedAt`  | datetime  | When the attribute was recorded              |
   | `AccountId`  | string?   | Optional related account id                  |

7. **Feature** – collection: `features`  
   Global or user-scoped feature flags and configuration.

   | Field      | Type     | Description                                  |
   | ---------- | -------- | -------------------------------------------- |
   | `Id`       | string   | Feature key                                  |
   | `Enabled`  | bool     | Whether the feature is enabled               |
   | `Options`  | string?  | Optional JSON/options string                 |

### Clients, Logos, Content, and Onboarding

8. **ManageableClient** – collection: `clients`  
   Client entities used when creating invoices and estimates (customer side).

   | Field       | Type      | Description                                  |
   | ----------- | --------- | -------------------------------------------- |
   | `Id`        | string    | PK: `AccountId|ClientId`                     |
   | `ClientId`  | string    | Logical client id                            |
   | `AccountId` | string    | Owning account                               |
   | `Info`      | array     | Collection of `ManageableClientInfo` records |
   | `Version`   | int       | Version for optimistic concurrency           |
   | `CreatedAt` | datetime  | Creation time                                |
   | `UpdatedAt` | datetime? | Last update time                             |
   | `DeletedAt` | datetime? | When client was soft-deleted                 |

9. **Logo** – collection: `logos`  
   Account and invoice logos, including image metadata and storage links.

   | Field            | Type   | Description                                 |
   | ---------------- | ------ | ------------------------------------------- |
   | `AccountId`      | string | PK, owning account                          |
   | `Name`           | string | Logo file name or key                       |
   | `HasBeenCompressed` | bool| Whether the logo has been compressed        |
   | `HasBeenResized` | bool   | Whether the logo has been resized           |
   | `ExternalUrl`    | string?| Location in external storage (if any)       |

10. **Content** – collection: `contents`  
    Generic content blocks (files, resources) used by invoices/email/jobs.

   | Field        | Type      | Description                                  |
   | ------------ | --------- | -------------------------------------------- |
   | `Id`         | string    | Content id                                   |
   | `AccountId`  | string    | Owning account                               |
   | `Url`        | string    | URL for accessing the content                |
   | `ContentType`| string    | MIME type or logical content type            |
   | `EntityId`   | string    | Related entity id (invoice, estimate, job)   |
   | `EntityType` | enum      | `ContentEntities` (Invoice / Estimate / Job) |
   | `CreatedAt`  | datetime  | Creation timestamp                           |
   | `UpdatedAt`  | datetime? | Last update timestamp                        |
   | `Properties` | object?   | `ContentAdditionalProperties` (orientation)  |

11. **Onboarding** – collection: `onboardings`  
    Tracks onboarding progress per account.

   | Field              | Type      | Description                                  |
   | ------------------ | --------- | -------------------------------------------- |
   | `Id`               | string    | Logical onboarding id                        |
   | `AccountId`        | string    | Owning account                               |
   | `UniqueId`         | string    | Physical id: `AccountId|Id`                  |
   | `Version`          | int       | Version (from `AccountScopedEntity`)         |
   | `CreatedTime`      | datetime  | Base creation time                           |
   | `ModifiedTime`     | datetime  | Base modification time                       |
   | `Steps`            | array     | List of onboarding steps                     |
   | `CreatedAt`        | datetime  | Onboarding-specific creation time            |
   | `UpdatedAt`        | datetime  | Onboarding-specific update time              |
   | `IsExperiencedUser`| bool      | Whether user is classified as experienced    |
   | `IsFromGenerator`  | bool      | Whether user came from invoice generator app |

### Configuration and Bans

12. **Configuration** – collection: `configurations`  
    Service-level configuration documents (feature switches, limits, etc.).

   | Field        | Type      | Description                                  |
   | ------------ | --------- | -------------------------------------------- |
   | `Id`         | string    | Configuration id                             |
   | `CreatedAt`  | datetime  | Creation time                                |
   | `UpdatedAt`  | datetime? | Last update time                             |
   | `Features`   | array?    | Collection of `ConfigurationFeature` entries |

   `ConfigurationFeature`:

   | Field   | Type   | Description                    |
   | ------- | ------ | ------------------------------ |
   | `Name`  | string | Feature name (e.g. `platform_fee_1_percent`) |

13. **BanContext** – collection: `bans`  
    Records of banned contexts (users, accounts, devices). Used to block
    access and operations at the gateway level.

   | Field       | Type      | Description                                  |
   | ----------- | --------- | -------------------------------------------- |
   | `UserId`    | string?   | Banned user (may be null)                    |
   | `AccountId` | string?   | Banned account (may be null)                 |
   | `Reason`    | string    | Human-readable ban reason                    |
   | `BanDate`   | datetime  | When the ban was created                     |

### Email and Templates

14. **EmailStatus** – collection: `emailStatus`  
    Tracking status of outbound emails (queued, sent, failed, etc.).

   | Field        | Type      | Description                                  |
   | ------------ | --------- | -------------------------------------------- |
   | `MessageId`  | string    | PK, provider message id                      |
   | `ProductKey` | string    | Product / app key                            |
   | `AccountId`  | string    | Related account                              |
   | `InvoiceId`  | string    | Related invoice / estimate id                |
   | `Type`       | enum      | `EmailStatusType` (sent, failed, etc.)       |
   | `Reason`     | string?   | Optional failure reason                      |
   | `Date`       | datetime  | Event timestamp                              |
   | `ObjectType` | enum?     | `BusinessObjectType` for the email           |
   | `EmailTo`    | string?   | Recipient email                              |

15. **EntityTemplate** – collection: `entityTemplates`  
    Templates for invoices, estimates, and emails.

   | Field        | Type      | Description                                  |
   | ------------ | --------- | -------------------------------------------- |
   | `AccountId`  | string    | Owning account                               |
   | `Current`    | object    | `TemplateParams` for the current template    |
   | `CreatedAt`  | datetime  | When the template was created                |
   | `UpdatedAt`  | datetime? | Last modification time                       |

### Payments and Subscriptions

16. **AuthenticatedPaymentTypes** – collection: `authenticatedPaymentTypes`  
    Authenticated payment methods available to an account/user.

   | Field                 | Type      | Description                          |
   | --------------------- | --------- | ------------------------------------ |
   | `Id`                  | string    | Logical id (from `Entity`)           |
   | `AccountId`           | string    | Owning account                       |
   | `UniqueId`            | string    | Physical id: `AccountId|Id`          |
   | `Version`             | int       | Version                              |
   | `CreatedTime`         | datetime  | Creation time                        |
   | `ModifiedTime`        | datetime  | Last modification time               |
   | `PaymentByCardEnabled`| bool      | Feature flag for card payments       |
   | `Items`               | array?    | List of `AuthenticatedPaymentType`   |
   | `UniqueAccountId`     | string?   | Optional account-level identifier    |

   `AuthenticatedPaymentType` (nested JSON structure):

   | Field                  | Type      | Description                          |
   | ---------------------- | --------- | ------------------------------------ |
   | `Name`                 | string    | Provider name (Stripe, etc.)         |
   | `Enabled`              | bool      | Whether provider is enabled          |
   | `Items`                | object    | Provider-specific settings           |
   | `SoftEnabled`          | bool?     | Pre-auth/pre-connect flag            |
   | `ClientPaysFeeEnabled` | bool?     | Whether client pays processing fees  |
   | `CreatedTime`          | datetime? | When this config was created         |
   | `Status`               | enum?     | `PaymentAccountConnectionStatus`     |
   | `ProductKey`           | string?   | Product / app key                    |

17. **AccountReceipt** – collection: `receipts`  
    Receipts for paid invoices or subscriptions (one per account).

   | Field         | Type      | Description                                  |
   | ------------- | --------- | -------------------------------------------- |
   | `AccountId`   | string    | PK and owning account                        |
   | `ReceiptData` | string?   | Raw receipt blob                             |
   | `Transactions`| array?    | Store-specific transactions                  |
   | `PayContext`  | string?   | Context for the payment                      |
   | `ProductId`   | string?   | Store product id                             |
   | `PurchaseToken`| string?  | Store purchase token                         |

18. **AccountSubscription** – collection: `subscriptions`  
    Subscription records for accounts (plan, renewal, original transaction).

   | Field                  | Type      | Description                          |
   | ---------------------- | --------- | ------------------------------------ |
   | `UniqueId`             | string    | PK: `AccountId|OriginalTransactionId`|
   | `AccountId`            | string    | Owning account                       |
   | `OriginalTransactionId`| string    | Store subscription id                |
   | `RenewalInfo`          | object    | `SubscriptionRenewalInfo` (intent, auto-renew) |
   | `Transactions`         | array     | History of `SubscriptionTransaction` |

   `SubscriptionTransaction` (nested JSON structure):

   | Field             | Type      | Description                              |
   | ----------------- | --------- | ---------------------------------------- |
   | `TransactionId`   | string?   | Store transaction id                     |
   | `ProductId`       | string?   | Store product id                         |
   | `PurchaseTime`    | datetime  | When the purchase occurred               |
   | `ExpirationTime`  | datetime  | When the subscription expires            |
   | `CancellationTime`| datetime? | When subscription was cancelled (if any) |
   | `CancellationReason`| enum?   | Reason for cancellation                  |
   | `Raw`             | jsonb?    | Provider-specific raw payload            |

19. **CheckoutCustomer** – collection: `checkoutCustomers`  
    Customers created via web checkout flows. Indexed by `Email`, `CustomerId`,
    and `UserId`.

   | Field              | Type      | Description                                  |
   | ------------------ | --------- | -------------------------------------------- |
   | `CustomerId`       | string    | Provider customer id                         |
   | `Email`            | string?   | Customer email                               |
   | `PaidCheckoutSubscriptions` | array | History of paid checkout subscriptions |
   | `CreatedAt`        | datetime  | When the customer was created                |
   | `UpdatedAt`        | datetime? | Last update time                             |
   | `ProductKey`       | string?   | Product / app key                            |
   | `UserId`           | string?   | Linked invoices backend user                 |
   | `AppsflyerId`      | string?   | AppsFlyer id                                 |
   | `PublicUserId`     | string?   | Public user id                               |
   | `WithAuth`         | bool      | Whether the customer has a full auth account |

### Short URLs and Integrations

20. **ShortUrl** – collection: `shortUrl`  
    Short links for invoices and public resources.

   | Field         | Type      | Description                                  |
   | ------------- | --------- | -------------------------------------------- |
   | `Id`          | string    | Short-url id (also stored as `Url`)          |
   | `Url`         | string    | Short URL                                    |
   | `LongUrl`     | string    | Original long URL                            |
   | `Metadata`    | object?   | `Metadata` for personalization/encoding      |
   | `CreatedOn`   | datetime? | Creation time                                |

   `Metadata` (nested JSON structure):

   | Field          | Type   | Description                          |
   | -------------- | ------ | ------------------------------------ |
   | `IsPersonalized`| bool  | Whether the URL was personalized     |
   | `IsUrlEncoded` | bool   | Whether the target URL is encoded    |

21. **FunnelFoxUser** – collection: `funnelFoxIntegration`  
    Integration data for FunnelFox users.

   | Field          | Type      | Description                                  |
   | -------------- | --------- | -------------------------------------------- |
   | `ProjectId`    | string    | FunnelFox project id                         |
   | `FunnelId`     | string    | FunnelFox funnel id                          |
   | `IsSandbox`    | bool      | Whether this config is for sandbox           |
   | `AdditionalInfo`| object   | Extra info (email, vendor profile, vendor)   |
   | `CreatedAt`    | datetime  | Creation time                                |
   | `UpdatedAt`    | datetime? | Last update time                             |

   `AdditionalInfo`:

   | Field          | Type    | Description                      |
   | -------------- | ------- | -------------------------------- |
   | `Email`        | string? | Contact email                    |
   | `VendorProfileId`| string?| Vendor profile identifier        |
   | `Vendor`       | string? | Vendor name                      |

22. **Web2WaveUser** – collection: `web2waveIntegration`  
    Integration data for Web2Wave users. Indexed by `UserEmail`
    (case-insensitive) and `UserId`.

   | Field        | Type      | Description                                  |
   | ------------ | --------- | -------------------------------------------- |
   | `UserId`     | string    | Web2Wave user id (unique)                    |
   | `UserEmail`  | string    | User email                                   |
   | `CustomerId` | string    | Provider customer id                         |
   | `PaymentSystem`| int?    | Payment system identifier                    |
   | `CreatedAt`  | datetime  | Creation time                                |
   | `UpdatedAt`  | datetime? | Last update time                             |

Generic Collections
-------------------

The Mongo context also exposes a generic method:

- `GetCollection<TEntity>()` – collection name from `TEntity.ClassifyCollection()`.

This is used for entities that classify their own collection at runtime. When
adding new persisted entities that use this pattern, document them here using
the structure from `Backend/Persistence.md`.

Relations Overview
------------------

Key relations between collections:

- **Accounts and account-scoped data**
  - `AccountData.AccountId` -> `Account.Id` (1:1, required).
  - `RegionalAccountSetting.AccountId` -> `Account.Id` (1:1, required, unique).
  - Many other entities are logically account-scoped via an `AccountId` field:
    `Content`, `EmailStatus`, `EntityTemplate`, `AuthenticatedPaymentTypes`,
    `AccountReceipt`, and `AccountSubscription`.

- **Accounts and users**
  - `AccountIdentifiersEntity.AccountId` -> `Account.Id` (1:N from account to identifier rows).
  - `AccountIdentifiersEntity.UserId` links platform users to accounts and is
    used (together with `MasterUser.OwnedAccounts`) to determine which accounts
    a given user can access.
  - `MasterUser.OwnedAccounts[].AccountId` -> `Account.Id` (N:M between master users and accounts).

- **Subscriptions and receipts**
  - `AccountReceipt.AccountId` -> `Account.Id` (1:1, upserted per account).
  - `AccountSubscription.AccountId` -> `Account.Id` (1:N, each original transaction
    becomes a separate subscription document via `UniqueId`).

- **Email and content**
  - `EmailStatus.AccountId` -> `Account.Id` (N:1).
  - `EmailStatus.InvoiceId` points to invoice/estimate identifiers owned by
    `Tofu.Invoices` (documented in `Backend/Services/Tofu.Invoices/Persistence.md`).
  - `Content.AccountId` -> `Account.Id` (N:1). `Content.EntityId` often refers to
    domain entities such as invoices or jobs; those relations are described in
    the respective feature docs (for example, `features/jobs/*`).

- **Payments and checkout**
  - `AuthenticatedPaymentTypes.AccountId` -> `Account.Id` (1:1 per account).
  - `AccountSubscription` and `AccountReceipt` are account-scoped and tie
    together store transaction ids with invoices backend accounts.
  - `CheckoutCustomer.UserId` links web checkout customers to invoices backend
    users; the mapping from `UserId` to master/ platform users is maintained
    in `MasterUser`.

- **Integrations**
  - `FunnelFoxUser` and `Web2WaveUser` store integration-specific identifiers
    (emails, external user ids). Where they reference invoices accounts or
    users, the mapping is done via `AccountId` or platform ids that are also
    present in `MasterUser` / `AccountIdentifiers`.

Cross-service or cross-feature relations (for example, invoices and estimates
themselves) are owned by other services such as `Tofu.Invoices`, and their
persistence is described in those services' docs. This file focuses on how
Invoices.Backend uses MongoDB collections and how its own entities relate
to each other.

