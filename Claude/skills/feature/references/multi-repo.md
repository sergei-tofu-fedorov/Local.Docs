# /feature — multi-repo coordination & PR guidance

Most non-trivial features touch more than one repo (e.g., a new gRPC method in `Tofu.Invoices.Backend` plus a new HTTP endpoint in `Invoices.Backend` that calls it). The skill handles this through the plan doc's `Affected repos` list, but the human-coordination parts need to stay explicit.

## Producer / consumer ordering

When a feature crosses a service boundary (gRPC contract, shared DTO, queue message shape), call out which repo is the **producer** and which is the **consumer** in the plan doc's `Affected repos` section. Typical pattern in this workspace:

- `Tofu.Invoices.Backend` / `Tofu.Auth.Backend` are **producers** (own the gRPC contracts and the data).
- `Invoices.Backend` (BFF) is the **consumer** that calls them.

**Implementation order** — implement and merge producer-side first:
1. Add the new gRPC method / DTO field in the producer repo with **backwards-compatible defaults** (new field optional, new method tolerates absence).
2. Land and deploy the producer.
3. Implement the consumer side in `Invoices.Backend`, calling the new contract.
4. Land the consumer.

Calling this out in the plan prevents shipping a BFF PR that calls a method the deployed gRPC service doesn't yet have.

## Contract changes (gRPC / DTOs)

If the feature changes a `.proto` file or a shared DTO, the plan doc must list:
- which proto file / DTO,
- whether the change is additive (safe) or breaking (requires versioning),
- whether the consumer's mapping layer (`Invoices.Backend\Src\Tofu.Invoices\Mapping\Mapper.cs` and friends) needs an updated arm.

`/feature lint` will not catch contract-vs-mapping drift; `/feature review` (which calls `/review-gw --branch`) does check the EventType / Mapper consistency rules already documented in the `review-gw` skill — extend that pattern to other contract changes the feature introduces.

## No `pr` op — the user opens PRs

There is **no `pr` op**. `/feature` never pushes branches, never runs `gh pr create`, never opens or comments on PRs. The user always handles push + PR creation themselves.

When the user is ready to open PRs (after `/feature review` is clean), they can use the template below as a starting point for each PR body — but constructing and submitting the PR is on them. If the user explicitly asks for help drafting a PR body, you can produce text for them to paste; do not run `gh` commands.

```
Title:  <TASK>: <Title from plan doc>
Body:
## Summary
<pulled from the plan doc's Goal section>

## Plan
<copy of the Plan checklist with completed items checked>

## Test plan
<copy of the Test plan section>

## Companion PRs
<only when feature spans more than one repo — list each repo and its PR URL>
- Tofu.Invoices.Backend: <url>
- Local.Docs: <url> (or "pending — open after this merges")

Docs: Local.Docs/features/<TASK>/README.md
ClickUp: https://app.clickup.com/t/<TASK>
```

For multi-repo features, **producers first**: the user opens producer-side PRs (typically `Tofu.Invoices.Backend`, `Tofu.Auth.Backend`) before consumer-side PRs (`Invoices.Backend`), so producer URLs are available to cross-link in the consumer PR body's `## Companion PRs` section.

**Recommended pre-PR gate (user-driven):** before opening PRs, the user should run `/feature lint --deep` (JetBrains InspectCode) on every affected repo. `dotnet build` only catches compile-level warnings; InspectCode mirrors what Rider would show in the editor (unused symbols, redundant qualifiers, possible null refs, naming violations). Surface remaining WARNING-or-higher issues before the user pushes; do not silently suppress them.

## PR cross-linking (manual)

When the user opens multiple PRs for a single feature, each PR body should include a **Companion PRs** section linking to the others. For example, an Invoices.Backend PR body should contain:

```markdown
## Companion PRs
- Tofu.Invoices.Backend: <url>
- Local.Docs: <url>
```

The user opens producer-side PR(s) **first** so the URLs are available to cross-link from the consumer-side PR(s). If only one repo is affected, this section is omitted. `/feature` does not open or update PRs — this is purely guidance for what the user should put in the PR body when they create it.

## Local.Docs PR

The plan-doc PR in `Local.Docs` is always its own PR. By convention it lands **last** — after all code PRs are merged — so the doc reflects what shipped. `/feature done` is what nudges you to land it; before then the plan doc lives on `main` of `Local.Docs` only via fast-forward updates from `/docs commit`.

## When repos are out of sync

If `/feature status` shows the feature branch is at different commits across repos (e.g., producer is merged, consumer is still in review), that's expected during the rollout window. Surface it but don't treat it as an error.

If `/feature start` finds an existing remote `feature/<TASK>` branch in some repos but not others (e.g., another teammate started the producer-side work), surface the existing branches and **ask** before creating new ones — never overwrite remote state silently.
