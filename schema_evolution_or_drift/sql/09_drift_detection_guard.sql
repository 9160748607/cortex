/* ===========================================================================
   09 - Pre-load drift detection guard
   ---------------------------------------------------------------------------
   Snowflake raises NOTHING when a source file loses columns. This is the gate
   that supplies the missing alert. Run it BEFORE every COPY.

   Additive drift is self-announcing - the table grows, and you can diff
   INFORMATION_SCHEMA before and after. Subtractive drift is not: the load
   succeeds, the structure is unchanged, and the only trace is NULLs that look
   exactly like legitimately missing values. Detection must therefore happen
   BEFORE the load, by comparing the incoming header to the target.

   Swap the two placeholders per file:
     <STAGE_PATH>    e.g. @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_2_deleted_columns.csv
     <FILE_FORMAT>   ff_store_master_iso  or  ff_store_master_eu
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- 9.1 SUBTRACTIVE drift check: target columns the incoming file does NOT have.
-- Any row returned = columns will be silently NULLed. Abort or alert.
-- Audit columns are excluded - they never come from the file.
-- ---------------------------------------------------------------------------
SELECT c.COLUMN_NAME AS missing_from_incoming_file
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_SCHEMA = 'DATA_MIGRATION'
  AND c.TABLE_NAME   = 'STORE_MASTER'
  AND c.COLUMN_NAME NOT LIKE '\_\_%'          -- skip __file_name etc.
  AND c.COLUMN_NAME NOT IN (
        SELECT UPPER(COLUMN_NAME)
        FROM TABLE(INFER_SCHEMA(
          LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_2_deleted_columns.csv',
          FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu'))
      )
ORDER BY 1;
/* For store_master_2_deleted_columns.csv this returns the 6 dropped columns:
     ADDRESS_LINE1, CITY, FORMAT_CODE, LATITUDE, POSTAL_CODE, STATE_CODE
   plus MANAGER_NAME / EMPLOYEE_COUNT (evolved earlier, never in this file).
   Treat a non-empty result as a pipeline failure or a reviewed exception -
   never as noise to ignore.                                                 */

-- ---------------------------------------------------------------------------
-- 9.2 ADDITIVE drift check: file columns the target does NOT yet have.
-- These WILL be auto-added by evolution. Review the inferred precision -
-- see the EMPLOYEE_COUNT NUMBER(2,0) trap in 08_validation.sql section 8.1.
-- ---------------------------------------------------------------------------
SELECT UPPER(f.COLUMN_NAME) AS new_column_to_be_added, f.TYPE AS inferred_type
FROM TABLE(INFER_SCHEMA(
       LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_1.csv',
       FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')) f
WHERE UPPER(f.COLUMN_NAME) NOT IN (
        SELECT COLUMN_NAME FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA='DATA_MIGRATION' AND TABLE_NAME='STORE_MASTER')
ORDER BY 1;
-- -> STATUS  BOOLEAN   (before load 2; empty afterwards)

-- ---------------------------------------------------------------------------
-- 9.3 TYPE drift check: shared column whose inferred type disagrees with the
-- target. Evolution will NOT fix these - they either fail the COPY or coerce
-- silently, so they need a human decision (a per-file DATE_FORMAT, a VARCHAR
-- landing column, etc.).
-- ---------------------------------------------------------------------------
SELECT UPPER(f.COLUMN_NAME) AS column_name,
       f.TYPE               AS inferred_in_file,
       c.DATA_TYPE          AS declared_in_target
FROM TABLE(INFER_SCHEMA(
       LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_1.csv',
       FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')) f
JOIN ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS c
  ON c.COLUMN_NAME = UPPER(f.COLUMN_NAME)
 AND c.TABLE_SCHEMA='DATA_MIGRATION' AND c.TABLE_NAME='STORE_MASTER'
WHERE SPLIT_PART(f.TYPE,'(',1) <> c.DATA_TYPE
  AND NOT (f.TYPE = 'TEXT' AND c.DATA_TYPE = 'TEXT')
ORDER BY 1;
/* Flags postal_code (NUMBER vs TEXT), the three date columns (TEXT vs DATE)
   and created_at (TEXT vs TEXT-by-design). Expected and already handled -
   the value is that a NEW unexpected entry here means a NEW problem.

   *** THIS CHECK OVER-REPORTS - PREFER 9.5 ***
   Run against store_master_3_datatypechange...csv it returned FIVE "BLOCKING"
   rows, but only ONE was real:
     FLOOR_AREA_SQFT       genuine - the literal 'testing' in a NUMBER column
     STORE_OPEN_DATE       FALSE POSITIVE - day-first dates that the file
     EFFECTIVE_START_DATE  FALSE POSITIVE   format's DATE_FORMAT converts
     EFFECTIVE_END_DATE    FALSE POSITIVE   perfectly
     STORE_CLOSE_DATE      FALSE POSITIVE - 100% empty, nothing to convert
   Comparing INFER_SCHEMA's guess to the declared type ignores the file format's
   DATE_FORMAT, so every day-first date column looks broken. A guard that cries
   wolf four times out of five gets muted, which is worse than no guard.
   9.5 tests the VALUES instead and returns exactly one row.                  */

-- ---------------------------------------------------------------------------
-- 9.4 Duplicate business key pre-check.
-- COPY load history is keyed on FILE NAME, not business key, so a renamed
-- re-export of already-loaded rows will load again and duplicate them. This is
-- exactly what store_master_2_deleted_columns.csv did.
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS incoming_keys_already_present
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER t
WHERE t.store_code IN (
  SELECT $1
  FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_2_deleted_columns.csv
       (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_inspect')
);
-- Non-zero => use the MERGE in 10_idempotent_merge_fix.sql, not COPY.

-- ---------------------------------------------------------------------------
-- 9.5 CASTABILITY PROBE - the accurate type-drift guard. PREFER THIS OVER 9.3.
--
-- Tests the actual VALUES against the target type using TRY_TO_*, rather than
-- comparing INFER_SCHEMA's guess to the declared type. This respects the file
-- format's DATE_FORMAT, so correctly-converting day-first dates report 0 and
-- only genuine failures surface.
--
-- Run against store_master_3_datatypechange...csv it returns exactly one
-- non-zero row - FLOOR_AREA_SQFT, 2 uncastable - versus 9.3's five.
--
-- The IS NOT NULL guard matters: a NULL is legitimately absent data, not a
-- cast failure, and must not be counted as drift.
--
-- Extend one UNION ALL branch per typed target column. Swap the two
-- placeholders and keep the positional $n aligned with the file's header.
-- ---------------------------------------------------------------------------
WITH raw AS (
  SELECT $11 AS latitude, $12 AS longitude, $13 AS store_open_date,
         $16 AS floor_area_sqft, $17 AS annual_rent_usd,
         $19 AS effective_start_date, $20 AS effective_end_date
  FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_3_datatypechange_numberdatasendingtextinafile.csv
       (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_inspect')
)
SELECT 'FLOOR_AREA_SQFT' AS column_name, 'NUMBER' AS target_type,
       COUNT(*) AS rows_present, COUNT(floor_area_sqft) AS non_null,
       SUM(IFF(floor_area_sqft IS NOT NULL
               AND TRY_TO_NUMBER(floor_area_sqft) IS NULL,1,0)) AS uncastable FROM raw
UNION ALL SELECT 'ANNUAL_RENT_USD','NUMBER',COUNT(*),COUNT(annual_rent_usd),
       SUM(IFF(annual_rent_usd IS NOT NULL
               AND TRY_TO_NUMBER(annual_rent_usd,14,2) IS NULL,1,0)) FROM raw
UNION ALL SELECT 'LATITUDE','NUMBER',COUNT(*),COUNT(latitude),
       SUM(IFF(latitude IS NOT NULL
               AND TRY_TO_NUMBER(latitude,12,6) IS NULL,1,0)) FROM raw
UNION ALL SELECT 'LONGITUDE','NUMBER',COUNT(*),COUNT(longitude),
       SUM(IFF(longitude IS NOT NULL
               AND TRY_TO_NUMBER(longitude,12,6) IS NULL,1,0)) FROM raw
UNION ALL SELECT 'STORE_OPEN_DATE','DATE',COUNT(*),COUNT(store_open_date),
       SUM(IFF(store_open_date IS NOT NULL
               AND TRY_TO_DATE(store_open_date,'DD-MM-YYYY') IS NULL,1,0)) FROM raw
UNION ALL SELECT 'EFFECTIVE_START_DATE','DATE',COUNT(*),COUNT(effective_start_date),
       SUM(IFF(effective_start_date IS NOT NULL
               AND TRY_TO_DATE(effective_start_date,'DD-MM-YYYY') IS NULL,1,0)) FROM raw
UNION ALL SELECT 'EFFECTIVE_END_DATE','DATE',COUNT(*),COUNT(effective_end_date),
       SUM(IFF(effective_end_date IS NOT NULL
               AND TRY_TO_DATE(effective_end_date,'DD-MM-YYYY') IS NULL,1,0)) FROM raw
ORDER BY uncastable DESC, column_name;

/* Recorded result for store_master_3_datatypechange...csv:
     FLOOR_AREA_SQFT       NUMBER  5  5  2   <- ONLY real failure
     ANNUAL_RENT_USD       NUMBER  5  5  0
     EFFECTIVE_START_DATE  DATE    5  5  0
     EFFECTIVE_END_DATE    DATE    5  5  0
     LATITUDE              NUMBER  5  5  0
     LONGITUDE             NUMBER  5  5  0
     STORE_OPEN_DATE       DATE    5  5  0

   Any uncastable > 0 means a plain COPY into the typed target WILL fail with
   ABORT_STATEMENT. Route that file through the quarantine pattern in
   11_load_file4_type_drift.sql - do NOT reach for ON_ERROR = CONTINUE, which
   converts a visible failure into silent row loss.                           */
