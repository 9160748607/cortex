/* ---------------------------------------------------------------------------
   V6.1.3 - Gold product dimension (dynamic table)

   Conforms the FOUR product hierarchy tables into ONE dimension at SKU grain:

       sv_product_category_master   10 rows   root
       sv_product_family_master     43 rows   -> category_code
       sv_product_model_master     111 rows   -> family_code
       sv_product_sku_master       650 rows   -> model_code   GRAIN DRIVER

   The fifth product table, sv_product_country_availability, is a MANY-TO-MANY
   bridge and cannot be flattened in here - it becomes V6.1.4.

   WHY ONE DIMENSION AND NOT FOUR
   --------------------------------------------------------------------
   The hierarchy is strict, so category/family/model are simply ATTRIBUTES of a
   SKU. Measured before building:

       sku rows                                650
       4-way flattened join                    650      <- zero fan-out
       sku -> model orphans                      0
       model -> family orphans                   0
       family -> category orphans                0
       sv_sales_item -> sku orphans              0

   Four separate dimensions would always join 1:1 and force every consumer into
   three extra joins for no benefit - a snowflake where a star is available. Same
   reasoning that made V6.1.1 one dim_country rather than the originally planned
   dim_geography + dim_currency_and_tax.

   ==========================================================================
   THIS IS SCD-1 WITH VERSION AWARENESS - NOT SCD-2. READ BEFORE ASSUMING.
   ==========================================================================
   V6.1.1/V6.1.2 gave dim_country genuine SCD-2. THAT APPROACH DOES NOT TRANSFER
   HERE, and forcing it would produce something actively wrong.

   dim_country works because its GRAIN DRIVER (sv_country_master) supplies
   effective_start_date, so LEAD() can close intervals. The product grain driver
   is sv_product_sku_master, which supplies NOTHING temporal. Measured:

       sv_product_category_master   effective_start_date   10 distinct, from 1984-01-24
       sv_product_family_master     NONE
       sv_product_model_master      NONE
       sv_product_sku_master        NONE   <- the grain driver
       sv_product_country_availability  NONE

   Only the category level - the ROOT, 10 rows, the least volatile thing in the
   hierarchy - has dates.

   DO NOT USE category.effective_start_date AS valid_from. It would assert that a
   2024 iPhone SKU was valid from 1984-01-24, because that is when the Mac
   category opened. Structurally plausible, semantically nonsense, and it would
   silently corrupt every as-of join built on it. That is why the column is
   carried as category_valid_from and its comment says explicitly that it is
   lineage, not validity.

   WHAT YOU GET INSTEAD: all four sources are version-preserving after
   V5.2.1/V5.2.2 - category temporally, the other three by content hash. This
   dimension takes only the CURRENT version of each level, so it is SCD-1.
   Superseded versions remain queryable in silver via __version_hash, which
   preserves auditability without pretending to a validity interval that does
   not exist.

   Temporal SCD-2 on products requires the product feed to emit
   effective_start_date the way the country feed does. That is a SOURCE change,
   not something gold can synthesise.

   ==========================================================================
   THE __is_current_version FILTER MUST BE IN THE JOIN, NOT THE WHERE
   ==========================================================================
   Three of the four sources carry __is_current_version. Filtering them is
   mandatory: without it, a second version of any model would fan this dimension
   out, break the one-row-per-SKU grain, destroy the derived PRIMARY KEY, and
   then fan out the fact.

   But the predicate MUST sit in the LEFT JOIN ... ON clause:

       LEFT JOIN sv_product_model_master m
              ON m.model_code = s.model_code
             AND m.__is_current_version = TRUE     <- correct

       LEFT JOIN sv_product_model_master m ON m.model_code = s.model_code
       WHERE m.__is_current_version = TRUE          <- WRONG: collapses the
                                                       LEFT JOIN to an INNER
                                                       join, so a SKU whose
                                                       model is missing
                                                       DISAPPEARS

   That second form is the classic outer-join-with-WHERE bug, and here it would
   silently delete SKUs - exactly the trade DQ rule 1 forbids. It is written as
   `= TRUE` rather than a bare boolean because outer joins only support EQUALITY
   predicates for incremental refresh.

   LEFT rather than INNER throughout: all three levels resolve for all 650 SKUs
   today (measured zero NULLs), so INNER would give an identical 650 rows right
   now. LEFT means a future missing parent leaves the SKU present with NULL
   attributes, where the 08_data_quality checks can catch it, instead of deleting
   it from the dimension and orphaning its facts.

   SURROGATE KEY
   --------------------------------------------------------------------
   product_key = SHA1_HEX(sku_code)

   Unlike dim_country.country_key this has NO version component, because there is
   no temporal version to disambiguate. If the product feed ever supplies
   effective dates, the key must become SHA1_HEX(sku_code || '|' || valid_from)
   and every downstream join must move to the validity window - a breaking change,
   flagged here so it is not a surprise.

   Sequences remain unusable (section 5). SHA1_HEX not HASH() - see
   06_gold/README.md.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.GOLD.dim_product (
  product_key            VARCHAR COMMENT 'PRIMARY KEY (by construction, not declared - dynamic tables accept no constraint clause). SHA1_HEX of sku_code. NOTE: unlike dim_country.country_key this carries NO version component, because the product sources supply no effective dates - there is no temporal version to disambiguate. See V6.1.3 header.',
  sku_code               VARCHAR COMMENT 'Natural/business key and the grain. Leaf of the product hierarchy. FK target for sv_sales_item.sku_code - zero orphans measured.',
  model_code             VARCHAR COMMENT 'Parent model. FK to the model level, flattened into this row.',
  family_code            VARCHAR COMMENT 'Grandparent family, via model.',
  category_code          VARCHAR COMMENT 'Great-grandparent category, via family. Root of the hierarchy.',
  variant                VARCHAR COMMENT 'SKU variant, e.g. colour or capacity.',
  price_tier             VARCHAR COMMENT 'Ordinal price BAND, not a price. This table has no price at all - derive price baselines from the fact per (sku_code, currency). AGENT.md section 7.',
  global_launch_date     DATE    COMMENT 'Global SKU launch date. Per-COUNTRY launch timing lives in GOLD.bridge_product_country.local_launch_date, which has 853 distinct values.',
  model_name             VARCHAR COMMENT 'Model display name.',
  model_launch_date      DATE    COMMENT 'Model launch date.',
  model_discontinue_date DATE    COMMENT 'NULL means still sold - an open-ended state, deliberately not flagged as a defect. Agrees with model_lifecycle_status.',
  model_lifecycle_status VARCHAR COMMENT 'Model lifecycle. No allow-list asserted - a new status is a business change, not a defect (DQ rule 4).',
  family_name            VARCHAR COMMENT 'Family display name.',
  family_launch_year     NUMBER  COMMENT 'Family launch year.',
  family_lifecycle_status VARCHAR COMMENT 'Family lifecycle. No allow-list asserted.',
  category_name          VARCHAR COMMENT 'Category display name.',
  reporting_segment      VARCHAR COMMENT 'Product reporting segment - only 4 values because Services has no physical SKU. Do NOT reconcile against dim_country.apple_fiscal_segment, which has 5 GEOGRAPHIC values and is unrelated despite the similar name. AGENT.md section 7.',
  category_valid_from    DATE    COMMENT 'effective_start_date of the CATEGORY version used. Carried for lineage ONLY - it is NOT this row validity. A 2024 SKU can carry a 1984 category date; using this as valid_from would be semantically wrong. See V6.1.3 header.',
  sku_is_active          BOOLEAN COMMENT 'Source is_active for the SKU.',
  model_is_active        BOOLEAN COMMENT 'Source is_active for the model.',
  family_is_active       BOOLEAN COMMENT 'Source is_active for the family.',
  category_is_active     BOOLEAN COMMENT 'Source is_active for the category.',
  scd_version_hash       VARCHAR COMMENT 'SHA1_HEX digest of all conformed attributes across all four levels. Lets a consumer detect that any level changed. NOT a validity interval - see header.',
  dq_issue_flags         VARCHAR COMMENT 'Concatenated row-level DQ flags from all four source levels, prefixed by level. NULL means no flag anywhere in the hierarchy.',
  source_system          VARCHAR COMMENT 'Originating source system, from the SKU level.'
)
TARGET_LAG   = DOWNSTREAM
WAREHOUSE    = {{ warehouse }}
REFRESH_MODE = INCREMENTAL
COMMENT      = 'Gold product dimension: flattens category -> family -> model -> sku into one row per SKU (650 rows, measured zero fan-out). SCD-1 WITH VERSION AWARENESS, not SCD-2: the product sources supply no effective dates, so no validity interval can be derived - only the CURRENT version of each level is included. Superseded versions remain queryable in silver via __version_hash. Per-country availability is a separate object, GOLD.bridge_product_country.'
AS
SELECT
  SHA1_HEX(s.sku_code)                          AS product_key,
  s.sku_code,
  s.model_code,
  m.family_code,
  f.category_code,
  s.variant,
  s.price_tier,
  s.global_launch_date,
  m.model_name,
  m.launch_date                                 AS model_launch_date,
  m.discontinue_date                            AS model_discontinue_date,
  m.lifecycle_status                            AS model_lifecycle_status,
  f.family_name,
  f.launch_year                                 AS family_launch_year,
  f.lifecycle_status                            AS family_lifecycle_status,
  c.category_name,
  c.reporting_segment,
  c.effective_start_date                        AS category_valid_from,
  s.is_active                                   AS sku_is_active,
  m.is_active                                   AS model_is_active,
  f.is_active                                   AS family_is_active,
  c.is_active                                   AS category_is_active,
  SHA1_HEX(
      NVL(s.model_code,'~')||'|'||NVL(s.variant,'~')||'|'||NVL(s.price_tier,'~')
   ||'|'||NVL(TO_VARCHAR(s.global_launch_date),'~')||'|'||NVL(TO_VARCHAR(s.is_active),'~')
   ||'|'||NVL(m.model_name,'~')||'|'||NVL(m.family_code,'~')
   ||'|'||NVL(TO_VARCHAR(m.launch_date),'~')||'|'||NVL(TO_VARCHAR(m.discontinue_date),'~')
   ||'|'||NVL(m.lifecycle_status,'~')||'|'||NVL(TO_VARCHAR(m.is_active),'~')
   ||'|'||NVL(f.family_name,'~')||'|'||NVL(f.category_code,'~')
   ||'|'||NVL(TO_VARCHAR(f.launch_year),'~')||'|'||NVL(f.lifecycle_status,'~')
   ||'|'||NVL(TO_VARCHAR(f.is_active),'~')
   ||'|'||NVL(c.category_name,'~')||'|'||NVL(c.reporting_segment,'~')
   ||'|'||NVL(TO_VARCHAR(c.is_active),'~')
  )                                             AS scd_version_hash,
  NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(s.dq_issue_flags IS NOT NULL, 'SKU:'      || s.dq_issue_flags, NULL),
      IFF(m.dq_issue_flags IS NOT NULL, 'MODEL:'    || m.dq_issue_flags, NULL),
      IFF(f.dq_issue_flags IS NOT NULL, 'FAMILY:'   || f.dq_issue_flags, NULL),
      IFF(c.dq_issue_flags IS NOT NULL, 'CATEGORY:' || c.dq_issue_flags, NULL)
  )),' | '),'')                                 AS dq_issue_flags,
  s.source_system
FROM {{ database }}.SILVER.sv_product_sku_master s
/* __is_current_version in the ON clause, never the WHERE - see header. */
LEFT JOIN {{ database }}.SILVER.sv_product_model_master m
       ON m.model_code = s.model_code
      AND m.__is_current_version = TRUE
LEFT JOIN {{ database }}.SILVER.sv_product_family_master f
       ON f.family_code = m.family_code
      AND f.__is_current_version = TRUE
/* Category is TEMPORALLY versioned (V5.2.1), so it has no __is_current_version
   column. The QUALIFY below picks its latest version by effective_start_date. */
LEFT JOIN {{ database }}.SILVER.sv_product_category_master c
       ON c.category_code = f.category_code
WHERE s.__is_current_version = TRUE
/* Establishes the one-row-per-SKU grain, produces the derived PRIMARY KEY, AND
   selects the newest category version in one pass. */
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY s.sku_code
          ORDER BY     c.effective_start_date DESC NULLS LAST,
                       c.category_code,
                       s.__file_name, s.__row_number) = 1;


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Refresh mode, checked at creation per section 5. Omitting this check is what
-- let a possible regression hide after V6.1.2.
SHOW DYNAMIC TABLES LIKE 'dim_product' IN SCHEMA {{ database }}.GOLD;
-- Recorded: target_lag = DOWNSTREAM, refresh_mode = INCREMENTAL,
--           refresh_mode_reason = NULL, rows = 650

-- Derived PRIMARY KEY. Single column here, because the QUALIFY partitions on
-- sku_code alone - contrast dim_country, which partitions on (code, valid_from).
SHOW UNIQUE KEYS IN {{ database }}.GOLD.dim_product;
-- Recorded: SKU_CODE seq 1, SYS_CONSTRAINT_DERIVED_PK, rely = true

-- Grain, key integrity, and hierarchy resolution. rows = keys = skus is the
-- invariant: one row per SKU, no fan-out from any level.
SELECT COUNT(*)                          AS rows_,
       COUNT(DISTINCT product_key)       AS keys,
       COUNT(DISTINCT sku_code)          AS skus,
       COUNT_IF(product_key IS NULL)     AS null_keys,
       MIN(LENGTH(product_key))          AS key_len,
       COUNT_IF(model_name    IS NULL)   AS unresolved_model,
       COUNT_IF(family_name   IS NULL)   AS unresolved_family,
       COUNT_IF(category_name IS NULL)   AS unresolved_category,
       COUNT_IF(dq_issue_flags IS NOT NULL) AS flagged,
       COUNT(DISTINCT reporting_segment) AS segments
FROM   {{ database }}.GOLD.dim_product;
-- Recorded: 650, 650, 650, 0, 40, 0, 0, 0, 0, 4
-- segments = 4 matches section 7: Services has no physical SKU.

-- No fan-out against the silver grain driver.
SELECT (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_sku_master
         WHERE __is_current_version) AS silver_current_skus,
       (SELECT COUNT(*) FROM {{ database }}.GOLD.dim_product) AS dim_rows;
-- Recorded: 650, 650

-- THE FACT-JOIN REGRESSION TEST. Every fact row must resolve to exactly one
-- product row. A fan-out here would multiply revenue.
SELECT (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item
         WHERE __is_current_version) AS fact_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item i
          JOIN {{ database }}.GOLD.dim_product p ON p.sku_code = i.sku_code
         WHERE i.__is_current_version) AS joined;
-- Recorded: 77155, 77155  (1:1, no fan-out, no loss)

-- Anything needing attention (expect ZERO rows)
SELECT product_key, sku_code, model_code, family_code, category_code, dq_issue_flags
FROM   {{ database }}.GOLD.dim_product
WHERE  dq_issue_flags IS NOT NULL
    OR model_name    IS NULL
    OR family_name   IS NULL
    OR category_name IS NULL
ORDER  BY sku_code;
-- Recorded: 0 rows
