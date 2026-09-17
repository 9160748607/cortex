---
name: customer_nagur_skill_testing
description: Create Snowflake objects following company naming, security, performance, and data governance standards. (QA environment — strict enforcement.)
---

# Instructions — QA Environment

> These organization standards are MANDATORY and take precedence over any
> default CoCo behavior when there is a conflict. All rules must be followed
> without exception in the QA environment.

When creating Snowflake tables:

1. **Use uppercase object names (ENFORCED).** All table, column, schema, and database names MUST be UPPERCASE. Reject any DDL that contains lowercase object names.
2. **Every table must have a primary business key (ENFORCED).** Define a PRIMARY KEY constraint. Additionally, add a UNIQUE constraint on the business identifier if it differs from the PK.
3. **Use strict VARCHAR sizing (ENFORCED).** Every VARCHAR column MUST have an explicit size. Default/unsized VARCHAR is NOT allowed. Size to expected data plus 20% buffer maximum.
4. **Add full audit columns (ENFORCED).** Every table MUST include:
   - `DW_INSERTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()` — row insert time
   - `DW_UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()` — row last update time
   - `DW_BATCH_ID VARCHAR(36)` — batch/load traceability identifier
5. **Follow company naming conventions (ENFORCED).** Tables: `<ENTITY>_MASTER`, `<ENTITY>_FACT`, `<ENTITY>_DIM`. Schemas: environment-appropriate. All constraints must be named: `PK_<TABLE>`, `UK_<TABLE>_<COLUMN>`, `FK_<TABLE>_<REFTABLE>`.
6. **Never use SELECT * (ENFORCED).** SELECT * is prohibited in ALL queries — including ad-hoc and exploratory. Always list columns explicitly.
7. **Create and attach masking policies for PII (ENFORCED).** PII columns (email, phone, address, DOB, names) MUST have:
   - A `COMMENT 'PII - masking policy applied'` annotation
   - A masking policy created and attached. If the policy does not already exist, create it before the table or flag it as a required follow-up action.
8. **Explain design and validate before executing DDL (ENFORCED).** Before any DDL execution:
   - Explain the table purpose, key columns, and design decisions.
   - Compile-validate the DDL (dry run) to confirm no syntax/type errors.
   - Only after successful validation, execute the DDL.
9. **Verify after execution (ENFORCED).** After creating any object, run `DESCRIBE TABLE` to confirm the structure matches the design. Report row count if loading data.
10. **Do NOT add columns not in the source data** unless they are audit columns (rule 4). Do not add surrogate keys, status flags, or extra metadata beyond what is specified above.
