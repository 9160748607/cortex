# ---------------------------------------------------------------------------
# Stage upload - Snowflake CoCo / snow CLI (Windows PowerShell)
#
# Uploads the store master Parquet source files to the internal stage. READ-ONLY
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
  [string] $SourceDir  = "C:\Users\X1Carbon\Music\store-master-testing\parquet",
  [string] $Connection = "ysirciu-vg28332",
  [string] $StagePath  = "@ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/"
)

# The snow CLI writes a benign "Encoding mismatch detected" UserWarning to
# stderr. PowerShell escalates any native stderr output into a NativeCommandError
# and aborts the script, even though the upload succeeded. Continue past it and
# judge success from the UPLOADED/SKIPPED status in stdout instead.
$ErrorActionPreference = 'Continue'

$files = @(
  'store_master.parquet',    # 22 columns - baseline
  'store_master_1.parquet'   # 23 columns - additive drift (+Status) AND two type drifts
)

Write-Host "Source     : $SourceDir"
Write-Host "Stage      : $StagePath"
Write-Host "Connection : $Connection`n"

foreach ($f in $files) {
  $full = Join-Path $SourceDir $f
  if (-not (Test-Path $full)) { Write-Warning "MISSING, skipped: $f"; continue }

  # NOTE: no --auto-compress. Parquet is already a compressed columnar container;
  # the CLI reports source_compression = PARQUET and passes it through. Gzipping
  # it would waste cycles and defeat predicate pushdown on read.
  #
  # Per-file invocation, not a *.parquet glob: PowerShell expands globs before
  # snow sees them, which breaks the argument.
  $out = snow stage copy "$full" "$StagePath" --connection $Connection --overwrite 2>&1 |
         Out-String -Width 250
  $status = if ($out -match 'UPLOADED') { 'UPLOADED' }
            elseif ($out -match 'SKIPPED') { 'SKIPPED' }
            else { 'FAILED' }
  Write-Host ("{0,-28} {1}" -f $f, $status)
  if ($status -eq 'FAILED') { Write-Host $out }
}

# ---------------------------------------------------------------------------
# No local pre-check is offered here, deliberately.
#
# Parquet is a binary columnar container - it cannot be inspected with
# Get-Content, a regex, or ConvertFrom-Json the way the CSV and JSON sources
# could. Reading its embedded schema locally would mean installing pyarrow or
# parquet-tools.
#
# Snowflake's INFER_SCHEMA reads the embedded schema server-side without scanning
# the data, so schema inspection happens in 02_schema_detection.sql instead.
# IMPORTANT: pair it with the TYPEOF cross-check in section 2.3 - on Parquet,
# INFER_SCHEMA reports the PHYSICAL type and can disagree with what you actually
# get on read (it reported NUMBER(38,0) for a column that reads as TIMESTAMP_NTZ).
# ---------------------------------------------------------------------------

# Verify from Snowflake's side, and confirm the sources are untouched.
Write-Host "`n--- staged files ---"
snow sql -q "LIST $StagePath" --connection $Connection 2>&1 |
  Select-String -Pattern 'store_master' | Out-String -Width 250

Write-Host "--- source folder (must be unchanged) ---"
Get-ChildItem $SourceDir | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
