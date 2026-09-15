-- Grade FACT_REVENUE row by row against the governed definition.
--
-- This is the evaluator. It is deliberately not part of the task, and not something the
-- agent is asked to run: it recomputes the expected answer from the source tables and
-- compares, so a model that passes every dbt test can still fail here.
--
-- One file per data-eng-bench task, named after the task. Run it with
--   /correctness --exchange-rate-settlement-date
-- inside a session, or directly:
--   uvx --from snowflake-cli snow sql -c DEVREL_ENTERPRISE -f verifiers/exchange-rate-settlement-date.sql
--
-- The five counts, and what a nonzero value means:
--   ACTUAL_ROWS        rows the agent produced. Zero means nothing was built.
--   MISSING_ROWS       grain keys the answer should contain and does not.
--   UNEXPECTED_ROWS    grain keys the answer contains and should not.
--   VALUE_MISMATCHES   rows that match on the grain but disagree on USD amounts.
--   FX_DATE_VIOLATIONS rows converted at the order-date rate instead of the settlement
--                      -date rate. This is the failure every dbt test in the project
--                      misses, and it is the whole reason this file exists.

-- Run as the lab role, not as the connection's default role. dbt runs as DLAI_LAB_RL, and
-- the role that creates an object owns it: FACT_REVENUE is not readable by ACCOUNTADMIN
-- unless the lab role is in its hierarchy. Without this the grade fails with
-- "Insufficient privileges to operate on table 'FACT_REVENUE'".
USE ROLE DLAI_LAB_RL;
USE WAREHOUSE DLAI_LAB_WH;

WITH pay AS (
  SELECT ORDER_ID, CAST(MAX(PROCESSED_AT) AS DATE) AS SETTLEMENT_DATE
  FROM DLAI_AGENT_ENGINEERING.L1_FX_SOURCE.ORDER_PAYMENTS
  GROUP BY ORDER_ID
), sales AS (
  SELECT f.ORDER_DATE, f.CURRENCY_CODE, f.SOURCE_SYSTEM,
         f.EXTENDED_PRICE - f.DISCOUNT_AMOUNT AS NET_REVENUE,
         f.LINE_TOTAL AS TOTAL_REVENUE,
         COALESCE(p.SETTLEMENT_DATE, f.ORDER_DATE) AS SETTLEMENT_DATE
  FROM DLAI_AGENT_ENGINEERING.L1_FX_SOURCE.FCT_SALES f
  LEFT JOIN pay p ON f.ORDER_ID = p.ORDER_ID
  WHERE f.ORDER_DATE IS NOT NULL
), sales_fx AS (
  SELECT s.*,
         CASE WHEN s.CURRENCY_CODE = 'USD' THEN 1.0 ELSE COALESCE(r.RATE, 1.0) END AS FX_RATE
  FROM sales s
  LEFT JOIN DLAI_AGENT_ENGINEERING.L1_FX_SOURCE.DIM_EXCHANGE_RATES r
    ON s.CURRENCY_CODE = r.FROM_CURRENCY
   AND r.TO_CURRENCY = 'USD'
   AND r.RATE_DATE = s.SETTLEMENT_DATE
), expected AS (
  SELECT ORDER_DATE, SETTLEMENT_DATE, CURRENCY_CODE, SOURCE_SYSTEM,
         ROUND(SUM(NET_REVENUE * FX_RATE), 2) AS NET_REVENUE_USD,
         ROUND(SUM(TOTAL_REVENUE * FX_RATE), 2) AS TOTAL_REVENUE_USD
  FROM sales_fx
  GROUP BY 1, 2, 3, 4
), actual AS (
  SELECT ORDER_DATE, SETTLEMENT_DATE, CURRENCY_CODE, SOURCE_SYSTEM,
         NET_REVENUE_USD, TOTAL_REVENUE_USD, FX_RATE
  FROM DLAI_AGENT_ENGINEERING.L1_LAB.FACT_REVENUE
  WHERE ORDER_DATE IS NOT NULL
), missing AS (
  SELECT ORDER_DATE, SETTLEMENT_DATE, CURRENCY_CODE, SOURCE_SYSTEM FROM expected
  MINUS
  SELECT ORDER_DATE, SETTLEMENT_DATE, CURRENCY_CODE, SOURCE_SYSTEM FROM actual
), unexpected AS (
  SELECT ORDER_DATE, SETTLEMENT_DATE, CURRENCY_CODE, SOURCE_SYSTEM FROM actual
  MINUS
  SELECT ORDER_DATE, SETTLEMENT_DATE, CURRENCY_CODE, SOURCE_SYSTEM FROM expected
), matched AS (
  SELECT a.NET_REVENUE_USD AS A_NET, a.TOTAL_REVENUE_USD AS A_TOTAL,
         e.NET_REVENUE_USD AS E_NET, e.TOTAL_REVENUE_USD AS E_TOTAL
  FROM actual a
  JOIN expected e
    ON a.ORDER_DATE = e.ORDER_DATE
   AND a.SETTLEMENT_DATE = e.SETTLEMENT_DATE
   AND EQUAL_NULL(a.CURRENCY_CODE, e.CURRENCY_CODE)
   AND a.SOURCE_SYSTEM = e.SOURCE_SYSTEM
), fx_check AS (
  SELECT a.FX_RATE, rs.RATE AS SETTLE_RATE
  FROM actual a
  JOIN DLAI_AGENT_ENGINEERING.L1_FX_SOURCE.DIM_EXCHANGE_RATES rs
    ON a.CURRENCY_CODE = rs.FROM_CURRENCY
   AND rs.TO_CURRENCY = 'USD'
   AND rs.RATE_DATE = a.SETTLEMENT_DATE
  JOIN DLAI_AGENT_ENGINEERING.L1_FX_SOURCE.DIM_EXCHANGE_RATES ro
    ON a.CURRENCY_CODE = ro.FROM_CURRENCY
   AND ro.TO_CURRENCY = 'USD'
   AND ro.RATE_DATE = a.ORDER_DATE
  WHERE a.CURRENCY_CODE <> 'USD'
    AND ABS(rs.RATE - ro.RATE) > 0.01
), counts AS (
  SELECT (SELECT COUNT(*) FROM actual) AS ACTUAL_ROWS,
         (SELECT COUNT(*) FROM missing) AS MISSING_ROWS,
         (SELECT COUNT(*) FROM unexpected) AS UNEXPECTED_ROWS,
         (SELECT COUNT(*) FROM matched
           WHERE ABS(A_NET - E_NET) >= 0.20 OR ABS(A_TOTAL - E_TOTAL) >= 0.20) AS VALUE_MISMATCHES,
         (SELECT COUNT(*) FROM fx_check WHERE ABS(FX_RATE - SETTLE_RATE) > 0.01) AS FX_DATE_VIOLATIONS
)
SELECT CASE
         WHEN ACTUAL_ROWS > 0
          AND MISSING_ROWS = 0
          AND UNEXPECTED_ROWS = 0
          AND VALUE_MISMATCHES = 0
          AND FX_DATE_VIOLATIONS = 0
         THEN 'PASS' ELSE 'FAIL'
       END AS RESULT,
       ACTUAL_ROWS, MISSING_ROWS, UNEXPECTED_ROWS, VALUE_MISMATCHES, FX_DATE_VIOLATIONS
FROM counts;
