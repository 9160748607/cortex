/* ---------------------------------------------------------------------------
   V1.1.3 - ENVIRONMENT tag

   Identifies which deployment context an object belongs to. Applied at the
   database level in 02_foundation and inherited by every schema, table and
   stage beneath it, so a single assignment covers the whole context.

   ALLOWED_VALUES closes the domain: a typo like 'Dev' or 'PRD' fails loudly at
   apply time instead of silently fragmenting chargeback reporting.

   Idempotent: IF NOT EXISTS (architectural note 5). Note that re-running this
   will NOT widen ALLOWED_VALUES on an existing tag - adding a value later
   requires its own versioned script with ALTER TAG ... ADD ALLOWED_VALUES.
   --------------------------------------------------------------------------- */

CREATE TAG IF NOT EXISTS {{ governance_database }}.TAGS.ENVIRONMENT
  ALLOWED_VALUES 'DEV', 'QA', 'PROD'
  COMMENT = 'Deployment context of the tagged object.';
