/* ===========================================================================
   04 - Target table with schema evolution enabled
   ---------------------------------------------------------------------------
   ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER

   DELIBERATELY built from FILE 1's 22 columns ONLY. `Status` is NOT declared
   here even though FILE 2 is known to contain it - the table must LEARN it from
   the data for evolution to be proven rather than asserted.

   Parquet needs only TWO settings for evolution:
       ENABLE_SCHEMA_EVOLUTION = TRUE      (here)
       MATCH_BY_COLUMN_NAME                (on the COPY)
   No PARSE_HEADER, no ERROR_ON_COLUMN_COUNT_MISMATCH, no STRIP_OUTER_ARRAY.
   The executing role needs EVOLVE SCHEMA (implied by OWNERSHIP).

   TYPE DECISIONS - every one overrides INFER_SCHEMA, and each for a reason
   --------------------------------------------------------------------

     postal_code -> VARCHAR(30), NOT NUMBER
       Non-negotiable. FILE 1 stores it as a string with leading zeros
       (08759, 02166, 00158, 03988, 06055 - 5 codes). FILE 2 stores it as
       INTEGER, where those zeros are ALREADY GONE at source. Adopting FILE 2's
       type would destroy FILE 1's correct data to match FILE 2's damaged data.
       Verified retained after load: 5 leading-zero codes intact.

     latitude / longitude -> NUMBER(9,6) / NUMBER(10,6), NOT REAL
       Parquet stores these as float64 and INFER_SCHEMA reports REAL. Exact
       decimal is the right choice for coordinates: binary floats cannot
       represent most decimal degrees exactly, so REAL invites drift in equality
       joins and GROUP BYs. NUMBER(10,6) also holds -180.000000, which the
       inferred precision would not.

     floor_area_sqft -> NUMBER(10,0)   (inferred NUMBER(38,0))
     annual_rent_usd -> NUMBER(14,2)   (inferred NUMBER(38,0))
       Parquet int64 maps to MAXIMUM precision, not to anything meaningful.
       38 digits for a floor area is not a declaration, it is an absence of one.
       Rent also needs scale 2 or cents are silently rounded.

     is_active -> BOOLEAN
       Source ships the string "Y" (FILE 1) and "Y"/"y" appears across files.
       Verified both coerce: 0 NULLs after load.

     store_close_date -> DATE
       INFER_SCHEMA said TEXT only because the column is 100% NULL in both files
       - no values to type, not evidence it holds strings.

   *** created_at - THE DELIBERATE TWO-COLUMN COMPROMISE ***
   --------------------------------------------------------------------
   FILE 1 has 121 rows of GENUINE timestamps. FILE 2 has 5 rows of '21:50.4',
   a time fragment that no format string can rescue. Three options were weighed:

     (a) Declare TIMESTAMP_NTZ
           Correct for the dominant data, but FILE 2's COPY fails outright and
           evolution never fires - so `Status` is never added and the whole
           demonstration stalls. Also fails the requirement to load both files.

     (b) Declare VARCHAR only
           Both files load, but 121 rows of valid timestamps are demoted to text
           to accommodate 5 bad ones. This is exactly the "just widen the column
           and let the corruption set the schema" move that should be resisted.

     (c) BOTH - chosen
           created_at      VARCHAR(50)     raw, faithful, preserves the evidence
           created_at_ntz  TIMESTAMP_NTZ   derived via TRY_TO_TIMESTAMP_NTZ

   Option (c) costs one extra column and loses nothing: 121 rows get real
   timestamps in created_at_ntz, the 5 corrupt rows are visibly NULL there with
   their raw text still inspectable in created_at. Consumers use created_at_ntz;
   the data-quality team uses created_at.

   created_at_ntz is added in 07, AFTER the loads, with a HAND-REVIEWED type.
   That is the point of contrast with schema evolution - see the
   EMPLOYEE_COUNT NUMBER(2,0) ceiling in 09.
   =========================================================================== */

CREATE TABLE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER (
  store_code               VARCHAR(30)     COMMENT 'Source store code, primary business key.',
  store_name               VARCHAR(150)    COMMENT 'Retail store name.',
  country_code             VARCHAR(10)     COMMENT 'ISO alpha-2 country code.',
  region_code              VARCHAR(20)     COMMENT 'Region code, e.g. AMER/EMEA/APAC.',
  tax_jurisdiction_code    VARCHAR(30)     COMMENT 'Sub-national tax jurisdiction code.',
  format_code              VARCHAR(20)     COMMENT 'Store format, e.g. FLG (flagship) or MINI.',
  city                     VARCHAR(100)    COMMENT 'City of the store location.',
  state_code               VARCHAR(20)     COMMENT 'State or province code.',
  postal_code              VARCHAR(30)     COMMENT 'Postal code as text. VARCHAR is mandatory: file 1 stores it as string with leading zeros, file 2 stores it as INTEGER which already lost them.',
  address_line1            VARCHAR(255)    COMMENT 'Street address line of the store.',
  latitude                 NUMBER(9,6)     COMMENT 'Store latitude in decimal degrees; Parquet stores this as float64.',
  longitude                NUMBER(10,6)    COMMENT 'Store longitude in decimal degrees; Parquet stores this as float64.',
  store_open_date          DATE            COMMENT 'Date the store opened.',
  store_close_date         DATE            COMMENT 'Date the store closed; NULL in all current source rows.',
  lifecycle_status         VARCHAR(30)     COMMENT 'Lifecycle state, e.g. ACTIVE/CLOSED.',
  floor_area_sqft          NUMBER(10,0)    COMMENT 'Retail floor area in square feet.',
  annual_rent_usd          NUMBER(14,2)    COMMENT 'Annual rent in USD.',
  is_active                BOOLEAN         COMMENT 'Active flag; source ships the string Y.',
  effective_start_date     DATE            COMMENT 'Date the record became effective.',
  effective_end_date       DATE            COMMENT 'Date the record stopped being effective.',
  created_at               VARCHAR(50)     COMMENT 'Raw creation timestamp as text. File 1 supplies a real Parquet timestamp, file 2 supplies the corrupted fragment 21:50.4; VARCHAR lands both losslessly. Use created_at_ntz for the typed value.',
  source_system            VARCHAR(50)     COMMENT 'Originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row came from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: row ordinal within the source file (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: staged file last modified time (METADATA$FILE_LAST_MODIFIED).',
  __loaded_at              TIMESTAMP_NTZ   COMMENT 'Audit: when the row was loaded (METADATA$START_SCAN_TIME).'
)
ENABLE_SCHEMA_EVOLUTION = TRUE
COMMENT = 'Unified store master Parquet target. Created from file 1 columns only; ENABLE_SCHEMA_EVOLUTION lets COPY add later columns such as Status automatically.';

-- Confirm the switch is on: expect ENABLE_SCHEMA_EVOLUTION = Y, 26 columns.
SHOW TABLES LIKE 'STORE_MASTER' IN SCHEMA ANALYSIS_DB.DATA_MIGRATION_PARQUET;

/* __loaded_at carries NO column DEFAULT on purpose. A DEFAULT is silently
   IGNORED by COPY when MATCH_BY_COLUMN_NAME is used - proven in the CSV
   exercise, where 126 rows landed NULL despite the DEFAULT being present in
   INFORMATION_SCHEMA.COLUMN_DEFAULT. The working mechanism is
   INCLUDE_METADATA = (__loaded_at = METADATA$START_SCAN_TIME).                */
