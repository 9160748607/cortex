/*
  Apple Inc Sales Analytics - Medallion Architecture
  Step 01: sales_dev foundation (database, schemas, common objects)

  Architectural rules applied:
    - Dev/QA objects are TRANSIENT (no fail-safe cost)
    - CREATE ... IF NOT EXISTS everywhere
    - Short, meaningful COMMENT on every object
    - Common utilities live in the COMMON schema

  Deferred: chargeback TAGs and masking policies must live in the
  governance database, which is created in a later step.
*/

-- ---------------------------------------------------------------------------
-- Database
-- ---------------------------------------------------------------------------
CREATE TRANSIENT DATABASE IF NOT EXISTS sales_dev
  DATA_RETENTION_TIME_IN_DAYS = 1
  COMMENT = 'Dev environment for Apple Inc sales analytics; medallion layers. Transient - no fail-safe cost.';

-- ---------------------------------------------------------------------------
-- Medallion schemas
-- ---------------------------------------------------------------------------
CREATE TRANSIENT SCHEMA IF NOT EXISTS sales_dev.bronze
  DATA_RETENTION_TIME_IN_DAYS = 1
  COMMENT = 'Bronze zone - raw CSV data landing as-is from source files.';

CREATE TRANSIENT SCHEMA IF NOT EXISTS sales_dev.silver
  DATA_RETENTION_TIME_IN_DAYS = 1
  COMMENT = 'Silver zone - cleaned and curated data built via incremental dynamic tables.';

CREATE TRANSIENT SCHEMA IF NOT EXISTS sales_dev.gold
  DATA_RETENTION_TIME_IN_DAYS = 1
  COMMENT = 'Gold zone - modelled fact and dimension tables, aggregates and semantic view.';

CREATE TRANSIENT SCHEMA IF NOT EXISTS sales_dev.common
  DATA_RETENTION_TIME_IN_DAYS = 1
  COMMENT = 'Common utilities - file formats, stages, sequences, UDFs and procedures.';

-- ---------------------------------------------------------------------------
-- Common: file formats
-- PARSE_HEADER and SKIP_HEADER are mutually exclusive, so two formats are
-- required: one for INFER_SCHEMA and one for COPY INTO.
-- ---------------------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS sales_dev.common.ff_csv_load
  TYPE = CSV
  SKIP_HEADER = 1
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE
  NULL_IF = ('', 'NULL', 'null', 'N/A')
  EMPTY_FIELD_AS_NULL = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  COMPRESSION = AUTO
  COMMENT = 'CSV format for COPY INTO bronze - skips header row.';

CREATE FILE FORMAT IF NOT EXISTS sales_dev.common.ff_csv_infer
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE
  NULL_IF = ('', 'NULL', 'null', 'N/A')
  EMPTY_FIELD_AS_NULL = TRUE
  COMPRESSION = AUTO
  COMMENT = 'CSV format for INFER_SCHEMA - reads header row as column names.';

-- ---------------------------------------------------------------------------
-- Common: internal stage for source CSV landing
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS sales_dev.common.stg_sales_landing
  DIRECTORY = (ENABLE = TRUE)
  FILE_FORMAT = sales_dev.common.ff_csv_load
  COMMENT = 'Internal stage for landing Apple sales source CSV files before COPY to bronze.';

-- ---------------------------------------------------------------------------
-- Common: surrogate key sequences for gold dimensions
-- ---------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS sales_dev.common.seq_dim_customer
  START = 1 INCREMENT = 1 COMMENT = 'Surrogate key for gold dim_customer.';

CREATE SEQUENCE IF NOT EXISTS sales_dev.common.seq_dim_store
  START = 1 INCREMENT = 1 COMMENT = 'Surrogate key for gold dim_store.';

CREATE SEQUENCE IF NOT EXISTS sales_dev.common.seq_dim_product
  START = 1 INCREMENT = 1 COMMENT = 'Surrogate key for gold dim_product.';

CREATE SEQUENCE IF NOT EXISTS sales_dev.common.seq_dim_geography
  START = 1 INCREMENT = 1 COMMENT = 'Surrogate key for gold dim_geography (region/country).';

CREATE SEQUENCE IF NOT EXISTS sales_dev.common.seq_dim_currency
  START = 1 INCREMENT = 1 COMMENT = 'Surrogate key for gold dim_currency.';

CREATE SEQUENCE IF NOT EXISTS sales_dev.common.seq_dim_tax
  START = 1 INCREMENT = 1 COMMENT = 'Surrogate key for gold dim_tax.';
