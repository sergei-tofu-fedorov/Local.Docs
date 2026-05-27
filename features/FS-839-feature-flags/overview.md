# FS-839 — Feature Flags for FieldService: bulk read by user / account

## 1. What we do

Add a backend mechanism that lets a caller ask the server "give me all feature settings that apply to me" in a single call. Settings include both an `enabled` flag and an optional payload (e.g. parameters for SQLite autovacuum). Targeting works globally, per-account, or per-platform-user.

The storage shape — Mongo collection with `enabled / default / rules[]` and first-match-wins resolution — and the bulk read endpoint with `accountId` / `platformUserId` targeting are introduced by this ticket.

## 2. Why

From the initiative ([FS-948](https://app.clickup.com/t/869cwthhk)):

- Maintaining one-off "show this hint once / remember it was seen" flags across the apps has become painful — each is implemented ad-hoc, no central place to roll a setting back or out.
- Need a single mechanism to:
  1. Describe a feature centrally.
  2. Toggle it globally for everyone.
  3. Toggle it for a specific list of accounts (allow-list).
  4. (future) Let the client itself flip a flag once some condition is met.
- Concrete first use case named in the initiative: SQLite autovacuum on FSM clients — needs not just on/off, but parameters.

So a feature flag here is **a small piece of configuration**, not just a boolean.

## 3. What already exists (do not reinvent)

| Piece | Where | What it gives us |
|---|---|---|
| `FeaturesController` + `FeaturesDto` | `Invoices.Backend` — `Src/Invoices.Api/Controllers/FeaturesController.cs`, `[ApiVersion("3.0")]` `GET /api/features` | Wire shape `{ Features: [{ Id, Enabled, Options }] }` already in production. |
| `FeaturesService` | `Invoices.Backend` — `Src/Invoices.Implementation.Services/Features/FeaturesService.cs` | Today computes one hard-coded flag (`IsEnabledEstimateForOldUsers`). Will be the integration point for the new resolver. |
| `IAccountConfigurationsService` + `Configuration` collection | `Invoices.Backend` — `AccountConfigurationsController`, `Configuration { Id=accountId, Features:[{Name}] }` | Existing per-account named-flag store (sole entry today: `platform_fee_1_percent`, read by `PaymentIntentsService.GetEntityForPayment` to decide whether to apply a 1% platform fee). **Stays as-is** — exposed through the resolver via a `ConfigurationBackedComputedFeatureFlag : IComputedFeatureFlag` adapter (see §5.4). No data migration. |

## 4. What we add (scope of FS-839)

1. **Mongo collection `FeatureFlags`** in `Invoices.Backend` — see §5.2 for the document shape. Targeting rule supports `accountId` and `platformUserId` allow-lists; `value` is `{ enabled, options }` (object), not a bare bool, so flags can carry payload.
2. **Bulk read endpoint** — extend the existing `GET /api/features` (`api-version: 3` header) to return the resolved set of flags for the caller (no query params). Inputs come from what `BaseController` already exposes: `AccountId`, plus `platformUserId` derived from `AuthenticationInfo.MasterUser.GetPlatformUserId(Request.GetPlatform(), ProductKey).PlatformId` (same pattern used today in e.g. `WebCheckoutController.cs:48`). Backward compatible: the legacy `IsEnabledEstimateForOldUsers` flag continues to appear in the response.
3. **Resolver service** — first-match-wins evaluation against the caller's `accountId` and `platformUserId`.
4. **In-process cache** — 30–60s TTL on the loaded `FeatureFlags` set; reads are hot, writes are rare. Refresh is lazy on miss / TTL expiry; no explicit invalidation in v1 (a flag edit becomes visible within one TTL window).
5. **Adapter for `Configuration.Features`** — implement `ConfigurationBackedComputedFeatureFlag : IComputedFeatureFlag` (one instance per known feature name; today only `platform_fee_1_percent` → key `invoices.platform_fee_1_percent`). It reads the caller's `Configuration` document and reports `enabled = true` when the feature name is present. `Configuration` stays the source of truth — no data migration, no dual-write.
6. **Switch the existing read site** — `PaymentIntentsService.GetEntityForPayment` (`Src/Invoices.Payments/PaymentIntentsService.cs:414`) calls `IFeatureFlagsResolver.IsEnabled("invoices.platform_fee_1_percent", accountId)` instead of inspecting `accountFeatures` directly. Drop the `IReadOnlyCollection<ConfigurationFeature>?` parameter once nothing else reads it.

> Real flag content (e.g. `fsm.sqlite_autovacuum`) is **not seeded by code** — once the collection and the endpoint are live, flags are created/edited directly in Mongo by the team.

### Not in scope (separate tickets)

- Client-driven write of flags (`PUT /features/{key}`).
- Admin UI / CRUD tooling.
- Percentage rollouts (`hash(key + subject) % 100 < N`).
- Audit trail / exposure events.
- Migrating `Configuration.Features` data into the `FeatureFlags` collection or deprecating `POST /api/account-configurations/set` — `Configuration` stays the SoT for those flags via the computed-flag adapter.
- BDUI ↔ flag integration (which template to fetch).

## 5. How

### 5.1 API contract

Same endpoint, same DTO shape, broader semantics.

```
GET /api/features
api-version: 3
Authorization: Bearer <token>
```

Response (existing `FeaturesDto`):

```json
{
  "features": [
    {
      "id": "fsm.sqlite_autovacuum",
      "enabled": true,
      "options": "{\"intervalHours\":24,\"pageThreshold\":1000}"
    },
    {
      "id": "IsEnabledEstimateForOldUsers",
      "enabled": true,
      "options": null
    }
  ]
}
```

Rules:

- `id` matches the flag `key`. Naming convention for **new** flags: `<namespace>.<feature_name>` — lowercase ASCII, words separated by `_`, exactly one `.` between namespace and name (regex: `^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$`). Examples: `fsm.sqlite_autovacuum`, `invoices.platform_fee_1_percent`. The only existing exception is the legacy `IsEnabledEstimateForOldUsers` (PascalCase, no namespace, hardcoded today in `FeaturesService.cs:81`) — it is already in production responses and renaming it is a breaking change for mobile clients, so it is grandfathered. No new flag may use PascalCase or camelCase; renames of the legacy id, if ever needed, ship under a separate ticket with a deprecation period.
- `enabled` is the post-resolution value.
- `options` is a JSON string (or `null`). Existing field on the DTO — no wire-shape change.
- Empty list (`{ "features": [] }`) is a valid response, returned as `200`.
- A flag is included when (a) its master `enabled = true`, and (b) some rule matches the caller, **or** the `default` carries a meaningful value (i.e. enabled=true or non-null payload). Plain "off, no payload" flags are omitted to keep the response small.

### 5.2 Storage — `FeatureFlags` collection

**New** Mongo collection in `Invoices.Backend`, to be created as part of this ticket. Unique index on `key`.

```json
{
  "_id": "ObjectId(...)",
  "key": "fsm.sqlite_autovacuum",
  "description": "SQLite autovacuum tuning for FSM clients",
  "enabled": true,
  "default": { "enabled": false, "options": null },
  "rules": [
    {
      "when": { "accountId": ["acc_123", "acc_456"] },
      "value": { "enabled": true, "options": { "intervalHours": 24 } }
    },
    {
      "when": { "platformUserId": ["pu_789"] },
      "value": { "enabled": true, "options": { "intervalHours": 6 } }
    }
  ],
  "createdAt": "2026-05-04T10:00:00Z",
  "updatedAt": "2026-05-04T10:00:00Z",
  "updatedBy": "system"
}
```

Notes on the shape:

- `value` is an object `{ enabled, options }` (so a flag can carry payload, not just a boolean). Each rule has its **own** `value`, so different cohorts can get different payloads. In the example above, accounts in the first list get `intervalHours: 24`, while platform user `pu_789` gets the more aggressive `intervalHours: 6`. **Rules are an ordered priority list, not combined.** If one caller satisfies several rules at once, only the first one's `value` is used — later rules are not evaluated, payloads are never merged. Anyone who matches no rule falls back to `default` — here `enabled:false, options:null` (autovacuum is off for everyone else).
- `options` is free-form JSON (object, array, or `null`) — the resolver doesn't interpret it; it's passed through to the client as a JSON string in `FeatureDto.Options` (see §5.4 on parsing).
- `when` supports `accountId` and `platformUserId` (lists). Conditions inside one `when` are AND-ed.

**Alternative considered: per-account override documents** (`{ accountId, overrides: {key: value} }` + a separate defaults collection). Rejected — we have few flags × many accounts, and the operational unit is the flag, not the account: rollout to N accounts is one update here vs N there; kill-switch is one boolean vs a coordinated write; targeting by `platformUserId` doesn't fit a "by account" shape cleanly; and read perf is sub-ms either way at our scale (≤100 flags). Worth revisiting only if flag count grows to thousands.

### 5.3 Resolution

The resolver merges flags from two sources for the current caller and returns one combined list.

**Per request** the resolver:

1. Fetches **all flags with master `enabled = true`** from an in-process cache (30–60s TTL). On cold cache / TTL expiry it loads them from the `FeatureFlags` collection in one round-trip (`find({ enabled: true })`) and stores them in memory. No targeted query by accountId — flags are not indexed by subject; allow-lists live inside the document. A flag edit becomes visible within one TTL window; no explicit invalidation in v1.
2. For each loaded flag, builds a `HashSet<string>` for every `when.accountId` / `when.platformUserId` list once (cached together with the flag set), then evaluates rules in order:
   - Skip the flag entirely if master `enabled = false` (already filtered by the query, but kept as a safety check).
   - Walk `rules` top-to-bottom. **The first rule whose `when` matches the caller wins** — its `value` becomes the answer for this flag, and any later rules are not evaluated. Rules are an ordered priority list, **not** OR-ed or AND-ed across each other. Put more specific rules first.
   - Inside a single rule, `when` uses **AND** between its conditions: every listed condition must hold. E.g. `when: { accountId: [A, B], platformUserId: [X] }` matches only if the caller's account is in `[A, B]` **and** their platform user is `X`. Each condition reduces to one HashSet lookup.
   - If no rule matches, use the flag's `default`.
   - Include the resulting `{ enabled, options }` in the response per the inclusion rule in §5.1.

   *Worked example.* Caller has `accountId = acc_123`, `platformUserId = pu_789`. Flag `fsm.sqlite_autovacuum` from §5.2: rule\[0\] (`when.accountId` contains `acc_123`) matches and wins → caller gets `intervalHours: 24`. Rule\[1\] (`when.platformUserId` contains `pu_789`) would also have matched, but is **not evaluated**, so its `intervalHours: 6` does not apply and is not merged in. To give the same caller the more aggressive interval, the order would have to be reversed.
3. Asks each `IComputedFeatureFlag` registered in DI (see §5.4) to evaluate itself for the caller's `accountId` and `platformUserId` — **but only for keys that are not present as a stored document**. Each computed result is merged into the response in the same shape (`{ id, enabled, options }`). This is how `IsEnabledEstimateForOldUsers` continues to work — it becomes one such computed implementation rather than a hardcoded merge inside `FeaturesService`.

**Stored owns the key.** Any key that has a document in the `FeatureFlags` collection is considered "owned" by the stored source — the matching `IComputedFeatureFlag` (if any) is **not evaluated at all** for that key, regardless of how the stored value resolves. So if a stored flag with key `K` resolves to `enabled: false, options: null` for the caller (default with no matching rule), the response simply omits `K` per §5.1 — it does **not** fall back to the computed implementation. This is the kill-switch mechanism: dropping a document into the collection deactivates the corresponding computed flag without a deploy.

**Operational limits (v1).** The "load all (with cache) and scan in memory" approach is fine because we cap the working set:

- ≤ ~100 active stored flags.
- ≤ 1000 IDs in any single allow-list (`when.accountId` or `when.platformUserId`).
- ≤ 20 rules per flag.

If a flag needs a larger audience than that, it should be expressed as `default = enabled` + a small deny-list rule, or moved to a percentage rollout (out of scope for v1). Crossing these limits should trigger a design revisit — at that point indexed-by-subject lookup or a per-account override collection becomes worth the added complexity.

In v1 we support two condition keys for stored flags:

| Key | What it matches |
|---|---|
| `accountId` | A list of account IDs. The rule applies if the caller's account is in the list. |
| `platformUserId` | A list of platform user IDs. The rule applies if the caller's platform user is in the list. |

### 5.4 Implementation outline (in `Invoices.Backend`)

1. New repository + models under `Src/Invoices.Implementation.*` and persistence in the existing Mongo context. Concrete shape:
   ```csharp
   public sealed class FeatureFlag
   {
       public required string Id { get; init; }                 // ObjectId
       public required string Key { get; init; }                // unique
       public string? Description { get; init; }
       public required bool Enabled { get; init; }              // master kill-switch
       public required FeatureFlagValue Default { get; init; }
       public required List<FeatureFlagRule> Rules { get; init; }
       // CreatedAt, UpdatedAt, UpdatedBy — auditing
   }

   public sealed class FeatureFlagRule
   {
       public required FeatureFlagWhen When { get; init; }
       public required FeatureFlagValue Value { get; init; }
   }

   public sealed class FeatureFlagWhen
   {
       public List<string>? AccountId { get; init; }
       public List<string>? PlatformUserId { get; init; }
   }

   public sealed class FeatureFlagValue
   {
       public required bool Enabled { get; init; }
       public BsonDocument? Options { get; init; }              // free-form JSON; serialised to string before going on the wire
   }
   ```
   Notes on parsing:
   - `When` is **typed**, not an open `Dictionary<string, List<string>>`. The two known condition keys (`accountId`, `platformUserId`) are explicit properties. Adding a new condition key is a code change anyway — the resolver needs the corresponding caller value plumbed in — so a typed shape is simpler and safer than reflective lookup.
   - `Options` is stored in Mongo as a sub-document so it can be edited as plain JSON in the DB. The resolver converts it to a JSON string (`Options?.ToJson()`) just before mapping to `FeatureDto.Options` (`string?`). The wire shape stays unchanged.
   - Standard `MongoDB.Driver` BSON deserialisation, no custom parser. Driver-level conventions (camelCase ↔ PascalCase) already wired up in `Invoices.Backend`.
2. `IFeatureFlagsResolver` service: in-process cache (30–60s TTL) of stored flags, evaluation logic from §5.3, and DI-injected `IEnumerable<IComputedFeatureFlag>` for computed flags.
3. Introduce `IComputedFeatureFlag` interface — minimal shape, takes only the inputs the resolver actually has at hand:
   ```csharp
   public interface IComputedFeatureFlag
   {
       string Key { get; }
       Task<FeatureFlagValue> Evaluate(string accountId, string? platformUserId, CancellationToken ct);
   }
   ```
   Implementations are registered in DI (Scrutor scan in `Invoices.DIConfig`) and discovered automatically by the resolver. Two implementations land in this ticket:
   - `IsEnabledEstimateForOldUsersComputedFlag` — the existing computed predicate moved out of `FeaturesService`. `FeaturesService` becomes a thin pass-through over the resolver.
   - `ConfigurationBackedComputedFeatureFlag` — reads the caller's `Configuration` document via `IAccountConfigurationsService` and reports `enabled = true` when the configured feature name is present. One DI registration per known name; today only `platform_fee_1_percent` → key `invoices.platform_fee_1_percent`.
4. **Switch the read site** — update `PaymentIntentsService.GetEntityForPayment` (`Src/Invoices.Payments/PaymentIntentsService.cs:414`) to call `IFeatureFlagsResolver.IsEnabled("invoices.platform_fee_1_percent", accountId)` instead of inspecting `accountFeatures`. `accountId` is already passed into `GetEntityForPayment`; `platformUserId` is not needed for this flag. Drop the `IReadOnlyCollection<ConfigurationFeature>?` parameter and the now-dead loading code in callers.
5. Tests:
   - Unit for resolver (rule order, AND in `when`, default, kill-switch, stored-wins-over-computed merge).
   - Unit for `IsEnabledEstimateForOldUsersComputedFlag` (parity with the previous `FeaturesService` behaviour).
   - Unit for `ConfigurationBackedComputedFeatureFlag` (`enabled = true` iff the feature name is in `Configuration.Features`; `false` when the document or feature is missing).
   - Integration on `GET /api/features` (`api-version: 3`) covering: both computed flags, a stored flag with payload, caller match by `accountId` / `platformUserId`.
   - Regression on `PaymentIntentsService` — fee applied iff the new flag resolves to enabled for the account.

Steps 1–5 fit inside the parent estimate (FS-949 = 16h) provided the admin tooling and client-driven write path stay out.

## 6. First flags

| Key | Source | Notes |
|---|---|---|
| `IsEnabledEstimateForOldUsers` | computed flag (existing logic, moved out of `FeaturesService`) | **Legacy / grandfathered** key — PascalCase, no namespace (matches the literal already produced by `FeaturesService.cs:81` and consumed by mobile clients). Kept as-is to avoid breaking the wire shape. Same behaviour as today; just exposed through the resolver. |
| `invoices.platform_fee_1_percent` | computed flag — `ConfigurationBackedComputedFeatureFlag` over `Configuration.Features` | Existing data and write endpoint untouched. Read by `PaymentIntentsService` via the resolver. |
| `fsm.sqlite_autovacuum` | stored flag | First use case from FS-948. Document is created and managed manually in Mongo after deploy. |

All new flag keys must follow the `<namespace>.<feature_name>` convention from §5.1. Other flags (one-time hint dismissals, future FSM toggles) are added the same way — either by writing a new document directly to Mongo (stored flag) or by adding a new `IComputedFeatureFlag` implementation in code and registering it in DI (computed flag).

## 7. Related

- [WEB-1430 — Feature Rollout System](../WEB-1430/README.md) — earlier design sketch for a generic feature-flag mechanism. Listed here for reference only.
