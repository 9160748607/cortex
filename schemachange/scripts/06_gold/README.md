# 06_gold — modelled zone

**Status: in progress.** `V6.1.1` `dim_country` is delivered and verified. The
remaining dimensions, the facts, the aggregate and the semantic view are still
scaffold.

## Two hard limits of dynamic tables — read before adding a dimension

Both were established by `V6.1.1` and neither has a workaround inside a dynamic
table. Do not spend another session rediscovering them.

### 1. A dynamic table cannot implement SCD-2

Three independent reasons:

1. SCD-2 change detection must compare incoming rows against the **existing
   target** to close the prior version. A dynamic table's definition is a query
   over its **sources** only — it cannot self-reference.
2. Stamping a close date needs `CURRENT_DATE`/`CURRENT_TIMESTAMP` in the SELECT
   list, which `AGENT.md` §5 bans outright — non-deterministic, forces FULL
   refresh.
3. A dynamic table is declarative: it always equals its query over current source
   state. When a source row changes the DT row changes **in place**. There is
   nowhere for history to live.

What `V6.1.1` does instead is carry the SCD-2 **column contract**
(`country_key`, `valid_from`, `valid_to`, `is_current`, `scd_version_hash`) and
**pass through** the intervals the source provides. Downstream facts can write
the correct as-of predicate today and will not need rewriting later. But nothing
*generates* history.

For **true** SCD-2, use a stream + task + `MERGE` into a **standard table**. That
is what "Reserve the sequences for any procedure-maintained SCD2 dimension added
later" below refers to. Reserved as `V6.4.x`.

### 2. A dynamic table cannot declare constraints — but Snowflake derives a PK

`CREATE DYNAMIC TABLE` has **no constraint clause** (the column definition takes
only masking/projection policy, tag, comment, contact), and `ALTER DYNAMIC TABLE`
has **no `ADD CONSTRAINT`** action.

However — writing the dimension with `QUALIFY ROW_NUMBER() OVER (PARTITION BY
<grain>) = 1` makes Snowflake derive a real primary key. Measured on `dim_country`:

```
SHOW UNIQUE KEYS IN dim_country;
COUNTRY_CODE  seq 1  SYS_CONSTRAINT_DERIVED_PK  rely = true
VALID_FROM    seq 2  SYS_CONSTRAINT_DERIVED_PK  rely = true
```

So the `QUALIFY` is **not** merely defensive de-duplication — it is the mechanism
that produces the constraint. Removing it silently removes the primary key.
`RELY = true` also lets the optimizer eliminate unnecessary joins downstream.

Declare the intended PK/FK relationships in **column comments** as well, so the
contract is discoverable via `DESCRIBE`.

## Rules this folder must implement

- Fact and dimension tables are **dynamic tables built on silver tables**.
- **The critical rule:** facts and dimensions must reference **gold-layer dim
  tables** for master data — *not* silver tables. So:

  ```
  silver.sales_item ─┐
                     ├─> gold.fact_sales ──> joins gold.dim_product  (correct)
  silver.product ────┘                       NOT silver.product      (wrong)
  ```

  Dimensions are therefore built first (V6.1.x), and facts join to those
  dimensions to resolve surrogate keys (V6.2.x). Ordering matters, which is why
  the version numbers separate the two stages.

- The **aggregated fact table** is also a dynamic table in this schema.
- The **semantic view** lives here.
- Same dynamic-table settings as silver: `TARGET_LAG = DOWNSTREAM`,
  `REFRESH_MODE = INCREMENTAL`, explicit `WAREHOUSE`.

## Surrogate keys — read before writing dimensions

`COMMON.seq_dim_*` sequences exist (V3.1.3) but **must not be called inside a
dynamic table** — a sequence is non-deterministic, so an incremental refresh and
a full refresh would mint different keys. Per the Snowflake docs, sequences are
not supported in dynamic tables at all.

Use a deterministic hash surrogate instead. **Use `SHA1_HEX`, not `HASH()`:**

```sql
SHA1_HEX(country_code || '|' || TO_VARCHAR(valid_from,'YYYY-MM-DD')) AS country_key
```

An earlier revision of this file suggested `HASH(product_sku_code)`. `SHA1_HEX` is
preferred and supersedes it: `HASH()` returns a signed 64-bit number, so collision
probability becomes non-trivial as dimensions grow, and its value is not
contractually stable across Snowflake versions. `SHA1_HEX` returns a
deterministic 40-character hex string.

**Include the validity start in the key of any SCD-2-shaped dimension**, as
above. Keying on the natural key alone means a second version collides with the
first.

Reserve the sequences for any procedure-maintained SCD2 dimension added later.

## Why the semantic view is an `R__` script

`R__gold_semantic_view.sql` is **repeatable**, not versioned, because:

- a semantic view is a whole-definition object — adding one metric means
  restating the object, exactly the case the schemachange docs call out for
  repeatable scripts;
- schemachange re-applies it whenever its checksum changes, so editing the file
  in place is the intended workflow;
- repeatable scripts run *after* all pending versioned scripts, so the tables it
  references always exist first.

This is the one documented exception to architectural note 5's
"`IF NOT EXISTS` everywhere": it will use `CREATE OR REPLACE SEMANTIC VIEW`.
That is safe here because a semantic view holds **no data** — it is a metadata
definition over gold tables, so replacing it destroys nothing. Applying note 5
literally would make the object unmaintainable.

## Planned scripts

Reserved version range **V6.x**:

```
V6.1.1__create_gold_dim_country.sql            # DELIVERED - region+country+currency+tax
V6.1.2__alter_gold_dim_country_scd2_intervals.sql  # DELIVERED - true SCD-2 via LEAD
V6.1.3__create_gold_dim_product.sql            # DELIVERED - category/family/model/sku
V6.1.4__create_gold_bridge_product_country.sql # DELIVERED - bridge, NOT a dimension
V6.1.5__create_gold_dim_store.sql              # DELIVERED - SCD-1, load-date trap
V6.1.6__create_gold_dim_customer.sql           # DELIVERED - SCD-1, CARRIES UNMASKED PII
V6.1.7__create_gold_dim_date.sql               # DELIVERED - REGULAR TABLE, not a DT
V6.1.8__alter_gold_dim_store_add_na_member.sql # DELIVERED - N/A member, no NULL FKs
V6.2.1__create_gold_fact_sales_item.sql        # DELIVERED - ATOMIC, line grain, revenue
V6.2.2__create_gold_fact_sales_header.sql      # DELIVERED - order grain, NOT the revenue source
V6.3.1__create_gold_agg_sales_summary.sql   # aggregated fact
V6.4.x__create_gold_dim_*_scd2.sql          # RESERVED - procedure-maintained
                                            # true SCD-2, if history is needed
R__gold_semantic_view.sql                   # repeatable, applied last
```

### 5 product tables became 2 gold objects, not 5

`V6.1.3` flattens the four-level hierarchy into ONE dimension at SKU grain.
Measured: the 4-way join returns **650 rows from 650** with zero orphans at every
level, so category/family/model are simply attributes of a SKU. Four separate
dims would always join 1:1 and force three extra joins on every consumer.

`V6.1.4` is separate because it is **many-to-many** — 650 × 35 = 22,750, a
complete cartesian. It cannot fold into a SKU-grain dimension.

### ⚠ Two things about the product objects that differ from `dim_country`

**1. They are SCD-1, not SCD-2 — and that is not a shortcut.** `dim_country` gets
real SCD-2 because its grain driver supplies `effective_start_date`. The product
grain driver, `sv_product_sku_master`, supplies **nothing temporal**. Only
`category` has dates (10 rows, the root). Using them as the dimension's
`valid_from` would assert a 2024 SKU was valid from 1984-01-24 — structurally
plausible, semantically nonsense. So `category_valid_from` is carried as lineage
only, and both objects take the **current version of each level**. Temporal SCD-2
on products needs the feed to emit effective dates.

**2. The bridge fans out 35×.** Measured against the fact:

| Join | Rows |
|---|---|
| `sv_sales_item`, current versions | 77,131 |
| → `dim_product` on `sku_code` | 77,131 — safe |
| → bridge on `sku_code` **alone** | **2,699,585** — exactly 35× |
| → bridge on `(sku_code, country_code)` | 77,131 — correct |

`country_code` is on `sv_sales_header`, not `sv_sales_item`, so the correct join
needs the header too. Also note `is_available` is **TRUE on all 22,750 rows** — it
filters nothing, and is retained only for source fidelity.

### `V6.1.1` superseded two originally-planned dimensions

`dim_geography` (region + country) and `dim_currency_and_tax` are gone. All four
country-related silver tables conform to one grain with zero fan-out (measured:
the 4-way join returns 35 rows from 35, zero orphans on all three lookups), so
splitting them would have produced two dimensions that always join 1:1 — a
snowflake where a star was available. The same reasoning produced one
`dim_product` rather than four.

### Carry-forward for `V6.1.7` dim_date

`V4.6.3` has since **removed** the 24 rows dated 2020-01-01, so the loaded data is
2019 only (77,131 rows). `dim_date` still covers that date as harmless headroom.
Originally: the date dimension had to cover 2020-01-01 or 24 sales rows would not join —
timezone spillover, recorded in `AGENT.md` §7.

### Carry-forward for `V6.2.1` fact_sales

- Build revenue from `sv_sales_item`, **not** `sv_sales_header`. Their measures
  are identical 1:1 and both total 50,172,602.26; summing both silently doubles
  revenue while the row count stays correct.
- **Filter `__is_current_version = TRUE` on both fact tables.** After `V5.2.2`
  they preserve corrected transactions as new versions; omitting the filter
  double-counts a correction.
- Join `dim_country` on the **validity window**, not just the code:
  `ON d.country_code = h.country_code AND h.transaction_timestamp::DATE BETWEEN
  d.valid_from AND d.valid_to`. Verified to return 77,131 of 77,131 rows.
- Join `dim_product` on `sku_code` — safe 1:1, it is SCD-1 with one row per SKU.
- If you need `bridge_product_country`, constrain **both** `sku_code` and
  `country_code` or it fans out 35×.
- The 38,088 sales rows predating their store's opening belong here (needs a
  join, per DQ rule 3). Compare against **each store's own** open date.
- Cross-currency `SUM` remains invalid until an FX dimension exists.
