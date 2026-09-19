/* ---------------------------------------------------------------------------
   V4.4.1 - Bronze landing tables for the product-master source group

   Covers the 5 CSVs under @sales_csv_stg/initial-load/product-master/:
     product_category_master.csv        10 rows
     product_family_master.csv          43 rows
     product_model_master.csv          111 rows
     product_sku_master.csv            650 rows
     product_country_availability.csv  22,750 rows

   These are 5 separate tables, unlike customer-master which collapsed into
   one. The difference is real: customer files were 35 slices of ONE entity at
   one grain, whereas these are four distinct levels of a product hierarchy
   (category -> family -> model -> SKU) plus a SKU-by-country bridge. Each has
   its own key and its own grain, so merging them would be a modelling error.

   Types derived with INFER_SCHEMA against COMMON.ff_csv_infer. Source headers
   are already clean snake_case - no sanitising needed.

   IMPORTANT - two columns overridden from the inferred type:
     product_model_master.discontinue_date            inferred TEXT -> DATE
     product_country_availability.local_discontinue_date  inferred TEXT -> DATE

   INFER_SCHEMA did not decide these were strings; it had nothing to work with.
   Both columns are 100% NULL in the staged files (verified: 0 of 111 and 0 of
   22,750 non-null), so type detection fell back to TEXT. Both are semantically
   dates - named as dates, and each sits beside a populated DATE sibling
   (launch_date / local_launch_date). Accepting TEXT would push a
   pointless string-to-date cast into silver forever and lose the ability to
   range-filter in bronze. Typed as DATE here deliberately.

   TRANSIENT in dev/qa via {{ object_type }}; permanent in prod (note 1).
   Idempotent: IF NOT EXISTS (note 5).

   Depends on: V2.1.2 (BRONZE schema), V3.1.1 (file formats).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_product_category_master (
  category_code            VARCHAR(20)     COMMENT 'Source product category code, primary business key.',
  category_name            VARCHAR(100)    COMMENT 'Human readable category name, e.g. iPhone/Mac/Wearables.',
  reporting_segment        VARCHAR(50)     COMMENT 'Apple financial reporting segment the category rolls up to.',
  is_active                BOOLEAN         COMMENT 'Source active flag for the category record.',
  effective_start_date     DATE            COMMENT 'Date the category record became effective.',
  effective_end_date       DATE            COMMENT 'Date the category record stopped being effective.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of product category master CSV from initial-load/product-master.';

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_product_family_master (
  family_code              VARCHAR(20)     COMMENT 'Source product family code, primary business key.',
  family_name              VARCHAR(100)    COMMENT 'Human readable family name, e.g. iPhone Pro.',
  category_code            VARCHAR(20)     COMMENT 'Category code linking to product category master.',
  launch_year              NUMBER(4,0)     COMMENT 'Calendar year the family was first launched.',
  is_active                BOOLEAN         COMMENT 'Source active flag for the family record.',
  lifecycle_status         VARCHAR(30)     COMMENT 'Lifecycle state of the family, e.g. ACTIVE/DISCONTINUED.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of product family master CSV from initial-load/product-master.';

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_product_model_master (
  model_code               VARCHAR(30)     COMMENT 'Source product model code, primary business key.',
  model_name               VARCHAR(150)    COMMENT 'Human readable model name, e.g. iPhone 15 Pro Max.',
  family_code              VARCHAR(20)     COMMENT 'Family code linking to product family master.',
  launch_date              DATE            COMMENT 'Date the model was launched.',
  discontinue_date         DATE            COMMENT 'Date the model was discontinued; NULL while still sold.',
  lifecycle_status         VARCHAR(30)     COMMENT 'Lifecycle state of the model, e.g. ACTIVE/DISCONTINUED.',
  is_active                BOOLEAN         COMMENT 'Source active flag for the model record.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of product model master CSV from initial-load/product-master.';

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_product_sku_master (
  sku_code                 VARCHAR(40)     COMMENT 'Source SKU code, primary business key.',
  model_code               VARCHAR(30)     COMMENT 'Model code linking to product model master.',
  variant                  VARCHAR(100)    COMMENT 'Variant descriptor such as storage size or colour.',
  price_tier               VARCHAR(30)     COMMENT 'Internal price tier classification for the SKU.',
  global_launch_date       DATE            COMMENT 'Date the SKU became available globally.',
  is_active                BOOLEAN         COMMENT 'Source active flag for the SKU record.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of product SKU master CSV from initial-load/product-master.';

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_product_country_availability (
  sku_code                 VARCHAR(40)     COMMENT 'SKU code linking to product SKU master.',
  country_code             VARCHAR(10)     COMMENT 'ISO alpha-2 country code linking to country master.',
  local_part_number        VARCHAR(50)     COMMENT 'Country specific part number used for the SKU.',
  local_launch_date        DATE            COMMENT 'Date the SKU launched in this country.',
  local_discontinue_date   DATE            COMMENT 'Date the SKU was discontinued in this country; NULL while still sold.',
  is_available             BOOLEAN         COMMENT 'True when the SKU is currently sellable in this country.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of SKU-by-country availability CSV from initial-load/product-master.';
