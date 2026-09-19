/* ---------------------------------------------------------------------------
   V2.1.1 - Environment database

   Renders to SALES_DEV / SALES_QA / SALES_PROD from the {{ '{{ database }}' }}
   var, so this one script serves all three contexts and objects move "as is"
   up the promotion path via GitHub PR.

   {{ '{{ object_type }}' }} renders as TRANSIENT in dev and qa, and as an empty
   string in prod. That is how architectural note 1 is honoured without
   forking the script:
     dev/qa -> CREATE TRANSIENT DATABASE ... (no fail-safe cost)
     prod   -> CREATE DATABASE ...           (permanent, live data)

   Tags are attached in V2.1.3, not here, because the tag definitions live in
   the governance database and are created by the 01_governance scripts.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE {{ object_type }} DATABASE IF NOT EXISTS {{ database }}
  DATA_RETENTION_TIME_IN_DAYS = {{ retention_days }}
  COMMENT = 'Apple Inc sales analytics - {{ env }} context, medallion layers.';
