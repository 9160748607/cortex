/* ===========================================================================
   10 - Idempotent load remediation (MERGE) and de-duplication
   ---------------------------------------------------------------------------
   NOT YET EXECUTED against ANALYSIS_DB. This is the recommended fix for the
   two defects that load 3 introduced, held here for review before anyone runs
   it - it mutates loaded data.

   PROBLEM 1 - COPY is append-only and its load history is keyed on FILE NAME.
   A renamed re-export of already-loaded rows loads again, so
   store_master_2_deleted_columns.csv duplicated US_0101..US_0105.

   PROBLEM 2 - a degraded file must not overwrite good values with NULL. When
   a column is absent from the incoming file, MATCH_BY_COLUMN_NAME yields NULL,
   and a naive MERGE ... UPDATE SET t.city = s.city would ERASE the city we
   already hold. COALESCE(s.col, t.col) makes the update additive-only.

   The trade-off is explicit: COALESCE cannot distinguish "source omitted this
   column" from "source genuinely set this field to NULL". For a slowly-changing
   master file that is the right bias - never destroy known data from a file
   that never claimed authority over the column. For a file that IS authoritative
   and must be able to blank a field, gate on column presence instead of
   relying on the value.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- 10.1 Staging table for a single incoming file.
-- LIKE inherits the fully evolved 29-column shape, so this needs no
-- maintenance as the target continues to evolve.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD
  LIKE ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER;

-- Load the incoming file into staging, not into the target.
-- Schema evolution on the TARGET still requires new columns to be applied
-- there; see 10.4.
COPY INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_2_deleted_columns.csv
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')
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
-- 10.2 Idempotent MERGE on the business key.
-- Re-running this is a no-op; it cannot duplicate and cannot blank a value.
-- ---------------------------------------------------------------------------
MERGE INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER t
USING ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD s
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
  t.__file_name              = s.__file_name,       -- audit: always latest load
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

-- ---------------------------------------------------------------------------
-- 10.3 One-off de-duplication of the 5 keys already duplicated by load 3.
-- Keeps the row with the MOST populated columns, so the complete FILE 2 row
-- wins over its degraded twin - not an arbitrary "latest load wins", which
-- here would keep the worse row.
-- INSPECT THE SELECT BEFORE RUNNING THE DELETE.
-- ---------------------------------------------------------------------------
WITH ranked AS (
  SELECT store_code, __file_name, __row_number,
         (IFF(city IS NULL,0,1) + IFF(postal_code IS NULL,0,1)
        + IFF(latitude IS NULL,0,1) + IFF(address_line1 IS NULL,0,1)
        + IFF(format_code IS NULL,0,1) + IFF(state_code IS NULL,0,1)) AS filled_cols,
         ROW_NUMBER() OVER (PARTITION BY store_code ORDER BY
           (IFF(city IS NULL,0,1) + IFF(postal_code IS NULL,0,1)
          + IFF(latitude IS NULL,0,1) + IFF(address_line1 IS NULL,0,1)
          + IFF(format_code IS NULL,0,1) + IFF(state_code IS NULL,0,1)) DESC,
           __file_last_modified_ntz DESC) AS rn
  FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
)
SELECT * FROM ranked WHERE store_code IN
  (SELECT store_code FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
   GROUP BY store_code HAVING COUNT(*) > 1)
ORDER BY store_code, rn;

/*  Then, once the above is confirmed correct:

DELETE FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
WHERE (store_code, __file_name, __row_number) IN (
  SELECT store_code, __file_name, __row_number FROM (
    SELECT store_code, __file_name, __row_number,
           ROW_NUMBER() OVER (PARTITION BY store_code ORDER BY
             (IFF(city IS NULL,0,1) + IFF(postal_code IS NULL,0,1)
            + IFF(latitude IS NULL,0,1) + IFF(address_line1 IS NULL,0,1)
            + IFF(format_code IS NULL,0,1) + IFF(state_code IS NULL,0,1)) DESC,
             __file_last_modified_ntz DESC) AS rn
    FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
  ) WHERE rn > 1
);
-- Expect 5 rows deleted -> 126 rows, 126 distinct store_code.
*/

-- ---------------------------------------------------------------------------
-- 10.4 LIMITATION worth stating plainly.
-- Routing loads through a staging table means the TARGET no longer evolves
-- automatically: a brand-new column would be added to STORE_MASTER_LOAD, and
-- the MERGE column list would not know about it. Idempotency and automatic
-- evolution pull in opposite directions here.
-- Reconcile by running 09.2 first and applying new columns explicitly:
--     ALTER TABLE ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
--       ADD COLUMN IF NOT EXISTS <new_col> <reviewed_type>
--           COMMENT '<meaning and source file>';
-- Reviewing the type by hand is a feature, not friction - it is what prevents
-- the EMPLOYEE_COUNT NUMBER(2,0) ceiling that automatic evolution installed.
-- ---------------------------------------------------------------------------
