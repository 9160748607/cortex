/* ---------------------------------------------------------------------------
   V2.1.4 - Attach MEDALLION_LAYER tag to each schema

   Architectural note 6. This tag cannot be inherited from the database because
   its value is different for each of the four schemas, so it is set once per
   schema here. Tables created inside each schema inherit their schema's value.

   ENVIRONMENT / COST_CENTER / CHARGEBACK_OWNER are NOT repeated here - they
   are already inherited from the database via V2.1.3. Re-setting them at
   schema level would be redundant and would create a second place to maintain
   the same value.

   Idempotent: see the note in V2.1.3 - ALTER ... SET TAG is a safe re-run.

   Depends on: V1.1.4 (tag definition), V2.1.2 (schemas).
   --------------------------------------------------------------------------- */

ALTER SCHEMA {{ database }}.BRONZE SET TAG
  {{ governance_database }}.TAGS.MEDALLION_LAYER = 'BRONZE';

ALTER SCHEMA {{ database }}.SILVER SET TAG
  {{ governance_database }}.TAGS.MEDALLION_LAYER = 'SILVER';

ALTER SCHEMA {{ database }}.GOLD SET TAG
  {{ governance_database }}.TAGS.MEDALLION_LAYER = 'GOLD';

ALTER SCHEMA {{ database }}.COMMON SET TAG
  {{ governance_database }}.TAGS.MEDALLION_LAYER = 'COMMON';
