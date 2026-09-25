/* ---------------------------------------------------------------------------
   V6.1.5 - Gold store dimension (dynamic table)

   One row per store_code, 121 rows, from sv_store_master.

   ==========================================================================
   SCD-1, NOT SCD-2 - AND THE REASON IS A MEASURED TRAP
   ==========================================================================
   sv_store_master IS temporally versioned in silver (V5.2.1 partitions it on
   (store_code, effective_start_date)), so at first glance it looks like a
   candidate for the V6.1.2 LEAD() treatment that gave dim_country real SCD-2.

   IT IS NOT. Measured:

       sv_store_master.effective_start_date   1 DISTINCT VALUE = 2026-04-17
       sv_store_master.store_open_date      119 distinct values, 2016-04-29 to 2026-04-10

   effective_start_date is a LOAD DATE, not a business date - section 7 already
   records this ("effective_start_date on stores: a load date, one value
   2026-04-17, not a business date"). It postdates the entire 2019 sales period.

   THE MEASUREMENT THAT SETTLES IT:

       sales joined to store on store_code only            61,804
       sales joined to store on store_code + effective window     0

   Using it as validity destroys 100% of the join. This is the same failure that
   killed the four-way interval intersection in V6.1.1 - a date that postdates the
   facts produces a clean, empty answer.

   So: SCD-1. The column is still carried, RENAMED to load_effective_date so it
   cannot be mistaken for validity, and its comment states the zero-row result.

   store_open_date is the real business date and the one to reason with. Note for
   V6.2.1: 38,102 sales rows predate their own store's opening (61.6% of
   store-attributed rows; 67 of 121 stores open after the 2019 period). That check
   belongs in the fact and must compare against EACH STORE'S OWN open date, never
   a literal year.

   WHY country IS NOT DENORMALISED IN
   --------------------------------------------------------------------
   dim_country is SCD-2 after V6.1.2, so there can be MULTIPLE country_key values
   per country. Two consequences:

     1. Storing a country_key here would silently pin one version and go stale.
     2. Copying country ATTRIBUTES (name, region, currency, tax) in would be worse -
        it would freeze a snapshot of a versioned dimension inside an unversioned
        one, and the two would drift apart with no signal.

   So only the natural country_code is carried, and the consumer joins dim_country
   on its validity window:

       JOIN dim_country d ON d.country_code = s.country_code
                         AND <date> BETWEEN d.valid_from AND d.valid_to

   Same decision as bridge_product_country (V6.1.4). Zero orphans measured against
   dim_country.

   NOTE THE FACT-SIDE NAME MISMATCH
   --------------------------------------------------------------------
   sv_sales_header.store_id joins dim_store.store_code. The names DIFFER. This
   already caused a bug in the 08_data_quality work, where a check was written
   against a non-existent sv_store_master.store_id and failed at compile time.
   Zero orphans once the correct columns are used.

   Also: store_id is NULL on 15,351 sales rows - exactly the ONLINE channel, an
   exact partition with channel_id, per section 7. So a store join returns 61,804
   not 77,155, and that is CORRECT, not a loss.

   tax_jurisdiction_code IS CARRIED BUT USELESS
   --------------------------------------------------------------------
   Section 7's decisive finding: it carries NO information at all - every
   component is derivable from country_code + state_code, verified across all 121
   rows. It is NOT a join key to the tax grain; resolve tax via
   country_code -> dim_country.tax_code. Retained for source fidelity with a
   comment saying so, the same treatment given is_available in V6.1.4.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.GOLD.dim_store (
  store_key              VARCHAR COMMENT 'PRIMARY KEY (by construction, not declared - dynamic tables accept no constraint clause). SHA1_HEX of store_code. No version component: the source effective_start_date is a LOAD date, not a business date, so there is no temporal version to disambiguate. See V6.1.5 header.',
  store_code             VARCHAR COMMENT 'Natural/business key and the grain. FK target for sv_sales_header.store_id - note the NAME DIFFERS on the fact side (store_id vs store_code). Zero orphans measured.',
  store_name             VARCHAR COMMENT 'Store display name.',
  country_code           VARCHAR COMMENT 'FK to GOLD.dim_country, as a NATURAL key not a country_key. dim_country is SCD-2 versioned on (country_code, valid_from), so a stored key would silently pin one version. Join it on the validity window.',
  state_code             VARCHAR COMMENT 'Subdivision code. NULL on 39 stores - those countries do not subdivide for tax. Expected, not a defect. AGENT.md section 7.',
  city                   VARCHAR COMMENT 'City.',
  postal_code            VARCHAR COMMENT 'Postal code.',
  address_line1          VARCHAR COMMENT 'Street address.',
  latitude               NUMBER  COMMENT 'Latitude. Range verified -32.68 to 60.99; no Null Island rows.',
  longitude              NUMBER  COMMENT 'Longitude. Range verified -126.18 to 143.79.',
  format_code            VARCHAR COMMENT 'Store format: MINI / FLG / MALL. No allow-list asserted - a new format is a business change, not a defect (DQ rule 4).',
  lifecycle_status       VARCHAR COMMENT 'Store lifecycle. ACTIVE on all 121 today.',
  store_open_date        DATE    COMMENT 'THE BUSINESS DATE for this store - 119 distinct values, 2016-04-29 to 2026-04-10. Use THIS for any date reasoning, never effective_start_date. 38,102 sales rows predate their own store opening; that check belongs in fact_sales and must compare against EACH STORE OWN open date, never a literal year.',
  store_close_date       DATE    COMMENT 'NULL on all 121 - no store has closed. Open-ended state, not a defect.',
  floor_area_sqft        NUMBER  COMMENT 'Floor area. Range 5,205 to 24,570.',
  annual_rent_usd        NUMBER  COMMENT 'Annual rent USD. Range 660,419 to 19,405,046. Rent-per-sqft reaches 3,690 - prime Apple retail genuinely does, so no plausibility band is asserted. Rejected rule, AGENT.md section 7.',
  tax_jurisdiction_code  VARCHAR COMMENT '*** CARRIES NO INFORMATION: every component is derivable from country_code + state_code, verified across all 121 rows. *** It is NOT a join key to the tax grain - resolve tax via country_code -> dim_country.tax_code instead. Retained for source fidelity only. AGENT.md section 7.',
  is_active              BOOLEAN COMMENT 'Source is_active. TRUE on all 121 today.',
  load_effective_date    DATE    COMMENT 'The source effective_start_date, a single value 2026-04-17. This is a LOAD DATE, NOT a business date - named load_effective_date to stop it being mistaken for validity. Filtering 2019 sales on it returns ZERO stores (measured). Use store_open_date for business dating.',
  scd_version_hash       VARCHAR COMMENT 'SHA1_HEX digest of all conformed attributes. Lets a consumer detect that the store record changed. NOT a validity interval.',
  dq_issue_flags         VARCHAR COMMENT 'Row-level DQ flags from sv_store_master. NULL means no flag.',
  source_system          VARCHAR COMMENT 'Originating source system.'
)
TARGET_LAG   = DOWNSTREAM
WAREHOUSE    = {{ warehouse }}
REFRESH_MODE = INCREMENTAL
COMMENT      = 'Gold store dimension: one row per store_code (121 rows). SCD-1, NOT SCD-2: the source effective_start_date is a LOAD date (single value 2026-04-17, after the 2019 fact period) so it cannot serve as validity - joining sales on it returns ZERO rows. Use store_open_date for business dating. country_code is a natural FK to dim_country; join it on the validity window.'
AS
SELECT
  SHA1_HEX(s.store_code)                        AS store_key,
  s.store_code,
  s.store_name,
  s.country_code,
  s.state_code,
  s.city,
  s.postal_code,
  s.address_line1,
  s.latitude,
  s.longitude,
  s.format_code,
  s.lifecycle_status,
  s.store_open_date,
  s.store_close_date,
  s.floor_area_sqft,
  s.annual_rent_usd,
  s.tax_jurisdiction_code,
  s.is_active,
  /* Renamed deliberately - see header. */
  s.effective_start_date                        AS load_effective_date,
  SHA1_HEX(
      NVL(s.store_name,'~')||'|'||NVL(s.country_code,'~')||'|'||NVL(s.state_code,'~')
   ||'|'||NVL(s.city,'~')||'|'||NVL(s.postal_code,'~')||'|'||NVL(s.address_line1,'~')
   ||'|'||NVL(TO_VARCHAR(s.latitude),'~')||'|'||NVL(TO_VARCHAR(s.longitude),'~')
   ||'|'||NVL(s.format_code,'~')||'|'||NVL(s.lifecycle_status,'~')
   ||'|'||NVL(TO_VARCHAR(s.store_open_date),'~')||'|'||NVL(TO_VARCHAR(s.store_close_date),'~')
   ||'|'||NVL(TO_VARCHAR(s.floor_area_sqft),'~')||'|'||NVL(TO_VARCHAR(s.annual_rent_usd),'~')
   ||'|'||NVL(s.tax_jurisdiction_code,'~')||'|'||NVL(TO_VARCHAR(s.is_active),'~')
  )                                             AS scd_version_hash,
  s.dq_issue_flags,
  s.source_system
FROM {{ database }}.SILVER.sv_store_master s
/* Establishes one row per store and produces the derived PRIMARY KEY. Ordering
   by effective_start_date DESC picks the latest LOAD of each store - which is
   what "current" means here, absent a business validity date. */
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY s.store_code
          ORDER BY     s.effective_start_date DESC NULLS LAST,
                       s.__file_name, s.__row_number) = 1;


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Refresh mode, checked AT CREATION per section 5.
SHOW DYNAMIC TABLES LIKE 'dim_store' IN SCHEMA {{ database }}.GOLD;
-- Recorded: target_lag = DOWNSTREAM, refresh_mode = INCREMENTAL,
--           refresh_mode_reason = NULL, rows = 121

SHOW UNIQUE KEYS IN {{ database }}.GOLD.dim_store;
-- Recorded: STORE_CODE seq 1, SYS_CONSTRAINT_DERIVED_PK, rely = true

-- Grain and FK integrity to the versioned country dimension.
SELECT COUNT(*)                        AS rows_,
       COUNT(DISTINCT store_key)       AS keys,
       COUNT(DISTINCT store_code)      AS codes,
       COUNT_IF(dq_issue_flags IS NOT NULL) AS flagged,
       COUNT_IF(state_code IS NULL)    AS null_state,
       COUNT(DISTINCT store_open_date) AS distinct_open_dates,
       COUNT(DISTINCT load_effective_date) AS distinct_load_dates
FROM   {{ database }}.GOLD.dim_store;
-- Recorded: 121, 121, 121, 0, 39, 119, 1
-- null_state = 39 is expected (countries that do not subdivide).
-- distinct_load_dates = 1 is the whole reason this is SCD-1.

SELECT COUNT(*) AS orphan_country
FROM   {{ database }}.GOLD.dim_store s
WHERE  NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_country d
                    WHERE d.country_code = s.country_code);
-- Recorded: 0

-- ** THE TRAP, MEASURED. ** Never join sales on load_effective_date.
SELECT
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
     JOIN {{ database }}.GOLD.dim_store s ON s.store_code = h.store_id
    WHERE h.__is_current_version)                                  AS join_on_code_CORRECT,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
     JOIN {{ database }}.GOLD.dim_store s ON s.store_code = h.store_id
      AND h.transaction_timestamp::DATE >= s.load_effective_date
    WHERE h.__is_current_version)                                  AS join_on_load_date_WRONG;
-- Recorded: 61804, 0
-- 61,804 is CORRECT and not a loss: store_id is NULL on the 15,351 ONLINE rows,
-- an exact partition with channel_id (section 7). The 0 is the trap.

-- Anything needing attention (expect ZERO rows)
SELECT store_key, store_code, country_code, state_code, dq_issue_flags
FROM   {{ database }}.GOLD.dim_store
WHERE  dq_issue_flags IS NOT NULL
ORDER  BY store_code;
-- Recorded: 0 rows
