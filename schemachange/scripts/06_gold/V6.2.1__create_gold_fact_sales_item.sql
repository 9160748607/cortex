/* ---------------------------------------------------------------------------
   V6.2.1 - Gold atomic sales fact at LINE grain (dynamic table)

   One row per (transaction_sk, line_number), 77,155 rows.
   Revenue: 50,186,627.97

   ==========================================================================
   *** THIS IS THE SINGLE SOURCE OF TRUTH FOR REVENUE. ***
   ==========================================================================
   V6.2.2 builds fact_sales_header at ORDER grain. Every monetary column there is
   an EXACT aggregate of this table - measured, 0 mismatches on gross, discount,
   tax and net. So both facts total 50,186,627.97 and joining or unioning them to
   sum money DOUBLE-COUNTS while the row count stays entirely plausible. This is
   already registered as a blocking issue in AGENT.md section 7.

   Rule: money from HERE. Order counts, basket size and AOV from the header fact.

   ==========================================================================
   WHY LINE GRAIN WHEN THE SOURCE IS STRICTLY 1:1 TODAY
   ==========================================================================
   Measured on the current data:

       header rows / distinct transaction_sk        77,155 / 77,155
       item   rows / distinct transaction_sk        77,155 / 77,155
       MIN(lines per header) / MAX(lines per header)      1 / 1
       DISTINCT line_number                                   1
       headers with no items / items with no header       0 / 0

   So today one order has exactly one line, and this fact is row-for-row
   identical in cardinality to the header fact. The grain is still declared at
   LINE level because that is the atomic grain of the business process: when the
   source starts emitting multi-line orders, nothing here needs restructuring -
   the row count simply grows and every measure stays correct.

   Declaring the grain at header level instead would have to be undone later, and
   undoing a fact's grain means rebuilding every downstream consumer.

   ==========================================================================
   THE TWO CONSTRAINTS THAT SHAPE THE COUNTRY JOIN - BOTH MEASURED
   ==========================================================================
   country_key is resolved AS OF the transaction date against SCD-2 dim_country:

       AND h.transaction_timestamp::DATE BETWEEN dcy.valid_from AND dcy.valid_to

   This is what makes dim_country's SCD-2 worth having - the fact records the
   country VERSION in force when the sale happened, so history stays correct once
   a second version exists. But a range predicate in a dynamic table is
   constrained twice over:

   1. **It must be an INNER join.** Tested:

          LEFT JOIN + BETWEEN -> FULL refresh mode. Reason given:
          "Change tracking is not supported on queries containing outer joins
           with non-equality predicates."

      That is a hard limitation, not a tuning knob. An outer join with a range
      predicate can NEVER be incremental.

   2. **REFRESH_MODE must be stated EXPLICITLY.** Tested:

          INNER JOIN + BETWEEN, REFRESH_MODE = AUTO  -> FULL. Reason given:
          "This dynamic table contains a complex query. Refresh mode has been
           automatically set to FULL for more predictable performance. To use
           INCREMENTAL, re-create the dynamic table with REFRESH_MODE=INCREMENTAL."

          INNER JOIN + BETWEEN, REFRESH_MODE = INCREMENTAL -> INCREMENTAL,
          refresh_mode_reason NULL.

      AUTO silently downgrades this shape. Never rely on it here.

   THE COST OF THE INNER JOIN, AND HOW IT IS MITIGATED
   --------------------------------------------------------------------
   An INNER join can silently DROP a fact row if a country ever fails to resolve
   within its validity window - the worst failure mode this repo has, since the
   result still looks clean. Zero rows are unresolved today (measured against all
   77,155). The mitigation is NOT to switch to a LEFT join, which would cost
   incremental refresh; it is the row-count assertion in the validation below and
   in the gold DQ checks. If this fact ever returns fewer than the header count,
   the country join is the first place to look.

   ALL OTHER JOINS ARE EQUI-JOINS, SO LEFT IS SAFE
   --------------------------------------------------------------------
   dim_date, dim_customer, dim_store and dim_product are joined on equality, which
   is incremental-safe even as LEFT. They are LEFT precisely so that an
   unresolvable key surfaces as a NULL FK - visible and assertable - instead of
   deleting a sale. Verified: 0 NULLs on all five FKs.

   ==========================================================================
   NO NULL FOREIGN KEYS - THE COALESCE IS LOAD-BEARING
   ==========================================================================
       LEFT JOIN dim_store ds ON ds.store_code = COALESCE(h.store_id, 'N/A')

   15,351 rows (19.9%) are ONLINE with a NULL source store_id - an exact partition
   with channel_id (0 mismatches). V6.1.8 added the synthetic 'N/A' member to
   dim_store so those rows get a real store_key. Without it, the obvious
   `JOIN dim_store USING (store_key)` would return 61,804 of 77,155 and quietly
   lose a fifth of revenue.

   ALL DIMENSION KEYS COME FROM GOLD, NOT SILVER
   --------------------------------------------------------------------
   Every FK resolves against a GOLD dimension. Silver is referenced ONLY for the
   two transaction tables themselves (sv_sales_item, sv_sales_header), which are
   the fact's own source rows - not dimension data.

   MEASURE SEMANTICS - LABELLED, BECAUSE THEY ARE NOT ALL ADDITIVE
   --------------------------------------------------------------------
     quantity, extended_gross_amount,
     discount_amount, tax_amount, net_amount   ADDITIVE across every dimension
     unit_price                                *** NON-ADDITIVE - NEVER SUM ***
                                               average only weighted by quantity

   Verified: net_amount = extended_gross_amount - discount_amount + tax_amount on
   all 77,155 rows (0 violations).

   tax_amount is AUTHORITATIVE. Never recompute it from dim_country.tax_rate -
   that rate is effective 2020-01-01, AFTER the sales period, and recomputing
   fails on 5 countries / 5,609 rows (section 7).

   currency_code is an ISO LABEL ONLY. All 27 currencies are USD-scaled; there is
   no FX dimension. A cross-currency SUM runs cleanly and means nothing. No
   blended `revenue_usd` column is provided, deliberately - it would be a
   type-correct lie.

   DEGENERATE DIMENSIONS, not dimension tables: transaction_sk, transaction_id,
   transaction_line_id, line_number, channel_id, payment_method. channel (2 values)
   and payment_method (9 values) have no master table in silver; carrying them
   inline was an explicit choice over building 2-row and 9-row dimensions.

   NOTE: no SYS_CONSTRAINT_DERIVED_PK is produced here, unlike every gold
   dimension. The QUALIFY is present and uniqueness holds (77,155 distinct
   sales_item_key for 77,155 rows, verified), but Snowflake does not infer the
   constraint through this many joins. Uniqueness is therefore asserted in the
   validation below rather than carried as metadata.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.GOLD.fact_sales_item (
  sales_item_key        VARCHAR COMMENT 'PRIMARY KEY (by construction, not declared - dynamic tables accept no constraint clause). SHA1_HEX of transaction_sk + line_number.',
  transaction_sk        VARCHAR COMMENT 'DEGENERATE DIMENSION. Silver surrogate for the transaction. Groups lines into an order and is the join key to fact_sales_header - but NEVER join the two facts to sum money (both total 50,186,627.97 today).',
  transaction_id        VARCHAR COMMENT 'DEGENERATE DIMENSION. Source-system transaction/order number. No dimension table - correct Kimball treatment for an identifier with no attributes.',
  transaction_line_id   VARCHAR COMMENT 'DEGENERATE DIMENSION. Source-system line identifier.',
  line_number           NUMBER  COMMENT 'Line sequence within the order. Part of the declared grain. ONLY THE VALUE 1 EXISTS TODAY - the source is strictly one line per order (max = min = 1 lines per header, measured). The grain is line-level so that 1:N needs no restructuring.',
  date_key              NUMBER  COMMENT 'FK to GOLD.dim_date.date_key (YYYYMMDD). Resolved by LEFT JOIN so an out-of-range date surfaces as NULL rather than dropping the row; assert NOT NULL in DQ. Covers the 24 timezone-spillover rows on 2020-01-01.',
  customer_key          VARCHAR COMMENT 'FK to GOLD.dim_customer.customer_key. Zero unresolved measured.',
  store_key             VARCHAR COMMENT 'FK to GOLD.dim_store.store_key. *** NEVER NULL: the 15,351 ONLINE lines point at the synthetic N/A member (store_code = ''N/A'') added in V6.1.8. *** Exclude that member when analysing real stores.',
  country_key           VARCHAR COMMENT 'FK to GOLD.dim_country.country_key - the country VERSION in force on the transaction date, resolved by an as-of range join. This is what makes dim_country SCD-2 pay off: history stays correct when a second version arrives.',
  product_key           VARCHAR COMMENT 'FK to GOLD.dim_product.product_key. Zero unresolved measured. Per-COUNTRY product availability is in GOLD.bridge_product_country, which fans out 35x - do not join it casually.',
  channel_id            VARCHAR COMMENT 'Order channel, POS or ONLINE. Carried as a degenerate attribute rather than a dimension - only 2 values and no master exists. ONLINE is an exact partition with a NULL source store_id (0 mismatches measured).',
  payment_method        VARCHAR COMMENT 'Payment method, 9 values. Degenerate attribute; no master table exists. No allow-list asserted - a new method is a business change, not a defect (DQ rule 4).',
  currency_code         VARCHAR COMMENT '*** ISO code ONLY - IT DOES NOT MEAN THE AMOUNTS ARE IN THIS CURRENCY. *** All 27 currencies are USD-scaled (every one averages 620-780 net_amount), and no FX dimension exists. Cross-currency SUM runs cleanly and returns a MEANINGLESS number. Always GROUP BY or filter on this column. AGENT.md section 7.',
  transaction_timestamp TIMESTAMP_NTZ COMMENT 'Full event timestamp, kept for time-of-day and intraday analysis. The date portion is already resolved into date_key.',
  quantity              NUMBER(38,2) COMMENT 'ADDITIVE. Units sold on this line.',
  unit_price            NUMBER(38,2) COMMENT '*** NON-ADDITIVE - NEVER SUM THIS. *** Price per unit. Averaging is valid only weighted by quantity. dim_product has no price at all, so this column is the only price source; derive baselines per (sku_code, currency_code).',
  extended_gross_amount NUMBER(38,2) COMMENT 'ADDITIVE. quantity * unit_price. Reconciles exactly to sv_sales_header.gross_amount (0 mismatches measured).',
  discount_amount       NUMBER(38,2) COMMENT 'ADDITIVE. Line discount. Reconciles exactly to header total_discount.',
  tax_amount            NUMBER(38,2) COMMENT 'ADDITIVE, and AUTHORITATIVE. Never recompute tax from dim_country.tax_rate - that rate is effective 2020-01-01, AFTER the 2019 sales period, and recomputing fails on 5 countries / 5,609 rows. Reconciles exactly to header total_tax.',
  net_amount            NUMBER(38,2) COMMENT 'ADDITIVE. THE REVENUE MEASURE - source line_total. Totals 50,186,627.97. Satisfies net = extended_gross - discount + tax (0 violations). *** Build revenue from THIS column, not from fact_sales_header. ***',
  sale_before_store_open BOOLEAN COMMENT 'TRUE when transaction date precedes that store OWN store_open_date. Expected TRUE on ~38,102 rows - a REGISTERED source defect (67 of 121 stores open after the 2019 period), not a regression. Compares per store, never against a literal year. FALSE for ONLINE lines, whose N/A member has a NULL open date by design.',
  dq_issue_flags        VARCHAR COMMENT 'Row-level DQ flags from the item and header rows, prefixed by origin. NULL means no flag on either.',
  source_system         VARCHAR COMMENT 'Originating source system, from the header.'
)
TARGET_LAG   = DOWNSTREAM
WAREHOUSE    = {{ warehouse }}
REFRESH_MODE = INCREMENTAL
COMMENT      = 'Gold ATOMIC transaction fact at LINE grain - one row per (transaction_sk, line_number), 77,155 rows. *** THIS IS THE SINGLE SOURCE OF TRUTH FOR REVENUE. *** Build all monetary analysis from net_amount here; fact_sales_header carries the same totals at order grain and summing both double-counts while the row count stays plausible. All dimension keys resolve to GOLD dimensions only - no silver reference. country_key uses an as-of range join against SCD-2 dim_country, which requires an INNER join and an EXPLICIT REFRESH_MODE=INCREMENTAL: an outer join with a non-equality predicate can never be incremental, and AUTO silently downgrades this query to FULL.'
AS
SELECT
  SHA1_HEX(i.transaction_sk || '|' || i.line_number::VARCHAR) AS sales_item_key,
  i.transaction_sk,
  h.transaction_id,
  i.transaction_line_id,
  i.line_number,
  dd.date_key,
  dc.customer_key,
  ds.store_key,
  dcy.country_key,
  dp.product_key,
  h.channel_id,
  h.payment_method,
  h.currency                                    AS currency_code,
  h.transaction_timestamp,
  i.quantity,
  i.unit_price,
  i.quantity * i.unit_price                     AS extended_gross_amount,
  i.discount_amount,
  i.tax_amount,
  i.line_total                                  AS net_amount,
  /* store_open_date IS NULL on the N/A member, so this is FALSE for online
     sales rather than accidentally TRUE. See V6.1.8. */
  (ds.store_open_date IS NOT NULL
     AND h.transaction_timestamp::DATE < ds.store_open_date) AS sale_before_store_open,
  NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(i.dq_issue_flags IS NOT NULL, 'ITEM:'   || i.dq_issue_flags, NULL),
      IFF(h.dq_issue_flags IS NOT NULL, 'HEADER:' || h.dq_issue_flags, NULL)
  )),' | '),'')                                 AS dq_issue_flags,
  h.source_system
FROM {{ database }}.SILVER.sv_sales_item i
JOIN {{ database }}.SILVER.sv_sales_header h
       ON h.transaction_sk = i.transaction_sk
      AND h.__is_current_version = TRUE
/* AS-OF join to the SCD-2 country dimension. MUST be INNER: an outer join with a
   non-equality predicate is rejected for change tracking outright. Zero rows are
   unresolved today, and DQ asserts the fact row count instead of using a LEFT. */
JOIN {{ database }}.GOLD.dim_country dcy
       ON dcy.country_code = h.country_code
      AND h.transaction_timestamp::DATE BETWEEN dcy.valid_from AND dcy.valid_to
/* Equi-joins below, so LEFT is safe for incremental refresh and protects the
   row count. COALESCE routes the 15,351 store-less ONLINE rows to the N/A member. */
LEFT JOIN {{ database }}.GOLD.dim_date     dd  ON dd.full_date   = h.transaction_timestamp::DATE
LEFT JOIN {{ database }}.GOLD.dim_customer dc  ON dc.customer_id = h.customer_id
LEFT JOIN {{ database }}.GOLD.dim_store    ds  ON ds.store_code  = COALESCE(h.store_id, 'N/A')
LEFT JOIN {{ database }}.GOLD.dim_product  dp  ON dp.sku_code    = i.sku_code
WHERE i.__is_current_version = TRUE
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY i.transaction_sk, i.line_number
          ORDER BY     i.transaction_line_id) = 1;


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Refresh mode, checked AT CREATION per section 5. This is the check that proves
-- the explicit REFRESH_MODE beat AUTO's downgrade.
SHOW DYNAMIC TABLES LIKE 'fact_sales_item' IN SCHEMA {{ database }}.GOLD;
-- Recorded: rows 77155, DOWNSTREAM, INCREMENTAL, refresh_mode_reason NULL

-- Grain, revenue, and FK completeness in one pass.
SELECT COUNT(*)                            AS rows_,
       COUNT(DISTINCT sales_item_key)      AS distinct_keys,
       COUNT(DISTINCT transaction_sk)      AS distinct_orders,
       SUM(net_amount)                     AS total_revenue,
       SUM(extended_gross_amount)          AS total_gross,
       SUM(tax_amount)                     AS total_tax,
       COUNT_IF(date_key     IS NULL)      AS null_date_key,
       COUNT_IF(customer_key IS NULL)      AS null_customer_key,
       COUNT_IF(store_key    IS NULL)      AS null_store_key,
       COUNT_IF(country_key  IS NULL)      AS null_country_key,
       COUNT_IF(product_key  IS NULL)      AS null_product_key,
       COUNT_IF(sale_before_store_open)    AS sale_before_open,
       COUNT_IF(dq_issue_flags IS NOT NULL) AS flagged,
       COUNT_IF(ABS(net_amount - (extended_gross_amount - discount_amount + tax_amount)) > 0.01)
                                           AS formula_violations
FROM   {{ database }}.GOLD.fact_sales_item;
-- Recorded: 77155, 77155, 77155,
--           50186627.97, 45424676.28, 5667434.34,
--           0, 0, 0, 0, 0,
--           38102, 0, 0
-- distinct_keys = rows_ is the uniqueness assertion standing in for the derived
--   PK that Snowflake does not infer through these joins.
-- ALL FIVE FK NULL COUNTS MUST STAY 0. A non-zero null_country_key is impossible
--   (the join is INNER, so it would drop the row instead) - which is exactly why
--   rows_ must be asserted against the header count below.
-- sale_before_open = 38102 matches the registered defect exactly.

-- ** THE GUARD ON THE INNER AS-OF JOIN. ** If the country join ever fails to
-- resolve, this fact loses rows silently. Both sides must agree.
SELECT (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item
         WHERE __is_current_version)                       AS silver_item_rows,
       (SELECT COUNT(*) FROM {{ database }}.GOLD.fact_sales_item) AS fact_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item WHERE __is_current_version)
         - (SELECT COUNT(*) FROM {{ database }}.GOLD.fact_sales_item) AS rows_lost;
-- Recorded: 77155, 77155, 0   <- rows_lost MUST be 0

-- Revenue must tie to silver exactly. 50,186,627.97 is the repo's reference figure.
SELECT (SELECT SUM(line_total) FROM {{ database }}.SILVER.sv_sales_item
         WHERE __is_current_version)                             AS silver_revenue,
       (SELECT SUM(net_amount) FROM {{ database }}.GOLD.fact_sales_item) AS fact_revenue;
-- Recorded: 50186627.97, 50186627.97

-- The N/A store member must absorb exactly the ONLINE rows and no others.
SELECT f.channel_id,
       COUNT(*)                                   AS rows_,
       COUNT_IF(s.store_code =  'N/A')             AS on_na_member,
       COUNT_IF(s.store_code <> 'N/A')             AS on_real_store
FROM   {{ database }}.GOLD.fact_sales_item f
JOIN   {{ database }}.GOLD.dim_store s ON s.store_key = f.store_key
GROUP  BY f.channel_id
ORDER  BY f.channel_id;
-- Recorded: ONLINE 15351 / 15351 / 0
--           POS    61804 /     0 / 61804
-- This also proves the star joins without loss: 15351 + 61804 = 77155.
