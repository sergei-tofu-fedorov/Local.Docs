---
name: mongo
description: MongoDB toolkit (local dev / prod Atlas). ALWAYS invoke before running mongosh. Local default; prod needs --prod + MONGODB_URI; never benchmark prod.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Purpose

`/mongo` is the MongoDB toolkit for this workspace. It centralises:

- Connection / env handling so callers don't have to re-derive the URI on every command.
- The common investigation patterns the team uses (collection inventory, index audit, current ops, load attribution, slow-query review).
- The safety rules: which cluster is the default, when to switch to prod, when to refuse a write.

For investigations (folder + write-up workflow) use the `investigate` skill; `/mongo` is for one-off queries. Counterpart to `/gcp` (which handles GCP / log queries).

## Environments

This workspace has two MongoDB environments. **Always know which one you're hitting before you run a command.**

| Env | URI source | Use for | Default? |
|-----|-----------|---------|----------|
| **local** | `mongodb://localhost:27017` (no auth) — from `docker-compose up mongo` | Dev, schema poking, repro scripts, anything you'd want to break safely. | ✅ Yes — every `/mongo` op defaults here. |
| **prod** | `$env:MONGODB_URI` — Atlas cluster `invoicescluster.in0ig.gcp.mongodb.net` (database `invoicesDB`) | Incident triage, load attribution, real-data inspection. **Never benchmark against prod.** | No — requires explicit `--prod` flag on every invocation. |

There is no shared remote `test` cluster: staging/production `appsettings` connection strings are TODO placeholders, and functional tests spin up Testcontainers. "Remote" effectively means "prod Atlas."

### Env-selection rules

1. **Default is local.** If the user does not specify, use `mongodb://localhost:27017`. Never silently fall through to whichever URI happens to be in the shell's env vars — that drifts and produces queries against the wrong cluster.
2. **Prod requires `--prod` (or `prod` in the env arg).** When `--prod` is passed, read `$env:MONGODB_URI`. If it is unset, **stop and tell the user to set it for the current session** — do not guess, do not look in `appsettings.Production.json` (the TODO placeholders there are not the real URI).
3. **Never print the prod URI in command output or transcripts.** It contains credentials. Show `mongodb+srv://…@invoicescluster.in0ig.gcp.mongodb.net/…` (host-only redaction) when you need to refer to it. The actual command run should use `"$env:MONGODB_URI"` literally so the secret is not interpolated into the visible transcript.
4. **Benchmarking is local-only.** No load tests, repeated polling loops, or latency probes against prod. Same rule as `/gcp` (which forbids prod benchmarking). If asked, refuse and redirect to local.
5. **Mutating commands against prod require user confirmation.** See "Write gate" below. Mutating commands against local run without confirmation.

### Session-scoped prod URI (recommended setup)

Rather than running `$env:MONGODB_URI = "..."` by hand each PowerShell session, install the `claude-mongo` wrapper in `$PROFILE`. It prompts for the URI at session start (masked input via `-AsSecureString`), launches `claude` with the env var set in its own process, and the env var dies with the wrapper when `claude` exits. Lifecycle: set at session start, gone at session end, never written to disk.

```powershell
# In $PROFILE — open via `notepad $PROFILE` (create the file if it doesn't exist)
function claude-mongo {
    $secure = Read-Host "MONGODB_URI (prod Atlas)" -AsSecureString
    $env:MONGODB_URI = [System.Net.NetworkCredential]::new('', $secure).Password
    try   { claude @args }
    finally { Remove-Item Env:\MONGODB_URI -ErrorAction SilentlyContinue }
}
```

**Usage:** `claude-mongo` (instead of plain `claude`) for any session where you'll hit `--prod`. Plain `claude` for sessions that only need local Mongo — keeps prod credentials out of process scope when they aren't needed.

If `--prod` ops fail with *"MONGODB_URI not set"*, the user forgot to launch via `claude-mongo`; surface that suggestion rather than trying to recover.

### Default database

`invoicesDB` for prod. Local typically has `invoicesDB` after running the API once. Skill assumes `invoicesDB` unless the user names another db. Always include `db.getSiblingDB("invoicesDB")` (or equivalent) in scripts so the connection's default database does not silently change the target.

### Repo ↔ collection routing

When mapping a Mongo namespace back to the source code that owns it:

| Repo | Collections it owns |
|---|---|
| `Tofu.Invoices.Backend` | `invoices`, `estimates` |
| `Invoices.Backend` (BFF) | `items`, `clients`, `accounts`, `regionalSettings`, `configurations`, `receipts`, `logos`, `accountData`, `subscriptions`, `operationsQueue`, `contents`, `entityTemplates`, `shortUrl`, `shortIds`, `masterUser`, `authenticatedPaymentTypes`, `emailStatus` |
| `Tofu.Auth.Backend` | `accountIdentifiers` (and other auth/identity collections, but these live in Postgres) |

When you find a hot query in Atlas / a slow plan / a missing index, jump straight to the owning repo for the call-site search.

### Tooling

- `mongosh` (2.x) — already installed (`mongosh --version`). All scripts in this skill are written for mongosh, not the legacy `mongo` shell.
- Investigation scripts live under `Investigation/investigations/mongo/scripts/`. Treat them as the canonical implementations — prefer running an existing script over inlining its logic.

## Operations

| Op | Usage | Description |
|---|---|---|
| **conn** | `/mongo conn [--prod]` | Show which URI would be used (redacted for prod) and whether `mongosh` can reach it. |
| **dbs** | `/mongo dbs [--prod]` | List databases + sizes. |
| **collections** | `/mongo collections [<db>] [--prod]` | Inventory of collections (count, size, indexes). Reuses `inspect_collections.js`. |
| **indexes** | `/mongo indexes <collection> [<db>] [--prod]` | List indexes on a collection. Add `--audit` to run the full `index_audit.js` over the whole db. |
| **find** | `/mongo find <collection> '<filter>' [--projection='…'] [--sort='…'] [--limit=N] [<db>] [--prod]` | Wrapper for `db.<col>.find(...)`. Default limit 20. |
| **count** | `/mongo count <collection> '<filter>' [<db>] [--prod]` | `countDocuments`. For very large collections on prod, suggest `estimatedDocumentCount` instead. |
| **aggregate** | `/mongo aggregate <collection> '<pipeline>' [<db>] [--prod] [--limit=N]` | Wrapper for `db.<col>.aggregate(...)`. Pipeline is a JSON array. |
| **explain** | `/mongo explain <collection> '<filter-or-pipeline>' [--mode=queryPlanner\|executionStats\|allPlansExecution] [<db>] [--prod]` | Run `.explain(mode)` and report `winningPlan`, `executionStats.executionTimeMillis`, `totalKeysExamined`, `totalDocsExamined`, `nReturned`. Default mode `executionStats`. |
| **currentOp** | `/mongo currentOp [--prod] [--all]` | Snapshot of currently running ops, heartbeats filtered out. Reuses `current_ops.js`. With `--all`, includes idle awaitable connections. |
| **sample** | `/mongo sample [<seconds>] [<intervalMs>] [--prod]` | Time-window load attribution. Reuses `sample_current_ops.js` + `load_attribution.js`. Default `120s @ 250ms`. **Refuses on prod without explicit `--prod`.** |
| **profile** | `/mongo profile [<db>] [--prod]` | Read `system.profile` if profiling is enabled (level > 0). Reuses `recent_profile.js`. For prod, prefer Atlas Profiler UI — note this in the report. |
| **status** | `/mongo status [--prod]` | `serverStatus` + cumulative scan counters. Reuses `server_status.js`. |
| **stats** | `/mongo stats <collection> [<db>] [--prod]` | `collStats` for a single collection. |
| **shell** | `/mongo shell [--prod]` | Print the exact `mongosh` command the user can paste into their terminal for an interactive session. Does not start the REPL itself (interactive shells don't fit a tool call). |
| **run** | `/mongo run '<js>' [<db>] [--prod]` | Execute an ad-hoc JS snippet via `mongosh --eval`. Use when no preset fits and the script is short enough to inline. |
| **script** | `/mongo script <path-to-js> [--prod]` | Execute a JS file via `mongosh --file`. Use for anything multi-line — keep the script in `Investigation/investigations/<slug>/scripts/` so it survives the session. |
| **write** | `/mongo write '<js>' [<db>] [--prod]` | Mutating command (insert, update, delete, createIndex, dropIndex, renameCollection, drop, etc.). **Always asks on prod; runs without asking on local.** |

If no operation is provided, infer from arguments — a JSON object → likely `find`, a JSON array → likely `aggregate`, an op name starting with `db.` → `run`. When ambiguous, ask.

---

## Operation: `conn`

```powershell
# local
mongosh "mongodb://localhost:27017" --quiet --eval 'db.runCommand({ ping: 1 })'

# prod (PowerShell — keep "$env:MONGODB_URI" quoted and unexpanded in the transcript)
if (-not $env:MONGODB_URI) { Write-Error "MONGODB_URI not set in this session" } else `
  { mongosh "$env:MONGODB_URI" --quiet --eval 'db.runCommand({ ping: 1 })' }
```

Report: cluster reached / ping ok / current user / current default db. **For prod, only echo the host portion of the URI back to the user — never the full string.**

## Operation: `dbs`

```js
db.adminCommand({ listDatabases: 1 })
```

Sort by size desc; report `name`, `sizeOnDisk` (MB).

## Operation: `collections`

Prefer the existing script if available; otherwise inline an equivalent. The script handles missing `collStats` permissions gracefully.

```powershell
# Existing script (preferred):
mongosh "<URI>" --quiet --file Investigation/investigations/mongo/scripts/inspect_collections.js
```

Report: collection name, doc count, data size MB, storage size MB, index list. Sort by data size desc. Flag any collection > 100 MB with **no indexes besides `_id_`** as a COLLSCAN risk (this is how `receipts` and `configurations` were caught in the 2026-05-01 audit).

## Operation: `indexes`

For a single collection:

```js
db.getSiblingDB("<db>").<collection>.getIndexes()
```

For the whole db (`--audit`): run `index_audit.js`. Reports: index name, key spec, `partialFilterExpression`, sparse/unique flags, and whether any indexes look redundant (prefix of another).

## Operation: `find`

```powershell
mongosh "<URI>" --quiet --eval @'
const r = db.getSiblingDB("<db>").<collection>
  .find(<filter>, <projection>)
  .sort(<sort>)
  .limit(<limit>)
  .toArray();
print(JSON.stringify(r, null, 2));
'@
```

Default limit **20**. If the user asks for "all", cap at 1000 and warn. For prod, refuse limits > 10,000 outright.

## Operation: `count`

```js
db.getSiblingDB("<db>").<collection>.countDocuments(<filter>)
```

For collections with > 1 M docs, suggest `estimatedDocumentCount()` (uses metadata, O(1)) when an exact count isn't needed.

## Operation: `aggregate`

```powershell
mongosh "<URI>" --quiet --eval @'
const r = db.getSiblingDB("<db>").<collection>.aggregate(<pipeline>, { allowDiskUse: true }).toArray();
print(JSON.stringify(r, null, 2));
'@
```

If the pipeline does not include `$limit`, append `{ $limit: <skill-limit> }` at the end before execution and tell the user you did so. Default skill-limit 100.

## Operation: `explain`

```js
db.getSiblingDB("<db>").<collection>.find(<filter>).explain("<mode>")
// or
db.getSiblingDB("<db>").<collection>.explain("<mode>").aggregate(<pipeline>)
```

Surface in the report:
- `winningPlan.stage` chain (IXSCAN vs COLLSCAN vs FETCH chain)
- `executionStats.executionTimeMillis`
- `totalKeysExamined` / `totalDocsExamined` / `nReturned`
- The ratio `totalDocsExamined / nReturned` — anything > 10 is a red flag.
- Whether the plan is `IXSCAN` and which index name it picked.

If `winningPlan.stage === "COLLSCAN"` against a non-trivial collection, call it out as the primary finding.

## Operation: `currentOp`

```powershell
mongosh "<URI>" --quiet --file Investigation/investigations/mongo/scripts/current_ops.js
```

Reports active ops with heartbeat/internal noise filtered out, grouped by namespace and appName, top 30 slowest listed. **Requires `clusterMonitor` or equivalent on prod** — if the user's Atlas role lacks it, `currentOp` returns only their own ops; surface this clearly.

## Operation: `sample`

```powershell
mongosh "<URI>" --quiet --eval "const DURATION_SEC=<sec>; const INTERVAL_MS=<ms>;" `
  --file Investigation/investigations/mongo/scripts/sample_current_ops.js > samples.json

mongosh --quiet --file Investigation/investigations/mongo/scripts/load_attribution.js
```

Default 120 s @ 250 ms — that produced 155 samples / 117 active op-instances during the 2026-05-01 investigation, which was enough to fingerprint the top 6 query shapes. On prod, restate the duration in the confirmation prompt and explain the load it adds (~1 lightweight `currentOp` per interval = negligible). Refuse if the user asks for a tight interval (< 100 ms) on prod.

## Operation: `profile`

```powershell
mongosh "<URI>" --quiet --file Investigation/investigations/mongo/scripts/recent_profile.js
```

If profiling is off (level 0), the script reports that and exits. On prod, the supported path is the Atlas Profiler UI (https://cloud.mongodb.com → Project → Performance Advisor → Profiler) — `system.profile` is typically not directly readable. Always cite the Atlas UI as the preferred prod path.

## Operation: `status`

```powershell
mongosh "<URI>" --quiet --file Investigation/investigations/mongo/scripts/server_status.js
```

Cumulative counters (queries, docs returned, keys scanned, docs scanned, collection scans, scanAndOrder, killed by maxTimeMS, write conflicts, connections). Use the docs-scanned / keys-scanned ratio as a coarse "are indexes working?" signal — ratios near 1.0 are healthy.

## Operation: `stats`

```js
db.getSiblingDB("<db>").runCommand({ collStats: "<collection>" })
```

Report: `count`, `size`, `storageSize`, `avgObjSize`, `nindexes`, `totalIndexSize`, index size per index.

## Operation: `shell`

Print and stop. Do not attempt to launch an interactive REPL — `mongosh` without `--eval`/`--file` blocks for stdin and will hang a tool call.

```powershell
# Local
mongosh "mongodb://localhost:27017/invoicesDB"

# Prod (paste into your terminal — DO NOT echo $env:MONGODB_URI back into chat)
mongosh "$env:MONGODB_URI"
```

## Operation: `run`

```powershell
mongosh "<URI>" --quiet --eval @'
<js>
'@
```

Keep the JS short. If it spans more than ~20 lines or you need to iterate on it, suggest moving it to `Investigation/investigations/<slug>/scripts/<name>.js` and invoking via `/mongo script` instead.

## Operation: `script`

```powershell
mongosh "<URI>" --quiet --file "<path-to-js>"
```

Resolve the path before running (`Test-Path`); refuse if it sits outside `Investigation/investigations/` or the user's CWD — the skill should not be a way to execute arbitrary files anywhere on disk.

## Operation: `write`

Any command that changes data or schema — `insertOne`, `insertMany`, `updateOne`, `updateMany`, `replaceOne`, `deleteOne`, `deleteMany`, `findOneAndUpdate`/`Replace`/`Delete`, `bulkWrite`, `createIndex`, `dropIndex`, `drop`, `renameCollection`, `createCollection`, profile-level changes, `setFeatureCompatibilityVersion`, etc.

**On local: run without asking.** Local has no real data and is reset frequently.

**On prod: always ask before running:**

```
About to run on env=prod (cluster invoicescluster, db invoicesDB):

  <the js snippet, as it would be passed to mongosh --eval>

This is a mutating command. Confirm to proceed?
```

Use `AskUserQuestion`. Do not run on implicit approval. **The confirmation must restate the cluster name and database** so the user sees what they're authorising. Single-keystroke confirms are too easy; spell out the target.

Refuse outright (no confirmation prompt) if:
- The command is a bulk delete/update with no filter or with a filter that obviously matches "all" (`{}`, `{_id: {$exists: true}}`).
- The command targets `admin`, `local`, or `config` databases.
- The command is part of a benchmarking workflow on prod.

After running: print the operation result (matchedCount, modifiedCount, insertedId, etc.) and a one-line summary. If the command produced no document-level result (silent success on schema ops), say so explicitly.

---

## Conventions

- **Env in every emitted command.** Show `mongodb://localhost:27017` for local and `"$env:MONGODB_URI"` (literal, unexpanded) for prod. Never paste the resolved prod URI into chat.
- **Always pin the database explicitly.** Use `db.getSiblingDB("invoicesDB")` rather than relying on the URI's default db — it makes the target obvious in the script.
- **Default limit on reads.** `find` defaults to 20, `aggregate` appends a `$limit: 100` if none is present. Raise consciously; note in the report when the cap was hit so partial results are read with scepticism.
- **Never re-prompt for credentials.** If `$env:MONGODB_URI` is unset on a `--prod` call, surface the exact PowerShell line the user should run (`$env:MONGODB_URI = "…"`) and stop. Do not attempt to look the secret up.
- **`mongosh` only.** No legacy `mongo` shell, no driver-specific scripts. Scripts must be JS the mongosh shell can execute directly.
- **Prefer the canonical scripts** under `Investigation/investigations/mongo/scripts/` over inlining their logic. If you need a variant, copy the script into the relevant investigation folder and edit there — keep `mongo/scripts/` as the stable reference.
- **Benchmarking on prod is refused, not asked.** Same rule as `/gcp`. The skill does not have authority to override it.
- **Write gate is per-env.** Local writes auto-run; prod writes ALWAYS confirm.
- The `/gcp` skill is the GCP counterpart — log-side evidence there, database-side evidence here; most real investigations need both. Postgres (Tofu.Auth.Backend) has no skill yet — model one on this if the patterns repeat.
