/* ===========================================================================
   08 - Validation
   ---------------------------------------------------------------------------
   Every query below is followed by the ACTUAL recorded result from the
   executed run, so this file doubles as a regression baseline.

   Final state: 131 rows, 29 columns, 3 source files, 5 duplicated store_codes.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- 8.1 Final table structure
-- ---------------------------------------------------------------------------
SELECT ORDINAL_POSITION AS pos, COLUMN_NAME, DATA_TYPE,
       COALESCE(CHARACTER_MAXIMUM_LENGTH::VARCHAR,
                NUMERIC_PRECISION||','||NUMERIC_SCALE, '') AS size,
       IS_NULLABLE, COMMENT
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'DATA_MIGRATION' AND TABLE_NAME = 'STORE_MASTER'
ORDER BY ORDINAL_POSITION;

/* 29 columns. Positions 1-22 declared in 04; 23-26 audit; 27+ EVOLVED:
     27  STATUS          BOOLEAN            <- added by load 2 (file 2)
   Columns 28-29 (MANAGER_NAME TEXT, EMPLOYEE_COUNT NUMBER(2,0)) were added by
   a throwaway 4th file during the future-column test, then its rows were
   deleted. The COLUMNS PERSIST - evolution is not reversible by DELETE. They
   remain as harmless all-NULL columns and as standing proof of the mechanism.

   *** CAVEAT WORTH REMEMBERING ***
   EMPLOYEE_COUNT arrived as NUMBER(2,0) - inferred from a 2-row sample whose
   max value was 87. That is a ceiling of 99. An evolved column inherits its
   precision from whichever file introduced it, so evolution can silently
   install a type too narrow for real data. Evolved columns need a precision
   review; they are not free.                                                */

-- ---------------------------------------------------------------------------
-- 8.2 Total row count
-- ---------------------------------------------------------------------------
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT store_code) AS distinct_store_codes,
       COUNT(DISTINCT __file_name) AS source_files
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER;
-- -> 131, 126, 3      131 rows but only 126 distinct keys = 5 duplicates

-- ---------------------------------------------------------------------------
-- 8.3 Row count by source file
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       COUNT(*) AS row_cnt,
       MIN(__file_last_modified_ntz) AS file_last_modified
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* ->  store_master.csv                     121
       store_master_1.csv                     5
       store_master_2_deleted_columns.csv     5                               */

-- ---------------------------------------------------------------------------
-- 8.4 NULL matrix - the core drift evidence.
-- Reading down each column shows exactly which file omitted what.
-- ---------------------------------------------------------------------------
SELECT
  REGEXP_SUBSTR(__file_name,'[^/]+$')      AS source_file,
  COUNT(*)                                 AS row_cnt,
  SUM(IFF(format_code   IS NULL,1,0))      AS format_code_null,
  SUM(IFF(city          IS NULL,1,0))      AS city_null,
  SUM(IFF(state_code    IS NULL,1,0))      AS state_null,
  SUM(IFF(postal_code   IS NULL,1,0))      AS postal_null,
  SUM(IFF(address_line1 IS NULL,1,0))      AS address_null,
  SUM(IFF(latitude      IS NULL,1,0))      AS latitude_null,
  SUM(IFF(longitude     IS NULL,1,0))      AS longitude_null,
  SUM(IFF(STATUS        IS NULL,1,0))      AS status_null
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* file                                rows fmt city state post addr lat lon status
   store_master.csv                     121   0    0    39    0    0   0   0    121
   store_master_1.csv                     5   0    0     0    0    0   0   0      0
   store_master_2_deleted_columns.csv     5   5    5     5    5    5   5   0      0

   Read it as: STATUS nulls collapse 121 -> 0 when the column appears (additive
   drift), and the six dropped columns spike 0 -> 5 when it vanishes
   (subtractive drift). state_code's 39 is NOT drift - see 8.5.              */

-- ---------------------------------------------------------------------------
-- 8.5 NULL PROVENANCE AMBIGUITY - the subtlest finding in the whole exercise
-- ---------------------------------------------------------------------------
SELECT
  COUNT(*)                                                      AS total_state_code_nulls,
  SUM(IFF(__file_name LIKE '%deleted_columns.csv',1,0))         AS structural_column_absent,
  SUM(IFF(__file_name NOT LIKE '%deleted_columns.csv',1,0))     AS genuine_value_absent
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
WHERE state_code IS NULL;
-- -> 44, 5, 39

/* 44 NULLs, two irreconcilable meanings mixed in one column:
     39  the store genuinely has no state (non-US locations)
      5  the column was not present in the source file at all
   A consumer writing  WHERE state_code IS NULL  cannot tell these apart.
   Only __file_name disambiguates - which is the entire justification for
   carrying audit columns into a landing table.                              */

-- ---------------------------------------------------------------------------
-- 8.6 Evolved columns populated only by the files that supplied them
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       COUNT(*)              AS row_cnt,
       COUNT(STATUS)         AS status_filled,
       COUNT(MANAGER_NAME)   AS manager_filled,
       COUNT(EMPLOYEE_COUNT) AS empcount_filled
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 8.7 Date normalisation across BOTH conventions
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       MIN(store_open_date) AS earliest_open,
       MAX(store_open_date) AS latest_open,
       MIN(effective_end_date) AS eff_end,
       SUM(IFF(store_open_date IS NULL,1,0)) AS unparsed_dates
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* unparsed_dates = 0 on all three files. Day-first files land 2016-06-22 from
   '22-06-2016' - the 22 proves day-first was honoured, since 22 is not a valid
   month. If the ISO format had been used by mistake these would be NULL, not
   wrong - which is the only reason the mistake would be catchable.          */

-- ---------------------------------------------------------------------------
-- 8.8 Duplicate business keys introduced by load 3
-- ---------------------------------------------------------------------------
SELECT store_code, COUNT(*) AS row_cnt,
       LISTAGG(REGEXP_SUBSTR(__file_name,'[^/]+$'), ' | ') AS from_files
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
GROUP BY store_code HAVING COUNT(*) > 1
ORDER BY store_code;
-- -> US_0101 .. US_0105, 2 rows each, from store_master_1 + *_deleted_columns

-- ---------------------------------------------------------------------------
-- 8.9 Sample records, one per source file
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS src, store_code, store_name,
       city, postal_code, latitude, longitude, store_open_date,
       created_at, is_active, STATUS
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
WHERE store_code IN ('US_0001','US_0101')
ORDER BY store_code, src;

-- ---------------------------------------------------------------------------
-- 8.10 Audit column health. __loaded_at is NULL for the first 126 rows
-- because the original load relied on a column DEFAULT, which COPY ignores
-- under MATCH_BY_COLUMN_NAME. Fixed from load 3 onward via
-- INCLUDE_METADATA = (__loaded_at = METADATA$START_SCAN_TIME).
-- ---------------------------------------------------------------------------
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       COUNT(*) AS row_cnt,
       SUM(IFF(__loaded_at IS NULL,1,0)) AS loaded_at_nulls,
       SUM(IFF(__file_name IS NULL,1,0)) AS file_name_nulls,
       MIN(__row_number) AS min_row, MAX(__row_number) AS max_row
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
GROUP BY 1 ORDER BY 1;
