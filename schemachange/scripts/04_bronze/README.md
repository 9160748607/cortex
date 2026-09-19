# 04_bronze — raw landing zone

**Status: partially complete.**

- `V4.1.1__create_sales_csv_stage.sql` — **done**, the internal landing stage
  (`sales_csv_stg`, SSE-encrypted, directory enabled).
- `_reference__stage_upload_commands.sql` — **reference only, never executed.**
  The `snow stage copy` commands that staged the initial load, plus the Windows
  PowerShell gotchas hit along the way. Underscore prefix keeps schemachange
  from picking it up.
- **47 source files are staged** (12.27 MB compressed) — see the table below.
- Bronze **tables** are not written yet, but are now unblocked: with files in the
  stage, `INFER_SCHEMA` can derive their structures.

## Staged data

| Folder | Files |
|---|---|
| `initial-load/country-master/` | 4 |
| `initial-load/product-master/` | 5 |
| `initial-load/store-master/` | 1 |
| `initial-load/customer-master/2019/<CC>/` | 35 |
| `initial-load/sales-transaction/2019/` | 2 |

Only **2019** was staged for customer and sales; 2020–2025 are held back
deliberately. The year sits in the stage path so later years land alongside
rather than overwriting — every year reuses the same 35 country codes, so
dropping the year level would collide.

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

Reserved version range **V4.x**. `V4.1.x` is the stage; tables start at `V4.2.x`:

```
V4.1.1__create_sales_csv_stage.sql            # DONE
V4.2.1__create_bronze_reference_tables.sql    # region, country, currency, tax
V4.2.2__create_bronze_product_tables.sql      # category, family, model, sku, country availability
V4.2.3__create_bronze_master_tables.sql       # store master, customer master
V4.2.4__create_bronze_sales_tables.sql        # sales header, sales item
V4.3.1__initial_copy_into_bronze.sql          # first full load from stage
```

## Next step

Files are staged, so `INFER_SCHEMA` can now be run against
`COMMON.ff_csv_infer` to derive each table's structure, for example:

```sql
SELECT *
FROM TABLE(
  INFER_SCHEMA(
    LOCATION      => '@BRONZE.sales_csv_stg/initial-load/country-master/',
    FILE_FORMAT   => 'COMMON.ff_csv_infer',
    IGNORE_CASE   => TRUE
  )
);
```

Feed those columns into the `V4.2.x` scripts, adding the 3 metadata columns, then
load with `V4.3.1`.
