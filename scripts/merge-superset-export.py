#!/usr/bin/env python3
"""Merge a Superset export ZIP into superset/assets/.

Charts and dashboards are built in the Superset UI and exported from there
(dashboard "..." menu -> Download -> Export YAML). The export cannot be copied
into superset/assets/ as it is:

- Superset names files <name>_<id>.yaml, while the files here have no id
  suffix. Copying a re-export next to the existing files leaves two files with
  the same UUID, and the import then keeps one of them at random.
- It carries databases/reporting_clickhouse.yaml, which must stay as it is here
  (core database UUID, no password).
- It drops `source_db_engine: clickhousedb` from SQL (virtual) datasets. Without
  it `superset import-directory` transpiles their SQL from a generic dialect and
  breaks ClickHouse functions such as dateDiff.
- It writes accented text as escapes ("r\\xE9quisition") and SQL and CSS as
  single escaped strings, so every diff would be unreadable.

This script overwrites existing files by UUID, gives new assets an id-less
name, skips databases/ and metadata.yaml, sets source_db_engine on SQL datasets,
rewrites the YAML in the readable style used here (plain accents, SQL and CSS as
blocks, keys in the order of the existing file) and refuses to leave two files
with the same UUID. Review `git diff` afterwards.

Usage:
  python3 scripts/merge-superset-export.py EXPORT.zip [--core PATH] [--dry-run]

EXPORT can also be an unzipped export directory. --core points at a checkout of
openlmis-reporting (or its superset/assets); assets that belong to core are then
skipped instead of copied here. Needs PyYAML (python3 -m pip install pyyaml).
"""

import argparse
import re
import sys
import unicodedata
import zipfile
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("This script needs PyYAML: python3 -m pip install pyyaml")

REPO_ROOT = Path(__file__).resolve().parent.parent
ASSETS = REPO_ROOT / "superset" / "assets"
KINDS = ("charts", "dashboards", "datasets")
SOURCE_DB_ENGINE = "clickhousedb"
ID_SUFFIX_RE = re.compile(r"_\d+$")


class AssetDumper(yaml.SafeDumper):
    """Indent list items under their key, as in the files here."""

    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


def _represent_str(dumper, value):
    style = "|" if "\n" in value else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)


AssetDumper.add_representer(str, _represent_str)


def dump(data):
    text = yaml.dump(data, Dumper=AssetDumper, sort_keys=False, allow_unicode=True)
    if yaml.safe_load(text) != data:
        raise ValueError("re-serialised YAML does not load back to the same data")
    return text


def ordered_like(data, reference):
    """Return data with dict keys in the reference's order; keys new to it go last."""
    if isinstance(data, dict) and isinstance(reference, dict):
        keys = [k for k in reference if k in data] + [k for k in data if k not in reference]
        return {k: ordered_like(data[k], reference.get(k)) for k in keys}
    if isinstance(data, list) and isinstance(reference, list) and len(data) == len(reference):
        return [ordered_like(d, r) for d, r in zip(data, reference)]
    return data


def uuid_of(data):
    value = data.get("uuid") if isinstance(data, dict) else None
    return str(value).lower() if value else None


def read_export(source):
    """Return {relative path: text} for the YAML files in an export ZIP or directory."""
    files = {}
    if source.is_dir():
        for path in sorted(source.rglob("*.yaml")):
            files[path.relative_to(source).as_posix()] = path.read_text(encoding="utf-8")
    else:
        with zipfile.ZipFile(source) as archive:
            for name in sorted(archive.namelist()):
                if name.endswith(".yaml"):
                    files[name] = archive.read(name).decode("utf-8")
    # A Superset export wraps everything in one top-level folder
    # (dashboard_export_<timestamp>/); drop it.
    tops = {name.split("/", 1)[0] for name in files}
    if len(tops) == 1 and all("/" in name for name in files):
        files = {name.split("/", 1)[1]: text for name, text in files.items()}
    return files


def index_assets(root):
    """Map UUID -> list of files under the charts/, dashboards/ and datasets/ folders."""
    index = {}
    for kind in KINDS:
        for path in sorted((root / kind).rglob("*.yaml")):
            uuid = uuid_of(yaml.safe_load(path.read_text(encoding="utf-8")))
            if uuid:
                index.setdefault(uuid, []).append(path)
    return index


def duplicates(index):
    return {uuid: paths for uuid, paths in index.items() if len(paths) > 1}


def core_uuids(core):
    if core is None:
        return set()
    assets = core / "superset" / "assets" if (core / "superset" / "assets").is_dir() else core
    if not assets.is_dir():
        sys.exit(f"--core: {core} is neither openlmis-reporting nor its superset/assets folder")
    return {uuid_of(yaml.safe_load(p.read_text(encoding="utf-8"))) for p in assets.rglob("*.yaml")} - {None}


def slug(name):
    """Turn an exported file name into the id-less, lower-case name used here."""
    name = ID_SUFFIX_RE.sub("", name)
    name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")


def new_path(kind_dir, stem, uuid, taken):
    base = slug(stem) or uuid
    path = kind_dir / f"{base}.yaml"
    counter = 2
    while path.exists() or path in taken:
        path = kind_dir / f"{base}_{counter}.yaml"
        counter += 1
    return path


def relative(path):
    return path.relative_to(REPO_ROOT).as_posix()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("export", type=Path, help="Superset export ZIP or unzipped export directory")
    parser.add_argument("--core", type=Path, help="openlmis-reporting checkout, to skip core assets")
    parser.add_argument("--dry-run", action="store_true", help="show what would change, write nothing")
    args = parser.parse_args()

    if not args.export.exists():
        sys.exit(f"{args.export}: not found")

    existing = index_assets(ASSETS)
    clashes = duplicates(existing)
    if clashes:
        for uuid, paths in clashes.items():
            print(f"ERROR: UUID {uuid} is in more than one file: {', '.join(relative(p) for p in paths)}")
        sys.exit("Fix the duplicates in superset/assets/ first (keep one file per UUID).")

    database_uuids = {
        uuid_of(yaml.safe_load(p.read_text(encoding="utf-8"))) for p in (ASSETS / "databases").glob("*.yaml")
    }
    core = core_uuids(args.core)

    added, updated, unchanged, skipped, errors = [], [], [], [], []
    planned = {}  # target path -> text
    seen = set()
    for name, text in read_export(args.export).items():
        parts = name.split("/")
        if name == "metadata.yaml":
            continue
        if parts[0] == "databases":
            skipped.append(f"{name} (database connection stays as it is in this repo)")
            continue
        if parts[0] not in KINDS:
            skipped.append(f"{name} (not a chart, dashboard or dataset)")
            continue

        data = yaml.safe_load(text)
        uuid = uuid_of(data)
        if not uuid:
            errors.append(f"{name}: no top-level uuid")
            continue
        if uuid in core:
            skipped.append(f"{name} (core asset, it lives in openlmis-reporting)")
            continue
        if uuid in seen:
            errors.append(f"{name}: the export has UUID {uuid} more than once")
            continue
        seen.add(uuid)

        if parts[0] == "datasets":
            if str(data.get("database_uuid", "")).lower() not in database_uuids:
                errors.append(f"{name}: dataset is not on the reporting_clickhouse database")
                continue
            if data.get("sql"):
                data["source_db_engine"] = SOURCE_DB_ENGINE

        if uuid in existing:
            target = existing[uuid][0]
            data = ordered_like(data, yaml.safe_load(target.read_text(encoding="utf-8")))
        else:
            target = new_path(ASSETS.joinpath(*parts[:-1]), Path(parts[-1]).stem, uuid, planned)

        try:
            text = dump(data)
        except ValueError as error:
            errors.append(f"{name}: {error}")
            continue
        planned[target] = text
        if not target.exists():
            added.append(target)
        elif target.read_text(encoding="utf-8") != text:
            updated.append(target)
        else:
            unchanged.append(target)

    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        sys.exit("Nothing was written.")

    if not args.dry_run:
        for target in added + updated:
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, "w", encoding="utf-8", newline="") as handle:
                handle.write(planned[target])
        clashes = duplicates(index_assets(ASSETS))
        if clashes:
            for uuid, paths in clashes.items():
                print(f"ERROR: UUID {uuid} is now in: {', '.join(relative(p) for p in paths)}")
            sys.exit("Duplicate UUIDs after the merge; check the files above.")

    for label, paths in (("add", added), ("update", updated)):
        for path in paths:
            print(f"{'Would ' + label if args.dry_run else label.capitalize()}: {relative(path)}")
    for item in skipped:
        print(f"Skipped: {item}")
    print(f"\n{len(added)} added, {len(updated)} updated, {len(unchanged)} unchanged, {len(skipped)} skipped.")
    if args.core is None:
        print("Core check skipped (no --core); `make package-validate` still catches core UUIDs.")
    if any(p.parent.name == "dashboards" for p in added):
        print("New dashboard: to show it inside OpenLMIS, enable embedding on it in Superset and add a"
              " dashboard report with that Embedded UUID in OpenLMIS.")
    if not args.dry_run and (added or updated):
        print("Next: review `git diff`, commit, push, then run the deploy job.")


if __name__ == "__main__":
    main()
