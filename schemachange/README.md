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
    ├── 04_bronze/        V4.x  landing stage (done), raw tables (pending)
    ├── 05_silver/        V5.x  cleaned dynamic tables        (scaffold)
    ├── 06_gold/          V6.x  facts, dims, agg, semantic view (scaffold)
    └── 07_orchestration/ V7.x  ingest task                   (scaffold)
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

`object_type` is how architectural note 1 is honoured without forking scripts:
it renders `CREATE TRANSIENT DATABASE` in dev/QA and `CREATE DATABASE` in prod.

`governance_database` is deliberately **not** per-environment — all three
contexts share one governance DB, so a tag applied in dev carries the identical
definition in prod.

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

**Deployed to `SALES_DEV`** — 12 versioned scripts applied and verified:
`GOVERNANCE` (4 tags, 2 schemas), `SALES_DEV` (transient) with `BRONZE`/`SILVER`/
`GOLD`/`COMMON`, tags attached at database and schema level, 2 CSV file formats,
6 sequences, and the `sales_csv_stg` landing stage.

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

No `COPY INTO` has run — bronze tables do not exist yet.

### Outstanding

| Item | Detail |
|---|---|
| `CHANGE_HISTORY_DEV` is empty | Dev was deployed by executing the rendered SQL directly, because the OAuth browser flow cannot complete unattended. Re-run `schemachange deploy` interactively to populate history; all 12 scripts are `IF NOT EXISTS`, so re-applying is harmless. Do this **before** the QA promotion. |
| Bronze tables (`V4.2.x`) | Now unblocked — files are staged, so `INFER_SCHEMA` can derive structures against `COMMON.ff_csv_infer`. |
| `05_silver` / `06_gold` / `07_orchestration` | Scaffolds; each folder's README holds the rules and reserved version range. |
