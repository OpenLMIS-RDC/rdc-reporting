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
    seeds/
      drc_reporting_dates.csv            # Reporting-rate cut-offs (legacy public.reporting_dates)
    models/
      staging/                           # drc_stg_* current-state views for source tables
                                         # that core does not stage (stockmanagement,
                                         # fulfillment, lots, program_orderables, ...)
      marts/                             # mart_drc_* marts, one per legacy view/dataset

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
```

## Conventions

- dbt model names carry a `drc_` / `mart_drc_` prefix. The platform validator rejects any name that also exists in core.
- Superset asset UUIDs must be unique across core and this package. The legacy DRC export UUIDs have been checked for collisions and may be reused for traceability.
- Marts `ref()` core marts (`mart_stock_status`, `mart_facility_directory`, `mart_requisition_summary`, ...) wherever the legacy view was a thin wrapper over the same data. Only build from staging when core has no equivalent.
- Column names of the legacy `analytics.*` objects are preserved where practical so the Power BI model can be re-pointed later with a documented mapping.
- Assets are authored in the Superset UI against dev, exported with the platform's import/export scripts, and committed as YAML.

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

## Verification against the legacy stack

The legacy Postgres reporting database stays available during the migration. For every DRC mart, run the legacy view SQL and the new mart over the same period and diff the aggregates. Record every deviation, including legacy bugs being fixed, in `docs/reporting-stack-migration.md` before users ask.
