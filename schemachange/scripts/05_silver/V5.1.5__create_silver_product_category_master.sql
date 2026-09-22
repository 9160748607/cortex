/* ---------------------------------------------------------------------------
   V5.1.5 - Silver product category master (dynamic table)

   First bronze -> silver transformation in the PRODUCT-MASTER group, which is a
   five-level hierarchy deployed in dependency order:

       category (V5.1.5)
         -> family (V5.1.6)
              -> model (V5.1.7)
                   -> sku (V5.1.8)
                        -> country availability (V5.1.9)  [+ country]

   The order is not cosmetic. Each script's FK validation joins against the
   SILVER parent, not bronze, so the parent must exist first for the check to be
   a genuine silver-to-silver integrity test rather than a restatement of the
   bronze result. The same convention was established in the country-master
   group (V5.1.1 - V5.1.4).

   Reuses the pattern from V5.1.1 - see that header for de-duplication,
   deterministic survivor ordering, why QUALIFY ROW_NUMBER rather than DISTINCT,
   and why there is no is_current or silver load-timestamp column. Only
   category-specific reasoning is recorded here.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per category_code
     Business key  category_code
     Volume        10 rows, static, 8 source columns - the smallest table in the
                   product group
     Foreign keys  none. This is the root of the product hierarchy.
     Referenced by sv_product_family_master (V5.1.6)

     reporting_segment  Mac (2), iPad (1), iPhone (1),
                        "Wearables, Home and Accessories" (6)

   FOUR SEGMENTS, NOT FIVE - AND WHY THAT IS CORRECT
   --------------------------------------------------------------------
   Apple reports five segments. Only four appear here; SERVICES IS ABSENT. That
   is not a data defect: Services (iCloud, Apple Music, AppleCare, App Store) is
   revenue without a physical SKU, so it has no product category, no family, no
   model and no part number. A product hierarchy legitimately covers only the
   four hardware segments.

   This is worth stating explicitly because the obvious "completeness" check -
   compare the four values here against sv_country_master.apple_fiscal_segment's
   five values - will always show a gap, and that gap must not be read as
   missing data. The two columns are also unrelated in meaning: one segments
   PRODUCTS, the other segments GEOGRAPHIES (Americas, Europe, Greater China,
   Japan, Rest of Asia Pacific). They share a name and nothing else.

   QUALITY CHECKS
   --------------------------------------------------------------------
   Record-level HARD REJECT: null or blank category_code. As established in
   V5.1.2, hard-reject only what is unusable AS A KEY - a row with no key cannot
   be de-duplicated, joined or referenced, so it has no downstream use.

   Everything else is FLAGGED:
       MISSING_CATEGORY_NAME     name null or blank
       NULL_REPORTING_SEGMENT    segment null or blank
       NULL_IS_ACTIVE            is_active null
       NULL_EFF_START / _END     effective dates null
       INVALID_DATE_RANGE        end date before start date
       NULL_SOURCE_SYSTEM        lineage column null

   NO DOMAIN-MEMBERSHIP FLAG ON reporting_segment. The tempting rule is
       reporting_segment NOT IN ('iPhone','Mac','iPad','Wearables, Home and Accessories')
   and it is deliberately NOT implemented. Apple has renamed and re-cut this
   segment repeatedly - "Wearables, Home and Accessories" was previously "Other
   Products", and a future Vision/wearables re-cut is likelier than not. A
   hard-coded allow-list would turn an ordinary business change into a wall of
   false positives on every row of a new segment, which is the same cry-wolf
   failure documented in V5.1.4 for the alpha2/alpha3 prefix heuristic. A NULL
   segment is a real defect and is flagged; an UNFAMILIAR one is news, not a
   defect, and belongs in a reconciliation report rather than a row-level flag.

   Verified after load: all 10 rows active, none with a null effective_end_date,
   zero flags.

   NORMALISATION: category_code is UPPER(TRIM(...))'d because it is the join key
   for family and casing drift would silently break the hierarchy. category_name
   and reporting_segment are TRIM-only - upper-casing them would corrupt display
   values ("IPHONE" is wrong; "iPhone" is the brand), and note that
   reporting_segment legitimately CONTAINS A COMMA. That is safe here because the
   flag string is built from flag literals only, never from data values, so no
   data comma can ever be mistaken for a flag delimiter.

   CONFIGURATION - identical to V5.1.1, mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG = DOWNSTREAM, REFRESH_MODE = INCREMENTAL (explicit),
     TRANSIENT, INITIALIZE = ON_CREATE

   Verified after creation: refresh_mode INCREMENTAL, refresh_action INCREMENTAL,
   SUCCEEDED, refresh_mode_reason empty, ZERO recommendations, 10 rows /
   10 distinct keys, ZERO dq flags, all __bronze_row_count = 1.

   Depends on: V2.1.2 (SILVER schema), V4.3.1/V4.3.2 (bronze product category),
               V1.1.4 (MEDALLION_LAYER tag).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_product_category_master
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver product category master: root of the product hierarchy, de-duplicated on category_code.'
AS
SELECT
    -- Business key. UPPER+TRIM; same expression must appear in QUALIFY below.
    UPPER(TRIM(b.category_code))                            AS category_code,
    -- TRIM only: "iPhone" is a brand, "IPHONE" is a corruption.
    TRIM(b.category_name)                                   AS category_name,
    -- TRIM only, and legitimately contains a comma. Safe: the flag string below
    -- is assembled from literals, never from data values.
    TRIM(b.reporting_segment)                               AS reporting_segment,
    b.is_active,
    b.effective_start_date,
    b.effective_end_date,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.category_name) IS NULL OR TRIM(b.category_name)='','MISSING_CATEGORY_NAME',NULL),
        -- A NULL segment is a defect. An UNFAMILIAR segment is a business
        -- change, not a defect - see header: no allow-list here on purpose.
        IFF(TRIM(b.reporting_segment) IS NULL OR TRIM(b.reporting_segment)='','NULL_REPORTING_SEGMENT',NULL),
        IFF(b.is_active IS NULL,                            'NULL_IS_ACTIVE',        NULL),
        IFF(b.effective_start_date IS NULL,                 'NULL_EFF_START',        NULL),
        IFF(b.effective_end_date IS NULL,                   'NULL_EFF_END',          NULL),
        IFF(b.effective_end_date < b.effective_start_date,  'INVALID_DATE_RANGE',    NULL),
        IFF(b.source_system IS NULL,                        'NULL_SOURCE_SYSTEM',    NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.category_code))) AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_product_category_master b
WHERE b.category_code IS NOT NULL
  AND TRIM(b.category_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.category_code))
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_product_category_master
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SHOW DYNAMIC TABLES LIKE 'SV_PRODUCT_CATEGORY_MASTER' IN SCHEMA {{ database }}.SILVER;
-- Expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.

USE DATABASE {{ database }};
SELECT dt.name, rec.value:"code"::STRING AS rec_code, rec.value:"info"::STRING AS rec_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_PRODUCT_CATEGORY_MASTER')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;
-- Expect ZERO rows.

-- Reconciliation, de-dup guarantee and DQ count.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_product_category_master)                  AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_category_master)                  AS silver_rows,
       (SELECT COUNT(DISTINCT category_code) FROM {{ database }}.SILVER.sv_product_category_master) AS silver_keys,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_category_master WHERE __bronze_row_count > 1) AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_category_master WHERE dq_issue_flags IS NOT NULL) AS dq_flagged;
-- Recorded: 10, 10, 10, 0, 0
-- silver_rows must equal silver_keys; keys_with_dupes and dq_flagged must be 0.

-- Segment distribution. Four hardware segments; Services is CORRECTLY absent.
SELECT reporting_segment, COUNT(*) AS categories,
       LISTAGG(category_code, ', ') WITHIN GROUP (ORDER BY category_code) AS codes
FROM {{ database }}.SILVER.sv_product_category_master
GROUP BY 1 ORDER BY 2 DESC;
-- Recorded: Wearables, Home and Accessories 6 | Mac 2 | iPad 1 | iPhone 1

-- Proof that the product segment column and the GEOGRAPHIC segment column in
-- sv_country_master are unrelated: the gap here is Services, and it is expected.
SELECT (SELECT COUNT(DISTINCT reporting_segment)   FROM {{ database }}.SILVER.sv_product_category_master) AS product_segments,
       (SELECT COUNT(DISTINCT apple_fiscal_segment) FROM {{ database }}.SILVER.sv_country_master)         AS geographic_segments;
-- Recorded: 4, 5. The two columns share a name and nothing else - do NOT
-- reconcile them.

-- Anything needing attention (expect ZERO rows)
SELECT category_code, dq_issue_flags, __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_product_category_master
WHERE dq_issue_flags IS NOT NULL OR __bronze_row_count > 1
ORDER BY category_code;
