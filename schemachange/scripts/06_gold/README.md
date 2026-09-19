# 06_gold — modelled zone

**Status: scaffold.** Blocked on the same CSV column definitions as `04_bronze`.

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
a full refresh would mint different keys, and the dynamic table would be forced
to `FULL` refresh mode at best.

Use a deterministic surrogate in gold dynamic dimensions instead:

```sql
HASH(product_sku_code) AS product_key
```

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
V6.1.1__create_gold_dim_geography.sql       # region + country
V6.1.2__create_gold_dim_currency_and_tax.sql
V6.1.3__create_gold_dim_product.sql         # category/family/model/sku rollup
V6.1.4__create_gold_dim_store.sql
V6.1.5__create_gold_dim_customer.sql
V6.2.1__create_gold_fact_sales.sql          # joins gold dims, not silver
V6.3.1__create_gold_agg_sales_summary.sql   # aggregated fact
R__gold_semantic_view.sql                   # repeatable, applied last
```
