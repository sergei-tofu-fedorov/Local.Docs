# /feature lint — commands, InspectCode recipe, reporting

For each affected repo:

## Default (fast)

```powershell
cd <repo>
dotnet build --nologo -clp:NoSummary /p:TreatWarningsAsErrors=true
dotnet format --verify-no-changes --no-restore
dotnet format analyzers --verify-no-changes --no-restore
```

- `dotnet build` with `TreatWarningsAsErrors` is already configured in these repos — surfaces compile warnings as failures.
- `dotnet format` enforces whitespace / .editorconfig rules.
- `dotnet format analyzers` runs Roslyn analyzers (the same squiggles Rider shows in the editor).

Capture the output, summarize: failures per repo, top warning categories, file:line references.

## `--deep` (JetBrains InspectCode — full Rider/ReSharper inspection)

If the user passes `--deep`:

```powershell
# One-time install if missing:
dotnet tool list -g | Select-String "jetbrains.resharper.globaltools" ; if ($LASTEXITCODE) { dotnet tool install -g JetBrains.ReSharper.GlobalTools }

# Resolve base branch dynamically (see "Operation: start" in SKILL.md — Invoices.Backend → master, others → main).
# Use plain `origin/$base` (not `origin/$base...HEAD`) so uncommitted working-tree changes are also covered —
# we want what the user is about to PR, including not-yet-committed edits.
cd <repo>
$base = (git symbolic-ref refs/remotes/origin/HEAD).Split('/')[-1]
$changed = git diff "origin/$base" --name-only --diff-filter=ACMR -- '*.cs' | Where-Object { $_ }
if (-not $changed) { Write-Host "No changed C# files; skipping InspectCode."; return }
# Use **\<basename> globs — InspectCode 2026.1 ignores absolute/relative paths in --include reliably.
$includeArg = (($changed | ForEach-Object { "**\" + (Split-Path $_ -Leaf) }) -join ';')

# Point InspectCode at Rider's bundled MSBuild — sidesteps the MSB4236 / WorkloadAutoImportPropsLocator
# error that hits the .NET 8 SDK MSBuild on this workspace. Rider install path is per-user.
$riderMsBuild = "$env:LOCALAPPDATA\Programs\Rider\tools\MSBuild\Current\Bin\amd64\MSBuild.exe"
# NuGetAudit is enabled in these repos and fails restore on a moderate OpenTelemetry advisory; disable for the inspection only.
$reportPath = Join-Path $env:TEMP "inspect-<TASK>-$(Get-Date -Format yyyyMMddHHmmss).sarif"
jb inspectcode <Solution>.sln `
    --toolset-path="$riderMsBuild" `
    --output="$reportPath" `
    --severity=WARNING `
    --no-swea `
    --include="$includeArg" `
    --properties:NuGetAudit=false

# Parse, summarize, delete — never leave the report inside the repo working tree
$report = Get-Content $reportPath -Raw | ConvertFrom-Json
# … iterate $report.runs[0].results, group by file, filter to changed-files-only, surface to user …
Remove-Item $reportPath
```

**Environment notes (lessons learned):**
- The standalone `JetBrains.ReSharper.GlobalTools` 2026.1 fails on .NET SDK 8.0.420 with `[MSB4236] The SDK 'Microsoft.NET.SDK.WorkloadAutoImportPropsLocator' specified could not be found` followed by "No files to inspect were found." Pointing `--toolset-path` at Rider's bundled MSBuild fixes it (Rider doesn't ship `inspectcode.exe` itself, but its MSBuild has the right workload manifests). See JetBrains YouTrack RIDER-97292 / RIDER-97058.
- Drop `--no-build` — InspectCode's project load happens before its own build step, so `--no-build` doesn't help and just hides legitimate restore failures.
- `--include` does not accept absolute paths reliably; use basename globs (`**\Foo.cs`).
- Output is **SARIF JSON** despite the `.xml` extension — parse via `ConvertFrom-Json` in PowerShell, not XML tooling.

Rules:
- **Scope is feature-branch diff only.** Build the `--include` list from `git diff origin/<base>...HEAD --name-only` filtered to `*.cs` (plus any project files that changed). Never run InspectCode against the whole solution — it is slow, and unrelated pre-existing warnings drown out the ones the feature actually introduced.
- If the diff contains no C# changes for a repo, skip InspectCode for that repo and report "no C# changes — skipped".
- Slow (~30–120s per repo when scoped to a feature; whole-solution runs are 5–15× longer — do not do that).
- Parse the report inline, summarize issues by file restricted to the changed-files set, then **delete it**. Never leave the report inside the repo working tree — there is nothing to gain from keeping a stale snapshot, and it is too easy to stage accidentally. Write it to `$env:TEMP` to make accidental staging impossible.

If `JetBrains.ReSharper.GlobalTools` is not installed, ask the user before installing globally — do not install silently.

## Reporting

After running, output:

```
## Lint summary — WEB-1234

| Repo | Build warnings | Format issues | Analyzer issues | Verdict |
|------|---:|---:|---:|---|
| Invoices.Backend | 0 | 2 | 5 | :yellow_circle: |
| Tofu.Invoices.Backend | 0 | 0 | 0 | :green_circle: |
```

Then list the actual issues with `file.cs:line — message` entries, top 20.
