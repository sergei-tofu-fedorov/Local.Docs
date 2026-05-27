# Stage 4: Web Frontend Changes

Summary of web frontend changes required for Stage 4 amount display updates.

## API Changes Overview

| Change | Breaking | Details |
|--------|----------|---------|
| New amount fields | No | `TotalScope`, `DisplayAmount`, `ManualStatus` added |
| CurrencyCode source | No | Now from job (not invoice) |

---

## New Fields

### API Response Fields

**Endpoint**: `GET /api/v3/jobs/paged`

```json
{
  "items": [{
    "currencyCode": "USD",
    "totalScope": 1500.00,
    "totalDue": 1200.00,
    "totalAmount": 1000.00,
    "displayAmount": 1500.00,
    "manualStatus": "none",
    "invoiceStatus": "unpaid",
    ...
  }]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `currencyCode` | `string` | Job's currency (for all amounts) |
| `totalScope` | `decimal` | Sum of job items (always available) |
| `totalDue` | `decimal?` | Invoice unpaid amount (null if no invoice) |
| `totalAmount` | `decimal?` | Invoice total amount (null if no invoice) |
| `displayAmount` | `decimal` | **Computed amount to display** |
| `manualStatus` | `enum` | `none`, `completed` |
| `invoiceStatus` | `enum` | `none`, `unpaid`, `paid` |

---

## Display Logic

**Backend computes `displayAmount`** - frontend should use it directly.

| Manual Status | Invoice State | `displayAmount` value |
|---------------|---------------|----------------------|
| Not Completed | Any (or none) | `totalScope` |
| Completed | No invoice | `totalScope` |
| Completed | Invoice unpaid | `totalDue` |
| Completed | Invoice paid | `totalAmount` |

**Key simplification:** Frontend no longer needs display logic - just use `displayAmount`.

### Currency Note

Two currency sources exist in the backend:
- `Job.CurrencyCode` - job's own currency (used for Scope Total)
- `InvoiceAmounts.CurrencyCode` - invoice currency (may differ)

The API exposes `currencyCode` from the job. If invoice has a different currency, amounts will still display correctly via `displayAmount`.

→ [Full documentation: 4.3_amount_display_rules.md](./4.3_amount_display_rules.md)

---

## Migration Checklist

- [ ] Use `displayAmount` for job amount display (replaces client-side logic)
- [ ] Use `currencyCode` for formatting (now always present, from job)
- [ ] Optionally use `totalScope` for showing job items total separately
- [ ] Optionally use `manualStatus` for completion state UI
