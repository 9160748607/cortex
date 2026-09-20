/* ###########################################################################
   COMPLETE FLOW - JSON
   Store Master schema drift & schema evolution, end to end.

   Target: ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
   Source: C:\Users\X1Carbon\Music\store-master-testing\json_data
             store_master.json                 22 keys, 121 records
             store_master_columns_added.json   23 keys,   5 records

   This is the whole sequence in one runnable file, with every recorded result
   inline. The individual 01-09 scripts are the same statements split by concern.

   Run order is strict. Steps 5-7 must precede step 8: the NaN investigation is
   what determines the target design, and two designs FAILED before the third
   worked.
   ###########################################################################

   ===========================================================================
   PART 0 - HOW JSON DATA IS SPLIT INTO COLUMNS AND LOCATED IN THE TARGET
   ===========================================================================

   JSON has NO columns and NO positions. It has named key/value pairs inside
   objects. Everything about the load follows from that.

   ---------------------------------------------------------------------------
   0.1  WHAT IS PHYSICALLY IN THE FILE
   ---------------------------------------------------------------------------
   Both source files are ONE top-level array containing objects:

       [
         { "store_code": "US_0001", "store_name": "Apple Bradleyton",
           "postal_code": "08759", "latitude": 42.839799,
           "store_close_date": NaN, ... },
         { "store_code": "US_0002", ... },
         ...121 objects...
       ]

   Snowflake parses this into a VARIANT - a self-describing tree, not a grid.
   There is no row. There is no column. There is a document.

   ---------------------------------------------------------------------------
   0.2  STAGE 1 OF 2 - FROM DOCUMENT TO ROWS  (STRIP_OUTER_ARRAY)
   ---------------------------------------------------------------------------
   The single most important format option here:

       STRIP_OUTER_ARRAY = FALSE (default)
           The ENTIRE array is ONE VARIANT value  ->  ONE ROW of 121 objects.
           The load "succeeds" and you get 1 row. Almost never what you want.

       STRIP_OUTER_ARRAY = TRUE
           Each element of the top-level array becomes its OWN ROW.
           121 objects -> 121 rows, each row one VARIANT OBJECT.

   So row-splitting is driven by ARRAY STRUCTURE, not by a record delimiter as in
   CSV. There is no \n significance; whitespace and line breaks are irrelevant.
   The files here are pretty-printed across ~24 lines per record and it makes no
   difference at all.

   ---------------------------------------------------------------------------
   0.3  STAGE 2 OF 2 - FROM OBJECT KEYS TO TARGET COLUMNS
   ---------------------------------------------------------------------------
   Each row is now a VARIANT OBJECT. With MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE:

     1. For each row, enumerate the object's KEYS.
     2. UPPER() each key and each target column name.
     3. Join on that uppercased name. Each match: the key's value is coerced to
        the declared Snowflake type and written to that column.
     4. Target column with NO matching key  -> NULL for that row.
     5. Key with NO matching target column  -> ENABLE_SCHEMA_EVOLUTION adds the
        column (name from the key, type inferred from the VALUE), then loads it.
        Existing rows get NULL.
     6. INCLUDE_METADATA columns are filled from METADATA$, never from the file.

   CRITICAL DIFFERENCE FROM CSV: key ORDER IS MEANINGLESS. These two objects are
   identical as far as the load is concerned:

       { "store_code": "US_0001", "city": "Bradleyton" }
       { "city": "Bradleyton", "store_code": "US_0001" }

   There is no $1, $2, $3 to bind to. This is why INFER_SCHEMA returns JSON keys
   ALPHABETICALLY - ORDER_ID is a sorted list index, NOT document position. And it
   is why MATCH_BY_COLUMN_NAME is not merely convenient for JSON, it is the only
   correct mechanism: there is no ordinal contract to fall back on.

   It also means MISSING KEYS ARE NORMAL, not an error. A record may legitimately
   omit a key; it simply yields NULL. There is no column-count concept, hence no
   ERROR_ON_COLUMN_COUNT_MISMATCH option for JSON - the CSV equivalent does not
   exist here because there is nothing to count.

   Worked example, store_master_columns_added.json into the 26-column target:

       JSON key            Target column        Outcome
       ---------------------------------------------------------------------
       store_code     ->   STORE_CODE           matched, loaded
       postal_code    ->   POSTAL_CODE          matched; "08759" stays '08759'
                                                because JSON QUOTED it
       is_active      ->   IS_ACTIVE            matched; string "Y" -> BOOLEAN TRUE
       Status         ->   (none)               EVOLUTION: adds STATUS TEXT,
                                                loads the string "True"
       (none)         <-   __FILE_NAME          from INCLUDE_METADATA
       (none)         <-   (any absent key)     NULL

   ---------------------------------------------------------------------------
   0.4  TYPES - PARTLY IN THE FILE, UNLIKE CSV
   ---------------------------------------------------------------------------
   JSON scalars carry a coarse type: string, number, true/false, null. That is
   more than CSV (everything is text) and far less than Parquet (full typed
   schema with logical annotations).

   Consequences seen in this dataset:

     postal_code "08759" is QUOTED, so it is a STRING. The leading zero is real
       data, not formatting. THE CSV VERSION OF THIS SAME DATA LOST IT, because a
       numeric export wrote 8759 and CSV has no way to say "this is text".
       7 leading-zero codes survive across the two JSON files.

     Status "True" is QUOTED, so evolution adds a TEXT column - not BOOLEAN. Had
       the producer emitted a real JSON boolean true, evolution would have added
       BOOLEAN. The quotes decided the column type.

     Dates are strings in JSON, so DATE_FORMAT still applies on coercion into a
       DATE target - but both files use ISO, so one format serves both. The CSV
       exercise needed TWO formats because its files disagreed on date order.

   ---------------------------------------------------------------------------
   0.5  THE NaN PROBLEM AND WHY NULL_IF BEHAVES ODDLY
   ---------------------------------------------------------------------------
   Both files contain, on every record:   "store_close_date": NaN

   NaN IS NOT VALID JSON. The specification defines numbers, strings, true,
   false, null, objects and arrays - there is no NaN literal. It is a
   pandas/numpy to_json() artefact where a missing value is emitted as the float
   NaN instead of JSON null.

   Three tested facts:
     - PowerShell ConvertFrom-Json ACCEPTS it and reports the file VALID.
       Local validation gives false confidence. Do not rely on it.
     - Snowflake ACCEPTS it and TYPEOF reports DOUBLE. Not NULL, not an error.
     - INFER_SCHEMA therefore types store_close_date as REAL - a DATE column
       reported as floating point.

   NULL_IF compares STRING representations. That single fact explains why the
   target design took three attempts (step 8):

       DATE target, no NULL_IF     -> fails: "Can't parse 'NaN' as date"
       DATE target, with NULL_IF   -> STILL fails. NaN was already parsed as a
                                      DOUBLE, so the string comparison never
                                      matched and DATE coercion ran on a float.
       VARCHAR target, with NULL_IF-> WORKS. On the way into a VARCHAR column the
                                      DOUBLE renders to the string 'NaN',
                                      NULL_IF matches it, value lands as NULL.

   The VARCHAR is not there to store text. It exists solely to give NULL_IF a
   string to match. All 126 rows end up as clean NULL, zero rows holding 'NaN'.

   ---------------------------------------------------------------------------
   0.6  WHY A TRANSFORMATION IS NOT AVAILABLE
   ---------------------------------------------------------------------------
   COPY INTO t FROM (SELECT $1:key::TYPE ...) cannot be combined with
   MATCH_BY_COLUMN_NAME. Evolution requires MATCH_BY_COLUMN_NAME, so there is no
   place to insert a TRY_TO_DATE mid-load. That is why the NaN had to be solved
   DECLARATIVELY in the file format plus the column type, rather than with a cast.
   ########################################################################### */


/* ===========================================================================
   STEP 1 - Create the schema

   Separate from DATA_MIGRATION (CSV) and DATA_MIGRATION_PARQUET: all three
   define a STORE_MASTER, so they cannot share a schema.
   =========================================================================== */
CREATE SCHEMA IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_JSON
  COMMENT = 'Store master JSON schema-drift and schema-evolution demonstration.';
-- -> Schema DATA_MIGRATION_JSON successfully created.


/* ===========================================================================
   STEP 2 - Create the JSON file format

   NULL_IF is folded in below. It was originally added by ALTER after the first
   load attempt failed; including it here means a fresh run works first time.

   Options that DO NOT EXIST for JSON, and why:
     PARSE_HEADER                    keys are self-describing, no header row
     ERROR_ON_COLUMN_COUNT_MISMATCH  objects have no column count to mismatch
     FIELD_DELIMITER / ENCLOSED_BY   structure is braces and quotes, not delimiters
   =========================================================================== */
CREATE FILE FORMAT IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json
  TYPE = JSON
  STRIP_OUTER_ARRAY = TRUE                       -- PART 0.2: 1 array -> 121 rows
  DATE_FORMAT = 'YYYY-MM-DD'                     -- both files are ISO
  TIMESTAMP_FORMAT = 'AUTO'
  COMPRESSION = AUTO
  NULL_IF = ('NaN', 'nan', 'NULL', 'null', '')   -- PART 0.5: the invalid literal
  COMMENT = 'JSON format for store master files. STRIP_OUTER_ARRAY turns each array element into a row; NULL_IF neutralises the invalid NaN literal in store_close_date.';
-- -> File format FF_STORE_MASTER_JSON successfully created.


/* ===========================================================================
   STEP 3 - Create the stage
   =========================================================================== */
CREATE STAGE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Internal stage holding store master JSON source files for the schema-drift demonstration.';
-- -> Stage area STORE_MASTER_JSON_STG successfully created.


/* ===========================================================================
   STEP 4 - Upload both files (CoCo / snow CLI, PowerShell)

     $ErrorActionPreference='Continue'
     cd "C:\Users\X1Carbon\Music\store-master-testing\json_data"

     foreach ($f in 'store_master.json','store_master_columns_added.json') {
       snow stage copy "$f" `
         '@ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/' `
         --connection ysirciu-vg28332 --overwrite
     }

   Recorded:
     | store_master.json               | 88095 | UPLOADED |
     | store_master_columns_added.json |  3784 | UPLOADED |

   Optional LOCAL pre-check - and note what NOT to use:
     # WRONG: ConvertFrom-Json ACCEPTS the invalid NaN and reports VALID
     # RIGHT: plain text scan
     ([regex]::Matches((Get-Content $f -Raw),'\bNaN\b')).Count
     -> 121 and 5 respectively
   =========================================================================== */
LIST @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/;


/* ===========================================================================
   STEP 5 - Schema detection, PER FILE

   Remember PART 0.3: ORDER_ID is an ALPHABETICAL index, not document position.
   =========================================================================== */

-- FILE 1
SELECT ORDER_ID, COLUMN_NAME, TYPE, NULLABLE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master.json',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json'
)) ORDER BY ORDER_ID;
/* 22 keys, ALPHABETICAL:
     address_line1 TEXT          longitude REAL
     annual_rent_usd NUMBER(8,0) postal_code TEXT     <-- quoted, zeros SAFE
     city TEXT                   region_code TEXT
     country_code TEXT           source_system TEXT
     created_at TIMESTAMP_NTZ    state_code TEXT
     effective_end_date DATE     store_close_date REAL  <-- !! NaN, see step 7
     effective_start_date DATE   store_code TEXT
     floor_area_sqft NUMBER(5,0) store_name TEXT
     format_code TEXT            store_open_date DATE
     is_active TEXT  ("Y")       tax_jurisdiction_code TEXT
     latitude NUMBER(8,6)
     lifecycle_status TEXT                                                     */

-- FILE 2
SELECT ORDER_ID, COLUMN_NAME, TYPE, NULLABLE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master_columns_added.json',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json'
)) ORDER BY ORDER_ID;
/* 23 keys. EXACTLY ONE difference vs FILE 1:
     Status  TEXT     <-- NEW KEY

   Every shared key has an IDENTICAL inferred type. Unlike the CSV exercise there
   is NO type drift between the two JSON files. JSON's self-typed, quoted values
   are why: postal_code is "08759" in both, dates are ISO in both.

   Status holds the STRING "True", not a JSON boolean - hence TEXT (PART 0.4).  */


/* ===========================================================================
   STEP 6 - Coercion probes

   Every risky conversion tested BEFORE designing the target. This is what saved
   several failed load attempts - and note that ONE of them still failed anyway,
   because a probe tests the VALUE while the load tests the COERCION PATH.
   =========================================================================== */
SELECT
    $1:store_close_date::FLOAT                   AS nan_as_float,    -- NaN
    TRY_TO_DATE($1:store_close_date::VARCHAR)    AS nan_to_date,     -- NULL
    TRY_TO_BOOLEAN($1:is_active::VARCHAR)        AS y_to_boolean,    -- TRUE
    TRY_TO_DATE($1:store_open_date::VARCHAR)     AS open_to_date,    -- 2017-09-01
    TRY_TO_TIMESTAMP_NTZ($1:created_at::VARCHAR) AS created_to_ts,   -- parses
    TRY_TO_DATE($1:effective_end_date::VARCHAR)  AS eff_end_to_date, -- 9999-12-31
    $1:postal_code::VARCHAR                      AS postal_text      -- 08759
FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master.json
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
LIMIT 2;
/* Everything coerces cleanly EXCEPT store_close_date. is_active "Y" -> TRUE and
   created_at parses as a real timestamp, so BOTH can be strongly typed - a
   contrast with the CSV run, where file 2's created_at was corrupted.

   THE JSON WIN OVER CSV: postal_text comes back '08759' with the leading zero
   intact, because JSON quotes it. The CSV version of this same data lost it. */


/* ===========================================================================
   STEP 7 - The NaN investigation  (PART 0.5 has the full reasoning)
   =========================================================================== */
SELECT $1:store_code::VARCHAR      AS store_code,
       $1:store_close_date         AS close_date_variant,
       TYPEOF($1:store_close_date) AS close_date_type,
       $1:postal_code::VARCHAR     AS postal_code,
       $1:latitude                 AS latitude
FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master.json
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
LIMIT 3;
/* -> close_date_variant = NaN, close_date_type = DOUBLE
   Snowflake accepted an invalid JSON literal and typed it as a float. THAT is
   why INFER_SCHEMA reported REAL for a column named ..._date. */

-- Record counts and KEY OVERLAP - this one matters for step 13.
WITH f1 AS (
  SELECT $1:store_code::VARCHAR AS sc
  FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master.json
       (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
), f2 AS (
  SELECT $1:store_code::VARCHAR AS sc, $1:Status::VARCHAR AS st
  FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master_columns_added.json
       (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
)
SELECT (SELECT COUNT(*) FROM f1)                          AS f1_rows,
       (SELECT COUNT(*) FROM f2)                          AS f2_rows,
       (SELECT COUNT(*) FROM f2 JOIN f1 ON f1.sc = f2.sc) AS overlapping_keys,
       (SELECT LISTAGG(DISTINCT st, ',') FROM f2)         AS status_values;
-- -> 121, 5, 5, 'True'
-- FIVE OVERLAPPING KEYS. File 2 re-exports file 1's US_0001..US_0005 with Status
-- added - not five new stores. Appending will DUPLICATE those keys. See step 13.


/* ===========================================================================
   STEP 8 - Create the target

   From FILE 1's 22 keys ONLY. `Status` deliberately NOT declared.

   *** store_close_date TOOK THREE ATTEMPTS. THE FIRST TWO ARE INSTRUCTIVE. ***

   Attempt 1 - store_close_date DATE (semantically correct):
       COPY -> Can't parse 'NaN' as date with format 'YYYY-MM-DD'
       MATCH_BY_COLUMN_NAME forbids a mid-load cast (PART 0.6), so there was
       nowhere to intercept it.

   Attempt 2 - DATE + NULL_IF = ('NaN', ...) on the file format:
       COPY -> STILL FAILED, identical error.
       NULL_IF compares STRINGS. NaN was already parsed as a DOUBLE, so the
       comparison never matched and DATE coercion ran on a float. This is the
       non-obvious one and the reason it is recorded here.

   Attempt 3 - VARCHAR + NULL_IF:   WORKS.
       The DOUBLE renders to the string 'NaN' on its way into a VARCHAR column,
       NULL_IF matches, value lands as NULL. Verified after load: all 126 rows
       NULL, ZERO rows holding the text 'NaN'.

   So the column is VARCHAR but contains proper NULLs, not junk. It is VARCHAR
   only to give NULL_IF a string to match.

   NOTE ON CREATE OR REPLACE: attempt 3 needed DATE -> VARCHAR, which ALTER
   COLUMN cannot do. CREATE OR REPLACE was used ONCE, only after verifying the
   table held 0 rows (both prior COPYs failed atomically) in a schema created
   minutes earlier with no dependents. It is IF NOT EXISTS below so a fresh run
   is safe and idempotent.
   =========================================================================== */
CREATE TABLE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER (
  store_code               VARCHAR(30)     COMMENT 'Source store code, primary business key.',
  store_name               VARCHAR(150)    COMMENT 'Retail store name.',
  country_code             VARCHAR(10)     COMMENT 'ISO alpha-2 country code.',
  region_code              VARCHAR(20)     COMMENT 'Region code, e.g. AMER/EMEA/APAC.',
  tax_jurisdiction_code    VARCHAR(30)     COMMENT 'Sub-national tax jurisdiction code.',
  format_code              VARCHAR(20)     COMMENT 'Store format, e.g. FLG (flagship) or MINI.',
  city                     VARCHAR(100)    COMMENT 'City of the store location.',
  state_code               VARCHAR(20)     COMMENT 'State or province code.',
  -- JSON quotes this, so the leading zero is real data. VARCHAR preserves it;
  -- NUMBER would destroy all 7 such codes across the two files.
  postal_code              VARCHAR(30)     COMMENT 'Postal code as text; JSON supplies it quoted so leading zeros survive.',
  address_line1            VARCHAR(255)    COMMENT 'Street address line of the store.',
  -- Inferred precision has no headroom: NUMBER(9,6) cannot hold -180.000000.
  latitude                 NUMBER(9,6)     COMMENT 'Store latitude in decimal degrees.',
  longitude                NUMBER(10,6)    COMMENT 'Store longitude in decimal degrees.',
  store_open_date          DATE            COMMENT 'Date the store opened.',
  -- See the three-attempt note above. VARCHAR exists to enable NULL_IF.
  store_close_date         VARCHAR(50)     COMMENT 'Close date, all NULL in current sources. Source ships the non-standard JSON literal NaN which Snowflake parses as DOUBLE; a DATE target fails outright, so this lands as VARCHAR where file-format NULL_IF can match the string NaN and yield NULL. Convert with TRY_TO_DATE if real dates ever arrive.',
  lifecycle_status         VARCHAR(30)     COMMENT 'Lifecycle state, e.g. ACTIVE/CLOSED.',
  -- Inferred NUMBER(5,0) caps floor area at 99,999 sqft; NUMBER(8,0) caps rent
  -- at ~100M and scale 0 would round cents away.
  floor_area_sqft          NUMBER(10,0)    COMMENT 'Retail floor area in square feet.',
  annual_rent_usd          NUMBER(14,2)    COMMENT 'Annual rent in USD.',
  -- Verified in step 6: the string "Y" coerces to TRUE.
  is_active                BOOLEAN         COMMENT 'Active flag; source ships the string Y.',
  effective_start_date     DATE            COMMENT 'Date the record became effective.',
  effective_end_date       DATE            COMMENT 'Date the record stopped being effective.',
  -- Strongly typed here, unlike the CSV run: both JSON files ship clean ISO
  -- timestamps, so there is no corruption to preserve.
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Originating source system.',
  -- NO DEFAULT on __loaded_at: COPY silently IGNORES column defaults under
  -- MATCH_BY_COLUMN_NAME. Metadata does the job instead.
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row came from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: row ordinal within the source file (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: staged file last modified time (METADATA$FILE_LAST_MODIFIED).',
  __loaded_at              TIMESTAMP_NTZ   COMMENT 'Audit: when the row was loaded (METADATA$START_SCAN_TIME).'
)
ENABLE_SCHEMA_EVOLUTION = TRUE          -- <<< the evolution switch
COMMENT = 'Unified store master JSON target. Created from file 1 keys only; ENABLE_SCHEMA_EVOLUTION lets COPY add later keys such as Status automatically.';
-- -> Table STORE_MASTER successfully created.  26 columns, 0 rows.

SHOW TABLES LIKE 'STORE_MASTER' IN SCHEMA ANALYSIS_DB.DATA_MIGRATION_JSON;
-- verify ENABLE_SCHEMA_EVOLUTION = Y


/* ===========================================================================
   STEP 9 - LOAD 1: baseline, no drift

   Mapping performed (PART 0.2 then 0.3):
     array stripped  -> 121 rows
     22 object keys  -> 22 target columns, matched by uppercased name
     4 audit columns -> from METADATA$
     nothing unmatched either way -> NO evolution event
   =========================================================================== */
COPY INTO ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master.json
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;
-- -> LOADED, rows_parsed 121, rows_loaded 121, errors_seen 0
-- Table now 26 columns, 121 rows.

-- Leading zeros survived - JSON quoted them AND the target is VARCHAR.
SELECT store_code, postal_code, store_open_date, store_close_date, is_active, created_at
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
WHERE postal_code LIKE '0%' ORDER BY store_code;
-- -> 08759, 02166, 00158, ... (5 in this file)

-- The NaN became a proper NULL, not the text 'NaN'. Proof attempt 3 worked.
SELECT SUM(IFF(store_close_date IS NULL,1,0)) AS close_date_null,
       SUM(IFF(store_close_date = 'NaN',1,0)) AS close_date_literal_nan
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER;
-- -> 121, 0


/* ===========================================================================
   STEP 10 - LOAD 2: ADDITIVE DRIFT -> SCHEMA EVOLUTION FIRES

   Byte-identical COPY, different path. NO DDL issued.

   Mapping performed:
     22 keys matched existing target columns
     Status  NO match -> evolution ALTERs the table, appends
             STATUS TEXT(16777216) at position 27, loads the string "True".
             TEXT not BOOLEAN because the producer QUOTED the value (PART 0.4).
             Unbounded because evolution does not guess a length.
     121 existing rows -> STATUS = NULL automatically.

   No file format change needed - unlike the CSV run, where each file required
   its own DATE_FORMAT. Both JSON files use ISO dates.
   =========================================================================== */
COPY INTO ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master/store_master_columns_added.json
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;
-- -> LOADED, rows_parsed 5, rows_loaded 5, errors_seen 0
-- Table now 27 columns, 126 rows.  EVOLUTION EVENT.


/* ===========================================================================
   STEP 11 - Verify evolution
   =========================================================================== */
SELECT ORDINAL_POSITION AS pos, COLUMN_NAME, DATA_TYPE,
       COALESCE(CHARACTER_MAXIMUM_LENGTH::VARCHAR,
                NUMERIC_PRECISION||','||NUMERIC_SCALE,'') AS size,
       IS_NULLABLE, COMMENT
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA='DATA_MIGRATION_JSON' AND TABLE_NAME='STORE_MASTER'
ORDER BY ORDINAL_POSITION;
/* Position 27 = STATUS, TEXT, 16777216, COMMENT NULL.
   A commentless column is an evolved column - every hand-declared one has a
   COMMENT. Worth back-filling with COMMENT IF EXISTS. */

-- NULL back-fill proof
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file,
       COUNT(*)                            AS row_cnt,
       COUNT(STATUS)                       AS status_filled,
       SUM(IFF(STATUS IS NULL,1,0))        AS status_nulls,
       COUNT(DISTINCT store_code)          AS distinct_keys
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* store_master.json                121   0  121  121
   store_master_columns_added.json    5   5    0    5                          */


/* ===========================================================================
   STEP 12 - Validate
   =========================================================================== */
SELECT
  REGEXP_SUBSTR(__file_name,'[^/]+$')        AS source_file,
  COUNT(*)                                   AS row_cnt,
  COUNT(STATUS)                              AS status_filled,
  SUM(IFF(STATUS IS NULL,1,0))               AS status_nulls,
  COUNT(DISTINCT store_code)                 AS distinct_keys,
  SUM(IFF(store_close_date = 'NaN',1,0))     AS close_date_nan,
  SUM(IFF(postal_code LIKE '0%',1,0))        AS leading_zero_postals,
  SUM(IFF(created_at IS NULL,1,0))           AS created_at_unparsed,
  SUM(IFF(is_active IS NULL,1,0))            AS is_active_unparsed
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* store_master.json                121   0  121  121  0  5  0  0
   store_master_columns_added.json    5   5    0    5  0  2  0  0
   TOTAL                            126   5  121  121  0  7  0  0

   Reading the TOTAL row:
     STATUS nulls 121              additive drift made visible
     0 rows holding 'NaN'          NULL_IF worked via the VARCHAR path
     7 leading-zero postals KEPT   the JSON win over CSV
     0 unparsed timestamps         both files ship clean ISO
     0 unparsed booleans           "Y" -> TRUE on every row

   NOTE 126 rows but only 121 distinct keys -> 5 DUPLICATES. See step 13.      */

-- Side by side: identical record, file 2 adds only Status.
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS src, store_code, store_name,
       postal_code, latitude, store_open_date, store_close_date,
       is_active, created_at, STATUS
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
WHERE store_code IN ('US_0001','US_0002') ORDER BY store_code, src;
/* Each store appears TWICE - once per file - differing ONLY in STATUS.
   The duplicate-key problem, visible in one query. */


/* ===========================================================================
   STEP 13 - Duplicate business keys  (detection only; fix in 09_idempotent_merge_fix.sql)

   File 2 is a re-export of file 1's first five records with Status added. COPY
   load history is keyed on FILE NAME, not business key, so the differently-named
   file loaded again.

   NOT a drift or evolution failure - evolution did its job correctly. A
   de-duplication gap in the load strategy, easy to miss because the load
   reported SUCCESS.

   Contrast the Parquet exercise, where file 2 RE-KEYED the same stores
   (US_0001 -> US_0101). There the keys did not collide, so this query returns
   nothing and the duplication is invisible. Colliding keys are the FRIENDLIER
   failure: at least they show up here.
   =========================================================================== */
SELECT store_code, COUNT(*) AS row_cnt,
       LISTAGG(REGEXP_SUBSTR(__file_name,'[^/]+$'), ' | ') AS from_files
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
GROUP BY store_code HAVING COUNT(*) > 1
ORDER BY store_code;
-- -> US_0001..US_0005, 2 rows each, from both files.

/* Had loads 9/10 used the staged-MERGE pattern in 09_idempotent_merge_fix.sql
   instead of two plain COPYs, the result would be 121 rows with Status populated
   on the first five - no duplicates at all. The 5 extra rows exist purely
   because COPY appends. That script is NOT executed: it mutates loaded data and
   contains a DELETE. */


/* ===========================================================================
   STEP 14 - Future-keys test  (EXECUTED, THEN ROLLED BACK)

   A 25-key file adding manager_name and employee_count, written to a TEMP
   directory - never to the source folder - and staged under a separate prefix.
   It also used "store_close_date": null - PROPER JSON null, which is what the
   real export should have emitted all along.

   Local file content (abridged):
     [ { "store_code": "US_9001", ..., "Status": "True",
         "manager_name": "Jane Okafor", "employee_count": 87 },
       { "store_code": "US_9002", ..., "Status": "False",
         "manager_name": "Raj Mehta",   "employee_count": 34 } ]

   Uploaded with:
     snow stage copy "<temp>\store_master_future_keys.json" `
       '@ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master-future/' `
       --connection ysirciu-vg28332 --overwrite
   =========================================================================== */
COPY INTO ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg/store-master-future/store_master_future_keys.json
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_JSON.ff_store_master_json')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;
-- -> LOADED 2 rows. Table 27 -> 29 columns. NO ALTER TABLE was issued.

SELECT ORDINAL_POSITION AS pos, COLUMN_NAME, DATA_TYPE,
       COALESCE(CHARACTER_MAXIMUM_LENGTH::VARCHAR,
                NUMERIC_PRECISION||','||NUMERIC_SCALE,'') AS size
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA='DATA_MIGRATION_JSON' AND TABLE_NAME='STORE_MASTER'
  AND ORDINAL_POSITION >= 27 ORDER BY ORDINAL_POSITION;
/* 27 STATUS TEXT 16777216 / 28 EMPLOYEE_COUNT NUMBER(2,0) / 29 MANAGER_NAME TEXT

   TWO THINGS TO NOTICE:

   1) ALPHABETICAL ORDER. EMPLOYEE_COUNT (28) landed BEFORE MANAGER_NAME (29)
      even though the document lists manager_name first - consistent with PART
      0.3: JSON keys have no order, so evolution appends them sorted. The Parquet
      exercise appended them in DOCUMENT order instead. Evolved column ordering
      is FORMAT-DEPENDENT; never depend on it.

   2) EMPLOYEE_COUNT NUMBER(2,0) - sized from a 2-record sample (87, 34), giving a
      CEILING OF 99. Evolution did not choose a sensible type, it chose the
      smallest that fit what it saw. A store with 100 staff fails the next load.
      Evolved columns need a precision review; they are not free.              */

-- NULL staircase across all three files
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$')          AS source_file,
       COUNT(*)                                     AS row_cnt,
       SUM(IFF(STATUS IS NULL,1,0))                 AS status_nulls,
       SUM(IFF(MANAGER_NAME IS NULL,1,0))           AS manager_nulls,
       SUM(IFF(EMPLOYEE_COUNT IS NULL,1,0))         AS empcount_nulls
FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* store_master.json                121  121  121  121
   store_master_columns_added.json    5    0    5    5
   store_master_future_keys.json      2    0    0    0
   A clean staircase: each file fills exactly the keys it supplies.            */

-- Rollback: rows go, COLUMNS STAY. Evolution is not reversible by DELETE.
DELETE FROM ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER
WHERE __file_name LIKE 'store-master-future/%';
-- -> 2 rows deleted. Back to 126 rows, still 29 columns.

-- Staged fixture also removed:
--   snow stage remove '@ANALYSIS_DB.DATA_MIGRATION_JSON.store_master_json_stg' \
--     'store-master-future/store_master_future_keys.json' --connection ysirciu-vg28332


/* ###########################################################################
   FINAL STATE

     126 rows, 121 distinct store_code, 29 columns, 2 source files
     5 duplicate business keys outstanding (step 13)
     Source files byte-identical: 88,095 / 3,784 bytes, original timestamps

   STATE TRANSITIONS
     step  8  create target (file 1 keys)       26 cols      0 rows   -
     step  9  COPY file 1                       26 cols    121 rows   no evolution
     step 10  COPY file 2                       26 -> 27   126 rows   EVOLUTION
     step 14  COPY future-keys fixture          27 -> 29   128 rows   EVOLUTION
     step 14  delete fixture rows               29 cols    126 rows   cols persist

   WHAT JSON MADE EASY, AND WHAT IT MADE HARD

     EASIER THAN CSV
       Quoted values preserved postal-code leading zeros that the CSV export
       destroyed - 7 codes saved.
       Self-typed scalars meant NO type drift between the two files, so no
       per-file DATE_FORMAT and no dual-format setup.
       Key-based structure means missing keys are normal, not an error.

     HARDER THAN CSV AND PARQUET
       The NaN literal is INVALID JSON that both a lenient client parser AND
       Snowflake accept - Snowflake as a DOUBLE. Nothing flags it. It took three
       target designs to handle, and the failing middle attempt (DATE + NULL_IF)
       is the one worth remembering: NULL_IF compares strings, so it cannot
       intercept a value that has already been parsed as a number.

   The general lesson: "the file parsed successfully" is not the same as "the
   data is valid".
   ########################################################################### */
