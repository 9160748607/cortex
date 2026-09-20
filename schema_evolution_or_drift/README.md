# Schema Drift & Schema Evolution — Store Master

End-to-end demonstration of **schema drift detection** and **Snowflake schema evolution**, from source files on disk through to a unified loaded table.

**Target:** `ANALYSIS_DB.DATA_MIGRATION.STORE_MASTER`
**Source:** `C:\Users\X1Carbon\Music\store-master-testing` (4 CSVs, never modified)

All **three** categories of drift are demonstrated against one target table:

| Category | File | Outcome | Evolution handles it? |
|---|---|---|---|
| **Additive** | `store_master_1.csv` | Table grows 26 → 27 columns | **Yes** |
| **Subtractive** | `..._deleted_columns.csv` | Load succeeds, 6 columns silently NULLed | **No** |
| **Type** | `..._datatypechange...csv` | **Load rejected outright** | **No** |

```
Source files → Schema detection → Drift identification → Schema evolution → Unified target → Load → Validation
```

## Run order

| # | Script | Purpose |
|---|---|---|
| — | `cli/upload_to_stage.ps1` | PUT all 4 CSVs to the internal stage |
| 01 | `sql/01_create_objects.sql` | Database, schema, 3 file formats, stage |
| 02 | `sql/02_schema_detection.sql` | `INFER_SCHEMA` **per file**, type-conversion probes |
| 03 | `sql/03_drift_analysis.sql` | Reusable two-file schema diff + recorded findings |
| 04 | `sql/04_create_target_table.sql` | Target with `ENABLE_SCHEMA_EVOLUTION = TRUE` |
| 05 | `sql/05_load_file1_baseline.sql` | Load file 1 — no drift |
| 06 | `sql/06_load_file2_additive_evolution.sql` | Load file 2 — **evolution fires** |
| 07 | `sql/07_load_file3_subtractive_drift.sql` | Load file 3 — **no evolution, silent degradation** |
| 08 | `sql/08_validation.sql` | Structure, counts, NULL matrix, samples |
| 09 | `sql/09_drift_detection_guard.sql` | Pre-load gate (run *before* each COPY) — **use 9.5** |
| 10 | `sql/10_idempotent_merge_fix.sql` | MERGE + de-dup remediation — **not yet executed** |
| 11 | `sql/11_load_file4_type_drift.sql` | Load file 4 — **COPY rejected**, quarantine + MERGE |

Order matters: 01 → 02 → 03 → 04 → 05 → 06 → 07 → 11. Loads 05–07 and 11 must run in sequence, since each demonstrates a different state transition of the same table.

## Source schema comparison

| Column | File 1 `store_master.csv` | File 2 `store_master_1.csv` | File 3 `..._deleted_columns.csv` | File 4 `..._datatypechange...csv` |
|---|---|---|---|---|
| store_code, store_name, country_code, region_code, tax_jurisdiction_code | TEXT | TEXT | TEXT | TEXT |
| **format_code** | TEXT | TEXT | **absent** | TEXT |
| **city** | TEXT | TEXT | **absent** | TEXT |
| **state_code** | TEXT | TEXT | **absent** | TEXT |
| **postal_code** | **TEXT** | **NUMBER(5,0)** | **absent** | **NUMBER(5,0)** |
| **address_line1** | TEXT | TEXT | **absent** | TEXT |
| **latitude** | NUMBER(8,6) | NUMBER(8,6) | **absent** | NUMBER(8,6) |
| longitude | NUMBER(9,6) | NUMBER(9,6) | NUMBER(9,6) | NUMBER(9,6) |
| **store_open_date** | **DATE** | **TEXT** | **TEXT** | **TEXT** |
| store_close_date | TEXT (empty) | TEXT (empty) | TEXT (empty) | TEXT (empty) |
| lifecycle_status, annual_rent_usd, is_active | same | same | same | same |
| **floor_area_sqft** | **NUMBER(5,0)** | **NUMBER(5,0)** | **NUMBER(5,0)** | **TEXT** holds `testing` |
| **effective_start_date** | **DATE** | **TEXT** | **TEXT** | **TEXT** |
| **effective_end_date** | **DATE** | **TEXT** | **TEXT** | **TEXT** |
| **created_at** | **TIMESTAMP_NTZ** | **TEXT** | **TEXT** | **TEXT** |
| source_system | TEXT | TEXT | TEXT | TEXT |
| **Status** | **absent** | **BOOLEAN** | **BOOLEAN** | **BOOLEAN** |
| **Column count** | **22** | **23** | **17** | **23** |
| **Rows** | 121 | 5 | 5 | 5 |

## Drift analysis

Three independent kinds of drift are present, and **only one is solved by schema evolution.**

### A. Structural drift

| Direction | Where | Effect | Handled by evolution? |
|---|---|---|---|
| **Additive** | File 2 adds `Status` | Table grows 26 → 27 columns automatically | **Yes** |
| **Subtractive** | File 3 drops 6 columns | Table unchanged; values silently NULL | **No** |

File 4 has **no** structural drift — its column list is identical to file 2.

### A2. Type drift inside a column — file 4

| Column | Every prior file | File 4 | Result |
|---|---|---|---|
| `floor_area_sqft` | `NUMBER` | `TEXT` — `testing` on 2 of 5 rows | **COPY rejected** |

```
Numeric value 'testing' is not recognized
Row 1, column "STORE_MASTER"["FLOOR_AREA_SQFT":16]
```

Snowflake did **not** widen the column to accommodate the bad value. Evolution adds columns; it does not retype them. Verified after the failure: 131 rows, 29 columns, `FLOOR_AREA_SQFT` still `NUMBER`, **0 rows loaded** — `COPY` is atomic per file, so the 3 good rows did not slip in with the 2 bad ones.

This is the **least** insidious category precisely because it fails loudly. The two tempting shortcuts are both traps:

| Shortcut | Why it's wrong |
|---|---|
| `ON_ERROR = CONTINUE` | Loads 3 rows, silently discards 2 — converts a visible failure into invisible data loss |
| `ALTER … TO VARCHAR` | Surrenders numeric typing on 121 good rows to accommodate 2 bad values — lets corruption set the schema |

The implemented fix keeps the target strongly typed and loses nothing: **all-text landing → `TRY_TO_*` validation → good rows `MERGE`, bad rows quarantined with their raw value.**

### B. Type / representation drift — 5 shared columns

| Column | Drift | Cause |
|---|---|---|
| `postal_code` | TEXT → NUMBER | Leading zeros destroyed (`08759` → `8759`) |
| `store_open_date`, `effective_start_date`, `effective_end_date` | DATE → TEXT | Day-first `01-09-2017` vs ISO `2017-09-01` |
| `created_at` | TIMESTAMP_NTZ → TEXT | Value is `21:50.4` — time fragment, no date |

**Root cause:** Files 2 and 3 are Excel round-trips of File 1's rows (`US_0001…` reappear as `US_0101…`). One bad export explains all three symptoms — regional date reformatting, timestamp truncation, zip-as-number. **The real fix belongs at the export step;** everything here is damage limitation.

## Unified target design

Decisions that deliberately override `INFER_SCHEMA`:

| Column | Inferred | Declared | Why |
|---|---|---|---|
| `postal_code` | NUMBER(5,0) *(file 2)* | **VARCHAR(30)** | Non-negotiable — NUMBER destroys leading zeros across all 121 file 1 rows |
| `created_at` | TIMESTAMP_NTZ *(file 1)* | **VARCHAR(50)** | Files disagree irreconcilably; text lands both losslessly **and preserves the corruption as evidence** |
| `store_close_date` | TEXT | **DATE** | 100% empty, so inference had no values — not evidence it's a string |
| `floor_area_sqft` | NUMBER(5,0) | **NUMBER(10,0)** | Inferred cap 99,999 sqft |
| `annual_rent_usd` | NUMBER(8,0) | **NUMBER(14,2)** | Inferred cap ~100M; scale 0 would round cents |
| `latitude` / `longitude` | NUMBER(8,6) / (9,6) | **NUMBER(9,6) / (10,6)** | Inferred precision can't hold `-180.000000` |

Dates are kept as real `DATE` by giving **each file its own `DATE_FORMAT`**, rather than degrading the column to text.

The table is created from **file 1's 22 columns only**. `Status` is deliberately *not* pre-declared — the table must *learn* it from the data for evolution to be proven rather than asserted.

## Schema evolution mechanism

Three settings must all be present:

```sql
-- 1. on the table
ENABLE_SCHEMA_EVOLUTION = TRUE

-- 2. on the file format
PARSE_HEADER = TRUE
ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE   -- else the load fails before matching

-- 3. on the COPY
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
```

`MATCH_BY_COLUMN_NAME` binds by header **name**, not ordinal — which is also what fills absent columns with NULL automatically, with no `COALESCE` logic anywhere.

`INCLUDE_METADATA` is the **only** way to capture `METADATA$` columns here: the transformation form `COPY INTO … FROM (SELECT …)` cannot be combined with `MATCH_BY_COLUMN_NAME`.

## Results

| Load | File | Cols before → after | Rows | Evolution? |
|---|---|---|---|---|
| 1 | `store_master.csv` | 26 → 26 | 121 | No — file matches table |
| 2 | `store_master_1.csv` | **26 → 27** | 126 | **Yes — `STATUS BOOLEAN` added** |
| 3 | `..._deleted_columns.csv` | **29 → 29** | 131 | **No — 6 columns silently NULLed** |
| 4 | `..._datatypechange...csv` | **29 → 29** | **131 — rejected** | **No — COPY failed on type** |

Loads 1–3: zero errors. Load 4 rejected by design, then remediated via quarantine + `MERGE` (0 inserted, 6 updated, 2 quarantined).

Final state: **131 rows, 126 distinct keys, 29 columns, 2 quarantined rows.**

**NULL matrix** — the drift evidence:

| Source file | rows | format_code | city | state | postal | address | lat | lon | STATUS |
|---|---|---|---|---|---|---|---|---|---|
| `store_master.csv` | 121 | 0 | 0 | 39 | 0 | 0 | 0 | 0 | **121** |
| `store_master_1.csv` | 5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `..._deleted_columns.csv` | 5 | **5** | **5** | **5** | **5** | **5** | **5** | 0 | 0 |

`STATUS` nulls collapse 121 → 0 when the column appears; the six dropped columns spike 0 → 5 when it vanishes.

Date normalisation verified across both conventions: `01-09-2017` → `2017-09-01`, `22-06-2016` → `2016-06-22` (the `22` proves day-first was honoured — 22 is not a valid month). Leading zeros retained: `08759`, `02166`, `00158`.

## Known issues in the current loaded state

**1. Five duplicate business keys.** File 3 re-exports file 2's `US_0101`–`US_0105`, which were already loaded. COPY load history is keyed on **filename, not business key**, so a renamed re-export loads again. The table holds two rows per store — one complete, one degraded. `COUNT(*)` is overstated by 5. Fix: `10_idempotent_merge_fix.sql`.

**2. NULL provenance is ambiguous.** `state_code` has **44 NULLs** with two irreconcilable meanings: **39** genuine (non-US stores have no state) and **5** structural (column absent from the file). Indistinguishable in the data — only `__file_name` disambiguates, which is the whole justification for audit columns in a landing table.

**3. `__loaded_at` NULL for the first 126 rows.** A column `DEFAULT` is **not** applied by `COPY` under `MATCH_BY_COLUMN_NAME`, despite appearing in `INFORMATION_SCHEMA.COLUMN_DEFAULT`. Corrected from load 3 onward via `INCLUDE_METADATA = (__loaded_at = METADATA$START_SCAN_TIME)`.

**4. Evolved columns inherit precision from the file that introduced them.** A future-column test added `EMPLOYEE_COUNT` as `NUMBER(2,0)` — inferred from a 2-row sample, giving a ceiling of **99**. Evolution can silently install a type too narrow for real data. Evolved columns need a precision review; they are not free.

**5. The `9.3` type-drift guard over-reports — use `9.5` instead.** Comparing `INFER_SCHEMA`'s guess to the declared type ignores the file format's `DATE_FORMAT`, so on file 4 it flagged **five** "blocking" columns when only **one** was real (`FLOOR_AREA_SQFT`); the four date columns convert perfectly. A guard that cries wolf four times in five gets muted. `9.5` probes actual values with `TRY_TO_*` and returns exactly the one genuine failure.

**6. `MERGE` on file 4 reported 6 updated, not 3** — because issue 1 is unresolved and each key still has two rows. It *repaired* the degraded twins (back-filling `city`, `postal_code`, `latitude` that file 3 dropped), but the duplicates remain. Once de-duplicated, that count should read 3.

## Handling a future file with new columns

Demonstrated live, not theorised: a 25-column test file adding `manager_name` and `employee_count` was loaded with the **identical COPY** — no `ALTER TABLE`, no recreate. The table grew 27 → 29 columns, new rows populated them, all 126 existing rows got NULL, and prior data was untouched. The test rows were then deleted; **the columns persist** (evolution is not reversible by `DELETE`).

So the pipeline is **additively future-proof**. It will **not** automatically handle:

- **Renamed** columns — arrive as a new column while the old one silently goes NULL
- **Removed** columns — no error, no alert (this is file 3)
- **Narrowed precision** on an evolved column
- **Incompatible type changes** on an existing column — the load fails outright (this is file 4)

Those need the guard in `09_drift_detection_guard.sql` (section 9.5) and the quarantine pattern in `11_load_file4_type_drift.sql`, not evolution.

## Interview summary

> **Schema drift** is a *source-side* problem: two files that should be the same shape aren't. **Schema evolution** is the *target-side* response: Snowflake alters the table to absorb it.
>
> In Snowflake you get it with `ENABLE_SCHEMA_EVOLUTION = TRUE` plus `COPY … MATCH_BY_COLUMN_NAME`, which for CSV needs `PARSE_HEADER = TRUE` — and you must set `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE`, or the load fails before matching is even attempted. Match-by-name also NULL-fills columns a file omits.
>
> The trap is assuming evolution solves all drift. It is **additive-only**. Across four files I saw all three outcomes: it handled the added `Status` column perfectly; it did nothing for six *deleted* columns and the load succeeded silently; and when a numeric column arrived carrying the string `testing` it refused the load entirely rather than widening the column. Ranked by danger, the silent one is worst — additive drift announces itself by changing the table, type drift announces itself by failing, and subtractive drift announces nothing at all.
>
> And the harder drift here wasn't structural at all: it was in the 22 columns all files shared — one dated `2017-09-01`, another `01-09-2017`; one preserved zip `08759`, another turned it into `8759`; one had a real timestamp, another a corrupted `21:50.4`. No amount of evolution fixes that. It's resolved by per-file `DATE_FORMAT`, typing zips as VARCHAR, and deciding where to preserve raw text rather than destroy evidence.
>
> So: evolution buys **structural** tolerance. **Semantic** drift still needs an engineer — plus a drift *alert*, because a schema change that succeeds silently is a change nobody reviewed.
