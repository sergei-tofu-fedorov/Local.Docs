# Sync Claude Code skills from this repo (canonical) into the workspace .claude/skills/ (runtime copy).
# Direction: Local.Docs/Claude/skills/* -> C:\Git\Work\Backend\.claude\skills\*  (one-way, mirrors per skill dir).
# Run after editing skills in the repo:  pwsh Local.Docs/scripts/sync-claude-skills.ps1

$src = Join-Path $PSScriptRoot "..\Claude\skills"
$dst = "C:\Git\Work\Backend\.claude\skills"

Get-ChildItem -Directory $src | ForEach-Object {
    robocopy $_.FullName (Join-Path $dst $_.Name) /MIR /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Error "robocopy failed for $($_.Name) (exit $LASTEXITCODE)" }
    else { Write-Host "synced: $($_.Name)" }
}
