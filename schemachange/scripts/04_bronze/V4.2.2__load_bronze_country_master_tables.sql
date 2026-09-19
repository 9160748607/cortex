/* ---------------------------------------------------------------------------
   V4.2.2 - COPY INTO the 4 country-master bronze tables

   Uses COMMON.ff_csv_load (SKIP_HEADER = 1) so the header line is not loaded
   as data. COMMON.ff_csv_infer is NOT usable here: PARSE_HEADER = TRUE is only
   valid for INFER_SCHEMA, and COPY INTO rejects it.

   Each COPY uses the transformation form - COPY INTO ... FROM (SELECT ...) -
   rather than a bare COPY, because METADATA$ pseudo-columns can only be
   referenced inside a SELECT over the stage. That is also why every source
   column has to be listed positionally as $1..$n with an explicit cast.

   Positional $n binding means column ORDER in the CSV is a hard contract. If a
   source ever reorders or inserts a column, this script loads the wrong data
   into the wrong column silently. ON_ERROR = ABORT_STATEMENT limits the damage
   to type-incompatible shifts; a same-type reorder would still slip through,
   so re-run INFER_SCHEMA whenever a source schema change is announced.

   ON_ERROR = ABORT_STATEMENT (not CONTINUE) is deliberate for master/reference
   data: a partially loaded dimension is worse than no load, since silver joins
   would quietly drop facts for the missing keys.

   Idempotency: COPY INTO load history makes re-running a no-op for files
   already loaded, so this script is safe to replay even though it is a V
   script. A genuine reload requires FORCE = TRUE, which is left off on purpose.

   Depends on: V4.1.1 (stage), V4.2.1 (tables), V3.1.1 (ff_csv_load).
   --------------------------------------------------------------------------- */

COPY INTO {{ database }}.BRONZE.br_region_master
FROM (
  SELECT
      $1::VARCHAR,        -- region_code
      $2::VARCHAR,        -- region_name
      $3::BOOLEAN,        -- is_active
      $4::DATE,           -- effective_start_date
      $5::DATE,           -- effective_end_date
      $6::TIMESTAMP_NTZ,  -- created_at
      $7::VARCHAR,        -- source_system
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/country-master/region_master.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;

COPY INTO {{ database }}.BRONZE.br_currency_master
FROM (
  SELECT
      $1::VARCHAR,        -- currency_code
      $2::VARCHAR,        -- currency_name
      $3::VARCHAR,        -- currency_symbol
      $4::NUMBER(2,0),    -- minor_unit
      $5::BOOLEAN,        -- is_active
      $6::DATE,           -- effective_start_date
      $7::DATE,           -- effective_end_date
      $8::TIMESTAMP_NTZ,  -- created_at
      $9::VARCHAR,        -- source_system
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/country-master/currency_master.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;

COPY INTO {{ database }}.BRONZE.br_tax_master
FROM (
  SELECT
      $1::VARCHAR,        -- tax_code
      $2::VARCHAR,        -- tax_type
      $3::NUMBER(7,4),    -- tax_rate
      $4::BOOLEAN,        -- tax_inclusive_flag
      $5::DATE,           -- effective_start_date
      $6::DATE,           -- effective_end_date
      $7::BOOLEAN,        -- is_active
      $8::TIMESTAMP_NTZ,  -- created_at
      $9::VARCHAR,        -- source_system
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/country-master/tax_master.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;

COPY INTO {{ database }}.BRONZE.br_country_master
FROM (
  SELECT
      $1::VARCHAR,        -- country_code
      $2::VARCHAR,        -- country_name
      $3::VARCHAR,        -- iso_alpha3
      $4::VARCHAR,        -- region_code
      $5::VARCHAR,        -- apple_fiscal_segment
      $6::VARCHAR,        -- currency_code
      $7::VARCHAR,        -- tax_code
      $8::VARCHAR,        -- primary_language
      $9::VARCHAR,        -- timezone
      $10::BOOLEAN,       -- ecommerce_supported
      $11::BOOLEAN,       -- retail_store_supported
      $12::VARCHAR,       -- market_tier
      $13::NUMBER(10,2),  -- population_millions
      $14::NUMBER(14,2),  -- gdp_usd_billions
      $15::BOOLEAN,       -- gdpr_applicable
      $16::BOOLEAN,       -- is_active
      $17::DATE,          -- effective_start_date
      $18::DATE,          -- effective_end_date
      $19::TIMESTAMP_NTZ, -- created_at
      $20::VARCHAR,       -- source_system
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/country-master/country_master.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;
