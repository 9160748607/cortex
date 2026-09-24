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
V6.1.1__create_gold_dim_country.sql         # DELIVERED - region+country+currency+tax
V6.1.2__create_gold_dim_product.sql         # category/family/model/sku rollup
V6.1.3__create_gold_dim_store.sql
V6.1.4__create_gold_dim_customer.sql
V6.1.5__create_gold_dim_date.sql            # must cover 2020-01-01, see below
V6.2.1__create_gold_fact_sales.sql          # joins gold dims, not silver
V6.3.1__create_gold_agg_sales_summary.sql   # aggregated fact
V6.4.x__create_gold_dim_*_scd2.sql          # RESERVED - procedure-maintained
                                            # true SCD-2, if history is needed
R__gold_semantic_view.sql                   # repeatable, applied last
```

`V6.1.1` **supersedes** the two scripts this file previously planned —
`dim_geography` (region + country) and `dim_currency_and_tax`. All four
country-related silver tables conform to one grain with zero fan-out (measured:
the 4-way join returns 35 rows from 35, zero orphans on all three lookups), so
splitting them would have produced two dimensions that always join 1:1 — a
snowflake where a star was available.

### Carry-forward for `V6.1.5` dim_date

The date dimension **must cover 2020-01-01** or 24 sales rows will not join —
timezone spillover, recorded in `AGENT.md` §7.

### Carry-forward for `V6.2.1` fact_sales

- Build revenue from `sv_sales_item`, **not** `sv_sales_header`. Their measures
  are identical 1:1 and both total 50,186,627.97; summing both silently doubles
  revenue while the row count stays correct.
- Join `dim_country` on the **validity window**, not just the code:
  `ON d.country_code = h.country_code AND h.transaction_timestamp::DATE BETWEEN
  d.valid_from AND d.valid_to`. Verified to return 77,155 of 77,155 rows.
- The 38,102 sales rows predating their store's opening belong here (needs a
  join, per DQ rule 3). Compare against **each store's own** open date.
- Cross-currency `SUM` remains invalid until an FX dimension exists.
