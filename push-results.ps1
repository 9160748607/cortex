# Commits everything under results/ and pushes to origin/main.
# Usage: .\push-results.ps1 [-Message "optional commit message"]
param(
    [string]$Message
)

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repo

git add results/
if (-not (git diff --cached --name-only)) {
    Write-Host "No new or changed result files to commit."
    exit 0
}

if (-not $Message) {
    $files = (git diff --cached --name-only) -join ", "
    $Message = "Add query results: $files"
}

git commit -q -m $Message
git push -u origin main
