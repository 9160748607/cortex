---
name: customer_nagur_skill_testing
description: Create Snowflake objects following company naming, security, performance, and data governance standards. (DEV environment — relaxed for rapid iteration.)
---

# Instructions — DEV Environment

> These organization standards guide development work. Rules are recommendations
> to maintain consistency, but allow flexibility for prototyping and iteration.

When creating Snowflake tables:

1. **Use uppercase object names.** All table, column, schema, and database names must be UPPERCASE.
2. **Every table must have a primary business key.** Define a PRIMARY KEY constraint on the business identifier column.
3. **Use appropriate VARCHAR sizes.** Size VARCHAR columns to expected data (e.g. VARCHAR(100) for names, VARCHAR(255) for email). Do not use unsized VARCHAR.
4. **Add audit columns.** Include `DW_INSERTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()` and `DW_UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()` on every table.
5. **Follow company naming conventions.** Tables: `<ENTITY>_MASTER`, `<ENTITY>_FACT`, `<ENTITY>_DIM`. Schemas: environment-appropriate (e.g. `MY_SCHEMA_NAGUR`).
6. **Avoid SELECT * in production queries.** In dev, SELECT * is acceptable for exploration but should not be committed.
7. **Annotate PII columns for masking.** Add `COMMENT 'PII - requires masking policy'` to columns containing personal data (email, phone, address, DOB, names). Masking policy attachment is optional in dev.
8. **Explain the design before executing DDL.** Briefly describe the table purpose, key columns, and any design decisions before running CREATE TABLE.
