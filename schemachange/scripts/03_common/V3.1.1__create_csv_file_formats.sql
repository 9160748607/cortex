/* ---------------------------------------------------------------------------
   V3.1.1 - CSV file formats

   Architectural note 2: common objects like file formats belong in the COMMON
   schema of the respective context.

   TWO formats are required, not one, because PARSE_HEADER and SKIP_HEADER are
   mutually exclusive in Snowflake:
     ff_csv_infer - PARSE_HEADER = TRUE, used by INFER_SCHEMA to derive bronze
                    table structure from the header row (data-flow rule 2).
     ff_csv_load  - SKIP_HEADER = 1, used by COPY INTO so the header row is not
                    ingested as data.

   ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE on the load format only: bronze must
   accept source files as-is rather than reject a whole file, and the row is
   still traceable via the __file_name / __row_number metadata columns.

   Idempotent: IF NOT EXISTS (architectural note 5). Changing an option later
   needs a new versioned script with ALTER FILE FORMAT - editing this file
   would change its checksum but schemachange will not re-run an already
   applied versioned script.
   --------------------------------------------------------------------------- */

CREATE FILE FORMAT IF NOT EXISTS {{ database }}.COMMON.ff_csv_infer
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE
  NULL_IF = ('', 'NULL', 'null', 'N/A')
  EMPTY_FIELD_AS_NULL = TRUE
  COMPRESSION = AUTO
  COMMENT = 'CSV format for INFER_SCHEMA - reads header row as column names.';

CREATE FILE FORMAT IF NOT EXISTS {{ database }}.COMMON.ff_csv_load
  TYPE = CSV
  SKIP_HEADER = 1
  FIELD_DELIMITER = ','
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  TRIM_SPACE = TRUE
  NULL_IF = ('', 'NULL', 'null', 'N/A')
  EMPTY_FIELD_AS_NULL = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  COMPRESSION = AUTO
  COMMENT = 'CSV format for COPY INTO bronze - skips header row.';
