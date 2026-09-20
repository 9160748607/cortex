/* ===========================================================================
   11 - LOAD 4 of 4: TYPE drift -> COPY REJECTED, then quarantine + merge
   ---------------------------------------------------------------------------
   File : store_master_3_datatypechange_numberdatasendingtextinafile.csv
          23 columns, 5 rows, day-first dates

   NO structural drift at all. Column list is identical to file 2. The damage is
   entirely INSIDE a column:

     floor_area_sqft   NUMBER in every prior file, TEXT here
       US_0101  'testing'   <- literal string in a numeric column
       US_0102  'testing'
       US_0103  18363       valid
       US_0104  13483       valid
       US_0105  9157        valid

   *** THE THIRD DRIFT CATEGORY, AND THE ONE EVOLUTION CANNOT TOUCH ***

   Schema evolution ADDS columns. It does not widen, retype or relax an
   existing one. Snowflake did NOT convert floor_area_sqft to VARCHAR to
   accommodate the bad value - it refused the load outright:

     Numeric value 'testing' is not recognized
     File '...datatypechange...csv', line 2, character 140
     Row 1, column "STORE_MASTER"["FLOOR_AREA_SQFT":16]

   Verified after the failure: 131 rows, 29 columns, FLOOR_AREA_SQFT still
   NUMBER, 0 rows from this file. COPY is ATOMIC PER FILE - the 3 good rows did
   not sneak in alongside the 2 bad ones.

   Contrast the three categories now demonstrated:
     ADDITIVE    (06)  table grows automatically     - loud, safe
     SUBTRACTIVE (07)  load succeeds, values NULLed  - SILENT, dangerous
     TYPE        (11)  load fails outright           - loud, blocks pipeline

   Type drift is the least insidious of the three precisely because it fails.
   The wrong fix is to make it quiet. Both tempting shortcuts are traps:

     ON_ERROR = CONTINUE
       Loads the 3 good rows, silently discards the 2 bad ones. Converts a
       visible failure into invisible data loss - strictly worse.

     ALTER floor_area_sqft TO VARCHAR
       Surrenders numeric typing for all 121 correctly-typed rows to
       accommodate 2 bad values. Lets the corruption set the schema.

   The pattern below keeps the target strongly typed AND loses nothing:
     all-text landing -> TRY_TO_* validation -> good rows MERGE, bad rows
     quarantined with their raw value for the source team.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- 11.1 What the standard COPY does. Left here deliberately: this is the
-- diagnostic, and it must keep failing. Do not "fix" it with ON_ERROR.
-- ---------------------------------------------------------------------------
/*
COPY INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_3_datatypechange_numberdatasendingtextinafile.csv
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;
-- ->  Numeric value 'testing' is not recognized      EXPECTED FAILURE
*/

-- ---------------------------------------------------------------------------
-- 11.2 All-text landing table. Every volatile column is VARCHAR so the file
-- always lands and validation, not parsing, decides what is acceptable.
-- ENABLE_SCHEMA_EVOLUTION is kept on so new columns still self-add here.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD_RAW (
  store_code               VARCHAR(30)   COMMENT 'Source store code, primary business key.',
  store_name               VARCHAR(150)  COMMENT 'Retail store name.',
  country_code             VARCHAR(10)   COMMENT 'ISO alpha-2 country code.',
  region_code              VARCHAR(20)   COMMENT 'Region code.',
  tax_jurisdiction_code    VARCHAR(30)   COMMENT 'Sub-national tax jurisdiction code.',
  format_code              VARCHAR(20)   COMMENT 'Store format code.',
  city                     VARCHAR(100)  COMMENT 'City of the store location.',
  state_code               VARCHAR(20)   COMMENT 'State or province code.',
  postal_code              VARCHAR(30)   COMMENT 'Postal code as text.',
  address_line1            VARCHAR(255)  COMMENT 'Street address line.',
  latitude                 VARCHAR(50)   COMMENT 'Latitude as raw text pending validation.',
  longitude                VARCHAR(50)   COMMENT 'Longitude as raw text pending validation.',
  store_open_date          VARCHAR(50)   COMMENT 'Store open date as raw text pending validation.',
  store_close_date         VARCHAR(50)   COMMENT 'Store close date as raw text pending validation.',
  lifecycle_status         VARCHAR(30)   COMMENT 'Lifecycle state.',
  floor_area_sqft          VARCHAR(50)   COMMENT 'Floor area as raw text: source has shipped non-numeric values such as the literal testing.',
  annual_rent_usd          VARCHAR(50)   COMMENT 'Annual rent as raw text pending validation.',
  is_active                VARCHAR(10)   COMMENT 'Active flag as raw text.',
  effective_start_date     VARCHAR(50)   COMMENT 'Effective start date as raw text pending validation.',
  effective_end_date       VARCHAR(50)   COMMENT 'Effective end date as raw text pending validation.',
  created_at               VARCHAR(50)   COMMENT 'Source creation timestamp as raw text.',
  source_system            VARCHAR(50)   COMMENT 'Originating source system.',
  Status                   VARCHAR(10)   COMMENT 'Secondary status flag as raw text.',
  __file_name              VARCHAR(500)  COMMENT 'Audit: staged file the row came from.',
  __row_number             NUMBER(18,0)  COMMENT 'Audit: data-row ordinal within the source file.',
  __file_last_modified_ntz TIMESTAMP_NTZ COMMENT 'Audit: staged file last modified time.',
  __loaded_at              TIMESTAMP_NTZ COMMENT 'Audit: when the row was loaded.'
)
ENABLE_SCHEMA_EVOLUTION = TRUE
COMMENT = 'All-text landing table for store master files. Absorbs type drift so a bad value fails validation instead of failing the load.';

-- ---------------------------------------------------------------------------
-- 11.3 Quarantine table. Rejected rows stay visible and actionable - not
-- dropped by ON_ERROR, not silently coerced to NULL.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_REJECTS (
  store_code               VARCHAR(30)   COMMENT 'Source store code of the rejected row.',
  reject_column            VARCHAR(100)  COMMENT 'Column whose value failed type validation.',
  reject_raw_value         VARCHAR(500)  COMMENT 'The offending raw value, preserved verbatim for the source team.',
  reject_expected_type     VARCHAR(50)   COMMENT 'Type the target column requires.',
  reject_reason            VARCHAR(200)  COMMENT 'Why the row was quarantined.',
  __file_name              VARCHAR(500)  COMMENT 'Audit: staged file the rejected row came from.',
  __row_number             NUMBER(18,0)  COMMENT 'Audit: data-row ordinal within the source file.',
  __rejected_at            TIMESTAMP_NTZ COMMENT 'Audit: when the row was quarantined.'
)
COMMENT = 'Quarantine for store master rows failing type validation. Keeps bad data visible and actionable instead of dropped or silently nulled.';

-- ---------------------------------------------------------------------------
-- 11.4 Land the file. This SUCCEEDS where 11.1 failed - same file, same
-- format, same COPY options. Only the destination typing differs.
-- ---------------------------------------------------------------------------
COPY INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD_RAW
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_3_datatypechange_numberdatasendingtextinafile.csv
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;
-- -> LOADED, rows_parsed 5, rows_loaded 5, errors_seen 0

-- ---------------------------------------------------------------------------
-- 11.5 Classify before moving anything. Note the IS NOT NULL guard: a NULL is
-- legitimately absent data, NOT a cast failure, and must not be quarantined.
-- ---------------------------------------------------------------------------
SELECT store_code,
       floor_area_sqft                AS raw_value,
       TRY_TO_NUMBER(floor_area_sqft) AS cast_value,
       CASE WHEN floor_area_sqft IS NULL                    THEN 'VALID - null allowed'
            WHEN TRY_TO_NUMBER(floor_area_sqft) IS NULL     THEN 'REJECT - not numeric'
            ELSE 'VALID' END          AS verdict
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD_RAW
WHERE __file_name LIKE '%datatypechange%'
ORDER BY __row_number;
/* -> US_0101 testing NULL  REJECT     US_0103 18363 18363 VALID
      US_0102 testing NULL  REJECT     US_0104 13483 13483 VALID
                                       US_0105  9157  9157 VALID   */

-- ---------------------------------------------------------------------------
-- 11.6 Quarantine the 2 uncastable rows, keeping the raw value.
-- ---------------------------------------------------------------------------
INSERT INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_REJECTS
  (store_code, reject_column, reject_raw_value, reject_expected_type, reject_reason,
   __file_name, __row_number, __rejected_at)
SELECT store_code, 'FLOOR_AREA_SQFT', floor_area_sqft, 'NUMBER(10,0)',
       'Non-numeric text in a numeric column; row withheld from STORE_MASTER pending source correction.',
       __file_name, __row_number, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD_RAW
WHERE __file_name LIKE '%datatypechange%'
  AND floor_area_sqft IS NOT NULL
  AND TRY_TO_NUMBER(floor_area_sqft) IS NULL;
-- -> 2 rows inserted

-- ---------------------------------------------------------------------------
-- 11.7 MERGE the valid rows, casting explicitly. MERGE not INSERT: these keys
-- already exist, so an INSERT would create a third copy.
-- COALESCE keeps an absent source value from erasing data we already hold.
-- ---------------------------------------------------------------------------
MERGE INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER t
USING (
  SELECT store_code, store_name, country_code, region_code, tax_jurisdiction_code,
         format_code, city, state_code, postal_code, address_line1,
         TRY_TO_NUMBER(latitude, 12, 6)                  AS latitude,
         TRY_TO_NUMBER(longitude, 12, 6)                 AS longitude,
         TRY_TO_DATE(store_open_date,'DD-MM-YYYY')       AS store_open_date,
         TRY_TO_DATE(store_close_date,'DD-MM-YYYY')      AS store_close_date,
         lifecycle_status,
         TRY_TO_NUMBER(floor_area_sqft)                  AS floor_area_sqft,
         TRY_TO_NUMBER(annual_rent_usd, 14, 2)           AS annual_rent_usd,
         TRY_TO_BOOLEAN(is_active)                       AS is_active,
         TRY_TO_DATE(effective_start_date,'DD-MM-YYYY')  AS effective_start_date,
         TRY_TO_DATE(effective_end_date,'DD-MM-YYYY')    AS effective_end_date,
         created_at, source_system,
         TRY_TO_BOOLEAN(Status)                          AS Status,
         __file_name, __row_number, __file_last_modified_ntz, __loaded_at
  FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD_RAW
  WHERE __file_name LIKE '%datatypechange%'
    AND (floor_area_sqft IS NULL OR TRY_TO_NUMBER(floor_area_sqft) IS NOT NULL)
) s
ON t.store_code = s.store_code
WHEN MATCHED THEN UPDATE SET
  t.format_code     = COALESCE(s.format_code,     t.format_code),
  t.city            = COALESCE(s.city,            t.city),
  t.state_code      = COALESCE(s.state_code,      t.state_code),
  t.postal_code     = COALESCE(s.postal_code,     t.postal_code),
  t.address_line1   = COALESCE(s.address_line1,   t.address_line1),
  t.latitude        = COALESCE(s.latitude,        t.latitude),
  t.longitude       = COALESCE(s.longitude,       t.longitude),
  t.floor_area_sqft = COALESCE(s.floor_area_sqft, t.floor_area_sqft),
  t.annual_rent_usd = COALESCE(s.annual_rent_usd, t.annual_rent_usd),
  t.STATUS          = COALESCE(s.STATUS,          t.STATUS),
  t.__file_name     = s.__file_name,
  t.__row_number    = s.__row_number,
  t.__loaded_at     = s.__loaded_at
WHEN NOT MATCHED THEN INSERT
  (store_code, store_name, country_code, region_code, tax_jurisdiction_code,
   format_code, city, state_code, postal_code, address_line1, latitude, longitude,
   store_open_date, store_close_date, lifecycle_status, floor_area_sqft,
   annual_rent_usd, is_active, effective_start_date, effective_end_date,
   created_at, source_system, STATUS,
   __file_name, __row_number, __file_last_modified_ntz, __loaded_at)
  VALUES
  (s.store_code, s.store_name, s.country_code, s.region_code, s.tax_jurisdiction_code,
   s.format_code, s.city, s.state_code, s.postal_code, s.address_line1, s.latitude, s.longitude,
   s.store_open_date, s.store_close_date, s.lifecycle_status, s.floor_area_sqft,
   s.annual_rent_usd, s.is_active, s.effective_start_date, s.effective_end_date,
   s.created_at, s.source_system, s.STATUS,
   s.__file_name, s.__row_number, s.__file_last_modified_ntz, s.__loaded_at);

/* -> 0 inserted, 6 updated.

   SIX, not three, and the number is diagnostic. Three source rows matched SIX
   target rows because US_0103..US_0105 each still have TWO rows in
   STORE_MASTER - the duplicates created by load 3 and not yet resolved.
   MERGE updated both twins of each key.

   Side effect: it REPAIRED the degraded twins, back-filling city, postal_code,
   address_line1, format_code, state_code and latitude that file 3 had dropped.
   Better data, but the duplicate keys remain. Run the de-duplication in
   10_idempotent_merge_fix.sql section 10.3 to finish the job - "6 updated"
   should read "3 updated" once the table holds one row per key.              */

-- ---------------------------------------------------------------------------
-- 11.8 Validation
-- ---------------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER)            AS total_rows,
  (SELECT COUNT(DISTINCT store_code) FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER) AS distinct_keys,
  (SELECT DATA_TYPE FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA='DATA_MIGRATION' AND TABLE_NAME='STORE_MASTER'
       AND COLUMN_NAME='FLOOR_AREA_SQFT')                                   AS floor_area_type,
  (SELECT COUNT(*) FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_REJECTS)    AS quarantined;
-- -> 131, 126, NUMBER, 2
--    Target stayed strongly typed and no row count was inflated.

SELECT store_code, reject_column, reject_raw_value, reject_expected_type, reject_reason
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_REJECTS
ORDER BY store_code;
-- -> US_0101 / US_0102, FLOOR_AREA_SQFT, 'testing', NUMBER(10,0)
