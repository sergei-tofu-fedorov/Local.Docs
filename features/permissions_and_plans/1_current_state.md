# Current State — Roles, Permissions & Feature Gating

Detailed analysis of the current authorization and feature gating implementation across all platforms.

---

## Identity Model

```
MasterUser (MongoDB, Invoices.Backend)         Tofu.Auth (PostgreSQL)
├── PlatformUserLinks[]                        ├── Users
├── OwnedAccounts[]                            ├── Roles (Admin=1, Worker=2)
│   ├── AccountId                              ├── RolePermissions
│   └── TenantRole (null=Admin, "Worker")      ├── UserTenantRoles (UserId+TenantId→RoleId)
└── MemberAccounts[]                           └── InvitationTokens
```

**Key constraint**: One role per user per tenant. `TenantRole = null` means owner/admin.

## Current Roles

| Role | Level | Source | Permissions |
|------|-------|--------|-------------|
| **Admin** | 1 | Implicit (account owner) or assigned | All 7 permission keys |
| **Worker** | 2 | Via invitation acceptance | `invoice.view`, `invoice.list` only |

## Current Permission Keys (Tofu.Auth)

| Key | Admin | Worker |
|-----|-------|--------|
| `invoice.view` | Yes | Yes |
| `invoice.list` | Yes | Yes |
| `invoice.create` | Yes | No |
| `invoice.edit` | Yes | No |
| `invoice.delete` | Yes | No |
| `invoice.email.send` | Yes | No |
| `user.roles.assign` | Yes | No |

**Pattern**: `{resource}.{action}[.{subaction}]` — lowercase, dot-separated.

## Permission & Feature Gating — Current Implementation by Platform

### Backend (Invoices.Backend)

- `GET /me/permissions` endpoint works — calls `ITofuAuthApiClient.GetMyPermissionsAsync()`, returns `Ability[]`
- `[Authorize(Policy = Policy.UserHasActiveSubscription)]` exists but is **commented out** on all endpoints (InvoicesController lines 115-120)
- `ActiveSubscriptionAuthorizationHandler` is configured in DI but no controllers reference it
- `AccountIdWithSignature` auth type **bypasses all subscription checks**
- **No middleware checks permissions** before endpoint execution — authentication only, no authorization

**Key files**: `AuthorizationController.cs`, `AuthorizationInstaller.cs`, `ActiveSubscriptionAuthorizationHandler.cs`, `AccountAuthenticationMiddleware.cs`

### Web Frontend (Tofu.Web.Frontend)

**Two-layer permission system:**

1. **User Role (ADMIN/WORKER)** — fetched via `GET /me/permissions`:
   - Determines role by checking for `user.roles.assign` ability → ADMIN, else WORKER
   - `$isWorker` store gates between admin/worker router (hard gate)
   - Workers see only `WorkerController`-served data

2. **Subscription Plan** — via CASL (`@casl/ability`):
   - `defineRulesForUser(planId, isActive)` builds cumulative ability set per plan tier
   - Plan hierarchy: `Plus(1) < Premium(2) ≈ Invoicing(2) < FSMSolo(3) < FSMTeam(4) < FSMBusiness(5)`
   - `<PaywallButton subject={Subjects.FSMSolo}>` wraps features — shows paywall if plan insufficient
   - `useCan()` hook provides `can(action, subject)`, `isFree`, `isSolo`, `isTeam`, etc.

**Soft paywall approach**: All routes accessible; features gated per-component, not at route level.

**Claim-first strategy**: Before showing paywall, attempts `POST /Account/claim-email` to link existing subscriptions.

**Feature gate mapping (Web):**

| Feature | Required Plan | Component |
|---------|--------------|-----------|
| Export invoices CSV/PDF | Plus | `PaywallButton(Subjects.Plus)` |
| Create estimates | Premium | `EstimatesPaywallButton` |
| Send/download/print estimate | Premium | `PaywallButton(Subjects.Premium)` |
| Photo attachments | Premium | `PaywallButton(Subjects.Premium)` |
| Professional templates | Premium | `PaywallButton(Subjects.Premium)` |
| Create jobs | FSMSolo | `JobsPaywallButton` |
| 3+ jobs (free limit) | FSMSolo | `FreeJobsLimitBanner` + `featureCheck` |
| Workers/team (5+) | FSMTeam | `WorkersLimitBanner` |
| Watermark removal | Any active | `useWatermark()` → `!$isSubscriptionActive` |

**Key files**: `src/shared/lib/ability/ability.ts`, `src/features/permissions/model/index.ts`, `src/features/paywall/ui/paywall-button/`, `src/app/providers/ability-provider.tsx`

### iOS (Invoices.Apps.iOS)

- **`AccessManager.isFunctionalAvaliable(context:)`** — central feature gate returning `AsyncStream<Bool>`
- `PaywallContext` enum defines all gated features: `createJob`, `addWorker`, `sendInvoice`, `premiumTemplate`, `attachmentInvoice`, `addBusiness`, `exportData`, etc.
- `ActualPlanType` enum: `noPlan(isTrialAvailable)`, `plus`, `premium`, `invoicing`, `fsmSolo`, `fsmTeam`, `fsmBusiness`, `expired`, `billingError`
- `TeamRole` enum (`admin`/`worker`) used for team display, not access control
- Worker seat limits enforced client-side: Solo=1, Team=5, Business=10
- Paywall navigation: `mainPaywall`, `upgradeWorkerPaywall`, `restrictedActiveSubscription`
- **No CASL/ability system** — direct plan-based checks via `AccessManager`

**Key files**: `AccessManager.swift`, `PaywallContext.swift`, `ActualPlanType.swift`, `TeamMember.swift`

### Android (Invoices.Apps.Android)

- **Subscription-only gating** — no role-based system
- `*SubsInfoPort` interface pattern: features call `isSubscribed()` before proceeding
- If not subscribed → `OpenPaywallAction` redirects to paywall
- `UserSubscription` sealed interface: `Inactive`, `Active`, `Expired`
- `PurchaseSource` enum tracks context: `Onboarding`, `SendInvoice`, `SettingsScreen`, `ShowAllPlans`
- No team/worker management in Android app currently
- Feature flags via `Experiments.pricing` for A/B testing plans

**Key files**: `UserSubscription.kt`, `InvoiceSharingSubsInfoPort.kt`, `CheckSubscriptionEpic.kt`, `PaywallScreen.kt`

### Worker App (Tofu.FieldService.WorkerApp — KMP)

- `AuthorizationApi.getPermissions()` defined but **minimally used client-side**
- **Primary access control**: visit filtering by `assignedWorkerId` in all database queries
- Worker ID sourced from `UserData.masterUserId` (Firebase auth)
- Role stored per business/tenant (`BusinessDto.role`) but not enforced client-side
- **No subscription checks** — worker app assumes subscription is valid (admin's responsibility)
- Status-based filtering only: `AllOpen`, `Scheduled`, `PaymentDue`, `Unscheduled`, `Paid`

**Key files**: `AuthorizationApi.kt`, `JobVisitDao.kt`, `WorkerIdProviderImpl.kt`, `WorkerApi.kt`

### Summary: Current State of Each Platform

| Aspect | Backend | Web | iOS | Android | Worker App |
|--------|---------|-----|-----|---------|------------|
| Role checks | None (disabled) | Router gate (admin/worker) | None | None | None |
| Plan gating | None (disabled) | CASL + PaywallButton | AccessManager + PaywallContext | SubsInfoPort + paywall | None |
| Permission API | Serves abilities, no enforcement | Fetches & uses for role | Not used | Not used | Defined, not used |
| Seat enforcement | None | Banner only | Client-side limit | N/A | N/A |
| Server enforcement | **None** | N/A (client) | N/A (client) | N/A (client) | N/A (client) |

## Subscription Tiers & Pricing

| Tier | Priority | Monthly | Annual | Intro | Seats | Product Family |
|------|----------|---------|--------|-------|-------|----------------|
| **Free/Starter** | — | Free | — | — | 0 | — |
| **Invoicing** | 3 | $19/mo | $120/yr | $9 first month | 0 | Invoice Maker |
| **Premium** | 2 | (legacy) | — | — | 0 | Invoice Maker (deprecated) |
| **Plus** | 1 | (base) | — | — | 0 | Invoice Maker |
| **FsmSolo** | 4 | $29/mo | $180/yr | $19 for 3 months | 1 worker | Field Service |
| **FsmTeam** | 5 | $79/mo | $600/yr | $49 first month | 5 workers | Field Service |
| **FsmBusiness** | 6 | $149/mo | $1,200/yr | $99 first month | 10 workers | Field Service |

**Seat counts** are stored in `SeatCount` field on `Offer` and `ProfileSubscription` (Subz).

**Trial strategy:**
- Organic traffic: 7-day free trial (FSM), 3-day free trial (Invoicing)
- Paid ads: 7-day $1.99 trial or 3-day $1.99 trial
- Attribution tracking remembers source for 7 days to prevent trial gaming

## Existing Limits & Quotas

| Limit | Value | Enforcement |
|-------|-------|-------------|
| Email rate (web) | 20/24h per account | Server (`EmailService.Send()`) |
| Email rate (mobile) | 100/24h per account | Server (`EmailService.Send()`) |
| Invitation rate | 20/hour per tenant | Server (Tofu.Auth) |
| Worker seats | 1 (Solo) / 5 (Team) / 10 (Business) | **Not enforced on server** |
| Free jobs (Starter) | 3 | Client-side only |

## Feature Access by Plan (Implicit, Client-Side Only)

| Feature | Free/Starter | Invoicing | FsmSolo | FsmTeam | FsmBusiness |
|---------|-------------|-----------|---------|---------|-------------|
| Create invoices & estimates | Yes | Yes | Yes | Yes | Yes |
| Photos & themes | No | No | Yes | Yes | Yes |
| Multi-business (multiple accounts) | No | No | Yes | Yes | Yes |
| Jobs | 3 free | No | Unlimited | Unlimited | Unlimited |
| Worker management | No | No | 1 worker | 5 workers | 10 workers |
| Worker assignment to visits | No | No | Yes | Yes | Yes |
| Visits/scheduling | No | No | Yes | Yes | Yes |
| Role-based permissions | No | No | Limited | Yes | Yes |
| Status tracking & alerts | No | No | Yes | Yes | Yes |
| Live activity log | No | No | Yes | Yes | Yes |
| Worker mobile app access | No | No | Yes | Yes | Yes |
| Estimate→Job conversion | 3 free | No | Yes | Yes | Yes |
| Email sending | Yes | Yes | Yes | Yes | Yes |

**Key gaps**:
- These restrictions are only enforced in client UI (paywalls/modals). The server has no concept of "this account's plan does not include Jobs."
- Jobs section is hidden in web if subscription came from App Store (mobile-only feature gating — not server-enforced)
- Photos/themes locked behind paywall with lock icon (client-only)
