# Idea: Plan Upgrade Eligibility

## Problem

Stripe prices have multiplied (tiers, intervals, legacy SKUs, regional variants). The current upgrade rules don't scale: hardcoded HashSets in `Src/Invoices.Core/Consts/PlansConstants.cs`, imperative branches in `PlanUpgradeService.IsValidUpgrade` (`Src/Invoices.Implementation.Services/Plans/PlanUpgradeService.cs:33–67`), and a `NonUpgradeablePlans` blacklist in `appsettings.json`. Adding a new Stripe price means editing all three.

A specific consequence: there's no clean way to forbid upgrades to paid‑trial plans (e.g. `$1` first week). Today they have to be added to `NonUpgradeablePlans` by hand.

## Idea

Drive eligibility from data the subz response already carries instead of hardcoded lists.

The subz `OfferAdapter` returns a `Metadata` dictionary per Stripe price (`Src/Invoices.Implementation.Services/Subscription/Subs/Responses/OffersAdapterResponse.cs`). It already contains useful keys like:

```
product_type            = fsm_team
trial_price             = 100        // cents — present iff paid trial
default_coupon_behavior = subscription
```

`PlanInfoProvider` only reads `product_type` today. The proposal:

1. **Enrich `OfferInfo` from metadata.** Read additional well‑known keys (`trial_price`, and later `family` / `rank` / `status`) into typed fields on `OfferInfo`. Zero contract changes — `Metadata` is already pass‑through.
2. **Filter out paid‑trial targets in upgrade logic.** A plan is paid‑trial iff `Metadata["trial_price"]` is present and `> 0`. Add one clause to `PlanUpgradeService.GetAvailableUpgradesAsync` (`:169`):

   ```
   target is eligible
       AND (target.trial_price_cents IS NULL OR target.trial_price_cents == 0)
   ```

3. **Once parity holds, drop the matching entries from `NonUpgradeablePlans`** — they're now covered by the rule.

This is a small, incremental change that proves the metadata‑driven approach before any larger restructuring of plan/family/rank modeling.

## Open Questions

- Are paid‑trial prices in Stripe consistently tagged with `trial_price` metadata, or do some still rely on `recurring.trial_period_days` (which subz doesn't surface)? Needs an audit before removing the blacklist entries.
- Should the rule also block *cross‑family* overrides (e.g. `legacy_plus → fsm`) from landing on a paid‑trial price? Almost certainly yes — the clause is independent of family/rank, so it does this for free.
