# Efficient Tool Use for Coding Agents

Enterprise data platforms expose hundreds of capabilities. Loading every tool
definition at startup consumes context before the agent reads the task. Large
SQL results consume context after the agent calls a tool. Both pressures grow
with session length.

This lab demonstrates three levers that reduce token spend while maintaining
quality, using a real dbt task against Snowflake data.

## The three levers

| Lever | What it does | Implementation |
|---|---|---|
| **Tool search** | Defers tool schemas; agent discovers on demand | `search_tools` + `invoke_tool` in `tools/server.js` |
| **Output compaction** | Lossless compression: TSV encoding + constant-column preamble | `compactResult` in `tools/lib.js` |
| **Result offloading** | Stores oversized results locally; only a preview enters context | `offloadLargeResult` in `tools/lib.js` |

### Scale of the problem

The Anthropic blog ["Introducing advanced tool use"](https://www.anthropic.com/engineering/advanced-tool-use) documents the scaling problem: five MCP servers (GitHub,
Slack, Sentry, Grafana, Splunk) consume ~55K tokens of tool definitions before
the conversation starts. Only 2-3 tools are needed for any given task.

## Prerequisites

- Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)
- Node.js 18+
- One of these model backends:
  - A Snowflake account with Cortex enabled (uses a PAT for both model inference and data)
  - An Anthropic API key (you still need Snowflake or DuckDB for the data)
- One of these data backends:
  - A Snowflake account with the lab data provisioned (see `setup/`)
  - DuckDB with the data-eng-bench retail dataset (see "Running with DuckDB" below)

## One-time setup

```bash
git clone https://github.com/joshreini1/agent-engineering-efficient-tool-use-for-data-workflows.git
cd agent-engineering-efficient-tool-use-for-data-workflows
```

All commands below assume you are in this **repo root** directory.

```bash
npm install --prefix tools
```

Then set your credentials and wire up the environment. Pick Option A or B.

### Option A: Snowflake Cortex (model + data)

```bash
export SNOWFLAKE_ACCOUNT=<your-account>
export SNOWFLAKE_USER=<your-user>
export SNOWFLAKE_CONNECTION=<your-snow-cli-connection>
export ANTHROPIC_BASE_URL="https://<account-url>.snowflakecomputing.com/api/v2/cortex"
export ANTHROPIC_AUTH_TOKEN=<your Snowflake Cortex PAT>
unset ANTHROPIC_API_KEY   # avoid "Auth conflict" warning in Claude Code
export ANTHROPIC_MODEL=claude-opus-4-6
source lab/env.sh
```

### Option B: Anthropic API (model) + Snowflake (data)

```bash
export SNOWFLAKE_ACCOUNT=<your-account>
export SNOWFLAKE_USER=<your-user>
export SNOWFLAKE_CONNECTION=<your-snow-cli-connection>
export ANTHROPIC_API_KEY=<your Anthropic API key>
export ANTHROPIC_MODEL=claude-sonnet-4-5  # or any model on your account
source lab/env.sh
```

No `ANTHROPIC_BASE_URL` needed -- Claude Code uses the Anthropic API by default.

## Stage 1: See the scaling problem

From the **repo root**, reset the workspace and start with the naive (30 eager tools) MCP config:

```bash
# repo root
lab/reset.sh
cat > workspace/.mcp.json <<EOF
{"mcpServers":{"data":{"type":"stdio","command":"node","args":["$PWD/tools/naive-server.js"],"env":{"SNOWFLAKE_CONNECTION":"$SNOWFLAKE_CONNECTION","SNOWFLAKE_ROLE":"DLAI_LAB_RL","SNOWFLAKE_WAREHOUSE":"DLAI_LAB_WH","DBT_PROJECT_DIR":"$PWD/workspace"}}}}
EOF
cd workspace && claude --setting-sources project,local
```

You are now inside a Claude Code session (cwd: `workspace/`). Run `/mcp`. This
server exposes 30 tool definitions at startup. Ask the agent to list the
available data-engineering capabilities, then `/exit`.

## Stage 2: Run the task with the naive catalog

From the **repo root** (run `cd ..` if you are still in `workspace/`):

```bash
# repo root
lab/reset.sh
cat > workspace/.mcp.json <<EOF
{"mcpServers":{"data":{"type":"stdio","command":"node","args":["$PWD/tools/naive-server.js"],"env":{"SNOWFLAKE_CONNECTION":"$SNOWFLAKE_CONNECTION","SNOWFLAKE_ROLE":"DLAI_LAB_RL","SNOWFLAKE_WAREHOUSE":"DLAI_LAB_WH","DBT_PROJECT_DIR":"$PWD/workspace"}}}}
EOF
cd workspace && claude --setting-sources project,local
```

Paste this task:

```
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
```

After the agent finishes:

```
/correctness --exchange-rate-settlement-date
/cost
```

Record the correctness and cost. `/exit`.

## Stage 3: Understand and apply the efficiency levers

This stage walks through each lever's code, then lets you test it interactively.
Start from the **repo root** (run `cd ..` if still in `workspace/`).

### Lever 1: Tool search (deferred discovery)

Open `tools/server.js`. The server registers only two MCP schemas:

```javascript
server.tool("search_tools", ...);   // keyword search over the 30-tool catalog
server.tool("invoke_tool", ...);    // dispatch to one implemented tool by name
```

The full catalog lives in `tools/catalog.js` (30 entries, 8 categories). The
client loads two tool definitions. The agent calls `search_tools` first to find
what it needs, then `invoke_tool` to run it.

**Try it.** `/exit` the current session, then from the **repo root** (`cd ..`),
switch to the efficient server and start a new session:

```bash
cd ..   # back to repo root
cat > workspace/.mcp.json <<EOF
{"mcpServers":{"data":{"type":"stdio","command":"node","args":["$PWD/tools/server.js"],"env":{"SNOWFLAKE_CONNECTION":"$SNOWFLAKE_CONNECTION","SNOWFLAKE_ROLE":"DLAI_LAB_RL","SNOWFLAKE_WAREHOUSE":"DLAI_LAB_WH","DBT_PROJECT_DIR":"$PWD/workspace"}}}}
EOF
cd workspace && claude --setting-sources project,local
```

Run `/mcp`. Now there are only two tools (`search_tools` and `invoke_tool`),
yet the same 30-capability catalog is available. Ask the agent:
`Search the MCP tool catalog for "dbt"`

### Lever 2: Output compaction (lossless compression)

Open `tools/lib.js` and find `compactResult`. Both output levers are applied
automatically inside `executeQuery`:

```javascript
export async function executeQuery(sql, options = {}) {
  // ... run SQL via snow sql --format JSON ...
  const { inlineRows, artifact, truncated } = await offloadLargeResult(...);
  const { preamble, tsv } = compactResult(columns, inlineRows);
  return { ..., preamble, tsv };
}
```

`compactResult` applies two lossless transformations:

```javascript
export function compactResult(columns, rows) {
  // 1. Constant-column preamble: columns with the same value in every row
  //    are stated once and removed from the row body.
  // 2. TSV encoding: tab-separated, no Markdown padding.
  return { preamble, tsv: `${header}\n${body}` };
}
```

**Try it.** Ask the agent:
```
Run this SQL: SELECT 'USD' AS TO_CURRENCY, FROM_CURRENCY, RATE FROM DLAI_AGENT_ENGINEERING.L1_FX_SOURCE.DIM_EXCHANGE_RATES WHERE RATE_DATE = '2024-01-02' LIMIT 10
```

Expand the tool result (ctrl+o in Claude Code). Look for `"preamble":
{"TO_CURRENCY": "USD"}` and a TSV body with only FROM_CURRENCY and RATE -- the
constant column is stated once and removed from the rows.

Note: the compaction saves tokens in the **tool result that enters context**, not
in the model's final response. The model reads the compact form, reasons over it,
and may re-render it however it wants (e.g. as a Markdown table). The savings are
in what the model pays to read, not what it displays.

### Lever 3: Intermediate result offloading

`offloadLargeResult` decides whether the full result fits inline (up to 20 rows /
6 KB) or must be written to disk:

```javascript
export async function offloadLargeResult(sql, rows, columns, rawChars) {
  const mustOffload = rows.length > maxInlineRows || ...;
  if (mustOffload) {
    await writeFile(".tool-results/query-<timestamp>.json", ...);
  }
  return { inlineRows: mustOffload ? sample.slice(0, 5) : sample, artifact };
}
```

When offloading triggers, the model gets: column names, the constant-column
preamble, 5 rows of compacted TSV, the artifact filepath, and `truncated: true`.
The full result is preserved on disk but never enters context.

**Try it.** Ask the agent:
```
Run this SQL: SELECT * FROM DLAI_AGENT_ENGINEERING.L1_FX_SOURCE.DIM_EXCHANGE_RATES
```

Expand the tool result. Look for `"truncated": true`, a 5-row preview, and the
`.tool-results/query-*.json` artifact path. The full 13,242 rows are on disk;
only ~900 characters entered context.

`/exit` when done exploring.

### Run the full task

`/exit` the interactive session, then from the **repo root** (`cd ..` if needed):

```bash
# repo root
lab/reset.sh
cat > workspace/.mcp.json <<EOF
{"mcpServers":{"data":{"type":"stdio","command":"node","args":["$PWD/tools/server.js"],"env":{"SNOWFLAKE_CONNECTION":"$SNOWFLAKE_CONNECTION","SNOWFLAKE_ROLE":"DLAI_LAB_RL","SNOWFLAKE_WAREHOUSE":"DLAI_LAB_WH","DBT_PROJECT_DIR":"$PWD/workspace"}}}}
EOF
cd workspace && claude --setting-sources project,local
```

Paste the same task as Stage 2:

```
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
```

After the agent finishes:

```
/correctness --exchange-rate-settlement-date
/cost
```

Check offloaded files: `ls .tool-results/`

## Expected results

| | Naive (30 eager tools) | Efficient (search + compaction) |
|---|---|---|
| Correct | PASS (340 rows) | PASS (340 rows) |
| Cost | ~$2.64 | ~$2.37 (10% less) |

Agents are stochastic. One run is a directional signal, not a rigorous comparison.

## What transfers

| Lever | Portable principle |
|---|---|
| Tool search | MCP catalog pattern works with any MCP client |
| Output compaction | Lossless; replace format for any SQL backend |
| Result offloading | Keep oversized data out of context; mechanism varies |

A fourth lever, **bundled dispatch (Programmatic Tool Calling)**, bundles multiple
tool calls into a single code-execution turn. PTC requires harness-level support
and is available in CoCo and the Anthropic API, but not in Claude Code CLI.

## These efficiencies -- and more -- are built into Snowflake CoCo

[Snowflake CoCo](https://www.snowflake.com/en/product/snowflake-coco/) (formerly Cortex Code) is Snowflake's data-native AI coding agent. The levers in this lab -- tool search, output compaction, result offloading -- are production features in CoCo's harness, along with additional optimizations like bundled dispatch (PTC), sidecar-based skill loading, and automatic context management.

The result is a shifted cost-quality frontier: a smaller model on CoCo matches or beats a larger model on a conventional harness.

<p align="center">
  <img src="https://www.snowflake.com/adobe/dynamicmedia/deliver/dm-aid--e1443c2c-1528-442a-830a-42f145760cdd/figure-1.-introducing-data-eng-bench--why-you-need-data-native-harnesses-for-data-engineering.png?preferwebp=true&quality=85&width=960" alt="Quality vs cost per trial by harness and model on data-eng-bench" width="720" />
</p>

<p align="center"><em>Quality vs cost per trial on <a href="https://github.com/Snowflake-Labs/data-eng-bench">data-eng-bench</a> (up-and-left is better). From <a href="https://www.snowflake.com/en/blog/engineering/data-eng-bench-data-engineering-agent-benchmark/">Snowflake AI Research, Aug 2026</a>.</em></p>

### Cost-quality frontier

**SQL-fixing benchmark** (Pass3 over three trials):

| Harness | Model | Pass3 | Cost/trial |
|---|---|---|---|
| **Snowflake CoCo** | Opus 5 | **98%** | $0.40 |
| **Snowflake CoCo** | Sonnet 5 | **86%** | $0.30 |
| Claude Code | Opus 5 | 72% | $0.45 |
| Claude Code | Sonnet 5 | 44% | $0.15 |

CoCo on Sonnet 5 outperforms Claude Code on Opus 5 -- a smaller model on the stronger harness -- with 86% vs 72% reliability at 33% lower cost.

**General Snowflake workloads** (Pass3 over three trials):

| Harness | Model | Pass3 | Cost/trial |
|---|---|---|---|
| **Snowflake CoCo** | Opus 5 | **68%** | $1.26 |
| **Snowflake CoCo** | Sonnet 5 | **60%** | $0.45 |
| Claude Code | Opus 5 | 58% | $0.82 |
| Claude Code | Sonnet 5 | 48% | $0.29 |

CoCo on Sonnet 5 matches Claude Code on Opus 5 reliability (60% vs 58%) at 45% lower cost per trial.

### Try CoCo

Sign up for a free trial at [signup.snowflake.com/cortex-code](https://signup.snowflake.com/cortex-code) -- includes 30 days of free credits. CoCo is available as a CLI, desktop app, in Snowsight, and as a VS Code extension.

## References

- [Intelligence Efficiency in CoCo and CoWork](https://www.snowflake.com/en/blog/engineering/snowflake-coco-cowork-token-spend-efficiency/) -- Snowflake AI Research, Aug 2026
- [Introducing advanced tool use](https://www.anthropic.com/engineering/advanced-tool-use) -- Anthropic, Nov 2025

## Running with DuckDB (no Snowflake account needed)

The task and data come from [data-eng-bench](https://github.com/Snowflake-Labs/data-eng-bench),
which supports both Snowflake and DuckDB.

1. Clone data-eng-bench and pull the DuckDB fixture:
   ```bash
   git clone https://github.com/Snowflake-Labs/data-eng-bench
   cd data-eng-bench && git lfs pull --include base-image/database/retail.duckdb
   ```

2. The DuckDB file contains `FCT_SALES`, `ORDER_PAYMENTS`, and `DIM_EXCHANGE_RATES`
   with identical data. Point dbt at DuckDB using `dbt-duckdb` instead of
   `dbt-snowflake`, and update `dbt_project/profiles.yml` to use a DuckDB connection.

3. Replace the SQL executor in `tools/lib.js`: change the `snow sql` subprocess call
   to `duckdb retail.duckdb -json`. The `compactResult` and `offloadLargeResult`
   functions work on parsed JSON rows regardless of the backend -- only the executor
   changes.

4. The `/correctness` verifier uses Snowflake SQL. Adapt the query in
   `verifiers/exchange-rate-settlement-date.sql` to DuckDB syntax (minor difference:
   `EQUAL_NULL` becomes `IS NOT DISTINCT FROM`).

## Troubleshooting

| Symptom | Cause |
|---|---|
| `/mcp` shows no tools | a relative path in `.mcp.json`, or you launched from the wrong directory |
| the agent cannot authenticate to Snowflake | you did not `source lab/env.sh` before launching |
| `/correctness` says FACT_REVENUE is not built | the agent never completed a successful dbt build |
| the reset counts are not 9456 / 1973 / 13242 | the source data is wrong; run `setup/verify_setup.sh` |
| `Auth conflict` | you launched without `--setting-sources project,local` |
