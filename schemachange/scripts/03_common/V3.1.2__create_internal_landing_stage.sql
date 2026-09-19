/* ---------------------------------------------------------------------------
   V3.1.2 - Internal landing stage

   Data-flow rule 1: source CSVs are loaded here with PUT (or snow cli copy)
   before COPY INTO moves them to bronze.

   DIRECTORY = (ENABLE = TRUE) is required, not cosmetic: the delta/incremental
   task in 07_orchestration relies on the directory table to identify files
   that have arrived since the last COPY.

   A stage stores data, so it is tagged per architectural note 6. It inherits
   ENVIRONMENT / COST_CENTER / CHARGEBACK_OWNER from the database (V2.1.3) and
   MEDALLION_LAYER = 'COMMON' from its schema (V2.1.4), so no explicit tag
   assignment is needed here - inheritance already covers it.

   Idempotent: IF NOT EXISTS (architectural note 5). Critically, this must
   never become CREATE OR REPLACE STAGE - that would silently discard every
   staged source file.

   Depends on: V3.1.1 (ff_csv_load), V2.1.2 (COMMON schema).
   --------------------------------------------------------------------------- */

CREATE STAGE IF NOT EXISTS {{ database }}.COMMON.stg_sales_landing
  DIRECTORY = (ENABLE = TRUE)
  FILE_FORMAT = {{ database }}.COMMON.ff_csv_load
  COMMENT = 'Internal stage for landing Apple sales source CSVs before COPY to bronze.';
