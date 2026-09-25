/* ---------------------------------------------------------------------------
   V6.1.8 - Add the Not-Applicable member to GOLD.dim_store

   121 real stores + 1 synthetic member = 122 rows.

   ==========================================================================
   WHY: A FACT MUST NOT CARRY A NULL FOREIGN KEY
   ==========================================================================
   Measured on sv_sales_header:

       store_id IS NULL                                        15,351 rows (19.9%)
       (store_id IS NULL) <> (channel_id = 'ONLINE')                 0 rows

   So store_id is null on exactly the ONLINE channel - an exact partition, not a
   data defect. Those sales genuinely have no store.

   If the fact carried a NULL store_key for them, the failure mode is silent and
   expensive: any consumer writing the obvious

       FROM fact_sales_item f JOIN dim_store s USING (store_key)

   gets 61,804 rows instead of 77,155 and loses a fifth of revenue, while the
   query looks completely correct. Documentation does not prevent this; a
   dimension member does.

   So dim_store gains one synthetic row, store_code = 'N/A', and the fact routes
   store-less rows to it with COALESCE(h.store_id, 'N/A'). No NULL FKs anywhere.

   Verified no collision first: real store codes are CC_NNNN (AE_0001 .. US_0050),
   7 characters, and zero rows already use 'N/A', 'NA', '-1' or 'UNKNOWN'.

   TWO DETAILS THAT MATTER MORE THAN THEY LOOK
   --------------------------------------------------------------------
   1. **store_open_date is deliberately NULL on the N/A member.** The
      sale_before_store_open flag in V6.2.1 is written as
      `store_open_date IS NOT NULL AND <date> < store_open_date`, so a NULL open
      date makes the flag FALSE for online sales rather than TRUE-by-accident.
      An online sale cannot predate a store opening.

   2. **is_active is TRUE on the N/A member.** If it were NULL or FALSE, the
      common `WHERE is_active` filter would silently discard all 15,351 online
      rows - reintroducing exactly the bug this script exists to prevent.

   country_code IS NULL on the member, because an online order's country comes
   from the fact, not from a store. Consequence: the dim_store -> dim_country
   orphan check must now exclude store_code = 'N/A'. The validation below does.

   ==========================================================================
   THE QUALIFY MUST SIT OUTSIDE THE UNION ALL
   ==========================================================================
   dim_store's PRIMARY KEY is not declared - dynamic tables accept no constraint
   clause - it is INFERRED by Snowflake from the QUALIFY ROW_NUMBER() = 1 pattern,
   producing SYS_CONSTRAINT_DERIVED_PK with rely = true.

   Appending `UNION ALL SELECT <literals>` after a branch that already had the
   QUALIFY applied would leave the union output not provably unique, and the
   derived PK would be LOST. So the query is restructured: both branches feed a
   subquery, and a single QUALIFY is applied to the combined set at the top level.

   Verified after deployment: SYS_CONSTRAINT_DERIVED_PK on STORE_CODE still
   present, rely = true, and 122 distinct store_key for 122 rows.

   ==========================================================================
   *** CREATE OR ALTER DOES NOT RE-MATERIALISE. AN EXPLICIT REFRESH IS REQUIRED. ***
   ==========================================================================
   This bit cost time once already (see AGENT.md section 5, the __version_hash
   incident in V5.2.2) and it recurred here exactly as documented.

   After `CREATE OR ALTER` returned "Statement executed successfully", the table
   still held 121 rows and the N/A member was ABSENT. The definition had changed;
   the data had not. Because every DT in this repo is TARGET_LAG = DOWNSTREAM and
   gold has no consumer yet, scheduling_state = OFF and nothing refreshes on its
   own - so the stale contents would have persisted indefinitely.

   The ALTER ... REFRESH below is therefore MANDATORY, not tidying. It reported
   insertedRows 122 / deletedRows 121.

   CREATE OR ALTER is otherwise non-destructive: created_on stayed 18:57:24, and
   refresh_mode remained INCREMENTAL with refresh_mode_reason NULL even after the
   UNION ALL was introduced.
   --------------------------------------------------------------------------- */

CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.GOLD.dim_store (
  store_key              VARCHAR COMMENT 'PRIMARY KEY (by construction). SHA1_HEX of store_code. Includes the synthetic N/A member, SHA1_HEX(''N/A''), used by ONLINE sales - see table comment.',
  store_code             VARCHAR COMMENT 'Natural/business key and the grain. Real codes are CC_NNNN (AE_0001 .. US_0050). ALSO CONTAINS the synthetic value ''N/A'' for the online channel - exclude it when counting real stores.',
  store_name             VARCHAR COMMENT 'Store display name. ''Not Applicable - Online Channel'' on the synthetic member.',
  country_code           VARCHAR COMMENT 'FK to GOLD.dim_country, as a NATURAL key not a country_key (dim_country is SCD-2; a stored key would pin one version). NULL ON THE N/A MEMBER ONLY - an online sale gets its country from the fact, not from the store. Orphan checks must exclude store_code = ''N/A''.',
  state_code             VARCHAR COMMENT 'Subdivision code. NULL on 39 real stores - those countries do not subdivide for tax. Expected, not a defect. Also NULL on the N/A member.',
  city                   VARCHAR COMMENT 'City. NULL on the N/A member.',
  postal_code            VARCHAR COMMENT 'Postal code. NULL on the N/A member.',
  address_line1          VARCHAR COMMENT 'Street address. NULL on the N/A member.',
  latitude               NUMBER  COMMENT 'Latitude. Range verified -32.68 to 60.99 across real stores; no Null Island rows. NULL on the N/A member.',
  longitude              NUMBER  COMMENT 'Longitude. Range verified -126.18 to 143.79. NULL on the N/A member.',
  format_code            VARCHAR COMMENT 'Store format: MINI / FLG / MALL. No allow-list asserted - a new format is a business change, not a defect (DQ rule 4). NULL on the N/A member.',
  lifecycle_status       VARCHAR COMMENT 'Store lifecycle. ACTIVE on all 121 real stores; ''N/A'' on the synthetic member.',
  store_open_date        DATE    COMMENT 'THE BUSINESS DATE for this store - 119 distinct values, 2016-04-29 to 2026-04-10. Use THIS for date reasoning, never load_effective_date. *** NULL ON THE N/A MEMBER, which is deliberate: the sale-before-store-open check in fact_sales must not fire for online sales. *** 38,102 sales rows predate their own store opening; compare against EACH STORE OWN open date, never a literal year.',
  store_close_date       DATE    COMMENT 'NULL on all 121 real stores - none has closed. Open-ended state, not a defect.',
  floor_area_sqft        NUMBER  COMMENT 'Floor area. Range 5,205 to 24,570. NULL on the N/A member.',
  annual_rent_usd        NUMBER  COMMENT 'Annual rent USD. Range 660,419 to 19,405,046. Rent-per-sqft reaches 3,690 - prime Apple retail genuinely does, so no plausibility band is asserted. NULL on the N/A member.',
  tax_jurisdiction_code  VARCHAR COMMENT '*** CARRIES NO INFORMATION: every component is derivable from country_code + state_code, verified across all 121 real rows. *** NOT a join key to the tax grain - resolve tax via country_code -> dim_country.tax_code. Retained for source fidelity only.',
  is_active              BOOLEAN COMMENT 'Source is_active. TRUE on all 121 real stores, and TRUE on the N/A member so that filtering is_active does not discard online sales.',
  load_effective_date    DATE    COMMENT 'The source effective_start_date, a single value 2026-04-17. A LOAD DATE, NOT a business date - named load_effective_date so it cannot be mistaken for validity. Filtering 2019 sales on it returns ZERO stores (measured). NULL on the N/A member.',
  scd_version_hash       VARCHAR COMMENT 'SHA1_HEX digest of all conformed attributes. Lets a consumer detect that the store record changed. NOT a validity interval.',
  dq_issue_flags         VARCHAR COMMENT 'Row-level DQ flags from sv_store_master. NULL means no flag. NULL on the N/A member - it is synthetic, not defective.',
  source_system          VARCHAR COMMENT 'Originating source system. ''SYNTHETIC'' on the N/A member, which has no source row.'
)
TARGET_LAG   = DOWNSTREAM
WAREHOUSE    = {{ warehouse }}
REFRESH_MODE = INCREMENTAL
COMMENT      = 'Gold store dimension: 121 real stores + 1 synthetic N/A member = 122 rows. *** THE N/A MEMBER (store_code = ''N/A'') EXISTS SO THE FACT HAS NO NULL FOREIGN KEY. *** 15,351 sales rows (19.9%) are ONLINE and have no store; store_id IS NULL exactly when channel_id = ''ONLINE'' (0 mismatches measured). Without this member those rows would carry a NULL store_key and any consumer inner-joining dim_store would silently lose a fifth of revenue. Exclude store_code = ''N/A'' when counting or geo-mapping real stores. SCD-1, NOT SCD-2: the source effective_start_date is a LOAD date (single value 2026-04-17, after the 2019 fact period) so it cannot serve as validity - joining sales on it returns ZERO rows. Use store_open_date for business dating.'
AS
SELECT
  s.store_key, s.store_code, s.store_name, s.country_code, s.state_code, s.city,
  s.postal_code, s.address_line1, s.latitude, s.longitude, s.format_code,
  s.lifecycle_status, s.store_open_date, s.store_close_date, s.floor_area_sqft,
  s.annual_rent_usd, s.tax_jurisdiction_code, s.is_active, s.load_effective_date,
  s.scd_version_hash, s.dq_issue_flags, s.source_system
FROM (
  SELECT
    SHA1_HEX(b.store_code)                        AS store_key,
    b.store_code, b.store_name, b.country_code, b.state_code, b.city,
    b.postal_code, b.address_line1, b.latitude, b.longitude, b.format_code,
    b.lifecycle_status, b.store_open_date, b.store_close_date, b.floor_area_sqft,
    b.annual_rent_usd, b.tax_jurisdiction_code, b.is_active,
    b.effective_start_date                        AS load_effective_date,
    SHA1_HEX(
        NVL(b.store_name,'~')||'|'||NVL(b.country_code,'~')||'|'||NVL(b.state_code,'~')
     ||'|'||NVL(b.city,'~')||'|'||NVL(b.postal_code,'~')||'|'||NVL(b.address_line1,'~')
     ||'|'||NVL(TO_VARCHAR(b.latitude),'~')||'|'||NVL(TO_VARCHAR(b.longitude),'~')
     ||'|'||NVL(b.format_code,'~')||'|'||NVL(b.lifecycle_status,'~')
     ||'|'||NVL(TO_VARCHAR(b.store_open_date),'~')||'|'||NVL(TO_VARCHAR(b.store_close_date),'~')
     ||'|'||NVL(TO_VARCHAR(b.floor_area_sqft),'~')||'|'||NVL(TO_VARCHAR(b.annual_rent_usd),'~')
     ||'|'||NVL(b.tax_jurisdiction_code,'~')||'|'||NVL(TO_VARCHAR(b.is_active),'~')
    )                                             AS scd_version_hash,
    b.dq_issue_flags, b.source_system,
    b.effective_start_date                        AS ord_1,
    b.__file_name                                 AS ord_2,
    b.__row_number                                AS ord_3
  FROM {{ database }}.SILVER.sv_store_master b
  UNION ALL
  /* The synthetic Not-Applicable member. store_open_date and country_code are
     NULL on purpose, is_active is TRUE on purpose - see the header. */
  SELECT
    SHA1_HEX('N/A'), 'N/A', 'Not Applicable - Online Channel',
    NULL::VARCHAR, NULL::VARCHAR, NULL::VARCHAR, NULL::VARCHAR, NULL::VARCHAR,
    NULL::NUMBER, NULL::NUMBER, NULL::VARCHAR, 'N/A',
    NULL::DATE, NULL::DATE, NULL::NUMBER, NULL::NUMBER, NULL::VARCHAR, TRUE,
    NULL::DATE, SHA1_HEX('N/A'), NULL::VARCHAR, 'SYNTHETIC',
    NULL::DATE, NULL::VARCHAR, NULL::NUMBER
) s
/* QUALIFY sits OUTSIDE the UNION ALL deliberately: applied inside the first
   branch it would be lost and the SYS_CONSTRAINT_DERIVED_PK would disappear. */
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY s.store_code
          ORDER BY     s.ord_1 DESC NULLS LAST, s.ord_2, s.ord_3) = 1;


/* ---------------------------------------------------------------------------
   *** MANDATORY. *** CREATE OR ALTER changes the DEFINITION but does not
   re-materialise, and DOWNSTREAM with no consumer means scheduling_state = OFF,
   so without this the table keeps its old 121 rows indefinitely. Verified: this
   is not belt-and-braces, the N/A member was genuinely absent until it ran.
   --------------------------------------------------------------------------- */
ALTER DYNAMIC TABLE {{ database }}.GOLD.dim_store REFRESH;
-- Recorded: {"insertedRows":122,"copiedRows":0,"deletedRows":121}


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- The derived PK must SURVIVE the UNION ALL. This is the check the restructure
-- exists to pass.
SHOW UNIQUE KEYS IN {{ database }}.GOLD.dim_store;
-- Recorded: STORE_CODE seq 1, SYS_CONSTRAINT_DERIVED_PK, rely = true

SHOW DYNAMIC TABLES LIKE 'dim_store' IN SCHEMA {{ database }}.GOLD;
-- Recorded: rows 122, DOWNSTREAM, INCREMENTAL, refresh_mode_reason NULL,
--           created_on 18:57:24 unchanged (CREATE OR ALTER is non-destructive)

SELECT COUNT(*)                                        AS total_rows,
       COUNT_IF(store_code =  'N/A')                   AS na_member,
       COUNT_IF(store_code <> 'N/A')                   AS real_stores,
       COUNT(DISTINCT store_key)                       AS distinct_keys,
       COUNT_IF(store_open_date IS NULL)               AS null_open_date,
       COUNT_IF(is_active)                             AS active_rows
FROM   {{ database }}.GOLD.dim_store;
-- Recorded: 122, 1, 121, 122, 1, 122
-- null_open_date = 1 is the N/A member, by design.
-- active_rows = 122 confirms the member is not excluded by `WHERE is_active`.

-- The N/A member's identity, so the fact's COALESCE target is unambiguous.
SELECT store_key, store_code, store_name, source_system
FROM   {{ database }}.GOLD.dim_store WHERE store_code = 'N/A';
-- Recorded: 08d2e98e6754af941484848930ccbaddfefe13d6 | N/A |
--           Not Applicable - Online Channel | SYNTHETIC

-- Orphan check, now EXCLUDING the synthetic member (its country_code is NULL
-- by design, so including it would report a false positive).
SELECT COUNT(*) AS real_orphan_country
FROM   {{ database }}.GOLD.dim_store s
WHERE  s.store_code <> 'N/A'
  AND  NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_country d
                    WHERE d.country_code = s.country_code);
-- Recorded: 0
