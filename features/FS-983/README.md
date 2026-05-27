# FS-983 — MongoDB index cleanup

## Goal

Reduce MongoDB CPU load by (a) dropping indexes that the query planner never selects, and (b) applying Mongo-level optimizations that current usage is paying for without benefit. No functional behaviour change for callers.

## Methodology

For each collection in `invoicesDB`:

1. `db.<coll>.getIndexes()` — what's actually defined in production.
2. `db.<coll>.aggregate([{ $indexStats: {} }])` — `accesses.ops` since last node restart.
3. Cross-reference with code: the two `MongoDbContext.cs` files in this workspace.

Each row in the recommendation tables below carries one of these statuses:

- **KEEP** — heavily used by application traffic, no action.
- **KEEP (support)** — application traffic is zero, but the index is kept on purpose because internal support / admin tooling queries against it (typically lookups that bypass `AccountId`, e.g. by raw domain `Id`). Not in `$indexStats` because support traffic is rare and may fall outside the audit window. Do not drop.
- **DROP (code)** — registered in `MongoDbContext.cs` and unused; remove the registration in code, follow up to drop in prod.
- **DROP (Mongo only)** — present in production but **not** in either repo. Likely manually created or left by a previous code version. Drop in prod.
- **ADOPT** — present in prod and used, but not in code; should be added to `MongoDbContext.cs` so a re-create includes it.

## Recommendations

### Highest-value drops (largest unused indexes)

These are the biggest reclaim opportunities. Each removes immediate working-set + write-amplification cost.

| Collection | Index | Key | Ops/72h | Status | Notes |
|---|---|---|---:|---|---|
| `invoices` | `Status_1_DueDateStatus_1_DueDays_1_CreatedTime_1_ModifiedTime_1_IsDeleted_1` | `{Status:1, DueDateStatus:1, DueDays:1, CreatedTime:1, ModifiedTime:1, IsDeleted:1}` | **73** | KEEP — but ADOPT into code | Not registered, but **is** used: `Tofu.Invoices.Backend` `InvoicesRepository.GetAllPastDueDate` (`src/Tofu.Invoices.Infrastructure/Repositories/InvoicesRepository.cs:125-156`) filters on exactly these six fields. 73 ops / 72 h ≈ 1/hour — consistent with the hourly due-date-notification worker. Dropping it would force that scan over the full `invoices` collection. Add the registration to `MongoDbContext.cs` so it survives a recreate. (Originally classified DROP because absence-from-code was misread as absence-of-use.) |
| `invoices` | `CreatedTime_1` | `{CreatedTime:1}` | **0** | DROP (Mongo only) | Not in code. Pure stale leftover. |
| `invoices` | `Id_1` | `{Id:1}` | **0** | KEEP (support) | Not in code, and zero application traffic — but kept for **support tooling**. Application queries go through `_id` (= `UniqueId = AccountId\|Id`); support staff look up invoices by raw domain `Id` without knowing the `AccountId`, which `_id` cannot serve. Don't drop. |
| `accountData` | `Id_1` | `{Id:1}` | **0** | DROP (Mongo only) | Code only registers `{AccountId:1}`. |
| `accounts` | `SchemaVersion_1_CreatedTime_1` | `{SchemaVersion:1, CreatedTime:1}` | **0** | DROP (code) | `MongoDbContext.cs:189-194`. Only `_id_` is hit (4.2 M ops). |
| `contents` | `ix_contents.accountid.links.entityid` | `{AccountId:1, "Links.EntityId":1}` | **0** | KEEP | `MongoDbContext.cs:350-356`. Backs `ContentsRepository.FindByEntityId` (`Invoices.Implementation.MongoDb/Repositories/ContentsRepository.cs:78-92`), called from `ContentsService.GetContentByEntityId` / `UnlinkAllContent` — i.e. `GET /contents?entityId=...`, invoice/estimate HTML rendering (attachments lookup in `HtmlBuilder.cs:102, 150`), and cascade-unlink on invoice/estimate delete (`V1/InvoicesController.cs:178`, `EstimatesController.cs:140`). Zero ops over the 72 h window reflects audit-window noise, not absence of use. The query's `$or` still has a legacy `EntityId == entityId` branch — only the `Links.EntityId` branch is index-covered, so dropping would force a COLLSCAN on the indexed half too. Do not drop. |
| `subscriptions` | `OriginalTransactionId_1` | `{OriginalTransactionId:1}` | **0** | DROP (code) | `MongoDbContext.cs:560-563`. Confirm IAP-restore path doesn't depend on it before dropping. |
| `operationsQueue` | `StartedAt_1_ExecuteAt_1` | `{StartedAt:1, ExecuteAt:1}` | **0** | DROP (code) | `MongoDbContext.cs:495-497, 511`. The 3-key `FinishedAt_StartedAt_ExecuteAt` (80 k ops) handles the actual queue scan. **Note:** the *separate* `StartedAt_1` (TTL=30 d) on this collection also reports 0 ops — that's expected because `$indexStats.ops` does not count TTL-monitor work. The TTL index drives `operationsQueue` eviction; do **not** drop it on the basis of 0 ops. |

### Indexes in production but not in code (manually created)

These survive any code-driven `Configure()` run but were never registered in either `MongoDbContext.cs`. Each row needs a decision: **adopt into code** (so they're recreated on a fresh deploy / DR) or **drop in prod**.

| Collection | Index | Key | Ops/72h | Recommendation |
|---|---|---|---:|---|
| `invoices` | `AccountId_1` | `{AccountId:1}` | **848 k** | **ADOPT** — heavily used. Add registration to `Tofu.Invoices.Backend` `MongoDbContext.cs`. |
| `estimates` | `AccountId_1` | `{AccountId:1}` | **443 k** | **ADOPT** — same pattern, heavily used; not registered. |
| `userAttributes` | `UserIp_1_AccountId_1_CreatedAt_1` | `{UserIp:1, AccountId:1, CreatedAt:1}` | 79 k | **ADOPT** — used (likely rate-limit / abuse signals). Find the call site, add registration in `MongoDbContext.cs`. |

### Indexes in code but NOT in prod

None. The earlier-listed `logos.{AccountId:1}` discrepancy was resolved as a `[BsonId]` illusion: `Logo.AccountId` is `[BsonId]` (`Invoices.Core/Models/Logo.cs:7-8`), so the registration in `MongoDbContext.cs:407-409` resolves to `{_id: 1}` — which is the auto-created `_id_` index. Mongo accepts `CreateOneAsync` silently and changes nothing. The 1.31 M `_id_` ops on `logos` *are* the LogosRepository traffic. Recommended cleanup: delete the dead block (`MongoDbContext.cs:403-412`) including the misleading `LogInformation("Creating index for collection logos")`. The same observation applies to `BusinessProfile.AccountId` — `[BsonId]` — though there's no registration to remove for that collection.

### COLLSCAN audit

Findings from a full code-level walk of every `*Repository.cs` cross-referenced against live indexes, validated with `db.<coll>.find(...).explain("executionStats")` against production, and a 15-minute level-1 profiler run on shard-00-02 (primary) with `planSummary: /COLLSCAN/` filter. The profiler captured **0 application COLLSCAN ops** in its window — the issues below are intermittent and were caught by `explain`, not by the profiler.

| # | Repository.method | Collection | Filter / sort | Plan | Cost | Action |
|---|---|---|---|---|---|---|
| 1 | `AuthenticatedPaymentTypesRepository.GetAuthenticatedPaymentTypes` | `authenticatedPaymentTypes` (661 k) | empty filter + `sort(CreatedTime)` + Skip/Limit | **COLLSCAN** | 4.04 s, 661 571 docs scanned per call | Add `{CreatedTime:1}` index, **or** replace offset/limit with cursor-based pagination keyed on `_id`. Endpoint is admin/listing — call frequency low but cost per call is high. |
| 2 | `AuthenticatedPaymentTypesRepository.GetNotUpdatedAuthenticatedPaymentTypes` | `authenticatedPaymentTypes` (661 k) | `{PaymentByCardEnabled, ModifiedTime<2hAgo, Items != null}` + `sort(ModifiedTime)` | IXSCAN `{ModifiedTime:1}` but examines most of the collection | 4.85 s, 207 911 keys + docs examined per call | Add compound `{PaymentByCardEnabled:1, ModifiedTime:1}` so equality on `PaymentByCardEnabled` narrows the scan before `ModifiedTime` ordering. |
| 3 | `LogosRepository.GetNotResized` | `logos` (407 k) | `{HasBeenResized: $exists:false}` + `sort(AccountId)` | **COLLSCAN** | 2.67 s, 407 333 docs scanned, **0 returned** | Migration is complete — every doc has `HasBeenResized` populated, so the worker is now a 2.7 s no-op. Either drop the worker or accept the wasted scan if it's infrequent. Don't add a partial index for a query that returns nothing. |
| 4 | `AttributesRepository.GetFeature` | `features` (38) | `{CompanyId}` | COLLSCAN | 0 ms | Negligible; ignore. |

Cleared (false alarms — investigated and dismissed):
- `LogosRepository.*` by `AccountId` — `[BsonId]` illusion. Confirmed `EXPRESS_IXSCAN _id_`, 0 ms.
- `BusinessProfileRepository.FindByAccountId` / `Upsert` by `AccountId` — `[BsonId]` illusion.
- `userAttributes.GetAttributes` `$or` — both branches index-covered (`AccountId_1` + compound `UserIp_1_AccountId_1_CreatedAt_1`).
- All other repositories: queries by `_id`/`UniqueId` (always indexed) or by indexed fields.

### Indexes to drop manually in production

Code changes alone don't drop existing indexes — they only stop the index from being recreated on a fresh `Configure()`. Each row below requires a separate `db.<coll>.dropIndex("<name>")` against `invoicesDB` after the corresponding code change is deployed.

| Collection | Index name | Key | Why drop | Source of removal |
|---|---|---|---|---|
| `accounts` | `SchemaVersion_1_CreatedTime_1` | `{SchemaVersion:1, CreatedTime:1}` | 0 ops over 3.87 d window. Code registration removed. | code edit (BFF `MongoDbContext.cs` `accounts` block) |
| `subscriptions` | `OriginalTransactionId_1` | `{OriginalTransactionId:1}` | 0 ops. Code registration removed. **Confirm IAP-restore path doesn't read by `OriginalTransactionId` before dropping.** | code edit (BFF `MongoDbContext.cs` `subscriptions` block) |
| `operationsQueue` | `StartedAt_1_ExecuteAt_1` | `{StartedAt:1, ExecuteAt:1}` | 0 ops. The 3-key `FinishedAt_1_StartedAt_1_ExecuteAt_1` (108 k ops) handles the actual queue scan. Code registration removed. | code edit (BFF `MongoDbContext.cs` `operationsQueue` block) |
| `invoices` | `CreatedTime_1` | `{CreatedTime:1}` | 0 ops. Manually-created leftover, never registered in code. | DROP (Mongo only) — was never in code, just delete from prod |
| `accountData` | `Id_1` | `{Id:1}` | 0 ops. Manually-created leftover. Code only registers `{AccountId:1}`. | DROP (Mongo only) — never in code |

Pre-flight checks before dropping any of these:

1. Re-run `$indexStats` over a 7–14 d window and confirm `accesses.ops == 0` for the index. Counters reset on node restart, so use the longest cluster-uptime node available (the [audit script](../../Investigation/investigations/mongo/scripts/index_audit.js) snapshots all three).
2. **Do not drop** any of the following — they were considered and explicitly kept:
   - `invoices.Id_1` — KEEP (support tooling)
   - `contents.ix_contents.accountid.links.entityid` — KEEP (used by `ContentsRepository.FindByEntityId`)
   - `operationsQueue.StartedAt_1` (TTL=30 d) — its 0 ops reading is from `$indexStats` not counting TTL-monitor work; the index drives TTL eviction
   - `masterUser.ix_masterusers_v5.owned_accounts.account_id` — UNIQUE constraint enforcer
3. Drop one at a time. After each drop, smoke-check the relevant flow (subscription-restore for `OriginalTransactionId_1`, queue scan for `StartedAt_1_ExecuteAt_1`, etc.) and confirm no slow-query regression in Atlas Profiler.
4. Drop syntax:
   ```
   db.getSiblingDB("invoicesDB").<coll>.dropIndex("<index-name>")
   ```

The [stale collections list](../../Investigation/investigations/mongo/audit-2026-05-05.md#drop-candidates) (`payments`, `disputes`, `refunds`, `users`, `tempcollection`, `OperationQueue`, `shortIds`) is tracked in the rerun doc, not here — those are out-of-scope for this PR but in scope for the broader cleanup ticket.
