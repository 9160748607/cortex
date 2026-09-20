/* ---------------------------------------------------------------------------
   V4.5.2 - COPY INTO the bronze store-master table

   Single file, single COPY - no PATTERN needed.

   Uses COMMON.ff_csv_load (SKIP_HEADER = 1). ff_csv_infer is not valid for
   COPY INTO - PARSE_HEADER = TRUE is accepted only by INFER_SCHEMA.

   Transformation form COPY INTO ... FROM (SELECT ...) is required to reference
   the METADATA$ pseudo-columns, which forces positional $1..$22 binding and
   makes CSV column ORDER a hard contract. A same-type source reorder would
   load wrong values into wrong columns without erroring - re-run INFER_SCHEMA
   whenever a source schema change is announced.

   Casts intentionally mirror the widened types in V4.5.1 rather than the raw
   INFER_SCHEMA output; casting narrower here would defeat the point of
   widening the column. store_close_date is cast ::DATE despite inferring as
   TEXT - see the V4.5.1 header for why.

   ON_ERROR = ABORT_STATEMENT, not CONTINUE: stores are a dimension that facts
   join through, and a partial load silently drops sales rows.

   Idempotency: COPY load history makes a re-run a no-op for files already
   loaded. FORCE = TRUE deliberately omitted.

   Verified after load: 121 rows, 121 distinct store_code, 24 countries,
   zero orphans against country master and region master. Stores appear only in
   countries flagged retail_store_supported - 0 violations.

   Depends on: V4.1.1 (stage), V4.5.1 (table), V3.1.1 (ff_csv_load).
   --------------------------------------------------------------------------- */

COPY INTO {{ database }}.BRONZE.br_store_master
FROM (
  SELECT
      $1::VARCHAR,         -- store_code
      $2::VARCHAR,         -- store_name
      $3::VARCHAR,         -- country_code
      $4::VARCHAR,         -- region_code
      $5::VARCHAR,         -- tax_jurisdiction_code
      $6::VARCHAR,         -- format_code
      $7::VARCHAR,         -- city
      $8::VARCHAR,         -- state_code
      $9::VARCHAR,         -- postal_code
      $10::VARCHAR,        -- address_line1
      $11::NUMBER(9,6),    -- latitude
      $12::NUMBER(10,6),   -- longitude
      $13::DATE,           -- store_open_date
      $14::DATE,           -- store_close_date (all NULL in source; see V4.5.1)
      $15::VARCHAR,        -- lifecycle_status
      $16::NUMBER(10,0),   -- floor_area_sqft
      $17::NUMBER(14,2),   -- annual_rent_usd
      $18::BOOLEAN,        -- is_active
      $19::DATE,           -- effective_start_date
      $20::DATE,           -- effective_end_date
      $21::TIMESTAMP_NTZ,  -- created_at
      $22::VARCHAR,        -- source_system
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/store-master/store_master.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;
