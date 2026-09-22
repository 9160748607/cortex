/* ---------------------------------------------------------------------------
   V5.1.9 - Silver product country availability (dynamic table)

   Fifth and final script in the product-master group, and the only BRIDGE table
   in it: category -> family -> model -> sku -> COUNTRY AVAILABILITY. It resolves
   the many-to-many between the product hierarchy (V5.1.5 - V5.1.8) and the
   geography hierarchy (V5.1.1 - V5.1.4), so it is numbered last because it is
   the only table in the layer with TWO parent chains.

   See V5.1.1 for the shared de-duplication and survivor-ordering conventions and
   V5.1.5 for the dependency-order rule. Only availability-specific reasoning is
   recorded here.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per (sku_code, country_code) - COMPOSITE KEY, the
                   first in this layer. Every other silver table so far has a
                   single-column business key.
     Volume        22,750 rows - by a wide margin the largest silver table built
                   so far (previous largest: 650). Still small, but this is the
                   first one where the de-duplication window does real work.
     Foreign keys  sku_code     -> sv_product_sku_master   ZERO orphans
                   country_code -> sv_country_master       ZERO orphans
                   Both verified against SILVER, not bronze - the first table in
                   the layer to be validated across BOTH hierarchies.
     Referenced by the gold product-availability dimension / bridge.

   THE GRAIN IS A COMPLETE CARTESIAN PRODUCT: 650 x 35 = 22,750
   --------------------------------------------------------------------
   Every SKU is listed against every country, min = max = 35 countries per SKU,
   and is_available is TRUE on all 22,750 rows. There is not one unavailable
   combination.

   This is worth stating plainly because it makes the table CURRENTLY
   INFORMATION-FREE AS A FILTER: joining it to restrict a sales query to
   "available products" cannot remove a single row, and any apparent effect of
   such a join would be fan-out, not filtering. It is a property of generated
   source data - the same class of finding as sales header:item being exactly 1:1
   (max line_number = 1), recorded during bronze profiling.

   The table is still built, and built properly, for two reasons. It carries
   local_part_number and the local launch / discontinue dates, which exist
   NOWHERE ELSE - those are genuine per-country attributes and are the real
   payload. And the moment the source reflects reality, is_available becomes
   selective; the DT then needs no change.

   IS_AVAILABLE THEREFORE GETS NO "ALL TRUE" FLAG, for the reason given in
   V5.1.7: a flag that fires on 100% (or 0%) of rows conveys nothing. Its uniform
   value is asserted in validation instead, where a future change shows up as a
   shift in a number rather than as 22,750 new flags.

   THE local_part_number FINDING - INVESTIGATED AND RULED CORRECT
   --------------------------------------------------------------------
   22,750 rows carry only 19,500 DISTINCT local_part_number values. 2,600 part
   numbers are each used more than once, covering 5,850 rows, with a maximum
   reuse of 3.

   That looks like a duplicate-key defect, and it is NOT one. The evidence:
     - Reuse NEVER crosses SKUs. Every duplicated part number maps to exactly
       one sku_code (reused_across_skus = 0), so the part number never becomes
       ambiguous about WHICH PRODUCT it identifies.
     - Reuse is ALWAYS within a single region. All 2,600 duplicated part numbers
       resolve to exactly one region_code when joined through sv_country_master
       (cross_region = 0, tested explicitly).
     - The suffixes are Apple's regional codes - ZD/A, EX/A, AB/A, CB/A and so
       on. Apple part numbers are REGION-specific, not country-specific: one
       ZD/A part legitimately serves several European countries.

   So local_part_number is unique at (sku, region) and not at (sku, country), and
   that is the correct real-world design rather than a loading error. NO FLAG IS
   RAISED. This follows the precedent set in V5.1.4, where the alpha2/alpha3
   prefix heuristic was tested, found to be 11/12 false positives, and discarded
   in favour of an explicit exception list - a candidate rule that has been
   disproved should be documented and dropped, not implemented defensively.

   What IS enforced is the real uniqueness requirement: the COMPOSITE KEY
   (sku_code, country_code), guaranteed by the QUALIFY window below and asserted
   in validation. That is the key the grain actually depends on.

   QUALITY CHECKS
   --------------------------------------------------------------------
   Record-level HARD REJECT: EITHER key part null or blank. Stricter than the
   single-key tables by necessity - half a composite key cannot identify a row,
   cannot be de-duplicated deterministically, and cannot be joined to either
   parent.

   FLAGGED:
       MISSING_LOCAL_PART_NUMBER   part number null or blank. Complete today.
       NULL_LOCAL_LAUNCH_DATE      local launch absent. Complete today.
       INVALID_LOCAL_DATE_RANGE    local_discontinue_date < local_launch_date.
                                   Dormant - local discontinue dates are null
                                   throughout, consistent with every model being
                                   live (V5.1.7). Kept for the same reason:
                                   costless while dormant, essential later.
       NULL_IS_AVAILABLE           is_available null. Note: null, NOT false -
                                   false is a legitimate business state and would
                                   be the whole point of the table.
       NULL_SOURCE_SYSTEM          lineage column null

   As in V5.1.7, there is NO null flag on local_discontinue_date: open-ended is
   the correct state for a product still being sold in a market.

   Cross-table coherence (a local launch preceding the SKU's global launch, which
   would mean a country shipped before the product existed) is asserted in
   VALIDATION, not flagged - the rule from V5.1.7 holds: a DT's flags describe
   only its own row, and anything needing a second table is a set-level
   assertion. That check matters more here than anywhere else in the group, since
   this is the only table whose dates are subordinate to another table's dates.

   NORMALISATION: both key columns are UPPER(TRIM(...))'d, and the SAME
   expressions are repeated in the QUALIFY partition - they must match exactly or
   de-duplication silently operates on a different grain than the projection.
   local_part_number is UPPER(TRIM(...))'d too: it is an identifier, matched
   exactly by downstream systems, so casing drift would fragment it. The local
   dates need no normalisation.

   CONFIGURATION - identical to V5.1.1, mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG = DOWNSTREAM, REFRESH_MODE = INCREMENTAL (explicit),
     TRANSIENT, INITIALIZE = ON_CREATE

   Verified after creation: refresh_mode INCREMENTAL, refresh_action INCREMENTAL,
   SUCCEEDED, refresh_mode_reason empty, ZERO recommendations, 22,750 rows /
   22,750 distinct composite keys, ZERO dq flags, all __bronze_row_count = 1,
   zero orphans against BOTH sv_product_sku_master and sv_country_master.

   Depends on: V2.1.2 (SILVER schema), V4.4.1/V4.4.2 (bronze availability),
               V5.1.8 and V5.1.4 (both parents - validation joins only),
               V1.1.4 (MEDALLION_LAYER tag).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_product_country_availability
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver product country availability: bridge between product and geography, composite key (sku_code, country_code). Part numbers are unique per region, not per country - by design.'
AS
SELECT
    -- COMPOSITE business key. Both parts UPPER+TRIM, and both expressions are
    -- repeated verbatim in the QUALIFY partition below - they must match or
    -- de-duplication operates on a different grain than the projection.
    UPPER(TRIM(b.sku_code))                                 AS sku_code,
    UPPER(TRIM(b.country_code))                             AS country_code,
    -- An identifier matched exactly downstream, so normalised. Legitimately
    -- REUSED across countries within one region - see header, this is not a
    -- defect and is not flagged.
    UPPER(TRIM(b.local_part_number))                        AS local_part_number,
    -- The real payload of this table: per-country dates that exist nowhere else.
    b.local_launch_date,
    b.local_discontinue_date,
    b.is_available,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.local_part_number) IS NULL OR TRIM(b.local_part_number)='','MISSING_LOCAL_PART_NUMBER',NULL),
        IFF(b.local_launch_date IS NULL,                    'NULL_LOCAL_LAUNCH_DATE',  NULL),
        -- Deliberately NO null flag on local_discontinue_date: open-ended is the
        -- correct state for a product still sold in a market (cf. V5.1.7).
        -- Dormant today, becomes the main guard once withdrawals are recorded.
        IFF(b.local_discontinue_date IS NOT NULL
            AND b.local_discontinue_date < b.local_launch_date,'INVALID_LOCAL_DATE_RANGE',NULL),
        -- NULL, not FALSE. FALSE is a legitimate business state and is in fact
        -- the entire purpose of this table.
        IFF(b.is_available IS NULL,                         'NULL_IS_AVAILABLE',       NULL),
        IFF(b.source_system IS NULL,                        'NULL_SOURCE_SYSTEM',      NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.sku_code)), UPPER(TRIM(b.country_code))) AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_product_country_availability b
-- BOTH key parts required: half a composite key identifies nothing.
WHERE b.sku_code IS NOT NULL
  AND TRIM(b.sku_code) <> ''
  AND b.country_code IS NOT NULL
  AND TRIM(b.country_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.sku_code)), UPPER(TRIM(b.country_code))
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_product_country_availability
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SHOW DYNAMIC TABLES LIKE 'SV_PRODUCT_COUNTRY_AVAILABILITY' IN SCHEMA {{ database }}.SILVER;
-- Expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.

USE DATABASE {{ database }};
SELECT dt.name, rec.value:"code"::STRING AS rec_code, rec.value:"info"::STRING AS rec_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_PRODUCT_COUNTRY_AVAILABILITY')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;
-- Expect ZERO rows.

-- Reconciliation, COMPOSITE-key de-dup guarantee, DQ count, and FK integrity
-- against BOTH parent hierarchies.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_product_country_availability)              AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_country_availability)              AS silver_rows,
       (SELECT COUNT(DISTINCT sku_code || '|' || country_code)
          FROM {{ database }}.SILVER.sv_product_country_availability)                            AS silver_composite_keys,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_country_availability WHERE __bronze_row_count > 1) AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_country_availability WHERE dq_issue_flags IS NOT NULL) AS dq_flagged,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_country_availability a
          LEFT JOIN {{ database }}.SILVER.sv_product_sku_master s ON a.sku_code=s.sku_code
          WHERE s.sku_code IS NULL)                                                             AS orphan_sku,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_product_country_availability a
          LEFT JOIN {{ database }}.SILVER.sv_country_master c ON a.country_code=c.country_code
          WHERE c.country_code IS NULL)                                                         AS orphan_country;
-- Recorded: 22750, 22750, 22750, 0, 0, 0, 0
-- silver_rows must equal silver_composite_keys; the last four must all be 0.

-- Grain shape: confirms the complete cartesian product and the uniform
-- is_available. 650 x 35 = 22,750 with min = max = 35.
SELECT COUNT(DISTINCT sku_code)      AS skus,
       COUNT(DISTINCT country_code)  AS countries,
       MIN(c)                        AS min_countries_per_sku,
       MAX(c)                        AS max_countries_per_sku,
       SUM(av)                       AS rows_available
FROM (SELECT sku_code, COUNT(*) AS c, SUM(IFF(is_available,1,0)) AS av
      FROM {{ database }}.SILVER.sv_product_country_availability GROUP BY sku_code);
-- Recorded: 650, 35, 35, 35, 22750
-- rows_available = 22,750 means the table CANNOT filter anything today. See
-- header: that is a property of the generated source, not a defect, and it is
-- asserted here rather than flagged so a future change shows up as a number.

-- THE PART-NUMBER INVESTIGATION, reproducible. Establishes that reuse never
-- crosses a SKU and never crosses a region, which is why no flag is raised.
WITH dup AS (
  SELECT local_part_number
  FROM {{ database }}.SILVER.sv_product_country_availability
  GROUP BY 1 HAVING COUNT(*) > 1),
scoped AS (
  SELECT a.local_part_number,
         COUNT(DISTINCT a.sku_code)   AS skus,
         COUNT(DISTINCT c.region_code) AS regions,
         COUNT(*)                     AS rows_used
  FROM {{ database }}.SILVER.sv_product_country_availability a
  JOIN dup d ON d.local_part_number = a.local_part_number
  JOIN {{ database }}.SILVER.sv_country_master c ON a.country_code = c.country_code
  GROUP BY 1)
SELECT (SELECT COUNT(DISTINCT local_part_number) FROM {{ database }}.SILVER.sv_product_country_availability) AS distinct_part_numbers,
       COUNT(*)                        AS reused_part_numbers,
       SUM(rows_used)                  AS rows_affected,
       MAX(rows_used)                  AS max_reuse,
       SUM(IFF(skus    > 1,1,0))       AS reused_across_skus,
       SUM(IFF(regions > 1,1,0))       AS reused_across_regions
FROM scoped;
-- Recorded: 19500, 2600, 5850, 3, 0, 0
-- reused_across_skus = 0 and reused_across_regions = 0 are the two numbers that
-- make this correct Apple regional part numbering rather than a defect. If
-- either ever becomes non-zero, THAT is a genuine finding and needs a flag.

-- CROSS-LEVEL COHERENCE - set-level assertion, deliberately NOT a row flag.
-- No country may launch a SKU before that SKU launched globally.
SELECT COUNT(*) AS local_launch_before_global
FROM {{ database }}.SILVER.sv_product_country_availability a
JOIN {{ database }}.SILVER.sv_product_sku_master s ON a.sku_code = s.sku_code
WHERE a.local_launch_date < s.global_launch_date;
-- Recorded: 0

-- FULL END-TO-END WALK across both hierarchies: product (4 levels) x geography
-- (country -> region). Must return exactly silver_rows.
SELECT COUNT(*) AS rows_reachable_across_both_hierarchies
FROM {{ database }}.SILVER.sv_product_country_availability a
JOIN {{ database }}.SILVER.sv_product_sku_master      s ON a.sku_code     = s.sku_code
JOIN {{ database }}.SILVER.sv_product_model_master    m ON s.model_code   = m.model_code
JOIN {{ database }}.SILVER.sv_product_family_master   f ON m.family_code  = f.family_code
JOIN {{ database }}.SILVER.sv_product_category_master g ON f.category_code= g.category_code
JOIN {{ database }}.SILVER.sv_country_master          c ON a.country_code = c.country_code
JOIN {{ database }}.SILVER.sv_region_master           r ON c.region_code  = r.region_code;
-- Recorded: 22750. Lower means a break in one of the six joins; higher means a
-- parent level has duplicate keys.

-- Anything needing attention (expect ZERO rows)
SELECT sku_code, country_code, local_part_number, dq_issue_flags,
       __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_product_country_availability
WHERE dq_issue_flags IS NOT NULL OR __bronze_row_count > 1
ORDER BY sku_code, country_code;
