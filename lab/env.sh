#!/usr/bin/env bash
# Snowflake and dbt wiring. Source this before running an experiment:
#
#   source lab/env.sh
#
# The agent's tools reach Snowflake through this environment. dbt reads these
# variables from profiles.yml, so the same project works without editing files.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# Your account — export these before sourcing this file.
export SNOWFLAKE_ACCOUNT="${SNOWFLAKE_ACCOUNT:-}"
export SNOWFLAKE_USER="${SNOWFLAKE_USER:-}"

# Lab objects, created by setup/setup.sql.
export SNOWFLAKE_DATABASE=DLAI_AGENT_ENGINEERING
export SNOWFLAKE_WAREHOUSE=DLAI_LAB_WH
export SNOWFLAKE_ROLE=DLAI_LAB_RL
export SNOWFLAKE_TARGET_SCHEMA=L1_LAB

# dbt authentication: Option A uses ANTHROPIC_AUTH_TOKEN (PAT), Option B uses ANTHROPIC_API_KEY.
export SNOWFLAKE_AUTHENTICATOR=snowflake
export SNOWFLAKE_PASSWORD="${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"

# Paths the reset script and MCP configs reference.
export DBT_PROJECT_DIR="$REPO_ROOT/workspace"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

missing=""
[ -z "${SNOWFLAKE_ACCOUNT:-}" ] && missing="$missing SNOWFLAKE_ACCOUNT"
[ -z "${SNOWFLAKE_USER:-}" ] && missing="$missing SNOWFLAKE_USER"
[ -z "${ANTHROPIC_BASE_URL:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] && missing="$missing ANTHROPIC_BASE_URL-or-ANTHROPIC_API_KEY"
[ -z "${ANTHROPIC_MODEL:-}" ] && missing="$missing ANTHROPIC_MODEL"
[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] && missing="$missing ANTHROPIC_AUTH_TOKEN-or-ANTHROPIC_API_KEY"
if [ -n "$missing" ]; then
  echo "env.sh: not set yet:$missing" >&2
  echo "env.sh: export them first. See the README." >&2
fi
unset missing
