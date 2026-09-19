/* ---------------------------------------------------------------------------
   V4.1.1 - Internal CSV landing stage (bronze)

   Data-flow rule 1: source CSVs are loaded here with PUT (snow stage copy)
   before COPY INTO moves them to bronze tables.

   Placed in BRONZE rather than COMMON deliberately: bronze IS the landing
   zone, so the stage that holds raw arriving files belongs with it. Note 2
   scopes COMMON to shared utilities (file formats, sequences, UDFs), which
   this is not - it stores data.

   ENCRYPTION = SNOWFLAKE_SSE gives server-side encryption with Snowflake
   managed keys. Verify with SHOW STAGES - type reads 'INTERNAL NO CSE',
   meaning no client-side encryption, which is what allows the directory
   table and downstream file access to work without a client key.

   DIRECTORY = (ENABLE = TRUE) is required, not cosmetic: the delta ingest
   task in 07_orchestration uses the directory table to spot files that
   arrived since the last COPY.

   Expected stage layout:
     initial-load/country-master/     region, country, currency, tax
     initial-load/product-master/
     initial-load/store-master/
     initial-load/customer-master/
     initial-load/sales-transaction/

   Idempotent: IF NOT EXISTS (architectural note 5). This must never become
   CREATE OR REPLACE STAGE - that would silently discard every staged file.

   Depends on: V3.1.1 (ff_csv_load), V2.1.2 (BRONZE schema).
   --------------------------------------------------------------------------- */

CREATE STAGE IF NOT EXISTS {{ database }}.BRONZE.sales_csv_stg
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  FILE_FORMAT = {{ database }}.COMMON.ff_csv_load
  COMMENT = 'Internal stage for Apple sales source CSVs landing into bronze.';
