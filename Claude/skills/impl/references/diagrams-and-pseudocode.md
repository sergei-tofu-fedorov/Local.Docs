# /impl — mermaid diagram rules & structured-pseudocode house style

Read the relevant section before drawing any diagram or pseudocode block in `impl-design.md` / `impl-interaction.md`.

## Mermaid class-diagram rules (required in every `impl-design.md`)

- Use `classDiagram`. Render interfaces with `<<interface>>`.
- Edges: `..|>` for *implements*, `-->` for *uses / depends on* (label the edge with the role, e.g. `EstimateService --> IEstimateRepository : reads`), `*--` for *owns / composes*.
- Include **new** types fully (with their key members). Include **existing** types only as endpoints of an edge (no member list) and tag them with a style so the reader sees what's new vs. what's already there:
  ```mermaid
  classDiagram
      class IEstimateExporter {
          <<interface>>
          +ExportAsync(EstimateId id) Task~ExportResult~
      }
      class PdfEstimateExporter {
          +PdfEstimateExporter(IEstimateRepository repo)
          +ExportAsync(EstimateId id) Task~ExportResult~
      }
      class IEstimateRepository {
          <<interface>>
      }
      PdfEstimateExporter ..|> IEstimateExporter
      PdfEstimateExporter --> IEstimateRepository : reads
      class IEstimateRepository:::existing
      classDef existing fill:#eee,stroke:#999,stroke-dasharray:3 3
  ```
- The diagram is for comprehension, not exhaustiveness — show the architecturally meaningful types and edges, not every DTO field.

## Mermaid interaction-diagram rules (only in `impl-interaction.md`, only on explicit request)

- Use `sequenceDiagram`. One participant per new class plus one per external store/service it touches (Mongo, Postgres, BigQuery, a gRPC service, Hangfire). Alias long names (`participant Job as MetricsRefreshJob`).
- Order matters: lay participants left-to-right in call order. Use `->>` for calls, `-->>` for returns (only draw returns that carry meaningful data).
- Wrap conditional steps in `opt` / `alt` and repeated work in `loop`, with a short label (`loop bounded parallel, per account_id`). This is the payload the diagram exists to convey.
- Annotate non-obvious steps with `%% comment` (the trigger, a branch condition, a batch size).
- Trace the **primary** flow end to end; leave error/retry paths to prose unless an error path is the whole point of the feature.

## Structured-pseudocode house style

When an algorithm or orchestration flow needs to be shown (a method's logic, a job tick, a multi-step funnel), write it as **structured pseudocode**, never as runnable C#:

- UPPERCASE control keywords (`IF` / `FOR EACH` / `WHILE` / `RETURN`); indentation for nesting, not braces.
- `←` for assignment, `∪` / `∩` / `∈` where set semantics are clearer than words.
- Drop language ceremony — no `await`, `var`, `new ParallelOptions{}`, generics, or types unless the type *is* the point.
- Trailing `# note` for the one detail a reader needs (a batch cap, fan-out count, the store hit).
- Fence as ```` ```text ````. Aim for ~⅓ the length of the equivalent C#.

Example (the `MetricsRefreshJob` tick):

```text
RunAsync(tick):
  expired ← BQ account_ids WHERE expires_at < now   (≤ BatchSize)
  IF first tick of UTC day:
      discovered ← DiscoverNewCandidates()
  queue ← distinct(expired ∪ discovered)

  FOR EACH account IN queue  (parallel ≤ MaxConcurrentAccounts):
      row ← collector.Build(account)    # 4 Mongo pipelines
      writer.Upsert(row)                # BQ Storage Write API, CDC UPSERT
```
