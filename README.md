# rdc-reporting

Country-specific **analytics-extension** package for OpenLMIS DRC (LOGIMEV), layered on top of [openlmis-reporting (analytics-core)](https://github.com/OpenLMIS/openlmis-reporting) and consumed by the [reporting-stack platform](https://github.com/SolDevelo/soldevelo-reporting-stack).

Extensions are additive only: they add dbt models and Superset dashboards but must not modify core models/dashboards or change ingestion contracts. The CDC table list is owned by the deployment (`rdc-deployment/<env>/reporting-stack/reporting-stack-cdc.sql` and `SOURCE_PG_TABLE_ALLOWLIST` in `rdc-configuration`), not by this package.

This package replaces the DRC-specific layer of the legacy Postgres reporting stack (the `analytics.*` star schema, the `public.vw_*` views, the daily `stock_daily_history` aggregation and the three French Superset dashboards). The object-by-object mapping is in [docs/reporting-stack-migration.md](docs/reporting-stack-migration.md); the delivery order is in [docs/plan.md](docs/plan.md).

## Directory structure

```
rdc-reporting/
  manifest.yaml                          # Package metadata (type: extension)

  dbt/
    dbt_project.yml
    seeds/                               # drc_* seeds (none yet)
    models/
      staging/                           # drc_stg_* current-state views for source tables
                                         # that core does not stage (stockmanagement,
                                         # fulfillment, lots, program_orderables, ...)
      intermediate/                      # drc_int_* building blocks shared by several marts
                                         # (the daily stock series)
      marts/                             # mart_drc_* marts, one per legacy view/dataset
    macros/                              # drc_* macros (French month names)
    tests/                               # singular tests (daily carry-forward check)

  superset/
    assets/
      metadata.yaml
      databases/reporting_clickhouse.yaml   # re-declares the core DB UUID for import
      datasets/reporting_clickhouse/        # one YAML per mart
      charts/
      dashboards/                           # Suivi des commandes, Suivi journalier des
                                            # stocks, Suivi mensuel des stocks
  docs/
    reporting-stack-migration.md         # legacy object -> target mapping and risks
    plan.md                              # phased delivery plan
    daily-snapshot-design.md             # Phase 5 design of the daily stock series
```

## Conventions

- dbt model names carry a `drc_` / `mart_drc_` prefix. The platform validator rejects any name that also exists in core.
- Superset asset UUIDs must be unique across core and this package, and are newly generated, not reused from the legacy DRC export (plan decision 3). The database YAML is the exception: it re-declares the core database UUID.
- Virtual datasets are written in ClickHouse SQL and carry `source_db_engine: clickhousedb`; without it `superset import-directory` transpiles the SQL from a generic dialect and rewrites `dateDiff` arguments.
- Marts `ref()` core marts (`mart_stock_status`, `mart_facility_directory`, `mart_requisition_summary`, ...) wherever the legacy view was a thin wrapper over the same data. Only build from staging when core has no equivalent.
- Column names are the ones the RDC team defined in the legacy views and datasets, kept verbatim (French in the `vw_*` line, English in the `analytics.*` star schema). When a mart builds on a core mart, core columns are aliased back to the legacy names. Display labels go in the dataset YAML `verbose_name`. This keeps the existing charts and the Power BI model valid without a column remap.
- Assets are authored in the Superset UI against dev, exported from there, merged into `superset/assets/` with `scripts/merge-superset-export.py` and committed as YAML (see [Changing charts and dashboards](#changing-charts-and-dashboards)).

## Usage

With the platform repo checked out, set in its `.env` (on the dev host this is `rdc-configuration/dev_env/.env.reporting-stack`):

```env
ANALYTICS_CORE_GIT_URL=https://github.com/OpenLMIS/openlmis-reporting.git
ANALYTICS_CORE_GIT_REF=main
ANALYTICS_CORE_PATH=.packages/core

ANALYTICS_EXTENSION_GIT_URLS=https://github.com/OpenLMIS-RDC/rdc-reporting.git
ANALYTICS_EXTENSION_GIT_REFS=master
ANALYTICS_EXTENSIONS_PATHS=.packages/extensions/rdc-reporting
```

For local development point `ANALYTICS_EXTENSIONS_PATHS` at a checkout of this repo instead. Then:

```bash
make package-validate   # extend-only rules, name and UUID collisions
make dbt-build          # deps + build (seeds, staging, marts, tests)
make superset-import    # import datasets, charts, dashboards
make verify-packages    # all of the above plus dashboard checks
```

## Changing charts and dashboards

Every deploy re-imports `superset/assets/` and overwrites what has the same UUID, so a change made only in the Superset UI is lost on the next deploy. To keep a change:

1. Build or change the charts and dashboards in the Superset UI on dev.
2. Export each changed dashboard: dashboard `...` menu -> Download -> Export YAML. The ZIP holds the dashboard with its charts and datasets.
3. Merge the export into this repo (needs PyYAML once: `python3 -m pip install pyyaml`):

   ```bash
   python3 scripts/merge-superset-export.py ~/Downloads/dashboard_export_<timestamp>.zip --dry-run
   python3 scripts/merge-superset-export.py ~/Downloads/dashboard_export_<timestamp>.zip
   ```

   The script overwrites the existing files by UUID, names new assets without Superset's id suffix, leaves `databases/` alone, sets `source_db_engine: clickhousedb` on SQL datasets and writes readable YAML. With `--core <openlmis-reporting checkout>` it also skips core assets that a dashboard happens to use.
4. Review `git diff`, commit and push, then run the deploy job.

Notes:

- The first export of an asset that was written by hand also adds the fields Superset always exports (`null` column attributes, `annotation_layers`) and drops `is_managed_externally`. Later exports only show real changes. Numeric `chartId` values follow the Superset instance and may change; the import maps charts by UUID.
- Deleting a chart or dashboard in Superset does not delete its YAML: remove the file by hand, or the next deploy brings it back.
- A new dashboard that should open inside OpenLMIS also needs embedding switched on in Superset and a dashboard report with that Embedded UUID in OpenLMIS (see `superset/assets/embedded.yaml`).

## Verification against the legacy stack

The legacy Postgres reporting database stays available during the migration. For every DRC mart, run the legacy view SQL and the new mart over the same period and diff the aggregates. Record every deviation, including legacy bugs being fixed, in `docs/reporting-stack-migration.md` before users ask.
