require("dotenv").config();
const fs = require("fs");
const { createObjectCsvWriter } = require("csv-writer");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const { ORDER_HEADER, ITEM_HEADER, delay, getNextUrl, fetchWithRetry, mapOrdersPage } = require("../src/shared/utils");

// Configure AWS S3 Client
const s3Client = new S3Client({ region: "ap-southeast-2" });
const S3_BUCKET = process.env.S3_BUCKET || "peppermayo-shopify-orders";
const API_VERSION = "2026-01";

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

const missingTokens = Object.entries(STORES)
  .filter(([, c]) => !c.token)
  .map(([r]) => `SHOPIFY_TOKEN_${r.toUpperCase()}`);
if (missingTokens.length) {
  throw new Error(`Missing required env vars: ${missingTokens.join(", ")}`);
}

async function fetchAndStream(domain, token, createdAtMin, createdAtMax, region, ordersFile, itemsFile) {
  let url = `https://${domain}/admin/api/${API_VERSION}/orders.json?created_at_min=${createdAtMin}&created_at_max=${createdAtMax}&status=any&limit=250`;
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

async function runBackfill(storeStartDates) {
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
      let currentEnd = new Date(currentStart);
      currentEnd.setMonth(currentEnd.getMonth() + 1);

      const createdAtMin = currentStart.toISOString();
      const createdAtMax = currentEnd.toISOString();
      const fileMonth = currentStart.toISOString().slice(0, 7);

      const ordersFileName = `${region}_orders_historical_${fileMonth}.csv`;
      const itemsFileName = `${region}_items_historical_${fileMonth}.csv`;

      console.log(`Fetching ${region}: ${fileMonth}...`);
      const { totalOrders, totalItems } = await fetchAndStream(
        config.domain,
        config.token,
        createdAtMin,
        createdAtMax,
        region,
        ordersFileName,
        itemsFileName
      );

      if (totalOrders > 0) {
        if (fs.existsSync(ordersFileName)) {
          await s3Client.send(
            new PutObjectCommand({
              Bucket: S3_BUCKET,
              Key: `historical/orders/${ordersFileName}`,
              Body: fs.createReadStream(ordersFileName),
            }),
          );
          fs.unlinkSync(ordersFileName);
        }

        if (fs.existsSync(itemsFileName)) {
          await s3Client.send(
            new PutObjectCommand({
              Bucket: S3_BUCKET,
              Key: `historical/items/${itemsFileName}`,
              Body: fs.createReadStream(itemsFileName),
            }),
          );
          fs.unlinkSync(itemsFileName);
        }
        console.log(`Uploaded ${fileMonth} to S3 (${totalOrders} orders / ${totalItems} line items).`);
      } else {
        console.log(`No orders found for ${fileMonth}.`);
      }
      currentStart = currentEnd;
    }
  }
}

// You can easily choose what stores and what date to start from by modifying this object.
// Use the "YYYY-MM-DD" format.
// To skip a store completely, comment it out or remove it from the object.

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
  us: "2020-01-01",
  uk: "2020-01-01",
  ca: "2020-01-01",
  eu: "2020-01-01",
};

runBackfill(START_DATES);
