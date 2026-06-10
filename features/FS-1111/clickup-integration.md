# FS-1111 — ClickUp integration spike: providing access to the Investigation service via ClickUp

How to let people **trigger an investigation from inside ClickUp and get the report back there** — the ClickUp analog of the planned Slack bot. This surveys ClickUp's integration surfaces (developer Webhooks, Automation "Call webhook" actions, native AI Agents, the ClickUp MCP server, REST post-back) and recommends a shape that reuses the existing async REST contract in [`overview.md`](./overview.md).

> Research date: **2026-06-10**. ClickUp's AI-agent surface (Brain / Autopilot / Super Agents) is moving fast — capability claims here are directional. Several `help.clickup.com` pages returned **HTTP 403** to automated fetch, so a few agent/automation claims are drawn from search-result summaries rather than a directly-fetched page; those are flagged inline. The `developer.clickup.com` API facts are from directly-fetched pages.

This is a *new* angle: FS-1111's [`web-spike.md`](./web-spike.md) Spike 1 already covers **ClickUp as a read *source*** (REST + personal token; the hosted MCP is OAuth-only). This doc covers ClickUp as an **access / interface channel**.

## Questions

1. What ClickUp surfaces can trigger an external service from inside ClickUp, and which fits "run an investigation → get the report back in ClickUp"?
2. Outbound trigger mechanics — Webhooks vs Automation "Call webhook": events, payload, signature verification, delivery guarantees, plan gating.
3. Inbound post-back mechanics — REST API to post the report as a comment: endpoint, auth, markdown, rate limits.
4. Build-vs-reuse: do we build a bot at all, or can ClickUp's native AI Agents call our service?
5. Auth model — personal token vs workspace OAuth2 app.

## Sources

**ClickUp developer docs (directly fetched):**
- [Webhooks](https://developer.clickup.com/docs/webhooks) — event-type catalog, payload shape, subscription/filtering.
- [Webhook signature](https://developer.clickup.com/docs/webhooksignature) — HMAC-SHA256 `X-Signature` verification.
- [Create Webhook](https://developer.clickup.com/reference/createwebhook) — `POST …/team/{team_id}/webhook`, events array, location filters, secret.
- [Create Task Comment](https://developer.clickup.com/reference/createtaskcomment) — `POST …/task/{task_id}/comment`, body fields.
- [Comments](https://developer.clickup.com/docs/comments) — task / List / Chat-view comment endpoints.
- [Authentication](https://developer.clickup.com/docs/authentication) — personal token (`pk_`) vs OAuth2 app.
- [Rate Limits](https://developer.clickup.com/docs/rate-limits) — per-plan limits, `429`, `X-RateLimit-*` headers.
- [ClickUp's MCP Server](https://developer.clickup.com/docs/connect-an-ai-assistant-to-clickups-mcp-server) — hosted, OAuth-only, read-shaped.

**ClickUp Help / blog (via search summary unless noted — some 403 to fetch):**
- [Integrate ClickUp using Automation webhooks](https://help.clickup.com/hc/en-us/articles/35313844961943-Integrate-ClickUp-using-Automation-webhooks) — Task vs Chat webhook automations *(403 on fetch)*.
- [Create a task webhook Automation](https://help.clickup.com/hc/en-us/articles/31126817112343-Create-a-task-webhook-Automation) · [Create a Chat webhook Automation](https://help.clickup.com/hc/en-us/articles/30402042482839-Create-a-Chat-webhook-Automation).
- [Create and configure Autopilot Agents](https://help.clickup.com/hc/en-us/articles/31012020810775-Create-and-configure-Autopilot-Agents) *(403 on fetch)*.
- [How to Build an AI Agent | ClickUp blog](https://clickup.com/blog/how-to-build-an-ai-agent/) — **directly fetched**, dated Mar 12 2026.
- [MCP Tools | ClickUp blog](https://clickup.com/blog/mcp-tools/) — MCP-compatible integrations.
- [Automations: Comments as trigger (feature request)](https://feedback.clickup.com/feature-requests/p/automations-comments-as-trigger) — comment-trigger availability signal.

## Findings

### Q1 — Trigger surfaces: three real options, plus the MCP server (which is the *source* path, not the interface path)

| Surface | What it is | Triggered by | Reaches an arbitrary external URL? | Best for | Source |
|---|---|---|---|---|---|
| **Developer Webhook** (API) | A webhook you create via the REST API; ClickUp POSTs workspace events to your URL | Any subscribed event (`taskCreated`, `taskCommentPosted`, `taskStatusUpdated`, …) | **Yes** — your endpoint | Full programmatic control; event breadth | [webhooks](https://developer.clickup.com/docs/webhooks) |
| **Automation "Call webhook"** | A no-code Automation action that calls an external app | Task events; Chat "message is posted"; comment-as-trigger is newer/MVP | **Yes** — configurable URL + custom headers | No-code triggers, per-List rules, dynamic fields in URL | [automation webhooks](https://help.clickup.com/hc/en-us/articles/35313844961943-Integrate-ClickUp-using-Automation-webhooks) *(via search)* |
| **AI Agents** (Autopilot / Super / Brain) | Native AI teammates that monitor the workspace and act | "status change, chat message"; workspace events; @mention *(see Q4)* | **Via ClickUp integrations / MCP-compatible tools**, not a raw custom URL | Conversational UX; richer Phase-2 | [build-an-ai-agent](https://clickup.com/blog/how-to-build-an-ai-agent/) |
| **ClickUp MCP server** | ClickUp-hosted MCP for *external* AI assistants to read the workspace | n/a — it's a read interface, not a trigger | n/a (it's *inbound to ClickUp*) | ClickUp **as a source** (agent reads tasks) | [MCP server](https://developer.clickup.com/docs/connect-an-ai-assistant-to-clickups-mcp-server) |

The MCP server is explicitly the **read-source** direction, not a way for ClickUp to call us:

> "The Model Context Protocol (MCP) is a secure, standardized framework that lets external AI agents interact with ClickUp Workspace data—like tasks, lists, folders, and docs—using natural language." … "No, you cannot authenticate using your own API keys or Auth access tokens. We only support OAuth for authentication." … "For the time being, we haven't added any deletion tools as a safety measure."
> — [ClickUp's MCP Server](https://developer.clickup.com/docs/connect-an-ai-assistant-to-clickups-mcp-server)

So the **interface path** (ClickUp triggers us + we post back) is Webhooks / Automation webhooks + REST. The **source path** (our agent reads ClickUp) is the hosted MCP or REST — already captured in `web-spike.md` Spike 1.

### Q2 — Outbound trigger mechanics

**Developer Webhook.** Created with `POST https://api.clickup.com/api/v2/team/{team_id}/webhook` — body carries the `endpoint` URL, an `events` array (or `"*"`), and optional location filters (`space_id` / `folder_id` / `list_id` / `task_id`) ([createwebhook](https://developer.clickup.com/reference/createwebhook)). The event catalog includes the ones we'd care about:

> `taskCreated`, `taskUpdated`, … `taskStatusUpdated`, `taskAssigneeUpdated`, … `taskCommentPosted`, `taskCommentUpdated` … Use `*` as a wildcard for all events.
> — [Webhooks](https://developer.clickup.com/docs/webhooks)

Each delivery is a `POST` whose body includes `"webhook_id"`, the `"event"` name, the resource id, and `"history_items"` describing the change (plus a `history_item_id`). **Custom-field-change events are not in the documented list**, and **retry / at-least-once delivery is not documented** — treat delivery as best-effort and design the inbound handler to be idempotent on `webhook_id` + `history_item_id`.

Signature verification is clean and standard:

> "All requests sent to your webhook endpoints are signed using a hash-based message authentication code (HMAC) … The `X-Signature` value is created by hashing the request body using the provided secret and the SHA-256 algorithm. Signatures are always digested in hexadecimal format." … "the body is already a string. If you are using an HTTP client that automatically parses request bodies, make sure to stringify the object without adding white spaces."
> — [Webhook signature](https://developer.clickup.com/docs/webhooksignature). The `secret` is returned in the Create-Webhook response object.

**Automation "Call webhook".** The no-code path; per ClickUp Help (via search — the page 403s to fetch):

> "Use Automations webhooks when you want complete control over the Triggers and Conditions that send your data to external apps. There are two kinds … Task webhooks that send data when tasks are updated, and Chat webhooks that send data when chat messages are posted." … "You can enter your webhook URL and select any dynamic fields to include them in the URL. By default, the content type is set to application/json, and to add a custom header, you can click +Add and enter a key and value." … "Message is posted is the only Chat webhook Trigger."
> — [Integrate ClickUp using Automation webhooks](https://help.clickup.com/hc/en-us/articles/35313844961943-Integrate-ClickUp-using-Automation-webhooks) (and the task/chat webhook help pages)

**Comment as a trigger** (the most natural "ask" entry point — a user comments the question on a task) is a **newer / MVP** capability per the feature-request tracker, not a long-stable trigger:

> "An MVP of comment-triggered automation features was being released, with awareness of additional asks such as selecting user(s) whose comments will trigger the automation."
> — [Automations: comments as trigger](https://feedback.clickup.com/feature-requests/p/automations-comments-as-trigger) *(via search; verify current availability in our workspace plan)*

### Q3 — Inbound post-back: returning the report as a comment

`POST https://api.clickup.com/api/v2/task/{task_id}/comment` with body `comment_text` (required) + `notify_all` (required), optional `assignee` / `group_assignee` ([createtaskcomment](https://developer.clickup.com/reference/createtaskcomment)). Comments can also target Lists and **Chat views** ([comments](https://developer.clickup.com/docs/comments)) — relevant if we later mirror the Slack-thread UX in ClickUp Chat.

**Markdown caveat:** the basic `comment_text` field is plain text; ClickUp exposes a separate "Comment formatting" doc and a richer `comment[]` block format for styled content. **How our rendered markdown report maps to ClickUp's comment format is unverified here** — flag for a short implementation spike (see Open questions).

**Auth + limits** ([authentication](https://developer.clickup.com/docs/authentication), [rate-limits](https://developer.clickup.com/docs/rate-limits)):

> "Use a personal API token for individual or testing purposes. Personal tokens begin with `pk_`." … "To allow others to use your app, implement the OAuth2 flow so each user has their own token." (OAuth uses `Authorization: Bearer {access_token}`.)

> "Free Forever, Unlimited, Business": "100 requests per minute per token" · "Business Plus": "1,000 …" · "Enterprise": "10,000 …" — applying to "both personal and OAuth tokens"; over-limit returns `429` with `X-RateLimit-Limit` / `-Remaining` / `-Reset` headers.

100/min is ample for low-frequency, developer-triggered investigations; the only burst risk is streaming many progress updates as comment edits — batch them.

### Q4 — Build-vs-reuse: native AI Agents vs a webhook glue layer

ClickUp's AI Agents are real and powerful, but their external reach is through **ClickUp's integration catalog + MCP-compatible integrations**, not an arbitrary "call my REST endpoint." From the directly-fetched ClickUp blog (Mar 12 2026):

> Users define "Triggers (e.g., status change, chat message), Instructions (custom prompts), Knowledge (Docs, tasks, chat history), Actions" … "You can even connect external tools like Slack or GitHub via" ClickUp integrations and include their data in agent Knowledge sources.
> — [How to Build an AI Agent](https://clickup.com/blog/how-to-build-an-ai-agent/)

> "With MCP-compatible ClickUp Integrations, you can connect to tools across your tech stack and execute workflows that span multiple platforms." … "Tools are available for use with Autopilot Agents, Super Agents, and Brain AI."
> — [MCP Tools](https://clickup.com/blog/mcp-tools/) and ClickUp Help (via search)

Search summaries of ClickUp Help further indicate Super Agents "can be assigned to tasks, @mentioned in comments, and operate with the same permissions as human team members," and "Autopilot Agents added to Channels can only take action on messages in the Channel." *(These specific @mention/assignment claims are from search summaries of `help.clickup.com` articles that 403'd on direct fetch — treat as directional and verify hands-on.)*

**Implication:** having a ClickUp Super Agent *itself* invoke our investigation service would require us to expose a ClickUp-recognized tool/integration (an MCP-compatible integration or catalog app) — net-new ClickUp-side work, on a fast-moving surface. The **webhook glue layer is dramatically simpler** and fully under our control.

## Implications for the design

- **Recommended Phase-1 shape — reuse the async REST contract, mirror the Slack-bot flow** (anchor: whether ClickUp access needs new service code). A ClickUp **Automation "Call webhook"** (or a developer **Webhook** on `taskCommentPosted`) → our **new inbound endpoint** → `POST /api/investigations` (existing) → run executes → we **post the report back via Create Task Comment**. No agent/runtime change; the only net-new service code is the inbound webhook receiver + a ClickUp REST client for post-back.
- **Generalize `SlackContext` → a provider-agnostic `ChannelContext`** carried opaque on the run (anchor: DTO/schema shape in `overview.md`). Fields: `provider` (`slack`|`clickup`), a channel/resource id (`task_id`), and a thread/anchor id (`comment_id`) so the post-back targets the right task/comment. This keeps one async contract serving both bots instead of a Slack-specific column set.
- **Two directions stay separate, don't conflate** (anchor: source vs interface): ClickUp-as-**interface** = Webhooks + REST post-back (this doc); ClickUp-as-**source** = the hosted MCP (OAuth-only, read) or REST, already in `web-spike.md` Spike 1. Different auth, different code path.
- **Secure the inbound webhook with HMAC-SHA256 `X-Signature` verification** (anchor: the no-PII / read-only security boundary). Store the `webhook.secret`; verify before parsing — same "validate-then-parse, payload untrusted until verified" discipline used elsewhere in the workspace. Make the handler idempotent on `webhook_id` + `history_item_id` since retry/delivery guarantees aren't documented.
- **Auth: start with a single service personal token (`pk_`) for post-back**; add a workspace **OAuth2 app** only if we need to attribute the run to the requesting ClickUp user (anchor: secret provisioning + `requested_by`). The Automation-webhook trigger needs no token on our side (ClickUp pushes to us).
- **Native AI-Agent integration is a Phase-2 enhancement, not Phase-1** (anchor: build-vs-reuse): richer UX (@mention a Super Agent, conversational follow-ups) but requires a ClickUp-recognized MCP/tool wrapper on a fast-moving surface. Defer until the webhook path proves the flow.
- **Rate limit (100/min on our likely plan) shapes progress UX** (anchor: events-timeline mapping): post a single "started" comment, then **one consolidated result comment** (or batched edits) rather than streaming each event — unlike Slack, comment spam is the failure mode here.

## Open questions / follow-ups

- [ ] **Which trigger UX do we want?** A user *comments the question on a task* (comment-trigger automation — newer/MVP, verify availability on our plan) vs *creates a task in a dedicated "Investigations" List* (stable `taskCreated` webhook) vs *sets a custom field*. Product decision; affects which trigger we wire.
- [ ] **Markdown → ClickUp comment format.** Confirm how our rendered markdown report maps to ClickUp's `comment_text` (plain) vs the rich `comment[]` block format — short implementation spike against the "Comment formatting" reference doc.
- [ ] **Which ClickUp plan is our workspace on?** Governs the rate limit *and* whether AI Agents / Automation webhooks / comment-triggers are available (admin input).
- [ ] **Per-user OAuth vs single service token** for post-back — do we need to attribute investigations to the requesting ClickUp user (audit / `requested_by`)?
- [ ] **Native Super-Agent reuse (Phase 2):** can a ClickUp Super Agent call a *custom* external tool / MCP we host, so the agent itself triggers an investigation? The MCP-compatible-integration model suggests it's possible but needs hands-on verification — and several supporting Help pages 403'd to automated fetch, so confirm in-product.
- [ ] **Verify the 403'd Help-page claims in-product** (automation webhook config, Autopilot/Super Agent triggers, @mention/assignment) — they're currently sourced from search summaries, not directly-fetched pages.
