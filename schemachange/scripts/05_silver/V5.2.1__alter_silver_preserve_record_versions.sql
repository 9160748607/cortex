/* ---------------------------------------------------------------------------
   V5.2.1 - Preserve record versions in silver (7 master tables)

   THE DEFECT THIS FIXES
   --------------------------------------------------------------------
   Every V5.1.* table de-duplicated on the BUSINESS KEY ALONE:

       QUALIFY ROW_NUMBER() OVER (
                 PARTITION BY UPPER(TRIM(b.country_code))     -- key only
                 ORDER BY ...) = 1

   That cannot distinguish two different things:

       a TRUE DUPLICATE  - the same record redelivered (replayed file, reloaded
                           batch). Collapsing it is correct.
       a NEW VERSION     - the same key with CHANGED attribute values. Collapsing
                           it DESTROYS the change.

   Both collapsed to one survivor, so a changed record was silently discarded in
   silver and gold could never build SCD-2 history - the history was gone before
   gold saw it.

   MEASURED BEFORE THE CHANGE: across all 13 silver tables,
       MAX(__bronze_row_count) = 1  and  COUNT_IF(__bronze_row_count > 1) = 0
   The QUALIFY had never discarded a single row. So this was a LATENT defect, not
   active data loss - nothing had been lost yet, and no backfill is needed. That
   is precisely why it was worth fixing now rather than after the first version
   arrives.

   THE FIX
   --------------------------------------------------------------------
   Add a version discriminator to the partition key. True duplicates still
   collapse; distinct versions now survive:

       PARTITION BY UPPER(TRIM(b.country_code)), b.effective_start_date

   Section 5 requires the partition key to appear in the SELECT list, and it
   already does for every table here. Survivor ORDER BY is unchanged and still
   ends in (__file_name, __row_number) for determinism.

   The same discriminator is added to the COUNT(*) OVER (...) that produces
   __bronze_row_count, so that column now counts duplicates WITHIN a version
   rather than across versions - which is what makes it a useful duplicate
   detector again.

   ==========================================================================
   SCOPE: 7 tables, and why not the other 6
   ==========================================================================
   Version discriminators are NOT uniform across bronze. Measured:

     effective_start_date present (6):
         br_region_master, br_currency_master, br_tax_master,
         br_country_master, br_product_category_master, br_store_master
     updated_at present, no effective dates (1):
         br_customer_master
     NEITHER - only created_at (4):
         br_product_family_master, br_product_model_master,
         br_product_sku_master, br_product_country_availability
     Facts (2):
         br_sales_header, br_sales_item

   THIS SCRIPT CHANGES THE 7 THAT HAVE A REAL DISCRIMINATOR.

   The 4 product tables are DELIBERATELY UNCHANGED. No temporal version exists in
   the source, so there is nothing to partition on. Options when it matters:
   a content hash (preserves distinct observed states but yields no validity
   interval, and A->B->A collapses to two rows), __file_last_modified_ntz as a
   weaker temporal anchor, or fixing the feed to emit effective dates like the
   other six. Deferred as a separate decision - see 05_silver/README.md.

   THE 2 FACT TABLES MUST NEVER BE VERSIONED. A transaction is immutable; it is
   corrected, not versioned. Versioning sv_sales_header would let the same
   transaction_sk appear twice and DOUBLE-COUNT REVENUE, which is the same trap
   section 7 already records for header-vs-item measures. V5.1.12 and V5.1.13 stay
   exactly as they are.

   ==========================================================================
   MECHANISM: CREATE OR ALTER, not CREATE OR REPLACE
   ==========================================================================
   Architectural note 5 bans CREATE OR REPLACE. A dynamic table's definition
   cannot be changed by ALTER, so the usual advice is CREATE OR REPLACE - which
   would drop and rebuild the object, losing grants and change-tracking lineage.

   CREATE OR ALTER DYNAMIC TABLE is used instead. It is declarative and
   idempotent: Snowflake computes the diff and applies it in place. VERIFIED
   non-destructive - after altering sv_region_master, created_on remained
   2026-09-21 (the original creation), so the object identity survived.

   This is a SECOND documented exception to note 5, after R__gold_semantic_view.
   It is a narrower one: CREATE OR ALTER is not destructive, so it honours the
   spirit of note 5 (never lose data or grants) while permitting a definition
   change that IF NOT EXISTS cannot express.

   ALSO VERIFIED to survive the alter, without being restated:
       MEDALLION_LAYER = 'SILVER' tag   (kept - no WITH TAG clause needed)
       TARGET_LAG = DOWNSTREAM
       REFRESH_MODE = INCREMENTAL, refresh_mode_reason = NULL

   ==========================================================================
   DATA IMPACT: NONE TODAY - AND THAT IS THE POINT
   ==========================================================================
   Because no table currently has more than one row per key, adding a
   discriminator to the partition key produces IDENTICAL output. Verified after
   the change - every row count unchanged:

       sv_region_master              5
       sv_currency_master           27
       sv_tax_master                35
       sv_country_master            35
       sv_product_category_master   10
       sv_store_master             121
       sv_customer_master       31,350

   The value is entirely in what it PREVENTS. It will read as a large diff with
   zero row-count change.

   DOWNSTREAM CONSEQUENCES (all handled)
   --------------------------------------------------------------------
     V6.1.2  dim_country now closes SCD-2 intervals with LEAD(valid_from) - 1 and
             derives is_current from MAX(valid_from) per country. Its QUALIFY
             already partitioned on (country_code, effective_start_date), so it
             was forward-compatible.
     V8.1.6  cust_id_unique asserted COUNT(DISTINCT customer_id); that would fail
             the moment a second version landed. Now uses the compound
             (customer_id, source_updated_at) grain.
     Future facts MUST join versioned dimensions on the validity window, not the
             bare code, or they will fan out. Recorded in 06_gold/README.md.

   Not idempotent in the IF NOT EXISTS sense - CREATE OR ALTER is idempotent by
   construction, which is the stronger guarantee.
   --------------------------------------------------------------------------- */


/* ===========================================================================
   1 of 7 - sv_region_master          discriminator: effective_start_date
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_region_master
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver region master: one row per (region_code, effective_start_date) so a changed record is preserved as a new version, not discarded as a duplicate. Trimmed and cased, with DQ flags.'
 AS
SELECT
    UPPER(TRIM(b.region_code))                              AS region_code,
    TRIM(b.region_name)                                     AS region_name,
    b.is_active,
    b.effective_start_date,
    b.effective_end_date,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.region_name) IS NULL OR TRIM(b.region_name)='','MISSING_REGION_NAME',NULL),
        IFF(b.is_active IS NULL,                            'NULL_IS_ACTIVE',     NULL),
        IFF(b.effective_start_date IS NULL,                 'NULL_EFF_START',     NULL),
        IFF(b.effective_end_date IS NULL,                   'NULL_EFF_END',       NULL),
        IFF(b.effective_end_date < b.effective_start_date,  'INVALID_DATE_RANGE', NULL),
        IFF(b.source_system IS NULL,                        'NULL_SOURCE_SYSTEM', NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.region_code)),
                                b.effective_start_date)     AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_region_master b
WHERE b.region_code IS NOT NULL
  AND TRIM(b.region_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.region_code)),
                       b.effective_start_date
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;


/* ===========================================================================
   2 of 7 - sv_currency_master        discriminator: effective_start_date
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_currency_master
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver currency master: one row per (currency_code, effective_start_date) so a changed record is preserved as a new version, not discarded as a duplicate. Trimmed and cased, with ISO and minor-unit DQ flags.'
 AS
SELECT
    UPPER(TRIM(b.currency_code))                            AS currency_code,
    TRIM(b.currency_name)                                   AS currency_name,
    TRIM(b.currency_symbol)                                 AS currency_symbol,
    b.minor_unit,
    b.is_active,
    b.effective_start_date,
    b.effective_end_date,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(LENGTH(UPPER(TRIM(b.currency_code))) <> 3,          'NON_ISO_3_CHAR_CODE',     NULL),
        IFF(TRIM(b.currency_name) IS NULL OR TRIM(b.currency_name)='','MISSING_CURRENCY_NAME',NULL),
        IFF(TRIM(b.currency_symbol) IS NULL OR TRIM(b.currency_symbol)='','MISSING_CURRENCY_SYMBOL',NULL),
        IFF(b.minor_unit IS NULL,                              'NULL_MINOR_UNIT',         NULL),
        IFF(b.minor_unit < 0 OR b.minor_unit > 4,               'MINOR_UNIT_OUT_OF_RANGE', NULL),
        IFF(b.is_active IS NULL,                               'NULL_IS_ACTIVE',          NULL),
        IFF(b.effective_start_date IS NULL,                    'NULL_EFF_START',          NULL),
        IFF(b.effective_end_date IS NULL,                      'NULL_EFF_END',            NULL),
        IFF(b.effective_end_date < b.effective_start_date,     'INVALID_DATE_RANGE',      NULL),
        IFF(b.source_system IS NULL,                           'NULL_SOURCE_SYSTEM',      NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.currency_code)),
                                b.effective_start_date)     AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_currency_master b
WHERE b.currency_code IS NOT NULL
  AND TRIM(b.currency_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.currency_code)),
                       b.effective_start_date
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;


/* ===========================================================================
   3 of 7 - sv_tax_master             discriminator: effective_start_date

   NOTE: versioning does NOT make this table time-variant retroactively. All 35
   rows still start 2020-01-01, after the 2019 sales period. Section 7 stands:
   the transaction's own total_tax remains authoritative for historical tax.
   What changes is that a FUTURE rate change will now be preserved.
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_tax_master
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver tax master: one row per (tax_code, effective_start_date) so a rate change is preserved as a new version, not discarded as a duplicate. Note this table still cannot express a HISTORICAL rate until the source delivers one - the transaction total_tax remains authoritative.'
 AS
SELECT
    UPPER(TRIM(b.tax_code))                                 AS tax_code,
    UPPER(TRIM(b.tax_type))                                 AS tax_type,
    b.tax_rate,
    b.tax_inclusive_flag,
    b.effective_start_date,
    b.effective_end_date,
    b.is_active,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.tax_type) IS NULL OR TRIM(b.tax_type)='',  'NULL_TAX_TYPE',              NULL),
        IFF(b.tax_rate IS NULL,                               'NULL_TAX_RATE',              NULL),
        IFF(b.tax_rate < 0 OR b.tax_rate > 1,                 'TAX_RATE_OUT_OF_RANGE',      NULL),
        IFF(b.tax_rate = 0 AND UPPER(TRIM(b.tax_type)) <> 'NONE', 'ZERO_RATE_WITH_TAX_TYPE', NULL),
        IFF(b.tax_rate > 0 AND UPPER(TRIM(b.tax_type))  = 'NONE', 'NONZERO_RATE_WITH_NONE_TYPE', NULL),
        IFF(b.tax_inclusive_flag IS NULL,                     'NULL_INCLUSIVE_FLAG',        NULL),
        IFF(b.is_active IS NULL,                              'NULL_IS_ACTIVE',             NULL),
        IFF(b.effective_start_date IS NULL,                   'NULL_EFF_START',             NULL),
        IFF(b.effective_end_date IS NULL,                     'NULL_EFF_END',               NULL),
        IFF(b.effective_end_date < b.effective_start_date,    'INVALID_DATE_RANGE',         NULL),
        IFF(b.source_system IS NULL,                          'NULL_SOURCE_SYSTEM',         NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.tax_code)),
                                b.effective_start_date)      AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_tax_master b
WHERE b.tax_code IS NOT NULL
  AND TRIM(b.tax_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.tax_code)),
                       b.effective_start_date
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;


/* ===========================================================================
   4 of 7 - sv_country_master         discriminator: effective_start_date
   Feeds GOLD.dim_country, which is where the SCD-2 intervals get closed.
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_country_master
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver country master: one row per (country_code, effective_start_date) so a changed record is preserved as a new version, not discarded as a duplicate. With ISO, FK-null and measure-range DQ flags.'
 AS
SELECT
    UPPER(TRIM(b.country_code))                             AS country_code,
    TRIM(b.country_name)                                    AS country_name,
    UPPER(TRIM(b.iso_alpha3))                               AS iso_alpha3,
    UPPER(TRIM(b.region_code))                              AS region_code,
    TRIM(b.apple_fiscal_segment)                            AS apple_fiscal_segment,
    UPPER(TRIM(b.currency_code))                            AS currency_code,
    UPPER(TRIM(b.tax_code))                                 AS tax_code,
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
        IFF(UPPER(TRIM(b.country_code)) IN ('UK','EL'),        'NON_ISO_ALPHA2_CODE',    NULL),
        IFF(LENGTH(UPPER(TRIM(b.country_code))) <> 2,          'NOT_2_CHAR_ALPHA2',      NULL),
        IFF(LENGTH(UPPER(TRIM(b.iso_alpha3))) <> 3,            'NOT_3_CHAR_ALPHA3',      NULL),
        IFF(TRIM(b.country_name) IS NULL OR TRIM(b.country_name)='','MISSING_COUNTRY_NAME',NULL),
        IFF(b.region_code   IS NULL OR TRIM(b.region_code)='',  'NULL_REGION_CODE',      NULL),
        IFF(b.currency_code IS NULL OR TRIM(b.currency_code)='','NULL_CURRENCY_CODE',    NULL),
        IFF(b.tax_code      IS NULL OR TRIM(b.tax_code)='',     'NULL_TAX_CODE',         NULL),
        IFF(b.population_millions IS NULL OR b.population_millions <= 0,'NONPOSITIVE_POPULATION',NULL),
        IFF(b.gdp_usd_billions    IS NULL OR b.gdp_usd_billions    <= 0,'NONPOSITIVE_GDP',NULL),
        IFF(TRIM(b.market_tier) IS NULL OR TRIM(b.market_tier)='','NULL_MARKET_TIER',    NULL),
        IFF(b.is_active IS NULL,                               'NULL_IS_ACTIVE',         NULL),
        IFF(b.effective_start_date IS NULL,                    'NULL_EFF_START',         NULL),
        IFF(b.effective_end_date IS NULL,                      'NULL_EFF_END',           NULL),
        IFF(b.effective_end_date < b.effective_start_date,     'INVALID_DATE_RANGE',     NULL),
        IFF(b.source_system IS NULL,                           'NULL_SOURCE_SYSTEM',     NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.country_code)),
                                b.effective_start_date)       AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_country_master b
WHERE b.country_code IS NOT NULL
  AND TRIM(b.country_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.country_code)),
                       b.effective_start_date
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;


/* ===========================================================================
   5 of 7 - sv_product_category_master   discriminator: effective_start_date
   The only product table with a usable discriminator - the other four have none.
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_product_category_master
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver product category master: root of the product hierarchy. One row per (category_code, effective_start_date) so a changed record is preserved as a new version, not discarded as a duplicate.'
 AS
SELECT UPPER(TRIM(b.category_code)) AS category_code, TRIM(b.category_name) AS category_name,
    TRIM(b.reporting_segment) AS reporting_segment, b.is_active, b.effective_start_date, b.effective_end_date,
    b.created_at AS source_created_at, b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.category_name) IS NULL OR TRIM(b.category_name)='','MISSING_CATEGORY_NAME',NULL),
        IFF(TRIM(b.reporting_segment) IS NULL OR TRIM(b.reporting_segment)='','NULL_REPORTING_SEGMENT',NULL),
        IFF(b.is_active IS NULL,'NULL_IS_ACTIVE',NULL),
        IFF(b.effective_start_date IS NULL,'NULL_EFF_START',NULL),
        IFF(b.effective_end_date IS NULL,'NULL_EFF_END',NULL),
        IFF(b.effective_end_date < b.effective_start_date,'INVALID_DATE_RANGE',NULL),
        IFF(b.source_system IS NULL,'NULL_SOURCE_SYSTEM',NULL)
    )),','),'') AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.category_code)), b.effective_start_date) AS __bronze_row_count,
    b.__file_name, b.__row_number, b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_product_category_master b
WHERE b.category_code IS NOT NULL AND TRIM(b.category_code) <> ''
QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.category_code)), b.effective_start_date
  ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
           b.__file_name DESC, b.__row_number DESC) = 1;


/* ===========================================================================
   6 of 7 - sv_store_master           discriminator: effective_start_date

   Section 7 records that store effective_start_date is a LOAD date (one value,
   2026-04-17), not a business date - filtering 2019 sales on it returns zero
   stores. That is exactly what makes it a VALID VERSION DISCRIMINATOR here: a
   new load date means a newly observed version of the record. Business dating
   still comes from store_open_date, unchanged.
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_store_master
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver store master: one row per (store_code, effective_start_date) so a changed record is preserved as a new version, not discarded as a duplicate. Here effective_start_date is a LOAD date, not a business date - which is exactly what makes it a valid version discriminator. Resolve tax via country_code -> sv_country_master.tax_code, NOT by parsing tax_jurisdiction_code. Use store_open_date for business dating.'
 AS
SELECT
    UPPER(TRIM(b.store_code)) AS store_code,
    TRIM(b.store_name) AS store_name,
    UPPER(TRIM(b.country_code)) AS country_code,
    UPPER(TRIM(b.tax_jurisdiction_code)) AS tax_jurisdiction_code,
    UPPER(TRIM(b.format_code)) AS format_code,
    TRIM(b.city) AS city,
    UPPER(TRIM(b.state_code)) AS state_code,
    TRIM(b.postal_code) AS postal_code,
    TRIM(b.address_line1) AS address_line1,
    b.latitude, b.longitude, b.store_open_date, b.store_close_date,
    TRIM(b.lifecycle_status) AS lifecycle_status,
    b.floor_area_sqft, b.annual_rent_usd, b.is_active,
    b.effective_start_date, b.effective_end_date,
    b.created_at AS source_created_at, b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.store_name) IS NULL OR TRIM(b.store_name)='','MISSING_STORE_NAME',NULL),
        IFF(b.country_code IS NULL OR TRIM(b.country_code)='','NULL_COUNTRY_CODE',NULL),
        IFF(SPLIT_PART(UPPER(TRIM(b.tax_jurisdiction_code)),'_',1)<>UPPER(TRIM(b.country_code)),'TAX_JURIS_COUNTRY_MISMATCH',NULL),
        IFF(ARRAY_SIZE(SPLIT(UPPER(TRIM(b.tax_jurisdiction_code)),'_'))=3
            AND SPLIT_PART(UPPER(TRIM(b.tax_jurisdiction_code)),'_',2)<>UPPER(TRIM(b.state_code)),'TAX_JURIS_SUBDIVISION_MISMATCH',NULL),
        IFF(RIGHT(UPPER(TRIM(b.tax_jurisdiction_code)),4)<>'_STD','TAX_JURIS_UNEXPECTED_SUFFIX',NULL),
        IFF((ARRAY_SIZE(SPLIT(UPPER(TRIM(b.tax_jurisdiction_code)),'_'))=3 AND TRIM(b.state_code) IS NULL)
         OR (ARRAY_SIZE(SPLIT(UPPER(TRIM(b.tax_jurisdiction_code)),'_'))=2 AND TRIM(b.state_code) IS NOT NULL),'STATE_JURIS_DISAGREEMENT',NULL),
        IFF(b.latitude IS NULL,'NULL_LATITUDE',NULL),
        IFF(b.longitude IS NULL,'NULL_LONGITUDE',NULL),
        IFF(b.latitude<-90 OR b.latitude>90 OR b.longitude<-180 OR b.longitude>180,'GEO_OUT_OF_RANGE',NULL),
        IFF(b.latitude=0 AND b.longitude=0,'GEO_NULL_ISLAND',NULL),
        IFF(b.floor_area_sqft IS NULL OR b.floor_area_sqft<=0,'NONPOSITIVE_FLOOR_AREA',NULL),
        IFF(b.annual_rent_usd IS NULL OR b.annual_rent_usd<=0,'NONPOSITIVE_RENT',NULL),
        IFF(b.store_open_date IS NULL,'NULL_OPEN_DATE',NULL),
        IFF(b.store_open_date<'1976-04-01'::DATE,'IMPLAUSIBLE_OPEN_DATE',NULL),
        IFF(b.store_close_date IS NOT NULL AND b.store_close_date<b.store_open_date,'INVALID_STORE_DATE_RANGE',NULL),
        IFF(TRIM(b.city) IS NULL OR TRIM(b.city)='','MISSING_CITY',NULL),
        IFF(TRIM(b.postal_code) IS NULL OR TRIM(b.postal_code)='','MISSING_POSTAL_CODE',NULL),
        IFF(TRIM(b.address_line1) IS NULL OR TRIM(b.address_line1)='','MISSING_ADDRESS',NULL),
        IFF(TRIM(b.format_code) IS NULL OR TRIM(b.format_code)='','NULL_FORMAT_CODE',NULL),
        IFF(TRIM(b.lifecycle_status) IS NULL OR TRIM(b.lifecycle_status)='','NULL_LIFECYCLE_STATUS',NULL),
        IFF(b.is_active IS NULL,'NULL_IS_ACTIVE',NULL),
        IFF(b.effective_start_date IS NULL,'NULL_EFF_START',NULL),
        IFF(b.effective_end_date IS NULL,'NULL_EFF_END',NULL),
        IFF(b.source_system IS NULL,'NULL_SOURCE_SYSTEM',NULL)
    )),','),'') AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.store_code)), b.effective_start_date) AS __bronze_row_count,
    b.__file_name, b.__row_number, b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_store_master b
WHERE b.store_code IS NOT NULL AND TRIM(b.store_code) <> ''
QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.store_code)), b.effective_start_date
  ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
           b.__file_name DESC, b.__row_number DESC) = 1;


/* ===========================================================================
   7 of 7 - sv_customer_master        discriminator: updated_at

   THE ONLY TABLE VERSIONED ON updated_at. br_customer_master has no effective
   dates - it is the one source that carries updated_at instead (section 5 already
   noted it as the only table whose survivor ordering leads with updated_at).

   CONSEQUENCE FOR GOLD: there is no effective_end_date to fall back on, so a
   future dim_customer must close intervals purely with
   LEAD(source_updated_at) - and the newest version's valid_to has to be the
   9999-12-31 sentinel supplied by gold, not by the source.

   The survivor ORDER BY drops its leading updated_at DESC, because updated_at is
   now a PARTITION column - ordering by it inside its own partition is a no-op.
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_customer_master
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver customer master: one row per (customer_id, updated_at) so a changed record is preserved as a new version, not discarded as a duplicate. customer_id is a lowercase UUID, NOT upper-cased. This is the only silver table versioned on updated_at rather than effective_start_date - the source provides no effective dates here, so gold must close validity intervals with LEAD(source_updated_at). Contains personal data - masking policies from GOVERNANCE must be attached. Denormalised country_name/region dropped; loyalty_tier sentinel None rewritten to NULL.'
 AS
SELECT
    TRIM(b.customer_id) AS customer_id,
    UPPER(TRIM(b.customer_number)) AS customer_number,
    TRIM(b.first_name) AS first_name,
    TRIM(b.last_name) AS last_name,
    TRIM(b.full_name) AS full_name,
    TRIM(b.gender) AS gender,
    b.date_of_birth,
    LOWER(TRIM(b.email)) AS email,
    TRIM(b.phone_number) AS phone_number,
    TRIM(b.street_address) AS street_address,
    TRIM(b.city) AS city,
    TRIM(b.state_province) AS state_province,
    TRIM(b.postal_code) AS postal_code,
    UPPER(TRIM(b.country_code)) AS country_code,
    TRIM(b.preferred_language) AS preferred_language,
    TRIM(b.customer_segment) AS customer_segment,
    NULLIF(TRIM(b.loyalty_tier), 'None') AS loyalty_tier,
    b.registration_date,
    b.acquisition_year,
    TRIM(b.customer_type) AS customer_type,
    b.is_active,
    b.created_at AS source_created_at,
    b.updated_at AS source_updated_at,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.customer_number) IS NULL OR TRIM(b.customer_number)='','MISSING_CUSTOMER_NUMBER',NULL),
        IFF(TRIM(b.first_name) IS NULL OR TRIM(b.first_name)='','MISSING_FIRST_NAME',NULL),
        IFF(TRIM(b.last_name) IS NULL OR TRIM(b.last_name)='','MISSING_LAST_NAME',NULL),
        IFF(b.country_code IS NULL OR TRIM(b.country_code)='','NULL_COUNTRY_CODE',NULL),
        IFF(TRIM(b.email) IS NULL OR TRIM(b.email)='','MISSING_EMAIL',NULL),
        IFF(TRIM(b.email) IS NOT NULL AND TRIM(b.email) NOT LIKE '%@%','INVALID_EMAIL_FORMAT',NULL),
        IFF(TRIM(b.phone_number) IS NOT NULL AND TRIM(b.phone_number) NOT LIKE '+%','PHONE_NOT_E164',NULL),
        IFF(TRIM(b.phone_number) IS NULL OR TRIM(b.phone_number)='','MISSING_PHONE',NULL),
        IFF(b.date_of_birth IS NULL,'NULL_DATE_OF_BIRTH',NULL),
        IFF(b.date_of_birth < '1900-01-01'::DATE,'IMPLAUSIBLE_DOB',NULL),
        IFF(b.registration_date IS NULL,'NULL_REGISTRATION_DATE',NULL),
        IFF(b.registration_date < b.date_of_birth,'REG_BEFORE_DOB',NULL),
        IFF(b.date_of_birth IS NOT NULL AND b.registration_date IS NOT NULL
            AND DATEDIFF('year',b.date_of_birth,b.registration_date) < 18,'MINOR_AT_REGISTRATION',NULL),
        IFF(b.date_of_birth IS NOT NULL AND b.registration_date IS NOT NULL
            AND DATEDIFF('year',b.date_of_birth,b.registration_date) < 13,'UNDER_13_AT_REGISTRATION',NULL),
        IFF(b.acquisition_year IS NOT NULL AND b.registration_date IS NOT NULL
            AND b.acquisition_year <> YEAR(b.registration_date),'ACQ_YEAR_MISMATCH',NULL),
        IFF(TRIM(b.gender) IS NULL OR TRIM(b.gender)='','NULL_GENDER',NULL),
        IFF(TRIM(b.customer_segment) IS NULL OR TRIM(b.customer_segment)='','NULL_CUSTOMER_SEGMENT',NULL),
        IFF(TRIM(b.street_address) IS NULL OR TRIM(b.street_address)='','MISSING_STREET_ADDRESS',NULL),
        IFF(TRIM(b.city) IS NULL OR TRIM(b.city)='','MISSING_CITY',NULL),
        IFF(TRIM(b.postal_code) IS NULL OR TRIM(b.postal_code)='','MISSING_POSTAL_CODE',NULL),
        IFF(b.is_active IS NULL,'NULL_IS_ACTIVE',NULL),
        IFF(b.source_system IS NULL,'NULL_SOURCE_SYSTEM',NULL)
    )),','),'') AS dq_issue_flags,
    b.source_system,
    COUNT(*) OVER (PARTITION BY TRIM(b.customer_id), b.updated_at) AS __bronze_row_count,
    b.__file_name, b.__row_number, b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_customer_master b
WHERE b.customer_id IS NOT NULL AND TRIM(b.customer_id) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY TRIM(b.customer_id), b.updated_at
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC, b.__row_number DESC) = 1;


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Row counts UNCHANGED. The whole point: adding a discriminator is data-neutral
-- while no duplicate keys exist, so this is a zero-risk migration.
SELECT 'sv_region_master' AS t, COUNT(*) AS rows_, 5 AS expected,
       MAX(__bronze_row_count) AS max_collapse FROM {{ database }}.SILVER.sv_region_master
UNION ALL SELECT 'sv_currency_master', COUNT(*), 27, MAX(__bronze_row_count) FROM {{ database }}.SILVER.sv_currency_master
UNION ALL SELECT 'sv_tax_master', COUNT(*), 35, MAX(__bronze_row_count) FROM {{ database }}.SILVER.sv_tax_master
UNION ALL SELECT 'sv_country_master', COUNT(*), 35, MAX(__bronze_row_count) FROM {{ database }}.SILVER.sv_country_master
UNION ALL SELECT 'sv_product_category_master', COUNT(*), 10, MAX(__bronze_row_count) FROM {{ database }}.SILVER.sv_product_category_master
UNION ALL SELECT 'sv_store_master', COUNT(*), 121, MAX(__bronze_row_count) FROM {{ database }}.SILVER.sv_store_master
UNION ALL SELECT 'sv_customer_master', COUNT(*), 31350, MAX(__bronze_row_count) FROM {{ database }}.SILVER.sv_customer_master
ORDER BY t;
-- Recorded: every rows_ = expected; max_collapse = 1 on all 7.

-- Settings survived the alter WITHOUT being restated. Section 5's rule stands:
-- requesting INCREMENTAL is not the same as getting it - so check.
SHOW DYNAMIC TABLES IN SCHEMA {{ database }}.SILVER;
-- Recorded: 13 of 13 rows show target_lag=DOWNSTREAM, refresh_mode=INCREMENTAL,
--           refresh_mode_reason=NULL. Row counts all unchanged.

-- The MEDALLION_LAYER tag survived without a WITH TAG clause.
SELECT tag_name, tag_value, level
FROM   TABLE({{ database }}.INFORMATION_SCHEMA.TAG_REFERENCES(
         '{{ database }}.SILVER.sv_region_master', 'TABLE'))
WHERE  tag_name = 'MEDALLION_LAYER';
-- Recorded: MEDALLION_LAYER / SILVER / TABLE

-- CREATE OR ALTER was non-destructive: the object was altered in place, not
-- recreated. created_on predates this migration.
SHOW DYNAMIC TABLES LIKE 'sv_region_master' IN SCHEMA {{ database }}.SILVER;
-- Recorded: created_on = 2026-09-21 06:46:04 (original creation, not today)

-- The 4 product tables and 2 facts are deliberately untouched - still one row
-- per business key.
SELECT (SELECT COUNT(*) - COUNT(DISTINCT sku_code) FROM {{ database }}.SILVER.sv_product_sku_master)          AS sku_dupes,
       (SELECT COUNT(*) - COUNT(DISTINCT transaction_sk) FROM {{ database }}.SILVER.sv_sales_header)          AS hdr_dupes,
       (SELECT COUNT(*) - COUNT(DISTINCT transaction_line_id) FROM {{ database }}.SILVER.sv_sales_item)       AS item_dupes;
-- Recorded: 0, 0, 0

-- Downstream DQ still green after the change.
SELECT COUNT(*) AS checks, COUNT_IF(passed) AS passed, COUNT_IF(NOT passed) AS failed
FROM   {{ database }}.COMMON.v_dq_checks;
-- Recorded: 31, 31, 0
