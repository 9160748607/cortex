/* ---------------------------------------------------------------------------
   V5.1.12 - Silver sales header (dynamic table)

   Twelfth bronze -> silver transformation, and the FIRST FACT TABLE in the layer.
   Everything before this was a dimension. Paired with V5.1.13 (sales item),
   which must be read alongside it - the two tables are in an exact 1:1
   relationship and that fact governs several decisions here.

   Reuses the pattern from V5.1.1 - see that header for de-duplication,
   deterministic survivor ordering and why there is no silver load-timestamp
   column. See V5.1.7 for the rule that row-level flags describe only their own
   row, V5.1.10 for the lowercase-UUID key lesson, and V5.1.11 for the
   store-chronology defect that surfaces here.

   ENTITY DOMAIN
   --------------------------------------------------------------------
     Grain         one row per transaction_sk
     Business key  transaction_sk - a lowercase UUID (surrogate, from source)
     Alternate key transaction_id - TXN-<hex>, also unique across all 77,155
     Volume        77,155 rows, 15 source columns
     Source system SAP_SD - a third source, distinct from MDM (customer) and
                   RETAIL_OPS (store)
     Foreign keys  customer_id -> sv_customer_master     ZERO orphans, ZERO nulls
                   country_code -> sv_country_master      ZERO orphans
                   currency -> sv_currency_master         ZERO orphans
                   store_id -> sv_store_master            ZERO orphans, but
                                                          15,351 legitimate NULLs
     Referenced by sv_sales_item (V5.1.13), 1:1

     channel_id       ONLINE 15,351 / POS 61,804
     payment_method   9 values (Visa, Mastercard, Amex, Discover, Apple Pay,
                      Apple Financing, Corporate Financing, Bank EMI, Cash)
     currency         27 distinct
     transaction ts   2019-01-01 00:49 to 2020-01-01 02:55

   WHAT IS ACTUALLY CLEAN HERE - and it is a lot
   --------------------------------------------------------------------
   Worth stating plainly before the defects, because the defects are all about
   VALUES and CHRONOLOGY, never about structure:
     - Both candidate keys are fully unique. No duplicates to resolve.
     - Every FK resolves. Zero orphans on customer, country, currency and store.
     - net_total = gross_amount - total_discount + total_tax holds on ALL 77,155
       rows, to the cent. Zero arithmetic breaks.
     - No negative gross, discount or tax. No non-positive net. No discount
       exceeding gross. No NULL amounts anywhere.
     - channel_id and store_id agree PERFECTLY: store_id IS NULL on exactly the
       15,351 ONLINE rows, and populated on exactly the 61,804 POS rows. Zero
       ONLINE-with-store, zero POS-without-store.
     - Geography is internally coherent: header country matches the store's
       country and the customer's country on every row, and currency matches the
       country's currency on every row. Zero mismatches on all three.

   So the structural integrity of this fact is exact. The problems are elsewhere.

   ==========================================================================
   DEFECT 1 - THE CURRENCY SCALE, AND WHY ROUNDING WOULD MAKE IT WORSE
   ==========================================================================
   V5.1.2 carried forward that 8,471 rows hold decimal amounts in JPY and KRW,
   currencies with minor_unit = 0, and proposed that the sales layer should
   "either ROUND() the amounts to it or raise a DQ flag". MEASURED HERE, BOTH
   OPTIONS ARE WRONG, and the reason is that the 8,471 figure understates the
   problem by an order of magnitude.

   Average net_total by currency, measured across all 27:
       DKK 773   NOK 758   SEK 735   TRY 711   PLN 706   EUR 701
       ZAR 696   MYR 679   MXN 676   INR 675   BRL 672   GBP 669
       JPY 624   KRW 628   ... every single currency lands in 620-780.
   A currency-agnostic band like that cannot occur in real retail. EUR 701 is a
   plausible Apple basket (~USD 760). The same 675 in INR is about USD 8, when a
   real basket would be ~65,000 INR. JPY 624 is about USD 4 against a real
   ~90,000 JPY.

   THE PRODUCER GENERATED EVERY AMOUNT ON ONE USD-LIKE SCALE AND ATTACHED A
   CURRENCY LABEL. The defect therefore affects ALL 77,155 ROWS, not 8,471. JPY
   and KRW are merely where it becomes DETECTABLE, because those are the only
   currencies whose minor_unit makes a decimal self-evidently illegal. INR, MXN
   and ZAR are wrong by the same factor and pass every decimal test.

   Consequences, and they are the important part of this header:

   1. DO NOT ROUND. Rounding JPY 623.51 to 624 produces a type-correct value that
      is still wrong by ~150x. It would destroy the only visible evidence of the
      defect while fixing nothing - the worst possible outcome, strictly worse
      than leaving it alone. The V5.1.2 suggestion is withdrawn.

   2. CROSS-CURRENCY AGGREGATION IS INVALID. SUM(net_total) across countries is
      meaningless: it adds USD-scaled numbers wearing 27 different labels. And
      there is NO EXCHANGE-RATE TABLE anywhere in this model, so it cannot be
      made valid by conversion either. Any gold revenue measure must either stay
      single-currency or wait for an FX dimension. This is the single most
      dangerous thing about this table, because such a SUM runs without error and
      returns a confident, wrong number.

   3. NO ROW-LEVEL FLAG IS RAISED. Three reasons, in order of weight:
      - Flagging only the 8,471 detectable rows would ASSERT THAT THE OTHER
        68,684 ARE FINE. They are not. A flag that implies a false negative on
        88% of the table is worse than no flag.
      - The check needs minor_unit from sv_currency_master, so it is a cross-table
        comparison, which the V5.1.7 rule assigns to set-level validation.
      - A hard-coded IN ('JPY','KRW') would avoid the join but is an incomplete
        ISO 4217 zero-decimal list (VND, CLP, ISK and others also qualify), so it
        would be wrong the moment the data widens.
      The evidence is instead reproduced in the VALIDATION block, where it can
      show the scale across ALL currencies rather than a misleading subset.

   ==========================================================================
   DEFECT 2 - sv_tax_master HOLDS CURRENT RATES, NOT 2019 RATES
   ==========================================================================
   New finding, and it invalidates the obvious tax reconciliation. Recomputing
   total_tax as (gross_amount - total_discount) * tax_rate, with tax_rate taken
   through country -> sv_tax_master, matches EXACTLY on most countries and fails
   on five, covering 5,609 rows:

       tax_code        master rate   effective rate   rows
       FI_VAT_STD         25.5%          24.0%         255
       CH_VAT_STD          8.1%           7.7%         754
       MY_SST_STD         10.0%           6.0%         526
       BR_ICMS_STD        17.0%          12.0%       1,033
       CA_GST_STD          5.0%          13.0%       3,041

   FOUR OF THE FIVE ARE THE SAME STORY, AND IT IS NOT A DATA ERROR. Finland
   raised VAT from 24% to 25.5% in 2024. Switzerland raised it from 7.7% to 8.1%
   in January 2024. Malaysia moved SST from 6% to 10% in 2024. In every case the
   EFFECTIVE rate in the data is the rate that was correct IN 2019, and the
   master holds the rate that is correct TODAY. The transactions are right; the
   dimension is simply not time-variant.

   sv_tax_master has effective_start_date / effective_end_date columns but only
   ONE ROW PER COUNTRY, so it cannot represent a rate change. It is a current-state
   dimension wearing temporal clothing.

   CA_GST_STD is a different problem: 5% is the FEDERAL GST while the data charges
   13%, which is Ontario's combined HST. That is a GRAIN mismatch, not a temporal
   one - Canadian tax is provincial and the master models it nationally. It is the
   same country-level-versus-subdivision issue that V5.1.11 decoded in
   tax_jurisdiction_code, surfacing again on the rate side.

   THE RULE THAT FOLLOWS: total_tax AS RECORDED ON THE TRANSACTION IS
   AUTHORITATIVE. Never recompute historical tax from sv_tax_master, and never
   flag a transaction for disagreeing with it - the transaction is the primary
   record of what was actually charged, and the dimension is a present-day
   lookup. Hence NO TAX_RATE_MISMATCH FLAG on this table, despite it being
   trivially computable. Flagging 5,609 rows would blame the fact for the
   dimension's missing history.

   For gold: sv_tax_master is safe for CURRENT rate lookups and for tax_type /
   inclusive-flag attributes. It is NOT safe for historical recomputation. Making
   it safe means making it a genuine type-2 dimension with one row per
   (jurisdiction, rate period) - a real modelling change, recorded here as an
   open item rather than patched over.

   ==========================================================================
   DEFECT 3 - 38,102 ROWS PREDATE THEIR STORE'S OPENING, AND WHERE THE FLAG GOES
   ==========================================================================
   Carried from V5.1.11: 67 of 121 stores open after the 2019 sales period (the
   latest in April 2026), so 38,102 rows - 61.6% of the 61,804 store-attributed
   rows - point at a store that did not yet exist.

   V5.1.11's header stated that "V5.1.12 owns the row-level flag". THAT IS
   REVISED HERE, and the reason is a rule this layer already committed to.

   The check requires comparing transaction_timestamp to the STORE'S OWN
   store_open_date, which means joining sv_store_master into this dynamic table's
   definition. The V5.1.7 rule is explicit that a DT's flags describe only its own
   row and that anything needing a second table is a set-level assertion. Adding
   the join would also make a 77,155-row fact refresh whenever a 121-row dimension
   changes, and would start this silver fact down the path of joining all five of
   its dimensions - which is a gold star-schema build, not a silver cleanse.

   So the chronology check belongs in GOLD, where the fact is conformed against
   its dimensions anyway, or as a data-metric function on the joined result. It is
   asserted in the VALIDATION block with the exact SQL. The earlier promise was
   made before that consequence was thought through; keeping the promise would
   have meant breaking a better rule.

   The constraint from V5.1.11 still stands and matters: whoever implements it
   must compare against each store's own open date via the join, NEVER a
   hard-coded '2019-12-31'. A literal happens to work on this load and silently
   stops working on the next.

   TWENTY-FOUR ROWS TIMESTAMPED 2020 - NOT FLAGGED, AND WHY
   --------------------------------------------------------------------
   The 2019 file contains 24 rows timestamped between 2020-01-01 00:00 and
   02:55 - timezone spillover, where a transaction late on 31 December in one
   zone lands in the next year once normalised to NTZ.

   No flag, for the same reason the store threshold is rejected: expressing it
   needs a hard-coded year boundary, and a rule that must be edited every January
   is a rule that will be wrong every January. The rows are also almost certainly
   CORRECT - the timestamp is real, only the file-partitioning assumption is
   naive. Asserted in validation, and noted for the gold date dimension, which
   must cover 2020-01-01 or 24 rows will fail to join to a calendar.

   MEASURES ARE IDENTICAL TO sv_sales_item - DO NOT SUM BOTH
   --------------------------------------------------------------------
   Because the relationship is exactly 1:1 (V5.1.13), the four header measures are
   a verbatim restatement of the item measures. Verified across all 77,155 pairs,
   to the cent, zero exceptions:
       gross_amount   = quantity * unit_price
       total_discount = discount_amount
       total_tax      = tax_amount
       net_total      = line_total

   The header therefore carries NO INDEPENDENT MEASURE. Gold must choose exactly
   ONE of the two tables as the revenue source. Joining both and summing measures
   from each double-counts every figure, and because the relationship is 1:1 the
   row count will look perfectly correct while every amount is doubled - a defect
   with no symptom other than being wrong.

   The measures are nonetheless KEPT on both tables rather than stripped from one.
   This is a genuine header-grain total in any normal schema; it is only redundant
   because this particular data has one line per transaction, which is an artefact
   of generation (V5.1.9 recorded the same 1:1 property). The day a second line
   appears, the header total stops being derivable and becomes the authoritative
   transaction total. Stripping it now would mean rebuilding it later.

   QUALITY CHECKS
   --------------------------------------------------------------------
   Record-level HARD REJECT: null or blank transaction_sk (per V5.1.2). None
   exist. Note the reject is on the SURROGATE, not transaction_id - the surrogate
   is what sv_sales_item joins on, so a row without it cannot carry its own line.

   FLAGGED - every one of these is ZERO today, which is the point: this is a fact
   table, and the arithmetic guards must exist before the day an amount arrives
   broken, not after.
       MISSING_TRANSACTION_ID      alternate key null or blank
       NULL_CUSTOMER_ID            flagged not rejected
       NULL_COUNTRY_CODE / NULL_CURRENCY / NULL_CHANNEL_ID / NULL_PAYMENT_METHOD
       NULL_TRANSACTION_TIMESTAMP
       IMPLAUSIBLE_TIMESTAMP       before 2000-01-01 (static literal - see V5.1.6)
       NULL_GROSS_AMOUNT / NULL_NET_TOTAL / NULL_DISCOUNT / NULL_TAX
       NEGATIVE_GROSS / NEGATIVE_DISCOUNT / NEGATIVE_TAX
       NONPOSITIVE_NET             a completed sale must have a positive total
       DISCOUNT_EXCEEDS_GROSS      a discount cannot exceed what is discounted
       NET_TOTAL_FORMULA_BREAK     net <> gross - discount + tax, to the cent.
                                   The most valuable flag on the table: it is the
                                   one internal consistency check that needs no
                                   other table and no assumption about currency.
       ONLINE_WITH_STORE           channel ONLINE but store_id populated
       POS_WITHOUT_STORE           channel POS but store_id absent
       NULL_SOURCE_SYSTEM

   NULL store_id IS NOT FLAGGED. It is the correct encoding of an online sale on
   15,351 rows and agrees exactly with channel_id. What IS flagged is DISAGREEMENT
   between the two columns - the coherence, not the nullability. Same judgement as
   NULL state_code in V5.1.11 and NULL discontinue_date in V5.1.7.

   NO ALLOW-LIST on channel_id or payment_method, per V5.1.5/V5.1.6: a tenth
   payment method is a business change, not a defect.

   A NOTE ON THE ARITHMETIC TOLERANCE: the formula checks use a 0.005 tolerance
   rather than exact equality. These are NUMBER columns, not floats, so exact
   comparison would work today - but the tolerance costs nothing and protects
   against a future source that delivers the same values as floats, where exact
   equality on a three-term sum is not guaranteed. It is deliberately tighter than
   half a cent so it cannot mask a real rounding error.

   NORMALISATION
   --------------------------------------------------------------------
     transaction_sk    TRIM ONLY - a lowercase UUID, exactly the V5.1.10 case.
                       Upper-casing would mutate all 77,155 values AND break the
                       join to sv_sales_item, whose transaction_sk is also
                       lowercase (verified on both sides). For an opaque
                       surrogate the rule is: both sides must be treated
                       identically, and neither should be re-cased.
     transaction_id    UPPER+TRIM - structured (TXN-<hex>), already upper-case,
                       so normalising is safe and mutates nothing.
     country_code, currency, channel_id, store_id
                       UPPER+TRIM - join keys and codes.
     customer_id       TRIM ONLY - lowercase UUID, must match sv_customer_master
                       which is also TRIM-only. This is the column where an
                       accidental UPPER() would orphan all 77,155 rows.
     payment_method    TRIM only - a display value with meaningful casing
                       ("Apple Pay", not "APPLE PAY").

   CONFIGURATION - identical to V5.1.1, mandated by the architecture
   --------------------------------------------------------------------
     TARGET_LAG = DOWNSTREAM, REFRESH_MODE = INCREMENTAL (explicit),
     TRANSIENT, INITIALIZE = ON_CREATE

   No updated_at on this table, so the V5.1.1 survivor ordering applies unchanged.

   Depends on: V2.1.2 (SILVER schema), V4.6.1 (bronze sales header),
               V5.1.4 / V5.1.2 / V5.1.10 / V5.1.11 (validation joins only),
               V1.1.4 (MEDALLION_LAYER tag).
   Open items: an FX-rate dimension (blocks all cross-currency revenue), and a
               type-2 sv_tax_master (blocks historical tax recomputation).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.sv_sales_header
  TARGET_LAG   = DOWNSTREAM
  WAREHOUSE    = {{ warehouse }}
  REFRESH_MODE = INCREMENTAL
  INITIALIZE   = ON_CREATE
  COMMENT = 'Silver sales header: de-duplicated on transaction_sk (lowercase UUID, NOT upper-cased). Amounts are USD-scaled regardless of currency label - cross-currency SUM is invalid. Measures duplicate sv_sales_item 1:1 - never sum both.'
AS
SELECT
    -- Business key. TRIM ONLY - lowercase UUID, and sv_sales_item joins on it.
    -- See V5.1.10: upper-casing would mutate every value and break the join.
    TRIM(b.transaction_sk)                                  AS transaction_sk,
    -- Alternate key. Structured and already upper-case, so normalising is safe.
    UPPER(TRIM(b.transaction_id))                           AS transaction_id,
    b.transaction_timestamp,
    -- TRIM ONLY - lowercase UUID matching sv_customer_master's TRIM-only key.
    -- An UPPER() here would orphan all 77,155 rows.
    TRIM(b.customer_id)                                     AS customer_id,
    -- NULL on exactly the 15,351 ONLINE rows. That is correct, not missing.
    UPPER(TRIM(b.store_id))                                 AS store_id,
    UPPER(TRIM(b.channel_id))                               AS channel_id,
    UPPER(TRIM(b.country_code))                             AS country_code,
    -- TRIM only: "Apple Pay" carries meaningful casing.
    TRIM(b.payment_method)                                  AS payment_method,
    UPPER(TRIM(b.currency))                                 AS currency,
    -- THE MEASURES. All four are USD-scaled regardless of the currency label
    -- above, and all four duplicate sv_sales_item exactly. See header.
    b.gross_amount,
    b.total_discount,
    b.total_tax,
    b.net_total,
    b.created_at                                            AS source_created_at,
    b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.transaction_id) IS NULL OR TRIM(b.transaction_id)='','MISSING_TRANSACTION_ID',NULL),
        -- Flagged, never rejected: an unattributed sale is still revenue.
        IFF(TRIM(b.customer_id) IS NULL OR TRIM(b.customer_id)='','NULL_CUSTOMER_ID',NULL),
        IFF(b.country_code IS NULL OR TRIM(b.country_code)='',  'NULL_COUNTRY_CODE',     NULL),
        IFF(b.currency IS NULL OR TRIM(b.currency)='',          'NULL_CURRENCY',         NULL),
        IFF(b.channel_id IS NULL OR TRIM(b.channel_id)='',      'NULL_CHANNEL_ID',       NULL),
        IFF(TRIM(b.payment_method) IS NULL OR TRIM(b.payment_method)='','NULL_PAYMENT_METHOD',NULL),
        IFF(b.transaction_timestamp IS NULL,                    'NULL_TRANSACTION_TIMESTAMP',NULL),
        -- STATIC literal: CURRENT_DATE() would force FULL refresh (V5.1.6).
        IFF(b.transaction_timestamp < '2000-01-01'::TIMESTAMP_NTZ,'IMPLAUSIBLE_TIMESTAMP',NULL),
        -- Deliberately NO flag for a 2020 timestamp: it needs a hard-coded year
        -- boundary and the rows are probably correct. See header.
        IFF(b.gross_amount IS NULL,                             'NULL_GROSS_AMOUNT',     NULL),
        IFF(b.total_discount IS NULL,                           'NULL_DISCOUNT',         NULL),
        IFF(b.total_tax IS NULL,                                'NULL_TAX',              NULL),
        IFF(b.net_total IS NULL,                                'NULL_NET_TOTAL',        NULL),
        IFF(b.gross_amount   < 0,                               'NEGATIVE_GROSS',        NULL),
        IFF(b.total_discount < 0,                               'NEGATIVE_DISCOUNT',     NULL),
        IFF(b.total_tax      < 0,                               'NEGATIVE_TAX',          NULL),
        IFF(b.net_total     <= 0,                               'NONPOSITIVE_NET',       NULL),
        IFF(b.total_discount > b.gross_amount,                  'DISCOUNT_EXCEEDS_GROSS',NULL),
        -- The single most valuable flag here: internal consistency, needing no
        -- other table and no assumption about the currency scale.
        IFF(ABS(b.net_total - (b.gross_amount - b.total_discount + b.total_tax)) > 0.005,
                                                                'NET_TOTAL_FORMULA_BREAK',NULL),
        -- Coherence between channel and store, NOT the nullability of store_id -
        -- NULL is correct on all 15,351 ONLINE rows.
        IFF(UPPER(TRIM(b.channel_id))='ONLINE' AND b.store_id IS NOT NULL,'ONLINE_WITH_STORE',NULL),
        IFF(UPPER(TRIM(b.channel_id))='POS'    AND b.store_id IS NULL,    'POS_WITHOUT_STORE',NULL),
        IFF(b.source_system IS NULL,                            'NULL_SOURCE_SYSTEM',    NULL)
        -- Deliberately absent: no CURRENCY_MINOR_UNIT flag (it would imply the
        -- other 88% of rows are fine), no TAX_RATE_MISMATCH (blames the fact for
        -- the dimension's missing history), no SALES_BEFORE_STORE_OPEN (needs a
        -- join - belongs in gold). All three are asserted in VALIDATION.
    )),','),'')                                             AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY TRIM(b.transaction_sk))      AS __bronze_row_count,
    b.__file_name,
    b.__row_number,
    b.__file_last_modified_ntz
FROM {{ database }}.BRONZE.br_sales_header b
WHERE b.transaction_sk IS NOT NULL
  AND TRIM(b.transaction_sk) <> ''
QUALIFY ROW_NUMBER() OVER (
          -- Must match the projection's TRIM-only treatment exactly.
          PARTITION BY TRIM(b.transaction_sk)
          ORDER BY b.created_at DESC NULLS LAST,
                   b.__file_last_modified_ntz DESC NULLS LAST,
                   b.__file_name DESC,
                   b.__row_number DESC) = 1;

/* Architectural note 6: data-storing objects carry a chargeback tag. */
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_sales_header
  SET TAG {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

SHOW DYNAMIC TABLES LIKE 'SV_SALES_HEADER' IN SCHEMA {{ database }}.SILVER;
-- Expect INCREMENTAL, empty refresh_mode_reason, DOWNSTREAM, ACTIVE.

USE DATABASE {{ database }};
SELECT dt.name, rec.value:"code"::STRING AS rec_code, rec.value:"info"::STRING AS rec_info
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES(NAME => '{{ database }}.SILVER.SV_SALES_HEADER')) dt,
     LATERAL FLATTEN(INPUT => dt.recommendations:recommendations) rec;
-- Expect ZERO rows.

-- Reconciliation, de-dup on BOTH candidate keys, DQ count, and FK integrity
-- across all four dimensions.
SELECT (SELECT COUNT(*) FROM {{ database }}.BRONZE.br_sales_header)                          AS bronze_rows,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header)                          AS silver_rows,
       (SELECT COUNT(DISTINCT transaction_sk) FROM {{ database }}.SILVER.sv_sales_header)     AS silver_sks,
       (SELECT COUNT(DISTINCT transaction_id) FROM {{ database }}.SILVER.sv_sales_header)     AS silver_tids,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header WHERE __bronze_row_count > 1) AS keys_with_dupes,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header WHERE dq_issue_flags IS NOT NULL) AS dq_flagged,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
          LEFT JOIN {{ database }}.SILVER.sv_customer_master c ON h.customer_id=c.customer_id
          WHERE c.customer_id IS NULL)                                                       AS orphan_customer,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
          LEFT JOIN {{ database }}.SILVER.sv_country_master c ON h.country_code=c.country_code
          WHERE c.country_code IS NULL)                                                      AS orphan_country,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
          LEFT JOIN {{ database }}.SILVER.sv_currency_master u ON h.currency=u.currency_code
          WHERE u.currency_code IS NULL)                                                     AS orphan_currency,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
          LEFT JOIN {{ database }}.SILVER.sv_store_master s ON h.store_id=s.store_code
          WHERE h.store_id IS NOT NULL AND s.store_code IS NULL)                             AS orphan_store;
-- Recorded: 77155, 77155, 77155, 77155, 0, 0, 0, 0, 0, 0
-- silver_rows must equal BOTH silver_sks and silver_tids.

-- KEY-MUTATION PROOF (the V5.1.10 lesson). If either count is non-zero a UUID
-- has been re-cased and the corresponding join is silently broken.
SELECT SUM(IFF(transaction_sk <> LOWER(transaction_sk),1,0)) AS sk_mutated,
       SUM(IFF(customer_id    <> LOWER(customer_id),1,0))    AS customer_id_mutated
FROM {{ database }}.SILVER.sv_sales_header;
-- Recorded: 0, 0

-- ==========================================================================
-- DEFECT 1 - the currency scale, shown across ALL currencies rather than the
-- misleading JPY/KRW subset. This is why no row-level flag is raised.
-- ==========================================================================
SELECT h.currency, u.minor_unit, COUNT(*) AS rows_,
       ROUND(AVG(h.net_total),2) AS avg_net,
       SUM(IFF(h.net_total <> ROUND(h.net_total, u.minor_unit),1,0)) AS illegal_decimals
FROM {{ database }}.SILVER.sv_sales_header h
JOIN {{ database }}.SILVER.sv_currency_master u ON h.currency = u.currency_code
GROUP BY 1,2 ORDER BY avg_net DESC;
-- Recorded: every currency averages 620-780. DKK 773.65, EUR 700.90, GBP 669.38,
-- JPY 623.51, KRW 627.87. illegal_decimals is non-zero ONLY for JPY (6,767) and
-- KRW (1,704) = 8,471, because only minor_unit = 0 makes a decimal detectable.
-- The other 68,684 rows are equally USD-scaled and entirely undetectable this
-- way. DO NOT ROUND: it would erase the evidence and fix nothing.

-- And the reason cross-currency revenue cannot be reported: no FX dimension
-- exists, so this number has no meaning despite running cleanly.
SELECT COUNT(DISTINCT currency) AS currencies_summed,
       ROUND(SUM(net_total),2)  AS meaningless_mixed_currency_total
FROM {{ database }}.SILVER.sv_sales_header;
-- Recorded: 27 currencies. The total is arithmetically valid and semantically
-- void. Gold must stay single-currency until an FX dimension exists.

-- ==========================================================================
-- DEFECT 2 - sv_tax_master holds CURRENT rates, so historical recomputation
-- fails on five countries. The transaction is authoritative.
-- ==========================================================================
SELECT t.tax_code, t.tax_rate AS master_rate_today,
       ROUND(AVG(h.total_tax/NULLIF(h.gross_amount-h.total_discount,0)),4) AS effective_rate_2019,
       COUNT(*) AS rows_,
       SUM(IFF(ABS(h.total_tax - ROUND((h.gross_amount-h.total_discount)*t.tax_rate,2)) > 0.02,1,0)) AS rows_not_matching
FROM {{ database }}.SILVER.sv_sales_header h
JOIN {{ database }}.SILVER.sv_country_master c ON h.country_code = c.country_code
JOIN {{ database }}.SILVER.sv_tax_master     t ON c.tax_code     = t.tax_code
GROUP BY 1,2
HAVING SUM(IFF(ABS(h.total_tax - ROUND((h.gross_amount-h.total_discount)*t.tax_rate,2)) > 0.02,1,0)) > 0
ORDER BY rows_ DESC;
-- Recorded, 5 codes / 5,609 rows:
--   CA_GST_STD   5.0% vs 13.0%  3,041   <- GRAIN issue: federal GST vs Ontario HST
--   BR_ICMS_STD 17.0% vs 12.0%  1,033
--   CH_VAT_STD   8.1% vs  7.7%    754   <- rate rose in Jan 2024
--   MY_SST_STD  10.0% vs  6.0%    526   <- rate rose in 2024
--   FI_VAT_STD  25.5% vs 24.0%    255   <- rate rose in 2024
-- Four of five are real post-2019 rate changes: the EFFECTIVE rate is correct
-- for 2019 and the master is correct for today. sv_tax_master has one row per
-- country, so it cannot express a rate change. NEVER recompute historical tax
-- from it, and never flag the transaction for disagreeing.

-- Proof that it is a one-row-per-country dimension and therefore not temporal.
SELECT COUNT(*) AS tax_rows, COUNT(DISTINCT tax_code) AS tax_codes,
       MAX(rows_per_country) AS max_rows_per_country
FROM {{ database }}.SILVER.sv_tax_master,
     LATERAL (SELECT COUNT(*) AS rows_per_country FROM {{ database }}.SILVER.sv_tax_master t2
              WHERE SPLIT_PART(t2.tax_code,'_',1) = SPLIT_PART(sv_tax_master.tax_code,'_',1));
-- max_rows_per_country = 1 confirms there is no rate history to draw on.

-- ==========================================================================
-- DEFECT 3 - the store-chronology check. This is the SQL that gold must run;
-- it is deliberately not a flag on this table (see header).
-- ==========================================================================
SELECT COUNT(*)                                          AS store_attributed_rows,
       SUM(IFF(h.transaction_timestamp::DATE < s.store_open_date,1,0)) AS rows_before_store_opened,
       ROUND(100.0 * SUM(IFF(h.transaction_timestamp::DATE < s.store_open_date,1,0))
             / COUNT(*),1)                               AS pct_impossible,
       COUNT(DISTINCT IFF(h.transaction_timestamp::DATE < s.store_open_date, s.store_code, NULL)) AS stores_implicated
FROM {{ database }}.SILVER.sv_sales_header h
JOIN {{ database }}.SILVER.sv_store_master s ON h.store_id = s.store_code;
-- Recorded: 61804, 38102, 61.6, 67
-- Note the comparison is against EACH STORE'S OWN open date via the join - never
-- a hard-coded year, which would work on this load and fail on the next.

-- Channel / store coherence - perfect, which is why NULL store_id is unflagged.
SELECT channel_id, COUNT(*) AS rows_,
       COUNT(store_id)             AS with_store,
       COUNT(*) - COUNT(store_id)  AS without_store
FROM {{ database }}.SILVER.sv_sales_header
GROUP BY 1 ORDER BY 2 DESC;
-- Recorded: POS 61804 / 61804 with store / 0 without
--           ONLINE 15351 / 0 with store / 15351 without
-- An exact partition. NULL store_id means online, not missing.

-- Geography coherence across three dimensions - all zero.
SELECT (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
          JOIN {{ database }}.SILVER.sv_store_master s ON h.store_id=s.store_code
          WHERE h.country_code <> s.country_code)                        AS store_country_mismatch,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
          JOIN {{ database }}.SILVER.sv_customer_master c ON h.customer_id=c.customer_id
          WHERE h.country_code <> c.country_code)                        AS customer_country_mismatch,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
          JOIN {{ database }}.SILVER.sv_country_master c ON h.country_code=c.country_code
          WHERE h.currency <> c.currency_code)                           AS currency_country_mismatch;
-- Recorded: 0, 0, 0

-- The 24 timezone-spillover rows, and the date range gold's calendar must cover.
SELECT MIN(transaction_timestamp) AS earliest,
       MAX(transaction_timestamp) AS latest,
       SUM(IFF(transaction_timestamp >= '2020-01-01',1,0)) AS rows_in_2020
FROM {{ database }}.SILVER.sv_sales_header;
-- Recorded: 2019-01-01 00:49:45, 2020-01-01 02:55:21, 24
-- The date dimension MUST cover 2020-01-01 or these 24 rows will not join.

-- Arithmetic integrity - the flag that matters most, and it is clean.
SELECT COUNT(*) AS silver_rows,
       SUM(IFF(ABS(net_total-(gross_amount-total_discount+total_tax)) > 0.005,1,0)) AS formula_breaks,
       SUM(IFF(net_total <= 0,1,0))                    AS nonpositive_net,
       SUM(IFF(total_discount > gross_amount,1,0))      AS discount_exceeds_gross,
       SUM(IFF(total_tax = 0,1,0))                      AS zero_tax_rows
FROM {{ database }}.SILVER.sv_sales_header;
-- Recorded: 77155, 0, 0, 0, 1205
-- 1,205 zero-tax rows are legitimate: zero-rate jurisdictions (see V5.1.3).

-- Anything needing attention (expect ZERO rows)
SELECT transaction_sk, transaction_id, currency, dq_issue_flags,
       __bronze_row_count, __file_name, __row_number
FROM {{ database }}.SILVER.sv_sales_header
WHERE dq_issue_flags IS NOT NULL OR __bronze_row_count > 1
ORDER BY transaction_sk;
