/* ===========================================================================
   06 - LOAD 2 of 2: ADDITIVE drift -> SCHEMA EVOLUTION FIRES
   ---------------------------------------------------------------------------
   File   : store_master_1.parquet   (23 columns, 5 rows)
   Before : table 26 columns, 121 rows
   After  : table 27 columns, 126 rows      -> EVOLUTION EVENT
   Result : LOADED, rows_parsed 5, rows_loaded 5, errors_seen 0

   *** THIS IS THE SCHEMA EVOLUTION MOMENT ***

   The file carries a column the table does not have: `Status`. Snowflake ALTERs
   the table mid-COPY and appends it. NO DDL is issued below. No ALTER TABLE, no
   recreate, no pre-declaration.

     Added automatically:  STATUS  TEXT(16777216)  at ordinal position 27
     Source values:        the string 'y'
     All 121 pre-existing FILE 1 rows get STATUS = NULL

   The evolved type is TEXT and UNBOUNDED (16777216). Both follow from the data,
   not from a choice: the source stores 'y' as a Parquet BYTE_ARRAY/UTF8, and
   evolution does not guess a length - it uses max VARCHAR. If a bounded or
   BOOLEAN column matters, declare it explicitly BEFORE the load.

   *** THIS LOAD ALSO CARRIES TWO TYPE DRIFTS, AND SUCCEEDS ANYWAY ***

   Unlike the CSV exercise - where a numeric column receiving the string
   'testing' aborted the load - this file's type drifts are absorbed silently,
   because the target was DESIGNED for them in 04:

     postal_code   INTEGER in file  -> VARCHAR(30) target
                   Loads as '8759', '2166'. The leading zeros were ALREADY LOST
                   AT SOURCE - Snowflake cannot recover what the exporter threw
                   away. Compare US_0102 here with US_0002 from FILE 1.
     created_at    VARCHAR '21:50.4' -> VARCHAR(50) target
                   Loads verbatim. Preserved as evidence rather than rejected;
                   07 derives the typed column and leaves these 5 rows NULL.

   That is the whole argument for designing the target from a COMPARISON of both
   schemas rather than from file 1 alone. Had created_at been declared
   TIMESTAMP_NTZ - which INFER_SCHEMA's own output would never have suggested,
   since it reported NUMBER - this COPY would have failed and evolution would
   never have fired.
   =========================================================================== */

COPY INTO ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master_1.parquet
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;

-- PROOF OF EVOLUTION: STATUS exists at position 27 and was never declared.
SELECT ORDINAL_POSITION AS pos, COLUMN_NAME, DATA_TYPE,
       COALESCE(CHARACTER_MAXIMUM_LENGTH::VARCHAR,
                NUMERIC_PRECISION||','||NUMERIC_SCALE,'') AS size,
       COMMENT
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'DATA_MIGRATION_PARQUET' AND TABLE_NAME = 'STORE_MASTER'
ORDER BY ORDINAL_POSITION;
/* Position 27 = STATUS, TEXT, 16777216, COMMENT NULL.
   The NULL comment is a useful tell: every hand-declared column carries one, so
   a commentless column is an evolved one. Worth back-filling with
   COMMENT IF EXISTS so the catalogue stays documented.                        */

-- PROOF OF NULL BACK-FILL plus both type drifts, in one query.
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$')            AS source_file,
       COUNT(*)                                       AS row_cnt,
       SUM(IFF(STATUS IS NULL,1,0))                   AS status_nulls,
       SUM(IFF(postal_code LIKE '0%',1,0))            AS leading_zero_postals,
       SUM(IFF(TRY_TO_TIMESTAMP_NTZ(created_at) IS NULL,1,0)) AS created_at_unparseable,
       SUM(IFF(is_active IS NULL,1,0))                AS is_active_nulls,
       COUNT(DISTINCT store_code)                     AS distinct_keys
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* ->  store_master.parquet     121   121   5   0   0   121
       store_master_1.parquet     5     0   0   5   0     5

   Read across: STATUS nulls collapse 121 -> 0 when the column appears;
   leading-zero postals drop 5 -> 0 because FILE 2's were destroyed at source;
   created_at becomes 100% unparseable in FILE 2; is_active coerces cleanly in
   BOTH files ('Y' and 'y' both -> TRUE, 0 nulls).                            */

-- The two type drifts side by side on the SAME physical store.
-- US_0002 and US_0102 are the same shop - note the identical latitude.
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS src, store_code, store_name,
       postal_code, latitude, store_open_date, created_at, is_active, STATUS
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
WHERE store_code IN ('US_0002','US_0004','US_0102','US_0104')
ORDER BY src, store_code;
/* store_master.parquet    US_0002  08759  28.454519  2019-06-04  2026-04-17 15:21:50.369  TRUE  NULL
   store_master_1.parquet  US_0102   8759  28.454519  2019-06-04  21:50.4                  TRUE  y

   Same coordinates, same open date, different key, damaged postal and
   created_at. That is the logical-duplicate problem - see 10.                 */
