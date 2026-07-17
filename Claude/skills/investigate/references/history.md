# Prior-work recall (two stores, one gate)

Two knowledge stores exist. **Read both, write to one.**

| Store | Role | Contents |
|---|---|---|
| `Investigations/investigations/` (sibling repo, own git) | **Canonical — all new cases go here** | one folder per case, frontmatter-first READMEs; `README.md` index; `KNOWN_ISSUES.md` (symptom-keyed early-exit registry) |
| `.tofu-ai/` (workspace root, service-projected) | **Read-only recall** | `runs/YYYY-MM-DD_<id8>_<slug>.md` digests; `INDEX.md` (one line per run); `known-issues.md` (human-verified verdicts); service API `:5027` |

## Gate greps (run in one parallel batch)

```bash
# Known-issue registries — mandatory first read, both:
# Read Investigations/investigations/KNOWN_ISSUES.md
# Read .tofu-ai/known-issues.md

# Every literal identifier from the ask — trace ids, Sentry short-ids, account ids, error text, paths:
grep -ril "<identifier>" Investigations/investigations/ .tofu-ai/runs/

# Fingerprint match (canonical error identity — sentry:<issue-id> or err:<hash>):
grep -rl "sentry:INVOICE-MAKER-IOS-2Z6" .tofu-ai/runs/

# Thematic (no id-shaped tokens): scan the two indexes
# Read Investigations/investigations/README.md   (status | services | tags | root cause per row)
# Read .tofu-ai/INDEX.md                          (date | id | status | tags | fingerprints | summary)
```

A hit = this was investigated before. `Read` the matching case/run file — it carries the prior conclusion with file:line evidence.

## Secondary: the service API (`http://localhost:5027`)

For what the tree doesn't carry — live run state, the full rich report, structured filters:

```bash
curl -s "http://localhost:5027/api/investigations?citationRef=INVOICE-MAKER-IOS-2Z6"
curl -s "http://localhost:5027/api/investigations?tag=area:payments&limit=10"
curl -s "http://localhost:5027/api/investigations/<RUN_ID>/report"   # full rich report
```

No full-text API search — free-text recall is your grep over the trees.

## Fuzzy recall (`similar`)

When you have a *story* rather than a token ("iOS sync fails on big payload"): read both indexes + case frontmatter, rank cases by similarity, return a short ranked list (status + one-line root cause) so the best match can be opened.

## How to use what you find

- **Prior case concluded the same symptom** → read it, VERIFY the conclusion still holds with 1–2 cheap checks against current data, then build on it — cite the case slug / run id instead of re-deriving. Spend turns on what's genuinely new.
- **Known issue matches** → verify cheaply, return early, tag `kind:known-issue`. Surface the "gotchas that mimic known issues" caveats from `KNOWN_ISSUES.md` — don't declare a match too eagerly.
- **Medium/low-confidence match** → a lead, not a verdict: link it via `related:` in the new case.
- **Evidence changed** (counts exploded, new release, different stack) → say so explicitly: "case X concluded …, but the situation now differs: …".
- Ignore your own in-flight run (its id is in your instructions, if any).

## Continuous matching (standing rule)

Evidence collection SURFACES identifiers the ask didn't contain — an exception type, a Sentry short-id, an account id, an endpoint. **The moment a new concrete identifier appears, grep both stores for it** — add the grep to the same parallel batch as your next source query; it costs nothing. This is how repeat root causes get answered in seconds instead of re-derived in minutes.
