/* ---------------------------------------------------------------------------
   V4.6.1 - Bronze landing tables for the sales-transaction source group

   Source: @sales_csv_stg/initial-load/sales-transaction/<year>/
             sales_header_<year>.csv   77,131 rows, 15 columns
             sales_item_<year>.csv     77,131 rows, 11 columns
   Currently staged: 2019 only.

   These are the fact-grain tables. Two tables, mirroring the source split at
   its two grains: one row per transaction (header) and one row per transaction
   line (item). They are NOT merged here even though this dataset happens to be
   1:1 (see the note below) - bronze mirrors the source contract, and the item
   file is the grain that will fan out as soon as multi-line orders appear.

   Types derived with INFER_SCHEMA against COMMON.ff_csv_infer. Source headers
   are already clean snake_case - no sanitising needed.

   IMPORTANT - inferred numeric precision was far too tight to accept. These
   are monetary and count columns on a fact table, and INFER_SCHEMA sized them
   to the 2019 sample only. Widened deliberately:

     line_number   NUMBER(1,0) -> NUMBER(9,0)
     quantity      NUMBER(1,0) -> NUMBER(9,0)
       Both capped at 9. Observed max line_number 1 and quantity 2, so the
       inferred type fits today - but a 10-line order or a 10-unit corporate
       purchase would fail the load outright. A single-digit cap on a fact
       table is a latent outage, not a tight fit.

     gross_amount / total_tax / net_total / unit_price / tax_amount /
     line_total   NUMBER(6,2) -> NUMBER(18,2)
     total_discount / discount_amount  NUMBER(5,2) -> NUMBER(18,2)
       NUMBER(6,2) caps at 9,999.99. Observed max net_total is already 6,039.93
       - roughly 60% of the ceiling on one year of data. A high-value order
       (several Mac Pros, or any transaction in a currency like JPY or KRW
       where nominal amounts are 100-1000x larger) would breach it. Note
       amounts are in TRANSACTION currency, not USD, so the ceiling has to hold
       for the weakest currency in the set, not the strongest.

   Scale is kept at 2 throughout: all observed values are exact to 2 decimals
   and these are transactional money amounts, not derived rates.

   NOTE - header:item is exactly 1:1 in this dataset, not 1:many. 77,131 rows
   each, 77,131 distinct transaction_sk on both sides, max line_number = 1,
   zero orphans in either direction. Any "average basket size" or "lines per
   order" metric will therefore be identically 1, and item-level aggregation
   will equal header-level aggregation. That is a property of the generated
   data, not of the model - do not build silver logic that assumes it.

   NOTE - store_id is NULL for 15,351 rows (19.9%). This is not missing data:
   it is NULL exactly and only when channel_id = 'ONLINE' (0 exceptions).
   Silver should treat store as an optional dimension keyed on channel, and any
   inner join to store master will silently drop a fifth of all revenue.

   NOTE - the 2019 file contains 24 rows timestamped 2020-01-01 (00:09 to
   02:55). Almost certainly timezone spillover at the year boundary rather than
   bad data. It means the file name's year is NOT a safe partition predicate -
   silver must derive the period from transaction_timestamp, and the 2020 load
   must not assume it owns every 2020 row.

   Verified: gross_amount - total_discount + total_tax = net_total on all
   77,131 header rows, and unit_price*quantity - discount_amount + tax_amount
   = line_total on all 77,131 item rows, to within 0.01.

   sales_item has no source_system column; header does. Left as-is - bronze
   does not invent columns the source omits.

   TRANSIENT in dev/qa via {{ object_type }}; permanent in prod (note 1).
   Idempotent: IF NOT EXISTS (note 5).

   Depends on: V2.1.2 (BRONZE schema), V3.1.1 (file formats).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_sales_header (
  transaction_sk           VARCHAR(50)     COMMENT 'Source surrogate key for the transaction, primary business key.',
  transaction_id           VARCHAR(50)     COMMENT 'Human readable transaction or receipt number.',
  transaction_timestamp    TIMESTAMP_NTZ   COMMENT 'Date and time the transaction was completed; authoritative period source, not the file year.',
  customer_id              VARCHAR(50)     COMMENT 'Customer UUID linking to customer master.',
  store_id                 VARCHAR(30)     COMMENT 'Store code linking to store master; NULL exactly when channel is ONLINE.',
  channel_id               VARCHAR(30)     COMMENT 'Sales channel identifier, e.g. RETAIL or ONLINE.',
  country_code             VARCHAR(10)     COMMENT 'ISO alpha-2 country code linking to country master.',
  payment_method           VARCHAR(50)     COMMENT 'Payment method used for the transaction.',
  currency                 VARCHAR(10)     COMMENT 'Transaction currency code linking to currency master.',
  gross_amount             NUMBER(18,2)    COMMENT 'Transaction total before discount and tax, in transaction currency.',
  total_discount           NUMBER(18,2)    COMMENT 'Total discount applied across all lines, in transaction currency.',
  total_tax                NUMBER(18,2)    COMMENT 'Total tax charged across all lines, in transaction currency.',
  net_total                NUMBER(18,2)    COMMENT 'Amount payable after discount and tax, in transaction currency.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of sales transaction header CSV from initial-load/sales-transaction. One row per transaction.';

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_sales_item (
  transaction_line_id      VARCHAR(50)     COMMENT 'Source line identifier, primary business key.',
  transaction_sk           VARCHAR(50)     COMMENT 'Transaction surrogate key linking to sales header.',
  line_number              NUMBER(9,0)     COMMENT 'Line sequence number within the transaction.',
  sku_code                 VARCHAR(40)     COMMENT 'SKU code linking to product SKU master.',
  category_code            VARCHAR(20)     COMMENT 'Category code linking to product category master.',
  quantity                 NUMBER(9,0)     COMMENT 'Units sold on this line.',
  unit_price               NUMBER(18,2)    COMMENT 'Price per unit before discount and tax, in transaction currency.',
  discount_amount          NUMBER(18,2)    COMMENT 'Discount applied to this line, in transaction currency.',
  tax_amount               NUMBER(18,2)    COMMENT 'Tax charged on this line, in transaction currency.',
  line_total               NUMBER(18,2)    COMMENT 'Line amount after discount and tax, in transaction currency.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of sales transaction line CSV from initial-load/sales-transaction. One row per transaction line.';
