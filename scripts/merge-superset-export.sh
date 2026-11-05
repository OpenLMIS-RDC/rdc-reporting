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
# It also stops, writing nothing, on two exports that would import wrongly:
# - With --core, a chart or dashboard that uses a core chart or dataset. The
#   platform imports each package on its own, and Superset only links assets
#   within one package: such a chart is skipped and such a dashboard fails.
# - A new dataset on the same table as an existing one under another UUID (a
#   dataset recreated in Superset). The import folds both files into one
#   dataset, and either definition can win.
#
# Needs bash (the 3.2 that ships with macOS is enough), grep, sed and, for a
# ZIP, unzip.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Run this script with bash: bash scripts/merge-superset-export.sh ..." >&2
  exit 1
fi

set -eu
export LC_ALL=C

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ASSETS="$REPO_ROOT/superset/assets"
SOURCE_DB_ENGINE=clickhousedb
TAB=$'\t'
BACKSLASH_NEWLINE=$'\\\n'

usage() {
  cat <<'EOF'
Usage: scripts/merge-superset-export.sh [--dry-run] [--core PATH] EXPORT

  EXPORT     Superset export ZIP, or the unzipped export folder
  --dry-run  show what would change, write nothing
  --core     openlmis-reporting checkout (or its superset/assets); core assets
             in the export are then skipped instead of copied here, and a
             chart or dashboard that uses one stops the merge
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

# Chart and dataset UUIDs a dashboard refers to (layout charts, native filter targets).
dashboard_refs() {
  sed -n -E 's/^[[:space:]]+(-[[:space:]]+)?(uuid|datasetUuid):[[:space:]]*"?([0-9a-fA-F-]{36})"?[[:space:]]*$/\3/p' "$1" \
    | tr 'A-F' 'a-f' | sort -u
}

# Raw text of a top-level YAML scalar, including the lines Superset's dumper
# wraps a long value onto.
top_scalar() {
  awk -v key="$1" '
    { sub(/\r$/, "") }
    found && /^[^ \t]/ { exit }
    found { line = $0; sub(/^[ \t]+/, "", line); value = value "\n" line; next }
    index($0, key ":") == 1 { found = 1; value = substr($0, length(key) + 2); sub(/^[ \t]+/, "", value) }
    END { printf "%s", value }
  ' "$2"
}

# UTF-8 bytes of a code point.
utf8() {
  code=$1
  if [ "$code" -lt 128 ]; then
    set -- "$code"
  elif [ "$code" -lt 2048 ]; then
    set -- $((192 + code / 64)) $((128 + code % 64))
  elif [ "$code" -lt 65536 ]; then
    set -- $((224 + code / 4096)) $((128 + code / 64 % 64)) $((128 + code % 64))
  else
    set -- $((240 + code / 262144)) $((128 + code / 4096 % 64)) $((128 + code / 64 % 64)) $((128 + code % 64))
  fi
  printf '%b' "$(printf '\\0%03o' "$@")"
}

# Decodes the escapes of a YAML double-quoted scalar (Superset writes accents as
# \xE9 or –), so an exported name compares equal to a hand-written one.
yaml_unescape() {
  s=$1
  out=""
  i=0
  while [ "$i" -lt "${#s}" ]; do
    c=${s:i:1}
    if [ "$c" != "\\" ]; then
      out="$out$c"
      i=$((i + 1))
      continue
    fi
    e=${s:i+1:1}
    case "$e" in
      x) len=2 ;;
      u) len=4 ;;
      U) len=8 ;;
      *) len=0 ;;
    esac
    hex=${s:i+2:len}
    if [ "$len" -gt 0 ] && [ "${#hex}" -eq "$len" ] && [ -z "${hex//[0-9A-Fa-f]/}" ]; then
      out="$out$(utf8 $((16#$hex)))"
      i=$((i + 2 + len))
      continue
    fi
    case "$e" in
      _) out="$out$(utf8 160)" ;;
      N) out="$out$(utf8 133)" ;;
      L) out="$out$(utf8 8232)" ;;
      P) out="$out$(utf8 8233)" ;;
      t) out="$out$TAB" ;;
      n) out="$out"$'\n' ;;
      *) out="$out$e" ;;
    esac
    i=$((i + 2))
  done
  printf '%s' "$out"
}

# Decoded value of a top-level YAML scalar such as a name, whether Superset wrote
# it (quoted, escaped, wrapped) or someone wrote it by hand.
name_of() {
  v=$(top_scalar "$1" "$2")
  case "$v" in
    \"*)
      # A wrapped double-quoted line ends in a backslash and joins directly; any
      # other line break folds to a space. Anything after the closing quote is
      # a comment.
      v=${v//"$BACKSLASH_NEWLINE"/}
      v=${v//$'\n'/ }
      v=${v#\"}
      v=$(yaml_unescape "${v%\"*}")
      ;;
    \'*)
      v=${v//$'\n'/ }
      v=${v#\'}
      v=${v%\'*}
      v=${v//\'\'/\'}
      ;;
    *)
      v=${v//$'\n'/ }
      v=${v%% #*}
      v=${v%"${v##*[![:space:]]}"}
      ;;
  esac
  printf '%s' "$v"
}

# "database_uuid|schema|table_name" of a dataset: what Superset matches datasets on.
dataset_key() {
  printf '%s|%s|%s\n' "$(top_value database_uuid "$1" | tr 'A-F' 'a-f')" \
    "$(name_of schema "$1")" "$(name_of table_name "$1")"
}

# Prints the path of an existing chart or dashboard whose name is $2 ($1 is the
# folder: charts or dashboards). The name index is built on first use.
find_same_name() {
  if [ ! -e "$WORK/names" ]; then
    : > "$WORK/names"
    for spec in charts:slice_name dashboards:dashboard_title; do
      [ -d "$ASSETS/${spec%%:*}" ] || continue
      find "$ASSETS/${spec%%:*}" -type f -name '*.yaml' | sort | while IFS= read -r file; do
        printf '%s\t%s\t%s\n' "${spec%%:*}" "$(name_of "${spec#*:}" "$file")" "$file"
      done >> "$WORK/names"
    done
  fi
  while IFS="$TAB" read -r kind name path; do
    if [ "$kind" = "$1" ] && [ "$name" = "$2" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done < "$WORK/names"
}

# Appends "key<TAB>uuid<TAB>path" for every dataset file under $1 to $2, leaving
# out the UUIDs listed in file $3 (datasets the export replaces).
index_dataset_keys() {
  [ -d "$1" ] || return 0
  find "$1" -type f -name '*.yaml' | sort | while IFS= read -r file; do
    uuid=$(uuid_of "$file")
    if [ -n "$(top_value table_name "$file")" ] && ! grep -qxF "$uuid" "$3"; then
      printf '%s\t%s\t%s\n' "$(dataset_key "$file")" "$uuid" "$file"
    fi
  done >> "$2"
}

# Prints the path of the first entry with key $1 in dataset-key index $2.
find_dataset_key() {
  while IFS="$TAB" read -r key _ path; do
    if [ "$key" = "$1" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done < "$2"
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
: > "$WORK/warnings"
: > "$WORK/dataset_keys"
: > "$WORK/core_dataset_keys"

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
  fi
  if [ ! -d "$CORE/charts" ] && [ ! -d "$CORE/dashboards" ] && [ ! -d "$CORE/datasets" ]; then
    die "--core: $CORE is neither openlmis-reporting nor its superset/assets folder"
  fi
  if [ "$(cd "$CORE" && pwd -P)" = "$(cd "$ASSETS" && pwd -P)" ] \
    || grep -qs '^type:[[:space:]]*extension' "$CORE/../../manifest.yaml"; then
    die "--core: $CORE belongs to an extension package; pass the openlmis-reporting checkout"
  fi
  find "$CORE" -type f -name '*.yaml' | while IFS= read -r file; do
    uuid=$(uuid_of "$file")
    if [ -n "$uuid" ]; then
      echo "$uuid"
    fi
  done > "$WORK/core"
  index_dataset_keys "$CORE/datasets" "$WORK/core_dataset_keys" /dev/null
fi

count=0
find "$SRC" -type f -name '*.yaml' | sort > "$WORK/files"
# Repo datasets the export replaces are compared in their exported form, so a
# rename in the same export is not mistaken for a clash.
while IFS= read -r file; do
  case "$file" in
    "$SRC"/datasets/*) uuid_of "$file" ;;
  esac
done < "$WORK/files" > "$WORK/export_datasets"
index_dataset_keys "$ASSETS/datasets" "$WORK/dataset_keys" "$WORK/export_datasets"
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
  target=$(grep "^$uuid$TAB" "$WORK/index" | head -n 1 | cut -f2)

  # Core assets cannot be linked from this package (see the header).
  case "$rel" in
    charts/*)
      ref=$(top_value dataset_uuid "$file" | tr 'A-F' 'a-f')
      if [ -n "$ref" ] && grep -qxF "$ref" "$WORK/core"; then
        echo "$rel: the chart uses core dataset $ref; a DRC chart needs a dataset from this package" >> "$WORK/errors"
        continue
      fi
      ;;
    dashboards/*)
      core_refs=0
      for ref in $(dashboard_refs "$file"); do
        if grep -qxF "$ref" "$WORK/core"; then
          echo "$rel: the dashboard uses core chart or dataset $ref; a DRC dashboard needs charts and datasets from this package" >> "$WORK/errors"
          core_refs=1
        fi
      done
      [ "$core_refs" -eq 0 ] || continue
      ;;
  esac

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
      key=$(dataset_key "$file")
      other=$(find_dataset_key "$key" "$WORK/dataset_keys")
      if [ -n "$other" ]; then
        echo "$rel: same table as $(relative "$other") under another UUID, and the import would merge the two (dataset recreated in Superset? then delete the old file and run again)" >> "$WORK/errors"
        continue
      fi
      other=$(find_dataset_key "$key" "$WORK/core_dataset_keys")
      if [ -n "$other" ]; then
        echo "$rel: same table as core dataset ${other##*/}, and the import would merge the two; use a SQL dataset on that table instead" >> "$WORK/errors"
        continue
      fi
      printf '%s\t%s\t%s\n' "$key" "$uuid" "$rel in this export" >> "$WORK/dataset_keys"
      case "$(top_value sql "$file")" in
        "" | null | "~" | "''") ;;
        *) add_source_db_engine "$staged" ;;
      esac
      ;;
  esac

  # A new chart or dashboard named like an existing one is allowed, but often a mistake.
  if [ -z "$target" ]; then
    case "$rel" in
      charts/*) name_key=slice_name ;;
      dashboards/*) name_key=dashboard_title ;;
      *) name_key="" ;;
    esac
    if [ -n "$name_key" ]; then
      name=$(name_of "$name_key" "$file")
      same=""
      if [ -n "$name" ]; then
        same=$(find_same_name "${rel%%/*}" "$name")
      fi
      [ -z "$same" ] || echo "$rel is new but has the same name as $(relative "$same")" >> "$WORK/warnings"
    fi
  fi

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
sed 's/^/Warning: /' "$WORK/warnings"
if [ -z "$CORE" ]; then
  echo "Core check skipped: pass --core <openlmis-reporting checkout> to stop on core charts and datasets."
fi
if grep -q "^add$TAB.*/dashboards/[^/]*$" "$WORK/plan"; then
  echo "New dashboard: to show it inside OpenLMIS, enable embedding on it in Superset and add a" \
    "dashboard report with that Embedded UUID in OpenLMIS."
fi
if [ "$DRY_RUN" -eq 0 ] && [ $((added + updated)) -gt 0 ]; then
  echo "Next: review \`git diff\`, commit only the files you meant to change and open a PR." \
    "Once it is merged to master, the next deploy keeps it."
fi
