---
name: feature
description: End-to-end feature workflow (plan | load | list | start | status | lint | review | done): scaffold plan docs in Local.Docs, branch, lint, pre-PR review. NEVER pushes, commits code, or opens PRs.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Workspace Layout

This skill is registered at the workspace root `C:\Git\Work\Backend\`. The workspace contains independent sibling git repos:

- `Invoices.Backend/` — BFF, main repo (default target)
- `Tofu.Invoices.Backend/`, `Tofu.Auth.Backend/`, `Tofu.Common.Backend/` — backend services / shared lib
- `Local.Docs/` — documentation, separate git repo

A feature can touch one or more of the backend repos. The plan document always lives in `Local.Docs/features/<TASK>/`.

## Slug / Branch Convention

- **Task ID format:** `WEB-1234` (ClickUp project prefix + dash + number, all caps).
- **Doc folder:** `Local.Docs/features/WEB-1234/`
- **Branch in each touched code repo:** `feature/WEB-1234`
- The same `<TASK>` is used everywhere — the doc folder, the branch name, the PR title prefix, the commit message prefix.

If the user gives a different format, normalize to upper-case letters + dash + digits (e.g., `web-1234` → `WEB-1234`). If the input does not look like a ClickUp task ID, ask before proceeding.

## Operations

| Op | Usage | Description |
|---|---|---|
| **plan** | `/feature plan <TASK> [<title>]` | Scaffold the plan doc in `Local.Docs/features/<TASK>/README.md`, then chain into `/plan write <TASK>` to produce `overview.md` |
| **load** | `/feature load <TASK>` | Load an existing feature — read the plan doc and show summary + state |
| **list** | `/feature list` | List existing feature folders with their current status |
| **start** | `/feature start <TASK>` | Create `feature/<TASK>` branch in each affected repo and print a derived checklist |
| **status** | `/feature status [<TASK>]` | Show working state across affected repos |
| **lint** | `/feature lint [<TASK>] [--deep]` | Run warning/inspection tools on touched repos — see [`references/lint.md`](references/lint.md) |
| **review** | `/feature review [<TASK>]` | Local pre-PR review against base branch (delegates to `/review-gw --branch`) — see [`references/review.md`](references/review.md) |
| **done** | `/feature done <TASK>` | Mark plan doc as `Status: shipped` after the user has landed all PRs |

> **The user always pushes and opens PRs manually.** `/feature` has no `pr` op and never runs `git push`, `git commit -a`, `gh pr create`, or any other publishing command. After `/feature review` returns clean, the next step is the user opening PRs themselves. PR-body template and producer/consumer ordering guidance: [`references/multi-repo.md`](references/multi-repo.md).

If `<TASK>` is omitted on ops other than `plan` and `list`, infer from the **current branch name** (`feature/WEB-1234` → `WEB-1234`). If multiple repos are checked out on different feature branches, ask the user which task is the active one.

**Default operation:** if the user types just `/feature <TASK>` with no operation verb, treat it as `load <TASK>` — i.e., resuming work on an existing feature. If `<TASK>` doesn't have a doc folder yet, suggest `/feature plan <TASK>` instead.

## Canonical workflow

The full backend-feature lifecycle, in order. Each step is a separate user-driven invocation — `/feature` does **not** auto-chain across step boundaries.

1. **`/feature plan <TASK> [<title>]`** — scaffold `Local.Docs/features/<TASK>/README.md` + index entry. Stops after scaffolding; the user picks the next step.
2. *(optional)* **`/web-spike <TASK> [<topic>]`** — web research for vendor APIs, design patterns, library choices, best practices. Writes `web-spike.md`. Skip for pure refactors and patterns already established in this workspace.
3. **`/plan write <TASK>`** — produce `overview.md` calibrated to feature complexity (Trivial / Small / Medium / Large). Reads `README.md` + `web-spike.md` (if present) + any other `research-*.md` companions. Interactive — asks only what cannot be inferred from the inputs.
4. *(optional)* User edits the docs by hand. `pwsh Local.Docs/scripts/commit-docs.ps1 -ShortDescription "<TASK> plan"` to commit the pair (or trio with `web-spike.md`).
5. **`/feature start <TASK>`** — branch `feature/<TASK>` in each affected repo; flips plan doc `Status: in-progress`. **Refuses if `overview.md` does not exist** (points back at `/plan write`).
6. *(implement against `overview.md`; observe the testing + comment rules in [`references/implementation-rules.md`](references/implementation-rules.md))*
7. **`/feature lint <TASK> [--deep]`** — `dotnet build` / `dotnet format` / InspectCode on the changed surface.
8. **`/feature review <TASK>`** — pre-PR review via `/review-gw --branch` + breaking-change scan.
9. *(user pushes branches and opens PRs themselves — `/feature` has no op for this)*
10. **`/feature done <TASK>`** — flip `Status: shipped` after the user's PRs land.

`/feature load <TASK>` is the resume entry point at any point in steps 2–8 or 10.

---

## Operation: `plan`

> **Scaffold-only — no investigation before user approval.**
> The `plan` op writes the template skeleton and stops. Do **not** read git logs, search the codebase, inspect manifests, peek at sibling repos, or otherwise enrich the doc with derived context. The placeholders stay as placeholders. Any facts the user supplied in the invocation arguments may be **quoted verbatim** into the `Goal` paragraph, but do not go fishing for more — that work belongs to `/web-spike` or `/plan write`, which the user invokes once they've reviewed the scaffold.
>
> Why: the user wants to review and edit the skeleton — adjusting scope, repos, framing — *before* expensive investigation locks in a particular framing. Pre-filling the doc from a one-line invocation pre-decides the shape of the feature and wastes context the user may want to redirect.
>
> Allowed reads in this op: only what's needed to (a) check the target folder doesn't already exist, and (b) find and edit the features index. Nothing else.

1. Validate / normalize `<TASK>` to `WEB-NNNN` form.
2. Create folder `Local.Docs/features/<TASK>/`.
3. Create `Local.Docs/features/<TASK>/README.md` with this template — keep all `<...>` placeholders intact except for `<TASK>`, the date, and (optionally) `<Title>` if the user supplied one. Do **not** pre-fill `Goal`, `Scope`, `Affected repos`, `Plan`, `Breaking changes`, `Open questions`, or `Test plan` from your own analysis. If the user supplied a one-line description in the invocation arguments, paste that **verbatim** into the `Goal` paragraph and stop — do not paraphrase, expand, or augment with codebase findings.

   ```markdown
   # <TASK> — <Title>

   **Status:** planning
   **Started:** <YYYY-MM-DD>
   **ClickUp:** https://app.clickup.com/t/<TASK>
   **Affected repos:** _<list once known>_

   ## Goal

   <one paragraph: what user/business outcome this delivers>

   ## Scope

   - In scope:
   - Out of scope:

   ## Affected repos

   For each repo touched, list the area and (if multi-repo) its role.

   - `Tofu.Invoices.Backend` (producer) — _e.g., new gRPC method, repository, domain change_
   - `Invoices.Backend` (consumer / BFF) — _e.g., new controller endpoint that calls the new gRPC method_
   - (others as needed)

   **Cross-repo notes:**
   - Producer / consumer order: _producer ships first; consumer references new contract after producer is deployed._
   - Contract changes: _list any .proto or shared DTO changes; mark additive vs breaking._
   - Mapper updates: _which `Mapping/Mapper.cs` arms need new entries._

   ## Plan

   Numbered, repo-scoped steps that can be ticked off during implementation.

   1. [ ] …
   2. [ ] …

   ## API / DTO changes

   <only if applicable — list new endpoints, request/response shapes, breaking changes>

   ## Breaking changes

   <list anything that could break consumers (other repos, mobile clients, third-party API users) — proto field renumbering, removed/renamed REST endpoints, narrowed types, new required fields, dropped DB columns, changed event payloads, etc. If purely additive, write `None — additive only` so the explicit check is recorded. The `/feature review` op will re-audit this against the actual diff.>

   ## Data / migration

   <only if applicable — new collections, indexes, migrations>

   ## Open questions

   - [ ] …

   ## Test plan

   - Unit tests:
   - Integration tests:
   - Manual verification:
   ```

4. Add an entry to `Local.Docs/features/AGENTS.md` (or `Local.Docs/features/README.md` if that's the index) under the appropriate section, linking to the new folder with a one-line description.
5. **Stop after scaffolding.** Do **not** auto-chain into `/web-spike` or `/plan write`. Tell the user the next steps explicitly:
   - **`/web-spike <TASK> [<topic>]`** — *(optional)* web research for vendor APIs, design patterns, library choices, or best practices. Recommended when the feature has unresolved architectural questions or net-new patterns. Writes `web-spike.md`.
   - **`/plan write <TASK>`** — produce the implementation plan (`overview.md`). Reads `README.md` + `web-spike.md` (if present) + any other `research-*.md` companions. Interactive.

   Why no auto-chain: `/web-spike` and `/plan write` are independently expensive (web fetches, interactive question batches) and not every feature needs `/web-spike`. Letting the user pick keeps the workflow honest. The user can choose to run `/plan write` immediately for trivial refactors, or `/web-spike` first for anything with architectural unknowns.

6. Inform the user that `README.md` is on disk — do **NOT** auto-commit. Suggest committing once `web-spike.md` (if produced) and `overview.md` are also done, via `pwsh Local.Docs/scripts/commit-docs.ps1 -ShortDescription "<TASK> plan"`.

The `Affected repos` list is the source of truth for which repos `start`, `lint`, `review` operate on. If it is empty, ask the user before any subsequent op.

## Ad-hoc spike / sub-plan docs inside a feature folder

When the user asks to **add** a spike, research, or sub-plan doc inside an existing feature folder (e.g., *"add storage-spike-plan doc"*, *"add a research doc on X"*, *"create a sub-plan for Y"*) — i.e., anything that is not `README.md`, `overview.md`, or `web-spike.md` (those have their own ops):

1. **Create the file empty.** Just `Write` the path with empty content (`""`). Do **not** draft an Overview, do **not** draft Steps, do **not** mirror the shape of neighbouring `*-spike-plan.md` files, do **not** pre-fill placeholders inferred from the filename.
2. Tell the user the file is on disk and waiting for them to fill in. Mention that nothing else was touched.
3. Stop. Do **not** auto-commit. Do **not** add an entry to `steps.md`, `README.md`, or any index — the user wires the doc in themselves once they have written its content.

Why: these ad-hoc docs are the user's framing of what to investigate next, and the framing is the whole value. Guessing the shape from the filename alone (e.g., inferring what "storage-spike" means) pre-decides scope the user has not committed to, and any draft will be immediately overwritten. This is the same scaffold-only principle as `Operation: plan`, applied to one-off docs inside an existing feature folder.

If the user **explicitly** asks for a draft (*"draft the overview"*, *"fill it in"*, *"propose steps"*, *"write a first cut"*), then draft. The empty-file default applies only to a bare *"add &lt;name&gt; doc"* style request.

## Pulling Local.Docs

`load` and `start` both refresh `Local.Docs` before reading the plan, so we work from the latest version that teammates may have edited. The flow:

1. `cd Local.Docs`
2. Capture state: `git status --porcelain` and `git symbolic-ref --short HEAD`.
3. **Skip pulling** in any of these cases — the user is mid-edit or on a non-default branch — and instead surface a one-line warning so they can decide what to do:
   - Working tree is dirty (uncommitted changes) **inside `Local.Docs` itself**.
   - Currently on a branch other than the default (typically `main`).
   - There are local commits not yet pushed.

   **Ignore** a dirty `Local.Docs` *submodule pointer* in the parent backend repos (a ` M Local.Docs` line from `git status` in `Invoices.Backend` / `Tofu.Invoices.Backend` / `Tofu.Auth.Backend`). That's just a stale gitlink from prior work, not a Local.Docs edit — it does not block any `/feature` op. Likewise, do not try to "fix" it by resetting the submodule pointer; leave it for the user to manage.
4. Otherwise: `git fetch origin && git pull --ff-only origin main`. If the pull is not fast-forward, abort and surface the divergence — never merge or rebase silently.
5. Report what was pulled (e.g., "Local.Docs: pulled 3 new commits, plan doc updated" or "Local.Docs: already up to date" or "Local.Docs: skipped — working tree dirty, working from local copy").

This is best-effort: a failed pull (network error, etc.) should not block `load`/`start` — log the failure and continue with the local copy.

## Operation: `load`

Load an existing feature into the current conversation context. Use this when resuming work on a feature that was previously planned (and possibly partially implemented).

1. Validate / normalize `<TASK>` to `WEB-NNNN` form.
2. **Pull latest in `Local.Docs`** so the plan doc reflects what other team members may have edited (see "Pulling Local.Docs" above).
3. Verify `Local.Docs/features/<TASK>/README.md` exists.
   - If it does **not** exist: do not invent one. Tell the user "no plan doc for `<TASK>` found at `Local.Docs/features/<TASK>/`" and offer `/feature plan <TASK>` to start one.
4. Read the entire plan doc.
5. Read any other markdown files in the same folder (e.g., `API.md`, design notes) — features sometimes have multiple docs in their folder.
6. Summarize for the user, in this shape:

   ```
   # WEB-1234 — <Title>
   Status: <status from doc> | Started: <date>
   Affected repos: <list>

   ## Goal
   <one-line summary of the goal section>

   ## Plan progress
   <count of [x] vs [ ] checkboxes, then list the unchecked items so the user knows what's left>

   ## Branch state
   <for each affected repo: is feature/<TASK> checked out? does it exist remotely? ahead/behind base?>

   ## Open questions
   <copy from the doc if any are unresolved>
   ```

7. Surface anything inconsistent: the doc says `Status: in-progress` but no `feature/<TASK>` branch exists in any repo; the doc lists repos that don't exist; remote branches exist but the local checkout is on a different branch; etc.

8. After loading, the feature becomes the **active feature** for subsequent ops in this conversation — `/feature lint`, `/feature review`, `/feature done` will default to this `<TASK>` even when omitted.

Do **not** modify any files in `load`. It's a read-only resume operation.

## Operation: `list`

1. List directories under `Local.Docs/features/` that match the `WEB-NNNN` pattern (skip `AGENTS.md`, `README.md`, and other non-feature entries).
2. For each, read just the front-matter / first ~30 lines of the README to extract `Status:`, `Started:`, `Affected repos:`, and the title.
3. Output as a table sorted by status (in-progress first, then planning, then shipped):

   ```
   | TASK | Status | Title | Affected repos | Started |
   |---|---|---|---|---|
   ```

4. Highlight any feature whose `Status` says `in-progress` but for which no local `feature/<TASK>` branch exists in any repo (likely abandoned or someone else's work).

This is a read-only inventory op — never modifies anything.

## Operation: `start`

1. **Pull latest in `Local.Docs`** before reading the plan (see "Pulling Local.Docs" above) — same reason as `load`: the plan may have been edited by someone else since you last pulled.
2. **Gate on `overview.md` existing.** If `Local.Docs/features/<TASK>/overview.md` is missing, refuse to branch and tell the user to run `/plan write <TASK>` first — implementing without the deepened plan is the failure mode this gate exists to prevent. The user may override with an explicit "skip overview" or "branch anyway" in their invocation; otherwise stop here.
3. Read `Local.Docs/features/<TASK>/README.md`. Extract the `Affected repos` list.
4. For each affected repo:
   - `cd <repo>; git fetch origin`
   - Determine base branch — **the default differs per repo** in this workspace, so always resolve it dynamically rather than assuming `main`. Read `git symbolic-ref refs/remotes/origin/HEAD` (preferred — purely local, no network) or fall back to `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`. Known defaults at time of writing:
     - `Invoices.Backend` → **`master`**
     - `Tofu.Invoices.Backend` → `main`
     - `Tofu.Auth.Backend` → `main`
     - `Tofu.Common.Backend` → `main`
     - `Local.Docs` → `main`
   - `git checkout -b feature/<TASK> --no-track origin/<base>` (or `git checkout feature/<TASK>` if it already exists locally).
     **Use `--no-track`** — without it, the new local branch silently auto-tracks `origin/<base>`. Later `git push` then fails with *"upstream branch of your current branch does not match the name of your current branch"* because git correctly refuses to push the local feature branch onto the base branch. With `--no-track` the upstream stays unset until the user's first `git push -u origin feature/<TASK>` wires it correctly. (`/feature` never pushes — that step is always manual.)
     If you discover a feature branch already created with the wrong upstream, the user can fix it by running `git push -u origin feature/<TASK>` — that creates the remote branch and re-points tracking in one command. No need to delete and recreate.
5. Update the plan doc to set `Status: in-progress` and add a `## Branches` section listing each repo and its branch (so we can find them later without scanning).
6. Print the numbered plan items from `overview.md`'s implementation surface as a checklist for the user to work through.

Do not modify any source code in this op — just branches and the plan doc's status line.

## Operation: `status`

1. Resolve `<TASK>` (arg or current branch).
2. For each affected repo:
   - Print: current branch, ahead/behind base, dirty files count, count of unpushed commits.
3. Flag any repo that is **not** on `feature/<TASK>` — usually a sign that work was started on the wrong branch.

## Operation: `lint`

Read [`references/lint.md`](references/lint.md) and follow it. Summary: fast pass = `dotnet build` (TreatWarningsAsErrors) + `dotnet format --verify-no-changes` + `dotnet format analyzers` per affected repo; `--deep` adds JetBrains InspectCode scoped to the feature-branch diff only (never whole-solution). The reference holds the exact commands, the Rider-MSBuild workaround, and the reporting format.

## Operation: `review`

Read [`references/review.md`](references/review.md) and follow it. Summary: per affected repo, invoke `/review-gw` in `--branch` mode against the dynamically-resolved base branch, **always** run the breaking-change scan (its category table and output format are in the reference), and aggregate findings into one report with sections per repo. Run before the user opens PRs.

## Operation: `done`

1. Verify all affected-repo PRs are merged (`gh pr view <num> --json state -q .state`).
2. Update plan doc: `Status: shipped`, add `**Shipped:** <date>` line, tick remaining checkboxes that the user confirms are done.
3. Suggest committing the doc update via `/docs commit "ship <TASK>"`.

---

## Multi-repo features

Most non-trivial features touch more than one repo. Producer/consumer ordering, contract-change rules, PR cross-linking, the PR-body template, and out-of-sync handling live in [`references/multi-repo.md`](references/multi-repo.md) — read it whenever the `Affected repos` list has more than one entry, and before the user opens PRs.

## Implementation rules

While implementing (step 6 of the canonical workflow), two discipline rules apply — integration-test coverage for every behavior change and single-line rationale comments for non-obvious business logic. Both are specified in [`references/implementation-rules.md`](references/implementation-rules.md).

## Conventions

- **Slug everywhere:** `<TASK>` (e.g., `WEB-1234`) is identical in: doc folder name, branch name (`feature/<TASK>`), commit message prefix (`<TASK>: …`), PR title prefix.
- **Plan doc is source of truth** for `Affected repos`. Operations that span repos (`start`, `lint`, `review`) read this list — keep it accurate.
- **Never auto-commit. Never push. Never open or update PRs.** `/feature` does not run `git commit`, `git push`, `gh pr create`, `gh pr edit`, or any other publishing command. Plan-doc changes go through `/docs commit` (which the user invokes); code commits, branch pushes, and PR lifecycle are entirely the user's responsibility.
- **Never force-push.** Never push to `main`/base.
- **One feature per branch per repo.** If a repo isn't touched by the feature, it doesn't get a `feature/<TASK>` branch.
- **Local.Docs PR is separate.** Each backend repo gets its own PR; the plan doc lives in Local.Docs and is committed/PRed there independently — the user opens that PR too.

## Notes

- The four backend repos (`Invoices.Backend`, `Tofu.Invoices.Backend`, `Tofu.Auth.Backend`, `Tofu.Common.Backend`) are **independent git repositories** — every git/`gh` command runs inside the target repo's folder.
- Default repo when only one is touched and the user does not specify: `Invoices.Backend` (BFF, main repo).
- For the doc-side flow (creating, updating, committing the plan), `/feature` shells out to the same primitives `/docs` uses — keep them consistent.
- For PR-side review, the existing `/review-gw <PR#>` works after PRs are open. Use `/feature review` (which calls `/review-gw --branch`) for **pre-PR** review on the local feature branch.
- Do not invent a new ClickUp task; if one doesn't exist, ask the user to create it first and pass its ID. The task ID is the feature's identity.
