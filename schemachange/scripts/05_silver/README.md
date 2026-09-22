# 05_silver — cleaned & curated zone

**Status: COMPLETE — all 13 tables delivered.** Country-master group
(V5.1.1 – V5.1.4), product-master group (V5.1.5 – V5.1.9), customer master
(V5.1.10), store master (V5.1.11) and the two sales facts (V5.1.12 – V5.1.13).
All 13 are INCREMENTAL and verified, all tagged, **zero Snowflake
recommendations across the entire layer**.

Two open modelling items block parts of gold: there is **no FX-rate dimension**
(so no cross-currency revenue) and **`sv_tax_master` is not time-variant** (so no
historical tax recomputation). Both are detailed in the sales-facts section.

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
| `V5.1.11` | `SILVER.sv_store_master` | 121 | INCREMENTAL, verified |
| `V5.1.12` | `SILVER.sv_sales_header` | 77,155 | INCREMENTAL, verified |
| `V5.1.13` | `SILVER.sv_sales_item` | 77,155 | INCREMENTAL, verified |

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

None — the layer is complete. Next is `06_gold`.

## Carried-forward control from V5.1.2

`sv_currency_master.minor_unit` is the money rounding contract (0 for JPY/KRW,
2 for the rest). It detected **8,471 rows** in `br_sales_header` holding decimal
amounts in currencies that cannot represent them - 6,767 JPY and 1,704 KRW. The
producer generated every amount on a USD scale and relabelled the currency.

Fixing that is the **sales** layer's job, not currency's. When the sales silver
and gold tables are built, join `minor_unit` in and either `ROUND()` the amounts
to it or raise a DQ flag. The detection query is at the bottom of `V5.1.2`.

> **RESOLVED in V5.1.12 — and both suggestions above are withdrawn.** Measuring
> `AVG(net_total)` across all 27 currencies showed every one landing in **620–780**,
> which is impossible in real retail. The USD-scaling defect therefore affects
> **all 77,155 rows**, not 8,471 — JPY and KRW are merely the only currencies whose
> `minor_unit = 0` makes the error *detectable*. So:
> - **Do not `ROUND()`.** Rounding JPY 623.51 → 624 yields a type-correct value
>   still wrong by ~150×, destroying the only visible evidence while fixing
>   nothing. Strictly worse than leaving it alone.
> - **Do not flag only the 8,471.** That would assert the other 68,684 are sound.
>
> The real consequence is that **cross-currency aggregation is invalid** and cannot
> be fixed by conversion, because **no FX-rate dimension exists** in this model.

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

**2. `br_store_master.tax_jurisdiction_code` does not join to `sv_tax_master`** —
all **121** store rows are orphans. Store codes are sub-national and omit the
tax-type token (`AU_ACT_STD`); tax codes are country-level and include it
(`AU_GST_STD`). 70 distinct store codes vs 35 tax codes.

> **RESOLVED in V5.1.11 — and this note was partly wrong.** It claimed a prefix
> join "fans out 1→2 for countries with multiple tax types" and that a mapping
> table or tax-jurisdiction dimension was therefore needed. **No country has more
> than one tax code** (`max_tax_codes_per_country = 1`, measured), so a
> country-level join cannot fan out and no mapping table is required. The
> jurisdiction string does not need parsing either: resolve tax via
> `store → sv_country_master.country_code → .tax_code → sv_tax_master`, which
> reaches all 121 stores with zero orphans. See the store-master section below.

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

## Store master complete (V5.1.11) — resolves the V5.1.3 tax question

121 rows, INCREMENTAL, tagged, zero Snowflake recommendations, **zero DQ flags**,
zero duplicate keys, zero FK orphans against `sv_country_master`. 24 countries
(not 35 — the estate does not cover every country that has customers), 8 of them
in the non-ISO `UK` code that V5.1.4 deliberately kept.

`format_code` is MINI 43 / FLG 40 / MALL 38. All 121 stores are open:
`store_close_date` NULL, `lifecycle_status` ACTIVE and `is_active` TRUE all agree,
which is why the NULL close date carries no flag (the 100% rule).

### RESOLVED — tax_jurisdiction_code never needed to be joined

The V5.1.3 note is corrected above. Three measurements settle it:

| Check | Result |
|---|---|
| tax codes per country in `sv_tax_master` | **exactly 1**, max = 1, none with >1 |
| jurisdiction prefix vs `country_code` | **0 mismatches / 121** |
| jurisdiction subdivision vs `state_code` | **0 mismatches / 82** |
| jurisdiction suffix | `_STD` on **121 / 121** |

The two vocabularies were never the same thing — the store code names the
**place** (`AU_ACT_STD`), the tax code names the **tax** (`AU_GST_STD`) — which is
why 70 store values met 35 tax values and matched none.

**The decisive finding: `tax_jurisdiction_code` carries no information at all.**
Every component already sits in a neighbouring column, and `state_code` is NULL on
exactly the 39 stores whose code has no middle part. So the correct path is:

```
store → sv_country_master.country_code → .tax_code → sv_tax_master
```

Verified: **121 stores resolved, zero orphans, zero fan-out.** No mapping table, no
tax-jurisdiction dimension, no string parsing. Gold must use this path — parsing
the string would hard-code a source naming convention to recover a value the model
already holds.

The column is **kept** rather than dropped (unlike `region_code`), for
traceability: it is the identifier `RETAIL_OPS` actually uses, so it is what an
operations analyst will quote. Its redundancy is policed by three flags
(`TAX_JURIS_COUNTRY_MISMATCH`, `TAX_JURIS_SUBDIVISION_MISMATCH`,
`TAX_JURIS_UNEXPECTED_SUFFIX`) plus `STATE_JURIS_DISAGREEMENT` — all zero today,
which is what keeps "derivable" honest rather than aspirational.

### THE HEADLINE DEFECT — 38,102 sales rows predate their store's opening

Discovered here, but it belongs to the **sales fact**:

- **67 of 121 stores (55%)** have a `store_open_date` after 2019-12-31; 83 opened
  after 2019-01-01; the latest is **2026-04-10**
- all 77,155 sales rows fall in 2019
- ⇒ **38,102 sales rows** are attributed to a store that had not yet opened —
  **61.6% of the 61,804 store-attributed rows** (the other 15,351 have a NULL
  `store_id` and are the online channel)

`orphan_store_sales = 0`, so every non-null `store_id` does resolve — the keys are
fine, the *chronology* is not.

**The store rows are not defective and carry no flag for this.** A store that
opened in 2021 is a valid store; the impossible thing is a 2019 transaction
pointing at it. Flagging the dimension would blame the wrong table and imply the
fix is deleting stores — which would delete 61.6% of store-attributed revenue. It
is also a statement about rows in *another* table, which the V5.1.7 rule assigns
to set-level validation. **V5.1.12 owns the row-level flag.**

One constraint on that flag: it must compare `transaction_timestamp` to **each
store's own** `store_open_date` via a join, never a hard-coded `'2019-12-31'`. A
literal happens to work on this data and silently stops working on any other load.

### Two traps and one rejected rule

**1. `effective_start_date` is a load date, not a business date.** It holds the
single value `2026-04-17` on all 121 rows (`distinct_eff_starts = 1`) and is later
than `store_open_date` on all 121. Filtering 2019 sales on
`effective_start_date <= transaction_date` returns **zero stores** and silently
zeroes every store-attributed metric. Use `store_open_date` / `store_close_date`
for temporal work; the `effective_*` pair is SCD mechanics only.

**2. Two sentinels, treated differently — deliberately.** V5.1.10 rewrote the
string `'None'` to NULL; this script **preserves** `effective_end_date =
9999-12-31`. `'None'` was a serialisation accident with no semantics that lied
about its own type and broke `IS NULL`. `9999-12-31` is an intentional, functional
SCD sentinel that *works*: `WHERE d BETWEEN effective_start_date AND
effective_end_date` selects the current row, whereas NULL would return no rows.
The test is not "does it look like a placeholder" but "does it carry correct
meaning and behave correctly".

**3. Rent per square foot is deliberately not flagged.** Range 30.69 – 3,690.50,
median **725**, p95 1,654, with 4 stores above 2,000. Prime Apple retail genuinely
reaches USD 2,000–3,000/sqft, so any threshold low enough to catch a real error
would also catch legitimate flagships — the cry-wolf failure from V5.1.4. Both
measures *are* guarded for impossibility (non-positive), and the distribution is
reported in validation so outliers are judged in context. Note `annual_rent_usd`
is already USD-denominated, so it is **not** affected by the JPY/KRW scaling
defect carried forward from V5.1.2.

### Other decisions

- **`region_code` dropped** — provably redundant (0 mismatches / 121 against
  `sv_country_master`, and its five values are exactly `sv_region_master`'s
  region codes). Same basis as V5.1.10. Bronze remains the faithful record.
- **NULL `state_code` on 39 stores is correct**, not missing data — those
  countries do not subdivide for tax purposes, and they are exactly the 39 with a
  2-part jurisdiction code. The flag guards *coherence* between the two, not
  nullability.
- **`GEO_NULL_ISLAND` is its own flag**, separate from the bounds check: `(0,0)`
  is *in* range but is the signature of a failed geocode, which a range test
  cannot see. Zero rows today; all coordinates in range.
- **No allow-list** on `format_code` or `lifecycle_status`, per V5.1.5/V5.1.6.

## Sales facts complete (V5.1.12 – V5.1.13) — the layer is finished

The first two fact tables, and an exact 1:1 pair. Both 77,155 rows, INCREMENTAL,
tagged, **zero Snowflake recommendations, zero DQ flags, zero duplicate keys,
zero FK orphans on any dimension**.

| Table | Rows | Key | Alternate key | DQ | Orphans |
|---|---|---|---|---|---|
| `sv_sales_header` | 77,155 | `transaction_sk` | `transaction_id` | 0 | 0 on customer, country, currency, store |
| `sv_sales_item` | 77,155 | `transaction_line_id` | `(transaction_sk, line_number)` | 0 | 0 on header, SKU |

### The structure is exact — the problems are values and chronology

Worth stating before the defects, because none of them are structural:
`net_total = gross_amount − total_discount + total_tax` holds on **all 77,155
rows** to the cent; `line_total = quantity × unit_price − discount_amount +
tax_amount` likewise. No negative or null amounts, no non-positive net, no
discount exceeding gross. `channel_id` and `store_id` form an **exact partition**
— `store_id` is NULL on precisely the 15,351 ONLINE rows and populated on
precisely the 61,804 POS rows. Header country matches both the store's and the
customer's country, and currency matches the country's currency, on every row.

### ⚠️ THE DOUBLE-COUNT TRAP — pick ONE table for revenue

The two tables are an exact bijection, proved four ways: 77,155 = 77,155 rows,
77,155 distinct `transaction_sk` **in items** (so no transaction has two lines),
`MIN(line_number) = MAX(line_number) = 1`, and zero headers without an item.

Consequently the header's measures are a **verbatim copy** of the item's —
verified to the cent, zero exceptions across all four:

```
header.gross_amount   = quantity * unit_price
header.total_discount = discount_amount
header.total_tax      = tax_amount
header.net_total      = line_total
```

Both tables total **50,186,627.97**. A naive join summing measures from each
returns **100,373,255.94** — exactly double — and because the join is 1:1 **the
row count stays perfectly correct while every amount is wrong.** A defect with no
symptom is the worst kind, and this one is easy to introduce.

**Build revenue from `sv_sales_item`, not the header.** It is the lower grain, so
it survives the arrival of a second line unchanged; header-based revenue would
silently stop matching the sum of its lines.

Measures are kept on **both** tables rather than stripped from one: a header-grain
total is legitimate in any normal schema and is only redundant because this data
has one line per transaction — an artefact of generation, the same class as the
650×35 cartesian in V5.1.9. **Do not build anything that assumes 1:1.**

### Defect 1 — the currency scale is worse than V5.1.2 thought

See the corrected V5.1.2 note above. Every one of the 27 currencies averages
620–780 `net_total`, so all 77,155 rows are USD-scaled with the currency as a bare
label. EUR 701 is a plausible basket; the same 675 in INR is ~USD 8 against a real
~65,000 INR.

**No row-level flag**, for three reasons in order of weight: flagging only the
8,471 detectable rows would assert the other 68,684 are fine (they are not); the
`minor_unit` test needs a join, which the V5.1.7 rule assigns to set-level
validation; and a hard-coded `IN ('JPY','KRW')` is an incomplete ISO 4217
zero-decimal list. The evidence is reproduced in validation across *all*
currencies instead.

**Open item: no FX-rate dimension exists.** `SUM(net_total)` across countries runs
cleanly and returns a confident, meaningless number. Gold must stay
single-currency until this is built.

### Defect 2 — `sv_tax_master` holds current rates, not 2019 rates

New finding. Recomputing tax as `(gross − discount) × tax_rate` via
country → `sv_tax_master` matches exactly on most countries and fails on five,
covering **5,609 rows**:

| tax_code | master rate (today) | effective rate (2019) | rows |
|---|---|---|---|
| `CA_GST_STD` | 5.0% | **13.0%** | 3,041 |
| `BR_ICMS_STD` | 17.0% | 12.0% | 1,033 |
| `CH_VAT_STD` | 8.1% | 7.7% | 754 |
| `MY_SST_STD` | 10.0% | 6.0% | 526 |
| `FI_VAT_STD` | 25.5% | 24.0% | 255 |

**Four of the five are the same story and not a data error.** Finland raised VAT
to 25.5% in 2024, Switzerland 7.7%→8.1% in Jan 2024, Malaysia SST 6%→10% in 2024.
In each case the *effective* rate is correct **for 2019** and the master is correct
**for today**. `sv_tax_master` has one row per country, so it cannot express a rate
change — it is a current-state dimension wearing temporal clothing
(`effective_start_date` / `effective_end_date` notwithstanding).

`CA_GST_STD` is different: 5% is **federal GST** while the data charges 13%,
Ontario's combined **HST**. That is a *grain* mismatch, not temporal — the same
country-vs-subdivision issue V5.1.11 decoded in `tax_jurisdiction_code`, resurfacing
on the rate side.

**Rule: `total_tax` as recorded on the transaction is authoritative.** Never
recompute historical tax from `sv_tax_master`, and **no `TAX_RATE_MISMATCH` flag**
is raised — flagging 5,609 rows would blame the fact for the dimension's missing
history. The master remains safe for *current* rate lookups and for `tax_type` /
inclusive-flag attributes.

**Open item:** making it safe for history means a genuine type-2 dimension with one
row per (jurisdiction, rate period).

### Defect 3 — 38,102 rows predate their store's opening, and a revised promise

Carried from V5.1.11 and confirmed: **38,102 rows (61.6% of the 61,804
store-attributed rows)** point at a store that had not yet opened, across 67
implicated stores.

> **V5.1.11 said "V5.1.12 owns the row-level flag". That is revised.** The check
> needs `sv_store_master.store_open_date`, i.e. a join — which the V5.1.7 rule
> assigns to set-level validation, and which would make a 77,155-row fact refresh
> whenever a 121-row dimension changes. It would also start this silver fact down
> the path of joining all five dimensions, which is a gold star-schema build, not a
> silver cleanse. **The check belongs in gold** (or as a DMF on the joined result);
> the exact SQL is in V5.1.12's validation block. The earlier promise was made
> before that consequence was thought through.

The V5.1.11 constraint still stands: compare against **each store's own** open date
via the join, never a hard-coded `'2019-12-31'` — a literal works on this load and
silently fails on the next.

### Other decisions

- **`category_code` dropped from the item** — provably derivable via
  sku → model → family → category with **0 unresolved and 0 mismatches / 77,155**.
  Stronger case than the earlier drops: it is *four* levels away, so it is the
  column most likely to be used as a shortcut and drift unnoticed.
- **24 rows timestamped 2020-01-01** (timezone spillover) are **not flagged** —
  expressing it needs a hard-coded year boundary, and the timestamps are probably
  correct; only the file-partitioning assumption is naive. **The gold date
  dimension must cover 2020-01-01** or those 24 rows will fail to join.
- **`transaction_sk` and `customer_id` are `TRIM`-only** — both lowercase UUIDs, the
  V5.1.10 trap. An `UPPER()` on either would orphan all 77,155 rows while leaving
  both tables looking healthy. A mutation check is in both validation blocks.
- **`line_number` is kept but unflagged** — 1 on 100% of rows (the V5.1.7 rule), yet
  it is half the alternate key and becomes essential with multi-line transactions.
- **`sv_sales_item` has no currency column.** An item amount is a bare number, so
  `AVG(unit_price)` by SKU silently averages 27 currencies. Any price-variance
  baseline (which V5.1.8 already required from the fact) must be computed per
  `(sku_code, currency)` — requiring the header join.
- **Formula checks use a 0.005 tolerance** rather than exact equality. These are
  `NUMBER` columns so exact would work today, but the tolerance costs nothing,
  survives a future float-delivering source, and stays tighter than half a cent so
  it cannot mask a real rounding error.
- **1,205 zero-tax rows** match exactly between header and item and are legitimate
  zero-rate jurisdictions (V5.1.3) — not flagged.
