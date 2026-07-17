# /gcp Skill - Quick Reference

Run gcloud commands against the workspace's test or prod GCP project. Read-only by default; mutating commands require user confirmation. Used directly or from the `investigate` skill. Field paths & query recipes: `.claude/skills/gcp/references/gcp-logs.md` (single source).

## Environments

| Env | Project ID | Use for | Default? |
|-----|-----------|---------|----------|
| **test** | `invoicesapp-project-test` | Dev, debugging, benchmarking, anything you'd want to break safely. | ✅ Yes |
| **prod** | `inv-project` | Incident triage, customer-impact verification. **Never benchmark prod.** | Requires `--prod` |

## Commands

| Command | Description |
|---------|-------------|
| `/gcp auth` | Show account, project, auth status |
| `/gcp project [test\|prod]` | Show or switch the gcloud-config default project |
| `/gcp logs <filter> [--prod] [--limit=N] [--freshness=Xh]` | Generic `gcloud logging read` |
| `/gcp errors [<freshness>] [--prod] [--service=<name>]` | Recent `severity>=ERROR` (default 1h) |
| `/gcp slow [<threshold>] [--prod]` | Slow LB requests above threshold (default 2s) |
| `/gcp trace <trace-id> [--prod]` | LB latency vs in-app `Elapsed` |
| `/gcp request <path-or-pattern> [--prod]` | Pull `RequestLoggingMiddleware` logs for a path |
| `/gcp aggregate <filter> <field> [--prod]` | Distinct values of `<field>` + counts |
| `/gcp run <gcloud-args>` | Raw passthrough; auto-injects `--project=<currentEnv>` |
| `/gcp write <gcloud-args> [--prod]` | Mutating command. **Always asks before running.** Prod double-confirms. |

## Safety rules

- **Default is test.** Prod requires explicit `--prod` (or `prod` env arg) on every invocation.
- **Benchmarking on prod is refused.** Per saved memory: any load test / repeated polling / latency-probe loop runs only against `invoicesapp-project-test`.
- **Mutating commands ask first.** `/gcp write` always uses `AskUserQuestion` before executing. Prod confirmations restate the project ID (`inv-project`).
- **Never re-auths silently.** Auth errors surface to the user with the suggested `gcloud auth login` command.

## Examples

```bash
# What's the env and auth status?
/gcp auth

# Recent errors in test
/gcp errors 1h

# Recent errors in prod
/gcp errors 1h --prod

# Distinct XA-App-Type values on /api/worker/* requests in test (last 30d)
/gcp aggregate 'logName="projects/invoicesapp-project-test/logs/Invoices.Api.Middleware.RequestLoggingMiddleware" jsonPayload.properties.RequestPath=~"^/api/worker/"' 'jsonPayload.properties."XA-App-Type"' --freshness=30d --limit=2000

# LB-vs-app latency for a trace in prod
/gcp trace abc123def456 --prod

# Quick request-log pull
/gcp request /api/invoices --freshness=2h

# Mutating command (will ask)
/gcp write 'pubsub topics delete some-test-topic'

# Mutating on prod (will double-confirm)
/gcp write 'run services update invoices-api --image=…' --prod
```

## How `investigate` uses `/gcp`

The `investigate` skill owns the investigation folder + write-up flow; its `inv-gcp` collector reads the same `references/gcp-logs.md`. Use `/gcp` directly for ad-hoc queries that don't need an investigation folder; use `investigate` when you want the findings persisted to `Investigations/investigations/<slug>/`.

## Filter syntax cheat sheet

```
# Severity
severity>=ERROR

# By log name (request middleware)
logName="projects/<projectId>/logs/Invoices.Api.Middleware.RequestLoggingMiddleware"

# By container (k8s)
resource.type="k8s_container" resource.labels.container_name="dev-gateway-api"

# JSON payload — substring vs equality vs regex
jsonPayload.properties.RequestPath="/api/jobs"          # exact
jsonPayload.properties.RequestPath:"/api/worker"        # substring
jsonPayload.properties.RequestPath=~"^/api/worker/"     # regex

# Hyphenated keys must be quoted
jsonPayload.properties."XA-App-Type"="tofu-fieldservice-worker"

# Combine
severity>=ERROR jsonPayload.properties.AccountId="<id>"
```

## Format shapes

```bash
--format=json                                                  # full structured
--format='value(jsonPayload.properties.X)'                     # one field per row
--format='csv[no-heading,separator="|"](field1,field2)'        # multi-field CSV
```

For aggregation, pipe `value(...)` output through `awk 'NF==0{print "(empty)"; next} {print}' | sort | uniq -c | sort -rn`. The `awk` step preserves blank rows.

## Where the skill lives

Canon: `Local.Docs/Claude/skills/gcp/` (runtime copy: `C:/Git/Work/Backend/.claude/skills/gcp/`, one-way synced).
