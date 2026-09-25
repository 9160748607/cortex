/* ---------------------------------------------------------------------------
   V5.2.2 - Preserve record versions in the remaining 6 silver tables

   Completes what V5.2.1 started. V5.2.1 changed the 7 tables that had a real
   temporal version discriminator. This changes the remaining 6, which do not.

   THE LOGIC IS THE SAME; THE DISCRIMINATOR DIFFERS
   --------------------------------------------------------------------
   Same principle throughout silver: partition on (business_key, version
   discriminator) so a TRUE DUPLICATE collapses while a CHANGED record survives
   as a new version. What differs is what is available to discriminate on, and
   that is a property of the source, not a design choice:

     V5.2.1  6 tables  effective_start_date     temporal - carries a real interval
     V5.2.1  1 table   updated_at               temporal - carries a real instant
     V5.2.2  6 tables  __version_hash           CONTENT - carries no interval

   Measured: br_product_family/model/sku/country_availability and both br_sales_*
   tables have NO effective dates and NO updated_at. Only created_at, which is a
   load stamp - using it would mint a spurious version every time an unchanged
   record was redelivered in a new file.

   WHAT A CONTENT HASH BUYS, AND WHAT IT DOES NOT
   --------------------------------------------------------------------
   __version_hash = SHA1_HEX over all business attributes (excluding keys,
   metadata, created_at and dq_issue_flags, which is itself derived from the
   attributes). Two rows with identical content hash to the same value and
   collapse; a changed attribute produces a new hash and a new row.

   IT BUYS:   change is no longer mistaken for duplication. Nothing is lost.
   IT DOES NOT BUY: a validity interval. There is no valid_from/valid_to to
              derive, because the source never said WHEN the change happened.
              Gold cannot build a temporal SCD-2 dimension from these - only a
              record of distinct observed states.
   LIMITATION: an A -> B -> A change collapses to two rows, not three. Hash
              equality cannot distinguish "reverted" from "never changed".

   If temporal SCD-2 is ever needed on these entities, the feed must emit
   effective dates like the other six do. That is a source change, not something
   silver can synthesise.

   __is_current_version - AND WHY IT IS LOAD-BEARING
   --------------------------------------------------------------------
   With no temporal ordering, nothing downstream could tell WHICH version is
   current. So each of these 6 tables now also projects:

       __is_current_version =
         ROW_NUMBER() OVER (PARTITION BY <business_key>
                            ORDER BY created_at DESC NULLS LAST,
                                     __file_last_modified_ntz DESC NULLS LAST,
                                     __file_name DESC, __row_number DESC) = 1

   Why exactly one surviving row is always TRUE: this ROW_NUMBER is computed over
   the pre-QUALIFY rowset, but it uses the SAME recency ordering as the QUALIFY.
   The globally most-recent row for a key is therefore necessarily the survivor of
   its own (key, hash) partition, so it survives and carries rank 1. Verified
   after deployment - zero keys with anything other than exactly one current
   version.

   ==========================================================================
   *** REVENUE WARNING - THE FACT TABLES ***
   ==========================================================================
   V5.2.1 deliberately EXCLUDED sv_sales_header and sv_sales_item, on the grounds
   that a transaction is immutable and versioning one would double-count revenue.
   That exclusion has now been reversed by explicit instruction, so the risk is
   real and must be stated plainly rather than buried:

       ONCE A CORRECTED TRANSACTION IS REDELIVERED, ANY AGGREGATE THAT DOES NOT
       FILTER __is_current_version = TRUE WILL DOUBLE-COUNT IT.

       SELECT SUM(line_total) FROM sv_sales_item;                  -- WRONG
       SELECT SUM(line_total) FROM sv_sales_item
        WHERE __is_current_version;                                -- CORRECT

   What makes this a live hazard rather than a theoretical one: it is INVISIBLE
   TODAY. Every key has exactly one version, so both queries return the identical
   50,186,627.97. The unfiltered query will start being wrong silently, at the
   moment the first correction lands, with no error and no row-count anomaly that
   an unsuspecting reader would notice.

   Three mitigations are in place:
     1. Both table COMMENTs carry the warning, so it surfaces in DESCRIBE and in
        any catalogue tool.
     2. V8.1.7 converts hdr_sk_unique and item_line_unique from "one row per key"
        to "exactly one CURRENT version per key" - which is the invariant that
        actually protects revenue - and filters both sides of
        hdr_total_matches_lines.
     3. 06_gold/README.md records that facts must filter the flag.

   The alternative design - keeping facts at one row per key and letting a
   correction overwrite silently - trades auditability for safety. That trade was
   reasonable and was the original recommendation; it has been consciously
   reversed in favour of preserving the correction history.

   ==========================================================================
   TWO SNOWFLAKE BEHAVIOURS DISCOVERED HERE
   ==========================================================================
   1. CREATE OR ALTER CANNOT REORDER COLUMNS. Placing __version_hash next to
      __bronze_row_count failed with:
          "Cannot reorder Dynamic Table columns in ALTER.
           Saw __IS_CURRENT_VERSION before __BRONZE_ROW_COUNT."
      New columns must be APPENDED AFTER all existing ones. Hence both new
      columns sit last, after __file_last_modified_ntz, rather than grouped with
      the other metadata columns where they would read better.

      The failure also warned "Partial updates may have been applied". Checked:
      nothing had been - the error was raised at compile time, before any change
      landed. Worth re-checking rather than assuming, if this recurs.

   2. CREATE OR ALTER DOES NOT RE-MATERIALISE THE ADDED COLUMNS. After a
      successful alter, __version_hash was NULL on all 77,155 rows and
      __is_current_version was never TRUE - the columns existed in the schema but
      held nothing. These dynamic tables are TARGET_LAG = DOWNSTREAM with no gold
      consumer, so scheduling_state = OFF and nothing recomputed them.

      An explicit ALTER DYNAMIC TABLE ... REFRESH is required, and is part of this
      migration. Without it the new columns are silently empty, which for
      __is_current_version means EVERY aggregate filtering on it returns NULL /
      zero rows. Do not skip it.

   DATA IMPACT: none. All 6 row counts unchanged, revenue identical at
   50,186,627.97 both filtered and unfiltered.
   --------------------------------------------------------------------------- */


/* ===========================================================================
   1 of 6 - sv_product_family_master
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_product_family_master
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver product family master: one row per (family_code, __version_hash). The source provides NO temporal discriminator, so versions are distinguished by a CONTENT HASH - distinct attribute states are preserved but carry no validity interval. Filter __is_current_version for current-state queries. FK to category flagged not rejected.'
 AS
SELECT UPPER(TRIM(b.family_code)) AS family_code, TRIM(b.family_name) AS family_name,
    UPPER(TRIM(b.category_code)) AS category_code, b.launch_year,
    TRIM(b.lifecycle_status) AS lifecycle_status, b.is_active,
    b.created_at AS source_created_at, b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.family_name) IS NULL OR TRIM(b.family_name)='','MISSING_FAMILY_NAME',NULL),
        IFF(b.category_code IS NULL OR TRIM(b.category_code)='','NULL_CATEGORY_CODE',NULL),
        IFF(b.launch_year IS NULL,'NULL_LAUNCH_YEAR',NULL),
        IFF(b.launch_year IS NOT NULL AND (b.launch_year < 1976 OR b.launch_year > 2035),'IMPLAUSIBLE_LAUNCH_YEAR',NULL),
        IFF(TRIM(b.lifecycle_status) IS NULL OR TRIM(b.lifecycle_status)='','NULL_LIFECYCLE_STATUS',NULL),
        IFF(b.is_active IS NULL,'NULL_IS_ACTIVE',NULL),
        IFF(b.source_system IS NULL,'NULL_SOURCE_SYSTEM',NULL)
    )),','),'') AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.family_code)),
      SHA1_HEX(NVL(TRIM(b.family_name),'~')||'|'||NVL(UPPER(TRIM(b.category_code)),'~')
      ||'|'||NVL(TO_VARCHAR(b.launch_year),'~')||'|'||NVL(TRIM(b.lifecycle_status),'~')
      ||'|'||NVL(TO_VARCHAR(b.is_active),'~')||'|'||NVL(b.source_system,'~'))) AS __bronze_row_count,
    b.__file_name, b.__row_number, b.__file_last_modified_ntz,
    SHA1_HEX(NVL(TRIM(b.family_name),'~')||'|'||NVL(UPPER(TRIM(b.category_code)),'~')
      ||'|'||NVL(TO_VARCHAR(b.launch_year),'~')||'|'||NVL(TRIM(b.lifecycle_status),'~')
      ||'|'||NVL(TO_VARCHAR(b.is_active),'~')||'|'||NVL(b.source_system,'~')) AS __version_hash,
    (ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.family_code))
       ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
                b.__file_name DESC, b.__row_number DESC) = 1) AS __is_current_version
FROM {{ database }}.BRONZE.br_product_family_master b
WHERE b.family_code IS NOT NULL AND TRIM(b.family_code) <> ''
QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.family_code)),
      SHA1_HEX(NVL(TRIM(b.family_name),'~')||'|'||NVL(UPPER(TRIM(b.category_code)),'~')
      ||'|'||NVL(TO_VARCHAR(b.launch_year),'~')||'|'||NVL(TRIM(b.lifecycle_status),'~')
      ||'|'||NVL(TO_VARCHAR(b.is_active),'~')||'|'||NVL(b.source_system,'~'))
  ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
           b.__file_name DESC, b.__row_number DESC) = 1;


/* ===========================================================================
   2 of 6 - sv_product_model_master
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_product_model_master
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver product model master: one row per (model_code, __version_hash). The source provides NO temporal discriminator, so versions are distinguished by a CONTENT HASH. Filter __is_current_version for current-state queries. NULL discontinue_date is the open-ended state and is not flagged.'
 AS
SELECT UPPER(TRIM(b.model_code)) AS model_code, TRIM(b.model_name) AS model_name,
    UPPER(TRIM(b.family_code)) AS family_code, b.launch_date, b.discontinue_date,
    TRIM(b.lifecycle_status) AS lifecycle_status, b.is_active,
    b.created_at AS source_created_at, b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.model_name) IS NULL OR TRIM(b.model_name)='','MISSING_MODEL_NAME',NULL),
        IFF(b.family_code IS NULL OR TRIM(b.family_code)='','NULL_FAMILY_CODE',NULL),
        IFF(b.launch_date IS NULL,'NULL_LAUNCH_DATE',NULL),
        IFF(b.launch_date < '1976-04-01'::DATE,'IMPLAUSIBLE_LAUNCH_DATE',NULL),
        IFF(b.discontinue_date IS NOT NULL AND b.discontinue_date < b.launch_date,'INVALID_DATE_RANGE',NULL),
        IFF(TRIM(b.lifecycle_status) IS NULL OR TRIM(b.lifecycle_status)='','NULL_LIFECYCLE_STATUS',NULL),
        IFF(b.is_active IS NULL,'NULL_IS_ACTIVE',NULL),
        IFF(b.source_system IS NULL,'NULL_SOURCE_SYSTEM',NULL)
    )),','),'') AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.model_code)),
      SHA1_HEX(NVL(TRIM(b.model_name),'~')||'|'||NVL(UPPER(TRIM(b.family_code)),'~')
      ||'|'||NVL(TO_VARCHAR(b.launch_date),'~')||'|'||NVL(TO_VARCHAR(b.discontinue_date),'~')
      ||'|'||NVL(TRIM(b.lifecycle_status),'~')||'|'||NVL(TO_VARCHAR(b.is_active),'~')
      ||'|'||NVL(b.source_system,'~'))) AS __bronze_row_count,
    b.__file_name, b.__row_number, b.__file_last_modified_ntz,
    SHA1_HEX(NVL(TRIM(b.model_name),'~')||'|'||NVL(UPPER(TRIM(b.family_code)),'~')
      ||'|'||NVL(TO_VARCHAR(b.launch_date),'~')||'|'||NVL(TO_VARCHAR(b.discontinue_date),'~')
      ||'|'||NVL(TRIM(b.lifecycle_status),'~')||'|'||NVL(TO_VARCHAR(b.is_active),'~')
      ||'|'||NVL(b.source_system,'~')) AS __version_hash,
    (ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.model_code))
       ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
                b.__file_name DESC, b.__row_number DESC) = 1) AS __is_current_version
FROM {{ database }}.BRONZE.br_product_model_master b
WHERE b.model_code IS NOT NULL AND TRIM(b.model_code) <> ''
QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.model_code)),
      SHA1_HEX(NVL(TRIM(b.model_name),'~')||'|'||NVL(UPPER(TRIM(b.family_code)),'~')
      ||'|'||NVL(TO_VARCHAR(b.launch_date),'~')||'|'||NVL(TO_VARCHAR(b.discontinue_date),'~')
      ||'|'||NVL(TRIM(b.lifecycle_status),'~')||'|'||NVL(TO_VARCHAR(b.is_active),'~')
      ||'|'||NVL(b.source_system,'~'))
  ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
           b.__file_name DESC, b.__row_number DESC) = 1;


/* ===========================================================================
   3 of 6 - sv_product_sku_master
   The grain sv_sales_item joins on, so fan-out here reaches the fact.
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_product_sku_master
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver product SKU master: one row per (sku_code, __version_hash). The source provides NO temporal discriminator, so versions are distinguished by a CONTENT HASH. Filter __is_current_version for current-state queries. Leaf of the global product hierarchy and the grain sales items join on. price_tier is a band, not a price.'
 AS
SELECT UPPER(TRIM(b.sku_code)) AS sku_code, UPPER(TRIM(b.model_code)) AS model_code,
    TRIM(b.variant) AS variant, TRIM(b.price_tier) AS price_tier, b.global_launch_date, b.is_active,
    b.created_at AS source_created_at, b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(b.model_code IS NULL OR TRIM(b.model_code)='','NULL_MODEL_CODE',NULL),
        IFF(TRIM(b.variant) IS NULL OR TRIM(b.variant)='','MISSING_VARIANT',NULL),
        IFF(TRIM(b.price_tier) IS NULL OR TRIM(b.price_tier)='','NULL_PRICE_TIER',NULL),
        IFF(b.global_launch_date IS NULL,'NULL_GLOBAL_LAUNCH_DATE',NULL),
        IFF(b.global_launch_date < '1976-04-01'::DATE,'IMPLAUSIBLE_LAUNCH_DATE',NULL),
        IFF(b.is_active IS NULL,'NULL_IS_ACTIVE',NULL),
        IFF(b.source_system IS NULL,'NULL_SOURCE_SYSTEM',NULL)
    )),','),'') AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.sku_code)),
      SHA1_HEX(NVL(UPPER(TRIM(b.model_code)),'~')||'|'||NVL(TRIM(b.variant),'~')
      ||'|'||NVL(TRIM(b.price_tier),'~')||'|'||NVL(TO_VARCHAR(b.global_launch_date),'~')
      ||'|'||NVL(TO_VARCHAR(b.is_active),'~')||'|'||NVL(b.source_system,'~'))) AS __bronze_row_count,
    b.__file_name, b.__row_number, b.__file_last_modified_ntz,
    SHA1_HEX(NVL(UPPER(TRIM(b.model_code)),'~')||'|'||NVL(TRIM(b.variant),'~')
      ||'|'||NVL(TRIM(b.price_tier),'~')||'|'||NVL(TO_VARCHAR(b.global_launch_date),'~')
      ||'|'||NVL(TO_VARCHAR(b.is_active),'~')||'|'||NVL(b.source_system,'~')) AS __version_hash,
    (ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.sku_code))
       ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
                b.__file_name DESC, b.__row_number DESC) = 1) AS __is_current_version
FROM {{ database }}.BRONZE.br_product_sku_master b
WHERE b.sku_code IS NOT NULL AND TRIM(b.sku_code) <> ''
QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.sku_code)),
      SHA1_HEX(NVL(UPPER(TRIM(b.model_code)),'~')||'|'||NVL(TRIM(b.variant),'~')
      ||'|'||NVL(TRIM(b.price_tier),'~')||'|'||NVL(TO_VARCHAR(b.global_launch_date),'~')
      ||'|'||NVL(TO_VARCHAR(b.is_active),'~')||'|'||NVL(b.source_system,'~'))
  ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
           b.__file_name DESC, b.__row_number DESC) = 1;


/* ===========================================================================
   4 of 6 - sv_product_country_availability     composite key (sku, country)
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_product_country_availability
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver product country availability: one row per (sku_code, country_code, __version_hash). The source provides NO temporal discriminator, so versions are distinguished by a CONTENT HASH. Filter __is_current_version for current-state queries. Complete 650x35 cartesian with is_available TRUE everywhere - joining it to restrict to available products removes zero rows. Part numbers are unique per region, not per country - by design.'
 AS
SELECT UPPER(TRIM(b.sku_code)) AS sku_code, UPPER(TRIM(b.country_code)) AS country_code,
    UPPER(TRIM(b.local_part_number)) AS local_part_number,
    b.local_launch_date, b.local_discontinue_date, b.is_available,
    b.created_at AS source_created_at, b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.local_part_number) IS NULL OR TRIM(b.local_part_number)='','MISSING_LOCAL_PART_NUMBER',NULL),
        IFF(b.local_launch_date IS NULL,'NULL_LOCAL_LAUNCH_DATE',NULL),
        IFF(b.local_discontinue_date IS NOT NULL AND b.local_discontinue_date < b.local_launch_date,'INVALID_LOCAL_DATE_RANGE',NULL),
        IFF(b.is_available IS NULL,'NULL_IS_AVAILABLE',NULL),
        IFF(b.source_system IS NULL,'NULL_SOURCE_SYSTEM',NULL)
    )),','),'') AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.sku_code)), UPPER(TRIM(b.country_code)),
      SHA1_HEX(NVL(UPPER(TRIM(b.local_part_number)),'~')||'|'||NVL(TO_VARCHAR(b.local_launch_date),'~')
      ||'|'||NVL(TO_VARCHAR(b.local_discontinue_date),'~')||'|'||NVL(TO_VARCHAR(b.is_available),'~')
      ||'|'||NVL(b.source_system,'~'))) AS __bronze_row_count,
    b.__file_name, b.__row_number, b.__file_last_modified_ntz,
    SHA1_HEX(NVL(UPPER(TRIM(b.local_part_number)),'~')||'|'||NVL(TO_VARCHAR(b.local_launch_date),'~')
      ||'|'||NVL(TO_VARCHAR(b.local_discontinue_date),'~')||'|'||NVL(TO_VARCHAR(b.is_available),'~')
      ||'|'||NVL(b.source_system,'~')) AS __version_hash,
    (ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.sku_code)), UPPER(TRIM(b.country_code))
       ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
                b.__file_name DESC, b.__row_number DESC) = 1) AS __is_current_version
FROM {{ database }}.BRONZE.br_product_country_availability b
WHERE b.sku_code IS NOT NULL AND TRIM(b.sku_code) <> ''
  AND b.country_code IS NOT NULL AND TRIM(b.country_code) <> ''
QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.sku_code)), UPPER(TRIM(b.country_code)),
      SHA1_HEX(NVL(UPPER(TRIM(b.local_part_number)),'~')||'|'||NVL(TO_VARCHAR(b.local_launch_date),'~')
      ||'|'||NVL(TO_VARCHAR(b.local_discontinue_date),'~')||'|'||NVL(TO_VARCHAR(b.is_available),'~')
      ||'|'||NVL(b.source_system,'~'))
  ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
           b.__file_name DESC, b.__row_number DESC) = 1;


/* ===========================================================================
   5 of 6 - sv_sales_header      *** SEE THE REVENUE WARNING IN THE HEADER ***
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_sales_header
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver sales header: one row per (transaction_sk, __version_hash) - a CORRECTED transaction is preserved as a new version rather than silently overwritten. *** REVENUE WARNING: you MUST filter __is_current_version = TRUE before aggregating any measure, or a corrected transaction is counted twice. *** Measures duplicate sv_sales_item 1:1 - never sum both. Amounts are USD-scaled regardless of currency label - cross-currency SUM is invalid.'
 AS
SELECT
    TRIM(b.transaction_sk) AS transaction_sk,
    UPPER(TRIM(b.transaction_id)) AS transaction_id,
    b.transaction_timestamp,
    TRIM(b.customer_id) AS customer_id,
    UPPER(TRIM(b.store_id)) AS store_id,
    UPPER(TRIM(b.channel_id)) AS channel_id,
    UPPER(TRIM(b.country_code)) AS country_code,
    TRIM(b.payment_method) AS payment_method,
    UPPER(TRIM(b.currency)) AS currency,
    b.gross_amount, b.total_discount, b.total_tax, b.net_total,
    b.created_at AS source_created_at, b.source_system,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.transaction_id) IS NULL OR TRIM(b.transaction_id)='','MISSING_TRANSACTION_ID',NULL),
        IFF(TRIM(b.customer_id) IS NULL OR TRIM(b.customer_id)='','NULL_CUSTOMER_ID',NULL),
        IFF(b.country_code IS NULL OR TRIM(b.country_code)='','NULL_COUNTRY_CODE',NULL),
        IFF(b.currency IS NULL OR TRIM(b.currency)='','NULL_CURRENCY',NULL),
        IFF(b.channel_id IS NULL OR TRIM(b.channel_id)='','NULL_CHANNEL_ID',NULL),
        IFF(TRIM(b.payment_method) IS NULL OR TRIM(b.payment_method)='','NULL_PAYMENT_METHOD',NULL),
        IFF(b.transaction_timestamp IS NULL,'NULL_TRANSACTION_TIMESTAMP',NULL),
        IFF(b.transaction_timestamp < '2000-01-01'::TIMESTAMP_NTZ,'IMPLAUSIBLE_TIMESTAMP',NULL),
        IFF(b.gross_amount IS NULL,'NULL_GROSS_AMOUNT',NULL),
        IFF(b.total_discount IS NULL,'NULL_DISCOUNT',NULL),
        IFF(b.total_tax IS NULL,'NULL_TAX',NULL),
        IFF(b.net_total IS NULL,'NULL_NET_TOTAL',NULL),
        IFF(b.gross_amount<0,'NEGATIVE_GROSS',NULL),
        IFF(b.total_discount<0,'NEGATIVE_DISCOUNT',NULL),
        IFF(b.total_tax<0,'NEGATIVE_TAX',NULL),
        IFF(b.net_total<=0,'NONPOSITIVE_NET',NULL),
        IFF(b.total_discount>b.gross_amount,'DISCOUNT_EXCEEDS_GROSS',NULL),
        IFF(ABS(b.net_total-(b.gross_amount-b.total_discount+b.total_tax))>0.005,'NET_TOTAL_FORMULA_BREAK',NULL),
        IFF(UPPER(TRIM(b.channel_id))='ONLINE' AND b.store_id IS NOT NULL,'ONLINE_WITH_STORE',NULL),
        IFF(UPPER(TRIM(b.channel_id))='POS' AND b.store_id IS NULL,'POS_WITHOUT_STORE',NULL),
        IFF(b.source_system IS NULL,'NULL_SOURCE_SYSTEM',NULL)
    )),','),'') AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY TRIM(b.transaction_sk),
      SHA1_HEX(NVL(UPPER(TRIM(b.transaction_id)),'~')||'|'||NVL(TO_VARCHAR(b.transaction_timestamp),'~')
      ||'|'||NVL(TRIM(b.customer_id),'~')||'|'||NVL(UPPER(TRIM(b.store_id)),'~')
      ||'|'||NVL(UPPER(TRIM(b.channel_id)),'~')||'|'||NVL(UPPER(TRIM(b.country_code)),'~')
      ||'|'||NVL(TRIM(b.payment_method),'~')||'|'||NVL(UPPER(TRIM(b.currency)),'~')
      ||'|'||NVL(TO_VARCHAR(b.gross_amount),'~')||'|'||NVL(TO_VARCHAR(b.total_discount),'~')
      ||'|'||NVL(TO_VARCHAR(b.total_tax),'~')||'|'||NVL(TO_VARCHAR(b.net_total),'~')
      ||'|'||NVL(b.source_system,'~'))) AS __bronze_row_count,
    b.__file_name, b.__row_number, b.__file_last_modified_ntz,
    SHA1_HEX(NVL(UPPER(TRIM(b.transaction_id)),'~')||'|'||NVL(TO_VARCHAR(b.transaction_timestamp),'~')
      ||'|'||NVL(TRIM(b.customer_id),'~')||'|'||NVL(UPPER(TRIM(b.store_id)),'~')
      ||'|'||NVL(UPPER(TRIM(b.channel_id)),'~')||'|'||NVL(UPPER(TRIM(b.country_code)),'~')
      ||'|'||NVL(TRIM(b.payment_method),'~')||'|'||NVL(UPPER(TRIM(b.currency)),'~')
      ||'|'||NVL(TO_VARCHAR(b.gross_amount),'~')||'|'||NVL(TO_VARCHAR(b.total_discount),'~')
      ||'|'||NVL(TO_VARCHAR(b.total_tax),'~')||'|'||NVL(TO_VARCHAR(b.net_total),'~')
      ||'|'||NVL(b.source_system,'~')) AS __version_hash,
    (ROW_NUMBER() OVER (PARTITION BY TRIM(b.transaction_sk)
       ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
                b.__file_name DESC, b.__row_number DESC) = 1) AS __is_current_version
FROM {{ database }}.BRONZE.br_sales_header b
WHERE b.transaction_sk IS NOT NULL AND TRIM(b.transaction_sk) <> ''
QUALIFY ROW_NUMBER() OVER (PARTITION BY TRIM(b.transaction_sk),
      SHA1_HEX(NVL(UPPER(TRIM(b.transaction_id)),'~')||'|'||NVL(TO_VARCHAR(b.transaction_timestamp),'~')
      ||'|'||NVL(TRIM(b.customer_id),'~')||'|'||NVL(UPPER(TRIM(b.store_id)),'~')
      ||'|'||NVL(UPPER(TRIM(b.channel_id)),'~')||'|'||NVL(UPPER(TRIM(b.country_code)),'~')
      ||'|'||NVL(TRIM(b.payment_method),'~')||'|'||NVL(UPPER(TRIM(b.currency)),'~')
      ||'|'||NVL(TO_VARCHAR(b.gross_amount),'~')||'|'||NVL(TO_VARCHAR(b.total_discount),'~')
      ||'|'||NVL(TO_VARCHAR(b.total_tax),'~')||'|'||NVL(TO_VARCHAR(b.net_total),'~')
      ||'|'||NVL(b.source_system,'~'))
  ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
           b.__file_name DESC, b.__row_number DESC) = 1;


/* ===========================================================================
   6 of 6 - sv_sales_item        *** SEE THE REVENUE WARNING IN THE HEADER ***
   =========================================================================== */
CREATE OR ALTER {{ object_type }} DYNAMIC TABLE {{ database }}.SILVER.sv_sales_item
 TARGET_LAG = 'DOWNSTREAM' REFRESH_MODE = INCREMENTAL WAREHOUSE = {{ warehouse }}
 COMMENT='Silver sales item: one row per (transaction_line_id, __version_hash) - a CORRECTED line is preserved as a new version rather than silently overwritten. *** REVENUE WARNING: you MUST filter __is_current_version = TRUE before aggregating any measure, or a corrected line is counted twice. *** Exactly 1:1 with sv_sales_header, whose measures duplicate these - never sum both. Amounts are USD-scaled and this table has no currency column.'
 AS
SELECT
    UPPER(TRIM(b.transaction_line_id)) AS transaction_line_id,
    TRIM(b.transaction_sk) AS transaction_sk,
    b.line_number,
    UPPER(TRIM(b.sku_code)) AS sku_code,
    b.quantity, b.unit_price, b.discount_amount, b.tax_amount, b.line_total,
    b.created_at AS source_created_at,
    NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(TRIM(b.transaction_sk) IS NULL OR TRIM(b.transaction_sk)='','NULL_TRANSACTION_SK',NULL),
        IFF(b.line_number IS NULL,'NULL_LINE_NUMBER',NULL),
        IFF(b.line_number IS NOT NULL AND b.line_number<=0,'NONPOSITIVE_LINE_NUMBER',NULL),
        IFF(TRIM(b.sku_code) IS NULL OR TRIM(b.sku_code)='','NULL_SKU_CODE',NULL),
        IFF(b.quantity IS NULL,'NULL_QUANTITY',NULL),
        IFF(b.quantity IS NOT NULL AND b.quantity<=0,'NONPOSITIVE_QUANTITY',NULL),
        IFF(b.unit_price IS NULL,'NULL_UNIT_PRICE',NULL),
        IFF(b.unit_price IS NOT NULL AND b.unit_price<=0,'NONPOSITIVE_UNIT_PRICE',NULL),
        IFF(b.discount_amount IS NULL,'NULL_DISCOUNT',NULL),
        IFF(b.tax_amount IS NULL,'NULL_TAX',NULL),
        IFF(b.line_total IS NULL,'NULL_LINE_TOTAL',NULL),
        IFF(b.discount_amount<0,'NEGATIVE_DISCOUNT',NULL),
        IFF(b.tax_amount<0,'NEGATIVE_TAX',NULL),
        IFF(b.line_total<=0,'NONPOSITIVE_LINE_TOTAL',NULL),
        IFF(b.discount_amount>b.quantity*b.unit_price,'DISCOUNT_EXCEEDS_EXTENDED',NULL),
        IFF(ABS(b.line_total-(b.quantity*b.unit_price-b.discount_amount+b.tax_amount))>0.005,'LINE_TOTAL_FORMULA_BREAK',NULL)
    )),','),'') AS dq_issue_flags,
    COUNT(*) OVER (PARTITION BY UPPER(TRIM(b.transaction_line_id)),
      SHA1_HEX(NVL(TRIM(b.transaction_sk),'~')||'|'||NVL(TO_VARCHAR(b.line_number),'~')
      ||'|'||NVL(UPPER(TRIM(b.sku_code)),'~')||'|'||NVL(TO_VARCHAR(b.quantity),'~')
      ||'|'||NVL(TO_VARCHAR(b.unit_price),'~')||'|'||NVL(TO_VARCHAR(b.discount_amount),'~')
      ||'|'||NVL(TO_VARCHAR(b.tax_amount),'~')||'|'||NVL(TO_VARCHAR(b.line_total),'~'))) AS __bronze_row_count,
    b.__file_name, b.__row_number, b.__file_last_modified_ntz,
    SHA1_HEX(NVL(TRIM(b.transaction_sk),'~')||'|'||NVL(TO_VARCHAR(b.line_number),'~')
      ||'|'||NVL(UPPER(TRIM(b.sku_code)),'~')||'|'||NVL(TO_VARCHAR(b.quantity),'~')
      ||'|'||NVL(TO_VARCHAR(b.unit_price),'~')||'|'||NVL(TO_VARCHAR(b.discount_amount),'~')
      ||'|'||NVL(TO_VARCHAR(b.tax_amount),'~')||'|'||NVL(TO_VARCHAR(b.line_total),'~')) AS __version_hash,
    (ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.transaction_line_id))
       ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
                b.__file_name DESC, b.__row_number DESC) = 1) AS __is_current_version
FROM {{ database }}.BRONZE.br_sales_item b
WHERE b.transaction_line_id IS NOT NULL AND TRIM(b.transaction_line_id) <> ''
QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(b.transaction_line_id)),
      SHA1_HEX(NVL(TRIM(b.transaction_sk),'~')||'|'||NVL(TO_VARCHAR(b.line_number),'~')
      ||'|'||NVL(UPPER(TRIM(b.sku_code)),'~')||'|'||NVL(TO_VARCHAR(b.quantity),'~')
      ||'|'||NVL(TO_VARCHAR(b.unit_price),'~')||'|'||NVL(TO_VARCHAR(b.discount_amount),'~')
      ||'|'||NVL(TO_VARCHAR(b.tax_amount),'~')||'|'||NVL(TO_VARCHAR(b.line_total),'~'))
  ORDER BY b.created_at DESC NULLS LAST, b.__file_last_modified_ntz DESC NULLS LAST,
           b.__file_name DESC, b.__row_number DESC) = 1;


/* ---------------------------------------------------------------------------
   MANDATORY: materialise the new columns.

   CREATE OR ALTER adds the columns to the schema but does NOT recompute them.
   These tables are TARGET_LAG = DOWNSTREAM with no gold consumer, so
   scheduling_state = OFF and nothing would refresh them on its own. Skipping
   this leaves __version_hash NULL and __is_current_version never TRUE, which
   silently breaks every aggregate that filters on the flag.
   --------------------------------------------------------------------------- */

ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_product_family_master        REFRESH;
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_product_model_master         REFRESH;
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_product_sku_master           REFRESH;
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_product_country_availability REFRESH;
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_sales_header                 REFRESH;
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_sales_item                   REFRESH;
ALTER DYNAMIC TABLE {{ database }}.GOLD.dim_country                       REFRESH;


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Row counts unchanged, new columns POPULATED, and exactly one current version
-- per key. The cur = keys = rows_ identity is the invariant to watch.
SELECT 'sv_product_family_master' AS t, COUNT(*) AS rows_, 43 AS expected,
       COUNT_IF(__is_current_version) AS cur, COUNT(DISTINCT family_code) AS keys,
       COUNT_IF(__version_hash IS NULL) AS null_hash
FROM   {{ database }}.SILVER.sv_product_family_master
UNION ALL SELECT 'sv_product_model_master', COUNT(*), 111, COUNT_IF(__is_current_version), COUNT(DISTINCT model_code), COUNT_IF(__version_hash IS NULL) FROM {{ database }}.SILVER.sv_product_model_master
UNION ALL SELECT 'sv_product_sku_master', COUNT(*), 650, COUNT_IF(__is_current_version), COUNT(DISTINCT sku_code), COUNT_IF(__version_hash IS NULL) FROM {{ database }}.SILVER.sv_product_sku_master
UNION ALL SELECT 'sv_product_country_availability', COUNT(*), 22750, COUNT_IF(__is_current_version), COUNT(DISTINCT sku_code||'|'||country_code), COUNT_IF(__version_hash IS NULL) FROM {{ database }}.SILVER.sv_product_country_availability
UNION ALL SELECT 'sv_sales_header', COUNT(*), 77155, COUNT_IF(__is_current_version), COUNT(DISTINCT transaction_sk), COUNT_IF(__version_hash IS NULL) FROM {{ database }}.SILVER.sv_sales_header
UNION ALL SELECT 'sv_sales_item', COUNT(*), 77155, COUNT_IF(__is_current_version), COUNT(DISTINCT transaction_line_id), COUNT_IF(__version_hash IS NULL) FROM {{ database }}.SILVER.sv_sales_item
ORDER BY t;
-- Recorded: every rows_ = expected = cur = keys; null_hash = 0 on all 6.

-- THE REVENUE ASSERTION. Both must equal the figure section 7 records
-- (50,186,627.97). They agree today because every key has one version; the point
-- is that they will DIVERGE once a correction lands, and only the filtered figure
-- will be right.
SELECT ROUND(SUM(line_total),2)                                        AS revenue_all_versions,
       ROUND(SUM(IFF(__is_current_version, line_total, 0)),2)          AS revenue_current_only
FROM   {{ database }}.SILVER.sv_sales_item;
-- Recorded: 50186627.97, 50186627.97

-- Hash shape.
SELECT MIN(LENGTH(__version_hash)) AS hash_len, COUNT(DISTINCT __version_hash) AS distinct_hashes
FROM   {{ database }}.SILVER.sv_sales_item;
-- Recorded: 40, 77155

-- EXACTLY ONE CURRENT VERSION PER KEY - expect ZERO rows from each.
SELECT transaction_sk FROM {{ database }}.SILVER.sv_sales_header
GROUP BY transaction_sk HAVING COUNT_IF(__is_current_version) <> 1;
-- Recorded: 0 rows

SELECT transaction_line_id FROM {{ database }}.SILVER.sv_sales_item
GROUP BY transaction_line_id HAVING COUNT_IF(__is_current_version) <> 1;
-- Recorded: 0 rows

SELECT sku_code FROM {{ database }}.SILVER.sv_product_sku_master
GROUP BY sku_code HAVING COUNT_IF(__is_current_version) <> 1;
-- Recorded: 0 rows

-- Settings survived, all 13 tables.
SHOW DYNAMIC TABLES IN SCHEMA {{ database }}.SILVER;
-- Recorded: 13 of 13 target_lag=DOWNSTREAM, refresh_mode=INCREMENTAL,
--           refresh_mode_reason=NULL

-- EXPECT ONE 'REINITIALIZE' PER ALTERED TABLE, AND DO NOT MISTAKE IT FOR FULL
-- REFRESH. Changing a dynamic table's definition forces a single rebuild because
-- the existing materialisation no longer matches the new query. The statistics
-- read like a full refresh - for sv_sales_item, numDeletedRows 77155 and
-- numInsertedRows 77155 - but refresh_mode is still INCREMENTAL. Distinguishing
-- the two:
--     refresh_mode = FULL          every refresh reprocesses everything, forever
--     refresh_action = REINITIALIZE  one rebuild, then incremental resumes
-- See AGENT.md section 5.
SELECT refresh_start_time, state, refresh_action, refresh_trigger
FROM   TABLE({{ database }}.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
         NAME => '{{ database }}.SILVER.sv_sales_item'))
ORDER  BY refresh_start_time DESC LIMIT 5;
-- Recorded: most recent = REINITIALIZE / MANUAL - this migration, expected

-- PROOF none of them is stuck in full refresh: with no upstream change an
-- INCREMENTAL table does no work. A FULL table would reprocess every row.
ALTER DYNAMIC TABLE {{ database }}.SILVER.sv_sales_item REFRESH;
-- Recorded: "No new data", refreshed_dt_count = 0

-- Gold unaffected, and the fact join still resolves every current row.
SELECT (SELECT COUNT(*) FROM {{ database }}.GOLD.dim_country)               AS dim_rows,
       (SELECT COUNT_IF(is_current) FROM {{ database }}.GOLD.dim_country)   AS dim_current,
       (SELECT COUNT(*) FROM {{ database }}.SILVER.sv_sales_header h
          JOIN {{ database }}.GOLD.dim_country d
            ON d.country_code = h.country_code
           AND h.transaction_timestamp::DATE BETWEEN d.valid_from AND d.valid_to
         WHERE h.__is_current_version)                                     AS sales_joined;
-- Recorded: 35, 35, 77155

-- Downstream DQ green (V8.1.7 made the fact checks version-aware).
SELECT COUNT(*) AS checks, COUNT_IF(passed) AS passed, COUNT_IF(NOT passed) AS failed
FROM   {{ database }}.COMMON.v_dq_checks;
-- Recorded: 31, 31, 0
