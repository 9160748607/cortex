/* ===========================================================================
   04 - Target table with schema evolution enabled
   ---------------------------------------------------------------------------
   ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER

   DELIBERATELY built from FILE 1's 22 keys ONLY. `Status` is NOT declared here
   even though FILE 2 is known to contain it. Pre-declaring it would make the
   demonstration circular - the table must LEARN the key from the data for
   evolution to be proven rather than asserted.

   ENABLE_SCHEMA_EVOLUTION = TRUE is the switch. For JSON it needs only ONE
   companion setting - MATCH_BY_COLUMN_NAME on the COPY. The two CSV
   prerequisites (PARSE_HEADER, ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE) do not
   apply, because JSON keys are self-describing. The executing role needs
   EVOLVE SCHEMA on the table (implied by OWNERSHIP).

   TYPE DECISIONS
   --------------------------------------------------------------------
   Most columns are strongly typed with confidence, because the 2.3 coercion
   probes proved each one converts:

     is_active -> BOOLEAN        source ships the string "Y"; verified "Y" -> TRUE
     created_at -> TIMESTAMP_NTZ clean ISO timestamps in both files
     store_open_date, effective_start_date, effective_end_date -> DATE
     postal_code -> VARCHAR(30)  JSON quotes it, so leading zeros arrive intact
                                 (08759, 02166, 00158 ...). Keeping it VARCHAR
                                 preserves them; NUMBER would destroy them.

   Inferred numerics widened - INFER_SCHEMA sizes to the observed sample with
   zero headroom:
     floor_area_sqft  NUMBER(5,0) -> NUMBER(10,0)   inferred cap 99,999 sqft
     annual_rent_usd  NUMBER(8,0) -> NUMBER(14,2)   inferred cap ~100M, and
                                                    scale 0 would round cents
     latitude         NUMBER(8,6) -> NUMBER(9,6)
     longitude        NUMBER(9,6) -> NUMBER(10,6)   inferred precision cannot
                                                    hold -180.000000

   *** store_close_date -> VARCHAR(50), NOT DATE. TWO FAILURES GOT US HERE. ***

   Attempt 1 - declared DATE, the semantically correct choice:
       COPY -> Can't parse 'NaN' as date with format 'YYYY-MM-DD'
     MATCH_BY_COLUMN_NAME cannot transform, so there was no way to intercept the
     value mid-load.

   Attempt 2 - kept DATE, added NULL_IF = ('NaN', ...) to the file format:
       COPY -> STILL FAILED with the identical error.
     Why: NULL_IF compares STRINGS. Snowflake had already parsed NaN as a
     DOUBLE (TYPEOF confirms it), so the string comparison never matched and
     the DATE coercion was attempted on a float.

   Attempt 3 - declared VARCHAR and kept NULL_IF: WORKS.
     The VARIANT DOUBLE renders to the string 'NaN' on its way into a VARCHAR
     column, NULL_IF matches that string, and the value lands as a clean NULL.
     Verified after load: all 126 rows NULL, zero rows holding the text 'NaN'.

   So the column is VARCHAR but contains proper NULLs, not junk. It is typed
   VARCHAR only to give NULL_IF a string to match. If real close dates ever
   arrive, convert with TRY_TO_DATE downstream - or fix the export to emit JSON
   null instead of NaN, which is the actual remedy.

   NOTE ON CREATE OR REPLACE: attempt 3 required changing DATE -> VARCHAR, which
   ALTER COLUMN cannot do. CREATE OR REPLACE was used once, only after verifying
   the table held 0 rows (both prior COPYs failed atomically) in a schema
   created minutes earlier with no dependents. It is IF NOT EXISTS below so a
   fresh run is safe and idempotent.
   =========================================================================== */

CREATE TABLE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER (
  store_code               VARCHAR(30)     COMMENT 'Source store code, primary business key.',
  store_name               VARCHAR(150)    COMMENT 'Retail store name.',
  country_code             VARCHAR(10)     COMMENT 'ISO alpha-2 country code.',
  region_code              VARCHAR(20)     COMMENT 'Region code, e.g. AMER/EMEA/APAC.',
  tax_jurisdiction_code    VARCHAR(30)     COMMENT 'Sub-national tax jurisdiction code.',
  format_code              VARCHAR(20)     COMMENT 'Store format, e.g. FLG (flagship) or MINI.',
  city                     VARCHAR(100)    COMMENT 'City of the store location.',
  state_code               VARCHAR(20)     COMMENT 'State or province code.',
  postal_code              VARCHAR(30)     COMMENT 'Postal code as text; JSON supplies it quoted so leading zeros survive.',
  address_line1            VARCHAR(255)    COMMENT 'Street address line of the store.',
  latitude                 NUMBER(9,6)     COMMENT 'Store latitude in decimal degrees.',
  longitude                NUMBER(10,6)    COMMENT 'Store longitude in decimal degrees.',
  store_open_date          DATE            COMMENT 'Date the store opened.',
  store_close_date         VARCHAR(50)     COMMENT 'Close date, all NULL in current sources. Source ships the non-standard JSON literal NaN which Snowflake parses as DOUBLE; a DATE target fails outright, so this lands as VARCHAR where file-format NULL_IF can match the string NaN and yield NULL. Convert with TRY_TO_DATE if real dates ever arrive.',
  lifecycle_status         VARCHAR(30)     COMMENT 'Lifecycle state, e.g. ACTIVE/CLOSED.',
  floor_area_sqft          NUMBER(10,0)    COMMENT 'Retail floor area in square feet.',
  annual_rent_usd          NUMBER(14,2)    COMMENT 'Annual rent in USD.',
  is_active                BOOLEAN         COMMENT 'Active flag; source ships the string Y.',
  effective_start_date     DATE            COMMENT 'Date the record became effective.',
  effective_end_date       DATE            COMMENT 'Date the record stopped being effective.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row came from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: row ordinal within the source file (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: staged file last modified time (METADATA$FILE_LAST_MODIFIED).',
  __loaded_at              TIMESTAMP_NTZ   COMMENT 'Audit: when the row was loaded (METADATA$START_SCAN_TIME).'
)
ENABLE_SCHEMA_EVOLUTION = TRUE
COMMENT = 'Unified store master JSON target. Created from file 1 keys only; ENABLE_SCHEMA_EVOLUTION lets COPY add later keys such as Status automatically.';

-- Confirm the switch is on: expect ENABLE_SCHEMA_EVOLUTION = Y, 26 columns.
SHOW TABLES LIKE 'STORE_MASTER' IN SCHEMA ANALYSIS_DB.DATA_MIGRATION_JSON;

/* __loaded_at carries NO column DEFAULT on purpose. A DEFAULT is silently
   IGNORED by COPY when MATCH_BY_COLUMN_NAME is used - proven in the CSV
   exercise, where 126 rows landed NULL despite the DEFAULT being present in
   INFORMATION_SCHEMA.COLUMN_DEFAULT. The working mechanism is
   INCLUDE_METADATA = (__loaded_at = METADATA$START_SCAN_TIME), applied in the
   load scripts.                                                              */
