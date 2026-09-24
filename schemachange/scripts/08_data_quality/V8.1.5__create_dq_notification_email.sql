/* ---------------------------------------------------------------------------
   V8.1.5 - Data quality email notification integration

   The delivery channel for COMMON.sp_run_silver_dq_checks. Without it the
   procedure's SYSTEM$SEND_EMAIL call fails and a DQ failure goes unnoticed - the
   exact gap this folder exists to close.

   ACCOUNT-LEVEL OBJECT, NAMED PER ENVIRONMENT
   --------------------------------------------------------------------
   Notification integrations are ACCOUNT-level, not database-level. All three
   contexts share one Snowflake account, so an unsuffixed name would collide the
   moment QA deploys: whichever context deployed last would own the recipient
   list, and dev failures would mail the prod distribution list or vice versa.

   Hence silver_dq_email_{{ env }} - three distinct integrations, one per context,
   each with its own recipient supplied by the dq_notification_email var.

   This is the same reasoning as change-history-table being suffixed
   CHANGE_HISTORY_{{ env }}, and the opposite of governance_database, which is
   deliberately NOT per-environment so a tag definition is identical everywhere.
   The rule of thumb: shared DEFINITIONS are unsuffixed, per-context STATE and
   ROUTING are suffixed.

   NEW VAR REQUIRED
   --------------------------------------------------------------------
   dq_notification_email was added to all three config files by this change. It
   is genuinely environment-specific - a dev data-quality failure should not page
   whoever owns prod - so it cannot be a constant in the script.

   ==========================================================================
   NOT VERIFIED: delivery
   ==========================================================================
   Creating the integration proves nothing about whether mail arrives.
   SYSTEM$SEND_EMAIL only fires on failure, and no check has failed, so this path
   HAS NEVER EXECUTED.

   Snowflake requires each ALLOWED_RECIPIENTS address to be a VERIFIED email on a
   user in the account. If it is not, the procedure raises at the CALL and the
   run's rows are already committed - so dq_results would show the failure while
   nobody was told. That is a silent-monitor failure mode and it is the single
   biggest weakness in this folder.

   CONFIRM DELIVERY BEFORE WRITING V8.2.1 (resume). One cheap way:

     CALL SYSTEM$SEND_EMAIL('silver_dq_email_{{ env }}',
       '{{ dq_notification_email }}', 'DQ integration test', 'Delivery check.');

   Tracked in 08_data_quality/README.md and AGENT.md section 9.

   Idempotent: IF NOT EXISTS (architectural note 5). Note this means changing the
   recipient later requires a new version, not an edit here.
   --------------------------------------------------------------------------- */

CREATE NOTIFICATION INTEGRATION IF NOT EXISTS silver_dq_email_{{ env }}
  TYPE               = EMAIL
  ENABLED            = TRUE
  ALLOWED_RECIPIENTS = ('{{ dq_notification_email }}')
  COMMENT            = 'Email channel for {{ database }} silver data quality failures. Consumed by {{ database }}.COMMON.sp_run_silver_dq_checks.';


/* ---------------------------------------------------------------------------
   VALIDATION
   --------------------------------------------------------------------------- */

-- Integration exists and is enabled.
SHOW NOTIFICATION INTEGRATIONS LIKE 'silver_dq_email_{{ env }}';
-- Recorded: type = EMAIL, enabled = true

-- Recipient list matches the var.
DESCRIBE NOTIFICATION INTEGRATION silver_dq_email_{{ env }};
-- Recorded: ALLOWED_RECIPIENTS = [nagur7749@gmail.com]

-- Delivery is NOT asserted here. See the header - the send path has never run.
