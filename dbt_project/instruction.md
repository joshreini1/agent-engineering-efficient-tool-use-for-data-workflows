# Revenue FX Settlement Date Fix

Finance cannot sum revenue across currencies because `FACT_REVENUE` reports local
currency amounts only. Add USD amounts converted at the rate in effect when the
customer's payment settled, not when the order was placed.

Fix `models/fact_revenue.sql`. Preserve every existing column and add
`settlement_date`, `fx_rate`, `net_revenue_usd`, and `total_revenue_usd`.

Derive settlement date from payment records. Preserve orders without payments. Use
the daily exchange rate for that settlement date. Keep USD unchanged, avoid null FX
rates, and preserve the existing output grain.

Do not modify sources or materialization. Continue until the focused dbt build and
visible tests pass. Report the inferred rules, evidence, changed files, and checks.