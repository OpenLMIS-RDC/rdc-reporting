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
- Assets are authored in the Superset UI against dev, exported from there, merged into `superset/assets/` with `scripts/merge-superset-export.sh` and committed as YAML (see [Changing charts and dashboards](#changing-charts-and-dashboards)).

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

`make package-validate` also reports the core database UUID that `databases/reporting_clickhouse.yaml` re-declares and exits non-zero, so `make verify-packages` stops at validation too. That collision is expected; any other one is real.

## Changing charts and dashboards

Every deploy re-imports `superset/assets/` and overwrites what has the same UUID, so a change made only in the Superset UI is lost on the next deploy. To keep a change:

1. Build or change the charts and dashboards in the Superset UI on dev. Use datasets from this package only: the platform imports each package on its own, so a DRC chart on a core dataset, or a core chart on a DRC dashboard, does not survive the import. For data from a core mart, create a SQL dataset on it.
2. Export the dashboards you changed. One dashboard: its `...` menu -> Download -> Export YAML. Several: Dashboards list -> Bulk select, tick them, Export. Either way you get one ZIP with the dashboards and their charts and datasets. Export only what you changed (see the note on shared dev below). An export of every dashboard still merges, because the script skips the core ones, but it also brings in whatever else differs on dev.
3. Merge the export into this repo. The script needs bash, unzip and the usual Unix tools (awk, sed, grep, find, xargs). On Windows, run it from Git Bash or WSL. It also needs an up-to-date clone of [openlmis-reporting](https://github.com/OpenLMIS/openlmis-reporting) on `main` next to this repo, as `../openlmis-reporting`. If your clone is elsewhere, pass `--core PATH`.

   ```bash
   git clone https://github.com/OpenLMIS/openlmis-reporting.git ../openlmis-reporting   # once
   git -C ../openlmis-reporting pull                                                  # before each merge
   scripts/merge-superset-export.sh --dry-run ~/Downloads/dashboard_export_<timestamp>.zip
   scripts/merge-superset-export.sh ~/Downloads/dashboard_export_<timestamp>.zip
   ```

   It overwrites the existing files by UUID, names new assets without Superset's id suffix, skips `databases/` and core assets, adds `source_db_engine: clickhousedb` to SQL datasets and stops on duplicate UUIDs. It also stops, writing nothing, when a chart or dashboard uses a core chart or dataset, or when a new dataset points at the same table as an existing one under another UUID, which happens when a dataset is deleted and recreated in Superset. Pass one export per run: the ZIP, or the folder you unzipped it into if you have no unzip. Files keep the format Superset writes.
4. Review `git diff`, commit only the files you meant to change and open a PR. The dev deploy takes this repo from `master`, so the change is kept once the PR is merged. SolDevelo reviews the PR. After the merge, SolDevelo runs the Jenkins job `rdc-OpenLMIS-3.0-deploy-to-dev` with `KEEP_OR_RESTORE=keep` and `SKIP_REPORTING_STACK=0` to check that the merged files import. Never run it before the merge: it re-imports everything from `master`, which overwrites UI changes on dev that are not merged yet (anyone's), and it redeploys OpenLMIS as well. A green job does not prove the import worked, so search its log for `An error occurred` and open the dashboard.

Notes:

- Dev Superset is shared, and an export takes the current state of everything on the dashboard there. Export right after your change, keep one person per dashboard at a time and keep the PR short: if a deploy or someone else's work changes dev in between, the next export brings that into your branch.
- The first export of an asset that was written by hand rewrites the whole file in Superset's format: accents as escapes (`\xE9`), SQL and CSS as quoted strings, Superset's key order and the fields it always exports. Later exports change only the lines that changed, though accented text still shows as escapes in the diff.
- Numeric `chartId` values, and chart ids in filter scopes, follow the Superset instance, so an export from another instance changes them. The import maps charts by UUID.
- Deleting a chart or dashboard in Superset does not delete its YAML: remove the file by hand, or the next deploy brings it back.
- A new dashboard that should open inside OpenLMIS also needs embedding switched on in Superset, which then shows the dashboard's Embedded UUID, and a dashboard report with that UUID in OpenLMIS. Record the slug and UUID in `superset/assets/embedded.yaml` as well; no deploy applies that file yet. A deploy with `KEEP_OR_RESTORE=restore` wipes Superset's database and replaces the OpenLMIS database from a snapshot, so embedding has to be switched on again (with a new UUID to enter in OpenLMIS) and a dashboard report added after that snapshot has to be added again.

## Verification against the legacy stack

The legacy Postgres reporting database stays available during the migration. For every DRC mart, run the legacy view SQL and the new mart over the same period and diff the aggregates. Record every deviation, including legacy bugs being fixed, in `docs/reporting-stack-migration.md` before users ask.
