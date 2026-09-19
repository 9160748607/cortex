/* ---------------------------------------------------------------------------
   V1.1.1 - Governance database

   Architectural note 3: every tag, policy and masking policy must live in the
   governance database - never inside sales_dev / sales_qa / sales_prod.

   This database is deliberately NOT templated with {{ env }}: it is shared by
   all three contexts in this single Snowflake account, so deploying dev, qa
   and prod all converge on the same governance objects. That is what lets a
   tag applied in dev carry the identical definition in prod.

   Permanent (not transient) on purpose - architectural note 1 scopes TRANSIENT
   to dev/qa data objects; governance metadata is small and must not be lost.

   Idempotent: IF NOT EXISTS (architectural note 5).
   --------------------------------------------------------------------------- */

CREATE DATABASE IF NOT EXISTS {{ governance_database }}
  COMMENT = 'Central governance DB - tags, policies and masking for sales analytics.';
