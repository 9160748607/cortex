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
   the value is that a NEW unexpected entry here means a NEW problem.        */

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
