# Task prompt

Same bare task as Lesson 1. The runtime configuration and L2-specific tool
instructions are in `CLAUDE.md` in the workspace, which the agent reads
automatically at session start.

---

Finance cannot sum revenue across currencies, because FACT_REVENUE reports
local-currency amounts only. They want USD amounts converted at the rate in effect
when the customer's payment actually settled, not when the order was placed.

Fix the dbt model models/fact_revenue.sql.

Available sources:
- retail.fct_sales - order line grain sales fact
- retail.order_payments - payment records captured against orders
- retail.dim_exchange_rates - daily currency conversion rates

Add these columns to FACT_REVENUE, preserving every column already there:
- settlement_date - the date whose exchange rate was used for conversion
- fx_rate - the exchange rate applied
- net_revenue_usd - net_revenue converted to USD, rounded to 2 decimals
- total_revenue_usd - total_revenue converted to USD, rounded to 2 decimals

Rules:
- Derive the settlement date from the payment records.
- Orders with no payment record still have to appear in the output.
- Convert using the daily exchange-rate dimension, based on the settlement date.
- USD amounts must come through unchanged.
- No NULL FX rates in the output. Handle missing rates sensibly.
- Keep the existing grain of the revenue output while incorporating the settlement date.

Constraints:
- Do not modify the source tables or the source declaration.
- Do not change the model materialization.
- Make the smallest scoped change.
