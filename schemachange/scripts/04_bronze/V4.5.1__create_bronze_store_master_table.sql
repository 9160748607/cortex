/* ---------------------------------------------------------------------------
   V4.5.1 - Bronze landing table for the store-master source group

   Source: @sales_csv_stg/initial-load/store-master/store_master.csv
   121 rows, 22 source columns, one row per retail store.

   Types derived with INFER_SCHEMA against COMMON.ff_csv_infer. Source headers
   are already clean snake_case - no sanitising needed.

   Inferred numerics widened deliberately. INFER_SCHEMA sizes to the observed
   sample, which here is only 121 rows and would reject plausible future values:
     floor_area_sqft  NUMBER(5,0) -> NUMBER(10,0)
       observed 5,205-24,570 sqft. NUMBER(5,0) caps at 99,999 - a single large
       flagship would fail the load.
     annual_rent_usd  NUMBER(8,0) -> NUMBER(14,2)
       observed 660,419-19,405,046. NUMBER(8,0) caps at 99,999,999, and scale 0
       would silently round any cents that appear later.
     latitude         NUMBER(8,6) -> NUMBER(9,6)
     longitude        NUMBER(9,6) -> NUMBER(10,6)
       observed lat -32.68..60.99, lon -126.18..143.79. The inferred precision
       left no headroom: NUMBER(9,6) allows exactly 3 integer digits, so a
       longitude of -180.000000 would not fit. One extra digit each.

   store_close_date: inferred TEXT, overridden to DATE. As with the product
   discontinue columns, INFER_SCHEMA had nothing to type - the column is 100%
   NULL in the staged file (0 of 121 non-null) - rather than evidence it holds
   strings. It is named as a date and pairs with a populated store_open_date.

   NOTE on tax_jurisdiction_code: this does NOT join to BRONZE.br_tax_master.
   tax_code. The two use different vocabularies at different grains - store
   codes are sub-national and omit the tax-type token (AU_ACT_STD, AE_STD)
   while tax master is country-level and includes it (AU_GST_STD, AE_VAT_STD).
   70 distinct store codes vs 35 in tax master. The country prefix IS
   consistent (0 rows fail a prefix match), so this is a grain difference to
   resolve with a mapping in silver, not a defect to fix in bronze. Bronze
   lands the source value as-is.

   TRANSIENT in dev/qa via {{ object_type }}; permanent in prod (note 1).
   Idempotent: IF NOT EXISTS (note 5).

   Depends on: V2.1.2 (BRONZE schema), V3.1.1 (file formats).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_store_master (
  store_code               VARCHAR(30)     COMMENT 'Source store code, primary business key.',
  store_name               VARCHAR(150)    COMMENT 'Retail store name, e.g. Apple Fifth Avenue.',
  country_code             VARCHAR(10)     COMMENT 'ISO alpha-2 country code linking to country master.',
  region_code              VARCHAR(20)     COMMENT 'Region code linking to region master.',
  tax_jurisdiction_code    VARCHAR(20)     COMMENT 'Sub-national tax jurisdiction code; finer grain than tax master, needs mapping in silver.',
  format_code              VARCHAR(20)     COMMENT 'Store format classification, e.g. flagship or standard.',
  city                     VARCHAR(100)    COMMENT 'City the store is located in.',
  state_code               VARCHAR(20)     COMMENT 'State or province code of the store location.',
  postal_code              VARCHAR(30)     COMMENT 'Postal or ZIP code of the store address.',
  address_line1            VARCHAR(255)    COMMENT 'Street address line of the store.',
  latitude                 NUMBER(9,6)     COMMENT 'Store latitude in decimal degrees.',
  longitude                NUMBER(10,6)    COMMENT 'Store longitude in decimal degrees.',
  store_open_date          DATE            COMMENT 'Date the store opened for trading.',
  store_close_date         DATE            COMMENT 'Date the store closed; NULL while still trading.',
  lifecycle_status         VARCHAR(30)     COMMENT 'Lifecycle state of the store, e.g. OPEN/CLOSED.',
  floor_area_sqft          NUMBER(10,0)    COMMENT 'Retail floor area of the store in square feet.',
  annual_rent_usd          NUMBER(14,2)    COMMENT 'Annual rent for the store in USD.',
  is_active                BOOLEAN         COMMENT 'Source active flag for the store record.',
  effective_start_date     DATE            COMMENT 'Date the store record became effective.',
  effective_end_date       DATE            COMMENT 'Date the store record stopped being effective.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of retail store master CSV from initial-load/store-master.';
