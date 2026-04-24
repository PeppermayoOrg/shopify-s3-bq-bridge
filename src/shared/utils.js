const axios = require("axios");
const crypto = require("crypto");

const MAX_RETRIES = 5;
const RETRYABLE_CODES = new Set([429, 500, 502, 503, 504]);

// Currencies the warehouse tracks. AUD is the reporting base; the
// others cover every storefront and the USD secondary reporting column
// on v_orders / v_order_items. Keep in sync with the FX join in
// v_orders.sql if this list ever changes.
const FX_QUOTE_CURRENCIES = ["USD", "GBP", "CAD", "EUR"];
const FX_BASE_CURRENCY = "AUD";
const FX_API_BASE_URL = "https://api.frankfurter.dev/v1";
const FX_SOURCE = "frankfurter/ecb";

const ORDER_HEADER = [
  { id: "store_region", title: "store_region" },
  { id: "order_id", title: "order_id" },
  { id: "customer_id", title: "customer_id" },
  { id: "created_at", title: "created_at" },
  { id: "updated_at", title: "updated_at" },
  { id: "cancelled_at", title: "cancelled_at" },
  { id: "closed_at", title: "closed_at" },
  { id: "financial_status", title: "financial_status" },
  { id: "fulfillment_status", title: "fulfillment_status" },
  { id: "currency", title: "currency" },
  { id: "subtotal_price", title: "subtotal_price" },
  { id: "total_discounts", title: "total_discounts" },
  { id: "total_tax", title: "total_tax" },
  { id: "total_shipping_price", title: "total_shipping_price" },
  { id: "total_price", title: "total_price" },
  { id: "tags", title: "tags" },
  { id: "discount_codes", title: "discount_codes" },
  { id: "source_name", title: "source_name" },
  { id: "order_number", title: "order_number" },
  { id: "cancel_reason", title: "cancel_reason" },
  { id: "payment_gateway", title: "payment_gateway" },
  { id: "device_type", title: "device_type" },
  { id: "referring_site", title: "referring_site" },
  { id: "shipping_city", title: "shipping_city" },
  { id: "shipping_province", title: "shipping_province" },
  { id: "shipping_country_code", title: "shipping_country_code" },
  { id: "total_weight_grams", title: "total_weight_grams" },
  { id: "presentment_currency", title: "presentment_currency" },
  { id: "current_total_price", title: "current_total_price" },
  { id: "hashed_email", title: "hashed_email" },
];

const ITEM_HEADER = [
  { id: "line_item_id", title: "line_item_id" },
  { id: "order_id", title: "order_id" },
  { id: "store_region", title: "store_region" },
  { id: "created_at", title: "created_at" },
  { id: "product_id", title: "product_id" },
  { id: "variant_id", title: "variant_id" },
  { id: "sku", title: "sku" },
  { id: "name", title: "name" },
  { id: "quantity", title: "quantity" },
  { id: "price", title: "price" },
  { id: "size", title: "size" },
  { id: "colour", title: "colour" },
  { id: "vendor", title: "vendor" },
  { id: "total_discount", title: "total_discount" },
  { id: "compare_at_price", title: "compare_at_price" },
  { id: "gift_card", title: "gift_card" },
];

const FX_HEADER = [
  { id: "rate_date", title: "rate_date" },
  { id: "currency", title: "currency" },
  { id: "rate_to_aud", title: "rate_to_aud" },
  { id: "source", title: "source" },
];

const REFUND_HEADER = [
  { id: "refund_id", title: "refund_id" },
  { id: "order_id", title: "order_id" },
  { id: "store_region", title: "store_region" },
  { id: "order_created_at", title: "order_created_at" },
  { id: "created_at", title: "created_at" },
  { id: "processed_at", title: "processed_at" },
  { id: "currency", title: "currency" },
  { id: "refund_subtotal", title: "refund_subtotal" },
  { id: "refund_total_tax", title: "refund_total_tax" },
  { id: "refund_amount", title: "refund_amount" },
  { id: "note", title: "note" },
  { id: "user_id", title: "user_id" },
];

const REFUND_ITEM_HEADER = [
  { id: "refund_line_item_id", title: "refund_line_item_id" },
  { id: "refund_id", title: "refund_id" },
  { id: "order_id", title: "order_id" },
  { id: "line_item_id", title: "line_item_id" },
  { id: "store_region", title: "store_region" },
  { id: "order_created_at", title: "order_created_at" },
  { id: "refund_processed_at", title: "refund_processed_at" },
  { id: "quantity", title: "quantity" },
  { id: "subtotal", title: "subtotal" },
  { id: "total_tax", title: "total_tax" },
  { id: "restock_type", title: "restock_type" },
];

const FULFILLMENT_HEADER = [
  { id: "fulfillment_id", title: "fulfillment_id" },
  { id: "order_id", title: "order_id" },
  { id: "store_region", title: "store_region" },
  { id: "order_created_at", title: "order_created_at" },
  { id: "created_at", title: "created_at" },
  { id: "fulfilled_at", title: "fulfilled_at" },
  { id: "status", title: "status" },
  { id: "shipment_status", title: "shipment_status" },
  { id: "tracking_company", title: "tracking_company" },
  { id: "tracking_number", title: "tracking_number" },
  { id: "tracking_numbers", title: "tracking_numbers" },
  { id: "tracking_url", title: "tracking_url" },
  { id: "service", title: "service" },
  { id: "location_id", title: "location_id" },
  { id: "name", title: "name" },
];

const FULFILLMENT_ITEM_HEADER = [
  { id: "fulfillment_id", title: "fulfillment_id" },
  { id: "line_item_id", title: "line_item_id" },
  { id: "order_id", title: "order_id" },
  { id: "store_region", title: "store_region" },
  { id: "order_created_at", title: "order_created_at" },
  { id: "fulfilled_at", title: "fulfilled_at" },
  { id: "status", title: "status" },
  { id: "quantity", title: "quantity" },
];

const PRODUCT_HEADER = [
  { id: "product_id", title: "product_id" },
  { id: "store_region", title: "store_region" },
  { id: "title", title: "title" },
  { id: "handle", title: "handle" },
  { id: "product_type", title: "product_type" },
  { id: "vendor", title: "vendor" },
  { id: "status", title: "status" },
  { id: "tags", title: "tags" },
  { id: "created_at", title: "created_at" },
  { id: "updated_at", title: "updated_at" },
  { id: "published_at", title: "published_at" },
  { id: "template_suffix", title: "template_suffix" },
  { id: "image_count", title: "image_count" },
  { id: "variant_count", title: "variant_count" },
];

const PRODUCT_VARIANT_HEADER = [
  { id: "variant_id", title: "variant_id" },
  { id: "product_id", title: "product_id" },
  { id: "store_region", title: "store_region" },
  { id: "title", title: "title" },
  { id: "sku", title: "sku" },
  { id: "price", title: "price" },
  { id: "compare_at_price", title: "compare_at_price" },
  { id: "currency", title: "currency" },
  { id: "option1", title: "option1" },
  { id: "option2", title: "option2" },
  { id: "option3", title: "option3" },
  { id: "colour", title: "colour" },
  { id: "size", title: "size" },
  { id: "inventory_quantity", title: "inventory_quantity" },
  { id: "inventory_policy", title: "inventory_policy" },
  { id: "inventory_management", title: "inventory_management" },
  { id: "barcode", title: "barcode" },
  { id: "grams", title: "grams" },
  { id: "requires_shipping", title: "requires_shipping" },
  { id: "taxable", title: "taxable" },
  { id: "created_at", title: "created_at" },
  { id: "updated_at", title: "updated_at" },
];

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function getNextUrl(linkHeader) {
  if (!linkHeader) return null;
  const nextLink = linkHeader
    .split(",")
    .find((link) => link.includes('rel="next"'));
  if (!nextLink) return null;
  const match = nextLink.match(/<([^>]+)>/);
  return match ? match[1] : null;
}

async function fetchWithRetry(url, headers) {
  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    try {
      return await axios.get(url, { headers });
    } catch (error) {
      const status = error.response?.status;
      const isLastAttempt = attempt === MAX_RETRIES - 1;

      if (status && RETRYABLE_CODES.has(status) && !isLastAttempt) {
        const backoff =
          status === 429
            ? (parseFloat(error.response.headers["retry-after"]) || 2) * 1000
            : Math.min(1000 * 2 ** attempt, 30000);
        await delay(backoff);
        continue;
      }
      if (!error.response && !isLastAttempt) {
        await delay(Math.min(1000 * 2 ** attempt, 30000));
        continue;
      }
      throw error;
    }
  }
  throw new Error(`Failed after ${MAX_RETRIES} retries: ${url}`);
}

// Retry a promise-returning function with exponential backoff + jitter.
// Used for wrapping S3 uploads where the AWS SDK's built-in retries
// have already been exhausted (e.g. long-running historical backfills
// that run into transient network flakes).
async function retry(fn, { attempts = MAX_RETRIES, baseMs = 1000, maxMs = 30000 } = {}) {
  let lastErr;
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (attempt === attempts - 1) break;
      const backoff = Math.min(baseMs * 2 ** attempt, maxMs);
      const jitter = Math.floor(Math.random() * baseMs);
      await delay(backoff + jitter);
    }
  }
  throw lastErr;
}

// Fetch one day's FX rates from Frankfurter (ECB-backed) and return the
// rows that fx_rates_master expects. Always includes a self-row for the
// base currency with rate_to_aud = 1.0 so downstream joins work for
// AUD-native orders without special-casing.
//
// `targetDate` is a Date object (UTC). Frankfurter returns the most
// recent prior business day's rates when queried for a weekend/holiday,
// which we store under the queried date — the v_fx_rates_filled view
// forward-fills from there anyway, so the effect is identical.
async function fetchFxRates(targetDate) {
  const dateStr = targetDate.toISOString().split("T")[0];
  const symbols = FX_QUOTE_CURRENCIES.join(",");
  const url = `${FX_API_BASE_URL}/${dateStr}?base=${FX_BASE_CURRENCY}&symbols=${symbols}`;

  const response = await fetchWithRetry(url, {});
  const rates = response.data?.rates || {};

  const rows = [
    { rate_date: dateStr, currency: FX_BASE_CURRENCY, rate_to_aud: 1.0, source: FX_SOURCE },
  ];

  for (const currency of FX_QUOTE_CURRENCIES) {
    const baseToQuote = rates[currency];
    if (typeof baseToQuote !== "number" || baseToQuote <= 0) {
      throw new Error(`Frankfurter missing or invalid rate for ${currency} on ${dateStr}: ${baseToQuote}`);
    }
    // Frankfurter returns "1 AUD = baseToQuote QUOTE". To convert a
    // native QUOTE amount to AUD we multiply by 1 / baseToQuote.
    rows.push({
      rate_date: dateStr,
      currency,
      rate_to_aud: 1 / baseToQuote,
      source: FX_SOURCE,
    });
  }

  return rows;
}

// Fetch FX rates for every calendar day in [startDate, endDate] (inclusive).
// Used by the historical backfill. Frankfurter's /timeseries endpoint
// returns all dates in one call, which is much cheaper than looping.
async function fetchFxRatesRange(startDate, endDate) {
  const start = startDate.toISOString().split("T")[0];
  const end = endDate.toISOString().split("T")[0];
  const symbols = FX_QUOTE_CURRENCIES.join(",");
  const url = `${FX_API_BASE_URL}/${start}..${end}?base=${FX_BASE_CURRENCY}&symbols=${symbols}`;

  const response = await fetchWithRetry(url, {});
  const ratesByDate = response.data?.rates || {};

  const rows = [];
  for (const [dateStr, rates] of Object.entries(ratesByDate)) {
    rows.push({ rate_date: dateStr, currency: FX_BASE_CURRENCY, rate_to_aud: 1.0, source: FX_SOURCE });
    for (const currency of FX_QUOTE_CURRENCIES) {
      const baseToQuote = rates[currency];
      if (typeof baseToQuote !== "number" || baseToQuote <= 0) continue;
      rows.push({
        rate_date: dateStr,
        currency,
        rate_to_aud: 1 / baseToQuote,
        source: FX_SOURCE,
      });
    }
  }
  rows.sort((a, b) => (a.rate_date === b.rate_date ? a.currency.localeCompare(b.currency) : a.rate_date.localeCompare(b.rate_date)));
  return rows;
}

function parseDeviceType(userAgent) {
  if (!userAgent) return "";
  if (/iPad|Android(?!.*Mobile)|Tablet/i.test(userAgent)) return "tablet";
  if (/Mobile|iPhone|iPod|Android|BlackBerry|IEMobile|Opera Mini/i.test(userAgent)) return "mobile";
  return "desktop";
}

function parseVariantInfo(variantTitle) {
  // Handle missing titles or Shopify's default single-option variant
  if (!variantTitle || variantTitle === "Default Title") {
    return { colour: "", size: "" };
  }

  // Handle the strict "Colour / Size" format
  if (variantTitle.includes(" / ")) {
    const parts = variantTitle.split(" / ").map((p) => p.trim());
    return {
      colour: parts[0] || "",
      // If a title accidentally contains multiple slashes (e.g., "Red / White / Large"),
      // group the remainder into the size column rather than dropping data.
      size: parts.length > 1 ? parts.slice(1).join(" / ") : "",
    };
  }

  // Fallback for variants missing the delimiter (e.g., just "Large" or "Red").
  // Without the delimiter, it is impossible to programmatically guarantee if it is a size or a colour. We default to assigning it to colour so the raw
  // string is captured in the warehouse rather than returning undefined.
  return {
    colour: variantTitle.trim(),
    size: "",
  };
}

function mapOrdersPage(orders, region) {
  const orderRows = [];
  const itemRows = [];
  const refundRows = [];
  const refundItemRows = [];
  const fulfillmentRows = [];
  const fulfillmentItemRows = [];

  for (const order of orders) {
    orderRows.push({
      store_region: region,
      order_id: order.id,
      customer_id: order.customer?.id != null ? order.customer.id : "",
      created_at: order.created_at,
      updated_at: order.updated_at,
      cancelled_at: order.cancelled_at || "",
      closed_at: order.closed_at || "",
      financial_status: order.financial_status,
      fulfillment_status: order.fulfillment_status || "unfulfilled",
      currency: order.currency,
      subtotal_price: order.subtotal_price,
      total_discounts: order.total_discounts,
      total_tax: order.total_tax,
      total_shipping_price:
        order.total_shipping_price_set?.shop_money?.amount || "0.00",
      total_price: order.total_price,
      tags: order.tags || "",
      discount_codes: order.discount_codes?.map((d) => d.code).join(",") || "",
      source_name: order.source_name || "",
      order_number: order.order_number,
      cancel_reason: order.cancel_reason || "",
      payment_gateway: order.payment_gateway || "",
      device_type: parseDeviceType(order.client_details?.user_agent),
      referring_site: order.referring_site || "",
      shipping_city: order.shipping_address?.city || "",
      shipping_province: order.shipping_address?.province || "",
      shipping_country_code: order.shipping_address?.country_code || "",
      total_weight_grams: order.total_weight || 0,
      presentment_currency: order.presentment_currency || order.currency,
      current_total_price: order.current_total_price,
      hashed_email: order.email
        ? crypto.createHash("sha256").update(order.email.toLowerCase().trim()).digest("hex")
        : "",
    });

    for (const item of order.line_items || []) {
      const { size, colour } = parseVariantInfo(item.variant_title);
      itemRows.push({
        line_item_id: item.id,
        order_id: order.id,
        // Denormalised from the parent order so order_items_master can be
        // partitioned on created_at and filtered by region without a join.
        store_region: region,
        created_at: order.created_at,
        product_id: item.product_id,
        variant_id: item.variant_id,
        sku: item.sku || "",
        name: item.name,
        quantity: item.quantity,
        price: item.price,
        size,
        colour,
        vendor: item.vendor || "",
        total_discount: item.total_discount || 0,
        compare_at_price: item.compare_at_price != null ? item.compare_at_price : null,
        gift_card: item.gift_card || false,
      });
    }

    // Refunds — flattened to one row per refund event plus one row per
    // refunded line item. Refund amount is the sum of successful
    // `refund` transactions, which covers shipping/adjustment refunds
    // that don't map to any single line item.
    for (const refund of order.refunds || []) {
      const refundAmount = (refund.transactions || [])
        .filter((t) => t.kind === "refund" && t.status === "success")
        .reduce((sum, t) => sum + parseFloat(t.amount || 0), 0);

      const refundSubtotal = (refund.refund_line_items || [])
        .reduce((sum, rli) => sum + parseFloat(rli.subtotal || 0), 0);
      const refundTotalTax = (refund.refund_line_items || [])
        .reduce((sum, rli) => sum + parseFloat(rli.total_tax || 0), 0);

      refundRows.push({
        refund_id: refund.id,
        order_id: order.id,
        store_region: region,
        order_created_at: order.created_at,
        created_at: refund.created_at || "",
        processed_at: refund.processed_at || "",
        currency: order.currency,
        refund_subtotal: refundSubtotal,
        refund_total_tax: refundTotalTax,
        refund_amount: refundAmount,
        note: refund.note || "",
        user_id: refund.user_id != null ? refund.user_id : "",
      });

      for (const rli of refund.refund_line_items || []) {
        refundItemRows.push({
          refund_line_item_id: rli.id,
          refund_id: refund.id,
          order_id: order.id,
          line_item_id: rli.line_item_id,
          store_region: region,
          order_created_at: order.created_at,
          refund_processed_at: refund.processed_at || "",
          quantity: rli.quantity,
          subtotal: rli.subtotal != null ? rli.subtotal : 0,
          total_tax: rli.total_tax != null ? rli.total_tax : 0,
          restock_type: rli.restock_type || "",
        });
      }
    }

    // Fulfilments — flattened to one row per fulfilment plus one row
    // per fulfilled line item. `fulfilled_at` in our schema maps to
    // Shopify's `created_at` for successful fulfilments (that's when
    // the carrier accepted it); `updated_at` tracks shipment_status
    // transitions afterwards.
    for (const f of order.fulfillments || []) {
      const trackingNumbers = Array.isArray(f.tracking_numbers)
        ? f.tracking_numbers.filter(Boolean)
        : f.tracking_number
          ? [f.tracking_number]
          : [];

      fulfillmentRows.push({
        fulfillment_id: f.id,
        order_id: order.id,
        store_region: region,
        order_created_at: order.created_at,
        created_at: f.created_at || "",
        fulfilled_at: f.status === "success" ? f.created_at || "" : "",
        status: f.status || "",
        shipment_status: f.shipment_status || "",
        tracking_company: f.tracking_company || "",
        tracking_number: f.tracking_number || "",
        tracking_numbers: trackingNumbers.join(","),
        tracking_url: f.tracking_url || "",
        service: f.service || "",
        location_id: f.location_id != null ? f.location_id : "",
        name: f.name || "",
      });

      for (const fli of f.line_items || []) {
        fulfillmentItemRows.push({
          fulfillment_id: f.id,
          line_item_id: fli.id,
          order_id: order.id,
          store_region: region,
          order_created_at: order.created_at,
          fulfilled_at: f.status === "success" ? f.created_at || "" : "",
          status: f.status || "",
          quantity: fli.quantity,
        });
      }
    }
  }
  return {
    orderRows,
    itemRows,
    refundRows,
    refundItemRows,
    fulfillmentRows,
    fulfillmentItemRows,
  };
}

// Fetch all products (and their variants) for one store. Intended for
// the weekly product catalog refresh. Products API returns ~50k rows
// max per store for a typical Shopify Plus merchant; we stream pages
// and the caller writes them to disk.
async function fetchProducts(domain, token, region, apiVersion, onPage) {
  let url = `https://${domain}/admin/api/${apiVersion}/products.json?limit=250&status=active,archived,draft`;
  const headers = { "X-Shopify-Access-Token": token };
  let totalProducts = 0;
  let totalVariants = 0;

  while (url) {
    const response = await fetchWithRetry(url, headers);
    const page = response.data.products || [];

    if (page.length) {
      const { productRows, variantRows } = mapProductsPage(page, region);
      await onPage({ productRows, variantRows });
      totalProducts += productRows.length;
      totalVariants += variantRows.length;
    }

    const callLimit = response.headers["x-shopify-shop-api-call-limit"];
    if (callLimit) {
      const [current, max] = callLimit.split("/").map(Number);
      if (max - current < 5) await delay(2000);
    }

    url = getNextUrl(response.headers["link"]);
  }

  return { totalProducts, totalVariants };
}

function mapProductsPage(products, region) {
  const productRows = [];
  const variantRows = [];

  for (const product of products) {
    productRows.push({
      product_id: product.id,
      store_region: region,
      title: product.title || "",
      handle: product.handle || "",
      product_type: product.product_type || "",
      vendor: product.vendor || "",
      status: product.status || "",
      tags: product.tags || "",
      created_at: product.created_at || "",
      updated_at: product.updated_at || "",
      published_at: product.published_at || "",
      template_suffix: product.template_suffix || "",
      image_count: Array.isArray(product.images) ? product.images.length : 0,
      variant_count: Array.isArray(product.variants) ? product.variants.length : 0,
    });

    for (const variant of product.variants || []) {
      const { size, colour } = parseVariantInfo(variant.title);
      variantRows.push({
        variant_id: variant.id,
        product_id: product.id,
        store_region: region,
        title: variant.title || "",
        sku: variant.sku || "",
        price: variant.price != null ? variant.price : "",
        compare_at_price: variant.compare_at_price != null ? variant.compare_at_price : "",
        // Store-level currency; Shopify returns this on the shop, not
        // the variant. Callers pass it in via the region/store config
        // if they want it populated. For multi-currency display prices
        // use order-side FX; these variant prices are store-native.
        currency: "",
        option1: variant.option1 || "",
        option2: variant.option2 || "",
        option3: variant.option3 || "",
        colour,
        size,
        inventory_quantity: variant.inventory_quantity != null ? variant.inventory_quantity : "",
        inventory_policy: variant.inventory_policy || "",
        inventory_management: variant.inventory_management || "",
        barcode: variant.barcode || "",
        grams: variant.grams != null ? variant.grams : "",
        requires_shipping: variant.requires_shipping != null ? variant.requires_shipping : "",
        taxable: variant.taxable != null ? variant.taxable : "",
        created_at: variant.created_at || "",
        updated_at: variant.updated_at || "",
      });
    }
  }

  return { productRows, variantRows };
}

module.exports = {
  ORDER_HEADER,
  ITEM_HEADER,
  FX_HEADER,
  REFUND_HEADER,
  REFUND_ITEM_HEADER,
  FULFILLMENT_HEADER,
  FULFILLMENT_ITEM_HEADER,
  PRODUCT_HEADER,
  PRODUCT_VARIANT_HEADER,
  FX_QUOTE_CURRENCIES,
  FX_BASE_CURRENCY,
  delay,
  retry,
  getNextUrl,
  fetchWithRetry,
  mapOrdersPage,
  mapProductsPage,
  fetchProducts,
  fetchFxRates,
  fetchFxRatesRange,
};
