/* ---------------------------------------------------------------------------
   V5.1.13 - Silver sales item (dynamic table)

   THE FINAL SCRIPT IN THE SILVER LAYER. Thirteenth of thirteen, and the second
   fact table. Must be read with V5.1.12 (sales header): the two are in an exact
   1:1 relationship, and the consequences of that are recorded in both headers.

   Reuses the pattern from V5.1.1, the row-level-flags-only rule from V5.1.7, the
   lowercase-UUID key lesson from V5.1.10, and the drop-provably-redundant-columns
   precedent from V5.1.10/V5.1.11.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per transaction_line_id
     Business key  transaction_line_id - LINE-<hex>, unique across all 77,155
     Alternate key (transaction_sk, line_number) - also unique, 77,155 distinct
     Volume        77,155 rows, 10 source columns - the narrowest fact
     Foreign keys  transaction_sk -> sv_sales_header      ZERO orphans, 1:1
                   sku_code -> sv_product_sku_master      ZERO orphans
     Referenced by nothing - this is a leaf.

     line_number     1 on every row - see below
     quantity        1 to 2, no nulls, none non-positive
     unit_price      no nulls, none non-positive

   ==========================================================================
   THE DEFINING PROPERTY: AN EXACT 1:1 WITH THE HEADER
   ==========================================================================
   This is not "mostly one line per transaction". It is an exact bijection,
   measured four independent ways:
       77,155 item rows                         = 77,155 header rows
       77,155 distinct transaction_line_id      = one key per row
       77,155 distinct transaction_sk IN ITEMS  = no transaction has two lines
       MAX(line_number) = MIN(line_number) = 1  = no line is ever numbered 2
       ZERO orphan items, ZERO headers without an item
   So every transaction has exactly one line, and every line has exactly one
   transaction.

   That is an artefact of data generation, not a property of retail - the same
   class of finding as the complete 650x35 cartesian in V5.1.9. Three things
   follow, and they are the most important content of this script.

   1. THE HEADER'S MEASURES ARE A VERBATIM COPY OF THIS TABLE'S. Verified across
      all 77,155 pairs, to the cent, zero exceptions:
          header.gross_amount   = quantity * unit_price
          header.total_discount = discount_amount
          header.total_tax      = tax_amount
          header.net_total      = line_total
      GOLD MUST PICK EXACTLY ONE TABLE AS THE REVENUE SOURCE. Joining both and
      summing measures from each doubles every figure, and because the join is 1:1
      THE ROW COUNT STAYS PERFECTLY CORRECT while every amount is wrong. A defect
      with no symptom is the worst kind; this one is easy to introduce and hard to
      notice.

      Recommendation: build revenue from THIS table, not the header. It is the
      lower grain, so it survives the arrival of a second line without any change
      to the measure logic, whereas header-based revenue would silently stop
      matching the sum of its lines.

   2. line_number CARRIES NO INFORMATION TODAY. It is 1 on 100% of rows, so it
      cannot discriminate anything and is NOT flagged for any value (the 100% rule
      from V5.1.7). It is KEPT because it is half of the natural alternate key and
      because the day multi-line transactions appear it becomes essential.

   3. DO NOT BUILD ANYTHING THAT ASSUMES 1:1. Any gold logic that relies on one
      line per transaction - a join that treats the pair as interchangeable, a
      header-level measure used as a line-level one, a DISTINCT that happens to be
      harmless - becomes silently wrong the moment a second line arrives. The
      relationship is a property of this data, not a guarantee of the model.

   category_code IS DROPPED - PROVABLY REDUNDANT
   --------------------------------------------------------------------
   Bronze carries category_code on every item row. It is fully derivable by
   walking the product hierarchy built in V5.1.5-V5.1.8:
       sku -> model -> family -> category
   Measured across all 77,155 rows: ZERO rows where the walk fails to resolve, and
   ZERO rows where the walked category differs from the stored one.

   It is therefore not carried into silver, for the reason established in V5.1.10
   and repeated in V5.1.11: two copies of one fact with no way to enforce
   agreement, so the day a SKU is re-classified the item rows silently contradict
   the hierarchy. sku_code reaches the category in three joins, all of which are
   already conformed and all of which have zero orphans.

   Note this is a slightly stronger case for dropping than either earlier one. The
   customer's country_name was one lookup away; this is four levels away, which
   means it is the column most likely to be used as a shortcut and therefore the
   one most likely to drift unnoticed. Bronze remains the faithful record.

   THE CURRENCY SCALE APPLIES HERE TOO - AND THERE IS NO CURRENCY COLUMN
   --------------------------------------------------------------------
   unit_price, discount_amount, tax_amount and line_total are all subject to the
   USD-scaling defect documented at length in V5.1.12: every amount in this data
   was generated on one USD-like scale and the currency is only a label.

   What makes it sharper here is that THIS TABLE HAS NO CURRENCY COLUMN AT ALL.
   The currency lives on the header, so an item amount is a bare number with no
   indication of its denomination. Consequences:
     - unit_price is NOT comparable across rows without joining the header for
       currency. A naive AVG(unit_price) by sku_code silently averages 27
       currencies together.
     - The same applies to any price-variance or discount-rate analysis, which
       V5.1.8 already flagged as needing a fact-derived baseline: that baseline
       must be computed per (sku_code, currency), which requires the header join.
   No flag, for the reasons given in V5.1.12 - the defect affects 100% of rows, so
   flagging the detectable subset would falsely imply the rest are sound, and the
   minor_unit test needs a two-table hop anyway.

   QUALITY CHECKS
   --------------------------------------------------------------------
   Record-level HARD REJECT: null or blank transaction_line_id (per V5.1.2).
   None exist.

   transaction_sk IS FLAGGED, NOT REJECTED, and this is the one place in the layer
   where that choice is genuinely arguable. A line with no transaction_sk cannot
   join to its header, so it has no customer, no store, no country, no currency
   and no date - it is very nearly useless. The case for keeping it anyway is that
   it still carries a real sku_code and a real amount, so it remains countable as
   revenue-that-failed-to-attribute, and silently deleting revenue is a worse
   failure than reporting unattributable revenue. The hard reject stays reserved
   for rows that cannot be identified AT ALL, which is the line's own key. Zero
   rows today either way.

   FLAGGED - all zero today, which is the point for a fact table:
       NULL_TRANSACTION_SK        cannot join to its header (see above)
       NULL_LINE_NUMBER / NONPOSITIVE_LINE_NUMBER
       NULL_SKU_CODE              cannot identify the product sold
       NULL_QUANTITY / NONPOSITIVE_QUANTITY
       NULL_UNIT_PRICE / NONPOSITIVE_UNIT_PRICE
       NULL_DISCOUNT / NULL_TAX / NULL_LINE_TOTAL
       NEGATIVE_DISCOUNT / NEGATIVE_TAX
       NONPOSITIVE_LINE_TOTAL
       DISCOUNT_EXCEEDS_EXTENDED  discount_amount > quantity * unit_price
       LINE_TOTAL_FORMULA_BREAK   line_total <> quantity * unit_price
                                  - discount_amount + tax_amount, to the cent

   LINE_TOTAL_FORMULA_BREAK is the most valuable flag on this table, for the same
   reason as its header counterpart: it is the only consistency check that needs no
   other table and makes no assumption about the currency scale. It also covers
   more ground here than on the header, because it validates the extension
   (quantity * unit_price) as well as the three-term sum - the header stores gross
   as a single number and so cannot check the multiplication at all.

   The 0.005 tolerance rather than exact equality is deliberate, for the reason
   given in V5.1.12: these are NUMBER columns today so exact comparison would
   work, but the tolerance costs nothing and survives a future float-delivering
   source, while staying tighter than half a cent so it cannot hide a real
   rounding error.

   NO FLAG for tax_amount = 0 - it is zero on 1,205 rows, exactly matching the
   header's 1,205, and those are legitimate zero-rate jurisdictions (V5.1.3).
   NO FLAG for line_number being 1, per the 100% rule.
   NO CROSS-TABLE FLAGS: agreement with the header's measures, and the SKU's
   availability in the transaction's country, both need a join and are therefore
   set-level assertions in the VALIDATION block (V5.1.7).

   NORMALISATION
   --------------------------------------------------------------------
     transaction_line_id  UPPER+TRIM - structured (LINE-<hex>), already
                          upper-case, so normalising mutates nothing.
     transaction_sk       TRIM ONLY - a lowercase UUID, and the join key to
                          sv_sales_header which is also TRIM-only. Verified
                          lowercase on both sides. This is the V5.1.10 trap: an
                          UPPER() here would orphan all 77,155 lines from their
                          headers while leaving both tables looking healthy.
     sku_code             UPPER+TRIM - the join key to sv_product_sku_master,
                          which upper-cases it too. A casing mismatch here would
                          drop revenue from every product report.
     line_number, quantity and the four amounts need no normalisation.

   CONFIGURATION - identical to V5.1.1, mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG = DOWNSTREAM, REFRESH_MODE = INCREMENTAL (explicit),
     TRANSIENT, INITIALIZE = ON_CREATE

   No updated_at on this table, so the V5.1.1 survivor ordering applies unchanged.

   Depends on: V2.1.2 (SILVER schema), V4.6.2 (bronze sales item),
               V5.1.12 and V5.1.5-V5.1.8 (validation joins only),
               V1.1.4 (MEDALLION_LAYER tag).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_sales_item
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver sales item: de-duplicated on transaction_line_id. Exactly 1:1 with sv_sales_header, whose measures duplicate these - never sum both. Amounts are USD-scaled and this table has no currency column. Denormalised category_code dropped.'
AS
SELECT
    -- Business key. Structured and already upper-case, so normalising is safe.
    UPPER(TRIM(b.transaction_line_id))                      AS transaction_line_id,
    -- FK to sv_sales_header. TRIM ONLY - lowercase UUID on both sides. An
    -- UPPER() here would orphan all 77,155 lines. See V5.1.10.
    TRIM(b.transaction_sk)                                  AS transaction_sk,
    -- 1 on every row today. Kept as half the alternate key and for the day
    -- multi-line transactions appear. Not flagged: a 100% value cannot signal.
    b.line_number,
    -- Join key to the product hierarchy. category_code is NOT carried - it is
    -- derivable from this in three joins. See header.
    UPPER(TRIM(b.sku_code))                                 AS sku_code,
    b.quantity,
    -- THE MEASURES. All USD-scaled regardless of the header's currency label,
    -- and this table has NO currency column - see header before comparing them.
    b.unit_price,
    b.discount_amount,
    b.tax_amount,
    b.line_total,
    b.created_at                                            AS source_created_at,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        -- Flagged, not rejected: the line still carries a real SKU and a real
        -- amount, and deleting revenue is worse than reporting it
        -- unattributable. See header - this is the layer's closest call.
        IFF(TRIM(b.transaction_sk) IS NULL OR TRIM(b.transaction_sk)='','NULL_TRANSACTION_SK',NULL),
        IFF(b.line_number IS NULL,                              'NULL_LINE_NUMBER',      NULL),
        IFF(b.line_number IS NOT NULL AND b.line_number <= 0,   'NONPOSITIVE_LINE_NUMBER',NULL),
        IFF(TRIM(b.sku_code) IS NULL OR TRIM(b.sku_code)='',    'NULL_SKU_CODE',         NULL),
        IFF(b.quantity IS NULL,                                 'NULL_QUANTITY',         NULL),
        IFF(b.quantity IS NOT NULL AND b.quantity <= 0,         'NONPOSITIVE_QUANTITY',  NULL),
        IFF(b.unit_price IS NULL,                               'NULL_UNIT_PRICE',       NULL),
        IFF(b.unit_price IS NOT NULL AND b.unit_price <= 0,     'NONPOSITIVE_UNIT_PRICE',NULL),
        IFF(b.discount_amount IS NULL,                          'NULL_DISCOUNT',         NULL),
        IFF(b.tax_amount IS NULL,                               'NULL_TAX',              NULL),
        IFF(b.line_total IS NULL,                               'NULL_LINE_TOTAL',       NULL),
        IFF(b.discount_amount < 0,                              'NEGATIVE_DISCOUNT',     NULL),
        IFF(b.tax_amount      < 0,                              'NEGATIVE_TAX',          NULL),
        IFF(b.line_total     <= 0,                              'NONPOSITIVE_LINE_TOTAL',NULL),
        IFF(b.discount_amount > b.quantity * b.unit_price,      'DISCOUNT_EXCEEDS_EXTENDED',NULL),
        -- The most valuable flag here: it validates the EXTENSION as well as the
        -- three-term sum, which the header cannot do because it stores gross as
        -- a single number.
        IFF(ABS(b.line_total - (b.quantity * b.unit_price - b.discount_amount + b.tax_amount)) > 0.005,
                                                                'LINE_TOTAL_FORMULA_BREAK',NULL)
        -- Deliberately absent: no flag on tax_amount = 0 (legitimate zero-rate
        -- jurisdictions), none on line_number = 1 (100% rule), and no
        -- cross-table checks against the header's measures or the SKU's country
        -- availability - both need a join and are asserted in VALIDATION.
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.transaction_line_id))) AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_sales_item b
WHERE b.transaction_line_id IS NOT NULL
  AND TRIM(b.transaction_line_id) <> ''
QUALIFY ROW_NUMBER() OVER (
          PARTITION BY UPPER(TRIM(b.transaction_line_id))
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_sales_item
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SHOW DYNAMIC TABLES LIKE 'SV_SALES_ITEM' IN SCHEMA {{ database }}.SILVER;
-- Expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.

USE DATABASE {{ database }};
SELECT dt.name, rec.value:"code"::STRING AS rec_code, rec.value:"info"::STRING AS rec_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_SALES_ITEM')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;
-- Expect ZERO rows.

-- Reconciliation, de-dup on BOTH candidate keys, DQ count, FK integrity.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_item)                              AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item)                              AS silver_rows,
       (SELECT COUNT(DISTINCT transaction_line_id) FROM {{ database }}.SILVER.sv_sales_item)    AS silver_line_ids,
       (SELECT COUNT(DISTINCT transaction_sk || '|' || line_number) FROM {{ database }}.SILVER.sv_sales_item) AS silver_alt_keys,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item WHERE __bronze_row_count > 1)  AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item WHERE dq_issue_flags IS NOT NULL) AS dq_flagged,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item i
          LEFT JOIN {{ database }}.SILVER.sv_sales_header h ON i.transaction_sk=h.transaction_sk
          WHERE h.transaction_sk IS NULL)                                                      AS orphan_header,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item i
          LEFT JOIN {{ database }}.SILVER.sv_product_sku_master s ON i.sku_code=s.sku_code
          WHERE s.sku_code IS NULL)                                                            AS orphan_sku;
-- Recorded: 77155, 77155, 77155, 77155, 0, 0, 0, 0
-- silver_rows must equal BOTH silver_line_ids and silver_alt_keys.

-- KEY-MUTATION PROOF (the V5.1.10 lesson). Non-zero means the lines have been
-- silently orphaned from their headers.
SELECT SUM(IFF(transaction_sk <> LOWER(transaction_sk),1,0)) AS sk_mutated
FROM {{ database }}.SILVER.sv_sales_item;
-- Recorded: 0

-- ==========================================================================
-- THE 1:1 BIJECTION, proved in both directions. Any change here invalidates
-- assumptions made in V5.1.12 as well.
-- ==========================================================================
SELECT (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header)                         AS header_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_item)                           AS item_rows,
       (SELECT COUNT(DISTINCT transaction_sk) FROM {{ database }}.SILVER.sv_sales_item)      AS distinct_sks_in_items,
       (SELECT MIN(line_number) FROM {{ database }}.SILVER.sv_sales_item)                    AS min_line_number,
       (SELECT MAX(line_number) FROM {{ database }}.SILVER.sv_sales_item)                    AS max_line_number,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
          LEFT JOIN {{ database }}.SILVER.sv_sales_item i ON h.transaction_sk=i.transaction_sk
          WHERE i.transaction_sk IS NULL)                                                   AS headers_without_item;
-- Recorded: 77155, 77155, 77155, 1, 1, 0
-- distinct_sks_in_items = item_rows means no transaction has two lines.
-- headers_without_item = 0 means none is missing one. An exact bijection - and an
-- artefact of generation, NOT a guarantee. Do not build logic that assumes it.

-- ==========================================================================
-- THE DOUBLE-COUNT TRAP: the header's measures are this table's, to the cent.
-- ==========================================================================
SELECT COUNT(*)                                                              AS pairs,
       SUM(IFF(ABS(h.gross_amount   - i.quantity * i.unit_price) > 0.005,1,0)) AS gross_differs,
       SUM(IFF(ABS(h.total_discount - i.discount_amount) > 0.005,1,0))         AS discount_differs,
       SUM(IFF(ABS(h.total_tax      - i.tax_amount) > 0.005,1,0))              AS tax_differs,
       SUM(IFF(ABS(h.net_total      - i.line_total) > 0.005,1,0))              AS net_differs
FROM {{ database }}.SILVER.sv_sales_header h
JOIN {{ database }}.SILVER.sv_sales_item   i ON h.transaction_sk = i.transaction_sk;
-- Recorded: 77155, 0, 0, 0, 0
-- All four zero. Gold must pick ONE table as the revenue source; summing both
-- doubles every amount while leaving the row count looking perfectly correct.

-- The same trap demonstrated as totals, so the size of the error is visible.
SELECT ROUND((SELECT SUM(net_total)  FROM {{ database }}.SILVER.sv_sales_header),2) AS header_total,
       ROUND((SELECT SUM(line_total) FROM {{ database }}.SILVER.sv_sales_item),2)   AS item_total,
       ROUND((SELECT SUM(h.net_total + i.line_total)
              FROM {{ database }}.SILVER.sv_sales_header h
              JOIN {{ database }}.SILVER.sv_sales_item i ON h.transaction_sk=i.transaction_sk),2) AS naive_joined_total;
-- header_total and item_total are IDENTICAL. naive_joined_total is exactly double
-- and is what an unwary gold build produces. (All three are mixed-currency and
-- therefore semantically void regardless - see V5.1.12.)

-- ==========================================================================
-- DROPPED-COLUMN PROOF: category is still reachable, four joins deep.
-- ==========================================================================
SELECT COUNT(*)                          AS items_resolved,
       COUNT(DISTINCT cat.category_code)  AS categories_recovered,
       COUNT(DISTINCT f.family_code)      AS families_recovered
FROM {{ database }}.SILVER.sv_sales_item i
JOIN {{ database }}.SILVER.sv_product_sku_master      s   ON i.sku_code      = s.sku_code
JOIN {{ database }}.SILVER.sv_product_model_master    m   ON s.model_code    = m.model_code
JOIN {{ database }}.SILVER.sv_product_family_master   f   ON m.family_code   = f.family_code
JOIN {{ database }}.SILVER.sv_product_category_master cat ON f.category_code = cat.category_code;
-- Recorded: 77155 items resolved, 10 categories, 43 families. items_resolved must
-- equal silver_rows - if lower, the hierarchy has a break; if higher, a parent
-- level has duplicate keys and the fact has started fanning out.

-- Arithmetic integrity - the flag that matters most, and it is clean. Note this
-- validates the EXTENSION too, which the header cannot.
SELECT COUNT(*) AS silver_rows,
       SUM(IFF(ABS(line_total-(quantity*unit_price-discount_amount+tax_amount)) > 0.005,1,0)) AS formula_breaks,
       SUM(IFF(quantity <= 0,1,0))                          AS nonpositive_quantity,
       SUM(IFF(unit_price <= 0,1,0))                        AS nonpositive_unit_price,
       SUM(IFF(discount_amount > quantity*unit_price,1,0))   AS discount_exceeds_extended,
       SUM(IFF(tax_amount = 0,1,0))                         AS zero_tax_rows,
       MIN(quantity) AS min_qty, MAX(quantity) AS max_qty
FROM {{ database }}.SILVER.sv_sales_item;
-- Recorded: 77155, 0, 0, 0, 0, 1205, 1, 2
-- zero_tax_rows = 1205 matches the header exactly and is legitimate (V5.1.3).

-- CROSS-TABLE ASSERTION: every SKU sold was available in the transaction's
-- country. Deliberately not a row flag - it needs two joins (V5.1.7).
SELECT COUNT(*) AS items_checked,
       SUM(IFF(a.sku_code IS NULL,1,0)) AS sold_where_unavailable
FROM {{ database }}.SILVER.sv_sales_item i
JOIN {{ database }}.SILVER.sv_sales_header h ON i.transaction_sk = h.transaction_sk
LEFT JOIN {{ database }}.SILVER.sv_product_country_availability a
       ON i.sku_code = a.sku_code AND h.country_code = a.country_code;
-- Recorded: 77155, 0
-- Passes trivially: V5.1.9 established that availability is a complete 650x35
-- cartesian with is_available TRUE everywhere, so this check cannot currently
-- fail. It becomes meaningful only once availability turns selective - kept for
-- that reason, and noted here so a clean result is not mistaken for evidence.

-- Top products by volume - a first look at the fact through the hierarchy.
-- Amounts are deliberately absent: they are mixed-currency (see V5.1.12).
SELECT cat.category_code, f.family_code, SUM(i.quantity) AS units, COUNT(*) AS lines_
FROM {{ database }}.SILVER.sv_sales_item i
JOIN {{ database }}.SILVER.sv_product_sku_master      s   ON i.sku_code      = s.sku_code
JOIN {{ database }}.SILVER.sv_product_model_master    m   ON s.model_code    = m.model_code
JOIN {{ database }}.SILVER.sv_product_family_master   f   ON m.family_code   = f.family_code
JOIN {{ database }}.SILVER.sv_product_category_master cat ON f.category_code = cat.category_code
GROUP BY 1,2 ORDER BY units DESC LIMIT 10;

-- Anything needing attention (expect ZERO rows)
SELECT transaction_line_id, transaction_sk, sku_code, dq_issue_flags,
       __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_sales_item
WHERE dq_issue_flags IS NOT NULL OR __bronze_row_count > 1
ORDER BY transaction_line_id;
