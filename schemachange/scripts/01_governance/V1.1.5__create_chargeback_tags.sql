/* ---------------------------------------------------------------------------
   V1.1.5 - Chargeback tags

   Architectural note 6: objects that store data (tables, stages) must carry a
   tag so consumption can be tracked back to an owner for chargeback.

   Both are applied at the database level in 02_foundation and inherited
   downward, so every table and stage in the context is attributable.

   No ALLOWED_VALUES here, deliberately: cost centres and owning teams change
   as the org changes, and pinning them would force a new versioned script for
   every reorg. Governance of the values belongs in the finance process, not
   the tag definition.

   Query usage later via:
     SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES joined to warehouse/storage usage.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE TAG IF NOT EXISTS {{ governance_database }}.TAGS.COST_CENTER
  COMMENT = 'Finance cost centre accountable for this object''s spend.';

CREATE TAG IF NOT EXISTS {{ governance_database }}.TAGS.CHARGEBACK_OWNER
  COMMENT = 'Team owning the object for chargeback purposes.';
