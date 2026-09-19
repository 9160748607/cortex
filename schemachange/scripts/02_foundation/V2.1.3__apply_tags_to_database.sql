/* ---------------------------------------------------------------------------
   V2.1.3 - Attach tags to the database

   Architectural note 6. Three tags are set at the DATABASE level because their
   value is constant for the whole context, and Snowflake tag inheritance then
   propagates them to every schema, table, view and stage underneath. One
   assignment therefore makes every data-storing object in the context
   attributable for chargeback.

   MEDALLION_LAYER is deliberately NOT set here - its value differs per schema,
   so it is applied in V2.1.4 instead.

   On idempotency: ALTER ... SET TAG has no IF NOT EXISTS form, but it is
   naturally idempotent - re-running assigns the same value again, which is a
   no-op. It never drops or replaces the object itself, so architectural
   note 5's intent (don't destroy existing objects) is preserved.

   Depends on: V1.1.3, V1.1.5 (tag definitions), V2.1.1 (database).
   --------------------------------------------------------------------------- */

ALTER DATABASE {{ database }} SET TAG
  {{ governance_database }}.TAGS.ENVIRONMENT       = '{{ env }}',
  {{ governance_database }}.TAGS.COST_CENTER       = '{{ cost_center }}',
  {{ governance_database }}.TAGS.CHARGEBACK_OWNER  = '{{ chargeback_owner }}';
