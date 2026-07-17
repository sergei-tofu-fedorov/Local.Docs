# Deep tier — Workflow template

For "thorough / audit / post-mortem" investigations, contradictory standard-tier evidence, or prod incidents with unclear blast radius. The skill instruction to use Workflow here IS the opt-in — no extra confirmation needed. **Gate runs inline BEFORE invoking Workflow; Persist runs inline AFTER it returns.**

Adapt this script — fill the identifiers/window from the gate, drop collectors whose source can't bear on the ask:

```js
export const meta = {
  name: 'deep-investigation',
  description: 'Fan out evidence collectors, cross-match, adversarially verify the mechanism',
  phases: [
    { title: 'Collect', detail: 'one agent per source' },
    { title: 'Verify', detail: 'refuters on each key claim' },
  ],
}

const FINDINGS = {
  type: 'object', required: ['findings', 'identifiers', 'limitations'],
  properties: {
    findings: { type: 'array', items: { type: 'object', required: ['claim', 'evidence', 'citation', 'confidence'],
      properties: { claim: {type:'string'}, evidence: {type:'string'}, citation: {type:'string'}, confidence: {enum:['high','med','low']} } } },
    identifiers: { type: 'array', items: { type: 'object', required: ['type','value'],
      properties: { type: {enum:['trace','account','error','path','sentry-issue','commit','other']}, value: {type:'string'} } } },
    limitations: { type: 'array', items: {type:'string'} },
  },
}
const VERDICT = { type: 'object', required: ['refuted', 'reason'],
  properties: { refuted: {type:'boolean'}, reason: {type:'string'} } }

// Collectors: prompt = role + ONE reference file + pinned identifiers/window + output schema.
// args = { ask, identifiers, window, gateSummary } — passed by the orchestrator.
const REF = '.claude/skills/investigate/references'
const SENTRY_REF = '.claude/skills/sentry/references/sentry.md'   // owned by the sentry toolkit skill
const GCP_REF = '.claude/skills/gcp/references/gcp-logs.md'       // owned by the gcp toolkit skill
const collectors = [
  { key: 'history', prompt: `Read ${REF}/history.md, then grep BOTH stores for each of: ${JSON.stringify(args.identifiers)}. Return prior-case conclusions with slugs/run-ids as citations. Read-only.` },
  { key: 'sentry',  prompt: `Read ${SENTRY_REF}, then pull issues/events for: ${JSON.stringify(args.identifiers)} in window ${args.window}. Counts, first/last-seen, tags, stack symbol + release. GET only, keep to a handful of calls.` },
  { key: 'gcp',     prompt: `Read ${GCP_REF}, then establish scope for: ${args.ask}. Counts, affected accounts, first-seen, per-endpoint/per-version aggregation. gcloud logging read ONLY; --project explicit; bound every query.` },
  { key: 'code',    prompt: `In the workspace repo checkouts, resolve the throw site / mapping / recent commit for: ${args.ask}. Deployed state is origin/<default-branch> — never checkout. Return file:line citations.` },
]

phase('Collect')
const results = (await parallel(collectors.map(c => () =>
  agent(c.prompt, { label: `collect:${c.key}`, phase: 'Collect', schema: FINDINGS })
))).filter(Boolean)

// Cross-match: NEW identifiers (not in the ask) → one more history pass. Barrier is justified: needs all collectors.
const known = new Set(args.identifiers.map(i => i.toLowerCase()))
const fresh = results.flatMap(r => r.identifiers).filter(i => !known.has(i.value.toLowerCase()))
let historyEcho = null
if (fresh.length) {
  historyEcho = await agent(
    `Read ${REF}/history.md, then grep BOTH stores for each of: ${JSON.stringify(fresh.map(f => f.value))}. Return matching case conclusions.`,
    { label: 'cross-match:history', phase: 'Collect', schema: FINDINGS })
}

phase('Verify')
const evidence = JSON.stringify([...results, historyEcho].filter(Boolean).flatMap(r => r.findings))
const keyClaims = results.flatMap(r => r.findings).filter(f => f.confidence === 'high')
const verified = await parallel(keyClaims.map(claim => () =>
  parallel([1, 2, 3].map(n => () =>
    agent(`Adversarially verify against this evidence set: ${evidence}\n\nTry to REFUTE: "${claim.claim}" (evidence: ${claim.evidence}, citation: ${claim.citation}). Check the citation actually supports it. Default to refuted=true if uncertain.`,
      { label: `refute${n}:${claim.citation}`.slice(0, 40), phase: 'Verify', schema: VERDICT })
  )).then(vs => ({ ...claim, survives: vs.filter(Boolean).filter(v => !v.refuted).length >= 2 }))
))

return {
  confirmed: verified.filter(c => c.survives),
  rejected: verified.filter(c => !c.survives),
  supporting: results.flatMap(r => r.findings).filter(f => f.confidence !== 'high'),
  limitations: results.flatMap(r => r.limitations),
  newIdentifiers: fresh,
}
```

After it returns (inline): synthesize the mechanism from `confirmed` (file:line), treat `rejected` claims as leads at best, carry every `limitations` entry into the report, persist per `case-format.md`. If the workflow returns empty/odd results, Read the run's `journal.jsonl` before re-running; resume with `resumeFromRunId` after edits.
