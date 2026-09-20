# Schema Drift & Schema Evolution — Store Master (JSON)

End-to-end demonstration of **schema drift detection** and **Snowflake schema evolution** for **JSON** sources, from files on disk through to a unified loaded table.

**Target:** `ANALYSIS_DB.DATA_MIGRATION_JSON.STORE_MASTER`
**Source:** `C:\Users\X1Carbon\Music\store-master-testing\json_data` (2 JSON files, never modified)

```
Source files → Schema detection → Drift identification → Schema evolution → Unified target → Load → Validation
```

A separate schema from `DATA_MIGRATION` deliberately — that one already holds the CSV `STORE_MASTER`, so reusing it would collide on the table name. See `../schema_evolution_or_drift/` for the CSV equivalent.

## Run order

| # | Script | Purpose |
|---|---|---|
| — | `COMPLETE_FLOW.sql` | **Whole sequence in one runnable file** + how JSON keys become columns |
| — | `cli/upload_to_stage.ps1` | PUT both JSON files to the internal stage |
| 01 | `sql/01_create_objects.sql` | Schema, JSON file format, stage |
| 02 | `sql/02_schema_detection.sql` | `INFER_SCHEMA` **per file** + the `NaN` investigation |
| 03 | `sql/03_drift_analysis.sql` | Reusable key/type diff + recorded findings |
| 04 | `sql/04_create_target_table.sql` | Target with `ENABLE_SCHEMA_EVOLUTION = TRUE` |
| 05 | `sql/05_load_file1_baseline.sql` | Load file 1 — no drift |
| 06 | `sql/06_load_file2_additive_evolution.sql` | Load file 2 — **evolution fires** |
| 07 | `sql/07_validation.sql` | Structure, counts, NULL matrix, samples |
| 08 | `sql/08_future_keys_evolution_test.sql` | Third-file proof — **executed then rolled back** |
| 09 | `sql/09_idempotent_merge_fix.sql` | MERGE + de-dup — **not executed** |

Loads 05 → 06 must run in sequence; each is a different state transition of the same table.

## Source schema comparison

`INFER_SCHEMA` returns JSON keys **alphabetically** — `ORDER_ID` is *not* document position. Ordinal position is meaningless in JSON, which is why name-based matching isn't merely convenient here, it's the only sane option.

| Key | File 1 `store_master.json` | File 2 `store_master_columns_added.json` |
|---|---|---|
| store_code, store_name, country_code, region_code, tax_jurisdiction_code | TEXT | TEXT |
| format_code, city, state_code, address_line1, lifecycle_status, source_system | TEXT | TEXT |
| postal_code | **TEXT** | **TEXT** |
| latitude / longitude | NUMBER(8,6) / NUMBER(9,6) | same |
| store_open_date, effective_start_date, effective_end_date | DATE | DATE |
| **store_close_date** | **REAL** ⚠️ | **REAL** ⚠️ |
| floor_area_sqft / annual_rent_usd | NUMBER(5,0) / NUMBER(8,0) | same |
| is_active | TEXT (`"Y"`) | TEXT (`"Y"`) |
| created_at | TIMESTAMP_NTZ | TIMESTAMP_NTZ |
| **Status** | **absent** | **TEXT** (`"True"`) ⚠️ |
| **Key count** | **22** | **23** |
| **Records** | **121** | **5** |

- **Common:** 22 · **Only in File 1:** none · **Only in File 2:** `Status`
- **Type differences between the files: none**

## Drift analysis

### Structural drift — purely additive

File 2 is a strict superset, adding `Status`. That is the only drift *between* the files, and it's exactly what evolution handles.

### No type drift between the files

All 22 shared keys have identical inferred types — a genuine contrast with the CSV version of this same data, where `postal_code`, three date columns and `created_at` all disagreed. JSON is better behaved because values are self-typed and quoted:

- `postal_code` arrives as `"08759"` in **both** files, so the leading zero cannot be lost. The CSV export stripped it. **7 leading-zero codes preserved here.**
- Dates are ISO in both files, so no per-file `DATE_FORMAT` is needed (the CSV run required two formats).

### A defect shared by both files — `NaN`

Every record in both files contains:

```json
"store_close_date": NaN
```

**`NaN` is not valid JSON** — the spec defines no such literal. Almost certainly a pandas `to_json()` artefact where a missing value is emitted as float NaN rather than `null`. Three findings, each tested:

| Test | Result |
|---|---|
| PowerShell `ConvertFrom-Json` | **Accepts it** — reports VALID. Local validation gives false confidence |
| Snowflake stage read | **Accepts it**, `TYPEOF` → **DOUBLE**. Not NULL, not an error |
| `INFER_SCHEMA` | Types `store_close_date` as **REAL** — a date column inferred as floating-point |

Because *both* files carry it, this is not drift between them — it's a constant source defect. It still dictated the target design.

## Unified target design

Built from **file 1's 22 keys only** — `Status` deliberately not pre-declared, so the table must *learn* it.

| Column | Inferred | Declared | Why |
|---|---|---|---|
| `store_close_date` | REAL | **VARCHAR(50)** | See below — two failed attempts |
| `is_active` | TEXT | **BOOLEAN** | `"Y"` → `TRUE` verified before declaring |
| `created_at` | TIMESTAMP_NTZ | **TIMESTAMP_NTZ** | Clean in both files |
| `postal_code` | TEXT | **VARCHAR(30)** | Keeps leading zeros; NUMBER would destroy them |
| `floor_area_sqft` | NUMBER(5,0) | **NUMBER(10,0)** | Inferred cap 99,999 sqft |
| `annual_rent_usd` | NUMBER(8,0) | **NUMBER(14,2)** | Inferred cap ~100M; scale 0 rounds cents |
| `latitude`/`longitude` | (8,6)/(9,6) | **(9,6)/(10,6)** | Inferred precision can't hold `-180.000000` |

### `store_close_date` — two failures got us here

| Attempt | Result |
|---|---|
| **1.** Declare `DATE` (semantically correct) | ❌ `Can't parse 'NaN' as date with format 'YYYY-MM-DD'` |
| **2.** Keep `DATE`, add `NULL_IF = ('NaN', …)` | ❌ **Still failed, identical error** |
| **3.** Declare `VARCHAR`, keep `NULL_IF` | ✅ Lands as clean NULL |

Attempt 2 is the instructive one. `NULL_IF` compares **strings**, but Snowflake had already parsed `NaN` as a DOUBLE (`TYPEOF` confirms), so the comparison never matched and the DATE coercion ran on a float. Only the VARCHAR path gives `NULL_IF` a string to match.

Verified after load: **all 126 rows NULL, zero rows holding the text `'NaN'`.** The column is VARCHAR only to give `NULL_IF` something to match — it contains proper NULLs, not junk. The real fix is upstream: emit JSON `null`.

## Schema-evolution mechanism

JSON needs **fewer** settings than CSV — just two:

```sql
-- on the table
ENABLE_SCHEMA_EVOLUTION = TRUE
-- on the COPY
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
```

The CSV prerequisites **do not exist** for JSON:

| CSV setting | Why not needed |
|---|---|
| `PARSE_HEADER = TRUE` | JSON keys are self-describing — no header row |
| `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE` | JSON objects have no fixed column count |

What JSON *does* need: `STRIP_OUTER_ARRAY = TRUE` (both files are one top-level array — without it the whole array loads as **one** row), and here `NULL_IF` for the `NaN`.

`INCLUDE_METADATA` is the only way to capture `METADATA$` columns, since `COPY INTO … FROM (SELECT …)` can't combine with `MATCH_BY_COLUMN_NAME`. That restriction is also *why* the `NaN` had to be fixed declaratively in the file format rather than with a cast.

## Results

| Load | File | Cols before → after | Rows | Evolution? |
|---|---|---|---|---|
| 1 | `store_master.json` | 26 → 26 | 121 | No — keys match table |
| 2 | `store_master_columns_added.json` | **26 → 27** | 126 | **Yes — `STATUS TEXT` added** |
| *(3, test)* | *`…future_keys.json`* | ***27 → 29*** | *128* | ***Yes — 2 more added*** |

**NULL matrix:**

| Source file | rows | STATUS | MANAGER_NAME | EMPLOYEE_COUNT | store_close_date |
|---|---|---|---|---|---|
| `store_master.json` | 121 | **121** | 121 | 121 | 121 |
| `store_master_columns_added.json` | 5 | **0** | 5 | 5 | 5 |
| **TOTAL** | **126** | 121 | 126 | 126 | 126 |

Zero unparsed dates, timestamps or booleans. 7 leading-zero postal codes preserved. `9999-12-31` intact.

Final state: **126 rows, 121 distinct keys, 29 columns.**

## Known issues in the current loaded state

**1. Five duplicate business keys.** File 2 is a re-export of file 1's first five records (`US_0001`–`US_0005`) with `Status` added — not five new stores. `COPY` load history is keyed on **filename, not business key**, so the differently-named file loaded again. 126 rows, 121 distinct keys. `COUNT(*)` overstated by 5, and a lookup on those keys returns two conflicting rows. Not a drift or evolution failure — a de-duplication gap in the load strategy, easy to miss because the load reported success. Fix: `09_idempotent_merge_fix.sql`.

**2. `EMPLOYEE_COUNT` evolved as `NUMBER(2,0)`** — a ceiling of **99**, inferred from a 2-record sample (87, 34). Evolution doesn't pick a *sensible* type, it picks the smallest that fits the sample. A store with 100 staff fails the next load. Every evolved column needs a precision review.

**3. Evolved columns carry no `COMMENT`** and are appended **alphabetically** (`EMPLOYEE_COUNT` at 28 before `MANAGER_NAME` at 29, though the document lists `manager_name` first). The missing comment is a useful tell — a commentless column is an evolved one — but worth back-filling.

**4. `store_close_date` is VARCHAR, not DATE.** Correct for today (all values NULL) but semantically wrong long-term. Fix the export to emit `null`, then retype the column.

## Handling a future file with new keys

Proven, not theorised — see `08`. A 25-key file adding `manager_name` and `employee_count` loaded with the **identical COPY**: no `ALTER TABLE`, no recreate. Table grew 27 → 29, new rows populated them, all 126 existing rows got NULL, prior data untouched. Test rows then deleted; **the columns persist** — evolution is not reversible by `DELETE`.

So the pipeline is **additively future-proof**. Evolution is **add-only**, and what it won't handle, ranked quietest-first (quietest is most dangerous):

| Rank | Case | Behaviour |
|---|---|---|
| 1 | **Removed key** | Succeeds silently, values NULLed, no alert |
| 2 | **Renamed key** | Succeeds silently — arrives as new column, old one goes NULL |
| 3 | **Narrowed precision** | Succeeds now, fails later on bigger data |
| 4 | **Incompatible type** | Fails immediately — what the `NaN`/DATE conflict did |
| — | **Invalid literals** | Accepted by Snowflake *and* by lenient client parsers. Nothing flags it |

Cases 1 and 2 need a **pre-load key-diff guard** (pattern in `08`), not a Snowflake feature.

## Interview explanation

> **Schema drift** is source-side: files that should share a shape don't. **Schema evolution** is the target-side response — Snowflake alters the table to absorb it.
>
> For JSON it's simpler than CSV: `ENABLE_SCHEMA_EVOLUTION = TRUE` plus `COPY … MATCH_BY_COLUMN_NAME`. No `PARSE_HEADER`, no `ERROR_ON_COLUMN_COUNT_MISMATCH`, because JSON keys are self-describing — you do need `STRIP_OUTER_ARRAY` when the file is one big array. Match-by-name also NULL-fills absent keys for free. And JSON dodged a whole class of CSV damage here: quoted values meant postal code `08759` survived, where the CSV export silently turned it into `8759`.
>
> But JSON brought its own trap, and it's the thing I'd raise in review. These files contain the literal `NaN`, which **isn't valid JSON**. PowerShell's parser accepted it, so local validation looked clean. Snowflake accepted it too — as a **DOUBLE** — so `INFER_SCHEMA` typed a *date* column as `REAL`. Declaring it `DATE` failed the load; adding `NULL_IF` **also** failed, because `NULL_IF` compares strings and `NaN` had already been parsed as a number. It only worked by landing the column as VARCHAR so `NULL_IF` had a string to match.
>
> The lesson: evolution gives you **structural** tolerance for *added* fields. It does nothing for invalid literals, type conflicts, or removed fields — and "the file parsed successfully" is not the same as "the data is valid." I'd also add a key-diff alert before each load, because a schema change that succeeds silently is a change nobody reviewed.
