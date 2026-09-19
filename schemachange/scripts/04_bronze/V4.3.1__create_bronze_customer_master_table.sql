/* ---------------------------------------------------------------------------
   V4.3.1 - Bronze landing table for the customer-master source group

   Source: @sales_csv_stg/initial-load/customer-master/<year>/<CC>/
             customer_master_<year>_<CC>.csv
   Currently staged: 2019 only, 35 country files, 31,350 rows.

   ONE table for all countries, not one per country. The files are partitioned
   by country purely for transport; the schema is identical across all 35 and
   country_code is carried inside the data, so splitting would fragment every
   downstream join for no gain. Provenance is not lost - __file_name retains
   the year and country folder.

   Column names and types derived with INFER_SCHEMA against COMMON.ff_csv_infer
   run over the whole 2019/ prefix, not a single file, so the type is the union
   across all 35 countries rather than whatever one country happened to contain.
   Source headers are already clean snake_case - no sanitising needed.

   Two deliberate departures from the inferred types:
     - created_at: inferred DATE because the 2019 files are date-only, but
       widened to TIMESTAMP_NTZ. DATE would silently truncate the time part if
       a later year ships one, and updated_at is already a timestamp - the two
       columns describing the same record should not disagree on grain.
     - TEXT columns pinned to explicit VARCHAR sizes so schema drift fails the
       load instead of being absorbed.

   PII: first_name, last_name, full_name, date_of_birth, email, phone_number
   and street_address are personal data, flagged in the column comments. Bronze
   holds them unmasked by design - it is the faithful raw landing. Masking
   policies belong in the GOVERNANCE database (architectural note 3) and are
   applied on exposure, not here. This table should not be granted broadly.

   TRANSIENT in dev/qa via {{ object_type }}; permanent in prod (note 1).
   Idempotent: IF NOT EXISTS (note 5).

   Depends on: V2.1.2 (BRONZE schema), V3.1.1 (file formats).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} TABLE IF NOT EXISTS {{ database }}.BRONZE.br_customer_master (
  customer_id              VARCHAR(50)     COMMENT 'Source customer UUID, primary business key.',
  customer_number          VARCHAR(50)     COMMENT 'Human readable customer account number.',
  first_name               VARCHAR(100)    COMMENT 'Customer given name. PII.',
  last_name                VARCHAR(100)    COMMENT 'Customer family name. PII.',
  full_name                VARCHAR(200)    COMMENT 'Concatenated customer full name. PII.',
  gender                   VARCHAR(20)     COMMENT 'Self-reported gender as supplied by source.',
  date_of_birth            DATE            COMMENT 'Customer date of birth. PII.',
  email                    VARCHAR(255)    COMMENT 'Customer email address. PII.',
  phone_number             VARCHAR(50)     COMMENT 'Customer contact phone number. PII.',
  street_address           VARCHAR(255)    COMMENT 'Street line of the customer address. PII.',
  city                     VARCHAR(100)    COMMENT 'City of the customer address.',
  state_province           VARCHAR(100)    COMMENT 'State or province of the customer address.',
  postal_code              VARCHAR(30)     COMMENT 'Postal or ZIP code of the customer address.',
  country_code             VARCHAR(10)     COMMENT 'ISO alpha-2 country code linking to country master.',
  country_name             VARCHAR(150)    COMMENT 'Country name as denormalised in the source file.',
  region                   VARCHAR(50)     COMMENT 'Region label as denormalised in the source file.',
  preferred_language       VARCHAR(50)     COMMENT 'Language the customer prefers for communication.',
  customer_segment         VARCHAR(50)     COMMENT 'Marketing segment assigned to the customer.',
  loyalty_tier             VARCHAR(50)     COMMENT 'Loyalty programme tier held by the customer.',
  registration_date        DATE            COMMENT 'Date the customer registered with Apple.',
  acquisition_year         NUMBER(4,0)     COMMENT 'Calendar year the customer was acquired.',
  customer_type            VARCHAR(50)     COMMENT 'Customer classification, e.g. individual or business.',
  is_active                BOOLEAN         COMMENT 'Source active flag for the customer record.',
  source_system            VARCHAR(50)     COMMENT 'Name of the originating source system.',
  created_at               TIMESTAMP_NTZ   COMMENT 'Record creation timestamp in the source system.',
  updated_at               TIMESTAMP_NTZ   COMMENT 'Record last update timestamp in the source system.',
  __file_name              VARCHAR(500)    COMMENT 'Audit: staged file the row was loaded from (METADATA$FILENAME).',
  __row_number             NUMBER(18,0)    COMMENT 'Audit: data-row ordinal within the source file, header excluded (METADATA$FILE_ROW_NUMBER).',
  __file_last_modified_ntz TIMESTAMP_NTZ   COMMENT 'Audit: last modified time of the staged file (METADATA$FILE_LAST_MODIFIED).'
)
COMMENT = 'Bronze raw landing of per-country customer master CSVs from initial-load/customer-master. Contains PII.';
