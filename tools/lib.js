import { execFile } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const connection = process.env.SNOWFLAKE_CONNECTION || "DEVREL_ENTERPRISE";
const role = process.env.SNOWFLAKE_ROLE || "";
const warehouse = process.env.SNOWFLAKE_WAREHOUSE || "";
const projectDir = process.env.DBT_PROJECT_DIR;
const resultDir = process.env.TOOL_RESULT_DIR || path.join(projectDir || process.cwd(), ".tool-results");
const maxInlineRows = Number(process.env.MAX_INLINE_SQL_ROWS || 20);
const maxInlineChars = Number(process.env.MAX_INLINE_SQL_CHARS || 6000);

export async function run(command, args, env = {}) {
  try {
    const { stdout, stderr } = await execFileAsync(command, args, {
      env: { ...process.env, ...env },
      maxBuffer: 20 * 1024 * 1024,
    });
    return { stdout, stderr, exitCode: 0 };
  } catch (error) {
    const details = `${error.stdout || ""}${error.stderr || ""}`.trim();
    error.message = `${error.message}\n${details.slice(-4000)}`.trim();
    throw error;
  }
}

export function assertReadOnly(sql) {
  const normalized = sql
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/--[^\n]*/g, " ")
    .trim();
  if (!/^(select|with|show|describe|desc|explain)\b/i.test(normalized)) {
    throw new Error("Only SELECT, WITH, SHOW, DESCRIBE, and EXPLAIN statements are allowed");
  }
  const withoutStrings = normalized.replace(/'(?:''|[^'])*'/g, "''");
  if (/;\s*\S/.test(withoutStrings)) throw new Error("Only one SQL statement is allowed");
  if (/\b(insert|update|delete|merge|create|alter|drop|truncate|copy|put|remove|grant|revoke|call)\b/i.test(withoutStrings)) {
    throw new Error("The SQL contains a write or administrative operation");
  }
  return normalized.replace(/;\s*$/, "");
}

export function assertIdentifier(value, label = "identifier") {
  const identifier = String(value || "");
  if (!/^[A-Za-z_][A-Za-z0-9_$]*(\.[A-Za-z_][A-Za-z0-9_$]*){0,2}$/.test(identifier)) {
    throw new Error(`${label} must be an unquoted Snowflake identifier with at most three parts`);
  }
  return identifier;
}

function flattenRows(payload) {
  const resultSets = Array.isArray(payload) ? payload : [payload];
  return resultSets.flatMap((item) => Array.isArray(item) ? item : [item]).filter((item) => item && typeof item === "object" && !Array.isArray(item));
}

// Lever 2: Output compaction (lossless compression).
// TSV encoding with constant-column preamble. Every value is preserved.
// Constant columns are listed once in a preamble and removed from the row body.
// The remaining columns are tab-separated (no padding, no Markdown formatting).
export function compactResult(columns, rows) {
  if (rows.length === 0) return { preamble: null, tsv: "", compressed_characters: 0 };

  const constants = {};
  const varying = [];
  for (const col of columns) {
    const first = String(rows[0][col] ?? "");
    if (rows.every((row) => String(row[col] ?? "") === first)) {
      constants[col] = rows[0][col];
    } else {
      varying.push(col);
    }
  }

  const preamble = Object.keys(constants).length > 0 ? constants : null;
  const header = varying.join("\t");
  const body = rows.map((row) => varying.map((col) => String(row[col] ?? "")).join("\t")).join("\n");
  const tsv = `${header}\n${body}`;
  return { preamble, tsv, compressed_characters: tsv.length + JSON.stringify(preamble).length };
}

// Lever 3: Intermediate result offloading.
// When a result exceeds the inline threshold, write the full payload to a local
// file and return only a bounded preview. The full data is preserved on disk but
// never enters model context.
export async function offloadLargeResult(sql, rows, columns, rawChars, options = {}) {
  const requestedRows = options.maxRows || maxInlineRows;
  const sample = rows.slice(0, requestedRows);
  const sampleChars = JSON.stringify(sample).length;
  const mustOffload = rows.length > requestedRows || sampleChars > maxInlineChars || rawChars > maxInlineChars;
  let artifact = null;
  if (mustOffload) {
    await mkdir(resultDir, { recursive: true });
    artifact = path.join(resultDir, `query-${Date.now()}.json`);
    await writeFile(artifact, JSON.stringify({ sql, rows }, null, 2));
  }
  const inlineRows = mustOffload ? sample.slice(0, 5) : sample;
  return { inlineRows, artifact, truncated: mustOffload };
}

// Execute a read-only SQL query, then apply both levers:
// 1. offloadLargeResult -- bound what enters context
// 2. compactResult -- losslessly compress what remains
export async function executeQuery(sql, options = {}) {
  const safeSql = assertReadOnly(sql);
  const started = Date.now();
  const args = ["--from", "snowflake-cli", "snow", "sql", "-c", connection, "--format", "JSON", "--silent"];
  if (role) args.push("--role", role);
  if (warehouse) args.push("--warehouse", warehouse);
  args.push("-q", safeSql);
  const { stdout } = await run("uvx", args);
  let payload;
  try {
    payload = JSON.parse(stdout);
  } catch {
    throw new Error(`Snowflake did not return JSON: ${stdout.slice(0, 500)}`);
  }
  const rows = flattenRows(payload);
  const columns = rows.length ? Object.keys(rows[0]) : [];
  const rawChars = stdout.length;

  const { inlineRows, artifact, truncated } = await offloadLargeResult(safeSql, rows, columns, rawChars, options);
  const { preamble, tsv, compressed_characters } = compactResult(columns, inlineRows);

  return {
    columns,
    returned_rows: rows.length,
    inline_rows: inlineRows.length,
    truncated,
    raw_characters: rawChars,
    compressed_characters,
    artifact,
    elapsed_ms: Date.now() - started,
    preamble,
    tsv,
  };
}

export async function dbt(command) {
  if (!projectDir) throw new Error("DBT_PROJECT_DIR is required");
  const { stdout, stderr } = await run(
    "uvx",
    ["--with", "dbt-snowflake", "--from", "dbt-core", "dbt", command, "--project-dir", projectDir],
    { DBT_PROFILES_DIR: projectDir },
  );
  const lines = `${stdout}${stderr ? `\n${stderr}` : ""}`.trim().split("\n");
  return {
    command: `dbt ${command}`,
    line_count: lines.length,
    summary: lines.slice(-20).join("\n"),
  };
}
