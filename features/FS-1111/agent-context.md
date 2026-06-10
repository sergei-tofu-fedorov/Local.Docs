# FS-1111 — Agent context: the `.tofu-ai/` knowledge tree

How the agent reads back what we know. Postgres is the system of record and the API backing store, but the **agent's interface to knowledge is files, not queries** — a greppable text tree in `WorkspaceRoot/.tofu-ai/` that the agent reads with the `Read`/`Grep`/`Glob` tools it already has (zero new tools). The DB stays authoritative; the tree is a rebuildable projection of it plus a few git-versioned source files.

For the schema, endpoints, and module layout, see [`overview.md`](./overview.md). This doc covers only the read-time context layer.

## Why files, not prompt-injected blocks

The agent pulls context on demand instead of receiving it pushed into the prompt. Per Anthropic's agentic-search guidance (code.claude.com docs + Agent SDK): an INDEX plus per-topic files beats one monolithic digest — the agent runs targeted greps instead of reading everything, and the system appendix shrinks to a few pointer lines plus two mandatory rules ("read `known-issues.md` FIRST; read `taxonomy.json` before tagging"). The prompt builder holds no repository dependencies and runs no recall queries.

```
.tofu-ai/
  INDEX.md          ← one line per run: date | id | status | tags | fingerprints | 1-line summary
  known-issues.md   ← active human verdicts, return-early instruction inline — read FIRST
  taxonomy.json     ← closed tag vocabulary
  runs/
    2026-06-06_b88ad28f_tap2pay-500s.md   ← per-run: findings, citations, fingerprints, limitations
```

- **Greppable naming carries recall:** `YYYY-MM-DD_<id8>_<slug>.md`; fingerprints appear verbatim in the files, so "seen before?" = `grep -rl "sentry:<id>" .tofu-ai/runs/` → one targeted `Read`.
- **Consistent headings** (`## Findings`, `## Root cause`) so section-targeted grep works.
- **Incremental generation:** after each `SaveResultAsync` the writer appends one run file + one INDEX line; a full rebuild at host start repairs drift. The tree is a rebuildable projection — Postgres stays the system of record.
- **Not nested `CLAUDE.md` files** — those are for instructions (lazy-loaded when the agent enters a directory; verified in `-p` mode). Data lives in plain markdown the agent greps on demand.

## Two kinds of files: projections vs sources

Only one kind is a cache. The distinction sets where each file lives and what protects it.

| Kind | Files | Owner | Protected by | Home |
|---|---|---|---|---|
| **Projections** (machine knowledge) | `runs/*.md`, `INDEX.md` | the service | Postgres — regenerable | `.tofu-ai/` cache |
| **Sources** (human knowledge) | `taxonomy.json`, `known-issues.md` | humans, via PR | git — versioned, reviewed, diffable | Phase 1: the `Tofu.AI.Backend` repo; container phase: the knowledge repo |

Consequences baked into the design:

- **The tag vocabulary is the file, not a table.** There is no `taxonomy` table and no FK from `investigation_tags`; the job validates tags against `taxonomy.json` app-side, and git review of the vocabulary file is the second net. `investigation_tags` stays (machine output; backs the `tag=` filter).
- **Known issues are the file, not a table.** `known-issues.md` is the only copy; the agent reads it directly. There are no known-issues API endpoints — curation is the PR flow on the knowledge repo.
- **Related runs are derived, not stored.** There is no links table; "related" = same `findings.fingerprint`, computed at read time.
- **Invariant:** projections are regenerable from Postgres; sources are protected by git; **`rm -rf .tofu-ai/` is always safe.** The agent never reads the DB, and the tree never holds anything the DB (or git) can't regenerate.

## Three buckets the agent consumes

| Bucket | Examples | How it gets there |
|---|---|---|
| Knowledge from our DB → **projected to text** | `.tofu-ai/INDEX.md`, `runs/*.md` | full rebuild at host start + per-run append (container phase: git clone + reconcile) |
| Knowledge already **file-native** | `taxonomy.json`, `known-issues.md`, source checkouts, workspace `CLAUDE.md` (auto-loads in `-p`), `.claude/skills/*` | git pull / deploy artifact — nothing to recreate |
| **Live evidence** — never cached | GCP logs, Sentry, Mongo (curated MCP) | queried fresh per investigation (it's the thing being investigated) |

Credentials sidecars (`sentry-header.txt`, the optional `pg_service.conf` below) regenerate alongside bucket 1.

## Files vs DB: division of labour

Files are the agent's **primary read path**; Postgres is the **system of record + operational state**. The tree is derived and disposable — rebuilt from the DB at host start / after deploy, appended incrementally per run.

| Layer | Home | Why |
|---|---|---|
| Knowledge (findings, reports, INDEX) | files-first; `runs/` + INDEX have a durable PG copy | read-mostly, agent-facing, greppable |
| Tag vocabulary, known-issues | git-versioned source files, **no PG copy** | human-curated, reviewed via PR |
| Run lifecycle (`pending→running→…`) | PG | concurrent conditional updates; live API polling |
| Approval queue (`proposed_actions`) | PG | the double-approve guard is a conditional UPDATE — files can't compare-and-set |
| Events stream | PG | high-frequency appends + incremental polling |
| Hangfire | PG by design | Postgres never leaves the stack — "dropping the DB" buys nothing operationally |

**`INDEX.md` is capped at ~25 KB** (mirroring Claude Code's own `MEMORY.md` cap of 25 KB / 200 lines, per the storage web-spike): beyond that the INDEX keeps recent runs + stats and the agent greps `runs/` for the tail.

## History search beyond the tree (deferred)

When the digest outgrows ~200 KB, deep search moves to **read-only psql** (chosen over a REST-via-skill or a history-MCP-tool), and the INDEX becomes "recent 30 + stats":

- a dedicated read-only PG user (`SELECT` on `investigations.*` only), connection-string key `ConnectionStrings:InvestigationsAgentRead`;
- the job materializes `.tofu-ai/pg_service.conf`; the adapter sets `PGSERVICEFILE` on the spawned process env — sidesteps both claude-CLI allowlist gotchas (no `$VAR` expansion; colons in connection strings make `--allowed-tools` patterns unparseable);
- allowlist addition `Bash(psql:*)`; the agent invokes `psql service=investigations -c "<SQL>"`;
- `.tofu-ai/investigations-schema.md` (static cheat-sheet: tables + citation/fingerprint query recipes) ships alongside.

One DB object supports this: view **`investigations.agent_recall`** — run ⋈ findings ⋈ tags flattened (id, created_at, status, description, finding summaries, fingerprints, tags). It is both the projection-export query and the future psql one-liner surface.

## Container-phase deployment: git checkout + reconcile

The knowledge tree lives in a **private** git repo the service clones at startup — the same pattern as the source-repo checkouts the agent already reads. Not git-as-database: Postgres stays the system of record, git is the *distribution + history channel*, local disk is the read path.

```
startup:   clone/pull knowledge repo → local disk
           reconcile — machine-owned files (runs/, INDEX.md) regenerate from PG on drift;
                       human-owned files (known-issues.md, taxonomy.json) are SOURCES,
                       read in place — no PG copy
per run:   agent greps the local checkout; job writes run file + INDEX line,
           commits, pushes BEST-EFFORT (a failed push never fails the run — next boot reconciles)
humans:    curate known-issues.md / taxonomy.json via normal PR flow  ← the deciding advantage
```

- **Ownership split prevents merge conflicts:** the service writes only `runs/` + `INDEX.md`; humans own `known-issues.md` + `taxonomy.json`; `pull --rebase` before each run.
- **Single writer:** safe under `MaxConcurrentRuns=1`; if replicas ever scale, exactly one instance pushes (git/GCS multi-writer hazards are why — see storage web-spike).
- **PII:** findings reach a git host — a private/self-hosted repo is required, plus the no-PII-in-findings prompt rule.
- **Phase 1 (local dev) needs no repo** — plain rebuild-from-PG into `.tofu-ai/`.

The storage web-spike disqualified the alternatives (GCS rsync, GCS FUSE, K8s PV): every external store adds ops + PII surface to solve durability Postgres already provides. The container-phase store is **rebuild-from-PG into local ephemeral disk (emptyDir)**, with the git repo as the distribution + human-curation channel.

## Efficiency notes (verified against code.claude.com docs)

- **Root `CLAUDE.md` in cwd auto-loads in `-p` mode** — the dev workspace's `CLAUDE.md` already enters every run's context (useful repo maps + some noise). Container phase: give the service-owned workspace a purpose-built `CLAUDE.md` carrying the static investigation rules (rides the cached system-prompt layer; shrinks the appendix to per-run bits).
- **Caching reality:** a per-run-varying `--append-system-prompt` costs exactly one cache miss on the first turn; within-run turns cache automatically. Cross-run caching is moot (sporadic runs vs the 5-min TTL).
- **Model/effort per run is the biggest wall-clock lever:** Sonnet ≈ 1.5–2× Opus throughput, Haiku ≈ 2–3×; lookup-shaped asks don't need Opus. `ClaudeCliOptions.Model` exists — consider exposing `model` on the POST request or routing by ask shape; `--effort low` exists for latency-sensitive runs.
- **Turn discipline:** the appendix nudges "run independent lookups in parallel within one turn"; push log filtering into LQL (`--limit`, `--format=json(...)`) — Bash output beyond ~100 KB is truncated anyway.
- **MCP context:** every server in `--mcp-config` loads schemas regardless of `--allowed-tools` (a permission filter, not a context filter); tool-search deferral (default on Sonnet/Opus 4+) cuts ~85%. The current surface is deliberately tiny (2 Mongo tools; Sentry via curl) — keep it that way.

## Risk: pull vs push for known-issues

Pushing `known-issues.md` into the prompt would *guarantee* the agent saw it; pulling risks it skipping the check. Mitigation: tiny files, a hard "read FIRST" rule in the appendix, and the `known-issues.md`-before-anything ordering enforced by prompt wording. If the agent demonstrably skips the check, `known-issues.md` content gets re-promoted into the appendix — it is the one block small and valuable enough to push.
