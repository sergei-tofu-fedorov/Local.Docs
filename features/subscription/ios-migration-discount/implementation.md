# FS-890: iOS-to-Stripe Migration Discount — Implementation

> Phase 2 plan + execution checklist. Phase 1 analysis lives in [`plan.md`](./plan.md).

## Implementation

### Step 1: Core models

**Files:**
- `Src/Invoices.Core/Models/Subscription/NextPayment.cs` (new)
- `Src/Invoices.Core/Models/Subscription/AccountSubscription.cs` (modify)
- `Src/Invoices.Core/Models/Plans/IosMigrationDiscount.cs` (new)
- `Src/Invoices.Core/Models/Plans/OfferWithDiscount.cs` (new)
- `Src/Invoices.Core/Models/WebCheckout/SubsPriceKey.cs` (new)

Introduce the core domain types used by the calculator, the new service methods, and the composite priceId parser. All pure data types / static helpers, no behavior beyond parsing.

#### 1.1 `NextPayment` model

Mirrors Subs API `nextPayment` section. Only fields we actually consume are included — extend later if needed.

```csharp
namespace Invoices.Core.Models.Subscription;

public sealed record NextPayment(
    string Currency,
    long TotalPrice,
    DateTime? Time);
```

#### 1.2 Add `NextPayment?` to `AccountSubscription`

```csharp
public NextPayment? NextPayment { get; set; }
```

Place next to other nullable properties. `get; set;` matches the rest of the model; not `required` (Subs responses may omit it).

#### 1.3 `IosMigrationDiscount` record

```csharp
namespace Invoices.Core.Models.Plans;

public sealed record IosMigrationDiscount(
    string CouponId,
    int DiscountPercent,
    decimal OriginalPrice,
    decimal DiscountedPrice);
```

#### 1.4 `OfferWithDiscount` record

```csharp
namespace Invoices.Core.Models.Plans;

public sealed record OfferWithDiscount(
    OfferInfo Offer,
    IosMigrationDiscount? Discount);
```

#### 1.5 `SubsPriceKey` parser/encoder

Static helper that round-trips `priceId` ↔ `priceId__c=<couponId>`. Plain priceIds parse to themselves with `CouponHint == null`. Used by `WebCheckoutController` (parsing) and the DTO mapper in Step 6 (encoding).

```csharp
namespace Invoices.Core.Models.WebCheckout;

public static class SubsPriceKey
{
    private const string CouponSeparator = "__c=";

    public readonly record struct Parsed(string PriceId, string? CouponHint);

    public static Parsed Parse(string raw)
    {
        if (string.IsNullOrEmpty(raw))
            return new Parsed(raw, null);

        var idx = raw.LastIndexOf(CouponSeparator, StringComparison.Ordinal);
        if (idx < 0)
            return new Parsed(raw, null);

        var priceId = raw[..idx];
        var coupon = raw[(idx + CouponSeparator.Length)..];
        return string.IsNullOrEmpty(coupon)
            ? new Parsed(raw, null)            // malformed "...__c=" → treat as plain
            : new Parsed(priceId, coupon);
    }

    public static string Encode(string priceId, string? couponId) =>
        string.IsNullOrEmpty(couponId) ? priceId : $"{priceId}{CouponSeparator}{couponId}";
}
```

`LastIndexOf` (not `IndexOf`) defends against the unlikely case of a priceId containing the separator. No URL-encoding here — Stripe priceIds and our coupon IDs are alphanumeric/underscore.

---

### Step 2: Subs API response & mapping

**Files:**
- `Src/Invoices.Implementation.Services/Subscription/Subs/Responses/Subscription.cs` (modify)
- `Src/Invoices.Implementation.Services/Subscription/Mapper.cs` (modify)
- `Src/Invoices.Implementation.Services/Subscription/SubscriptionService.cs` (modify — 3 mapping sites)

Carry `nextPayment` from the Subs API all the way into `AccountSubscription`. There are **three** mapping sites in `SubscriptionService` that construct `AccountSubscription` (`GetSubscriptions`, `PutReceiptAsync`, `PutCustomerId`) — all three must set `NextPayment`.

#### 2.1 Add `NextPayment` response DTO and extend `Subs.Responses.Subscription`

```csharp
public record Subscription(
    string Id,
    bool IsActive,
    string? ProductId,
    DateTime CurrentTime,
    DateTime? StartTime,
    DateTime? InitialPurchaseTime,
    DateTime? ExpirationTime,
    DateTime? CancellationTime,
    bool? IsAutoRenewEnabled,
    bool? IsTrial,
    int? SeatCount,
    AdapterType AdapterType,
    string? OfferId,
    Dictionary<string, string> OfferMetadata,
    NextPaymentResponse? NextPayment);

public record NextPaymentResponse(
    string Currency,
    long TotalPrice,
    DateTime? Time);
```

Append `NextPayment` **at the end** so no positional arguments break at other call sites.

#### 2.2 Map to `Core.Models.Subscription.NextPayment`

Add to `Mapper.cs`:

```csharp
public static NextPayment? Map(this NextPaymentResponse? src) =>
    src is null ? null : new NextPayment(src.Currency, src.TotalPrice, src.Time);
```

#### 2.3 Populate `NextPayment` in all three AccountSubscription mappings

In `SubscriptionService` methods `GetSubscriptions`, `PutReceiptAsync`, `PutCustomerId`, add `NextPayment = s.NextPayment.Map()` to each `new AccountSubscription { … }` initializer.

**NO changes** to `Mapper.GetDuration`, `AdapterType.Map`, or the plans mapping path — `NextPayment` is only wired where subscriptions are mapped.

---

### Step 3: `IosMigrationDiscountCalculator`

**Files:** `Src/Invoices.Implementation.Services/Plans/IosMigrationDiscountCalculator.cs` (new)

Pure static calculator. Encapsulates the formula from the plan’s Analysis section and every eligibility check that depends only on an `AccountSubscription` + target price.

```csharp
namespace Invoices.Implementation.Services.Plans;

public static class IosMigrationDiscountCalculator
{
    private const int MinDiscountPercent = 10;
    private const int MaxDiscountPercent = 90;
    private const string CouponIdPrefix = "ios_migration_";

    public static IosMigrationDiscount? Calculate(
        AccountSubscription iosSubscription,
        decimal stripeAnnualPrice,
        DateTime now)
    {
        if (!IsEligibleIosSubscription(iosSubscription))
            return null;

        if (iosSubscription.NextPayment is null)
            return null;

        if (!string.Equals(iosSubscription.NextPayment.Currency, "usd", StringComparison.OrdinalIgnoreCase))
            return null;

        if (stripeAnnualPrice <= 0)
            return null;

        var iosAnnualPrice = iosSubscription.NextPayment.TotalPrice.RoundAmount(); // cents → decimal
        if (iosAnnualPrice <= 0)
            return null;

        var startTime = iosSubscription.StartTime ?? iosSubscription.InitialPurchaseTime;
        if (startTime is null)
            return null;

        var daysUsed = Math.Max(0, (now - startTime.Value).TotalDays);
        var monthsUsed = (int)Math.Ceiling(daysUsed / 30d);

        var amountSpent = (iosAnnualPrice / 12m) * monthsUsed;
        var remaining = iosAnnualPrice - amountSpent;
        if (remaining <= 0)
            return null;

        var rawPercent = (double)(remaining / stripeAnnualPrice) * 100d;
        var rounded = (int)(Math.Ceiling(rawPercent / 10d) * 10);
        var clamped = Math.Clamp(rounded, MinDiscountPercent, MaxDiscountPercent);

        var discounted = Math.Round(stripeAnnualPrice * (100 - clamped) / 100m, 2);
        return new IosMigrationDiscount(
            CouponId: CouponIdPrefix + clamped,
            DiscountPercent: clamped,
            OriginalPrice: stripeAnnualPrice,
            DiscountedPrice: discounted);
    }

    public static bool IsEligibleIosSubscription(AccountSubscription s) =>
        s.IsActive
        && s.AdapterType == AccountSubscriptionAdapterType.AppleStore
        && s.IsTrial != true
        && s.GetDuration() == Duration.Year
        && (s.ProductType == ProductType.Premium || s.ProductType == ProductType.Plus);

    private static readonly Regex ValidCouponIdRegex =
        new($"^{CouponIdPrefix}(10|20|30|40|50|60|70|80|90)$", RegexOptions.Compiled);

    /// <summary>
    /// Whitelist check used by <c>WebCheckoutController</c> at checkout time.
    /// Accepts only the 9 pre-created Stripe coupons; rejects any other id.
    /// </summary>
    public static bool IsValidCouponId(string? couponId) =>
        couponId is not null && ValidCouponIdRegex.IsMatch(couponId);
}
```

`GetDuration()` is the existing extension on `AccountSubscription`. `RoundAmount(long)` is the existing cents→decimal helper in `Invoices.Payments.AmountExtensions`. The whitelist regex matches **exactly** the coupon IDs `Calculate` can ever produce — keep them in lockstep if the discount steps ever change.

**NOT in calculator:** exclusivity check ("no other active subs") and target-tier check (Solo/Team/Business) — those are policies applied in `PlansService` since they span multiple subscriptions / offers.

---

### Step 4: `PlansService` — `GetMigrationOffersAsync`

**Files:**
- `Src/Invoices.Core/Services/IPlansService.cs` (modify — add one method signature)
- `Src/Invoices.Implementation.Services/Plans/PlansService.cs` (modify — implement)

Encapsulates eligibility, cross-subscription exclusivity, target-offer filtering, and calculation. Used **only** by the offers endpoint — checkout no longer calls back here (see Step 7).

#### 4.1 Extend `IPlansService`

```csharp
Task<List<OfferWithDiscount>> GetMigrationOffersAsync(
    ProductUser[] productUsers,
    CancellationToken ct);
```

#### 4.2 Eligibility helper in `PlansService`

Private helper that fetches invoices-product subscriptions for the given `ProductUser[]`, enforces exclusivity (no other active adapters), and returns the one eligible iOS sub or `null`.

```csharp
private async Task<AccountSubscription?> FindEligibleIosSubscriptionAsync(
    ProductUser[] productUsers,
    CancellationToken ct)
{
    var invoicesUser = productUsers.FirstOrDefault(u =>
        string.Equals(u.ProductKey, ProductConst.InvoicesIos, StringComparison.OrdinalIgnoreCase));
    if (invoicesUser is null) return null;

    var subs = await _subscriptionService.GetSubscriptions(
        invoicesUser.PlatformUserId, invoicesUser.ProductKey, ct);

    var iosCandidates = subs
        .Where(IosMigrationDiscountCalculator.IsEligibleIosSubscription)
        .ToList();
    if (iosCandidates.Count == 0) return null;

    var hasOtherActive = subs.Any(s =>
        s.IsActive && s.AdapterType != AccountSubscriptionAdapterType.AppleStore);
    if (hasOtherActive) return null;

    return iosCandidates.OrderByDescending(s => s.ExpirationTime ?? DateTime.MaxValue).First();
}
```

#### 4.3 `GetMigrationOffersAsync`

```csharp
public async Task<List<OfferWithDiscount>> GetMigrationOffersAsync(
    ProductUser[] productUsers, CancellationToken ct)
{
    var iosSub = await FindEligibleIosSubscriptionAsync(productUsers, ct);
    if (iosSub is null) return new List<OfferWithDiscount>();

    var offers = await GetAllAsync(AccountSubscriptionAdapterType.Stripe, ProductConst.Tofu, ct);

    var eligibleOffers = offers.Where(o =>
        o.Duration == Duration.Year &&
        o.ProductType is ProductType.FsmSolo or ProductType.FsmTeam or ProductType.FsmBusiness);

    var now = DateTime.UtcNow;
    return eligibleOffers
        .Select(o => new OfferWithDiscount(
            o,
            o.Price.HasValue
                ? IosMigrationDiscountCalculator.Calculate(iosSub, o.Price.Value, now)
                : null))
        .ToList();
}
```

**NO changes** to `GetCurrent`, `GetAllActiveAsync`, `CancelActivePlanAsync`, `RenewActivePlanAsync`, `GetAllAsync`, or the existing `MapToPlan`/`TryGetPrice`/etc. The cache stays untouched — discounts are computed fresh each call.

---

### Step 5: `IWebCheckoutService` + `WebCheckoutStripeService` — optional coupon params

**Files:**
- `Src/Invoices.Core/WebCheckout/IWebCheckoutService.cs` (modify)
- `Src/Invoices.Implementation.Services/WebCheckout/WebCheckoutStripeService.cs` (modify)

Minimal interface surface change: two optional parameters, default `null`, callers that don’t care keep working.

#### 5.1 Interface

```csharp
Task<CheckoutSubscription> CreateSubscriptionForAuthorizedUser(
    string priceId,
    string platformUserId,
    string? appsflyerId,
    bool isProduction,
    string? couponOverride,        // new — null = use priceConfig.CouponId
    CancellationToken ct);

Task<CheckoutConfig?> GetConfig(
    string? priceId,
    string? couponId,              // new — null = use priceConfig.CouponId
    CancellationToken ct);
```

Use named positional params (not default values) on the interface — callers already pass explicitly. In the impl, keep signature aligned.

#### 5.2 `WebCheckoutStripeService.CreateSubscriptionForAuthorizedUser`

Thread `couponOverride` into `InternalCreateSubscriptionInSubs`:

```csharp
var coupon = couponOverride ?? priceConfig.CouponId;
return await InternalCreateSubscriptionInSubs(
    priceId, appsflyerId, platformUserId, platformUserId, coupon, isProduction, ct);
```

#### 5.3 `WebCheckoutStripeService.GetConfig`

Use `couponId` argument when fetching the Stripe coupon details; keep fallback behavior for anonymous calls:

```csharp
var effectiveCouponId = !string.IsNullOrWhiteSpace(couponId) ? couponId : priceConfig.CouponId;

Task<Coupon>? getCouponTask = null;
if (!string.IsNullOrWhiteSpace(effectiveCouponId))
{
    getCouponTask = _couponService.GetAsync(effectiveCouponId, couponGetOptions, requestOptions, ct);
}
// … unchanged price fetch / response build, but set "coupon-id" = effectiveCouponId
```

Emit the **effective** `coupon-id` into the response dictionary so the client sees the coupon it’s previewing. If `couponPrice` math needs `coupon.PercentOff`, fall back to percent-off calculation (currently the code only uses `AmountOff`). **No change to the percent-off fallback** unless required — the ios_migration_* coupons use `percent_off`, so:

```csharp
couponPrice = coupon.PercentOff.HasValue
    ? (long?)Math.Round((price.UnitAmount ?? 0) * (100 - (double)coupon.PercentOff.Value) / 100d)
    : price.UnitAmount - coupon.AmountOff;
```

This is a minimal extension to the existing code so percent-off coupons render correctly.

**NO changes** to `CreateSubscription` (anonymous flow), `TryConfirmSubscription`, or helper methods.

---

### Step 6: API DTOs + Mapping

**Files:**
- `Src/Invoices.Api/Models/Plans/OfferWithDiscountDto.cs` (new)
- `Src/Invoices.Api/Models/Plans/IosMigrationDiscountDto.cs` (new)
- `Src/Invoices.Api/Models/Mapping.cs` (modify — add mappers)

DTOs match the shapes from Phase 1 "API Contracts". Serialization attributes follow `PlanDto` / `ActivePlanDto` conventions (Newtonsoft, `DefaultValueHandling.Ignore` where nullable).

#### 6.1 DTO files

```csharp
public sealed class OfferWithDiscountDto
{
    public required string OriginOfferId { get; init; }
    public required string SubsPriceKey { get; init; }   // == OriginOfferId when no Discount
    public required DurationDto Duration { get; init; }
    public required int AdapterType { get; init; }
    public required string OriginProductId { get; init; }
    public required ProductTypeDto ProductType { get; init; }
    public required decimal? Price { get; init; }

    [JsonProperty(DefaultValueHandling = DefaultValueHandling.Ignore)]
    public IosMigrationDiscountDto? Discount { get; init; }
}

public sealed class IosMigrationDiscountDto
{
    public required string CouponId { get; init; }
    public required int DiscountPercent { get; init; }
    public required decimal OriginalPrice { get; init; }
    public required decimal DiscountedPrice { get; init; }
}
```

#### 6.2 Mapping methods in `Mapping.cs`

```csharp
public static OfferWithDiscountDto ToDto(this OfferWithDiscount source, string currentProductKey) =>
    new()
    {
        OriginOfferId = source.Offer.OriginOfferId,
        SubsPriceKey = SubsPriceKey.Encode(source.Offer.OriginOfferId, source.Discount?.CouponId),
        Duration = source.Offer.Duration.ToDto(),
        AdapterType = (int)source.Offer.AdapterType,
        OriginProductId = source.Offer.OriginProductId,
        ProductType = source.Offer.ProductType.ToDto(currentProductKey), // existing private helper
        Price = source.Offer.Price,
        Discount = source.Discount?.ToDto(),
    };

private static IosMigrationDiscountDto ToDto(this IosMigrationDiscount d) =>
    new()
    {
        CouponId = d.CouponId,
        DiscountPercent = d.DiscountPercent,
        OriginalPrice = d.OriginalPrice,
        DiscountedPrice = d.DiscountedPrice,
    };
```

When `source.Discount == null`, `SubsPriceKey` collapses to the plain `OriginOfferId` — useful if/when this DTO is reused for non-discounted offers.

`ToDto(this ProductType ...)` is already `private` in `Mapping.cs` — exposing through existing `OfferWithDiscount.ToDto` keeps it private; make sure the new method lives in the same file so visibility holds.

**NO changes** to `PlanDto`, `ActivePlanDto`, or other DTOs.

---

### Step 7: Controllers — PlansController + WebCheckoutController

**Files:**
- `Src/Invoices.Api/Controllers/PlansController.cs` (modify)
- `Src/Invoices.Api/Controllers/WebCheckoutController.cs` (modify)

Wire the new service methods into HTTP.

#### 7.1 `PlansController.MigrationOffers`

```csharp
[HttpGet("migration-offers")]
public async Task<OfferWithDiscountDto[]> MigrationOffers(CancellationToken ct)
{
    var productUsers = await GetProductUsersAsync();
    var offers = await _plansService.GetMigrationOffersAsync(productUsers, ct);
    return offers.Select(o => o.ToDto(ProductKey)).ToArray();
}
```

Requires auth like other non-anonymous endpoints (inherits `BaseController`, no `[AllowAnonymous]`). No new injection required — `IPlansService` is already injected.

#### 7.2 `WebCheckoutController.CreateSubscriptionAuthorized` — parse composite + whitelist hint

- **No** `IPlansService` injection — checkout no longer queries Subs API for eligibility.
- Parse incoming `request.PriceId` via `SubsPriceKey.Parse` to get `realPriceId` and `couponHint`.
- Pass `couponHint` through `IosMigrationDiscountCalculator.IsValidCouponId` whitelist; if it doesn't match `^ios_migration_(10|...|90)$`, drop it.
- Pass `realPriceId` and the (possibly null) coupon to the service.

```csharp
var parsed = SubsPriceKey.Parse(request.PriceId);
var couponOverride = IosMigrationDiscountCalculator.IsValidCouponId(parsed.CouponHint)
    ? parsed.CouponHint
    : null;

var subscription = await _webCheckoutService.CreateSubscriptionForAuthorizedUser(
    parsed.PriceId, platformUserId, request.AppsflyerId,
    _hostEnvironment.IsProduction(),
    couponOverride,
    ct);
```

External request shape (`{ priceId }`) is unchanged — the same field now optionally carries a composite key that the server unpacks. Stripe's `duration=once` on every `ios_migration_*` coupon caps any abuse to one billing period (see plan.md → Risk Points → "Coupon abuse via composite key").

#### 7.3 `WebCheckoutController.GetCheckoutConfig` — parse composite, forward hint

The query signature stays exactly the same (no new `couponId` query param). The composite is unpacked server-side.

```csharp
[HttpGet("config")]
[AllowAnonymous]
public async Task<ActionResult<GetCheckoutConfig.Response>> GetCheckoutConfig(
    [FromQuery] string? priceId,
    CancellationToken ct)
{
    var parsed = priceId is null
        ? new SubsPriceKey.Parsed(null!, null)
        : SubsPriceKey.Parse(priceId);

    var config = await _webCheckoutService.GetConfig(parsed.PriceId, parsed.CouponHint, ct);
    return config is null
        ? throw new CheckoutConfigNotFoundException($"Not found price id '{priceId}'")
        : config.Map();
}
```

**NO changes** to `CreateSubscription` (anonymous), `ConfirmSubscription`. Existing anonymous flow stays as-is. Web checkout app sees no contract change.

---

### Step 8: Run full test suite (verification gate)

Run ALL existing unit and integration tests to verify nothing is broken before writing new tests. Do NOT proceed to Step 9 if anything fails.

```bash
cd Src && dotnet test
```

### Step 9: Write new tests (via `/tests sync`)

Expected test coverage:

#### Unit tests — `SubsPriceKey`
- `Parse_PlainPriceId_ReturnsPriceIdWithNullHint`
- `Parse_CompositeWithCoupon_SplitsCorrectly`
- `Parse_TrailingSeparatorWithEmptyCoupon_TreatedAsPlain` — `"price_xxx__c="` → no hint
- `Parse_PriceIdContainingSeparator_SplitsOnLastOccurrence`
- `Encode_NullCoupon_ReturnsPriceIdUnchanged`
- `Encode_WithCoupon_AppendsSuffix`
- `RoundTrip_EncodeThenParse_PreservesValues`

#### Unit tests — `IosMigrationDiscountCalculator.Calculate`
- `Calculate_EligibleUsdAnnualIosPremium_ReturnsExpectedCouponId` — golden path, canonical example from Analysis
- `Calculate_NonUsdCurrency_ReturnsNull`
- `Calculate_NoNextPayment_ReturnsNull`
- `Calculate_TrialSubscription_ReturnsNull`
- `Calculate_GooglePlaySubscription_ReturnsNull`
- `Calculate_MonthlyIosSubscription_ReturnsNull`
- `Calculate_InvoicingProductType_ReturnsNull` (tier filter)
- `Calculate_AlmostFullyUsed_ClampsTo10Percent`
- `Calculate_BarelyUsed_ClampsTo90Percent`
- `Calculate_RoundsUpToNearest10`
- `Calculate_ExpensiveIosCheapStripe_Clamps`
- `Calculate_StartTimeMissing_FallsBackToInitialPurchaseTime`

#### Unit tests — `IosMigrationDiscountCalculator.IsValidCouponId`
- `IsValidCouponId_AllNineWhitelistedIds_ReturnTrue` — parametric for 10/20/.../90
- `IsValidCouponId_Null_ReturnsFalse`
- `IsValidCouponId_EmptyString_ReturnsFalse`
- `IsValidCouponId_NonMigrationPromo_ReturnsFalse` — e.g., `mega_summer_promo`
- `IsValidCouponId_OutOfRangePercent_ReturnsFalse` — e.g., `ios_migration_5`, `ios_migration_100`
- `IsValidCouponId_PrefixOnly_ReturnsFalse` — `ios_migration_`
- `IsValidCouponId_TrailingGarbage_ReturnsFalse` — `ios_migration_30x`

#### Unit tests — `PlansService.GetMigrationOffersAsync`
- `GetMigrationOffers_NoIosSub_ReturnsEmpty`
- `GetMigrationOffers_HasOtherActiveStripeSub_ReturnsEmpty`
- `GetMigrationOffers_EligibleIos_ReturnsAnnualFsmOffersWithDiscount`
- `GetMigrationOffers_SkipsNonAnnualOffers`
- `GetMigrationOffers_SkipsNonFsmTierOffers`

#### Integration tests
- `GET /api/plans/migration-offers` returns `200` and empty array for non-eligible user
- `GET /api/plans/migration-offers` for an eligible user returns `subsPriceKey` of form `<originOfferId>__c=ios_migration_<percent>`
- `GET /web-checkout/config?priceId=<priceId>__c=ios_migration_30` surfaces the override coupon metadata (mocking Stripe `CouponService.GetAsync`)
- `GET /web-checkout/config?priceId=<plainPriceId>` behaves identically to before this change (regression safeguard)
- `POST /web-checkout/subscriptions` with `priceId=<priceId>__c=mega_summer_promo` drops the coupon (whitelist rejects non-`ios_migration_*`)
- `POST /web-checkout/subscriptions` with `priceId=<priceId>__c=ios_migration_30` forwards `ios_migration_30` to the Subs API as the coupon

> This step delegates to `/tests sync`, which writes tests following project conventions.

---

## Execution Checklist

Tracks top-level steps. Sub-steps (e.g., 1.1–1.4) are implemented together within one `/plan exec` call.

| # | Task | Files | Status |
|---|------|-------|--------|
| 1 | Core models: `NextPayment`, `IosMigrationDiscount`, `OfferWithDiscount`, `SubsPriceKey`, extend `AccountSubscription` | `Invoices.Core/Models/Subscription/NextPayment.cs`, `Invoices.Core/Models/Subscription/AccountSubscription.cs`, `Invoices.Core/Models/Plans/IosMigrationDiscount.cs`, `Invoices.Core/Models/Plans/OfferWithDiscount.cs`, `Invoices.Core/Models/WebCheckout/SubsPriceKey.cs` | done |
| 2 | Subs API DTO + mapping — carry `nextPayment` into `AccountSubscription` at 3 mapping sites | `Invoices.Implementation.Services/Subscription/Subs/Responses/Subscription.cs`, `…/Mapper.cs`, `…/SubscriptionService.cs` | done |
| 3 | `IosMigrationDiscountCalculator` static class with `Calculate` + `IsValidCouponId` whitelist | `Invoices.Implementation.Services/Plans/IosMigrationDiscountCalculator.cs` | done |
| 4 | `IPlansService` + `PlansService` — `GetMigrationOffersAsync` + private `FindEligibleIosSubscriptionAsync` helper | `Invoices.Core/Services/IPlansService.cs`, `Invoices.Implementation.Services/Plans/PlansService.cs` | done |
| 5 | `IWebCheckoutService` + `WebCheckoutStripeService` — add `couponOverride` / `couponId` params, percent-off fallback in `GetConfig` | `Invoices.Core/WebCheckout/IWebCheckoutService.cs`, `Invoices.Implementation.Services/WebCheckout/WebCheckoutStripeService.cs` | done |
| 6 | API DTOs + Mapping (`OfferWithDiscountDto` with `SubsPriceKey` field, `IosMigrationDiscountDto`) | `Invoices.Api/Models/Plans/OfferWithDiscountDto.cs`, `Invoices.Api/Models/Plans/IosMigrationDiscountDto.cs`, `Invoices.Api/Models/Mapping.cs` | done |
| 7 | Controllers — `PlansController.MigrationOffers`; `WebCheckoutController` parses composite priceId via `SubsPriceKey.Parse` and whitelists `couponHint` via `IosMigrationDiscountCalculator.IsValidCouponId` (no `IPlansService`) | `Invoices.Api/Controllers/PlansController.cs`, `Invoices.Api/Controllers/WebCheckoutController.cs` | done |
| 8 | Run full test suite (verification gate) | — | done |
| 9 | Write new tests (via `/tests sync`) | test files | done |
