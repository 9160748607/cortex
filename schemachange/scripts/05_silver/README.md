# 05_silver — cleaned & curated zone

**Status: scaffold.** Blocked on the same CSV column definitions as `04_bronze`.

## Rules this folder must implement

- Bronze → silver movement uses **dynamic tables only** — never `INSERT`,
  `MERGE` or a task-driven procedure.
- Every dynamic table:

  ```sql
  CREATE DYNAMIC TABLE IF NOT EXISTS {{ database }}.SILVER.<name>
    TARGET_LAG  = DOWNSTREAM          -- refresh driven by gold consumers
    WAREHOUSE   = {{ warehouse }}
    REFRESH_MODE = INCREMENTAL        -- mandated, not AUTO
    COMMENT = '...'
  AS
  SELECT ...
  ```

- `TARGET_LAG = DOWNSTREAM` on every silver table: freshness is pulled by the
  gold layer rather than each table refreshing on its own clock.
- `REFRESH_MODE = INCREMENTAL` is explicit. Leaving it `AUTO` lets Snowflake
  silently fall back to full refresh, which breaks the incremental requirement
  and costs more.
- This is where cleansing belongs: type casting, trimming, `NULL`
  standardisation, deduplication on natural keys, rejecting orphan rows.
- Silver reads bronze only.

## Incremental-refresh constraints to respect

Not every query can refresh incrementally. When writing these, avoid in the
dynamic table definition:

- non-deterministic functions (`CURRENT_TIMESTAMP()`, `RANDOM()`, sequences)
- `QUALIFY RANK()` not at the top level
- aggregates not at the top level
- lateral joins and some correlated subqueries

Verify after deploy with:

```sql
SELECT name, refresh_mode, refresh_mode_reason
FROM   {{ database }}.INFORMATION_SCHEMA.DYNAMIC_TABLES;
```

If `refresh_mode` came back `FULL` when `INCREMENTAL` was requested,
`refresh_mode_reason` names the offending construct.

## Planned scripts

Reserved version range **V5.x**, one script per source group:

```
V5.1.1__create_silver_reference_dynamic_tables.sql
V5.1.2__create_silver_product_dynamic_tables.sql
V5.1.3__create_silver_master_dynamic_tables.sql
V5.1.4__create_silver_sales_dynamic_tables.sql
```
