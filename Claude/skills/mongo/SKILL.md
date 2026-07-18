---
name: mongo
description: MongoDB toolkit for the Tofu/Invoices clusters (local dev / prod Atlas `invoicesDB`). ALWAYS invoke before running mongosh. Use it whenever the task is find/count/aggregate on a collection (`invoices`, `accounts`, `subscriptions`, …), an index audit, an `explain` / slow-query check, a current-ops or load-attribution snapshot, or "inspect invoicesDB". Local by default; prod needs `--prod` + `MONGODB_URI`; benchmarking prod is refused. For a persisted investigation use investigate; for warehouse analytics use bq.
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

**Exact command shape + report fields for every read / inspection op** (`conn`, `dbs`, `collections`, `indexes`, `find`, `count`, `aggregate`, `explain`, `currentOp`, `sample`, `profile`, `status`, `stats`, `shell`, `run`, `script`) live in [`references/operations.md`](references/operations.md) — **read the row for the op you're about to run before running it** (you only need that one block, not all sixteen). The `write` op is the exception: its gate is spelled out below so it's always in front of you.

---

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
