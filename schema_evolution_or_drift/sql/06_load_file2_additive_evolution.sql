/* ===========================================================================
   06 - LOAD 2 of 3: ADDITIVE drift -> SCHEMA EVOLUTION FIRES
   ---------------------------------------------------------------------------
   File   : store_master_1.csv      (23 columns, 5 rows, DAY-FIRST dates)
   Before : table 26 columns, 121 rows
   After  : table 27 columns, 126 rows      -> EVOLUTION EVENT
   Result : LOADED, rows_parsed 5, rows_loaded 5, errors_seen 0

   *** THIS IS THE SCHEMA EVOLUTION MOMENT ***

   The file carries a column the table does not have: `Status`. Snowflake
   ALTERs the table mid-COPY and appends it. NO DDL is issued below. There is
   no ALTER TABLE, no recreate, no pre-declaration.

     Added automatically:  STATUS  BOOLEAN  at ordinal position 27
     Source values 'y' -> TRUE
     All 121 pre-existing FILE 1 rows get STATUS = NULL

   That NULL back-fill is requirement "missing column -> NULL" satisfied by the
   engine, not by our SQL.

   NOTE THE FILE FORMAT CHANGE: ff_store_master_eu, not _iso.
   This file ships day-first dates (01-09-2017). Loading it with the ISO format
   would NOT raise an error - AUTO parsing returns NULL - so the dates would
   land empty and nobody would be alerted. The per-file format choice is the
   load's correctness hinge, not a cosmetic detail.

   Verified after load - day-first parsing is correct, not transposed:
     01-09-2017 -> 2017-09-01   (NOT 2017-01-09)
     22-06-2016 -> 2016-06-22   (22 cannot be a month, so this proves day-first)
     31-12-9999 -> 9999-12-31
   =========================================================================== */

COPY INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_1.csv
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;

-- PROOF OF EVOLUTION: STATUS now exists at position 27 and was never declared.
SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE, IS_NULLABLE
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'DATA_MIGRATION' AND TABLE_NAME = 'STORE_MASTER'
ORDER BY ORDINAL_POSITION;

-- PROOF OF NULL BACK-FILL: file 1 rows NULL, file 2 rows populated.
SELECT
    REGEXP_SUBSTR(__file_name,'[^/]+$')    AS source_file,
    COUNT(*)                               AS row_cnt,
    SUM(IFF(STATUS IS NULL,1,0))           AS status_nulls,
    MIN(store_open_date)                   AS earliest_open,
    MAX(store_open_date)                   AS latest_open
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
GROUP BY 1
ORDER BY 1;
/* ->  store_master.csv     121   121    2016-04-29   2026-04-10
       store_master_1.csv     5     0    2016-06-22   2019-09-01   */

-- Row-level date verification for every file 2 row.
SELECT store_code, store_open_date, effective_start_date, effective_end_date,
       created_at, is_active, STATUS
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
WHERE __file_name LIKE '%store_master_1.csv'
ORDER BY __row_number;
/* created_at stays raw as '21:50.4' - corruption preserved as evidence,
   which is the entire reason the column is VARCHAR. See 04.               */
