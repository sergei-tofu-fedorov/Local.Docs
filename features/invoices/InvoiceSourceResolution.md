Invoice Source Resolution
=========================

## Problem

When creating an invoice, the system determines its `Source` (Job, Estimate, or None)
based on the presence of `JobId` and `EstimateId` on the invoice object. If both fields
are present, the system always preferred `JobId`, making it impossible for callers to
explicitly choose `Estimate` as the source.

This caused incorrect analytics events: an invoice created from an estimate but also
linked to a job would emit `InvoiceCreatedFromJobDomainEvent` instead of
`InvoiceCreatedFromEstimateDomainEvent`.

## Solution

The `AddInvoiceCommand` and gRPC `AddRequest` now accept an optional `source` parameter.
When set to `Job` or `Estimate`, it overrides the default inference logic.

### Resolution Rules

The source is resolved in `EnrichedInvoice.ResolveSource` with the following priority:

| Passed Source | JobId present | EstimateId present | Resolved Source |
|---------------|---------------|--------------------|-----------------|
| `Job`         | yes           | (any)              | **Job**         |
| `Job`         | no            | (any)              | **None**        |
| `Estimate`    | (any)         | yes                | **Estimate**    |
| `Estimate`    | (any)         | no                 | **None**        |
| `null`        | yes           | (any)              | **Job**         |
| `null`        | no            | yes                | **Estimate**    |
| `null`        | no            | no                 | **None**        |

Key points:

- Only `Job` and `Estimate` are accepted as explicit overrides; other values fall through to default inference.
- An explicit source is only honored when the matching identifier (`JobId` or `EstimateId`) is non-empty. If the ID is missing, the system falls back to `None`.
- When `source` is `null` (not provided), the legacy behavior is preserved: `JobId` takes priority over `EstimateId`.

## Contract Changes

### gRPC Proto (`InvoicesApi.proto`)

New optional field on `AddRequest`:

```protobuf
message AddRequest {
    InvoiceObj invoice = 1;
    optional google.protobuf.StringValue master_user_id = 2;
    optional int64 occurred_at_ms = 3;
    optional google.protobuf.StringValue job_number = 4;
    optional InvoiceSource source = 5;  // NEW
}
```

Uses the existing `InvoiceSource` enum (`ISRC_UNKNOWN`, `ISRC_NONE`, `ISRC_ESTIMATE`, `ISRC_JOB`).

### Domain Command

```csharp
public record AddInvoiceCommand(
    Invoice Invoice,
    string? MasterUserId,
    DateTimeOffset? OccurredAt,
    string? JobNumber = null,
    InvoiceSource? Source = null)   // NEW
```

## Backward Compatibility

The field is optional with a default of `null`. Existing callers that do not pass `source`
get the same behavior as before (JobId > EstimateId > None).
