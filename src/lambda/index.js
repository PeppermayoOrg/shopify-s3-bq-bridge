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
const { ORDER_HEADER, ITEM_HEADER, delay, getNextUrl, fetchWithRetry, mapOrdersPage } = require("../shared/utils");

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
const s3 = new S3Client();

// Streams each paginated response straight to disk so we never hold more
// than one page (~250 orders) of raw data in memory at once.
async function fetchAndStream(domain, token, updatedAtMin, updatedAtMax, region, ordersFile, itemsFile) {
  let url = `https://${domain}/admin/api/${API_VERSION}/orders.json?updated_at_min=${updatedAtMin}&updated_at_max=${updatedAtMax}&status=any&limit=250`;
  const headers = { "X-Shopify-Access-Token": token };

  let ordersInitialised = false;
  let itemsInitialised = false;
  let totalOrders = 0;
  let totalItems = 0;

  while (url) {
    const response = await fetchWithRetry(url, headers);
    const page = response.data.orders || [];

    if (page.length) {
      const { orderRows, itemRows } = mapOrdersPage(page, region);

      if (orderRows.length) {
        const writer = createObjectCsvWriter({
          path: ordersFile,
          header: ORDER_HEADER,
          append: ordersInitialised,
        });
        await writer.writeRecords(orderRows);
        ordersInitialised = true;
        totalOrders += orderRows.length;
      }

      if (itemRows.length) {
        const writer = createObjectCsvWriter({
          path: itemsFile,
          header: ITEM_HEADER,
          append: itemsInitialised,
        });
        await writer.writeRecords(itemRows);
        itemsInitialised = true;
        totalItems += itemRows.length;
      }
    }

    const callLimit = response.headers["x-shopify-shop-api-call-limit"];
    if (callLimit) {
      const [current, max] = callLimit.split("/").map(Number);
      if (max - current < 5) await delay(2000);
    }

    url = getNextUrl(response.headers["link"]);
  }

  return { totalOrders, totalItems };
}

async function uploadAndCleanup(filePath, key) {
  if (!fs.existsSync(filePath)) return;
  try {
    await s3.send(
      new PutObjectCommand({
        Bucket: S3_BUCKET,
        Key: key,
        Body: fs.createReadStream(filePath),
      }),
    );
  } finally {
    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
    }
  }
}

async function syncRegion(region, config, updatedAtMin, updatedAtMax, dateStr) {
  console.log(`[${region}] fetching orders updated ${updatedAtMin} -> ${updatedAtMax}`);

  const { Parameter } = await ssm.send(
    new GetParameterCommand({ Name: config.ssmKey, WithDecryption: true }),
  );

  const ordersFile = path.join("/tmp", `${region}_orders_${dateStr}.csv`);
  const itemsFile = path.join("/tmp", `${region}_items_${dateStr}.csv`);

  const { totalOrders, totalItems } = await fetchAndStream(
    config.domain,
    Parameter.Value,
    updatedAtMin,
    updatedAtMax,
    region,
    ordersFile,
    itemsFile
  );
  console.log(`[${region}] ${totalOrders} orders / ${totalItems} line items`);

  if (totalOrders === 0) return { region, orders: 0 };

  await uploadAndCleanup(ordersFile, `daily/orders/${region}_orders_${dateStr}.csv`);
  await uploadAndCleanup(itemsFile, `daily/items/${region}_items_${dateStr}.csv`);

  return { region, orders: totalOrders };
}

exports.handler = async () => {
  const now = new Date();
  const startTime = new Date(now.getTime() - ROLLING_WINDOW_HOURS * 60 * 60 * 1000);

  const updatedAtMin = startTime.toISOString();
  const updatedAtMax = now.toISOString();
  const dateStr = now.toISOString().split("T")[0];

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

  if (failures.length > 0) {
    const summary = { window: { updatedAtMin, updatedAtMax }, results, failures };
    throw new Error(
      `Daily sync completed with ${failures.length} failure(s): ${JSON.stringify(summary)}`,
    );
  }

  return {
    statusCode: 200,
    body: JSON.stringify({
      window: { updatedAtMin, updatedAtMax },
      results,
    }),
  };
};