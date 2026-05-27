# Subscription Product IDs

**Task**: [FS-836](https://app.clickup.com/t/869cg8wcv) — subtask of [FS-763 (BE: Invite workers)](https://app.clickup.com/t/869cb4jj6)

## What Changed

`FsmTeam` and `FsmBusiness` enum values and upgrade priority already existed in the codebase, but their product ID sets in [`PlansConstants.cs`](https://github.com/m-unicorn/Invoices.Backend/blob/master/Src/Invoices.Core/Consts/PlansConstants.cs) were empty. This meant any Apple/Google purchase of a Team or Business plan would fall through all hash set checks and incorrectly resolve to `ProductType.Plus`.

FS-836 populates these sets with the actual product IDs so that [`PlanInfoProvider`](https://github.com/m-unicorn/Invoices.Backend/blob/master/Src/Invoices.Implementation.Services/Plans/PlanInfoProvider.cs) correctly resolves Team/Business subscriptions.

## Product ID Registry

### Invoice Maker tiers

| Tier | Product IDs |
|------|------------|
| **Premium** | `com.getpaidapp.invoices.premium_*` (30+ variants — weekly, monthly, annual across platforms) |
| **Invoicing** | `fieldservice.invoicing.weekly.intro499`, `fieldservice.invoicing.weekly.trial3d`, `fieldservice.invoicing.yearly.base` |

### Field Service tiers

| Tier | Product IDs | Pricing |
|------|------------|---------|
| **FsmSolo** | `fieldservice.solo.monthly.intro19`, `fieldservice.solo.monthly.trial7d`, `fieldservice.solo.yearly.base` | $29/mo |
| **FsmTeam** | `fieldservice.team.monthly.trial7d`, `fieldservice.team.monthly.intro49`, `fieldservice.team.yearly.base` | $79/mo (intro: $49 first month) |
| **FsmBusiness** | `fieldservice.business.monthly.trial7d`, `fieldservice.business.monthly.intro99`, `fieldservice.business.yearly.base` | $149/mo (intro: $99 first month) |

All product IDs share the prefix `com.getpaidapp.` (omitted above for readability).

## Resolution Flow

Two code paths resolve product IDs to `ProductType`, depending on payment provider:

**Apple/Google** — matches the raw product ID against `PlansConstants.*ProductIds` hash sets:

```
productId → PremiumProductIds → InvoicingProductIds → FsmSoloProductIds
          → FsmTeamProductIds → FsmBusinessProductIds → fallback: Plus
```

**Stripe/Paddle** — reads `product_type` metadata from the Stripe offer and matches against string constants (`fsm_solo`, `fsm_team`, `fsm_business`, etc.). Weekly duration always maps to Plus.

See [Subscription Tier Priority](../../../features/jobs/implementation/6_job_from_estimate/6.10_subscription_priority.md) for how the resolved `ProductType` is used to select the primary subscription when a user has multiple active plans.

## Team and Business Activation

FsmTeam and FsmBusiness were added to the `ProductType` enum and upgrade priority as part of the Invite Workers initiative ([FS-230](https://app.clickup.com/t/869bu3yzw)). Product IDs were registered in FS-836.

These tiers enable multi-seat subscriptions:
- **Team**: 5 worker seats
- **Business**: 10 worker seats

Seat count is carried in the `SeatCount` field on `Offer` and `ProfileSubscription` models (defined in Subz).
