/**
 * Verify BigQuery warehouse contents against Shopify directly.
 *
 * Three modes (CLI arg):
 *   counts     Fast: per-region per-month order/refund counts. Uses
 *              Shopify's /orders/count.json endpoint so this is cheap
 *              even over years of history.
 *   revenue    Medium: paginates orders for a date window, sums native
 *              monetary totals (subtotal/discount/tax/shipping/total)
 *              by region, compares to orders_master.
 *   spotcheck  Slow but rigorous: picks N random order_ids from BQ per
 *              region, fetches each from Shopify by ID, deep-compares
 *              every mapped field including line items, refunds, and
 *              fulfillments.
 *   all        Runs counts → revenue → spotcheck.
 *
 * Usage:
 *   node scripts/verify_data.js counts                  # full history
 *   node scripts/verify_data.js counts 2025-01 2025-12  # bounded
 *   node scripts/verify_data.js revenue 2026-04         # one month
 *   node scripts/verify_data.js spotcheck 25            # 25 orders/region
 *   node scripts/verify_data.js all
 *
 * Requires the same env as the backfill script: SHOPIFY_TOKEN_<REGION>
 * for AU/US/UK/CA/EU. Reads BigQuery via the local `bq` CLI authenticated
 * against the project that owns the dataset.
 */

require("dotenv").config();
const { execFileSync } = require("child_process");
const {
  getNextUrl,
  fetchWithRetry,
  mapOrdersPage,
} = require("../src/shared/utils");

const API_VERSION = "2026-01";
const DATASET = "peppermayo";

const STORES = {
  AU: { domain: "pmayo.myshopify.com", token: process.env.SHOPIFY_TOKEN_AU },
  US: { domain: "pmayo-us.myshopify.com", token: process.env.SHOPIFY_TOKEN_US },
  UK: { domain: "pmayo-uk.myshopify.com", token: process.env.SHOPIFY_TOKEN_UK },
  CA: { domain: "pmayo-ca.myshopify.com", token: process.env.SHOPIFY_TOKEN_CA },
  EU: { domain: "pmayo-eu.myshopify.com", token: process.env.SHOPIFY_TOKEN_EU },
};

const REGIONS = Object.keys(STORES);

// ---------------------------------------------------------------------------
// Tally / formatting helpers
// ---------------------------------------------------------------------------

const RESET = "\x1b[0m";
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const DIM = "\x1b[2m";

const summary = { ok: 0, warn: 0, fail: 0, fails: [] };

function pass(msg) {
  summary.ok++;
  console.log(`${GREEN}  ✓${RESET} ${msg}`);
}
function warn(msg) {
  summary.warn++;
  console.log(`${YELLOW}  ⚠${RESET} ${msg}`);
}
function fail(msg) {
  summary.fail++;
  summary.fails.push(msg);
  console.log(`${RED}  ✗ ${msg}${RESET}`);
}
function info(msg) {
  console.log(`${DIM}  · ${msg}${RESET}`);
}
function header(msg) {
  console.log(`\n${msg}`);
  console.log("─".repeat(msg.length));
}

// Money diff tolerance — Shopify and the warehouse both store strings
// at 2dp, but FX-of-one and rounding-of-zero edge cases can produce
// sub-cent drift after summation. 1 cent absolute or 0.001% relative.
function moneyMatches(a, b) {
  const da = Number(a) || 0;
  const db = Number(b) || 0;
  if (Math.abs(da - db) <= 0.01) return true;
  const denom = Math.max(Math.abs(da), Math.abs(db), 1);
  return Math.abs(da - db) / denom < 1e-5;
}

// ---------------------------------------------------------------------------
// BigQuery helpers
// ---------------------------------------------------------------------------

function bq(sql) {
  const out = execFileSync(
    "bq",
    [
      "query",
      "--use_legacy_sql=false",
      "--format=json",
      "--max_rows=1000000",
      "--quiet",
      sql,
    ],
    { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 },
  );
  return JSON.parse(out);
}

// ---------------------------------------------------------------------------
// Shopify helpers
// ---------------------------------------------------------------------------

async function shopifyCountOrders(region, params) {
  const { domain, token } = STORES[region];
  const qs = new URLSearchParams({ status: "any", ...params }).toString();
  const url = `https://${domain}/admin/api/${API_VERSION}/orders/count.json?${qs}`;
  const res = await fetchWithRetry(url, {
    "X-Shopify-Access-Token": token,
  });
  return res.data.count;
}

async function shopifyCountProducts(region) {
  const { domain, token } = STORES[region];
  const url = `https://${domain}/admin/api/${API_VERSION}/products/count.json`;
  const res = await fetchWithRetry(url, {
    "X-Shopify-Access-Token": token,
  });
  return res.data.count;
}

async function shopifyFetchOrder(region, orderId) {
  const { domain, token } = STORES[region];
  const url = `https://${domain}/admin/api/${API_VERSION}/orders/${orderId}.json`;
  const res = await fetchWithRetry(url, {
    "X-Shopify-Access-Token": token,
  });
  return res.data.order;
}

// Iterates every order in the date window for a region. Yields full
// raw Shopify order objects so the caller can sum whatever fields it
// likes. Honours Shopify's Link-header cursor pagination. Logs a
// running progress line per page so callers know the script is alive
// during long pulls.
async function* shopifyOrdersInWindow(region, createdAtMin, createdAtMax) {
  const { domain, token } = STORES[region];
  // Match BQ's half-open semantics: BQ uses `created_at < end`, but
  // Shopify treats created_at_max as inclusive. See toShopifyExclusiveMax.
  const exclusiveMax = toShopifyExclusiveMax(createdAtMax);
  let url =
    `https://${domain}/admin/api/${API_VERSION}/orders.json` +
    `?created_at_min=${createdAtMin}&created_at_max=${exclusiveMax}` +
    `&status=any&limit=250`;
  const headers = { "X-Shopify-Access-Token": token };
  let pageNum = 0;
  let totalSoFar = 0;
  const startedAt = Date.now();
  while (url) {
    const res = await fetchWithRetry(url, headers);
    pageNum += 1;
    const pageOrders = res.data.orders || [];
    totalSoFar += pageOrders.length;
    const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1);
    process.stdout.write(
      `    [${region}] page ${String(pageNum).padStart(3)} → ${String(pageOrders.length).padStart(3)} orders` +
      ` (running total: ${totalSoFar}, elapsed ${elapsed}s)\n`,
    );
    for (const o of pageOrders) yield o;
    url = getNextUrl(res.headers["link"]);
  }
}

// ---------------------------------------------------------------------------
// Date helpers
// ---------------------------------------------------------------------------

function monthRange(start, end) {
  // start, end are 'YYYY-MM' strings (inclusive). Returns array of months.
  const out = [];
  const [sy, sm] = start.split("-").map(Number);
  const [ey, em] = end.split("-").map(Number);
  let y = sy;
  let m = sm;
  while (y < ey || (y === ey && m <= em)) {
    out.push(`${y}-${String(m).padStart(2, "0")}`);
    m++;
    if (m > 12) {
      y++;
      m = 1;
    }
  }
  return out;
}

function monthBounds(yyyymm) {
  const [y, m] = yyyymm.split("-").map(Number);
  const start = new Date(Date.UTC(y, m - 1, 1)).toISOString();
  const end = new Date(Date.UTC(m === 12 ? y + 1 : y, m === 12 ? 0 : m, 1)).toISOString();
  return { start, end };
}

function defaultRange() {
  // Use orders_master min/max created_at if no range supplied. Shopify
  // counts respect created_at filters so we'll get apples-to-apples.
  const rows = bq(
    `SELECT FORMAT_DATE('%Y-%m', MIN(DATE(created_at))) AS first_month,
            FORMAT_DATE('%Y-%m', MAX(DATE(created_at))) AS last_month
     FROM \`${DATASET}.orders_master\``,
  );
  return [rows[0].first_month, rows[0].last_month];
}

// The pipeline has inherent T-1 latency: the daily Lambda runs at
// 15:00 UTC. Anything created or mutated after the most recent Lambda
// invocation is in Shopify but not yet in BQ — expected, not a bug.
// Comparisons that don't account for this surface false-positive deltas.
//
// `pipelineCutoff()` returns 14:55 UTC (Lambda start − 5 min) of the
// most recent run, which is the latest moment for which Shopify and BQ
// definitely agree on the set of orders that exist (membership, not
// status — see notes in modeCounts).
// `MERGE_CUTOFF` env var lets the operator pin it for deterministic CI.
function pipelineCutoff() {
  if (process.env.MERGE_CUTOFF) return new Date(process.env.MERGE_CUTOFF);
  const now = new Date();
  const cutoff = new Date(
    Date.UTC(
      now.getUTCFullYear(),
      now.getUTCMonth(),
      now.getUTCDate(),
      14,
      55,
      0,
    ),
  );
  if (cutoff > now) cutoff.setUTCDate(cutoff.getUTCDate() - 1);
  return cutoff;
}

function minIso(a, b) {
  return a < b ? a : b;
}

// Shopify's `created_at_max` is INCLUSIVE of the exact timestamp,
// while BQ comparisons use `created_at < end` (exclusive). For a
// window like 2025-01 with end=2025-02-01T00:00:00Z, an order created
// at exactly that boundary is counted by Shopify in January but lives
// in February in BQ — producing a phantom 1-order delta. Subtracting
// 1 millisecond lines the two semantics up. Shopify accepts ms
// precision in ISO timestamps.
function toShopifyExclusiveMax(iso) {
  return new Date(new Date(iso).getTime() - 1).toISOString();
}

// ---------------------------------------------------------------------------
// Mode: counts
// ---------------------------------------------------------------------------

async function modeCounts(args) {
  const [start, end] = args.length === 2 ? args : defaultRange();
  const cutoff = pipelineCutoff();
  const cutoffIso = cutoff.toISOString();

  header(`COUNTS: ${start} → ${end}`);
  info(`Pipeline cutoff: ${cutoffIso}`);
  info(
    `Filtering both sides to created_at <= cutoff so the comparison is`
    + ` apples-to-apples (BQ is a snapshot at last merge; Shopify is live).`,
  );

  const { start: rangeStartIso } = monthBounds(start);
  const { end: rangeEndIsoRaw } = monthBounds(end);
  const rangeEndIso = minIso(rangeEndIsoRaw, cutoffIso);
  const rangeEndDateClause = `LEAST(
      DATE_SUB(DATE_ADD(PARSE_DATE('%Y-%m', '${end}'), INTERVAL 1 MONTH), INTERVAL 1 DAY),
      DATE(TIMESTAMP('${cutoffIso}'))
    )`;

  if (rangeEndIsoRaw > cutoffIso) {
    warn(
      `Window end ${rangeEndIsoRaw} is past cutoff; capping at ${cutoffIso}.`
      + ` Orders created after the cutoff are excluded from both sides.`,
    );
  }

  // 1. Per-region order counts — full range, capped at cutoff
  info("\nPer-region order counts (range, status=any, capped at cutoff)…");
  const bqRegionCounts = bq(
    `SELECT store_region, COUNT(*) AS n
     FROM \`${DATASET}.orders_master\`
     WHERE DATE(created_at) BETWEEN
           PARSE_DATE('%Y-%m', '${start}') AND
           ${rangeEndDateClause}
       AND created_at <= TIMESTAMP('${cutoffIso}')
     GROUP BY store_region`,
  );
  const bqByRegion = Object.fromEntries(
    bqRegionCounts.map((r) => [String(r.store_region).toUpperCase(), Number(r.n)]),
  );

  for (const region of REGIONS) {
    const shopify = await shopifyCountOrders(region, {
      created_at_min: rangeStartIso,
      created_at_max: toShopifyExclusiveMax(rangeEndIso),
    });
    const bqN = bqByRegion[region] || 0;
    const msg = `${region}: BQ=${bqN} Shopify=${shopify}`;
    if (shopify === bqN) pass(msg);
    else fail(`${msg} (delta=${bqN - shopify})`);
  }

  // 2. Per-month per-region (catches missing months / fence-post bugs).
  //    The current month (or any month whose end > cutoff) gets capped
  //    at the cutoff on both sides so the comparison stays exact.
  info("\nPer-month per-region order counts (capped at cutoff)…");
  const months = monthRange(start, end);
  const bqMonth = bq(
    `SELECT store_region,
            FORMAT_DATE('%Y-%m', DATE(created_at)) AS ym,
            COUNT(*) AS n
     FROM \`${DATASET}.orders_master\`
     WHERE DATE(created_at) BETWEEN
           PARSE_DATE('%Y-%m', '${start}') AND
           ${rangeEndDateClause}
       AND created_at <= TIMESTAMP('${cutoffIso}')
     GROUP BY store_region, ym`,
  );
  const bqMonthMap = new Map(
    bqMonth.map((r) => [`${String(r.store_region).toUpperCase()}|${r.ym}`, Number(r.n)]),
  );

  for (const region of REGIONS) {
    let monthFails = 0;
    let monthsChecked = 0;
    for (const ym of months) {
      const { start: monthMinIso, end: monthMaxIsoRaw } = monthBounds(ym);
      if (monthMinIso > cutoffIso) continue; // month entirely in the future
      const monthMaxIso = minIso(monthMaxIsoRaw, cutoffIso);
      monthsChecked++;
      const shopify = await shopifyCountOrders(region, {
        created_at_min: monthMinIso,
        created_at_max: toShopifyExclusiveMax(monthMaxIso),
      });
      const bqN = bqMonthMap.get(`${region}|${ym}`) || 0;
      if (shopify !== bqN) {
        monthFails++;
        fail(`${region} ${ym}: BQ=${bqN} Shopify=${shopify} (delta=${bqN - shopify})`);
      }
    }
    if (monthFails === 0) pass(`${region}: all ${monthsChecked} months match`);
  }

  // 3. Financial-status check intentionally OMITTED.
  //
  // Status fields are mutable and Shopify's count.json filters on the
  // *current* updated_at, while BQ stores the snapshot updated_at at
  // last merge. Any order whose status changed after the cutoff:
  //   - BQ.updated_at = pre-mutation (<= cutoff)  → still counted in
  //     its old status
  //   - Shopify.updated_at = post-mutation (> cutoff) → excluded by
  //     updated_at_max=cutoff entirely
  // So `paid` will systematically over-count in BQ (and `refunded` /
  // `partially_refunded` will under-count) by exactly the size of
  // the in-flight mutation set. There is no count.json filter that
  // resolves this asymmetry; the only reliable status validation is
  // per-order, which `verify:spotcheck` does. Use that.
  info(
    "\nStatus correctness: skipped here — run `npm run verify:spotcheck`"
    + " for per-order status / refund / fulfilment validation.",
  );

  // 4. Product catalog counts
  info("\nProduct catalog counts…");
  const bqProducts = bq(
    `SELECT store_region, COUNT(*) AS n
     FROM \`${DATASET}.products_master\`
     GROUP BY store_region`,
  );
  const bqProdMap = Object.fromEntries(
    bqProducts.map((r) => [String(r.store_region).toUpperCase(), Number(r.n)]),
  );
  for (const region of REGIONS) {
    const shopify = await shopifyCountProducts(region);
    const bqN = bqProdMap[region] || 0;
    if (shopify === bqN) pass(`${region}: ${bqN} products`);
    else {
      const delta = Math.abs(bqN - shopify);
      // Products are weekly. Up to ~7 days of catalog drift is normal.
      const tolerable = delta <= Math.max(5, Math.ceil(shopify * 0.01));
      if (tolerable) {
        warn(`${region}: BQ=${bqN} Shopify=${shopify} (delta=${bqN - shopify}; weekly drift, OK)`);
      } else {
        fail(`${region}: BQ=${bqN} Shopify=${shopify} (delta=${bqN - shopify})`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Mode: revenue
// ---------------------------------------------------------------------------

async function modeRevenue(args) {
  const ym = args[0] || new Date().toISOString().slice(0, 7);
  const { start: monthStartIso, end: monthEndIsoRaw } = monthBounds(ym);
  const cutoff = pipelineCutoff();
  const cutoffIso = cutoff.toISOString();
  const monthEndIso = minIso(monthEndIsoRaw, cutoffIso);

  header(`REVENUE: ${ym} (${monthStartIso} → ${monthEndIso})`);
  info(`Pipeline cutoff: ${cutoffIso}`);
  if (monthEndIsoRaw > cutoffIso) {
    warn(`Window end ${monthEndIsoRaw} is past cutoff; capping at ${cutoffIso}.`);
  }

  // BQ aggregates in native currency, capped at cutoff to match what
  // Shopify will return when we filter by created_at_max=cutoff.
  const bqAgg = bq(
    `SELECT store_region,
            COUNT(*)                          AS orders,
            COALESCE(SUM(subtotal_price), 0)  AS subtotal_price,
            COALESCE(SUM(total_discounts), 0) AS total_discounts,
            COALESCE(SUM(total_tax), 0)       AS total_tax,
            COALESCE(SUM(total_shipping_price), 0) AS total_shipping_price,
            COALESCE(SUM(total_price), 0)     AS total_price,
            COALESCE(SUM(current_total_price), 0) AS current_total_price
     FROM \`${DATASET}.orders_master\`
     WHERE created_at >= TIMESTAMP('${monthStartIso}')
       AND created_at <  TIMESTAMP('${monthEndIso}')
     GROUP BY store_region`,
  );
  const bqByRegion = Object.fromEntries(
    bqAgg.map((r) => [String(r.store_region).toUpperCase(), r]),
  );

  for (const region of REGIONS) {
    info(`${region}: paginating Shopify…`);
    const totals = {
      orders: 0,
      subtotal_price: 0,
      total_discounts: 0,
      total_tax: 0,
      total_shipping_price: 0,
      total_price: 0,
      current_total_price: 0,
    };
    for await (const o of shopifyOrdersInWindow(region, monthStartIso, monthEndIso)) {
      totals.orders++;
      totals.subtotal_price += Number(o.subtotal_price) || 0;
      totals.total_discounts += Number(o.total_discounts) || 0;
      totals.total_tax += Number(o.total_tax) || 0;
      totals.total_shipping_price +=
        (o.total_shipping_price_set?.shop_money?.amount &&
          Number(o.total_shipping_price_set.shop_money.amount)) ||
        0;
      totals.total_price += Number(o.total_price) || 0;
      totals.current_total_price += Number(o.current_total_price) || 0;
    }

    const bqRow = bqByRegion[region] || {};
    const compare = (field) => {
      const b = Number(bqRow[field] || 0);
      const s = totals[field];
      if (field === "orders") {
        if (b === s) pass(`${region} ${field}: ${b}`);
        else fail(`${region} ${field}: BQ=${b} Shopify=${s} (delta=${b - s})`);
        return;
      }
      if (moneyMatches(b, s)) pass(`${region} ${field}: ${b.toFixed(2)}`);
      else fail(`${region} ${field}: BQ=${b.toFixed(2)} Shopify=${s.toFixed(2)} (delta=${(b - s).toFixed(2)})`);
    };

    [
      "orders",
      "subtotal_price",
      "total_discounts",
      "total_tax",
      "total_shipping_price",
      "total_price",
      "current_total_price",
    ].forEach(compare);
  }
}

// ---------------------------------------------------------------------------
// Mode: spotcheck
// ---------------------------------------------------------------------------

async function modeSpotcheck(args) {
  const n = Number(args[0]) || 20;
  header(`SPOTCHECK: ${n} random orders/region — deep field comparison`);

  for (const region of REGIONS) {
    info(`${region}: sampling ${n} order_ids…`);
    // The Lambda writes store_region in lowercase (matches the STORES
    // map keys in src/lambda/index.js + scripts/historical_sync.js).
    // mapOrdersPage echoes whatever region string we pass in, so feed
    // it the lowercase form for an apples-to-apples comparison.
    const regionLower = region.toLowerCase();
    const rows = bq(
      `SELECT order_id
       FROM \`${DATASET}.orders_master\`
       WHERE LOWER(store_region) = '${regionLower}'
       ORDER BY FARM_FINGERPRINT(CAST(order_id AS STRING))
       LIMIT ${n}`,
    );
    if (rows.length === 0) {
      warn(`${region}: no orders to sample`);
      continue;
    }

    let regionFails = 0;
    for (const { order_id } of rows) {
      try {
        const shopifyRaw = await shopifyFetchOrder(region, order_id);
        const mapped = mapOrdersPage([shopifyRaw], regionLower);
        const shopifyOrder = mapped.orderRows[0];
        const shopifyItems = mapped.itemRows;
        const shopifyRefunds = mapped.refundRows;
        const shopifyFulfillments = mapped.fulfillmentRows;

        // Pull the BQ side
        const [bqOrder] = bq(
          `SELECT * FROM \`${DATASET}.orders_master\` WHERE order_id = ${order_id}`,
        );
        const bqItems = bq(
          `SELECT * FROM \`${DATASET}.order_items_master\`
           WHERE order_id = ${order_id} ORDER BY line_item_id`,
        );
        const bqRefunds = bq(
          `SELECT * FROM \`${DATASET}.refunds_master\`
           WHERE order_id = ${order_id} ORDER BY refund_id`,
        );
        const bqFulfillments = bq(
          `SELECT * FROM \`${DATASET}.fulfillments_master\`
           WHERE order_id = ${order_id} ORDER BY fulfillment_id`,
        );

        const failsBefore = summary.fail;
        compareOrder(region, order_id, bqOrder, shopifyOrder);
        compareCollection(region, order_id, "items", bqItems, shopifyItems, "line_item_id", [
          "quantity",
          "price",
          "sku",
          "name",
          "size",
          "colour",
        ]);
        compareCollection(region, order_id, "refunds", bqRefunds, shopifyRefunds, "refund_id", [
          "refund_amount",
          "refund_subtotal",
          "refund_total_tax",
        ]);
        compareCollection(
          region,
          order_id,
          "fulfillments",
          bqFulfillments,
          shopifyFulfillments,
          "fulfillment_id",
          ["status", "shipment_status", "tracking_number"],
        );
        if (summary.fail > failsBefore) regionFails++;
      } catch (e) {
        const status = e.response?.status;
        if (status === 404) {
          fail(`${region} order ${order_id}: missing in Shopify (deleted?)`);
        } else {
          fail(`${region} order ${order_id}: ${e.message}`);
        }
        regionFails++;
      }
    }
    if (regionFails === 0) pass(`${region}: all ${rows.length} orders match`);
  }
}

// Compare scalar/key order fields
function compareOrder(region, orderId, bqOrder, shopifyOrder) {
  if (!bqOrder) {
    fail(`${region} order ${orderId}: missing in BQ`);
    return;
  }
  if (!shopifyOrder) {
    fail(`${region} order ${orderId}: mapping returned no order`);
    return;
  }

  const checks = [
    // Identity
    ["order_id", String(bqOrder.order_id), String(shopifyOrder.order_id)],
    ["store_region", bqOrder.store_region, shopifyOrder.store_region],
    ["currency", bqOrder.currency, shopifyOrder.currency],
    ["financial_status", bqOrder.financial_status, shopifyOrder.financial_status],
    ["fulfillment_status", bqOrder.fulfillment_status, shopifyOrder.fulfillment_status],
    [
      "customer_id",
      bqOrder.customer_id == null ? null : String(bqOrder.customer_id),
      shopifyOrder.customer_id == null ? null : String(shopifyOrder.customer_id),
    ],
  ];
  const moneyChecks = [
    ["subtotal_price", bqOrder.subtotal_price, shopifyOrder.subtotal_price],
    ["total_discounts", bqOrder.total_discounts, shopifyOrder.total_discounts],
    ["total_tax", bqOrder.total_tax, shopifyOrder.total_tax],
    ["total_price", bqOrder.total_price, shopifyOrder.total_price],
    ["current_total_price", bqOrder.current_total_price, shopifyOrder.current_total_price],
  ];

  for (const [field, b, s] of checks) {
    if (b !== s && !(b == null && s == null)) {
      fail(`${region} order ${orderId} ${field}: BQ='${b}' Shopify='${s}'`);
    }
  }
  for (const [field, b, s] of moneyChecks) {
    if (!moneyMatches(b, s)) {
      fail(`${region} order ${orderId} ${field}: BQ=${b} Shopify=${s}`);
    }
  }

  // Soft check — order_number is not always populated by Shopify's
  // /orders.json list endpoint (which the Lambda uses) but is always
  // populated by /orders/{id}.json (which spotcheck uses), so a NULL
  // in BQ vs a value from Shopify is a known list-endpoint quirk and
  // not a pipeline correctness issue. The canonical display number is
  // `order.name` (e.g. #PMAU500570450). Demoting to warn.
  const bN = bqOrder.order_number == null ? null : String(bqOrder.order_number);
  const sN = shopifyOrder.order_number == null ? null : String(shopifyOrder.order_number);
  if (bN !== sN && !(bN == null && sN == null)) {
    if (bN == null && sN != null) {
      warn(`${region} order ${orderId} order_number: BQ=NULL Shopify='${sN}' (list-endpoint quirk; use \`name\` for display)`);
    } else {
      fail(`${region} order ${orderId} order_number: BQ='${bN}' Shopify='${sN}'`);
    }
  }
}

// Carrier shipment_status progresses forward as tracking events come
// in (label_printed → confirmed → in_transit → out_for_delivery →
// delivered, with attempted_delivery / failure as side branches).
// Shopify mutates the fulfilment but does NOT always bump the parent
// order's updated_at, so the daily Lambda (which windows on
// orders.updated_at) can have a stale earlier stage. Forward drift is
// expected; backward movement is genuinely suspicious.
const SHIPMENT_STATUS_ORDER = [
  "",
  "label_printed",
  "label_purchased",
  "confirmed",
  "in_transit",
  "out_for_delivery",
  "attempted_delivery",
  "delivered",
];

function shipmentStatusForwardOnly(bqVal, shopifyVal) {
  const bi = SHIPMENT_STATUS_ORDER.indexOf(bqVal || "");
  const si = SHIPMENT_STATUS_ORDER.indexOf(shopifyVal || "");
  // Only treat as soft if both values are recognised stages and
  // Shopify is strictly later than BQ.
  return bi !== -1 && si !== -1 && si > bi;
}

// Compare two arrays of {keyField, ...fields} dicts. Asserts same set
// of keys and same values for the listed fields on each.
function compareCollection(region, orderId, label, bqRows, shopifyRows, keyField, fields) {
  const bqKeys = new Set(bqRows.map((r) => String(r[keyField])));
  const shopifyKeys = new Set(shopifyRows.map((r) => String(r[keyField])));

  for (const k of bqKeys) {
    if (!shopifyKeys.has(k)) fail(`${region} order ${orderId} ${label}: ${k} in BQ but not Shopify`);
  }
  for (const k of shopifyKeys) {
    if (!bqKeys.has(k)) fail(`${region} order ${orderId} ${label}: ${k} in Shopify but not BQ`);
  }

  const bqMap = new Map(bqRows.map((r) => [String(r[keyField]), r]));
  for (const sr of shopifyRows) {
    const k = String(sr[keyField]);
    const br = bqMap.get(k);
    if (!br) continue;
    for (const f of fields) {
      const bv = br[f];
      const sv = sr[f];
      // money-ish comparison if both look numeric
      const isMoney = !Number.isNaN(Number(bv)) && !Number.isNaN(Number(sv)) && bv != null && sv != null;
      if (isMoney) {
        if (!moneyMatches(bv, sv)) {
          fail(`${region} order ${orderId} ${label} ${k} ${f}: BQ=${bv} Shopify=${sv}`);
        }
      } else if ((bv ?? "") !== (sv ?? "")) {
        // Soft case — fulfilment shipment_status moving forward without
        // the parent order.updated_at bumping is a known Shopify quirk.
        if (label === "fulfillments" && f === "shipment_status" && shipmentStatusForwardOnly(bv, sv)) {
          warn(`${region} order ${orderId} ${label} ${k} ${f}: BQ='${bv}' Shopify='${sv}' (forward-only carrier drift, OK)`);
          continue;
        }
        fail(`${region} order ${orderId} ${label} ${k} ${f}: BQ='${bv}' Shopify='${sv}'`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Mode: diff
// ---------------------------------------------------------------------------
// Pinpoints the exact orders BQ is missing (or has extra) for one
// (region, month) pair. Usage:
//   node scripts/verify_data.js diff au 2025-01
// Prints up to 50 missing IDs (in Shopify, not in BQ) and 50 extras
// (in BQ, not in Shopify), capped at the pipeline cutoff so the
// comparison is apples-to-apples.
async function modeDiff(args) {
  const [regionArg, ym] = args;
  if (!regionArg || !ym) {
    console.error("Usage: verify_data.js diff <region> <YYYY-MM>");
    process.exit(2);
  }
  const region = regionArg.toUpperCase();
  if (!STORES[region]) throw new Error(`Unknown region: ${regionArg}`);
  const lc = region.toLowerCase();

  const cutoff = pipelineCutoff();
  const cutoffIso = cutoff.toISOString();
  const { start: monthStartIso, end: monthEndIsoRaw } = monthBounds(ym);
  const monthEndIso = minIso(monthEndIsoRaw, cutoffIso);

  header(`DIFF: ${region} ${ym}`);
  info(`Window ${monthStartIso} → ${monthEndIso} (cutoff ${cutoffIso})`);

  // Collect Shopify IDs in window.
  const shopifyIds = new Set();
  for await (const o of shopifyOrdersInWindow(region, monthStartIso, monthEndIso)) {
    shopifyIds.add(String(o.id));
  }
  info(`Shopify: ${shopifyIds.size} order IDs`);

  // Collect BQ IDs in same window.
  const bqRows = bq(
    `SELECT CAST(order_id AS STRING) AS order_id
     FROM \`${DATASET}.orders_master\`
     WHERE LOWER(store_region) = '${lc}'
       AND created_at >= TIMESTAMP('${monthStartIso}')
       AND created_at <  TIMESTAMP('${monthEndIso}')`,
  );
  const bqIds = new Set(bqRows.map((r) => String(r.order_id)));
  info(`BQ:      ${bqIds.size} order IDs`);

  const missing = [...shopifyIds].filter((id) => !bqIds.has(id));
  const extras = [...bqIds].filter((id) => !shopifyIds.has(id));

  if (!missing.length && !extras.length) {
    pass(`${region} ${ym}: order ID sets match exactly`);
    return;
  }

  if (missing.length) {
    fail(`${region} ${ym}: ${missing.length} order(s) in Shopify but missing from BQ`);
    const sample = missing.slice(0, 50);
    for (const id of sample) {
      const { domain, token } = STORES[region];
      try {
        const url = `https://${domain}/admin/api/${API_VERSION}/orders/${id}.json?fields=id,name,created_at,updated_at,financial_status,cancelled_at,test`;
        const res = await fetchWithRetry(url, { "X-Shopify-Access-Token": token });
        const o = res.data.order;
        console.log(
          `      missing ${id}  name=${o.name}  created=${o.created_at}` +
          `  updated=${o.updated_at}  fin=${o.financial_status}` +
          `  cancelled=${o.cancelled_at || "-"}  test=${o.test}`,
        );
      } catch (e) {
        console.log(`      missing ${id}  (lookup failed: ${e.message})`);
      }
    }
    if (missing.length > sample.length) {
      info(`…and ${missing.length - sample.length} more`);
    }
  }

  if (extras.length) {
    warn(`${region} ${ym}: ${extras.length} order(s) in BQ but not in Shopify (likely deleted upstream)`);
    for (const id of extras.slice(0, 50)) console.log(`      extra   ${id}`);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function assertTokens() {
  const missing = REGIONS.filter((r) => !STORES[r].token).map(
    (r) => `SHOPIFY_TOKEN_${r}`,
  );
  if (missing.length) {
    throw new Error(`Missing required env vars: ${missing.join(", ")}`);
  }
}

async function main() {
  assertTokens();
  const [mode, ...rest] = process.argv.slice(2);
  switch ((mode || "counts").toLowerCase()) {
    case "counts":
      await modeCounts(rest);
      break;
    case "revenue":
      await modeRevenue(rest);
      break;
    case "spotcheck":
      await modeSpotcheck(rest);
      break;
    case "diff":
      await modeDiff(rest);
      break;
    case "all":
      await modeCounts([]);
      await modeRevenue([new Date().toISOString().slice(0, 7)]);
      await modeSpotcheck([rest[0] || "20"]);
      break;
    default:
      console.error(`Unknown mode: ${mode}. Use counts | revenue | spotcheck | diff | all`);
      process.exit(2);
  }

  console.log("\n────────────────────────────────");
  console.log(
    `Result: ${GREEN}${summary.ok} ok${RESET}  ` +
      `${YELLOW}${summary.warn} warn${RESET}  ` +
      `${RED}${summary.fail} fail${RESET}`,
  );
  if (summary.fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
