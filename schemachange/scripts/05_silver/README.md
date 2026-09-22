# 05_silver — cleaned & curated zone

**Status: in progress.** First table delivered: `V5.1.1__create_silver_region_master.sql`.

## Delivered

| Script | Table | Rows | Refresh mode |
|---|---|---|---|
| `V5.1.1` | `SILVER.sv_region_master` | 5 | INCREMENTAL, verified |
| `V5.1.2` | `SILVER.sv_currency_master` | 27 | INCREMENTAL, verified |
| `V5.1.3` | `SILVER.sv_tax_master` | 35 | INCREMENTAL, verified |
| `V5.1.4` | `SILVER.sv_country_master` | 35 | INCREMENTAL, verified |

## Patterns established by V5.1.1 (reuse for the remaining 9 tables)

- **De-duplicate with `QUALIFY ROW_NUMBER()`, never `DISTINCT` or `GROUP BY`.**
  `ROW_NUMBER()` is incrementally supported; the other two are only partial and
  risk forcing FULL refresh. Keep `QUALIFY` top-level and put the partition key
  in the SELECT list.
- **Make the survivor ordering deterministic**, ending in
  `(__file_name, __row_number)` which is unique per bronze row. A
  non-deterministic tie-break lets the winner change on every refresh.
- **Hard-reject only unusable rows** (null/blank business key). Flag everything
  else in `dq_issue_flags` rather than dropping it.
- **Carry the three bronze technical columns forward unchanged**, and add
  `__bronze_row_count` as the duplicate-monitoring hook.
- **Never put `CURRENT_TIMESTAMP()` / `CURRENT_DATE()` in the projection** - they
  are allowed in filters only; in a SELECT list they force FULL refresh. This
  rules out `is_current` and any `__silver_loaded_at` column.
- **`SEQ*()` sequences do not work in dynamic tables at all** - relevant to gold,
  where the 6 sequences from `V3.1.3` cannot be used.
- **Tag every table** with `MEDALLION_LAYER` (architectural note 6).

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

## Carried-forward control from V5.1.2

`sv_currency_master.minor_unit` is the money rounding contract (0 for JPY/KRW,
2 for the rest). It detected **8,471 rows** in `br_sales_header` holding decimal
amounts in currencies that cannot represent them - 6,767 JPY and 1,704 KRW. The
producer generated every amount on a USD scale and relabelled the currency.

Fixing that is the **sales** layer's job, not currency's. When the sales silver
and gold tables are built, join `minor_unit` in and either `ROUND()` the amounts
to it or raise a DQ flag. The detection query is at the bottom of `V5.1.2`.

## Country-master group complete (V5.1.1 - V5.1.4)

`region -> (currency, tax) -> country`. All four INCREMENTAL, all tagged, no
Snowflake recommendations, and **silver-to-silver FK integrity verified**:
country joins cleanly to all three referenced silver tables with zero orphans.

| Table | Rows | DQ flagged |
|---|---|---|
| `sv_region_master` | 5 | 0 |
| `sv_currency_master` | 27 | 0 |
| `sv_tax_master` | 35 | 0 |
| `sv_country_master` | 35 | **1** (`UK` -> `NON_ISO_ALPHA2_CODE`) |

### Two carry-forward items for later layers

**1. `UK` is not a valid ISO alpha-2 code** (should be `GB`; the alpha-3 `GBR` is
correct). Flagged, never rejected - 2,400 customers, 5,862 sales rows and 8
stores reference it.

Detection uses an **explicit exception list**, not a pattern. The obvious
heuristic `country_code <> LEFT(iso_alpha3,2)` returns 12 rows of which **11 are
valid ISO pairs** (AE/ARE, DK/DNK, KR/KOR ...). An 11-in-12 false-positive rate
is the same cry-wolf failure as the naive type-drift guard in
`schema_evolution_or_drift/09` section 9.3.

**2. `br_store_master.tax_jurisdiction_code` does not join to `sv_tax_master`** -
all **121** store rows are orphans. Store codes are sub-national and omit the
tax-type token (`AU_ACT_STD`); tax codes are country-level and include it
(`AU_GST_STD`). 70 distinct store codes vs 35 tax codes. The country prefix is
consistent, so it is reconcilable - but a prefix join **fans out 1->2** for
countries with multiple tax types. `sv_store_master` needs a mapping table or an
explicit tax-jurisdiction dimension, not a `LEFT JOIN` returning NULL for every
store. Control query is at the bottom of `V5.1.3`.
