# 05_silver — cleaned & curated zone

**Status: in progress. 10 of 13 tables delivered** — the country-master group
(V5.1.1 – V5.1.4), the product-master group (V5.1.5 – V5.1.9) and customer
master (V5.1.10) are complete. Remaining: store, sales header, sales item.

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
| `V5.1.10` | `SILVER.sv_customer_master` | 31,350 | INCREMENTAL, verified |

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
V5.1.11__create_silver_store_master.sql
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

## Customer master complete (V5.1.10) — first table with personal data

31,350 rows, INCREMENTAL, tagged, zero Snowflake recommendations, zero duplicate
keys, zero FK orphans. **24,713 rows carry DQ flags** — by far the most in the
layer, and every one is a real finding rather than a loading artefact.

`customer_id` and `customer_number` are **both** unique (31,350 distinct each),
so the table has two candidate keys. `customer_id` is the business key.

### OUTSTANDING GOVERNANCE GAP — masking policies do not exist yet

Nine columns are personal data and all nine are 100% populated:

`first_name` `last_name` `full_name` `date_of_birth` `email` `phone_number`
`street_address` `city` `postal_code`

Directly identifying: `email`, `phone_number`, `full_name`, `street_address`.
**Quasi-identifying:** `date_of_birth` + `postal_code` + `gender` re-identify an
individual even with names removed, so those must be in scope too — not waved
through as harmless geography.

No policy is applied in V5.1.10 **by design**: per the architectural rule,
masking policies live in `GOVERNANCE` and are only *attached* in `SALES_DEV`.
The policies have not been written, so this is recorded as an open gap rather
than half-solved. Two notes for whoever writes them:

- `full_name` is exactly `first_name || ' ' || last_name` on all 31,350 rows
  (verified). It **must** be masked in step with the two parts, or masking either
  is pointless. It is kept rather than dropped because a policy needs a single
  column to govern.
- `date_of_birth` wants a *generalising* policy (year, or an age band), not full
  redaction — age is analytically useful, an exact birth date is not.

**1,051 of these customers are in GDPR countries**, which makes this a legal
requirement rather than a preference.

### THE COMPLIANCE FINDING — 3,515 customers were minors at registration

| Threshold | Rows | Why this threshold |
|---|---|---|
| under 18 | **3,515** | general contractual capacity |
| under 16 | 2,360 | GDPR Art. 8 default for a child's own consent |
| under 13 | **698** | COPPA line (US) |

**The youngest was 11.** 1,051 of the under-18s are in GDPR countries. Only 360
of the 3,515 are in the Education segment, so this is *not* explained away as
school accounts.

Flagged at **two** thresholds deliberately — 13 and 18 carry different legal
obligations, and a single "is a minor" flag would collapse three regimes into
one. **Flagged, never rejected:** deleting the rows would destroy the evidence
the account exists, orphan its sales, and make the compliance position harder to
establish. This needs a governance decision (consent verification, erasure, or
source-side age-gating) and needs the rows visible to make it.

Age is computed **at registration**, not today — a current-age calculation needs
`CURRENT_DATE()`, which would force FULL refresh. Age at registration is the
compliance-relevant figure anyway, since consent is given at sign-up.

### Four deliberate divergences from the layer pattern

**1. `customer_id` is NOT upper-cased.** It is a lowercase UUID (RFC 4122
canonical form), and `br_sales_header.customer_id` is lowercase too. Applying the
usual `UPPER(TRIM(...))` would *mutate* all 31,350 values and silently orphan all
**77,155** sales rows. The rule exists to stop casing drift breaking joins; here
applying it mechanically would *create* that exact failure. Treatment is `TRIM`
only. `customer_number` is still upper-cased — it is a structured business code.

**2. `country_name` and `region` are dropped.** Both are provably redundant
against the conformed dimension — **0 mismatches / 31,350** on each, and
`region`'s five values are exactly `sv_region_master`'s region codes. Keeping them
would store the same fact twice with no way to enforce agreement. `country_code`
reaches both in one join. Bronze remains the faithful record.

`preferred_language` is **kept** despite also matching the country default on
every row: a country *has* a primary language, a customer *chooses* one, and
those legitimately diverge. It carries no independent signal today — noted so
nobody mistakes it for real per-customer preference.

**3. `loyalty_tier = 'None'` is rewritten to NULL** — 15,641 rows (49.9%) held the
four-character *string* `'None'`, a Python `None` serialised into CSV. Cleansed
via `NULLIF`, **not flagged**: a flag on half the table says nothing (the 100%
rule), and leaving it would mean the first consumer who writes `IS NOT NULL`
instead of `<> 'None'` gets a silently wrong answer. NULL here means *not
enrolled*, which is a legitimate state, not missing data.

**4. Survivor ordering now leads with `updated_at`** — the first table in the
layer to have it. It is populated on every row and differs from `created_at` on
every row, so it is the true recency signal; `created_at` is demoted to a
tie-break. Ordering by `created_at` first would pick the oldest-edited version of
a re-delivered customer.

### Two carry-forward items

**1. Email is NOT an identity key — never de-duplicate on it.** 31,350 rows hold
only **30,106** distinct addresses; 1,056 are shared across 2,300 rows, up to 5
each. Investigated before deciding, and the evidence inverts the obvious reading:
**1,006 of the 1,056 shared addresses belong to different people** (different
names) and 756 span different countries, while testing for genuine duplicates
(same first name + last name + DOB) returns **zero** groups. These are distinct
individuals colliding on a generated address, not duplicate records. No row-level
flag is raised — sharing is a property of a *group*, so it is a set-level
assertion per the V5.1.7 rule, and flagging all 2,300 would imply each is
defective, which the name evidence contradicts.

**2. `phone_number` is not normalised, and no digits-only variant was derived.**
23,874 rows (76.2%) are flagged `PHONE_NOT_E164`. Four incompatible shapes
coexist:

| Shape | Rows | Example |
|---|---|---|
| digits/separators only | 15,924 | `0 2061 8330` |
| contains letters (extensions) | 6,660 | `(010)034-9469x052` |
| leading `+` | 6,177 | `+04(4)9130337535` |
| parenthesised | 2,589 | `(+358) 131281138` |

`REGEXP_REPLACE(phone_number,'[^0-9]','')` is deterministic and incremental-safe,
so it would *work* — but 6,660 values carry an **extension**, and stripping
non-digits fuses it onto the subscriber number, producing a plausible-looking
number that dials the wrong place. **A visibly messy value is safer than an
invisibly wrong one.** Real E.164 normalisation needs the country dialling code
and extension parsing — a gold-layer or utility job, not a REGEXP in a dimension.

Also note `acquisition_year` duplicates `YEAR(registration_date)` with zero
mismatches, and `customer_type` is `'NEW'` on 100% of rows — uniform, so no flag
(the 100% rule again). Both are asserted in validation.
