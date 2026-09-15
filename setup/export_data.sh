#!/usr/bin/env bash
# Export the Lesson 1 source tables from an account that already has them.
#
#   setup/export_data.sh <source-connection> [output-dir]
#
# Writes three Parquet files. Run setup/load_data.sh next to load them elsewhere.
#
# Every temporal column is carried as an ISO string rather than a Parquet timestamp.
# That is not fussiness: loading Parquet timestamps directly produced invalid dates when
# this dataset was first loaded, and the whole task turns on PROCESSED_AT resolving to
# the correct settlement date.

set -uo pipefail

CONN="${1:-}"
OUT="${2:-setup/fixtures}"
[ -z "$CONN" ] && { echo "usage: setup/export_data.sh <source-connection> [output-dir]" >&2; exit 1; }

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$LAB_DIR"
mkdir -p "$OUT"
# Resolve to an absolute path: the stage download needs file://<absolute>, and OUT may
# have been given either relative to lab/ or absolute.
OUT="$(cd "$OUT" && pwd)"

SRC="${SNOWFLAKE_SOURCE_SCHEMA:-DLAI_AGENT_ENGINEERING.L1_FX_SOURCE}"
STAGE="$SRC.FXSTAGE"

# Column-by-column export expressions, read from the live table so the script cannot
# drift from the schema.
python3 - "$CONN" "$SRC" > /tmp/export_generated.sql <<'PY'
import json, subprocess, sys

conn, src = sys.argv[1], sys.argv[2]
db, schema = src.split(".")[0], src.split(".")[1]

def q(sql):
    r = subprocess.run(
        ["uvx", "--from", "snowflake-cli", "snow", "sql", "-c", conn, "--format", "json", "-q", sql],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"query failed: {r.stdout}\n{r.stderr}")
    return json.loads(r.stdout)

rows = q(f"""select table_name, column_name, data_type
             from {db}.information_schema.columns
             where table_schema = '{schema}' order by table_name, ordinal_position""")

by = {}
for r in rows:
    by.setdefault(r["TABLE_NAME"], []).append(r)

NTZ = "YYYY-MM-DD HH24:MI:SS.FF9"
TZ = "YYYY-MM-DD HH24:MI:SS.FF9 TZHTZM"

def expr(c):
    t, n = c["DATA_TYPE"], c["COLUMN_NAME"]
    if t == "TIMESTAMP_NTZ":
        return f"TO_VARCHAR({n}, '{NTZ}') AS {n}"
    if t == "TIMESTAMP_TZ":
        return f"TO_VARCHAR({n}, '{TZ}') AS {n}"
    if t == "DATE":
        return f"TO_VARCHAR({n}, 'YYYY-MM-DD') AS {n}"
    return n

print(f"CREATE STAGE IF NOT EXISTS {src}.FXSTAGE FILE_FORMAT = (TYPE = PARQUET);")
for t in ("FCT_SALES", "ORDER_PAYMENTS", "DIM_EXCHANGE_RATES"):
    cols = ", ".join(expr(c) for c in by[t])
    print(f"REMOVE @{src}.FXSTAGE/export/{t}/;")
    print(f"COPY INTO @{src}.FXSTAGE/export/{t}/ FROM (SELECT {cols} FROM {src}.{t}) "
          f"FILE_FORMAT = (TYPE = PARQUET) HEADER = TRUE OVERWRITE = TRUE "
          f"MAX_FILE_SIZE = 268435456;")
PY
[ $? -eq 0 ] || { echo "export: could not generate SQL" >&2; exit 1; }

echo "export: unloading to @$STAGE/export/"
uvx --from snowflake-cli snow sql -c "$CONN" -f /tmp/export_generated.sql >/dev/null || {
  echo "export: unload failed" >&2; exit 1; }

for t in FCT_SALES ORDER_PAYMENTS DIM_EXCHANGE_RATES; do
  rm -rf "$OUT/$t"; mkdir -p "$OUT/$t"
  # Pass a plain local path, not a file:// URL. Given file:// the CLI reports DOWNLOADED
  # but writes into a directory literally named "file:" under the current directory.
  uvx --from snowflake-cli snow stage copy "@$STAGE/export/$t/" "$OUT/$t" -c "$CONN" >/dev/null || {
    echo "export: download of $t failed" >&2; exit 1; }
  f=$(find "$OUT/$t" -name '*.parquet' | head -1)
  [ -z "$f" ] && { echo "export: no parquet for $t" >&2; exit 1; }
  mv "$f" "$OUT/$t.parquet"
  rm -rf "$OUT/$t"
  printf 'export: %-20s %s bytes\n' "$t" "$(stat -f %z "$OUT/$t.parquet")"
done

uvx --from snowflake-cli snow sql -c "$CONN" -q "REMOVE @$STAGE/export/;" >/dev/null 2>&1
rm -f /tmp/export_generated.sql
echo "export: done. Files in $OUT/, load them with:  setup/load_data.sh <target-connection> $OUT"
