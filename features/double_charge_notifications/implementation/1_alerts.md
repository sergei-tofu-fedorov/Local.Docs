# 1. Alerts — Enrich Plans API Responses

Adds fields to `GET /plans/current` and `GET /plans/active` so clients can detect and display double-charge warnings.

## API Contracts

### `GET /plans/current` — Response changes

| Field | Type | New? | Description |
|-------|------|------|-------------|
| `hasDuplicateSubscriptions` | `bool` | **New** | `true` if user has 2+ active renewing subscriptions |

All existing fields unchanged.

### `GET /plans/active` — Request

No request changes. Portal return URL is resolved server-side from `ProductKey`.

### `GET /plans/active` — Response changes

| Field | Type | New? | Description |
|-------|------|------|-------------|
| `expirationTime` | `DateTime?` | **New** | Subscription renewal/expiration date |
| `originProductId` | `string?` | **New** | External product identifier (e.g., `com.getpaidapp.invoices.plus.weekly`) |
| `isPrimary` | `bool` | **New** | `true` for the subscription selected by `GetPrimarySubscription()` |
| `isAutoRenewEnabled` | `bool?` | **New** | `true` if subscription auto-renews, `false` if cancelled. Used in duplicate detection — cancelled subs are not duplicates. |
| `customerPortalLink` | `string?` | **New** | Stripe/Paddle management URL. `null` for Apple/Google or unsupported platforms. |

All existing fields (`productType`, `duration`, `adapterType`, `productKey`) unchanged.

---

## 1.1 `GET /plans/current` — `HasDuplicateSubscriptions`

### Detection Logic

`PlansService.GetCurrent()` already fetches all subscriptions via `GetSubscriptionsAsync()`. Detection is a check on the already-fetched data:

```
activeSubscriptions = subscriptions.Where(s => s.IsActive)
renewingSubscriptions = activeSubscriptions.Where(s => s.IsAutoRenewEnabled != false)
hasDuplicates = renewingSubscriptions.Count > 1
```

A duplicate means 2+ active **renewing** subscriptions. Cancelled subscriptions (`IsAutoRenewEnabled == false`) are excluded — they will expire naturally without causing double charges.

### Changes

**Domain** — `Invoices.Core/Models/Plans/Plan.cs`:
```csharp
public bool HasDuplicateSubscriptions { get; init; }
```

**DTO** — `Invoices.Api/Models/Plans/PlanDto.cs`:
```csharp
public bool HasDuplicateSubscriptions { get; init; }
```

**Service** — `PlansService.cs`, `MapToPlan(IReadOnlyCollection<AccountSubscription>)`:

```csharp
var activeSubscriptions = subscriptions.Where(s => s.IsActive).ToList();
var renewingSubscriptions = activeSubscriptions
    .Where(s => s.IsAutoRenewEnabled != false).ToList();
var hasDuplicates = renewingSubscriptions.Count > 1;
```

**Mapping** — `Mapping.cs`, `ToPlanDto()`:
```csharp
HasDuplicateSubscriptions = plan.HasDuplicateSubscriptions,
```

## 1.2 `GET /plans/active` — New response fields + `CustomerPortalLink`

### Portal Return URL Resolution

Portal return URL is hardcoded per app in a const file, resolved from the `ProductKey` request header. No client parameter needed.

```csharp
// Invoices.Core/Models/PortalReturnUrls.cs
public static class PortalReturnUrls
{
    public static string? Resolve(string productKey) => productKey switch
    {
        ProductConst.InvoicesIos => "invoices://close_managment",
        ProductConst.Tofu or ProductConst.FieldService => "tofu://close_managment",
        _ => null
    };
}
```

| ProductKey | Return URL | Notes |
|-----------|------------|-------|
| `invoices` (IM iOS) | `invoices://close_managment` | Deep link back to IM |
| `tofu` / `tofu-fieldservice` | `tofu://close_managment` | Deep link back to Tofu |
| Web, Android, other | `null` | No portal link; web uses existing `subscription-management-link` endpoint |

When resolved URL is `null`, `CustomerPortalLink` is `null` for all subscriptions (portal link fetch is skipped entirely).

### Changes

**New file** — `Invoices.Core/Models/PortalReturnUrls.cs`:
```csharp
public static class PortalReturnUrls
{
    public static string? Resolve(string productKey) => productKey switch
    {
        ProductConst.InvoicesIos => "invoices://close_managment",
        ProductConst.Tofu or ProductConst.FieldService => "tofu://close_managment",
        _ => null
    };
}
```

**Domain** — `Invoices.Core/Models/Plans/ActivePlan.cs`:
```csharp
public DateTime? ExpirationTime { get; init; }
public string? OriginProductId { get; init; }
public bool IsPrimary { get; init; }
public string? CustomerPortalLink { get; set; }
```

**DTO** — `Invoices.Api/Models/Plans/ActivePlanDto.cs`:
```csharp
public DateTime? ExpirationTime { get; init; }
public string? OriginProductId { get; init; }
public bool IsPrimary { get; init; }
public string? CustomerPortalLink { get; init; }
```

**Controller** — `PlansController.cs`:
```csharp
[HttpGet("active")]
public async Task<ActivePlanDto[]> Active(CancellationToken token)
{
    var productUsers = await GetProductUsersAsync();
    var portalReturnUrl = PortalReturnUrls.Resolve(ProductKey);
    var plans = await _plansService.GetAllActiveAsync(productUsers, portalReturnUrl, token);
    return plans.Select(w => w.ToDto(ProductKey)).ToArray();
}
```

**Interface** — `IPlansService.cs`:
```csharp
Task<List<ActivePlan>> GetAllActiveAsync(ProductUser[] productUsers, string? portalReturnUrl, CancellationToken ct);
```

**Service** — `PlansService.cs`, `GetAllActiveAsync()`:

```csharp
public async Task<List<ActivePlan>> GetAllActiveAsync(
    ProductUser[] productUsers, string? portalReturnUrl, CancellationToken ct)
{
    var subscriptions = await GetSubscriptionsAsync(productUsers, ct);
    var primary = subscriptions.GetPrimarySubscription();

    var activePlans = subscriptions
        .Where(p => p.IsActive)
        .Select(s => MapToActivePlan(s, isPrimary: s.Id == primary?.Id))
        .ToList();

    if (!string.IsNullOrEmpty(portalReturnUrl))
        await PopulatePortalLinksAsync(activePlans, portalReturnUrl, ct);

    return activePlans;
}
```

**Service** — `PlansService.cs`, `PopulatePortalLinksAsync()`:

Reuses existing `ISubscriptionService.GetSubscriptionManagementLink()` which calls Subz → Stripe/Paddle. Only Stripe and Paddle adapters support portal links.

```csharp
private async Task PopulatePortalLinksAsync(List<ActivePlan> plans, string portalReturnUrl, CancellationToken ct)
{
    var portalPlans = plans.Where(p => PortalLinkAdapters.Contains(p.AdapterType));
    await Parallel.ForEachAsync(portalPlans, ..., async (plan, cti) =>
    {
        try
        {
            var response = await _subscriptionService.GetSubscriptionManagementLink(
                plan.PlatformUserId, plan.ProductKey, portalReturnUrl, plan.AdapterType, cti);
            plan.CustomerPortalLink = response.Url;
        }
        catch (Exception ex) { _logger.LogWarning(ex, ...); }
    });
}
```

**Mapping** — `Mapping.cs`, `ActivePlan.ToDto()`:
```csharp
ExpirationTime = activePlan.ExpirationTime,
OriginProductId = activePlan.OriginProductId,
IsPrimary = activePlan.IsPrimary,
CustomerPortalLink = activePlan.CustomerPortalLink,
```

## Testing

### Unit Tests

**Duplicate detection** (`HasDuplicateSubscriptions`):

| Scenario | Subscriptions | Expected |
|----------|--------------|----------|
| No subscriptions | `[]` | `false` |
| Single active | `[AppleStore, active, renewing]` | `false` |
| Two active renewing, same adapter | `[AppleStore, renewing] + [AppleStore, renewing]` | `true` |
| Two active renewing, different adapters | `[AppleStore, renewing] + [Stripe, renewing]` | `true` |
| One active + one inactive | `[AppleStore, active] + [Stripe, inactive]` | `false` |
| Two active, one cancelled (no auto-renew) | `[AppleStore, renewing] + [Stripe, cancelled]` | `false` |

**Active plan enrichment** (`GetAllActiveAsync`):

| Scenario | Expected |
|----------|----------|
| Single active sub | `IsPrimary = true`, all new fields populated |
| Two active (different tiers) | Higher-tier is `IsPrimary = true` |
| Mobile app + Stripe sub | `CustomerPortalLink` populated |
| Web app (any sub) | `CustomerPortalLink` is `null` for all |
| Mobile app + Apple sub | `CustomerPortalLink` stays `null` |

## Notes

- `ExpirationTime` = end of current billing period. For auto-renewing subscriptions this equals the next charge date.
- `CustomerPortalLink` uses hardcoded deep link URLs per app. The Stripe BillingPortal API requires a return URL — this is where the user is redirected after finishing. Paddle does not use it but the param is passed through.
- All changes are additive and backward-compatible.
