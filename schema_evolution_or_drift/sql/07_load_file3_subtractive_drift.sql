/* ===========================================================================
   07 - LOAD 3 of 3: SUBTRACTIVE drift -> NO EVOLUTION, SILENT DEGRADATION
   ---------------------------------------------------------------------------
   File   : store_master_2_deleted_columns.csv  (17 columns, 5 rows, day-first)
   Before : table 29 columns, 126 rows
   After  : table 29 columns, 131 rows      -> NO evolution event
   Result : LOADED, rows_parsed 5, rows_loaded 5, errors_seen 0

   *** THE IMPORTANT NEGATIVE RESULT ***

   SCHEMA EVOLUTION IS ADDITIVE-ONLY. It never drops or deprecates a column.
   Six columns vanished from the source and Snowflake did not care:

     Absent from file: format_code, city, state_code, postal_code,
                       address_line1, latitude
     Table structure:  UNCHANGED at 29 columns
     Those 6 columns:  silently filled with NULL for these 5 rows
     Load status:      SUCCESS, zero errors, zero warnings

   This is the dangerous direction of drift precisely BECAUSE it succeeds. An
   upstream export that loses a quarter of its columns is indistinguishable, in
   the load logs, from a perfectly healthy run. Additive drift announces itself
   by changing the table; subtractive drift announces nothing.

   Two concrete harms, both verified in 08_validation.sql:

     1. DUPLICATE BUSINESS KEYS
        This file re-exports FILE 2's rows US_0101..US_0105, which are already
        loaded. COPY load history is keyed on FILE NAME, not business key, so a
        renamed re-export is invisible to it. The table now holds TWO rows per
        store: one complete, one degraded. Any COUNT(*), roll-up or lookup is
        wrong - overstated by 5, with two conflicting answers per key.

     2. NULL PROVENANCE BECOMES AMBIGUOUS
        state_code ends up with 44 NULLs meaning two different things:
          39 - genuine: non-US stores have no state (present since FILE 1)
           5 - structural: the column was not in the file at all
        Indistinguishable in the data. Only __file_name separates them, and
        only because 04 declared that audit column.

   The remedy is NOT a Snowflake feature - it is the pre-load guard in
   09_drift_detection_guard.sql plus the MERGE in 10_idempotent_merge_fix.sql.
   Run the guard BEFORE this COPY in any real pipeline.
   =========================================================================== */

-- Capture the pre-load state so the effect is measurable, not assumed.
SELECT
  (SELECT COUNT(*) FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER) AS rows_before,
  (SELECT COUNT(*) FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA='DATA_MIGRATION' AND TABLE_NAME='STORE_MASTER') AS cols_before,
  (SELECT COUNT(*) FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
     WHERE store_code IN ('US_0101','US_0102','US_0103','US_0104','US_0105')) AS existing_rows_same_keys;
-- -> 126, 29, 5      the 5 warns that this load will duplicate, before it runs

COPY INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_2_deleted_columns.csv
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;

-- PROOF: 5 rows added, column count NOT changed, 5 keys now duplicated.
SELECT
  (SELECT COUNT(*) FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER) AS rows_after,
  (SELECT COUNT(*) FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
     WHERE TABLE_SCHEMA='DATA_MIGRATION' AND TABLE_NAME='STORE_MASTER') AS cols_after,
  (SELECT COUNT(*) FROM (SELECT store_code FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
     GROUP BY store_code HAVING COUNT(*) > 1)) AS duplicated_store_codes;
-- -> 131, 29, 5

-- The degraded twin, side by side with the complete row.
SELECT store_code,
       REGEXP_SUBSTR(__file_name,'[^/]+$') AS src,
       city, postal_code, latitude, longitude, store_open_date, STATUS
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
WHERE store_code IN ('US_0101','US_0104')
ORDER BY store_code, src;
/* US_0101 store_master_1.csv               Bradleyton 77677 42.839799 -84.299787
   US_0101 store_master_2_deleted_columns   NULL       NULL  NULL      -84.299787
   Note longitude survived but latitude did not - the geo pair is half-broken,
   which is worse than losing both: a naive map plot silently misplaces stores. */
