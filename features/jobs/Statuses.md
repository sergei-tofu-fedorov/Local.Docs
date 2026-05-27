Jobs - Statuses
===============

This document describes the **job status system**: how statuses are computed,
the relationship between manual and effective statuses, and the status lifecycle.

Related:
- `Activity.md` for timeline events and activity phrasing.
- `Backend/Domain.md` → Amount Display Logic for how status affects displayed amounts.
- `Backend/Api/JOBS_API_REFERENCE.md` → [Amount Display Rules](../../Backend/Api/JOBS_API_REFERENCE.md#amount-display-rules) for API-level details.

Enums
-----

### JobStatus (7 values)

```csharp
public enum JobStatus
{
    Unscheduled = 1,
    Scheduled = 2,
    InProgress = 3,
    Completed = 4,       // Not used in EffectiveStatus
    ReadyForInvoice = 5,
    Invoiced = 6,
    Paid = 7
}
```

**Note:** `Completed = 4` exists in the enum but is never returned by `EffectiveStatus`.
When a job is manually completed, it goes directly to `ReadyForInvoice` (5), `Invoiced` (6), or `Paid` (7).

### JobManualStatus (2 values)

```csharp
public enum JobManualStatus
{
    None = 1,
    Completed = 2
}
```

Only `None` and `Completed` are implemented. `InProgress` and `OnHold` do not exist.

### VisitStatus (4 values)

```csharp
public enum VisitStatus
{
    Unknown = 0,
    Scheduled = 1,
    InProgress = 2,
    Completed = 3
}
```

### JobInvoiceStatus (3 values)

```csharp
public enum JobInvoiceStatus
{
    Unknown = 0,
    Unpaid = 1,
    Paid = 2
}
```

EffectiveStatus Logic
---------------------

`Job.EffectiveStatus` is a **computed property** (not stored). The logic:

```
// ManualStatus takes priority - checked FIRST
if (ManualStatus == Completed)
    if (no invoice linked)
        return ReadyForInvoice
    if (invoice is paid)
        return Paid
    else
        return Invoiced

// Only then check visits
if (no visits)
    return Unscheduled

if (any visit is InProgress)
    return InProgress

if (any visit is Scheduled)
    return Scheduled

// All visits completed but not manually confirmed
return InProgress  // capped until manual completion
```

### Key Points

- `ManualStatus == Completed` takes priority over all other status checks
- `ReadyForInvoice` = manually completed (`ManualStatus == Completed`), no invoice linked
- `Invoiced` = manually completed, invoice linked but not paid
- `Paid` = manually completed, invoice paid
- `Unscheduled` = no visits exist AND not manually completed
- `Scheduled` = at least one visit with `Scheduled` status
- `InProgress` = any visit with `InProgress` status, OR all visits completed but job not manually marked complete

**Note**: A job without visits can still be completed if `ManualStatus` is set to `Completed`.

Status Flow Diagram
-------------------

```
                    ┌─────────────┐
                    │ Unscheduled │
                    │ (no visits) │
                    └──────┬──────┘
                           │ add visit
                           ▼
                    ┌─────────────┐
                    │  Scheduled  │◄────────────┐
                    │             │             │
                    └──────┬──────┘             │
                           │ visit → InProgress │
                           ▼                    │
                    ┌─────────────┐             │
                    │ InProgress  │─────────────┘
                    │             │  (visit completed,
                    └──────┬──────┘   more scheduled)
                           │
                           │ all visits completed
                           │ (stays InProgress until manual action)
                           │
                           │ ManualStatus → Completed
                           ▼
┌──────────────────────────────────────────────────────┐
│                Post-Completion Flow                  │
│                                                      │
│  ┌─────────────────┐    ┌──────────┐    ┌──────┐   │
│  │ReadyForInvoice  │───▶│ Invoiced │───▶│ Paid │   │
│  │ (no invoice)    │    │(unpaid)  │    │      │   │
│  └─────────────────┘    └──────────┘    └──────┘   │
│                                                      │
└──────────────────────────────────────────────────────┘
```

Manual Status Override
----------------------

Users can manually mark a job as completed via `Job.UpdateManualStatus()`.

When `ManualStatus == Completed`:
- The job enters the post-completion billing flow
- Final status depends on invoice state (ReadyForInvoice → Invoiced → Paid)
- A `StatusChanged` event is raised

When `ManualStatus` is reset to `None`:
- The job reverts to computed status based on visits
- A `StatusChanged` event is raised

**Not implemented:**
- `JobManualStatus.InProgress` - cannot manually set a job to In Progress
- `JobManualStatus.OnHold` - on hold status does not exist
- Undo functionality for status changes

Status Storage
--------------

| Property | Stored? | Location |
|----------|---------|----------|
| `ManualStatus` | Yes | `jobs.Jobs.ManualStatus` column |
| `EffectiveStatus` | Computed | `Job.EffectiveStatus` property |
| `EffectiveStatus` (cached) | Yes | `jobs.JobSummaryView.EffectiveStatus` column |

The `JobSummaryView.EffectiveStatus` is refreshed by `Job.RefreshComputedFields()`
before each save, ensuring list queries can filter by status without recomputing.

UI Badge Mapping
----------------

| EffectiveStatus   | UI Badge        |
|-------------------|-----------------|
| `Unscheduled`     | Created         |
| `Scheduled`       | Scheduled       |
| `InProgress`      | In Progress     |
| `ReadyForInvoice` | Job Completed   |
| `Invoiced`        | Invoiced        |
| `Paid`            | Paid            |
