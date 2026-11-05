#!/usr/bin/env bash
# Merge a Superset export into superset/assets/.
#
# Charts and dashboards are built in the Superset UI and exported from there
# (dashboard "..." menu -> Download -> Export YAML). The export cannot be copied
# into superset/assets/ as it is:
#
# - Superset names files <name>_<id>.yaml, while the files here have no id
#   suffix. Copying a re-export next to the existing files leaves two files with
#   the same UUID, and the import then keeps one of them at random.
# - It carries databases/reporting_clickhouse.yaml, which must stay as it is
#   here (core database UUID, no password).
# - It drops `source_db_engine: clickhousedb` from SQL (virtual) datasets.
#   Without it `superset import-directory` transpiles their SQL from a generic
#   dialect and breaks ClickHouse functions such as dateDiff.
#
# This script overwrites existing files by UUID, gives new assets an id-less
# name, skips databases/ and metadata.yaml, adds source_db_engine to SQL
# datasets and refuses to leave two files with the same UUID. Files are copied
# as Superset writes them. Review `git diff` afterwards.
#
# Needs bash (the 3.2 that ships with macOS is enough), grep, sed and, for a
# ZIP, unzip.

set -eu
export LC_ALL=C

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ASSETS="$REPO_ROOT/superset/assets"
SOURCE_DB_ENGINE=clickhousedb
TAB=$'\t'

usage() {
  cat <<'EOF'
Usage: scripts/merge-superset-export.sh [--dry-run] [--core PATH] EXPORT

  EXPORT     Superset export ZIP, or the unzipped export folder
  --dry-run  show what would change, write nothing
  --core     openlmis-reporting checkout (or its superset/assets); core assets
             in the export are then skipped instead of copied here
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

relative() {
  printf '%s\n' "${1#"$REPO_ROOT"/}"
}

# Top-level value of a YAML key, without surrounding double quotes.
top_value() {
  sed -n "s/^$1:[[:space:]]*//p" "$2" | head -n 1 | sed -e 's/^"//' -e 's/"[[:space:]]*$//' -e 's/[[:space:]]*$//'
}

uuid_of() {
  top_value uuid "$1" | tr 'A-F' 'a-f'
}

# Writes "uuid<TAB>path" for every chart, dashboard and dataset file under $1 to $2.
index_assets() {
  : > "$2"
  for kind in charts dashboards datasets; do
    [ -d "$1/$kind" ] || continue
    find "$1/$kind" -type f -name '*.yaml' | sort | while IFS= read -r file; do
      uuid=$(uuid_of "$file")
      if [ -n "$uuid" ]; then
        printf '%s\t%s\n' "$uuid" "$file"
      fi
    done >> "$2"
  done
}

# Prints the UUIDs that more than one file in index $1 carries; fails if there are any.
check_duplicates() {
  dups=$(cut -f1 "$1" | sort | uniq -d)
  [ -z "$dups" ] && return 0
  for uuid in $dups; do
    printf 'ERROR: UUID %s is in more than one file:' "$uuid"
    grep "^$uuid$TAB" "$1" | cut -f2 | while IFS= read -r file; do
      printf ' %s' "$(relative "$file")"
    done
    echo
  done
  return 1
}

add_source_db_engine() {
  if grep -q '^source_db_engine:' "$1"; then
    sed "s/^source_db_engine:.*/source_db_engine: $SOURCE_DB_ENGINE/" "$1" > "$1.tmp"
    mv "$1.tmp" "$1"
  else
    if [ -n "$(tail -c 1 "$1")" ]; then
      echo >> "$1"
    fi
    echo "source_db_engine: $SOURCE_DB_ENGINE" >> "$1"
  fi
}

# Id-less, lower-case file name for a new asset; numbered if the name is taken.
new_path() {
  dir=$1
  base=$(printf '%s' "$2" | sed 's/_[0-9][0-9]*$//' | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9][^a-z0-9]*/_/g' -e 's/^_//' -e 's/_$//')
  [ -n "$base" ] || base=$3
  path="$dir/$base.yaml"
  counter=2
  while [ -e "$path" ] || cut -f3 "$WORK/plan" | grep -qxF "$path"; do
    path="$dir/${base}_$counter.yaml"
    counter=$((counter + 1))
  done
  printf '%s\n' "$path"
}

DRY_RUN=0
CORE=""
EXPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --core)
      [ $# -ge 2 ] || die "--core needs a path"
      CORE=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      [ -z "$EXPORT" ] || die "Pass one export at a time."
      EXPORT=$1
      ;;
  esac
  shift
done
[ -n "$EXPORT" ] || {
  usage >&2
  exit 1
}
[ -e "$EXPORT" ] || die "$EXPORT: not found"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/merge-superset-export.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/plan"
: > "$WORK/errors"
: > "$WORK/skipped"
: > "$WORK/seen"
: > "$WORK/core"

if [ -d "$EXPORT" ]; then
  SRC=${EXPORT%/}
else
  command -v unzip > /dev/null 2>&1 || die "unzip not found: unzip the export and pass the folder instead."
  mkdir "$WORK/export"
  unzip -q "$EXPORT" -d "$WORK/export" || die "$EXPORT: could not unzip it."
  SRC="$WORK/export"
fi
# A Superset export wraps everything in one top-level folder (dashboard_export_<timestamp>/).
if [ ! -e "$SRC/metadata.yaml" ]; then
  for dir in "$SRC"/*/; do
    if [ -e "$dir/metadata.yaml" ]; then
      SRC=${dir%/}
      break
    fi
  done
fi

index_assets "$ASSETS" "$WORK/index"
if ! check_duplicates "$WORK/index"; then
  die "Fix the duplicates in superset/assets/ first (keep one file per UUID)."
fi

for file in "$ASSETS"/databases/*.yaml; do
  uuid_of "$file"
done > "$WORK/databases"

if [ -n "$CORE" ]; then
  if [ -d "$CORE/superset/assets" ]; then
    CORE="$CORE/superset/assets"
  elif [ ! -d "$CORE" ]; then
    die "--core: $CORE is neither openlmis-reporting nor its superset/assets folder"
  fi
  find "$CORE" -type f -name '*.yaml' | while IFS= read -r file; do
    uuid=$(uuid_of "$file")
    if [ -n "$uuid" ]; then
      echo "$uuid"
    fi
  done > "$WORK/core"
fi

count=0
find "$SRC" -type f -name '*.yaml' | sort > "$WORK/files"
while IFS= read -r file; do
  rel=${file#"$SRC"/}
  case "$rel" in
    metadata.yaml) continue ;;
    databases/*)
      echo "$rel (database connection stays as it is in this repo)" >> "$WORK/skipped"
      continue
      ;;
    charts/* | dashboards/* | datasets/*) ;;
    *)
      echo "$rel (not a chart, dashboard or dataset)" >> "$WORK/skipped"
      continue
      ;;
  esac

  uuid=$(uuid_of "$file")
  if [ -z "$uuid" ]; then
    echo "$rel: no top-level uuid" >> "$WORK/errors"
    continue
  fi
  if grep -qxF "$uuid" "$WORK/core"; then
    echo "$rel (core asset, it lives in openlmis-reporting)" >> "$WORK/skipped"
    continue
  fi
  if grep -qxF "$uuid" "$WORK/seen"; then
    echo "$rel: the export has UUID $uuid more than once" >> "$WORK/errors"
    continue
  fi
  echo "$uuid" >> "$WORK/seen"

  count=$((count + 1))
  staged="$WORK/staged.$count"
  cp "$file" "$staged"
  case "$rel" in
    datasets/*)
      database=$(top_value database_uuid "$file" | tr 'A-F' 'a-f')
      if [ -z "$database" ] || ! grep -qxF "$database" "$WORK/databases"; then
        echo "$rel: dataset is not on the reporting_clickhouse database" >> "$WORK/errors"
        continue
      fi
      case "$(top_value sql "$file")" in
        "" | null | "~" | "''") ;;
        *) add_source_db_engine "$staged" ;;
      esac
      ;;
  esac

  target=$(grep "^$uuid$TAB" "$WORK/index" | head -n 1 | cut -f2)
  if [ -z "$target" ]; then
    target=$(new_path "$ASSETS/${rel%/*}" "$(basename "$rel" .yaml)" "$uuid")
  fi
  if [ ! -e "$target" ]; then
    action=add
  elif cmp -s "$staged" "$target"; then
    action=same
  else
    action=update
  fi
  printf '%s\t%s\t%s\n' "$action" "$staged" "$target" >> "$WORK/plan"
done < "$WORK/files"

if [ -s "$WORK/errors" ]; then
  sed 's/^/ERROR: /' "$WORK/errors"
  die "Nothing was written."
fi
[ -s "$WORK/plan" ] || [ -s "$WORK/skipped" ] || die "$EXPORT holds no charts, dashboards or datasets."

if [ "$DRY_RUN" -eq 0 ]; then
  while IFS="$TAB" read -r action staged target; do
    case "$action" in
      add | update)
        # cat rather than cp: the export ZIP stores files as 0600, and a new
        # file should get the usual permissions.
        mkdir -p "$(dirname "$target")"
        cat "$staged" > "$target"
        ;;
    esac
  done < "$WORK/plan"
  index_assets "$ASSETS" "$WORK/index.after"
  if ! check_duplicates "$WORK/index.after"; then
    die "Duplicate UUIDs after the merge; check the files above."
  fi
fi

while IFS="$TAB" read -r action staged target; do
  case "$action" in
    add) label=Add ;;
    update) label=Update ;;
    *) continue ;;
  esac
  [ "$DRY_RUN" -eq 0 ] || label="Would $(echo "$label" | tr '[:upper:]' '[:lower:]')"
  echo "$label: $(relative "$target")"
done < "$WORK/plan"
sed 's/^/Skipped: /' "$WORK/skipped"

added=$(grep -c "^add$TAB" "$WORK/plan" || true)
updated=$(grep -c "^update$TAB" "$WORK/plan" || true)
unchanged=$(grep -c "^same$TAB" "$WORK/plan" || true)
skipped=$(grep -c . "$WORK/skipped" || true)
echo
echo "$added added, $updated updated, $unchanged unchanged, $skipped skipped."
if [ -z "$CORE" ]; then
  echo "Core check skipped (no --core); \`make package-validate\` still catches core UUIDs."
fi
if grep -q "^add$TAB.*/dashboards/[^/]*$" "$WORK/plan"; then
  echo "New dashboard: to show it inside OpenLMIS, enable embedding on it in Superset and add a" \
    "dashboard report with that Embedded UUID in OpenLMIS."
fi
if [ "$DRY_RUN" -eq 0 ] && [ $((added + updated)) -gt 0 ]; then
  echo "Next: review \`git diff\`, commit and open a PR. Once it is merged to master, the next deploy keeps it."
fi
