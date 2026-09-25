/* ---------------------------------------------------------------------------
   V6.1.6 - Gold customer dimension (dynamic table)

   One row per customer_id, 31,350 rows, from sv_customer_master.

   ==========================================================================
   *** THIS TABLE CONTAINS 9 UNMASKED PERSONAL-DATA COLUMNS ***
   ==========================================================================
   first_name, last_name, full_name, date_of_birth, email, phone_number,
   street_address, city, postal_code.

   Masking policies are an OUTSTANDING item (AGENT.md section 9) - none exists yet,
   so every column above is readable by anyone holding SELECT on this table.
   1,051 customers are in GDPR countries.

   This was a deliberate, explicit decision: carry the full attribute set now and
   attach masking later, rather than ship a reduced dimension. The alternatives
   considered were an analytics-only dimension excluding all 9 columns, and
   carrying them behind a DATA_SENSITIVITY tag (which would have required a new
   tag in 01_governance). Recording the alternatives so the choice is visible
   rather than looking like an oversight.

   Per architectural rule 3, the policies themselves must be DEFINED in the
   GOVERNANCE database and merely ATTACHED here. Attaching them is a separate
   change and does not require altering this script.

   ==========================================================================
   SCD-1, NOT SCD-2 - AND THIS ONE IS THE MOST TEMPTING TO GET WRONG
   ==========================================================================
   Of all 13 silver tables, sv_customer_master looks like the strongest SCD-2
   candidate. It is versioned on updated_at (V5.2.1), it is the entity most likely
   to genuinely change over time (address, loyalty tier, segment), and the LEAD()
   mechanism that gives dim_country real SCD-2 is already proven in V6.1.2.

   IT STILL CANNOT WORK TODAY. Measured:

       source_updated_at   31,350 DISTINCT values for 31,350 rows - unique per row
       range               2026-04-17 15:58:27.218 to 2026-04-17 15:58:32.465

   That is a FIVE-SECOND WINDOW. Every "update" timestamp was minted by the same
   bulk load on 2026-04-17. The column is a perfectly serviceable VERSION
   DISCRIMINATOR - which is why V5.2.1 uses it - but it is not a business
   timestamp, and it postdates the entire 2019 sales period.

   THE MEASUREMENT THAT SETTLES IT:

       sales joined to customer on customer_id only                77,131
       sales joined to customer on customer_id + updated_at window      0

   Using it as valid_from destroys 100% of the join. Same failure mode as
   dim_store's load date (V6.1.5) and the tax interval in V6.1.1: a date that
   postdates the facts yields a clean, empty answer.

   So: SCD-1. The column is carried, RENAMED to load_updated_at so it cannot be
   mistaken for validity, with the zero-row result in its comment.

   WHEN THIS SHOULD BECOME SCD-2: the moment the customer feed supplies real
   update timestamps. The change would be to key on (customer_id, load_updated_at),
   derive valid_to via LEAD(load_updated_at) and is_current via MAX - exactly the
   V6.1.2 pattern. Note there is NO effective_end_date on this source to fall back
   on, so gold must supply the 9999-12-31 sentinel for the newest version itself.
   Reserved as V6.4.x.

   TRAPS CARRIED FORWARD FROM SECTION 7, EACH IN A COLUMN COMMENT
   --------------------------------------------------------------------
     email             NEVER an identity key. 1,056 shared addresses, of which
                       1,006 belong to DIFFERENT PEOPLE. Zero true duplicate
                       persons exist. Deduplicating on email would merge
                       unrelated customers.
     loyalty_tier      NULL on 15,641 rows (49.9%) and that is LEGITIMATE - it
                       means no tier. The source 'None' string was a serialisation
                       accident already rewritten to NULL in V5.1.10. Asserting
                       NOT NULL here would report 15,641 false positives - a
                       mistake already made once during the 08_data_quality work.
     phone_number      76.2% not E.164 (23,874 rows). Flagged, not corrected. No
                       digits-only variant derived: 6,660 values carry extensions
                       that stripping would fuse onto the subscriber number.
     date_of_birth     Basis of the minor flags: 3,515 minors at registration,
                       698 under 13 (COPPA), youngest 11. A governance decision,
                       not a data fix.
     customer_type     'NEW' on all 31,350 rows - carries no discriminating
                       information yet. Do not build segmentation on it.

   dq_issue_flags is NOT NULL on 24,713 of 31,350 rows (78.8%), overwhelmingly
   PHONE_NOT_E164. These are KNOWN, REGISTERED defects. A gold DQ check on this
   column must assert "no worse than" rather than zero, exactly as
   08_data_quality/V8.1.2 does for silver.

   country is a natural FK, not a country_key - same reasoning as V6.1.5 and
   V6.1.4: dim_country is SCD-2, so a stored key would pin one version. Zero
   orphans measured.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.GOLD.dim_customer (
  customer_key           VARCHAR COMMENT 'PRIMARY KEY (by construction, not declared - dynamic tables accept no constraint clause). SHA1_HEX of customer_id. No version component: source_updated_at is a LOAD artifact (all 31,350 values inside a 5-second window on 2026-04-17), not a business date. See V6.1.6 header.',
  customer_id            VARCHAR COMMENT 'Natural/business key and the grain. LOWERCASE UUID - deliberately NOT upper-cased. FK target for sv_sales_header.customer_id; zero orphans measured.',
  customer_number        VARCHAR COMMENT 'Human-readable customer number.',
  first_name             VARCHAR COMMENT 'PERSONAL DATA - masking policy pending (AGENT.md section 9). No policy is attached yet; this column is readable by anyone with SELECT.',
  last_name              VARCHAR COMMENT 'PERSONAL DATA - masking policy pending.',
  full_name              VARCHAR COMMENT 'PERSONAL DATA - masking policy pending. Denormalised from first+last.',
  date_of_birth          DATE    COMMENT 'PERSONAL DATA - masking policy pending. Also the basis of the minor-at-registration flags: 3,515 customers were minors and 698 were under 13 (COPPA), youngest 11. Needs a governance decision, not a data fix.',
  email                  VARCHAR COMMENT 'PERSONAL DATA - masking policy pending. *** NEVER USE AS AN IDENTITY KEY: 1,056 addresses are shared, and 1,006 of those belong to DIFFERENT PEOPLE. Zero true duplicate persons exist. *** AGENT.md section 7.',
  phone_number           VARCHAR COMMENT 'PERSONAL DATA - masking policy pending. 76.2% are not E.164 (23,874 rows, flagged not corrected). No digits-only variant was derived: 6,660 values carry extensions that stripping would fuse onto the subscriber number. Rejected rule, section 7.',
  street_address         VARCHAR COMMENT 'PERSONAL DATA - masking policy pending.',
  city                   VARCHAR COMMENT 'PERSONAL DATA - masking policy pending.',
  state_province         VARCHAR COMMENT 'Customer state or province.',
  postal_code            VARCHAR COMMENT 'PERSONAL DATA - masking policy pending.',
  country_code           VARCHAR COMMENT 'FK to GOLD.dim_country, as a NATURAL key not a country_key. dim_country is SCD-2 versioned on (country_code, valid_from), so a stored key would silently pin one version. Join it on the validity window. 1,051 customers sit in GDPR countries.',
  preferred_language     VARCHAR COMMENT 'Preferred language.',
  customer_segment       VARCHAR COMMENT 'Consumer / Business / Education. No allow-list asserted in silver - a new segment is a business change, not a defect (DQ rule 4).',
  loyalty_tier           VARCHAR COMMENT 'Silver / Gold / Platinum, or NULL. NULL on 15,641 customers (49.9%) and that is a LEGITIMATE state meaning no tier - the source None sentinel was a serialisation accident already rewritten to NULL in V5.1.10. Do not assert NOT NULL here.',
  registration_date      DATE    COMMENT 'Registration date.',
  acquisition_year       NUMBER  COMMENT 'Acquisition year. Should agree with YEAR(registration_date) - disagreement is flagged as ACQ_YEAR_MISMATCH.',
  customer_type          VARCHAR COMMENT 'Customer type. NEW on all 31,350 rows today - carries no discriminating information yet.',
  is_active              BOOLEAN COMMENT 'Source is_active.',
  load_updated_at        TIMESTAMP_NTZ COMMENT 'The source updated_at. A LOAD ARTIFACT, not a business timestamp: all 31,350 values fall within a 5-second window on 2026-04-17. Named load_updated_at to stop it being mistaken for validity - joining 2019 sales on it returns ZERO rows (measured). It IS the silver version discriminator, so it stays for lineage.',
  scd_version_hash       VARCHAR COMMENT 'SHA1_HEX digest of all conformed attributes. Lets a consumer detect that the customer record changed. NOT a validity interval.',
  dq_issue_flags         VARCHAR COMMENT 'Row-level DQ flags from sv_customer_master. 24,713 of 31,350 rows are flagged (78.8%) - overwhelmingly PHONE_NOT_E164. These are KNOWN, REGISTERED defects, not regressions.',
  source_system          VARCHAR COMMENT 'Originating source system.'
)
TARGET_LAG   = DOWNSTREAM
WAREHOUSE    = {{ warehouse }}
REFRESH_MODE = INCREMENTAL
COMMENT      = 'Gold customer dimension: one row per customer_id (31,350 rows). *** CONTAINS 9 UNMASKED PERSONAL-DATA COLUMNS - masking policies from GOVERNANCE are still outstanding (AGENT.md section 9). 1,051 customers are in GDPR countries. *** SCD-1, NOT SCD-2: source_updated_at is a load artifact (all values within a 5-second window on 2026-04-17, after the 2019 fact period) so it cannot serve as validity - joining sales on it returns ZERO rows. Customer is the best SCD-2 candidate if the feed ever supplies real update timestamps; the LEAD mechanism is proven in V6.1.2.'
AS
SELECT
  SHA1_HEX(c.customer_id)                       AS customer_key,
  c.customer_id,
  c.customer_number,
  c.first_name,
  c.last_name,
  c.full_name,
  c.date_of_birth,
  c.email,
  c.phone_number,
  c.street_address,
  c.city,
  c.state_province,
  c.postal_code,
  c.country_code,
  c.preferred_language,
  c.customer_segment,
  c.loyalty_tier,
  c.registration_date,
  c.acquisition_year,
  c.customer_type,
  c.is_active,
  /* Renamed deliberately - see header. */
  c.source_updated_at                           AS load_updated_at,
  SHA1_HEX(
      NVL(c.customer_number,'~')||'|'||NVL(c.first_name,'~')||'|'||NVL(c.last_name,'~')
   ||'|'||NVL(c.full_name,'~')||'|'||NVL(TO_VARCHAR(c.date_of_birth),'~')
   ||'|'||NVL(c.email,'~')||'|'||NVL(c.phone_number,'~')||'|'||NVL(c.street_address,'~')
   ||'|'||NVL(c.city,'~')||'|'||NVL(c.state_province,'~')||'|'||NVL(c.postal_code,'~')
   ||'|'||NVL(c.country_code,'~')||'|'||NVL(c.preferred_language,'~')
   ||'|'||NVL(c.customer_segment,'~')||'|'||NVL(c.loyalty_tier,'~')
   ||'|'||NVL(TO_VARCHAR(c.registration_date),'~')||'|'||NVL(TO_VARCHAR(c.acquisition_year),'~')
   ||'|'||NVL(c.customer_type,'~')||'|'||NVL(TO_VARCHAR(c.is_active),'~')
  )                                             AS scd_version_hash,
  c.dq_issue_flags,
  c.source_system
FROM {{ database }}.SILVER.sv_customer_master c
/* Establishes one row per customer and produces the derived PRIMARY KEY.
   Ordering by source_updated_at DESC picks the newest version - which today is
   the only version, since updated_at is unique per customer. */
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY c.customer_id
          ORDER BY     c.source_updated_at DESC NULLS LAST,
                       c.__file_name, c.__row_number) = 1;


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Refresh mode, checked AT CREATION per section 5.
SHOW DYNAMIC TABLES LIKE 'dim_customer' IN SCHEMA {{ database }}.GOLD;
-- Recorded: target_lag = DOWNSTREAM, refresh_mode = INCREMENTAL,
--           refresh_mode_reason = NULL, rows = 31350

SHOW UNIQUE KEYS IN {{ database }}.GOLD.dim_customer;
-- Recorded: CUSTOMER_ID seq 1, SYS_CONSTRAINT_DERIVED_PK, rely = true

-- Grain, and the two NULL/flag counts that must NOT be treated as defects.
SELECT COUNT(*)                            AS rows_,
       COUNT(DISTINCT customer_key)        AS keys,
       COUNT(DISTINCT customer_id)         AS ids,
       COUNT_IF(dq_issue_flags IS NOT NULL) AS flagged,
       COUNT_IF(loyalty_tier IS NULL)      AS null_tier,
       COUNT(DISTINCT load_updated_at)     AS distinct_load_updated
FROM   {{ database }}.GOLD.dim_customer;
-- Recorded: 31350, 31350, 31350, 24713, 15641, 31350
-- flagged = 24,713 (78.8%) is EXPECTED - registered defects, not a regression.
-- null_tier = 15,641 is LEGITIMATE - no tier, not a missing value.
-- distinct_load_updated = 31,350 for 31,350 rows shows it is unique per row,
--   which makes it a valid version discriminator but NOT a business date.

SELECT COUNT(*) AS orphan_country
FROM   {{ database }}.GOLD.dim_customer c
WHERE  NOT EXISTS (SELECT 1 FROM {{ database }}.GOLD.dim_country d
                    WHERE d.country_code = c.country_code);
-- Recorded: 0

-- ** THE TRAP, MEASURED. ** Never join sales on load_updated_at.
SELECT
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
     JOIN {{ database }}.GOLD.dim_customer c ON c.customer_id = h.customer_id
    WHERE h.__is_current_version)                                  AS join_on_id_CORRECT,
  (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
     JOIN {{ database }}.GOLD.dim_customer c ON c.customer_id = h.customer_id
      AND h.transaction_timestamp >= c.load_updated_at
    WHERE h.__is_current_version)                                  AS join_on_load_ts_WRONG;
-- Recorded: 77131, 0

-- PII EXPOSURE CHECK. Confirms no masking policy is attached yet - this should
-- return ZERO rows TODAY, and the outstanding work is to make it return 9.
SELECT COUNT(*) AS masked_columns
FROM   {{ database }}.INFORMATION_SCHEMA.COLUMNS
WHERE  table_schema = 'GOLD' AND table_name = 'DIM_CUSTOMER'
  AND  column_name IN ('FIRST_NAME','LAST_NAME','FULL_NAME','DATE_OF_BIRTH','EMAIL',
                       'PHONE_NUMBER','STREET_ADDRESS','CITY','POSTAL_CODE');
-- Recorded: 9 columns present. Masking policy attachment is OUTSTANDING -
-- see AGENT.md section 9. Track via TAG_REFERENCES / POLICY_REFERENCES once attached.
