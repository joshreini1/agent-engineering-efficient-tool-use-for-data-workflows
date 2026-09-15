This is a focused dbt project for a single model. Read the dbt project files
before editing anything.

- The Snowflake connection is already configured through environment variables
  and profiles.yml. Do not change the connection or authentication.
- Database: DLAI_AGENT_ENGINEERING
- Source schema: L1_FX_SOURCE (read-only fixtures)
- Lab schema: L1_LAB (agent writes here)
- Role: DLAI_LAB_RL
- Warehouse: DLAI_LAB_WH
- The dbt source `retail` resolves to the tables in the configured schema.
  Read models/sources.yml for the source definitions.
- Work only in this workspace. Do not search the web.
- Do not read parent directories or any runner/evaluator files.
- Search the tool catalog before invoking capabilities.
- Prefer aggregate SQL evidence and bounded samples over large result sets.
- Continue until the focused dbt build and visible tests pass.
