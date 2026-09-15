#!/usr/bin/env bash
# Check that a provisioned account is actually usable for Lesson 1.
#
#   setup/verify_setup.sh <connection>
#
# Row counts are the weak check. This also checks the properties that make the task
# discriminating, and the expected answer itself, because a subtly wrong load produces a
# lab that runs fine and grades wrongly.

set -uo pipefail

CONN="${1:-}"
[ -z "$CONN" ] && { echo "usage: setup/verify_setup.sh <connection>" >&2; exit 1; }

SRC="DLAI_AGENT_ENGINEERING.L1_FX_SOURCE"

sql=$(cat <<SQL
USE WAREHOUSE DLAI_LAB_WH;
WITH pay AS (
  SELECT ORDER_ID, CAST(MAX(PROCESSED_AT) AS DATE) AS SETTLEMENT_DATE
  FROM $SRC.ORDER_PAYMENTS GROUP BY ORDER_ID
), s AS (
  SELECT f.ORDER_DATE, f.CURRENCY_CODE, f.SOURCE_SYSTEM,
         f.EXTENDED_PRICE - f.DISCOUNT_AMOUNT AS NET_REVENUE,
         f.LINE_TOTAL AS TOTAL_REVENUE,
         COALESCE(p.SETTLEMENT_DATE, f.ORDER_DATE) AS SETTLEMENT_DATE
  FROM $SRC.FCT_SALES f LEFT JOIN pay p ON f.ORDER_ID = p.ORDER_ID
  WHERE f.ORDER_DATE IS NOT NULL
), fx AS (
  SELECT s.*, CASE WHEN s.CURRENCY_CODE = 'USD' THEN 1.0 ELSE COALESCE(r.RATE, 1.0) END AS FX_RATE
  FROM s LEFT JOIN $SRC.DIM_EXCHANGE_RATES r
    ON s.CURRENCY_CODE = r.FROM_CURRENCY AND r.TO_CURRENCY = 'USD' AND r.RATE_DATE = s.SETTLEMENT_DATE
), expected AS (
  SELECT ORDER_DATE, SETTLEMENT_DATE, CURRENCY_CODE, SOURCE_SYSTEM,
         ROUND(SUM(NET_REVENUE * FX_RATE), 2) AS NET_REVENUE_USD
  FROM fx GROUP BY 1,2,3,4
)
SELECT (SELECT COUNT(*) FROM $SRC.FCT_SALES) AS FCT_SALES,
       (SELECT COUNT(*) FROM $SRC.ORDER_PAYMENTS) AS ORDER_PAYMENTS,
       (SELECT COUNT(*) FROM $SRC.DIM_EXCHANGE_RATES) AS DIM_EXCHANGE_RATES,
       (SELECT COUNT(*) FROM s WHERE SETTLEMENT_DATE <> ORDER_DATE) AS DIFF_SETTLE,
       (SELECT COUNT(*) FROM s WHERE CURRENCY_CODE IS NULL) AS NO_CCY,
       (SELECT COUNT(*) FROM expected) AS OUTPUT_ROWS,
       (SELECT ROUND(SUM(NET_REVENUE_USD), 2) FROM expected) AS NET_USD;
SQL
)

out=$(uvx --from snowflake-cli snow sql -c "$CONN" --format json -q "$sql" 2>&1)

python3 - "$out" <<'PY' || exit 1
import json, sys

raw = sys.argv[1]
expected = {
    "FCT_SALES": 9456, "ORDER_PAYMENTS": 1973, "DIM_EXCHANGE_RATES": 13242,
    "DIFF_SETTLE": 977, "NO_CCY": 60, "OUTPUT_ROWS": 340, "NET_USD": 118720.8,
}
try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    print("verify: FAILED - Snowflake did not return JSON:", file=sys.stderr)
    print(raw.strip()[-800:], file=sys.stderr)
    sys.exit(1)

row = None
for rs in payload if isinstance(payload, list) else []:
    if isinstance(rs, list):
        for r in rs:
            if isinstance(r, dict) and "FCT_SALES" in r:
                row = r
    elif isinstance(rs, dict) and "FCT_SALES" in rs:
        row = rs
if row is None:
    print("verify: FAILED - no result row", file=sys.stderr)
    sys.exit(1)

bad = False
for k, want in expected.items():
    got = row.get(k)
    got_cmp = round(float(got), 2) if isinstance(got, (int, float)) and k == "NET_USD" else got
    ok = abs(got_cmp - want) < 0.05 if k == "NET_USD" else got_cmp == want
    print(f"verify: {k:<20} {got} ({'ok' if ok else 'WRONG, expected ' + str(want)})")
    bad = bad or not ok

if bad:
    print("verify: FAILED - the data is not equivalent to the reference load.", file=sys.stderr)
    print("verify: do not run experiments against it; the published results assume this data.", file=sys.stderr)
    sys.exit(1)
print("verify: OK. Account is ready for Lesson 1.")
PY
