# WEB-1523 — Provider (LLM model + integration)

Locked on **OpenAI `gpt-4.1-nano`** with strict structured outputs, validated against a 1,000-account FSM-fit run on 2026-05-13. Volume: ~45k accounts/week (~195k/month), ~700 input + ~200 output tokens. Cost is **not** the binding constraint at this scale; integration surface is. PII payload shape + legal stack: [`privacy.md`](privacy.md).

## Decision

- **Provider / model:** OpenAI direct API, `gpt-4.1-nano`.
- **Integration:** `/v1/chat/completions` with `response_format: { type: "json_schema", strict: true }` for schema-enforced JSON. No retry-on-parse logic needed — strict mode wire-enforces the schema.
- **Pricing:** $0.10 / $0.025 cached / $0.40 per 1M tokens (input / cached-input / output).
- **Measured cost:** $0.20 for 1,000 accounts (~$0.000202/account, 2026-05-13 sweep). Projected ~$15/month for weekly 50k refresh once caching is engaged at steady state.
- **Audience:** mostly US, with an EU minority. See § 2 for how we route each request to the right region; § 3 for Azure OpenAI as the fallback if residency ever hardens.
- **Constraints satisfied:** see [`privacy.md`](privacy.md) — signed DPA, ZDR via Enterprise tier, region pinning per project for the EU minority.

## 1. Cost-control techniques (OpenAI-specific)

**Prompt caching has a hard 1,024-token floor.** Below that, OpenAI does not cache the prefix at all. The production prompt is ~1,400 tokens by deliberate padding (industry lists, per-field examples, hard rules) — not dead text, content that improves quality. If the natural prompt is shorter, pad with rule definitions / examples; never with filler.

**Cache-routing — two techniques stack to ~95% steady-state hit ratio:**

1. **Warmup-then-pool** (client-side timing). One sequential call to populate the cache, then burst the parallel pool. Turns 35% burst-from-cold into ~95%.
2. **`prompt_cache_key`** (server-side hint). Stable string per prompt version pins related requests to the same cache shard; bump the suffix when the system prompt changes so old/new prompts don't share cache space.

```js
const body = {
  model: 'gpt-4.1-nano',
  prompt_cache_key: 'fsm-fit-v1',
  messages: [
    { role: 'system', content: SYSTEM_PROMPT },   // ≥ 1024 tokens
    { role: 'user',   content: userMessage },
  ],
  response_format: { type: 'json_schema', json_schema: SCHEMA },
  temperature: 0,
  max_tokens: 600,
};
// Wrap the batch in a warmup-then-pool driver:
//   await callOnce(items[0]); await sleep(2000);
//   await pool(items.slice(1), CONCURRENCY, ...)
```

**Batch API.** 50% off, ≤24h SLA (most batches finish in <1h). Stacks with caching. Right tool for non-user-blocking analyses — exactly our case. Structured outputs supported on Batch for the 4.1 family.

**Async / queue execution.** Analyses run off Hangfire in-process inside `Tofu.AI.Api` (single-pod; no separate worker), never inline with a user request — see [`../implementation/service.md`](../implementation/service.md).

## 2. Regions in practice — routing US vs. EU customers

"Region" for an AI provider is **where the prompt is processed and where any retained data sits** — a compliance attribute, not just a latency one. Our customer base is mostly US with an EU minority, so the question isn't "pick one region" — it's "route each request to the right region."

### How OpenAI's Project model handles regions

One **OpenAI Project** is pinned to one region (set in the platform's project settings) and one API key belongs to one project. There is no per-request region override — the region is whichever Project the key on the request belongs to. Serving both US and EU customers from one OpenAI account therefore means **two Projects, two API keys, and routing at the application layer.**

### Routing the customer to the right region

Each `Account` already carries enough signal to pick a jurisdiction without adding new fields — `Account.CurrencyCode` and `Timezone` (see [`../analyses/data-sources.md`](../analyses/data-sources.md)) give a strong proxy; the customer's billing country, if collected, is authoritative. The worker picks the API key based on this attribute before constructing the request:

```csharp
var key = account.IsEu()
    ? config["Openai:ApiKey:Eu"]
    : config["Openai:ApiKey:Us"];
```

No model change, no SDK change, no prompt change — same `gpt-4.1-nano`, same nano pricing on both Projects (no uplift at this tier), same emit schema.

### Three concrete options

1. **One US Project, no routing.** Cheapest setup. Acceptable while EU users have no stricter-than-default expectations and our customer DPA / sub-processor list does not promise a specific region. Breaks the moment a German enterprise asks where their invoice item text is processed.
2. **Two OpenAI Projects, jurisdiction-based routing (recommended for v1).** US Project for US accounts, EU Project for EU accounts; one extra config line + a `pickKey(account)` helper. Same model, same pricing, same SDK. Scales to the EU minority without rework.
3. **Hybrid — OpenAI US + Azure OpenAI EU.** Only needed if EU residency hardens (regulator audit, or a customer DPA demanding architecturally-pinned EU processing rather than project-scoped). Adds a second SDK + integration; defer until forced.

**Pick option 2 for v1.** Keeps the LLM client adapter portable, leaves option 3 as a future swap that does not change the prompt or emit schema.

## 3. Alternatives — if we ever swap

Eligibility constraints (DPA + ZDR + region) defined in [`privacy.md`](privacy.md) § 3. Audience is **mostly US with an EU minority** — both jurisdictions need a viable region; the US case dominates the verdict and the EU case has to be at least covered. Volume = ~137M input + ~39M output tokens/month.

| Provider · model | In $/1M | Out $/1M | Raw $/mo | + Batch | US region | EU region | Verdict |
|---|---:|---:|---:|---:|---|---|---|
| **OpenAI · gpt-4.1-nano** *(locked)* | $0.10 | $0.40 | $30 | $15 | ✅ US-native | ⚠️ project-scoped pinning | Cheapest tier with strict structured outputs we have working code for. US default; EU minority covered via project region (fall back to Azure OpenAI if EU residency hardens). |
| Azure OpenAI · GPT-4.1 nano | $0.10 | $0.40 | $30 | $15 | ✅ East US / West US | ✅ Sweden / France / Switzerland Central | Same model with stricter regional pinning + BAA on both sides — swap target if residency hardens on either jurisdiction. |
| Google Vertex · Gemini 2.5 Flash-Lite | $0.10 | $0.40 | $30 | $15 | ✅ `us-central1` etc. | ✅ native `europe-west*` | Strongest dual-region story; cheapest Google option. |
| Anthropic Haiku 4.5 | $1.00 | $5.00 | $332 | $166 | ✅ direct API (US-native) | ✅ via Bedrock `eu-central-1` | ~10× cost — only if reasoning quality clearly outperforms nano. |
| AWS Bedrock · Nova Micro | $0.035 | $0.14 | $10 | n/a | ✅ `us-east-1` / `us-west-2` | ✅ `eu-central-1` | Cheapest of all; viable if cost ever becomes the binding constraint. |
| Mistral La Plateforme · Small 3.1 | $0.20 | $0.60 | $51 | $26 | ✅ via API | ✅ native EU (French co.) | EU-sovereignty pick if regulator concern dominates. |
| DeepSeek V3 | $0.14 | $0.28 | $30 | n/a | ❌ PRC infra | ❌ PRC infra | **Disqualified** for production — offline prototyping only. |

The cheap-tier cluster (~$15/month with batch) is fungible across jurisdictions. **The portable artifact is the prompt + emit schema** ([`../analyses/fsm-fit/scoring.md`](../analyses/fsm-fit/scoring.md)), not the SDK; swapping providers — or splitting US vs. EU traffic across two providers if the audience mix ever shifts — means re-wiring the client adapter, not redesigning the analysis.

## Sources

- [OpenAI Pricing](https://developers.openai.com/api/docs/pricing) — gpt-4.1-nano list rates.
- [OpenAI Structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs) — `response_format: { type: 'json_schema', strict: true }`.
- [OpenAI Batch](https://developers.openai.com/api/docs/guides/batch) — 50% off, 24h SLA.
- [Prompt caching across providers (PromptHub)](https://www.prompthub.us/blog/prompt-caching-with-openai-anthropic-and-google-models) — caching mechanics by provider.
- Cross-provider cost floor: [Anthropic Pricing](https://platform.claude.com/docs/en/about-claude/pricing), [Gemini Pricing](https://ai.google.dev/gemini-api/docs/pricing), [AWS Nova Pricing](https://aws.amazon.com/nova/pricing/), [Mistral Pricing](https://devtk.ai/en/blog/mistral-api-pricing-guide-2026/).
