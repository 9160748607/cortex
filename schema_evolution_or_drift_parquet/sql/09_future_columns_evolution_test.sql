/* ===========================================================================
   09 - Future-columns test: proving the third-file case for Parquet
   ---------------------------------------------------------------------------
   EXECUTED AND THEN ROLLED BACK. The 2 test rows were deleted and the staged
   file removed, so the target matches the two-file specification. THE EVOLVED
   COLUMNS REMAIN - see 08_validation.sql section 8.1.

   Question: if a future store master Parquet file contains columns the table has
   never seen, does it load without recreating the table?

   Answer: yes, proven - not theorised.

     Before : 28 columns, 126 rows
     After  : 30 columns, 128 rows
     Result : LOADED, rows_parsed 2, rows_loaded 2, errors_seen 0

     Added automatically:
       MANAGER_NAME    TEXT(16777216)
       EMPLOYEE_COUNT  NUMBER(2,0)     <- see the precision warning below

     All 126 pre-existing rows received NULL for both. Prior data untouched.

   GENERATING THE TEST PARQUET WITH SNOWFLAKE ITSELF
   --------------------------------------------------------------------
   Unlike CSV and JSON, a Parquet fixture cannot be hand-written in a text editor
   or a PowerShell here-string - it is a binary columnar container. Rather than
   install pyarrow locally, the test file is produced by UNLOADING a query to the
   stage as Parquet. This is a genuinely useful technique for Parquet test data:
   no local tooling, and the file is written by the same engine that will read it.

   Written to a SEPARATE prefix (store-master-future/) so it cannot be confused
   with the real inputs or swept up by a prefix-wide load. The user's source
   folder was never written to.

   Snowflake names unload output automatically - here data_0_0_0.snappy.parquet -
   so the COPY below targets the PREFIX, not a filename.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- 9.1 Generate the test file. 25 columns: the 22 baseline + Status +
-- manager_name + employee_count.
-- ---------------------------------------------------------------------------
COPY INTO @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master-future/
FROM (
  SELECT 'US_9001' AS store_code, 'Apple Evolution Test North' AS store_name, 'US' AS country_code,
         'AMER' AS region_code, 'US_NY_STD' AS tax_jurisdiction_code, 'FLG' AS format_code,
         'Testburgh' AS city, 'NY' AS state_code, '01001' AS postal_code,
         '1 Evolution Plaza' AS address_line1, 40.712776 AS latitude, -74.005974 AS longitude,
         '2024-03-15'::DATE AS store_open_date, NULL::DATE AS store_close_date,
         'ACTIVE' AS lifecycle_status, 15000 AS floor_area_sqft, 9500000 AS annual_rent_usd,
         'Y' AS is_active, '2026-04-17'::DATE AS effective_start_date,
         '9999-12-31'::DATE AS effective_end_date,
         '2026-04-17 16:00:00.000' AS created_at, 'RETAIL_OPS' AS source_system,
         'y' AS status, 'Jane Okafor' AS manager_name, 87 AS employee_count
  UNION ALL
  SELECT 'US_9002','Apple Evolution Test South','US','AMER','US_CA_STD','MINI',
         'Demo Creek','CA','90210','2 Demo Way',34.052235,-118.243683,
         '2025-11-02'::DATE, NULL::DATE, 'ACTIVE', 7400, 6200000, 'Y',
         '2026-04-17'::DATE,'9999-12-31'::DATE,'2026-04-17 16:00:01.000','RETAIL_OPS',
         'n','Raj Mehta',34
)
FILE_FORMAT = (TYPE = PARQUET)
HEADER = TRUE
OVERWRITE = TRUE;
-- -> rows_unloaded 2

-- ---------------------------------------------------------------------------
-- 9.2 The load. Byte-identical to 05/06 apart from the path.
-- ---------------------------------------------------------------------------
COPY INTO ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master-future/
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;

-- ---------------------------------------------------------------------------
-- 9.3 PROOF: both new columns became columns, NULL for every earlier row.
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$')          AS source_file,
       COUNT(*)                                     AS row_cnt,
       SUM(IFF(STATUS IS NULL,1,0))                 AS status_nulls,
       SUM(IFF(MANAGER_NAME IS NULL,1,0))           AS manager_nulls,
       SUM(IFF(EMPLOYEE_COUNT IS NULL,1,0))         AS empcount_nulls,
       SUM(IFF(created_at_ntz IS NULL,1,0))         AS created_ntz_nulls
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* ->  data_0_0_0.snappy.parquet    2     0     0     0     2
       store_master.parquet       121   121   121   121     0
       store_master_1.parquet       5     0     5     5     5

   A clean staircase: each file fills exactly the columns it supplies.

   NOTE created_ntz_nulls = 2 for the new file. That is NOT a drift finding - it
   is the known limitation documented in 07: created_at_ntz is populated by a
   one-off UPDATE, so rows loaded afterwards stay NULL until it is re-run. Caught
   by this test, which is exactly what a test is for.                          */

SELECT ORDINAL_POSITION AS pos, COLUMN_NAME, DATA_TYPE,
       COALESCE(CHARACTER_MAXIMUM_LENGTH::VARCHAR,
                NUMERIC_PRECISION||','||NUMERIC_SCALE,'') AS size
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA='DATA_MIGRATION_PARQUET' AND TABLE_NAME='STORE_MASTER'
  AND ORDINAL_POSITION >= 27
ORDER BY ORDINAL_POSITION;
/* -> 27 STATUS TEXT 16777216 / 28 CREATED_AT_NTZ TIMESTAMP_NTZ
      29 MANAGER_NAME TEXT 16777216 / 30 EMPLOYEE_COUNT NUMBER 2,0

   *** EMPLOYEE_COUNT NUMBER(2,0) IS THE WARNING WORTH REMEMBERING ***
   Inferred from a 2-row sample (87, 34) -> a ceiling of 99. Evolution did not
   choose a sensible type, it chose the smallest that fit the sample. A store with
   100 employees fails the next load.

   Compare position 28, CREATED_AT_NTZ, added by hand in 07 with a reviewed type.
   That is the difference between convenient and correct.

   Note also that 29 and 30 are in DOCUMENT order here, matching the Parquet
   schema - whereas the JSON exercise appended them alphabetically. Evolved
   column ordering is format-dependent; do not depend on it.                   */

-- ---------------------------------------------------------------------------
-- 9.4 Rollback of the test. Rows go, COLUMNS STAY.
-- ---------------------------------------------------------------------------
DELETE FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
WHERE __file_name LIKE 'store-master-future/%';
-- -> 2 rows deleted; back to 126 rows, still 30 columns.

-- Staged file also removed:
--   snow stage remove '@ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg' \
--     'store-master-future/data_0_0_0.snappy.parquet' --connection ysirciu-vg28332

/* ===========================================================================
   WHAT THIS PIPELINE DOES *NOT* HANDLE AUTOMATICALLY
   ---------------------------------------------------------------------------
   Additively future-proof, yes. Evolution is ADD-ONLY:

     Renamed column     arrives as a NEW column; the old one silently goes NULL.
     Removed column     no error, no alert, values silently NULL. The load
                        SUCCEEDS - the most dangerous case.
     Narrowed precision see EMPLOYEE_COUNT NUMBER(2,0) above.
     Incompatible type  fails the load outright IF the target is strongly typed.
                        Here it did not fail, because 04 deliberately declared
                        created_at as VARCHAR after comparing BOTH schemas. Had
                        the target been built from file 1 alone, load 2 would
                        have aborted.
     Logical duplicates completely invisible to evolution and to key checks.
                        See 10.

   Ranked by danger, quietest first:
     1. logical duplicates - nothing looks wrong at all
     2. removed column     - succeeds silently, data quietly disappears
     3. renamed column     - succeeds silently, splits a column in two
     4. narrow precision   - succeeds now, fails later on bigger data
     5. type conflict      - fails immediately, easy to spot

   The remedy for 2 and 3 is a PRE-LOAD GUARD comparing incoming columns to the
   target. Parquet makes this cheap and exact, because the embedded schema can be
   read without scanning any data:

     SELECT c.COLUMN_NAME AS missing_from_incoming_file
     FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS c
     WHERE c.TABLE_SCHEMA='DATA_MIGRATION_PARQUET'
       AND c.TABLE_NAME='STORE_MASTER'
       AND c.COLUMN_NAME NOT LIKE '\_\_%'
       AND c.COLUMN_NAME NOT IN ('CREATED_AT_NTZ')   -- derived, never in source
       AND c.COLUMN_NAME NOT IN (
             SELECT UPPER(COLUMN_NAME) FROM TABLE(INFER_SCHEMA(
               LOCATION=>'@.../incoming_file.parquet',
               FILE_FORMAT=>'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')))
     ORDER BY 1;

   Any row returned = columns that will be silently NULLed. Treat a non-empty
   result as a pipeline failure or a reviewed exception, never as noise.
   And pair it with the TYPEOF cross-check from 02.3 - INFER_SCHEMA alone is not
   enough on Parquet.
   =========================================================================== */
