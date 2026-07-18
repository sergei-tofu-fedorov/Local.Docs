# mongo — per-operation command shapes

**Contents:** exact `mongosh` command shape and report fields for each read / inspection op — `conn`, `dbs`, `collections`, `indexes`, `find`, `count`, `aggregate`, `explain`, `currentOp`, `sample`, `profile`, `status`, `stats`, `shell`, `run`, `script`. Read the row for the op you're running before running it. The **write** op (the mutation gate) lives in `SKILL.md`, not here — it stays always-loaded.

Substitute `<URI>` with `mongodb://localhost:27017` (local) or `"$env:MONGODB_URI"` (prod, kept literal and unexpanded in the transcript). Always pin the database with `db.getSiblingDB("<db>")`.

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
