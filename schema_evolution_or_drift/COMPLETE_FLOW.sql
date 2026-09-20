/* ###########################################################################
   COMPLETE FLOW - CSV
   Store Master schema drift & schema evolution, end to end.

   Target: ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
   Source: C:\Users\X1Carbon\Music\store-master-testing
             store_master.csv                                  22 cols, 121 rows
             store_master_1.csv                                23 cols,   5 rows
             store_master_2_deleted_columns.csv                 17 cols,   5 rows
             store_master_3_datatypechange_numberdata...csv     23 cols,   5 rows

   FOUR files, and ALL THREE categories of drift are demonstrated here - the most
   complete of the three format exercises:

     additive     file 2 adds a column       -> evolution absorbs it
     subtractive  file 3 drops six columns   -> evolution does NOTHING, load
                                                still SUCCEEDS (the dangerous one)
     type         file 4 puts text in a
                  numeric column             -> load is REJECTED outright

   This is the whole sequence in one runnable file with every recorded result
   inline. The individual 01-11 scripts are the same statements split by concern.
   ###########################################################################

   ===========================================================================
   PART 0 - HOW CSV DATA IS SPLIT INTO COLUMNS AND LOCATED IN THE TARGET
   ===========================================================================

   CSV is the only one of the three formats where columns have to be MANUFACTURED
   from a flat byte stream. Parquet already has columns; JSON has named keys. CSV
   has neither - it has text and a set of rules for cutting it up. Every quirk
   below follows from that.

   ---------------------------------------------------------------------------
   0.1  WHAT IS PHYSICALLY IN THE FILE
   ---------------------------------------------------------------------------
   One undifferentiated stream of characters:

       store_code,store_name,...,source_system\n
       US_0001,Apple Bradleyton,...,RETAIL_OPS\n
       US_0002,"20653 Nguyen Summit\nSuite 103",...,RETAIL_OPS\n

   No types. No names, except by convention on the first line. No structure at
   all beyond two delimiter characters.

   ---------------------------------------------------------------------------
   0.2  STAGE 1 OF 3 - BYTES TO FIELDS  (this is where CSV earns its reputation)
   ---------------------------------------------------------------------------
       RECORD_DELIMITER = '\n'              cut the stream into records
       FIELD_DELIMITER  = ','               cut each record into fields
       FIELD_OPTIONALLY_ENCLOSED_BY = '"'   ...except inside quotes

   That third option is not cosmetic. Without it a comma inside an address splits
   the row and every subsequent field shifts one column left - a silent, total
   corruption of the record.

   It also means A RECORD IS NOT A LINE. Quoted fields may contain the record
   delimiter itself. In store_master.csv, FIVE address values contain embedded
   newlines, so:

       126 physical lines  ->  121 logical records

   A shell line count says 126 and is WRONG. This was verified rather than
   assumed - see step 6. Never reconcile a CSV row count against wc -l or
   Measure-Object without checking for quoted newlines first.

   After this stage the fields are positional only:  $1, $2, $3 ... $n

   ---------------------------------------------------------------------------
   0.3  STAGE 2 OF 3 - FIELDS TO NAMES  (PARSE_HEADER)
   ---------------------------------------------------------------------------
       PARSE_HEADER = TRUE
           The FIRST record is consumed as NAMES, not data. Field k's name is
           header token k. Enables INFER_SCHEMA and MATCH_BY_COLUMN_NAME.
           MUTUALLY EXCLUSIVE with SKIP_HEADER.
           CANNOT be used in an ad-hoc SELECT over a stage - Snowflake raises
           "PARSE_HEADER is only allowed for CSV INFER_SCHEMA and
           MATCH_BY_COLUMN_NAME". That is why a THIRD format,
           ff_store_master_inspect with SKIP_HEADER = 1, exists purely for
           profiling queries.

   Names are therefore POSITIONALLY DERIVED. The header is just another line
   subject to the same cutting rules, and the link between a name and a value is
   "they were the k-th thing on their respective lines". Contrast JSON, where the
   name is physically attached to its value, and Parquet, where the name is in a
   schema footer.

   ---------------------------------------------------------------------------
   0.4  STAGE 3 OF 3 - NAMES TO TARGET COLUMNS  (MATCH_BY_COLUMN_NAME)
   ---------------------------------------------------------------------------
     1. UPPER() each header-derived name and each target column name.
     2. Join on that uppercased name. Each match: the field's TEXT is coerced to
        the declared Snowflake type, using DATE_FORMAT / TIMESTAMP_FORMAT /
        NULL_IF from the file format as the coercion rules.
     3. Target column with NO matching header  -> NULL for these rows.
     4. Header with NO matching target column  -> ENABLE_SCHEMA_EVOLUTION adds it.
     5. INCLUDE_METADATA columns come from METADATA$, never from the file.

       ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE  IS MANDATORY
           Default TRUE compares the file's FIELD COUNT to the TARGET's COLUMN
           COUNT and aborts on any difference:
             "Number of columns in file (22) does not match that of the
              corresponding table (26)"
           The whole point of MATCH_BY_COLUMN_NAME is that those counts differ -
           the target has audit columns the file does not, and drifting files have
           different widths. Leaving this at TRUE makes evolution IMPOSSIBLE.
           This was the first real failure of the exercise.

   So CSV binds in TWO stages: POSITIONAL parse, then NAME-BASED bind. Both can
   break independently, and only the second produces a helpful error.

   ---------------------------------------------------------------------------
   0.5  NO TYPES IN THE FILE - THE ROOT OF MOST CSV PAIN
   ---------------------------------------------------------------------------
   Every CSV field is text. Types come ENTIRELY from the target column plus the
   file format's coercion rules. Four consequences, all visible in this dataset:

     a) LEADING ZEROS ARE UNRECOVERABLE ONCE LOST. File 1 writes 08759, file 2
        writes 8759. CSV cannot say "this is text" - so if the producer formatted
        it as a number, the zero is gone before Snowflake sees the file.
        postal_code MUST be VARCHAR in the target, or file 1's 5 zero-prefixed
        codes are destroyed to match file 2's damage.
        (JSON avoided this by quoting; Parquet by having a STRING type.)

     b) DATE FORMAT IS A GUESS UNLESS DECLARED. File 1 writes 2017-09-01, files
        2/3/4 write 01-09-2017. Same nine characters, opposite meaning.
        Tested: TRY_TO_DATE('01-09-2017','DD-MM-YYYY') -> 2017-09-01 correct
                TRY_TO_DATE('01-09-2017')              -> NULL
        AUTO fails LOUDLY rather than silently reading 1 Sep as 9 Jan. That is
        the only reason per-file DATE_FORMAT is a safe fix rather than a gamble -
        a wrong guess would produce plausible wrong dates, not an error.
        Hence TWO file formats: ff_store_master_iso and ff_store_master_eu.

     c) CORRUPTION IS INDISTINGUISHABLE FROM DATA. File 2's created_at is
        '21:50.4' - a time fragment with no date. It is just text, so nothing
        rejects it at parse time; it only fails when coerced to TIMESTAMP.

     d) A TEXT VALUE IN A NUMERIC COLUMN ABORTS THE LOAD. File 4 has the literal
        'testing' in floor_area_sqft. See step 14.

   ---------------------------------------------------------------------------
   0.6  WHY A TRANSFORMATION IS NOT AVAILABLE
   ---------------------------------------------------------------------------
   COPY INTO t FROM (SELECT $1::TYPE, ...) cannot be combined with
   MATCH_BY_COLUMN_NAME. Evolution needs MATCH_BY_COLUMN_NAME, so there is no
   mid-load cast available. Everything must be solved by DECLARATION (column
   types), by FILE FORMAT (DATE_FORMAT, NULL_IF), or by a STAGING TABLE
   (step 14's quarantine pattern).
   ########################################################################### */


/* ===========================================================================
   STEP 1 - Create database and schema
   =========================================================================== */
CREATE DATABASE IF NOT EXISTS ANALYSIS_DB
  COMMENT = 'Analysis and data-migration workbench database.';

CREATE SCHEMA IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION
  COMMENT = 'Store master schema-drift and schema-evolution demonstration.';


/* ===========================================================================
   STEP 2 - Create THREE file formats

   Two loaders differing ONLY in DATE_FORMAT (PART 0.5b), plus one inspector.
   ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE is folded in below; it was originally
   added by ALTER after the first load failed (PART 0.4).
   =========================================================================== */

-- Loader 1: ISO dates (store_master.csv)
CREATE FILE FORMAT IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.ff_store_master_iso
  TYPE = CSV
  PARSE_HEADER = TRUE                       -- PART 0.3
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'        -- PART 0.2: 5 addresses need this
  TRIM_SPACE = TRUE
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('', 'NULL', 'null', 'N/A')
  DATE_FORMAT = 'YYYY-MM-DD'
  TIMESTAMP_FORMAT = 'AUTO'
  COMPRESSION = AUTO
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE    -- PART 0.4: MANDATORY
  COMMENT = 'CSV format for store master files using ISO YYYY-MM-DD dates; PARSE_HEADER enables INFER_SCHEMA and schema evolution.';

-- Loader 2: day-first dates (files 2, 3, 4)
CREATE FILE FORMAT IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE
  EMPTY_FIELD_AS_NULL = TRUE
  NULL_IF = ('', 'NULL', 'null', 'N/A')
  DATE_FORMAT = 'DD-MM-YYYY'                -- the ONLY difference
  TIMESTAMP_FORMAT = 'AUTO'
  COMPRESSION = AUTO
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  COMMENT = 'CSV format for store master files using DD-MM-YYYY dates; PARSE_HEADER enables INFER_SCHEMA and schema evolution.';

-- Inspector: PARSE_HEADER formats CANNOT be used in SELECT (PART 0.3), so
-- profiling needs SKIP_HEADER. Not used by any COPY.
CREATE FILE FORMAT IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.ff_store_master_inspect
  TYPE = CSV
  SKIP_HEADER = 1
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE
  EMPTY_FIELD_AS_NULL = TRUE
  COMMENT = 'Skip-header CSV format for ad-hoc staged-file inspection; PARSE_HEADER formats cannot be used in SELECT.';


/* ===========================================================================
   STEP 3 - Create the stage
   =========================================================================== */
CREATE STAGE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.store_master_stg
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Internal stage holding store master source CSVs for the schema-drift demonstration.';


/* ===========================================================================
   STEP 4 - Upload all four files (CoCo / snow CLI, PowerShell)

     $ErrorActionPreference='Continue'
     cd "C:\Users\X1Carbon\Music\store-master-testing"
     foreach ($f in 'store_master.csv','store_master_1.csv',
                    'store_master_2_deleted_columns.csv',
                    'store_master_3_datatypechange_numberdatasendingtextinafile.csv') {
       snow stage copy "$f" `
         '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/' `
         --connection ysirciu-vg28332 --overwrite
     }

   Per-file calls, NOT a *.csv glob: PowerShell expands globs before snow sees
   them, which breaks the argument.
   =========================================================================== */
LIST @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/;


/* ===========================================================================
   STEP 5 - Schema detection, PER FILE
   Pair each file with the format matching its DATE convention.
   =========================================================================== */

-- FILE 1: 22 columns
SELECT ORDER_ID, COLUMN_NAME, TYPE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master.csv',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_iso')) ORDER BY ORDER_ID;
/*  8 postal_code           TEXT            <-- string here
   12 store_open_date       DATE
   18 effective_start_date  DATE
   19 effective_end_date    DATE
   20 created_at            TIMESTAMP_NTZ
   13 store_close_date      TEXT            (all empty, no type evidence)
   ORDER_ID here IS field position - CSV is the only format where that is true. */

-- FILE 2: 23 columns  (ADDITIVE drift)
SELECT ORDER_ID, COLUMN_NAME, TYPE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_1.csv',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')) ORDER BY ORDER_ID;
/* Differences vs FILE 1 - FIVE type drifts plus one new column:
     8 postal_code           NUMBER(5,0)   <-- was TEXT: leading zeros DESTROYED
    12 store_open_date       TEXT          <-- was DATE: day-first not detected
    18 effective_start_date  TEXT          <-- was DATE
    19 effective_end_date    TEXT          <-- was DATE
    20 created_at            TEXT          <-- was TIMESTAMP: value is '21:50.4'
    22 Status                BOOLEAN       <-- NEW COLUMN                       */

-- FILE 3: 17 columns  (SUBTRACTIVE drift)
SELECT ORDER_ID, COLUMN_NAME, TYPE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_2_deleted_columns.csv',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')) ORDER BY ORDER_ID;
/* SIX columns from FILE 1 are ABSENT:
     format_code, city, state_code, postal_code, address_line1, latitude
   Status IS present. longitude survived but latitude did not - the geo pair is
   HALF-broken, which is worse than losing both: a naive map plot silently
   misplaces stores rather than showing nothing.                               */

-- FILE 4: 23 columns  (TYPE drift inside a column)
SELECT ORDER_ID, COLUMN_NAME, TYPE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_3_datatypechange_numberdatasendingtextinafile.csv',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')) ORDER BY ORDER_ID;
/* NO structural drift - column list identical to FILE 2. The damage is INSIDE:
    15 floor_area_sqft  TEXT   <-- NUMBER in every other file
       rows 1-2 hold the literal string 'testing'; rows 3-5 hold valid numbers  */


/* ===========================================================================
   STEP 6 - Value probes and the row-count reconciliation
   =========================================================================== */

-- Date convention test (PART 0.5b). Uses the INSPECT format, not PARSE_HEADER.
SELECT $13                            AS open_raw,
       TRY_TO_DATE($13,'DD-MM-YYYY')  AS open_day_first,   -- 2017-09-01 correct
       TRY_TO_DATE($13)               AS open_auto,        -- NULL, cannot parse
       $20                            AS eff_end_raw,
       TRY_TO_DATE($20,'DD-MM-YYYY')  AS eff_end_day_first,-- 9999-12-31
       $21                            AS created_raw,      -- '21:50.4'
       TRY_TO_TIMESTAMP_NTZ($21)      AS created_parsed,   -- NULL, no date part
       $9                             AS postal_raw,       -- 8759 vs 08759
       $23                            AS status_raw        -- 'y'
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_1.csv
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_inspect')
LIMIT 3;

-- ROW COUNT RECONCILIATION (PART 0.2). A shell line count says 126; the real
-- record count is 121, because 5 addresses contain embedded newlines inside
-- quoted fields. ALWAYS confirm this before trusting a line count.
SELECT COUNT(*) AS data_rows, COUNT(DISTINCT $1) AS distinct_store_codes
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master.csv
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_inspect');
-- -> 121, 121


/* ===========================================================================
   STEP 7 - Create the target

   From FILE 1's 22 columns ONLY. `Status` deliberately NOT declared.
   =========================================================================== */
CREATE TABLE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER (
  store_code               VARCHAR(30)     COMMENT 'Source store code, primary business key.',
  store_name               VARCHAR(150)    COMMENT 'Retail store name.',
  country_code             VARCHAR(10)     COMMENT 'ISO alpha-2 country code.',
  region_code              VARCHAR(20)     COMMENT 'Region code, e.g. AMER/EMEA/APAC.',
  tax_jurisdiction_code    VARCHAR(30)     COMMENT 'Sub-national tax jurisdiction code.',
  format_code              VARCHAR(20)     COMMENT 'Store format, e.g. FLG (flagship) or MINI.',
  city                     VARCHAR(100)    COMMENT 'City of the store location.',
  state_code               VARCHAR(20)     COMMENT 'State or province code.',
  -- NON-NEGOTIABLE (PART 0.5a). Accepting file 2's NUMBER inference would strip
  -- leading zeros from ALL of file 1. Verified retained: 08759, 02166, 00158,
  -- 03988, 06055.
  postal_code              VARCHAR(30)     COMMENT 'Postal code as text; VARCHAR deliberately, file 2 lost leading zeros by typing it numeric.',
  address_line1            VARCHAR(255)    COMMENT 'Street address line of the store.',
  -- Inferred precision had no headroom: NUMBER(9,6) cannot hold -180.000000.
  latitude                 NUMBER(9,6)     COMMENT 'Store latitude in decimal degrees.',
  longitude                NUMBER(10,6)    COMMENT 'Store longitude in decimal degrees.',
  -- Kept as real DATEs by giving each file its own DATE_FORMAT, rather than
  -- degrading the column to text to accommodate two conventions.
  store_open_date          DATE            COMMENT 'Date the store opened; normalised from per-file date formats.',
  -- Inferred TEXT only because 100% empty - no values to type.
  store_close_date         DATE            COMMENT 'Date the store closed; NULL while trading.',
  lifecycle_status         VARCHAR(30)     COMMENT 'Lifecycle state, e.g. ACTIVE/CLOSED.',
  -- Inferred NUMBER(5,0) caps floor area at 99,999 sqft; NUMBER(8,0) caps rent
  -- at ~100M and scale 0 would round cents.
  floor_area_sqft          NUMBER(10,0)    COMMENT 'Retail floor area in square feet.',
  annual_rent_usd          NUMBER(14,2)    COMMENT 'Annual rent in USD.',
  is_active                BOOLEAN         COMMENT 'Active flag; source ships Y/N.',
  effective_start_date     DATE            COMMENT 'Date the record became effective.',
  effective_end_date       DATE            COMMENT 'Date the record stopped being effective.',
  -- DELIBERATE (PART 0.5c). File 1 ships a full timestamp, files 2/3/4 ship the
  -- fragment '21:50.4' which no format string can rescue. VARCHAR lands both
  -- losslessly AND PRESERVES THE CORRUPTION AS EVIDENCE. Typing it TIMESTAMP
  -- would either fail the load or quietly null the bad values, destroying proof
  -- that the upstream export is broken.
  created_at               VARCHAR(50)     COMMENT 'Source creation timestamp kept as raw text: file 1 ships a full timestamp, file 2 ships a corrupted time-only value that cannot be cast.',
  source_system            VARCHAR(50)     COMMENT 'Originating source system.',
  -- Audit columns make drift forensics possible. Without __file_name a NULL from
  -- "column absent in this file" is INDISTINGUISHABLE from a NULL meaning "value
  -- genuinely unknown" - see step 12, which proves state_code holds 44 NULLs of
  -- BOTH kinds.
  -- NO DEFAULT on __loaded_at: COPY silently IGNORES column defaults under
  -- MATCH_BY_COLUMN_NAME. Proven here - see step 12.
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row came from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: staged file last modified time (METADATA$FILE_LAST_MODIFIED).',
  __loaded_at              TIMESTAMP_NTZ   COMMENT 'Audit: when the row was loaded (METADATA$START_SCAN_TIME).'
)
ENABLE_SCHEMA_EVOLUTION = TRUE          -- <<< the evolution switch
COMMENT = 'Unified store master target. Created from file 1 schema only; ENABLE_SCHEMA_EVOLUTION lets COPY add later columns such as Status automatically.';
-- -> 26 columns, 0 rows.

SHOW TABLES LIKE 'STORE_MASTER' IN SCHEMA ANALYSIS_DB.DATA_MIGRATION;
-- verify ENABLE_SCHEMA_EVOLUTION = Y


/* ===========================================================================
   STEP 8 - LOAD 1 of 4: baseline, no drift

   *** THIS IS WHERE THE FIRST FAILURE HAPPENED ***
   With ERROR_ON_COLUMN_COUNT_MISMATCH at its TRUE default:
       Number of columns in file (22) does not match that of the corresponding
       table (26)
   The load died BEFORE name-matching was even attempted. Fixed by setting it
   FALSE on both loader formats (now folded into step 2). PART 0.4.

   Mapping performed (PART 0.2 -> 0.3 -> 0.4):
     bytes  -> 121 records (5 quoted newlines absorbed)
     fields -> $1..$22, named from the header line
     names  -> 22 target columns by uppercased name
     4 audit columns from METADATA$
     nothing unmatched either way -> NO evolution event
   =========================================================================== */
COPY INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master.csv
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_iso')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;
-- -> LOADED, rows_parsed 121, rows_loaded 121, errors_seen 0
-- 121, NOT 126 - the quoted-newline reconciliation from step 6.

SELECT store_code, postal_code, store_open_date, created_at, is_active
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
WHERE postal_code LIKE '0%' ORDER BY store_code LIMIT 5;
-- -> 08759, 02166, 03988, 00158, 06055   proves the VARCHAR decision in step 7


/* ===========================================================================
   STEP 9 - LOAD 2 of 4: ADDITIVE DRIFT -> SCHEMA EVOLUTION FIRES

   Mapping performed:
     22 names matched existing target columns
     Status  NO match -> evolution ALTERs the table, appends STATUS BOOLEAN at
             position 27, loads 'y' -> TRUE.
             BOOLEAN here, not TEXT, because CSV has no types so INFER_SCHEMA
             judged the VALUE - contrast the JSON run, where the producer QUOTED
             "True" and evolution added TEXT.
     121 existing rows -> STATUS = NULL automatically.

   *** NOTE THE FILE FORMAT CHANGE: ff_store_master_eu, not _iso. ***
   This file ships day-first dates. Loading it with the ISO format would NOT
   raise an error - AUTO parsing returns NULL - so the dates would land EMPTY and
   nobody would be alerted. The per-file format choice is the load's correctness
   hinge, not a cosmetic detail.
   =========================================================================== */
COPY INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_1.csv
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')
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

-- Day-first parsing verified CORRECT, not transposed:
SELECT store_code, store_open_date, effective_end_date, created_at, is_active, STATUS
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
WHERE __file_name LIKE '%store_master_1.csv' ORDER BY __row_number;
/* 01-09-2017 -> 2017-09-01  (NOT 2017-01-09)
   22-06-2016 -> 2016-06-22  (22 cannot be a month, so this PROVES day-first)
   31-12-9999 -> 9999-12-31
   created_at stays raw as '21:50.4' - corruption preserved as evidence.       */


/* ===========================================================================
   STEP 10 - LOAD 3 of 4: SUBTRACTIVE DRIFT -> NO EVOLUTION, SILENT DEGRADATION

   *** THE IMPORTANT NEGATIVE RESULT ***

   SCHEMA EVOLUTION IS ADDITIVE-ONLY. It never drops or deprecates a column. Six
   columns vanished from the source and Snowflake did not care:

     Absent:            format_code, city, state_code, postal_code,
                        address_line1, latitude
     Table structure:   UNCHANGED at 29 columns
     Those 6 columns:   silently filled with NULL for these 5 rows
     Load status:       SUCCESS, zero errors, zero warnings

   This is the DANGEROUS direction precisely BECAUSE it succeeds. An upstream
   export that loses a quarter of its columns is indistinguishable, in the load
   logs, from a perfectly healthy run. Additive drift announces itself by
   changing the table; subtractive drift announces NOTHING.
   =========================================================================== */

-- Capture pre-load state so the effect is measurable, not assumed.
SELECT (SELECT COUNT(*) FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER) AS rows_before,
       (SELECT COUNT(*) FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
          WHERE TABLE_SCHEMA='DATA_MIGRATION' AND TABLE_NAME='STORE_MASTER') AS cols_before,
       (SELECT COUNT(*) FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
          WHERE store_code IN ('US_0101','US_0102','US_0103','US_0104','US_0105')) AS existing_same_keys;
-- -> 126, 29, 5   <-- the 5 WARNS this load will duplicate, before it runs

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
-- -> LOADED, rows_parsed 5, rows_loaded 5, errors_seen 0
-- 131 rows, STILL 29 columns. NO evolution. 5 duplicate store_codes created.

-- The degraded twin beside the complete row.
SELECT store_code, REGEXP_SUBSTR(__file_name,'[^/]+$') AS src,
       city, postal_code, latitude, longitude, store_open_date, STATUS
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
WHERE store_code IN ('US_0101','US_0104') ORDER BY store_code, src;
/* US_0101 store_master_1.csv             Bradleyton 77677 42.839799 -84.299787
   US_0101 store_master_2_deleted_columns NULL       NULL  NULL      -84.299787
   longitude survived, latitude did not - half-broken geo. */


/* ===========================================================================
   STEP 11 - Pre-load drift guard  (run BEFORE every COPY)

   Snowflake raises NOTHING for subtractive drift. This supplies the missing
   alert. Detection must happen BEFORE the load, because afterwards the only
   trace is NULLs that look exactly like legitimately missing values.
   =========================================================================== */
SELECT c.COLUMN_NAME AS missing_from_incoming_file
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_SCHEMA = 'DATA_MIGRATION'
  AND c.TABLE_NAME   = 'STORE_MASTER'
  AND c.COLUMN_NAME NOT LIKE '\_\_%'                -- audit cols never come from file
  AND c.COLUMN_NAME NOT IN (
        SELECT UPPER(COLUMN_NAME) FROM TABLE(INFER_SCHEMA(
          LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_2_deleted_columns.csv',
          FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')))
ORDER BY 1;
-- -> the 6 dropped columns. Treat a non-empty result as a pipeline FAILURE.

/* A castability probe is the ACCURATE type-drift guard. Comparing INFER_SCHEMA's
   guess to the declared type OVER-REPORTS: on file 4 it flagged FIVE "blocking"
   columns when only ONE was real, because it ignores the file format's
   DATE_FORMAT. A guard that cries wolf four times in five gets muted.
   Test the VALUES instead - full version in 09_drift_detection_guard.sql 9.5: */
WITH raw AS (
  SELECT $16 AS floor_area_sqft, $13 AS store_open_date, $17 AS annual_rent_usd
  FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_3_datatypechange_numberdatasendingtextinafile.csv
       (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_inspect')
)
SELECT 'FLOOR_AREA_SQFT' AS col, 'NUMBER' AS target_type, COUNT(*) AS rows_present,
       SUM(IFF(floor_area_sqft IS NOT NULL
               AND TRY_TO_NUMBER(floor_area_sqft) IS NULL,1,0)) AS uncastable FROM raw
UNION ALL SELECT 'STORE_OPEN_DATE','DATE',COUNT(*),
       SUM(IFF(store_open_date IS NOT NULL
               AND TRY_TO_DATE(store_open_date,'DD-MM-YYYY') IS NULL,1,0)) FROM raw
UNION ALL SELECT 'ANNUAL_RENT_USD','NUMBER',COUNT(*),
       SUM(IFF(annual_rent_usd IS NOT NULL
               AND TRY_TO_NUMBER(annual_rent_usd,14,2) IS NULL,1,0)) FROM raw
ORDER BY uncastable DESC;
-- -> FLOOR_AREA_SQFT 5 2  |  others 5 0.  Exactly ONE real failure.


/* ===========================================================================
   STEP 12 - Validate
   =========================================================================== */
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$')      AS source_file,
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

   STATUS nulls collapse 121 -> 0 (additive drift); the six dropped columns spike
   0 -> 5 (subtractive drift). state_code's 39 is NOT drift - see next query.  */

/* *** NULL PROVENANCE AMBIGUITY - the subtlest finding in the CSV exercise ***
   state_code ends up with 44 NULLs meaning TWO DIFFERENT THINGS.              */
SELECT COUNT(*)                                                  AS total_state_code_nulls,
       SUM(IFF(__file_name LIKE '%deleted_columns.csv',1,0))     AS structural_column_absent,
       SUM(IFF(__file_name NOT LIKE '%deleted_columns.csv',1,0)) AS genuine_value_absent
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER WHERE state_code IS NULL;
-- -> 44, 5, 39
/* 39 = the store genuinely has no state (non-US locations)
    5 = the column was not present in the source file at all
   INDISTINGUISHABLE in the data. Only __file_name separates them - which is the
   entire justification for carrying audit columns into a landing table. A
   consumer writing WHERE state_code IS NULL cannot tell these apart. */

-- __loaded_at is NULL for the first 126 rows: a column DEFAULT is NOT applied by
-- COPY under MATCH_BY_COLUMN_NAME, despite appearing in COLUMN_DEFAULT. Fixed
-- from load 3 onward via INCLUDE_METADATA = (__loaded_at = METADATA$START_SCAN_TIME).
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS source_file, COUNT(*) AS row_cnt,
       SUM(IFF(__loaded_at IS NULL,1,0))   AS loaded_at_nulls
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER GROUP BY 1 ORDER BY 1;

-- Duplicate business keys from load 3
SELECT store_code, COUNT(*) AS row_cnt,
       LISTAGG(REGEXP_SUBSTR(__file_name,'[^/]+$'), ' | ') AS from_files
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
GROUP BY store_code HAVING COUNT(*) > 1 ORDER BY store_code;
-- -> US_0101..US_0105, 2 rows each. COPY load history is keyed on FILE NAME,
--    not business key, so a renamed re-export loads again.


/* ===========================================================================
   STEP 13 - Future-columns test  (EXECUTED, THEN ROLLED BACK)

   A 25-column CSV adding manager_name and employee_count, written to a TEMP
   directory - never the source folder - and staged under a separate prefix.
   Loaded with the IDENTICAL COPY: no ALTER TABLE, no recreate.

     Before: 27 columns, 126 rows    After: 29 columns, 128 rows
     Added:  MANAGER_NAME TEXT(16777216), EMPLOYEE_COUNT NUMBER(2,0)
     All 126 existing rows -> NULL for both.

   *** EMPLOYEE_COUNT NUMBER(2,0) IS THE WARNING ***
   Sized to a 2-row sample (87, 34) -> a CEILING OF 99. Evolution chose the
   smallest type that fit the sample, not a sensible one. A store with 100 staff
   fails the next load. The same trap recurred in the JSON and Parquet exercises:
   it is inherent to automatic evolution, not format-specific.

   Rollback deleted the 2 rows; THE COLUMNS PERSIST. Evolution is not reversible
   by DELETE.
   =========================================================================== */


/* ===========================================================================
   STEP 14 - LOAD 4 of 4: TYPE DRIFT -> COPY REJECTED

   File: store_master_3_datatypechange_numberdatasendingtextinafile.csv
   NO structural drift. The damage is INSIDE floor_area_sqft:
       US_0101 'testing'   US_0102 'testing'   US_0103..05 valid numbers

   *** THE THIRD DRIFT CATEGORY, AND THE ONE EVOLUTION CANNOT TOUCH ***

   Evolution ADDS columns. It does not widen, retype or relax an existing one.
   Snowflake did NOT convert floor_area_sqft to VARCHAR - it refused the load:

       Numeric value 'testing' is not recognized
       Row 1, column "STORE_MASTER"["FLOOR_AREA_SQFT":16]

   Verified after the failure: 131 rows, 29 columns, FLOOR_AREA_SQFT still
   NUMBER, 0 rows from this file. COPY IS ATOMIC PER FILE - the 3 good rows did
   not sneak in alongside the 2 bad ones.

   Type drift is the LEAST insidious of the three categories precisely because it
   fails. The wrong fix is to make it quiet:

     ON_ERROR = CONTINUE    loads 3 rows, silently discards 2. Converts a visible
                            failure into invisible data loss - strictly worse.
     ALTER TO VARCHAR       surrenders numeric typing on 121 correctly-typed rows
                            to accommodate 2 bad values. Lets corruption set the
                            schema.

   The pattern below keeps the target strongly typed AND loses nothing.
   =========================================================================== */

-- 14.1 The diagnostic. Left commented: it MUST keep failing. Do not "fix" it.
/*
COPY INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_3_datatypechange_numberdatasendingtextinafile.csv
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = ( ...same four... )
ON_ERROR = ABORT_STATEMENT;
-- -> Numeric value 'testing' is not recognized      EXPECTED FAILURE
*/

-- 14.2 All-text landing table: every volatile column VARCHAR, so the file always
-- lands and VALIDATION - not parsing - decides what is acceptable.
CREATE TABLE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD_RAW (
  store_code VARCHAR(30), store_name VARCHAR(150), country_code VARCHAR(10),
  region_code VARCHAR(20), tax_jurisdiction_code VARCHAR(30), format_code VARCHAR(20),
  city VARCHAR(100), state_code VARCHAR(20), postal_code VARCHAR(30),
  address_line1 VARCHAR(255), latitude VARCHAR(50), longitude VARCHAR(50),
  store_open_date VARCHAR(50), store_close_date VARCHAR(50), lifecycle_status VARCHAR(30),
  floor_area_sqft VARCHAR(50)  COMMENT 'Floor area as raw text: source has shipped non-numeric values such as the literal testing.',
  annual_rent_usd VARCHAR(50), is_active VARCHAR(10),
  effective_start_date VARCHAR(50), effective_end_date VARCHAR(50),
  created_at VARCHAR(50), source_system VARCHAR(50), Status VARCHAR(10),
  __file_name VARCHAR(500), __row_number NUMBER(18,0),
  __file_last_modified_ntz TIMESTAMP_NTZ, __loaded_at TIMESTAMP_NTZ
)
ENABLE_SCHEMA_EVOLUTION = TRUE
COMMENT = 'All-text landing table for store master files. Absorbs type drift so a bad value fails validation instead of failing the load.';

-- 14.3 Quarantine table. Rejected rows stay VISIBLE and ACTIONABLE - not dropped
-- by ON_ERROR, not silently coerced to NULL.
CREATE TABLE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_REJECTS (
  store_code VARCHAR(30), reject_column VARCHAR(100), reject_raw_value VARCHAR(500),
  reject_expected_type VARCHAR(50), reject_reason VARCHAR(200),
  __file_name VARCHAR(500), __row_number NUMBER(18,0), __rejected_at TIMESTAMP_NTZ
)
COMMENT = 'Quarantine for store master rows failing type validation. Keeps bad data visible and actionable instead of dropped or silently nulled.';

-- 14.4 Land the file. SUCCEEDS where 14.1 failed - same file, same format, same
-- COPY options. Only the DESTINATION TYPING differs.
COPY INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD_RAW
FROM @ANALYSIS_DB.DATA_MIGRATION.store_master_stg/store-master/store_master_3_datatypechange_numberdatasendingtextinafile.csv
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION.ff_store_master_eu')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;
-- -> LOADED, rows_parsed 5, rows_loaded 5, errors_seen 0

-- 14.5 Classify before moving anything. Note the IS NOT NULL guard: a NULL is
-- legitimately absent data, NOT a cast failure, and must not be quarantined.
SELECT store_code, floor_area_sqft AS raw_value,
       TRY_TO_NUMBER(floor_area_sqft) AS cast_value,
       CASE WHEN floor_area_sqft IS NULL                THEN 'VALID - null allowed'
            WHEN TRY_TO_NUMBER(floor_area_sqft) IS NULL THEN 'REJECT - not numeric'
            ELSE 'VALID' END AS verdict
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD_RAW
WHERE __file_name LIKE '%datatypechange%' ORDER BY __row_number;
/* US_0101 testing NULL REJECT | US_0103 18363 18363 VALID
   US_0102 testing NULL REJECT | US_0104 13483 13483 VALID
                               | US_0105  9157  9157 VALID                     */

-- 14.6 Quarantine the 2 uncastable rows, keeping the RAW value for the producer.
INSERT INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_REJECTS
  (store_code, reject_column, reject_raw_value, reject_expected_type, reject_reason,
   __file_name, __row_number, __rejected_at)
SELECT store_code, 'FLOOR_AREA_SQFT', floor_area_sqft, 'NUMBER(10,0)',
       'Non-numeric text in a numeric column; row withheld from STORE_MASTER pending source correction.',
       __file_name, __row_number, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD_RAW
WHERE __file_name LIKE '%datatypechange%'
  AND floor_area_sqft IS NOT NULL
  AND TRY_TO_NUMBER(floor_area_sqft) IS NULL;
-- -> 2 rows inserted

-- 14.7 MERGE the valid rows, casting explicitly. MERGE not INSERT: these keys
-- already exist, so an INSERT would create a THIRD copy.
-- COALESCE keeps an absent source value from ERASING data we already hold.
MERGE INTO ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER t
USING (
  SELECT store_code, format_code, city, state_code, postal_code, address_line1,
         TRY_TO_NUMBER(latitude, 12, 6)        AS latitude,
         TRY_TO_NUMBER(longitude, 12, 6)       AS longitude,
         TRY_TO_NUMBER(floor_area_sqft)        AS floor_area_sqft,
         TRY_TO_NUMBER(annual_rent_usd, 14, 2) AS annual_rent_usd,
         TRY_TO_BOOLEAN(Status)                AS Status,
         __file_name, __row_number, __loaded_at
  FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_LOAD_RAW
  WHERE __file_name LIKE '%datatypechange%'
    AND (floor_area_sqft IS NULL OR TRY_TO_NUMBER(floor_area_sqft) IS NOT NULL)
) s
ON t.store_code = s.store_code
WHEN MATCHED THEN UPDATE SET
  t.format_code     = COALESCE(s.format_code,     t.format_code),
  t.city            = COALESCE(s.city,            t.city),
  t.state_code      = COALESCE(s.state_code,      t.state_code),
  t.postal_code     = COALESCE(s.postal_code,     t.postal_code),
  t.address_line1   = COALESCE(s.address_line1,   t.address_line1),
  t.latitude        = COALESCE(s.latitude,        t.latitude),
  t.longitude       = COALESCE(s.longitude,       t.longitude),
  t.floor_area_sqft = COALESCE(s.floor_area_sqft, t.floor_area_sqft),
  t.annual_rent_usd = COALESCE(s.annual_rent_usd, t.annual_rent_usd),
  t.STATUS          = COALESCE(s.STATUS,          t.STATUS),
  t.__file_name     = s.__file_name,
  t.__row_number    = s.__row_number,
  t.__loaded_at     = s.__loaded_at;
/* -> 0 inserted, 6 updated.

   SIX, not three, and the number is DIAGNOSTIC. Three source rows matched SIX
   target rows because US_0103..US_0105 each still have TWO rows - the duplicates
   created by load 3 and not yet resolved. MERGE updated both twins of each key.

   Side effect: it REPAIRED the degraded twins, back-filling city, postal_code,
   address_line1, format_code, state_code and latitude that file 3 had dropped.
   Better data, but the duplicate keys remain. "6 updated" should read "3 updated"
   once the table holds one row per key. De-duplication is in
   10_idempotent_merge_fix.sql section 10.3 - NOT executed. */

-- 14.8 Validate the quarantine outcome
SELECT (SELECT COUNT(*) FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER)          AS total_rows,
       (SELECT COUNT(DISTINCT store_code) FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER) AS distinct_keys,
       (SELECT DATA_TYPE FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
          WHERE TABLE_SCHEMA='DATA_MIGRATION' AND TABLE_NAME='STORE_MASTER'
            AND COLUMN_NAME='FLOOR_AREA_SQFT')                                 AS floor_area_type,
       (SELECT COUNT(*) FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_REJECTS)   AS quarantined;
-- -> 131, 126, NUMBER, 2
-- Target stayed STRONGLY TYPED and no row count was inflated.

SELECT store_code, reject_column, reject_raw_value, reject_expected_type, reject_reason
FROM ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER_REJECTS ORDER BY store_code;
-- -> US_0101 / US_0102, FLOOR_AREA_SQFT, 'testing', NUMBER(10,0)


/* ###########################################################################
   FINAL STATE

     131 rows, 126 distinct store_code, 29 columns, 3 loaded source files
     2 rows quarantined from file 4
     5 duplicate business keys outstanding
     __loaded_at NULL on the first 126 rows
     All four source files byte-identical and untouched

   STATE TRANSITIONS
     step  7  create target (file 1 schema)   26 cols     0 rows   -
     step  8  COPY file 1                     26 cols   121 rows   no evolution
     step  9  COPY file 2                     26 -> 27  126 rows   EVOLUTION
     step 10  COPY file 3                     29 cols   131 rows   NO evolution,
                                                                   6 cols NULLed
     step 13  COPY future-columns fixture     27 -> 29  128 rows   EVOLUTION
     step 14  COPY file 4 direct              29 cols   131 rows   REJECTED
     step 14  quarantine + MERGE              29 cols   131 rows   2 quarantined,
                                                                   6 updated

   THE THREE DRIFT CATEGORIES, RANKED BY DANGER - QUIETEST IS WORST

     1. SUBTRACTIVE  load SUCCEEDS, 6 columns silently NULLed, no alert.
                     Worse still, it makes NULL provenance ambiguous: state_code
                     ends with 44 NULLs, 39 genuine and 5 structural, and only
                     __file_name can tell them apart.
     2. ADDITIVE     load succeeds and the TABLE CHANGES - self-announcing.
     3. TYPE         load FAILS immediately. Loudest, therefore safest.

   WHY CSV IS THE HARDEST OF THE THREE FORMATS
     It is the only one that must MANUFACTURE columns from a byte stream, so it
     is the only one where a quoted comma or newline can shift every field in a
     record. It carries NO type information, so leading zeros, date order and
     corrupted timestamps are all unrecoverable or ambiguous at the file level.
     And it needed the most configuration: 3 file formats, 2 date conventions,
     and ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE without which evolution is
     impossible.

   Evolution buys STRUCTURAL tolerance for ADDED columns. Semantic drift still
   needs an engineer - plus a drift ALERT, because a schema change that succeeds
   silently is a change nobody reviewed.
   ########################################################################### */
