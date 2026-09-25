# AGENT.md — orientation for a new session

Read this first. It maps the repository, records the rules that govern it, and
points at the documents that hold the detail. It is a **router**, not a copy: the
authoritative reasoning lives in the files it links to, and this file should stay
short enough to read in full before touching anything.

**Project:** Apple Inc sales analytics on Snowflake — a medallion architecture
(bronze → silver → gold) managed entirely through
[schemachange](https://github.com/Snowflake-Labs/schemachange).

---

## 1. Standing rules — do not violate without being asked

| # | Rule |
|---|---|
| 1 | **Commit and push to `dev_branch` only.** Never push to `main` or `qa_branch`. Promotion happens by PR: `dev_branch → qa_branch → main`. |
| 2 | **`CREATE ... IF NOT EXISTS`, never `CREATE OR REPLACE`** and never destructive DDL. One documented exception: the gold semantic view — reasoning in `schemachange/scripts/06_gold/README.md`. |
| 3 | **Tags, masking policies and all governance objects live only in the `GOVERNANCE` database.** Environment databases *attach* them; they never define them. |
| 4 | **Dev and QA objects are `TRANSIENT`** (no fail-safe cost). Driven by the `object_type` var, empty in prod. Never hard-code `TRANSIENT` in a script. |
| 5 | **Every object gets a short, meaningful `COMMENT`.** |
| 6 | **Data-storing objects carry chargeback tags** (`MEDALLION_LAYER`, plus DB-level inherited tags). |
| 7 | **Bronze → silver movement uses dynamic tables only** — never `INSERT`, `MERGE`, or a task-driven procedure. |
| 8 | **Never hard-code a database name in a script.** Use the Jinja vars in §4. |

---

## 2. Where everything is

```
cortex/
├── AGENT.md                    <- you are here
├── SKILL.md                    root skill definition
├── customer_nagur_skill_testing/SKILL.md
├── plans/                      session summaries (see §7)
├── results/                    ad-hoc query output as CSV, not authoritative
├── sql/                        one-off scratch SQL, superseded by schemachange
├── schemachange/               ALL managed DDL — the source of truth
└── schema_evolution_or_drift{,_json,_parquet}/   standalone demos (see §8)
```

### Documents to read, in priority order

| Document | Why it matters |
|---|---|
| `schemachange/README.md` | Deployment mechanics, naming convention, env var matrix, promotion flow. **Read before writing any script.** |
| `schemachange/scripts/05_silver/README.md` | **The single most valuable file in the repo.** Every DQ convention, every data defect, every rejected rule, and all carry-forward items for gold. |
| `schemachange/scripts/04_bronze/README.md` | Bronze loading approach, `INFER_SCHEMA` usage, metadata columns. |
| `schemachange/scripts/08_data_quality/README.md` | **Read before adding any DQ check.** Why DQ is hand-rolled rather than DMF-based, the documented exception to DQ rule 4, and why the check task is not resumed. |
| `schemachange/scripts/06_gold/README.md` | Gold rules and reserved version range. Scaffold — this is the next build. |
| `schemachange/scripts/07_orchestration/README.md` | Ingest task / stage stream design. Scaffold. |
| `plans/2026-09-19-session-summary.md` | Earlier session narrative. Historical — trust the script headers over it where they disagree. |

`01_governance/`, `02_foundation/` and `03_common/` have **no README**; their
scripts are short and self-documenting.

### ⚠️ There is no `data_quality_docs/` folder

It does not exist in this repository, and no file matching `*qual*`, `*dq*` or
`*doc*` does either. **Do not go looking for it.** The data-quality requirements
live in three places instead, and all are richer than a separate folder would be:

1. **`schemachange/scripts/05_silver/README.md`** — the consolidated layer-wide
   view: conventions, the defect register, and what each one blocks downstream.
2. **The header comment block of each `05_silver/V5.1.*.sql` script** — per-table
   reasoning. These headers are long on purpose. They record not just what each
   DQ flag does but **which candidate rules were tested and rejected, and why**,
   so a future session does not re-implement a rule that was already disproved.
3. **`schemachange/scripts/08_data_quality/`** — the *executable* checks, as
   distinct from 1 and 2 which document the row-level flags built into silver.
   This is where set-level assertions live (FK existence, bronze↔silver parity),
   per DQ rule 3.

If a `data_quality_docs/` folder is genuinely wanted as a separate artefact, it
would need to be created and populated — say so rather than assuming it exists.

---

## 3. Current state

**Silver is complete. Gold is in progress — country and product dimensions built.**

| Layer | Folder | State |
|---|---|---|
| Governance | `01_governance/` V1.x | Done — `GOVERNANCE` DB, `TAGS` + `SCHEMACHANGE` schemas, 4 tags |
| Foundation | `02_foundation/` V2.x | Done — `SALES_DEV` + 4 schemas, tags attached |
| Common | `03_common/` V3.x | Done — 2 CSV file formats, 6 sequences (**note:** `V3.1.2` is an intentional gap) |
| Bronze | `04_bronze/` V4.x | Done — internal stage, 47 staged files, **13 tables loaded** |
| Silver | `05_silver/` V5.x | **Done — 13 dynamic tables, all INCREMENTAL, all verified** |
| Gold | `06_gold/` V6.x | **In progress — `dim_country` (35, SCD-2), `dim_product` (650, SCD-1), `bridge_product_country` (22,750), `dim_store` (121, SCD-1), `dim_customer` (31,350, SCD-1, **unmasked PII**), `dim_date` (31,411, **regular table**)** |
| Orchestration | `07_orchestration/` V7.x | Scaffold only |
| Data quality | `08_data_quality/` V8.x | **Done for silver — 31 checks, task created SUSPENDED** |

Only the **DEV** context (`SALES_DEV`) exists. QA and prod are not built.

### Bronze script numbering — easy to get wrong

Verify against the filesystem before citing one. The order is **not** the order
the silver scripts were built in:

| Scripts | Domain |
|---|---|
| `V4.1.1` | stage |
| `V4.2.1` / `V4.2.2` | country master |
| `V4.3.1` / `V4.3.2` | **customer** master |
| `V4.4.1` / `V4.4.2` | **product** master |
| `V4.5.1` / `V4.5.2` | **store** master |
| `V4.6.1` / `V4.6.2` | sales transaction |

### The 13 silver tables

All are `sv_*` dynamic tables in `SALES_DEV.SILVER`, all `TARGET_LAG = DOWNSTREAM`,
`REFRESH_MODE = INCREMENTAL` (verified, not just requested), `WAREHOUSE = COMPUTE_WH`,
tagged `MEDALLION_LAYER = 'SILVER'`, **zero Snowflake recommendations across the
whole layer**.

| Script | Table | Rows | DQ flagged |
|---|---|---|---|
| `V5.1.1` | `sv_region_master` | 5 | 0 |
| `V5.1.2` | `sv_currency_master` | 27 | 0 |
| `V5.1.3` | `sv_tax_master` | 35 | 0 |
| `V5.1.4` | `sv_country_master` | 35 | 1 |
| `V5.1.5` | `sv_product_category_master` | 10 | 0 |
| `V5.1.6` | `sv_product_family_master` | 43 | 0 |
| `V5.1.7` | `sv_product_model_master` | 111 | 0 |
| `V5.1.8` | `sv_product_sku_master` | 650 | 0 |
| `V5.1.9` | `sv_product_country_availability` | 22,750 | 0 |
| `V5.1.10` | `sv_customer_master` | 31,350 | **24,713** |
| `V5.1.11` | `sv_store_master` | 121 | 0 |
| `V5.1.12` | `sv_sales_header` | 77,155 | 0 |
| `V5.1.13` | `sv_sales_item` | 77,155 | 0 |

---

## 4. Conventions a new script must follow

**Jinja vars** available in every script (values shown for dev):

| Var | Dev value |
|---|---|
| `{{ database }}` | `SALES_DEV` |
| `{{ governance_database }}` | `GOVERNANCE` |
| `{{ warehouse }}` | `COMPUTE_WH` |
| `{{ object_type }}` | `TRANSIENT` (empty in prod) |
| `{{ env }}` | `DEV` |
| `{{ retention_days }}`, `{{ cost_center }}`, `{{ chargeback_owner }}` | see config |

**File naming:** `V<version>__<description>.sql`, **two** underscores, version
unique across the whole project. Each folder owns a reserved range. `R__` =
repeatable, `A__` = always. Anything else is ignored by schemachange — which is
how `README.md` and `_reference__*.sql` (client-side `PUT` commands, never
executed) live safely alongside migrations.

**Script shape** — follow any `05_silver/V5.1.*.sql`:
1. Long header comment: entity domain, findings, decisions **and rejected
   alternatives with the measurement that killed them**.
2. The `CREATE ... IF NOT EXISTS` statement.
3. `ALTER ... SET TAG` for `MEDALLION_LAYER`.
4. A `VALIDATION` block of read-only queries, each with its **recorded result**
   inline as a comment. This is what makes the work re-verifiable.

---

## 5. Dynamic-table rules learned the hard way

These were all discovered by breaking something. Full reasoning in
`05_silver/README.md`.

- **De-duplicate with `QUALIFY ROW_NUMBER()`** — never `DISTINCT` or `GROUP BY`,
  which are only partially incremental and risk forcing FULL refresh. Keep
  `QUALIFY` top-level and put the partition key in the SELECT list.
- **Partition on `(business_key, version_discriminator)`, NOT the key alone.**
  Superseded the original "one row per business key" rule in `V5.2.1`/`V5.2.2`.
  Keying on the business key alone cannot tell a **true duplicate** (same record
  redelivered) from a **new version** (same key, changed attributes) — it
  collapses both, destroying the change before gold can build SCD-2.
  **All 13 tables are now version-preserving**, in two styles dictated by what
  each source provides:

  | Tables | Discriminator | Currency expressed as |
  |---|---|---|
  | 6 masters (`V5.2.1`) | `effective_start_date` | derived downstream from `MAX(valid_from)` |
  | `sv_customer_master` (`V5.2.1`) | `updated_at` | derived downstream via `LEAD` |
  | 4 product + 2 facts (`V5.2.2`) | `__version_hash` (content) | materialised `__is_current_version` |

  Do **not** "harmonise" this by adding the flag to the temporal tables —
  `valid_from` ordering is strictly more informative. The content-hash tables get
  the flag only because they have no temporal ordering to derive it from, and an
  `A→B→A` change collapses to two rows there, not three.
- **⚠ Fact aggregates MUST filter `__is_current_version = TRUE`.** `sv_sales_header`
  and `sv_sales_item` now preserve corrected transactions as new versions.
  `SUM(line_total)` without the filter double-counts a correction. This is
  **invisible today** — every key has one version, so both forms return
  `50,186,627.97`. It starts being silently wrong when the first correction lands.
  Guarded by `hdr_sk_unique` / `item_line_unique`, which now assert *exactly one
  current version per key* rather than one row per key.
- **`CREATE OR ALTER` cannot reorder columns** — new ones must be appended after
  all existing columns, and it **does not re-materialise them**. A
  `TARGET_LAG = DOWNSTREAM` table with no consumer has `scheduling_state = OFF`,
  so an added column stays NULL until an explicit
  `ALTER DYNAMIC TABLE … REFRESH`. Cost an hour on `V5.2.2` — `__version_hash` was
  NULL on all 77,155 rows after a "successful" alter.
- **`QUALIFY ROW_NUMBER()` is also what makes Snowflake derive a PRIMARY KEY**
  on the partition columns (`SYS_CONSTRAINT_DERIVED_PK`, `rely = true`). Removing
  it silently removes the key. See `06_gold/README.md`.
- **The `QUALIFY` partition expression must match the projection's exactly.**
  Mismatch means de-duplicating on a different grain than you return.
- **Make survivor ordering deterministic**, ending in
  `(__file_name, __row_number)`. Lead with `updated_at` if the table has one
  (only `br_customer_master` does).
- **No non-deterministic function anywhere in the definition** — including
  *inside* an `IFF`. `CURRENT_TIMESTAMP()` / `CURRENT_DATE()` / `RANDOM()` force
  FULL refresh. This is why there is no `__silver_loaded_at` column and why all
  plausibility bounds are **static literals** (`1976`, `2035`, `'1900-01-01'`).
- **`SEQ*()` sequences do not work in dynamic tables at all.** The 6 sequences
  from `V3.1.3` are unusable in gold — use hash keys (`SHA1_HEX`) instead.
- **Always verify `REFRESH_MODE` actually came back `INCREMENTAL`** after
  creating **and after every `CREATE OR ALTER`**. Requesting it is not the same as
  getting it; check `refresh_mode` + `refresh_mode_reason` in
  `SHOW DYNAMIC TABLES` and `refresh_action` in
  `DYNAMIC_TABLE_REFRESH_HISTORY`. Altering a definition is exactly when this can
  silently regress — adding a window function is a plausible way to lose
  incremental — and it was missed once on `dim_country` after `V6.1.2`.
- **`REINITIALIZE` is NOT `FULL` — and Snowsight labels it "Full refresh".**
  After a definition change, the first refresh is a one-off
  `refresh_action = REINITIALIZE` that discards and rebuilds, because the existing
  materialisation no longer matches the new query. Its statistics read
  `deleted 35, inserted 35` (delete-all-then-insert-all), and **Snowsight's
  refresh-history / monitoring page renders this as "Full refresh"**. That display
  is about the *action*, not the *mode*:

  | | Meaning |
  |---|---|
  | `refresh_mode = FULL` | **every** refresh reprocesses everything, forever — a cost problem |
  | `refresh_action = REINITIALIZE` | **one** rebuild after a definition change, then incremental resumes |

  Confirm via SQL, not the UI: `SHOW DYNAMIC TABLES` gives `refresh_mode` and
  `refresh_mode_reason`. Then refresh again — an `INCREMENTAL` table with no
  upstream change returns `No new data` and does no work; a `FULL` table
  reprocesses regardless.

  **⚠ The misleading label is sticky here.** Every DT in this repo is
  `TARGET_LAG = DOWNSTREAM`, and with no gold consumer and no `V7.x` ingest,
  `scheduling_state = OFF` — so no further refresh occurs on its own and the
  `REINITIALIZE` entry stays the most recent one **indefinitely**. Snowsight will
  keep showing "Full refresh" until gold gains a consumer or the ingest task runs.
  This has already prompted the question twice. Do not "fix" it by recreating the
  table or switching refresh modes; verify in SQL and move on.
  `V5.2.1`, `V5.2.2` and `V6.1.2` each produced one, and all **18** dynamic tables
  (13 silver + 5 gold) remain `INCREMENTAL` with `refresh_mode_reason = NULL`.
- **A dynamic table must have at least one base table — so a calendar cannot be
  one.** Measured: `CREATE DYNAMIC TABLE ... FROM TABLE(GENERATOR(...))` fails with
  `Dynamic Tables must have at least one base table`. `GOLD.dim_date` is therefore
  the **one regular table in gold**, and that is forced, not a preference. Do not
  "fix" it by giving it a base table: the only candidate is `sv_sales_header`,
  which would bound the calendar to the **366** sales days *and* falsely assert
  that the calendar depends on sales data.

  Two corollaries worth holding on to:
  - **Lineage to a fact comes from the fact joining the dimension**, not from the
    dimension reading the fact. `dim_date → fact_sales` is the edge you want, and
    a regular table upstream of a DT renders fine — bronze → silver is already
    exactly that pattern. `V6.2.1` must therefore **join** `dim_date` rather than
    computing `date_key` arithmetically, and must use a **`LEFT JOIN`** so an
    out-of-range date surfaces as NULL instead of vanishing.
  - **A statically populated table must contain no relative flags.**
    `is_current_month` and friends would be evaluated once at load time and be
    silently wrong forever. Same non-determinism that forces `FULL` refresh in a
    DT, wearing a different hat.
- **`dim_date` does not contain `9999-12-31` — never join `valid_to` to it.**
  `dim_country.valid_to` uses that sentinel for the current version. Joining it to
  `dim_date` drops **every current row** and returns a clean-looking result. Only
  ever join `valid_from`. Verified: `SELECT COUNT(*) ... WHERE full_date =
  '9999-12-31'` returns 0, by design.
- **Use the ISO date parts, not the plain ones.** `DAYOFWEEK`, `WEEK` and
  `YEAROFWEEK` depend on the session parameters `WEEK_START` and
  `WEEK_OF_YEAR_POLICY`, so two users can read different values from the same row.
  `dim_date` exposes `DAYOFWEEKISO` / `WEEKISO` / `YEAROFWEEKISO` only. Consequence
  to respect: `2019-12-30` has `year_num = 2019` but `iso_year = 2020`, `iso_week = 1`
  — **never group by `iso_week` without also grouping by `iso_year`.**
- **`dim_date.fiscal_*` is an Oct–Sep approximation, not Apple's real calendar.**
  Apple uses a 52/53-week calendar ending the last Saturday of September (FY2019
  was 2018-09-30 → 2019-09-28). Measured divergence: `2019-09-30` is FY2019 Q4 in
  `dim_date` but FY2020 Q1 in reality. Fine for internal grouping; **never
  reconcile against published Apple financials.** Unrelated to
  `dim_country.apple_fiscal_segment`, which is geographic.
- **No streams on bronze tables** — DTs manage their own change tracking, so a
  stream is redundant and forces extended retention.
- **Before treating ANY source date as SCD-2 validity, measure two things.** This
  has now cost three separate designs, so it is a rule, not an anecdote. Most
  "effective date" columns in this source are **load artifacts**, not business
  dates, and they postdate the 2019 facts — so using them as validity produces a
  clean, confident, **empty** answer rather than an error.

  | Source column | Distinct values | Fact join **with** the window |
  |---|---|---|
  | `sv_tax_master.effective_start_date` | 1 (`2020-01-01`) | 24 of 77,155 rows |
  | `sv_store_master.effective_start_date` | **1** (`2026-04-17`) | **0** of 61,804 |
  | `sv_customer_master.updated_at` | 31,350, all in a **5-second window** | **0** of 77,155 |

  The two checks, always in this order:
  1. `COUNT(DISTINCT <date>)` — one value, or a span of seconds, means a load stamp.
  2. Join the fact **with** the validity predicate and compare to joining without it.
     A collapse to 0 is decisive.

  Note the customer case: `updated_at` is unique per row, so it is a perfectly
  valid **version discriminator** (V5.2.1 relies on it) while still being useless
  as **validity**. Those are two different jobs — do not infer one from the other.
  Only `sv_country_master.effective_start_date` has survived both checks, which is
  why `dim_country` is the single SCD-2 dimension. Where the check fails, build
  SCD-1, rename the column to `load_*` so it cannot be mistaken for validity, and
  record the measured zero in its comment.

---

## 6. DQ philosophy — the rules that decide whether a flag exists

Applied consistently across all 13 tables. Following them keeps gold coherent;
ignoring them produces flags nobody trusts.

1. **Hard-reject only what is unusable *as a key*** (null/blank business key).
   Everything else is flagged, never dropped. Deleting a fact to fix a dimension
   attribute is never the right trade.
2. **A flag that fires on 100% (or 0%) of rows is a bug, not a check.** It
   carries no information and trains readers to ignore the column. Assert
   uniformity in validation instead, so a future change shows up as a shifted
   number.
3. **Row-level flags describe only their own row.** Anything needing a second
   table — FK existence, cross-level date coherence, childless-parent coverage —
   is a **set-level assertion** for validation SQL or gold, never a flag. A join
   in a DT couples its refresh to the joined table.
4. **No allow-lists on business categorisations.** A new segment, tier, format or
   payment method is a *business change*, not a defect. NULL is the defect;
   unfamiliar is news. **Scoped exception:** this forbids an allow-list as a
   *row-level flag inside a dynamic table*. `08_data_quality/V8.1.2` asserts
   accepted values as *set-level monitoring* on `channel_id`, `payment_method`,
   `loyalty_tier` and `customer_segment` — it rejects no row, writes no flag, and
   delivers the "news" rather than labelling a defect. Reasoning in that script's
   header. **Do not migrate those back into a silver flag expression.**
5. **Nullability does not decide whether a flag belongs — semantics do.** For a
   *measure*, absent is always wrong. For an *open-ended date*, absent is a
   legitimate state.
6. **Test a candidate rule before implementing it, and record the ones you
   reject.** Several plausible rules were killed by measurement (§7). A rule with
   an 11-in-12 false-positive rate is worse than no rule.
7. **Prefer a visibly messy value over an invisibly wrong one.** Never "fix" data
   in a way that produces a plausible-looking but incorrect result.
8. **Drop denormalised columns only when provably redundant** — measure
   0 mismatches first — and prove recoverability in validation. Bronze stays the
   faithful record.

---

## 7. The defect register — read before building gold

Every item is measured, not assumed. Detail in `05_silver/README.md` and the
relevant script header.

### Blocking issues

| Issue | Impact |
|---|---|
| **All amounts are USD-scaled regardless of currency** | Every one of the 27 currencies averages 620–780 `net_total`. Affects **all 77,155 rows**, not just the 8,471 JPY/KRW rows where `minor_unit = 0` makes it detectable. **Do not `ROUND()`** — it yields a type-correct value still wrong by ~150× and destroys the evidence. |
| **No FX-rate dimension exists** | Cross-currency `SUM(net_total)` runs cleanly and returns a confident, meaningless number. Gold must stay single-currency until one is built. |
| **`sv_tax_master` is not time-variant** | One row per country, so it cannot express a rate change. Recomputing 2019 tax fails on 5 countries / 5,609 rows — four are real post-2019 rate rises. **The transaction's `total_tax` is authoritative.** Never recompute historical tax from the master. |
| **Header and item measures are identical (1:1)** | Both total **50,186,627.97**. A naive join summing both returns exactly double **while the row count stays correct**. Build revenue from `sv_sales_item` (lower grain). |
| **No masking policies exist** | `sv_customer_master` has 9 fully-populated personal-data columns; 1,051 customers are in GDPR countries. Policies belong in `GOVERNANCE` (rule 3) and must be *attached* in silver. **Widened by `V6.1.6`: `GOLD.dim_customer` now re-exposes all 9 columns unmasked, so the same data is readable in two schemas.** Carrying them was an explicit decision (the alternatives — an analytics-only dimension, or a `DATA_SENSITIVITY` tag — are recorded in the `V6.1.6` header), so attaching a policy must now cover **both** `SILVER.sv_customer_master` and `GOLD.dim_customer`. |

### Data defects to carry forward

| Defect | Detail |
|---|---|
| **38,102 sales rows predate their store's opening** | 61.6% of store-attributed rows; 67 of 121 stores open after the 2019 sales period. Belongs in **gold** (needs a join, per DQ rule 3). Must compare against **each store's own** open date, never a hard-coded year. |
| **3,515 customers were minors at registration** | 698 under 13 (COPPA), 1,051 minors in GDPR countries, youngest **11**. Needs a governance decision, not a data fix. |
| **`UK` is not valid ISO 3166-1 alpha-2** | Should be `GB`. Flagged not rejected — 2,400 customers, 5,862 sales and 8 stores depend on it. |
| **24 sales rows timestamped 2020-01-01** | Timezone spillover. **RESOLVED by `V6.1.7`** — `dim_date` spans 1950-01-01 → 2035-12-31, and a zero-miss coverage check confirms all 77,155 sales dates resolve. Still relevant to any *hard-coded* 2019 filter, which would silently drop these 24 rows. |
| **1,056 shared email addresses** | 1,006 belong to *different people*; zero true duplicate persons. **Never use email as an identity key.** |
| **`phone_number` has 4 incompatible formats** | 76.2% non-E.164. No digits-only variant was derived: 6,660 values carry extensions that stripping would fuse onto the subscriber number. |
| **`sv_product_country_availability` cannot filter** | Complete 650×35 cartesian, `is_available` TRUE everywhere. Joining it to restrict to "available products" removes zero rows; any effect is fan-out. |
| **`sv_product_sku_master` has no price** | `price_tier` is an ordinal band. Price-variance baselines must come from the **fact**, per `(sku_code, currency)`. |

### Traps that look like bugs but are not

| Looks wrong | Actually correct |
|---|---|
| `tax_jurisdiction_code` orphans all 121 stores | It is **fully derivable** from `country_code` + `state_code` and was never meant to be joined. Resolve tax via `store → sv_country_master.tax_code → sv_tax_master`. No country has >1 tax code, so **no fan-out and no mapping table needed**. |
| `local_part_number` reused across 2,600 values | Apple part numbers are **region**-scoped. Never crosses a SKU or a region. |
| Only 4 product reporting segments | Services has no physical SKU. Do **not** reconcile against `sv_country_master.apple_fiscal_segment` (5 *geographic* values) — same name, unrelated meaning. |
| `effective_start_date` on stores | A **load date** (one value, 2026-04-17), not a business date. Filtering 2019 sales on it returns **zero stores**. Use `store_open_date`. |
| `effective_end_date = 9999-12-31` | An intentional, *functional* SCD sentinel — preserved deliberately. Unlike the `'None'` string in `loyalty_tier`, which was a serialisation accident and *was* rewritten to NULL. |
| `discontinue_date` NULL on all 111 models | Open-ended = still sold. Agrees with `lifecycle_status`. |
| NULL `store_id` on 15,351 sales rows | Exactly the ONLINE channel. An exact partition with `channel_id`. |
| NULL `state_code` on 39 stores | Those countries do not subdivide for tax. |

### Rejected rules — do not re-implement

| Rule | Why it was killed |
|---|---|
| `country_code <> LEFT(iso_alpha3,2)` | 12 hits, **11 valid ISO pairs**. Replaced by an explicit exception list. |
| `ROUND()` JPY/KRW to `minor_unit` | Hides a ~150× scale error behind a type-correct value. |
| Flagging only the 8,471 detectable currency rows | Would assert the other 68,684 are sound. |
| Rent-per-sqft plausibility band | Prime Apple retail genuinely reaches USD 2,000–3,000/sqft; any useful threshold flags real flagships. |
| `REGEXP_REPLACE` phone to digits | Fuses extensions onto subscriber numbers. |
| Allow-lists on segment / tier / format / lifecycle | Business changes, not defects. **Still rejected as silver row-level flags.** Permitted as set-level monitoring in `08_data_quality/V8.1.2` — see DQ rule 4's scoped exception. |
| `YEAR(CURRENT_DATE())` plausibility bounds | Non-deterministic → forces FULL refresh. |
| **Data Metric Functions for the DQ checks** | Snowflake's native Data Quality Monitoring is **Enterprise Edition**; this account is `STANDARD`. Measured: `SELECT edition FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS WHERE account_locator = CURRENT_ACCOUNT()` → `STANDARD`. Every DMF statement fails with `Unsupported feature 'DATA METRIC FUNCTION'`, as do `SHOW DATA METRIC FUNCTIONS` and `SYSTEM$DATA_METRIC_SCAN`. Hence `08_data_quality` is hand-rolled SQL. **If the account is ever upgraded, replace most of V8.1.2/V8.1.3 with DMF associations** — the mapping is in that folder's README. |
| **SCD-2 inside a dynamic table** | **Partly reversed by `V5.2.1` + `V6.1.2` — read this before repeating the old claim.** A DT still cannot *generate* history: it cannot self-reference to close a prior version, and `CURRENT_DATE` in the SELECT list is banned by §5. But that was never the real blocker — silver was *discarding* the prior version as a duplicate, so there was no second row to close an interval against. With silver preserving versions, closing intervals is a pure window function: `valid_to = COALESCE(LEAD(valid_from) OVER (PARTITION BY key ORDER BY valid_from) - 1, effective_end_date)` and `is_current = valid_from = MAX(valid_from) OVER (PARTITION BY key)`. Both are INCREMENTAL-safe, and `dim_country` now does genuine SCD-2. A procedure-maintained table is only needed if you must stamp change-detection times the source does not supply. |
| **`CREATE OR REPLACE` to change a dynamic-table definition** | Use **`CREATE OR ALTER DYNAMIC TABLE`** — declarative, idempotent and **non-destructive**: verified that `created_on` survived the `V5.2.1` alter, so grants and object identity are preserved. Second documented exception to note 5, and narrower than the semantic view since nothing is dropped. |
| **Declared PK/FK on a dynamic table** | `CREATE DYNAMIC TABLE` has no constraint clause and `ALTER DYNAMIC TABLE` has no `ADD CONSTRAINT`. **But** `QUALIFY ROW_NUMBER() OVER (PARTITION BY <grain>) = 1` makes Snowflake derive a real `SYS_CONSTRAINT_DERIVED_PK` with `rely = true` — verified on `dim_country` via `SHOW UNIQUE KEYS`. So the `QUALIFY` is the constraint mechanism, not just de-duplication; removing it removes the PK. |
| **Intersecting all four source validity intervals in `dim_country`** | Textbook SCD-2 conformance, catastrophic here. `sv_tax_master.effective_start_date` is `2020-01-01` on all 35 rows but the sales data is 2019, so `GREATEST()` pushes every `valid_from` past the entire fact period. Measured: country-driven validity joins **77,155 of 77,155** sales rows; intersecting all four joins **24** — and those 24 are exactly the timezone-spillover rows below. A 99.97% silent loss that returns a clean, nearly-empty answer. |
| `HASH()` for gold surrogate keys | Superseded by `SHA1_HEX`. `HASH()` returns a signed 64-bit number — non-trivial collision probability as dimensions grow, and no cross-version stability contract. An early revision of `06_gold/README.md` recommended it; now reconciled. |

---

## 8. Other things in this repo

**`schema_evolution_or_drift/`, `_json/`, `_parquet/`** — three self-contained
demonstrations of schema drift (additive, subtractive, type) using Store Master
data in CSV, JSON and Parquet. Each has a `README.md` and a `COMPLETE_FLOW.sql`
explaining the column-splitting mechanics for that format. They target
`ANALYSIS_DB` and are **independent of the medallion pipeline** — do not wire
them into it. Two findings worth knowing: `INFER_SCHEMA` widens types from small
samples, and Parquet `INFER_SCHEMA` disagrees with `TYPEOF`.

**`results/`** — CSV exports from ad-hoc queries. Snapshots, not authoritative.

**`sql/01_sales_dev_foundation.sql`** — pre-schemachange scratch work,
superseded. Do not extend it; add a versioned script instead.

---

## 9. Environment

- **Snowflake connection:** `ysirciu-vg28332` (OAuth). User `NAGUR`, role
  `ACCOUNTADMIN`.
- **Edition: `STANDARD`.** This rules out Data Quality Monitoring / DMFs, and is
  why `08_data_quality` is hand-rolled. Check before assuming any Enterprise
  feature is available.
- **Warehouses:** `COMPUTE_WH` only. **`WH_DT_XS` does not exist** despite
  earlier notes claiming it — all silver DTs run on `COMPUTE_WH`, whose
  `AUTO_SUSPEND` is 600 s and could reasonably be lowered.
- **Databases:** `GOVERNANCE` (permanent), `SALES_DEV` (transient), `ANALYSIS_DB`
  (drift demos).
- **Git:** `git@github.com:9160748607/cortex.git`, local clone
  `C:\Users\X1Carbon\cortex`, SSH configured. Shell is **Windows PowerShell** —
  chain with `;` not `&&`, and note `git push` writes to stderr, which PowerShell
  surfaces as an error even on success.

### Known outstanding items

| Item | Detail |
|---|---|
| **`CHANGE_HISTORY_DEV` is empty** | Everything was deployed by executing rendered SQL directly, because the OAuth browser flow cannot complete unattended. Re-run `schemachange deploy` interactively to populate it. All scripts are `IF NOT EXISTS`, so re-applying is harmless. **Do this before the QA promotion.** |
| Masking policies | Not written. See §7. |
| FX-rate dimension | Not modelled. Blocks cross-currency revenue. |
| Type-2 `sv_tax_master` | Needed for historical tax. |
| QA and prod contexts | Not created. |
| `COMPUTE_WH` `AUTO_SUSPEND` | 600 s; 60 s would suit DT refreshes better. |
| **DQ check task is SUSPENDED** | `SALES_DEV.COMMON.t_silver_dq_checks`. Do not resume until V7.x ingest runs or gold exists — until then the silver DTs have `TARGET_LAG = DOWNSTREAM` with no consumer and `scheduling_state = OFF`, so they never refresh and every run records 31 identical rows. `V8.2.1__resume_dq_check_task.sql` is **reserved and intentionally unwritten** so a deploy cannot start it silently. |
| **DQ email delivery unverified** | `silver_dq_email_DEV` exists, but `SYSTEM$SEND_EMAIL` only fires on failure and nothing has failed, so the path has never run. The recipient must be a **verified** address on an account user. If it is not, `dq_results` records the failure while nobody is told — a silent-monitor failure mode. Verify before resuming the task. |
| **DQ flag thresholds are DEV baselines** | The `<=` thresholds in `V8.1.2` are the measured 2019-dataset counts (24,713 / 23,874 / 3,515 / 698). QA and prod need their own baselines before the task is resumed there. |
| **`$$` body vs schemachange splitting** | `V8.1.3`'s procedure body is a `$$` block containing semicolons. `07_orchestration/README.md` notes schemachange splits on semicolons client-side. Whether this breaks `schemachange deploy` is **unmeasured** — dev was applied by executing rendered SQL directly. Resolve alongside the `CHANGE_HISTORY_DEV` item, before the QA promotion. |

---

## 10. Working agreement

- **Measure before asserting.** Every number in the script headers and in §7 came
  from a query. Do not restate a claim from memory or from `plans/` without
  re-checking it — several earlier notes turned out to be wrong (the `WH_DT_XS`
  warehouse, the tax fan-out claim, the `ROUND()` advice, the bronze script
  numbers in §3).
- **Record rejected alternatives, not just decisions.** That is what stops the
  next session re-litigating settled questions.
- **Update the folder README and this file when state changes.** A stale pointer
  is worse than no pointer.
- **Verify, then report.** For a dynamic table that means: `refresh_action`
  is `INCREMENTAL`, recommendations are empty, row counts reconcile to bronze,
  keys are unique, FKs have zero orphans, and the flag distribution is only what
  you expect.
