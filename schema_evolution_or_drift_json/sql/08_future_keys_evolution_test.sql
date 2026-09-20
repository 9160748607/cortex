/* ===========================================================================
   08 - Future-keys test: proving the third-file case
   ---------------------------------------------------------------------------
   EXECUTED AND THEN ROLLED BACK. The 2 test rows were deleted and the staged
   file removed, so the target matches the two-file specification. THE EVOLVED
   COLUMNS REMAIN - see 07_validation.sql section 7.1.

   Question: if a future store master file contains keys the table has never
   seen, does it load without recreating the table?

   Answer: yes, proven - not theorised. A 25-key file adding `manager_name` and
   `employee_count` was loaded with the IDENTICAL COPY used in 05 and 06.
   No ALTER TABLE, no recreate, no pre-declaration.

     Before : 27 columns, 126 rows
     After  : 29 columns, 128 rows
     Result : LOADED, rows_parsed 2, rows_loaded 2, errors_seen 0

     Added automatically:
       EMPLOYEE_COUNT  NUMBER(2,0)      <- see the precision warning below
       MANAGER_NAME    TEXT(16777216)

     All 126 pre-existing rows received NULL for both. Prior data untouched.

   The test file was written to a TEMP directory, never to the source folder,
   so the user's originals stayed untouched:
     C:\Users\X1Carbon\AppData\Local\Temp\json-evolution-test\
       store_master_future_keys.json
   and staged under a separate prefix (store-master-future/) so it could not be
   confused with the real inputs or swept up by a prefix-wide load.

   It also used "store_close_date": null - PROPER JSON null, not NaN - which is
   what the real export should have emitted all along.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- 8.1 The load. Byte-identical to 05/06 apart from the file path.
-- ---------------------------------------------------------------------------
COPY INTO ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master-future/store_master_future_keys.json
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;

-- ---------------------------------------------------------------------------
-- 8.2 PROOF: both new keys became columns, NULL for every earlier row.
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$')   AS source_file,
       COUNT(*)                              AS row_cnt,
       SUM(IFF(STATUS IS NULL,1,0))          AS status_nulls,
       SUM(IFF(MANAGER_NAME IS NULL,1,0))    AS manager_nulls,
       SUM(IFF(EMPLOYEE_COUNT IS NULL,1,0))  AS empcount_nulls
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* ->  store_master.json                 121   121   121   121
       store_master_columns_added.json      5     0     5     5
       store_master_future_keys.json        2     0     0     0
   A clean staircase: each file fills exactly the keys it supplies.           */

SELECT ORDINAL_POSITION AS pos, COLUMN_NAME, DATA_TYPE,
       COALESCE(CHARACTER_MAXIMUM_LENGTH::VARCHAR,
                NUMERIC_PRECISION||','||NUMERIC_SCALE,'') AS size
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA='DATA_MIGRATION_JSON' AND TABLE_NAME='STORE_MASTER'
  AND ORDINAL_POSITION >= 27
ORDER BY ORDINAL_POSITION;
/* -> 27 STATUS TEXT 16777216 / 28 EMPLOYEE_COUNT NUMBER 2,0 / 29 MANAGER_NAME TEXT

   *** EMPLOYEE_COUNT NUMBER(2,0) IS THE WARNING IN THIS WHOLE EXERCISE ***
   Inferred from a 2-record sample (87, 34) -> a ceiling of 99. Evolution did
   not pick a sensible type, it picked the smallest type that fit the sample.
   A store with 100 employees fails the next load. Automatic evolution is
   convenient, not correct - review the type of every column it adds.         */

-- ---------------------------------------------------------------------------
-- 8.3 Rollback of the test. Rows go, COLUMNS STAY.
-- ---------------------------------------------------------------------------
DELETE FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
WHERE __file_name LIKE 'store-master-future/%';
-- -> 2 rows deleted; back to 126 rows, still 29 columns.

-- Staged file also removed:
--   snow stage remove '@ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg' \
--     'store-master-future/store_master_future_keys.json' --connection ysirciu-vg28332

/* ===========================================================================
   WHAT THIS PIPELINE DOES *NOT* HANDLE AUTOMATICALLY
   ---------------------------------------------------------------------------
   Additively future-proof, yes. But evolution is ADD-ONLY:

     Renamed key        arrives as a NEW column; the old one silently goes NULL.
                        Looks identical to a rename done properly - it is not.
     Removed key        no error, no alert, values silently NULL. The most
                        dangerous case, because the load still SUCCEEDS.
     Narrowed precision see EMPLOYEE_COUNT NUMBER(2,0) above.
     Incompatible type  fails the load outright - which is what the NaN/DATE
                        conflict did in 04. Loud, and therefore safe.
     Invalid literals   NaN is accepted by Snowflake as DOUBLE and by lenient
                        client parsers as valid. Nothing flags it.

   Ranked by danger, quietest first:
     1. removed key     - succeeds silently, data quietly disappears
     2. renamed key     - succeeds silently, splits a column in two
     3. narrow precision- succeeds now, fails later on bigger data
     4. type conflict   - fails immediately, easy to spot

   The remedy for 1 and 2 is a PRE-LOAD GUARD comparing incoming keys to the
   target, not a Snowflake feature. Pattern:

     SELECT c.COLUMN_NAME AS missing_from_incoming_file
     FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS c
     WHERE c.TABLE_SCHEMA='DATA_MIGRATION_JSON'
       AND c.TABLE_NAME='STORE_MASTER'
       AND c.COLUMN_NAME NOT LIKE '\_\_%'
       AND c.COLUMN_NAME NOT IN (
             SELECT UPPER(COLUMN_NAME) FROM TABLE(INFER_SCHEMA(
               LOCATION=>'@.../incoming_file.json',
               FILE_FORMAT=>'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')))
     ORDER BY 1;

   Any row returned = keys that will be silently NULLed. Treat a non-empty
   result as a pipeline failure or a reviewed exception, never as noise.
   =========================================================================== */
