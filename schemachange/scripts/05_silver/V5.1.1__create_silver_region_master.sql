/* ---------------------------------------------------------------------------
   V5.1.1 - Silver region master (dynamic table)

   First bronze -> silver transformation. Region is the top of the geography
   hierarchy (region -> country -> store), so it is the natural table to start
   with: no upstream dependencies, 5 rows, and it establishes the pattern the
   remaining 12 tables will copy.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per region_code
     Business key  region_code - natural, stable, no surrogate needed
     Domain        AMER, EMEA, JAPAN, GREATER_CHINA, APAC
                   Apple's five actual reporting segments
     Type          reference / dimension. Effective-dated columns exist but
                   every row is open-ended (2000-01-01 -> 9999-12-31) with one
                   version per key, so this is effectively SCD1 / current-only
                   today. The effective dates are carried forward so it can
                   become SCD2 later without restructuring.
     Volume        5 rows, static

   DE-DUPLICATION - WHY IT IS HERE EVEN THOUGH BRONZE IS CLEAN
   --------------------------------------------------------------------
   Bronze currently holds 5 rows / 5 distinct keys / 0 duplicates. The
   de-duplication is DEFENSIVE, not corrective, because COPY load history is
   keyed on FILE NAME, not business key. Three real triggers:

     1. region_master.csv re-delivered under any new name -> 5 more rows
     2. FORCE = TRUE on a reload                          -> 5 more rows
     3. the delta-ingest task in 07_orchestration adds files continuously

   This is not theoretical. The CSV, JSON and Parquet schema-drift exercises in
   schema_evolution_or_drift*/ each produced duplicate rows by exactly this
   mechanism - a re-delivered file under a different name.

   MECHANISM: QUALIFY ROW_NUMBER(), deliberately NOT DISTINCT or GROUP BY.
     - ROW_NUMBER() with PARTITION BY / ORDER BY IS incrementally supported.
     - DISTINCT and GROUP BY are only PARTIALLY supported and risk forcing a
       FULL refresh, which would violate the architectural mandate.
     - QUALIFY must stay TOP LEVEL and the partition key must appear in the
       SELECT list, or Snowflake emits QUALIFY_RANK_NOT_TOP_LEVEL /
       QUALIFY_RANK_KEYS_NOT_PERSISTED. Verified after creation: NO
       recommendations emitted, so the structure is optimal.

   SURVIVOR ORDERING IS FULLY DETERMINISTIC. A non-deterministic tie-break
   would let the DT pick a different winner on each refresh, so the chain ends
   in (__file_name, __row_number) which is unique per bronze row:
       created_at DESC                -> newest source version wins
       __file_last_modified_ntz DESC  -> then newest file
       __file_name DESC, __row_number DESC -> guaranteed single winner

   QUALITY CHECKS
   --------------------------------------------------------------------
   Record-level HARD REJECT (row excluded) - one rule only:
       region_code IS NULL OR TRIM(region_code) = ''
     A dimension row with no business key is unusable and would break every
     downstream join. Everything else is FLAGGED, not dropped - silently
     discarding reference rows is worse than passing them through marked.

   Column-level NORMALISATION:
       UPPER(TRIM(region_code)), TRIM(region_name)
     Guards against the whitespace and case drift the CSV sources have already
     demonstrated elsewhere in this project.

   Record-level FLAGGED via dq_issue_flags (NULL when the row is clean):
       MISSING_REGION_NAME, NULL_IS_ACTIVE, NULL_EFF_START, NULL_EFF_END,
       INVALID_DATE_RANGE, NULL_SOURCE_SYSTEM
     All NULL on current data. This is future-proofing and the reusable pattern
     for the remaining tables.

   COLUMNS DELIBERATELY NOT ADDED - all three for the same root cause
   --------------------------------------------------------------------
   CURRENT_TIMESTAMP() / CURRENT_DATE() / SYSDATE() are supported in an
   incremental dynamic table ONLY IN FILTERS. Used in the SELECT projection they
   FORCE FULL REFRESH, because the value changes on every refresh and rows stop
   being reproducible. Therefore:

     is_current          would need CURRENT_DATE() in the projection. Expose it
                         from a view over this table, or derive it in gold.
     __silver_loaded_at  same problem. Also semantically wrong here: the row's
                         provenance is already fully described by the three
                         bronze technical columns, so a silver load stamp adds
                         no information and costs the incremental mode.
     sequence-based key  SEQ*() is NOT SUPPORTED in dynamic tables at all.
                         NOTE FOR GOLD: the 6 sequences created in COMMON by
                         V3.1.3 cannot be used by any dynamic table. Gold
                         dimensions will need deterministic hash keys
                         (e.g. SHA1_HEX of the business key) or a non-DT load
                         path. Worth deciding before the gold layer is built.

   TECHNICAL COLUMNS
   --------------------------------------------------------------------
   All three bronze technical columns are carried forward unchanged:
       __file_name, __row_number, __file_last_modified_ntz
   Plus one addition that directly serves the duplicate concern:
       __bronze_row_count - how many bronze rows collapsed into this one.
       > 1 means duplicates arrived and were de-duplicated. This is the
       monitoring hook; alert on it rather than discovering duplicates later.

   created_at is RENAMED to source_created_at. It is the SOURCE system's
   timestamp, and the bare name invites downstream readers to mistake it for a
   load time.

   CONFIGURATION
   --------------------------------------------------------------------
     TARGET_LAG   = DOWNSTREAM    architectural rule: freshness is pulled by
                                  gold, not set per table.
     REFRESH_MODE = INCREMENTAL   EXPLICIT, not AUTO. With AUTO, Snowflake can
                                  silently fall back to FULL and nothing fails.
                                  Explicit INCREMENTAL makes an
                                  un-incrementalizable query an ERROR instead of
                                  a silent cost increase.
     TRANSIENT                    architectural note 1 - no fail-safe cost.
     INITIALIZE   = ON_CREATE     populate immediately so the result is
                                  verifiable at deploy time.

   OPERATIONAL CAVEAT - TARGET_LAG = DOWNSTREAM DOES NOT REFRESH ON A CLOCK.
   DOWNSTREAM means "refresh when a downstream DT needs data". There is no gold
   layer yet, so after ON_CREATE populates this table it stays STATIC until gold
   exists or someone runs ALTER DYNAMIC TABLE ... REFRESH. That is correct for
   the end state, but bronze changes will not appear here in the meantime.

   RELATED RISK: the SILVER schema has DATA_RETENTION_TIME_IN_DAYS = 1.
   Incremental refresh needs the change-tracking window to still cover the gap
   since the last refresh. A DT that goes more than a day without refreshing may
   be reinitialized with a full recompute. Harmless at 5 rows; it will matter for
   br_sales_header at 77,131 rows. Either raise retention on SILVER or give the
   leaf gold table a time-based lag so the whole chain is pulled regularly.

   Change tracking on the base table is enabled implicitly by Snowflake when the
   dynamic table is created - no explicit ALTER TABLE is required.

   Verified after creation: refresh_mode = INCREMENTAL, refresh_mode_reason
   empty (no downgrade), scheduling_state ACTIVE, 5 rows, all dq_issue_flags
   NULL, all __bronze_row_count = 1.

   Depends on: V2.1.2 (SILVER schema), V4.2.1/V4.2.2 (bronze region master),
               V1.1.4 (MEDALLION_LAYER tag).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_region_master
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver region master: de-duplicated on region_code, trimmed and cased, with DQ flags.'
AS
SELECT
    -- Cleaned business key. UPPER+TRIM is the de-dup partition key too, so the
    -- same expression must appear here and in QUALIFY (keys must be persisted).
    UPPER(TRIM(b.region_code))                              AS region_code,
    TRIM(b.region_name)                                     AS region_name,
    b.is_active,
    b.effective_start_date,
    b.effective_end_date,
    -- Renamed: this is the SOURCE system's timestamp, not a silver load time.
    b.created_at                                            AS source_created_at,
    b.source_system,
    -- Record-level quality flags. NULL when the row is clean, so a simple
    -- WHERE dq_issue_flags IS NOT NULL finds everything needing attention.
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.region_name) IS NULL OR TRIM(b.region_name)='','MISSING_REGION_NAME',NULL),
        IFF(b.is_active IS NULL,                            'NULL_IS_ACTIVE',     NULL),
        IFF(b.effective_start_date IS NULL,                 'NULL_EFF_START',     NULL),
        IFF(b.effective_end_date IS NULL,                   'NULL_EFF_END',       NULL),
        IFF(b.effective_end_date < b.effective_start_date,  'INVALID_DATE_RANGE', NULL),
        IFF(b.source_system IS NULL,                        'NULL_SOURCE_SYSTEM', NULL)
    )),','),'')                                             AS dq_issue_flags,
    -- Duplicate monitoring: > 1 means bronze duplicates were collapsed here.
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.region_code)))  AS __bronze_row_count,
    -- The three bronze technical columns, carried forward unchanged.
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_region_master b
-- HARD REJECT: a dimension row with no business key is unusable.
WHERE b.region_code IS NOT NULL
  AND TRIM(b.region_code) <> ''
-- DE-DUPLICATE to one row per business key. Top-level QUALIFY keeps this
-- incrementalizable; the ORDER BY is fully deterministic so the winner is
-- stable across refreshes.
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.region_code))
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: objects that store data must carry a tag so they can be
   tracked for chargeback. ENVIRONMENT, COST_CENTER and CHARGEBACK_OWNER are
   inherited from the database level (V2.1.3); MEDALLION_LAYER is set per object. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_region_master
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Config: expect refresh_mode INCREMENTAL, refresh_mode_reason empty,
-- target_lag DOWNSTREAM, scheduling_state ACTIVE.
SHOW DYNAMIC TABLES LIKE 'SV_REGION_MASTER' IN SCHEMA {{ database }}.SILVER;

-- Optimality: expect ZERO rows. Any QUALIFY_RANK_* code here means the
-- de-duplication is not structured for incremental refresh.
USE DATABASE {{ database }};
SELECT dt.name,
       rec.value:"code"::STRING AS recommendation_code,
       rec.value:"info"::STRING AS recommendation_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_REGION_MASTER')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;

-- Row reconciliation bronze vs silver, and duplicate detection.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_region_master)                AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_region_master)                AS silver_rows,
       (SELECT COUNT(DISTINCT region_code) FROM {{ database }}.SILVER.sv_region_master) AS silver_distinct_keys,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_region_master
          WHERE __bronze_row_count > 1)                                             AS keys_with_bronze_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_region_master
          WHERE dq_issue_flags IS NOT NULL)                                         AS rows_with_dq_issues;
-- Recorded: 5, 5, 5, 0, 0
-- silver_rows must equal silver_distinct_keys - that is the de-dup guarantee.

-- Content check
SELECT region_code, region_name, is_active, effective_start_date, effective_end_date,
       source_created_at, source_system, dq_issue_flags, __bronze_row_count,
       __file_name, __row_number, __file_last_modified_ntz
FROM {{ database }}.SILVER.sv_region_master
ORDER BY region_code;
-- Recorded: AMER, APAC, EMEA, GREATER_CHINA, JAPAN - all flags NULL, all counts 1.

-- Anything needing attention (expect zero rows on current data)
SELECT region_code, dq_issue_flags, __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_region_master
WHERE dq_issue_flags IS NOT NULL
   OR __bronze_row_count > 1
ORDER BY region_code;
