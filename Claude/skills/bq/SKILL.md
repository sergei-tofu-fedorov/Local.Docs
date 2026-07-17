---
name: bq
description: BigQuery toolkit for the Tofu/Invoices analytics warehouse (`inv-project`). ALWAYS invoke before composing or running ANY `bq` command or BigQuery SQL — reads, cost checks, DDL, or DTS. It carries the cost gate (metadata + `--dry_run` before every scan), the prod/test env rules, and the SA-key write gate. Use it whenever the task is "query BigQuery", "how much revenue / how many invoices / active subscriptions", "check a table's size", "run this SQL against `ai_analysis_us` / `amplitude_us` / `payments_us`", add/replace a warehouse table, or edit a scheduled query — even when the user just pastes SQL without naming BigQuery.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Purpose

`/bq` is the BigQuery **operations** toolkit: environment handling, the cost gate that guards every scan, the SA-key write gate for mutations, and the routing to the query-composition knowledge. It exists because BigQuery bills per **byte scanned** and prod mutations need a service account the interactive user doesn't have — both are easy to get wrong and expensive or destructive when you do.

**Query-composition knowledge lives in ONE place:** `Local.Docs/Backend/Storage/bigquery-agent-guide.md` (workspace-relative path — read it with the Read tool from the workspace root; it resolves identically for the canon and the synced runtime copy) — the query-first guide to the three analytics datasets. It holds the identity model (account ↔ platform user ↔ master), the partition/cluster cost rules, the per-dataset table + decode reference, the interpretation principles (grain discipline, lower bounds, source cross-checks), and a ready SQL cookbook. **Read it before composing any non-trivial analytics query** — do not re-derive schema, joins, or enum decodes from memory. That file is part of the Storage catalog (humans browse it there); `/bq` points at it rather than duplicating it.

For one-off ad-hoc queries use `/bq` directly; for a persisted investigation (folder + write-up) use the `investigate` skill, which reads the same guide.

## Environments

| Env | Project ID | Use for | Default? |
|-----|-----------|---------|----------|
| **prod** | `inv-project` | **All real analytics reads** — `ai_analysis_us`, `amplitude_us`, `payments_us` live only here. Interactive identity is **read-only** on the dataset. | ✅ Yes for reads — the data is only here. |
| **test** | `invoicesapp-project-test` | Benchmarking, repeated experiments, repro of build/DDL logic, anything you'd want to break safely. Has **stubs and gaps** (e.g. `mart_account_current_plan` is a static stub) — real numbers do not live here. | For writes/experiments only. |

### Env-selection rules

1. **Reads default to prod `inv-project`** — unlike `/gcp` (which defaults to test), the analytics data only exists in prod, and a read against test returns stub/empty results. Prod reads are safe: the interactive account is read-only there, and the cost gate below bounds every scan. State the project explicitly in every emitted command (`--project_id=inv-project` / fully-qualified `` `inv-project.dataset.table` ``).
2. **Benchmarking / repeated experiments / load probes → test only, no exceptions** (saved-memory rule). If asked to benchmark or hammer prod, refuse and explain.
3. **Never query `stg_*` tables** (saved-memory rule) — they are the stage copy; use prod `inv-project` raw analytics. No `playfair-project` access.
4. **Mutations require the write gate** (DDL, `bq rm`, `bq load`, DTS trigger/update) — see below. The interactive identity cannot mutate prod; the gate switches to the SA key.

### On Windows: run `bq query` from bash, not PowerShell

PowerShell mangles quotes in inline SQL. Compose the query in a heredoc via the **Bash** tool:

```bash
bq query --project_id=inv-project --use_legacy_sql=false --format=prettyjson <<'SQL'
SELECT ... FROM `inv-project.ai_analysis_us.src_invoices` WHERE ...
SQL
```

## The cost gate (ALWAYS, before ANY scan)

BigQuery bills on **column-bytes scanned**, not rows. `SELECT *` on a JSON-column table reads gigabytes. Every query goes through this gate before it actually runs — this is the single most important rule in the skill.

1. **Metadata is free** — `bq ls`, `bq show` cost nothing. Use them to learn the schema, partitioning, and size before touching data.
2. **`--dry_run` before every real scan** — it returns the byte estimate without billing. Emit it, read the number, and only then run the real query. Surface the estimate to the user when it's large.
   ```bash
   bq query --project_id=inv-project --use_legacy_sql=false --dry_run <<'SQL'
   SELECT ... 
   SQL
   ```
3. **Prune before you scan:**
   - **Select only needed columns** — never `SELECT *` on `src_*` / `v_events_resolved` (the JSON prop columns like `event_properties` are ~10+ GB per 90-day full scan).
   - **Filter the partition column** on partitioned tables (a missing/wrong-typed partition filter scans everything or errors). Partition columns and their types are in the guide §1.2 — e.g. `amplitude_us.src_amplitude_events` is day-partitioned on `event_time` (TIMESTAMP); `mart_subscription_periods` is the only DATE-partitioned table.
   - Clustering (e.g. `account_id`) prunes only equality/`IN` **filters**, not JOINs or GROUP BYs.
4. **When a dry-run estimate is large** (say >5 GB) or the user's question is exploratory, narrow the date range / columns and re-dry-run rather than running the fat query "to see". Cheap metadata + a tight re-scope beats a surprise bill.

Free metadata + `--dry_run` are never skipped "because it's a small table" — confirm it's small first.

## Operations

| Op | Usage | Description |
|---|---|---|
| **query** | `/bq query <sql>` | Run read SQL. Gate first: `--dry_run` → surface estimate → run. Prod by default. |
| **dryrun** | `/bq dryrun <sql>` | Just the byte estimate — no scan. Use to size a query before committing. |
| **ls** | `/bq ls [<dataset>]` | List datasets / tables (free metadata). |
| **show** | `/bq show <dataset.table>` | Schema, partitioning, clustering, row count, size (free metadata). |
| **cost** | `/bq cost <sql>` | Alias of `dryrun` with the estimate translated to GB + a note on the biggest column(s). |
| **write** | `/bq write <ddl-or-mutation>` | Mutating op (DDL, `bq rm`, `bq load`, DTS trigger/update). **Always asks first + switches to the SA key** — see the write gate. |

If no op is given, infer — a `SELECT`/`WITH` → `dryrun` then `query`; a `CREATE`/`DROP`/`ALTER`/`MERGE`/`DELETE`/`bq rm`/`bq load` → `write`; a bare `dataset.table` → `show`. When ambiguous, ask.

For **analytics query composition** (which dataset, which join, which enum decode), open the guide first (routing table in guide §2), then draft, then gate.

## Write gate (mutations)

The interactive identity `s.fedorov@tofu.com` is **read-only** on `inv-project` BigQuery — `bq rm` / DDL / DTS-update fail with Access Denied (a DTS `update` is a silent no-op, not even an error). The legitimate executor is the prod service account **`tofu-ai-backend@inv-project.iam.gserviceaccount.com`** (`bigquery.dataEditor` + `storage.objectAdmin`).

**Every mutation follows this sequence:**

1. **Confirm** with the user before doing anything — restate the env and the exact statement:
   ```
   About to MUTATE prod BigQuery (project inv-project) as the tofu-ai-backend SA:

     <the DDL / bq rm / load / DTS command>

   This changes warehouse data. Confirm to proceed?
   ```
   Use `AskUserQuestion`; never mutate on implicit approval. Benchmark-flavoured writes on prod: refuse outright, don't ask.
2. **Switch identity** to the SA (its key is at `C:\Files\SA\tofu-ai-backend (prod)\inv-project-e097726fbd27.json`; the same key is also embedded in `C:\Files\tofu-ai-api-secret.prod.json` at `Analyses.BigQuery.ServiceAccountKeyJson`):
   ```bash
   gcloud auth activate-service-account --key-file="C:/Files/SA/tofu-ai-backend (prod)/inv-project-e097726fbd27.json"
   ```
3. **Run** the mutation.
4. **Restore identity — always, even if the mutation failed:**
   ```bash
   gcloud config set account s.fedorov@tofu.com
   ```
5. **Verify it took.** DTS `update`/`trigger` and some DDL succeed silently — read the object back (`bq show`, or re-query the transfer config) to confirm the change actually landed. Report what you confirmed, not just "command exited 0".

Notes:
- This SA has **only** `bigquery` + `storage` roles — no `aiplatform.user`. Vertex/AI ops will not work under it.
- DTS scheduled-query configs in `inv-project` can be edited/triggered **only** by this SA; the interactive account's `bq update` on them silently no-ops.
- For a surgical single-table rebuild without a full warehouse run, see the external-table + `CALL build_<coll>()` recipe in saved ops notes — still goes through this gate.

## Conventions

- **Project in every emitted command** — always the explicit `--project_id=inv-project` (or test) and fully-qualified table names. Never rely on the gcloud/bq default project.
- **`--dry_run` before every scan.** No exceptions; metadata is free.
- **Reads = prod, mutations = SA-gated, benchmarks = test.** Keep the three straight.
- **Schema/join/enum knowledge lives in the guide** — when a table, decode, or cost rule changes, update `Backend/Storage/bigquery-agent-guide.md` once, not this file.
- **Sanity-check every result against guide §1.4** — grain discipline (person vs account vs master), lower bounds (backend-visible sends ~17%, PSP ~3% of payments), amounts are dirty (report medians, not SUM/AVG), and cross-check a number that matters against a second source. Name the blind spot of the source you used.
- **Never re-auth silently.** On an auth error, surface the command and stop.

## Notes

- The guide was verified live on prod 2026-07-13 and refined over six agent eval runs; its snapshot distributions (channel shares etc.) are ~90-day windows from 2026-07 — recompute for the report window.
- Freshness (guide §5): `ai_analysis_us` daily ~16:xx UTC snapshot-driven; `amplitude_us` daily 04:00 UTC, rolling 90 days only, query full days ≤ yesterday; `payments_us` daily 01:00 UTC, history since 2024-04.
- Extended-JSON enum gotcha: Mongo-sourced int enums in raw JSON arrive as `{"$numberInt":"N"}` — read via `COALESCE(JSON_VALUE(x,'$.F."$numberInt"'), JSON_VALUE(x,'$.F'))`, never bare `JSON_VALUE` (guide §1.3).
