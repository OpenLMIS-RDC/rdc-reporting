#!/usr/bin/env bash
# Merge a Superset export into superset/assets/.
#
# Charts and dashboards are built in the Superset UI and exported from there
# (dashboard "..." menu -> Download -> Export YAML, or several dashboards at once
# from the Dashboards list -> Bulk select -> Export). The export cannot be copied
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
# - An export of all dashboards also holds the core ones, which belong to
#   openlmis-reporting, not here.
#
# This script overwrites existing files by UUID, gives new assets an id-less
# name, skips databases/, metadata.yaml and core assets, adds source_db_engine to
# SQL datasets and refuses to leave two files with the same UUID. Files are
# copied as Superset writes them. Review `git diff` afterwards.
#
# It also stops, writing nothing, on exports that would import wrongly:
# - A chart or dashboard that uses a core chart or dataset. The platform imports
#   each package on its own, and Superset only links assets within one package:
#   such a chart is skipped and such a dashboard fails.
# - A new dataset on the same table as an existing one under another UUID (a
#   dataset recreated in Superset). The import folds both files into one
#   dataset, and either definition can win.
#
# The core package is read from ../openlmis-reporting (a clone next to this
# repository) unless --core says otherwise.
#
# Needs bash (the 3.2 that ships with macOS is enough), the usual Unix tools
# (awk, sed, grep, find, xargs) and, for a ZIP, unzip.

# The awk programs below use $ inside single quotes on purpose.
# shellcheck disable=SC2016

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Run this script with bash: bash scripts/merge-superset-export.sh ..." >&2
  exit 1
fi

set -eu
export LC_ALL=C
unset CDPATH
# Run as "sh script" on macOS, bash is in POSIX mode, where echo expands backslashes.
shopt -u xpg_echo

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ASSETS="$REPO_ROOT/superset/assets"
SOURCE_DB_ENGINE=clickhousedb
TAB=$'\t'
SEP=$'\037'

usage() {
  cat <<'EOF'
Usage: scripts/merge-superset-export.sh [--dry-run] [--core PATH] EXPORT

  EXPORT     Superset export ZIP, or the unzipped export folder
  --dry-run  show what would change, write nothing
  --core     openlmis-reporting checkout (or its superset/assets), when it is
             not cloned next to this repository as ../openlmis-reporting
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

relative() {
  printf '%s\n' "${1#"$REPO_ROOT"/}"
}

# One awk pass over many YAML files. For each file it prints the path and the
# raw value of each top-level key in KEYS, separated by SEP:
# - a value Superset's dumper wrapped over several lines is joined back (a
#   double-quoted line ending in a backslash joins directly, other lines with a
#   space);
# - keys ending in "uuid" are unquoted and lower-cased;
# - "sql" becomes 1 for a SQL dataset and 0 otherwise;
# - "@refs" lists the nested uuid and datasetUuid values (what a dashboard uses).
AWK_EXTRACT='
function flush(   i, v, row) {
  if (file == "") return
  row = file
  for (i = 1; i <= nk; i++) {
    v = val[i]
    if (k[i] == "@refs") v = refs
    else if (k[i] ~ /uuid$/) { gsub(/["'"'"' \t]/, "", v); v = tolower(v) }
    else if (k[i] == "sql") v = (v == "" || v == "null" || v == "~" || v == "'"''"'" || v == "\"\"") ? 0 : 1
    row = row sep v
  }
  print row
}
BEGIN {
  nk = split(keys, k, ",")
  sep = "\037"
  for (i = 1; i <= nk; i++) if (k[i] == "@refs") want_refs = 1
}
FNR == 1 {
  flush()
  file = FILENAME
  for (i = 1; i <= nk; i++) val[i] = ""
  cur = 0
  refs = ""
}
{ sub(/\r$/, "") }
/^[ \t]/ {
  if (cur) {
    line = $0
    sub(/^[ \t]+/, "", line)
    if (quoted && val[cur] ~ /\\$/) val[cur] = substr(val[cur], 1, length(val[cur]) - 1) line
    else if (line != "") val[cur] = val[cur] " " line
  }
  if (want_refs && match($0, /^[ \t]+(-[ \t]+)?(uuid|datasetUuid):[ \t]*/)) {
    v = substr($0, RLENGTH + 1)
    gsub(/["'"'"' \t]/, "", v)
    v = tolower(v)
    if (length(v) == 36 && v ~ /^[0-9a-f-]+$/ && index(refs " ", " " v " ") == 0) refs = refs " " v
  }
  next
}
{
  cur = 0
  for (i = 1; i <= nk; i++) {
    if (index($0, k[i] ":") == 1) {
      v = substr($0, length(k[i]) + 2)
      sub(/^[ \t]+/, "", v)
      sub(/[ \t]+$/, "", v)
      val[i] = v
      cur = i
      quoted = (substr(v, 1, 1) == "\"")
      break
    }
  }
}
END { flush() }
'

# Runs AWK_EXTRACT for keys $1 over the files listed in $2 and writes the rows to $3.
# xargs splits a long list over several awk runs where the command line is short
# (Git Bash on Windows).
extract() {
  if [ -s "$2" ]; then
    tr '\n' '\000' < "$2" | xargs -0 awk -v keys="$1" "$AWK_EXTRACT" > "$3"
  else
    : > "$3"
  fi
}

# Lists the YAML files under the given folders that exist, sorted, into the last argument.
list_yaml() {
  out=$1
  shift
  for dir in "$@"; do
    if [ -d "$dir" ]; then
      find "$dir" -type f -name '*.yaml'
    fi
  done | sort > "$out"
}

# Sets UTF8 to the bytes of code point $1.
utf8_into() {
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
  esc=""
  for byte in "$@"; do
    printf -v octal '%03o' "$byte"
    esc="$esc\\0$octal"
  done
  printf -v UTF8 '%b' "$esc"
}

# Sets DECODED to the value of a raw YAML scalar from AWK_EXTRACT, so that a name
# Superset exported (quoted, with accents escaped as \xE9) compares equal to the
# same name written by hand.
decode_scalar() {
  v=$1
  case "$v" in
    \"*)
      # Anything after the closing quote is a comment.
      v=${v#\"}
      v=${v%\"*}
      DECODED=""
      i=0
      while [ "$i" -lt "${#v}" ]; do
        c=${v:i:1}
        if [ "$c" != "\\" ]; then
          DECODED="$DECODED$c"
          i=$((i + 1))
          continue
        fi
        e=${v:i+1:1}
        case "$e" in
          x) len=2 ;;
          u) len=4 ;;
          U) len=8 ;;
          *) len=0 ;;
        esac
        hex=${v:i+2:len}
        if [ "$len" -gt 0 ] && [ "${#hex}" -eq "$len" ] && [ -z "${hex//[0-9A-Fa-f]/}" ]; then
          utf8_into $((16#$hex))
          DECODED="$DECODED$UTF8"
          i=$((i + 2 + len))
          continue
        fi
        case "$e" in
          _) utf8_into 160 ;;
          N) utf8_into 133 ;;
          L) utf8_into 8232 ;;
          P) utf8_into 8233 ;;
          t) UTF8=$TAB ;;
          n) UTF8=$'\n' ;;
          *) UTF8=$e ;;
        esac
        DECODED="$DECODED$UTF8"
        i=$((i + 2))
      done
      ;;
    \'*)
      v=${v#\'}
      v=${v%\'*}
      DECODED=${v//\'\'/\'}
      ;;
    *)
      v=${v%% #*}
      DECODED=${v%"${v##*[![:space:]]}"}
      ;;
  esac
}

# Appends "database_uuid|schema|table_name<TAB>uuid<TAB>path" for each dataset row
# of $1 (extracted with "uuid,database_uuid,schema,table_name") to $2, leaving out
# the UUIDs listed in file $3. That key is what Superset matches datasets on.
add_dataset_keys() {
  excluded=" $(tr '\n' ' ' < "$3") "
  while IFS="$SEP" read -r path uuid database schema table; do
    [ -n "$table" ] || continue
    case "$excluded" in
      *" $uuid "*) continue ;;
    esac
    decode_scalar "$schema"
    key="$database|$DECODED"
    decode_scalar "$table"
    printf '%s|%s\t%s\t%s\n' "$key" "$DECODED" "$uuid" "$path"
  done < "$1" >> "$2"
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

# Prints the path of an existing chart or dashboard whose name is $2 ($1 is the
# folder: charts or dashboards). The name index is built on first use.
find_same_name() {
  if [ ! -e "$WORK/names" ]; then
    : > "$WORK/names"
    for spec in charts:slice_name dashboards:dashboard_title; do
      list_yaml "$WORK/names.list" "$ASSETS/${spec%%:*}"
      extract "${spec#*:}" "$WORK/names.list" "$WORK/names.rows"
      while IFS="$SEP" read -r path raw; do
        decode_scalar "$raw"
        printf '%s\t%s\t%s\n' "${spec%%:*}" "$DECODED" "$path"
      done < "$WORK/names.rows" >> "$WORK/names"
    done
  fi
  while IFS="$TAB" read -r kind name path; do
    if [ "$kind" = "$1" ] && [ "$name" = "$2" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done < "$WORK/names"
}

# Writes "uuid<TAB>path" for every chart, dashboard and dataset file under $1 to $2.
index_assets() {
  list_yaml "$WORK/index.list" "$1/charts" "$1/dashboards" "$1/datasets"
  extract uuid "$WORK/index.list" "$WORK/index.rows"
  awk -F "$SEP" '$2 != "" { print $2 "\t" $1 }' "$WORK/index.rows" > "$2"
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
  while [ -e "$path" ] || cut -f2 "$WORK/pairs" | grep -qxF "$path"; do
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

if [ -z "$CORE" ]; then
  CORE="$REPO_ROOT/../openlmis-reporting"
  [ -d "$CORE" ] || die "Core package not found at ../openlmis-reporting: clone" \
    "https://github.com/OpenLMIS/openlmis-reporting next to this repository, or pass --core PATH."
fi
[ -d "$CORE" ] || die "--core: $CORE: no such folder"
# Absolute, physical paths from here on: awk would read a relative path such as
# "name=x/charts/a.yaml" as a variable assignment, and find does not enter a
# symlink given as its starting point.
CORE=$(cd "$CORE" && pwd -P)
if [ -d "$CORE/superset/assets" ]; then
  CORE="$CORE/superset/assets"
fi
if [ ! -d "$CORE/charts" ] && [ ! -d "$CORE/dashboards" ] && [ ! -d "$CORE/datasets" ]; then
  die "Core package: $CORE is neither openlmis-reporting nor its superset/assets folder." \
    "Pass your openlmis-reporting clone with --core PATH."
fi
if [ "$(cd "$CORE" && pwd -P)" = "$(cd "$ASSETS" && pwd -P)" ] \
  || grep -qs '^type:[[:space:]]*extension' "$CORE/../../manifest.yaml"; then
  die "Core package: $CORE belongs to an extension package. Pass your openlmis-reporting clone with --core PATH."
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/merge-superset-export.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
: > "$WORK/pairs"
: > "$WORK/errors"
: > "$WORK/skipped"
: > "$WORK/warnings"
: > "$WORK/dataset_keys"
: > "$WORK/core_dataset_keys"

if [ -d "$EXPORT" ]; then
  SRC=$(cd "$EXPORT" && pwd -P)
else
  command -v unzip > /dev/null 2>&1 || die "unzip not found: unzip the export and pass the folder instead."
  mkdir "$WORK/export"
  unzip -q "$EXPORT" -d "$WORK/export" || die "$EXPORT: could not unzip it."
  SRC="$WORK/export"
fi
# A Superset export wraps everything in one top-level folder (dashboard_export_<timestamp>/)
# with metadata.yaml in it. A folder holding several exports is refused: only one
# of them would be merged.
if [ ! -e "$SRC/metadata.yaml" ]; then
  found=""
  exports=0
  for dir in "$SRC"/*/; do
    if [ -e "$dir/metadata.yaml" ]; then
      found=$(cd "$dir" && pwd -P)
      exports=$((exports + 1))
    fi
  done
  [ "$exports" -gt 0 ] || die "$EXPORT is not a Superset export (no metadata.yaml)."
  [ "$exports" -eq 1 ] || die "$EXPORT holds $exports exports. Export the dashboards together as one ZIP" \
    "(Dashboards list -> Bulk select, tick them, Export), or run the script once per export."
  SRC=$found
fi

index_assets "$ASSETS" "$WORK/index"
if ! check_duplicates "$WORK/index"; then
  die "Fix the duplicates in superset/assets/ first (keep one file per UUID)."
fi

list_yaml "$WORK/databases.list" "$ASSETS/databases"
extract uuid "$WORK/databases.list" "$WORK/databases.rows"
cut -d "$SEP" -f2 "$WORK/databases.rows" > "$WORK/databases"

index_assets "$CORE" "$WORK/core.idx"
cut -f1 "$WORK/core.idx" > "$WORK/core"
[ -s "$WORK/core" ] || die "Core package: $CORE holds no charts, dashboards or datasets." \
  "Pass your openlmis-reporting clone with --core PATH."
list_yaml "$WORK/core_datasets.list" "$CORE/datasets"
extract uuid,database_uuid,schema,table_name "$WORK/core_datasets.list" "$WORK/core_datasets.rows"
add_dataset_keys "$WORK/core_datasets.rows" "$WORK/core_dataset_keys" /dev/null

# Sort the export's files: skipped ones are listed, empty ones are errors, the rest
# are read in one pass.
find "$SRC" -type f -name '*.yaml' | sort > "$WORK/files"
: > "$WORK/assets.list"
while IFS= read -r file; do
  rel=${file#"$SRC"/}
  case "$rel" in
    metadata.yaml) ;;
    databases/*) echo "$rel (database connection stays as it is in this repo)" >> "$WORK/skipped" ;;
    charts/* | dashboards/* | datasets/*)
      if [ -s "$file" ]; then
        echo "$file" >> "$WORK/assets.list"
      else
        echo "$rel: no top-level uuid" >> "$WORK/errors"
      fi
      ;;
    *) echo "$rel (not a chart, dashboard or dataset)" >> "$WORK/skipped" ;;
  esac
done < "$WORK/files"
extract uuid,database_uuid,dataset_uuid,sql,schema,table_name,slice_name,dashboard_title,@refs \
  "$WORK/assets.list" "$WORK/export.rows"

# Repo datasets the export replaces are compared in their exported form, so a
# rename in the same export is not mistaken for a clash.
# The prefix goes through the environment: awk -v would turn backslashes in the
# path into escapes.
EXPORT_DATASETS="$SRC/datasets/" awk -F "$SEP" 'index($1, ENVIRON["EXPORT_DATASETS"]) == 1 { print $2 }' \
  "$WORK/export.rows" > "$WORK/export_datasets"
list_yaml "$WORK/datasets.list" "$ASSETS/datasets"
extract uuid,database_uuid,schema,table_name "$WORK/datasets.list" "$WORK/datasets.rows"
add_dataset_keys "$WORK/datasets.rows" "$WORK/dataset_keys" "$WORK/export_datasets"

# Look everything up in one pass: core asset, repeated UUID, existing file, core
# chart or dataset used, known database.
awk -F "$SEP" -v sep="$SEP" '
  FILENAME == ARGV[1] { core[$0] = 1; next }
  FILENAME == ARGV[2] { known_db[$0] = 1; next }
  FILENAME == ARGV[3] { split($0, a, "\t"); if (!(a[1] in target)) target[a[1]] = a[2]; next }
  {
    uuid = $2
    is_core = (uuid != "" && (uuid in core)) ? 1 : 0
    repeated = 0
    if (uuid != "" && !is_core) { if (uuid in seen) repeated = 1; seen[uuid] = 1 }
    existing = (uuid in target) ? target[uuid] : ""
    core_dataset = ($4 != "" && ($4 in core)) ? $4 : ""
    n = split($10, r, " ")
    core_refs = ""
    for (j = 1; j <= n; j++) if (r[j] in core) core_refs = core_refs " " r[j]
    db_ok = ($3 != "" && ($3 in known_db)) ? 1 : 0
    print $0 sep is_core sep repeated sep existing sep core_dataset sep core_refs sep db_ok
  }
' "$WORK/core" "$WORK/databases" "$WORK/index" "$WORK/export.rows" > "$WORK/export.plan"

count=0
while IFS="$SEP" read -r file uuid database _ sql schema table slice title _ is_core repeated target core_dataset core_refs db_ok; do
  rel=${file#"$SRC"/}
  if [ -z "$uuid" ]; then
    echo "$rel: no top-level uuid" >> "$WORK/errors"
    continue
  fi
  if [ "$is_core" = 1 ]; then
    echo "$rel (core asset, it lives in openlmis-reporting)" >> "$WORK/skipped"
    continue
  fi
  if [ "$repeated" = 1 ]; then
    echo "$rel: the export has UUID $uuid more than once" >> "$WORK/errors"
    continue
  fi

  # Core assets cannot be linked from this package (see the header).
  if [ -n "$core_dataset" ]; then
    echo "$rel: the chart uses core dataset $core_dataset; a DRC chart needs a dataset from this package" >> "$WORK/errors"
    continue
  fi
  if [ -n "$core_refs" ]; then
    for ref in $core_refs; do
      echo "$rel: the dashboard uses core chart or dataset $ref; a DRC dashboard needs charts and datasets from this package" >> "$WORK/errors"
    done
    continue
  fi

  source=$file
  case "$rel" in
    datasets/*)
      if [ "$db_ok" != 1 ]; then
        echo "$rel: dataset is not on the reporting_clickhouse database" >> "$WORK/errors"
        continue
      fi
      decode_scalar "$schema"
      key="$database|$DECODED"
      decode_scalar "$table"
      key="$key|$DECODED"
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
      if [ "$sql" = 1 ]; then
        count=$((count + 1))
        source="$WORK/staged.$count"
        cp "$file" "$source"
        add_source_db_engine "$source"
      fi
      ;;
  esac

  if [ -z "$target" ]; then
    # A new chart or dashboard named like an existing one is allowed, but often a mistake.
    case "$rel" in
      charts/*) raw=$slice ;;
      dashboards/*) raw=$title ;;
      *) raw="" ;;
    esac
    if [ -n "$raw" ]; then
      decode_scalar "$raw"
      same=$(find_same_name "${rel%%/*}" "$DECODED")
      [ -z "$same" ] || echo "$rel is new but has the same name as $(relative "$same")" >> "$WORK/warnings"
    fi
    target=$(new_path "$ASSETS/${rel%/*}" "$(basename "$rel" .yaml)" "$uuid")
  fi
  printf '%s\t%s\n' "$source" "$target" >> "$WORK/pairs"
done < "$WORK/export.plan"

if [ -s "$WORK/errors" ]; then
  sed 's/^/ERROR: /' "$WORK/errors"
  die "Nothing was written."
fi
[ -s "$WORK/pairs" ] || [ -s "$WORK/skipped" ] || die "$EXPORT holds no charts, dashboards or datasets."

# Compare each export file with its target in one awk run: add, update or same.
# Files are read whole, so a difference in line ends or in the last newline
# counts too. RS is \001 and some awks stop a string at NUL; YAML files hold
# neither byte.
awk -v tab="$TAB" '
  function slurp(path,   r, s, n, rc) {
    RS = "\001"
    s = ""
    n = 0
    while ((rc = (getline r < path)) > 0) s = s (n++ ? RS : "") r
    close(path)
    RS = "\n"
    found = (rc == 0)
    return s
  }
  {
    split($0, p, tab)
    a = slurp(p[1])
    b = slurp(p[2])
    if (!found) action = "add"
    else if ((a "") == (b "")) action = "same"
    else action = "update"
    print action tab p[1] tab p[2]
  }
' "$WORK/pairs" > "$WORK/plan"

if [ "$DRY_RUN" -eq 0 ]; then
  while IFS="$TAB" read -r action source target; do
    case "$action" in
      add | update)
        # cat rather than cp: the export ZIP stores files as 0600, and a new
        # file should get the usual permissions.
        [ -d "${target%/*}" ] || mkdir -p "${target%/*}"
        cat "$source" > "$target"
        ;;
    esac
  done < "$WORK/plan"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  add_label=Add
  update_label=Update
else
  add_label="Would add"
  update_label="Would update"
fi
while IFS="$TAB" read -r action _ target; do
  case "$action" in
    add) echo "$add_label: $(relative "$target")" ;;
    update) echo "$update_label: $(relative "$target")" ;;
  esac
done < "$WORK/plan"
sed 's/^/Skipped: /' "$WORK/skipped"

added=$(grep -c "^add$TAB" "$WORK/plan" || true)
updated=$(grep -c "^update$TAB" "$WORK/plan" || true)
unchanged=$(grep -c "^same$TAB" "$WORK/plan" || true)
skipped=$(grep -c . "$WORK/skipped" || true)
echo
echo "$added added, $updated updated, $unchanged unchanged, $skipped skipped."
sed 's/^/Warning: /' "$WORK/warnings"
if grep -q "^add$TAB.*/dashboards/[^/]*$" "$WORK/plan"; then
  echo "New dashboard: to show it inside OpenLMIS, enable embedding on it in Superset and add a" \
    "dashboard report with that Embedded UUID in OpenLMIS."
fi
if [ "$DRY_RUN" -eq 0 ] && [ $((added + updated)) -gt 0 ]; then
  echo "Next: review \`git diff\`, commit only the files you meant to change and open a PR." \
    "Once it is merged to master, the next deploy keeps it."
fi
