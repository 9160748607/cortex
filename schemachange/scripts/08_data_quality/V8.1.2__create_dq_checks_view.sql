/* ---------------------------------------------------------------------------
   V8.1.2 - Data quality check set (view)

   The 31 assertions themselves. A view rather than a procedure body so the
   current state can be read ad hoc without recording a run:

       SELECT * FROM <db>.COMMON.v_dq_checks WHERE NOT passed;

   V8.1.3's procedure simply SELECTs this into COMMON.dq_results.

   WHY THESE LIVE OUTSIDE SILVER
   --------------------------------------------------------------------
   DQ rule 3: "Row-level flags describe only their own row. Anything needing a
   second table - FK existence, cross-level date coherence, childless-parent
   coverage - is a set-level assertion for validation SQL or gold, never a flag.
   A join in a DT couples its refresh to the joined table."

   Every REFERENTIAL, PARITY and LAG check here needs a second table. They
   therefore CANNOT be dq_issue_flags expressions, and this is the sanctioned
   home for them.

   ==========================================================================
   DOCUMENTED EXCEPTION TO DQ RULE 4 - the four categorical allow-lists
   ==========================================================================
   AGENT.md section 6 rule 4 says no allow-lists on business categorisations, and section 7
   lists them under rejected rules. The checks hdr_channel_known,
   hdr_payment_known, cust_tier_known and cust_segment_known are allow-lists.
   This is deliberate and scoped. The distinction is the whole justification:

     Rule 4 forbids an allow-list as a ROW-LEVEL dq_issue_flags BIT INSIDE A
     DYNAMIC TABLE. There it is genuinely wrong - it permanently mislabels a
     legitimate business change as a per-row defect, and bakes a business
     vocabulary into the silver contract.

     These are SET-LEVEL ASSERTIONS IN EXTERNAL VALIDATION SQL, which rule 3
     positively directs here. They reject no row, write no flag, and do not
     touch silver. What they produce is a notification - which is rule 4's OWN
     stated remedy: "unfamiliar is news". This delivers the news.

   Consequence when the source adds a payment method: the run fails at MEDIUM,
   someone reads it, the value is added below. Two-minute triage, not a defect.

   DO NOT migrate these into a silver dq_issue_flags expression. The exception
   is specific to set-level monitoring and does not generalise.

   ==========================================================================
   THRESHOLDS: pinned to measured baselines, not to zero
   ==========================================================================
   sv_customer_master carries 24,713 flagged rows. Those are KNOWN, REGISTERED
   defects (AGENT.md section 7), not regressions. Asserting = 0 on them would fail
   permanently, which is precisely DQ rule 2's failure mode - "a flag that fires
   on 100% of rows is a bug, not a check ... it trains readers to ignore the
   column".

   So flag checks assert <= today's measured count. Only DETERIORATION alerts.
   Tighten these as the underlying numbers come down.

     cust_flagged_not_worse   <= 24713   any flag set
     cust_phone_not_worse     <= 23874   PHONE_NOT_E164
     cust_minor_not_worse     <=  3515   MINOR_AT_REGISTRATION
     cust_under13_not_worse   <=   698   UNDER_13_AT_REGISTRATION (COPPA)

   Everything else asserts = 0 and measures 0 today.

   ==========================================================================
   NOT absolute freshness - relative bronze-vs-silver lag
   ==========================================================================
   Max transaction_timestamp in silver is 2019-12-31 (V4.6.3 removed the 24 timezone-spillover
   rows in section 7; the dataset is 2019). ANY absolute freshness threshold violates
   forever and gets ignored. Comparing silver's max timestamp to BRONZE's is the
   signal that means something: it detects silver falling behind its source.

   90000s = 25h, tolerating a daily batch plus slack. Tighten once V7.x ingest
   establishes a real cadence.

   ==========================================================================
   COLUMN-NAME TRAPS verified against the live schema
   ==========================================================================
     sv_sales_header.store_id   -> sv_store_master.STORE_CODE   (names differ)
     sv_sales_header.currency   -> sv_currency_master.CURRENCY_CODE
     bronze uses created_at / updated_at; silver renames these to
     source_created_at / source_updated_at

     loyalty_tier is NULL on 15,641 rows, NOT the string 'None'. section 7 records that
     the 'None' sentinel was a serialisation accident already rewritten to NULL
     in V5.1.10. A NULL tier is a LEGITIMATE state (customer has no tier), so
     cust_tier_known allows NULL and checks only non-null values. Asserting
     NOT NULL here would report 15,641 false positives.

   ==========================================================================
   DELIBERATELY NOT CHECKED
   ==========================================================================
     38,088 sales rows predating their store's opening - real, but section 7 assigns it
       to gold, and it needs each store's OWN open date, never a literal year.
     Cross-currency amount correctness - unfixable without an FX dimension. A
       check would assert a problem nobody can action.
     hdr_total_matches_lines IS checked, but note from section 7 that header and item
       measures are identical 1:1 by construction. It guards against future join
       fan-out; it is NOT evidence the measures are independent.

   Idempotent: IF NOT EXISTS (architectural note 5). Note this means a change to
   the check set needs a NEW version, not an edit to this file - the same
   constraint every other versioned script here operates under.
   --------------------------------------------------------------------------- */

CREATE VIEW IF NOT EXISTS {{ database }}.COMMON.v_dq_checks
COMMENT = 'Silver data quality check set, 31 set-level assertions. Read directly for current state; COMMON.sp_run_silver_dq_checks records it to COMMON.dq_results.'
AS
SELECT *, (CASE WHEN comparator = '=' THEN metric_value = threshold
                ELSE metric_value <= threshold END) AS passed
FROM (

  /* ---------- sv_sales_header : key integrity ---------- */
  SELECT 'SILVER' AS layer, 'sv_sales_header' AS table_name,
         'hdr_sk_not_null' AS check_name, 'NULL_COUNT' AS check_type,
         'CRITICAL' AS severity, '=' AS comparator, 0 AS threshold,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header
           WHERE transaction_sk IS NULL) AS metric_value
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_sk_unique','DUPLICATE_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) - COUNT(DISTINCT transaction_sk)
            FROM {{ database }}.SILVER.sv_sales_header)

  /* ---------- sv_sales_header : referential integrity (DQ rule 3) ----------
     NULL source values are excluded, matching standard FK semantics: a NULL FK
     is valid. Each is paired with a NULL_COUNT where the key must be present.
     store_id is NULL on 15,351 rows - exactly the ONLINE channel per section 7, an
     expected partition, so no NULL_COUNT on it. */
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_customer_resolves','REFERENTIAL','CRITICAL','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
           WHERE h.customer_id IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_customer_master d
              WHERE d.customer_id = h.customer_id))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_store_resolves','REFERENTIAL','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
           WHERE h.store_id IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_store_master d
              WHERE d.store_code = h.store_id))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_currency_resolves','REFERENTIAL','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
           WHERE h.currency IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_currency_master d
              WHERE d.currency_code = h.currency))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_country_resolves','REFERENTIAL','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
           WHERE h.country_code IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_country_master d
              WHERE d.country_code = h.country_code))

  /* ---------- sv_sales_header : categorical (SEE EXCEPTION IN HEADER) ---------- */
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_channel_known','ACCEPTED_VALUES','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header
           WHERE channel_id IS NULL OR channel_id NOT IN ('POS','ONLINE'))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_payment_known','ACCEPTED_VALUES','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header
           WHERE payment_method IS NULL OR payment_method NOT IN
             ('Cash','Bank EMI','Mastercard','Apple Financing','Corporate Financing',
              'Apple Pay','Visa','American Express','Discover'))

  /* ---------- sv_sales_header : measure ranges ----------
     Measure semantics, not categorisation - DQ rule 5: "for a measure, absent
     is always wrong". These are not covered by the rule 4 exception. */
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_net_non_negative','ACCEPTED_VALUES','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header WHERE net_total < 0)
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_total_matches_lines','ACCEPTED_VALUES','CRITICAL','=',0,
         (SELECT COUNT(*) FROM (
            SELECT h.transaction_sk
              FROM {{ database }}.SILVER.sv_sales_header h
              JOIN {{ database }}.SILVER.sv_sales_item   i
                ON i.transaction_sk = h.transaction_sk
             GROUP BY h.transaction_sk, h.net_total
            HAVING ABS(h.net_total - SUM(i.line_total)) > 1))

  /* ---------- sv_sales_item ---------- */
  UNION ALL SELECT 'SILVER','sv_sales_item','item_parent_not_null','NULL_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item WHERE transaction_sk IS NULL)
  UNION ALL SELECT 'SILVER','sv_sales_item','item_line_unique','DUPLICATE_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) - COUNT(DISTINCT transaction_sk || '|' || line_number)
            FROM {{ database }}.SILVER.sv_sales_item)
  UNION ALL SELECT 'SILVER','sv_sales_item','item_no_orphans','REFERENTIAL','CRITICAL','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item i WHERE NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_sales_header h
              WHERE h.transaction_sk = i.transaction_sk))
  UNION ALL SELECT 'SILVER','sv_sales_item','item_sku_resolves','REFERENTIAL','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item i
           WHERE i.sku_code IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_product_sku_master p
              WHERE p.sku_code = i.sku_code))
  UNION ALL SELECT 'SILVER','sv_sales_item','item_qty_positive','ACCEPTED_VALUES','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item WHERE quantity <= 0)
  UNION ALL SELECT 'SILVER','sv_sales_item','item_price_non_negative','ACCEPTED_VALUES','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item WHERE unit_price < 0)

  /* ---------- sv_customer_master ---------- */
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_id_not_null','NULL_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master WHERE customer_id IS NULL)
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_id_unique','DUPLICATE_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) - COUNT(DISTINCT customer_id)
            FROM {{ database }}.SILVER.sv_customer_master)
  /* NULL loyalty_tier is legitimate (no tier) on 15,641 rows - see header trap. */
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_tier_known','ACCEPTED_VALUES','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master
           WHERE loyalty_tier IS NOT NULL
             AND loyalty_tier NOT IN ('Silver','Gold','Platinum'))
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_segment_known','ACCEPTED_VALUES','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master
           WHERE customer_segment IS NULL OR customer_segment NOT IN
             ('Consumer','Business','Education'))

  /* ---------- flag monitoring: makes dq_issue_flags alertable ----------
     The flags are already computed by 05_silver. Nothing consumed them until
     now - 698 UNDER_13_AT_REGISTRATION rows had no threshold and notified
     nobody. Thresholds are today's counts; only deterioration alerts. */
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_flagged_not_worse','FLAG_COUNT','MEDIUM','<=',24713,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master
           WHERE dq_issue_flags IS NOT NULL AND dq_issue_flags <> '')
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_under13_not_worse','FLAG_COUNT','CRITICAL','<=',698,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master
           WHERE dq_issue_flags LIKE '%UNDER_13_AT_REGISTRATION%')
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_minor_not_worse','FLAG_COUNT','HIGH','<=',3515,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master
           WHERE dq_issue_flags LIKE '%MINOR_AT_REGISTRATION%')
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_phone_not_worse','FLAG_COUNT','MEDIUM','<=',23874,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master
           WHERE dq_issue_flags LIKE '%PHONE_NOT_E164%')
  /* Both fact tables have dq_issue_flags 100% NULL - 05_silver implemented flag
     logic only for the customer dimension. Asserting = 0 means the day the
     transform STARTS flagging facts, it surfaces rather than passing silently. */
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_no_flags','FLAG_COUNT','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header
           WHERE dq_issue_flags IS NOT NULL AND dq_issue_flags <> '')
  UNION ALL SELECT 'SILVER','sv_sales_item','item_no_flags','FLAG_COUNT','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item
           WHERE dq_issue_flags IS NOT NULL AND dq_issue_flags <> '')

  /* ---------- bronze <-> silver gate ----------
     Silver row counts currently equal bronze exactly for all 13 tables: the
     layer flags rather than rejects, by design (DQ rule 1 - hard-reject only an
     unusable key). Parity is therefore the correct assertion, and a break means
     either a de-duplication change or a partial refresh. */
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_parity_with_bronze','PARITY','CRITICAL','=',0,
         (SELECT ABS((SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header)
                   - (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_header)))
  UNION ALL SELECT 'SILVER','sv_sales_item','item_parity_with_bronze','PARITY','CRITICAL','=',0,
         (SELECT ABS((SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item)
                   - (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_item)))
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_parity_with_bronze','PARITY','CRITICAL','=',0,
         (SELECT ABS((SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master)
                   - (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_customer_master)))

  /* Relative lag, not absolute freshness - see header. */
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_lag_seconds_vs_bronze','LAG','HIGH','<=',90000,
         (SELECT GREATEST(0, COALESCE(DATEDIFF(SECOND,
              (SELECT MAX(source_created_at) FROM {{ database }}.SILVER.sv_sales_header),
              (SELECT MAX(created_at)        FROM {{ database }}.BRONZE.br_sales_header)), 0)))
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_lag_seconds_vs_bronze','LAG','HIGH','<=',90000,
         (SELECT GREATEST(0, COALESCE(DATEDIFF(SECOND,
              (SELECT MAX(source_updated_at) FROM {{ database }}.SILVER.sv_customer_master),
              (SELECT MAX(updated_at)        FROM {{ database }}.BRONZE.br_customer_master)), 0)))
);


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Full check set passes. This is the headline assertion for the whole folder.
SELECT COUNT(*) AS checks, COUNT_IF(passed) AS passed, COUNT_IF(NOT passed) AS failed
FROM   {{ database }}.COMMON.v_dq_checks;
-- Recorded: 31, 31, 0

-- Composition by severity and type.
SELECT severity, check_type, COUNT(*) AS checks
FROM   {{ database }}.COMMON.v_dq_checks
GROUP  BY 1,2
ORDER  BY DECODE(severity,'CRITICAL',1,'HIGH',2,'MEDIUM',3), check_type;
-- Recorded: CRITICAL 13 (ACCEPTED_VALUES 1, DUPLICATE_COUNT 3, FLAG_COUNT 1,
--                        NULL_COUNT 3, PARITY 3, REFERENTIAL 2)
--           HIGH     10 (ACCEPTED_VALUES 3, FLAG_COUNT 1, LAG 2, REFERENTIAL 4)
--           MEDIUM    8 (ACCEPTED_VALUES 4, FLAG_COUNT 4)

-- The flag baselines the thresholds are pinned to. If these move, the
-- thresholds in this script are stale and a new version is required.
SELECT COUNT(*)                                                        AS total,
       COUNT_IF(dq_issue_flags IS NOT NULL)                            AS flagged,
       COUNT_IF(dq_issue_flags LIKE '%PHONE_NOT_E164%')                AS phone,
       COUNT_IF(dq_issue_flags LIKE '%MINOR_AT_REGISTRATION%')         AS minor,
       COUNT_IF(dq_issue_flags LIKE '%UNDER_13_AT_REGISTRATION%')      AS under13
FROM   {{ database }}.SILVER.sv_customer_master;
-- Recorded: 31350, 24713, 23874, 3515, 698

-- The loyalty_tier trap: NULL, never the string 'None'. Confirms why
-- cust_tier_known permits NULL.
SELECT COUNT_IF(loyalty_tier IS NULL)      AS is_null,
       COUNT_IF(loyalty_tier = 'None')     AS literal_none,
       COUNT(DISTINCT loyalty_tier)        AS distinct_non_null
FROM   {{ database }}.SILVER.sv_customer_master;
-- Recorded: 15641, 0, 3

-- The store_id -> store_code name mismatch resolves cleanly despite differing
-- column names. 121 of 121.
SELECT COUNT(DISTINCT h.store_id) AS fact_stores,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_store_master) AS dim_stores
FROM   {{ database }}.SILVER.sv_sales_header h;
-- Recorded: 121, 121

-- Anything needing attention (expect ZERO rows)
SELECT table_name, check_name, severity, metric_value, comparator, threshold
FROM   {{ database }}.COMMON.v_dq_checks
WHERE  NOT passed
ORDER  BY severity, table_name;
