/* ===========================================================================
   02 - Schema detection: INFER_SCHEMA per file, plus the TYPEOF cross-check
   ---------------------------------------------------------------------------
   Run INFER_SCHEMA on EACH FILE SEPARATELY - a folder-prefix call returns a
   merged union and hides the drift.

   For Parquet, INFER_SCHEMA reads the EMBEDDED SCHEMA rather than sampling
   values. That sounds authoritative, and it is the main reason people trust it
   blindly. Section 2.3 shows why that trust is misplaced.

   ORDER_ID here IS document order (store_code first), unlike JSON where
   INFER_SCHEMA returns keys alphabetically. Parquet preserves column order in
   its schema. Convenient, but do not build on it - MATCH_BY_COLUMN_NAME binds
   by name and ignores order entirely.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- FILE 1: store_master.parquet  -> 22 columns, 121 rows
-- ---------------------------------------------------------------------------
SELECT ORDER_ID, COLUMN_NAME, TYPE, NULLABLE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master.parquet',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet'
))
ORDER BY ORDER_ID;

/* Actual result - 22 columns, document order:
     0  store_code             TEXT
     1  store_name             TEXT
     2  country_code           TEXT
     3  region_code            TEXT
     4  tax_jurisdiction_code  TEXT
     5  format_code            TEXT
     6  city                   TEXT
     7  state_code             TEXT
     8  postal_code            TEXT            <-- string, zeros SAFE
     9  address_line1          TEXT
    10  latitude               REAL            <-- Parquet float64
    11  longitude              REAL
    12  store_open_date        DATE
    13  store_close_date       TEXT            (all NULL, no type evidence)
    14  lifecycle_status       TEXT
    15  floor_area_sqft        NUMBER(38,0)    <-- int64 -> MAX precision
    16  annual_rent_usd        NUMBER(38,0)    <-- int64 -> MAX precision
    17  is_active              TEXT            (values "Y")
    18  effective_start_date   DATE
    19  effective_end_date     DATE
    20  created_at             NUMBER(38,0)    <-- !! see 2.3, this is WRONG
    21  source_system          TEXT

   Note int64 columns land as NUMBER(38,0) - Snowflake maps Parquet's integer
   width to maximum precision, not to something sensible for the data. 38 digits
   for a floor area in square feet is not a useful declaration.               */

-- ---------------------------------------------------------------------------
-- FILE 2: store_master_1.parquet -> 23 columns, 5 rows
-- ---------------------------------------------------------------------------
SELECT ORDER_ID, COLUMN_NAME, TYPE, NULLABLE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master_1.parquet',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet'
))
ORDER BY ORDER_ID;

/* Actual result - 23 columns. THREE differences vs FILE 1:
     8  postal_code   NUMBER(38,0)   <-- was TEXT      : zeros DESTROYED
    20  created_at    TEXT           <-- was NUMBER    : OPPOSITE direction
    22  Status        TEXT           <-- NEW COLUMN
*/

/* ===========================================================================
   2.3  THE INFER_SCHEMA vs TYPEOF DISAGREEMENT - the key Parquet finding
   ---------------------------------------------------------------------------
   INFER_SCHEMA reported created_at in FILE 1 as NUMBER(38,0). The read path
   disagrees. Run the query below and compare.
   =========================================================================== */

SELECT $1:store_code::VARCHAR        AS store_code,
       $1:postal_code               AS postal_raw,
       TYPEOF($1:postal_code)       AS postal_type,
       $1:created_at                AS created_raw,
       TYPEOF($1:created_at)        AS created_type,
       $1:store_close_date          AS close_raw,
       TYPEOF($1:store_close_date)  AS close_type,
       $1:latitude                  AS lat_raw
FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master.parquet
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
LIMIT 3;

/* Actual result for FILE 1:
     postal_raw   = '77677', '08759'   postal_type  = VARCHAR
     created_raw  = 2026-04-17 15:21:50.368
     created_type = TIMESTAMP_NTZ      <-- !!! INFER_SCHEMA said NUMBER(38,0)
     close_type   = NULL               (all rows NULL)
     lat_raw      = 42.839799

   THE TWO DISAGREE, and the reader is right:
     INFER_SCHEMA surfaced the PHYSICAL storage type - Parquet stores the value
     as int64 epoch microseconds.
     The read path honours the LOGICAL TYPE ANNOTATION on that column and
     materialises a real TIMESTAMP_NTZ.

   WHY THIS MATTERS: designing the target from INFER_SCHEMA alone would have
   declared created_at as NUMBER(38,0) and stored raw epoch integers - a load
   that "succeeds" while silently discarding the timestamp semantics and leaving
   every consumer to reverse-engineer the epoch unit. Nothing would have failed.

   RULE: for Parquet, never design a column type from INFER_SCHEMA alone. Always
   cross-check the handful of date/time and numeric columns with TYPEOF against
   a real read. INFER_SCHEMA tells you how the bytes are stored; TYPEOF tells
   you what you will actually get.
   =========================================================================== */

-- 2.4 The same probe against FILE 2 - confirms the drift is real, not inferred.
SELECT $1:store_code::VARCHAR        AS store_code,
       $1:postal_code               AS postal_raw,
       TYPEOF($1:postal_code)       AS postal_type,
       $1:created_at                AS created_raw,
       TYPEOF($1:created_at)        AS created_type,
       $1:Status                    AS status_raw,
       TYPEOF($1:Status)            AS status_type
FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master_1.parquet
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
LIMIT 5;

/* Actual result for FILE 2:
     postal_raw   = 77677, 8759, 61211, 2166, 13344    postal_type  = INTEGER
                            ^^^^         ^^^^  leading zeros GONE
                            (FILE 1 had 08759 and 02166)
     created_raw  = '21:50.4'                          created_type = VARCHAR
                    a time fragment with no date - not recoverable
     status_raw   = 'y'                                status_type  = VARCHAR

   Here INFER_SCHEMA and TYPEOF AGREE, because these are genuinely stored as
   INTEGER and VARCHAR. The disagreement in 2.3 was specific to the logical
   timestamp annotation.

   FILE 2 is the same Excel-damaged export seen in the CSV exercise, re-
   serialised to Parquet: identical '21:50.4' corruption, identical
   zip-code-as-number. The remedy belongs at the export step.                  */

-- ---------------------------------------------------------------------------
-- 2.5 Row counts and key overlap.
-- ---------------------------------------------------------------------------
WITH f1 AS (
  SELECT $1:store_code::VARCHAR AS sc, $1:postal_code::VARCHAR AS pc
  FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master.parquet
       (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
), f2 AS (
  SELECT $1:store_code::VARCHAR AS sc
  FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master_1.parquet
       (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
)
SELECT (SELECT COUNT(*) FROM f1)                        AS f1_rows,
       (SELECT COUNT(*) FROM f2)                        AS f2_rows,
       (SELECT COUNT(*) FROM f2 JOIN f1 ON f1.sc=f2.sc) AS overlapping_keys,
       (SELECT COUNT(*) FROM f1 WHERE pc LIKE '0%')     AS f1_leading_zero_postals,
       (SELECT MIN(sc) FROM f2)                         AS f2_min_key,
       (SELECT MAX(sc) FROM f2)                         AS f2_max_key;
/* -> 121, 5, 0, 5, US_0101, US_0105

   ZERO overlapping keys - FILE 2 uses US_0101..US_0105 while FILE 1 uses
   US_0001.. So no duplicate-key problem, unlike the JSON exercise where the
   keys collided outright.

   DO NOT CONCLUDE THERE ARE NO DUPLICATES. The rows are the SAME FIVE STORES
   re-keyed. A key-based check cannot see it. See
   10_logical_duplicate_detection.sql.                                        */
