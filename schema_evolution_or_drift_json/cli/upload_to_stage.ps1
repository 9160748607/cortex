# ---------------------------------------------------------------------------
# Stage upload - Snowflake CoCo / snow CLI (Windows PowerShell)
#
# Uploads the store master JSON source files to the internal stage. READ-ONLY
# on the source folder: `snow stage copy` opens files for reading and PUTs them.
# The originals are never modified, renamed or deleted.
#
# Run 01_create_objects.sql FIRST - the stage must exist.
#
# Usage:
#   .\upload_to_stage.ps1
#   .\upload_to_stage.ps1 -SourceDir "D:\other\path" -Connection my_conn
# ---------------------------------------------------------------------------

param(
  [string] $SourceDir  = "C:\Users\X1Carbon\Music\store-master-testing\json_data",
  [string] $Connection = "ysirciu-vg28332",
  [string] $StagePath  = "@ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/"
)

# The snow CLI writes a benign "Encoding mismatch detected" UserWarning to
# stderr. PowerShell escalates any native stderr output into a NativeCommandError
# and aborts the script, even though the upload succeeded. Continue past it and
# judge success from the UPLOADED/SKIPPED status in stdout instead.
$ErrorActionPreference = 'Continue'

$files = @(
  'store_master.json',                # 22 keys - baseline
  'store_master_columns_added.json'   # 23 keys - additive drift (+Status)
)

Write-Host "Source     : $SourceDir"
Write-Host "Stage      : $StagePath"
Write-Host "Connection : $Connection`n"

foreach ($f in $files) {
  $full = Join-Path $SourceDir $f
  if (-not (Test-Path $full)) { Write-Warning "MISSING, skipped: $f"; continue }

  # Per-file invocation, not a *.json glob: PowerShell expands globs before snow
  # sees them, which breaks the argument.
  $out = snow stage copy "$full" "$StagePath" --connection $Connection --overwrite 2>&1 |
         Out-String -Width 250
  $status = if ($out -match 'UPLOADED') { 'UPLOADED' }
            elseif ($out -match 'SKIPPED') { 'SKIPPED' }
            else { 'FAILED' }
  Write-Host ("{0,-40} {1}" -f $f, $status)
  if ($status -eq 'FAILED') { Write-Host $out }
}

# ---------------------------------------------------------------------------
# Optional local pre-check for the NaN defect.
#
# Do NOT trust ConvertFrom-Json as a validator - it ACCEPTS the invalid NaN
# literal these files contain and reports them as valid JSON. A plain text
# search is the reliable local check.
# ---------------------------------------------------------------------------
Write-Host "`n--- NaN literal scan (NaN is NOT valid JSON) ---"
foreach ($f in $files) {
  $full = Join-Path $SourceDir $f
  if (-not (Test-Path $full)) { continue }
  $n = ([regex]::Matches((Get-Content $full -Raw), '\bNaN\b')).Count
  $verdict = if ($n -gt 0) { "$n NaN literal(s) - handled by file-format NULL_IF" } else { 'clean' }
  Write-Host ("{0,-40} {1}" -f $f, $verdict)
}

# Verify from Snowflake's side, and confirm the sources are untouched.
Write-Host "`n--- staged files ---"
snow sql -q "LIST $StagePath" --connection $Connection 2>&1 |
  Select-String -Pattern 'store_master' | Out-String -Width 250

Write-Host "--- source folder (must be unchanged) ---"
Get-ChildItem $SourceDir | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
