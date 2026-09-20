/* ===========================================================================
   08 - Validation
   ---------------------------------------------------------------------------
   Every query is followed by the ACTUAL recorded result from the executed run,
   so this file doubles as a regression baseline.

   Final state: 126 rows, 126 distinct keys, 30 columns, 2 source files.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- 8.1 Final table structure
-- ---------------------------------------------------------------------------
SELECT ORDINAL_POSITION AS pos, COLUMN_NAME, DATA_TYPE,
       COALESCE(CHARACTER_MAXIMUM_LENGTH::VARCHAR,
                NUMERIC_PRECISION||','||NUMERIC_SCALE,'') AS size,
       IS_NULLABLE, COMMENT
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'DATA_MIGRATION_PARQUET' AND TABLE_NAME = 'STORE_MASTER'
ORDER BY ORDINAL_POSITION;

/* 30 columns:
     1-22   declared in 04
     23-26  audit (__ prefix)
     27     STATUS          TEXT(16777216)   <- EVOLVED, load 2
     28     CREATED_AT_NTZ  TIMESTAMP_NTZ    <- added by hand in 07
     29     MANAGER_NAME    TEXT(16777216)   <- EVOLVED, 09 test
     30     EMPLOYEE_COUNT  NUMBER(2,0)      <- EVOLVED, 09 test

   The 09 test rows were deleted afterwards; THE COLUMNS PERSIST. Evolution is
   not reversible by DELETE.

   TWO THINGS TO NOTICE:

   1) Evolved columns 29 and 30 appear in DOCUMENT order (MANAGER_NAME then
      EMPLOYEE_COUNT), matching the Parquet column order. Contrast the JSON
      exercise, where evolution appended them ALPHABETICALLY
      (EMPLOYEE_COUNT before MANAGER_NAME). The ordering follows how the format
      reports its schema, so it is format-dependent - never rely on evolved
      column position.

   2) EMPLOYEE_COUNT arrived as NUMBER(2,0) - a CEILING OF 99 - inferred from a
      two-row sample (87, 34). Third time this trap has appeared across CSV, JSON
      and Parquet: it is inherent to automatic evolution, not format-specific.
      Evolved columns need a precision review. Compare CREATED_AT_NTZ at 28,
      where the type was chosen deliberately.                                  */

-- ---------------------------------------------------------------------------
-- 8.2 Total row count
-- ---------------------------------------------------------------------------
SELECT COUNT(*)                    AS total_rows,
       COUNT(DISTINCT store_code)  AS distinct_store_codes,
       COUNT(DISTINCT __file_name) AS source_files
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER;
-- -> 126, 126, 2
-- Rows == distinct keys, so NO key duplication. See 8.7 before believing that
-- means no duplicates.

-- ---------------------------------------------------------------------------
-- 8.3 Row count by source file
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       COUNT(*)                            AS row_cnt,
       MIN(__file_last_modified_ntz)       AS file_last_modified,
       MIN(__loaded_at)                    AS loaded_at
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* ->  store_master.parquet     121
       store_master_1.parquet     5                                            */

-- ---------------------------------------------------------------------------
-- 8.4 NULL matrix - the core drift evidence
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$')   AS source_file,
       COUNT(*)                              AS row_cnt,
       SUM(IFF(STATUS IS NULL,1,0))          AS status_nulls,
       SUM(IFF(MANAGER_NAME IS NULL,1,0))    AS manager_nulls,
       SUM(IFF(EMPLOYEE_COUNT IS NULL,1,0))  AS empcount_nulls,
       SUM(IFF(created_at_ntz IS NULL,1,0))  AS created_ntz_nulls,
       SUM(IFF(store_close_date IS NULL,1,0)) AS close_date_nulls
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* file                     rows  status  manager  empcount  created_ntz  close
   store_master.parquet      121     121      121       121            0    121
   store_master_1.parquet      5       0        5         5            5      5

   STATUS nulls collapse 121 -> 0 when the column appears (additive drift).
   created_ntz nulls are 0 -> 5, which is the TYPE drift made visible: file 2's
   timestamps are unrecoverable. manager/empcount stay fully NULL because neither
   real file supplies them.                                                    */

-- ---------------------------------------------------------------------------
-- 8.5 Evolved columns populated only by the files that supplied them
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       COUNT(*)              AS row_cnt,
       COUNT(STATUS)         AS status_filled,
       COUNT(MANAGER_NAME)   AS manager_filled,
       COUNT(EMPLOYEE_COUNT) AS empcount_filled
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 8.6 Type-conversion health across both files
-- ---------------------------------------------------------------------------
SELECT
  COUNT(*)                                       AS total_rows,
  SUM(IFF(store_open_date IS NULL,1,0))          AS open_date_unparsed,
  SUM(IFF(is_active IS NULL,1,0))                AS is_active_unparsed,
  SUM(IFF(created_at_ntz IS NULL,1,0))           AS created_at_unparseable,
  SUM(IFF(postal_code LIKE '0%',1,0))            AS leading_zero_postals,
  MIN(store_open_date)                           AS earliest_open,
  MAX(store_open_date)                           AS latest_open,
  MIN(effective_end_date)                        AS eff_end
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER;
/* -> 126, 0, 0, 5, 5, 2016-04-29, 2026-04-10, 9999-12-31

   Reading that row:
     0 unparsed dates                  - Parquet DATE columns arrive typed
     0 unparsed booleans               - 'Y' and 'y' both coerced to TRUE
     5 unparseable timestamps          - exactly file 2's rows, as expected
     5 leading-zero postal codes KEPT  - all from file 1; file 2's were already
                                         destroyed at source by INTEGER storage
     9999-12-31 intact                 - no date truncation                    */

-- ---------------------------------------------------------------------------
-- 8.7 *** LOGICAL DUPLICATES - the check 8.2 cannot see ***
-- 126 rows and 126 distinct store_code looks clean. It is not.
-- Full detail and remediation in 10_logical_duplicate_detection.sql.
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS logical_duplicate_pairs
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER a
JOIN ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER b
  ON a.latitude = b.latitude AND a.longitude = b.longitude
 AND a.store_code <> b.store_code;
-- -> 10 (5 pairs counted in both directions). Five physical stores held twice
--    under different surrogate keys.

-- ---------------------------------------------------------------------------
-- 8.8 Sample records - one per source file, same physical store
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS src, store_code, store_name, city,
       postal_code, latitude, longitude, store_open_date, store_close_date,
       floor_area_sqft, annual_rent_usd, is_active,
       created_at, created_at_ntz, STATUS
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
WHERE store_code IN ('US_0001','US_0101','US_0002','US_0102')
ORDER BY store_name, src;

-- ---------------------------------------------------------------------------
-- 8.9 Audit column health. __loaded_at is populated on every row, because
-- INCLUDE_METADATA = (__loaded_at = METADATA$START_SCAN_TIME) was used from the
-- first load rather than a column DEFAULT, which COPY ignores under
-- MATCH_BY_COLUMN_NAME.
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       COUNT(*)                            AS row_cnt,
       SUM(IFF(__loaded_at IS NULL,1,0))   AS loaded_at_nulls,
       SUM(IFF(__file_name IS NULL,1,0))   AS file_name_nulls,
       MIN(__row_number)                   AS min_row,
       MAX(__row_number)                   AS max_row
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
GROUP BY 1 ORDER BY 1;
