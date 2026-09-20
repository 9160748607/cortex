/* ===========================================================================
   02 - Schema detection: INFER_SCHEMA per source file, plus the NaN
        investigation
   ---------------------------------------------------------------------------
   Run INFER_SCHEMA on EACH FILE SEPARATELY. Pointing it at the folder prefix
   returns a merged union and hides the drift entirely.

   IMPORTANT DIFFERENCE FROM CSV: for JSON, INFER_SCHEMA returns keys in
   ALPHABETICAL order, so ORDER_ID is NOT document position. Ordinal position
   is meaningless in JSON - an object's keys can appear in any order and the
   document is still equivalent. That is precisely why MATCH_BY_COLUMN_NAME is
   the natural loader for JSON rather than a convenience: there IS no reliable
   ordinal to bind to.
   =========================================================================== */

-- ---------------------------------------------------------------------------
-- FILE 1: store_master.json  -> 22 keys, 121 records
-- ---------------------------------------------------------------------------
SELECT ORDER_ID, COLUMN_NAME, TYPE, NULLABLE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master.json',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json'
))
ORDER BY ORDER_ID;

/* Actual result - 22 keys, alphabetical:
     address_line1          TEXT
     annual_rent_usd        NUMBER(8,0)
     city                   TEXT
     country_code           TEXT
     created_at             TIMESTAMP_NTZ
     effective_end_date     DATE
     effective_start_date   DATE
     floor_area_sqft        NUMBER(5,0)
     format_code            TEXT
     is_active              TEXT           (values are the string "Y")
     latitude               NUMBER(8,6)
     lifecycle_status       TEXT
     longitude              NUMBER(9,6)
     postal_code            TEXT           <-- quoted in JSON, zeros SAFE
     region_code            TEXT
     source_system          TEXT
     state_code             TEXT
     store_close_date       REAL           <-- !! a DATE column typed as float
     store_code             TEXT
     store_name             TEXT
     store_open_date        DATE
     tax_jurisdiction_code  TEXT
*/

-- ---------------------------------------------------------------------------
-- FILE 2: store_master_columns_added.json -> 23 keys, 5 records
--         (ADDITIVE drift)
-- ---------------------------------------------------------------------------
SELECT ORDER_ID, COLUMN_NAME, TYPE, NULLABLE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master_columns_added.json',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json'
))
ORDER BY ORDER_ID;

/* Actual result - 23 keys. EXACTLY ONE difference vs FILE 1:
     Status   TEXT     <-- NEW KEY, absent from FILE 1
   Every shared key has an IDENTICAL inferred type. Unlike the CSV exercise
   there is no type drift BETWEEN the two files.

   Note Status holds the STRING "True", not a JSON boolean true. Had it been a
   real boolean, evolution would have added a BOOLEAN column instead of TEXT.
*/

/* ===========================================================================
   THE NaN INVESTIGATION
   ---------------------------------------------------------------------------
   Both files contain, on every single record:

       "store_close_date": NaN

   NaN IS NOT VALID JSON. The JSON specification defines no NaN literal - only
   numbers, strings, true, false, null, objects and arrays. This is almost
   certainly a pandas/numpy DataFrame.to_json() artefact, where a missing value
   is emitted as the float NaN rather than JSON null.

   Three findings, each TESTED rather than assumed:
   =========================================================================== */

-- 2.1 A lenient client parser ACCEPTS it, which gives false confidence.
--     PowerShell:  Get-Content file | ConvertFrom-Json   -> VALID, no error.
--     So local validation does NOT catch this. Do not rely on it.

-- 2.2 Snowflake also accepts it - and types it as DOUBLE, not NULL, not error.
SELECT $1:store_code::VARCHAR      AS store_code,
       $1:store_close_date         AS close_date_variant,
       TYPEOF($1:store_close_date) AS close_date_type,
       $1:postal_code::VARCHAR     AS postal_code,
       $1:latitude                 AS latitude
FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master.json
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
LIMIT 3;
/* -> close_date_variant = NaN, close_date_type = DOUBLE
   This is why INFER_SCHEMA reported REAL for a column named ..._date.       */

-- 2.3 Coercion probes. Run these BEFORE designing the target - they are what
--     turned guesses into evidence and saved several failed load attempts.
SELECT
    $1:store_close_date::FLOAT                   AS nan_as_float,      -- NaN
    TRY_TO_DATE($1:store_close_date::VARCHAR)    AS nan_to_date,       -- NULL
    TRY_TO_BOOLEAN($1:is_active::VARCHAR)        AS y_to_boolean,      -- TRUE
    TRY_TO_DATE($1:store_open_date::VARCHAR)     AS open_to_date,      -- 2017-09-01
    TRY_TO_TIMESTAMP_NTZ($1:created_at::VARCHAR) AS created_to_ts,     -- parses
    TRY_TO_DATE($1:effective_end_date::VARCHAR)  AS eff_end_to_date,   -- 9999-12-31
    $1:postal_code::VARCHAR                      AS postal_text        -- 08759
FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master.json
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
LIMIT 2;
/* Everything coerces cleanly EXCEPT store_close_date. is_active "Y" -> TRUE
   and created_at parses as a real timestamp, so both can be strongly typed.

   NOTE the JSON win over CSV: postal_code comes back as '08759' with the
   leading zero intact, because JSON quotes it as a string. The CSV version of
   this same data had the zero stripped by a numeric export. 7 such codes are
   preserved across the two files.                                            */

-- 2.4 Record counts and - importantly - KEY OVERLAP between the two files.
WITH f1 AS (
  SELECT $1:store_code::VARCHAR AS sc
  FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master.json
       (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
), f2 AS (
  SELECT $1:store_code::VARCHAR AS sc, $1:Status::VARCHAR AS st
  FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master_columns_added.json
       (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
)
SELECT (SELECT COUNT(*) FROM f1)                            AS f1_rows,
       (SELECT COUNT(*) FROM f2)                            AS f2_rows,
       (SELECT COUNT(*) FROM f2 JOIN f1 ON f1.sc = f2.sc)   AS overlapping_keys,
       (SELECT LISTAGG(DISTINCT st, ',') FROM f2)           AS status_values;
/* -> 121, 5, 5, 'True'

   FIVE OVERLAPPING KEYS. FILE 2 is a re-export of FILE 1's first five records
   (US_0001..US_0005) with Status bolted on - not five new stores. Appending it
   therefore DUPLICATES those business keys. COPY load history is keyed on FILE
   NAME, not business key, so it cannot detect this. See 09_idempotent_merge_fix.sql.
*/
