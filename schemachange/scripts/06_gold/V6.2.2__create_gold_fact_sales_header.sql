/* ---------------------------------------------------------------------------
   V6.2.2 - Gold sales fact at ORDER (header) grain (dynamic table)

   One row per transaction_sk, 77,131 rows.

   ==========================================================================
   *** THIS IS NOT THE REVENUE SOURCE. READ THIS BEFORE USING IT. ***
   ==========================================================================
   Every monetary column in this table is an EXACT aggregate of
   GOLD.fact_sales_item. Measured on the current data, per order:

       header net_total      vs SUM(line_total)              0 mismatches
       header total_tax      vs SUM(tax_amount)              0 mismatches
       header total_discount vs SUM(discount_amount)         0 mismatches
       header gross_amount   vs SUM(quantity*unit_price)     0 mismatches

   Both facts therefore total 50,172,602.26. Joining or unioning them to sum money
   returns EXACTLY DOUBLE while the row count stays entirely plausible - the
   blocking issue already registered in AGENT.md section 7.

       Revenue, units, tax, discount   -> fact_sales_item
       Order counts, AOV, basket size,
       payment-method and channel mix  -> THIS TABLE

   To make the mistake harder, every money column here is prefixed `order_`, so
   `net_amount` and `order_net_amount` cannot be confused in a SELECT list.

   ==========================================================================
   WHY THIS TABLE EXISTS AT ALL, GIVEN IT OWNS NO UNIQUE MEASURE
   ==========================================================================
   This was the central design question, and it deserves an honest answer rather
   than a Kimball reflex. The header carries NO measure that the lines cannot
   supply - verified above. On strict Kimball grounds a single atomic line-grain
   fact would be sufficient, and a header fact is an aggregate.

   It is built anyway, for three reasons:

   1. **line_count genuinely only exists at this grain.** Basket size cannot be
      read off a single row of fact_sales_item; it requires an aggregate. It is 1
      on every order today (max = min = 1 measured) and becomes informative the
      moment the source emits multi-line orders.

   2. **payment_method and channel_id are order-level facts about the order.**
      They do not vary by line. They are carried on both facts for convenience,
      but this is where they belong.

   3. **Order counts and AOV are asked constantly** and are cheaper and less
      error-prone here than a COUNT(DISTINCT transaction_sk) over the line fact.

   If the source ever adds a genuine header-only measure - order-level shipping,
   an order-level discount that is not allocated to lines - this table becomes
   unambiguously necessary rather than merely convenient.

   THE MONEY DELIBERATELY COMES FROM THE HEADER, NOT FROM RE-AGGREGATING THE FACT
   --------------------------------------------------------------------
   order_net_amount etc. are sourced from sv_sales_header's own columns, not from
   SUM()-ing fact_sales_item. Two reasons: the header row is the source record and
   is authoritative (and reconciles exactly), and re-aggregating the item fact
   would make this table depend on another gold fact, deepening the refresh chain
   for no gain. Only line_count and total_quantity come from the lines, because
   they cannot come from anywhere else.

   SAME TWO DYNAMIC-TABLE CONSTRAINTS AS V6.2.1
   --------------------------------------------------------------------
   The as-of join to SCD-2 dim_country must be an INNER join (an outer join with a
   non-equality predicate is rejected for change tracking), and REFRESH_MODE must
   be stated EXPLICITLY because AUTO downgrades this shape to FULL. Both measured
   in V6.2.1 - see that header for the exact error text.

   All other joins are equi-joins and therefore safe as LEFT, which protects the
   row count. The GROUP BY subquery supplying line_count did not prevent
   INCREMENTAL: verified DOWNSTREAM + INCREMENTAL, refresh_mode_reason NULL.

   NO NULL FOREIGN KEYS
   --------------------------------------------------------------------
   COALESCE(h.store_id, 'N/A') routes the 15,351 store-less ONLINE orders to the
   synthetic dim_store member added in V6.1.8. Verified 0 NULLs across date,
   customer, store and country keys.

   ALL DIMENSION KEYS COME FROM GOLD. Silver is referenced only for the fact's own
   source rows (sv_sales_header, and sv_sales_item for line_count).

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.GOLD.fact_sales_header (
  sales_header_key      VARCHAR COMMENT 'PRIMARY KEY (by construction). SHA1_HEX of transaction_sk.',
  transaction_sk        VARCHAR COMMENT 'DEGENERATE DIMENSION and the grain. Joins to fact_sales_item.transaction_sk - but *** NEVER JOIN THE TWO FACTS TO SUM MONEY: both total 50,172,602.26 and a naive join returns exactly double while the row count stays plausible. *** AGENT.md section 7.',
  transaction_id        VARCHAR COMMENT 'DEGENERATE DIMENSION. Source-system order number.',
  date_key              NUMBER  COMMENT 'FK to GOLD.dim_date.date_key (YYYYMMDD). LEFT-resolved; assert NOT NULL in DQ.',
  customer_key          VARCHAR COMMENT 'FK to GOLD.dim_customer.customer_key. Zero unresolved measured.',
  store_key             VARCHAR COMMENT 'FK to GOLD.dim_store.store_key. NEVER NULL - the 15,351 ONLINE orders point at the synthetic N/A member added in V6.1.8.',
  country_key           VARCHAR COMMENT 'FK to GOLD.dim_country.country_key - the country VERSION in force on the order date, via an as-of range join.',
  channel_id            VARCHAR COMMENT 'Order channel, POS or ONLINE. Degenerate attribute - 2 values, no master table. Exact partition with a NULL source store_id.',
  payment_method        VARCHAR COMMENT 'Payment method, 9 values. Degenerate attribute, no master table. This is genuinely ORDER-level and does not vary by line - one of the few reasons this fact exists.',
  currency_code         VARCHAR COMMENT '*** ISO code ONLY - the amounts are USD-scaled regardless. *** All 27 currencies average 620-780 net. No FX dimension exists, so cross-currency SUM is meaningless. Always GROUP BY or filter on this.',
  transaction_timestamp TIMESTAMP_NTZ COMMENT 'Full order timestamp, for intraday analysis.',
  line_count            NUMBER  COMMENT 'THE MEASURE THAT ONLY EXISTS AT THIS GRAIN - number of lines on the order, i.e. basket size. Cannot be derived from a single row of fact_sales_item. *** 1 ON EVERY ORDER TODAY *** (max = min = 1 measured); it becomes informative when the source starts emitting multi-line orders.',
  total_quantity        NUMBER(38,2) COMMENT 'ADDITIVE. Total units across the order, summed from the lines.',
  order_gross_amount    NUMBER(38,2) COMMENT 'ADDITIVE at THIS grain only. Source header gross_amount, verified equal to SUM(quantity*unit_price) over the lines (0 mismatches). Prefixed order_ so it cannot be confused with the line measure.',
  order_discount_amount NUMBER(38,2) COMMENT 'ADDITIVE at this grain only. Source header total_discount, verified equal to SUM(line discount_amount).',
  order_tax_amount      NUMBER(38,2) COMMENT 'ADDITIVE at this grain only, and AUTHORITATIVE for tax. Source header total_tax, verified equal to SUM(line tax_amount). Never recompute from dim_country.tax_rate - that rate starts 2020-01-01, after the sales period.',
  order_net_amount      NUMBER(38,2) COMMENT 'ADDITIVE at this grain only. Source header net_total; totals 50,172,602.26 - THE SAME TOTAL as fact_sales_item.net_amount, because the header is an exact aggregate of the lines. *** Use fact_sales_item.net_amount as the revenue measure; use this one only for order-grain work such as average order value. ***',
  sale_before_store_open BOOLEAN COMMENT 'TRUE when the order date precedes that store OWN store_open_date. A REGISTERED source defect on ~38,088 rows, not a regression. FALSE for ONLINE orders (N/A member has a NULL open date by design).',
  dq_issue_flags        VARCHAR COMMENT 'Row-level DQ flags from the header row. NULL means no flag.',
  source_system         VARCHAR COMMENT 'Originating source system.'
)
TARGET_LAG   = DOWNSTREAM
WAREHOUSE    = {{ warehouse }}
REFRESH_MODE = INCREMENTAL
COMMENT      = 'Gold transaction fact at ORDER (header) grain - one row per transaction_sk, 77,131 rows. *** THIS IS NOT THE REVENUE SOURCE. *** Every monetary column here is an EXACT aggregate of GOLD.fact_sales_item (verified: 0 mismatches on gross, discount, tax and net), so the two facts both total 50,172,602.26 and must NEVER be joined or unioned to sum money. Use this fact for order-grain questions only - order counts, average order value, basket size, payment-method and channel mix. Its one measure that the item fact cannot supply is line_count. Money comes from fact_sales_item.net_amount.'
AS
SELECT
  SHA1_HEX(h.transaction_sk)                    AS sales_header_key,
  h.transaction_sk,
  h.transaction_id,
  dd.date_key,
  dc.customer_key,
  ds.store_key,
  dcy.country_key,
  h.channel_id,
  h.payment_method,
  h.currency                                    AS currency_code,
  h.transaction_timestamp,
  agg.line_count,
  agg.total_quantity,
  h.gross_amount                                AS order_gross_amount,
  h.total_discount                              AS order_discount_amount,
  h.total_tax                                   AS order_tax_amount,
  h.net_total                                   AS order_net_amount,
  (ds.store_open_date IS NOT NULL
     AND h.transaction_timestamp::DATE < ds.store_open_date) AS sale_before_store_open,
  h.dq_issue_flags,
  h.source_system
FROM {{ database }}.SILVER.sv_sales_header h
/* AS-OF join to SCD-2 dim_country. MUST be INNER - see V6.2.1 for the measured
   reason and the exact error text. */
JOIN {{ database }}.GOLD.dim_country dcy
       ON dcy.country_code = h.country_code
      AND h.transaction_timestamp::DATE BETWEEN dcy.valid_from AND dcy.valid_to
/* line_count and total_quantity are the only things sourced from the lines. The
   money deliberately comes from the header's own columns, which are the source
   record and reconcile exactly - not from re-aggregating the item fact. */
LEFT JOIN (
  SELECT transaction_sk,
         COUNT(*)       AS line_count,
         SUM(quantity)  AS total_quantity
  FROM   {{ database }}.SILVER.sv_sales_item
  WHERE  __is_current_version = TRUE
  GROUP  BY transaction_sk
) agg ON agg.transaction_sk = h.transaction_sk
LEFT JOIN {{ database }}.GOLD.dim_date     dd  ON dd.full_date   = h.transaction_timestamp::DATE
LEFT JOIN {{ database }}.GOLD.dim_customer dc  ON dc.customer_id = h.customer_id
LEFT JOIN {{ database }}.GOLD.dim_store    ds  ON ds.store_code  = COALESCE(h.store_id, 'N/A')
WHERE h.__is_current_version = TRUE
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY h.transaction_sk
          ORDER BY     h.transaction_id) = 1;


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Refresh mode, checked AT CREATION per section 5. Confirms the GROUP BY
-- subquery did not force FULL.
SHOW DYNAMIC TABLES LIKE 'fact_sales_header' IN SCHEMA {{ database }}.GOLD;
-- Recorded: rows 77131, DOWNSTREAM, INCREMENTAL, refresh_mode_reason NULL

SELECT COUNT(*)                          AS rows_,
       COUNT(DISTINCT sales_header_key)  AS distinct_keys,
       SUM(order_net_amount)             AS order_revenue,
       COUNT_IF(date_key     IS NULL)    AS null_date_key,
       COUNT_IF(customer_key IS NULL)    AS null_customer_key,
       COUNT_IF(store_key    IS NULL)    AS null_store_key,
       COUNT_IF(country_key  IS NULL)    AS null_country_key,
       COUNT_IF(line_count   IS NULL)    AS null_line_count,
       SUM(line_count)                   AS sum_line_count,
       MAX(line_count)                   AS max_line_count,
       COUNT_IF(sale_before_store_open)  AS sale_before_open
FROM   {{ database }}.GOLD.fact_sales_header;
-- Recorded: 77131, 77131, 50172602.26, 0, 0, 0, 0, 0, 77131, 1, 38102
-- sum_line_count = 77131 with max = 1 confirms strictly one line per order today,
--   and equals the fact_sales_item row count exactly.

-- ** THE RECONCILIATION THAT MATTERS. ** Per order, the header total must equal
-- the sum of that order's own lines. This is what makes the double-count risk
-- real rather than theoretical - and it must stay at 0.
SELECT COUNT(*) AS per_order_mismatch
FROM   {{ database }}.GOLD.fact_sales_header h
JOIN   (SELECT transaction_sk, SUM(net_amount) AS s
        FROM   {{ database }}.GOLD.fact_sales_item GROUP BY transaction_sk) i
       ON i.transaction_sk = h.transaction_sk
WHERE  ABS(h.order_net_amount - i.s) > 0.01;
-- Recorded: 0

-- Both facts total the SAME figure. This is EXPECTED, not a bug - and is exactly
-- why they must never be combined.
SELECT (SELECT SUM(order_net_amount) FROM {{ database }}.GOLD.fact_sales_header) AS header_total,
       (SELECT SUM(net_amount)       FROM {{ database }}.GOLD.fact_sales_item)   AS item_total;
-- Recorded: 50172602.26, 50172602.26

-- Order grain must match the header source exactly - no rows lost to the INNER
-- as-of country join.
SELECT (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header
         WHERE __is_current_version)                             AS silver_header_rows,
       (SELECT COUNT(*) FROM {{ database }}.GOLD.fact_sales_header) AS fact_rows;
-- Recorded: 77131, 77131
