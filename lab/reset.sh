#!/usr/bin/env bash
# Reset the lab to a clean state before an experiment.
#
#   source lab/env.sh && lab/reset.sh
#
# Rebuilds workspace/ from dbt_project/, injects the harness plumbing,
# resets the Snowflake data, and verifies both.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
HARNESS="$REPO_ROOT/lab/harness"
SOURCE_PROJECT="$REPO_ROOT/dbt_project"
WORKSPACE="$REPO_ROOT/workspace"
MODEL="$WORKSPACE/models/fact_revenue.sql"

fail() { printf 'reset: FAILED - %s\n' "$1" >&2; exit 1; }

[ -d "$SOURCE_PROJECT" ] || fail "no dbt_project/ in $REPO_ROOT"
[ -f "$REPO_ROOT/lab/reset_lab.sql" ] || fail "no reset_lab.sql in lab/"
[ -d "$HARNESS/commands" ] || fail "no harness/commands in lab/"

printf 'reset: rebuilding workspace\n'

# 1. Rebuild workspace from the pristine project.
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"
rsync -a \
  --exclude 'target/' \
  --exclude 'logs/' \
  --exclude 'dbt_packages/' \
  --exclude '.user.yml' \
  "$SOURCE_PROJECT"/ "$WORKSPACE"/ || fail "could not copy dbt_project/ into workspace/"

# 2. Inject the shared harness: slash commands and permission policy.
mkdir -p "$WORKSPACE/.claude/commands"
cp "$HARNESS"/commands/*.md "$WORKSPACE/.claude/commands/" || fail "could not install slash commands"
cp "$HARNESS/claude-settings.json" "$WORKSPACE/.claude/settings.json" || fail "could not install settings.json"

# 3. Make the model writable (the pristine copy is read-only).
[ -f "$MODEL" ] || fail "workspace/models/fact_revenue.sql is missing after the copy"
chmod u+w "$MODEL" || fail "could not make the workspace model writable"

# 4. Reset the Snowflake data.
printf 'reset: resetting Snowflake data\n'
sql_log=$(mktemp)
trap 'rm -f "$sql_log"' EXIT
uvx --from snowflake-cli snow sql -c "${SNOWFLAKE_CONNECTION:-DEVREL_ENTERPRISE}" \
  -f "$REPO_ROOT/lab/reset_lab.sql" --format json >"$sql_log" 2>&1
sql_status=$?

# 5. Verify row counts.
python3 - "$sql_status" "$sql_log" <<'PY' || exit 1
import json, pathlib, sys

status = sys.argv[1]
raw = pathlib.Path(sys.argv[2]).read_text()
expected = {"FCT_SALES": 9456, "ORDER_PAYMENTS": 1973, "DIM_EXCHANGE_RATES": 13242}

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    print("reset: FAILED - Snowflake did not return JSON. Output was:", file=sys.stderr)
    print(raw.strip()[-800:], file=sys.stderr)
    sys.exit(1)

counts = {}
for result_set in payload if isinstance(payload, list) else []:
    if isinstance(result_set, list):
        for row in result_set:
            if isinstance(row, dict) and "RELATION" in row:
                counts[row["RELATION"]] = row.get("ROW_COUNT")

if not counts:
    print(f"reset: FAILED - no row counts came back (snow sql exit {status})", file=sys.stderr)
    sys.exit(1)

bad = {k: (counts.get(k), v) for k, v in expected.items() if counts.get(k) != v}
for name, value in expected.items():
    got = counts.get(name)
    mark = "ok" if got == value else "WRONG"
    print(f"reset: {name:<19} {got} ({mark}, expected {value})")

if bad:
    print("reset: FAILED - the source data is wrong.", file=sys.stderr)
    sys.exit(1)
PY

# 6. Verify workspace state.
for f in .claude/commands/correctness.md .claude/settings.json; do
  [ -f "$WORKSPACE/$f" ] || fail "workspace/$f is missing"
done

solved=$(grep -vE '^\s*(--|\{#)' "$MODEL" | grep -oiE 'fx_rate|settlement_date|_usd' | sort -u | paste -sd, -)
[ -n "$solved" ] && fail "workspace model already contains FX logic ($solved). dbt_project/ is contaminated."

if [ -e "$WORKSPACE/.mcp.json" ] || [ -d "$WORKSPACE/.claude/skills" ]; then
  fail "workspace still has harness pieces in it; dbt_project/ is contaminated"
fi

printf 'reset: workspace rebuilt, model has no FX logic\n'
printf 'reset: ready. Copy an mcp-*.json into workspace/.mcp.json, then start claude.\n'
