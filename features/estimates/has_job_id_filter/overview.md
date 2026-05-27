# Estimates: `hasJobId` Filter

**Tasks**: [WEB-1169](https://app.clickup.com/t/869ce1emx), [WEB-1170](https://app.clickup.com/t/869ce1ewh)
**Parent**: [WEB-1131](https://app.clickup.com/t/869cb9dme) (BE: Jobs Empty State Redesign)

## Goal

Add an optional `hasJobId` filter to the estimates paged and balances-by-status endpoints. The frontend needs this to show a conversion banner ("You have N approved estimates") that only counts **approved estimates not yet linked to a job** (`JobId == null`). When the parameter is omitted, endpoints behave exactly as before.

## Current State

### Data model

`Estimate.JobId` is a nullable string (`string?`) with `[BsonIgnoreIfNull]` in MongoDB. When an estimate is converted to a job (or created from a job), `JobId` is set. Otherwise it is `null` / absent from the document.

### Endpoints involved

| Layer | Endpoint | What it does today |
|-------|----------|--------------------|
| Gateway | `GET /api/v3/estimates/paged` | Accepts `limit`, `token`, `clientId`, `estimateStatus[]`. No job filter. |
| Gateway | `GET /api/v3/estimates/balances-by-status` | Accepts `clientId`. Returns count + totals per status. No job filter. |
| gRPC | `POST /v1/estimates/paged` | `GetEstimatesPagedRequest` has `status_types` (field 5). No job filter. |
| gRPC | `POST /v1/estimates/balances-by-status` | `GetEstimatesBalancesByStatusRequest` has `client_id` (field 2). No job filter. |

### Key files

| File | Role |
|------|------|
| `Tofu.Invoices.Protos/V1/EstimatesApi.proto` | Proto definitions for request/response messages |
| `Tofu.Invoices.Domain/Models/Estimate/Estimate.cs` | Entity with `JobId` field |
| `Tofu.Invoices.Domain/Queries/PagedEstimates/PagedEstimatesQuery.cs` | Query + predicate for paged listing |
| `Tofu.Invoices.Domain/Queries/CalculateEstimatesBalancesByStatus/` | Query + handler for balances stats |
| `Tofu.Invoices.Api/Grpc/V1/EstimatesService.cs` | gRPC service handlers |
| `Invoices.Backend: Invoices.Api/Controllers/EstimatesController.cs` | Gateway REST controller |
| `Invoices.Backend: Invoices.Core/Models/Estimates/GetEstimatesPagedRequestModel.cs` | Gateway request model (paged) |
| `Invoices.Backend: Invoices.Core/Models/Estimates/GetEstimatesBalancesByStatusRequestModel.cs` | Gateway request model (balances) |
| `Invoices.Backend: Tofu.Invoices/EstimatesGateway.cs` | gRPC client wrapper |
| `Invoices.Backend: Tofu.Invoices/Mapping/Mapper.cs` | Proto mapping |

---

## Changes by Layer

### 1. Proto (`Tofu.Invoices.Protos`)

**File:** `V1/EstimatesApi.proto`

Add `google.protobuf.BoolValue has_job_id` to both request messages. `BoolValue` makes it truly optional — `null` means no filter.

```protobuf
message GetEstimatesPagedRequest {
    string account_id = 1;
    int32 limit = 2;
    google.protobuf.StringValue client_id = 3;
    google.protobuf.StringValue token = 4;
    repeated EstimateStatus status_types = 5;
    google.protobuf.BoolValue has_job_id = 6;  // NEW
}

message GetEstimatesBalancesByStatusRequest {
    string account_id = 1;
    google.protobuf.StringValue client_id = 2;
    google.protobuf.BoolValue has_job_id = 3;  // NEW
}
```

Bump proto NuGet version in `Tofu.Invoices.Protos.csproj`.

### 2. Domain (`Tofu.Invoices.Domain`)

#### 2.1 Paged query

**File:** `Queries/PagedEstimates/PagedEstimatesQuery.cs`

Add `bool? HasJobId` to the query record and to `ByAccountIdOrClientId`. Extend `Predicate()`:

```csharp
&& (HasJobId == null
    || (HasJobId == true && i.JobId != null)
    || (HasJobId == false && i.JobId == null))
```

MongoDB LINQ handles `i.JobId == null` correctly for missing fields (documents without `JobId` match).

#### 2.2 Balances-by-status query

**File:** `Queries/CalculateEstimatesBalancesByStatus/CalculateEstimatesBalancesByStatusQuery.cs`

Add `bool? HasJobId` to the record.

**File:** `Queries/CalculateEstimatesBalancesByStatus/CalculateEstimatesBalancesByStatusQueryHandler.cs`

The handler fetches all estimates then groups in memory. Apply filter after fetch:

```csharp
if (query.HasJobId == true)
    estimates = estimates.Where(e => e.JobId != null).ToList();
else if (query.HasJobId == false)
    estimates = estimates.Where(e => e.JobId == null).ToList();
```

### 3. gRPC Service (`Tofu.Invoices.Api`)

**File:** `Grpc/V1/EstimatesService.cs`

Pass the new field from proto request to domain query in both handlers:

```csharp
// In GetEstimatesPaged:
HasJobId = request.HasJobId?.Value

// In GetEstimatesBalancesByStatus:
HasJobId = request.HasJobId?.Value
```

### 4. Gateway Request Models (`Invoices.Core`)

**File:** `Models/Estimates/GetEstimatesPagedRequestModel.cs`

```csharp
public bool? HasJobId { get; set; }
```

**File:** `Models/Estimates/GetEstimatesBalancesByStatusRequestModel.cs`

```csharp
public bool? HasJobId { get; init; }
```

### 5. Gateway Mapper (`Tofu.Invoices`)

**File:** `Mapping/Mapper.cs`

In `MapToRequest` (paged):

```csharp
if (obj.HasJobId.HasValue)
    request.HasJobId = obj.HasJobId.Value;
```

In `MapToProto` (balances-by-status):

```csharp
HasJobId = obj.HasJobId
```

### 6. Gateway Controller (`Invoices.Api`)

**File:** `Controllers/EstimatesController.cs`

Add `[FromQuery] bool? hasJobId` parameter to both endpoints:

**Paged:**
```csharp
public async Task<PageDto<EstimateDto>> Paged(
    [FromQuery] int? limit,
    [FromQuery] string? token,
    [FromQuery] string? clientId,
    [FromQuery] List<EstimateStatusDto>? estimateStatus,
    [FromQuery] bool? hasJobId,  // NEW
    CancellationToken ct = default)
```

**BalancesByStatus:**
```csharp
public async Task<EstimatesBalancesByStatusDto> BalancesByStatus(
    [FromQuery] string? clientId = null,
    [FromQuery] bool? hasJobId = null,  // NEW
    CancellationToken ct = default)
```

Pass to request models: `HasJobId = hasJobId`.

---

## Execution Order

| # | Repo | Scope |
|---|------|-------|
| 1 | Tofu.Invoices.Protos | Proto changes + version bump + publish NuGet |
| 2 | Tofu.Invoices.Backend | Domain queries (2.1, 2.2) + gRPC service (3) |
| 3 | Invoices.Backend | Gateway models (4) + mapper (5) + controller (6) |

Steps 2 and 3 can be done in parallel once the new proto NuGet is published.

## Testing

| Scenario | Expected |
|----------|----------|
| `GET /api/v3/estimates/paged` (no `hasJobId`) | Same as before — all estimates returned |
| `GET /api/v3/estimates/paged?hasJobId=false` | Only estimates without linked jobs |
| `GET /api/v3/estimates/paged?hasJobId=true` | Only estimates with linked jobs |
| `GET /api/v3/estimates/paged?hasJobId=false&estimateStatus=approved` | Approved estimates without jobs (conversion banner list) |
| `GET /api/v3/estimates/balances-by-status` (no `hasJobId`) | Same as before — counts for all estimates |
| `GET /api/v3/estimates/balances-by-status?hasJobId=false` | Counts only for unlinked estimates (conversion banner count) |
| Paged `totalCount` matches balances `approved.count` | When both use `hasJobId=false`, counts should be consistent |

## Related Documentation

- `features/jobs/implementation/6_job_from_estimate/overview.md` — Estimate-Job relation model and linking flows
- `Backend/Api/ESTIMATES_API_REFERENCE.md` — current API reference for estimates endpoints
