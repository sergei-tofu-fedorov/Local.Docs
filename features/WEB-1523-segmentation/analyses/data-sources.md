_Research compiled 2026-05-10. Consolidates the prior `research-user-data.md` (data inventory across the workspace) + the use-case option mapping. Source: code scan of `Invoices.Backend`, `Tofu.Invoices.Backend`, `Tofu.Auth.Backend`, and `Tofu.Docs/`._

# WEB-1523 — Investigation: User Data + AI Use-Case Option Space

> **Scope:** "user" = a SaaS account owner / subscriber on our platform — the entity that pays us. NOT the `Client.cs` entity (which is a contact a user invoices). This inventory covers everything we can analyze about a user, including transitively the business data they generate (their clients, invoices, estimates, payments, etc.).

> **Audience for the AI feature: invoice-only users.** The primary outcome is proposing the FSM (Jobs) feature to users currently issuing only invoices. Job / visit / technician-assignment data is therefore **inventoried below for completeness but excluded from the analysis payload** — the target audience has none, and existing FSM users are not the audience. FSM-fit must be inferred from invoice-only signal.

> ⚠️ **Existing prior art:** `feature/ai_summary` branch + `Tofu.Docs/features/ai_summary/` already contains a DeepSeek-based FSM-compatibility classifier. *(The branch is being dropped per the feature owner's call — `Tofu.AI.Backend` is built fresh per [`../service.md`](../service.md).)*

---

# Part A — Data inventory

What we have to feed any AI analysis pipeline.

## 1. User / Account / Tenant model

### Identity (dual model)

**`MasterUser`** — `Invoices.Backend/Src/Invoices.Core/Models/MasterUser.cs:16` — Mongo collection `masterUsers`
- `Id` (MasterUserId) — backend identifier
- `PlatformUserLinks[]` — federated platform identities
  - `PlatformId`, `Platform` (iOS/Android/Web), `Product`, `OriginalEmail`, `IsFirstLink`, `CreatedAt`
- `OwnedAccounts[]` — accounts user owns or is a member of
  - `AccountId`, `TenantRole` (null = owner), `OwnedAccountMeta.AssignedBy`
- `CreatedAt`, `UpdatedAt`, `DeletedAt`

**`User`** — `Tofu.Auth.Backend/src/Tofu.Auth.Domain/Models/User.cs:11` — Postgres `users`
- `Id` (Guid), `Email` (normalized), `ExternalUserId`, `Name`, `PictureUrl`
- `IsAnonymous`, `AuthMethod` (Google/OTP/Firebase/etc.)
- `CreatedAt`, `UpdatedAt`

### Account

**`Account`** — `Invoices.Backend/Src/Invoices.Core/Models/Account.cs:9` — Mongo `accounts`
- `Id`, `BusinessName`, `Contacts` (Name/Phone/Email/Address)
- `Timezone`, `Culture`, `CurrencyCode`
- `Store` (sandbox vs prod), `CreatedIP`, `CreatedTime`, `ModifiedTime`
- `IsDeleted`, `IsTechnical`, `SchemaVersion`

**`Account`** — `Tofu.Invoices.Backend/src/Tofu.Invoices.Domain/Models/Account.cs:4` — Postgres
- `Timezone`, `Store` — used for notification scheduling

**`AccountIdentifiers`** — `Invoices.Backend/Src/Invoices.Core/Models/AccountIdentifiers.cs`
- `AccountId`, `UserId`, `VendorId`, `Idfa`, `AppsflyerId`, `FirebaseId`, `Platform`, `AppVersion`

### Repositories
- `AccountsRepository` — `Invoices.Backend/Src/Invoices.Implementation.MongoDb/Repositories/AccountsRepository.cs:15` — `GetAsync`, `FindAsync`, `FindIdentifiersAsync`, `GetAccountsForUserId`, `FindManyAsync`
- `MasterUserRepository` — `Invoices.Backend/Src/Invoices.Implementation.MongoDb/Repositories/MasterUserRepository.cs:10` — `Find`, `Upsert`, `MarkUserAsAccountOwner`, `AddOrUpdateInvitedAccount`

## 2. Subscription / billing of the user (their subscription to us)

### Models

**`Subscription`** — `Invoices.Backend/Src/Invoices.Core/Models/Subscription/Subscription.cs:5` — App Store / Google Play receipts
- `OriginalTransactionId`, `RenewalInfo` (auto-renew state), `Transactions[]`, `Type`, `ExpirationTime`

**`SubscriptionTransaction`** — `Invoices.Backend/Src/Invoices.Core/Models/Subscription/SubscriptionTransaction.cs`
- `ProductId`, `ExpirationTime`, `CancellationTime`, `PurchaseDate`, `CreationDate`

**`AccountSubscription`** — `Invoices.Backend/Src/Invoices.Core/Models/Subscription/AccountSubscription.cs:3` — Mongo `subscriptions`
- `Id`, `AccountId`, `UserId`, `ProductKey`, `ProductType`
- `IsActive`, `ProductId`, `StartTime`, `ExpirationTime`, `CancellationTime`
- `IsAutoRenewEnabled`, `IsTrial`, `InitialPurchaseTime`, `IsRenewing` (computed)
- `AdapterType` — AppStore / GooglePlay / Stripe / Paddle

**`Plan`** — `Invoices.Backend/Src/Invoices.Core/Models/Plans/Plan.cs:5`
- `IsActive`, `ProductType` (Plus / Premium / Invoicing / **FsmSolo / FsmTeam / FsmBusiness** ← FS plans already exist as types)
- `Duration` (Week/Month/Year), `ExpirationTime`, `IsTrialAvailable`, `IsAutoRenewalEnabled`
- `OriginProductId`, `PlatformUserId`, `Product`, `ExternalSubscriptionId`, `Price`

### Providers

| Provider | Purpose | File |
|---|---|---|
| **Apple App Store / Google Play** | RevenueCat-style in-app subs | `Subscription`, `SubscriptionTransaction` |
| **Stripe Billing** | Web subs, Customer Portal | `Tofu.Stripe`, `SubscriptionService.cs:29` |
| **Paddle** | Legacy | references in subscription models |

Stripe config: `Subscriptions:Stripe` — `PortalConfigurationId`, `NonUpgradeablePlans`, `IntroCoupons`. Plan upgrade endpoint: `POST /api/plans/upgrade-links` (Stripe hosted checkout).

### Services
- `PlanInfoProvider` — `Invoices.Backend/Src/Invoices.Implementation.Services/Plans/PlanInfoProvider.cs` — active plan per product key
- `PlansService` — `GetAllActiveAsync(userId, productKey)`, `GetAllAsync()`
- `SubscriptionsRepository` — `Invoices.Backend/Src/Invoices.Implementation.MongoDb/Repositories/SubscriptionsRepository.cs:13` — `StoreReceiptAsync`, `GetReceiptAsync`, `StoreSubscriptionAsync`, `GetSubscriptionSummaryAsync`

### Trial signal
No explicit `TrialStartDate` / `TrialEndDate` fields. Derived from `ProductId` metadata + `Subscription.RenewalInfo.IsAutoRenewEnabled`.

## 3. Product usage / behavior signals

### Activity

**`AccountInfoWithActivityDto`** — `Invoices.Backend/Src/Invoices.Api/Models/AccountInfoWithActivityDto.cs:3`
- `LastInvoiceActivity`, `LastEstimateActivity`, `TotalInvoices`, `TotalEstimates`

`AuthService` — `Invoices.Backend/Src/Invoices.Implementation.Services/Authentication/AuthService.cs` — computes `TotalInvoices` on login.

### Onboarding / activation

**`OnboardingStatus`** — `Invoices.Backend/Src/Invoices.Core/Models/OnboardingStatus.cs:6`
- `Steps[]` (`OnboardingStep`), `IsExperiencedUser`, `FirstInvoiceId` (activation signal), `IsFromGenerator`, `UserType`, `ModalDismissals[]`

### Platform / device

**`Platform`** enum — `Unknown / IOS / Android / Web` (`Invoices.Backend/Src/Invoices.Core/Models/MasterUser.cs:6`)
`AccountIdentifiers.Platform`, `AccountIdentifiers.AppVersion`.

### Engagement (email)

**`EmailStatus`** — `Invoices.Backend/Src/Invoices.Core/Models/Email/EmailStatus.cs:5` — Mongo `emailStatuses`
- `MessageId`, `AccountId`, `InvoiceId`, `EmailTo`, `Type`, `Reason`, `Date`, `ObjectType`, `ProductKey`

**No per-user aggregated open/click rates** — would require aggregating `EmailStatus` events.

## 4. Business data the user owns (transitive)

### Clients
**`ManageableClient`** (Invoices.Backend) — Mongo `clients` — `AccountId`, `Info[]`, lifecycle
**`Client`** — `Tofu.Invoices.Backend/src/Tofu.Invoices.Domain/Models/Client.cs:3` — `Name`, `Phone`, `Email`, `Address`, `CatalogId`
Repo: `ClientsRepository.GetByAccountIdAsync`, `GetByAccountIdWithActivityAsync`, `FindManyAsync`

### Invoices
**`Invoice`** — `Tofu.Invoices.Backend/src/Tofu.Invoices.Domain/Models/Invoices/Invoice.cs` — Mongo `invoices`
- `AccountId`, `ClientId`, `Number`, `Date`, `DueDate`, `Status`, `TotalAmount`, `Items[]`, lifecycle

### Estimates
**`Estimate`** — `Tofu.Invoices.Backend/src/Tofu.Invoices.Domain/Models/Estimate/Estimate.cs:6`
- Same shape as Invoice + `MailStatus`, `InvoiceId`, `JobId`, `Source`

### Jobs (Field Service)
**`Job`** — `Invoices.Backend/Src/Jobs/Jobs.Domain/Models/Job.cs:14`
- `Id`, `AccountId`, `ClientId`, `Number`, `Title`, `CreatedAt`, `UpdatedAt`, `CompletionTime`
- `Status` (`EffectiveStatus`: Unscheduled / Scheduled / InProgress / ReadyForInvoice / Invoiced / Paid)
- `ManualStatus`, `Items[]`, `Visits[]` (assigned worker, status, datetime), `CurrencyCode`, `Summary`, `ClientSnapshot`, `IsDeleted`

**`JobEvent`** — `Invoices.Backend/Src/Jobs/Jobs.Domain/Models/JobEvent.cs`

### Items / catalog
**`ManageableItem`** — `Invoices.Backend/Src/Invoices.Core/Models/Items/ManageableItem.cs` — `AccountId`, `Name`, `Type`, `Price`
Repo: `ItemsRepository`

### Attachments
Stored via `ContentsRepository` + Google Cloud Storage. Referenced from Invoice / Estimate / Job.

### Per-user aggregating reads
- `AccountsRepository.GetAccountsForUserId` → account ids
- `ClientsRepository.GetByAccountIdAsync` → clients per account
- `InvoiceEventsRepository.GetByAccountIdAsync` / `GetByMasterUserIdAsync`
- `EstimateEventsRepository.GetByAccountIdAsync`

No cross-account aggregation method exists — caller must loop.

## 5. Communications the user sent through us

**`EmailStatus`** (see §3) — outbound email events tracked via SendGrid webhooks.
Webhook receiver: `Invoices.Backend/Src/Invoices.Api/Controllers/SendGridCallbackController.cs`
Email service: `Invoices.Backend/Src/Tofu.Email/Service/EmailService.cs`
Alternative provider: Sendinblue (`SendinblueCallbackController.cs`)

**Chat** — `Invoices.Backend/Src/Invoices.Api/Controllers/ChatController.cs:17` — proxies to external `Tofu.AI.Api`. No persisted chat history in this backend.

No SMS, no push, no in-app messaging at user level.

## 6. Per-user aggregates already computed

**On login** (`AuthService`): `TotalInvoices`.
**Per-account API**: `AccountInfoWithActivityDto` — `TotalInvoices`, `TotalEstimates`, `LastInvoiceActivity`, `LastEstimateActivity`.

**Reports** — `Invoices.Backend/Src/Invoices.Api/Controllers/ReportsController.cs:18`
- `GET /api/reports/{type}` — CSV / PDF zip export
- `GET /api/reports/totalsByYears` — yearly aggregates
- `GET /api/reports/stream/invoices_full_period_pdf_zip`
- `POST /api/reports/send` — email a report
- Data source: gRPC to `Tofu.Invoices.Backend`

**Analytics gateway** — `Tofu.Invoices.Backend/src/Tofu.Invoices.Infrastructure/Analytics/AnalyticsApiGateway.cs` — pushes events to external analytics.

**No materialized per-user aggregates:** no `UserMetrics`, `UserHealth`, churn flag, activation score, engagement score.

## 7. External signals tied to the user

| Integration | Path | Signal |
|---|---|---|
| **Stripe (merchant)** | `Invoices.Backend/Src/Tofu.Stripe/StripeAccountClient.cs` | User's connected Stripe account for accepting client payments |
| **PayPal** (legacy) | payment models | Same shape |
| **SendGrid sender** | `Invoices.Backend/Src/Tofu.Email/Service/EmailService.cs` | Sender identity for outbound emails |
| **Web2Wave** | `Invoices.Backend/Src/Invoices.Implementation.Services/Web2Wave/Web2WaveService.cs` + `Web2WaveCallbackController.cs` | CRM/automation sync (`Web2WaveUser` model) |
| **Funnelfox** | `Invoices.Backend/Src/Invoices.Implementation.Services/Funnelfox/FunnelfoxService.cs` + `FunnelfoxCallbackController.cs:14` | Marketing-funnel events (`EventSessionCreated`, `EventPurchaseCompleted`) |
| **Sendinblue** | `SendinblueCallbackController.cs` | Email-marketing alternative |
| **AppsFlyer** | `AccountIdentifiers.AppsflyerId` | Mobile attribution |
| **Firebase** | `AccountIdentifiers.FirebaseId`, Tofu.Auth Firebase JWT | Auth + analytics |

## 8. Activity / event / audit logs

| Log | Storage | Source file | Tracks |
|---|---|---|---|
| `InvoiceEvent` | Postgres (`Tofu.Invoices.Backend`) | `src/Tofu.Invoices.Domain/Models/Events/InvoiceEvent.cs:8` | `MasterUserId`, status changes, email events, payments, creation source |
| `EstimateEvent` | Postgres | `src/Tofu.Invoices.Domain/Models/Events/EstimateEvent.cs:9` | Status changes, email events, conversion to invoice/job |
| `JobEvent` | (Mongo, in `Invoices.Backend`) | `Src/Jobs/Jobs.Domain/Models/JobEvent.cs` | Job state, visits |
| `EmailStatus` | Mongo | `Src/Invoices.Core/Models/Email/EmailStatus.cs:5` | Per-message sendgrid events |
| `TokenRevocation` | Postgres (`Tofu.Auth`) | Tofu.Auth domain | Revoked JWTs |

**Common event payload fields:** `AccountId`, `EntityId`, `MasterUserId`, `OccurredAt`, `EventType`, `ActorType` (User/System/External), `Payload` (JSON), `Hash` (SHA256).

**No global per-user audit log** — no tracking of account-property changes (name, timezone, currency, plan), no permission/role-change log.

## 9. API surfaces touching user data

### Auth (Tofu.Auth.Backend)
`Tofu.Auth.Backend/src/Tofu.Auth.Api/Controllers/UsersController.cs:13`
- `GET /users/authenticated/info`
- `POST /users/authenticated/search-by-user-ids`
- `GET /users/authenticated/session-cookie`, `GET /users/session-cookie/exchange`
- `POST /users/authenticated/logout`

### Accounts (Invoices.Backend)
`Invoices.Backend/Src/Invoices.Api/Controllers/V3/AccountController.cs` (v1, v3)
- `GET /api/accounts`, `GET /api/accounts/{id}`, `POST /api/accounts`, `PUT /api/accounts/{id}`, `DELETE /api/accounts/{id}`, `GET /api/accounts/{id}/activity`

### Authorization
`Invoices.Backend/Src/Invoices.Api/Controllers/AuthorizationController.cs` and `Tofu.Auth.Backend/src/Tofu.Auth.Api/Controllers/AuthorizationController.cs`
- `GET /authorization/permissions`, `GET /authorization/roles`

### Plans
`Invoices.Backend/Src/Invoices.Api/Controllers/PlansController.cs`
- `GET /api/plans/active`, `POST /api/plans/upgrade-links`, `GET /api/plans/subscription-management-link`

### Reports
`Invoices.Backend/Src/Invoices.Api/Controllers/ReportsController.cs:18` (see §6)

### Teams / invitations
`Invoices.Backend/Src/Invoices.Api/Controllers/TeamController.cs`, `Tofu.Auth.Backend/src/Tofu.Auth.Api/Controllers/InvitationsController.cs`

### Chat
`Invoices.Backend/Src/Invoices.Api/Controllers/ChatController.cs:17`
- `GET /api/chat`, `POST /api/chat/ask`

### Business data CRUD
`InvoicesController`, `EstimatesController`, `ClientsController`, `JobsController` — all scoped by `AccountId`.

## 10. Existing AI / ML / LLM scaffolding

- **Chat proxy** — `ChatController.cs:17` → external `Tofu.AI.Api` (named HttpClient, base address + 100s timeout, Polly retries — `Invoices.Backend/Src/Invoices.Api/DI/ExternalServicesConfiguration.cs:135`). No LLM SDKs in this repo.
- **`feature/ai_summary` branch** — DeepSeek-based FSM compatibility classifier. `PUT /api/jobs/ai-summary` endpoint. Documented in `Tofu.Docs/features/ai_summary/`. *(Branch dropped per the feature owner; WEB-1523 builds fresh.)*
- **Analytics events** — `Invoices.Backend/Src/Invoices.Analytics/AnalyticsService.cs:9` pushes events with payload `{productKey, eventType, payload: {occuredAt, userId, accountId, properties, userProperties}}` — could feed downstream ML.
- No OpenAI / Anthropic / Gemini SDK imports. No vector DB. No embeddings. No prompt store.

## 11. Tofu.Docs paths (related)

**User / auth**
- `Backend/Services/Invoices.Backend/Users.md`
- `Backend/Services/Invoices.Backend/Accounts.md`
- `Backend/Domain/users.md`
- `Backend/HowTo/Authentication.md`
- `Backend/Flows/AUTHENTICATION_FLOW.md`, `Backend/Flows/OTP_FLOW.md`

**Authorization**
- `Backend/Domain/permissions-architecture.md`, `Backend/Domain/permissions-migration-plan.md`
- `Backend/HowTo/Authorization.md`
- `Backend/Services/Tofu.Auth/API.md`, `Backend/Services/Tofu.Auth/Roles_and_Tenants.md`, `Backend/Services/Tofu.Auth/WorkerRoles.md`

**Plans / billing**
- `Backend/Domain/plans-stripe.md`
- `Backend/Services/Invoices.Backend/SubscriptionProductIds.md`

**Business data**
- `Backend/Services/Tofu.Invoices/API.md`, `Backend/Services/Tofu.Invoices/Activity.md`
- `Backend/Domain/reports.md`

**Features**
- `features/ai_summary/` — prior AI work *(branch dropped)*
- `features/jobs/`, `features/subscription/`, `features/account_filtering/`

## 12. Gaps for AI-powered user analysis

**Persistence**
1. No `UserMetrics` / `UserHealth` table — no health score, churn risk, engagement score
2. No `UserCohort` / segmentation model
3. No per-user revenue aggregate persisted (ad-hoc compute only)
4. No activation KPI table — `OnboardingStatus` exists but no aggregates (DaysToFirstInvoice, StepsCompleted%)
5. No NPS / CSAT / feedback model
6. No `UserAttributeChange` audit log (timezone/currency/plan changes invisible)
7. No in-app event stream — feature usage (PDF export, email send, payment accept) not tracked at user level
8. No conversion-funnel materialization (trial → paid → renewal → cancel)

**Infrastructure**
9. No real-time event bus (no Kafka / Pub/Sub) — events live in DBs only
10. No feature store — features computed ad-hoc per request
11. No user-graph / org-hierarchy beyond `OwnedAccounts[]` and `TenantRole`
12. No prediction models (churn / expansion)
13. No RFM scoring / propensity models

**Operational**
14. No clickstream / API-call sequence tracking
15. No error-aggregation per user (friction signal)
16. No cohort-retention table

---

# Part B — AI use-case option space

We already have one AI use case scoped — **FSM-fit scoring** for invoice-only users. This maps the wider option space: what other AI analyses do comparable SaaS / invoicing / FSM / SMB-finance products ship today, and which of them are actually feasible given the data inventory in **Part A** (Account / Subscription / invoice-estimate-job entities and events / SendGrid engagement / `AccountIdentifiers` / external billing & attribution IDs). This is option-mapping, not v1 scope selection.

## 13. Summary table

| Use case | Real-world examples | Our data sufficient? | Notes |
|---|---|---|---|
| FSM-fit scoring (already scoped — v1) | — | ✅ | covered in [`fsm-fit/scoring.md`](fsm-fit/scoring.md) + [`fsm-fit/training.md`](fsm-fit/training.md) |
| Vertical / industry classification | Breeze (ex-Clearbit), Census BEACON | ✅ | `BusinessName` + invoice `Items[]` text → NAICS-style label |
| Voluntary churn / cancellation risk | Salesforce Einstein, Gainsight, ChartMogul | ✅ | `AccountSubscription` lifecycle + `InvoiceEvent` + `EmailStatus` are the standard inputs |
| Involuntary churn / dunning risk | Recurly, Stripe Smart Retries, Cleverbridge | ⚠️ | We see `IsAutoRenewEnabled` and `AdapterType` but billing retry telemetry lives at AppStore / GooglePlay / Stripe — not in our store |
| Expansion / upgrade candidacy | HubSpot Predictive Lead Scoring, Einstein, Amplitude Predictive Cohorts | ✅ | Invoice volume / item velocity / multi-staff signals → tier-up score |
| Plan-mismatch (over- or under-paying) | Stripe Sigma, AWS Cost Explorer, GCP Recommender | ✅ | `Plan` entitlements vs. observed usage from invoice/job events |
| Activation / onboarding success | Pendo, Userpilot, Amplitude Nova AutoML | ✅ | `OnboardingStatus.Steps[]`, `FirstInvoiceId`, `ModalDismissals[]` |
| Engagement health (R/Y/G) | Gainsight, ChurnZero, Vitally, Planhat | ⚠️ | We have invoice/estimate/job/email events; lack in-app screen-view stream typical of CSMs |
| Suspicious / fraud user detection | Stripe Radar, Sift, Sardine, Adyen | ❌ | Need device fingerprint, IP graph, login telemetry beyond `AccountIdentifiers` / `CreatedIP` |
| Anomaly detection (business-level) | QuickBooks Intuit Assist, Zoho Zia, NetSuite | ✅ | Period-over-period invoice/payment/job spikes per account |
| Support-risk / likely-to-ticket | Intercom Fin, Zendesk AI | ❌ | We have no ticket history / chat transcripts |
| Next-best-action / intervention timing | HubSpot, Einstein NBA, Sequenzy | ⚠️ | Doable as a thin recommender on top of churn/expansion/activation scores; no rich CRM features |
| Lookalike-user expansion (marketing) | Meta / Google LAL, Stripe Atlas, Common Room | ⚠️ | Seed pool fine; activation depends on getting traits to ad networks (AppsFlyer/Firebase IDs help) |
| Sentiment from invoice notes / emails | Generic NLP (Azure / Lexalytics / OpenAI) | ⚠️ | Notes are short, sparse, often blank — usable as a weak feature, not a primary signal |

Legend: ✅ have-the-data, ⚠️ partial / weak signal or needs cleanup, ❌ wrong shape / missing key inputs.

## 14. Per-use-case detail

### Vertical / industry classification
Auto-tag a user's business type (e.g. "HVAC", "Photographer", "Cleaning") from `Account.BusinessName` plus the bag-of-words of `Invoice.Items[]` line descriptions. Census Bureau's BEACON tool ranks NAICS codes from a free-text business description, and Breeze Intelligence (the rebranded Clearbit) ships 6-digit NAICS as a primary enrichment attribute [Source: https://github.com/uscensusbureau/BEACON] [Source: https://clearbit.com/]. Output: a NAICS-like label + confidence, or a coarser internal vertical taxonomy that downstream features (FSM-fit, expansion, benchmarking) can key off. Feasible — `BusinessName` and items text are the canonical inputs; an LLM zero/few-shot classifier on item text already works, no new data required. ✅

### Voluntary churn / cancellation risk
Predict probability that an active `AccountSubscription` won't renew or will downgrade. Salesforce Einstein and Gainsight build account health from "login frequency, transaction volume changes, support ticket sentiment, feature adoption rates, payment failures" [Source: https://help.salesforce.com/s/articleView?id=ind.comms_churn_predictions_for_communications_with_einstein_discovery.htm] [Source: https://www.gainsight.com/blog/customer-health-scores/]. We have direct equivalents: invoice send/payment cadence (`InvoiceEvent`), estimate→invoice conversion (`EstimateEvent`), job throughput (`JobEvent`), email engagement decay (`EmailStatus` rolling-window opens/clicks), and subscription lifecycle on `AccountSubscription`. Output: per-account 0–1 score + reason codes. ✅

### Involuntary churn / dunning risk
Predict failed-renewal events ahead of the bill. Recurly's 2025 forecast pegged failed payments at $129B and AI retry tools claim 2–4× recovery vs. rules [Source: https://www.slickerhq.com/resources/blog/129-billion-problem-recurly-2025-involuntary-churn-forecast-ai-recovery-engines]. Our `AccountSubscription` has `AdapterType` (AppStore/GooglePlay/Stripe) and `IsAutoRenewEnabled`, but the actual retry / decline-code stream lives in those external systems — Stripe Smart Retries and store-side billing don't expose decline reasons consistently to the merchant app. ⚠️ — usable as a coarse signal (auto-renew off + nearing period end) but a real model needs Stripe webhook ingestion, App Store Server Notifications v2, RTDN from Google Play.

### Expansion / upgrade candidacy
Predict who's ready for a higher plan tier or add-on. HubSpot's predictive lead scoring outputs a 0–100 "likelihood to close" + priority tier from behavioural+firmographic data; Amplitude's Nova AutoML emits a per-user probability for any chosen target action [Source: https://www.hubspot.com/products/marketing/lead-scoring] [Source: https://amplitude.com/docs/data/audiences/predictions-use]. We have strong proxies for "outgrowing the plan": invoice count per month, distinct clients (`Client` count), distinct items, multi-`technician` job assignments, attachment usage, multiple `MasterUser` identities on one `Account`. Target label = observed plan upgrade in `AccountSubscription` history. ✅

### Plan-mismatch detection
Two flavours: (a) **overpaying** — on `FsmTeam` but using only solo features; (b) **underpaying / hitting limits** — heavy invoice send volume on `Invoicing` tier. Stripe Sigma and the major hyperscaler "right-sizing" tools (AWS Cost Explorer, GCP Recommender) ship this pattern as canned recs [Source: https://stripe.com/sigma]. We have `Plan` entitlements and the operational truth (invoices/estimates/jobs/clients counts), so this is essentially a feature-vs-quota diff with a usage-trend overlay. ✅

### Activation / onboarding success scoring
Predict whether a new account will reach "first invoice sent" (or a richer "habituated" milestone) within N days. Pendo and Userpilot ship this on event streams; Amplitude offers it via Nova [Source: https://amplitude.com/docs/data/audiences/predictions-use]. Our `OnboardingStatus.Steps[]`, `FirstInvoiceId`, `IsExperiencedUser`, `ModalDismissals[]`, plus the first 7-day slice of `InvoiceEvent` / `EstimateEvent`, give us a clean training set. Output: per-new-account activation probability + the missing step likely to unblock them. ✅

### Engagement health (R/Y/G)
Composite per-account health pulse. Gainsight's 2025 Pulse report claims 27% lower gross churn vs. rule-based scoring, with sentiment from unstructured conversations as the biggest 2026 lift [Source: https://www.gainsight.com/blog/customer-health-scores/]. We have business-event streams (`InvoiceEvent`/`EstimateEvent`/`JobEvent`) and `EmailStatus` but **no in-app feature-usage event stream** of the form Pendo/Heap/Amplitude assume — clicks, screens, dwell time. ⚠️ — viable as a "business-activity health" score (are they invoicing more or less than last month?), not a true product-engagement health score until an in-app event pipe is added.

### Suspicious / fraud user detection
Stripe Radar runs on $1T+ payment volume with a "Payments Foundation Model" lifting attack detection on large users from 59% → 97%; Sardine/Sift rely on device fingerprints, behavioural biometrics, emulator detection, and consortium intelligence to catch multi-accounting and free-trial abuse [Source: https://stripe.com/radar] [Source: https://www.sardine.ai/blog/device-fingerprinting] [Source: https://sift.com/platform/]. Our `AccountIdentifiers` carries `Platform`, `AppVersion`, `AppsflyerId`, `FirebaseId`, `Idfa`, and `Account.CreatedIP` — that is **not** a device fingerprint and gives us no IP graph, no emulator/VM signal, no behavioural biometrics. ❌ for fraud-detection in the Radar/Sardine sense. We could ship a much narrower **abuse heuristic** (multiple accounts sharing `Idfa` / `FirebaseId` / `CreatedIP`, anonymous Tofu.Auth user with high invoice volume to test client emails) but it's rules-with-light-ML, not "fraud detection".

### Anomaly detection (business-level, not fraud)
Different problem — flag unusual patterns in a user's *own* business activity. QuickBooks Intuit Assist's Accounting Agent flags period-over-period changes with root-cause attribution; Zoho Zia and NetSuite ship the same pattern [Source: https://www.firmofthefuture.com/artificial-intelligence/quickbooks-anomaly-detection/] [Source: https://www.zoho.com/blog/general/zoho-finance-ai-features.html]. We have rich per-account time series (invoice count/value, estimate conversion rate, payment latency, refund rate, email bounce rate) — classic STL / Prophet / IsolationForest territory. Output: "Account X had 3.2× normal refund volume this week". ✅ Worth distinguishing from fraud — anomaly here is a *helpful* signal to the user, not a risk flag against them.

### Support-risk / likely-to-ticket
Intercom Fin and Zendesk AI score and deflect tickets — Forrester '25 has Zendesk AI at ~38% deflection, Fin at ~50% resolution [Source: https://www.intercom.com/compare-intercom-vs-zendesk]. The signal these models train on is ticket history + chat transcripts + help-centre search logs. We don't have any of that in the entities listed (no `Ticket`, no chat transcript table, no help-centre log). ❌ — would require ingesting whatever support tool we run (Zendesk/Intercom/Helpshift) before this is feasible.

### Next-best-action / intervention recommendation
Einstein Next Best Action and HubSpot ship per-contact recs; Sequenzy markets AI sequences keyed off "reduce churn for monthly subscribers" / "convert trial users" [Source: https://www.sequenzy.com/blog/best-ai-email-marketing-tools]. This is a meta-feature: it composes outputs of churn-risk, expansion, activation, plan-mismatch into a single action queue. Feasibility tracks the underlying scores. ⚠️ — only as good as the scores feeding it, and "send-time optimisation" research suggests you need ≥1000 engaged users per cohort before per-user STO beats the global best-time.

### Lookalike-user expansion
Standard marketing playbook — feed a seed of "best users" to Meta/Google/LinkedIn and expand. Lookalike algorithms typically want ≥1000-user seeds and recover better with rich firmographics [Source: https://medium.com/adobetech/look-alike-audiences-ai-enabled-audience-expansion-in-real-time-cdp-e143a1ce93de]. We have the seed (long-tenured / FSM-paying accounts), and `AppsflyerId` / `FirebaseId` / `Idfa` make activation against ad networks possible. ⚠️ — feasible but is a marketing-ops feature, not really an in-app AI surface.

### Sentiment from communications
Sentiment on invoice notes / email body / item descriptions. Generic NLP / LLM tooling makes this trivially possible at the model level. The data problem is volume and signal: invoice `Notes` are typically blank or short, item descriptions are templated, and we don't store outbound email *body* text in `EmailStatus` (only Sent/Delivered/Opened/Clicked/Bounced/Dropped/SpamReport/Unsubscribe events). ⚠️ — usable as a weak side feature into churn or support-risk models, not a standalone product surface.

## 15. Bottom line — use-case feasibility

**Most achievable from current data, no new ingestion needed:** vertical classification, voluntary churn risk, expansion candidacy, plan-mismatch, activation scoring, business-anomaly detection. These are well-documented patterns from Einstein/HubSpot/Gainsight/Amplitude/QuickBooks, and the inputs they want (subscription lifecycle, invoice/estimate/job events, email engagement, onboarding state) are exactly what we store.

**Big-value but blocked by data shape:** fraud detection (needs device fingerprint + IP graph), support-risk (needs ticket history), classic product-engagement health (needs an in-app event stream). Each is a separate ingestion project before any model work is worth attempting.

**Soft / composable:** next-best-action and lookalike expansion are wrappers — they only make sense once we have a couple of the primary scores live. Sentiment is an enrichment feature, not a product on its own.

---

# Investigation summary

**Strong foundations for v1 (FSM-fit):** dual-model identity (`MasterUser` + `Tofu.Auth User`), multi-provider subscription tracking (App Store / Google Play / Stripe), full business-data history (invoices, estimates, jobs, clients, items) with event audit logs (`InvoiceEvent`, `EstimateEvent`, `JobEvent`), email engagement tracking (`EmailStatus`), and **FS plan tiers already encoded** (`ProductType.FsmSolo / FsmTeam / FsmBusiness`).

**v1 scope reminder — FSM-fit only, invoice-only audience:** the audience is invoice-only users (proposing FSM to them), so jobs/visits/technician data is **out of scope as input**. FSM-fit must come from invoice-only signal — strongest candidates are invoice item text (line-item descriptions), business name, repeat-client patterns, and invoice frequency/amount distributions. The FS plan SKUs (`FsmSolo` / `FsmTeam` / `FsmBusiness`) and Jobs domain remain useful as reference for what FS users look like, but their data does not feed the analysis prompt.

**Adjacent use cases for v2+:** of the 13 use cases mapped in Part B, six are ✅ feasible today on existing data (vertical classification, voluntary churn, expansion, plan-mismatch, activation, business anomaly). These are natural extensions once FSM-fit is shipped and the analysis infrastructure (`Tofu.AI.Backend` per [`../service.md`](../service.md), shared `account_metrics` + per-analysis `account_<type>` tables + `v_<type>` views per [`../storage.md`](../storage.md)) is in place — each is a new `analysis_type` = one folder + one table + one view, **no edits to framework code or existing analyses' tables**.

**Notable gaps that block other use cases:** no materialized per-user metrics, no in-app feature-usage event stream, no ticket history, no device fingerprint. Each is a separate ingestion / instrumentation project before the corresponding AI feature is feasible — not on the WEB-1523 v1 critical path.
