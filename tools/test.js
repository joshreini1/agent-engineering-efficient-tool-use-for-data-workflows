import assert from "node:assert/strict";
import { catalog } from "./catalog.js";
import { assertIdentifier, assertReadOnly, executeQuery, compactResult } from "./lib.js";

assert.equal(catalog.length, 30);
assert.equal(new Set(catalog.map((tool) => tool.name)).size, 30);
assert.equal(assertIdentifier("DB.SCHEMA.TABLE"), "DB.SCHEMA.TABLE");
assert.throws(() => assertIdentifier("DB.SCHEMA.TABLE; DROP TABLE X"));
assert.equal(assertReadOnly("-- evidence\nSELECT 1;"), "SELECT 1");
assert.equal(assertReadOnly("WITH x AS (SELECT 1) SELECT * FROM x"), "WITH x AS (SELECT 1) SELECT * FROM x");
assert.throws(() => assertReadOnly("SELECT 1; DELETE FROM T"));
assert.throws(() => assertReadOnly("CALL dangerous()"));

const compact = await executeQuery(
  "SELECT SEQ4() AS N FROM TABLE(GENERATOR(ROWCOUNT => 30))",
  { maxRows: 10 },
);
assert.equal(compact.returned_rows, 30);
assert.equal(compact.inline_rows, 5);
assert.equal(compact.truncated, true);
assert.ok(compact.artifact);
assert.ok(compact.tsv);
assert.ok(compact.tsv.startsWith("N\n"));

// Lossless compression: constant-column preamble
const constTest = await executeQuery(
  "SELECT 'USD' AS CURRENCY, SEQ4() AS N FROM TABLE(GENERATOR(ROWCOUNT => 5))",
);
assert.equal(constTest.truncated, false);
assert.ok(constTest.preamble);
assert.equal(constTest.preamble.CURRENCY, "USD");
assert.ok(!constTest.tsv.includes("USD"));  // constant column removed from TSV body
assert.ok(constTest.tsv.startsWith("N\n")); // only varying column remains
assert.ok(constTest.compressed_characters < constTest.raw_characters);

console.log("tool contract tests: PASS");