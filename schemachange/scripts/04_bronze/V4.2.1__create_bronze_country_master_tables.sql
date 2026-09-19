/* ---------------------------------------------------------------------------
   V4.2.1 - Bronze landing tables for the country-master source group

   Covers the 4 CSVs under @sales_csv_stg/initial-load/country-master/:
     region_master.csv, country_master.csv, currency_master.csv, tax_master.csv

   Column names and types were derived with INFER_SCHEMA against
   COMMON.ff_csv_infer (PARSE_HEADER = TRUE), then hand-tightened:

     - Source headers are already clean snake_case, so no space/special-char
       sanitising was needed. Any future source with dirty headers must be
       cleaned here rather than in silver - bronze owns the physical contract.
     - INFER_SCHEMA sizes numerics to the sample it sees. Widened deliberately
       so later files with decimals or larger values do not fail the COPY:
         population_millions  NUMBER(4,0)  -> NUMBER(10,2)
         gdp_usd_billions     NUMBER(5,0)  -> NUMBER(14,2)
         minor_unit           NUMBER(1,0)  -> NUMBER(2,0)
         tax_rate             NUMBER(4,3)  -> NUMBER(7,4)
     - TEXT left unbounded by INFER_SCHEMA is pinned to explicit VARCHAR sizes
       so schema drift surfaces as a load error instead of silent acceptance.

   Audit columns (double-underscore prefix marks them as platform-added, not
   source-supplied) are populated from stage metadata by V4.2.2's COPY INTO:
     __file_name               METADATA$FILENAME
     __row_number              METADATA$FILE_ROW_NUMBER
     __file_last_modified_ntz  METADATA$FILE_LAST_MODIFIED

   Note on __row_number: with SKIP_HEADER = 1 this is the data-row ordinal,
   not the physical file line - the header does not consume ordinal 1.

   TRANSIENT in dev/qa via {{ object_type }}; permanent in prod (note 1).
   Idempotent: IF NOT EXISTS (note 5). Never CREATE OR REPLACE - that would
   discard loaded rows and reset COPY load history.

   Depends on: V2.1.2 (BRONZE schema), V3.1.1 (file formats).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_region_master (
  region_code              VARCHAR(20)     COMMENT 'Source region code, e.g. AMER/EMEA/APAC.',
  region_name              VARCHAR(100)    COMMENT 'Human readable region name.',
  is_active                BOOLEAN         COMMENT 'Source active flag for the region record.',
  effective_start_date     DATE            COMMENT 'Date the region record became effective.',
  effective_end_date       DATE            COMMENT 'Date the region record stopped being effective.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of region master CSV from initial-load/country-master.';

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_currency_master (
  currency_code            VARCHAR(10)     COMMENT 'ISO 4217 currency code.',
  currency_name            VARCHAR(100)    COMMENT 'Full currency name.',
  currency_symbol          VARCHAR(10)     COMMENT 'Display symbol for the currency.',
  minor_unit               NUMBER(2,0)     COMMENT 'Number of decimal digits used by the currency.',
  is_active                BOOLEAN         COMMENT 'Source active flag for the currency record.',
  effective_start_date     DATE            COMMENT 'Date the currency record became effective.',
  effective_end_date       DATE            COMMENT 'Date the currency record stopped being effective.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of currency master CSV from initial-load/country-master.';

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_tax_master (
  tax_code                 VARCHAR(20)     COMMENT 'Source tax code referenced by country master.',
  tax_type                 VARCHAR(50)     COMMENT 'Type of tax, e.g. VAT/GST/SALES_TAX.',
  tax_rate                 NUMBER(7,4)     COMMENT 'Tax rate expressed as a decimal fraction.',
  tax_inclusive_flag       BOOLEAN         COMMENT 'True when listed prices already include this tax.',
  effective_start_date     DATE            COMMENT 'Date the tax rate became effective.',
  effective_end_date       DATE            COMMENT 'Date the tax rate stopped being effective.',
  is_active                BOOLEAN         COMMENT 'Source active flag for the tax record.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of tax master CSV from initial-load/country-master.';

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_country_master (
  country_code             VARCHAR(10)     COMMENT 'ISO alpha-2 country code, primary business key.',
  country_name             VARCHAR(150)    COMMENT 'Full country name.',
  iso_alpha3               VARCHAR(10)     COMMENT 'ISO alpha-3 country code.',
  region_code              VARCHAR(20)     COMMENT 'Region code linking to region master.',
  apple_fiscal_segment     VARCHAR(50)     COMMENT 'Apple reporting segment the country rolls up to.',
  currency_code            VARCHAR(10)     COMMENT 'Local currency code linking to currency master.',
  tax_code                 VARCHAR(20)     COMMENT 'Tax code linking to tax master.',
  primary_language         VARCHAR(50)     COMMENT 'Primary language used in the country.',
  timezone                 VARCHAR(100)    COMMENT 'Representative IANA timezone for the country.',
  ecommerce_supported      BOOLEAN         COMMENT 'True when the Apple online store operates in the country.',
  retail_store_supported   BOOLEAN         COMMENT 'True when physical Apple retail stores exist in the country.',
  market_tier              VARCHAR(20)     COMMENT 'Internal market tier classification.',
  population_millions      NUMBER(10,2)    COMMENT 'Country population in millions.',
  gdp_usd_billions         NUMBER(14,2)    COMMENT 'Country GDP in billions of USD.',
  gdpr_applicable          BOOLEAN         COMMENT 'True when GDPR data protection rules apply.',
  is_active                BOOLEAN         COMMENT 'Source active flag for the country record.',
  effective_start_date     DATE            COMMENT 'Date the country record became effective.',
  effective_end_date       DATE            COMMENT 'Date the country record stopped being effective.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of country master CSV from initial-load/country-master.';
