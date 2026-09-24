# 08_data_quality — post-silver data quality assertions

**Status: implemented for silver in DEV.** Depends on `05_silver` existing first.

Reserved version range **V8.x**.

This folder holds **set-level data quality assertions** that run *outside* the
dynamic-table chain: a check-set view, a history table, a procedure that records
a run, and a suspended task that will schedule it. It is the home for the
"needs a second table" checks that DQ rule 3 explicitly pushes out of silver.

---

## Why this is not built on Data Metric Functions

Snowflake ships Data Quality Monitoring — Data Metric Functions, expectations,
`SYSTEM$DATA_METRIC_SCAN`, `DATA_QUALITY_MONITORING_RESULTS` — which would
replace almost all of this folder with declarative `ALTER TABLE ... ADD DATA
METRIC FUNCTION` statements.

**It is unavailable on this account. Measured, not assumed:**

```
SELECT edition FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS
WHERE account_locator = CURRENT_ACCOUNT();
-- Recorded: STANDARD
```

Every DMF statement fails with `Unsupported feature 'DATA METRIC FUNCTION'`, as
do `SHOW DATA METRIC FUNCTIONS` and `SYSTEM$DATA_METRIC_SCAN`. Data Quality
Monitoring is an **Enterprise Edition** feature.

So the check set is hand-rolled SQL. **If this account is ever upgraded to
Enterprise, most of V8.1.2 and V8.1.3 should be deleted and replaced with DMF
associations** — the native version gives scheduling, history and expectation
evaluation for free, and does not need a task or a results table. The check
*semantics* in `V8.1.2` map one-to-one onto system DMFs:

| This folder's check type | Native equivalent |
|---|---|
| `NULL_COUNT` | `SNOWFLAKE.CORE.NULL_COUNT` |
| `DUPLICATE_COUNT` | `SNOWFLAKE.CORE.DUPLICATE_COUNT` |
| `REFERENTIAL` | `SNOWFLAKE.CORE.REFERENTIAL_INTEGRITY_COUNT` |
| `ACCEPTED_VALUES` | `SNOWFLAKE.CORE.ACCEPTED_VALUES` (lambda form) |
| `PARITY` / `LAG` | custom two-table DMF (no system equivalent) |
| `FLAG_COUNT` | custom single-table DMF |

---

## Why the objects live in `COMMON`

Rule 3 reserves the **`GOVERNANCE` database** for tags, masking policies and
governance object *definitions*. These are neither — they are utilities that
read environment data and write environment history, so they belong to the
environment database.

`COMMON` is documented as "Common utilities — file formats, stages, sequences,
**UDFs and procedures**", which is exactly what this is. It also means
`dq_results` **inherits `MEDALLION_LAYER = 'COMMON'` from its schema**, so
architectural note 6 is satisfied without tagging the table — the mechanism
`V1.1.4` was designed around.

A separate `DATA_QUALITY` schema was considered and rejected: it would require
amending `02_foundation`, and it would collide conceptually with the
`GOVERNANCE` database for no benefit.

---

## Documented exception to DQ rule 4 — allow-lists

`AGENT.md` §6 rule 4 says no allow-lists on business categorisations, and §7
lists "Allow-lists on segment / tier / format / lifecycle" under **rejected
rules**. `V8.1.2` nevertheless asserts accepted values on `channel_id`,
`payment_method`, `loyalty_tier` and `customer_segment`.

**This is a deliberate, scoped exception, and the distinction is the point:**

Rule 4 forbids an allow-list as a **row-level `dq_issue_flags` bit inside a
dynamic table**. There it is genuinely wrong — it permanently mislabels a
legitimate business change as a per-row defect, and it bakes a business
vocabulary into the silver contract.

These are **set-level assertions in external validation SQL**, which DQ rule 3
positively *directs* here: "anything needing a second table … is a set-level
assertion for validation SQL or gold, never a flag." The assertion does not
reject a row, does not write a flag, and does not touch silver. What it
produces is a notification — which is precisely rule 4's own remedy,
"**unfamiliar is news**". It delivers the news.

Practical consequence: when the source adds a payment method, the run fails
with `MEDIUM` severity, someone reads it, and the value is added to `V8.1.2`.
That is a two-minute triage, not a data defect.

**Do not migrate these back into a silver `dq_issue_flags` expression.** The
exception is specific to set-level monitoring and does not generalise.

---

## Scripts

```
V8.1.1__create_dq_results_table.sql            history table
V8.1.2__create_dq_checks_view.sql              the 31-check set
V8.1.3__create_dq_run_procedure.sql            records a run, emails on failure
V8.1.4__create_dq_check_task.sql               task, created SUSPENDED
V8.1.5__create_dq_notification_email.sql       per-env email integration
```

### V8.2.1 is reserved and deliberately not written

Following `07_orchestration`'s rule — "keep the resume in its own script so a
deploy to prod does not silently start ingesting" — the `ALTER TASK ... RESUME`
belongs in its own script.

It is **not in the repo yet, on purpose.** A versioned script is applied by the
next `schemachange deploy`, so committing `V8.2.1` now would start the task on
the next deploy, which is exactly what we do not want. Add it as
`V8.2.1__resume_dq_check_task.sql` when the conditions below are met.

**Do not resume the task until both hold:**

1. `07_orchestration` V7.x bronze ingest exists and runs, *or* gold exists.
   Until then the silver dynamic tables have `TARGET_LAG = DOWNSTREAM` with no
   downstream consumer and `scheduling_state = OFF` — **they never refresh**, so
   every run records 31 identical rows and burns warehouse time for a constant.
2. The email path in `V8.1.5` has been confirmed to deliver — see outstanding
   items below.

---

## The check set

31 checks over the 4 highest-traffic silver tables. Baselines were measured on
live DEV data and all 31 pass; the recorded values are inline in `V8.1.2`.

| Type | Count | Notes |
|---|---|---|
| `NULL_COUNT` | 3 | business keys only |
| `DUPLICATE_COUNT` | 4 | includes the `(transaction_sk, line_number)` compound key |
| `REFERENTIAL` | 6 | set-level per DQ rule 3; NULL sources excluded, standard FK semantics |
| `ACCEPTED_VALUES` | 7 | 4 categorical (see exception above) + 3 measure-range |
| `FLAG_COUNT` | 6 | makes `dq_issue_flags` alertable |
| `PARITY` | 3 | silver vs bronze row count |
| `LAG` | 2 | silver behind bronze, by max timestamp |

### Two deliberate choices worth knowing

**Flag thresholds are pinned to today's counts, not to zero.** `sv_customer_master`
carries 24,713 flagged rows — 23,874 `PHONE_NOT_E164`, 3,515
`MINOR_AT_REGISTRATION`, 698 `UNDER_13_AT_REGISTRATION`. These are known,
registered defects (`AGENT.md` §7), not regressions. Asserting `= 0` would fail
permanently and train readers to ignore the output, which is DQ rule 2's failure
mode. Asserting `<= today` means only **deterioration** alerts. Tighten the
thresholds as the numbers come down.

**Relative bronze-vs-silver lag, not absolute freshness.** Max
`transaction_timestamp` in silver is 2020-01-01 (the 24 timezone-spillover rows
in §7; the dataset is 2019). Any absolute freshness threshold violates forever.
Comparing silver's max timestamp to *bronze's* is the signal that actually means
something: it detects silver falling behind its source.

### What is deliberately NOT checked here

- **The 38,102 sales rows predating their store's opening** — a real defect, but
  it belongs in gold per §7, and needs each store's own open date.
- **Cross-currency amount correctness** — unfixable without an FX dimension. A
  check would assert a problem nobody can action.
- **`header total = SUM(line totals)`** *is* checked, but note from §7 that the
  two are identical 1:1 by construction. The check guards against future join
  fan-out; it is not evidence the measures are independent.

---

## Verification after deploy

```sql
CALL <db>.COMMON.sp_run_silver_dq_checks();
-- expect: total=31 failed=0 critical=0

SELECT table_name, check_name, severity, metric_value, comparator, threshold
FROM   <db>.COMMON.v_dq_checks
WHERE  NOT passed;
-- expect: zero rows

SHOW TASKS IN SCHEMA <db>.COMMON;
-- expect t_silver_dq_checks state = suspended
```

---

## Outstanding

| Item | Detail |
|---|---|
| **Email delivery unverified** | `SYSTEM$SEND_EMAIL` only fires on failure, and nothing has failed, so the path has never executed. Snowflake requires the recipient to be a **verified** address on a user in the account. Confirm before relying on the alert. |
| `V8.2.1` resume script | Not written. See the two preconditions above. |
| Gold-layer checks | This folder covers silver only. Gold will need its own range and reconciliation against silver. |
| Thresholds are DEV baselines | The flag counts are specific to the 2019 dataset. QA and prod will need their own measured baselines before the task is resumed there. |
