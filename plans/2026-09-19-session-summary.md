# Session Summary — 2026-09-19

Apple Inc sales analytics platform: medallion architecture on Snowflake,
managed as code with schemachange. This document records what was built, the
decisions taken, and what remains.

- **Branch:** `dev_branch` (all work pushed here only; `main` and `qa_branch`
  deliberately untouched)
- **Account:** `YSIRCIU-VG28332` · role `ACCOUNTADMIN` · warehouse `COMPUTE_WH`
- **Commits:** `f8cee32`, `d7781ff` (this doc adds a third)

---

## 1. Objective

Build the dev context of a three-environment medallion platform from three
architecture diagrams, then capture the DDL as reusable change-management
scripts so QA and prod can be deployed from the same source.

Source diagrams (read-only reference, outside the repo):

```
__architectural_notes/
  medallion-architecture-with-dev-qa-prod.png
  architectural-important-notes.png
  architectural-data-flow-rules.png
```

---

## 2. What was deployed to Snowflake

### `GOVERNANCE` database (permanent)

| Object | Detail |
|---|---|
| `TAGS` schema | tag definitions |
| `SCHEMACHANGE` schema | deployment history per env |
| `TAGS.ENVIRONMENT` | allowed: `DEV`, `QA`, `PROD` |
| `TAGS.MEDALLION_LAYER` | allowed: `BRONZE`, `SILVER`, `GOLD`, `COMMON` |
| `TAGS.COST_CENTER` | open values (chargeback) |
| `TAGS.CHARGEBACK_OWNER` | open values (chargeback) |

### `SALES_DEV` database (TRANSIENT, 1-day retention)

| Object | Detail |
|---|---|
| `BRONZE` / `SILVER` / `GOLD` / `COMMON` | all TRANSIENT, all commented |
| `COMMON.ff_csv_infer` | `PARSE_HEADER=TRUE`, for `INFER_SCHEMA` |
| `COMMON.ff_csv_load` | `SKIP_HEADER=1`, for `COPY INTO` |
| `COMMON.stg_sales_landing` | internal stage, `DIRECTORY=(ENABLE=TRUE)` |
| `COMMON.seq_dim_*` | 6 surrogate-key sequences |

### Tag assignment (verified)

Three tags at **database** level, inherited downward; `MEDALLION_LAYER` set per
**schema** because its value differs per zone:

```
SALES_DEV                 ENVIRONMENT=DEV, COST_CENTER=..., CHARGEBACK_OWNER=...
  └─ BRONZE               + MEDALLION_LAYER=BRONZE   (resolves 4 tags total)
  └─ SILVER               + MEDALLION_LAYER=SILVER
  └─ GOLD                 + MEDALLION_LAYER=GOLD
  └─ COMMON               + MEDALLION_LAYER=COMMON
```

Confirmed via `TAG_REFERENCES`: BRONZE returns 3 rows at `DATABASE` level plus
1 at `SCHEMA` level. One assignment therefore covers every future table.

---

## 3. Repository layout

```
schemachange/                          20 files committed
├── README.md                          conventions, deploy commands, promotion
├── config/
│   ├── schemachange-config-dev.yml
│   ├── schemachange-config-qa.yml
│   └── schemachange-config-prod.yml
└── scripts/
    ├── 01_governance/    V1.1.1–V1.1.5   governance DB, schemas, 4 tags
    ├── 02_foundation/    V2.1.1–V2.1.4   env DB, 4 schemas, tag attachment
    ├── 03_common/        V3.1.1–V3.1.3   file formats, stage, sequences
    ├── 04_bronze/        README only     scaffold
    ├── 05_silver/        README only     scaffold
    ├── 06_gold/          README only     scaffold
    └── 07_orchestration/ README only     scaffold
```

Each folder owns a reserved version range so parallel work cannot collide —
schemachange requires globally unique version numbers and errors on duplicates.

### Multi-environment mechanism

One script set, three contexts, driven entirely by Jinja vars:

| Var | DEV | QA | PROD |
|---|---|---|---|
| `database` | `SALES_DEV` | `SALES_QA` | `SALES_PROD` |
| `env` | `DEV` | `QA` | `PROD` |
| `object_type` | `TRANSIENT` | `TRANSIENT` | *(empty)* |
| `retention_days` | `1` | `1` | `7` |
| `governance_database` | `GOVERNANCE` | ← same | ← same |

`object_type` renders `CREATE TRANSIENT DATABASE` in dev/QA and
`CREATE DATABASE` in prod — both renders were compile-verified.

---

## 4. Decisions and deviations

| # | Decision | Reason |
|---|---|---|
| 1 | Governance DB created now, not deferred | Note 3 requires tags there; deferring would have forced tags into `COMMON` and a later migration. |
| 2 | Renamed `SALES_GOVERNANCE` → `GOVERNANCE` | Shared across all three contexts; `SALES_` prefix was misleading. Rename preserved contents. |
| 3 | Governance DB is permanent, not transient | Note 1 scopes TRANSIENT to dev/QA *data*; losing tag definitions or deploy history is worse than the storage cost. |
| 4 | No Jinja macros module | Self-contained scripts read better than indirection for this volume. |
| 5 | Scaffolds are `README.md`, not placeholder `.sql` | schemachange only reads `V`/`R`/`A`-prefixed SQL, so markdown cannot break a deploy. Placeholder SQL would. |
| 6 | Semantic view will be `R__` + `CREATE OR REPLACE` | Documented exception to note 5. A semantic view holds no data and must be restated in full to change a metric; `IF NOT EXISTS` would make it unmaintainable. |
| 7 | Deployed via direct SQL, not `schemachange deploy` | OAuth browser flow could not complete from a non-interactive shell. See open item 1. |

### Correctness note carried into gold

`COMMON.seq_dim_*` sequences **must not be called inside a dynamic table.** A
sequence is non-deterministic, so incremental and full refreshes would mint
different keys, forcing the table to `FULL` refresh mode at best. Gold dynamic
dimensions should use a deterministic surrogate such as `HASH(natural_key)`.
The sequences remain useful for any procedure-maintained SCD2 dimension.

---

## 5. Also done this session

- **Dropped `SALES_DEV`** (an earlier hardcoded build) before rebuilding it
  from templated scripts.
- **Removed `coco_web_user` completely** — Snowflake user, its
  `DROPPED_USER$...` personal database, workspace, `connections.toml` entry,
  private key, public key, and a temporary backup.

---

## 6. Open items

| # | Item | Detail |
|---|---|---|
| 1 | `CHANGE_HISTORY_DEV` is empty | Objects exist but schemachange never ran, so nothing was recorded. Fix by running the real deploy — all 12 scripts are `IF NOT EXISTS`, so re-applying is harmless and populates history. **Do this before the QA PR**, or QA becomes the first env with tracked history while dev has none. |
| 2 | Bronze → orchestration unwritten | Blocked on the 12 source CSV headers in `__initial_load`; a read attempt was denied. Bronze needs them for `INFER_SCHEMA`-derived structures, silver/gold for modelling. |
| 3 | `connections.toml` is `0o666` | World-writable credentials file, flagged by schemachange. Unresolved. |
| 4 | Key-pair auth rejected | `coco_web_user`'s JWT was refused by an authentication policy. Unattended CI/CD will need a service user whose key-pair auth the policy permits. |

### Recovering DCM history

```bash
cd C:\Users\X1Carbon\cortex
schemachange deploy --config-folder schemachange/config \
  --config-file-name schemachange-config-dev.yml --create-change-history-table
```

Must be run interactively so the OAuth browser redirect can complete.

---

## 7. Gotchas worth remembering

- **PowerShell `-Encoding UTF8` adds a BOM.** Writing `connections.toml` that
  way made `cortex connections list` return zero connections. Use
  `UTF8Encoding($false)` for TOML/YAML.
- **`ALTER DATABASE ... RENAME TO` preserves contents** — schemas and tags
  carried over intact.
- **Dropping a user does not delete their personal database.** It is renamed to
  `DROPPED_USER$<user>_<id>` and reassigned to `ACCOUNTADMIN`, and must be
  dropped separately.
- **`TAG_REFERENCES_ALL_COLUMNS` is table-only.** Use `TAG_REFERENCES` for
  database- and schema-level tags.
- **Snowflake ownership is by role, not user** — so which user deploys does not
  change the resulting objects, provided the role matches.
