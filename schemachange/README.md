# Apple Inc Sales Analytics — Database Change Management

Medallion architecture (bronze / silver / gold / common) across three contexts
in a single Snowflake account, deployed with
[schemachange](https://github.com/Snowflake-Labs/schemachange).

One script set serves all three environments. The only thing that differs
between dev, QA and prod is the `vars` block in the config file.

## Layout

```
schemachange/
├── config/
│   ├── schemachange-config-dev.yml
│   ├── schemachange-config-qa.yml
│   └── schemachange-config-prod.yml
└── scripts/
    ├── 01_governance/    V1.x  governance DB, schemas, tag definitions
    ├── 02_foundation/    V2.x  environment DB, 4 schemas, tag attachment
    ├── 03_common/        V3.x  file formats, sequences
    ├── 04_bronze/        V4.x  landing stage + 13 raw tables      (done)
    ├── 05_silver/        V5.x  13 cleaned dynamic tables          (done)
    ├── 06_gold/          V6.x  facts, dims, agg, semantic view  (in progress)
    ├── 07_orchestration/ V7.x  ingest task                   (scaffold)
    └── 08_data_quality/  V8.x  silver DQ check set                (done)
```

schemachange keys off **file names, not paths** — the numbered folders exist
purely for human maintainability. Version numbers must be unique across the
whole project, so each folder owns a reserved range (`V1.x`, `V2.x`, …) to keep
parallel work from colliding.

## Naming convention

| Prefix | Meaning | When applied |
|---|---|---|
| `V<version>__<desc>.sql` | Versioned | Once, in version order. Never re-run after applying. |
| `R__<desc>.sql` | Repeatable | Whenever its checksum changes, after all versioned scripts, alphabetically. |
| `A__<desc>.sql` | Always | Every run, last. |

Separator is **two** underscores; the description itself cannot contain `__`.

Anything **not** matching those three prefixes is ignored by schemachange. Two
conventions rely on this:

| Pattern | Purpose |
|---|---|
| `README.md` | folder documentation |
| `_reference__*.sql` | client-side commands recorded for traceability, never executed |

`_reference__*.sql` files hold operations that **cannot** live in a migration
because they do not run inside Snowflake — `PUT` / `snow stage copy` execute from
a workstation or CI runner. Keeping them in the repo makes the load
reproducible and reviewable; the leading underscore guarantees
`schemachange deploy` will not pick them up.

## Environment variables

| Var | DEV | QA | PROD |
|---|---|---|---|
| `database` | `SALES_DEV` | `SALES_QA` | `SALES_PROD` |
| `env` | `DEV` | `QA` | `PROD` |
| `object_type` | `TRANSIENT` | `TRANSIENT` | *(empty)* |
| `retention_days` | `1` | `1` | `7` |
| `governance_database` | `GOVERNANCE` | ← same | ← same |
| `dq_notification_email` | dev owner | QA owner | prod on-call list |

`object_type` is how architectural note 1 is honoured without forking scripts:
it renders `CREATE TRANSIENT DATABASE` in dev/QA and `CREATE DATABASE` in prod.

`governance_database` is deliberately **not** per-environment — all three
contexts share one governance DB, so a tag applied in dev carries the identical
definition in prod.

`dq_notification_email` **is** per-environment: a dev data-quality failure must
not page whoever owns prod. It must be a **verified** email on a user in the
account or `SYSTEM$SEND_EMAIL` fails. The rule of thumb across these vars is that
shared *definitions* are unsuffixed while per-context *state and routing* are
suffixed — compare `CHANGE_HISTORY_<ENV>` and `silver_dq_email_<ENV>`.

## Deploying

```bash
pip install schemachange==4.3.3   # pin the version; do not use --upgrade in CI

# dev
schemachange deploy --config-folder schemachange/config \
  --config-file-name schemachange-config-dev.yml --create-change-history-table

# qa  (only after the dev PR is merged)
schemachange deploy --config-folder schemachange/config \
  --config-file-name schemachange-config-qa.yml --create-change-history-table

# prod (only after business validation in qa)
schemachange deploy --config-folder schemachange/config \
  --config-file-name schemachange-config-prod.yml --create-change-history-table
```

Preview the rendered SQL without touching Snowflake:

```bash
schemachange render --config-folder schemachange/config \
  --config-file-name schemachange-config-dev.yml \
  schemachange/scripts/02_foundation/V2.1.1__create_environment_database.sql
```

Add `--dry-run` to `deploy` to see what would be applied.

## Promotion

Per the architecture diagram, objects move **up contexts via GitHub PR only** —
never by running ad-hoc DDL in QA or prod:

```
dev_branch ──PR──> qa_branch ──PR──> main
   │                  │                │
   └─> SALES_DEV      └─> SALES_QA     └─> SALES_PROD
```

Deployment history per context lives in
`GOVERNANCE.SCHEMACHANGE.CHANGE_HISTORY_<ENV>`.

## Architectural rules encoded here

| # | Rule | Where |
|---|---|---|
| 1 | Dev/QA objects `TRANSIENT`, no fail-safe cost | `object_type` var |
| 2 | Common objects in `COMMON` schema | `03_common/` |
| 3 | Tags/policies only in governance DB | `01_governance/` |
| 4 | Short, meaningful `COMMENT` on every object | all scripts |
| 5 | `CREATE ... IF NOT EXISTS`, never destructive | all scripts |
| 6 | Data-storing objects tagged for chargeback | `V2.1.3`, `V2.1.4` |

**One documented exception to rule 5:** `R__gold_semantic_view.sql` will use
`CREATE OR REPLACE`. A semantic view is a metadata definition holding no data,
and it must be restated in full to change a metric — reasoning in
`06_gold/README.md`.

## Current status

**Bronze and silver are complete in `SALES_DEV`. Gold is underway — `dim_country` is the first gold object.**

| Layer | Range | State |
|---|---|---|
| `01_governance` | V1.x | Done — `GOVERNANCE` DB, 2 schemas, 4 tags |
| `02_foundation` | V2.x | Done — `SALES_DEV` (transient) + `BRONZE`/`SILVER`/`GOLD`/`COMMON`, tags attached at DB and schema level |
| `03_common` | V3.x | Done — 2 CSV file formats, 6 sequences (`V3.1.2` is an intentional gap) |
| `04_bronze` | V4.x | Done — stage, 47 staged files, **13 tables loaded** |
| `05_silver` | V5.x | **Done — 13 dynamic tables, all INCREMENTAL and verified** |
| `06_gold` | V6.x | **In progress — `dim_country` (35, SCD-2), `dim_product` (650, SCD-1), `bridge_product_country` (22,750), `dim_store` (121, SCD-1), `dim_customer` (31,350, SCD-1, **unmasked PII**); all 5 DOWNSTREAM + INCREMENTAL** |
| `07_orchestration` | V7.x | Scaffold |
| `08_data_quality` | V8.x | **Done for silver — 31 checks, all passing; task created SUSPENDED** |

Only the **DEV** context exists; QA and prod are not built.

**Source data staged** — 47 files, 12.27 MB compressed, in
`@SALES_DEV.BRONZE.sales_csv_stg/initial-load/`:

| Folder | Files | Note |
|---|---|---|
| `country-master/` | 4 | region, country, currency, tax |
| `product-master/` | 5 | category, family, model, sku, country availability |
| `store-master/` | 1 | |
| `customer-master/2019/<CC>/` | 35 | 2019 only; 35 country codes |
| `sales-transaction/2019/` | 2 | header + item |

Years **2020–2025 are deliberately not staged** for customer and sales. Commands
used are recorded in `04_bronze/_reference__stage_upload_commands.sql`.

### Bronze script numbering

Not in the order the silver layer was built — verify before citing:

| Scripts | Domain |
|---|---|
| `V4.1.1` | stage |
| `V4.2.1` / `V4.2.2` | country master |
| `V4.3.1` / `V4.3.2` | **customer** master |
| `V4.4.1` / `V4.4.2` | **product** master |
| `V4.5.1` / `V4.5.2` | **store** master |
| `V4.6.1` / `V4.6.2` | sales transaction |

### Outstanding

| Item | Detail |
|---|---|
| `CHANGE_HISTORY_DEV` is empty | Dev was deployed by executing the rendered SQL directly, because the OAuth browser flow cannot complete unattended. Re-run `schemachange deploy` interactively to populate history; every script is `IF NOT EXISTS`, so re-applying is harmless. Do this **before** the QA promotion. |
| Masking policies | `sv_customer_master` holds 9 populated personal-data columns and no policy exists yet. Policies belong in `01_governance/` and are *attached* in silver. |
| FX-rate dimension | Absent, and it blocks all cross-currency revenue in gold. See `05_silver/README.md`. |
| Type-2 `sv_tax_master` | One row per country, so historical tax cannot be recomputed. |
| `06_gold` / `07_orchestration` | Scaffolds; each folder's README holds the rules and reserved range. Note sequences from `V3.1.3` **cannot** be used in dynamic tables — gold needs hash keys. |
| `08_data_quality` task suspended | `COMMON.t_silver_dq_checks` is created but not resumed, and `V8.2.1__resume_dq_check_task.sql` is deliberately **not** in the repo so a deploy cannot start it. Silver DTs have `TARGET_LAG = DOWNSTREAM` with no consumer, so they never refresh — a resumed task would record identical rows daily. Resume once V7.x ingest runs or gold exists. |
| DQ email path unverified | `SYSTEM$SEND_EMAIL` only fires on failure and nothing has failed. The recipient must be a verified account email. See `08_data_quality/README.md`. |

For the full data-quality picture — conventions, defect register, and rules that
were tested and rejected — read `scripts/05_silver/README.md`. For the executable
checks and why they are not built on Data Metric Functions (this account is
`STANDARD`; DMFs are Enterprise-only), read `scripts/08_data_quality/README.md`.
Repo-wide orientation is in `../AGENT.md`.
