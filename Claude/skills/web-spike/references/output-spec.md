# web-spike output spec

**Contents:** source-quality tiers (which sources to fetch) · the `web-spike.md` output template · the enforced style rules. Read this at Step 3 (fetch) and Step 4 (synthesize) of the `write` op.

## Source-quality tiers

The whole value of a web-spike is that its claims trace to authoritative sources. Fetch in this priority order; a deviation (using a lower tier when a higher one exists) needs a stated reason.

**Always preferred:**
- Official vendor docs (`developer.servicetitan.io`, `developer.getjobber.com`, `learn.microsoft.com`, `developer.salesforce.com`, `learn.microsoft.com/dynamics365`).
- Standards bodies (`datatracker.ietf.org`, `w3.org`).
- Cited authors with track records (`martinfowler.com`, `microservices.io` — Chris Richardson, Vaughn Vernon, Eric Evans).
- Cloud architecture references (Azure Architecture Center, AWS Prescriptive Guidance).
- Major library / framework docs (`learn.microsoft.com/ef-core`, `mongodb.com/docs`, `kafka.apache.org/documentation`).

**Acceptable when nothing better exists:**
- Well-cited Medium / dev.to / personal-blog articles by named experts (NOT random aggregators).
- Stack Overflow answers from high-rep users when no other source exists.
- Confluent / Datadog / Decodable / similar engineering blogs when the topic is in their wheelhouse.

**Skip:**
- Aggregator / SEO-content sites with no named author.
- Tutorials that don't cite primary sources.
- Anything more than ~5 years old when the topic involves active framework / library evolution.
- LinkedIn posts and Twitter threads as primary sources.

For each source: fetch via `WebFetch` with a focused extraction prompt, capture **verbatim quotes** for load-bearing claims (do NOT paraphrase facts), and capture the URL for citation. When a quote is paraphrased due to access restrictions (JS-rendered SPA, paywall), say so inline.

## Output template

Produce `web-spike.md` with this shape:

```markdown
# <TASK> — Web Spike: <topic title>

Two- or three-sentence framing of what was investigated and why this feature needs it.

## Questions

1. <research question 1>
2. <research question 2>
3. ...

## Sources

Authoritative references used, grouped by category if there are many.

- [Title](URL) — one-line characterisation of what the source establishes.
- ...

## Findings

### <Question 1 restated as a heading>

Synthesis paragraph.

> Verbatim quote when a claim is load-bearing.
> — Author, [Source](URL)

Comparison table when surveying ≥3 options, with a Source column linking each row.

### <Question 2 ...>

...

## Implications for the design

Bulleted list. Connect findings to the design choices the next `/plan write` will need to make. Do not just summarise the findings — link them to specific architectural decisions (data store choice, contract shape, pattern selection, breaking-change risk).

- Implication 1 (anchor: which design decision this informs).
- Implication 2.

## Open questions / follow-ups

- [ ] Things the web-spike couldn't resolve and need product / team / lead input.
- [ ] Adjacent topics worth a separate web-spike.
```

## Style rules (enforced in output)

1. **Verbatim quotes for load-bearing claims**, not paraphrases. If a vendor's API behaviour or a pattern's invariant is being cited as fact, quote the docs and link the page.
2. **Every source carries a URL.** No "I read somewhere that…".
3. **Comparison tables** when ≥3 options are being weighed. Columns: option name + key trait(s) + a `Source` column with per-row links.
4. **Findings section organised by question, not by source.** The reader should be able to skim section headings and learn the answers.
5. **Implications section is mandatory.** A web-spike that doesn't connect findings to the design is research, not engineering. Force the link.
6. **Caveats inline.** When a source is older than the field has moved, when a vendor's docs are JS-rendered (so verification was indirect), when a quote was paraphrased due to access restrictions, say so in the same sentence — not in a footnote.
7. **No conjecture without sources.** If the web-spike couldn't find a source for a claim, either drop the claim or move it to `Open questions / follow-ups`.
