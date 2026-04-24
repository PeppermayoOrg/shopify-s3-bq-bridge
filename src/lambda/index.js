/**
 * Daily Shopify -> S3 extraction Lambda.
 *
 * Runs once per day on EventBridge. For every storefront, pulls the orders
 * updated in the last 26 hours (26h gives ~2h overlap across runs so we
 * never miss an order if a run is delayed or retried), scrubs PII, and writes
 * two CSVs per region to S3: one for orders, one for line items.
 *
 * BigQuery Data Transfer picks these up shortly after.
 */

const fs = require("fs");
const path = require("path");
const { createObjectCsvWriter } = require("csv-writer");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const { SSMClient, GetParameterCommand } = require("@aws-sdk/client-ssm");
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
  fetchFxRates,
} = require("../shared/utils");

const API_VERSION = "2026-01";
const S3_BUCKET = process.env.S3_BUCKET || "peppermayo-shopify-orders";
const ROLLING_WINDOW_HOURS = 26;

const STORES = {
  au: { domain: "pmayo.myshopify.com", ssmKey: "/shopify/peppermayo-au/token" },
  us: { domain: "pmayo-us.myshopify.com", ssmKey: "/shopify/peppermayo-us/token" },
  uk: { domain: "pmayo-uk.myshopify.com", ssmKey: "/shopify/peppermayo-uk/token" },
  ca: { domain: "pmayo-ca.myshopify.com", ssmKey: "/shopify/peppermayo-ca/token" },
  eu: { domain: "pmayo-eu.myshopify.com", ssmKey: "/shopify/peppermayo-eu/token" },
};

const ssm = new SSMClient();
// Bump SDK retries from the default 3 — the daily pipeline is an
// unattended batch job and a failed upload is expensive (a whole
// region has to be re-fetched on the next run).
const s3 = new S3Client({ maxAttempts: 5 });

// Streams each paginated response straight to disk so we never hold more
// than one page (~250 orders) of raw data in memory at once. For each
// order we also extract embedded refund and fulfilment events and
// stream them to their own CSVs — this is why a single Shopify call
// produces six output files (orders, items, refunds, refund_items,
// fulfillments, fulfillment_items).
async function fetchAndStream(domain, token, updatedAtMin, updatedAtMax, region, files) {
  let url = `https://${domain}/admin/api/${API_VERSION}/orders.json?updated_at_min=${updatedAtMin}&updated_at_max=${updatedAtMax}&status=any&limit=250`;
  const headers = { "X-Shopify-Access-Token": token };

  const init = {
    orders: false,
    items: false,
    refunds: false,
    refundItems: false,
    fulfillments: false,
    fulfillmentItems: false,
  };
  const totals = {
    orders: 0,
    items: 0,
    refunds: 0,
    refundItems: 0,
    fulfillments: 0,
    fulfillmentItems: 0,
  };

  async function writeBatch(path, header, records, initKey) {
    if (!records.length) return;
    const writer = createObjectCsvWriter({ path, header, append: init[initKey] });
    await writer.writeRecords(records);
    init[initKey] = true;
  }

  while (url) {
    const response = await fetchWithRetry(url, headers);
    const page = response.data.orders || [];

    if (page.length) {
      const {
        orderRows,
        itemRows,
        refundRows,
        refundItemRows,
        fulfillmentRows,
        fulfillmentItemRows,
      } = mapOrdersPage(page, region);

      await writeBatch(files.orders,           ORDER_HEADER,              orderRows,           "orders");
      await writeBatch(files.items,            ITEM_HEADER,               itemRows,            "items");
      await writeBatch(files.refunds,          REFUND_HEADER,             refundRows,          "refunds");
      await writeBatch(files.refundItems,      REFUND_ITEM_HEADER,        refundItemRows,      "refundItems");
      await writeBatch(files.fulfillments,     FULFILLMENT_HEADER,        fulfillmentRows,     "fulfillments");
      await writeBatch(files.fulfillmentItems, FULFILLMENT_ITEM_HEADER,   fulfillmentItemRows, "fulfillmentItems");

      totals.orders           += orderRows.length;
      totals.items            += itemRows.length;
      totals.refunds          += refundRows.length;
      totals.refundItems      += refundItemRows.length;
      totals.fulfillments     += fulfillmentRows.length;
      totals.fulfillmentItems += fulfillmentItemRows.length;
    }

    const callLimit = response.headers["x-shopify-shop-api-call-limit"];
    if (callLimit) {
      const [current, max] = callLimit.split("/").map(Number);
      if (max - current < 5) await delay(2000);
    }

    url = getNextUrl(response.headers["link"]);
  }

  return totals;
}

async function uploadAndCleanup(filePath, key) {
  if (!fs.existsSync(filePath)) return;
  try {
    // SDK already retries internally (maxAttempts: 5). The outer retry
    // adds another layer of exponential backoff with jitter so a
    // sustained S3 hiccup can't fail the whole daily run.
    await retry(() =>
      s3.send(
        new PutObjectCommand({
          Bucket: S3_BUCKET,
          Key: key,
          Body: fs.createReadStream(filePath),
        }),
      ),
    );
  } finally {
    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
    }
  }
}

async function syncFxRates(now, dateStr) {
  console.log(`[fx] fetching rates for ${dateStr}`);
  const rows = await fetchFxRates(now);
  const fxFile = path.join("/tmp", `fx_${dateStr}.csv`);
  const writer = createObjectCsvWriter({ path: fxFile, header: FX_HEADER });
  await writer.writeRecords(rows);
  await uploadAndCleanup(fxFile, `daily/fx/fx_${dateStr}.csv`);
  console.log(`[fx] wrote ${rows.length} rates for ${dateStr}`);
  return { rates: rows.length };
}

async function syncRegion(region, config, updatedAtMin, updatedAtMax, dateStr) {
  console.log(`[${region}] fetching orders updated ${updatedAtMin} -> ${updatedAtMax}`);

  const { Parameter } = await ssm.send(
    new GetParameterCommand({ Name: config.ssmKey, WithDecryption: true }),
  );

  const files = {
    orders:           path.join("/tmp", `${region}_orders_${dateStr}.csv`),
    items:            path.join("/tmp", `${region}_items_${dateStr}.csv`),
    refunds:          path.join("/tmp", `${region}_refunds_${dateStr}.csv`),
    refundItems:      path.join("/tmp", `${region}_refund_items_${dateStr}.csv`),
    fulfillments:     path.join("/tmp", `${region}_fulfillments_${dateStr}.csv`),
    fulfillmentItems: path.join("/tmp", `${region}_fulfillment_items_${dateStr}.csv`),
  };

  const totals = await fetchAndStream(
    config.domain,
    Parameter.Value,
    updatedAtMin,
    updatedAtMax,
    region,
    files,
  );
  console.log(
    `[${region}] ${totals.orders} orders / ${totals.items} items / ` +
    `${totals.refunds} refunds (${totals.refundItems} items) / ` +
    `${totals.fulfillments} fulfillments (${totals.fulfillmentItems} items)`,
  );

  if (totals.orders === 0) return { region, orders: 0 };

  await uploadAndCleanup(files.orders,           `daily/orders/${region}_orders_${dateStr}.csv`);
  await uploadAndCleanup(files.items,            `daily/items/${region}_items_${dateStr}.csv`);
  await uploadAndCleanup(files.refunds,          `daily/refunds/${region}_refunds_${dateStr}.csv`);
  await uploadAndCleanup(files.refundItems,      `daily/refund_items/${region}_refund_items_${dateStr}.csv`);
  await uploadAndCleanup(files.fulfillments,     `daily/fulfillments/${region}_fulfillments_${dateStr}.csv`);
  await uploadAndCleanup(files.fulfillmentItems, `daily/fulfillment_items/${region}_fulfillment_items_${dateStr}.csv`);

  return { region, ...totals };
}

// Weekly product catalog refresh. Invoked by a separate EventBridge
// rule with payload `{ mode: "products" }`. Full refresh semantics:
// we truncate the staging tables via DTS and rebuild products_master
// with CREATE OR REPLACE, so emitting all products every week is
// correct.
async function syncProducts(dateStr) {
  const results = [];
  const failures = [];

  for (const [region, config] of Object.entries(STORES)) {
    try {
      console.log(`[${region}/products] fetching catalog`);
      const { Parameter } = await ssm.send(
        new GetParameterCommand({ Name: config.ssmKey, WithDecryption: true }),
      );

      const productsFile = path.join("/tmp", `${region}_products_${dateStr}.csv`);
      const variantsFile = path.join("/tmp", `${region}_product_variants_${dateStr}.csv`);

      let productsInit = false;
      let variantsInit = false;

      const onPage = async ({ productRows, variantRows }) => {
        if (productRows.length) {
          const writer = createObjectCsvWriter({
            path: productsFile,
            header: PRODUCT_HEADER,
            append: productsInit,
          });
          await writer.writeRecords(productRows);
          productsInit = true;
        }
        if (variantRows.length) {
          const writer = createObjectCsvWriter({
            path: variantsFile,
            header: PRODUCT_VARIANT_HEADER,
            append: variantsInit,
          });
          await writer.writeRecords(variantRows);
          variantsInit = true;
        }
      };

      const { totalProducts, totalVariants } = await fetchProducts(
        config.domain,
        Parameter.Value,
        region,
        API_VERSION,
        onPage,
      );
      console.log(`[${region}/products] ${totalProducts} products / ${totalVariants} variants`);

      if (totalProducts > 0) {
        await uploadAndCleanup(productsFile, `weekly/products/${region}_products_${dateStr}.csv`);
        await uploadAndCleanup(variantsFile, `weekly/product_variants/${region}_product_variants_${dateStr}.csv`);
      }
      results.push({ region, products: totalProducts, variants: totalVariants });
    } catch (err) {
      console.error(`[${region}/products] sync failed:`, err);
      failures.push({ region, error: err.message });
    }
  }

  return { results, failures };
}

exports.handler = async (event = {}) => {
  const now = new Date();
  const dateStr = now.toISOString().split("T")[0];
  const mode = event.mode || "daily";

  // Weekly products refresh — invoked by a separate EventBridge rule
  // with `{ "mode": "products" }` in the payload. Runs independently
  // of the daily order/FX sync so one doesn't block or crash the other.
  if (mode === "products") {
    console.log(`[products] starting weekly catalog refresh for ${dateStr}`);
    const { results, failures } = await syncProducts(dateStr);
    if (failures.length > 0) {
      throw new Error(
        `Products sync completed with ${failures.length} failure(s): ${JSON.stringify({ results, failures })}`,
      );
    }
    return {
      statusCode: 200,
      body: JSON.stringify({ mode: "products", date: dateStr, results }),
    };
  }

  const startTime = new Date(now.getTime() - ROLLING_WINDOW_HOURS * 60 * 60 * 1000);
  const updatedAtMin = startTime.toISOString();
  const updatedAtMax = now.toISOString();

  const results = [];
  const failures = [];

  for (const [region, config] of Object.entries(STORES)) {
    try {
      const result = await syncRegion(region, config, updatedAtMin, updatedAtMax, dateStr);
      results.push(result);
    } catch (err) {
      console.error(`[${region}] sync failed:`, err);
      failures.push({ region, error: err.message });
    }
  }

  // FX snapshot runs after the regions. A single HTTP call to
  // Frankfurter; failure here doesn't block the order sync but is
  // surfaced as a failure so the Lambda invocation reports failed.
  let fxResult = null;
  try {
    fxResult = await syncFxRates(now, dateStr);
  } catch (err) {
    console.error(`[fx] sync failed:`, err);
    failures.push({ region: "fx", error: err.message });
  }

  if (failures.length > 0) {
    const summary = { window: { updatedAtMin, updatedAtMax }, results, fx: fxResult, failures };
    throw new Error(
      `Daily sync completed with ${failures.length} failure(s): ${JSON.stringify(summary)}`,
    );
  }

  return {
    statusCode: 200,
    body: JSON.stringify({
      window: { updatedAtMin, updatedAtMax },
      results,
      fx: fxResult,
    }),
  };
};