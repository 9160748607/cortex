/* ===========================================================================
   01 - Foundation objects: schema, JSON file format, stage
   ---------------------------------------------------------------------------
   Target: ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER

   A SEPARATE schema from DATA_MIGRATION deliberately. That schema already holds
   the CSV STORE_MASTER from the CSV exercise; reusing it would collide on the
   table name and mix two unrelated demonstrations.

   JSON needs FAR LESS format configuration than CSV. Two CSV prerequisites for
   schema evolution simply DO NOT EXIST here:

     PARSE_HEADER                     - CSV-only. JSON keys are self-describing,
                                        so there is no header row to parse.
     ERROR_ON_COLUMN_COUNT_MISMATCH   - CSV-only. JSON objects have no fixed
                                        column count to mismatch against.

   What JSON does need:

     STRIP_OUTER_ARRAY = TRUE
       Both source files are a single top-level array: [ {...}, {...} ].
       Without this the whole array loads as ONE row containing 121 objects.
       With it, each array element becomes its own row.

     NULL_IF = ('NaN', ...)
       This is NOT boilerplate. Both source files contain
           "store_close_date": NaN
       and NaN is NOT VALID JSON - the spec has no such literal. See
       02_schema_detection.sql for the full investigation and
       04_create_target_table.sql for why NULL_IF only works in combination
       with a VARCHAR target column.

   NOTE: NULL_IF was added by ALTER after the first load attempt failed. It is
   folded into the CREATE below so a fresh run works first time.
   =========================================================================== */

CREATE SCHEMA IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_JSON
  COMMENT = 'Store master JSON schema-drift and schema-evolution demonstration.';

-- ---------------------------------------------------------------------------
-- JSON file format. Used for BOTH files and for INFER_SCHEMA.
-- Unlike the CSV exercise there is no per-file variant: both JSON files use
-- ISO dates, so one format serves both.
-- ---------------------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json
  TYPE = JSON
  STRIP_OUTER_ARRAY = TRUE
  DATE_FORMAT = 'YYYY-MM-DD'
  TIMESTAMP_FORMAT = 'AUTO'
  COMPRESSION = AUTO
  NULL_IF = ('NaN', 'nan', 'NULL', 'null', '')
  COMMENT = 'JSON format for store master files. STRIP_OUTER_ARRAY turns each array element into a row; NULL_IF neutralises the invalid NaN literal in store_close_date.';

-- ---------------------------------------------------------------------------
-- Stage. IF NOT EXISTS, never CREATE OR REPLACE - that silently discards every
-- staged file.
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Internal stage holding store master JSON source files for the schema-drift demonstration.';

SHOW FILE FORMATS IN SCHEMA ANALYSIS_DB.DATA_MIGRATION_JSON;
SHOW STAGES IN SCHEMA ANALYSIS_DB.DATA_MIGRATION_JSON;
LIST @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/;
