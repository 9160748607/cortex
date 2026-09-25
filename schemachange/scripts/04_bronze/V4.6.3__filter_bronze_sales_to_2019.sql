/* ---------------------------------------------------------------------------
   V4.6.3 - Restrict bronze sales transactions to calendar 2019

   Removes the 24 rows dated 2020-01-01 from both sales tables.
   Result: 77,131 header rows and 77,131 item rows (from 77,155 each).

   ==========================================================================
   WHY THIS SCRIPT EXISTS AS A SEPARATE STEP
   ==========================================================================
   The file named sales_header_2019.csv is NOT purely 2019. Verified by reading
   the local source directly:

       total data rows in the CSV                    77,155
       rows whose transaction_timestamp is not 2019      24   (all 2020-01-01)

   V4.6.2 already warned about this ("the 2020 load must not assume the file year
   partitions cleanly"). Those 24 rows are timezone spillover - transactions that
   occurred late on 2019-12-31 local time and were stamped 2020-01-01 - and all
   24 are POS, across 3 countries. AGENT.md section 7 carried them as a known
   trait rather than a defect.

   They are now EXCLUDED, so the loaded data is genuinely 2019 only.

   *** THIS COULD NOT BE DONE IN THE COPY. *** A filtered COPY was attempted first
   and Snowflake rejected it:

       COPY INTO ... FROM (SELECT ... FROM @stage WHERE $3 < '2020-01-01')
       -> SQL compilation error:
          COPY statement only supports simple SELECT from stage statements
          for import.

   COPY transformations permit column projection, casts and reordering, but NOT
   a WHERE clause, joins, aggregates or DISTINCT. So the filter has to be a
   separate DML step after the load - which is exactly what this script is. Do
   not "simplify" this by folding the predicate back into V4.6.2; it will fail.

   ==========================================================================
   BOTH TABLES ARE FILTERED, AND THE ORDER MATTERS
   ==========================================================================
   Filtering the header alone would leave 24 item rows whose parent no longer
   exists. Because GOLD.fact_sales_item INNER JOINs the header, those items would
   silently vanish from the fact anyway - but silver would hold 77,155 items
   against 77,131 headers, breaking the 1:1 relationship that the whole gold
   design rests on, and the DQ checks in 08_data_quality would start reporting
   orphans.

   The item DELETE therefore runs FIRST and is driven by a subquery against the
   header. If it ran second the driving rows would already be gone.

   Verified: the item side matches the header side exactly - the 24 affected
   transactions own exactly 24 item rows, all with created_at >= 2020-01-01,
   with ZERO disagreement between the two ways of identifying them. Their
   line_total sums to 14,025.71, identical to the header net_total sum.

   ==========================================================================
   *** THIS MAKES BRONZE NO LONGER A FAITHFUL COPY OF THE SOURCE FILE. ***
   ==========================================================================
   A deliberate, explicit trade-off, recorded here because it deviates from the
   medallion principle that bronze is raw landing. Bronze now holds 77,131 rows
   while the staged CSV holds 77,155.

   The alternative - keep bronze at 77,155 and put the 2019 predicate in the
   silver dynamic tables - was considered and NOT chosen. Consequence to be aware
   of when the 2020-2025 files are loaded (they exist in the local
   __initial_load/sales-transaction folder but were never staged): each year's
   file will likewise contain a handful of spillover rows belonging to the NEXT
   year, so this same filter pattern must be applied per year, and the 24 rows
   removed here legitimately belong to the 2020 load.

   Re-runnable: the DELETEs are idempotent - after the first run there are no
   matching rows, so a second run deletes 0.

   Depends on: V4.6.2 (the COPY that loads both tables).
   --------------------------------------------------------------------------- */

/* Items first - driven by the header, which must still hold the 24 rows. */
DELETE FROM {{ database }}.BRONZE.br_sales_item
WHERE transaction_sk IN (
  SELECT transaction_sk
  FROM   {{ database }}.BRONZE.br_sales_header
  WHERE  transaction_timestamp >= '2020-01-01'
     OR  transaction_timestamp <  '2019-01-01'
);
-- Recorded: 24 rows deleted

DELETE FROM {{ database }}.BRONZE.br_sales_header
WHERE transaction_timestamp >= '2020-01-01'
   OR transaction_timestamp <  '2019-01-01';
-- Recorded: 24 rows deleted


/* ---------------------------------------------------------------------------
   The dynamic tables do NOT pick this up on their own. Every DT in this repo is
   TARGET_LAG = DOWNSTREAM and gold has no consumer, so scheduling_state = OFF.
   Refresh in dependency order: silver, then the gold facts.
   --------------------------------------------------------------------------- */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_sales_header REFRESH;
-- Recorded: insertedRows 77131, deletedRows 77155
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_sales_item   REFRESH;
-- Recorded: insertedRows 77131, deletedRows 77155
ALTER DYNAMIC TABLE {{ database }}.GOLD.fact_sales_item   REFRESH;
-- Recorded: insertedRows 77131, deletedRows 77155, refreshed_dt_count 17
ALTER DYNAMIC TABLE {{ database }}.GOLD.fact_sales_header REFRESH;
-- Recorded: insertedRows 77131, deletedRows 77155, refreshed_dt_count 12


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- 2019 and nothing else.
SELECT COUNT(*)                                          AS rows_,
       MIN(transaction_timestamp)                        AS min_ts,
       MAX(transaction_timestamp)                        AS max_ts,
       COUNT(DISTINCT YEAR(transaction_timestamp))       AS distinct_years,
       COUNT_IF(transaction_timestamp >= '2020-01-01')   AS rows_2020
FROM   {{ database }}.BRONZE.br_sales_header;
-- Recorded: 77131, 2019-01-01 00:49:45, 2019-12-31 23:59:33, 1, 0

-- Every layer must agree. Six objects, one number.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_header)      AS bronze_hdr,
       (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_item)        AS bronze_itm,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header
         WHERE __is_current_version)                                     AS silver_hdr,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item
         WHERE __is_current_version)                                     AS silver_itm,
       (SELECT COUNT(*) FROM {{ database }}.GOLD.fact_sales_item)        AS fact_itm,
       (SELECT COUNT(*) FROM {{ database }}.GOLD.fact_sales_header)      AS fact_hdr;
-- Recorded: 77131, 77131, 77131, 77131, 77131, 77131

-- ** THE 1:1 RELATIONSHIP MUST SURVIVE. ** This is what filtering both tables
-- exists to protect; header-only filtering would make orphan_items = 24.
SELECT (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item i
         WHERE i.__is_current_version
           AND NOT EXISTS (SELECT 1 FROM {{ database }}.SILVER.sv_sales_header h
                            WHERE h.transaction_sk = i.transaction_sk
                              AND h.__is_current_version))              AS orphan_items,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
         WHERE h.__is_current_version
           AND NOT EXISTS (SELECT 1 FROM {{ database }}.SILVER.sv_sales_item i
                            WHERE i.transaction_sk = h.transaction_sk
                              AND i.__is_current_version))              AS headers_no_items;
-- Recorded: 0, 0

-- Revenue after exclusion, and the star still joining losslessly.
SELECT (SELECT SUM(net_amount)       FROM {{ database }}.GOLD.fact_sales_item)   AS item_revenue,
       (SELECT SUM(order_net_amount) FROM {{ database }}.GOLD.fact_sales_header) AS header_revenue,
       (SELECT COUNT_IF(date_key IS NULL OR customer_key IS NULL OR store_key IS NULL
                     OR country_key IS NULL OR product_key IS NULL)
          FROM {{ database }}.GOLD.fact_sales_item)                              AS fact_null_fks;
-- Recorded: 50172602.26, 50172602.26, 0
-- Previous figure was 50,172,602.26; the 24 excluded rows carried 14,025.71.
