/* ---------------------------------------------------------------------------
   V8.1.4 - Data quality check task (created SUSPENDED)

   Schedules COMMON.sp_run_silver_dq_checks. Created suspended and deliberately
   NOT resumed here.

   ==========================================================================
   WHY THIS IS NOT RESUMED, AND WHY V8.2.1 IS ABSENT FROM THE REPO
   ==========================================================================
   Two separate reasons, both of which must be cleared first.

   1. THE SILVER TABLES DO NOT CURRENTLY REFRESH.
      All 13 are dynamic tables with TARGET_LAG = DOWNSTREAM. There is no gold
      consumer and no 07_orchestration ingest task, so there is nothing
      downstream to pull them. Measured, not assumed:

        SHOW DYNAMIC TABLES IN SCHEMA {{ database }}.SILVER;
        -- Recorded: all 13 rows scheduling_state = OFF, target_lag = DOWNSTREAM

      A resumed daily task would therefore record 31 IDENTICAL rows every day
      indefinitely and resume the warehouse to compute a constant. That is not
      monitoring, it is noise with a bill attached.

   2. 07_orchestration's RULE ON RESUME SCRIPTS.
      "Tasks are created SUSPENDED by default and need an explicit ALTER TASK ...
      RESUME. Keep the resume in its own script so a deploy to prod does not
      silently start ingesting."

      Honouring that rule properly means the resume CANNOT simply be committed as
      V8.2.1 today - a versioned script is applied by the NEXT deploy, so
      committing it would start the task automatically, defeating the rule it was
      meant to satisfy. V8.2.1 is therefore RESERVED AND INTENTIONALLY UNWRITTEN.
      See 08_data_quality/README.md.

   WRITE V8.2.1__resume_dq_check_task.sql WHEN BOTH HOLD:
     a) V7.x bronze ingest runs, or gold exists - i.e. silver actually refreshes.
     b) The email path in V8.1.5 is confirmed to deliver.

   SCHEDULE CHOICE
   --------------------------------------------------------------------
   06:00 UTC daily. Once V7.x ingest exists this should follow it rather than
   run on a fixed clock - a DQ check that runs BEFORE the day's load measures
   yesterday's data and reports a stale pass. Prefer making this task a CHILD of
   the ingest task (AFTER <ingest_task>) when V7.x lands, and delete the
   SCHEDULE. Recorded here so the next session does not simply resume a
   cron-driven task and inherit the race.

   No $$ block in this definition, per 07_orchestration's note that $$ is not
   valid directly in a task body - a single CALL needs none.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE TASK IF NOT EXISTS {{ database }}.COMMON.t_silver_dq_checks
  WAREHOUSE = {{ warehouse }}
  SCHEDULE  = 'USING CRON 0 6 * * * UTC'
  COMMENT   = 'Daily silver data quality checks. Created SUSPENDED - see V8.1.4 header before resuming.'
AS
  CALL {{ database }}.COMMON.sp_run_silver_dq_checks();


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Task exists and is SUSPENDED. The state assertion is the point of this script.
SHOW TASKS LIKE 't_silver_dq_checks' IN SCHEMA {{ database }}.COMMON;
-- Recorded: state = suspended, schedule = USING CRON 0 6 * * * UTC,
--           warehouse = COMPUTE_WH, predecessors = []

-- Confirms the silver dynamic tables are not refreshing, which is reason 1 above.
SHOW DYNAMIC TABLES IN SCHEMA {{ database }}.SILVER;
-- Recorded: 13 rows, every one scheduling_state = OFF, target_lag = DOWNSTREAM,
--           refresh_mode = INCREMENTAL

-- No task history, because it has never run.
SELECT COUNT(*) AS runs
FROM   TABLE({{ database }}.INFORMATION_SCHEMA.TASK_HISTORY(
         TASK_NAME => 't_silver_dq_checks'));
-- Recorded: 0
