# 04_bronze — raw landing zone

**Status: scaffold.** No DDL yet — the source CSV column definitions in
`__initial_load` have not been read, so table structures cannot be authored.

This folder is intentionally empty of `.sql` files. schemachange only picks up
files prefixed `V`, `R` or `A` with a `.sql`/`.sql.jinja` suffix, so this
README is ignored by `schemachange deploy` and the project deploys cleanly as-is.

## Rules this folder must implement

From the architectural data-flow rules:

- Tables populated with **`COPY INTO`**, structure derived using
  **`INFER_SCHEMA`** against `COMMON.ff_csv_infer`.
- Every bronze table carries **3 metadata columns** sourced from stage metadata:

  | Column | Source |
  |---|---|
  | `__file_name` | `METADATA$FILENAME` |
  | `__row_number` | `METADATA$FILE_ROW_NUMBER` |
  | `__load_timestamp` | `METADATA$START_SCAN_TIME` (or `CURRENT_TIMESTAMP()`) |

- Data lands **as-is** — no cleansing, casting or deduplication here. That is
  silver's job.
- Tables inherit `TRANSIENT` from the schema in dev/qa (note 1) and inherit all
  four tags from database + schema (note 6), so no per-table tagging is needed.
- `CREATE TABLE IF NOT EXISTS` only (note 5).

## Planned scripts

Reserved version range **V4.x**:

```
V4.1.1__create_bronze_reference_tables.sql    # region, country, currency, tax
V4.1.2__create_bronze_product_tables.sql      # category, family, model, sku, country availability
V4.1.3__create_bronze_master_tables.sql       # store master, customer master
V4.1.4__create_bronze_sales_tables.sql        # sales header, sales item
V4.2.1__initial_copy_into_bronze.sql          # first full load from stage
```

## Unblocking

Grant read access to the `__initial_load` folder
(`...\cortex-code-cli-masterclass-v1.0\__initial_load`) — a previous attempt to
list it was denied. With the 12 CSV headers available, these scripts plus
`05_silver` and `06_gold` can be written.
