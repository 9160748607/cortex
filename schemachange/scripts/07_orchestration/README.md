# 07_orchestration — delta & incremental load

**Status: scaffold.** Depends on `04_bronze` existing first.

## Rules this folder must implement

From the final data-flow rule: a **task** encapsulates the `COPY` command for
newly-arrived files in the internal stage. Newly-landed data then flows to gold
through the dynamic-table chain automatically, with no further orchestration.

So the pipeline splits cleanly in two:

```
stage files ──[TASK + COPY INTO]──> bronze ──[dynamic tables, DOWNSTREAM lag]──> silver ──> gold
             ^ only this part is scheduled          ^ this part is pull-driven
```

Only the bronze ingest needs a task. Do **not** add tasks to refresh silver or
gold — `TARGET_LAG = DOWNSTREAM` already handles that, and a manual refresh task
would fight the dynamic-table scheduler.

## Task shape

- The task only needs to run `COPY INTO`; `COPY` is already incremental by
  default, since Snowflake tracks which files in a stage have been loaded and
  skips them. `FORCE = TRUE` must **not** be used — it would reload everything.
- Gate execution on the stage actually having new files so the warehouse is not
  resumed for nothing.
- Tasks are created `SUSPENDED` by default and need an explicit
  `ALTER TASK ... RESUME`. Keep the resume in its own script so a deploy to prod
  does not silently start ingesting.
- Multi-statement task bodies need `EXECUTE IMMEDIATE $$ ... $$` or a stored
  procedure call. Per the schemachange docs, `$$` delimiters are *not* valid
  directly in a task definition, and schemachange splits on semicolons
  client-side — so prefer a **single** `COPY INTO` per task, or call a stored
  procedure that wraps the logic.

## Planned scripts

Reserved version range **V7.x**:

```
V7.1.1__create_bronze_copy_procedure.sql    # SP wrapping COPY for all bronze tables
V7.1.2__create_bronze_ingest_task.sql       # scheduled task calling the SP
V7.2.1__resume_bronze_ingest_task.sql       # explicit RESUME, separated on purpose
```

## Verification after deploy

```sql
SHOW TASKS IN SCHEMA <db>.COMMON;

SELECT name, state, scheduled_time, error_message
FROM   TABLE(<db>.INFORMATION_SCHEMA.TASK_HISTORY())
ORDER  BY scheduled_time DESC
LIMIT  20;
```
