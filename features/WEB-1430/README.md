# WEB-1430 — Feature Rollout System

A flexible feature-flag mechanism for introducing new features to a controlled
subset of our users before a full release.

First concrete use case: enabling **Vacuum** for selected iOS accounts.
The design, however, must not be Vacuum- or iOS-specific — any future feature
should be able to reuse the same toggle infrastructure.

## Goals

- Turn a feature on/off without a deployment.
- Target by **account**, **user**, **platform** (iOS / Android / Web / Backend),
  app version, country, plan tier, or any combination.
- Support **percentage rollouts** (e.g. 10% today, 40% next week, 100% later).
- Assignment must be **deterministic and sticky** — the same user must always land
  on the same side of the split for a given flag.
- Fast kill-switch: a misbehaving feature can be turned off in seconds.
- Clients do not hard-code rollout logic — they ask the backend what is enabled.

## Non-goals

- We are **not** building an experimentation / A-B analytics platform.
  Metrics and statistical significance are out of scope for v1.
- No per-request dynamic evaluation in hot paths that cannot tolerate a config
  lookup — cache the flag state per request/session.

## Concepts

| Term              | Meaning |
|-------------------|---------|
| **Flag**          | A named boolean toggle, e.g. `ios.vacuum`. |
| **Targeting rule**| A predicate that decides who the flag applies to. |
| **Audience**      | The set of users/accounts matched by the rules. |
| **Rollout %**     | Fraction of the audience for which the flag is `on`. |
| **Bucketing key** | Stable identifier hashed to place a subject in `[0, 100)`. Default: `userId`; fallback `accountId`. |
| **Default**       | Value returned when no rule matches. Almost always `off`. |

### Deterministic bucketing

For a flag `F` and subject `S`, enabled iff:

```
hash(flagKey + ":" + subjectId) % 100 < rolloutPercent
```

Including the flag key in the hash prevents the same users from being
"first in line" on every feature. Same subject + same flag → same bucket, so
10% → 40% always grows the audience (no user is dropped on increase).

## Example rule shape

```json
{
  "key": "ios.vacuum",
  "enabled": true,
  "default": false,
  "rules": [
    {
      "when": {
        "platform": "iOS",
        "appVersionMin": "5.12.0",
        "country": ["US", "CA"]
      },
      "rollout": { "percent": 10, "by": "userId" }
    },
    {
      "when": { "accountId": ["acc_123", "acc_456"] },
      "value": true
    }
  ]
}
```

Rules evaluate top-to-bottom; first match wins. An explicit `accountId` allow-list
lets us force-enable for QA / pilot customers regardless of the percentage.

## Rollout playbook

Never jump from 0 → 100.

1. **Internal** — enable for staff accounts only (allow-list rule).
2. **Canary** — 1–5% of the target audience. Watch errors/latency/support tickets.
3. **Ramp** — 10% → 25% → 50% → 100% over several days, pausing between steps.
4. **Cleanup** — once at 100% and stable for 2+ weeks, remove the flag from code.

Stale flags accumulate tech debt — treat flag removal as part of finishing the feature.

## Implementation direction (Backend, .NET 8)

Recommended: **Microsoft.FeatureManagement** with custom filters.

- `PercentageFilter` — built-in, random per-request (not sticky). Do not use for
  user-facing rollouts.
- `TargetingFilter` — built-in, supports users, groups, and percentage; sticky
  via `TargetingContext`. This is the primary building block.
- Custom filters for project-specific dimensions: `PlatformFilter`,
  `AppVersionFilter`, `AccountTierFilter`, `CountryFilter`.

### v1 scope

At the first stage we only ship **one endpoint**:

```
GET /features/{featureKey}
→ { "enabled": true | false }
```

The endpoint takes no targeting parameters in the query or body. All targeting
input comes from the existing **`RequestContext`** that the middleware already
populates for every authenticated request:

| Field            | Nullable | Used in v1 |
|------------------|----------|------------|
| `product`        | no       | yes — keeps the flag store product-scoped |
| `platform`       | no       | reserved (iOS / Android / Web / Backend) |
| `accountId`      | yes      | reserved |
| `platformUserId` | no       | yes — primary v1 targeting dimension |
| `masterUserId`   | yes      | reserved |

**v1 stage — manual opt-in by `platformUserId`.** At the first stage we
enable a feature for a hand-picked list of `platformUserId`s. The evaluator
matches the caller's `platformUserId` against the flag's rules and returns
the rule's `value`; if no rule matches, it returns `default` (normally `off`).

Example v1 rule:

```json
{
  "key": "ios.vacuum",
  "enabled": true,
  "default": false,
  "rules": [
    {
      "when": { "platformUserId": ["pu_123", "pu_456", "pu_789"] },
      "value": true
    }
  ]
}
```

Additional dimensions (accountId, platform, app version, country, percentage
rollout) are layered on later by extending the rule evaluator — the wire
contract (`featureKey` in, `enabled` out) does not change.

### Storage plan

Flag definitions are stored in **MongoDB** — the service's primary DB, with
existing `MongoDbContext` + repository patterns. Document shape naturally
fits flags with nested rules and allow-lists, and no migrations are needed
when we add new targeting dimensions.

#### What to store

- `key` (e.g. `ios.vacuum`) — unique
- `description`
- `enabled` (master kill-switch)
- `default` (value when no rule matches)
- `rules: []` — ordered list of targeting rules; first match wins.
  Each rule has `when` (conditions on `RequestContext` fields such as
  `platformUserId`, `accountId`, `platform`, …) and `value` (the result when
  matched). In v1, rules match on `platformUserId` only; later rules add
  other dimensions and percentage rollout without changing the document shape.
- `createdAt`, `updatedAt`, `updatedBy`

Small dataset (tens to low hundreds of flags), read-heavy, rarely written,
cacheable for seconds to minutes.

#### Collection

- Collection: `FeatureFlags`
- Unique index on `key`
- Document example:
  ```json
  {
    "_id": "ObjectId(...)",
    "key": "ios.vacuum",
    "description": "Enable Vacuum in iOS app",
    "enabled": true,
    "default": false,
    "rules": [
      { "when": { "platformUserId": ["pu_123", "pu_456"] }, "value": true }
    ],
    "createdAt": "2026-04-14T10:00:00Z",
    "updatedAt": "2026-04-14T10:00:00Z",
    "updatedBy": "sergei.fedorov@tofu"
  }
  ```
- Caching is **not implemented in v1** — the endpoint reads directly from
  Mongo. An in-process cache (e.g. 30–60s TTL) is optional and can be added
  at a later stage if the endpoint shows measurable load.

## First use case — `ios.vacuum`

- Flag key: `ios.vacuum`
- Default: `off`
- v1 targeting: manual `platformUserId` allow-list — we collect IDs of pilot
  users (internal, QA, selected customers) and list them in a single
  `value: true` rule.
- Kill-switch: set `enabled: false` on the flag.

## Open questions

- Who can edit flags in production, and how is the change audited?
- Do we need per-flag analytics (exposure events) in v1, or defer?

## References

- [Microsoft.FeatureManagement — TargetingFilter](https://learn.microsoft.com/en-us/azure/azure-app-configuration/howto-targetingfilter)
- [Microsoft.FeatureManagement — .NET reference](https://learn.microsoft.com/en-us/azure/azure-app-configuration/feature-management-dotnet-reference)
- [Unleash — progressive / gradual rollouts](https://www.getunleash.io/feature-flag-use-cases-progressive-or-gradual-rollouts)
- [GrowthBook — what are feature flags](https://blog.growthbook.io/what-are-feature-flags/)
- [Feature flags: 12 best practices](https://designrevision.com/blog/feature-flags-best-practices)
