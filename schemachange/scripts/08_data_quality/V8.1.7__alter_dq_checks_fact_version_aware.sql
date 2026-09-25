/* ---------------------------------------------------------------------------
   V8.1.7 - Make fact checks version-aware after V5.2.2

   V5.2.1 made 7 silver tables version-preserving and V8.1.6 adapted the one
   check that broke (cust_id_unique). V5.2.2 then made the remaining 6 - including
   BOTH FACT TABLES - version-preserving too. Three more checks need adapting, and
   two of them are the ones standing between a corrected transaction and
   double-counted revenue.

   ==========================================================================
   1 & 2. hdr_sk_unique / item_line_unique - REDEFINED, NOT LOOSENED
   ==========================================================================
   Before:  COUNT(*) - COUNT(DISTINCT transaction_sk) = 0
            i.e. "exactly one row per key"

   After:   COUNT of keys HAVING COUNT_IF(__is_current_version) <> 1
            i.e. "exactly one CURRENT version per key"

   This is deliberately NOT a relaxation. The old assertion becomes false by
   design the moment a correction arrives, so keeping it would produce a false
   CRITICAL. But simply deleting it would remove the only guard on the invariant
   that actually matters:

       If a key ever has ZERO current versions, every measure for that
       transaction VANISHES from a filtered aggregate.
       If a key ever has TWO, the transaction is DOUBLE-COUNTED.

   Both are silent. Neither changes the row count in a way a reader would notice.
   So the new form is strictly stronger than the old one for the failure modes
   that now exist, and it is the reason a versioned fact table is safe to build on
   at all.

   ==========================================================================
   3. hdr_total_matches_lines - MUST filter BOTH sides
   ==========================================================================
   This check joins header to item and compares net_total to SUM(line_total).
   Unfiltered, once versions exist, it joins every header version to every item
   version of the same transaction - an N x M fan-out. SUM(line_total) then
   includes superseded lines and the comparison is meaningless: the check would
   report a formula break where the data is fine.

   Now filters h.__is_current_version AND i.__is_current_version. Note this is
   the reconciliation check the whole revenue figure rests on, so it has to be
   right for the right reason, not merely passing.

   ==========================================================================
   CHECKS EXAMINED AND DELIBERATELY LEFT ALONE
   ==========================================================================
     hdr_customer_resolves, hdr_store_resolves, hdr_currency_resolves,
     hdr_country_resolves, item_no_orphans, item_sku_resolves
         All NOT EXISTS existence tests. Multiple versions on either side do not
         change existence, so they remain correct. NOTE the limitation: because
         they test existence rather than cardinality, they will NOT detect
         fan-out. Fan-out is a fact-build concern - see 06_gold/README.md.

     *_parity_with_bronze
         Both sides count all rows and silver rejects nothing, so parity holds
         regardless of versioning.

     hdr_no_flags / item_no_flags
         Assert zero flagged fact rows. Still correct - a new version of a clean
         row is also clean.

     All FLAG_COUNT thresholds
         These count ROWS. Once versions exist the counts rise simply because
         there are more rows, and the thresholds will need REBASELINING then.
         Deliberately not loosened now: pre-emptively widening a threshold before
         there is data to justify it is how a monitor stops meaning anything.

     cust_id_unique
         Already made version-aware in V8.1.6, on (customer_id,
         source_updated_at). Left as-is - sv_customer_master versions on
         updated_at, not on a content hash, so it has no __is_current_version
         column.

   Total check count unchanged at 31.

   ASYMMETRY WORTH KNOWING
   --------------------------------------------------------------------
   Silver now has two version styles, so "current version" is expressed two ways:
       7 tables (V5.2.1)  temporal discriminator, NO __is_current_version column.
                          Currency is derived downstream - dim_country uses
                          MAX(valid_from) per key.
       6 tables (V5.2.2)  content-hash discriminator, WITH __is_current_version.
                          There is no temporal ordering to derive currency from,
                          so the flag is materialised in silver.
   That is a consequence of what the sources provide, not an inconsistency of
   intent. Do not "harmonise" it by adding the flag to the temporal tables -
   valid_from ordering is strictly more informative.
   --------------------------------------------------------------------------- */

CREATE OR ALTER VIEW {{ database }}.COMMON.v_dq_checks
COMMENT = 'Silver data quality check set, 31 set-level assertions. Read directly for current state; COMMON.sp_run_silver_dq_checks records it to COMMON.dq_results. ALL 13 silver tables are now version-preserving, so uniqueness checks assert EXACTLY ONE CURRENT VERSION per key, and cross-table reconciliation filters __is_current_version. See V8.1.7.'
AS
SELECT *, (CASE WHEN comparator = '=' THEN metric_value = threshold
                ELSE metric_value <= threshold END) AS passed
FROM (
  SELECT 'SILVER' AS layer, 'sv_sales_header' AS table_name,
         'hdr_sk_not_null' AS check_name, 'NULL_COUNT' AS check_type,
         'CRITICAL' AS severity, '=' AS comparator, 0 AS threshold,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header
           WHERE transaction_sk IS NULL) AS metric_value
  /* VERSION-AWARE (V8.1.7): zero current versions loses the transaction, two
     double-counts it. Both silent. See header. */
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_sk_unique','DUPLICATE_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) FROM (SELECT transaction_sk FROM {{ database }}.SILVER.sv_sales_header
            GROUP BY transaction_sk HAVING COUNT_IF(__is_current_version) <> 1))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_customer_resolves','REFERENTIAL','CRITICAL','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
           WHERE h.customer_id IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_customer_master d WHERE d.customer_id = h.customer_id))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_store_resolves','REFERENTIAL','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
           WHERE h.store_id IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_store_master d WHERE d.store_code = h.store_id))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_currency_resolves','REFERENTIAL','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
           WHERE h.currency IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_currency_master d WHERE d.currency_code = h.currency))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_country_resolves','REFERENTIAL','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
           WHERE h.country_code IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_country_master d WHERE d.country_code = h.country_code))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_channel_known','ACCEPTED_VALUES','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header
           WHERE channel_id IS NULL OR channel_id NOT IN ('POS','ONLINE'))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_payment_known','ACCEPTED_VALUES','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header
           WHERE payment_method IS NULL OR payment_method NOT IN
             ('Cash','Bank EMI','Mastercard','Apple Financing','Corporate Financing',
              'Apple Pay','Visa','American Express','Discover'))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_net_non_negative','ACCEPTED_VALUES','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header WHERE net_total < 0)
  /* VERSION-AWARE (V8.1.7): filters BOTH sides. Unfiltered this is an N x M
     fan-out across version pairs and the arithmetic is meaningless. */
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_total_matches_lines','ACCEPTED_VALUES','CRITICAL','=',0,
         (SELECT COUNT(*) FROM (
            SELECT h.transaction_sk FROM {{ database }}.SILVER.sv_sales_header h
              JOIN {{ database }}.SILVER.sv_sales_item i ON i.transaction_sk = h.transaction_sk
             WHERE h.__is_current_version AND i.__is_current_version
             GROUP BY h.transaction_sk, h.net_total
            HAVING ABS(h.net_total - SUM(i.line_total)) > 1))
  UNION ALL SELECT 'SILVER','sv_sales_item','item_parent_not_null','NULL_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item WHERE transaction_sk IS NULL)
  /* VERSION-AWARE (V8.1.7) - see hdr_sk_unique. */
  UNION ALL SELECT 'SILVER','sv_sales_item','item_line_unique','DUPLICATE_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) FROM (SELECT transaction_line_id FROM {{ database }}.SILVER.sv_sales_item
            GROUP BY transaction_line_id HAVING COUNT_IF(__is_current_version) <> 1))
  UNION ALL SELECT 'SILVER','sv_sales_item','item_no_orphans','REFERENTIAL','CRITICAL','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item i WHERE NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_sales_header h WHERE h.transaction_sk = i.transaction_sk))
  UNION ALL SELECT 'SILVER','sv_sales_item','item_sku_resolves','REFERENTIAL','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item i
           WHERE i.sku_code IS NOT NULL AND NOT EXISTS
            (SELECT 1 FROM {{ database }}.SILVER.sv_product_sku_master p WHERE p.sku_code = i.sku_code))
  UNION ALL SELECT 'SILVER','sv_sales_item','item_qty_positive','ACCEPTED_VALUES','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item WHERE quantity <= 0)
  UNION ALL SELECT 'SILVER','sv_sales_item','item_price_non_negative','ACCEPTED_VALUES','HIGH','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item WHERE unit_price < 0)
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_id_not_null','NULL_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master WHERE customer_id IS NULL)
  /* Version-aware since V8.1.6. Versions on updated_at, so no
     __is_current_version column exists here - see the asymmetry note in the header. */
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_id_unique','DUPLICATE_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) - COUNT(DISTINCT customer_id || '|' ||
                   COALESCE(TO_VARCHAR(source_updated_at),'~'))
            FROM {{ database }}.SILVER.sv_customer_master)
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_tier_known','ACCEPTED_VALUES','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master
           WHERE loyalty_tier IS NOT NULL AND loyalty_tier NOT IN ('Silver','Gold','Platinum'))
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_segment_known','ACCEPTED_VALUES','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master
           WHERE customer_segment IS NULL OR customer_segment NOT IN ('Consumer','Business','Education'))
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
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_no_flags','FLAG_COUNT','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header
           WHERE dq_issue_flags IS NOT NULL AND dq_issue_flags <> '')
  UNION ALL SELECT 'SILVER','sv_sales_item','item_no_flags','FLAG_COUNT','MEDIUM','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item
           WHERE dq_issue_flags IS NOT NULL AND dq_issue_flags <> '')
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_parity_with_bronze','PARITY','CRITICAL','=',0,
         (SELECT ABS((SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header)
                   - (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_header)))
  UNION ALL SELECT 'SILVER','sv_sales_item','item_parity_with_bronze','PARITY','CRITICAL','=',0,
         (SELECT ABS((SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item)
                   - (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_item)))
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_parity_with_bronze','PARITY','CRITICAL','=',0,
         (SELECT ABS((SELECT COUNT(*) FROM {{ database }}.SILVER.sv_customer_master)
                   - (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_customer_master)))
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_lag_seconds_vs_bronze','LAG','HIGH','<=',90000,
         (SELECT GREATEST(0, COALESCE(DATEDIFF(SECOND,
              (SELECT MAX(source_created_at) FROM {{ database }}.SILVER.sv_sales_header),
              (SELECT MAX(created_at) FROM {{ database }}.BRONZE.br_sales_header)), 0)))
  UNION ALL SELECT 'SILVER','sv_customer_master','cust_lag_seconds_vs_bronze','LAG','HIGH','<=',90000,
         (SELECT GREATEST(0, COALESCE(DATEDIFF(SECOND,
              (SELECT MAX(source_updated_at) FROM {{ database }}.SILVER.sv_customer_master),
              (SELECT MAX(updated_at) FROM {{ database }}.BRONZE.br_customer_master)), 0)))
);


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SELECT COUNT(*) AS checks, COUNT_IF(passed) AS passed, COUNT_IF(NOT passed) AS failed
FROM   {{ database }}.COMMON.v_dq_checks;
-- Recorded: 31, 31, 0

-- The three redefined checks specifically.
SELECT check_name, metric_value, comparator, threshold, passed
FROM   {{ database }}.COMMON.v_dq_checks
WHERE  check_name IN ('hdr_sk_unique','item_line_unique','hdr_total_matches_lines')
ORDER  BY check_name;
-- Recorded: hdr_sk_unique 0 = 0 TRUE
--           hdr_total_matches_lines 0 = 0 TRUE
--           item_line_unique 0 = 0 TRUE

CALL {{ database }}.COMMON.sp_run_silver_dq_checks();
-- Recorded: total=31 failed=0 critical=0
