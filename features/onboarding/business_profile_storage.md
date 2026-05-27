
Onboarding – Business Profile Storage
======================================

Goal
----

Collect business profile information during onboarding (industry, team size, pain points) and persist it on the backend so it can be retrieved later by any client, used for analytics/segmentation, and as input for feature flags.

Storage Decision
----------------

Store as a **separate `business_profiles` collection** in MongoDB (Invoices.Backend), linked to Account by `accountId`.

Rationale:

- Separate collection is easier for analytics queries without loading full Account documents.
- MongoDB supports efficient indexing and aggregation on a dedicated collection.
- Keeps Account document lean — business profile is conceptually related but queried independently for segmentation.

Data Model
----------

New collection `business_profiles`:

```csharp
public class BusinessProfile
{
    [BsonId]
    [BsonRepresentation(BsonType.ObjectId)]
    public string? Id { get; set; }

    [BsonRequired]
    public string AccountId { get; set; }

    public string? Industry { get; set; }
    public string? TeamSize { get; set; }
    public List<string>? PainPoints { get; set; }

    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
}
```

**Index**: unique index on `accountId` — one profile per account.

`BusinessName` is already a top-level field on `Account`, so it is not duplicated here.

### Allowed Values

Fields are stored as **strings**. The backend validates incoming values against the allowed sets below. Unknown values are **ignored** (the field is not updated), and an error is logged.

**Industry:**

| Key | Category |
|-----|----------|
| `general_contracting` | Trades |
| `electrical` | Trades |
| `hvac` | Trades |
| `locksmith` | Trades |
| `mechanical_service` | Trades |
| `plumbing` | Trades |
| `handyman` | Home Services |
| `appliance_repair` | Home Services |
| `flooring` | Home Services |
| `junk_removal` | Home Services |
| `painting` | Home Services |
| `pest_control` | Home Services |
| `pool_spa_service` | Home Services |
| `renovations` | Home Services |
| `roofing` | Home Services |
| `cleaning` | Cleaning |
| `arborist_tree_care` | Lawn & Outdoor |
| `landscaping` | Lawn & Outdoor |
| `lawn_care_maintenance` | Lawn & Outdoor |
| `snow_removal` | Lawn & Outdoor |
| `computers_it` | Specialty Services |
| `home_theater` | Specialty Services |
| `security_alarm` | Specialty Services |
| `other` | Other |

**TeamSize:**

| Key | Label |
|-----|-------|
| `1` | Just me |
| `2_5` | 2–5 people |
| `6_10` | 6–10 people |
| `11_plus` | 11+ people |

**PainPoints:**

| Key | Label |
|-----|-------|
| `paperwork_takes_time` | Paperwork eats my evenings |
| `lose_job_details` | I lose job details |
| `hard_to_track_jobs` | Hard to track active jobs |
| `slow_estimates_payments` | Slow estimates and payments |
| `too_many_tools` | Too many tools for one job |

### Query Patterns

**Primary use case — segmentation/analytics:**

```js
db.business_profiles.find({
    teamSize: { $in: ["2_5", "6_10", "11_plus"] },
    industry: { $in: ["plumbing", "hvac"] }
}, { accountId: 1 })
```

Returns `accountId` list → look up full account info separately.

**Secondary use case — feature flags / paywall selection:**

```js
// Check single account's profile for feature flag logic
db.business_profiles.findOne({ accountId: "abc123" })
```

Used to determine which paywall/plan to show based on business attributes. Where this logic lives (backend vs client) is TBD — but the data needs to be accessible from backend either way. Possible approaches:
- Backend resolves flags and returns them in an existing API response (e.g., `plans/current` or a dedicated flags endpoint)
- Client fetches profile and applies rules locally

API Endpoints
-------------

### Save Business Profile

**Endpoint**: `PUT /api/v3/account/business-profile`

**Auth**: Requires authenticated user with `Account-Id` header.

**Request body**:

```json
{
  "industry": "plumbing",
  "teamSize": "team_2_5",
  "painPoints": ["paperwork", "estimates_payments"]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `industry` | string? | no | Industry key (see allowed values) |
| `teamSize` | string? | no | Team size key (see allowed values) |
| `painPoints` | string[]? | no | Selected pain points (one or more) |

**Behaviour**:

- Resolves `AccountId` from the request context (header).
- Upserts into `business_profiles` collection (insert if not exists, update if exists).
- Only fields present in the request are updated; `null` fields are ignored (partial update).
- Validates string values against allowed sets. If an unknown value is received, the field is **not updated** (existing value is preserved), and the backend **logs an error**. The request still succeeds — unknown values are silently skipped, not rejected.

**Response**: `200 OK`

```json
{
  "industry": "plumbing",
  "teamSize": "team_2_5",
  "painPoints": ["paperwork", "estimates_payments"]
}
```

**Errors**:

- `401 Unauthorized` — missing or invalid auth token.
- `404 Not Found` — account not found.

---

### Get Business Profile

**Endpoint**: `GET /api/v3/account/business-profile`

**Auth**: Requires authenticated user with `Account-Id` header.

**Response**: `200 OK`

```json
{
  "industry": "plumbing",
  "teamSize": "team_2_5",
  "painPoints": ["paperwork", "estimates_payments"]
}
```

**Errors**:

- `401 Unauthorized` — missing or invalid auth token.
- `404 Not Found` — business profile has not been set yet.

Extensibility
-------------

Adding new fields in the future requires only:

1. Add the property to `BusinessProfile` class.
2. Add the new allowed values to the validation set.
3. Include in the request/response DTOs.

No database migration needed — MongoDB schemaless design handles new fields naturally.

