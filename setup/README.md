# Recreating the lab in a Snowflake account

Three scripts, run in order. They are idempotent and each one verifies its own work.

```bash
# 1. Objects: database, schemas, warehouse, role, grants, empty tables.
uvx --from snowflake-cli snow sql -c <target> -f setup/setup.sql

# 2. Data out of an account that already has it.
setup/export_data.sh <source> setup/fixtures

# 3. Data into the new account, verified.
setup/load_data.sh <target> setup/fixtures
```

Check an existing account at any time:

```bash
setup/verify_setup.sh <connection>
```

## What gets created

| Object | Name |
|---|---|
| Database | `DLAI_AGENT_ENGINEERING` |
| Source schema | `L1_FX_SOURCE` (read-only to the lab role) |
| Working schema | `L1_LAB` |
| Warehouse | `DLAI_LAB_WH` (XSMALL, auto-suspend 60) |
| Role | `DLAI_LAB_RL` |
| Stage | `L1_FX_SOURCE.FXSTAGE` |

`setup.sql` grants `DLAI_LAB_RL` to `CURRENT_USER()`, so it grants to whoever runs it.

After running these, point [../env.sh](../env.sh) at the account and run
[../reset.sh](../reset.sh).

## The data is not committed here

`setup/fixtures/` is deliberately empty in version control. The rows are derived from the
[Snowflake-Labs/data-eng-bench](https://github.com/Snowflake-Labs/data-eng-bench) retail
dataset, whose task definitions carry a canary string asking that benchmark data stay out
of training corpora. Committing the Parquet to a public course repository would work
against that, so the fixtures are generated on demand from an account that already holds
the data.

If no account has the data, rebuild it from the benchmark:

```bash
git clone https://github.com/Snowflake-Labs/data-eng-bench
cd data-eng-bench && git lfs pull --include base-image/database/retail.duckdb
```

Then extract `FCT_SALES`, `ORDER_PAYMENTS` and `DIM_EXCHANGE_RATES` from the DuckDB file
to Parquet, casting every timestamp column to an ISO string, and drop the files in
`setup/fixtures/` as `<TABLE>.parquet`.

## Why the timestamps go through strings

Every temporal column is exported as an ISO string and cast back on load. Loading Parquet
timestamps directly produced invalid dates when this dataset was first loaded, and the
whole task turns on `PROCESSED_AT` resolving to the correct settlement date. A load that
looks fine but shifts that column produces a lab that runs normally and grades wrongly.

That is also why `verify_setup.sh` checks more than row counts:

| Check | Expected |
|---|---|
| `FCT_SALES` | 9,456 |
| `ORDER_PAYMENTS` | 1,973 |
| `DIM_EXCHANGE_RATES` | 13,242 |
| rows settling on a date other than the order date | 977 |
| rows with no currency code | 60 |
| expected output rows | 340 |
| expected net USD total | 118,720.80 |

The published turn and cost figures in [../README.md](../README.md) assume exactly this
data. If `verify_setup.sh` fails, do not run experiments against the account.

## Known CLI quirk

`snow stage copy` given a `file://` destination reports `DOWNLOADED` and writes into a
directory literally named `file:` under the current directory. `export_data.sh` passes a
plain local path instead.
