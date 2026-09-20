/* ===========================================================================
   06 - LOAD 2 of 2: ADDITIVE drift -> SCHEMA EVOLUTION FIRES
   ---------------------------------------------------------------------------
   File   : store_master_columns_added.json   (23 keys, 5 records)
   Before : table 26 columns, 121 rows
   After  : table 27 columns, 126 rows        -> EVOLUTION EVENT
   Result : LOADED, rows_parsed 5, rows_loaded 5, errors_seen 0

   *** THIS IS THE SCHEMA EVOLUTION MOMENT ***

   The file carries a key the table does not have: `Status`. Snowflake ALTERs
   the table mid-COPY and appends it. NO DDL is issued below. No ALTER TABLE, no
   recreate, no pre-declaration.

     Added automatically:  STATUS  TEXT(16777216)  at ordinal position 27
     Source values:        the STRING "True" (not a JSON boolean)
     All 121 pre-existing FILE 1 rows get STATUS = NULL

   Note the evolved type is TEXT, not BOOLEAN, and it is UNBOUNDED VARCHAR.
   Both follow from the data, not from a choice:
     - TEXT because the source quotes the value as "True". Had it emitted a real
       JSON boolean, evolution would have added a BOOLEAN column.
     - 16777216 because evolution does not guess a length; it uses max VARCHAR.
   If a bounded, correctly-typed column matters, add it explicitly BEFORE the
   load rather than letting evolution infer it.

   NO file format change is needed for this file - unlike the CSV exercise,
   where each file needed its own DATE_FORMAT. Both JSON files use ISO dates.
   =========================================================================== */

COPY INTO ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master_columns_added.json
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;

-- PROOF OF EVOLUTION: STATUS now exists at position 27 and was never declared.
SELECT ORDINAL_POSITION AS pos, COLUMN_NAME, DATA_TYPE,
       COALESCE(CHARACTER_MAXIMUM_LENGTH::VARCHAR,
                NUMERIC_PRECISION||','||NUMERIC_SCALE,'') AS size,
       IS_NULLABLE, COMMENT
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'DATA_MIGRATION_JSON' AND TABLE_NAME = 'STORE_MASTER'
ORDER BY ORDINAL_POSITION;
/* Position 27 = STATUS, TEXT, 16777216, NULLABLE, COMMENT NULL.
   The NULL comment is itself a tell: every hand-declared column carries one,
   so a commentless column is an evolved column. Worth back-filling with
   COMMENT IF EXISTS so the catalogue stays documented.                       */

-- PROOF OF NULL BACK-FILL: file 1 rows NULL, file 2 rows populated.
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       COUNT(*)                            AS row_cnt,
       COUNT(STATUS)                       AS status_filled,
       SUM(IFF(STATUS IS NULL,1,0))        AS status_nulls,
       COUNT(DISTINCT store_code)          AS distinct_keys
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* ->  store_master.json                 121   0    121   121
       store_master_columns_added.json      5   5      0     5          */

-- Side-by-side: identical record, file 2 adds only Status.
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS src, store_code, store_name,
       postal_code, latitude, store_open_date, store_close_date,
       is_active, created_at, STATUS
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
WHERE store_code IN ('US_0001','US_0002')
ORDER BY store_code, src;
/* Same store appears twice - once per file - differing ONLY in STATUS.
   That is the duplicate-key problem, visible in one query. See 09.          */
