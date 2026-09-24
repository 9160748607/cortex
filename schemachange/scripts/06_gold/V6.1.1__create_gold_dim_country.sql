/* ---------------------------------------------------------------------------
   V6.1.1 - Gold country dimension (dynamic table)

   First gold-layer object. Conforms the four country-related silver tables into
   one dimension:

       sv_country_master   grain and validity driver   35 rows
       sv_region_master    region_code   -> region attributes
       sv_currency_master  currency_code -> currency attributes
       sv_tax_master       tax_code      -> tax attributes

   SUPERSEDES the two scripts 06_gold/README.md originally planned - V6.1.1
   dim_geography and V6.1.2 dim_currency_and_tax - with a single conformed
   dimension. The README has been updated; V6.1.2 is now free.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per (country_code, effective_start_date)
     Natural key   country_code - 35 rows, 35 distinct
     Surrogate key country_key - SHA1_HEX, see below
     Volume        35 rows
     Join fan-out  NONE. Measured: 4-way join returns 35 rows from 35, and all
                   three lookups have ZERO orphans. No country has >1 region,
                   currency or tax code.
     Referenced by sv_sales_header.country_code (77,155 rows), and later
                   sv_store_master.country_code (121 rows)

   ==========================================================================
   SCD-2: THIS TABLE HAS SCD-2 STRUCTURE BUT RETAINS NO HISTORY
   ==========================================================================
   READ THIS BEFORE TREATING valid_from/valid_to AS A HISTORY LOG.

   SCD-2 was requested. A dynamic table CANNOT implement it, for three
   independent reasons:

     1. SCD-2 change detection requires comparing incoming rows to the EXISTING
        TARGET to close the prior version. A dynamic table's definition is a
        query over its SOURCES only - it cannot self-reference.
     2. Stamping a close date requires CURRENT_DATE/CURRENT_TIMESTAMP in the
        SELECT list. AGENT.md section 5 bans that outright: it is
        non-deterministic and forces FULL refresh.
     3. A dynamic table is declarative - it always equals its query over current
        source state. When a source row changes, the DT row changes IN PLACE.
        The prior value is gone. There is nowhere for history to live.

   06_gold/README.md already anticipated this: "Reserve the sequences for any
   procedure-maintained SCD2 dimension added later." Procedure-maintained, not
   dynamic.

   WHAT THIS TABLE DOES INSTEAD: it carries the SCD-2 COLUMN CONTRACT
   (country_key, valid_from, valid_to, is_current, scd_version_hash) and
   PASSES THROUGH the validity intervals the source already provides. So:

     - Downstream facts can already write the correct as-of join predicate, and
       will not need rewriting if real versioning ever arrives.
     - If a source ever delivers a second interval for a country, a new row
       appears automatically with its own country_key. The grain supports it.
     - But nothing here GENERATES history. Measured today:

         all 4 source tables: one row per key, zero extra versions
         every effective_end_date = 9999-12-31 (1 distinct value)
         => 35 rows, all is_current = TRUE

   For true SCD-2 (detecting an attribute change and closing the prior row) a
   stream + task + MERGE into a STANDARD table is required. Reserved as a
   follow-up; see 06_gold/README.md.

   ==========================================================================
   SURROGATE KEY: SHA1_HEX, not a sequence, not HASH()
   ==========================================================================
   country_key = SHA1_HEX(country_code || '|' || valid_from)

   Sequences (COMMON.seq_dim_*, V3.1.3) are UNUSABLE here - non-deterministic,
   and per the Snowflake docs sequences are not supported in dynamic tables at
   all. AGENT.md section 5 records this.

   SHA1_HEX rather than HASH(): an earlier draft of 06_gold/README.md suggested
   HASH(). SHA1_HEX is preferred and the README is now reconciled. HASH() returns
   a signed 64-bit number, so collision probability becomes non-trivial as
   dimensions grow and the value is not stable across Snowflake versions by
   contract. SHA1_HEX returns a deterministic 40-char hex string. Measured: 35
   distinct keys from 35 rows, length 40, zero nulls.

   valid_from is INCLUDED in the key, not just country_code. That is what makes
   the key describe the GRAIN (a version of a country) rather than the entity.
   Without it, a second version would collide with the first.

   ==========================================================================
   PRIMARY KEY / CONSTRAINTS: DECLARED IN COMMENTS, NOT IN DDL
   ==========================================================================
   Table/field comments and constraints were requested. Comments: done, on the
   table and on every column. Constraints: NOT POSSIBLE on a dynamic table.

   Verified against the Snowflake SQL reference:
     - CREATE DYNAMIC TABLE has NO constraint clause. The column definition
       accepts MASKING POLICY, PROJECTION POLICY, TAG, COMMENT and CONTACT -
       there is no inline or out-of-line PRIMARY KEY / UNIQUE / FOREIGN KEY.
     - ALTER DYNAMIC TABLE has no ADD CONSTRAINT action either. Its actions are
       SUSPEND/RESUME, RENAME, SWAP, REFRESH, clustering, column comments, table
       comment, policy/tag, search optimization, storage lifecycle, SET/UNSET.

   So a DECLARED PK is unavailable by construction. Two things substitute, and
   the first turned out stronger than expected:

     1. SNOWFLAKE DERIVES A REAL PRIMARY KEY. Per the docs, QUALIFY ROW_NUMBER()=1
        makes the PARTITION BY columns a system-derived unique key, because the
        filter keeps exactly one row per partition. MEASURED after creation, what
        Snowflake actually materialised is a derived PRIMARY KEY with RELY:

            SHOW UNIQUE KEYS IN dim_country;
            COUNTRY_CODE  seq 1  SYS_CONSTRAINT_DERIVED_PK  rely = true
            VALID_FROM    seq 2  SYS_CONSTRAINT_DERIVED_PK  rely = true

        So the dimension does carry a genuine, catalogue-visible PK constraint -
        it simply cannot be hand-declared. RELY=true additionally means the
        optimizer trusts it for join elimination on downstream facts.

        This is why the QUALIFY is NOT merely defensive de-duplication: it is the
        mechanism that produces the constraint. Removing it would silently remove
        the primary key.
     2. The intended PK and FK relationships are stated in the column comments,
        so the contract is discoverable via DESCRIBE and in the catalog.

   Note the derived key is on (country_code, valid_from) - the declared grain -
   not on country_key. country_key is a deterministic SHA1_HEX of exactly those
   two columns, so it is equivalent in uniqueness; Snowflake just cannot infer
   that through the hash expression.

   If ENFORCED constraints are ever required, they must live on a standard table
   downstream of this one - Snowflake enforces neither PK nor FK on standard
   tables either, so in practice RELY metadata is the ceiling.

   ==========================================================================
   VALIDITY WINDOW: DRIVEN BY COUNTRY ONLY - AND WHY
   ==========================================================================
   valid_from/valid_to come from sv_country_master ALONE. Region, currency and
   tax are joined as ATTRIBUTES, and their own effective dates are deliberately
   ignored.

   THE REJECTED ALTERNATIVE, AND THE MEASUREMENT THAT KILLED IT:

   Textbook SCD-2 conformance would intersect all four intervals -
   GREATEST(all four starts), LEAST(all four ends). That is WRONG here, and
   catastrophically so:

       sv_tax_master.effective_start_date = 2020-01-01 on ALL 35 rows
       the sales data is 2019

   Tax validity begins AFTER the entire sales period. So GREATEST() returns
   2020-01-01 for every country, and the dimension covers no 2019 sale.

       country-driven validity  ->  77,155 of 77,155 sales rows join
       intersect all four       ->         24 of 77,155 sales rows join

   The 24 survivors are exactly the 24 timezone-spillover rows timestamped
   2020-01-01 that AGENT.md section 7 documents. A 99.97% silent loss: the join
   runs clean and returns a confident, nearly-empty answer.

   This is AGENT.md section 7's tax finding in a different costume - "sv_tax_master
   is not time-variant ... the transaction's total_tax is authoritative. Never
   recompute historical tax from the master."

   tax_rate IS carried, because it is legitimately useful for current-state
   reporting. Its column comment says plainly that it must not be used to
   recompute 2019 tax.

   ==========================================================================
   LEFT JOIN, not INNER - deliberate
   ==========================================================================
   All three lookups resolve for all 35 countries today (measured: zero NULLs on
   region_name, currency_name, tax_rate). INNER JOIN would therefore produce an
   identical 35 rows right now.

   LEFT is still correct. With INNER, a future missing region/currency/tax row
   would SILENTLY DELETE a country from the dimension, and every fact joining it
   would lose its geography. That is exactly the trade DQ rule 1 forbids:
   "hard-reject only what is unusable as a key ... deleting a fact to fix a
   dimension attribute is never the right trade." With LEFT, the country
   survives with NULL attributes and the 08_data_quality checks can catch it.

   Outer joins with equality predicates are supported for INCREMENTAL refresh.

   OTHER NOTES
   --------------------------------------------------------------------
     Tagging      NOT tagged explicitly. MEDALLION_LAYER='GOLD' is applied to
                  the GOLD schema in V2.1.4 and tables inherit it - the
                  mechanism V1.1.4 describes for satisfying note 6.
                  Verified: TAG_REFERENCES on SALES_DEV.GOLD returns
                  MEDALLION_LAYER=GOLD at level SCHEMA.
     Bronze meta  __file_name / __row_number / __bronze_row_count are NOT
                  projected. They are lineage for silver, not attributes of a
                  gold dimension. They are still used in the QUALIFY ORDER BY
                  for deterministic survivor selection, which needs no
                  projection.
     dq_issue_flags  carried through. 1 of 35 countries is flagged - the 'UK'
                  non-ISO code from section 7, flagged not rejected because
                  2,400 customers, 5,862 sales and 8 stores depend on it.
     No CURRENT_* anywhere, so INCREMENTAL is achievable. is_current compares
                  against the static 9999-12-31 sentinel, which section 7 records
                  as an intentional and functional SCD sentinel.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.GOLD.dim_country (

  -- Keys and SCD-2 contract
  country_key              VARCHAR COMMENT 'PRIMARY KEY (by construction, not declared - dynamic tables accept no constraint clause). SHA1_HEX of country_code + valid_from, so it identifies a VERSION of a country, not the country. Deterministic; never a sequence.',
  country_code             VARCHAR COMMENT 'Natural/business key. ISO 3166-1 alpha-2, except UK which should be GB - flagged in dq_issue_flags, not corrected. FK target for sv_sales_header.country_code and sv_store_master.country_code.',
  valid_from               DATE    COMMENT 'SCD-2 validity start, inclusive. Sourced from sv_country_master.effective_start_date (1997-11-10 to 2014-05-06). Region/currency/tax effective dates are deliberately NOT intersected in - see script header.',
  valid_to                 DATE    COMMENT 'SCD-2 validity end, inclusive. 9999-12-31 is the intentional open-ended sentinel, not a data defect.',
  is_current               BOOLEAN COMMENT 'TRUE when valid_to is the 9999-12-31 sentinel. TRUE on all 35 rows today because the source carries no closed intervals.',
  scd_version_hash         VARCHAR COMMENT 'SHA1_HEX digest of all conformed attributes. Lets a future process detect that an attribute changed. NOTE: this table cannot itself close a prior version - it is a dynamic table. See script header.',

  -- Country attributes
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
  country_is_active        BOOLEAN COMMENT 'Source is_active for the country. TRUE on all 35 rows today.',

  -- Region attributes (sv_region_master)
  region_code              VARCHAR COMMENT 'FK to the region grain. LEFT-joined: NULL would mean a missing region, not a dropped country.',
  region_name              VARCHAR COMMENT 'Region name. NULL indicates an unresolved region_code - zero occurrences today.',

  -- Currency attributes (sv_currency_master)
  currency_code            VARCHAR COMMENT 'ISO 4217 code. Note: sales amounts are USD-scaled REGARDLESS of this label - cross-currency SUM is invalid until an FX dimension exists (AGENT.md section 7).',
  currency_name            VARCHAR COMMENT 'Currency name.',
  currency_symbol          VARCHAR COMMENT 'Display symbol.',
  currency_minor_unit      NUMBER  COMMENT 'Decimal places (0 for JPY/KRW). Do NOT ROUND() amounts to this - it hides a ~150x scale error behind a type-correct value. Rejected rule, section 7.',

  -- Tax attributes (sv_tax_master)
  tax_code                 VARCHAR COMMENT 'FK to the tax grain. Resolved via country_code -> tax_code, NOT by parsing store.tax_jurisdiction_code (section 7).',
  tax_type                 VARCHAR COMMENT 'Tax type, e.g. VAT/GST.',
  tax_rate                 NUMBER  COMMENT 'CURRENT tax rate only. Effective 2020-01-01 for all 35 rows, i.e. AFTER the 2019 sales period. NEVER recompute historical tax from this - use the transactions own total_tax, which is authoritative. Recomputing 2019 tax fails on 5 countries / 5,609 rows.',
  tax_inclusive_flag       BOOLEAN COMMENT 'Whether the rate is tax-inclusive.',

  -- Lineage
  dq_issue_flags           VARCHAR COMMENT 'Row-level DQ flags carried from sv_country_master. 1 of 35 rows is flagged (the UK non-ISO code). NULL means no flag.',
  source_system            VARCHAR COMMENT 'Originating source system.'
)
TARGET_LAG   = DOWNSTREAM
WAREHOUSE    = {{ warehouse }}
REFRESH_MODE = INCREMENTAL
COMMENT      = 'Gold country dimension: conforms sv_country_master with region, currency and tax. Grain = one row per (country_code, valid_from). PK country_key is a SHA1_HEX hash, enforced by construction via QUALIFY - dynamic tables accept no declared constraints. Has SCD-2 STRUCTURE but retains NO history; see V6.1.1 header.'
AS
SELECT
  SHA1_HEX(c.country_code || '|' || TO_VARCHAR(c.effective_start_date, 'YYYY-MM-DD')) AS country_key,
  c.country_code,
  c.effective_start_date                       AS valid_from,
  c.effective_end_date                         AS valid_to,
  (c.effective_end_date = DATE '9999-12-31')   AS is_current,

  /* Attribute digest. NVL guards make a NULL attribute distinguishable from an
     empty string, so a genuine change is not masked. */
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

/* Defensive de-duplication AND the source of the system-derived unique key.
   The partition expression is the declared grain and matches the projection
   exactly (section 5: a mismatch de-duplicates on a different grain than you
   return). Survivor ordering ends in (__file_name, __row_number) to be
   deterministic - required for INCREMENTAL. */
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY c.country_code, c.effective_start_date
          ORDER BY     c.__file_name, c.__row_number) = 1;


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Refresh mode and lag actually came back as requested. Section 5: requesting
-- INCREMENTAL is not the same as getting it.
SHOW DYNAMIC TABLES LIKE 'dim_country' IN SCHEMA {{ database }}.GOLD;
-- Recorded: target_lag = DOWNSTREAM, refresh_mode = INCREMENTAL,
--           refresh_mode_reason = NULL, warehouse = COMPUTE_WH, rows = 35,
--           scheduling_state = OFF (expected - DOWNSTREAM with no gold consumer
--           yet, same as all 13 silver DTs)

-- Stronger than SHOW: confirms the refresh Snowflake actually PERFORMED was
-- incremental, not merely the mode it advertised.
SELECT name, state, refresh_action, refresh_trigger
FROM   TABLE({{ database }}.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
         NAME => '{{ database }}.GOLD.dim_country'))
ORDER  BY refresh_start_time DESC LIMIT 1;
-- Recorded: DIM_COUNTRY / SUCCEEDED / INCREMENTAL / CREATION

-- THE CONSTRAINT CHECK. Must return rows, otherwise the "PK by construction"
-- claim in the header is false.
SHOW UNIQUE KEYS IN {{ database }}.GOLD.dim_country;
-- Recorded: 2 rows, and BETTER than expected - Snowflake materialised a real
--           DERIVED PRIMARY KEY, not merely a unique key:
--             COUNTRY_CODE  key_sequence 1  SYS_CONSTRAINT_DERIVED_PK  rely=true
--             VALID_FROM    key_sequence 2  SYS_CONSTRAINT_DERIVED_PK  rely=true
--           Note the column is VALID_FROM (the projected output name), not
--           effective_start_date. RELY=true means the optimizer trusts it for
--           join elimination - so the dimension carries a genuine, queryable PK
--           constraint despite CREATE DYNAMIC TABLE having no constraint clause.

-- Grain and key integrity.
SELECT COUNT(*)                        AS rows_,
       COUNT(DISTINCT country_key)     AS distinct_keys,
       COUNT(DISTINCT country_code)    AS distinct_codes,
       COUNT_IF(country_key IS NULL)   AS null_keys,
       MIN(LENGTH(country_key))        AS key_len,
       COUNT_IF(is_current)            AS current_rows
FROM   {{ database }}.GOLD.dim_country;
-- Recorded: 35, 35, 35, 0, 40, 35
-- rows = distinct_keys = distinct_codes confirms one version per country today.

-- Validity window. All intervals open, per the source.
SELECT MIN(valid_from) AS min_from, MAX(valid_from) AS max_from,
       COUNT(DISTINCT valid_from) AS distinct_froms,
       COUNT(DISTINCT valid_to)   AS distinct_tos, MAX(valid_to) AS max_to
FROM   {{ database }}.GOLD.dim_country;
-- Recorded: 1997-11-10, 2014-05-06, 21, 1, 9999-12-31

-- Zero fan-out: the conformed dimension has exactly as many rows as its driver.
SELECT (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_country_master) AS silver_countries,
       (SELECT COUNT(*) FROM {{ database }}.GOLD.dim_country)         AS dim_rows;
-- Recorded: 35, 35

-- THE REGRESSION TEST THAT MATTERS. Every sales row must resolve to exactly one
-- dimension version. This is what would have caught the interval-intersection
-- trap described in the header.
SELECT COUNT(*) AS sales_rows_joined
FROM   {{ database }}.SILVER.sv_sales_header h
JOIN   {{ database }}.GOLD.dim_country d
       ON  d.country_code = h.country_code
       AND h.transaction_timestamp::DATE BETWEEN d.valid_from AND d.valid_to;
-- Recorded: 77155  (= all of sv_sales_header; no fan-out, no loss)
-- For contrast, GREATEST() across all four source intervals yields 24.

-- Attribute resolution. NULLs here mean a LEFT JOIN found no match, which is
-- survivable by design but should be zero today.
SELECT COUNT_IF(region_name   IS NULL) AS unresolved_region,
       COUNT_IF(currency_name IS NULL) AS unresolved_currency,
       COUNT_IF(tax_rate      IS NULL) AS unresolved_tax
FROM   {{ database }}.GOLD.dim_country;
-- Recorded: 0, 0, 0

-- Tag inherited from the schema; no explicit ALTER ... SET TAG needed (note 6).
SELECT tag_name, tag_value, level
FROM   TABLE({{ database }}.INFORMATION_SCHEMA.TAG_REFERENCES(
         '{{ database }}.GOLD.dim_country', 'TABLE'))
WHERE  tag_name = 'MEDALLION_LAYER';
-- Recorded: MEDALLION_LAYER / GOLD / SCHEMA

-- NOT ASSERTED: Snowflake dynamic-table RECOMMENDATIONS.
-- AGENT.md section 3 claims "zero Snowflake recommendations" across silver, but the
-- recommendations surface is NOT queryable on this account - all three candidates
-- fail:
--     DYNAMIC_TABLE_REFRESH_HISTORY()        -> no RECOMMENDATIONS column
--     <db>.INFORMATION_SCHEMA.DYNAMIC_TABLES -> object does not exist
--     SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLES -> object does not exist
-- Plausibly edition-gated (this account is STANDARD). So this script does NOT
-- claim zero recommendations - that would be an unverified assertion. The
-- verifiable evidence that the definition is well-formed is refresh_action =
-- INCREMENTAL above, plus refresh_mode_reason = NULL.

-- Anything needing attention (expect ZERO rows)
SELECT country_key, country_code, valid_from, dq_issue_flags,
       region_name, currency_name, tax_rate
FROM   {{ database }}.GOLD.dim_country
WHERE  dq_issue_flags IS NOT NULL
    OR region_name   IS NULL
    OR currency_name IS NULL
ORDER  BY country_code;
-- Recorded: 1 row - UK / 'UK' is not valid ISO 3166-1 alpha-2, flagged in
-- V5.1.4 and deliberately not rejected. Expected, not a failure.
