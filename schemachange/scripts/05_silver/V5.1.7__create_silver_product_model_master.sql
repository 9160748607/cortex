/* ---------------------------------------------------------------------------
   V5.1.7 - Silver product model master (dynamic table)

   Third level of the product hierarchy: category -> family -> MODEL -> sku ->
   country availability. See V5.1.5 for the dependency-order convention and
   V5.1.1 for the shared de-duplication and survivor-ordering rules. Only
   model-specific reasoning is here.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per model_code
     Business key  model_code
     Volume        111 rows, static, 9 source columns
     Foreign keys  family_code -> sv_product_family_master   ZERO orphans
                   Verified against SILVER, not bronze.
     Referenced by sv_product_sku_master (V5.1.8)

     lifecycle_status   ACTIVE on all 111 rows
     launch_date        populated on all 111 rows
     discontinue_date   NULL on ALL 111 rows - see below

   THE MOST IMPORTANT FINDING: discontinue_date IS NULL ON EVERY ROW
   --------------------------------------------------------------------
   All 111 models have a NULL discontinue_date, and THAT IS NOT A DEFECT. For a
   lifecycle end-date, NULL is the meaningful open-ended state: "still sold, no
   retirement date set". It is the correct representation of a live product, and
   it agrees exactly with lifecycle_status = ACTIVE on all 111 rows - two
   independent columns telling the same consistent story.

   Therefore THERE IS NO NULL_DISCONTINUE_DATE FLAG. Adding one would flag 100%
   of the table, which is the definitional failure mode of a DQ rule: a flag
   present on every row carries no information, cannot be sorted or filtered on
   usefully, and trains whoever reads the dq_issue_flags column to ignore it.
   The same reasoning excluded the lifecycle_status allow-list in V5.1.6.

   Note this deliberately DIVERGES from V5.1.4, where NULL measures were folded
   into a flag (NONPOSITIVE_POPULATION). The distinction is what NULL MEANS for
   the column's type: for a MEASURE, absent is always wrong - a country has a
   population whether or not it was loaded. For an OPEN-ENDED DATE, absent is a
   legitimate state with business meaning. Nullability alone does not decide
   whether a flag belongs; the semantics of the column do.

   What IS still worth checking is COHERENCE, because it stays meaningful once
   discontinue dates begin to arrive:
       INVALID_DATE_RANGE   discontinue_date < launch_date
   Zero rows can trigger it today (no discontinue dates exist), and that is
   fine - unlike the null flag, this one costs nothing while dormant and becomes
   the primary retirement-data guard the moment the source starts populating the
   column.

   A CROSS-LEVEL CHECK THAT IS DELIBERATELY NOT IN THE DT
   --------------------------------------------------------------------
   A model should not launch before its family's launch_year. That holds in the
   data (zero violations) and is asserted in VALIDATION - but it is NOT a flag,
   because expressing it would require joining sv_product_family_master into
   this dynamic table's definition. That join would make this DT refresh
   whenever EITHER table changes, and would couple a 111-row dimension's refresh
   to its parent for the sake of an attribute check.

   The general rule adopted for this layer: a dynamic table's DQ flags describe
   ONLY ITS OWN ROW. Anything requiring another table - FK existence, cross-level
   date coherence, childless-parent coverage - is a set-level assertion and
   belongs in validation SQL or in a gold-layer reconciliation, never in the
   row-level flag string. This is why every script in the group validates FKs
   with a LEFT JOIN after creation instead of flagging them inside the DT.

   QUALITY CHECKS
   --------------------------------------------------------------------
   Record-level HARD REJECT: null or blank model_code.

   FLAGGED:
       MISSING_MODEL_NAME       name null or blank
       NULL_FAMILY_CODE         FK null or blank - flagged not rejected, same
                                cascade argument as V5.1.6
       NULL_LAUNCH_DATE         launch date absent (this one IS a defect: a
                                model that shipped has a launch date)
       IMPLAUSIBLE_LAUNCH_DATE  launch_date < 1976-04-01, Apple's founding.
                                STATIC literal - CURRENT_DATE() would force this
                                DT to FULL refresh, see V5.1.6's header.
       INVALID_DATE_RANGE       discontinue_date < launch_date (dormant today)
       NULL_LIFECYCLE_STATUS    status null or blank
       NULL_IS_ACTIVE           is_active null
       NULL_SOURCE_SYSTEM       lineage column null

   NORMALISATION: model_code and family_code are UPPER(TRIM(...))'d as join keys.
   model_name and lifecycle_status are TRIM-only - model names carry meaningful
   casing ("iPhone 15 Pro Max").

   CONFIGURATION - identical to V5.1.1, mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG = DOWNSTREAM, REFRESH_MODE = INCREMENTAL (explicit),
     TRANSIENT, INITIALIZE = ON_CREATE

   Verified after creation: refresh_mode INCREMENTAL, refresh_action INCREMENTAL,
   SUCCEEDED, refresh_mode_reason empty, ZERO recommendations, 111 rows /
   111 distinct keys, ZERO dq flags, all __bronze_row_count = 1, zero orphans
   against sv_product_family_master.

   Depends on: V2.1.2 (SILVER schema), V4.3.1/V4.3.2 (bronze product model),
               V5.1.6 (parent - validation join only),
               V1.1.4 (MEDALLION_LAYER tag).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_product_model_master
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver product model master: de-duplicated on model_code. NULL discontinue_date is the open-ended state and is not flagged.'
AS
SELECT
    -- Business key. UPPER+TRIM; same expression must appear in QUALIFY below.
    UPPER(TRIM(b.model_code))                               AS model_code,
    -- TRIM only: "iPhone 15 Pro Max" carries meaningful casing.
    TRIM(b.model_name)                                      AS model_name,
    -- FK normalised: casing drift would break the hierarchy silently.
    UPPER(TRIM(b.family_code))                              AS family_code,
    b.launch_date,
    -- NULL on all 111 rows today, and correctly so: open-ended = still sold.
    b.discontinue_date,
    TRIM(b.lifecycle_status)                                AS lifecycle_status,
    b.is_active,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.model_name) IS NULL OR TRIM(b.model_name)='','MISSING_MODEL_NAME',NULL),
        -- Flag, never reject - rejecting cascades down to SKUs and sales facts.
        IFF(b.family_code IS NULL OR TRIM(b.family_code)='','NULL_FAMILY_CODE',   NULL),
        -- A model that shipped HAS a launch date, so absence is a real defect.
        IFF(b.launch_date IS NULL,                          'NULL_LAUNCH_DATE',      NULL),
        -- STATIC literal on purpose: CURRENT_DATE() would force FULL refresh.
        IFF(b.launch_date < '1976-04-01'::DATE,             'IMPLAUSIBLE_LAUNCH_DATE',NULL),
        -- Deliberately NO NULL_DISCONTINUE_DATE flag - it would fire on 100% of
        -- rows and therefore carry no information. See header.
        -- This coherence check is dormant today but costs nothing and becomes
        -- the main guard once retirement dates start arriving.
        IFF(b.discontinue_date IS NOT NULL
            AND b.discontinue_date < b.launch_date,         'INVALID_DATE_RANGE',    NULL),
        IFF(TRIM(b.lifecycle_status) IS NULL OR TRIM(b.lifecycle_status)='','NULL_LIFECYCLE_STATUS',NULL),
        IFF(b.is_active IS NULL,                            'NULL_IS_ACTIVE',        NULL),
        IFF(b.source_system IS NULL,                        'NULL_SOURCE_SYSTEM',    NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.model_code)))   AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_product_model_master b
WHERE b.model_code IS NOT NULL
  AND TRIM(b.model_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.model_code))
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_product_model_master
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SHOW DYNAMIC TABLES LIKE 'SV_PRODUCT_MODEL_MASTER' IN SCHEMA {{ database }}.SILVER;
-- Expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.

USE DATABASE {{ database }};
SELECT dt.name, rec.value:"code"::STRING AS rec_code, rec.value:"info"::STRING AS rec_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_PRODUCT_MODEL_MASTER')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;
-- Expect ZERO rows.

-- Reconciliation, de-dup guarantee, DQ count, SILVER-to-SILVER FK integrity.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_product_model_master)                   AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_model_master)                   AS silver_rows,
       (SELECT COUNT(DISTINCT model_code) FROM {{ database }}.SILVER.sv_product_model_master) AS silver_keys,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_model_master WHERE __bronze_row_count > 1) AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_model_master WHERE dq_issue_flags IS NOT NULL) AS dq_flagged,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_model_master m
          LEFT JOIN {{ database }}.SILVER.sv_product_family_master f ON m.family_code=f.family_code
          WHERE f.family_code IS NULL)                                                        AS orphan_family;
-- Recorded: 111, 111, 111, 0, 0, 0

-- Confirms the header's central claim: discontinue_date is null on every row and
-- lifecycle_status agrees. If open_ended ever stops equalling silver_rows, the
-- dormant INVALID_DATE_RANGE check becomes live and should be re-reviewed.
SELECT COUNT(*) AS silver_rows,
       COUNT(*) - COUNT(discontinue_date) AS open_ended,
       SUM(IFF(lifecycle_status='ACTIVE',1,0)) AS active_status,
       MIN(launch_date) AS earliest_launch,
       MAX(launch_date) AS latest_launch
FROM {{ database }}.SILVER.sv_product_model_master;
-- Recorded: 111, 111, 111 - two independent columns agreeing that every model
-- is live. earliest_launch is far later than the 1976-04-01 plausibility floor.

-- CROSS-LEVEL COHERENCE - a set-level assertion, deliberately NOT a row flag.
-- No model may launch before its family's launch_year. See header.
SELECT COUNT(*) AS models_launched_before_family_year
FROM {{ database }}.SILVER.sv_product_model_master m
JOIN {{ database }}.SILVER.sv_product_family_master f ON m.family_code = f.family_code
WHERE YEAR(m.launch_date) < f.launch_year;
-- Recorded: 0

-- Hierarchy coverage: every family must have at least one model.
SELECT COUNT(*) AS childless_families
FROM {{ database }}.SILVER.sv_product_family_master f
LEFT JOIN {{ database }}.SILVER.sv_product_model_master m ON f.family_code = m.family_code
WHERE m.family_code IS NULL;
-- Recorded: 0

-- Anything needing attention (expect ZERO rows)
SELECT model_code, family_code, launch_date, discontinue_date, dq_issue_flags,
       __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_product_model_master
WHERE dq_issue_flags IS NOT NULL OR __bronze_row_count > 1
ORDER BY model_code;
