import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { catalog, implementedTools } from "./catalog.js";
import { assertIdentifier, executeQuery, dbt } from "./lib.js";

const server = new McpServer({ name: "dlai-l2-tool-catalog", version: "1.0.0" });

server.tool(
  "search_tools",
  "Search the larger data-engineering catalog before invoking a capability. Returns compact tool references, not full tool schemas.",
  { query: z.string(), category: z.string().optional(), limit: z.number().int().min(1).max(8).default(5) },
  async ({ query, category, limit }) => {
    const terms = query.toLowerCase().split(/\W+/).filter(Boolean);
    const results = catalog
      .filter((tool) => !category || tool.category === category)
      .map((tool) => ({
        ...tool,
        score: terms.reduce((score, term) => score + (`${tool.name} ${tool.category} ${tool.description}`.toLowerCase().includes(term) ? 1 : 0), 0),
        implemented: implementedTools.has(tool.name),
      }))
      .filter((tool) => tool.score > 0)
      .sort((left, right) => right.score - left.score || left.name.localeCompare(right.name))
      .slice(0, limit)
      .map(({ score, ...tool }) => tool);
    return { content: [{ type: "text", text: JSON.stringify({ catalog_size: catalog.length, results }, null, 2) }] };
  },
);

server.tool(
  "invoke_tool",
  "Invoke one tool returned by search_tools. SQL results are bounded and oversized results are stored locally instead of entering model context.",
  { name: z.string(), input: z.record(z.unknown()).default({}) },
  async ({ name, input }) => {
    if (!implementedTools.has(name)) throw new Error(`${name} is catalog-only in this lab`);
    let result;
    if (name === "catalog_list_databases") result = await executeQuery("SHOW DATABASES", { maxRows: input.max_rows });
    else if (name === "catalog_list_schemas") result = await executeQuery(`SHOW SCHEMAS IN DATABASE ${assertIdentifier(input.database, "database")}`, { maxRows: input.max_rows });
    else if (name === "catalog_list_relations") result = await executeQuery(`SHOW TABLES IN SCHEMA ${assertIdentifier(input.schema, "schema")}`, { maxRows: input.max_rows });
    else if (name === "schema_describe_table" || name === "schema_list_columns") result = await executeQuery(`DESCRIBE TABLE ${assertIdentifier(input.table_name, "table_name")}`, { maxRows: input.max_rows });
    else if (name === "sql_query") result = await executeQuery(String(input.sql || ""), { maxRows: input.max_rows });
    else if (name === "sql_sample_rows") result = await executeQuery(`SELECT * FROM ${assertIdentifier(input.table_name, "table_name")} LIMIT ${Math.min(Math.max(Number(input.limit || 10), 1), 100)}`);
    else if (name === "sql_profile_table") result = await executeQuery(String(input.sql || ""));
    else if (name === "sql_explain") result = await executeQuery(`EXPLAIN ${input.sql}`);
    else if (name === "warehouse_status") result = await executeQuery("SHOW WAREHOUSES");
    else if (name.startsWith("dbt_")) result = await dbt(name.replace("dbt_", ""));
    return { content: [{ type: "text", text: JSON.stringify({ tool: name, result }, null, 2) }] };
  },
);

await server.connect(new StdioServerTransport());