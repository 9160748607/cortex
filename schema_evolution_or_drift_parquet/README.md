# Schema Drift & Schema Evolution — Store Master (Parquet)

End-to-end demonstration of **schema drift detection** and **Snowflake schema evolution** for **Parquet** sources, from files on disk through to a unified loaded table.

**Target:** `ANALYSIS_DB.DATA_MIGRATION_PARQUET.STORE_MASTER`
**Source:** `C:\Users\X1Carbon\Music\store-master-testing\parquet` (2 Parquet files, never modified)

```
Source files → Schema detection → Drift identification → Schema evolution → Unified target → Load → Validation
```

Third of three format exercises — see `../schema_evolution_or_drift/` (CSV) and `../schema_evolution_or_drift_json/` (JSON). All three define a `STORE_MASTER`, so each needs its own schema.

> **Naming note:** the request specified schema `DATA_MIGRATION_parquit`. Corrected to `DATA_MIGRATION_PARQUET` — a misspelled schema name is a long-lived artefact, and renaming one later means reworking every grant, view and pipeline referencing it.

## Run order

| # | Script | Purpose |
|---|---|---|
| — | `COMPLETE_FLOW.sql` | **Whole sequence in one runnable file** + how Parquet column chunks map to the target |
| — | `cli/upload_to_stage.ps1` | PUT both Parquet files to the internal stage |
| 01 | `sql/01_create_objects.sql` | Schema, Parquet file format, stage |
| 02 | `sql/02_schema_detection.sql` | `INFER_SCHEMA` per file **+ the `TYPEOF` cross-check** |
| 03 | `sql/03_drift_analysis.sql` | Reusable column/type diff + recorded findings |
| 04 | `sql/04_create_target_table.sql` | Target with `ENABLE_SCHEMA_EVOLUTION = TRUE` |
| 05 | `sql/05_load_file1_baseline.sql` | Load file 1 — no drift |
| 06 | `sql/06_load_file2_additive_evolution.sql` | Load file 2 — **evolution fires** |
| 07 | `sql/07_derive_typed_timestamp.sql` | Add `created_at_ntz` with a reviewed type |
| 08 | `sql/08_validation.sql` | Structure, counts, NULL matrix, samples |
| 09 | `sql/09_future_columns_evolution_test.sql` | Third-file proof — **executed then rolled back** |
| 10 | `sql/10_logical_duplicate_detection.sql` | Re-keyed duplicate detection — remediation **not executed** |

Loads 05 → 06 → 07 must run in order; 07 depends on both loads being complete.

## Source schema comparison

Parquet embeds a typed, ordered schema, so `INFER_SCHEMA` reads the real definition rather than sampling. `ORDER_ID` is **document order** here — unlike JSON, which returns keys alphabetically.

| Column | File 1 `store_master.parquet` | File 2 `store_master_1.parquet` |
|---|---|---|
| store_code, store_name, country_code, region_code, tax_jurisdiction_code, format_code, city, state_code, address_line1, lifecycle_status, is_active, source_system | TEXT | TEXT |
| **postal_code** | **TEXT** | **NUMBER(38,0)** ⚠️ |
| latitude / longitude | REAL / REAL | REAL / REAL |
| store_open_date, effective_start_date, effective_end_date | DATE | DATE |
| store_close_date | TEXT (all NULL) | TEXT (all NULL) |
| floor_area_sqft / annual_rent_usd | NUMBER(38,0) | NUMBER(38,0) |
| **created_at** | **NUMBER(38,0)** ⚠️ *(but see below)* | **TEXT** ⚠️ |
| **Status** | **absent** | **TEXT** (`'y'`) ⚠️ |
| **Column count** | **22** | **23** |
| **Rows** | 121 | 5 |

- **Common:** 22 · **Only in File 1:** none · **Only in File 2:** `Status`

## Drift analysis

The richest of the three formats — **three distinct drifts**, with the two type drifts running in *opposite* directions.

### A. Additive structural drift
File 2 adds `Status`. This is the one drift evolution handles.

### B. Type drift — two columns, opposite directions

| Column | File 1 → File 2 | Values | Consequence |
|---|---|---|---|
| `postal_code` | **TEXT → INTEGER** | `08759`→`8759`, `02166`→`2166` | Leading zeros destroyed at source |
| `created_at` | **timestamp → TEXT** | real timestamp → `21:50.4` | Corrupted to a time fragment |

These can't be resolved by one policy. `postal_code` wants the **wider** type because File 1 is *correct*; `created_at` also ends up VARCHAR, but because File 2 is *corrupt* and must be landed as evidence. Same declaration, opposite justification.

### C. `INFER_SCHEMA` is not authoritative on Parquet

| Source | `created_at` type |
|---|---|
| `INFER_SCHEMA` | `NUMBER(38,0)` — physical int64 storage |
| `TYPEOF` on read | **`TIMESTAMP_NTZ`** — logical type annotation honoured |

**The reader is right.** Designing from `INFER_SCHEMA` alone would have declared a NUMBER column and silently stored epoch integers — a load that *succeeds* while discarding timestamp semantics and leaving consumers to reverse-engineer the epoch unit. Nothing would have failed.

**Rule:** on Parquet, never design a column type from `INFER_SCHEMA` alone. Cross-check date/time and numeric columns with `TYPEOF` against a real read. `INFER_SCHEMA` tells you how the bytes are stored; `TYPEOF` tells you what you'll get.

Also note int64 → `NUMBER(38,0)`: Snowflake maps Parquet integer width to *maximum* precision. 38 digits for a floor area isn't a declaration, it's the absence of one.

### D. Logical duplicates with no key collision

Every obvious check says clean: **126 rows, 126 distinct `store_code`**.

It isn't. File 2's five rows are File 1's first five stores **re-keyed** `US_0001`→`US_0101`: identical `store_name`, `latitude`, `longitude`, `store_open_date`. Only the surrogate key differs, plus the damaged `postal_code` and `created_at`.

This is **worse than the JSON exercise**, where File 2 reused the same keys and the collision showed up immediately as `COUNT(*) > COUNT(DISTINCT store_code)`. Re-keying keeps the corruption and removes the alarm. Any store count or rent roll-up is overstated by five stores, and no duplicate-key test would flag it.

**Root cause:** File 2 is the same Excel round-trip from the CSV exercise, re-serialised to Parquet and then re-keyed. Parquet introduced none of this damage — it faithfully preserved damage done upstream.

## Unified target design

Built from **file 1's 22 columns only** — `Status` deliberately not pre-declared.

| Column | Inferred | Declared | Why |
|---|---|---|---|
| `postal_code` | TEXT / NUMBER | **VARCHAR(30)** | Mandatory — NUMBER destroys File 1's 5 leading-zero codes |
| `created_at` | NUMBER / TEXT | **VARCHAR(50)** | Lands both losslessly, preserves the corruption |
| `created_at_ntz` | — | **TIMESTAMP_NTZ** | **Added by hand** (07), derived via `TRY_TO_TIMESTAMP_NTZ` |
| `latitude`/`longitude` | REAL | **NUMBER(9,6)/(10,6)** | Exact decimal beats float for coordinates |
| `floor_area_sqft` | NUMBER(38,0) | **NUMBER(10,0)** | int64 → max precision is meaningless |
| `annual_rent_usd` | NUMBER(38,0) | **NUMBER(14,2)** | Scale 0 would round cents |
| `is_active` | TEXT | **BOOLEAN** | `"Y"` and `"y"` both coerce — 0 nulls verified |
| `store_close_date` | TEXT | **DATE** | 100% NULL, so no type evidence — not proof it's a string |

### The `created_at` two-column compromise

Three options were weighed:

| Option | Outcome |
|---|---|
| Declare `TIMESTAMP_NTZ` | File 2's COPY **fails**, evolution never fires, `Status` never added |
| Declare `VARCHAR` only | Both load, but 121 valid timestamps demoted to text for 5 bad rows |
| **Both — chosen** | `created_at` VARCHAR keeps evidence; `created_at_ntz` gives real typing |

Costs one column and loses nothing: **121 rows typed, 5 visibly NULL** with raw text still inspectable. Consumers use `created_at_ntz`; data quality uses `created_at`.

## Schema-evolution mechanism

Parquet needs the **fewest settings of all three formats** — just two:

```sql
ENABLE_SCHEMA_EVOLUTION = TRUE   -- on the table
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE  -- on the COPY
```

| Option | CSV | JSON | Parquet |
|---|---|---|---|
| `PARSE_HEADER` | required | n/a | n/a |
| `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE` | required | n/a | n/a |
| delimiters / `ENCLOSED_BY` | required | n/a | n/a |
| `STRIP_OUTER_ARRAY` | n/a | required | n/a |
| per-file `DATE_FORMAT` | required (2 formats) | not needed | not needed |
| `NULL_IF` for bad literals | — | required (`NaN`) | not needed |

`USE_VECTORIZED_SCANNER = TRUE` matters beyond performance: it affects how logical type annotations surface on read — which is what exposed finding C.

## Results

| Load | File | Cols before → after | Rows | Evolution? |
|---|---|---|---|---|
| 1 | `store_master.parquet` | 26 → 26 | 121 | No — columns match |
| 2 | `store_master_1.parquet` | **26 → 27** | 126 | **Yes — `STATUS TEXT` added** |
| *(3, test)* | *generated Parquet* | ***28 → 30*** | *128* | ***Yes — 2 more added*** |

Zero errors on all loads. Notably, load 2 carried **two type drifts and still succeeded** — because the target was designed from a *comparison of both schemas*. Had it been built from file 1 alone, that COPY would have aborted.

**NULL matrix:**

| Source file | rows | STATUS | MANAGER_NAME | EMPLOYEE_COUNT | created_at_ntz |
|---|---|---|---|---|---|
| `store_master.parquet` | 121 | **121** | 121 | 121 | **0** |
| `store_master_1.parquet` | 5 | **0** | 5 | 5 | **5** |
| **TOTAL** | **126** | 121 | 126 | 126 | 5 |

Verified: 126 rows / 126 distinct keys, 5 leading-zero postal codes preserved from File 1, `is_active` 0 nulls, all `store_close_date` NULL, dates 2016-04-29 → 2026-04-10, `9999-12-31` intact.

Final state: **126 rows, 30 columns.**

## Known issues in the current loaded state

**1. Five logical duplicates, invisible to key checks.** Detection requires matching on `store_name` + coordinates + `store_open_date`, not `store_code`. See `10`. Deleting them would also discard File 2's `Status` values, which exist *only* on the degraded rows — so they must be merged onto the File 1 rows first, joining on the composite natural key. That's the real cost of re-keying.

**2. `EMPLOYEE_COUNT` evolved as `NUMBER(2,0)`** — ceiling of **99** from a 2-row sample. Third appearance across CSV, JSON and Parquet: inherent to automatic evolution, not format-specific. Contrast `created_at_ntz`, added by hand with a reviewed type.

**3. `created_at_ntz` is not self-maintaining.** A plain column populated by a one-off `UPDATE`, so rows loaded afterwards stay NULL — caught by the `09` test, whose 2 rows landed NULL. Options documented in `07`: re-run as a post-load step, make it a view column, or fix the export.

**4. Evolved columns carry no `COMMENT`** and appear in **document order** here (`MANAGER_NAME` then `EMPLOYEE_COUNT`) — whereas JSON appended them alphabetically. Evolved column ordering is format-dependent; don't depend on it.

## Handling a third file with new columns

Proven live — see `09`. A 25-column Parquet file adding `manager_name` and `employee_count` loaded with the **identical COPY**: no `ALTER TABLE`, no recreate. Table grew 28 → 30, new rows populated them, all 126 existing rows got NULL, prior data untouched. Test rows deleted; **the columns persist**.

The test fixture was **generated by Snowflake itself** — `COPY INTO @stage FROM (SELECT …) FILE_FORMAT = (TYPE = PARQUET)`. Parquet is a binary container that can't be hand-written in an editor, and this avoids installing pyarrow locally while having the file written by the same engine that reads it.

Not handled automatically, ranked quietest-first (quietest is most dangerous):

| Rank | Case | Behaviour |
|---|---|---|
| 1 | **Logical duplicates** | Nothing looks wrong at all |
| 2 | **Removed column** | Succeeds silently, values NULLed |
| 3 | **Renamed column** | Succeeds silently, splits a column in two |
| 4 | **Narrowed precision** | Succeeds now, fails later |
| 5 | **Incompatible type** | Fails immediately — *if* the target is strongly typed |

Cases 2 and 3 need a pre-load column-diff guard (pattern in `09`). Parquet makes that cheap and exact — the embedded schema can be read without scanning data — but pair it with the `TYPEOF` cross-check, because `INFER_SCHEMA` alone isn't enough.

## Interview explanation

> **Schema drift** is source-side; **schema evolution** is the target-side response — `ENABLE_SCHEMA_EVOLUTION = TRUE` plus `COPY … MATCH_BY_COLUMN_NAME`.
>
> Parquet is the easiest of the three formats to evolve. The schema is embedded, typed and ordered, so there's nothing to configure: no `PARSE_HEADER`, no delimiters, no `STRIP_OUTER_ARRAY`, no per-file `DATE_FORMAT` — CSV needed two of those and JSON needed `NULL_IF` for an invalid literal. It added `Status` automatically and NULL-filled 121 existing rows.
>
> But "typed and self-describing" isn't "trustworthy," and Parquet has a trap the others don't. `INFER_SCHEMA` told me `created_at` was `NUMBER(38,0)`; `TYPEOF` on a real read said `TIMESTAMP_NTZ`. `INFER_SCHEMA` surfaced the physical int64 storage while the reader honoured the logical timestamp annotation. Trusting it alone would have stored epoch integers — a load that succeeds while quietly losing the timestamp. Always cross-check.
>
> Evolution is also additive-only, so type drift needs a design decision. Here two columns drifted in *opposite* directions: `postal_code` string→int losing leading zeros, `created_at` timestamp→corrupt text. I landed `created_at` as VARCHAR to keep the evidence and added a separate `created_at_ntz` via `TRY_TO_TIMESTAMP_NTZ`, so 121 good rows keep real timestamps and the 5 bad ones are visibly NULL — rather than failing the load or being silently coerced. The important part is that the target was designed by comparing *both* schemas; built from file 1 alone, the second load would have aborted.
>
> And the subtlest finding: the second file was the first file's stores **re-keyed**, so `COUNT(DISTINCT store_code)` came back clean at 126 while the table held five stores twice. Duplicate detection has to match on business attributes, not the surrogate key — and re-keying is worse than a key collision precisely because it removes the alarm while keeping the problem.
