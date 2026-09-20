/* ===========================================================================
   10 - Logical duplicate detection and remediation
   ---------------------------------------------------------------------------
   DETECTION QUERIES ARE SAFE TO RUN. The remediation at the end is NOT
   EXECUTED - it mutates loaded data and includes a DELETE. Review first.

   THE PROBLEM, AND WHY IT IS THE SUBTLEST FINDING IN THIS EXERCISE
   --------------------------------------------------------------------
   Every obvious check says the load is clean:

       SELECT COUNT(*), COUNT(DISTINCT store_code) FROM STORE_MASTER;
       -> 126, 126        rows == distinct keys, no duplicates

   It is not clean. FILE 2's five rows are FILE 1's first five stores RE-KEYED:

       US_0001 -> US_0101    Apple Bradleyton
       US_0002 -> US_0102    Apple Hunttown
       US_0003 -> US_0103    Apple Robinsonville
       US_0004 -> US_0104    Apple Dianaberg
       US_0005 -> US_0105    Apple North Alejandramouth

   Identical store_name, latitude, longitude and store_open_date. Only the
   surrogate key differs - plus the damaged postal_code and created_at.

   So the table holds FIVE PHYSICAL STORES TWICE, and no key-based check can see
   it. Compare the JSON exercise, where FILE 2 reused US_0001..US_0005 and the
   collision was immediately visible as COUNT(*) > COUNT(DISTINCT store_code).
   Re-keying is strictly worse: the corruption is the same, but the alarm is gone.

   CONSEQUENCE: any store count, floor-area total or rent roll-up is overstated
   by five stores, and nothing in the load, the schema, or a duplicate-key test
   would ever flag it.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- 10.1 Detection by business attributes rather than the surrogate key.
-- Coordinates are the natural natural-key here: a physical store has one
-- location.
-- ---------------------------------------------------------------------------
SELECT a.store_code                              AS file1_key,
       b.store_code                              AS file2_key,
       a.store_name,
       a.latitude, a.longitude, a.store_open_date,
       a.postal_code                             AS f1_postal,
       b.postal_code                             AS f2_postal,
       a.created_at                              AS f1_created_at,
       b.created_at                              AS f2_created_at
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER a
JOIN ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER b
  ON a.latitude = b.latitude
 AND a.longitude = b.longitude
 AND a.__file_name LIKE '%store_master.parquet'
 AND b.__file_name LIKE '%store_master_1.parquet'
ORDER BY a.store_code;

/* Actual result - 5 rows:
     US_0001  US_0101  Apple Bradleyton             42.839799  -84.299787  77677 / 77677
     US_0002  US_0102  Apple Hunttown               28.454519 -109.838435  08759 /  8759
     US_0003  US_0103  Apple Robinsonville          31.100593  -80.263677  61211 / 61211
     US_0004  US_0104  Apple Dianaberg              28.731634  -75.886758  02166 /  2166
     US_0005  US_0105  Apple North Alejandramouth   31.716178 -123.744726  13344 / 13344

   Note the postal columns: identical where there was no leading zero, damaged
   where there was. That asymmetry is itself proof the two rows describe the same
   store and that FILE 2 is the degraded copy.                                 */

-- ---------------------------------------------------------------------------
-- 10.2 File-agnostic version, for general monitoring. Does not assume which
-- file is the good one, so it keeps working as new files arrive.
-- ---------------------------------------------------------------------------
SELECT latitude, longitude,
       COUNT(*)                                               AS row_cnt,
       COUNT(DISTINCT store_code)                             AS distinct_keys,
       LISTAGG(store_code, ' | ') WITHIN GROUP (ORDER BY store_code) AS keys,
       LISTAGG(DISTINCT REGEXP_SUBSTR(__file_name,'[^/]+$'), ' | ') AS files
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
GROUP BY latitude, longitude
HAVING COUNT(*) > 1
ORDER BY latitude;
-- -> 5 groups, 2 rows each, 2 distinct keys each.

-- ---------------------------------------------------------------------------
-- 10.3 A stricter composite check. Coordinates alone could in principle collide
-- for genuinely different records, so confirm on name + location + open date
-- before treating anything as a duplicate.
-- ---------------------------------------------------------------------------
SELECT store_name, latitude, longitude, store_open_date,
       COUNT(*)                   AS row_cnt,
       COUNT(DISTINCT store_code) AS distinct_keys
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
GROUP BY store_name, latitude, longitude, store_open_date
HAVING COUNT(*) > 1
ORDER BY store_name;
-- -> the same 5 groups. All four attributes agree, so these are duplicates,
--    not coincidental co-location.

-- ---------------------------------------------------------------------------
-- 10.4 Impact quantified - what the duplicates do to real metrics.
-- ---------------------------------------------------------------------------
WITH dupes AS (
  SELECT store_code
  FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
  WHERE __file_name LIKE '%store_master_1.parquet'
)
SELECT
  (SELECT COUNT(*) FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER)              AS reported_stores,
  (SELECT COUNT(*) FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
     WHERE store_code NOT IN (SELECT store_code FROM dupes))                          AS actual_stores,
  (SELECT SUM(annual_rent_usd) FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER)  AS reported_rent,
  (SELECT SUM(annual_rent_usd) FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
     WHERE store_code NOT IN (SELECT store_code FROM dupes))                          AS actual_rent;
/* Reported figures are inflated by the five duplicated stores. This is the query
   to put in front of anyone who thinks "126 rows, 126 distinct keys" settles it. */

/* ===========================================================================
   10.5 REMEDIATION - NOT EXECUTED. Review before running.
   ---------------------------------------------------------------------------
   Prefer fixing the SOURCE. FILE 2 should either reuse the original store_code
   values - making the duplication visible and MERGE-able on the key - or not be
   produced at all. Re-keying the same physical stores defeats every downstream
   integrity control, and no amount of SQL fully compensates.

   If a database-side fix is required, keep the BETTER row: the one with a
   parseable created_at and an intact postal_code, which is FILE 1's.

   -- Inspect first:
   WITH ranked AS (
     SELECT store_code, store_name, latitude, longitude, __file_name,
            (IFF(created_at_ntz IS NULL,0,1)
           + IFF(postal_code LIKE '0%' OR postal_code IS NOT NULL,1,0)) AS quality_score,
            ROW_NUMBER() OVER (
              PARTITION BY store_name, latitude, longitude, store_open_date
              ORDER BY IFF(created_at_ntz IS NULL,0,1) DESC,
                       __file_last_modified_ntz ASC) AS rn
     FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
   )
   SELECT * FROM ranked WHERE rn > 1 ORDER BY store_name;
   -- Expect the 5 US_010x rows - the degraded copies.

   -- Then, once confirmed:
   -- DELETE FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
   -- WHERE (store_name, latitude, longitude, store_open_date, store_code) IN (
   --   SELECT store_name, latitude, longitude, store_open_date, store_code FROM (
   --     SELECT store_name, latitude, longitude, store_open_date, store_code,
   --            ROW_NUMBER() OVER (
   --              PARTITION BY store_name, latitude, longitude, store_open_date
   --              ORDER BY IFF(created_at_ntz IS NULL,0,1) DESC,
   --                       __file_last_modified_ntz ASC) AS rn
   --     FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
   --   ) WHERE rn > 1
   -- );
   -- Expect 5 rows deleted -> 121 rows.

   NOTE: deleting them also discards FILE 2's `Status` values, which exist ONLY on
   the degraded rows. If Status matters, MERGE it onto the FILE 1 rows FIRST -
   joining on the composite natural key, not on store_code, since the keys differ.
   That is the real cost of re-keying: you cannot even de-duplicate cleanly
   without first reconciling which attributes each copy uniquely contributes.
   =========================================================================== */
