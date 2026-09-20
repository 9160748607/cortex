/* ===========================================================================
   02 - Schema detection: INFER_SCHEMA per source file
   ---------------------------------------------------------------------------
   Run INFER_SCHEMA on EACH FILE SEPARATELY. Pointing it at the folder prefix
   would return a merged union and hide the very drift we are trying to find.
   Per-file is the whole point of this step.

   Each query is paired with the file format matching that file's date
   convention (see 01_create_objects.sql).
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- FILE 1: store_master.csv  -> 22 columns, 121 rows
-- ---------------------------------------------------------------------------
SELECT ORDER_ID, COLUMN_NAME, TYPE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master.csv',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_iso'
))
ORDER BY ORDER_ID;

/* Actual result - 22 columns:
     0  store_code             TEXT
     1  store_name             TEXT
     2  country_code           TEXT
     3  region_code            TEXT
     4  tax_jurisdiction_code  TEXT
     5  format_code            TEXT
     6  city                   TEXT
     7  state_code             TEXT
     8  postal_code            TEXT            <-- TEXT here
     9  address_line1          TEXT
    10  latitude               NUMBER(8,6)
    11  longitude              NUMBER(9,6)
    12  store_open_date        DATE            <-- DATE here
    13  store_close_date       TEXT            (all empty -> no type evidence)
    14  lifecycle_status       TEXT
    15  floor_area_sqft        NUMBER(5,0)
    16  annual_rent_usd        NUMBER(8,0)
    17  is_active              BOOLEAN
    18  effective_start_date   DATE            <-- DATE here
    19  effective_end_date     DATE            <-- DATE here
    20  created_at             TIMESTAMP_NTZ   <-- TIMESTAMP here
    21  source_system          TEXT
*/

-- ---------------------------------------------------------------------------
-- FILE 2: store_master_1.csv  -> 23 columns, 5 rows   (ADDITIVE drift)
-- ---------------------------------------------------------------------------
SELECT ORDER_ID, COLUMN_NAME, TYPE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_1.csv',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu'
))
ORDER BY ORDER_ID;

/* Actual result - 23 columns. Differences vs FILE 1 marked:
     8  postal_code            NUMBER(5,0)   <-- was TEXT: leading zeros destroyed
    12  store_open_date        TEXT          <-- was DATE: day-first not detected
    18  effective_start_date   TEXT          <-- was DATE
    19  effective_end_date     TEXT          <-- was DATE
    20  created_at             TEXT          <-- was TIMESTAMP_NTZ: value is '21:50.4'
    22  Status                 BOOLEAN       <-- NEW COLUMN, not in FILE 1
*/

-- ---------------------------------------------------------------------------
-- FILE 3: store_master_2_deleted_columns.csv -> 17 columns, 5 rows
--         (SUBTRACTIVE drift)
-- ---------------------------------------------------------------------------
SELECT ORDER_ID, COLUMN_NAME, TYPE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_2_deleted_columns.csv',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu'
))
ORDER BY ORDER_ID;

/* Actual result - 17 columns. SIX columns from FILE 1 are absent:
     format_code, city, state_code, postal_code, address_line1, latitude
   Status IS present. longitude survived but latitude did not, so the
   geo pair is half-broken.
*/

-- ---------------------------------------------------------------------------
-- Type-conversion probes that drove the target design.
-- These are the tests that turned assumptions into evidence - do not skip them
-- when onboarding a new file.
-- ---------------------------------------------------------------------------
SELECT
    $13                            AS open_raw,
    TRY_TO_DATE($13,'DD-MM-YYYY')  AS open_day_first,   -- 01-09-2017 -> 2017-09-01  correct
    TRY_TO_DATE($13)               AS open_auto,        -- NULL: AUTO cannot parse day-first
    $20                            AS eff_end_raw,
    TRY_TO_DATE($20,'DD-MM-YYYY')  AS eff_end_day_first,-- 31-12-9999 -> 9999-12-31
    $21                            AS created_raw,      -- '21:50.4'
    TRY_TO_TIMESTAMP_NTZ($21)      AS created_parsed,   -- NULL: no date component, unrecoverable
    $9                             AS postal_raw,       -- 8759 vs 08759 in FILE 1
    $23                            AS status_raw        -- 'y'
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_1.csv
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_inspect')
LIMIT 3;

-- ---------------------------------------------------------------------------
-- Row-count reconciliation.
-- FILE 1 has 126 physical lines but 121 logical rows: 5 address values contain
-- embedded newlines inside quoted fields. FIELD_OPTIONALLY_ENCLOSED_BY handles
-- this. Always reconcile a shell line count against this before trusting it.
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS data_rows, COUNT(DISTINCT $1) AS distinct_store_codes
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master.csv
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_inspect');
-- -> 121, 121
