/* ---------------------------------------------------------------------------
   V5.1.2 - Silver currency master (dynamic table)

   Second bronze -> silver transformation. Reuses the pattern established by
   V5.1.1 (region master) - see that script's header for the full rationale on
   de-duplication, deterministic survivor ordering, why QUALIFY ROW_NUMBER is
   used instead of DISTINCT, and why no is_current or silver load-timestamp
   column exists. Only the currency-specific reasoning is repeated here.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per currency_code
     Business key  currency_code - ISO 4217, natural and stable
     Domain        27 currencies, all valid 3-character ISO codes
     Source        TREASURY_SYS (region master comes from MDM_CORE)
     Type          reference / dimension. As with region, every row is
                   open-ended (2000-01-01 -> 9999-12-31) with one version per
                   key, so effectively SCD1 / current-only today.
     Volume        27 rows, static
     Referenced by br_country_master.currency_code and br_sales_header.currency
                   Verified: ZERO orphans from either against this table.

   minor_unit IS THE MONEY ROUNDING CONTRACT - the important column here
   --------------------------------------------------------------------
   minor_unit is the number of decimal digits the currency actually has:
       0  JPY, KRW          yen and won have no subunit
       2  the other 25      cents, pence, paise etc.
   ISO 4217 also allows 3 (BHD, KWD, OMR) and 4 (CLF), which is why the DQ
   range check below accepts 0-4 rather than just 0 and 2 - the current data
   happens to contain only 0 and 2, but rejecting 3 or 4 would be wrong.

   DOWNSTREAM FINDING, RECORDED HERE BECAUSE THIS TABLE IS WHAT DETECTS IT:
   8,471 rows in BRONZE.br_sales_header carry decimal amounts in currencies
   that cannot represent them.

       currency  minor_unit  sales_rows  rows_violating_minor_unit  max_net_total
       JPY       0           6,843       6,767                      4,830.86
       KRW       0           1,718       1,704                      4,382.48

   Detected with:
       SUM(IFF(h.net_total <> ROUND(h.net_total, c.minor_unit),1,0))

   The magnitudes are wrong too - a Japanese iPhone is roughly 150,000 JPY, not
   4,830 - so the producer generated every amount on a USD scale and simply
   relabelled the currency. Both symptoms have one cause upstream.

   THIS IS NOT CURRENCY MASTER'S PROBLEM TO FIX. Currency master is clean and
   correct; rounding or rejecting sales amounts here would be the wrong layer.
   The fix belongs in the sales silver/gold layer, where minor_unit should be
   joined in and used either to ROUND() the amounts or to raise a DQ flag.
   Recorded here so the control is not forgotten when those tables are built.

   QUALITY CHECKS - what differs from V5.1.1
   --------------------------------------------------------------------
   Record-level HARD REJECT (unchanged): null or blank currency_code. A
   dimension row with no business key is unusable.

   NON_ISO_3_CHAR_CODE is FLAGGED, NOT REJECTED. A 4-character code is
   non-standard but still a perfectly usable join key, and both
   br_country_master and br_sales_header reference it. Rejecting such a row
   would orphan real sales rows - strictly worse than passing it through
   marked. The rule stays: reject only what is unusable AS A KEY.

   MISSING_CURRENCY_SYMBOL is informational. Some currencies have no widely
   used symbol, so its absence is not necessarily a defect - but it matters for
   any UI that formats amounts, so it is worth surfacing rather than ignoring.

   Currency-specific flags added on top of the V5.1.1 set:
       NON_ISO_3_CHAR_CODE       code length <> 3
       MISSING_CURRENCY_SYMBOL   no display symbol
       NULL_MINOR_UNIT           no rounding contract available
       MINOR_UNIT_OUT_OF_RANGE   outside the ISO 4217 range of 0-4

   All flags are NULL on current data; all 27 rows are clean.

   ENCODING NOTE: currency_symbol holds multi-byte characters
   (EUR, GBP, INR, JPY, KRW symbols). Verified intact after load, which is
   worth checking explicitly because the CSV ingestion path emits encoding
   warnings and a mis-decoded symbol column would be easy to miss.

   CONFIGURATION - identical to V5.1.1 and mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG   = DOWNSTREAM
     REFRESH_MODE = INCREMENTAL   explicit, so an un-incrementalizable query
                                  ERRORS rather than silently costing more
     TRANSIENT, INITIALIZE = ON_CREATE

   Verified after creation: refresh_mode = INCREMENTAL, refresh_mode_reason
   empty, scheduling_state ACTIVE, 27 rows, 27 distinct keys, all
   dq_issue_flags NULL, all __bronze_row_count = 1, ZERO recommendations
   emitted, and zero orphans from country master or sales header.

   The DOWNSTREAM / retention caveats in V5.1.1 apply equally: with no gold
   consumer this table will not refresh on a clock, and the SILVER schema's
   1-day retention can force a full reinitialization after a long idle gap.

   Depends on: V2.1.2 (SILVER schema), V4.2.1/V4.2.2 (bronze currency master),
               V1.1.4 (MEDALLION_LAYER tag).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_currency_master
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver currency master: de-duplicated on currency_code, trimmed and cased, with ISO and minor-unit DQ flags.'
AS
SELECT
    -- Cleaned business key. Same expression must appear in QUALIFY below.
    UPPER(TRIM(b.currency_code))                            AS currency_code,
    TRIM(b.currency_name)                                   AS currency_name,
    -- Multi-byte symbols; TRIM only, never UPPER.
    TRIM(b.currency_symbol)                                 AS currency_symbol,
    -- The money rounding contract. Carried through untouched.
    b.minor_unit,
    b.is_active,
    b.effective_start_date,
    b.effective_end_date,
    -- Renamed: the SOURCE system's timestamp, not a silver load time.
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        -- Flagged, not rejected: a non-3-char code is still a usable join key,
        -- and country/sales rows depend on it.
        IFF(LENGTH(UPPER(TRIM(b.currency_code))) <> 3,          'NON_ISO_3_CHAR_CODE',     NULL),
        IFF(TRIM(b.currency_name) IS NULL OR TRIM(b.currency_name)='','MISSING_CURRENCY_NAME',NULL),
        IFF(TRIM(b.currency_symbol) IS NULL OR TRIM(b.currency_symbol)='','MISSING_CURRENCY_SYMBOL',NULL),
        IFF(b.minor_unit IS NULL,                              'NULL_MINOR_UNIT',         NULL),
        -- ISO 4217 permits 0-4 (3 for BHD/KWD/OMR, 4 for CLF), so the range is
        -- deliberately wider than the 0 and 2 present today.
        IFF(b.minor_unit < 0 OR b.minor_unit > 4,               'MINOR_UNIT_OUT_OF_RANGE', NULL),
        IFF(b.is_active IS NULL,                               'NULL_IS_ACTIVE',          NULL),
        IFF(b.effective_start_date IS NULL,                    'NULL_EFF_START',          NULL),
        IFF(b.effective_end_date IS NULL,                      'NULL_EFF_END',            NULL),
        IFF(b.effective_end_date < b.effective_start_date,     'INVALID_DATE_RANGE',      NULL),
        IFF(b.source_system IS NULL,                           'NULL_SOURCE_SYSTEM',      NULL)
    )),','),'')                                             AS dq_issue_flags,
    -- Duplicate monitoring: > 1 means bronze duplicates were collapsed here.
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.currency_code))) AS __bronze_row_count,
    -- The three bronze technical columns, carried forward unchanged.
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_currency_master b
-- HARD REJECT: no business key means the row cannot be joined to anything.
WHERE b.currency_code IS NOT NULL
  AND TRIM(b.currency_code) <> ''
-- DE-DUPLICATE to one row per key. Top-level QUALIFY keeps this
-- incrementalizable; the ORDER BY is fully deterministic, ending in
-- (__file_name, __row_number) which is unique per bronze row.
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.currency_code))
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag.
   ENVIRONMENT, COST_CENTER and CHARGEBACK_OWNER inherit from the database
   (V2.1.3); MEDALLION_LAYER is set per object. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_currency_master
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Config: expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.
SHOW DYNAMIC TABLES LIKE 'SV_CURRENCY_MASTER' IN SCHEMA {{ database }}.SILVER;

-- Optimality: expect ZERO rows. Any QUALIFY_RANK_* code means the
-- de-duplication is not structured for incremental refresh.
USE DATABASE {{ database }};
SELECT dt.name,
       rec.value:"code"::STRING AS recommendation_code,
       rec.value:"info"::STRING AS recommendation_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_CURRENCY_MASTER')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;

-- Reconciliation, de-dup guarantee, DQ, and referential integrity in one row.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_currency_master)                     AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_currency_master)                     AS silver_rows,
       (SELECT COUNT(DISTINCT currency_code) FROM {{ database }}.SILVER.sv_currency_master) AS silver_distinct_keys,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_currency_master
          WHERE __bronze_row_count > 1)                                                    AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_currency_master
          WHERE dq_issue_flags IS NOT NULL)                                                AS rows_with_dq_issues,
       (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_country_master c
          LEFT JOIN {{ database }}.SILVER.sv_currency_master s ON c.currency_code = s.currency_code
          WHERE s.currency_code IS NULL)                                                   AS country_orphans,
       (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_header h
          LEFT JOIN {{ database }}.SILVER.sv_currency_master s ON h.currency = s.currency_code
          WHERE s.currency_code IS NULL)                                                   AS sales_orphans;
-- Recorded: 27, 27, 27, 0, 0, 0, 0
-- silver_rows must equal silver_distinct_keys - that is the de-dup guarantee.

-- minor_unit domain check, and the multi-byte symbol check.
SELECT minor_unit, COUNT(*) AS currencies,
       LISTAGG(currency_code, ', ') WITHIN GROUP (ORDER BY currency_code) AS codes
FROM {{ database }}.SILVER.sv_currency_master
GROUP BY minor_unit ORDER BY minor_unit;
-- Recorded: 0 -> JPY, KRW (2 currencies) | 2 -> the other 25

SELECT currency_code, currency_name, currency_symbol, minor_unit, dq_issue_flags
FROM {{ database }}.SILVER.sv_currency_master
WHERE currency_code IN ('USD','JPY','KRW','EUR','GBP','INR')
ORDER BY currency_code;
-- Symbols must render as the correct multi-byte characters, not mojibake.

-- Anything needing attention (expect zero rows on current data)
SELECT currency_code, dq_issue_flags, __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_currency_master
WHERE dq_issue_flags IS NOT NULL
   OR __bronze_row_count > 1
ORDER BY currency_code;

/* ---------------------------------------------------------------------------
   CARRY-FORWARD CONTROL for the sales silver/gold layer.
   Re-run this after the sales tables exist; it is the check that surfaced the
   8,471 violating rows recorded in the header.
   --------------------------------------------------------------------------- */
SELECT c.currency_code, c.minor_unit, COUNT(*) AS sales_rows,
       SUM(IFF(h.net_total <> ROUND(h.net_total, c.minor_unit),1,0)) AS rows_violating_minor_unit
FROM {{ database }}.BRONZE.br_sales_header h
JOIN {{ database }}.SILVER.sv_currency_master c ON h.currency = c.currency_code
GROUP BY 1,2
HAVING SUM(IFF(h.net_total <> ROUND(h.net_total, c.minor_unit),1,0)) > 0
ORDER BY rows_violating_minor_unit DESC;
-- Recorded: JPY 6,767 and KRW 1,704 violating rows.
