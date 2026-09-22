/* ---------------------------------------------------------------------------
   V5.1.8 - Silver product SKU master (dynamic table)

   Fourth level of the product hierarchy: category -> family -> model -> SKU ->
   country availability. This is the LEAF OF THE GLOBAL HIERARCHY and the level
   at which sales facts join: br_sales_item carries sku_code, so sv_product_sku_
   master is the grain the gold product dimension will be built on. See V5.1.5
   for the dependency-order convention and V5.1.1 for the shared de-duplication
   and survivor-ordering rules.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per sku_code
     Business key  sku_code
     Volume        650 rows, static, 8 source columns
     Foreign keys  model_code -> sv_product_model_master   ZERO orphans
                   Verified against SILVER, not bronze.
     Referenced by sv_product_country_availability (V5.1.9) and, in gold, by the
                   sales item fact.

     variant             112 distinct values (colour / capacity / configuration)
     price_tier          Premium (306), Ultra (255), Standard (89)
     global_launch_date  populated on all 650 rows, never earlier than its
                         model's launch_date (zero violations)

   THERE IS NO PRICE ON THE PRICE TABLE - AND THAT MATTERS DOWNSTREAM
   --------------------------------------------------------------------
   price_tier is an ORDINAL BAND, not a number. This table carries no list price,
   no MSRP and no currency, so the SKU master CANNOT be used to value a
   transaction or to recompute a sales amount. All monetary values live in the
   sales item fact.

   Recording this here because it is exactly the assumption a gold-layer or BI
   developer would otherwise make ("join the SKU dimension to get list price"),
   and it has a direct consequence: any price-variance or discount analysis must
   derive its baseline from the FACT - for example a median selling price per
   (sku_code, currency_code) - and not from this dimension. It also means
   price_tier is safe to treat as a dimension attribute that never needs
   currency conversion, unlike anything in the sales tables.

   A RELATED TRAP, carried forward from earlier profiling: sales amounts for JPY
   and KRW are USD-scaled in the source (8,471 rows carry decimals in currencies
   that have no subunit). That defect belongs to the sales fact, not here, but it
   reinforces the same point - price_tier is the only price-like attribute in the
   product hierarchy that is NOT affected by it.

   NO ALLOW-LIST ON price_tier - CONSISTENT WITH THE GROUP
   --------------------------------------------------------------------
   Standard / Premium / Ultra are the three values present, and there is
   deliberately no flag asserting membership - same reasoning as V5.1.5
   (reporting_segment) and V5.1.6 (lifecycle_status). A tier is a marketing
   construct and a fourth one is a routine business change, not a defect. NULL is
   flagged; unfamiliar is not.

   variant likewise gets only a null check. With 112 distinct values across 650
   SKUs it is a high-cardinality descriptive attribute, and enumerating it would
   be unmaintainable by construction.

   QUALITY CHECKS
   --------------------------------------------------------------------
   Record-level HARD REJECT: null or blank sku_code. This is the strictest place
   in the hierarchy for that rule, because sku_code is the join key for the sales
   fact - a SKU with no key cannot be joined to revenue at all.

   FLAGGED:
       NULL_MODEL_CODE            FK null or blank - flagged not rejected. At this
                                  level the cascade argument from V5.1.6 is at
                                  its strongest: rejecting a SKU would strand the
                                  sales rows that reference it, trading a lost
                                  fact for a missing dimension attribute.
       MISSING_VARIANT            variant null or blank
       NULL_PRICE_TIER            tier null or blank
       NULL_GLOBAL_LAUNCH_DATE    launch date absent
       IMPLAUSIBLE_LAUNCH_DATE    global_launch_date < 1976-04-01. STATIC
                                  literal - CURRENT_DATE() would force this DT to
                                  FULL refresh (see V5.1.6's header).
       NULL_IS_ACTIVE             is_active null
       NULL_SOURCE_SYSTEM         lineage column null

   The SKU-before-model coherence check (global_launch_date < the model's
   launch_date) is a set-level assertion in VALIDATION, not a row flag, under the
   rule stated in V5.1.7: a DT's flags describe only its own row, and anything
   needing a second table belongs in validation SQL.

   NORMALISATION: sku_code and model_code are UPPER(TRIM(...))'d as join keys -
   sku_code especially, since a casing mismatch here would silently drop revenue
   when the gold fact joins. variant and price_tier are TRIM-only to preserve
   display casing ("Space Black", not "SPACE BLACK").

   CONFIGURATION - identical to V5.1.1, mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG = DOWNSTREAM, REFRESH_MODE = INCREMENTAL (explicit),
     TRANSIENT, INITIALIZE = ON_CREATE

   Verified after creation: refresh_mode INCREMENTAL, refresh_action INCREMENTAL,
   SUCCEEDED, refresh_mode_reason empty, ZERO recommendations, 650 rows /
   650 distinct keys, ZERO dq flags, all __bronze_row_count = 1, zero orphans
   against sv_product_model_master.

   Depends on: V2.1.2 (SILVER schema), V4.4.1/V4.4.2 (bronze product SKU),
               V5.1.7 (parent - validation join only),
               V1.1.4 (MEDALLION_LAYER tag).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_product_sku_master
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver product SKU master: leaf of the global product hierarchy and the grain sales items join on. price_tier is a band, not a price.'
AS
SELECT
    -- Business key, and the join key for the sales fact. A casing mismatch here
    -- would silently drop revenue in gold, hence UPPER+TRIM.
    UPPER(TRIM(b.sku_code))                                 AS sku_code,
    -- FK normalised for the same reason.
    UPPER(TRIM(b.model_code))                               AS model_code,
    -- TRIM only: "Space Black" is a display value, not a code.
    TRIM(b.variant)                                         AS variant,
    -- An ORDINAL BAND, not a monetary amount. See header: this table cannot
    -- value a transaction.
    TRIM(b.price_tier)                                      AS price_tier,
    b.global_launch_date,
    b.is_active,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        -- Flag, never reject: rejecting a SKU strands the sales rows that
        -- reference it. Strongest instance of the V5.1.6 cascade argument.
        IFF(b.model_code IS NULL OR TRIM(b.model_code)='',  'NULL_MODEL_CODE',       NULL),
        IFF(TRIM(b.variant) IS NULL OR TRIM(b.variant)='',  'MISSING_VARIANT',       NULL),
        -- NULL is a defect; an unfamiliar fourth tier is a business change and
        -- is deliberately NOT flagged. See header.
        IFF(TRIM(b.price_tier) IS NULL OR TRIM(b.price_tier)='','NULL_PRICE_TIER',   NULL),
        IFF(b.global_launch_date IS NULL,                   'NULL_GLOBAL_LAUNCH_DATE',NULL),
        -- STATIC literal on purpose: CURRENT_DATE() would force FULL refresh.
        IFF(b.global_launch_date < '1976-04-01'::DATE,      'IMPLAUSIBLE_LAUNCH_DATE',NULL),
        IFF(b.is_active IS NULL,                            'NULL_IS_ACTIVE',        NULL),
        IFF(b.source_system IS NULL,                        'NULL_SOURCE_SYSTEM',    NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.sku_code)))     AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_product_sku_master b
WHERE b.sku_code IS NOT NULL
  AND TRIM(b.sku_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.sku_code))
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_product_sku_master
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SHOW DYNAMIC TABLES LIKE 'SV_PRODUCT_SKU_MASTER' IN SCHEMA {{ database }}.SILVER;
-- Expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.

USE DATABASE {{ database }};
SELECT dt.name, rec.value:"code"::STRING AS rec_code, rec.value:"info"::STRING AS rec_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_PRODUCT_SKU_MASTER')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;
-- Expect ZERO rows.

-- Reconciliation, de-dup guarantee, DQ count, SILVER-to-SILVER FK integrity.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_product_sku_master)                   AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_sku_master)                   AS silver_rows,
       (SELECT COUNT(DISTINCT sku_code) FROM {{ database }}.SILVER.sv_product_sku_master)   AS silver_keys,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_sku_master WHERE __bronze_row_count > 1) AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_sku_master WHERE dq_issue_flags IS NOT NULL) AS dq_flagged,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_sku_master s
          LEFT JOIN {{ database }}.SILVER.sv_product_model_master m ON s.model_code=m.model_code
          WHERE m.model_code IS NULL)                                                       AS orphan_model;
-- Recorded: 650, 650, 650, 0, 0, 0

-- Attribute distribution. No allow-list is enforced on price_tier, so this is
-- the report that would reveal a new tier as NEWS rather than as 650 false
-- positives.
SELECT price_tier, COUNT(*) AS skus, COUNT(DISTINCT model_code) AS models,
       COUNT(DISTINCT variant) AS variants
FROM {{ database }}.SILVER.sv_product_sku_master
GROUP BY 1 ORDER BY 2 DESC;
-- Recorded: Premium 306 | Ultra 255 | Standard 89. 112 distinct variants overall.

-- CROSS-LEVEL COHERENCE - set-level assertion, deliberately NOT a row flag.
-- No SKU may launch globally before its model launched.
SELECT COUNT(*) AS skus_launched_before_model
FROM {{ database }}.SILVER.sv_product_sku_master s
JOIN {{ database }}.SILVER.sv_product_model_master m ON s.model_code = m.model_code
WHERE s.global_launch_date < m.launch_date;
-- Recorded: 0

-- Hierarchy coverage and fan-out: every model must have at least one SKU.
SELECT COUNT(*) AS childless_models
FROM {{ database }}.SILVER.sv_product_model_master m
LEFT JOIN {{ database }}.SILVER.sv_product_sku_master s ON m.model_code = s.model_code
WHERE s.model_code IS NULL;
-- Recorded: 0 (650 SKUs across 111 models, ~5.9 per model)

-- End-to-end hierarchy walk: category -> family -> model -> SKU must preserve
-- the row count at the leaf with no fan-out loss and no duplication.
SELECT COUNT(*) AS skus_reachable_from_category
FROM {{ database }}.SILVER.sv_product_sku_master s
JOIN {{ database }}.SILVER.sv_product_model_master    m ON s.model_code   = m.model_code
JOIN {{ database }}.SILVER.sv_product_family_master   f ON m.family_code  = f.family_code
JOIN {{ database }}.SILVER.sv_product_category_master c ON f.category_code= c.category_code;
-- Recorded: 650. Must equal silver_rows above - if it is lower the hierarchy has
-- a break, if it is higher a parent level has duplicate keys.

-- Anything needing attention (expect ZERO rows)
SELECT sku_code, model_code, variant, price_tier, dq_issue_flags,
       __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_product_sku_master
WHERE dq_issue_flags IS NOT NULL OR __bronze_row_count > 1
ORDER BY sku_code;
