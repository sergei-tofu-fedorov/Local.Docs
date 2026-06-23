# Comp Plan Grants (BFF-side trial / free high-tier access)

Status: **DRAFT — for review**
Owner: TBD
Related: `PlansService`, `SubscriptionService`, `PlansAccessProvider`, `FeatureMatrix`

## Goal

Grant a **specific client** trial / free access to a high-tier plan (e.g. `FsmBusiness`,
`Premium`) **without** going through Stripe/Subz billing, such that:

- `GET /api/plans/current` returns the granted plan, and
- server-side feature/quota gating (`PlansAccessProvider` → `FeatureMatrix`) actually unlocks
  the corresponding features and limits.

This is a manual, low-volume, ops-driven capability — not a self-serve trial.

## Why not a real (free) Stripe subscription

- Subz **rejects** creating a subscription when the user already has an active one
  (`SubsUserHasActiveSubscriptionException` → `UserHasActiveSubscriptionException`,
  `WebCheckoutStripeService.cs:243`). Stacking a second sub requires bypassing that guard.
- Even if bypassed: duplicate-subscription detection fires
  (`PlansService.cs:138-144`), primary-plan selection becomes ambiguous, and
  `cancel`/`renew` may target the wrong subscription.
- A real free sub is clean only for users with **no** existing subscription.

→ Chosen approach: inject a **synthetic `AccountSubscription`** at the BFF boundary.

## Approach (Option A — single choke point)

Inject the grant as a synthetic `AccountSubscription` inside
`SubscriptionService.GetSubscriptions(...)` — the lowest shared read point. Everything
downstream sees it uniformly:

- `plans/current` (via `GetPrimarySubscription` → `MapToPlan`)
- `plans/active` (`GetAllActiveAsync`)
- `PlansAccessProvider.Resolve` → `FeatureMatrix.BuildAccess` (features + quotas)
- `ActiveSubscriptionAuthorizationHandler` (reads `GetSubscriptions` directly)

### Key design decision: non-Stripe adapter type

The synthetic sub MUST use an adapter that is **not** `Stripe`/`Paddle`. Add a dedicated
value to `AccountSubscriptionAdapterType` (e.g. `Comp = 7`), or reuse `None`.

Rationale — the billing-mutating flows already gate on `Stripe`/`Paddle`, so a non-Stripe
synthetic sub is **auto-excluded** with zero changes to those services:

| Flow | Gate | Effect on synthetic |
|---|---|---|
| `plans/active` portal link | `PortalLinkAdapters.Contains` (`PlansService.cs:270`) | no portal link requested |
| `plans/cancel` | `GetActiveStripePlanAsync` → `AdapterType==Stripe` (`PlansService.cs:366`) | ignored |
| `plans/renew` | same | ignored |
| `plans/upgrade-links` | `FindPlanToUpgrade` → `AdapterType==Stripe` (`PlanUpgradeService.cs:123`) | ignored |

Prod traffic confirms these are low-risk anyway (7d): `cancel`/`renew` = 0,
`upgrade-links` = 160, `migration-offers` = 70, `active` = 938 — and the gap only ever
affects a granted user.

## Data model

New Mongo collection `PlanGrants` (BFF-owned):

| Field | Notes |
|---|---|
| `Id` | grant id (also used as synthetic `AccountSubscription.Id`, prefixed e.g. `grant_…`) |
| `MasterUserId` **or** `AccountId` | grant key — see open question below |
| `ProductKey` | which product the grant applies to |
| `ProductType` | granted tier (`Premium` / `FsmBusiness` / …) |
| `Duration` | for DTO display |
| `StartTime`, `ExpirationTime` | grant window |
| `Revoked` | manual kill switch |
| `CreatedBy`, `CreatedAt`, `Reason` | audit |

`IsActive` for the grant is **computed** at read time: `!Revoked && StartTime <= now < ExpirationTime`.

## Work items

1. **Model + repo**
   - `PlanGrant` model + `IPlanGrantsRepository` (Core) + Mongo impl.
   - Register in DI; document collection in `Docs/persistence.md`.

2. **Adapter type**
   - Add `AccountSubscriptionAdapterType.Comp` (audit all `switch`/filters on adapter type —
     price lookup, portal, `PlanInfoProvider`, migration calc).

3. **Injection in `SubscriptionService.GetSubscriptions`**
   - After fetching real subs, look up active grants for the (user/account, productKey) and
     append a synthetic `AccountSubscription` (`AdapterType = Comp`, `IsActive = true`,
     `IsTrial = true`, `IsAutoRenewEnabled = false`, `ProductType` set directly,
     `ExpirationTime` from grant).
   - Ensure priority: if granted tier must win over a real lower-tier sub,
     `GetPrimarySubscription` already orders by tier priority → fine.

4. **`IsTrialAvailable` correction**
   - `ResolvePlanAsync` sets `IsTrialAvailable = subscriptions.Count == 0`. With a synthetic
     sub present, count > 0 → already `false`. **Verify** the synthetic counts toward this so a
     granted user is NOT offered "start trial". (If we instead inject above this layer, confirm
     the count includes it.)

5. **Expiry + cache invalidation**
   - `PlansAccessProvider` caches `AccountAccess` via `IAccessCache` keyed by
     `(accountId, productKey)`. On grant create/revoke, **invalidate** that cache entry so
     start/stop is immediate (otherwise it lags by TTL).
   - No worker needed if `IsActive` is computed from `ExpirationTime` on every read; on expiry
     the user drops to `Starter` fallback automatically.

6. **Duplicate detection**
   - Confirm the synthetic sub is NOT counted in `renewingSubscriptions`
     (`IsRenewing => IsActive && IsAutoRenewEnabled != false`). Set
     `IsAutoRenewEnabled = false` on the synthetic so it never trips the duplicate notification.

7. **Admin surface for granting**
   - Minimal internal endpoint or CLI/script to create/revoke a `PlanGrant`
     (gated by an internal permission). Out of scope: self-serve UI.

## Out of scope / intentionally untouched

- `cancel`, `renew`, `upgrade-links`, portal — auto-excluded by the non-Stripe adapter; no code
  changes there.
- Subz and real billing — not modified.

## Known behavioral effects (accepted, not bugs)

- **`migration-offers`**: an active grant makes `hasOtherActive = true`
  (`PlansService.cs:409`) → granted iOS users stop seeing migration offers. Acceptable
  (they already hold a higher plan).
- **`plans/active`**: the grant appears as an active plan with **no** manage/portal link.
  Verify client rendering handles an active plan without a portal link.

## Open questions

1. **Grant key: `MasterUserId` vs `AccountId`?** `PlansAccessProvider` resolves the plan from the
   account **owner** (`FindOwnerForAccountId`) and worker members inherit it — so an account-level
   grant propagates to the whole team. Decide whether that's intended or grants should be
   per-master-user.
2. **Tier-vs-real-sub policy**: if the user later buys a *higher* real sub, primary selection
   handles it; if they buy an *equal/lower* one, the grant keeps winning until expiry — is that OK?
3. **Adapter value vs `None`**: dedicated `Comp` is cleaner for analytics/debugging but touches
   more `switch` sites; `None` is zero-enum-change but semantically overloaded.

## Testing

- Unit: `SubscriptionService` injects synthetic sub; `PlansService.ResolvePlanAsync` →
  correct `PlanDto` (`IsActive=true`, tier, `IsTrialAvailable=false`); expiry → drops to Starter.
- Unit: `PlansAccessProvider` returns the granted tier's features/limits.
- Unit: grant does NOT trip duplicate detection; is excluded from cancel/renew/upgrade.
- Integration: `GET /api/plans/current` and a gated write endpoint succeed for a granted user
  with no real subscription.

## Rollout

1. Ship behind no flag (grants are opt-in by data — empty `PlanGrants` = no behavior change).
2. Create one grant for a pilot client, verify `current` + a gated feature.
3. Document the grant/revoke runbook.
