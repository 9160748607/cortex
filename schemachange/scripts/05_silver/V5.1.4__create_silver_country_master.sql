/* ---------------------------------------------------------------------------
   V5.1.4 - Silver country master (dynamic table)

   Fourth and final bronze -> silver transformation in the country-master group,
   completing region -> (currency, tax) -> country. Reuses the pattern from
   V5.1.1 - see that header for de-duplication, deterministic survivor ordering,
   why QUALIFY ROW_NUMBER rather than DISTINCT, and why there is no is_current or
   silver load-timestamp column. Only country-specific reasoning is here.

   Numbered last in the group on purpose: country carries three foreign keys
   (region_code, currency_code, tax_code) and is the join hub, so it reads
   naturally after the three tables it references.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per country_code
     Business key  country_code - ISO 3166-1 alpha-2 (with one exception, below)
     Volume        35 rows, static, 20 source columns - the widest reference
                   table in the group
     Foreign keys  region_code   -> sv_region_master    ZERO orphans
                   currency_code -> sv_currency_master   ZERO orphans
                   tax_code      -> sv_tax_master        ZERO orphans
                   All three verified against SILVER, not bronze - so this is a
                   genuine silver-to-silver integrity check, not a restatement of
                   the bronze result.
     Referenced by customer master, store master, sales header, and product
                   country availability.

     market_tier           Tier1, Tier2
     apple_fiscal_segment  Americas, Europe, Greater China, Japan,
                           Rest of Asia Pacific
                           - Apple's five actual reporting segments, consistent
                             with sv_region_master's five region codes.

   THE ONE REAL DEFECT: country_code 'UK'
   --------------------------------------------------------------------
   'UK' IS NOT A VALID ISO 3166-1 alpha-2 CODE. The standard is 'GB'. The source
   pairs the colloquial 'UK' with the standards-correct alpha-3 'GBR', so it got
   one half right and one half wrong.

   IT IS FLAGGED, NOT REJECTED, and the numbers are why:
       2,400 customers, 5,862 sales rows and 8 stores reference country_code 'UK'
   Rejecting the row would orphan all of that. The rule established in V5.1.2
   holds: hard-reject only what is unusable AS A KEY; 'UK' is a perfectly usable
   key, it is just not the standard one.

   HOW IT IS DETECTED, AND A HEURISTIC THAT WAS TRIED AND REJECTED
   --------------------------------------------------------------------
   The tempting rule is "alpha-2 should be the first two characters of alpha-3":
       WHERE country_code <> LEFT(iso_alpha3,2)
   That returns 12 rows here, and ELEVEN OF THEM ARE CORRECT ISO PAIRS:
       AE/ARE  AT/AUT  CN/CHN  DK/DNK  IE/IRL  IL/ISR
       KR/KOR  MX/MEX  PL/POL  SE/SWE  TR/TUR   all valid
       UK/GBR                                   the only genuine error
   An 11-out-of-12 false-positive rate is worse than no rule - it is the same
   cry-wolf failure as the naive type-drift guard in schema_evolution_or_drift
   (09 section 9.3), which flagged five columns when one was wrong and therefore
   got superseded by a value-level probe.

   So detection is an EXPLICIT KNOWN-EXCEPTION LIST, not a pattern:
       UPPER(TRIM(country_code)) IN ('UK','EL')
   'UK' should be 'GB' and 'EL' should be 'GR' (Greece); both are widely used
   non-standard codes. Extend the list rather than inventing a rule. Verified
   after load: exactly ONE row flagged, and it is UK.

   QUALITY CHECKS - what differs from the earlier scripts
   --------------------------------------------------------------------
   Record-level HARD REJECT (unchanged): null or blank country_code.

   FK NULLS ARE FLAGGED, NOT REJECTED - NULL_REGION_CODE, NULL_CURRENCY_CODE,
   NULL_TAX_CODE. A country with no region is still a valid country, and
   customers and sales reference it; dropping it would orphan facts to fix a
   dimension attribute. Flagging surfaces it without destroying anything. This is
   the same judgement as 'UK' and as the non-ISO currency code in V5.1.2.

   MEASURE RANGE CHECKS, new in this table:
       NONPOSITIVE_POPULATION   population_millions IS NULL OR <= 0
       NONPOSITIVE_GDP          gdp_usd_billions    IS NULL OR <= 0
   A country cannot have zero or negative population or GDP, so either is a
   loading or sourcing error rather than a real value. Note these deliberately
   fold the NULL case into the same flag: for a measure, "absent" and "impossible"
   need the same follow-up, so splitting them would add a flag without adding
   information.

   Boolean columns (ecommerce_supported, retail_store_supported,
   gdpr_applicable) carry NO null flags. All three are complete today, and a NULL
   boolean is adequately visible as a NULL - a flag would be noise.

   NORMALISATION: the four code columns are UPPER(TRIM(...))'d because they are
   join keys and casing drift would silently break the joins to region, currency
   and tax. Descriptive columns (country_name, primary_language, timezone,
   market_tier, apple_fiscal_segment) are TRIM-only - upper-casing them would
   corrupt display values and timezone identifiers, which are case-sensitive
   (Europe/London, not EUROPE/LONDON).

   CONFIGURATION - identical to V5.1.1, mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG = DOWNSTREAM, REFRESH_MODE = INCREMENTAL (explicit),
     TRANSIENT, INITIALIZE = ON_CREATE

   Verified after creation: refresh_mode INCREMENTAL, refresh_action INCREMENTAL,
   SUCCEEDED in 1,134 ms, refresh_mode_reason empty, ZERO recommendations,
   35 rows / 35 distinct keys, exactly 1 dq flag (UK), all
   __bronze_row_count = 1, and zero orphans on all three FKs against silver.

   Depends on: V2.1.2 (SILVER schema), V4.2.1/V4.2.2 (bronze country master),
               V5.1.1 / V5.1.2 / V5.1.3 (the three referenced silver tables -
               required only for the validation joins, not for the DT itself),
               V1.1.4 (MEDALLION_LAYER tag).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_country_master
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver country master: de-duplicated on country_code, with ISO, FK-null and measure-range DQ flags.'
AS
SELECT
    -- Business key. UPPER+TRIM; same expression must appear in QUALIFY below.
    UPPER(TRIM(b.country_code))                             AS country_code,
    TRIM(b.country_name)                                    AS country_name,
    UPPER(TRIM(b.iso_alpha3))                               AS iso_alpha3,
    -- The three FK columns are normalised because casing drift would silently
    -- break the joins to region / currency / tax.
    UPPER(TRIM(b.region_code))                              AS region_code,
    TRIM(b.apple_fiscal_segment)                            AS apple_fiscal_segment,
    UPPER(TRIM(b.currency_code))                            AS currency_code,
    UPPER(TRIM(b.tax_code))                                 AS tax_code,
    -- TRIM only. Upper-casing would corrupt display values, and timezone
    -- identifiers are case-sensitive (Europe/London, not EUROPE/LONDON).
    TRIM(b.primary_language)                                AS primary_language,
    TRIM(b.timezone)                                        AS timezone,
    b.ecommerce_supported,
    b.retail_store_supported,
    TRIM(b.market_tier)                                     AS market_tier,
    b.population_millions,
    b.gdp_usd_billions,
    b.gdpr_applicable,
    b.is_active,
    b.effective_start_date,
    b.effective_end_date,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        -- Explicit known-exception list, NOT a pattern. See header: the
        -- alpha2/alpha3 prefix heuristic is 11/12 false positives.
        IFF(UPPER(TRIM(b.country_code)) IN ('UK','EL'),        'NON_ISO_ALPHA2_CODE',    NULL),
        IFF(LENGTH(UPPER(TRIM(b.country_code))) <> 2,          'NOT_2_CHAR_ALPHA2',      NULL),
        IFF(LENGTH(UPPER(TRIM(b.iso_alpha3))) <> 3,            'NOT_3_CHAR_ALPHA3',      NULL),
        IFF(TRIM(b.country_name) IS NULL OR TRIM(b.country_name)='','MISSING_COUNTRY_NAME',NULL),
        -- FK nulls: flagged, never rejected. Dropping the row would orphan
        -- customers and sales to fix a dimension attribute.
        IFF(b.region_code   IS NULL OR TRIM(b.region_code)='',  'NULL_REGION_CODE',      NULL),
        IFF(b.currency_code IS NULL OR TRIM(b.currency_code)='','NULL_CURRENCY_CODE',    NULL),
        IFF(b.tax_code      IS NULL OR TRIM(b.tax_code)='',     'NULL_TAX_CODE',         NULL),
        -- NULL and impossible folded into one flag: for a measure both need the
        -- same follow-up, so splitting adds a flag without adding information.
        IFF(b.population_millions IS NULL OR b.population_millions <= 0,'NONPOSITIVE_POPULATION',NULL),
        IFF(b.gdp_usd_billions    IS NULL OR b.gdp_usd_billions    <= 0,'NONPOSITIVE_GDP',NULL),
        IFF(TRIM(b.market_tier) IS NULL OR TRIM(b.market_tier)='','NULL_MARKET_TIER',    NULL),
        IFF(b.is_active IS NULL,                               'NULL_IS_ACTIVE',         NULL),
        IFF(b.effective_start_date IS NULL,                    'NULL_EFF_START',         NULL),
        IFF(b.effective_end_date IS NULL,                      'NULL_EFF_END',           NULL),
        IFF(b.effective_end_date < b.effective_start_date,     'INVALID_DATE_RANGE',     NULL),
        IFF(b.source_system IS NULL,                           'NULL_SOURCE_SYSTEM',     NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.country_code)))  AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_country_master b
WHERE b.country_code IS NOT NULL
  AND TRIM(b.country_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.country_code))
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_country_master
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SHOW DYNAMIC TABLES LIKE 'SV_COUNTRY_MASTER' IN SCHEMA {{ database }}.SILVER;
-- Expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.

USE DATABASE {{ database }};
SELECT dt.name, rec.value:"code"::STRING AS rec_code, rec.value:"info"::STRING AS rec_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_COUNTRY_MASTER')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;
-- Expect ZERO rows.

-- Reconciliation, de-dup guarantee, DQ count, and SILVER-to-SILVER FK integrity.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_country_master)                    AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_country_master)                    AS silver_rows,
       (SELECT COUNT(DISTINCT country_code) FROM {{ database }}.SILVER.sv_country_master)  AS silver_keys,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_country_master WHERE __bronze_row_count > 1) AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_country_master WHERE dq_issue_flags IS NOT NULL) AS dq_flagged,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_country_master c
          LEFT JOIN {{ database }}.SILVER.sv_region_master r ON c.region_code=r.region_code
          WHERE r.region_code IS NULL)                                                   AS orphan_region,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_country_master c
          LEFT JOIN {{ database }}.SILVER.sv_currency_master u ON c.currency_code=u.currency_code
          WHERE u.currency_code IS NULL)                                                 AS orphan_currency,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_country_master c
          LEFT JOIN {{ database }}.SILVER.sv_tax_master t ON c.tax_code=t.tax_code
          WHERE t.tax_code IS NULL)                                                      AS orphan_tax;
-- Recorded: 35, 35, 35, 0, 1, 0, 0, 0
-- dq_flagged = 1 is EXPECTED and correct: the UK row. silver_rows must equal
-- silver_keys, and all three orphan counts must be 0.

-- The flagged row, and proof it must not be rejected.
SELECT country_code, iso_alpha3, country_name, dq_issue_flags
FROM {{ database }}.SILVER.sv_country_master
WHERE dq_issue_flags IS NOT NULL;
-- Recorded: UK / GBR / United Kingdom / NON_ISO_ALPHA2_CODE

SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_customer_master WHERE country_code='UK') AS uk_customers,
       (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_header   WHERE country_code='UK') AS uk_sales,
       (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_store_master   WHERE country_code='UK') AS uk_stores;
-- Recorded: 2400, 5862, 8. This is why NON_ISO_ALPHA2_CODE is a flag, not a filter.

-- Segment / region coherence: both must show the same five groupings.
SELECT apple_fiscal_segment, region_code, COUNT(*) AS countries
FROM {{ database }}.SILVER.sv_country_master
GROUP BY 1,2 ORDER BY 1;

-- Anything needing attention beyond the known UK row (expect only UK)
SELECT country_code, dq_issue_flags, __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_country_master
WHERE dq_issue_flags IS NOT NULL OR __bronze_row_count > 1
ORDER BY country_code;
