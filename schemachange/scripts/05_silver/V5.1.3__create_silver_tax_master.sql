/* ---------------------------------------------------------------------------
   V5.1.3 - Silver tax master (dynamic table)

   Third bronze -> silver transformation. Reuses the pattern established by
   V5.1.1 (region master) - see that header for the full rationale on
   de-duplication, deterministic survivor ordering, why QUALIFY ROW_NUMBER is
   used instead of DISTINCT, and why no is_current or silver load-timestamp
   column exists. Only tax-specific reasoning is repeated here.

   NUMBERED BEFORE COUNTRY DELIBERATELY. Both read only from bronze, so there is
   no technical ordering requirement - but country references tax_code, and
   building the referenced table first keeps the script sequence readable as the
   hierarchy it actually is: region -> (currency, tax) -> country.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per tax_code
     Business key  tax_code, e.g. UK_VAT_STD, US_SALES_TAX, JP_VAT_STD
     Domain        35 codes across 7 tax types
     Volume        35 rows, static
     Referenced by br_country_master.tax_code - ZERO orphans, verified.

     tax_type      codes  rate range     inclusive
     ---------------------------------------------------------
     VAT           25     0.0500-0.2550  all 25 inclusive
     GST            5     0.0500-0.1800  all 5 inclusive
     ICMS           1     0.1700         inclusive
     IVA            1     0.1600         inclusive
     SST            1     0.1000         inclusive
     SALES_TAX      1     0.0700         NOT inclusive
     NONE           1     0.0000         NOT inclusive

   THE DATA IS SEMANTICALLY COHERENT, and that coherence is what the DQ rules
   below encode. tax_inclusive_flag correctly separates US-style sales tax -
   added at the till, so exclusive - from VAT/GST-style, which is baked into the
   shelf price. NONE is 0% and exclusive, which is the only sensible combination.
   These are not arbitrary checks; they are the invariants the source currently
   honours, so a future violation is a genuine regression.

   QUALITY CHECKS - what differs from the earlier scripts
   --------------------------------------------------------------------
   Record-level HARD REJECT (unchanged): null or blank tax_code.

   Rate range: 0 to 1 inclusive. tax_rate is a DECIMAL FRACTION, not a
   percentage - 0.2550 means 25.5%. A value above 1 would mean someone switched
   to percentage units, which would inflate every tax calculation 100x. Observed
   range is 0.0000-0.2550, comfortably inside.

   Two CROSS-COLUMN consistency rules, which the earlier tables did not need:
       ZERO_RATE_WITH_TAX_TYPE      rate = 0 but type <> 'NONE'
                                    a named tax charging nothing is suspect
       NONZERO_RATE_WITH_NONE_TYPE  rate > 0 but type = 'NONE'
                                    'no tax' charging something is contradictory
   Both clean today. These catch the realistic failure mode where a rate is
   updated but the type is not, or vice versa.

   tax_type is UPPER(TRIM(...))'d because the consistency rules compare it to the
   literal 'NONE'. Casing drift would silently disable those two rules - a quiet
   failure, so the normalisation is load-bearing rather than cosmetic.

   CARRY-FORWARD PROBLEM FOR THE STORE LAYER - recorded here because this is the
   table that exposes it.
   --------------------------------------------------------------------
   br_store_master.tax_jurisdiction_code DOES NOT JOIN to this table.
   ALL 121 store rows are orphans. Verified:

       SELECT COUNT(*) FROM BRONZE.br_store_master s
       LEFT JOIN SILVER.sv_tax_master t ON s.tax_jurisdiction_code = t.tax_code
       WHERE t.tax_code IS NULL;     -> 121

   The two use different vocabularies at different GRAINS:
       store  AE_STD, AU_ACT_STD, CA_BC_STD   sub-national, no tax-type token
       tax    AE_VAT_STD, AU_GST_STD, CA_GST_STD  country-level, type included
   70 distinct store codes vs 35 tax codes. The country prefix IS consistent
   (zero rows fail a prefix match), so this is reconcilable - but NOT by a
   straight join, and not in this table.

   Two consequences for whoever builds sv_store_master:
     1. Joining on the country prefix alone FANS OUT 1->2 for countries with
        more than one tax type, silently duplicating store rows.
     2. Tax master cannot supply a rate at store grain without a decision on how
        to choose among sub-national jurisdictions.
   A mapping table or an explicit tax-jurisdiction dimension is required. Do not
   paper over it with a LEFT JOIN that returns NULL for every store.

   CONFIGURATION - identical to V5.1.1, mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG = DOWNSTREAM, REFRESH_MODE = INCREMENTAL (explicit),
     TRANSIENT, INITIALIZE = ON_CREATE

   Verified after creation: refresh_mode INCREMENTAL, refresh_action INCREMENTAL,
   SUCCEEDED in 1,001 ms, refresh_mode_reason empty, ZERO recommendations,
   35 rows / 35 distinct keys, all dq_issue_flags NULL, all
   __bronze_row_count = 1.

   Depends on: V2.1.2 (SILVER schema), V4.2.1/V4.2.2 (bronze tax master),
               V1.1.4 (MEDALLION_LAYER tag).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_tax_master
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver tax master: de-duplicated on tax_code, with rate-range and rate/type consistency DQ flags.'
AS
SELECT
    UPPER(TRIM(b.tax_code))                                 AS tax_code,
    -- Normalised because the two consistency rules below compare it to 'NONE'.
    -- Casing drift would silently disable those rules.
    UPPER(TRIM(b.tax_type))                                 AS tax_type,
    -- Decimal FRACTION, not a percentage: 0.2550 = 25.5%.
    b.tax_rate,
    -- TRUE for VAT/GST style (price-inclusive), FALSE for US sales tax and NONE.
    b.tax_inclusive_flag,
    b.effective_start_date,
    b.effective_end_date,
    b.is_active,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.tax_type) IS NULL OR TRIM(b.tax_type)='',  'NULL_TAX_TYPE',              NULL),
        IFF(b.tax_rate IS NULL,                               'NULL_TAX_RATE',              NULL),
        -- > 1 would mean someone switched to percentage units: a 100x error.
        IFF(b.tax_rate < 0 OR b.tax_rate > 1,                 'TAX_RATE_OUT_OF_RANGE',      NULL),
        -- Cross-column: a named tax charging nothing.
        IFF(b.tax_rate = 0 AND UPPER(TRIM(b.tax_type)) <> 'NONE', 'ZERO_RATE_WITH_TAX_TYPE', NULL),
        -- Cross-column: 'no tax' charging something.
        IFF(b.tax_rate > 0 AND UPPER(TRIM(b.tax_type))  = 'NONE', 'NONZERO_RATE_WITH_NONE_TYPE', NULL),
        IFF(b.tax_inclusive_flag IS NULL,                     'NULL_INCLUSIVE_FLAG',        NULL),
        IFF(b.is_active IS NULL,                              'NULL_IS_ACTIVE',             NULL),
        IFF(b.effective_start_date IS NULL,                   'NULL_EFF_START',             NULL),
        IFF(b.effective_end_date IS NULL,                     'NULL_EFF_END',               NULL),
        IFF(b.effective_end_date < b.effective_start_date,    'INVALID_DATE_RANGE',         NULL),
        IFF(b.source_system IS NULL,                          'NULL_SOURCE_SYSTEM',         NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.tax_code)))     AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_tax_master b
WHERE b.tax_code IS NOT NULL
  AND TRIM(b.tax_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.tax_code))
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_tax_master
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SHOW DYNAMIC TABLES LIKE 'SV_TAX_MASTER' IN SCHEMA {{ database }}.SILVER;
-- Expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.

USE DATABASE {{ database }};
SELECT dt.name, rec.value:"code"::STRING AS rec_code, rec.value:"info"::STRING AS rec_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_TAX_MASTER')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;
-- Expect ZERO rows.

SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_tax_master)                  AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_tax_master)                  AS silver_rows,
       (SELECT COUNT(DISTINCT tax_code) FROM {{ database }}.SILVER.sv_tax_master)   AS silver_keys,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_tax_master WHERE __bronze_row_count > 1) AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_tax_master WHERE dq_issue_flags IS NOT NULL) AS dq_flagged;
-- Recorded: 35, 35, 35, 0, 0.  silver_rows must equal silver_keys.

-- Rate / type coherence. Only SALES_TAX and NONE should be exclusive.
SELECT tax_type, COUNT(*) AS codes, MIN(tax_rate) AS min_rate, MAX(tax_rate) AS max_rate,
       SUM(IFF(tax_inclusive_flag,1,0)) AS inclusive_codes
FROM {{ database }}.SILVER.sv_tax_master
GROUP BY tax_type ORDER BY tax_type;

-- Anything needing attention (expect zero rows)
SELECT tax_code, tax_type, tax_rate, dq_issue_flags, __bronze_row_count
FROM {{ database }}.SILVER.sv_tax_master
WHERE dq_issue_flags IS NOT NULL OR __bronze_row_count > 1
ORDER BY tax_code;

/* ---------------------------------------------------------------------------
   CARRY-FORWARD CONTROL for the store layer. Re-run when sv_store_master is
   built; it must return 0, not 121.
   --------------------------------------------------------------------------- */
SELECT COUNT(*) AS store_rows_with_unmatched_tax_jurisdiction
FROM {{ database }}.BRONZE.br_store_master s
LEFT JOIN {{ database }}.SILVER.sv_tax_master t
       ON s.tax_jurisdiction_code = t.tax_code
WHERE t.tax_code IS NULL;
-- Recorded: 121 of 121. Grain mismatch, see header. Needs a mapping, not a join.
