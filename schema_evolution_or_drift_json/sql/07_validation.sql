/* ===========================================================================
   07 - Validation
   ---------------------------------------------------------------------------
   Every query is followed by the ACTUAL recorded result from the executed run,
   so this file doubles as a regression baseline.

   Final state: 126 rows, 121 distinct keys, 29 columns, 2 source files.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- 7.1 Final table structure
-- ---------------------------------------------------------------------------
SELECT ORDINAL_POSITION AS pos, COLUMN_NAME, DATA_TYPE,
       COALESCE(CHARACTER_MAXIMUM_LENGTH::VARCHAR,
                NUMERIC_PRECISION||','||NUMERIC_SCALE,'') AS size,
       IS_NULLABLE, COMMENT
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'DATA_MIGRATION_JSON' AND TABLE_NAME = 'STORE_MASTER'
ORDER BY ORDINAL_POSITION;

/* 29 columns. 1-22 declared in 04; 23-26 audit; 27+ EVOLVED:
     27  STATUS          TEXT(16777216)   <- added by load 2
     28  EMPLOYEE_COUNT  NUMBER(2,0)      <- added by the 08 future-keys test
     29  MANAGER_NAME    TEXT(16777216)   <- added by the 08 future-keys test

   The 08 test rows were deleted afterwards; THE COLUMNS PERSIST. Evolution is
   not reversible by DELETE. They remain as harmless all-NULL columns and as
   standing proof of the mechanism.

   TWO THINGS TO NOTICE:

   1) Evolved columns were appended in ALPHABETICAL order - EMPLOYEE_COUNT (28)
      before MANAGER_NAME (29) - even though the JSON document lists
      manager_name first. Consistent with INFER_SCHEMA's alphabetical key
      ordering. Do not rely on evolved column position meaning anything.

   2) EMPLOYEE_COUNT arrived as NUMBER(2,0) - inferred from a 2-record sample
      whose values were 87 and 34. That is a CEILING OF 99. An evolved column
      inherits precision from whichever file introduced it, so evolution can
      silently install a type too narrow for real data. A store with 100 staff
      would fail the next load. Evolved columns need a precision review; they
      are not free.                                                           */

-- ---------------------------------------------------------------------------
-- 7.2 Total row count. Note rows > distinct keys - see 7.7.
-- ---------------------------------------------------------------------------
SELECT COUNT(*)                    AS total_rows,
       COUNT(DISTINCT store_code)  AS distinct_store_codes,
       COUNT(DISTINCT __file_name) AS source_files
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER;
-- -> 126, 121, 2       126 rows but only 121 distinct keys = 5 duplicates

-- ---------------------------------------------------------------------------
-- 7.3 Row count by source file
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       COUNT(*)                            AS row_cnt,
       MIN(__file_last_modified_ntz)       AS file_last_modified,
       MIN(__loaded_at)                    AS loaded_at
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* ->  store_master.json                 121
       store_master_columns_added.json     5                                  */

-- ---------------------------------------------------------------------------
-- 7.4 NULL matrix - the core drift evidence.
-- Reading across shows exactly which file supplied which key.
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$')   AS source_file,
       COUNT(*)                              AS row_cnt,
       SUM(IFF(STATUS IS NULL,1,0))          AS status_nulls,
       SUM(IFF(MANAGER_NAME IS NULL,1,0))    AS manager_nulls,
       SUM(IFF(EMPLOYEE_COUNT IS NULL,1,0))  AS empcount_nulls,
       SUM(IFF(store_close_date IS NULL,1,0)) AS close_date_nulls
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* file                              rows  status  manager  empcount  close_date
   store_master.json                  121     121      121       121         121
   store_master_columns_added.json      5       0        5         5           5

   STATUS nulls collapse 121 -> 0 when the key appears. manager/empcount stay
   fully NULL because neither real file supplies them - they exist only because
   the 08 test introduced them.                                                */

-- ---------------------------------------------------------------------------
-- 7.5 Evolved columns populated only by the files that supplied them
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       COUNT(*)              AS row_cnt,
       COUNT(STATUS)         AS status_filled,
       COUNT(MANAGER_NAME)   AS manager_filled,
       COUNT(EMPLOYEE_COUNT) AS empcount_filled
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 7.6 Type-conversion health. All of these were RISKS that the 02 probes
-- cleared before the target was designed; this confirms them post-load.
-- ---------------------------------------------------------------------------
SELECT
  COUNT(*)                                      AS total_rows,
  SUM(IFF(store_open_date IS NULL,1,0))         AS open_date_unparsed,
  SUM(IFF(created_at IS NULL,1,0))              AS created_at_unparsed,
  SUM(IFF(is_active IS NULL,1,0))               AS is_active_unparsed,
  SUM(IFF(store_close_date = 'NaN',1,0))        AS close_date_literal_nan,
  SUM(IFF(postal_code LIKE '0%',1,0))           AS leading_zero_postals,
  MIN(store_open_date)                          AS earliest_open,
  MAX(store_open_date)                          AS latest_open,
  MIN(effective_end_date)                       AS eff_end
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER;
/* -> 126, 0, 0, 0, 0, 7, 2016-04-29, 2026-04-10, 9999-12-31

   Reading that row:
     0 unparsed dates / timestamps / booleans - "Y" -> TRUE worked on all rows
     0 rows holding the literal 'NaN'         - NULL_IF neutralised all 126
     7 leading-zero postal codes PRESERVED    - the JSON win over CSV
     9999-12-31 intact, so no date truncation                                 */

-- ---------------------------------------------------------------------------
-- 7.7 Duplicate business keys. NOT caused by drift or evolution - caused by
-- FILE 2 being a re-export of FILE 1's first five records.
-- ---------------------------------------------------------------------------
SELECT store_code, COUNT(*) AS row_cnt,
       LISTAGG(REGEXP_SUBSTR(__file_name,'[^/]+$'), ' | ') AS from_files
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
GROUP BY store_code HAVING COUNT(*) > 1
ORDER BY store_code;
/* -> US_0001 .. US_0005, 2 rows each, from both files.
   COUNT(*) is overstated by 5 and any lookup on those keys returns two
   conflicting answers. Remediation in 09_idempotent_merge_fix.sql.           */

-- ---------------------------------------------------------------------------
-- 7.8 Sample records
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS src, store_code, store_name, city,
       postal_code, latitude, longitude, store_open_date, store_close_date,
       floor_area_sqft, annual_rent_usd, is_active, created_at, STATUS
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
ORDER BY store_code, src
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 7.9 Audit column health. Unlike the CSV run, __loaded_at is populated on
-- every row here, because INCLUDE_METADATA = (__loaded_at =
-- METADATA$START_SCAN_TIME) was used from the first load rather than relying
-- on a column DEFAULT, which COPY ignores under MATCH_BY_COLUMN_NAME.
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       COUNT(*)                            AS row_cnt,
       SUM(IFF(__loaded_at IS NULL,1,0))   AS loaded_at_nulls,
       SUM(IFF(__file_name IS NULL,1,0))   AS file_name_nulls,
       MIN(__row_number)                   AS min_row,
       MAX(__row_number)                   AS max_row
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
GROUP BY 1 ORDER BY 1;
