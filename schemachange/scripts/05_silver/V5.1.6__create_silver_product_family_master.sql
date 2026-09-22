/* ---------------------------------------------------------------------------
   V5.1.6 - Silver product family master (dynamic table)

   Second level of the product hierarchy: category -> FAMILY -> model -> sku ->
   country availability. See V5.1.5 for why the five scripts are numbered in
   dependency order, and V5.1.1 for the shared de-duplication, survivor-ordering
   and no-load-timestamp conventions. Only family-specific reasoning is here.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per family_code
     Business key  family_code
     Volume        43 rows, static, 8 source columns
     Foreign keys  category_code -> sv_product_category_master   ZERO orphans
                   Verified against SILVER, not bronze.
     Referenced by sv_product_model_master (V5.1.7)

     launch_year        2019 - 2024, no nulls
     lifecycle_status   ACTIVE on all 43 rows

   COVERAGE: all 10 categories have at least one family, so the hierarchy has no
   childless roots. This is asserted in validation rather than flagged: a
   childless category is a defect of the SET, not of any individual row, so it
   cannot be expressed as a row-level flag on this table.

   THE launch_year RANGE CHECK, AND A CONSTRAINT THE DT IMPOSES ON IT
   --------------------------------------------------------------------
   A plausibility check on launch_year is worth having - a 4-digit year is the
   classic place for a 0, a 19 or a 20219 to survive loading. The natural
   expression is

       launch_year > YEAR(CURRENT_DATE()) + 1        -- DO NOT DO THIS

   and it is FORBIDDEN HERE. CURRENT_DATE() is non-deterministic, and a
   non-deterministic function anywhere in a dynamic table's projection forces
   REFRESH_MODE to fall back to FULL. That is exactly the reason there is no
   __silver_loaded_at column anywhere in this layer (V5.1.1), and the rule
   applies just as much to a value used inside an IFF as to one that is
   selected. A DQ flag is not worth silently converting an incremental pipeline
   into a full recompute.

   So the bound is a STATIC LITERAL:
       IMPLAUSIBLE_LAUNCH_YEAR   launch_year < 1976 OR launch_year > 2035
   1976 is Apple's founding year, so nothing can legitimately precede it, and
   2035 is a deliberately loose forward bound. The trade-off is explicit: a
   static ceiling has to be revised eventually, which is a known, scheduled
   maintenance cost, whereas CURRENT_DATE() would impose an unbounded and
   invisible compute cost on every refresh. Revise the literal when it nears;
   do not reintroduce the date function.

   QUALITY CHECKS
   --------------------------------------------------------------------
   Record-level HARD REJECT: null or blank family_code (per V5.1.2 - reject only
   what is unusable as a key).

   FLAGGED, never rejected:
       MISSING_FAMILY_NAME        name null or blank
       NULL_CATEGORY_CODE         FK null or blank
       IMPLAUSIBLE_LAUNCH_YEAR    outside 1976 - 2035 (static bounds, above)
       NULL_LAUNCH_YEAR           year absent
       NULL_LIFECYCLE_STATUS      status null or blank
       NULL_IS_ACTIVE             is_active null
       NULL_SOURCE_SYSTEM         lineage column null

   NULL_CATEGORY_CODE IS A FLAG, NOT A REJECT, and this is the first place in the
   product group where that choice bites. An orphaned family still has models,
   SKUs and sales beneath it; rejecting it here would cascade - the model rows
   would orphan in V5.1.7, the SKUs in V5.1.8, and the sales facts that reference
   those SKUs would lose their product dimension entirely. Deleting a fact
   because a grandparent dimension attribute is missing is never the right
   trade. This is the same judgement made for the FK nulls in V5.1.4.

   As in V5.1.5, there is NO allow-list flag on lifecycle_status. All 43 rows are
   ACTIVE today, so an allow-list would be trivially satisfiable and therefore
   worthless, and it would fire on every row the day a real status such as
   END_OF_LIFE is introduced. NULL is the defect; an unfamiliar value is news.

   NORMALISATION: family_code and category_code are UPPER(TRIM(...))'d - both are
   join keys (family_code upward from model, category_code upward to category)
   and casing drift would silently break the hierarchy. family_name and
   lifecycle_status are TRIM-only to preserve display casing.

   CONFIGURATION - identical to V5.1.1, mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG = DOWNSTREAM, REFRESH_MODE = INCREMENTAL (explicit),
     TRANSIENT, INITIALIZE = ON_CREATE

   Verified after creation: refresh_mode INCREMENTAL, refresh_action INCREMENTAL,
   SUCCEEDED, refresh_mode_reason empty, ZERO recommendations, 43 rows /
   43 distinct keys, ZERO dq flags, all __bronze_row_count = 1, zero orphans
   against sv_product_category_master.

   Depends on: V2.1.2 (SILVER schema), V4.3.1/V4.3.2 (bronze product family),
               V5.1.5 (parent - required for the validation join),
               V1.1.4 (MEDALLION_LAYER tag).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_product_family_master
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver product family master: de-duplicated on family_code, FK to category flagged not rejected.'
AS
SELECT
    -- Business key. UPPER+TRIM; same expression must appear in QUALIFY below.
    UPPER(TRIM(b.family_code))                              AS family_code,
    TRIM(b.family_name)                                     AS family_name,
    -- FK normalised: casing drift here would break the hierarchy silently.
    UPPER(TRIM(b.category_code))                            AS category_code,
    b.launch_year,
    TRIM(b.lifecycle_status)                                AS lifecycle_status,
    b.is_active,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.family_name) IS NULL OR TRIM(b.family_name)='','MISSING_FAMILY_NAME',NULL),
        -- Flag, never reject: rejecting would cascade and ultimately strand
        -- sales facts with no product dimension. See header.
        IFF(b.category_code IS NULL OR TRIM(b.category_code)='','NULL_CATEGORY_CODE',NULL),
        IFF(b.launch_year IS NULL,                          'NULL_LAUNCH_YEAR',      NULL),
        -- STATIC bounds on purpose. YEAR(CURRENT_DATE()) would make this DT
        -- FULL-refresh - see header. 1976 = Apple's founding year.
        IFF(b.launch_year IS NOT NULL
            AND (b.launch_year < 1976 OR b.launch_year > 2035),'IMPLAUSIBLE_LAUNCH_YEAR',NULL),
        IFF(TRIM(b.lifecycle_status) IS NULL OR TRIM(b.lifecycle_status)='','NULL_LIFECYCLE_STATUS',NULL),
        IFF(b.is_active IS NULL,                            'NULL_IS_ACTIVE',        NULL),
        IFF(b.source_system IS NULL,                        'NULL_SOURCE_SYSTEM',    NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.family_code)))  AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_product_family_master b
WHERE b.family_code IS NOT NULL
  AND TRIM(b.family_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.family_code))
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_product_family_master
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SHOW DYNAMIC TABLES LIKE 'SV_PRODUCT_FAMILY_MASTER' IN SCHEMA {{ database }}.SILVER;
-- Expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.

USE DATABASE {{ database }};
SELECT dt.name, rec.value:"code"::STRING AS rec_code, rec.value:"info"::STRING AS rec_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_PRODUCT_FAMILY_MASTER')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;
-- Expect ZERO rows.

-- Reconciliation, de-dup guarantee, DQ count, SILVER-to-SILVER FK integrity.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_product_family_master)                    AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_family_master)                    AS silver_rows,
       (SELECT COUNT(DISTINCT family_code) FROM {{ database }}.SILVER.sv_product_family_master) AS silver_keys,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_family_master WHERE __bronze_row_count > 1) AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_family_master WHERE dq_issue_flags IS NOT NULL) AS dq_flagged,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_family_master f
          LEFT JOIN {{ database }}.SILVER.sv_product_category_master c ON f.category_code=c.category_code
          WHERE c.category_code IS NULL)                                                        AS orphan_category;
-- Recorded: 43, 43, 43, 0, 0, 0
-- silver_rows must equal silver_keys; the last three must all be 0.

-- Hierarchy coverage: every category must have at least one family. A childless
-- category is a defect of the SET, not of a row, so it is asserted here rather
-- than flagged in the DT.
SELECT COUNT(*) AS childless_categories
FROM {{ database }}.SILVER.sv_product_category_master c
LEFT JOIN {{ database }}.SILVER.sv_product_family_master f ON c.category_code = f.category_code
WHERE f.category_code IS NULL;
-- Recorded: 0

-- Fan-out and launch-year spread per category.
SELECT c.reporting_segment, f.category_code, COUNT(*) AS families,
       MIN(f.launch_year) AS first_launch, MAX(f.launch_year) AS last_launch
FROM {{ database }}.SILVER.sv_product_family_master f
JOIN {{ database }}.SILVER.sv_product_category_master c ON f.category_code = c.category_code
GROUP BY 1,2 ORDER BY 1,2;
-- launch_year recorded across the whole table: 2019 - 2024, comfortably inside
-- the static 1976 - 2035 plausibility bounds.

-- Anything needing attention (expect ZERO rows)
SELECT family_code, category_code, launch_year, dq_issue_flags, __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_product_family_master
WHERE dq_issue_flags IS NOT NULL OR __bronze_row_count > 1
ORDER BY family_code;
