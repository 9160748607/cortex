/* ===========================================================================
   09 - Idempotent load remediation (MERGE) and de-duplication
   ---------------------------------------------------------------------------
   NOT EXECUTED against ANALYSIS_DB. Held here for review before anyone runs
   it - it mutates loaded data and includes a DELETE.

   THE PROBLEM
   --------------------------------------------------------------------
   COPY is append-only and its load history is keyed on FILE NAME, not business
   key. store_master_columns_added.json is a re-export of store_master.json's
   first five records (US_0001..US_0005) with Status added. Because the filename
   differs, COPY happily loaded them again:

       126 rows, but only 121 distinct store_code
       5 keys with 2 rows each - one without Status, one with

   This is NOT schema drift and NOT an evolution failure. Evolution did its job
   correctly. It is a de-duplication gap in the load strategy, and it is easy to
   miss precisely because the load reported success.

   WHY COALESCE ON UPDATE
   --------------------------------------------------------------------
   Under MATCH_BY_COLUMN_NAME a key absent from a record yields NULL. A naive
   MERGE ... UPDATE SET t.city = s.city would then ERASE a city we already hold
   just because a thinner file did not mention it. COALESCE(s.col, t.col) makes
   the update additive-only.

   The trade-off is explicit: COALESCE cannot distinguish "source omitted this
   key" from "source deliberately set it to null". For a slowly-changing master
   file that is the right bias - never destroy known data on the word of a file
   that never claimed authority over the field. If a source IS authoritative and
   must be able to blank a field, gate on key PRESENCE instead of on the value.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- 9.1 Staging table for one incoming file.
-- LIKE inherits the fully evolved 29-column shape, so this needs no maintenance
-- as the target keeps evolving.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER_LOAD
  LIKE ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER;

COPY INTO ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER_LOAD
FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master_columns_added.json
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
FORCE = TRUE                 -- staging is disposable; always re-read the file
ON_ERROR = ABORT_STATEMENT;

-- ---------------------------------------------------------------------------
-- 9.2 Idempotent MERGE on the business key.
-- Re-running is a no-op: it cannot duplicate and cannot blank a known value.
-- ---------------------------------------------------------------------------
MERGE INTO ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER t
USING ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER_LOAD s
   ON t.store_code = s.store_code
WHEN MATCHED THEN UPDATE SET
  t.store_name               = COALESCE(s.store_name,            t.store_name),
  t.country_code             = COALESCE(s.country_code,          t.country_code),
  t.region_code              = COALESCE(s.region_code,           t.region_code),
  t.tax_jurisdiction_code    = COALESCE(s.tax_jurisdiction_code, t.tax_jurisdiction_code),
  t.format_code              = COALESCE(s.format_code,           t.format_code),
  t.city                     = COALESCE(s.city,                  t.city),
  t.state_code               = COALESCE(s.state_code,            t.state_code),
  t.postal_code              = COALESCE(s.postal_code,           t.postal_code),
  t.address_line1            = COALESCE(s.address_line1,         t.address_line1),
  t.latitude                 = COALESCE(s.latitude,              t.latitude),
  t.longitude                = COALESCE(s.longitude,             t.longitude),
  t.store_open_date          = COALESCE(s.store_open_date,       t.store_open_date),
  t.store_close_date         = COALESCE(s.store_close_date,      t.store_close_date),
  t.lifecycle_status         = COALESCE(s.lifecycle_status,      t.lifecycle_status),
  t.floor_area_sqft          = COALESCE(s.floor_area_sqft,       t.floor_area_sqft),
  t.annual_rent_usd          = COALESCE(s.annual_rent_usd,       t.annual_rent_usd),
  t.is_active                = COALESCE(s.is_active,             t.is_active),
  t.effective_start_date     = COALESCE(s.effective_start_date,  t.effective_start_date),
  t.effective_end_date       = COALESCE(s.effective_end_date,    t.effective_end_date),
  t.created_at               = COALESCE(s.created_at,            t.created_at),
  t.source_system            = COALESCE(s.source_system,         t.source_system),
  t.STATUS                   = COALESCE(s.STATUS,                t.STATUS),
  t.__file_name              = s.__file_name,      -- audit: always latest load
  t.__row_number             = s.__row_number,
  t.__file_last_modified_ntz = s.__file_last_modified_ntz,
  t.__loaded_at              = s.__loaded_at
WHEN NOT MATCHED THEN INSERT (
  store_code, store_name, country_code, region_code, tax_jurisdiction_code,
  format_code, city, state_code, postal_code, address_line1, latitude, longitude,
  store_open_date, store_close_date, lifecycle_status, floor_area_sqft,
  annual_rent_usd, is_active, effective_start_date, effective_end_date,
  created_at, source_system, STATUS,
  __file_name, __row_number, __file_last_modified_ntz, __loaded_at
) VALUES (
  s.store_code, s.store_name, s.country_code, s.region_code, s.tax_jurisdiction_code,
  s.format_code, s.city, s.state_code, s.postal_code, s.address_line1, s.latitude, s.longitude,
  s.store_open_date, s.store_close_date, s.lifecycle_status, s.floor_area_sqft,
  s.annual_rent_usd, s.is_active, s.effective_start_date, s.effective_end_date,
  s.created_at, s.source_system, s.STATUS,
  s.__file_name, s.__row_number, s.__file_last_modified_ntz, s.__loaded_at
);

/* Had loads 05/06 used this pattern instead of two plain COPYs, the result
   would be 121 rows with Status populated on the first five - no duplicates at
   all. The 5 extra rows exist purely because COPY appends.                   */

-- ---------------------------------------------------------------------------
-- 9.3 One-off de-duplication of the 5 keys already duplicated.
-- Keeps the row with the MOST populated columns, so the Status-bearing row wins
-- over its Status-less twin. NOT "latest load wins" - in a different file order
-- that would keep the poorer row.
-- INSPECT THE SELECT BEFORE RUNNING THE DELETE.
-- ---------------------------------------------------------------------------
WITH ranked AS (
  SELECT store_code, __file_name, __row_number,
         (IFF(STATUS IS NULL,0,1) + IFF(city IS NULL,0,1)
        + IFF(postal_code IS NULL,0,1) + IFF(latitude IS NULL,0,1)) AS filled_cols,
         ROW_NUMBER() OVER (PARTITION BY store_code ORDER BY
           (IFF(STATUS IS NULL,0,1) + IFF(city IS NULL,0,1)
          + IFF(postal_code IS NULL,0,1) + IFF(latitude IS NULL,0,1)) DESC,
           __file_last_modified_ntz DESC) AS rn
  FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
)
SELECT * FROM ranked
WHERE store_code IN (
  SELECT store_code FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
  GROUP BY store_code HAVING COUNT(*) > 1)
ORDER BY store_code, rn;

/*  Then, once the above is confirmed correct:

DELETE FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
WHERE (store_code, __file_name, __row_number) IN (
  SELECT store_code, __file_name, __row_number FROM (
    SELECT store_code, __file_name, __row_number,
           ROW_NUMBER() OVER (PARTITION BY store_code ORDER BY
             (IFF(STATUS IS NULL,0,1) + IFF(city IS NULL,0,1)
            + IFF(postal_code IS NULL,0,1) + IFF(latitude IS NULL,0,1)) DESC,
             __file_last_modified_ntz DESC) AS rn
    FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
  ) WHERE rn > 1
);
-- Expect 5 rows deleted -> 121 rows, 121 distinct store_code.
*/

-- ---------------------------------------------------------------------------
-- 9.4 LIMITATION worth stating plainly.
-- Routing loads through a staging table means the TARGET no longer evolves
-- automatically: a brand-new key would be added to STORE_MASTER_LOAD, and the
-- MERGE column list would not know about it. Idempotency and automatic
-- evolution pull in opposite directions.
-- Reconcile by running the key-diff guard from 08 first, then adding new
-- columns explicitly with a REVIEWED type:
--     ALTER TABLE ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
--       ADD COLUMN IF NOT EXISTS <new_col> <reviewed_type>
--           COMMENT '<meaning and source file>';
-- Choosing the type by hand is a FEATURE here - it is exactly what prevents the
-- EMPLOYEE_COUNT NUMBER(2,0) ceiling that automatic evolution installed.
-- ---------------------------------------------------------------------------
