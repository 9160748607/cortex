/* ---------------------------------------------------------------------------
   V6.1.4 - Gold product-country bridge (dynamic table)

   The fifth product table, sv_product_country_availability, made available in
   gold. It is a BRIDGE, not a dimension, and it is named accordingly.

   WHY IT CANNOT LIVE INSIDE dim_product
   --------------------------------------------------------------------
   It is MANY-TO-MANY: 650 SKUs x 35 countries = 22,750 rows, a complete
   cartesian. Folding it into V6.1.3 would multiply that dimension's grain 35x
   and destroy its one-row-per-SKU contract. A bridge is the correct shape, and
   calling it dim_* would invite exactly the wrong usage.

   ==========================================================================
   *** THIS TABLE FANS OUT 35x IF YOU DO NOT CONSTRAIN country_code ***
   ==========================================================================
   Measured against the fact, not asserted:

       sv_sales_item (current versions)                        77,155
       joined to dim_product on sku_code                       77,155   safe, 1:1
       joined to THIS BRIDGE on sku_code alone              2,700,425   35x FAN-OUT
       joined to THIS BRIDGE on (sku_code, country_code)       77,155   correct

   2,700,425 / 77,155 = exactly 35. The correct join needs country_code, which on
   the fact side lives on sv_sales_header, not sv_sales_item:

       FROM sv_sales_item i
       JOIN sv_sales_header h ON h.transaction_sk = i.transaction_sk
                             AND h.__is_current_version
       JOIN bridge_product_country b ON b.sku_code     = i.sku_code
                                    AND b.country_code = h.country_code

   ==========================================================================
   WHAT THIS TABLE IS AND IS NOT GOOD FOR - A REFINEMENT OF SECTION 7
   ==========================================================================
   AGENT.md section 7 records that sv_product_country_availability "cannot
   filter". That is CORRECT but NARROWER than "carries no information", and the
   distinction decides whether the table is worth having at all.

   CARRIES NO INFORMATION, measured:
       is_available              TRUE on all 22,750 rows, FALSE on ZERO.
                                 Filtering on it removes nothing. Joining this
                                 table to "restrict to available products" only
                                 fans out.
       local_discontinue_date    NULL on all 22,750 rows.

   CARRIES REAL INFORMATION, measured:
       local_launch_date         853 DISTINCT VALUES across 22,750 rows.
                                 Per-(SKU, country) launch timing genuinely
                                 varies, and dim_product cannot express it
                                 because it varies BY COUNTRY.
       local_part_number         Region-scoped part numbers. Reused across
                                 countries within a region, never crossing a SKU
                                 or a region - by design, per section 7.

   So the table exists for local_launch_date and local_part_number. Both useless
   columns are retained for fidelity to source, with comments saying plainly that
   they are useless, so nobody has to rediscover it.

   WHY country_code AND NOT A country_key
   --------------------------------------------------------------------
   dim_country is SCD-2 versioned on (country_code, valid_from) after V6.1.2, so
   there can be MULTIPLE country_key values per country. Storing one of them here
   would silently pin a single version and go stale the moment a country changes.

   Carrying the natural country_code forces the consumer to join on the validity
   window, which is the only correct way to resolve a versioned dimension:

       JOIN dim_country d ON d.country_code = b.country_code
                         AND <some_date> BETWEEN d.valid_from AND d.valid_to

   product_key IS stored, because dim_product has exactly one row per SKU
   (V6.1.3 is SCD-1), so a stored key cannot go stale.

   OTHER NOTES
   --------------------------------------------------------------------
     __is_current_version is filtered in the WHERE, which is safe here because
     this is the only table in the FROM - there is no outer join whose semantics
     could collapse (contrast V6.1.3's header).

     QUALIFY on (sku_code, country_code) establishes the grain and produces the
     derived PRIMARY KEY on both columns.

     No temporal validity. Like dim_product this is version-aware SCD-1: the
     source supplies no effective dates, so there is nothing to close an interval
     against. local_launch_date is a business attribute, NOT a row validity date -
     do not mistake it for valid_from.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.GOLD.bridge_product_country (
  product_country_key    VARCHAR COMMENT 'PRIMARY KEY (by construction). SHA1_HEX of sku_code + country_code.',
  product_key            VARCHAR COMMENT 'FK to GOLD.dim_product.product_key. Safe to join 1:1 - dim_product has exactly one row per SKU.',
  sku_code               VARCHAR COMMENT 'Natural key, product side.',
  country_code           VARCHAR COMMENT 'Natural key, geography side. Deliberately NOT a country_key: dim_country is SCD-2 versioned by (country_code, valid_from), so joining it requires the validity window - ON d.country_code = b.country_code AND <date> BETWEEN d.valid_from AND d.valid_to. A stored country_key would silently pin one version.',
  local_part_number      VARCHAR COMMENT 'Region-scoped part number. Values are reused across countries within a region and never cross a SKU or region - by design, not a defect. AGENT.md section 7.',
  local_launch_date      DATE    COMMENT 'THE REASON THIS TABLE EXISTS. Per-(SKU, country) launch timing - 853 distinct values across 22,750 rows. This is genuine information that dim_product cannot carry, because it varies by country. It is a BUSINESS ATTRIBUTE, not a row validity date.',
  local_discontinue_date DATE    COMMENT 'Local discontinuation. CURRENTLY NULL ON ALL 22,750 ROWS - carries no information today. Do not build logic that assumes it is populated.',
  is_available           BOOLEAN COMMENT '*** CARRIES NO INFORMATION: measured TRUE on all 22,750 rows, FALSE on zero. *** Filtering on it removes no rows; joining this table to "restrict to available products" only fans out 35x. Retained for fidelity to source, NOT for use. AGENT.md section 7.',
  dq_issue_flags         VARCHAR COMMENT 'Row-level DQ flags from sv_product_country_availability. NULL means no flag.',
  source_system          VARCHAR COMMENT 'Originating source system.'
)
TARGET_LAG   = DOWNSTREAM
WAREHOUSE    = {{ warehouse }}
REFRESH_MODE = INCREMENTAL
COMMENT      = 'Gold product-country BRIDGE, not a dimension. Grain = one row per (sku_code, country_code); 22,750 rows = a complete 650 x 35 cartesian. *** JOINING THIS TO A FACT FANS OUT 35x UNLESS YOU CONSTRAIN country_code. *** Its only genuine payload is local_launch_date (853 distinct values) and local_part_number; is_available is TRUE everywhere and filters nothing.'
AS
SELECT
  SHA1_HEX(a.sku_code || '|' || a.country_code) AS product_country_key,
  SHA1_HEX(a.sku_code)                          AS product_key,
  a.sku_code,
  a.country_code,
  a.local_part_number,
  a.local_launch_date,
  a.local_discontinue_date,
  a.is_available,
  a.dq_issue_flags,
  a.source_system
FROM {{ database }}.SILVER.sv_product_country_availability a
WHERE a.__is_current_version = TRUE
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY a.sku_code, a.country_code
          ORDER BY     a.__file_name, a.__row_number) = 1;


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Refresh mode, checked at creation per section 5.
SHOW DYNAMIC TABLES LIKE 'bridge_product_country' IN SCHEMA {{ database }}.GOLD;
-- Recorded: target_lag = DOWNSTREAM, refresh_mode = INCREMENTAL,
--           refresh_mode_reason = NULL, rows = 22750

-- Derived PRIMARY KEY on the composite grain.
SHOW UNIQUE KEYS IN {{ database }}.GOLD.bridge_product_country;
-- Recorded: SKU_CODE seq 1, COUNTRY_CODE seq 2, SYS_CONSTRAINT_DERIVED_PK,
--           rely = true

-- Grain, and the complete-cartesian shape. 650 x 35 = 22,750.
SELECT COUNT(*)                              AS rows_,
       COUNT(DISTINCT product_country_key)   AS keys,
       COUNT(DISTINCT sku_code)              AS skus,
       COUNT(DISTINCT country_code)          AS countries,
       COUNT(DISTINCT local_launch_date)     AS distinct_local_launch,
       COUNT_IF(is_available)                AS available_true,
       COUNT_IF(NOT is_available)            AS available_false,
       COUNT_IF(local_discontinue_date IS NOT NULL) AS discontinue_populated
FROM   {{ database }}.GOLD.bridge_product_country;
-- Recorded: 22750, 22750, 650, 35, 853, 22750, 0, 0
-- available_false = 0 and discontinue_populated = 0 are the measurements behind
-- the "carries no information" comments on those two columns.
-- distinct_local_launch = 853 is the measurement that justifies the table.

-- Referential integrity to both dimensions.
SELECT (SELECT COUNT(*) FROM {{ database }}.GOLD.bridge_product_country b
          WHERE NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_product p
                             WHERE p.product_key = b.product_key))  AS orphan_product,
       (SELECT COUNT(*) FROM {{ database }}.GOLD.bridge_product_country b
          WHERE NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_country d
                             WHERE d.country_code = b.country_code)) AS orphan_country;
-- Recorded: 0, 0

-- ** THE FAN-OUT DEMONSTRATION. ** This is the check that turns the warning in
-- the header from an assertion into a measurement. Run it before letting anyone
-- join this table to a fact.
SELECT
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item
    WHERE __is_current_version)                                       AS fact_rows,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item i
     JOIN {{ database }}.GOLD.dim_product p ON p.sku_code = i.sku_code
    WHERE i.__is_current_version)                                     AS via_dim_product_safe,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item i
     JOIN {{ database }}.GOLD.bridge_product_country b ON b.sku_code = i.sku_code
    WHERE i.__is_current_version)                                     AS bridge_unconstrained_BAD,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item i
     JOIN {{ database }}.SILVER.sv_sales_header h
       ON h.transaction_sk = i.transaction_sk AND h.__is_current_version
     JOIN {{ database }}.GOLD.bridge_product_country b
       ON b.sku_code = i.sku_code AND b.country_code = h.country_code
    WHERE i.__is_current_version)                                     AS bridge_constrained_GOOD;
-- Recorded: 77155, 77155, 2700425, 77155
-- 2700425 / 77155 = exactly 35. Constraining on country_code restores 1:1.

-- Anything needing attention (expect ZERO rows)
SELECT product_country_key, sku_code, country_code, dq_issue_flags
FROM   {{ database }}.GOLD.bridge_product_country
WHERE  dq_issue_flags IS NOT NULL
ORDER  BY sku_code, country_code;
-- Recorded: 0 rows
