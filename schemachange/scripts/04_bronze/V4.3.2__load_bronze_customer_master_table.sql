/* ---------------------------------------------------------------------------
   V4.3.2 - COPY INTO the bronze customer-master table

   Loads all 35 country files for a year in ONE statement by pointing at the
   year prefix and filtering with PATTERN, instead of 35 separate COPY calls.
   Snowflake parallelises file scanning within a single COPY, so this is both
   faster and far less code to keep in step.

   PATTERN anchors on the full expected filename shape rather than a loose
   '.*[.]csv[.]gz'. That matters: the prefix is a shared stage, and a loose
   pattern would happily ingest any unrelated CSV that lands under it. The
   [A-Z]{2} enforces the country-folder naming convention as a side effect.
   Note PATTERN is regex over the full path and is case-sensitive.

   Uses COMMON.ff_csv_load (SKIP_HEADER = 1). ff_csv_infer is not valid for
   COPY INTO - PARSE_HEADER = TRUE is accepted only by INFER_SCHEMA.

   Transformation form COPY INTO ... FROM (SELECT ...) is required to reference
   the METADATA$ pseudo-columns, which forces positional $1..$26 binding. That
   makes CSV column ORDER a hard contract: a same-type source reorder would
   load wrong values into wrong columns without erroring. Re-run INFER_SCHEMA
   over the year prefix whenever a source schema change is announced.

   ON_ERROR = ABORT_STATEMENT, not CONTINUE: a half-loaded customer dimension
   silently drops facts from every downstream join, which is worse than a
   visible failure.

   Idempotency: COPY load history makes a re-run a no-op for files already
   loaded, so replaying this script is safe. FORCE = TRUE is deliberately
   omitted - a genuine reload should be an explicit, deliberate act.

   Scope: 2019 only, matching what is currently staged. Later years are a new
   versioned script (or the delta-ingest task in 07_orchestration), never an
   edit to this one - schemachange checksums applied scripts.

   Depends on: V4.1.1 (stage), V4.3.1 (table), V3.1.1 (ff_csv_load).
   --------------------------------------------------------------------------- */

COPY INTO {{ database }}.BRONZE.br_customer_master
FROM (
  SELECT
      $1::VARCHAR,         -- customer_id
      $2::VARCHAR,         -- customer_number
      $3::VARCHAR,         -- first_name
      $4::VARCHAR,         -- last_name
      $5::VARCHAR,         -- full_name
      $6::VARCHAR,         -- gender
      $7::DATE,            -- date_of_birth
      $8::VARCHAR,         -- email
      $9::VARCHAR,         -- phone_number
      $10::VARCHAR,        -- street_address
      $11::VARCHAR,        -- city
      $12::VARCHAR,        -- state_province
      $13::VARCHAR,        -- postal_code
      $14::VARCHAR,        -- country_code
      $15::VARCHAR,        -- country_name
      $16::VARCHAR,        -- region
      $17::VARCHAR,        -- preferred_language
      $18::VARCHAR,        -- customer_segment
      $19::VARCHAR,        -- loyalty_tier
      $20::DATE,           -- registration_date
      $21::NUMBER(4,0),    -- acquisition_year
      $22::VARCHAR,        -- customer_type
      $23::BOOLEAN,        -- is_active
      $24::VARCHAR,        -- source_system
      $25::TIMESTAMP_NTZ,  -- created_at (date-only in source, widened)
      $26::TIMESTAMP_NTZ,  -- updated_at
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/customer-master/2019/
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
PATTERN = '.*customer_master_2019_[A-Z]{2}[.]csv[.]gz'
ON_ERROR = ABORT_STATEMENT;
