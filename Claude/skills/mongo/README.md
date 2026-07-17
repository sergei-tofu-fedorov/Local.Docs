# /mongo Skill - Quick Reference

Run MongoDB queries against the workspace's local dev instance or the prod Atlas cluster. Read-only by default; mutating commands against prod require user confirmation. Used directly or invoked from `/inv`.

## Environments

| Env | URI source | Use for | Default? |
|-----|-----------|---------|----------|
| **local** | `mongodb://localhost:27017` (no auth) | Dev, schema poking, repro scripts, anything you'd want to break safely. | ✅ Yes |
| **prod** | `$env:MONGODB_URI` (Atlas cluster `invoicescluster`, db `invoicesDB`) | Incident triage, load attribution, real-data inspection. **Never benchmark prod.** | Requires `--prod` |

No shared remote `test` cluster exists — staging/production `appsettings` are placeholder values; functional tests use Testcontainers.

## Commands

| Command | Description |
|---------|-------------|
| `/mongo conn [--prod]` | Show which URI would be used (host-only for prod) and ping it |
| `/mongo dbs [--prod]` | List databases with sizes |
| `/mongo collections [<db>] [--prod]` | Inventory: count, size, indexes per collection |
| `/mongo indexes <coll> [<db>] [--prod]` | Indexes on one collection; `--audit` for whole-db audit |
| `/mongo find <coll> '<filter>' [...] [--prod]` | Wrapper for `find()`, default limit 20 |
| `/mongo count <coll> '<filter>' [--prod]` | `countDocuments`; suggests `estimatedDocumentCount` for huge collections |
| `/mongo aggregate <coll> '<pipeline>' [--prod]` | Wrapper for `aggregate()`, auto-caps with `$limit: 100` |
| `/mongo explain <coll> '<filter>' [--mode=…] [--prod]` | `.explain()`, surfaces winning plan + scan ratios |
| `/mongo currentOp [--prod]` | Snapshot of running ops, heartbeats filtered |
| `/mongo sample [<sec>] [<intervalMs>] [--prod]` | Time-window load attribution (default 120s @ 250ms) |
| `/mongo profile [<db>] [--prod]` | Read `system.profile` if enabled; otherwise points at Atlas Profiler UI |
| `/mongo status [--prod]` | `serverStatus` cumulative counters |
| `/mongo stats <coll> [<db>] [--prod]` | `collStats` for one collection |
| `/mongo shell [--prod]` | Prints the `mongosh` command to paste into your terminal |
| `/mongo run '<js>' [<db>] [--prod]` | Ad-hoc `mongosh --eval` snippet |
| `/mongo script <path-to-js> [--prod]` | `mongosh --file` for an investigation script |
| `/mongo write '<js>' [<db>] [--prod]` | Mutating command. **Asks before running on prod.** Local runs without asking. |

## Safety rules

- **Default is local.** Prod requires explicit `--prod` on every invocation.
- **Never print the prod URI in chat.** It contains credentials. Pass `"$env:MONGODB_URI"` literally to `mongosh`; show only the host portion (`…@invoicescluster.in0ig.gcp.mongodb.net`) when referring to it.
- **Benchmarking on prod is refused.** No load tests, repeated polling loops, or sub-100ms sampling intervals against prod. Same rule as `/gcp`.
- **Mutating commands on prod ask first.** `/mongo write` uses `AskUserQuestion` and the confirmation restates the cluster + database. Local writes auto-run.
- **Refuse outright** (no prompt) for: bulk deletes/updates with empty/match-all filters, writes to `admin`/`local`/`config` databases, or benchmarking writes on prod.
- **Always pin the database.** Scripts use `db.getSiblingDB("invoicesDB")` rather than relying on the URI default.

## Session-scoped prod URI

Install the `claude-mongo` wrapper in `$PROFILE` so the prod URI is prompted-for at session start and gone when `claude` exits — never written to disk:

```powershell
function claude-mongo {
    $secure = Read-Host "MONGODB_URI (prod Atlas)" -AsSecureString
    $env:MONGODB_URI = [System.Net.NetworkCredential]::new('', $secure).Password
    try   { claude @args }
    finally { Remove-Item Env:\MONGODB_URI -ErrorAction SilentlyContinue }
}
```

Launch with `claude-mongo` for sessions that touch `--prod`; plain `claude` otherwise.

## Default database

`invoicesDB` (the only application database). The skill assumes this unless another db is named.

## Repo ↔ collection routing

When a Mongo namespace shows up in a slow plan / Atlas profiler row / log, jump straight to:

| Repo | Collections |
|---|---|
| `Tofu.Invoices.Backend` | `invoices`, `estimates` |
| `Invoices.Backend` (BFF) | `items`, `clients`, `accounts`, `regionalSettings`, `configurations`, `receipts`, `logos`, `accountData`, `subscriptions`, `operationsQueue`, `contents`, `entityTemplates`, `shortUrl`, `shortIds`, `masterUser`, `authenticatedPaymentTypes`, `emailStatus` |
| `Tofu.Auth.Backend` | `accountIdentifiers` (most auth state is in Postgres) |

## Canonical investigation scripts

Live under `Investigation/investigations/mongo/scripts/`. Treat them as the stable reference — prefer running them over inlining their logic:

| Script | Purpose | Op that calls it |
|---|---|---|
| `inspect_collections.js` | Collection inventory + index list + size | `/mongo collections` |
| `index_audit.js` | Whole-db index audit | `/mongo indexes --audit` |
| `current_ops.js` | Active ops, heartbeats filtered | `/mongo currentOp` |
| `sample_current_ops.js` | Repeated `currentOp` over a time window | `/mongo sample` |
| `load_attribution.js` | Aggregate sampled ops into op-time per fingerprint | `/mongo sample` |
| `recent_profile.js` | Read `system.profile` | `/mongo profile` |
| `server_status.js` | Cumulative scan / lock / write-conflict counters | `/mongo status` |

If you need a one-off variant, copy the script into the relevant investigation folder and edit there. Keep `mongo/scripts/` as the stable reference.

## Examples

```powershell
# Ping the local cluster
/mongo conn

# Ping prod (will surface a clear error if MONGODB_URI is unset)
/mongo conn --prod

# Collection inventory on prod (spot COLLSCAN risks)
/mongo collections --prod

# Explain a hot query on prod
/mongo explain invoices '{ AccountId: "abc123" }' --prod

# 2-minute load sample on prod
/mongo sample 120 250 --prod

# Mutating command on prod — will prompt before running
/mongo write 'db.getSiblingDB("invoicesDB").receipts.createIndex({ AccountId: 1 })' --prod

# Same on local — runs without prompting
/mongo write 'db.getSiblingDB("invoicesDB").receipts.createIndex({ AccountId: 1 })'
```

## How `/inv` uses `/mongo`

`/inv` owns the investigation folder + write-up flow. Its database-investigation operations delegate to `/mongo`:

- `/inv find <coll> …` → `/mongo find <coll> …`
- `/inv aggregate`, `/inv explain`, `/inv collections`, `/inv currentOp`, `/inv sample`, `/inv profile`, `/inv status` → identical `/mongo` ops
- `/inv` retains: `new`, `list`, `open`, `note`, `finding`, `script`, `commit`, `status`

Use `/mongo` directly for ad-hoc queries that don't need an investigation folder; use `/inv` when you want the findings persisted under `Investigation/investigations/<slug>/`.

## Counterpart skills

- `/gcp` — gcloud / logs / traces. Most real investigations need both: `/gcp` for log-side evidence, `/mongo` for database-side evidence.
- No `/pg` skill yet (Postgres in `Tofu.Auth.Backend`). Add one modelled on `/mongo` if the patterns become repeated.

## Where the skill lives

`C:/Git/Work/Backend/.claude/commands/mongo.md` (workspace-scoped, alongside `/feature`, `/plan`, `/web-spike`, `/docs`, `/inv`, `/tests`, `/review-gw`, `/gcp`).
