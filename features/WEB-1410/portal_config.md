# Stripe Portal Configuration for Subscription Cancellation

**Ticket:** WEB-1410

## Goal

Expose the Stripe Customer Portal "cancel subscription" action **only**
in the portal links returned by `GET /api/plans/active` (the
`CustomerPortalLink` field on each `ActivePlan`).

The Stripe Dashboard default portal configuration does **not** allow
cancellation. A second portal configuration (with cancellation enabled)
is provisioned in the Stripe Dashboard and its id is supplied via app
settings as a single value. The backend appends `&configuration={id}`
to the Stripe `subscription-management-link` request **only when**
building the portal link for `plans/active`.

All other entry points keep using the Stripe Dashboard default:

- `GET /api/users/authenticated/subscription-management-link` — never
  sends `configuration`. This endpoint is the generic "manage
  subscription" link and must not expose cancellation.
- The plan-upgrade flow (`subscription-update-link`) — never sends
  `configuration`. After the recent price changes both portal
  configurations share the same prices, so the dedicated upgrade
  configuration is no longer required.

Per-platform routing is **out of scope** for this ticket. Today every
client that hits `plans/active` gets the cancellation-enabled portal
link; if a future requirement needs to gate by platform, the single
setting can be promoted to a dictionary without restructuring callers.

## Current State

`SubscriptionService.GetSubscriptionManagementLink` currently appends
the `configuration` query parameter for **every** caller when the
adapter is Stripe and a platform override exists. Both call sites —
`UsersController.GetSubscriptionManagementLinkAsync` and
`PlansService.PopulatePortalLinksAsync` — go through the same method,
so today the cancellation-enabled configuration leaks into the
generic "manage subscription" link as well. This needs to be narrowed
to the `plans/active` call site only, and the per-platform dictionary
collapsed to a single setting.

## Configuration

`StripeCancellationPortalId` lives at the **root** of
`SubscriptionsOptions` (not nested under `Stripe`). `Stripe` is itself
a dictionary keyed by product key (`Stripe:tofu:...`); putting a
Stripe-only setting inside each product entry would duplicate the
same value for every product. Keeping it flat at the root gives a
single source of truth shared across products.

```jsonc
"Subscriptions": {
  "Stripe": {
    "tofu": {
      "PlusProductId": "prod_...",
      "NonUpgradeablePlans": [ "price_..." ]
    }
  },
  // Stripe customer portal configuration id with cancellation enabled.
  // Used ONLY by the plans/active flow.
  // Empty/absent -> no configuration query is sent -> Stripe Dashboard default.
  "StripeCancellationPortalId": "bpc_1RjiMMJnc2Yr4yxFaqsViZX9"
}
```

`SubscriptionsOptions`
(`Src/Invoices.Implementation.Services/Config/SubscriptionsOptions.cs`):

```csharp
/// <summary>
/// Stripe customer portal configuration id with cancellation enabled.
/// Consumed only by the plans/active portal-link flow. Null/empty means
/// "send no configuration -> Stripe Dashboard default".
/// </summary>
public string? StripeCancellationPortalId { get; init; }
```

`Validate` does not require this value — leaving it unset is a
legitimate "use Stripe default everywhere" choice.

### Settings migration

- Removed `Subscriptions:Stripe:tofu:PortalConfigurationId` from
  `appsettings.json` and `appsettings.Development.json`.
- Removed the per-platform `Subscriptions:PortalConfigurations`
  dictionary that was added earlier on this branch.
- Added `Subscriptions:StripeCancellationPortalId` pointing at
  the cancellation-enabled portal configuration id provisioned in the
  Stripe Dashboard.
- `SubscriptionsOptions.Validate` does not require the new setting.

## Refactoring Options

We need to make `GetSubscriptionManagementLink` apply the
cancellation-enabled configuration **only** when called from
`PlansService.PopulatePortalLinksAsync`, and **never** when called
from `UsersController.GetSubscriptionManagementLinkAsync`. We also
need to drop the `Platform` parameter that was added for the
per-platform dictionary, since selection is no longer platform-based.
Three options considered:

### Option A — Boolean flag on the service method (preferred)

Add a `bool includeCancellationConfiguration` parameter (default
`false`) to
`ISubscriptionService.GetSubscriptionManagementLink`, and remove the
`Platform platform` parameter introduced earlier on this branch. Only
`PopulatePortalLinksAsync` passes `true`; `UsersController` passes
`false` (or omits it).

```csharp
Task<SubscriptionManagementLinkResponse> GetSubscriptionManagementLink(
    string userId,
    string productKey,
    string returnUrl,
    AccountSubscriptionAdapterType adapterType,
    bool includeCancellationConfiguration,
    CancellationToken cancellationToken);
```

Inside `SubscriptionService`, the `configuration` query is appended
only when `adapterType == Stripe && includeCancellationConfiguration
&& !string.IsNullOrEmpty(StripeCancellationPortalId)`.

- **Pros:** smallest diff, intent visible at the call site, no new
  types, `Web2WebSubscriptionService` only needs to thread one extra
  bool through. Removing `Platform` shrinks the signature back.
- **Cons:** boolean parameter — slightly less self-documenting than
  an enum if more variants appear later.

### Option B — Dedicated portal-kind enum

Replace the bool with `StripePortalKind { Default, WithCancellation }`
(or similar). Caller passes the kind explicitly.

- **Pros:** more extensible if a third portal configuration ever
  appears (e.g. trial-cancellation, dunning).
- **Cons:** more types and naming overhead for what is currently a
  binary choice.

### Option C — Split into two service methods

Add a separate
`GetSubscriptionManagementLinkWithCancellationAsync` (or similar) used
only by `PopulatePortalLinksAsync`, and leave the existing method
cancellation-free.

- **Pros:** call sites are unambiguous; no conditional inside the
  method.
- **Cons:** duplicates the request-building logic or forces an
  internal helper anyway; bigger surface area on
  `ISubscriptionService` and `Web2WebSubscriptionService`.

**Recommendation:** Option A. It is the smallest change that fixes
the leak, and Option B can be applied later cheaply if a second
non-default portal configuration is ever introduced.

## Implementation Plan (Option A)

1. **`SubscriptionsOptions`** — replace `PortalConfigurations`
   dictionary (and `GetPortalConfigurationId(Platform)` helper) with
   a single nullable `StripeCancellationPortalId` string.
2. **`ISubscriptionService.GetSubscriptionManagementLink`** — drop
   the `Platform platform` parameter; add
   `bool includeCancellationConfiguration`.
3. **`SubscriptionService.GetSubscriptionManagementLink`** — gate the
   `configuration=...` query append on
   `includeCancellationConfiguration` plus the Stripe adapter check,
   reading `StripeCancellationPortalId` directly.
4. **`Web2WebSubscriptionService`** — drop `platform`, thread the
   new bool through to the inner service call.
5. **`PlansService.PopulatePortalLinksAsync`** — pass `true`; remove
   the `Platform platform` parameter that was added for routing
   (also drop it from `GetAllActiveAsync` and its callers if it is
   no longer used elsewhere).
6. **`UsersController.GetSubscriptionManagementLinkAsync`** — pass
   `false` (both the master-user branch and the regular branch);
   stop forwarding `BaseController.Platform` into the call.
7. **`appsettings.json` / `appsettings.Development.json`** — replace
   `Subscriptions:PortalConfigurations` with
   `Subscriptions:StripeCancellationPortalId`.
8. **Tests** — update `UsersControllerTests` to assert that no
   `configuration` query parameter is sent from the
   `subscription-management-link` endpoint, and add/extend
   `PlansService` tests covering `PopulatePortalLinksAsync`
   appending the `configuration` query when the setting is present
   and omitting it when blank.

## Out of Scope

- Creating the Stripe Portal Configuration itself; the id is
  provisioned in the Stripe Dashboard and supplied via configuration.
- Per-platform or per-product routing of portal configurations.
  Selection is currently a single global value; if a future
  requirement needs to differentiate, the setting can be promoted to
  a dictionary without restructuring callers.
- Reintroducing a portal configuration for the plan-upgrade flow.

## Notes

- The Subs API supports `configuration` on
  `subscription-management-link`; only the `plans/active` portal-link
  flow uses it.
- When `StripeCancellationPortalId` is null or empty, no
  `configuration` query parameter is sent and Stripe applies the
  Dashboard default everywhere — including `plans/active`.
