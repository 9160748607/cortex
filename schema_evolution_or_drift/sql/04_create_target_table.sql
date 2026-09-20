/* ===========================================================================
   04 - Target table with schema evolution enabled
   ---------------------------------------------------------------------------
   ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER

   DELIBERATELY built from FILE 1's 22 columns ONLY. `Status` is NOT declared
   here even though we already know FILE 2 contains it. Pre-declaring it would
   make the demonstration circular - the table has to LEARN the column from the
   data for schema evolution to be proven rather than asserted.

   ENABLE_SCHEMA_EVOLUTION = TRUE is the switch. It works only in combination
   with COPY ... MATCH_BY_COLUMN_NAME and a PARSE_HEADER = TRUE file format.
   The executing role needs EVOLVE SCHEMA on the table (implied by OWNERSHIP).

   TYPE DECISIONS THAT DEPART FROM INFER_SCHEMA - each one is a judgement call,
   not an oversight:

     postal_code -> VARCHAR(30), NOT NUMBER
       Non-negotiable. FILE 2 inferred NUMBER(5,0); adopting that would strip
       leading zeros from all 121 FILE 1 rows. Verified retained after load:
       08759, 02166, 00158, 03988, 06055.

     store_close_date -> DATE, though inferred TEXT
       100% empty in every file, so INFER_SCHEMA had no values to type and fell
       back to TEXT. It is a date by name and pairs with store_open_date.

     created_at -> VARCHAR(50), though FILE 1 inferred TIMESTAMP_NTZ
       The files disagree irreconcilably: FILE 1 ships a full timestamp,
       FILES 2 and 3 ship '21:50.4' - a time fragment with no date, which no
       format string can rescue. VARCHAR lands both losslessly AND PRESERVES
       THE CORRUPTION AS EVIDENCE. Typing it TIMESTAMP would either fail the
       load or quietly null the bad values, destroying the proof that the
       upstream export is broken. Cast to a typed column downstream once the
       source is fixed.

     floor_area_sqft  NUMBER(5,0) -> NUMBER(10,0)
     annual_rent_usd  NUMBER(8,0) -> NUMBER(14,2)
     latitude         NUMBER(8,6) -> NUMBER(9,6)
     longitude        NUMBER(9,6) -> NUMBER(10,6)
       INFER_SCHEMA sizes to the observed 121-row sample with zero headroom.
       NUMBER(5,0) caps floor area at 99,999 sqft; NUMBER(9,6) cannot hold
       longitude -180.000000. Scale 0 on rent would silently round cents.

   AUDIT COLUMNS (__ prefix) make drift forensics possible. Without __file_name
   a NULL from "column absent in this file" is indistinguishable from a NULL
   meaning "value genuinely unknown" - see 08_validation.sql, which proves
   state_code holds 44 NULLs of BOTH kinds.
   =========================================================================== */

CREATE TABLE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER (
  store_code               VARCHAR(30)     COMMENT 'Source store code, primary business key.',
  store_name               VARCHAR(150)    COMMENT 'Retail store name.',
  country_code             VARCHAR(10)     COMMENT 'ISO alpha-2 country code.',
  region_code              VARCHAR(20)     COMMENT 'Region code, e.g. AMER/EMEA/APAC.',
  tax_jurisdiction_code    VARCHAR(30)     COMMENT 'Sub-national tax jurisdiction code.',
  format_code              VARCHAR(20)     COMMENT 'Store format, e.g. FLG (flagship) or MINI.',
  city                     VARCHAR(100)    COMMENT 'City of the store location.',
  state_code               VARCHAR(20)     COMMENT 'State or province code.',
  postal_code              VARCHAR(30)     COMMENT 'Postal code as text; VARCHAR deliberately, file 2 lost leading zeros by typing it numeric.',
  address_line1            VARCHAR(255)    COMMENT 'Street address line of the store.',
  latitude                 NUMBER(9,6)     COMMENT 'Store latitude in decimal degrees.',
  longitude                NUMBER(10,6)    COMMENT 'Store longitude in decimal degrees.',
  store_open_date          DATE            COMMENT 'Date the store opened; normalised from per-file date formats.',
  store_close_date         DATE            COMMENT 'Date the store closed; NULL while trading.',
  lifecycle_status         VARCHAR(30)     COMMENT 'Lifecycle state, e.g. ACTIVE/CLOSED.',
  floor_area_sqft          NUMBER(10,0)    COMMENT 'Retail floor area in square feet.',
  annual_rent_usd          NUMBER(14,2)    COMMENT 'Annual rent in USD.',
  is_active                BOOLEAN         COMMENT 'Active flag; source ships Y/N.',
  effective_start_date     DATE            COMMENT 'Date the record became effective.',
  effective_end_date       DATE            COMMENT 'Date the record stopped being effective.',
  created_at               VARCHAR(50)     COMMENT 'Source creation timestamp kept as raw text: file 1 ships a full timestamp, file 2 ships a corrupted time-only value that cannot be cast.',
  source_system            VARCHAR(50)     COMMENT 'Originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row came from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: staged file last modified time (METADATA$FILE_LAST_MODIFIED).',
  __loaded_at              TIMESTAMP_NTZ   COMMENT 'Audit: when the row was loaded into Snowflake (METADATA$START_SCAN_TIME).'
)
ENABLE_SCHEMA_EVOLUTION = TRUE
COMMENT = 'Unified store master target. Created from file 1 schema only; ENABLE_SCHEMA_EVOLUTION lets COPY add later columns such as Status automatically.';

-- Confirm the switch is on: expect ENABLE_SCHEMA_EVOLUTION = Y
SHOW TABLES LIKE 'STORE_MASTER' IN SCHEMA ANALYSIS_DB.DATA_MIGRATION;

/* NOTE on __loaded_at - a defect found and corrected during development.
   It was originally declared as:
       __loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
   A column DEFAULT is NOT applied by COPY when MATCH_BY_COLUMN_NAME is used.
   All 126 rows of the first two loads landed with __loaded_at = NULL despite
   the DEFAULT being present in INFORMATION_SCHEMA.COLUMN_DEFAULT.
   The working mechanism is INCLUDE_METADATA = (__loaded_at =
   METADATA$START_SCAN_TIME), applied in 05-07. The DEFAULT is dropped above to
   avoid implying it does something.                                          */
