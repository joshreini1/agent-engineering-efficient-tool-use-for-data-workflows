#!/usr/bin/env bash
# Load the Lesson 1 source data into an account that setup/setup.sql has provisioned.
#
#   setup/load_data.sh <target-connection> [fixtures-dir]
#
# Expects the three Parquet files produced by setup/export_data.sh. The ISO strings in
# those files are cast back to TIMESTAMP_NTZ, TIMESTAMP_TZ and DATE here, so the loaded
# types match the DDL exactly.
#
# Verifies its own work and exits nonzero if anything is off.

set -uo pipefail

CONN="${1:-}"
FIX="${2:-setup/fixtures}"
[ -z "$CONN" ] && { echo "usage: setup/load_data.sh <target-connection> [fixtures-dir]" >&2; exit 1; }

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$LAB_DIR"

DST="DLAI_AGENT_ENGINEERING.L1_FX_SOURCE"
STAGE="$DST.FXSTAGE"

for t in FCT_SALES ORDER_PAYMENTS DIM_EXCHANGE_RATES; do
  [ -f "$FIX/$t.parquet" ] || { echo "load: missing $FIX/$t.parquet. Run setup/export_data.sh first." >&2; exit 1; }
done

echo "load: uploading to @$STAGE/load/"
for t in FCT_SALES ORDER_PAYMENTS DIM_EXCHANGE_RATES; do
  uvx --from snowflake-cli snow stage copy "$FIX/$t.parquet" "@$STAGE/load/$t/" -c "$CONN" >/dev/null || {
    echo "load: upload of $t failed" >&2; exit 1; }
done

# Generate the COPY statements from the target DDL, so the casts always match the columns.
python3 - "$CONN" > /tmp/load_generated.sql <<'PY'
import json, subprocess, sys

conn = sys.argv[1]
DST = "DLAI_AGENT_ENGINEERING.L1_FX_SOURCE"

def q(sql):
    r = subprocess.run(
        ["uvx", "--from", "snowflake-cli", "snow", "sql", "-c", conn, "--format", "json", "-q", sql],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"query failed: {r.stdout}\n{r.stderr}")
    return json.loads(r.stdout)

rows = q("""select table_name, column_name, data_type, numeric_precision, numeric_scale
            from DLAI_AGENT_ENGINEERING.information_schema.columns
            where table_schema = 'L1_FX_SOURCE' order by table_name, ordinal_position""")
if not rows:
    sys.exit("no columns found: run setup/setup.sql against this account first")

by = {}
for r in rows:
    by.setdefault(r["TABLE_NAME"], []).append(r)

NTZ = "YYYY-MM-DD HH24:MI:SS.FF9"
TZ = "YYYY-MM-DD HH24:MI:SS.FF9 TZHTZM"

def expr(c):
    t, n = c["DATA_TYPE"], c["COLUMN_NAME"]
    if t == "TIMESTAMP_NTZ":
        return f"TO_TIMESTAMP_NTZ($1:{n}::VARCHAR, '{NTZ}')"
    if t == "TIMESTAMP_TZ":
        return f"TO_TIMESTAMP_TZ($1:{n}::VARCHAR, '{TZ}')"
    if t == "DATE":
        return f"TO_DATE($1:{n}::VARCHAR, 'YYYY-MM-DD')"
    if t == "NUMBER":
        return f"$1:{n}::NUMBER({c['NUMERIC_PRECISION']},{c['NUMERIC_SCALE']})"
    if t == "FLOAT":
        return f"$1:{n}::FLOAT"
    if t == "BOOLEAN":
        return f"$1:{n}::BOOLEAN"
    return f"$1:{n}::VARCHAR"

print("USE WAREHOUSE DLAI_LAB_WH;")
for t in ("FCT_SALES", "ORDER_PAYMENTS", "DIM_EXCHANGE_RATES"):
    cols = ", ".join(expr(c) for c in by[t])
    # TRUNCATE rather than DROP so the DDL in setup.sql stays the single definition.
    print(f"TRUNCATE TABLE {DST}.{t};")
    print(f"COPY INTO {DST}.{t} FROM (SELECT {cols} FROM @{DST}.FXSTAGE/load/{t}/) "
          f"FILE_FORMAT = (TYPE = PARQUET) ON_ERROR = ABORT_STATEMENT;")
PY
[ $? -eq 0 ] || { echo "load: could not generate SQL" >&2; exit 1; }

echo "load: copying into $DST"
uvx --from snowflake-cli snow sql -c "$CONN" -f /tmp/load_generated.sql >/dev/null || {
  echo "load: COPY failed" >&2; exit 1; }

uvx --from snowflake-cli snow sql -c "$CONN" -q "REMOVE @$STAGE/load/;" >/dev/null 2>&1
rm -f /tmp/load_generated.sql

echo "load: verifying"
bash "$LAB_DIR/setup/verify_setup.sh" "$CONN" || exit 1
