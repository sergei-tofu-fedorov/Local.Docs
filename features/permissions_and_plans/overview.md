# Roles, Permissions & Subscription Feature Gating

**Task**: [WEB-794](https://app.clickup.com/t/24553599/WEB-794)

## Problem Statement

The Tofu platform currently has **no server-side enforcement** of role-based access control or subscription-based feature gating:

1. **Roles exist but are not enforced** — Tofu.Auth stores Admin/Worker roles and permissions, clients fetch them via `GET /permissions`, but no backend endpoint actually checks them. Any authenticated user can call any endpoint.
2. **No plan-based feature gating on server** — subscription tiers (Plus through FsmBusiness) determine pricing and seat counts, but there is no mechanism to restrict features based on the account's active plan. Feature access is only controlled client-side (paywall UI).
3. **Dual role storage** — roles live in both MongoDB (`MasterUser.OwnedAccount.TenantRole` as a string) and PostgreSQL (Tofu.Auth `UserTenantRole` with proper model). This creates inconsistency risks.

This document proposes a unified authorization model that combines role-based access with plan-based access, enforced at the server level.

---

## Current State

> Full analysis: [1_current_state.md](1_current_state.md)

Key conclusions from the current state analysis:

- **Zero server-side enforcement** — authentication exists, but no backend endpoint checks roles or subscription tier before executing. Any authenticated user can call any endpoint.
- **Dual role storage** — roles live in MongoDB (`OwnedAccount.TenantRole`) and PostgreSQL (Tofu.Auth `UserTenantRole`), creating inconsistency risk. Only two roles exist: Admin and Worker.
- **Client-only feature gating** — all platforms implement subscription checks in UI (paywalls, banners), but the server has no concept of "this plan does not include feature X." Each platform uses a different mechanism (Web: CASL, iOS: AccessManager, Android: SubsInfoPort, Worker App: none).
- **Permission API works but is unused for enforcement** — `GET /me/permissions` returns abilities, clients fetch them, but no middleware or controller actually blocks requests based on them.
- **Seat limits not enforced** — worker seat counts (Solo=1, Team=5, Business=10) are only checked client-side. Server accepts unlimited worker invitations.
- **`AccountIdWithSignature` auth bypasses everything** — this authentication type skips all subscription and permission checks entirely.
- **7 tiers** — Starter (free), Plus, Premium, Invoicing ($19/mo), FsmSolo ($29/mo), FsmTeam ($79/mo), FsmBusiness ($149/mo).

---

## Gaps Summary

| # | Gap | Risk | Addressed in |
|---|-----|------|-------------|
| G1 | No server-side RBAC enforcement | Workers can call admin-only endpoints directly | Phase 1: unified access registry + middleware |
| G2 | No subscription feature gating on server | Free/low-tier users can access paid features via API | Phase 1: `AccessMiddleware` with plan checks |
| G3 | Worker seat limits not enforced | Accounts can exceed their plan's seat allocation | Phase 1: quota check in invitation flow (1.8) |
| G4 | No Manager role | No intermediate access level between Admin and Worker | Phase 2: new roles via Access Registry (see 2.1) |
| G5 | Dual role storage | Roles in MongoDB may diverge from Tofu.Auth | Phase 2: remove `OwnedAccount.TenantRole` |
| G6 | No structured feature matrix per plan | Feature access per tier not codified anywhere | Phase 1: `AccessRegistry` in shared NuGet |
| G7 | `assignedWorkerId` is just a string | Not linked to actual user/role records | Phase 2: TeamMembers in Tofu.Auth with FK to UserId |

---

## Design Goals

1. **Server-side RBAC** — enforce role-based permissions at API endpoints, not just UI
2. **Plan-based access** — codify what each plan tier includes, enforce on server
3. **Unified access registry** — "Can user X (role=Worker) in account Y (plan=FsmTeam) do action Z?" answered by a single registry that defines both role and plan conditions per action
4. **Product-scoped** — `AccountAccess` is resolved per product (subscription is per-product), preserving the product dimension
5. **Extensible** — new roles (Manager), new plans, new permissions without restructuring
6. **Backwards compatible** — existing clients continue working; enforcement is additive, with mobile client version gating

---

## Proposed Authorization Model

> Full model: [2_authorization_model.md](2_authorization_model.md)

Key design decisions:

- **Unified Access Registry** — each permission key (e.g., `job.create`) defines both required **roles** (e.g., `[Admin]`) and required **plans** (e.g., `[FsmSolo, FsmTeam, FsmBusiness]`) in one place. A single `[AuthorizeAction("job.create")]` attribute on an endpoint is enough — the registry knows both conditions.
- **Two denial reasons** — even though the registry is unified, the denial response distinguishes between role denial ("contact your admin") and plan denial ("upgrade your plan" with upsell info: `requiredPlan`, `currentPlan`). This lets clients show the right message.
- **Product-scoped AccountAccess** — `AccountAccess` is resolved per product (via `ProductKey` from request). An account can have different subscription states per product. The value object carries `ProductKey`, `PlanTier`, `IsActive`, features, and quotas.
- **All 7 tiers explicit** — Plus and Premium are kept as separate plan tiers in the feature matrix and access registry (not mapped to Invoicing/FsmSolo).
- **Simple subscription state** — `IsActive` bool is enough. No separate trial/grace/expired states — a subscription is either active or not, matching how Subz already works.
- **Feature matrix codified in code** — 7 tiers × 12 features + quotas (WorkerSeats, EmailsPerDay, FreeJobs)
- **Permission naming** — follows existing Tofu.Auth standard: `{resource}.{action}[.{subaction}]`, lowercase, dot-separated
- **Subscription resolution documented** — the actual `AccountId → platUserId → Subz → AccountSubscription → AccountAccess` chain is documented, including the SHA256-based account hash

---

## Migration Phases

Two independently shippable phases:

- **[Phase 1 — Shared Library + Access Middleware](3_1_phase1_implementation.md)**: NuGet package (`Tofu.Permissions.Shared`) with access registry, middleware, and authorization context. Single `AccessMiddleware` resolves both role and plan, checks the unified registry. No new services, no data model changes. Starts in log-only mode with graduated enforcement per-endpoint. Prioritized rollout: P0 (Jobs/Workers) → P1 (Invoices/Estimates) → P2 (rest).
- **[Phase 2 — Full RBAC + Identity Hub in Tofu.Auth](3_2_phase2_rbac.md)**: Tofu.Auth becomes single source of truth. `TeamMembers` table added directly in Tofu.Auth (PostgreSQL). Manager role with granular permissions. `PlatformUserLinks` migrates to Tofu.Auth. Roles embedded in JWT claims. Deprecates `OwnedAccount.TenantRole`. Plan to be revisited after Phase 1 implementation.

---

## Phase 1: Implementation Plan

> Full details: [3_1_phase1_implementation.md](3_1_phase1_implementation.md)

Key deliverables:
- `Tofu.Permissions.Shared` NuGet package with `AccessRegistry`, `AccessMiddleware`, `IAuthorizationContext`, and `IAccessProvider` interface
- Unified `AccessMiddleware`: resolves role from OwnedAccount/MemberAccount (already in MasterUser, no extra HTTP call), resolves plan via `IAccessProvider` → product-scoped `AccountAccess` (cached 10min), stores both in `HttpContext.Features`
- Endpoint protection with `[AuthorizeAction("job.create")]` — single attribute, registry holds both role and plan conditions
- Imperative `IAuthorizationContext` for complex logic (worker-only-own-visits, conditional quotas)
- Worker seat enforcement as quota check in invitation flow
- Error codes: `forbidden` (403, role), `featureNotAvailable` (403, plan + upsell info), `seatLimitExceeded` (400), `quotaExceeded` (429), `internalError` (500, downstream service unavailable)
- Log-only mode first, graduated per-endpoint enforcement with config overrides
- Prioritized rollout: P0 (Jobs/Workers) → P1 (Invoices/Estimates) → P2 (rest)
- Mobile client compatibility: old client version gate, 403 handling in upcoming app releases

---

## Phase 2: Full RBAC + Identity Hub in Tofu.Auth

> Full details: [3_2_phase2_rbac.md](3_2_phase2_rbac.md)

Key deliverables:
- Extensible role system — adding new roles (Manager, Subcontractor, etc.) requires only Tofu.Auth seed + Access Registry update (see 2.1)
- `TeamMembers` table directly in Tofu.Auth (PostgreSQL) — single source of truth, no sync needed
- `PlatformUserLinks` migrates from MongoDB to Tofu.Auth
- Roles and permissions embedded in JWT claims
- Deprecate `OwnedAccount.TenantRole`, slim down `MasterUser`

Phase 2 plan will be revisited after Phase 1 implementation — details may change based on Phase 1 learnings.

---

## Testing Considerations

### Key Scenarios

| Scenario | Expected |
|----------|----------|
| Admin + FsmBusiness → create job | 200 OK |
| Worker + FsmBusiness → create job | 403 (role: `forbidden`) |
| Admin + Invoicing → create job | 403 (plan: `featureNotAvailable`, requiredPlan=FsmSolo) |
| Admin + Plus → create job | 403 (plan: `featureNotAvailable`) |
| Admin + FsmTeam → invite 6th worker | 400 (seat limit) |
| Admin + FsmSolo → invite 1st worker | 200 OK (1 seat available) |
| Admin + FsmSolo → invite 2nd worker | 400 (seat limit — only 1 seat) |
| Admin + Invoicing → invite worker | 403 (plan: 0 seats) |
| Worker + any plan → view assigned visits | 200 OK |
| Unauthenticated → any endpoint | 401 |
| Admin + inactive subscription → create invoice | 403 (plan: subscription not active) |
| User accessing another account's data | 403 (horizontal privilege escalation blocked) |
| AccountIdWithSignature → admin-only endpoint | Depends on endpoint classification |
| Request during Tofu.Auth outage (log-only mode) | 200 OK + warning log |
| Request during Tofu.Auth outage (enforcement mode) | 500 Internal Server Error |
| Old mobile client (below min version) + enforcement on | LogOnly fallback for that request |

### Testing Strategy

- **Unit tests**: test `AccessRegistry`, `AccountAccess` value object methods in isolation. Test each plan tier maps to the correct features and limits. Test each permission key resolves to the correct role + plan conditions
- **Integration tests**: test middleware pipeline end-to-end with mock Tofu.Auth and PlansService responses. Cover cache hit/miss, cache invalidation, service unavailability
- **Log-only validation**: before switching from log-only to enforcement, analyze log data for at least 1 week to identify false positives. Establish a threshold (e.g., < 0.1% of requests would be blocked) before enabling enforcement
- **Client compatibility**: verify that iOS, Android, and Worker App handle 403 responses with proper paywall/error messages. Test both `forbidden` and `featureNotAvailable` error codes

---

## Decisions Log

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | No grace period after subscription expires | Not needed for now |
| 2 | Expenses not included in feature matrix | No plans to gate Expenses by plan |
| 3 | Plus and Premium kept as separate tiers | Not mapped to Invoicing/FsmSolo — they are real ProductTypes in the system |
| 4 | 500 (not 503) for downstream service errors | Gateway itself is available; 503 would be misleading |
| 5 | Simple IsActive instead of trial/grace states | Sufficient for Phase 1; can be expanded later if needed |

---

## Related Documentation

- [Permissions Architecture Options](../../Backend/Domain/permissions-architecture.md)
- [Permissions Migration Plan](../../Backend/Domain/permissions-migration-plan.md)
- [Users Domain Model](../../Backend/Domain/users.md)
- [Worker Roles & Invitations](../../Backend/Services/Tofu.Auth/WorkerRoles.md)
- [Worker Permissions Implementation](../jobs/implementation/5_worker_users/5.x_worker_permissions.md)
- [Subscription Product IDs](../../Backend/Services/Invoices.Backend/SubscriptionProductIds.md)
- [Subscription Tier Priority](../jobs/implementation/6_job_from_estimate/6.10_subscription_priority.md)
- [Authorization HowTo](../../Backend/HowTo/Authorization.md)
