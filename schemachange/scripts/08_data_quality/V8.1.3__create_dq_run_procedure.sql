/* ---------------------------------------------------------------------------
   V8.1.3 - Data quality run procedure

   Records one run of COMMON.v_dq_checks into COMMON.dq_results, then emails ONLY
   if something failed. Called ad hoc, and by COMMON.t_silver_dq_checks (V8.1.4)
   once that task is resumed.

   WHY A PROCEDURE AND NOT JUST THE VIEW
   --------------------------------------------------------------------
   The view gives current state. The procedure gives HISTORY and NOTIFICATION -
   the two things that turn a query into monitoring. Without a recorded run there
   is no regression detection, and without the conditional email nobody learns
   that a check failed.

   DESIGN NOTES
   --------------------------------------------------------------------
     EXECUTE AS CALLER   so the run is attributed to whoever invoked it and
                         inherits their masking-policy context. sv_customer_master
                         holds 9 populated personal-data columns (section 7); when
                         masking policies land, an OWNER-rights procedure would
                         silently bypass them. CALLER must not be changed to OWNER
                         without revisiting that.

     Email on failure    Not on every run. A monitor that mails on success is a
                         monitor people filter to a folder and stop reading.

     severity in subject  CRITICAL count is surfaced separately so triage can be
                         done from the notification list without opening anything.

     No CURRENT_TIMESTAMP in the view  measured_at is stamped here, once per run,
                         so every row in a run shares an identical timestamp and
                         can be grouped on it. (Unlike 05_silver, non-determinism
                         is harmless in a procedure - that constraint is specific
                         to dynamic-table definitions.)

   ==========================================================================
   KNOWN RISK: schemachange semicolon splitting - NOT YET EXERCISED
   ==========================================================================
   07_orchestration/README.md records that "schemachange splits on semicolons
   client-side" and that $$ delimiters are not valid directly in a task
   definition. This procedure body is a $$-quoted block CONTAINING semicolons,
   so the same mechanism could in principle break it on `schemachange deploy`.

   This has NOT been verified either way, because per AGENT.md section 9
   CHANGE_HISTORY_DEV is empty - every script in this repo so far was applied by
   executing the rendered SQL directly, and this one was too. The risk is real
   but unmeasured.

   If `schemachange deploy` does mangle this, the fix is to move the body into a
   single-statement form or deploy this one script out of band. Resolve it as
   part of the section 9 item "re-run schemachange deploy interactively", BEFORE the QA
   promotion - not after.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE PROCEDURE IF NOT EXISTS {{ database }}.COMMON.sp_run_silver_dq_checks()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Records one run of COMMON.v_dq_checks into COMMON.dq_results; emails via silver_dq_email_{{ env }} only when a check fails.'
EXECUTE AS CALLER
AS
$$
DECLARE
  v_run_id   VARCHAR DEFAULT UUID_STRING();
  v_failed   NUMBER  DEFAULT 0;
  v_critical NUMBER  DEFAULT 0;
  v_total    NUMBER  DEFAULT 0;
  v_detail   VARCHAR DEFAULT '';
BEGIN
  INSERT INTO {{ database }}.COMMON.dq_results
    (run_id, measured_at, layer, table_name, check_name, check_type,
     metric_value, threshold, comparator, passed, severity)
  SELECT :v_run_id, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
         layer, table_name, check_name, check_type,
         metric_value, threshold, comparator, passed, severity
  FROM   {{ database }}.COMMON.v_dq_checks;

  SELECT COUNT(*),
         COUNT_IF(NOT passed),
         COUNT_IF(NOT passed AND severity = 'CRITICAL')
    INTO :v_total, :v_failed, :v_critical
  FROM {{ database }}.COMMON.dq_results
  WHERE run_id = :v_run_id;

  IF (:v_failed > 0) THEN
    SELECT LISTAGG(severity || '  ' || table_name || '.' || check_name ||
                   '  value=' || metric_value ||
                   ' threshold=' || comparator || threshold,
                   '\n') WITHIN GROUP (ORDER BY severity, table_name)
      INTO :v_detail
    FROM {{ database }}.COMMON.dq_results
    WHERE run_id = :v_run_id AND NOT passed;

    CALL SYSTEM$SEND_EMAIL(
      'silver_dq_email_{{ env }}',
      '{{ dq_notification_email }}',
      '[{{ env }}] {{ database }}.SILVER DQ: ' || :v_failed || ' failed ('
        || :v_critical || ' critical)',
      'Run ' || :v_run_id || ' - ' || :v_failed || ' of ' || :v_total
        || ' checks failed.\n\n' || :v_detail
        || '\n\nDetail:\n'
        || '  SELECT * FROM {{ database }}.COMMON.dq_results'
        || ' WHERE run_id = ''' || :v_run_id || ''' AND NOT passed;'
    );
  END IF;

  RETURN 'run_id=' || :v_run_id || ' total=' || :v_total
      || ' failed=' || :v_failed || ' critical=' || :v_critical;
END;
$$;


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Procedure exists.
SELECT COUNT(*) AS procedure_count
FROM   {{ database }}.INFORMATION_SCHEMA.PROCEDURES
WHERE  procedure_schema = 'COMMON' AND procedure_name = 'SP_RUN_SILVER_DQ_CHECKS';
-- Recorded: 1

-- Execute it. Returns a summary string and writes 31 rows.
CALL {{ database }}.COMMON.sp_run_silver_dq_checks();
-- Recorded: run_id=<uuid> total=31 failed=0 critical=0
-- No email sent, which is correct behaviour at zero failures.

-- One run recorded, 31 rows, all sharing a single measured_at.
SELECT COUNT(DISTINCT run_id)      AS runs,
       COUNT(*)                    AS rows_recorded,
       COUNT(DISTINCT measured_at) AS distinct_timestamps
FROM   {{ database }}.COMMON.dq_results;
-- Recorded: 1, 31, 1

-- Health summary per run - the shape a regression query would use.
SELECT measured_at,
       COUNT(*)             AS checks,
       COUNT_IF(passed)     AS passed,
       COUNT_IF(NOT passed) AS failed,
       ROUND(100.0 * COUNT_IF(passed) / COUNT(*), 1) AS health_pct
FROM   {{ database }}.COMMON.dq_results
GROUP  BY run_id, measured_at
ORDER  BY measured_at DESC;
-- Recorded: 1 row - 31, 31, 0, 100.0

-- Anything needing attention (expect ZERO rows)
SELECT run_id, table_name, check_name, severity, metric_value, comparator, threshold
FROM   {{ database }}.COMMON.dq_results
WHERE  NOT passed
ORDER  BY measured_at DESC, severity;
