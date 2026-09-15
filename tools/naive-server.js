import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { catalog } from "./catalog.js";

const execFileAsync = promisify(execFile);
const connection = process.env.SNOWFLAKE_CONNECTION || "DEVREL_ENTERPRISE";
const role = process.env.SNOWFLAKE_ROLE || "";
const warehouse = process.env.SNOWFLAKE_WAREHOUSE || "";
const projectDir = process.env.DBT_PROJECT_DIR;

function assertIdentifier(value) {
  if (!/^[A-Za-z_][A-Za-z0-9_$]*(\.[A-Za-z_][A-Za-z0-9_$]*){0,2}$/.test(value)) {
    throw new Error("input must be an unquoted Snowflake identifier with at most three parts");
  }
  return value;
}

function assertReadOnly(sql) {
  const normalized = sql.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/--[^\n]*/g, " ").trim();
  if (!/^(select|with|show|describe|desc|explain)\b/i.test(normalized)) throw new Error("Only read-only SQL is allowed");
  if (/;\s*\S/.test(normalized) || /\b(insert|update|delete|merge|create|alter|drop|truncate|copy|put|remove|grant|revoke|call)\b/i.test(normalized)) {
    throw new Error("Only one read-only SQL statement is allowed");
  }
  return normalized;
}

async function run(command, args, env = {}) {
  const { stdout, stderr } = await execFileAsync(command, args, {
    env: { ...process.env, ...env },
    maxBuffer: 20 * 1024 * 1024,
  });
  return `${stdout}${stderr ? `\n${stderr}` : ""}`.trim();
}

async function snowSql(sql) {
  const args = ["--from", "snowflake-cli", "snow", "sql", "-c", connection];
  if (role) args.push("--role", role);
  if (warehouse) args.push("--warehouse", warehouse);
  args.push("-q", sql);
  return run("uvx", args);
}

async function dbt(command) {
  if (!projectDir) throw new Error("DBT_PROJECT_DIR is required");
  return run(
    "uvx",
    ["--with", "dbt-snowflake", "--from", "dbt-core", "dbt", command, "--project-dir", projectDir],
    { DBT_PROFILES_DIR: projectDir },
  );
}

const server = new McpServer({ name: "dlai-l2-eager-catalog", version: "1.0.0" });

for (const tool of catalog) {
  server.tool(
    tool.name,
    `${tool.description} This Lesson 2 eager-catalog tool is loaded in full at session start.`,
    { input: z.string().optional().describe("SQL, object name, or optional command input") },
    async ({ input = "" }) => {
      if (tool.name === "schema_describe_table") {
        return { content: [{ type: "text", text: await snowSql(`DESCRIBE TABLE ${assertIdentifier(input)}`) }] };
      }
      if (tool.name === "sql_query") {
        return { content: [{ type: "text", text: await snowSql(assertReadOnly(input)) }] };
      }
      if (tool.name === "dbt_build") {
        return { content: [{ type: "text", text: await dbt("build") }] };
      }
      return {
        content: [{
          type: "text",
          text: `${tool.name} is present to demonstrate an eagerly loaded enterprise catalog. Use the focused schema, SQL, and dbt tools for this lab.`,
        }],
      };
    },
  );
}

await server.connect(new StdioServerTransport());