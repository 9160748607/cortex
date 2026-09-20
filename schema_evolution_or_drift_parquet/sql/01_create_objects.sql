/* ===========================================================================
   01 - Foundation objects: schema, Parquet file format, stage
   ---------------------------------------------------------------------------
   Target: ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER

   A THIRD schema, separate from DATA_MIGRATION (CSV) and DATA_MIGRATION_JSON.
   All three hold a table called STORE_MASTER, so they cannot share a schema.

   NAMING NOTE: the request specified 'DATA_MIGRATION_parquit'. Corrected to
   DATA_MIGRATION_PARQUET - a misspelled schema name is a long-lived artefact
   and renaming one later means reworking every grant, view and pipeline that
   references it.

   PARQUET NEEDS THE FEWEST FORMAT OPTIONS OF ALL THREE FORMATS. The schema is
   embedded in the file, typed and ordered, so there is nothing to describe:

     option                            CSV        JSON       PARQUET
     -------------------------------------------------------------------
     PARSE_HEADER                      required   n/a        n/a
     ERROR_ON_COLUMN_COUNT_MISMATCH    required   n/a        n/a
     FIELD_DELIMITER / ENCLOSED_BY     required   n/a        n/a
     STRIP_OUTER_ARRAY                 n/a        required   n/a
     per-file DATE_FORMAT              required   not needed not needed
     NULL_IF for bad literals          -          required   not needed

   USE_VECTORIZED_SCANNER = TRUE
     Recommended for Parquet and relevant here beyond performance: it affects
     how Parquet logical type annotations are surfaced on read. With it enabled,
     an int64 column annotated as a timestamp reads back as TIMESTAMP_NTZ rather
     than as a raw integer. See 02_schema_detection.sql section 2.3 - that
     behaviour is what exposed the INFER_SCHEMA disagreement.
   =========================================================================== */

CREATE SCHEMA IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_PARQUET
  COMMENT = 'Store master Parquet schema-drift and schema-evolution demonstration.';

-- ---------------------------------------------------------------------------
-- Parquet file format. ONE format serves both files - unlike the CSV exercise,
-- which needed two because the files disagreed on date convention.
-- ---------------------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_PARQUET.ff_store_master_parquet
  TYPE = PARQUET
  COMPRESSION = AUTO
  USE_VECTORIZED_SCANNER = TRUE
  COMMENT = 'Parquet format for store master files. Parquet embeds its own typed schema, so no header, delimiter or array-stripping options are needed.';

-- ---------------------------------------------------------------------------
-- Stage. IF NOT EXISTS, never CREATE OR REPLACE - that silently discards every
-- staged file.
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Internal stage holding store master Parquet source files for the schema-drift demonstration.';

SHOW FILE FORMATS IN SCHEMA ANALYSIS_DB.DATA_MIGRATION_PARQUET;
SHOW STAGES IN SCHEMA ANALYSIS_DB.DATA_MIGRATION_PARQUET;
LIST @ANALYSIS_DB.DATA_MIGRATION_PARQUET.store_master_parquet_stg/store-master/;

/* NOTE on upload: `snow stage copy` reports source_compression = PARQUET for
   these files - the CLI recognises the container and does not re-compress.
   Do NOT pass --auto-compress for Parquet; gzipping an already-compressed
   columnar file wastes cycles and defeats predicate pushdown on read.        */
