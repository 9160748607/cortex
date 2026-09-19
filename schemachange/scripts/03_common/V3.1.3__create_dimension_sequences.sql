/* ---------------------------------------------------------------------------
   V3.1.3 - Surrogate key sequences for gold dimensions

   Architectural note 2: sequence objects belong in the COMMON schema.

   One sequence per gold dimension, matching the source-file groups in the
   architecture diagram:
     customer   <- Customer Master
     store      <- Store Master
     product    <- Product Category / Family / Model / SKU / Country Availability
     geography  <- Region / Country
     currency   <- Currency
     tax        <- Tax

   Caveat worth knowing before these are wired into gold: the gold dimensions
   are DYNAMIC tables, and a dynamic table's definition must be deterministic -
   calling a sequence inside one is not supported, because a full refresh would
   mint different keys than an incremental one. These sequences are therefore
   intended for any non-dynamic dimension handling added later (for example a
   stored-procedure-maintained SCD2 table). Gold dynamic dimensions should use
   a deterministic surrogate instead, such as HASH() over the natural key.

   Idempotent: IF NOT EXISTS (architectural note 5). Never CREATE OR REPLACE -
   that resets the counter and would collide with keys already issued.
   --------------------------------------------------------------------------- */

CREATE SEQUENCE IF NOT EXISTS {{ database }}.COMMON.seq_dim_customer
  START = 1 INCREMENT = 1
  COMMENT = 'Surrogate key for gold dim_customer.';

CREATE SEQUENCE IF NOT EXISTS {{ database }}.COMMON.seq_dim_store
  START = 1 INCREMENT = 1
  COMMENT = 'Surrogate key for gold dim_store.';

CREATE SEQUENCE IF NOT EXISTS {{ database }}.COMMON.seq_dim_product
  START = 1 INCREMENT = 1
  COMMENT = 'Surrogate key for gold dim_product.';

CREATE SEQUENCE IF NOT EXISTS {{ database }}.COMMON.seq_dim_geography
  START = 1 INCREMENT = 1
  COMMENT = 'Surrogate key for gold dim_geography (region/country).';

CREATE SEQUENCE IF NOT EXISTS {{ database }}.COMMON.seq_dim_currency
  START = 1 INCREMENT = 1
  COMMENT = 'Surrogate key for gold dim_currency.';

CREATE SEQUENCE IF NOT EXISTS {{ database }}.COMMON.seq_dim_tax
  START = 1 INCREMENT = 1
  COMMENT = 'Surrogate key for gold dim_tax.';
