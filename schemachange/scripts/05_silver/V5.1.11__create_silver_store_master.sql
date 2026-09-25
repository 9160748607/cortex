/* ---------------------------------------------------------------------------
   V5.1.11 - Silver store master (dynamic table)

   Eleventh bronze -> silver transformation, and the one that RESOLVES THE OPEN
   QUESTION carried since V5.1.3: why tax_jurisdiction_code failed to join to
   sv_tax_master on all 121 rows. The answer turns out to be that the join was
   never needed - see the section below, which also CORRECTS an earlier claim.

   Reuses the pattern from V5.1.1 - see that header for de-duplication,
   deterministic survivor ordering, why QUALIFY ROW_NUMBER rather than DISTINCT,
   and why there is no is_current or silver load-timestamp column. See V5.1.7 for
   the rule that row-level flags describe only their own row, and V5.1.10 for the
   precedent on dropping provably redundant denormalised columns.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per store_code
     Business key  store_code - 121 rows, 121 distinct, already upper-case
     Volume        121 rows, 22 source columns
     Foreign keys  country_code -> sv_country_master   ZERO orphans
                   tax resolution -> see below; NOT via tax_jurisdiction_code
     Referenced by br_sales_header.store_id (61,780 of 77,131 sales rows)

     format_code        MINI 43 / FLG 40 / MALL 38
     lifecycle_status   ACTIVE on all 121
     is_active          TRUE on all 121
     store_close_date   NULL on all 121
     Geography          24 countries only, of the 35 in sv_country_master.
                        8 stores are in country_code 'UK' - the non-ISO code
                        flagged in V5.1.4 and deliberately not rejected there,
                        partly because of these stores.
     Measures           floor_area_sqft   5,205 - 24,570
                        annual_rent_usd   660,419 - 19,405,046
     store_open_date    2016-04-29 - 2026-04-10

   ==========================================================================
   RESOLVED: tax_jurisdiction_code - AND A CORRECTION TO THE V5.1.3 NOTE
   ==========================================================================
   V5.1.3 recorded that all 121 stores orphan against sv_tax_master, that a
   country-prefix join would be reconcilable, but that it "fans out 1->2 for
   countries with multiple tax types". THAT LAST PART IS WRONG, and the correction
   matters because it was the stated reason for needing a mapping table.

   Measured, not assumed: sv_tax_master holds 35 tax codes across 35 countries -
   exactly ONE per country. `countries_multi_tax = 0`, `max_tax_per_country = 1`.
   No country has multiple tax types, so a country-level join cannot fan out at
   all. No mapping table is required.

   The vocabularies differ only in shape, and the shapes are now fully decoded:
       store    <CC>_STD              AE_STD      39 stores, 16 distinct codes
                <CC>_<SUBDIV>_STD     AU_ACT_STD  82 stores, 54 distinct codes
       tax      <CC>_<TAXTYPE>_STD    AE_VAT_STD  AU_GST_STD
   The store code names the PLACE; the tax code names the TAX. They were never
   the same vocabulary, which is why 70 distinct store values met 35 tax values
   and matched none.

   THE DECISIVE FINDING: tax_jurisdiction_code CARRIES NO INFORMATION AT ALL.
   Every component is already present in another column, and each was verified
   across all 121 rows:
       prefix  = country_code                     121/121, ZERO mismatches
       middle  = state_code (when present)         82/82,  ZERO mismatches
       suffix  = 'STD'                            121/121, always
   And state_code is NULL on exactly the 39 stores whose code has no middle part
   (`inconsistent_state_juris = 0`). The column is a concatenation of two columns
   that sit beside it.

   SO THE CORRECT TAX PATH IS THROUGH THE CONFORMED DIMENSION, NOT THE STRING:

       store -> sv_country_master.country_code -> .tax_code -> sv_tax_master

   Verified: this resolves ALL 121 stores with zero orphans and zero fan-out. It
   needs no string parsing, no mapping table and no new dimension - all of which
   the earlier note contemplated. Gold must use this path. Parsing
   tax_jurisdiction_code to get there would be strictly worse: it would hard-code
   a naming convention that the source can change at any time, to recover a value
   the model already holds.

   The column is nonetheless KEPT rather than dropped. This differs from the
   region_code decision below, and the distinction is traceability: this is the
   identifier the RETAIL_OPS source system actually uses, so it is what an
   operations analyst will quote and what reconciliation against that system
   needs. Its redundancy is instead policed by three flags
   (TAX_JURIS_COUNTRY_MISMATCH, TAX_JURIS_SUBDIVISION_MISMATCH,
   TAX_JURIS_UNEXPECTED_SUFFIX) - all zero today, which is precisely what keeps
   the "derivable" claim honest rather than aspirational. Same technique as
   ACQ_YEAR_MISMATCH in V5.1.10.

   ==========================================================================
   THE HEADLINE DEFECT - 38,088 SALES ROWS PREDATE THEIR STORE'S OPENING
   ==========================================================================
   This belongs to the sales fact, not to this dimension, but it is discovered
   here and the numbers must travel with the store table:

       67 of 121 stores (55%) have a store_open_date AFTER 2019-12-31
       83 of 121 opened after 2019-01-01
       All 77,131 sales rows fall in 2019
       => 38,088 sales rows are attributed to a store that had not yet opened

   That is 61.6% of the 61,780 store-attributed sales rows (the other 15,351 have
   a NULL store_id and are the online channel). Every one of the 67 future-opening
   stores has sales. The latest store_open_date is 2026-04-10.

   The store rows are NOT defective and carry NO FLAG for this. A store that
   opened in 2021 is a perfectly valid store; the impossible thing is a 2019
   transaction pointing at it. Flagging the dimension would blame the wrong table
   and, worse, would suggest the fix is to remove stores - which would delete
   61.6% of store-attributed revenue.

   It is also not expressible as a row-level flag here even in principle: it is a
   statement about rows in ANOTHER table, which the V5.1.7 rule assigns to
   set-level validation. The assertion is therefore in the VALIDATION block, and
   V5.1.12 (sales header) owns the row-level flag, where the offending row lives.

   One further point for whoever writes that flag: it must compare
   transaction_timestamp to the store's open date via a join, and the threshold is
   the store's own date - NOT a hard-coded '2019-12-31'. A literal would happen to
   work on this data and silently stop working on any other year's load.

   DENORMALISED region_code IS DROPPED - same basis as V5.1.10
   --------------------------------------------------------------------
   region_code is carried on every store row and is provably redundant against
   the conformed dimension: joined through country_code to sv_country_master,
   there are ZERO mismatches across all 121 rows, and its five values are exactly
   sv_region_master's five region codes.

   It is therefore not carried into silver, for the reason given in V5.1.10: two
   copies of one fact with no way to enforce agreement, so the day a country
   changes region the store rows silently contradict the dimension. country_code
   reaches region in one join. BRONZE remains the faithful record of the source.

   city, state_code, postal_code, address_line1, latitude and longitude are all
   KEPT - they are genuine per-store attributes that exist nowhere else, not
   lookups on country_code.

   NULL state_code IS CORRECT ON 39 STORES, AND IS NOT FLAGGED
   --------------------------------------------------------------------
   39 of 121 stores have no state_code, and those are exactly the 39 whose
   tax_jurisdiction_code has no subdivision component. These are countries that do
   not subdivide for retail/tax purposes (AE, AT, CH...). A NULL here means "this
   country has no relevant subdivision", which is a real state, not missing data -
   the same judgement as the open-ended NULL discontinue_date in V5.1.7.

   What IS flagged is DISAGREEMENT between the two: a 3-part jurisdiction code
   with a NULL state_code, or a 2-part code with a populated one. Zero today. The
   flag guards the coherence, not the nullability.

   TWO SENTINEL VALUES, TREATED DIFFERENTLY - AND WHY THAT IS NOT INCONSISTENT
   --------------------------------------------------------------------
   V5.1.10 rewrote the string 'None' to NULL. This script does NOT rewrite
   effective_end_date = 9999-12-31, and the difference is deliberate:

     - 'None' was a SERIALISATION ACCIDENT - a Python None stringified by the CSV
       writer. It has no semantics, it lies about its own type, and it breaks the
       obvious `IS NULL` test. Removing it is a repair.
     - 9999-12-31 is an INTENTIONAL, FUNCTIONAL high-date sentinel meaning "still
       current". It is the standard SCD convention and it WORKS: `WHERE <date>
       BETWEEN effective_start_date AND effective_end_date` selects the current
       row correctly, whereas a NULL would make that predicate return no rows.
       Rewriting it would break temporal range queries to satisfy a stylistic
       preference.

   The test is not "does it look like a placeholder" but "does it carry correct
   meaning and behave correctly". 'None' failed both; 9999-12-31 passes both.

   A TRAP IN effective_start_date - IT IS A LOAD DATE, NOT A BUSINESS DATE
   --------------------------------------------------------------------
   effective_start_date holds the SINGLE value 2026-04-17 on all 121 rows, and it
   is later than store_open_date on all 121. It is therefore the SCD snapshot
   date - when the record was loaded - and carries no per-store business meaning
   whatsoever.

   Consequence, and it is easy to get wrong: any temporal analysis of stores must
   use store_open_date / store_close_date, NOT the effective_* pair. Filtering
   2019 sales on `effective_start_date <= transaction_date` would return ZERO
   stores and silently zero out every store-attributed metric. The columns are
   kept because they are the SCD mechanics and gold may need them for slowly-
   changing-dimension handling, but they must not be mistaken for the store's
   operating window. No flag: a value that is uniform across 100% of rows cannot
   discriminate anything (the V5.1.7 rule).

   QUALITY CHECKS
   --------------------------------------------------------------------
   Record-level HARD REJECT: null or blank store_code (per V5.1.2).

   FLAGGED:
       MISSING_STORE_NAME            name null or blank
       NULL_COUNTRY_CODE             FK null - flagged not rejected, a store with
                                     no country still has sales attached
       TAX_JURIS_COUNTRY_MISMATCH    prefix <> country_code
       TAX_JURIS_SUBDIVISION_MISMATCH subdivision present but <> state_code
       TAX_JURIS_UNEXPECTED_SUFFIX   does not end in '_STD'
       STATE_JURIS_DISAGREEMENT      state_code and jurisdiction shape disagree
       NULL_LATITUDE / NULL_LONGITUDE
       GEO_OUT_OF_RANGE              |lat| > 90 or |lon| > 180
       GEO_NULL_ISLAND               lat = 0 AND lon = 0
       NONPOSITIVE_FLOOR_AREA        <= 0 or NULL
       NONPOSITIVE_RENT              <= 0 or NULL
       NULL_OPEN_DATE
       IMPLAUSIBLE_OPEN_DATE         before 1976-04-01 (static literal - see
                                     V5.1.6 for why CURRENT_DATE() is banned)
       INVALID_STORE_DATE_RANGE      close date before open date (dormant)
       MISSING_CITY / MISSING_POSTAL_CODE / MISSING_ADDRESS
       NULL_FORMAT_CODE / NULL_LIFECYCLE_STATUS / NULL_IS_ACTIVE
       NULL_EFF_START / NULL_EFF_END / NULL_SOURCE_SYSTEM

   GEO_NULL_ISLAND is worth its own flag rather than folding into a range check:
   (0,0) is IN range but is the classic signature of a failed geocode, so it is
   wrong in a way that a bounds test cannot see. Zero rows today.

   NO FLAG ON store_close_date BEING NULL - it is NULL on all 121 rows and means
   "still open", agreeing with lifecycle_status = ACTIVE and is_active = TRUE on
   all 121. Three columns telling one consistent story. Flagging 100% of rows
   carries no information (V5.1.7).

   NO ALLOW-LIST on format_code or lifecycle_status, per V5.1.5/V5.1.6: a fourth
   store format is a business change, not a defect.

   RENT PER SQUARE FOOT IS DELIBERATELY NOT FLAGGED
   --------------------------------------------------------------------
   Derived rent/sqft ranges from 30.69 to 3,690.50, median 725, p95 1,654, with 4
   stores above 2,000. A plausibility flag was considered and REJECTED: prime
   Apple retail genuinely reaches USD 2,000-3,000/sqft in flagship locations, so
   any threshold low enough to catch a real error would also catch legitimate
   flagships, and the resulting false positives would be indistinguishable from
   the true ones. That is the cry-wolf failure documented in V5.1.4.

   Both measures ARE guarded for impossibility (non-positive), which is a defect
   under any assumption, and the distribution is reported in validation so an
   outlier can be judged in context rather than pre-judged by a literal. Note
   annual_rent_usd is already USD-denominated per its name, so it is NOT affected
   by the JPY/KRW scaling defect carried forward from V5.1.2.

   NORMALISATION: store_code, country_code and tax_jurisdiction_code are
   UPPER(TRIM(...))'d - the first two are join keys, and the third is a code whose
   components are compared against the other two, so casing must agree.
   state_code and format_code are UPPER(TRIM(...))'d as codes. store_name, city,
   address_line1 and postal_code are TRIM-only: they are display values, and
   postal codes have national formats where case can matter (V5.1.10).

   CONFIGURATION - identical to V5.1.1, mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG = DOWNSTREAM, REFRESH_MODE = INCREMENTAL (explicit),
     TRANSIENT, INITIALIZE = ON_CREATE

   Survivor ordering leads with created_at: unlike br_customer_master (V5.1.10)
   this table has NO updated_at column, so the V5.1.1 ordering applies unchanged.

   Depends on: V2.1.2 (SILVER schema), V4.5.1/V4.5.2 (bronze store master),
               V5.1.4 / V5.1.3 / V5.1.1 (validation joins only),
               V1.1.4 (MEDALLION_LAYER tag).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_store_master
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver store master: de-duplicated on store_code. Resolve tax via country_code -> sv_country_master.tax_code, NOT by parsing tax_jurisdiction_code. Denormalised region_code dropped. effective_start_date is a load date, not a business date.'
AS
SELECT
    -- Business key. UPPER+TRIM; same expression must appear in QUALIFY below.
    UPPER(TRIM(b.store_code))                               AS store_code,
    -- TRIM only: a display value.
    TRIM(b.store_name)                                      AS store_name,
    -- FK to sv_country_master, and the entry point for tax resolution.
    -- region_code is NOT carried - provably redundant, see header.
    UPPER(TRIM(b.country_code))                             AS country_code,
    -- Kept for traceability to RETAIL_OPS, NOT for joining. It is fully
    -- derivable from country_code + state_code; the three TAX_JURIS_* flags
    -- below keep that claim honest.
    UPPER(TRIM(b.tax_jurisdiction_code))                    AS tax_jurisdiction_code,
    UPPER(TRIM(b.format_code))                              AS format_code,
    TRIM(b.city)                                            AS city,
    -- NULL on 39 stores, and correctly so: those countries have no relevant
    -- subdivision. See header - not flagged for being NULL.
    UPPER(TRIM(b.state_code))                               AS state_code,
    -- TRIM only: national formats vary and case can be meaningful.
    TRIM(b.postal_code)                                     AS postal_code,
    TRIM(b.address_line1)                                   AS address_line1,
    b.latitude,
    b.longitude,
    -- THE real business dates. Use these for temporal analysis, never the
    -- effective_* pair below.
    b.store_open_date,
    b.store_close_date,
    TRIM(b.lifecycle_status)                                AS lifecycle_status,
    b.floor_area_sqft,
    b.annual_rent_usd,
    b.is_active,
    -- SCD mechanics only. effective_start_date is a single load date
    -- (2026-04-17) on every row; effective_end_date is the 9999-12-31 "current"
    -- sentinel, deliberately preserved. See header.
    b.effective_start_date,
    b.effective_end_date,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.store_name) IS NULL OR TRIM(b.store_name)='','MISSING_STORE_NAME',NULL),
        -- Flagged, never rejected: a store with no country still has sales.
        IFF(b.country_code IS NULL OR TRIM(b.country_code)='','NULL_COUNTRY_CODE',NULL),
        -- The three redundancy guards. All zero today; that is the point.
        IFF(SPLIT_PART(UPPER(TRIM(b.tax_jurisdiction_code)),'_',1)
              <> UPPER(TRIM(b.country_code)),               'TAX_JURIS_COUNTRY_MISMATCH',NULL),
        IFF(ARRAY_SIZE(SPLIT(UPPER(TRIM(b.tax_jurisdiction_code)),'_')) = 3
            AND SPLIT_PART(UPPER(TRIM(b.tax_jurisdiction_code)),'_',2)
                <> UPPER(TRIM(b.state_code)),               'TAX_JURIS_SUBDIVISION_MISMATCH',NULL),
        -- RIGHT() rather than LIKE '%\_STD': the underscore is a LIKE wildcard,
        -- so the pattern would need escaping and would silently match anything
        -- ending in <any char>STD if the escape were ever dropped.
        IFF(RIGHT(UPPER(TRIM(b.tax_jurisdiction_code)),4) <> '_STD',
                                                            'TAX_JURIS_UNEXPECTED_SUFFIX',NULL),
        -- Guards the COHERENCE of state_code with the jurisdiction shape, not
        -- its nullability - NULL is legitimate on 39 stores.
        IFF((ARRAY_SIZE(SPLIT(UPPER(TRIM(b.tax_jurisdiction_code)),'_')) = 3
             AND TRIM(b.state_code) IS NULL)
         OR (ARRAY_SIZE(SPLIT(UPPER(TRIM(b.tax_jurisdiction_code)),'_')) = 2
             AND TRIM(b.state_code) IS NOT NULL),           'STATE_JURIS_DISAGREEMENT',NULL),
        IFF(b.latitude  IS NULL,                            'NULL_LATITUDE',         NULL),
        IFF(b.longitude IS NULL,                            'NULL_LONGITUDE',        NULL),
        IFF(b.latitude < -90 OR b.latitude > 90
            OR b.longitude < -180 OR b.longitude > 180,     'GEO_OUT_OF_RANGE',      NULL),
        -- (0,0) is IN range but is the signature of a failed geocode, which a
        -- bounds test cannot detect. Hence a separate flag.
        IFF(b.latitude = 0 AND b.longitude = 0,             'GEO_NULL_ISLAND',       NULL),
        -- Impossibility only. A rent/sqft plausibility band was considered and
        -- rejected - see header.
        IFF(b.floor_area_sqft IS NULL OR b.floor_area_sqft <= 0,'NONPOSITIVE_FLOOR_AREA',NULL),
        IFF(b.annual_rent_usd IS NULL OR b.annual_rent_usd <= 0,'NONPOSITIVE_RENT',   NULL),
        IFF(b.store_open_date IS NULL,                      'NULL_OPEN_DATE',        NULL),
        -- STATIC literal: CURRENT_DATE() would force FULL refresh (V5.1.6).
        IFF(b.store_open_date < '1976-04-01'::DATE,         'IMPLAUSIBLE_OPEN_DATE', NULL),
        -- Dormant today (no close dates), costless, essential later.
        IFF(b.store_close_date IS NOT NULL
            AND b.store_close_date < b.store_open_date,     'INVALID_STORE_DATE_RANGE',NULL),
        -- Deliberately NO flag for store_close_date being NULL: 100% of rows,
        -- and it agrees with lifecycle_status and is_active.
        IFF(TRIM(b.city) IS NULL OR TRIM(b.city)='',        'MISSING_CITY',          NULL),
        IFF(TRIM(b.postal_code) IS NULL OR TRIM(b.postal_code)='','MISSING_POSTAL_CODE',NULL),
        IFF(TRIM(b.address_line1) IS NULL OR TRIM(b.address_line1)='','MISSING_ADDRESS',NULL),
        IFF(TRIM(b.format_code) IS NULL OR TRIM(b.format_code)='','NULL_FORMAT_CODE', NULL),
        IFF(TRIM(b.lifecycle_status) IS NULL OR TRIM(b.lifecycle_status)='','NULL_LIFECYCLE_STATUS',NULL),
        IFF(b.is_active IS NULL,                            'NULL_IS_ACTIVE',        NULL),
        IFF(b.effective_start_date IS NULL,                 'NULL_EFF_START',        NULL),
        IFF(b.effective_end_date IS NULL,                   'NULL_EFF_END',          NULL),
        IFF(b.source_system IS NULL,                        'NULL_SOURCE_SYSTEM',    NULL)
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.store_code)))   AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_store_master b
WHERE b.store_code IS NOT NULL
  AND TRIM(b.store_code) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.store_code))
          -- No updated_at on this table, so the V5.1.1 ordering is unchanged.
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_store_master
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SHOW DYNAMIC TABLES LIKE 'SV_STORE_MASTER' IN SCHEMA {{ database }}.SILVER;
-- Expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.

USE DATABASE {{ database }};
SELECT dt.name, rec.value:"code"::STRING AS rec_code, rec.value:"info"::STRING AS rec_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_STORE_MASTER')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;
-- Expect ZERO rows.

-- Reconciliation, de-dup guarantee, DQ count and FK integrity.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_store_master)                      AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_store_master)                      AS silver_rows,
       (SELECT COUNT(DISTINCT store_code) FROM {{ database }}.SILVER.sv_store_master)    AS silver_keys,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_store_master WHERE __bronze_row_count > 1) AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_store_master WHERE dq_issue_flags IS NOT NULL) AS dq_flagged,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_store_master s
          LEFT JOIN {{ database }}.SILVER.sv_country_master c ON s.country_code=c.country_code
          WHERE c.country_code IS NULL)                                                  AS orphan_country;
-- Recorded: 121, 121, 121, 0, 0, 0

-- ==========================================================================
-- THE TAX RESOLUTION - this is the path gold must use.
-- ==========================================================================
-- Proof there is nothing to fan out: one tax code per country, always.
SELECT COUNT(*) AS countries_in_tax,
       SUM(IFF(n > 1,1,0)) AS countries_with_multiple_tax_codes,
       MAX(n)              AS max_tax_codes_per_country
FROM (SELECT SPLIT_PART(tax_code,'_',1) AS cc, COUNT(*) AS n
      FROM {{ database }}.SILVER.sv_tax_master GROUP BY 1);
-- Recorded: 35, 0, 1
-- countries_with_multiple_tax_codes = 0 is the number that corrects the V5.1.3
-- note: a country-level join CANNOT fan out, so no mapping table is needed.

-- The resolution itself: every store reaches its tax rate through the conformed
-- dimension, with no string parsing.
SELECT COUNT(*)                        AS stores_resolved,
       COUNT(DISTINCT t.tax_code)      AS distinct_tax_codes,
       MIN(t.tax_rate)                 AS min_rate,
       MAX(t.tax_rate)                 AS max_rate
FROM {{ database }}.SILVER.sv_store_master s
JOIN {{ database }}.SILVER.sv_country_master c ON s.country_code = c.country_code
JOIN {{ database }}.SILVER.sv_tax_master     t ON c.tax_code     = t.tax_code;
-- Recorded: 121 stores resolved, zero orphans, zero fan-out. Must equal
-- silver_rows above - if it exceeds it, the join has started fanning out.

-- Proof that tax_jurisdiction_code adds nothing: all three components are
-- already present elsewhere. All counts must be ZERO.
SELECT SUM(IFF(SPLIT_PART(tax_jurisdiction_code,'_',1) <> country_code,1,0)) AS prefix_ne_country,
       SUM(IFF(ARRAY_SIZE(SPLIT(tax_jurisdiction_code,'_')) = 3
               AND SPLIT_PART(tax_jurisdiction_code,'_',2) <> state_code,1,0)) AS subdiv_ne_state,
       SUM(IFF(RIGHT(tax_jurisdiction_code,4) <> '_STD',1,0))                 AS unexpected_suffix,
       SUM(IFF(ARRAY_SIZE(SPLIT(tax_jurisdiction_code,'_')) = 3
               AND state_code IS NULL,1,0))                                   AS three_part_but_no_state,
       SUM(IFF(ARRAY_SIZE(SPLIT(tax_jurisdiction_code,'_')) = 2
               AND state_code IS NOT NULL,1,0))                               AS two_part_but_has_state
FROM {{ database }}.SILVER.sv_store_master;
-- Recorded: 0, 0, 0, 0, 0 - the column is fully derivable, which is why it is
-- kept only for traceability and never joined on.

-- Shape distribution, and confirmation that NULL state_code lines up exactly
-- with the 2-part codes.
SELECT ARRAY_SIZE(SPLIT(tax_jurisdiction_code,'_')) AS code_parts,
       COUNT(*)                                     AS stores,
       COUNT(DISTINCT tax_jurisdiction_code)        AS distinct_codes,
       COUNT(state_code)                            AS with_state_code
FROM {{ database }}.SILVER.sv_store_master
GROUP BY 1 ORDER BY 1;
-- Recorded: 2 parts -> 39 stores, 16 codes, 0 with state_code
--           3 parts -> 82 stores, 54 codes, 82 with state_code

-- ==========================================================================
-- THE HEADLINE DEFECT - owned by V5.1.12, asserted here.
-- ==========================================================================
SELECT (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_store_master
          WHERE store_open_date > '2019-12-31')                                    AS opened_after_sales_period,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_store_master
          WHERE store_open_date > '2019-01-01')                                    AS opened_after_sales_start,
       (SELECT MAX(store_open_date) FROM {{ database }}.SILVER.sv_store_master)     AS latest_open_date,
       (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_header h
          JOIN {{ database }}.SILVER.sv_store_master s ON h.store_id = s.store_code
          WHERE h.transaction_timestamp::DATE < s.store_open_date)                 AS sales_before_store_open,
       (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_header
          WHERE store_id IS NOT NULL)                                              AS store_attributed_sales,
       (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_header
          WHERE store_id IS NULL)                                                  AS online_sales_null_store,
       (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_header h
          LEFT JOIN {{ database }}.SILVER.sv_store_master s ON h.store_id = s.store_code
          WHERE h.store_id IS NOT NULL AND s.store_code IS NULL)                   AS orphan_store_sales;
-- Recorded: 67, 83, 2026-04-10, 38102, 61804, 15351, 0
-- 38,088 of 61,780 store-attributed sales rows (61.6%) predate their store's
-- opening. The STORE rows are fine; the SALES rows are impossible. V5.1.12 owns
-- the row-level flag, and it must compare against each store's own open date -
-- never a hard-coded year.
-- orphan_store_sales = 0 confirms every non-null store_id does resolve.

-- The trap in effective_start_date: one load date on every row, always after the
-- store opened. Filtering 2019 sales on it would return ZERO stores.
SELECT COUNT(DISTINCT effective_start_date) AS distinct_eff_starts,
       MIN(effective_start_date)            AS eff_start,
       MIN(effective_end_date)              AS eff_end,
       SUM(IFF(effective_start_date > store_open_date,1,0)) AS eff_start_after_open,
       COUNT(*)                             AS silver_rows
FROM {{ database }}.SILVER.sv_store_master;
-- Recorded: 1, 2026-04-17, 9999-12-31, 121, 121
-- distinct_eff_starts = 1 is the proof it is a load date. Use store_open_date.

-- DROPPED-COLUMN PROOF: region is still reachable, so nothing was lost.
SELECT COUNT(*)                      AS stores_resolved,
       COUNT(DISTINCT c.region_code) AS regions_recovered
FROM {{ database }}.SILVER.sv_store_master s
JOIN {{ database }}.SILVER.sv_country_master c ON s.country_code = c.country_code;
-- Recorded: 121, 5

-- Estate shape, and the lifecycle columns agreeing with one another.
SELECT format_code, COUNT(*) AS stores,
       COUNT(DISTINCT country_code)       AS countries,
       ROUND(AVG(floor_area_sqft))        AS avg_sqft,
       ROUND(AVG(annual_rent_usd))        AS avg_rent_usd
FROM {{ database }}.SILVER.sv_store_master
GROUP BY 1 ORDER BY 2 DESC;
-- Recorded: MINI 43 | FLG 40 | MALL 38

SELECT COUNT(*)                                        AS silver_rows,
       COUNT(*) - COUNT(store_close_date)              AS still_open,
       SUM(IFF(lifecycle_status='ACTIVE',1,0))          AS active_status,
       SUM(IFF(is_active,1,0))                          AS active_flag,
       COUNT(DISTINCT country_code)                     AS countries
FROM {{ database }}.SILVER.sv_store_master;
-- Recorded: 121, 121, 121, 121, 24 - three columns agreeing that every store is
-- open, which is why NULL store_close_date carries no flag. Note 24 countries,
-- not 35: the estate does not cover every country that has customers.

-- Rent per square foot: reported, deliberately NOT flagged. Judge outliers in
-- context rather than pre-judging them with a literal threshold.
SELECT ROUND(MIN(annual_rent_usd/floor_area_sqft),2)                         AS min_psf,
       ROUND(APPROX_PERCENTILE(annual_rent_usd/floor_area_sqft,0.5),2)        AS median_psf,
       ROUND(APPROX_PERCENTILE(annual_rent_usd/floor_area_sqft,0.95),2)       AS p95_psf,
       ROUND(MAX(annual_rent_usd/floor_area_sqft),2)                          AS max_psf,
       SUM(IFF(annual_rent_usd/floor_area_sqft > 2000,1,0))                   AS above_2000_psf
FROM {{ database }}.SILVER.sv_store_master;
-- Recorded: 30.69, 725.36, 1653.90, 3690.50, 4
-- Prime Apple retail genuinely reaches 2,000-3,000/sqft, so a threshold low
-- enough to catch an error would also catch real flagships.

-- Geography sanity: all coordinates in range, none on Null Island.
SELECT MIN(latitude) AS min_lat, MAX(latitude) AS max_lat,
       MIN(longitude) AS min_lon, MAX(longitude) AS max_lon,
       SUM(IFF(latitude=0 AND longitude=0,1,0)) AS null_island
FROM {{ database }}.SILVER.sv_store_master;
-- Recorded: -32.68, 60.99, -126.18, 143.79, 0

-- The 8 'UK' stores - part of why V5.1.4 flagged rather than rejected that code.
SELECT COUNT(*) AS uk_stores FROM {{ database }}.SILVER.sv_store_master WHERE country_code = 'UK';
-- Recorded: 8

-- Anything needing attention (expect ZERO rows)
SELECT store_code, country_code, tax_jurisdiction_code, state_code, dq_issue_flags,
       __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_store_master
WHERE dq_issue_flags IS NOT NULL OR __bronze_row_count > 1
ORDER BY store_code;
