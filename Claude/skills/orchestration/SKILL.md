---
name: orchestration
description: Reusable multi-agent orchestration pattern for workspace skills (investigate today; feature-planner and others later) — tier ladder (inline / standard / deep), phase model (gate → collect → cross-match → synthesize → verify → persist), subagent prompt contract, structured-output schemas. Load when running or authoring a skill that fans out to subagents.
---

# Multi-agent orchestration pattern (workspace-wide)

One pattern, many skills. A consuming skill (e.g. `investigate`) defines *what* its phases collect; this file defines *how* fan-out works. Don't re-derive these rules per skill.

## Tier ladder — match cost to the ask

| Tier | Mechanism | When |
|---|---|---|
| **inline** | no subagents, main context only | single-identifier lookups, "glance at X", anything one grep/query answers |
| **standard** | Agent-tool fan-out (2–5 agents, one parallel batch) | default for a real task: multiple independent sources to consult |
| **deep** | Workflow script (deterministic phases, resume, adversarial verify) | "thorough / audit / comprehensive / incident post-mortem" wording, or standard tier surfaced contradictory evidence |

Selection: infer from the user's wording; when torn between two tiers, pick the cheaper one and say so — the user can escalate. A skill invoking Workflow per its own instructions is a legitimate opt-in (no extra confirmation needed), but never jump to deep for a question inline answers.

## Phase model

```
0. GATE        (inline, always)  — intake + prior-knowledge check; may EARLY-EXIT everything
1. COLLECT     (fan-out)         — one agent per independent source, launched in ONE message
2. CROSS-MATCH (inline loop)     — new identifiers from any agent → re-run the gate greps
3. SYNTHESIZE  (inline)          — merge evidence, name the mechanism/decision
4. VERIFY      (deep tier only)  — adversarial agents try to REFUTE the synthesis
5. PERSIST     (inline, always)  — write the artifact; file writes never happen in subagents
```

Hard rules:

- **Gate and Persist are always inline.** The gate can end the whole task in one grep (don't spawn agents before it); the main context owns all file writes and user-visible conclusions.
- **Collect agents are read-only** and independent — if agent B needs agent A's output, that's two phases, not one batch.
- **Launch parallel agents in a single message** (multiple Agent calls in one block). Filter out failed/null results; never fabricate a pending agent's result.
- **Cross-match is a loop, not a step**: any *new* concrete identifier (id, error type, path, account) surfaced by a collector gets fed back through the gate greps before synthesis.

## Subagent prompt contract

Every collector prompt has exactly four parts:

1. **Role + scope** — one sentence: what source it owns, what it must NOT do (no writes, no other sources).
2. **Reference** — the ONE reference file to read first (`Read .claude/skills/<skill>/references/<file>.md`). Agents never load the whole parent skill.
3. **Question(s)** — the concrete questions, with the identifiers/time-window pinned. Include the relevant safety rails (env, read-only, rate limits) verbatim from the reference.
4. **Output schema** — the agent's final text must be exactly this JSON, nothing else:

```json
{
  "findings":    [{ "claim": "...", "evidence": "...", "citation": "<id/file:line/url>", "confidence": "high|med|low" }],
  "identifiers": [{ "type": "trace|account|error|path|sentry-issue|commit|other", "value": "..." }],
  "limitations": ["what could not be checked and why"]
}
```

A claim without a citation is not a finding. Agents report "nothing found" as an empty `findings` array with the search described in `limitations` — silence is not a result.

## Deep tier (Workflow)

Encode phases 1–4 as a Workflow script: `phase('Collect')` fan-out with `schema` (the JSON above as JSON Schema — validation is free), a barrier only where synthesis genuinely needs all results, then `phase('Verify')` — 2–3 refuters per key claim (`Try to refute: <claim>. Default to refuted=true if uncertain.`), majority vote. Gate runs inline *before* invoking Workflow; Persist runs inline *after* it returns. See the consuming skill's `references/deep-workflow.md` for its concrete template.

## Adopting this pattern in a new skill

1. In `SKILL.md`: a tier-selection line, a **collector table** (agent role → reference file → question shape), and the persist contract. Keep it thin — knowledge goes to `references/`.
2. One reference file per source/concern, self-sufficient for a subagent that reads nothing else.
3. Reuse the output schema above; extend fields, don't replace them.
4. State the skill's early-exit condition for the gate (for `investigate`: known-issue match; for a feature planner: an existing plan/spike covering the ask).
