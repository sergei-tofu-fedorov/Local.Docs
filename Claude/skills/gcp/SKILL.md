---
name: gcp
description: gcloud toolkit (test/prod GCP). ALWAYS invoke before composing any gcloud command. Read-only default; prod needs --prod; never benchmark prod.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Purpose

`/gcp` is the gcloud **operations** toolkit: project/env handling, the common query presets, and the safety rules (default env, prod switching, write refusal).

**Field paths, log schemas, and query recipes live in ONE place:** `.claude/skills/gcp/references/gcp-logs.md`. **Read it before composing any non-trivial `gcloud logging read` filter** — it holds the LQL field reference (BFF request log, identity/client-context/request fields, LB log, tofu-ai selectors) and the per-field gotchas (auth-gated properties, 200-error envelope, hyphen quoting, the nonexistent `RequestId`). Do not re-derive or duplicate that knowledge here.

For investigations (folder + write-up workflow) use the `investigate` skill; `/gcp` is for one-off queries.

## Environments

| Env | Project ID | Use for | Default? |
|-----|-----------|---------|----------|
| **test** | `invoicesapp-project-test` | Development, debugging, log inspection, benchmarking, repro scripts. | ✅ Yes — every `/gcp` op defaults here. |
| **prod** | `inv-project` | Incident triage, customer-impact verification, real traffic patterns. **Never benchmark against prod.** | No — requires explicit `--prod`. |

Browser log explorer:
- Test: https://console.cloud.google.com/logs/query;project=invoicesapp-project-test
- Prod: https://console.cloud.google.com/logs/query;project=inv-project

### Env-selection rules

1. **Default is test.** Never silently fall through to the gcloud config's currently-set project — that drifts and hits the wrong env unnoticed.
2. **Prod requires `--prod`** (or `prod` in the env arg). Prod reads run without asking, but every emitted command must show `--project=inv-project` explicitly.
3. **Benchmarking is test-only, no exceptions** (saved-memory rule). If asked for benchmarking on `--prod`, refuse and explain.
4. **Mutating commands require user confirmation** — see the write gate below.

### Auth

gcloud auth is set up for the user's account. On `Reauthentication is needed`, surface the error with the suggested `gcloud auth login` — do NOT re-auth silently or run interactive login yourself.

## Operations

| Op | Usage | Description |
|---|---|---|
| **auth** | `/gcp auth` | Show current account, project, auth status. |
| **project** | `/gcp project [test\|prod]` | Show or switch the gcloud-config default project. |
| **logs** | `/gcp logs <filter> [--prod] [--limit=N] [--freshness=Xh] [--format=...]` | Generic `gcloud logging read`. |
| **errors** | `/gcp errors [<freshness>] [--prod] [--service=<name>]` | Recent `severity>=ERROR` (default freshness `1h`, limit 50). |
| **slow** | `/gcp slow [<threshold>] [--prod]` | Slow LB requests above threshold (default `2s`). |
| **trace** | `/gcp trace <trace-id> [--prod]` | LB latency vs in-app `Elapsed` for one trace. |
| **request** | `/gcp request <path-or-pattern> [--prod] [--limit=N] [--freshness=Xh]` | Request-middleware logs by path (substring `:` / regex `=~`). |
| **aggregate** | `/gcp aggregate <filter> <field-path> [--prod] [--limit=N] [--freshness=Xh]` | Distinct-value counts of a field. |
| **run** | `/gcp run <gcloud-args...>` | Raw passthrough; auto-injects `--project=<currentEnv>` if absent. Refuse args smuggling a different `--project`. |
| **write** | `/gcp write <gcloud-args...> [--prod]` | Mutating command — **always asks first** (see gate). |

If no operation is given, infer — a trace ID → `trace`, a path starting with `/api/` → `request`, a quoted filter → `logs`. When ambiguous, ask.

### Op notes

- **auth**: `gcloud auth list`; `gcloud config get-value project`; cheap reauth probe `gcloud auth print-identity-token --quiet 2>&1 | head -1` (output discarded). If reauth needed — print the command and stop.
- **project**: `gcloud config set project invoicesapp-project-test|inv-project`. On prod switch, warn: *"Switched to prod (`inv-project`). Read-only commands run there until switched back."*
- **logs / request / trace / aggregate**: exact command shapes, format flags (`value(...)`, `csv[no-heading,separator="|"]`), the empty-row-preserving `awk`, and the LB↔app trace join are in the reference file — use them verbatim. Bound EVERY query with `--limit` + `--freshness`; note in the report when a cap was hit (counts are then partial).
- **errors**: with `--service=<name>` add `resource.labels.container_name="<name>"` (k8s) or `resource.labels.service_name="<name>"` (Cloud Run); group by `logName`/message, surface repeating exceptions and spikes.
- **slow**: `resource.type="http_load_balancer" httpRequest.latency>"<threshold>"`, limit 20; summarize endpoints/latencies/trace ids, offer `/gcp trace` follow-ups.

## Write gate

Any mutating command (`create`, `update`, `delete`, `deploy`, `restart`, `set-iam-policy`, `pubsub publish`, `secrets versions add`, `kubectl apply`, …):

```
About to run on <env> (project <projectId>):

  gcloud <args...>

This is a mutating command. Confirm to proceed?
```

Use `AskUserQuestion`; never run on implicit approval. **On prod, restate the project ID** in the confirmation. Benchmark-flavoured writes on `--prod`: refuse outright, don't ask. After running: print output + short summary; on silent success, say so explicitly.

## Conventions

- **Env in every emitted command** — always print the actual `--project=<id>` flag.
- **Never re-auth silently.**
- **Limit + freshness, every time.** Defaults: 50 (reads) / 2000 (aggregate); freshness 1h (reads) / 30d (aggregate).
- **Field knowledge lives in the reference file** — when a filter, field path, or project rule changes, update `.claude/skills/gcp/references/gcp-logs.md` once, not this file.
