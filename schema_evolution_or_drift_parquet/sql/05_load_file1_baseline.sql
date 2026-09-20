/* ===========================================================================
   05 - LOAD 1 of 2: baseline load, no drift
   ---------------------------------------------------------------------------
   File   : store_master.parquet     (22 columns, 121 rows)
   Before : table 26 columns, 0 rows
   After  : table 26 columns, 121 rows      -> NO evolution event
   Result : LOADED, rows_parsed 121, rows_loaded 121, errors_seen 0

   Establishes the baseline. The file's columns match the table exactly, so
   nothing evolves - which is the point: evolution must not fire spuriously.

   MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
     Binds by COLUMN NAME from the Parquet schema, not by position. Parquet does
     preserve column order, so positional binding would technically work here -
     but it would silently break the moment a producer reorders columns, which
     is a legal and invisible change in Parquet. Name binding also NULL-fills any
     table column the file omits, which is requirement "missing column -> NULL"
     satisfied by the engine rather than by our SQL.
     CASE_INSENSITIVE because FILE 2 ships `Status` capitalised while every other
     column is lower snake_case.

   INCLUDE_METADATA
     The only way to capture METADATA$ pseudo-columns alongside
     MATCH_BY_COLUMN_NAME - the transformation form
     COPY INTO ... FROM (SELECT ...) cannot be combined with it. For Parquet
     that restriction bites harder than for CSV: without a transformation there
     is no opportunity to cast or repair a value mid-load, which is precisely
     why created_at had to be handled by declaration (04) plus a derived column
     (07) rather than by a cast.

   ON_ERROR = ABORT_STATEMENT, not CONTINUE
     A partially loaded dimension is worse than no load: plausible-looking but
     incomplete reference data that nothing downstream flags.

   Idempotency: COPY load history is keyed on FILE NAME, so re-running is a
   no-op for files already loaded. FORCE = TRUE deliberately omitted.
   =========================================================================== */

COPY INTO ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master.parquet
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
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
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER;

-- Leading zeros survived, because FILE 1 stores postal_code as a string AND the
-- target declares it VARCHAR. Either choice alone would have lost them.
SELECT store_code, postal_code, store_open_date, created_at, is_active
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
WHERE postal_code LIKE '0%'
ORDER BY store_code;
-- -> 08759, 02166, 03988, 00158, 06055   (5 codes)

-- created_at landed as the full timestamp text, NOT an epoch integer.
-- Had the target been declared NUMBER(38,0) per INFER_SCHEMA, this would show
-- raw epoch microseconds instead. See 02 section 2.3.
SELECT store_code, created_at, TRY_TO_TIMESTAMP_NTZ(created_at) AS parses_cleanly
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
ORDER BY store_code LIMIT 3;
-- -> 2026-04-17 15:21:50.368  ->  parses cleanly, 0 unparseable in this file

-- store_close_date is NULL on every row - no NaN-style junk to neutralise here,
-- unlike the JSON sources which needed NULL_IF.
SELECT SUM(IFF(store_close_date IS NULL,1,0)) AS close_date_nulls
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER;
-- -> 121
