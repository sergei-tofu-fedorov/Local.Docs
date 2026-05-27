# Proposed Authorization Model

---

## Two Dimensions — One Registry

Every API action has two access conditions: **role** (who is this user?) and **plan** (what did this account pay for?). Both must pass.

A **unified Access Registry** defines both conditions per action in one place:

```
Access Registry (static, in shared NuGet)
┌──────────────────────────────────────────────────────────────┐
│  "invoice.create"                                            │
│     roles: [Admin]                                           │
│     plans: [Plus, Premium, Invoicing, FsmSolo, FsmTeam,     │
│             FsmBusiness, Starter]                             │
│                                                              │
│  "job.create"                                                │
│     roles: [Admin]                                           │
│     plans: [FsmSolo, FsmTeam, FsmBusiness]                   │
│                                                              │
│  "worker.invite"                                             │
│     roles: [Admin]                                           │
│     plans: [FsmSolo, FsmTeam, FsmBusiness]                   │
│     quota: WorkerSeats                                       │
│                                                              │
│  "visit.update"                                              │
│     roles: [Admin, Worker]                                   │
│     plans: [FsmSolo, FsmTeam, FsmBusiness]                   │
└──────────────────────────────────────────────────────────────┘
```

At runtime, the middleware resolves:
1. User's **role** (from Tofu.Auth, cached)
2. Account's **plan** per product (from subscription via Subz, cached)
3. Looks up the action in the registry → checks both conditions → 403 or proceed

**Why a single registry?** One source of truth for "who can do what under which plan." One `[AuthorizeAction("job.create")]` on an endpoint is enough — the registry knows it requires Admin role AND an FSM plan.

**Why still two dimensions internally?** The denial reason matters for clients:
- Role denial → "You don't have permission" (contact your admin)
- Plan denial → "Upgrade your plan" (show paywall with upsell info: `requiredPlan`, `currentPlan`)

The registry stores both conditions, and the middleware returns different error codes depending on which condition failed.

### Existing Permission Naming Standard (Tofu.Auth)

Tofu.Auth already defines a permission naming convention (see `Permissions.cs` and `PermissionRegistry` table):

```
Pattern: {resource}.{action}[.{subaction}]
Case: lowercase, dot-separated
Max depth: 4 levels
```

Existing keys in Tofu.Auth: `invoice.view`, `invoice.create`, `invoice.edit`, `invoice.delete`, `invoice.email.send`, `invoice.list`, `user.roles.assign`

New keys follow the same pattern: `job.create`, `job.edit`, `job.delete`, `visit.assign`, `visit.update`, `worker.invite`, `estimate.create`, `analytics.view`, etc.

---

## Account Access Model (DDD)

`AccountAccess` is a value object representing the resolved subscription state for an account, **scoped per product**. An account can have different subscriptions per product (e.g., Invoicing plan for "invoices" product, FsmTeam for "tofu-fieldservice" product). The middleware resolves `AccountAccess` based on the `ProductKey` from the request.

```
AccountAccess (Value Object, per product)
├── ProductKey: string                    // "invoices", "tofu", "tofu-fieldservice"
├── PlanTier: ProductType                 // FsmTeam, Premium, Plus, etc.
├── IsActive: bool                        // Subscription is active (paid or trial)
├── Features: HashSet<Feature>            // Enabled features for this plan
├── Limits: Dictionary<Quota, int>        // Numeric limits
│   ├── WorkerSeats: 5
│   ├── EmailsPerDay: 100
│   └── FreeJobs: 0 (or 3 for Starter)
└── Methods:
    ├── HasFeature(Feature) → bool
    ├── GetLimit(Quota) → int
    ├── CanInviteWorker(currentCount) → bool
    └── IsActive → bool
```

The middleware determines `IsActive` from the subscription's `IsActive` field in `AccountSubscription`. No separate trial/grace/expired states — a subscription is either active or not. This keeps the model simple and aligned with how Subz already works.

```
Feature (Enum)
├── Invoicing           // Create/send invoices
├── Estimates           // Create/send estimates
├── Jobs                // Job management
├── WorkerManagement    // Invite/manage workers
├── Scheduling          // Visit scheduling
├── Payments            // Payment processing
├── Analytics           // Business analytics
└── EmailSending        // Send via email providers

Quota (Enum)
├── WorkerSeats
├── EmailsPerDay
├── FreeJobs
├── ...
```

---

## Subscription Resolution Path

How the middleware resolves which plan an account is on. This is important because the subscription system uses `platUserId` (platform user ID), not `accountId` directly.

```
HTTP Request (AccountId + ProductKey from headers)
    │
    ├── Path A: Authenticated user (Bearer token)
    │   → MasterUser loaded from MongoDB
    │   → MasterUser.PlatformUserLinks.Where(IsFirstLink)
    │   → ProductUser(PlatformId, Product) for each link
    │
    ├── Path B: Signature auth (AccountIdWithSignature)
    │   → AccountIdentifiers collection (MongoDB)
    │   → AccountIdentifiers.UserId = platUserId
    │   → ProductUser(platUserId, ProductKey)
    │
    └── Both paths converge:
        → SubscriptionService.GetSubscriptions(platUserId, productKey)
        → Subz API: /api/accounts/{SHA256(platUserId)|productKey}/subscriptions
        → AccountSubscription[] returned
        → Select primary: active subs ordered by ProductType priority, then ExpirationTime
        → Map to AccountAccess value object via FeatureMatrix
```

Key identifiers in the chain:

| Identifier | Source | Purpose |
|-----------|--------|---------|
| `AccountId` | HTTP header | Tenant identifier |
| `ProductKey` | HTTP header | Product ("invoices", "tofu", "tofu-fieldservice") |
| `PlatUserId` | `PlatformUserLink.PlatformId` or `AccountIdentifiers.UserId` | Subscription owner |
| `ProductType` | Mapped from `AccountSubscription.ProductId` | Plan tier (FsmTeam, Invoicing, Plus, Premium, etc.) |

The `IAccessProvider` interface (see Phase 1) must handle this resolution — the shared NuGet defines the interface, and each host provides the implementation that knows how to get from `AccountId` + `ProductKey` to `AccountAccess`.

---

## Feature Matrix (Codified)

Derived from Notion product specs, code analysis, and Tofu.Docs. All 7 tiers are listed explicitly — Plus and Premium are kept as separate tiers (not mapped to Invoicing/FsmSolo).

Plus and Premium are Invoice Maker (IM) tiers. FsmSolo/FsmTeam/FsmBusiness are FSM tiers. Where behavior differs between products, the cell shows `IM: X / FSM: Y`.

| Feature | Starter | Plus | Premium | Invoicing | FsmSolo | FsmTeam | FsmBusiness |
|---------|---------|------|---------|-----------|---------|---------|-------------|
| Invoicing | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Estimates | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| PhotosAndThemes | No | No | IM: Yes / FSM: No | No | Yes | Yes | Yes |
| MultiBusiness | No | No | No | No | Yes | Yes | Yes |
| Jobs | IM: No / FSM: 3 free | No | No | No | Yes (unlimited) | Yes (unlimited) | Yes (unlimited) |
| WorkerManagement | No | No | No | No | Yes (1 seat) | Yes (5 seats) | Yes (10 seats) |
| Scheduling | No | No | No | No | Yes | Yes | Yes |
| StatusTracking | No | No | No | No | Yes | Yes | Yes |
| ActivityLog | No | No | No | No | Yes | Yes | Yes |
| WorkerMobileApp | No | No | No | No | Yes | Yes | Yes |
| EmailSending | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Analytics | No | No | No | No | No | Yes | Yes |

> Source: [Notion — Маппинг тарифов](https://www.notion.so/tofu-com/2c657d1d286980419d58f46827674ddc)

| Quota | Starter | Plus | Premium | Invoicing | FsmSolo | FsmTeam | FsmBusiness |
|-------|---------|------|---------|-----------|---------|---------|-------------|
| WorkerSeats | 0 | 0 | 0 | 0 | 1 | 5 | 10 |
| EmailsPerDay (web) | 20 | 20 | 20 | 20 | 20 | 20 | 20 |
| EmailsPerDay (mobile) | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| FreeJobs | 3 | 0 | 0 | 0 | unlimited | unlimited | unlimited |

> **FreeJobs quota**: only meaningful when the Jobs feature is enabled. For plans where Jobs feature is disabled, FreeJobs = 0 means "no jobs at all" — the feature-level check blocks before the quota is ever evaluated. For Starter, FreeJobs = 3 means "up to 3 jobs allowed" (Jobs feature is implicitly enabled for the limited quota).

---

## Access Registry — Full Permission Map

Each permission key defines **which roles** can perform it and **which plans** include it (explicit list).

| Permission Key | Roles | Plans | Quota | Notes |
|---------------|-------|-------|-------|-------|
| `invoice.view` | Admin, Worker | All | — | Workers: read-only |
| `invoice.create` | Admin | All | — | Covers create, edit, build-preview, web-link |
| `invoice.delete` | Admin | All | — | |
| `invoice.email.send` | Admin | All | EmailsPerDay | |
| `estimate.view` | Admin | All | — | |
| `estimate.create` | Admin | All | — | Covers create, edit, build-preview, web-link |
| `job.view` | Admin, Worker | Starter, FsmSolo, FsmTeam, FsmBusiness | — | Worker: assigned only. Starter: up to FreeJobs quota |
| `job.create` | Admin | FsmSolo, FsmTeam, FsmBusiness | FreeJobs (Starter) | |
| `job.delete` | Admin | FsmSolo, FsmTeam, FsmBusiness | — | |
| `visit.update` | Admin, Worker | FsmSolo, FsmTeam, FsmBusiness | — | Worker: assigned visits only |
| `worker.invite` | Admin | FsmSolo, FsmTeam, FsmBusiness | WorkerSeats | |
| `worker.view` | Admin | FsmSolo, FsmTeam, FsmBusiness | — | Also covers invitation list, team member details |
| `worker.remove` | Admin | FsmSolo, FsmTeam, FsmBusiness | — | |
| `worker.self` | Admin, Worker | All | — | Worker self-service: my visits, businesses, invitations |
| `user.roles.assign` | Admin | FsmSolo, FsmTeam, FsmBusiness | — | |
| `analytics.view` | Admin | FsmTeam, FsmBusiness | — | |
| `photo.upload` | Admin, Worker | Premium, FsmSolo, FsmTeam, FsmBusiness | — | |
| `client.manage` | Admin | All | — | All client CRUD |
| `item.manage` | Admin | All | — | All item CRUD |
| `tax.manage` | Admin | All | — | |
| `report.view` | Admin | All | — | Reports + export |
| `report.send` | Admin | All | EmailsPerDay | Send report via email |
| `billing.manage` | Admin | All | — | Payments, payouts, Stripe, tap2pay, plan management |
| `account.settings` | Admin | All | — | Account config, templates, logo, chat |

**"All"** = Starter, Plus, Premium, Invoicing, FsmSolo, FsmTeam, FsmBusiness.

> Full endpoint-to-key mapping: [endpoint_authorization_map.md](endpoint_authorization_map.md#action-key-summary)

This registry is the single source of truth. Phase 2 adds Manager and Subcontractor columns.
