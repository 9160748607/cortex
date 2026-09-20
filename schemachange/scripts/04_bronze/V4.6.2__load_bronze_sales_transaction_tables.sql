/* ---------------------------------------------------------------------------
   V4.6.2 - COPY INTO the 2 sales-transaction bronze tables

   One COPY per file: header and item are different grains and different tables.

   Uses COMMON.ff_csv_load (SKIP_HEADER = 1). ff_csv_infer is not valid for
   COPY INTO - PARSE_HEADER = TRUE is accepted only by INFER_SCHEMA.

   Transformation form COPY INTO ... FROM (SELECT ...) is required to reference
   the METADATA$ pseudo-columns, which forces positional $n binding and makes
   CSV column ORDER a hard contract. That risk is highest on these two files:
   the money columns are adjacent and same-typed, so a source reorder of, say,
   total_discount and total_tax would load silently and produce wrong revenue
   with no error anywhere. Re-run INFER_SCHEMA on any announced source change,
   and re-check the arithmetic assertions recorded in V4.6.1.

   Casts mirror the widened types in V4.6.1, not the raw INFER_SCHEMA output -
   casting to the narrow inferred precision here would defeat the widening and
   reintroduce the 9,999.99 / single-digit-quantity ceilings.

   ON_ERROR = ABORT_STATEMENT, not CONTINUE: these are the revenue facts. A
   partial load produces a plausible-looking but understated revenue figure,
   which is the worst possible failure mode - far more dangerous than a visible
   abort, because nothing downstream would flag it.

   Idempotency: COPY load history makes a re-run a no-op for files already
   loaded. FORCE = TRUE deliberately omitted - on a fact table an accidental
   forced reload would double-count every transaction.

   Load order is header then item, matching the dependency direction. Bronze has
   no enforced FKs so the engine does not require it, but a mid-script failure
   then leaves headers without items rather than orphan items.

   Verified after load: 77,155 rows each, keys unique on both sides, zero
   orphans in either direction, zero orphans to customer / country / currency /
   store / SKU / category dimensions.

   Scope: 2019 only, matching what is staged. Later years are a new versioned
   script (or the delta-ingest task in 07_orchestration), never an edit to this
   one - schemachange checksums applied scripts. Note the 24 rows timestamped
   2020-01-01 already present in the 2019 file: the 2020 load must not assume
   the file year partitions cleanly.

   Depends on: V4.1.1 (stage), V4.6.1 (tables), V3.1.1 (ff_csv_load).
   --------------------------------------------------------------------------- */

COPY INTO {{ database }}.BRONZE.br_sales_header
FROM (
  SELECT
      $1::VARCHAR,         -- transaction_sk
      $2::VARCHAR,         -- transaction_id
      $3::TIMESTAMP_NTZ,   -- transaction_timestamp
      $4::VARCHAR,         -- customer_id
      $5::VARCHAR,         -- store_id (NULL when channel is ONLINE)
      $6::VARCHAR,         -- channel_id
      $7::VARCHAR,         -- country_code
      $8::VARCHAR,         -- payment_method
      $9::VARCHAR,         -- currency
      $10::NUMBER(18,2),   -- gross_amount
      $11::NUMBER(18,2),   -- total_discount
      $12::NUMBER(18,2),   -- total_tax
      $13::NUMBER(18,2),   -- net_total
      $14::TIMESTAMP_NTZ,  -- created_at
      $15::VARCHAR,        -- source_system
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/sales-transaction/2019/sales_header_2019.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;

COPY INTO {{ database }}.BRONZE.br_sales_item
FROM (
  SELECT
      $1::VARCHAR,         -- transaction_line_id
      $2::VARCHAR,         -- transaction_sk
      $3::NUMBER(9,0),     -- line_number
      $4::VARCHAR,         -- sku_code
      $5::VARCHAR,         -- category_code
      $6::NUMBER(9,0),     -- quantity
      $7::NUMBER(18,2),    -- unit_price
      $8::NUMBER(18,2),    -- discount_amount
      $9::NUMBER(18,2),    -- tax_amount
      $10::NUMBER(18,2),   -- line_total
      $11::TIMESTAMP_NTZ,  -- created_at
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER,
      METADATA$FILE_LAST_MODIFIED
  FROM @{{ database }}.BRONZE.sales_csv_stg/initial-load/sales-transaction/2019/sales_item_2019.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = '{{ database }}.COMMON.ff_csv_load')
ON_ERROR = ABORT_STATEMENT;
