Jobs - Alerts (Action Required)
===============================

This document describes the **job alerts system**: conditions that trigger
"Action Required" status, indicating the job needs user attention.

Overview
--------

Jobs display an "Action Required" alert when they are in a state that needs
user intervention. These alerts are shown regardless of invoice status.

Alert Conditions
----------------

### Action Required: Overdue

Triggered when a **Scheduled** visit's date/time has passed without the visit
being started or completed.

| Visit Status | Condition | Alert |
|--------------|-----------|-------|
| Scheduled | Visit datetime has passed | Action Required (Overdue) |

**Important**: Only visits with `Scheduled` status are considered for overdue alerts.
- `InProgress` visits are not overdue (work has already started)
- `Completed` visits are not overdue (work is done)

**Note**: If an overdue Scheduled visit exists alongside a future scheduled visit,
the overdue alert takes precedence.

### Action Required: Completed

Triggered when all visits are completed but the job has not been marked
as complete by the user.

| Visit Status | Condition | Alert |
|--------------|-----------|-------|
| All visits Completed | Job NOT marked complete | Action Required (Completed) |
| Last visit Completed | Other visits Scheduled/In Progress, last is done | Action Required (Completed) |

This prompts the user to either:
- Mark the job as complete
- Schedule additional visits

Alert + Invoice Status
----------------------

Alerts persist regardless of invoice status:

| Alert Type | Invoice Status | Final Status |
|------------|----------------|--------------|
| Action Required | No invoice | Action Required |
| Action Required | Unpaid | Action Required |
| Action Required | Paid | Action Required |

**Rationale**: The action required state indicates work-related issues that
must be resolved before considering the job's billing status.

Alert Priority
--------------

When multiple conditions apply:

1. **Overdue** takes highest priority - immediate attention needed
2. **Completed (needs confirmation)** - work done but needs user action

Alert Resolution
----------------

| Alert | Resolution Action |
|-------|-------------------|
| Overdue | Start the visit, reschedule, or cancel |
| Completed | Mark job as complete or schedule more visits |

Once resolved, the job returns to its normal computed status based on
visit and invoice state.
