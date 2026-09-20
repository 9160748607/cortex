/* ===========================================================================
   03 - Schema drift analysis
   ---------------------------------------------------------------------------
   Reusable SQL to diff any two staged files, plus the recorded findings for
   the three store master files.

   TWO KINDS OF DRIFT ARE PRESENT, and only one is solved by schema evolution:

     A. STRUCTURAL drift  - columns added or removed        -> evolution helps
                                                               (additive only)
     B. TYPE / REPRESENTATION drift - same column, different
        type or encoding                                   -> evolution does
                                                               NOT help; needs
                                                               design decisions
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- Reusable two-file schema diff. Swap the two LOCATION values.
-- Returns one row per column with which side(s) it appears on and the types.
-- ---------------------------------------------------------------------------
WITH f1 AS (
  SELECT UPPER(COLUMN_NAME) AS col, TYPE, ORDER_ID
  FROM TABLE(INFER_SCHEMA(
    LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master.csv',
    FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_iso'))
),
f2 AS (
  SELECT UPPER(COLUMN_NAME) AS col, TYPE, ORDER_ID
  FROM TABLE(INFER_SCHEMA(
    LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_1.csv',
    FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu'))
)
SELECT
    COALESCE(f1.col, f2.col)                        AS column_name,
    f1.TYPE                                         AS type_file1,
    f2.TYPE                                         AS type_file2,
    CASE
      WHEN f1.col IS NULL                 THEN 'ONLY IN FILE 2 (added)'
      WHEN f2.col IS NULL                 THEN 'ONLY IN FILE 1 (removed)'
      WHEN f1.TYPE <> f2.TYPE             THEN 'TYPE DRIFT'
      ELSE 'MATCH'
    END                                             AS drift_class
FROM f1 FULL OUTER JOIN f2 ON f1.col = f2.col
ORDER BY COALESCE(f1.ORDER_ID, f2.ORDER_ID);

/* ===========================================================================
   RECORDED FINDINGS
   ===========================================================================

   FILE 1 vs FILE 2  ->  ADDITIVE structural drift
   --------------------------------------------------------------------
     Columns:        22  vs  23
     Only in FILE 2: Status (BOOLEAN)
     Only in FILE 1: none
     FILE 2 is a strict superset.

   FILE 1 vs FILE 3  ->  SUBTRACTIVE structural drift
   --------------------------------------------------------------------
     Columns:        22  vs  17
     Only in FILE 1: format_code, city, state_code, postal_code,
                     address_line1, latitude          (6 dropped)
     Only in FILE 3: Status
     latitude dropped while longitude survived - geo pair half-broken.

   TYPE DRIFT on 5 SHARED columns (FILE 1 vs FILES 2 and 3)
   --------------------------------------------------------------------
     postal_code           TEXT          -> NUMBER(5,0)   leading zeros lost
                                                          (08759 -> 8759)
     store_open_date       DATE          -> TEXT          day-first dates
     effective_start_date  DATE          -> TEXT          day-first dates
     effective_end_date    DATE          -> TEXT          day-first dates
     created_at            TIMESTAMP_NTZ -> TEXT          value is '21:50.4'

   ROOT CAUSE
   --------------------------------------------------------------------
   FILES 2 and 3 are Excel round-trips of FILE 1's rows: US_0001..US_0005
   reappear as US_0101..US_0105 with identical names, coordinates and rents.
   One export explains all three symptoms at once - regional date reformatting,
   timestamp truncation to a time fragment, and zip-code-as-number.

   This matters for remediation: the fix belongs at the export step, not in
   SQL. Everything below is damage limitation.

   CONSEQUENCE FOR DESIGN
   --------------------------------------------------------------------
   postal_code MUST be VARCHAR in the target. Accepting FILE 2's NUMBER
   inference would destroy leading zeros across all 121 FILE 1 rows
   (08759, 02166, 00158 verified present).
   =========================================================================== */
