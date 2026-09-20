/* ===========================================================================
   07 - Derive the typed timestamp column
   ---------------------------------------------------------------------------
   Recovers proper TIMESTAMP_NTZ typing for the 121 valid rows WITHOUT
   discarding FILE 2's corrupted raw values.

   WHY THIS EXISTS
   --------------------------------------------------------------------
   created_at is VARCHAR in the target (see 04 for the reasoning). That is right
   for LANDING - it accepts both a real timestamp and the fragment '21:50.4'
   losslessly - but wrong for CONSUMPTION: nobody should have to cast a
   timestamp in every downstream query, and a VARCHAR will not sort, range-filter
   or date-truncate correctly.

   So: keep the raw column, add a typed sibling.
     created_at      VARCHAR(50)     faithful landing, evidence preserved
     created_at_ntz  TIMESTAMP_NTZ   what consumers should actually use

   Result: 121 rows typed, 5 rows NULL with their raw text still inspectable.
   Nothing is lost and nothing is silently coerced.

   WHY ADDED EXPLICITLY RATHER THAN LET EVOLUTION DO IT
   --------------------------------------------------------------------
   This is the deliberate contrast with schema evolution. Here the type is chosen
   by a human who looked at the data. Compare 09, where evolution auto-added
   EMPLOYEE_COUNT as NUMBER(2,0) - a ceiling of 99 - because it sized the column
   to a two-row sample. Automatic evolution is convenient; it is not a substitute
   for judgement.

   ORDER MATTERS: run this AFTER both loads (05, 06). Running it before means the
   UPDATE sees only FILE 1's rows.
   =========================================================================== */

ALTER TABLE ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
  ADD COLUMN IF NOT EXISTS created_at_ntz TIMESTAMP_NTZ
  COMMENT 'Typed creation timestamp derived from created_at via TRY_TO_TIMESTAMP_NTZ. NULL where the source value is unparseable, e.g. file 2 ships the fragment 21:50.4. Added explicitly with a reviewed type, not by schema evolution.';

UPDATE ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
SET created_at_ntz = TRY_TO_TIMESTAMP_NTZ(created_at)
WHERE created_at IS NOT NULL;
-- -> 126 rows updated

-- Validate the split: file 1 fully typed, file 2 fully NULL.
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$')        AS source_file,
       COUNT(*)                                   AS row_cnt,
       COUNT(created_at_ntz)                      AS typed_ok,
       SUM(IFF(created_at_ntz IS NULL,1,0))       AS typed_null,
       MIN(created_at_ntz)                        AS earliest,
       MAX(created_at_ntz)                        AS latest
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* ->  store_master.parquet     121   121   0   2026-04-17 15:21:50.368  ...
       store_master_1.parquet     5     0   5   NULL                    NULL  */

-- The raw value is still there for the 5 failures - that is the whole point.
SELECT store_code, created_at AS raw_value, created_at_ntz AS typed_value
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
WHERE created_at_ntz IS NULL
ORDER BY store_code;
/* -> US_0101..US_0105, raw_value '21:50.4', typed_value NULL
   A data-quality report can point at exactly these rows and quote the offending
   source value back to the producing team.                                    */

/* ===========================================================================
   KNOWN LIMITATION - created_at_ntz is NOT self-maintaining
   ---------------------------------------------------------------------------
   This is a plain column populated by a one-off UPDATE, so rows loaded AFTER
   this script runs will have created_at_ntz = NULL until it is re-run. That was
   observed during the 09 future-columns test: its 2 rows landed with NULL here.

   For a real pipeline, pick one:
     (a) re-run the UPDATE as a post-load step in the same task, or
     (b) make it a VIEW column instead of a stored column:
             CREATE OR REPLACE VIEW ..._V AS
               SELECT *, TRY_TO_TIMESTAMP_NTZ(created_at) AS created_at_ntz FROM ...
         which can never go stale, at the cost of casting on every read, or
     (c) fix the upstream export so created_at is always a valid timestamp and
         drop this column entirely.

   (c) is the actual remedy. (a) and (b) are workarounds for a producer defect.
   =========================================================================== */
