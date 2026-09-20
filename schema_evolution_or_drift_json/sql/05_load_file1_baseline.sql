/* ===========================================================================
   05 - LOAD 1 of 2: baseline load, no drift
   ---------------------------------------------------------------------------
   File   : store_master.json     (22 keys, 121 records)
   Before : table 26 columns, 0 rows
   After  : table 26 columns, 121 rows      -> NO evolution event
   Result : LOADED, rows_parsed 121, rows_loaded 121, errors_seen 0

   Establishes the baseline. The file's keys match the table exactly, so nothing
   evolves - which is the point: evolution must not fire spuriously.

   MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
     Binds by JSON KEY NAME. For JSON this is not merely convenient, it is the
     only sane option: INFER_SCHEMA returns keys alphabetically and JSON object
     key order carries no meaning, so there is no ordinal to bind to.
     CASE_INSENSITIVE is chosen because FILE 2 ships `Status` capitalised while
     every other key is lower snake_case.
     It also NULL-fills any table column a record omits - which is requirement
     "missing key -> NULL" satisfied by the engine, not by our SQL.

   INCLUDE_METADATA
     The only way to capture METADATA$ pseudo-columns alongside
     MATCH_BY_COLUMN_NAME - the transformation form
     COPY INTO ... FROM (SELECT ...) cannot be combined with it. That
     restriction is also why the NaN problem had to be solved declaratively in
     the file format rather than with a cast. See 04.

   ON_ERROR = ABORT_STATEMENT, not CONTINUE
     A partially loaded dimension is worse than no load: plausible-looking but
     incomplete reference data that nothing downstream flags. Fail visibly.
     This setting is what surfaced the NaN defect at all - with CONTINUE the
     file would have silently produced 0 rows.

   Idempotency: COPY load history is keyed on FILE NAME, so re-running is a
   no-op for files already loaded. FORCE = TRUE deliberately omitted.
   BEWARE: that key is the filename, NOT the business key - FILE 2 re-exports
   the same five stores under a different filename and loads again. See 09.
   =========================================================================== */

COPY INTO ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master.json
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;

-- Expect 121 rows / 121 distinct keys.
SELECT COUNT(*) AS row_cnt, COUNT(DISTINCT store_code) AS distinct_stores
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER;

-- Leading zeros survived, because JSON quotes postal_code as a string.
-- The CSV version of this same data lost them to a numeric export.
SELECT store_code, postal_code, store_open_date, store_close_date, is_active, created_at
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
WHERE postal_code LIKE '0%'
ORDER BY store_code;
-- -> 08759, 02166, 00158, ...   5 such codes in this file

-- The NaN literal became a proper NULL, not the text 'NaN'.
SELECT SUM(IFF(store_close_date IS NULL,1,0))     AS close_date_null,
       SUM(IFF(store_close_date = 'NaN',1,0))     AS close_date_literal_nan
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER;
-- -> 121, 0    NULL_IF did its job via the VARCHAR path
