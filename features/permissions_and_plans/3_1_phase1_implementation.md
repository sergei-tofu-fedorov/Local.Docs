# Phase 1: Shared Library + Access Middleware

## Summary

- Fastest path to server-side enforcement
- Shared NuGet package (`Tofu.Permissions.Shared`) ships access registry, middleware, and authorization context
- Each backend references the package and enforces authorization locally
- Plan resolution via `IAccessProvider` (interface from NuGet, host registers its own implementation)
- Starts in log-only mode, graduates to enforcement after validation
- No data model changes, no new services

---

## 1.1 Create `Tofu.Permissions.Shared` NuGet Package

Shared library referenced by all backends.

```
Tofu.Permissions.Shared/
├── Registry/
│   ├── AccessRegistry.cs             // Unified permission definitions (role + plan per action)
│   ├── AccessRule.cs                 // Single rule: key, roles[], plans[], quota?
│   ├── Features.cs                   // Feature enum
│   └── Quotas.cs                     // Quota enum
├── Models/
│   ├── AccountAccess.cs              // Value object (product-scoped: plan tier, features, limits)
│   └── SubscriptionState.cs          // Active or Inactive
├── Middleware/
│   ├── AccessMiddleware.cs           // Single middleware: resolves role + plan, checks registry
│   └── AccessResult.cs              // Allowed / DeniedByRole / DeniedByPlan
├── Attributes/
│   └── AuthorizeActionAttribute.cs   // [AuthorizeAction("job.create")]
├── Services/
│   ├── IAuthorizationContext.cs      // Imperative checks for complex/conditional logic
│   ├── AuthorizationContext.cs       // Implementation (reads from HttpContext.Features)
│   ├── IAccessProvider.cs            // Interface for resolving AccountAccess from request
│   └── IAccessCacheManager.cs        // Cache invalidation interface + implementation
└── Extensions/
    └── ServiceCollectionExtensions.cs
```

## 1.2 Access Registry

The registry is a static collection of `AccessRule` entries. Each rule defines a permission key and its access conditions — explicit plan list, not a hierarchy:

```csharp
// Pseudocode
AccessRule(key: "job.create",     roles: [Admin],          plans: [FsmSolo, FsmTeam, FsmBusiness])
AccessRule(key: "worker.invite",  roles: [Admin],          plans: [FsmSolo, FsmTeam, FsmBusiness], quota: WorkerSeats)
AccessRule(key: "visit.update",   roles: [Admin, Worker],  plans: [FsmSolo, FsmTeam, FsmBusiness])
AccessRule(key: "invoice.create", roles: [Admin],          plans: All)
```

The full permission map is in [2_authorization_model.md — Access Registry](2_authorization_model.md#access-registry--full-permission-map).

## 1.3 Authorization Usage Patterns

**DI registration** — host provides `IAccessProvider` implementation:

```csharp
// Program.cs (Invoices.Backend)
services.AddTofuAuthorization<PlansAccessProvider>(options => {
    options.EnforcementMode = EnforcementMode.LogOnly;
});

app.UseAuthentication();
app.UseTofuAuthorization();
```

`AddTofuAuthorization<TAccessProvider>()` registers the middleware, `IAuthorizationContext` (scoped), `IAccessCacheManager` (singleton), and the host's `IAccessProvider` implementation.

**Runtime enforcement toggle**: `EnforcementMode` readable from app configuration, not hardcoded:

```
// appsettings.json
"TofuAuthorization": {
    "EnforcementMode": "LogOnly"
}
```

Two modes:
- `LogOnly` — resolve and log violations, never block. For initial rollout.
- `Enforce` — log AND return 403.

This is the primary rollback mechanism: set to `LogOnly` to disable enforcement instantly.

**Declarative (primary)** — attribute on endpoint:

```csharp
[AuthorizeAction("job.create")]
public async Task<IActionResult> CreateJob(...)
{
    // middleware already checked: user has Admin role + account has FsmSolo+ plan
    ...
}
```

The registry knows which roles and plans are required for `job.create` — no need for separate role and feature attributes.

**Imperative (complex cases)** — `IAuthorizationContext` in controller/service:

```csharp
public interface IAuthorizationContext
{
    bool HasPermission(string permissionKey);
    bool HasFeature(Feature feature);
    bool HasRole(Role role);
    bool IsInAnyRole(params Role[] roles);
    int GetQuotaLimit(Quota quota);
    IReadOnlyList<Role> Roles { get; }
    AccountAccess Access { get; }
}
```

Example — worker can only update their own assigned visits:

```csharp
[AuthorizeAction("visit.update")]
public async Task<IActionResult> UpdateVisitStatus(...)
{
    if (authContext.HasRole(Role.Worker))
    {
        var visit = await visitService.Get(request.VisitId);
        if (visit.AssignedWorkerId != currentUser.Id)
            throw new ForbiddenException("Workers can only update assigned visits");
    }
    ...
}
```

`IAuthorizationContext` is populated by middleware from `HttpContext.Features` and injected as a scoped service. Services (not just controllers) can make authorization decisions without depending on HttpContext directly.

**Multi-role design**: `IReadOnlyList<Role> Roles` (not single `CurrentRole`) supports multiple roles per user per tenant in the future. In Phase 1, this list always contains exactly one role. Use `HasRole()` / `IsInAnyRole()` helpers instead of direct equality checks.

## 1.4 Access Middleware (Single Pipeline)

One middleware handles both role and plan checks:

```
Request → Auth Middleware (existing, resolves MasterUser + AccountId)
       → AccessMiddleware (NEW)
           1. Resolve role:
              a. Read TenantRole from MasterUser.OwnedAccount or MemberAccount
              b. Role → permissions mapping is in AccessRegistry (static, no HTTP call)
           2. Resolve plan (product-scoped):
              a. Call IAccessProvider.Resolve(accountId, productKey)
              b. Provider resolves AccountId → platUserId → Subz → AccountAccess
                 (cached 10min)
           3. Store both in HttpContext.Features<AuthorizationState>
       → [AuthorizeAction("job.create")] on endpoint
           → Look up rule in AccessRegistry
           → Check role condition → if fail: 403 (forbidden)
           → Check plan condition → if fail: 403 (featureNotAvailable + upsell info)
           → Check quota if defined → if fail: 400 (quotaExceeded)
           → Proceed
```

**MemberAccounts handling**: When a user accesses a tenant they're a member of (not owner), the role comes from `MasterUser.MemberAccounts[].TenantRole`, not `OwnedAccounts`. The middleware resolves which account relationship type applies based on the `AccountId` in the request context.

## 1.5 IAccessProvider — Subscription Resolution

Interface from NuGet, implementation in host:

```csharp
public interface IAccessProvider
{
    Task<AccountAccess> Resolve(string accountId, string productKey, CancellationToken ct);
}
```

The Invoices.Backend implementation (`PlansAccessProvider`) follows the existing subscription resolution path:

```
AccountId + ProductKey
  → AccountIdentifiers collection (MongoDB) → UserId (= platUserId)
  → OR MasterUser.PlatformUserLinks.Where(IsFirstLink) → PlatformId (= platUserId)
  → SubscriptionService.GetSubscriptions(platUserId, productKey)
  → Subz API: /api/accounts/{SHA256(platUserId)|productKey}/subscriptions
  → AccountSubscription[] → select primary by ProductType priority
  → Map ProductType → AccountAccess via FeatureMatrix
```

This reuses the existing `IPlansService`/`ISubscriptionService` infrastructure. The `PlansAccessProvider` is a thin adapter over `PlansService.GetCurrent()`.

`AccountAccess` is product-scoped — the `productKey` parameter determines which subscription to look up. An account can have different plans for different products.

Key identifiers in the chain:

| Identifier | Source | Purpose |
|-----------|--------|---------|
| `AccountId` | HTTP header | Tenant identifier |
| `ProductKey` | HTTP header | Product ("invoices", "tofu", "tofu-fieldservice") |
| `PlatUserId` | `PlatformUserLink.PlatformId` or `AccountIdentifiers.UserId` | Subscription owner |
| `ProductType` | Mapped from `AccountSubscription.ProductId` via `PlanInfoProvider` | Plan tier |

## 1.6 Cache Invalidation

```csharp
public interface IAccessCacheManager
{
    void InvalidatePermissions(string userId, string tenantId);
    void InvalidateAccess(string accountId);
    void InvalidateAll();
}
```

Use cases: call `InvalidateAccess(accountId)` after a subscription change event, `InvalidatePermissions(userId, tenantId)` after a role change. The middleware re-fetches on the next request.

## 1.7 Endpoint Protection (Invoices.Backend)

**Default policy**: endpoints without `[AuthorizeAction]` are accessible to any authenticated user — no role or plan check.

> Complete endpoint authorization map with exact attributes for all ~180 endpoints across 50 controllers: [endpoint_authorization_map.md](endpoint_authorization_map.md)

## 1.8 Worker Seat Enforcement

Add quota check to invitation flow:

```
POST /api/invitations
  → [AuthorizeAction("worker.invite")]
    Registry checks: role=Admin, plans=[FsmSolo, FsmTeam, FsmBusiness], quota=WorkerSeats
  → Quota check: currentWorkerCount < accountAccess.GetLimit(Quota.WorkerSeats)
  → If exceeded: throw SeatLimitExceededException → 400
```

## 1.9 Error Responses

| Error Code | HTTP | When | Payload |
|------------|------|------|---------|
| `forbidden` | 403 | User's role lacks permission | `{ permissionKey }` |
| `featureNotAvailable` | 403 | Account's plan doesn't include feature | `{ feature, requiredPlan, currentPlan }` |
| `seatLimitExceeded` | 400 | Account has reached worker seat limit | `{ limit, current }` |
| `quotaExceeded` | 429 | Generic quota exceeded | `{ quota, limit, current }` |
| `internalError` | 500 | Tofu.Auth or Subz unreachable | — |

**Upsell info in plan denial**: when a request is denied because of plan tier, the response includes `requiredPlan` and `currentPlan`. Clients show targeted upgrade prompts.

**Downstream service unavailable**: when Tofu.Auth or Subz cannot be reached, return 500 (not 503) — the gateway itself is available, so 503 would be misleading.

Response format (standard error envelope):

```json
{
  "errorCode": "featureNotAvailable",
  "message": "Your current plan does not include this feature",
  "details": {
    "feature": "workerManagement",
    "requiredPlan": "FsmTeam",
    "currentPlan": "FsmSolo"
  }
}
```

---

## 1.10 Rollout Plan

### Implementation Priority

Not all endpoints are equally important. Rollout order by priority:

**P0 — FSM core (first)**
- Jobs, Visits, Workers, Invitations — these are the endpoints where plan-gating matters most (FSM-only features)
- `job.create`, `job.delete`, `visit.update`, `worker.invite`, `worker.view`, `worker.remove`

**P1 — Invoicing core**
- Invoices, Estimates, Email — role-gating (Admin vs Worker) is the main value here
- `invoice.create`, `invoice.delete`, `estimate.create`, `invoice.email.send`

**P2 — Everything else (later)**
- Clients, Items, Reports, Payments, Taxes, Account settings, Billing, Analytics
- These are all Admin-only with no plan restriction — lower risk, lower urgency

### Deployment Sequence

1. **Publish `Tofu.Permissions.Shared` NuGet** — no runtime impact, just a library
2. **Integrate into Invoices.Backend** — add middleware + `PlansAccessProvider` in `LogOnly` mode. Deploy to dev → staging → production. All requests are evaluated but never blocked
3. **Monitor log-only data** for at least 1 week. Analyze:
   - False positives (legitimate requests that would be blocked)
   - Missing permissions (endpoints that need `[AuthorizeAction]` but don't have it)
   - Cache hit/miss ratio, latency impact
4. **Graduated enforcement** — switch specific endpoint groups to `Enforce` one at a time:
   - Start with P0 (Jobs/Workers — cleanest boundaries, FSM-only feature)
   - Then P1 (Invoices/Estimates)
   - P2 can wait or stay in LogOnly
5. **Integrate into Tofu.* microservices** — same sequence: LogOnly → monitor → Enforce

### Per-endpoint enforcement toggle

For graduated enforcement, support per-action overrides in config:

```json
"TofuAuthorization": {
    "EnforcementMode": "LogOnly",
    "Overrides": {
        "job.create": "Enforce",
        "worker.invite": "Enforce"
    }
}
```

This allows enforcing specific actions while keeping the rest in LogOnly.

### Mobile Client Compatibility

**Current state**: None of the mobile apps handle 403 as a permission or paywall trigger. All use client-side plan checks. Since clients already perform these same checks client-side, old app versions will rarely hit server-side 403s in practice — server enforcement is a second line of defense.

| App | Current 403 handling |
|-----|---------------------|
| iOS | Generic `System_HTTP_403` error, no paywall trigger |
| Android | Generic 4xx "client error" message |
| Worker App | `NetworkErrorForbidden` exception with localized string |

**Rollout strategy**:

1. **LogOnly first** — server logs violations but never returns 403. Clients unaffected. This buys time for mobile updates
2. **Ship mobile updates** before switching to Enforce:
   - Detect 403 with `errorCode: "featureNotAvailable"` → show targeted paywall (using `requiredPlan` from response)
   - Detect 403 with `errorCode: "forbidden"` → show "contact your admin" message
   - Worker App: already has `NetworkErrorForbidden` — add proper message for access denials
3. **Minimum client version gate** — before enabling enforcement on an endpoint, verify the latest app store version handles 403. Use `AppVersion` header to skip enforcement for old clients
4. **Old client fallback** — if `AppVersion` is below the minimum, downgrade enforcement to LogOnly for that request. Prevents breaking users on old app versions
