# /feature review — pre-PR review + breaking-change scan

1. Resolve `<TASK>`. For each affected repo:
   - Determine base branch (resolve dynamically — see "Operation: start" in SKILL.md; `Invoices.Backend` → `master`, others → `main`).
   - Invoke the existing `/review-gw` logic with **`--branch` mode** (reviews `git diff <base>...HEAD` of the local feature branch — does not need a GitHub PR yet). See the `review-gw` skill.
2. **Always run a breaking-change scan** (below) and fold its findings into the per-repo section of the report. This is non-optional — every `/feature review` includes it, even on apparently additive features.
3. Aggregate findings across repos into a single report with sections per repo.

This is meant to be run **before** the user opens PRs, so issues are caught locally. After `/feature review` is clean, the user pushes branches and opens PRs themselves — `/feature` does not do this.

## Breaking-change check (mandatory part of `review`)

Audit the diff for changes that could break consumers — internal callers in this workspace, mobile apps already in the field, third-party API users, or downstream services. Flag each finding as either **breaking** (requires version bump / migration / coordinated rollout) or **risky** (looks safe but worth a second look).

Categories to scan, per repo:

| Layer | Check |
|---|---|
| **gRPC `.proto`** | Removed/renamed messages, fields, RPCs, or enum values; reordered/renumbered field tags; type changes; required-vs-optional changes; renamed packages or `csharp_namespace`. Adding new messages/RPCs/enum values is **additive** (safe). Reusing an existing enum from another proto file is safe **as long as the wire numbers don't move**. |
| **REST API** | Removed/renamed endpoints, paths, query params, headers; changed HTTP verbs; changed status codes; tighter request validation; response shape changes (removed fields, renamed fields, narrowed types, newly-required fields). New endpoints / new optional fields are additive. |
| **Public C# surface** (anything used by another repo or NuGet consumers — `*.Client` libraries, shared contracts) | Removed/renamed public types/members; signature changes; visibility downgrades; namespace moves; default-value changes on parameters; nullability changes on public surface. |
| **Database / Mongo / EF** | Removed collections/columns; renamed fields without dual-read; index drops; non-additive migrations; changed serialization (e.g., enum-as-string ↔ enum-as-int); changed constraints (`NOT NULL` adds, unique-index adds on populated tables). |
| **Queue / event payloads** | Removed/renamed fields in published events; consumer must tolerate older producers and vice versa during rollout. |
| **Configuration / env vars** | Renamed/removed config keys without fallback; changed defaults; added required keys. |
| **Auth / permissions** | Tightened authorization; removed permission keys; renamed roles. |
| **CLI / public scripts** | Removed flags or changed flag semantics. |

Output format inside the review report:

```
## Breaking-change scan — <repo>

- **BREAKING — gRPC**: `EstimatesApi.SyncEstimates` enum renumbered field 2 — drops compatibility with shipped iOS clients. Roll out producer-first, gate consumer behind feature flag.
- **Risky — Mongo**: dropped index `ix_estimates.accountid.date.createdtime` (replaced by composite). Verify no remaining query patterns rely on the dropped index by scanning `EstimatesRepository.*`.
- **Additive only**: 4 new proto messages, 1 new RPC, 1 new REST endpoint — no compatibility risk.
```

If **no** breaking or risky changes are found, still emit the section with an explicit `Additive only` line so it's clear the check ran. Never omit the section — its absence is a smell.

When a breaking change is unavoidable (e.g., a security or compliance fix), capture the rollout plan in the plan doc's `Cross-repo notes` and surface it in the PR body's `## Summary`. The reviewer needs to see the migration story alongside the code.
