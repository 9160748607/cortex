/* ---------------------------------------------------------------------------
   V8.1.6 - Make uniqueness checks version-aware

   V5.2.1 changed the silver grain on 7 master tables so a changed record is
   preserved as a new version instead of being discarded as a duplicate. One
   check in V8.1.2 asserts a grain that no longer holds.

   THE BREAKING CHECK
   --------------------------------------------------------------------
       cust_id_unique   COUNT(*) - COUNT(DISTINCT customer_id) = 0

   sv_customer_master is now one row per (customer_id, source_updated_at). The
   moment a second version of any customer arrives, COUNT(*) exceeds
   COUNT(DISTINCT customer_id) and this CRITICAL check fails - reporting a defect
   where the pipeline is working exactly as designed.

   That is the SAME LATENT-FAILURE CLASS the V5.2.1 change was made to fix: an
   assertion that is correct today and silently wrong the moment real data
   arrives. It is worth fixing in the same breath, not after the first false alarm
   trains someone to ignore a CRITICAL alert.

   THE FIX
   --------------------------------------------------------------------
       COUNT(*) - COUNT(DISTINCT customer_id || '|' ||
                        COALESCE(TO_VARCHAR(source_updated_at),'~')) = 0

   The COALESCE sentinel matters. A NULL source_updated_at would make the
   concatenation NULL, COUNT(DISTINCT) would skip the row entirely, and the check
   would under-count duplicates - failing open, which is the worst failure mode
   for a CRITICAL assertion. '~' makes a NULL version distinguishable and
   countable.

   CHECKS DELIBERATELY NOT CHANGED
   --------------------------------------------------------------------
     hdr_sk_unique, item_line_unique
         Facts. V5.2.1 deliberately left sv_sales_header and sv_sales_item on the
         business key alone - a transaction is immutable, and versioning one would
         double-count revenue. So single-key uniqueness is still correct here, and
         these checks must STAY strict.

     cust_parity_with_bronze
         Still correct. Both sides count all rows, and silver rejects nothing, so
         parity holds whether or not versions exist.

     hdr_customer_resolves
         Still correct. It is a NOT EXISTS existence test, not a cardinality test,
         so multiple customer versions do not affect it. Note this means it will
         NOT detect fan-out - that is a fact-side concern, recorded as a
         carry-forward in 06_gold/README.md.

     cust_flagged_not_worse and the other FLAG_COUNT thresholds
         These count ROWS carrying a flag. Once versions exist the counts will
         rise simply because there are more rows, so the thresholds will need
         rebaselining THEN - not now. Flagged here rather than pre-emptively
         loosened, because loosening a threshold before there is data to justify
         it is how a monitor stops meaning anything.

   MECHANISM: CREATE OR ALTER VIEW rather than CREATE OR REPLACE. Same reasoning
   as V5.2.1 - declarative, and it does not drop the object. A view holds no data,
   so this is a mild case regardless.

   Total check count is unchanged at 31.
   --------------------------------------------------------------------------- */

CREATE OR ALTER VIEW {{ database }}.COMMON.v_dq_checks
COMMENT = 'Silver data quality check set, 31 set-level assertions. Read directly for current state; COMMON.sp_run_silver_dq_checks records it to COMMON.dq_results. Uniqueness checks on versioned master tables use the COMPOUND (key, version) grain - see V8.1.6.'
AS
SELECT *, (CASE WHEN comparator = '=' THEN metric_value = threshold
                ELSE metric_value <= threshold END) AS passed
FROM (
  SELECT 'SILVER' AS layer, 'sv_sales_header' AS table_name,
         'hdr_sk_not_null' AS check_name, 'NULL_COUNT' AS check_type,
         'CRITICAL' AS severity, '=' AS comparator, 0 AS threshold,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header
           WHERE transaction_sk IS NULL) AS metric_value
  /* Fact - single-key uniqueness stays strict. See header. */
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_sk_unique','DUPLICATE_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) - COUNT(DISTINCT transaction_sk) FROM {{ database }}.SILVER.sv_sales_header)
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
  UNION ALL SELECT 'SILVER','sv_sales_header','hdr_total_matches_lines','ACCEPTED_VALUES','CRITICAL','=',0,
         (SELECT COUNT(*) FROM (
            SELECT h.transaction_sk FROM {{ database }}.SILVER.sv_sales_header h
              JOIN {{ database }}.SILVER.sv_sales_item i ON i.transaction_sk = h.transaction_sk
             GROUP BY h.transaction_sk, h.net_total
            HAVING ABS(h.net_total - SUM(i.line_total)) > 1))
  UNION ALL SELECT 'SILVER','sv_sales_item','item_parent_not_null','NULL_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item WHERE transaction_sk IS NULL)
  /* Fact - single-key uniqueness stays strict. See header. */
  UNION ALL SELECT 'SILVER','sv_sales_item','item_line_unique','DUPLICATE_COUNT','CRITICAL','=',0,
         (SELECT COUNT(*) - COUNT(DISTINCT transaction_sk || '|' || line_number)
            FROM {{ database }}.SILVER.sv_sales_item)
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
  /* VERSION-AWARE (changed in V8.1.6). Silver keeps one row per
     (customer_id, source_updated_at). Asserting DISTINCT customer_id alone would
     fail the moment a second version lands. The '~' sentinel keeps a NULL version
     countable - without it COUNT(DISTINCT) would skip the row and the check would
     fail open. */
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
  /* FLAG_COUNT thresholds count ROWS. Once versions exist these will rise simply
     because there are more rows, and will need REBASELINING then - deliberately
     not loosened pre-emptively. See header. */
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

-- Still 31 checks, still all passing after the V5.2.1 grain change.
SELECT COUNT(*) AS checks, COUNT_IF(passed) AS passed, COUNT_IF(NOT passed) AS failed
FROM   {{ database }}.COMMON.v_dq_checks;
-- Recorded: 31, 31, 0

-- The changed check specifically.
SELECT check_name, metric_value, comparator, threshold, passed
FROM   {{ database }}.COMMON.v_dq_checks
WHERE  check_name = 'cust_id_unique';
-- Recorded: cust_id_unique / 0 / = / 0 / TRUE

-- Record a run so the change is visible in history.
CALL {{ database }}.COMMON.sp_run_silver_dq_checks();
-- Recorded: total=31 failed=0 critical=0
