# /feature Skill - Quick Reference

End-to-end backend feature workflow: scaffold plan in Local.Docs → *(optional)* `/web-spike` for web research → deepen via `/plan` → branch & implement → lint → pre-PR review. **Push and PR creation are always manual** — the user opens PRs themselves; `/feature` never pushes, commits code, or runs `gh pr create`.

## Slug convention

`<TASK>` = ClickUp task ID, e.g. **`WEB-1234`** (uppercase letters + dash + digits). The same slug is used everywhere:

- Plan doc: `Local.Docs/features/WEB-1234/README.md`
- Branch in each touched repo: `feature/WEB-1234`
- Commit prefix / PR title prefix: `WEB-1234: …`

## Commands

| Command | Description |
|---------|-------------|
| `/feature plan <TASK> [<title>]` | Scaffold `README.md` in Local.Docs. Stops after scaffolding; user runs `/web-spike` and/or `/plan write` next. |
| `/feature load <TASK>` | Load an existing feature — pulls Local.Docs, reads plan, shows state |
| `/feature list` | List feature folders with status |
| `/feature start <TASK>` | Pulls Local.Docs, **gates on `overview.md` existing**, then creates `feature/<TASK>` branch in each affected repo |
| `/feature status [<TASK>]` | Show working state across affected repos |
| `/feature lint [<TASK>] [--deep]` | Run lint/inspection on touched repos |
| `/feature review [<TASK>]` | Local pre-PR review (calls `/review-gw --branch`) |
| `/feature done <TASK>` | Mark plan as shipped after the user lands the PRs |

> No `pr` op. The user pushes branches and opens PRs themselves — `/feature` never runs `git push`, `gh pr create`, or any other publishing command.

`<TASK>` is inferred from the current branch (`feature/WEB-1234` → `WEB-1234`) when omitted on ops other than `plan` and `list`.

Bare form `/feature <TASK>` (no verb) is treated as `load <TASK>` — quick way to resume an existing feature.

## Typical flow

```bash
# 1. Plan — scaffolds README.md and stops
/feature plan WEB-1234 "Add bulk invoice export"

# 2. Spike (optional) — web research for vendor APIs, design patterns, libraries
/web-spike WEB-1234 "field-service vendor note APIs"
# Writes Local.Docs/features/WEB-1234/web-spike.md. Skip for pure refactors.

# 3. Plan write — produces overview.md, reads README + web-spike.md
/plan write WEB-1234
# Asks clarifying questions, writes overview.md calibrated to complexity tier

# Commit the docs (whichever you produced)
pwsh Local.Docs/scripts/commit-docs.ps1 -ShortDescription "WEB-1234 plan"

# 4. Start — refuses if overview.md is missing
/feature start WEB-1234
# → branches created in each affected repo

# 5. Implement against overview.md
# (write code, commit per repo)

# 6. Lint
/feature lint              # fast: dotnet build + dotnet format + analyzers
/feature lint --deep       # slow: JetBrains InspectCode

# 7. Local review
/feature review            # pre-PR review against base branch

# 8. Rider/InspectCode pass — recommended last gate before opening a PR
/feature lint --deep       # surface remaining warnings before you push

# 9. Push + open PRs YOURSELF (no /feature op for this)
#    git push -u origin feature/WEB-1234   # in each affected repo
#    gh pr create ...                      # producers first, then consumers
#    Cross-link "## Companion PRs" sections by hand for multi-repo features.

# 10. Ship
/feature done WEB-1234     # after your PRs land
```

**Skip `/web-spike`** when the pattern is already established in this workspace, the change is a pure refactor / config edit, or research has already been done and dropped in the folder.

**Skip `/plan write`?** Don't. `/feature start` refuses without `overview.md`. To branch anyway (without the deepened plan), pass `skip overview` or `branch anyway` to `/feature start` — generally don't, branching without `overview.md` is the failure mode the gate exists to prevent.

## Lint tooling

- **Default (fast):** `dotnet build /warnaserror`, `dotnet format --verify-no-changes`, `dotnet format analyzers --verify-no-changes`. Catches what Rider's Build view + .editorconfig + Roslyn analyzers show.
- **`--deep`:** JetBrains InspectCode CLI (`jb inspectcode`), the literal Rider/ReSharper engine headless. **Always scoped to feature-branch diff only** (`--include` built from `git diff origin/<base>...HEAD -- *.cs`); never whole-solution. Skips repos with no C# changes. Installed via `dotnet tool install -g JetBrains.ReSharper.GlobalTools` (skill asks before installing globally).

## Conventions

- Plan doc is the **source of truth** for which repos are affected.
- Same `<TASK>` everywhere — folder, branch, commit prefix, PR title.
- **Never auto-commit. Never push. Never open PRs.** Doc changes via `/docs commit` (user-invoked); code commits, branch pushes, and PR creation are entirely the user's responsibility — `/feature` does not do any of these.
- **Never force-push** or push to base branches.
- One feature per branch per repo. Untouched repos don't get a branch.
- Local.Docs PR is separate from the code PRs.
- Default single repo: `Invoices.Backend` (BFF / main repo).
- **Add at least one integration test** for any new runtime behavior, then run `/tests` to refactor the new test files into project convention before `/feature lint`.
- **Add short single-line comments to non-obvious business logic** while implementing — domain rules invisible in code structure, hidden invariants, cross-system contracts, intentional asymmetries, framework workarounds. Default is no comment; the trigger is *"would a six-month-later reader wonder why?"*. Single-line `// why`, never restating the *what*. `/feature review` flags rationale gaps; `/feature lint` does not enforce.
- **`/feature review` always runs a breaking-change scan** (proto field renumbering, removed/renamed REST endpoints, dropped DB columns, narrowed types, changed event payloads, etc.) and records `Additive only` explicitly when there are none. The plan doc has a `## Breaking changes` section for the same purpose at planning time.
- **Base branch differs per repo** — resolve via `git symbolic-ref refs/remotes/origin/HEAD`. Known: `Invoices.Backend` → `master`; `Tofu.Invoices.Backend` / `Tofu.Auth.Backend` / `Tofu.Common.Backend` / `Local.Docs` → `main`.
