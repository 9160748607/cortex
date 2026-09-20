/* ===========================================================================
   03 - Schema drift analysis
   ---------------------------------------------------------------------------
   Reusable SQL to diff any two staged Parquet files, plus recorded findings.

   This is the richest drift case of the three formats: THREE distinct drifts,
   and the two type drifts run in OPPOSITE directions.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- Reusable two-file column/type diff. Swap the two LOCATION values.
-- ---------------------------------------------------------------------------
WITH f1 AS (
  SELECT UPPER(COLUMN_NAME) AS col, TYPE, ORDER_ID
  FROM TABLE(INFER_SCHEMA(
    LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master.parquet',
    FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet'))
),
f2 AS (
  SELECT UPPER(COLUMN_NAME) AS col, TYPE, ORDER_ID
  FROM TABLE(INFER_SCHEMA(
    LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master_1.parquet',
    FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet'))
)
SELECT
    COALESCE(f1.col, f2.col) AS column_name,
    f1.TYPE                  AS type_file1,
    f2.TYPE                  AS type_file2,
    CASE
      WHEN f1.col IS NULL     THEN 'ONLY IN FILE 2 (added)'
      WHEN f2.col IS NULL     THEN 'ONLY IN FILE 1 (removed)'
      WHEN f1.TYPE <> f2.TYPE THEN 'TYPE DRIFT'
      ELSE 'MATCH'
    END                      AS drift_class
FROM f1 FULL OUTER JOIN f2 ON f1.col = f2.col
ORDER BY drift_class, COALESCE(f1.ORDER_ID, f2.ORDER_ID);

/* ===========================================================================
   RECORDED FINDINGS
   ===========================================================================

   A. STRUCTURAL DRIFT - additive
   --------------------------------------------------------------------
     Columns:         22  vs  23
     Only in FILE 2:  Status (TEXT, values 'y')
     Only in FILE 1:  none
     This is the ONE drift schema evolution handles.

   B. TYPE DRIFT - TWO columns, OPPOSITE directions
   --------------------------------------------------------------------
     postal_code   TEXT         -> NUMBER(38,0)
       FILE 1 '08759', '02166'   FILE 2  8759, 2166
       Leading zeros destroyed. 5 affected codes in FILE 1.
       Forces postal_code to VARCHAR in the target - NUMBER would destroy
       FILE 1's good data to match FILE 2's damaged data.

     created_at    NUMBER(38,0) -> TEXT
       FILE 1 a real Parquet timestamp (see the TYPEOF caveat below)
       FILE 2 the string '21:50.4' - a time fragment, no date, unrecoverable
       Drifting the OTHER WAY is what makes this case interesting: there is no
       single "the source got looser" narrative to apply.

     Note the two drifts cannot be solved by one policy. postal_code wants the
     WIDER type (VARCHAR) because FILE 1 is correct. created_at also ends up
     VARCHAR, but for the opposite reason - FILE 2 is corrupt and must be landed
     as evidence rather than rejected. Same declaration, different justification.

   C. INFER_SCHEMA IS NOT AUTHORITATIVE FOR created_at
   --------------------------------------------------------------------
     INFER_SCHEMA:  NUMBER(38,0)        (physical int64 storage)
     TYPEOF on read: TIMESTAMP_NTZ      (logical type annotation honoured)

     The reader is right. Trusting INFER_SCHEMA alone would have declared a
     NUMBER column and silently stored epoch integers - a load that succeeds
     while throwing away the timestamp semantics. Full detail in
     02_schema_detection.sql section 2.3.

     So the FILE 1 -> FILE 2 drift on created_at is really
         TIMESTAMP_NTZ -> corrupted VARCHAR
     not NUMBER -> VARCHAR as the diff query above reports. The diff is only as
     good as its inputs, and on Parquet those inputs need a TYPEOF cross-check.

   D. LOGICAL DUPLICATES WITH NO KEY COLLISION
   --------------------------------------------------------------------
     0 overlapping store_code values, so key-based checks report a clean load:
     126 rows, 126 distinct keys.

     But FILE 2's five rows ARE FILE 1's first five stores, re-keyed
     US_0001 -> US_0101 etc. Identical store_name, latitude, longitude and
     store_open_date; only the damaged postal_code differs.

     This is WORSE than the JSON exercise, where the keys collided and the
     duplication was trivially visible. Here nothing looks wrong.
     Detection requires matching on business attributes - see
     10_logical_duplicate_detection.sql.

   ROOT CAUSE
   --------------------------------------------------------------------
     FILE 2 is the same Excel round-trip seen in the CSV exercise, re-serialised
     to Parquet, then re-keyed. One bad export explains the '21:50.4'
     truncation, the zip-as-number, and the stringified 'y' status at once.
     Parquet did not introduce any of this damage - it faithfully preserved
     damage done upstream. The fix belongs at the export step.
   =========================================================================== */
