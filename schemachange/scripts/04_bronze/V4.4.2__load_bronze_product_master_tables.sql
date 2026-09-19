/* ---------------------------------------------------------------------------
   V4.4.2 - COPY INTO the 5 product-master bronze tables

   One COPY per file: each file maps to a different table at a different grain,
   so unlike customer-master there is nothing to collapse into a PATTERN.

   Uses COMMON.ff_csv_load (SKIP_HEADER = 1). ff_csv_infer is not valid for
   COPY INTO - PARSE_HEADER = TRUE is accepted only by INFER_SCHEMA.

   Transformation form COPY INTO ... FROM (SELECT ...) is required to reference
   the METADATA$ pseudo-columns, which forces positional $n binding and makes
   CSV column ORDER a hard contract. A same-type source reorder would load
   wrong values into wrong columns without erroring - re-run INFER_SCHEMA
   whenever a source schema change is announced.

   The two all-NULL date columns (discontinue_date, local_discontinue_date) are
   cast ::DATE to match the deliberate type override in V4.4.1 - see the header
   comment there for why they are not TEXT.

   ON_ERROR = ABORT_STATEMENT, not CONTINUE: these tables form the product
   hierarchy that facts join through, and a partial load silently drops facts.

   Idempotency: COPY load history makes a re-run a no-op for files already
   loaded. FORCE = TRUE deliberately omitted.

   Load order follows the hierarchy (category -> family -> model -> SKU ->
   availability). Bronze has no enforced FKs so this is not required by the
   engine, but it keeps the sequence readable and means a mid-script failure
   leaves a prefix of the hierarchy rather than dangling leaves.

   Verified after load: 10 / 43 / 111 / 650 / 22,750 rows, zero orphans at
   every level. 650 SKUs x 35 countries = 22,750 - availability is a complete
   cross product in this dataset, not a sparse bridge.

   Depends on: V4.1.1 (stage), V4.4.1 (tables), V3.1.1 (ff_csv_load).
   --------------------------------------------------------------------------- */

COPY INTO {{ database }}.BRONZE.br_product_category_master
FROM (
  SELECT
      $1::VARCHAR,        -- category_code
      $2::VARCHAR,        -- category_name
      $3::VARCHAR,        -- reporting_segment
      $4::BOOLEAN,        -- is_active
      $5::DATE,           -- effective_start_date
      $6::DATE,           -- effective_end_date
      $7::TIMESTAMP_NTZ,  -- created_at
      $8::VARCHAR,        -- source_system
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/product-master/product_category_master.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;

COPY INTO {{ database }}.BRONZE.br_product_family_master
FROM (
  SELECT
      $1::VARCHAR,        -- family_code
      $2::VARCHAR,        -- family_name
      $3::VARCHAR,        -- category_code
      $4::NUMBER(4,0),    -- launch_year
      $5::BOOLEAN,        -- is_active
      $6::VARCHAR,        -- lifecycle_status
      $7::TIMESTAMP_NTZ,  -- created_at
      $8::VARCHAR,        -- source_system
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/product-master/product_family_master.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;

COPY INTO {{ database }}.BRONZE.br_product_model_master
FROM (
  SELECT
      $1::VARCHAR,        -- model_code
      $2::VARCHAR,        -- model_name
      $3::VARCHAR,        -- family_code
      $4::DATE,           -- launch_date
      $5::DATE,           -- discontinue_date (all NULL in source; see V4.4.1)
      $6::VARCHAR,        -- lifecycle_status
      $7::BOOLEAN,        -- is_active
      $8::TIMESTAMP_NTZ,  -- created_at
      $9::VARCHAR,        -- source_system
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/product-master/product_model_master.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;

COPY INTO {{ database }}.BRONZE.br_product_sku_master
FROM (
  SELECT
      $1::VARCHAR,        -- sku_code
      $2::VARCHAR,        -- model_code
      $3::VARCHAR,        -- variant
      $4::VARCHAR,        -- price_tier
      $5::DATE,           -- global_launch_date
      $6::BOOLEAN,        -- is_active
      $7::TIMESTAMP_NTZ,  -- created_at
      $8::VARCHAR,        -- source_system
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/product-master/product_sku_master.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;

COPY INTO {{ database }}.BRONZE.br_product_country_availability
FROM (
  SELECT
      $1::VARCHAR,        -- sku_code
      $2::VARCHAR,        -- country_code
      $3::VARCHAR,        -- local_part_number
      $4::DATE,           -- local_launch_date
      $5::DATE,           -- local_discontinue_date (all NULL in source; see V4.4.1)
      $6::BOOLEAN,        -- is_available
      $7::TIMESTAMP_NTZ,  -- created_at
      $8::VARCHAR,        -- source_system
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/product-master/product_country_availability.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;
