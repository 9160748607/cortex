/* ===========================================================================
   01 - Foundation objects: database, schema, file formats, stage
   ---------------------------------------------------------------------------
   Target: ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER

   TWO file formats are created, differing ONLY in DATE_FORMAT. This is not
   redundancy - the source files disagree on date convention:
     store_master.csv                   2017-09-01   (ISO, YYYY-MM-DD)
     store_master_1.csv                 01-09-2017   (day-first, DD-MM-YYYY)
     store_master_2_deleted_columns.csv 01-09-2017   (day-first, DD-MM-YYYY)

   Verified during development:
     TRY_TO_DATE('01-09-2017','DD-MM-YYYY') -> 2017-09-01   correct
     TRY_TO_DATE('01-09-2017')              -> NULL         AUTO cannot parse
   AUTO fails LOUDLY (NULL) rather than silently reading 1 Sep as 9 Jan, which
   is why a per-file DATE_FORMAT is a safe fix rather than a guess.

   THREE settings below are mandatory for schema evolution and each was found
   the hard way:

     PARSE_HEADER = TRUE
       Required for both INFER_SCHEMA and MATCH_BY_COLUMN_NAME on CSV. Note it
       is mutually exclusive with SKIP_HEADER, and a PARSE_HEADER format CANNOT
       be used in an ad-hoc SELECT over a stage - hence ff_store_master_inspect.

     ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
       Without this the load fails before name-matching is even attempted:
         "Number of columns in file (22) does not match that of the
          corresponding table (26)"
       The whole point of MATCH_BY_COLUMN_NAME is that the counts differ, so
       leaving this at its TRUE default makes evolution impossible.

     ENABLE_SCHEMA_EVOLUTION = TRUE   (on the table - see 04_create_target_table.sql)
   =========================================================================== */

CREATE DATABASE IF NOT EXISTS ANALYSIS_DB
  COMMENT = 'Analysis and data-migration workbench database.';

CREATE SCHEMA IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION
  COMMENT = 'Store master schema-drift and schema-evolution demonstration.';

-- ---------------------------------------------------------------------------
-- File format 1: ISO dates (store_master.csv)
-- ---------------------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.ff_store_master_iso
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'   -- required: 5 addresses contain embedded newlines
  TRIM_SPACE = TRUE
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('', 'NULL', 'null', 'N/A')
  DATE_FORMAT = 'YYYY-MM-DD'
  TIMESTAMP_FORMAT = 'AUTO'
  COMPRESSION = AUTO
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  COMMENT = 'CSV format for store master files using ISO YYYY-MM-DD dates; PARSE_HEADER enables INFER_SCHEMA and schema evolution.';

-- ---------------------------------------------------------------------------
-- File format 2: day-first dates (store_master_1.csv, *_deleted_columns.csv)
-- ---------------------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('', 'NULL', 'null', 'N/A')
  DATE_FORMAT = 'DD-MM-YYYY'
  TIMESTAMP_FORMAT = 'AUTO'
  COMPRESSION = AUTO
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  COMMENT = 'CSV format for store master files using DD-MM-YYYY dates; PARSE_HEADER enables INFER_SCHEMA and schema evolution.';

-- ---------------------------------------------------------------------------
-- File format 3: inspection only
-- A PARSE_HEADER format raises
--   "PARSE_HEADER is only allowed for CSV INFER_SCHEMA and MATCH_BY_COLUMN_NAME"
-- when used in SELECT, so ad-hoc staged-file profiling needs SKIP_HEADER.
-- Not used by any COPY.
-- ---------------------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.ff_store_master_inspect
  TYPE = CSV
  SKIP_HEADER = 1
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE
  EMPTY_FIELD_AS_NULL = TRUE
  COMMENT = 'Skip-header CSV format for ad-hoc staged-file inspection; PARSE_HEADER formats cannot be used in SELECT.';

-- ---------------------------------------------------------------------------
-- Stage. IF NOT EXISTS, never CREATE OR REPLACE - that silently discards
-- every staged file.
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.store_master_stg
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Internal stage holding store master source CSVs for the schema-drift demonstration.';

SHOW FILE FORMATS IN SCHEMA ANALYSIS_DB.DATA_MIGRATION;
SHOW STAGES IN SCHEMA ANALYSIS_DB.DATA_MIGRATION;
