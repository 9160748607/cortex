/* ===========================================================================
   03 - Schema drift analysis
   ---------------------------------------------------------------------------
   Reusable SQL to diff any two staged JSON files, plus the recorded findings.

   For JSON the diff MUST be by key name. There is no ordinal position to
   compare - INFER_SCHEMA returns keys alphabetically and a JSON object's key
   order carries no meaning.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- Reusable two-file key/type diff. Swap the two LOCATION values.
-- ---------------------------------------------------------------------------
WITH f1 AS (
  SELECT UPPER(COLUMN_NAME) AS col, TYPE
  FROM TABLE(INFER_SCHEMA(
    LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master.json',
    FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json'))
),
f2 AS (
  SELECT UPPER(COLUMN_NAME) AS col, TYPE
  FROM TABLE(INFER_SCHEMA(
    LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master_columns_added.json',
    FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json'))
)
SELECT
    COALESCE(f1.col, f2.col) AS key_name,
    f1.TYPE                  AS type_file1,
    f2.TYPE                  AS type_file2,
    CASE
      WHEN f1.col IS NULL     THEN 'ONLY IN FILE 2 (added)'
      WHEN f2.col IS NULL     THEN 'ONLY IN FILE 1 (removed)'
      WHEN f1.TYPE <> f2.TYPE THEN 'TYPE DRIFT'
      ELSE 'MATCH'
    END                      AS drift_class
FROM f1 FULL OUTER JOIN f2 ON f1.col = f2.col
ORDER BY drift_class, key_name;

/* ===========================================================================
   RECORDED FINDINGS
   ===========================================================================

   STRUCTURAL DRIFT - purely ADDITIVE
   --------------------------------------------------------------------
     Keys:            22  vs  23
     Only in FILE 2:  Status (TEXT)
     Only in FILE 1:  none
     FILE 2 is a strict superset. This is the ONE drift between the files, and
     it is exactly the case schema evolution handles.

   TYPE DRIFT BETWEEN THE FILES - NONE
   --------------------------------------------------------------------
     Every one of the 22 shared keys has an identical inferred type. This is a
     genuine contrast with the CSV version of the same data, where postal_code,
     three date columns and created_at all disagreed between files.

     Why JSON is better behaved here: values are self-typed and quoted.
     postal_code arrives as the string "08759" in both files, so the leading
     zero cannot be lost. Dates are ISO in both files, so no per-file
     DATE_FORMAT is needed.

   A DEFECT SHARED BY BOTH FILES - not drift, but it dictates the design
   --------------------------------------------------------------------
     "store_close_date": NaN     on all 126 records across both files

     NaN is not valid JSON. Snowflake parses it as DOUBLE, so INFER_SCHEMA
     reports REAL for a column that is semantically a DATE. Because BOTH files
     carry it, it is not drift between them - it is a constant source defect.

     It still forced a design decision, and two attempts failed first:
       DATE target               -> COPY fails: "Can't parse 'NaN' as date"
       DATE target + NULL_IF     -> STILL fails: NULL_IF compares strings, and
                                    NaN was already parsed as a number
       VARCHAR target + NULL_IF  -> WORKS: NaN renders as the string 'NaN',
                                    NULL_IF matches it, value lands as NULL
     See 04_create_target_table.sql.

   DUPLICATE BUSINESS KEYS
   --------------------------------------------------------------------
     FILE 2's five records are US_0001..US_0005 - the SAME stores as FILE 1's
     first five, re-exported with Status added. Appending duplicates those keys:
     126 rows but only 121 distinct store_code. Remediation in
     09_idempotent_merge_fix.sql.

   ROOT CAUSE
   --------------------------------------------------------------------
     FILE 2 looks like a re-export of a slice of FILE 1 from a tool that (a)
     added a Status field as a stringified boolean "True" rather than a JSON
     boolean, and (b) reproduced the same NaN artefact. The fix belongs at the
     export step; everything here is damage limitation.
   =========================================================================== */
