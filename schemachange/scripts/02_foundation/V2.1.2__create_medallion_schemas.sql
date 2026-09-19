/* ---------------------------------------------------------------------------
   V2.1.2 - Medallion schemas

   The four schemas from the architecture diagram:
     BRONZE  (A) raw CSV landing, as-is
     SILVER  (B) cleaned and curated, built by incremental dynamic tables
     GOLD    (C) fact/dimension tables, aggregates, semantic view
     COMMON  (D) file formats, stages, sequences, UDFs, procedures

   All four inherit {{ '{{ object_type }}' }}, so they are TRANSIENT in dev/qa
   and permanent in prod (architectural note 1). Tables created inside a
   transient schema are transient automatically, which is what makes the whole
   dev/qa tree fail-safe free.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} SCHEMA IF NOT EXISTS {{ database }}.BRONZE
  DATA_RETENTION_TIME_IN_DAYS = {{ retention_days }}
  COMMENT = 'Bronze zone - raw CSV data landing as-is from source files.';

CREATE {{ object_type }} SCHEMA IF NOT EXISTS {{ database }}.SILVER
  DATA_RETENTION_TIME_IN_DAYS = {{ retention_days }}
  COMMENT = 'Silver zone - cleaned and curated data via incremental dynamic tables.';

CREATE {{ object_type }} SCHEMA IF NOT EXISTS {{ database }}.GOLD
  DATA_RETENTION_TIME_IN_DAYS = {{ retention_days }}
  COMMENT = 'Gold zone - modelled fact and dimension tables, aggregates, semantic view.';

CREATE {{ object_type }} SCHEMA IF NOT EXISTS {{ database }}.COMMON
  DATA_RETENTION_TIME_IN_DAYS = {{ retention_days }}
  COMMENT = 'Common utilities - file formats, stages, sequences, UDFs and procedures.';
