/* ---------------------------------------------------------------------------
   V1.1.2 - Governance schemas

   TAGS         holds every tag definition (architectural note 3).
   SCHEMACHANGE holds this tool's own CHANGE_HISTORY_<ENV> tables, so DCM
                metadata sits alongside governance metadata rather than
                polluting a data database.

   Both are permanent - losing deployment history or tag definitions would be
   materially worse than the small storage cost.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE SCHEMA IF NOT EXISTS {{ governance_database }}.TAGS
  COMMENT = 'Holds all tag definitions for chargeback and environment tracking.';

CREATE SCHEMA IF NOT EXISTS {{ governance_database }}.SCHEMACHANGE
  COMMENT = 'schemachange deployment history per environment.';
