# FS-1111 — Web Spike: AI investigation system over ClickUp / tickets / GCP logs / Sentry / Amplitude / Stripe / source code

Research for an AI system that investigates issues and bugs by correlating ClickUp tasks, support tickets, GCP Cloud Logging, Sentry, Amplitude, Stripe, and the backend/mobile/web source code. The feature needs a buy-vs-build verdict, a reference architecture that keeps connectors pluggable (sources onboarded one at a time — Amplitude access does not exist yet), a per-source integration survey with access prerequisites for phase ordering, and a framework + internal-storage choice for a .NET shop.

> Research date: 2026-06-06. AI-SRE is a fast-moving space — vendor capability claims are directional, not benchmarked. Sources older than ~1 year are flagged inline.

## Questions

1. **Buy vs build** — what existing AI incident-investigation / "AI SRE" products and OSS frameworks cover this, and where do they fall short for our source mix?
2. **Reference architecture** — agentic tool-calling vs ingest-and-index vs hybrid; where MCP fits; how to keep connectors pluggable for one-at-a-time onboarding.
3. **Per-source integration surface** — best path (API / MCP), read-only auth, rate limits, and access prerequisites per source, so phases can be ordered by availability.
4. **Incremental rollout** — minimal useful slice and source ordering.
5. **Framework + runtime** — Claude Agent SDK vs Microsoft Agent Framework vs LangGraph vs OpenAI Agents SDK vs thin custom loop; .NET-native vs sidecar.
6. **Internal storage** — what to persist (runs, tool-call traces, findings, embeddings) and where (Postgres+pgvector / Mongo / BigQuery).
7. *(speed & safety sub-questions)* — what makes investigations slow; PII redaction before the LLM.

## Sources

**Vendor / product (buy-vs-build):**
- [Resolve AI — AI SRE](https://resolve.ai/product/ai-sre) — agentic AI SRE; MCP/API/Skills integration; AWS/K8s/GitHub/Slack-centric.
- [Traversal](https://www.traversal.com/) — enterprise causal-ML AI SRE; BYOC; opaque sources/pricing.
- [Cleric](https://cleric.ai/) — autonomous AI SRE; Datadog/Grafana/Slack/PagerDuty/Linear.
- [Cleric — What is an AI SRE](https://cleric.ai/blog/what-is-an-ai-sre) — parallel-hypothesis investigation pattern *(Dec 2024 — stale-risk, corroborated by newer sources)*.
- [Datadog Bits AI SRE](https://www.datadoghq.com/product/ai/bits-ai-sre/) + [deeper-reasoning blog](https://www.datadoghq.com/blog/bits-ai-sre-deeper-reasoning/) — Datadog-data-only SRE agent.
- [incident.io AI SRE](https://incident.io/ai-sre) — multi-agent investigation in incident channels.
- [ZenML LLMOps: incident.io case study](https://www.zenml.io/llmops-database/ai-powered-incident-response-system-with-multi-agent-investigation) — production lessons: parallel searchers, vector-search demotion, progressive disclosure.
- [PagerDuty AI ecosystem](https://www.pagerduty.com/newsroom/pagerduty-expands-ai-ecosystem-to-supercharge-ai-agents/) — Advance SRE Agent (March 2026).
- [Sentry Seer / Autofix docs](https://docs.sentry.io/product/ai-in-sentry/seer/autofix/) + [GA blog](https://blog.sentry.io/seer-sentrys-ai-debugger-is-generally-available/) — Sentry-native AI debugger, $40/active contributor/mo.
- [Parity (YC S24)](https://www.ycombinator.com/launches/Lbr-parity-the-world-s-first-ai-sre) — K8s-only AI SRE.
- [RunLLM → Herald](https://runllm.com/) — rebranded; support-bot, not investigator.
- [HolmesGPT (CNCF Sandbox)](https://github.com/HolmesGPT/holmesgpt) + [community toolsets](https://github.com/robusta-dev/holmesgpt-community-toolsets) — OSS agentic SRE, 60+ YAML-extensible toolsets.
- [Keep (keephq)](https://github.com/keephq/keep) — OSS AIOps/alert-correlation platform, 70+ providers.

**Architecture / patterns:**
- [MCP architecture](https://modelcontextprotocol.io/docs/learn/architecture) + [introduction](https://modelcontextprotocol.io/introduction) — official client-per-server topology (protocol 2025-06-18).
- [Anthropic — multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) (Jun 2025) — parallelization economics.
- [Anthropic — effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) (Sep 2025) — just-in-time context, context rot.
- [Anthropic — building effective agents](https://www.anthropic.com/research/building-effective-agents) *(late 2024 — older but still Anthropic's canonical guidance)* — thin-loop-over-framework advice.
- ["Is Agentic RAG worth it?" (arXiv, Jan 2026)](https://arxiv.org/pdf/2601.07711) — agentic vs RAG token/latency trade-offs.
- [CData — enterprise MCP architecture patterns](https://www.cdata.com/blog/enterprise-mcp-architecture-patterns-for-data-integration) — MCP-per-source pros/cons *(third-party opinion)*.
- [Microsoft Presidio](https://microsoft.github.io/presidio/) — structured + NER redaction, allow/deny lists.
- [LiteLLM PII masking guardrails](https://docs.litellm.ai/docs/proxy/guardrails/pii_masking_v2) — gateway-level redaction.
- [UptimeRobot — AI agent monitoring best practices](https://uptimerobot.com/knowledge-hub/monitoring/ai-agent-monitoring-best-practices-tools-and-metrics/) — staged-rollout playbooks.

**Per-source integration:**
- [Sentry MCP](https://github.com/getsentry/sentry-mcp) ([hosted](https://mcp.sentry.dev/)) · [API permissions](https://docs.sentry.io/api/permissions/) · [auth tokens](https://docs.sentry.io/account/auth-tokens/) · [rate limits](https://docs.sentry.io/api/ratelimits/)
- [GCP Logging entries.list](https://docs.cloud.google.com/logging/docs/reference/v2/rest/v2/entries/list) · [Logging quotas](https://docs.cloud.google.com/logging/quotas)
- [ClickUp MCP](https://developer.clickup.com/docs/connect-an-ai-assistant-to-clickups-mcp-server) · [authentication](https://developer.clickup.com/docs/authentication) · [rate limits](https://developer.clickup.com/docs/rate-limits)
- [Stripe MCP](https://docs.stripe.com/mcp) · [Agent Toolkit](https://github.com/stripe/agent-toolkit) · [restricted keys](https://docs.stripe.com/keys/restricted-api-keys) · [rate limits](https://docs.stripe.com/rate-limits)
- [Amplitude APIs](https://amplitude.com/docs/apis) · [Export API](https://amplitude.com/docs/apis/analytics/export) · [Dashboard REST](https://amplitude.com/docs/apis/analytics/dashboard-rest) · [keys & tokens](https://amplitude.com/docs/apis/keys-and-tokens)
- [GitHub MCP server](https://github.com/github/github-mcp-server) · [fine-grained PAT permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)
- [Zendesk MCP (marketplace)](https://www.zendesk.com/marketplace/apps/support/1191848/mcp-server/) · [Intercom MCP](https://developers.intercom.com/docs/guides/mcp)

**Framework / storage:**
- [Claude Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)
- [Microsoft Agent Framework 1.0 GA](https://devblogs.microsoft.com/agent-framework/microsoft-agent-framework-version-1-0/) (Apr 3, 2026) · [overview](https://learn.microsoft.com/en-us/agent-framework/overview/)
- [Microsoft.Extensions.AI](https://learn.microsoft.com/en-us/dotnet/ai/microsoft-extensions-ai) · [AI/Vector extensions GA](https://devblogs.microsoft.com/dotnet/ai-vector-data-dotnet-extensions-ga/)
- [LangGraph overview](https://docs.langchain.com/oss/python/langgraph/overview) · [repo](https://github.com/langchain-ai/langgraph)
- [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/)
- [OTel GenAI agent spans](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/) · [GenAI conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) *(experimental status)*
- [LangChain — agent observability](https://www.langchain.com/articles/agent-observability) · [Braintrust — tracing tool calls](https://www.braintrust.dev/articles/agent-observability-tracing-tool-calls-memory)
- [pgvector vs MongoDB Atlas (Zilliz)](https://zilliz.com/comparison/pgvector-vs-mongodb-atlas) · [MongoDB vs Postgres webinar](https://www.mongodb.com/resources/solutions/use-cases/webinar-ai-database-comparison-mongodb-vs-postgresql-and-pgvector)

## Findings

### Q1 — Buy vs build: no existing product covers our source mix

**The market is K8s/observability-ops-centric. No surveyed product natively integrates ClickUp, Amplitude, or Stripe.** GCP Cloud Logging and Sentry appear as first-class sources only in the OSS frameworks. The "correlate billing + product analytics + tasks + errors + code" thesis is genuinely underserved → leans **build (on OSS)**.

| Product | Sources vs our set | Customizability | Self-host | Pricing | Gap for us | Source |
|---|---|---|---|---|---|---|
| Resolve AI | AWS, K8s, GitHub, Slack via MCP/API/Skills | custom agents, MCP | not stated (SaaS) | not public | none of our sources listed; AWS-leaning | [resolve.ai](https://resolve.ai/product/ai-sre) |
| Traversal | enterprise observability; specifics not public | not documented | BYOC | enterprise sales | overkill; opaque | [traversal.com](https://www.traversal.com/) |
| Cleric | Datadog, Grafana, Slack, PagerDuty, Linear | integrations "source-available and extensible" | SaaS | not public | obs-tool-centric; none of our sources | [cleric.ai](https://cleric.ai/) |
| Datadog Bits AI SRE | Datadog-only world (incl. source code) | Action Catalog; locked to DD | no | DD add-on | requires all data in Datadog | [datadoghq.com](https://www.datadoghq.com/product/ai/bits-ai-sre/) |
| incident.io AI SRE | GitHub PRs, Slack, Grafana, Datadog, CloudWatch, Jira | integration-config level | "closed-source SaaS, no self-hosted option" *(secondary source — verify)* | ~$31–45/user/mo + AI via sales | Slack-first; none of our sources | [incident.io](https://incident.io/ai-sre) |
| PagerDuty SRE Agent | PD ecosystem, 30+ AI partners | playbooks, partner directory | no | PD add-on | needs PD as hub | [pagerduty.com](https://www.pagerduty.com/newsroom/pagerduty-expands-ai-ecosystem-to-supercharge-ai-agents/) |
| Sentry Seer/Autofix | Sentry data + linked GitHub repos | automation caps; reads agent rule files | no; GitHub-cloud only | **$40/active contributor/mo** | Sentry-only context; not a correlator | [docs.sentry.io](https://docs.sentry.io/product/ai-in-sentry/seer/autofix/) |
| Parity | Kubernetes (AWS/GCP), Datadog, PD | runbooks | no | not public | K8s-only | [YC launch](https://www.ycombinator.com/launches/Lbr-parity-the-world-s-first-ai-sre) |
| RunLLM → Herald | Slack/Discord/Zendesk | connectors | not documented | custom | rebranded; support-bot, not investigator | [runllm.com](https://runllm.com/) |
| **HolmesGPT** (OSS, CNCF Sandbox) | 60+ toolsets incl. **GCP, Sentry, MongoDB, PostgreSQL, GitHub** | **YAML custom toolsets** | **yes**, Apache 2.0 | free (LLM costs) | no ClickUp/Amplitude/Stripe toolsets (build as YAML); no investigation-storage UI | [github.com/HolmesGPT](https://github.com/HolmesGPT/holmesgpt) |
| **Keep** (OSS) | 70+ providers incl. **BigQuery, MongoDB, PostgreSQL** + LLM backends | custom providers + YAML workflows | **yes**, incl. air-gapped | free OSS (+cloud) | alert-correlation engine, not narrative RCA agent | [github.com/keephq](https://github.com/keephq/keep) |

Load-bearing details:

> "No Kubernetes required: Works with any infrastructure — VMs, bare metal, cloud services, or containers."
> — [HolmesGPT README](https://github.com/HolmesGPT/holmesgpt) (release 0.31.1, May 28 2026 — current)

HolmesGPT custom toolsets are YAML files loaded with `-t /path/to/custom/toolset`; the [community toolsets repo](https://github.com/robusta-dev/holmesgpt-community-toolsets) is MIT.

Sentry Seer is a cheap partial buy for the slice we already have data for: it uses "Issue details: Error messages, stack traces, and event metadata", traces, structured logs (beta), and "Relevant code from linked GitHub repositories" ([docs](https://docs.sentry.io/product/ai-in-sentry/seer/autofix/)), at "$40 per active contributor per month, with unlimited use" ([Sentry blog](https://blog.sentry.io/seer-sentrys-ai-debugger-is-generally-available/)). Limits: "the cloud version of GitHub is the only SCM supported by Seer."

**Verdict: build the correlator (no product exists for our mix), consider HolmesGPT as the agentic core or at least the toolset-pattern reference, and optionally adopt Sentry Seer as an interim partial buy for the error→code slice.**

### Q2 — Reference architecture: hybrid, live tool-calling first, vector search demoted

The strongest production signal (incident.io) is **hybrid, leaning deterministic + live tool-calls**, with vector search deliberately demoted:

> "vector similarity often triggered on fuzzy or irrelevant matches rather than the precise information needed" … "Their current approach uses a combination of text similarity, LLM summarization, and selective use of embeddings." … "simpler technology often performs better and causes less pain in the long term"
> — [ZenML LLMOps: incident.io](https://www.zenml.io/llmops-database/ai-powered-incident-response-system-with-multi-agent-investigation)

Cleric's agent calls live systems directly — "It uses the same tools engineers use (querying Datadog metrics, checking Kubernetes logs, examining traces) but can investigate dozens of paths simultaneously" ([Cleric blog](https://cleric.ai/blog/what-is-an-ai-sre), *Dec 2024 — stale-risk*). The cost of agentic freshness is quantified in the research literature:

> "the Agentic setting requires on average 2.7× more input tokens and 1.7× more output tokens than Enhanced RAG … tool calling is inherently multistep and can stack latency when sequential."
> — ["Is Agentic RAG worth it?"](https://arxiv.org/pdf/2601.07711) (arXiv, Jan 2026)

**Conclusion: live tool-calling for telemetry** (logs, errors, billing, analytics — huge, changing, must be fresh; never mass-ingest), **pre-index only the slow-changing reusable corpus** (source code, past investigation runs, resolved-ticket summaries), preferring LLM text summaries + conventional Postgres indexing over heavy vector stores.

#### MCP as the connector layer — per-source servers are the established pattern

> "MCP follows a client-server architecture where an MCP host... establishes connections to one or more MCP servers. The MCP host accomplishes this by creating one MCP client for each MCP server. Each MCP client maintains a dedicated connection with its corresponding MCP server."
> — [MCP architecture docs](https://modelcontextprotocol.io/docs/learn/architecture) (protocol 2025-06-18; Sentry is the docs' own canonical remote-server example)

MCP primitives map cleanly: **Tools** = "search Sentry issues" / "query Cloud Logging"; **Resources** = schemas/context; **Prompts** = per-source templates. The `notifications/tools/list_changed` primitive lets a source appear at runtime — exactly the "Amplitude arrives later" requirement. Trade-off (third-party opinion): "Distributed MCP increases operational complexity. You must coordinate security and identity flows across servers, monitor multiple endpoints" ([CData](https://www.cdata.com/blog/enterprise-mcp-architecture-patterns-for-data-integration)).

**Pragmatic middle path for a small .NET team: in-process connectors behind an MCP-shaped tool contract** (same Tool schema), externalizing a connector to a standalone MCP server only when it needs independent deploy/ownership. Several sources (Sentry, Stripe, GitHub) already ship **official hosted MCP servers**, so those can be consumed remotely with zero connector code.

#### Speed: parallelism is the lever

> "Early agents... executed sequential searches, which was painfully slow." … "These changes cut research time by up to 90% for complex queries" — via "spinning up 3-5 subagents in parallel" and subagents "using 3+ tools in parallel."
> — [Anthropic multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) (Jun 2025)

incident.io runs "multiple 'searcher checks' … in parallel across different data sources" and lands "actionable reports in Slack within 1-2 minutes" ([ZenML](https://www.zenml.io/llmops-database/ai-powered-incident-response-system-with-multi-agent-investigation)). Just-in-time context avoids context rot:

> "agents built with the 'just in time' approach maintain lightweight identifiers (file paths, stored queries, web links, etc.) and use these references to dynamically load data into context at runtime using tools"
> — [Anthropic context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) (Sep 2025)

Cost caveat: "multi-agent systems use about 15× more tokens than chats... require tasks where the value of the task is high enough" ([Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system)) — acceptable here: investigations are high-value, low-frequency.

#### PII safety: allowlists first, Presidio second

For mostly-structured telemetry (Stripe/Amplitude/Cloud Logging), **per-source field allowlists are the primary control**; Presidio (structured + NER, allow/deny lists — [docs](https://microsoft.github.io/presidio/)) is the second net on free-text fields (log messages, ticket bodies, Sentry breadcrumbs), placed at the connector boundary so every source is covered uniformly, plus an output sweep before persisting findings. Presidio's own limitation: "there is no guarantee it will find all sensitive information; consequently, additional systems and protections should be employed." We already run Presidio in Tofu.AI.Backend — reuse the pattern (and its fail-closed behavior).

### Q3 — Per-source integration surface and access prerequisites

| Source | Best path | Auth (read-only) | Rate limits | Access prerequisites | Ready today? |
|--------|-----------|------------------|-------------|----------------------|--------------|
| **Sentry** | Official hosted MCP ([mcp.sentry.dev](https://mcp.sentry.dev/), OAuth) or REST | user auth token: `event:read`, `project:read`, `org:read` (org tokens are CI-oriented, not customizable) | per caller+endpoint; **numbers not published** | org membership (have: `getpaid-inc`) | **Yes** |
| **GCP Cloud Logging** | REST `entries.list` (recent); **BigQuery sink for heavy history** | SA scope `logging.read` + role `logging.viewer` | **"60 per minute, per Google Cloud project"** ([quotas](https://docs.cloud.google.com/logging/quotas)) | GCP IAM (have) | **Yes** |
| **ClickUp** | REST + personal token (simplest); official MCP is **OAuth-only** | personal API token (never expires) | **"100 requests per minute per token"** (Free/Unlimited/Business) ([rate limits](https://developer.clickup.com/docs/rate-limits)) | workspace membership; OAuth app for MCP | **Yes** (REST) |
| **Stripe** | Official hosted MCP ([mcp.stripe.com](https://docs.stripe.com/mcp)) / Agent Toolkit | Restricted API Key `rk_*` — "you select which Stripe resources the key can access"; tool availability enforced by key perms | live 100 ops/s; **Search 20 read/s** | dashboard access to mint RAK | **Yes** |
| **Amplitude** | REST (Dashboard / Export / User Activity); **no official MCP found** | Basic auth, project **API Key + Secret Key** | User Activity/Search: "up to 10 concurrent requests", "360 queries per hour"; Export: 4 GB, 365 d/query | **Blocked**: project-admin access for Secret Key + per-plan API entitlement is **ambiguous in public docs — verify with Amplitude** | **No** |
| **GitHub (source code)** | Official hosted MCP (`api.githubcopilot.com/mcp/`) with `--read-only` | fine-grained PAT: Contents/Issues/PRs = Read, Metadata mandatory | standard secondary limits | PAT scoped to specific repos | **Yes** |
| **Support tickets** | Zendesk: marketplace MCP + REST (no new Basic auth after 2026-03-31). Intercom: official MCP (`mcp.intercom.com/mcp`) | OAuth/API token (Zendesk); bearer + read-conversations (Intercom) | vendor-standard | **identify which system we use** | path ready; blocked on system ID |

Notable per-source quotes:

> "Number of `entries.list` requests: 60 per minute, per Google Cloud project." — [GCP Logging quotas](https://docs.cloud.google.com/logging/quotas). Also: `entries.list` "isn't intended for high-volume retrieval of log entries" — the documented heavy-history path is a **log sink to BigQuery**.

> "you cannot authenticate using your own API keys or Auth access tokens. They only support OAuth for authentication." — [ClickUp MCP docs](https://developer.clickup.com/docs/connect-an-ai-assistant-to-clickups-mcp-server) (hence REST + personal token first).

> "Stripe recommends always using RAKs instead of unrestricted secret keys, especially when giving a key to an AI agent." — [Stripe restricted keys](https://docs.stripe.com/keys/restricted-api-keys)

GitHub security caveat: even read-only PATs are an injection vector — scope the FGPAT to only the needed repos and combine with the MCP server's `--read-only` flag.

### Q4 — Incremental rollout: errors + logs + code first

Practitioner ordering puts **code changes + errors/observability + past incidents** first — incident.io's initial sources were "GitHub or GitLab code changes, historical incidents on the platform, Slack workspace messages, and connections to observability platforms" ([ZenML](https://www.zenml.io/llmops-database/ai-powered-incident-response-system-with-multi-agent-investigation)); the headline early capability is "correlating recent code changes with error spikes". Rollout posture:

> "Teams typically start the agent with read-only access in production, gradually expanding its capabilities based on its track record."
> — [Cleric](https://cleric.ai/blog/what-is-an-ai-sre) *(Dec 2024 — stale-risk, directionally corroborated)*

**Phasing for us** (by payoff × access):
1. **Phase 1 — GCP Cloud Logging + Sentry + GitHub source** (all ready today): enables the proven "code change ↔ error spike" investigation.
2. **Phase 2 — ClickUp + support tickets**: human context, prior incidents (ClickUp ready via REST; tickets blocked on identifying the system).
3. **Phase 3 — Stripe** (ready when billing incidents matter; integration is trivial via hosted MCP + RAK).
4. **Phase 4 — Amplitude** (blocked on access; lower-signal for incident RCA anyway).

### Q5 — Framework: .NET is now first-class; thin loop is credible

| Framework | Runtime | MCP | Multi-agent / parallel | Durable runs | Maturity (mid-2026) | Source |
|---|---|---|---|---|---|---|
| Claude Agent SDK | Python / TypeScript | native (incl. in-process custom tools) | subagents, isolated contexts | sessions: resume/fork (JSONL); hosted "Managed Agents" | GA, powers Claude Code | [docs](https://code.claude.com/docs/en/agent-sdk/overview) |
| **Microsoft Agent Framework** | **.NET (`Microsoft.Agents.AI`)** + Python | native at 1.0 | sequential/concurrent/handoff/group-chat/Magentic-One | **checkpointing + hydration, pause/resume** | **1.0 GA 2026-04-03**; successor to SK + AutoGen | [GA blog](https://devblogs.microsoft.com/agent-framework/microsoft-agent-framework-version-1-0/) |
| LangGraph | Python / JS | via LangChain | fan-out, supervisor graphs | first-class durable execution, pluggable checkpointers, time-travel | mature, v1.x active | [docs](https://docs.langchain.com/oss/python/langgraph/overview) |
| OpenAI Agents SDK | Python-first | built-in | handoffs, agents-as-tools | sessions; no graph checkpointing | GA; tracing feeds OpenAI dashboard (lock-in vector) | [docs](https://openai.github.io/openai-agents-python/) |
| Thin custom loop (Anthropic API from .NET) | any | DIY | DIY | DIY | explicitly endorsed for narrow cases | [Anthropic](https://www.anthropic.com/research/building-effective-agents) |

Load-bearing quotes:

> "Microsoft Agent Framework 1.0 GA was released on April 3, 2026, unifying Semantic Kernel and AutoGen into one .NET + Python SDK with MCP and A2A." … "Checkpointing and hydration ensure long-running processes survive interruptions."
> — [MS Agent Framework 1.0 GA](https://devblogs.microsoft.com/agent-framework/microsoft-agent-framework-version-1-0/)

> "Developers should start by using LLM APIs directly: many patterns can be implemented in a few lines of code. Frameworks often create extra layers of abstraction that can obscure the underlying prompts and responses, making them harder to debug."
> — [Anthropic, Building Effective Agents](https://www.anthropic.com/research/building-effective-agents) *(late 2024 — still Anthropic's canonical guidance)*

**The sidecar question:** a Python/TS sidecar is an accepted pattern but **no longer required** for a .NET shop — Agent Framework (`dotnet add package Microsoft.Agents.AI`) gives orchestration + MCP + checkpointing natively, building on GA [Microsoft.Extensions.AI](https://learn.microsoft.com/en-us/dotnet/ai/microsoft-extensions-ai). A sidecar is justified mainly if we specifically want the Claude Agent SDK runtime or LangGraph's time-travel tooling (no .NET ports). Caveat on Claude Agent SDK fit: its built-in tools are filesystem/Claude-Code-shaped (Read/Bash/Grep) — for a pure API-tool-calling investigator we'd use MCP servers + custom tools anyway, weakening its advantage.

### Q6 — Internal storage: co-locate runs + findings + embeddings; Postgres + pgvector fits

What teams persist: the full run trace — "the user input, the agent's planning step, every LLM call, every tool call, intermediate results, and the final answer, along with timing, token counts, and costs at each step" ([LangChain](https://www.langchain.com/articles/agent-observability)); for tools, "which tools were selected, what arguments were passed, what results were returned, and how long each call took" ([Braintrust](https://www.braintrust.dev/articles/agent-observability-tracing-tool-calls-memory)).

Schema vocabulary: **OpenTelemetry GenAI semantic conventions** (`invoke_agent`, `execute_tool {gen_ai.tool.name}`, `invoke_workflow` spans) — but note they are in **Development (experimental) status — attribute names may churn** ([OTel](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/)).

Store comparison (investigation-findings volume is small — nowhere near vector-DB scale):

| Option | Fit | Caveat | Source |
|---|---|---|---|
| **Postgres + pgvector** | "ideal for teams that want to keep embeddings, metadata, and application data in one system" — runs, findings, embeddings co-located; we already run Postgres | limits only "beyond 50-100M vectors" — irrelevant at our scale | [Zilliz comparison](https://zilliz.com/comparison/pgvector-vs-mongodb-atlas) |
| MongoDB Atlas Vector Search | "query vectors and documents together"; fine if runs live as documents in Mongo | second-best unless data is document-shaped | [MongoDB](https://www.mongodb.com/resources/solutions/use-cases/webinar-ai-database-comparison-mongodb-vs-postgresql-and-pgvector) |
| BigQuery | offline analytics over exported traces (cost/latency rollups) | not a transactional run-store; no low-latency recall | (positioning, per docs above) |

Combined with incident.io's vector-demotion lesson (Q2): store findings as **LLM text summaries with conventional Postgres indexing first**, add pgvector similarity over past findings as a later enhancement, not a foundation.

## Implications for the design

- **Build, don't buy — but don't build from scratch.** No product covers ClickUp+Amplitude+Stripe+GCP+Sentry+code (anchor: the buy-vs-build decision). Evaluate **HolmesGPT** as the agentic core or as the toolset-pattern reference; **Sentry Seer ($40/contributor/mo)** is a cheap interim partial buy for the error→code slice while we build.
- **Architecture = hybrid:** live tool-calling against source APIs for telemetry; pre-index only source code + past investigations as LLM summaries in Postgres; vector search is an enhancement, not a foundation (anchor: ingest-vs-live and storage design).
- **Connector layer = MCP-shaped tool contract, in-process first.** One connector per source behind a common Tool-schema interface; consume the **official hosted MCP servers** (Sentry, Stripe, GitHub) where they exist; graduate bespoke connectors (ClickUp, Amplitude, GCP logs) to standalone MCP servers only when ownership demands it (anchor: pluggability / "highly customizable" requirement and phase boundaries).
- **Runtime: .NET service is viable as the primary path** via Microsoft Agent Framework 1.0 (GA, MCP, checkpointing) — consistent with workspace conventions; the credible alternative is a thin custom loop on the Anthropic API in .NET (Anthropic-endorsed for narrow tool sets). A Python/TS sidecar is only needed if we choose Claude Agent SDK or LangGraph (anchor: service runtime decision for `/plan write`).
- **Speed budget ~1–2 min per investigation**, achieved by 3–5 parallel per-source sub-agents + parallel hypothesis testing + just-in-time context (pass IDs/handles, not raw payload dumps). Accept the ~15× token cost — investigations are high-value, low-frequency (anchor: orchestration design + cost model).
- **Phase ordering by access × payoff:** P1 GCP logs + Sentry + GitHub ("code change ↔ error spike"), P2 ClickUp + tickets, P3 Stripe, P4 Amplitude. Rate-limit design constraint: GCP `entries.list` is hard-capped at 60 req/min/project — connector must budget queries and lean on the BigQuery sink for history (anchor: the step-by-step plan structure in `overview.md`).
- **PII: per-source field allowlists at the connector boundary + Presidio (structured + NER) on free-text + output sweep before persisting** — reuse the Tofu.AI.Backend Presidio integration and its fail-closed posture (anchor: data-safety design).
- **Internal storage: Postgres**, one schema co-locating investigation runs, tool-call traces (modeled on OTel GenAI span vocabulary — experimental, expect churn), findings, and later pgvector embeddings; BigQuery only for offline trace analytics (anchor: internal-storage decision).
- **Read-only everything in v1**: Sentry read scopes, GCP `logging.viewer`, Stripe restricted key (read), GitHub fine-grained read-only PAT scoped to our repos + `--read-only` MCP flag, ClickUp personal token. Expand autonomy only on track record (anchor: auth/secret provisioning steps in the plan).

## Open questions / follow-ups

- [ ] **Which support-ticket system do we use?** (Zendesk and Intercom both have ready MCP paths; can't pick a connector until identified.)
- [ ] **Amplitude access:** request project-admin access (Secret Key) and **verify with Amplitude support which API endpoints our plan tier includes** — per-plan API gating is ambiguous in public docs.
- [ ] **Is a BigQuery log sink already configured** for prod (`inv-project`)? Determines whether heavy historical log search is free to build or needs sink setup first. (Check `Local.Docs/Backend/Storage/` inventory before re-deriving.)
- [ ] **HolmesGPT hands-on spike**: does its YAML toolset model + LLM support fit, or does the .NET-native path win on maintainability? (1-day prototype recommended before `/plan write` commits the runtime.)
- [ ] **Trigger model for investigations**: alert-driven (log-based alerts → webhook), Slack-command, or manual UI? Affects API surface — not researched here; product decision.
- [ ] **incident.io self-host claim** came from a secondary source (Better Stack) — verify with vendor only if buy re-enters consideration.
- [ ] Sentry publishes no numeric API rate limits — validate empirically during Phase 1 if the investigator fans out heavily.

# FS-1111 — Web Spike: error fingerprinting, tag taxonomy, cross-run linking

Follow-up research (2026-06-06): how to recognize that an error found in GCP logs is the same underlying error as one covered by a previous investigation, and how to organize investigations beyond exact citations.

## Questions

1. How do production systems decide two errors are "the same" (fingerprinting/grouping)?
2. Controlled vs free-form tags for incident/investigation knowledge bases; LLM auto-tagging patterns.
3. How do tools model "related to / duplicate of" links between records?

## Sources

- [Sentry — event grouping](https://docs.sentry.io/concepts/data-management/event-grouping/) · [fingerprint rules](https://docs.sentry.io/concepts/data-management/event-grouping/fingerprint-rules/) · [merging issues](https://docs.sentry.io/concepts/data-management/event-grouping/merging-issues/) · [dev: grouping internals](https://develop.sentry.dev/backend/application-domains/grouping/)
- [Datadog — error grouping](https://docs.datadoghq.com/error_tracking/error_grouping/)
- [Drain3 — log template miner](https://github.com/logpai/Drain3/blob/master/README.md)
- [incident.io — custom fields](https://docs.incident.io/articles/3494530207-customizing-your-incident-creation-form-using-custom-fields)
- [FireHydrant — incident classification](https://firehydrant.com/blog/incident-classification/)
- [Grab Engineering — LLM-powered data classification](https://engineering.grab.com/llm-powered-data-classification) *(2024-07-15 — >1y old; the controlled-vocab + schema-output + human-review pattern remains standard)*

## Findings

### Fingerprinting — stable signal + aggressive message normalization

Sentry precedence: > "All versions consider the `fingerprint` first, the `stack trace` next, then the `exception`, and then finally the `message`." Per frame, only normalized `module`/`function`/`context-line` contribute; message fallback strips parameters. Sentry additionally layers embedding similarity: > "Sentry generates an embedding of the error's message and in-app stack frames … and merges the new error into an existing issue if a similar issue is found within the configured threshold." ([docs](https://docs.sentry.io/concepts/data-management/event-grouping/), [dev docs](https://develop.sentry.dev/backend/application-domains/grouping/))

Datadog has the most copyable recipe: grouping uses `service` + `error.type` + `error.message` + `error.stack`, evaluates "the topmost stack frame", and > "ignores numbers, punctuation, and anything that is between quotes or parentheses: only word-like tokens are used" — plus removal of "versions, ids, dates". Errors are never grouped across services. ([Datadog](https://docs.datadoghq.com/error_tracking/error_grouping/))

Drain3 (LogPAI) is the mature tool for raw log lines without stack traces: fixed-depth parse tree, masking of variable parts, and an inference mode where > "input is matched against previously trained clusters only." Caveat: Python — for a .NET service it's a sidecar or an offline pass; the Datadog-style regex normalization is the in-process approximation. ([Drain3](https://github.com/logpai/Drain3/blob/master/README.md))

### Tags — controlled vocabulary for queryable axes, LLM-classified at write time

incident.io custom fields: select-lists (single/multi) backed by controlled sources for anything filtered/reported on; free text reserved for narrative. FireHydrant: plan for taxonomy revision during postmortems. Grab's LLM pattern: classify at write time against a defined tag library with schema-enforced output and human verification that relaxes as accuracy rises ("users on average change less than one tag").

### Cross-linking — typed, reversible, separate from auto-grouping

Sentry merging lesson: > "We don't infer any new grouping rules from how you merge issues." Manual merges are stored as fingerprint sets and are reversible (Unmerge). The cross-tool norm (Jira links, incident.io related incidents) is a typed self-referential link table `(from_id, to_id, relation_kind, created_by, created_at)`.

## Implications for the design

- Fingerprint per finding, priority order: (1) Sentry issue ref present → reuse it verbatim as the fingerprint (Sentry already did the grouping work); (2) exception/stack info → hash(error_type + top in-app frame); (3) raw log line → hash of the Datadog-style normalized message (strip numbers, ids, quoted/parenthesized substrings, dates, versions). Store algorithm version alongside the hash; re-fingerprint on recipe change.
- Cross-run dedup = exact fingerprint lookup at recall time; embedding similarity is a Phase 2+ *proposal* mechanism (suggest, never auto-merge) — consistent with the earlier vector-search-demotion finding.
- Tags (already decided, Option A): rows + FK-enforced taxonomy; add per-row `source (llm|human)` so human corrections are distinguishable — Grab's verification loop in miniature.
- Links: `investigation_links` typed edge table, agent- or human-created, with rationale; never mutates fingerprints (Sentry lesson).

# FS-1111 — Web Spike: storing/deploying the agent knowledge file tree

Follow-up research (2026-06-07) for [`agent-context-pull.md`](./agent-context-pull.md): the `.tofu-ai/` knowledge tree is the agent's read interface — where should it live and how should it deploy in the container phase? Options surveyed: separate git repo (commit-per-run), GCS sync / FUSE mount, K8s persistent volume, rebuild-from-Postgres at startup (current baseline). Plus prior art: how shipping agent products store file-based memory.

## Questions

1. What are the credible options for storing & deploying a small markdown knowledge tree (~50–200 files) consumed by a containerized agent, and their trade-offs (write path, change history, multi-writer, disaster recovery, PII exposure, ops complexity)?
2. How do shipping agent products store file-based memory — and is git-backed memory an established pattern?

## Sources

**Storage options:**
- [Cloud Storage FUSE overview](https://docs.cloud.google.com/storage/docs/cloud-storage-fuse/overview) — POSIX gaps, latency, concurrent-writer behavior.
- [GKE Cloud Storage FUSE CSI perf tuning](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cloud-storage-fuse-csi-driver-perf) — read-only/write-to-new recommendation, out-of-band caveats.
- [gcloud storage rsync](https://docs.cloud.google.com/sdk/gcloud/reference/storage/rsync) — sync semantics, `--delete-unmatched-destination-objects`.
- [GCS object versioning](https://docs.cloud.google.com/storage/docs/object-versioning) — noncurrent versions, cost, no diffable history.
- [Lobsters: databases that use git as a backend](https://lobste.rs/s/mb2hi2/databases_use_git_as_backend) — *(forum discussion; used for the practitioner-consensus trade-off list, no better single source found)*.

**Prior art (agent file memory):**
- [Anthropic memory tool docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) — client-side `/memories` directory, pluggable backend.
- [Claude Code memory docs](https://code.claude.com/docs/en/memory) — auto memory: `MEMORY.md` index + topic files, load caps.
- [Anthropic: effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) — git as checkpoint/recovery, state in the working directory.
- [Cline Memory Bank](https://docs.cline.bot/prompting/cline-memory-bank) — `memory-bank/` markdown committed in the project repo.

## Findings

### Q1 — Storage options: everything external solves a problem we don't have

The decisive frame: the tree is a **projection** — Postgres already owns durability and history. External storage options therefore add ops + exposure without adding safety:

| Option | Write path per run | Change history | Multi-writer | PII exposure | Ops | Verdict (at ~200 small files) | Source |
|---|---|---|---|---|---|---|---|
| **Rebuild-from-PG at startup** (baseline) | local file write | DB rows (it IS the record) | single in-process writer | stays internal | none new | ✅ **wins** — projection pattern, zero new infra | (design) |
| **Separate git repo** (commit+push per run) | commit+push (~1–3 s, deploy key) | `git log` — genuinely diffable | ⚠️ "merging operates over text structure… you can't be sure what the outcome of a 3-way merge will be"; "which repository is master?" | ⚠️ findings (account ids, error details) pushed to an external host | deploy keys, push-failure handling | viable as a **mirror**, never as primary | [Lobsters](https://lobste.rs/s/mb2hi2/databases_use_git_as_backend) |
| **GCS bucket + rsync at startup** | upload per run | versioning = noncurrent objects, "charged at the same rate… when it was live", not diffable | last-writer-wins | bucket IAM (internal) | bucket + creds + `--delete-unmatched…` foot-gun | redundant next to PG rebuild | [rsync](https://docs.cloud.google.com/sdk/gcloud/reference/storage/rsync), [versioning](https://docs.cloud.google.com/storage/docs/object-versioning) |
| **GCS FUSE mount (CSI)** | transparent | none | "first mount to complete the write… is saved. Other mounts… encounter a syscall.ESTALE error" | internal | CSI driver + tuning | ❌ ruled out — "much higher latency than a local file system", "throughput may be reduced when reading or writing one small file at a time"; grep-heavy small-file reads are its worst case | [FUSE overview](https://docs.cloud.google.com/storage/docs/cloud-storage-fuse/overview) |
| **K8s PersistentVolume** | local write | none | RWO pins one pod | internal | one more stateful object | unnecessary — persisting a rebuildable cache | (positioning) |

Git's own qualifier fits us only partially: appropriate when "all (or almost all) the data you're storing is plain text" and "it's a non critical service that can withstand some downtime" ([Lobsters](https://lobste.rs/s/mb2hi2/databases_use_git_as_backend)) — content-wise yes, but as *primary* it would create a second source of truth next to PG.

### Q2 — Prior art: agent products keep memory as plain local files; git is the harness's checkpoint, not the store

| Product | Where memory lives | Structure | Git? | Source |
|---|---|---|---|---|
| Anthropic memory tool | client-side `/memories` dir — "you control where and how the data is stored through your own infrastructure"; backend pluggable ("file-based, database, cloud storage…") | files + dirs, agent-managed | no | [docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) |
| Claude Code auto memory | machine-local `~/.claude/projects/<project>/memory/` | **`MEMORY.md` index ("first 200 lines or 25KB" loaded) + topic files read on demand** | no | [docs](https://code.claude.com/docs/en/memory) |
| Cline Memory Bank | `memory-bank/` markdown **in the project repo**, shared via git | 6 core files (brief/context/progress…) | yes — committed | [docs](https://docs.cline.bot/prompting/cline-memory-bank) |
| Anthropic long-running harness | "agent memory persists in the working directory itself" | progress file + feature JSON; git commits as checkpoints — "use git to revert bad code changes and recover working states" | yes — **recovery**, not storage | [engineering post](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) |

Two patterns directly validate the FS-1111 design: **(a)** Claude Code's own auto memory is exactly INDEX-loaded + topic-files-on-demand — including a hard cap on the index (25 KB / 200 lines), worth copying for `.tofu-ai/INDEX.md`; **(b)** where git appears, it is either a *shared-via-repo* convenience (Cline) or a *recovery/checkpoint* mechanism (Anthropic harness) — no surveyed product uses a remote git repo as the memory backend.

## Implications for the design

- **Container phase storage = rebuild-from-PG into local ephemeral disk (emptyDir).** No PV, no bucket, no FUSE — every external option adds ops/PII surface to solve durability PG already provides (anchor: `agent-context-pull.md` deployment story; already consistent with it).
- **GCS FUSE is explicitly disqualified** for this workload shape (grep over many small files) — record it so it doesn't resurface (anchor: container-phase infra choices).
- **Git mirror = optional Phase 2+, push-after-persist, single writer, failure-tolerant** — gives diffable history and human browsing; must be a *derived mirror*, never primary; **PII gate before pushing to an external host** (findings carry account ids / error details). Self-hosted or private repo + the no-PII-in-findings rule are prerequisites (anchor: the deferred git-repo idea in `agent-context-pull.md`).
- **Cap `INDEX.md` like Claude Code caps `MEMORY.md`** (~25 KB): when exceeded, INDEX keeps recent + stats and the agent greps `runs/` for the tail (anchor: `.tofu-ai/` tree spec).
- **Single-writer invariant must be stated**: `MaxConcurrentRuns=1` makes tree writes safe today; if replicas ever scale, tree generation must stay single-writer (git/GCS multi-writer hazards above) (anchor: container-phase scaling notes).

## Open questions / follow-ups

- [ ] If the git mirror is ever adopted: self-hosted vs private GitHub (where may investigation content legally live?), retention policy.
- [ ] Letta's filesystem docs were unreachable (404) — prior-art table is missing one data point; revisit only if their model becomes relevant.
