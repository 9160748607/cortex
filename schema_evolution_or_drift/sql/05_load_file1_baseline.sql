/* ===========================================================================
   05 - LOAD 1 of 3: baseline load, no drift
   ---------------------------------------------------------------------------
   File   : store_master.csv        (22 columns, 121 rows, ISO dates)
   Before : table 26 columns, 0 rows
   After  : table 26 columns, 121 rows      -> NO evolution event
   Result : LOADED, rows_parsed 121, rows_loaded 121, errors_seen 0

   This load establishes the baseline. The file matches the table exactly, so
   nothing evolves - which is the point: evolution must not fire spuriously.

   MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
     Binds by HEADER NAME, not ordinal position. This is what makes the loader
     immune to column reordering, and it is what fills absent columns with NULL
     automatically - no COALESCE or placeholder logic anywhere.
     CASE_INSENSITIVE is chosen because FILE 2 ships `Status` in mixed case
     while every other column is lower snake_case.

   INCLUDE_METADATA
     The only way to capture METADATA$ pseudo-columns alongside
     MATCH_BY_COLUMN_NAME. The transformation form
     COPY INTO ... FROM (SELECT ...) CANNOT be combined with
     MATCH_BY_COLUMN_NAME, so INCLUDE_METADATA is not a convenience here - it
     is the only available mechanism.

   ON_ERROR = ABORT_STATEMENT, not CONTINUE
     A partially loaded dimension is worse than no load: it produces
     plausible-looking but incomplete reference data that nothing downstream
     flags. Fail visibly instead.

   Idempotency: COPY load history is keyed on FILE NAME, so re-running this is
   a no-op for files already loaded. FORCE = TRUE is deliberately omitted.
   BEWARE: that key is the filename, NOT the business key - see 07, where a
   renamed re-export of the same rows loads again and duplicates them.
   =========================================================================== */

COPY INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master.csv
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_iso')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;

-- Expect 121 rows, 26 columns, leading zeros intact.
SELECT COUNT(*) AS row_cnt, COUNT(DISTINCT store_code) AS distinct_stores
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER;

SELECT store_code, postal_code, store_open_date, created_at, is_active
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
WHERE postal_code LIKE '0%'
ORDER BY store_code
LIMIT 5;
-- -> 08759, 02166, 03988, 00158, 06055  (proves the VARCHAR decision in 04)
