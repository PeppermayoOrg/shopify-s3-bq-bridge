require("dotenv").config();
const fs = require("fs");
const os = require("os");
const path = require("path");
const { createObjectCsvWriter } = require("csv-writer");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const {
  ORDER_HEADER,
  ITEM_HEADER,
  FX_HEADER,
  REFUND_HEADER,
  REFUND_ITEM_HEADER,
  FULFILLMENT_HEADER,
  FULFILLMENT_ITEM_HEADER,
  PRODUCT_HEADER,
  PRODUCT_VARIANT_HEADER,
  delay,
  retry,
  getNextUrl,
  fetchWithRetry,
  mapOrdersPage,
  fetchProducts,
  fetchFxRatesRange,
} = require("../src/shared/utils");

// S3 client. maxAttempts: 5 bumps the SDK's internal retry count from
// the default 3, which is especially valuable for a long-running
// backfill that may hit transient network flakes across thousands of
// uploads. The `retry()` wrapper below adds a second layer of
// backoff-with-jitter on top.
const s3Client = new S3Client({ region: "ap-southeast-2", maxAttempts: 5 });
const S3_BUCKET = process.env.S3_BUCKET || "peppermayo-shopify-orders";
const API_VERSION = "2026-01";

// Write CSVs to a scratch dir under the OS tmp directory instead of
// the cwd. Keeps the repo root clean even if the script is run from
// there, and guarantees the path is writable.
const SCRATCH_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "pm-backfill-"));

const STORES = {
  au: {
    domain: "pmayo.myshopify.com",
    token: process.env.SHOPIFY_TOKEN_AU,
  },
  us: {
    domain: "pmayo-us.myshopify.com",
    token: process.env.SHOPIFY_TOKEN_US,
  },
  uk: {
    domain: "pmayo-uk.myshopify.com",
    token: process.env.SHOPIFY_TOKEN_UK,
  },
  ca: {
    domain: "pmayo-ca.myshopify.com",
    token: process.env.SHOPIFY_TOKEN_CA,
  },
  eu: {
    domain: "pmayo-eu.myshopify.com",
    token: process.env.SHOPIFY_TOKEN_EU,
  },
};

function assertTokens() {
  const missing = Object.entries(STORES)
    .filter(([, c]) => !c.token)
    .map(([r]) => `SHOPIFY_TOKEN_${r.toUpperCase()}`);
  if (missing.length) {
    throw new Error(`Missing required env vars: ${missing.join(", ")}`);
  }
}

async function uploadAndCleanup(localPath, s3Key) {
  if (!fs.existsSync(localPath)) return;
  try {
    await retry(() =>
      s3Client.send(
        new PutObjectCommand({
          Bucket: S3_BUCKET,
          Key: s3Key,
          Body: fs.createReadStream(localPath),
        }),
      ),
    );
  } finally {
    if (fs.existsSync(localPath)) fs.unlinkSync(localPath);
  }
}

async function fetchAndStream(domain, token, createdAtMin, createdAtMax, region, files) {
  let url = `https://${domain}/admin/api/${API_VERSION}/orders.json?created_at_min=${createdAtMin}&created_at_max=${createdAtMax}&status=any&limit=250`;
  const headers = { "X-Shopify-Access-Token": token };

  const init = {
    orders: false, items: false,
    refunds: false, refundItems: false,
    fulfillments: false, fulfillmentItems: false,
  };
  const totals = {
    orders: 0, items: 0,
    refunds: 0, refundItems: 0,
    fulfillments: 0, fulfillmentItems: 0,
  };
  let pageNum = 0;

  async function writeBatch(path, header, records, initKey) {
    if (!records.length) return;
    const writer = createObjectCsvWriter({ path, header, append: init[initKey] });
    await writer.writeRecords(records);
    init[initKey] = true;
  }

  while (url) {
    const response = await fetchWithRetry(url, headers);
    const page = response.data.orders || [];
    pageNum += 1;

    if (page.length) {
      const {
        orderRows, itemRows,
        refundRows, refundItemRows,
        fulfillmentRows, fulfillmentItemRows,
      } = mapOrdersPage(page, region);

      await writeBatch(files.orders,           ORDER_HEADER,            orderRows,           "orders");
      await writeBatch(files.items,            ITEM_HEADER,             itemRows,            "items");
      await writeBatch(files.refunds,          REFUND_HEADER,           refundRows,          "refunds");
      await writeBatch(files.refundItems,      REFUND_ITEM_HEADER,      refundItemRows,      "refundItems");
      await writeBatch(files.fulfillments,     FULFILLMENT_HEADER,      fulfillmentRows,     "fulfillments");
      await writeBatch(files.fulfillmentItems, FULFILLMENT_ITEM_HEADER, fulfillmentItemRows, "fulfillmentItems");

      totals.orders           += orderRows.length;
      totals.items            += itemRows.length;
      totals.refunds          += refundRows.length;
      totals.refundItems      += refundItemRows.length;
      totals.fulfillments     += fulfillmentRows.length;
      totals.fulfillmentItems += fulfillmentItemRows.length;
    }

    // Per-page progress — a long month can be 50+ pages and the user
    // otherwise has no signal that the script is alive.
    process.stdout.write(
      `  page ${String(pageNum).padStart(3)} → ${String(page.length).padStart(3)} orders` +
      ` (running totals: ${totals.orders} orders / ${totals.items} items` +
      ` / ${totals.refunds} refunds / ${totals.fulfillments} fulfillments)\n`,
    );

    const callLimit = response.headers["x-shopify-shop-api-call-limit"];
    if (callLimit) {
      const [current, max] = callLimit.split("/").map(Number);
      if (max - current < 5) await delay(2000);
    }

    url = getNextUrl(response.headers["link"]);
  }

  return totals;
}

// Resolve the six historical/* file paths and S3 keys for one
// (region, fileMonth) pair. Used by both runOrdersBackfill and
// runOrdersGapFill so the path conventions stay in lockstep.
function historicalFilePaths(region, fileMonth) {
  const stem = `${region}_%s_historical_${fileMonth}.csv`;
  return {
    orders:           path.join(SCRATCH_DIR, stem.replace("%s", "orders")),
    items:            path.join(SCRATCH_DIR, stem.replace("%s", "items")),
    refunds:          path.join(SCRATCH_DIR, stem.replace("%s", "refunds")),
    refundItems:      path.join(SCRATCH_DIR, stem.replace("%s", "refund_items")),
    fulfillments:     path.join(SCRATCH_DIR, stem.replace("%s", "fulfillments")),
    fulfillmentItems: path.join(SCRATCH_DIR, stem.replace("%s", "fulfillment_items")),
  };
}

async function uploadHistoricalSet(files) {
  await uploadAndCleanup(files.orders,           `historical/orders/${path.basename(files.orders)}`);
  await uploadAndCleanup(files.items,            `historical/items/${path.basename(files.items)}`);
  await uploadAndCleanup(files.refunds,          `historical/refunds/${path.basename(files.refunds)}`);
  await uploadAndCleanup(files.refundItems,      `historical/refund_items/${path.basename(files.refundItems)}`);
  await uploadAndCleanup(files.fulfillments,     `historical/fulfillments/${path.basename(files.fulfillments)}`);
  await uploadAndCleanup(files.fulfillmentItems, `historical/fulfillment_items/${path.basename(files.fulfillmentItems)}`);
}

// Convert 'YYYY-MM' to the inclusive UTC ISO bounds for that month.
function monthToBounds(yyyymm) {
  const m = /^(\d{4})-(\d{2})$/.exec(yyyymm);
  if (!m) throw new Error(`Invalid month: ${yyyymm} (expected YYYY-MM)`);
  const y = Number(m[1]);
  const mo = Number(m[2]);
  if (mo < 1 || mo > 12) throw new Error(`Invalid month: ${yyyymm}`);
  const start = new Date(Date.UTC(y, mo - 1, 1));
  const end = new Date(Date.UTC(mo === 12 ? y + 1 : y, mo === 12 ? 0 : mo, 1));
  return { start, end };
}

async function runOrdersBackfill(storeStartDates) {
  assertTokens();
  const endDate = new Date();

  for (const [region, config] of Object.entries(STORES)) {
    const startDateStr = storeStartDates[region];
    if (!startDateStr) {
      console.log(`\n--- Skipping ${region} (no start date provided) ---`);
      continue;
    }

    console.log(`\n--- Starting backfill for ${region} from ${startDateStr} ---`);
    let currentStart = new Date(startDateStr);

    while (currentStart < endDate) {
      const currentEnd = new Date(currentStart);
      currentEnd.setMonth(currentEnd.getMonth() + 1);

      const createdAtMin = currentStart.toISOString();
      const createdAtMax = currentEnd.toISOString();
      const fileMonth = currentStart.toISOString().slice(0, 7);
      const files = historicalFilePaths(region, fileMonth);

      console.log(`Fetching ${region}: ${fileMonth}...`);
      const totals = await fetchAndStream(
        config.domain,
        config.token,
        createdAtMin,
        createdAtMax,
        region,
        files,
      );

      if (totals.orders > 0) {
        await uploadHistoricalSet(files);
        console.log(
          `Uploaded ${fileMonth}: ${totals.orders} orders, ${totals.items} items, ` +
          `${totals.refunds} refunds (${totals.refundItems} items), ` +
          `${totals.fulfillments} fulfillments (${totals.fulfillmentItems} items).`,
        );
      } else {
        console.log(`No orders found for ${fileMonth}.`);
      }
      currentStart = currentEnd;
    }
  }
}

// Targeted gap-fill. Runs only the (region, month) pairs in the
// supplied list. Same MERGE-guarded write path as the full backfill,
// so re-running an already-loaded month is a no-op for unchanged rows
// and still picks up any missing inserts.
async function runOrdersGapFill(targets) {
  assertTokens();
  if (!targets.length) {
    console.log("No BACKFILL_MONTHS configured — nothing to do.");
    return;
  }
  console.log(`\n--- Gap-fill: ${targets.length} (region, month) pair(s) ---`);

  for (const { region, month } of targets) {
    const config = STORES[region];
    if (!config) {
      throw new Error(`Unknown region in BACKFILL_MONTHS: ${region}`);
    }
    const { start, end } = monthToBounds(month);
    const createdAtMin = start.toISOString();
    const createdAtMax = end.toISOString();
    const files = historicalFilePaths(region, month);

    console.log(`\nFetching ${region}: ${month} (${createdAtMin} → ${createdAtMax})…`);
    const totals = await fetchAndStream(
      config.domain,
      config.token,
      createdAtMin,
      createdAtMax,
      region,
      files,
    );

    if (totals.orders > 0) {
      await uploadHistoricalSet(files);
      console.log(
        `Uploaded ${region} ${month}: ${totals.orders} orders, ${totals.items} items, ` +
        `${totals.refunds} refunds (${totals.refundItems} items), ` +
        `${totals.fulfillments} fulfillments (${totals.fulfillmentItems} items).`,
      );
    } else {
      console.log(`No orders found for ${region} ${month}.`);
    }
  }
}

// One-off products catalog pull. Writes directly to `weekly/products/`
// so the normal weekly DTS + refresh_products_master.sql path picks
// them up without a separate "historical" route. There's nothing
// historical about a product catalog — only the current state matters
// — so we piggyback on the existing weekly pipeline.
async function runProductsBackfill() {
  assertTokens();
  const dateStr = new Date().toISOString().split("T")[0];
  console.log(`\n--- Products catalog pull for ${dateStr} ---`);

  for (const [region, config] of Object.entries(STORES)) {
    const productsFile = path.join(SCRATCH_DIR, `${region}_products_${dateStr}.csv`);
    const variantsFile = path.join(SCRATCH_DIR, `${region}_product_variants_${dateStr}.csv`);

    let productsInit = false;
    let variantsInit = false;

    const onPage = async ({ productRows, variantRows }) => {
      if (productRows.length) {
        const w = createObjectCsvWriter({ path: productsFile, header: PRODUCT_HEADER, append: productsInit });
        await w.writeRecords(productRows);
        productsInit = true;
      }
      if (variantRows.length) {
        const w = createObjectCsvWriter({ path: variantsFile, header: PRODUCT_VARIANT_HEADER, append: variantsInit });
        await w.writeRecords(variantRows);
        variantsInit = true;
      }
    };

    console.log(`[${region}] fetching product catalog...`);
    const { totalProducts, totalVariants } = await fetchProducts(config.domain, config.token, region, API_VERSION, onPage);
    console.log(`[${region}] ${totalProducts} products / ${totalVariants} variants`);

    if (totalProducts > 0) {
      await uploadAndCleanup(productsFile, `weekly/products/${region}_products_${dateStr}.csv`);
      await uploadAndCleanup(variantsFile, `weekly/product_variants/${region}_product_variants_${dateStr}.csv`);
    }
  }
}

// One-off FX backfill. Frankfurter's /timeseries endpoint returns the
// full range in a single call, so we don't page per month. Covers
// every order-creation date the backfill could write, so v_orders
// always has a rate to join against.
async function runFxBackfill({ startDate = "2020-01-01", endDate } = {}) {
  const end = endDate ? new Date(endDate) : new Date();
  const start = new Date(startDate);
  console.log(`\n--- FX backfill ${start.toISOString().slice(0, 10)} .. ${end.toISOString().slice(0, 10)} ---`);

  const rows = await fetchFxRatesRange(start, end);
  if (!rows.length) {
    console.log("No FX rates returned. Aborting.");
    return;
  }

  const fileName = `fx_historical_${start.toISOString().slice(0, 10)}_to_${end.toISOString().slice(0, 10)}.csv`;
  const localPath = path.join(SCRATCH_DIR, fileName);
  const writer = createObjectCsvWriter({ path: localPath, header: FX_HEADER });
  await writer.writeRecords(rows);
  await uploadAndCleanup(localPath, `historical/fx/${fileName}`);
  console.log(`Uploaded ${rows.length} FX rates to historical/fx/${fileName}.`);
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
// Two ways to run an orders backfill:
//
//  1. Full backfill (default). Each region walks forward one month at
//     a time from its START_DATES entry to today. Use this for the
//     initial historical load.
//
//  2. Targeted gap-fill. Set BACKFILL_MONTHS to a non-empty list of
//     (region, month) pairs and run `npm run backfill -- gaps`. Only
//     those specific months are fetched and uploaded, and the merge
//     guard (S.updated_at > T.updated_at) makes the re-load safe even
//     for months that already have rows in master. Use this to repair
//     known gaps surfaced by `npm run verify:counts`.
//
// Use the "YYYY-MM-DD" format for START_DATES and "YYYY-MM" for months.
// To skip a store completely, comment its entry out.
//
// Default configuration (all stores, all history):
// const START_DATES = {
//   au: "2020-01-01",
//   us: "2020-01-01",
//   uk: "2020-01-01",
//   ca: "2020-01-01",
//   eu: "2020-01-01",
// };

const START_DATES = {
  // au: "2020-01-01",
  // us: "2020-01-01",
  // uk: "2020-01-01",
  // ca: "2020-01-01",
  // eu: "2020-01-01",
};

// Targeted (region, month) pairs to re-fetch. Edit this list, then run
// `npm run backfill -- gaps`. Leave empty in normal operation.
const BACKFILL_MONTHS = [
  // { region: "au", month: "2024-10" },
  // { region: "au", month: "2025-01" },
];

// Dispatch on `npm run backfill -- <orders|gaps|fx|products|all>`.
// Defaults to `orders` so existing muscle memory keeps working.
async function main() {
  const mode = (process.argv[2] || "orders").toLowerCase();
  if (!["orders", "gaps", "fx", "products", "all"].includes(mode)) {
    console.error(`Unknown mode: ${mode}. Expected one of: orders, gaps, fx, products, all`);
    process.exit(1);
  }
  console.log(`Scratch dir: ${SCRATCH_DIR}`);

  if (mode === "orders" || mode === "all") {
    await runOrdersBackfill(START_DATES);
  }
  if (mode === "gaps") {
    await runOrdersGapFill(BACKFILL_MONTHS);
  }
  if (mode === "fx" || mode === "all") {
    // FX backfill covers every date any order could land on.
    const earliest = Object.values(START_DATES).sort()[0] || "2020-01-01";
    await runFxBackfill({ startDate: earliest });
  }
  if (mode === "products" || mode === "all") {
    await runProductsBackfill();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
