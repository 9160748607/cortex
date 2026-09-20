/* ###########################################################################
   COMPLETE FLOW - PARQUET
   Store Master schema drift & schema evolution, end to end.

   Target: ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
   Source: C:\Users\X1Carbon\Music\store-master-testing\parquet
             store_master.parquet     22 columns, 121 rows
             store_master_1.parquet   23 columns,   5 rows

   This is the whole sequence in one runnable file, with every recorded result
   inline. The individual 01-10 scripts are the same statements split by concern.

   Run order is strict. Steps 5-6 must precede step 8, because the target design
   depends on what they reveal.
   ###########################################################################

   ===========================================================================
   PART 0 - HOW PARQUET DATA IS SPLIT INTO COLUMNS AND LOCATED IN THE TARGET
   ===========================================================================

   Parquet is fundamentally different from CSV and JSON: it is ALREADY columns.
   There is no splitting step at all. Understanding that is the key to
   understanding why the load behaves the way it does.

   ---------------------------------------------------------------------------
   0.1  WHAT IS PHYSICALLY IN THE FILE
   ---------------------------------------------------------------------------
   A Parquet file is a binary container laid out roughly like this:

       [magic "PAR1"]
       [Row Group 0]
           [Column Chunk: store_code ]  -> pages of encoded values
           [Column Chunk: store_name ]  -> pages
           [Column Chunk: postal_code]  -> pages
           ...one contiguous chunk PER COLUMN...
       [Row Group 1]
           ...same column chunks again...
       [FOOTER: FileMetaData]
           schema      : ordered list of (name, physical type, logical type,
                         repetition - required/optional/repeated)
           row groups  : for each, per-column chunk offset, length, encoding,
                         compression, value count, null count, min/max stats
       [footer length][magic "PAR1"]

   Two consequences that matter for loading:

     a) VALUES FOR ONE COLUMN ARE STORED TOGETHER, not interleaved per row.
        A row is not a contiguous thing in the file - it is assembled by taking
        the Nth value from each column chunk. So "splitting a row into columns"
        never happens. The columns were never joined in the first place.

     b) THE SCHEMA IS IN THE FILE. Column names, types and nullability are read
        from the footer. Nothing is guessed from the data, and no file-format
        option is needed to describe the layout - which is why
        ff_store_master_parquet has no delimiter, no header, no quote character
        and no array handling. Compare CSV, which needs all four.

   ---------------------------------------------------------------------------
   0.2  PHYSICAL TYPE vs LOGICAL TYPE - the trap in this dataset
   ---------------------------------------------------------------------------
   Parquet stores each column with a PHYSICAL type from a small fixed set:
       BOOLEAN, INT32, INT64, INT96, FLOAT, DOUBLE, BYTE_ARRAY,
       FIXED_LEN_BYTE_ARRAY
   and optionally annotates it with a LOGICAL type that says what those bytes
   MEAN:
       BYTE_ARRAY + STRING            -> text
       INT32      + DATE              -> days since epoch
       INT64      + TIMESTAMP(MICROS) -> microseconds since epoch
       INT32/64   + DECIMAL(p,s)      -> scaled integer

   created_at in store_master.parquet is stored as INT64 annotated
   TIMESTAMP(MICROS). Two readers can legitimately report two different things:

       INFER_SCHEMA  -> NUMBER(38,0)     it surfaced the PHYSICAL INT64
       TYPEOF(...)   -> TIMESTAMP_NTZ    the read path applied the ANNOTATION

   Both are "correct" about different layers. The COPY read path uses the
   logical type, so TYPEOF is what predicts load behaviour. See step 6.

   This is why USE_VECTORIZED_SCANNER = TRUE is not just a performance flag: it
   governs how logical annotations are materialised on read.

   ---------------------------------------------------------------------------
   0.3  HOW A COLUMN CHUNK BECOMES A TARGET COLUMN
   ---------------------------------------------------------------------------
   With MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE the mapping is ONE step, by
   name, using the footer schema:

     1. Read the footer. Obtain the list of column names.
     2. UPPER() each Parquet column name and each target column name.
     3. Join the two lists on that uppercased name. For every match, the
        column chunk is decoded and written to that target column, coercing the
        Parquet logical type to the declared Snowflake type.
     4. Target column with NO matching Parquet column  -> NULL for these rows.
     5. Parquet column with NO matching target column  -> ENABLE_SCHEMA_EVOLUTION
        adds the column (name from footer, type from footer), then loads it.
        Existing rows get NULL.
     6. Columns listed in INCLUDE_METADATA are filled from METADATA$ pseudo-
        columns, not from the file.

   Worked example for store_master_1.parquet (23 columns) into the 26-column
   target (22 data + 4 audit):

       Parquet footer column     Target column           Outcome
       ---------------------------------------------------------------------
       store_code           ->   STORE_CODE              matched, loaded
       postal_code          ->   POSTAL_CODE             matched; INT64 value
                                                         8759 coerced to
                                                         VARCHAR '8759'
       created_at           ->   CREATED_AT              matched; BYTE_ARRAY
                                                         '21:50.4' into VARCHAR
       Status               ->   (none)                  EVOLUTION: adds
                                                         STATUS TEXT, loads 'y'
       (none)               <-   __FILE_NAME             from INCLUDE_METADATA
       (none)               <-   (any absent column)     NULL

   NOTE ON ORDER: Parquet preserves column order in the footer, so positional
   binding would technically work here. It is still the wrong choice. Reordering
   columns is a legal, invisible change for a Parquet producer - it does not
   change the data, only the footer - and positional binding would silently
   shift every value one column left or right. Name binding is immune.

   ---------------------------------------------------------------------------
   0.4  PROJECTION PUSHDOWN - only Parquet gets this
   ---------------------------------------------------------------------------
   Because each column lives in its own chunk with a recorded byte offset, the
   reader can SKIP a column entirely: it never reads those bytes off storage.

     CSV     must scan every byte of every line to find the delimiters, even to
             read one field.
     JSON    must parse the whole object to reach one key.
     PARQUET seeks directly to the needed column chunks.

   For a load this matters when the file is wider than the target. Columns the
   target does not have and that evolution is not adding are simply not read.

   ---------------------------------------------------------------------------
   0.5  WHY A TRANSFORMATION IS NOT AVAILABLE
   ---------------------------------------------------------------------------
   The transformation form
       COPY INTO t FROM (SELECT $1:col::TYPE, ... FROM @stage)
   CANNOT be combined with MATCH_BY_COLUMN_NAME. You pick one:

       MATCH_BY_COLUMN_NAME  -> automatic name mapping + schema evolution,
                                but NO per-column casting or repair
       transformation SELECT -> full control, casts and CASE expressions,
                                but positional $1:key access and NO evolution

   This exercise needs evolution, so no mid-load repair is possible. That single
   constraint drove the whole created_at design: it had to be solved by
   DECLARATION (step 8) plus a DERIVED COLUMN (step 12), because there was
   nowhere to put a TRY_TO_TIMESTAMP_NTZ inside the COPY.
   ########################################################################### */


/* ===========================================================================
   STEP 1 - Create the schema
   =========================================================================== */
CREATE SCHEMA IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_PARQUET
  COMMENT = 'Store master Parquet schema-drift and schema-evolution demonstration.';
-- -> Schema DATA_MIGRATION_PARQUET successfully created.


/* ===========================================================================
   STEP 2 - Create the Parquet file format

   Almost empty by necessity, not by laziness. Everything CSV needs a format
   option for, Parquet carries in its footer:
       no FIELD_DELIMITER            columns are separate chunks
       no FIELD_OPTIONALLY_ENCLOSED_BY  no text quoting exists
       no PARSE_HEADER / SKIP_HEADER    names are in the footer
       no STRIP_OUTER_ARRAY             not a document format
       no DATE_FORMAT                   dates are typed, not parsed from text
   =========================================================================== */
CREATE FILE FORMAT IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet
  TYPE = PARQUET
  COMPRESSION = AUTO                 -- reads the codec from the footer per chunk
  USE_VECTORIZED_SCANNER = TRUE      -- see PART 0.2: governs logical-type surfacing
  COMMENT = 'Parquet format for store master files. Parquet embeds its own typed schema, so no header, delimiter or array-stripping options are needed.';
-- -> File format FF_STORE_MASTER_PARQUET successfully created.


/* ===========================================================================
   STEP 3 - Create the stage
   IF NOT EXISTS, never CREATE OR REPLACE - that silently discards staged files.
   =========================================================================== */
CREATE STAGE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Internal stage holding store master Parquet source files for the schema-drift demonstration.';
-- -> Stage area STORE_MASTER_PARQUET_STG successfully created.


/* ===========================================================================
   STEP 4 - Upload both files (CoCo / snow CLI, run in PowerShell)

     $ErrorActionPreference='Continue'
     cd "C:\Users\X1Carbon\Music\store-master-testing\parquet"

     snow stage copy "store_master.parquet" `
       '@ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/' `
       --connection ysirciu-vg28332 --overwrite

     snow stage copy "store_master_1.parquet" `
       '@ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/' `
       --connection ysirciu-vg28332 --overwrite

   Recorded:
     | store_master.parquet   | 20940 | PARQUET | PARQUET | UPLOADED |
     | store_master_1.parquet |  5434 | PARQUET | PARQUET | UPLOADED |

   source_compression = PARQUET: the CLI recognises the container and passes it
   through. Do NOT add --auto-compress - gzipping an already-compressed columnar
   file wastes cycles and destroys the per-chunk seekability that PART 0.4
   depends on.

   The snow CLI emits a benign "Encoding mismatch" UserWarning on stderr, which
   PowerShell escalates to NativeCommandError. Judge success by UPLOADED.
   =========================================================================== */
LIST @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/;


/* ===========================================================================
   STEP 5 - Schema detection, PER FILE

   INFER_SCHEMA on Parquet reads the FOOTER ONLY - it does not scan data. That
   makes it exact and cheap, and it is why ORDER_ID here is true document order
   (contrast JSON, where INFER_SCHEMA returns keys alphabetically).

   Run per file. A folder-prefix call would return a merged union and hide the
   drift we are looking for.
   =========================================================================== */

-- FILE 1
SELECT ORDER_ID, COLUMN_NAME, TYPE, NULLABLE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master.parquet',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet'
)) ORDER BY ORDER_ID;
/* 22 columns, document order:
    0 store_code TEXT           11 longitude REAL
    1 store_name TEXT           12 store_open_date DATE
    2 country_code TEXT         13 store_close_date TEXT   (100% NULL)
    3 region_code TEXT          14 lifecycle_status TEXT
    4 tax_jurisdiction_code TEXT 15 floor_area_sqft NUMBER(38,0)
    5 format_code TEXT          16 annual_rent_usd NUMBER(38,0)
    6 city TEXT                 17 is_active TEXT      (values 'Y')
    7 state_code TEXT           18 effective_start_date DATE
    8 postal_code TEXT  <--     19 effective_end_date DATE
    9 address_line1 TEXT        20 created_at NUMBER(38,0) <-- WRONG, see step 6
   10 latitude REAL             21 source_system TEXT

   NUMBER(38,0) for the int64 columns is Snowflake mapping Parquet integer WIDTH
   to MAXIMUM precision. 38 digits for a floor area in square feet is not a
   declaration, it is the absence of one. Step 8 narrows these deliberately. */

-- FILE 2
SELECT ORDER_ID, COLUMN_NAME, TYPE, NULLABLE
FROM TABLE(INFER_SCHEMA(
  LOCATION    => '@ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master_1.parquet',
  FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet'
)) ORDER BY ORDER_ID;
/* 23 columns. THREE differences vs FILE 1:
     8  postal_code  NUMBER(38,0)  <-- was TEXT    : leading zeros DESTROYED
    20  created_at   TEXT          <-- was NUMBER  : OPPOSITE direction
    22  Status       TEXT          <-- NEW COLUMN                              */


/* ===========================================================================
   STEP 6 - TYPEOF CROSS-CHECK  *** the critical step for Parquet ***

   PART 0.2 explains why this is necessary. Never design a Parquet target column
   type from INFER_SCHEMA alone.
   =========================================================================== */
SELECT $1:store_code::VARCHAR       AS store_code,
       $1:postal_code              AS postal_raw,
       TYPEOF($1:postal_code)      AS postal_type,
       $1:created_at               AS created_raw,
       TYPEOF($1:created_at)       AS created_type,
       TYPEOF($1:store_close_date) AS close_type,
       $1:latitude                 AS lat_raw
FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master.parquet
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
LIMIT 3;
/* FILE 1 recorded:
     US_0001  77677  VARCHAR  2026-04-17 15:21:50.368  TIMESTAMP_NTZ  42.839799
     US_0002  08759  VARCHAR  2026-04-17 15:21:50.369  TIMESTAMP_NTZ  28.454519

   INFER_SCHEMA said created_at = NUMBER(38,0). TYPEOF says TIMESTAMP_NTZ.
   THE READER IS RIGHT - it applied the INT64 + TIMESTAMP(MICROS) annotation.

   Declaring created_at NUMBER per INFER_SCHEMA would have stored raw epoch
   microseconds in a load that SUCCEEDS, silently discarding the timestamp and
   leaving every consumer to reverse-engineer the epoch unit. Nothing fails.

   Also note postal_code = '08759' as VARCHAR: file 1 stores it as
   BYTE_ARRAY/STRING, so the leading zero is real data, not formatting. */

-- Same probe, FILE 2
SELECT $1:store_code::VARCHAR   AS store_code,
       $1:postal_code           AS postal_raw,
       TYPEOF($1:postal_code)   AS postal_type,
       $1:created_at            AS created_raw,
       TYPEOF($1:created_at)    AS created_type,
       $1:Status                AS status_raw,
       TYPEOF($1:Status)        AS status_type
FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master_1.parquet
     (FILE_FORMAT => 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
LIMIT 5;
/* FILE 2 recorded:
     US_0101  77677  INTEGER  21:50.4  VARCHAR  y  VARCHAR
     US_0102   8759  INTEGER  21:50.4  VARCHAR  y  VARCHAR
     US_0104   2166  INTEGER  21:50.4  VARCHAR  y  VARCHAR

   postal_code is INT64 here, so 08759 -> 8759 and 02166 -> 2166. The zeros were
   destroyed BY THE PRODUCER before Snowflake ever saw the file. No load option
   can recover them.
   created_at is BYTE_ARRAY holding '21:50.4' - a time fragment with no date,
   unrecoverable. Same Excel damage as the CSV exercise, re-serialised.
   INFER_SCHEMA and TYPEOF AGREE here; the disagreement in FILE 1 was specific
   to the logical timestamp annotation. */


/* ===========================================================================
   STEP 7 - Row counts and key overlap
   =========================================================================== */
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
       (SELECT COUNT(*) FROM f1 WHERE pc LIKE '0%')     AS f1_leading_zero_postals;
-- -> 121, 5, 0, 5
-- ZERO key overlap. Do NOT conclude there are no duplicates - see step 15.


/* ===========================================================================
   STEP 8 - Create the target

   From FILE 1's 22 columns ONLY. `Status` is deliberately NOT declared - the
   table must LEARN it in step 10 for evolution to be proven, not asserted.

   Every type below overrides INFER_SCHEMA, each for a stated reason.
   =========================================================================== */
CREATE TABLE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER (
  store_code               VARCHAR(30)     COMMENT 'Source store code, primary business key.',
  store_name               VARCHAR(150)    COMMENT 'Retail store name.',
  country_code             VARCHAR(10)     COMMENT 'ISO alpha-2 country code.',
  region_code              VARCHAR(20)     COMMENT 'Region code, e.g. AMER/EMEA/APAC.',
  tax_jurisdiction_code    VARCHAR(30)     COMMENT 'Sub-national tax jurisdiction code.',
  format_code              VARCHAR(20)     COMMENT 'Store format, e.g. FLG (flagship) or MINI.',
  city                     VARCHAR(100)    COMMENT 'City of the store location.',
  state_code               VARCHAR(20)     COMMENT 'State or province code.',
  -- VARCHAR is MANDATORY. File 1 stores postal_code as STRING with real leading
  -- zeros; file 2 stores it as INT64 where they are already gone. Adopting file
  -- 2's NUMBER would destroy file 1's correct data to match file 2's damage.
  postal_code              VARCHAR(30)     COMMENT 'Postal code as text. VARCHAR is mandatory: file 1 stores it as string with leading zeros, file 2 stores it as INTEGER which already lost them.',
  address_line1            VARCHAR(255)    COMMENT 'Street address line of the store.',
  -- Parquet stores these as DOUBLE and INFER_SCHEMA reports REAL. Exact decimal
  -- is right for coordinates: binary floats cannot represent most decimal
  -- degrees exactly, so REAL invites drift in equality joins and GROUP BYs.
  -- NUMBER(10,6) also holds -180.000000, which the inferred precision would not.
  latitude                 NUMBER(9,6)     COMMENT 'Store latitude in decimal degrees; Parquet stores this as float64.',
  longitude                NUMBER(10,6)    COMMENT 'Store longitude in decimal degrees; Parquet stores this as float64.',
  store_open_date          DATE            COMMENT 'Date the store opened.',
  -- INFER_SCHEMA said TEXT only because the column is 100% NULL in both files:
  -- no values to type, not evidence it holds strings.
  store_close_date         DATE            COMMENT 'Date the store closed; NULL in all current source rows.',
  lifecycle_status         VARCHAR(30)     COMMENT 'Lifecycle state, e.g. ACTIVE/CLOSED.',
  -- int64 -> NUMBER(38,0) narrowed to something meaningful. Rent needs scale 2
  -- or cents are silently rounded away.
  floor_area_sqft          NUMBER(10,0)    COMMENT 'Retail floor area in square feet.',
  annual_rent_usd          NUMBER(14,2)    COMMENT 'Annual rent in USD.',
  is_active                BOOLEAN         COMMENT 'Active flag; source ships the string Y.',
  effective_start_date     DATE            COMMENT 'Date the record became effective.',
  effective_end_date       DATE            COMMENT 'Date the record stopped being effective.',
  -- THE DELIBERATE COMPROMISE. File 1 has 121 real timestamps, file 2 has 5
  -- occurrences of '21:50.4'. Options weighed:
  --   TIMESTAMP_NTZ  -> file 2's COPY aborts, evolution never fires, Status
  --                     never added, requirement "load both files" unmet
  --   VARCHAR only   -> 121 valid timestamps demoted to text for 5 bad rows
  --   BOTH (chosen)  -> raw here, typed sibling in step 12. Costs one column,
  --                     loses nothing.
  -- PART 0.5 is why there is no third option: MATCH_BY_COLUMN_NAME forbids a
  -- mid-load cast.
  created_at               VARCHAR(50)     COMMENT 'Raw creation timestamp as text. File 1 supplies a real Parquet timestamp, file 2 supplies the corrupted fragment 21:50.4; VARCHAR lands both losslessly. Use created_at_ntz for the typed value.',
  source_system            VARCHAR(50)     COMMENT 'Originating source system.',
  -- Audit columns. Filled from METADATA$ via INCLUDE_METADATA, never from the
  -- file. NO DEFAULT on __loaded_at: COPY silently IGNORES column defaults when
  -- MATCH_BY_COLUMN_NAME is used (proven in the CSV exercise, where 126 rows
  -- landed NULL despite the DEFAULT existing in INFORMATION_SCHEMA).
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row came from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: row ordinal within the source file (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: staged file last modified time (METADATA$FILE_LAST_MODIFIED).',
  __loaded_at              TIMESTAMP_NTZ   COMMENT 'Audit: when the row was loaded (METADATA$START_SCAN_TIME).'
)
ENABLE_SCHEMA_EVOLUTION = TRUE          -- <<< the evolution switch
COMMENT = 'Unified store master Parquet target. Created from file 1 columns only; ENABLE_SCHEMA_EVOLUTION lets COPY add later columns such as Status automatically.';
-- -> Table STORE_MASTER successfully created.  26 columns, 0 rows.

SHOW TABLES LIKE 'STORE_MASTER' IN SCHEMA ANALYSIS_DB.DATA_MIGRATION_PARQUET;
-- verify ENABLE_SCHEMA_EVOLUTION = Y


/* ===========================================================================
   STEP 9 - LOAD 1: baseline, no drift

   Mapping performed (PART 0.3): all 22 footer columns matched a target column
   by uppercased name; 4 audit columns filled from metadata; nothing unmatched
   in either direction, so NO evolution event.
   =========================================================================== */
COPY INTO ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master.parquet
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
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

-- Leading zeros survived. BOTH conditions were required: file 1 stores them as
-- STRING, AND the target declares VARCHAR. Either alone loses them.
SELECT store_code, postal_code, created_at, is_active
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
WHERE postal_code LIKE '0%' ORDER BY store_code;
-- -> 08759, 02166, 03988, 00158, 06055   (5 codes)


/* ===========================================================================
   STEP 10 - LOAD 2: ADDITIVE DRIFT -> SCHEMA EVOLUTION FIRES

   Byte-identical COPY, different path. NO DDL is issued here.

   Mapping performed:
     22 columns  matched existing target columns
     Status      NO match -> evolution ALTERs the table, appends
                 STATUS TEXT(16777216) at position 27, loads 'y'.
                 Unbounded because evolution does not guess a length.
                 TEXT not BOOLEAN because the footer says BYTE_ARRAY/STRING.
     121 existing rows -> STATUS = NULL automatically.

   THIS LOAD ALSO CARRIES TWO TYPE DRIFTS AND SUCCEEDS ANYWAY, because step 8
   designed for them:
     postal_code  INT64 8759      -> VARCHAR '8759'   (zeros already lost at source)
     created_at   '21:50.4'       -> VARCHAR verbatim (evidence preserved)
   Had created_at been declared TIMESTAMP_NTZ, this COPY would have ABORTED and
   evolution would never have fired. That is the argument for designing the
   target from a COMPARISON of both schemas rather than from file 1 alone.
   =========================================================================== */
COPY INTO ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/store_master_1.parquet
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
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
       COMMENT
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA='DATA_MIGRATION_PARQUET' AND TABLE_NAME='STORE_MASTER'
ORDER BY ORDINAL_POSITION;
/* Position 27 = STATUS, TEXT, 16777216, COMMENT NULL.
   The NULL comment is a useful tell: every hand-declared column carries one, so
   a commentless column is an evolved one. Worth back-filling. */


/* ===========================================================================
   STEP 12 - Derive the typed timestamp

   The second half of the step-8 compromise. Added BY HAND with a REVIEWED type
   - the deliberate contrast with evolution, which in step 14 auto-installs
   NUMBER(2,0) for employee_count.

   MUST run AFTER both loads, or the UPDATE only sees file 1's rows.
   =========================================================================== */
ALTER TABLE ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
  ADD COLUMN IF NOT EXISTS created_at_ntz TIMESTAMP_NTZ
  COMMENT 'Typed creation timestamp derived from created_at via TRY_TO_TIMESTAMP_NTZ. NULL where the source value is unparseable, e.g. file 2 ships the fragment 21:50.4. Added explicitly with a reviewed type, not by schema evolution.';

UPDATE ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
SET created_at_ntz = TRY_TO_TIMESTAMP_NTZ(created_at)
WHERE created_at IS NOT NULL;
-- -> 126 rows updated. File 1: 121 typed. File 2: 5 NULL, raw text retained.

/* LIMITATION: this is a plain column populated by a one-off UPDATE, so rows
   loaded LATER stay NULL until it is re-run. Step 14 demonstrates exactly that.
   Fix by (a) re-running as a post-load step, (b) making it a view column, or
   (c) fixing the upstream export. (c) is the real remedy. */


/* ===========================================================================
   STEP 13 - Validate
   =========================================================================== */
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$')            AS source_file,
       COUNT(*)                                       AS row_cnt,
       SUM(IFF(STATUS IS NULL,1,0))                   AS status_nulls,
       SUM(IFF(postal_code LIKE '0%',1,0))            AS leading_zero_postals,
       SUM(IFF(created_at_ntz IS NULL,1,0))           AS created_at_unparseable,
       SUM(IFF(is_active IS NULL,1,0))                AS is_active_nulls,
       SUM(IFF(store_close_date IS NULL,1,0))         AS close_date_nulls,
       COUNT(DISTINCT store_code)                     AS distinct_keys
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* store_master.parquet    121  121  5  0  0  121  121
   store_master_1.parquet    5    0  0  5  0    5    5
   TOTAL                   126  121  5  5  0  126  126

   Read across:
     STATUS nulls 121 -> 0        additive drift made visible
     leading zeros  5 -> 0        file 2's destroyed at SOURCE, not by the load
     unparseable    0 -> 5        type drift made visible
     is_active      0 nulls       'Y' and 'y' BOTH coerced to TRUE            */

-- Same physical store, both files, side by side.
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$') AS src, store_code, postal_code,
       latitude, created_at, created_at_ntz, is_active, STATUS
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
WHERE store_code IN ('US_0002','US_0102') ORDER BY src;
/* store_master.parquet    US_0002  08759  28.454519  2026-04-17 15:21:50.369  <ts>  TRUE  NULL
   store_master_1.parquet  US_0102   8759  28.454519  21:50.4                  NULL  TRUE  y
   Identical latitude. Different key. That is step 15's problem.               */


/* ===========================================================================
   STEP 14 - Future-columns test  (EXECUTED, THEN ROLLED BACK)

   Parquet is binary and cannot be hand-written in an editor, so the fixture is
   GENERATED BY SNOWFLAKE - a genuinely useful technique: no local pyarrow, and
   the file is written by the same engine that will read it.

   Written to a SEPARATE prefix so it cannot be swept into a real load.
   =========================================================================== */
COPY INTO @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master-future/
FROM (
  SELECT 'US_9001' AS store_code, 'Apple Evolution Test North' AS store_name, 'US' AS country_code,
         'AMER' AS region_code, 'US_NY_STD' AS tax_jurisdiction_code, 'FLG' AS format_code,
         'Testburgh' AS city, 'NY' AS state_code, '01001' AS postal_code,
         '1 Evolution Plaza' AS address_line1, 40.712776 AS latitude, -74.005974 AS longitude,
         '2024-03-15'::DATE AS store_open_date, NULL::DATE AS store_close_date,
         'ACTIVE' AS lifecycle_status, 15000 AS floor_area_sqft, 9500000 AS annual_rent_usd,
         'Y' AS is_active, '2026-04-17'::DATE AS effective_start_date,
         '9999-12-31'::DATE AS effective_end_date,
         '2026-04-17 16:00:00.000' AS created_at, 'RETAIL_OPS' AS source_system,
         'y' AS status, 'Jane Okafor' AS manager_name, 87 AS employee_count
  UNION ALL
  SELECT 'US_9002','Apple Evolution Test South','US','AMER','US_CA_STD','MINI',
         'Demo Creek','CA','90210','2 Demo Way',34.052235,-118.243683,
         '2025-11-02'::DATE, NULL::DATE, 'ACTIVE', 7400, 6200000, 'Y',
         '2026-04-17'::DATE,'9999-12-31'::DATE,'2026-04-17 16:00:01.000','RETAIL_OPS',
         'n','Raj Mehta',34
)
FILE_FORMAT = (TYPE = PARQUET) HEADER = TRUE OVERWRITE = TRUE;
-- -> rows_unloaded 2. Snowflake names the output data_0_0_0.snappy.parquet, so
--    the COPY below targets the PREFIX, not a filename.

COPY INTO ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
FROM @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master-future/
FILE_FORMAT = (FORMAT_NAME = 'ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
INCLUDE_METADATA = (
  __file_name              = METADATA$FILENAME,
  __row_number             = METADATA$FILE_ROW_NUMBER,
  __file_last_modified_ntz = METADATA$FILE_LAST_MODIFIED,
  __loaded_at              = METADATA$START_SCAN_TIME
)
ON_ERROR = ABORT_STATEMENT;
-- -> LOADED 2 rows. Table 28 -> 30 columns. NO ALTER TABLE was issued.

SELECT ORDINAL_POSITION AS pos, COLUMN_NAME, DATA_TYPE,
       COALESCE(CHARACTER_MAXIMUM_LENGTH::VARCHAR,
                NUMERIC_PRECISION||','||NUMERIC_SCALE,'') AS size
FROM ANALYSIS_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA='DATA_MIGRATION_PARQUET' AND TABLE_NAME='STORE_MASTER'
  AND ORDINAL_POSITION >= 27 ORDER BY ORDINAL_POSITION;
/* 27 STATUS TEXT 16777216 / 28 CREATED_AT_NTZ TIMESTAMP_NTZ
   29 MANAGER_NAME TEXT 16777216 / 30 EMPLOYEE_COUNT NUMBER(2,0)

   *** EMPLOYEE_COUNT NUMBER(2,0) IS THE WARNING ***
   Sized to a 2-row sample (87, 34) -> a CEILING OF 99. Evolution did not choose
   a sensible type, it chose the smallest that fit what it saw. A store with 100
   staff fails the next load. Compare position 28, chosen by a human in step 12.

   Note 29/30 are in DOCUMENT order, matching the Parquet footer - whereas the
   JSON exercise appended evolved columns ALPHABETICALLY. Evolved column
   ordering follows how the format reports its schema; never depend on it. */

-- NULL staircase across all three files
SELECT REGEXP_SUBSTR(__file_name,'[^/]+$')          AS source_file,
       COUNT(*)                                     AS row_cnt,
       SUM(IFF(STATUS IS NULL,1,0))                 AS status_nulls,
       SUM(IFF(MANAGER_NAME IS NULL,1,0))           AS manager_nulls,
       SUM(IFF(EMPLOYEE_COUNT IS NULL,1,0))         AS empcount_nulls,
       SUM(IFF(created_at_ntz IS NULL,1,0))         AS created_ntz_nulls
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
GROUP BY 1 ORDER BY 1;
/* data_0_0_0.snappy.parquet    2    0    0    0    2
   store_master.parquet       121  121  121  121    0
   store_master_1.parquet       5    0    5    5    5

   Each file fills exactly the columns it supplies. created_ntz_nulls = 2 on the
   new file is NOT drift - it is the step-12 limitation, caught by the test. */

-- Rollback: rows go, COLUMNS STAY. Evolution is not reversible by DELETE.
DELETE FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER
WHERE __file_name LIKE 'store-master-future/%';
-- -> 2 rows deleted. Back to 126 rows, still 30 columns.

-- Staged fixture also removed:
--   snow stage remove '@ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg' \
--     'store-master-future/data_0_0_0.snappy.parquet' --connection ysirciu-vg28332


/* ===========================================================================
   STEP 15 - Logical duplicate detection

   Every obvious check says the load is clean:
       126 rows, 126 distinct store_code
   It is not. File 2's rows are file 1's first five stores RE-KEYED
   US_0001 -> US_0101. A key-based check cannot see it.

   Worse than the JSON exercise, where file 2 reused the same keys and the
   collision was immediately visible as COUNT(*) > COUNT(DISTINCT store_code).
   Re-keying keeps the corruption and removes the alarm.
   =========================================================================== */
SELECT a.store_code AS file1_key, b.store_code AS file2_key, a.store_name,
       a.latitude, a.longitude, a.store_open_date,
       a.postal_code AS f1_postal, b.postal_code AS f2_postal
FROM ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER a
JOIN ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER b
  ON a.latitude = b.latitude AND a.longitude = b.longitude
 AND a.__file_name LIKE '%store_master.parquet'
 AND b.__file_name LIKE '%store_master_1.parquet'
ORDER BY a.store_code;
/* US_0001 US_0101 Apple Bradleyton            42.839799  -84.299787  77677/77677
   US_0002 US_0102 Apple Hunttown              28.454519 -109.838435  08759/ 8759
   US_0003 US_0103 Apple Robinsonville         31.100593  -80.263677  61211/61211
   US_0004 US_0104 Apple Dianaberg             28.731634  -75.886758  02166/ 2166
   US_0005 US_0105 Apple North Alejandramouth  31.716178 -123.744726  13344/13344

   The postal columns match where there was no leading zero and differ where
   there was. That asymmetry is itself proof the two rows describe the same store
   and that file 2 is the degraded copy.

   Full monitoring queries and remediation in 10_logical_duplicate_detection.sql.
   Remediation is NOT executed - deleting the degraded rows would also discard
   file 2's Status values, which exist ONLY there, so they must be merged onto
   the file 1 rows first on the composite natural key. That is the real cost of
   re-keying: you cannot even de-duplicate without reconciling which attributes
   each copy uniquely contributes. */


/* ###########################################################################
   FINAL STATE

     126 rows, 126 distinct store_code, 30 columns, 2 source files
     5 logical duplicates outstanding (step 15)
     Source files byte-identical: 20,940 / 5,434 bytes, original timestamps

   STATE TRANSITIONS
     step  8  create target (file 1 schema)     26 cols      0 rows   -
     step  9  COPY file 1                       26 cols    121 rows   no evolution
     step 10  COPY file 2                       26 -> 27   126 rows   EVOLUTION
     step 12  add created_at_ntz by hand        27 -> 28   126 rows   manual
     step 14  COPY future-columns fixture       28 -> 30   128 rows   EVOLUTION
     step 14  delete fixture rows               30 cols    126 rows   cols persist

   Every load ran with ZERO errors - notable, because the CSV run hit
   ERROR_ON_COLUMN_COUNT_MISMATCH and a type abort, and the JSON run needed three
   attempts on the NaN/DATE conflict. Parquet's embedded schema made the loads
   clean. The risk moved from PARSING to INTERPRETATION: the INFER_SCHEMA vs
   TYPEOF disagreement (step 6) and the re-keyed duplicates (step 15), neither of
   which would ever surface as a load failure.
   ########################################################################### */
