# FS-1111 — Runtime flow: broad ask ("investigate the latest Sentry alerts")

Traces one run end-to-end for a **broad, no-hints request** — the agent discovers its own targets (recent Sentry issues), triages them, investigates each, and the run yields *multiple* findings, some of which fingerprint-match prior investigations. The narrow case ("investigate issue PROD-API-1234") is the same flow minus the discovery loop.

```mermaid
sequenceDiagram
    participant U as Client (curl / future Slack bot)
    participant C as InvestigationsController
    participant DB as Postgres (investigations.*)
    participant HF as Hangfire
    participant J as RunInvestigationJob
    participant PB as InvestigationPromptBuilder
    participant A as ClaudeCliAgentAdapter
    participant CLI as claude CLI (subprocess)
    participant SRC as Sources (Sentry MCP · gcloud · repo files)

    U->>C: POST /api/investigations {description: "investigate latest sentry alerts"}
    C->>DB: insert run (status=pending)
    C->>HF: Enqueue RunInvestigationJob(runId)
    C-->>U: 202 {id}

    HF->>J: ExecuteAsync(runId)
    J->>DB: CountRunningAsync()
    %% MaxConcurrentRuns gate — if at cap, the run simply stays pending in the queue
    J->>SRC: AgentContextFilesWriter — refresh .tofu-ai/ (INDEX, runs/), copy in sources (taxonomy.json, known-issues.md)
    J->>PB: BuildAsync(run)
    PB-->>J: AgentRunRequest {task verbatim + appendix: source inventory, rules, .tofu-ai pointers, report contract}
    J->>DB: status=running (event: status_change)

    J->>A: RunAsync(request, onEvent)
    A->>CLI: spawn claude -p … --output-format stream-json (read-only --allowed-tools)

    CLI->>SRC: Read .tofu-ai/known-issues.md (mandatory FIRST) + grep INDEX.md for prior work
    CLI->>SRC: mcp__sentry__search_issues(sortBy=last_seen / new, 24h)
    %% DISCOVERY — broad ask: agent finds its own targets, no issue id was given
    SRC-->>CLI: e.g. 5 recent issues (counts, first_seen, releases)

    loop per suspicious issue (agent triages, typically top 2-3 by volume/newness)
        CLI->>SRC: grep .tofu-ai/runs/ for the issue's fingerprint   %% seen before? verify, don't rediscover
        CLI->>SRC: get_issue_details(issue) — stack trace, tags, release
        CLI->>SRC: gcloud logging read (matching RequestPath/StatusCode, around first_seen)
        CLI->>SRC: Grep/Read implicated code in workspace checkouts
        CLI-->>A: stream-json lines (tool calls, reasoning)
        A->>J: onEvent(AgentEvent)
        J->>DB: AppendEventAsync(runId, event)   %% live — bot polls GET /{id}/events?afterId=N
    end

    U->>C: GET /api/investigations/{id}/events?afterId=12
    C->>DB: GetEventsAsync()
    C-->>U: progress timeline (while run is live)

    CLI-->>A: final message with fenced JSON {findings[3], tags, limitations}
    A->>A: FencedReportParser.TryParse (1 retry on failure)
    A-->>J: AgentRunResult

    J->>J: fingerprinter.Derive(finding) per finding
    %% sentry-cited findings → fingerprint = sentry:<issue-id> verbatim; related runs are DERIVED
    %% from fingerprint equality at read time — no link rows
    J->>DB: SaveResultAsync(findings + tags + limitations + proposed actions + token stats)  %% one transaction
    J->>SRC: append .tofu-ai/runs/<date>_<id8>_<slug>.md + INDEX line  %% container phase: commit + push best-effort
    J->>DB: status=succeeded (event: status_change)

    U->>C: GET /api/investigations/{id}
    C->>DB: GetAsync()
    C-->>U: 200 {findings[3], tags, limitations, links}
```

What the diagram can't carry:

- **Triage is the agent's judgment, not code** — "latest alerts" → it decides how many issues are worth chasing within `MaxTurns`; typically one finding per root cause, several issues may collapse into one finding when they share a cause.
- **Already-investigated alerts surface two ways:** the agent's own grep over `.tofu-ai/` (known-issues first, then INDEX/runs by fingerprint) lets it *verify-not-rediscover*; and fingerprints persisted per finding make relatedness derivable at read time regardless of what the agent noticed.
- **Timeout/failure exits:** `RunTimeout` kills the subprocess → `timed_out` with partial events retained; parse failure after one retry or non-zero exit → `failed` with `error` populated. Both leave the events trail intact — never a 5xx to the caller.
- **`onEvent` ordering:** events are plain INSERTs; the identity `id` is the monotonic cursor backing the bot's incremental poll (`afterId`).
