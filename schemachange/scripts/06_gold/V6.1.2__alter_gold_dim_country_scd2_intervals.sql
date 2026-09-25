/* ---------------------------------------------------------------------------
   V6.1.2 - dim_country: close SCD-2 intervals (TRUE SCD-2)

   Upgrades V6.1.1's dimension from SCD-2 *shape* to SCD-2 *behaviour*, now that
   V5.2.1 makes silver preserve record versions.

   WHAT CHANGED, AND WHY IT IS NOW POSSIBLE
   --------------------------------------------------------------------
   V6.1.1's header states that a dynamic table cannot implement SCD-2. That is
   still true of GENERATING history - a DT cannot self-reference to close a prior
   version, and CURRENT_DATE is banned from the SELECT list by section 5.

   But the blocker was never the interval arithmetic. It was that silver DISCARDED
   the prior version as a duplicate, so there was no second row to close an
   interval against. V5.2.1 fixed that. With multiple versions arriving,
   closing the intervals is a pure WINDOW FUNCTION over the incoming rows - no
   self-reference, no non-deterministic function:

       valid_to   = COALESCE(LEAD(valid_from) OVER (PARTITION BY country_code
                                                    ORDER BY valid_from) - 1,
                             effective_end_date)
       is_current = valid_from = MAX(valid_from) OVER (PARTITION BY country_code)

   LEAD() and MAX() OVER are both supported for INCREMENTAL refresh. So this is
   genuine SCD-2 inside a dynamic table, achieved by fixing the upstream grain
   rather than by fighting the DT model.

   TWO CORRECTIONS TO V6.1.1
   --------------------------------------------------------------------
   1. valid_to was the source effective_end_date verbatim - always 9999-12-31.
      With versions that is WRONG: every version would claim to be open-ended and
      an as-of join would match MULTIPLE versions per country, silently fanning
      out the fact. Now LEAD-derived, with effective_end_date as the fallback for
      the newest version only.

   2. is_current was (effective_end_date = 9999-12-31). With versions that is
      WRONG for the same reason - it would be TRUE on every version. Now derived
      from MAX(valid_from), which is TRUE on exactly one row per country.

   Neither bug was observable at V6.1.1 time, because silver had exactly one
   version per country. They would have appeared the moment real history arrived -
   as a fact table that silently multiplied rows.

   PROVEN, NOT ASSERTED
   --------------------------------------------------------------------
   The mechanism was verified by simulating a second version read-only (the real
   source still has only one version per country):

     country  valid_from   valid_to_derived  is_current
     UK       2004-06-15   2021-05-31        FALSE
     UK       2021-06-01   9999-12-31        TRUE
     US       1997-11-10   2021-05-31        FALSE
     US       2021-06-01   9999-12-31        TRUE

   Contiguous, non-overlapping, exactly one current version per country.

   WHY THE QUALIFY STAYS
   --------------------------------------------------------------------
   Silver already guarantees one row per (country_code, effective_start_date), so
   the QUALIFY is no longer needed for correctness. It is retained because it is
   what makes Snowflake derive the PRIMARY KEY - verified still present after this
   change:

       SHOW UNIQUE KEYS IN dim_country;
       COUNTRY_CODE  seq 1  SYS_CONSTRAINT_DERIVED_PK  rely = true
       VALID_FROM    seq 2  SYS_CONSTRAINT_DERIVED_PK  rely = true

   Removing the QUALIFY would silently remove the primary key. Because silver
   guarantees the grain, computing LEAD/MAX over the pre-QUALIFY rows is
   equivalent to computing them post-QUALIFY, so keeping QUALIFY top-level costs
   nothing in correctness.

   CARRY-FORWARD FOR FACTS
   --------------------------------------------------------------------
   Any fact joining this dimension MUST use the validity window, not the bare
   code:

       ON  d.country_code = h.country_code
       AND h.transaction_timestamp::DATE BETWEEN d.valid_from AND d.valid_to

   Joining on country_code alone will fan out once a second version exists.

   Mechanism: CREATE OR ALTER - see V5.2.1's header for why this is the second
   documented exception to architectural note 5.
   --------------------------------------------------------------------------- */

CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.GOLD.dim_country (
  country_key              VARCHAR COMMENT 'PRIMARY KEY (by construction, not declared - dynamic tables accept no constraint clause). SHA1_HEX of country_code + valid_from, so it identifies a VERSION of a country, not the country. Deterministic; never a sequence.',
  country_code             VARCHAR COMMENT 'Natural/business key. ISO 3166-1 alpha-2, except UK which should be GB - flagged in dq_issue_flags, not corrected. FK target for sv_sales_header.country_code and sv_store_master.country_code.',
  valid_from               DATE    COMMENT 'SCD-2 validity start, inclusive. Sourced from sv_country_master.effective_start_date. Silver preserves one row per (country_code, effective_start_date), so multiple versions arrive here as multiple rows.',
  valid_to                 DATE    COMMENT 'SCD-2 validity end, inclusive. DERIVED: LEAD(valid_from) - 1 within the country, falling back to the source effective_end_date (9999-12-31) for the newest version. This is what closes prior versions - no CURRENT_DATE needed, so INCREMENTAL refresh is preserved.',
  is_current               BOOLEAN COMMENT 'TRUE for the version with the greatest valid_from per country. DERIVED from MAX(valid_from) OVER (PARTITION BY country_code) - NOT from the 9999-12-31 sentinel, which would mark every version current once history exists.',
  scd_version_hash         VARCHAR COMMENT 'SHA1_HEX digest of all conformed attributes. Lets a consumer detect which attributes changed between two versions of the same country.',
  country_name             VARCHAR COMMENT 'Official country name.',
  iso_alpha3               VARCHAR COMMENT 'ISO 3166-1 alpha-3. Do NOT assert country_code = LEFT(iso_alpha3,2): 12 rows differ and 11 are valid ISO pairs. Rejected rule, see AGENT.md section 7.',
  apple_fiscal_segment     VARCHAR COMMENT 'Apple GEOGRAPHIC fiscal segment (5 values). Unrelated to product reporting_segment despite the similar name - never reconcile the two.',
  primary_language         VARCHAR COMMENT 'Primary language of the country.',
  timezone                 VARCHAR COMMENT 'Representative timezone. Relevant to the 24 sales rows timestamped 2020-01-01 (timezone spillover).',
  market_tier              VARCHAR COMMENT 'Business market tier. No allow-list asserted - a new tier is a business change, not a defect (DQ rule 4).',
  population_millions      NUMBER  COMMENT 'Population in millions.',
  gdp_usd_billions         NUMBER  COMMENT 'GDP in USD billions.',
  ecommerce_supported      BOOLEAN COMMENT 'Whether online sales are supported. Pairs with the ONLINE channel on sv_sales_header.',
  retail_store_supported   BOOLEAN COMMENT 'Whether physical retail is supported.',
  gdpr_applicable          BOOLEAN COMMENT 'GDPR applies. 1,051 customers sit in GDPR countries - relevant to the masking policies still outstanding.',
  country_is_active        BOOLEAN COMMENT 'Source is_active for the country.',
  region_code              VARCHAR COMMENT 'FK to the region grain. LEFT-joined: NULL would mean a missing region, not a dropped country.',
  region_name              VARCHAR COMMENT 'Region name. NULL indicates an unresolved region_code - zero occurrences today.',
  currency_code            VARCHAR COMMENT 'ISO 4217 code. Note: sales amounts are USD-scaled REGARDLESS of this label - cross-currency SUM is invalid until an FX dimension exists (AGENT.md section 7).',
  currency_name            VARCHAR COMMENT 'Currency name.',
  currency_symbol          VARCHAR COMMENT 'Display symbol.',
  currency_minor_unit      NUMBER  COMMENT 'Decimal places (0 for JPY/KRW). Do NOT ROUND() amounts to this - it hides a ~150x scale error behind a type-correct value. Rejected rule, section 7.',
  tax_code                 VARCHAR COMMENT 'FK to the tax grain. Resolved via country_code -> tax_code, NOT by parsing store.tax_jurisdiction_code (section 7).',
  tax_type                 VARCHAR COMMENT 'Tax type, e.g. VAT/GST.',
  tax_rate                 NUMBER  COMMENT 'CURRENT tax rate only. Effective 2020-01-01, i.e. AFTER the 2019 sales period. NEVER recompute historical tax from this - use the transactions own total_tax, which is authoritative. Recomputing 2019 tax fails on 5 countries / 5,609 rows.',
  tax_inclusive_flag       BOOLEAN COMMENT 'Whether the rate is tax-inclusive.',
  dq_issue_flags           VARCHAR COMMENT 'Row-level DQ flags carried from sv_country_master. NULL means no flag.',
  source_system            VARCHAR COMMENT 'Originating source system.'
)
TARGET_LAG   = DOWNSTREAM
WAREHOUSE    = {{ warehouse }}
REFRESH_MODE = INCREMENTAL
COMMENT      = 'Gold country dimension: conforms sv_country_master with region, currency and tax. Grain = one row per (country_code, valid_from). PK country_key is a SHA1_HEX hash, enforced by construction via QUALIFY. TRUE SCD-2: valid_to is closed by LEAD(valid_from)-1 and is_current by MAX(valid_from) per country, so real history is captured as soon as silver delivers a second version.'
AS
SELECT
  SHA1_HEX(c.country_code || '|' || TO_VARCHAR(c.effective_start_date, 'YYYY-MM-DD')) AS country_key,
  c.country_code,
  c.effective_start_date                       AS valid_from,
  /* Close the interval against the NEXT version of this country. Falls back to
     the source end date only for the newest version. */
  COALESCE(
    LEAD(c.effective_start_date) OVER (
      PARTITION BY c.country_code ORDER BY c.effective_start_date) - 1,
    c.effective_end_date)                      AS valid_to,
  /* Exactly one TRUE per country, regardless of what the source end date says. */
  (c.effective_start_date = MAX(c.effective_start_date) OVER (
      PARTITION BY c.country_code))            AS is_current,
  SHA1_HEX(
      NVL(c.country_name,'~')          || '|' || NVL(c.iso_alpha3,'~')
   || '|' || NVL(c.apple_fiscal_segment,'~') || '|' || NVL(c.primary_language,'~')
   || '|' || NVL(c.timezone,'~')       || '|' || NVL(c.market_tier,'~')
   || '|' || NVL(TO_VARCHAR(c.population_millions),'~')
   || '|' || NVL(TO_VARCHAR(c.gdp_usd_billions),'~')
   || '|' || NVL(TO_VARCHAR(c.ecommerce_supported),'~')
   || '|' || NVL(TO_VARCHAR(c.retail_store_supported),'~')
   || '|' || NVL(TO_VARCHAR(c.gdpr_applicable),'~')
   || '|' || NVL(TO_VARCHAR(c.is_active),'~')
   || '|' || NVL(r.region_code,'~')    || '|' || NVL(r.region_name,'~')
   || '|' || NVL(u.currency_code,'~')  || '|' || NVL(u.currency_name,'~')
   || '|' || NVL(u.currency_symbol,'~')
   || '|' || NVL(TO_VARCHAR(u.minor_unit),'~')
   || '|' || NVL(t.tax_code,'~')       || '|' || NVL(t.tax_type,'~')
   || '|' || NVL(TO_VARCHAR(t.tax_rate),'~')
   || '|' || NVL(TO_VARCHAR(t.tax_inclusive_flag),'~')
  )                                            AS scd_version_hash,
  c.country_name,
  c.iso_alpha3,
  c.apple_fiscal_segment,
  c.primary_language,
  c.timezone,
  c.market_tier,
  c.population_millions,
  c.gdp_usd_billions,
  c.ecommerce_supported,
  c.retail_store_supported,
  c.gdpr_applicable,
  c.is_active                                  AS country_is_active,
  r.region_code,
  r.region_name,
  u.currency_code,
  u.currency_name,
  u.currency_symbol,
  u.minor_unit                                 AS currency_minor_unit,
  t.tax_code,
  t.tax_type,
  t.tax_rate,
  t.tax_inclusive_flag,
  c.dq_issue_flags,
  c.source_system
FROM {{ database }}.SILVER.sv_country_master c
LEFT JOIN {{ database }}.SILVER.sv_region_master   r ON r.region_code   = c.region_code
LEFT JOIN {{ database }}.SILVER.sv_currency_master u ON u.currency_code = c.currency_code
LEFT JOIN {{ database }}.SILVER.sv_tax_master      t ON t.tax_code      = c.tax_code
/* Retained for the derived PRIMARY KEY, not for correctness - silver already
   guarantees this grain. See header. */
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY c.country_code, c.effective_start_date
          ORDER BY     c.__file_name, c.__row_number) = 1;


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- REFRESH MODE SURVIVED THE ALTER. This check was MISSING from the first version
-- of this script and the omission was caught only by review. Adding window
-- functions (LEAD, MAX OVER) is a plausible way to lose incremental refresh, so
-- an ALTER that adds them is exactly when section 5's rule applies: requesting
-- INCREMENTAL is not the same as getting it.
SHOW DYNAMIC TABLES LIKE 'dim_country' IN SCHEMA {{ database }}.GOLD;
-- Recorded: refresh_mode = INCREMENTAL, refresh_mode_reason = NULL,
--           configured_refresh_mode = INCREMENTAL, target_lag = DOWNSTREAM

-- EXPECT ONE 'REINITIALIZE' HERE, AND DO NOT MISTAKE IT FOR FULL REFRESH.
-- Changing a dynamic table's definition forces a single rebuild, because the
-- existing materialisation no longer matches the new query. Its statistics look
-- like a full refresh (numDeletedRows 35, numInsertedRows 35) but the MODE is
-- still INCREMENTAL. See AGENT.md section 5.
SELECT refresh_start_time, state, refresh_action, refresh_trigger
FROM   TABLE({{ database }}.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
         NAME => '{{ database }}.GOLD.dim_country'))
ORDER  BY refresh_start_time DESC LIMIT 5;
-- Recorded: 18:21 REINITIALIZE / MANUAL   <- this alter, expected, one-off
--           12:14 INCREMENTAL  / CREATION <- V6.1.1

-- PROOF the table is not stuck in full refresh: with no upstream change an
-- INCREMENTAL table does no work. A FULL table would reprocess all 35 rows.
ALTER DYNAMIC TABLE {{ database }}.GOLD.dim_country REFRESH;
-- Recorded: "No new data", refreshed_dt_count = 0

-- The derived PRIMARY KEY survived adding the window functions. This was the
-- other real risk of the change - window functions can defeat key derivation.
SHOW UNIQUE KEYS IN {{ database }}.GOLD.dim_country;
-- Recorded: COUNTRY_CODE seq 1 / VALID_FROM seq 2, SYS_CONSTRAINT_DERIVED_PK,
--           rely = true. Unchanged from V6.1.1.

-- Grain, currency of versions, and interval closure.
SELECT COUNT(*)                     AS rows_,
       COUNT(DISTINCT country_key)  AS distinct_keys,
       COUNT_IF(is_current)         AS current_rows,
       COUNT(DISTINCT country_code) AS countries,
       MAX(valid_to)                AS max_valid_to
FROM   {{ database }}.GOLD.dim_country;
-- Recorded: 35, 35, 35, 35, 9999-12-31
-- current_rows = countries is the SCD-2 invariant: exactly one current version
-- per country. It holds trivially today (one version each) and is the assertion
-- that will catch a broken LEAD once history exists.

-- Fact joinability unchanged by the SCD-2 upgrade.
SELECT COUNT(*) AS sales_rows_joined
FROM   {{ database }}.SILVER.sv_sales_header h
JOIN   {{ database }}.GOLD.dim_country d
       ON  d.country_code = h.country_code
       AND h.transaction_timestamp::DATE BETWEEN d.valid_from AND d.valid_to;
-- Recorded: 77155 (all of sv_sales_header, no fan-out, no loss)

-- SCD-2 INTEGRITY: no country may have two current versions, and no two versions
-- may overlap. Expect ZERO rows from both.
SELECT country_code, COUNT_IF(is_current) AS current_versions
FROM   {{ database }}.GOLD.dim_country
GROUP  BY country_code
HAVING COUNT_IF(is_current) <> 1;
-- Recorded: 0 rows

SELECT a.country_code, a.valid_from AS a_from, a.valid_to AS a_to,
       b.valid_from AS b_from, b.valid_to AS b_to
FROM   {{ database }}.GOLD.dim_country a
JOIN   {{ database }}.GOLD.dim_country b
       ON  a.country_code = b.country_code
       AND a.country_key <> b.country_key
       AND a.valid_from  <= b.valid_to
       AND b.valid_from  <= a.valid_to;
-- Recorded: 0 rows (no overlapping validity intervals)
