#!/usr/bin/env node
/**
 * Schema alignment check.
 *
 * Catches the class of bug that caused the 2026-04-23 daily Orders load
 * failure: the CSV extractor in src/shared/utils.js had `source_name`
 * added at column index 17, but the live BigQuery staging_orders table
 * (and its DDL) was never updated. BigQuery CSV loads bind columns by
 * ORDINAL POSITION — header names are ignored — so the CSV was
 * off-by-one against the table and silently corrupted two rows before
 * failing on a non-numeric source_name value.
 *
 * Two modes:
 *
 *   npm run verify:schema         -- static: _HEADER arrays in
 *                                    src/shared/utils.js vs staging
 *                                    CREATE TABLE statements in
 *                                    sql/ddl/. Runs as part of
 *                                    `npm run build` so a broken zip
 *                                    can't ship.
 *
 *   npm run verify:schema:live    -- same static checks, PLUS queries
 *                                    the live BigQuery dataset and
 *                                    compares its schemas to the repo
 *                                    DDL. Catches drift introduced
 *                                    outside this repo (e.g. a console
 *                                    `ALTER TABLE ADD COLUMN`). Run
 *                                    before every schema-changing
 *                                    deploy and after every
 *                                    `sql/migrations/*.sql` run.
 *
 * The live mode shells out to `bq show --format=prettyjson <dataset>.<table>`
 * so you need the `bq` CLI authenticated against the project that owns
 * the dataset. Override the dataset with BQ_DATASET (default: peppermayo).
 *
 * Exits non-zero on any mismatch. Prints a human-readable diff.
 */

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const REPO_ROOT = path.resolve(__dirname, "..");
const UTILS_PATH = path.join(REPO_ROOT, "src/shared/utils.js");
const DDL_DIR = path.join(REPO_ROOT, "sql/ddl");
const BQ_DATASET = process.env.BQ_DATASET || "peppermayo";

// Static check pairs: (header const name in utils.js, staging table, DDL file).
const HEADER_PAIRS = [
  ["ORDER_HEADER", "staging_orders", "create_staging_tables.sql"],
  ["ITEM_HEADER", "staging_order_items", "create_staging_tables.sql"],
  ["FX_HEADER", "staging_fx_rates", "create_staging_fx_tables.sql"],
  ["REFUND_HEADER", "staging_refunds", "create_staging_refunds_tables.sql"],
  [
    "REFUND_ITEM_HEADER",
    "staging_refund_line_items",
    "create_staging_refunds_tables.sql",
  ],
  [
    "FULFILLMENT_HEADER",
    "staging_fulfillments",
    "create_staging_fulfillments_tables.sql",
  ],
  [
    "FULFILLMENT_ITEM_HEADER",
    "staging_fulfillment_line_items",
    "create_staging_fulfillments_tables.sql",
  ],
  ["PRODUCT_HEADER", "staging_products", "create_staging_products_tables.sql"],
  [
    "PRODUCT_VARIANT_HEADER",
    "staging_product_variants",
    "create_staging_products_tables.sql",
  ],
];

// Live check targets: every table whose column ORDER matters because
// CSV loads bind positionally. Staging tables are the obvious ones (DTS
// writes CSV into them). Master tables are included because the
// incident root cause was a console `ALTER TABLE ADD COLUMN` on
// orders_master — the MERGEs use explicit column lists so order doesn't
// break them, but out-of-order columns in master still signal that
// someone did a console ALTER instead of a proper migration, and
// staging likely has the same problem.
const LIVE_TABLES = [
  { table: "staging_orders", ddlFile: "create_staging_tables.sql" },
  { table: "staging_order_items", ddlFile: "create_staging_tables.sql" },
  { table: "staging_fx_rates", ddlFile: "create_staging_fx_tables.sql" },
  { table: "staging_refunds", ddlFile: "create_staging_refunds_tables.sql" },
  {
    table: "staging_refund_line_items",
    ddlFile: "create_staging_refunds_tables.sql",
  },
  {
    table: "staging_fulfillments",
    ddlFile: "create_staging_fulfillments_tables.sql",
  },
  {
    table: "staging_fulfillment_line_items",
    ddlFile: "create_staging_fulfillments_tables.sql",
  },
  { table: "staging_products", ddlFile: "create_staging_products_tables.sql" },
  {
    table: "staging_product_variants",
    ddlFile: "create_staging_products_tables.sql",
  },
  { table: "orders_master", ddlFile: "create_master_tables.sql" },
  { table: "order_items_master", ddlFile: "create_master_tables.sql" },
  { table: "fx_rates_master", ddlFile: "create_fx_tables.sql" },
  { table: "refunds_master", ddlFile: "create_refunds_tables.sql" },
  { table: "refund_line_items_master", ddlFile: "create_refunds_tables.sql" },
  { table: "fulfillments_master", ddlFile: "create_fulfillments_tables.sql" },
  {
    table: "fulfillment_line_items_master",
    ddlFile: "create_fulfillments_tables.sql",
  },
];

function extractHeaderColumns(utilsSource, constName) {
  const re = new RegExp(
    `const\\s+${constName}\\s*=\\s*\\[([\\s\\S]*?)\\];`,
    "m",
  );
  const m = utilsSource.match(re);
  if (!m) throw new Error(`Could not find ${constName} in utils.js`);
  const body = m[1];
  const idRe = /id\s*:\s*"([^"]+)"/g;
  const cols = [];
  let mm;
  while ((mm = idRe.exec(body)) !== null) cols.push(mm[1]);
  if (!cols.length) throw new Error(`${constName} parsed to zero columns`);
  return cols;
}

function extractDdlColumns(ddlSource, tableName) {
  // Also match `CREATE OR REPLACE TABLE` (refresh_*_master.sql style).
  const re = new RegExp(
    "CREATE\\s+(?:OR\\s+REPLACE\\s+)?TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?`peppermayo\\." +
      tableName +
      "`\\s*\\(([\\s\\S]*?)\\)\\s*(?:OPTIONS|PARTITION|CLUSTER|AS\\b|;)",
    "m",
  );
  const m = ddlSource.match(re);
  if (!m) throw new Error(`Could not find CREATE TABLE for ${tableName}`);
  const body = m[1];

  const cols = [];
  for (let rawLine of body.split("\n")) {
    const commentIdx = rawLine.indexOf("--");
    const line = (
      commentIdx >= 0 ? rawLine.slice(0, commentIdx) : rawLine
    ).trim();
    if (!line) continue;
    const colMatch = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s+(?:[A-Z]|ARRAY)/);
    if (!colMatch) continue;
    cols.push(colMatch[1]);
  }
  if (!cols.length) throw new Error(`${tableName} parsed to zero columns`);
  return cols;
}

function fetchLiveColumns(fqTable) {
  // `bq show --format=prettyjson <dataset>.<table>` returns a JSON doc
  // whose `schema.fields` array preserves the table's column order.
  let raw;
  try {
    raw = execFileSync("bq", ["show", "--format=prettyjson", fqTable], {
      stdio: ["ignore", "pipe", "pipe"],
      encoding: "utf8",
    });
  } catch (err) {
    const stderr = err.stderr ? err.stderr.toString() : err.message;
    throw new Error(`bq show failed for ${fqTable}: ${stderr.trim()}`);
  }
  const parsed = JSON.parse(raw);
  const fields = parsed && parsed.schema && parsed.schema.fields;
  if (!Array.isArray(fields)) {
    throw new Error(`${fqTable}: schema.fields missing in bq response`);
  }
  return fields.map((f) => f.name);
}

function diff(expected, actual, labelExp, labelAct) {
  const out = [];
  const len = Math.max(expected.length, actual.length);
  for (let i = 0; i < len; i++) {
    if (expected[i] !== actual[i]) {
      out.push(
        `    idx ${String(i).padStart(2)}: ` +
          `${labelExp}=${expected[i] ?? "<missing>"}  ` +
          `${labelAct}=${actual[i] ?? "<missing>"}`,
      );
    }
  }
  return out;
}

function runStaticChecks() {
  console.log("== Static checks (utils.js ↔ repo DDL) ==");
  const utilsSrc = fs.readFileSync(UTILS_PATH, "utf8");
  const ddlCache = new Map();
  const failures = [];

  for (const [constName, tableName, ddlFile] of HEADER_PAIRS) {
    const ddlPath = path.join(DDL_DIR, ddlFile);
    if (!ddlCache.has(ddlPath)) {
      ddlCache.set(ddlPath, fs.readFileSync(ddlPath, "utf8"));
    }
    const csvCols = extractHeaderColumns(utilsSrc, constName);
    const ddlCols = extractDdlColumns(ddlCache.get(ddlPath), tableName);

    const mismatches = diff(csvCols, ddlCols, "CSV", "DDL");
    if (mismatches.length || csvCols.length !== ddlCols.length) {
      failures.push({
        label: `${constName} ↔ ${tableName}`,
        ddlFile,
        expected: csvCols,
        actual: ddlCols,
        mismatches,
        expLabel: "CSV",
        actLabel: "DDL",
      });
    } else {
      console.log(`✓ ${constName} (${csvCols.length}) ↔ ${tableName}`);
    }
  }
  return failures;
}

function runLiveChecks() {
  console.log(
    `\n== Live checks (repo DDL ↔ BigQuery dataset '${BQ_DATASET}') ==`,
  );

  // Fail fast if bq is missing — a confusing ENOENT later is unhelpful.
  try {
    execFileSync("bq", ["version"], { stdio: ["ignore", "pipe", "pipe"] });
  } catch (err) {
    console.error(
      "\n✗ `bq` CLI not found or not authenticated. Install the Google\n" +
        "  Cloud SDK and run `gcloud auth application-default login`, then\n" +
        "  retry. (Static checks above still passed.)",
    );
    process.exit(2);
  }

  const ddlCache = new Map();
  const failures = [];

  for (const { table, ddlFile } of LIVE_TABLES) {
    const ddlPath = path.join(DDL_DIR, ddlFile);
    if (!ddlCache.has(ddlPath)) {
      ddlCache.set(ddlPath, fs.readFileSync(ddlPath, "utf8"));
    }
    const ddlCols = extractDdlColumns(ddlCache.get(ddlPath), table);

    let liveCols;
    try {
      liveCols = fetchLiveColumns(`${BQ_DATASET}.${table}`);
    } catch (err) {
      failures.push({
        label: `${BQ_DATASET}.${table}`,
        ddlFile,
        error: err.message,
      });
      continue;
    }

    const mismatches = diff(ddlCols, liveCols, "DDL", "LIVE");
    if (mismatches.length || ddlCols.length !== liveCols.length) {
      failures.push({
        label: `${BQ_DATASET}.${table}`,
        ddlFile,
        expected: ddlCols,
        actual: liveCols,
        mismatches,
        expLabel: "DDL",
        actLabel: "LIVE",
      });
    } else {
      console.log(`✓ ${table} (${ddlCols.length}) — live matches ${ddlFile}`);
    }
  }
  return failures;
}

function reportFailures(failures, header, remediation) {
  if (!failures.length) return;
  console.error(`\n✗ ${header}:\n`);
  for (const f of failures) {
    console.error(`  ${f.label}  (ddl: ${f.ddlFile})`);
    if (f.error) {
      console.error(`    ERROR: ${f.error}`);
      console.error("");
      continue;
    }
    console.error(`    ${f.expLabel} column count: ${f.expected.length}`);
    console.error(`    ${f.actLabel} column count: ${f.actual.length}`);
    for (const line of f.mismatches) console.error(line);
    console.error("");
  }
  console.error(remediation);
}

function main() {
  const live = process.argv.includes("--live");

  const staticFailures = runStaticChecks();
  const liveFailures = live ? runLiveChecks() : [];

  reportFailures(
    staticFailures,
    "Static schema alignment failures (utils.js ↔ repo DDL)",
    "BigQuery CSV loads bind columns by ordinal position. Fix the CSV\n" +
      "header (src/shared/utils.js), the staging DDL (sql/ddl/...), and\n" +
      "the master DDL + merge DML together.",
  );
  reportFailures(
    liveFailures,
    "Live schema drift (repo DDL ↔ live BigQuery table)",
    "Live tables don't match the repo. Do NOT use `ALTER TABLE ADD COLUMN`\n" +
      "on a CSV-loaded table — it appends at the end and breaks positional\n" +
      "CSV loads. Write a migration under sql/migrations/ that rebuilds the\n" +
      "table with `CREATE OR REPLACE TABLE ... AS SELECT` in the correct\n" +
      "column order, then re-run this check with --live.",
  );

  if (staticFailures.length || liveFailures.length) {
    process.exit(1);
  }

  const suffix = live ? `static + live against '${BQ_DATASET}'` : "static only";
  console.log(`\nAll schemas aligned (${suffix}).`);
}

main();
