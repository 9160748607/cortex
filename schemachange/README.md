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
    ├── 01_governance/      V1.x  governance DB, schemas, tag definitions
    ├── 02_foundation/      V2.x  environment DB, 4 schemas, tag attachment
    ├── 03_common/          V3.x  file formats, landing stage, sequences
    ├── 04_bronze/          V4.x  raw landing tables            (scaffold)
    ├── 05_silver/          V5.x  cleaned dynamic tables        (scaffold)
    ├── 06_gold/            V6.x  facts, dims, agg, semantic view (scaffold)
    └── 07_orchestration/   V7.x  ingest task                   (scaffold)
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

`01_governance`, `02_foundation` and `03_common` are complete and compile-checked.

`04_bronze` through `07_orchestration` are **scaffolds** — each folder's
`README.md` records the rules, the reserved version range and the planned file
names. They contain no `.sql`, so `schemachange deploy` runs cleanly today.
Writing them needs the 12 source CSV headers from `__initial_load`.
