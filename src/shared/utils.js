const axios = require("axios");

const MAX_RETRIES = 5;
const RETRYABLE_CODES = new Set([429, 500, 502, 503, 504]);

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
];

const ITEM_HEADER = [
  { id: "line_item_id", title: "line_item_id" },
  { id: "order_id", title: "order_id" },
  { id: "product_id", title: "product_id" },
  { id: "variant_id", title: "variant_id" },
  { id: "sku", title: "sku" },
  { id: "name", title: "name" },
  { id: "quantity", title: "quantity" },
  { id: "price", title: "price" },
  { id: "size", title: "size" },
  { id: "colour", title: "colour" },
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

  for (const order of orders) {
    orderRows.push({
      store_region: region,
      order_id: order.id,
      customer_id: order.customer?.id || "",
      created_at: order.created_at,
      updated_at: order.updated_at,
      cancelled_at: order.cancelled_at || "",
      closed_at: order.closed_at || "",
      financial_status: order.financial_status,
      fulfillment_status: order.fulfillment_status || "",
      currency: order.currency,
      subtotal_price: order.subtotal_price,
      total_discounts: order.total_discounts,
      total_tax: order.total_tax,
      total_shipping_price:
        order.total_shipping_price_set?.shop_money?.amount || "0.00",
      total_price: order.total_price,
      tags: order.tags || "",
      discount_codes: order.discount_codes?.map((d) => d.code).join(",") || "",
    });

    for (const item of order.line_items || []) {
      const { size, colour } = parseVariantInfo(item.variant_title);
      itemRows.push({
        line_item_id: item.id,
        order_id: order.id,
        product_id: item.product_id,
        variant_id: item.variant_id,
        sku: item.sku || "",
        name: item.name,
        quantity: item.quantity,
        price: item.price,
        size,
        colour,
      });
    }
  }
  return { orderRows, itemRows };
}

module.exports = {
  ORDER_HEADER,
  ITEM_HEADER,
  delay,
  getNextUrl,
  fetchWithRetry,
  mapOrdersPage,
};
