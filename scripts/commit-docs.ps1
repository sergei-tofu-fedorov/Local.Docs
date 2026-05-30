param(
    [string]$ShortDescription
)

$ErrorActionPreference = "Stop"

# Paths
$scriptRoot = $PSScriptRoot
$submoduleRoot = Split-Path $scriptRoot -Parent
$parentRoot = Split-Path $submoduleRoot -Parent

if (-not (Test-Path $parentRoot)) {
    Write-Host "Parent repository root not found. Aborting."
    exit 1
}

# Resolve parent repo info
try {
    $branchName = git -C $parentRoot rev-parse --abbrev-ref HEAD
} catch {
    Write-Host "Failed to get parent repo branch name. Ensure git is installed and this is a git repo."
    exit 1
}

$parentRepoName = Split-Path $parentRoot -Leaf

if (-not $ShortDescription) {
    $ShortDescription = Read-Host "Enter short description of docs change"
}

if (-not $ShortDescription) {
    Write-Host "No description provided. Aborting."
    exit 1
}

$commitMessage = "$branchName | $parentRepoName | $ShortDescription"

# Check for changes in the docs submodule
$status = git -C $submoduleRoot status --porcelain
if (-not $status) {
    Write-Host "No changes in Local.Docs to commit."
    exit 0
}

Write-Host "Committing docs changes in Local.Docs with message:"
Write-Host "  $commitMessage"

git -C $submoduleRoot add .
git -C $submoduleRoot commit -m "$commitMessage"

# Always push docs changes to the main branch in the Local.Docs repo
$targetBranch = "main"

Write-Host "Pushing docs changes to origin/$targetBranch from current commit (HEAD)."
git -C $submoduleRoot push origin HEAD:$targetBranch
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to push docs changes to origin/$targetBranch."
    Write-Host "You can push manually with:"
    Write-Host "  git -C `"$submoduleRoot`" push origin HEAD:$targetBranch"
    exit 1
}

Write-Host "Docs changes committed and pushed successfully to origin/$targetBranch."
