/* ---------------------------------------------------------------------------
   V1.1.4 - MEDALLION_LAYER tag

   Identifies which medallion zone an object belongs to. Unlike ENVIRONMENT
   this is applied per SCHEMA (in 02_foundation), because the value differs
   between bronze / silver / gold / common within one database - so it cannot
   be inherited from the database level.

   Tables created inside each schema inherit their schema's value, which is
   what satisfies architectural note 6 for data-storing objects without
   tagging each table individually.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE TAG IF NOT EXISTS {{ governance_database }}.TAGS.MEDALLION_LAYER
  ALLOWED_VALUES 'BRONZE', 'SILVER', 'GOLD', 'COMMON'
  COMMENT = 'Medallion zone the tagged object belongs to.';
