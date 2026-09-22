# 05_silver — cleaned & curated zone

**Status: in progress. 9 of 13 tables delivered** — the country-master group
(V5.1.1 – V5.1.4) and the product-master group (V5.1.5 – V5.1.9) are complete.
Remaining: store, customer, sales header, sales item.

## Delivered

| Script | Table | Rows | Refresh mode |
|---|---|---|---|
| `V5.1.1` | `SILVER.sv_region_master` | 5 | INCREMENTAL, verified |
| `V5.1.2` | `SILVER.sv_currency_master` | 27 | INCREMENTAL, verified |
| `V5.1.3` | `SILVER.sv_tax_master` | 35 | INCREMENTAL, verified |
| `V5.1.4` | `SILVER.sv_country_master` | 35 | INCREMENTAL, verified |
| `V5.1.5` | `SILVER.sv_product_category_master` | 10 | INCREMENTAL, verified |
| `V5.1.6` | `SILVER.sv_product_family_master` | 43 | INCREMENTAL, verified |
| `V5.1.7` | `SILVER.sv_product_model_master` | 111 | INCREMENTAL, verified |
| `V5.1.8` | `SILVER.sv_product_sku_master` | 650 | INCREMENTAL, verified |
| `V5.1.9` | `SILVER.sv_product_country_availability` | 22,750 | INCREMENTAL, verified |

## Patterns established by V5.1.1 (reuse for the remaining tables)

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

## Remaining scripts

Reserved version range **V5.x**, one script per table (superseding the earlier
one-script-per-group sketch, which the delivered work outgrew — a single script
per table keeps each entity's DQ reasoning with its DDL):

```
V5.1.10__create_silver_store_master.sql
V5.1.11__create_silver_customer_master.sql
V5.1.12__create_silver_sales_header.sql
V5.1.13__create_silver_sales_item.sql
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

## Product-master group complete (V5.1.5 - V5.1.9)

`category -> family -> model -> sku -> country availability`. All five
INCREMENTAL and verified, all tagged, **zero Snowflake recommendations**, and
**zero DQ flags across all 23,564 rows** - the cleanest group in the layer.

| Table | Rows | Key | DQ flagged | Orphans |
|---|---|---|---|---|
| `sv_product_category_master` | 10 | `category_code` | 0 | n/a (root) |
| `sv_product_family_master` | 43 | `family_code` | 0 | 0 |
| `sv_product_model_master` | 111 | `model_code` | 0 | 0 |
| `sv_product_sku_master` | 650 | `sku_code` | 0 | 0 |
| `sv_product_country_availability` | 22,750 | `(sku_code, country_code)` | 0 | 0 both FKs |

Integrity verified end-to-end, not just per table: the four-level product walk
returns exactly **650** rows and the six-join walk across **both** hierarchies
(product x geography) returns exactly **22,750**. A lower number would mean a
broken join; a higher one would mean duplicate keys at a parent level. No
childless categories, families or models.

### Three conventions this group added to the layer

**1. Static literals instead of `CURRENT_DATE()` in DQ flags.** Plausibility
bounds on `launch_year` / `launch_date` use `1976` and `2035` literals, never
`YEAR(CURRENT_DATE())`. The existing rule banned non-deterministic functions from
the projection; this group establishes that it applies **inside `IFF()` too**, not
just to selected columns. A date function anywhere in the definition forces FULL
refresh - too high a price for a DQ flag. The trade-off is explicit: a static
ceiling needs revising eventually (scheduled, visible) rather than imposing
unbounded compute on every refresh (unscheduled, invisible).

**2. Row-level flags describe only their own row.** Anything needing a second
table - FK existence, cross-level date coherence, childless-parent coverage - is a
**set-level assertion** and lives in validation SQL, never in `dq_issue_flags`.
Joining a parent into a DT definition would couple its refresh to that parent for
the sake of an attribute check. This is why every script validates FKs with a
`LEFT JOIN` *after* creation.

**3. A flag firing on 100% (or 0%) of rows is a bug, not a check.** Both
`discontinue_date` (NULL on all 111 models) and `is_available` (TRUE on all 22,750
rows) are deliberately **unflagged**: a universal flag carries no information and
trains readers to ignore the column. Their uniformity is asserted in validation
instead, so a future change surfaces as a shifted number rather than 22,750 new
flags. Note this **diverges** from V5.1.4, where NULL measures *were* folded into
flags - for a measure, absent is always wrong; for an open-ended date, absent is a
legitimate business state. Nullability does not decide whether a flag belongs; the
column's semantics do.

Consistent with this, **no allow-list flags** on `reporting_segment`,
`lifecycle_status` or `price_tier`. A new segment or tier is a routine business
change, not a defect - NULL is flagged, unfamiliar is not.

### Four carry-forward items for later layers

**1. `sv_product_sku_master` has no price.** `price_tier` is an ordinal band
(Premium 306 / Ultra 255 / Standard 89), not a monetary amount - no MSRP, no
currency. The SKU dimension **cannot value a transaction**. Any price-variance or
discount analysis must derive its baseline from the sales **fact** (e.g. median
selling price per `sku_code, currency_code`). This is exactly the assumption a
gold or BI developer would otherwise make.

**2. `local_part_number` is unique per region, not per country - and that is
correct.** 22,750 rows carry only **19,500 distinct** part numbers; 2,600 are
reused across 5,850 rows, max reuse 3. Investigated before deciding: reuse
**never crosses a SKU** (`reused_across_skus = 0`) and **never crosses a region**
(`reused_across_regions = 0`, tested by joining through `sv_country_master`). The
suffixes are Apple's regional codes (`ZD/A`, `EX/A`, `CB/A`...) and Apple part
numbers are region-scoped by design. **No flag raised** - same precedent as the
alpha2/alpha3 heuristic discarded in V5.1.4: a candidate rule that has been
disproved is documented and dropped, not implemented defensively. If either
number ever becomes non-zero, *that* is a genuine finding.

**3. `sv_product_country_availability` cannot filter anything today.** The grain
is a complete cartesian product (650 x 35, min = max = 35 countries per SKU) with
`is_available` TRUE on every row. Joining it to restrict a sales query to
"available products" removes **zero** rows, and any apparent effect would be
fan-out rather than filtering. Same class of generated-data artefact as sales
header:item being exactly 1:1. The table is still worth building: `local_part_
number` and the local launch/discontinue dates exist nowhere else, and the DT
needs no change once the source becomes selective.

**4. Only four reporting segments, and Services is correctly absent.** Services
has no physical SKU, so it has no product category. Do **not** reconcile
`sv_product_category_master.reporting_segment` (4 values, segments PRODUCTS)
against `sv_country_master.apple_fiscal_segment` (5 values, segments
GEOGRAPHIES) - they share a name and nothing else, and the gap is permanent.
