-- Master tables for the Peppermayo Shopify warehouse.
--
-- These two tables are the source of truth for BI reporting and for
-- LLM-assisted querying via Claude Cowork. Every column carries a
-- description so downstream tooling (and LLMs reading
-- INFORMATION_SCHEMA.COLUMN_FIELD_PATHS) can reason about semantics
-- without having to guess.
--
-- Conventions:
--    All TIMESTAMPs are UTC. For Sydney-local date bucketing use
--     DATE(created_at, "Australia/Sydney") or the pre-computed
--     created_date_sydney column on the v_orders view (PR 2).
--    Monetary columns are in the order's NATIVE currency (see
--     `currency`). AUD/USD normalised columns live on the v_orders /
--     v_order_items views, not on these master tables.
--    PII is stripped at extraction. `hashed_email` is a SHA-256 of
--     the lowercased, trimmed email and is the only identifier that
--     can cross-reference an order to a person.

CREATE TABLE `peppermayo.orders_master` (
  store_region STRING NOT NULL OPTIONS(description="Storefront region this order belongs to. One of: AU, US, UK, CA, EU."),
  order_id INT64 NOT NULL OPTIONS(description="Shopify order ID. Globally unique across stores. Primary key."),
  customer_id STRING OPTIONS(description="Shopify customer ID. NULL for guest checkouts. Join key to customers_master."),
  created_at TIMESTAMP NOT NULL OPTIONS(description="UTC timestamp the order was placed. Partition key. Immutable."),
  updated_at TIMESTAMP NOT NULL OPTIONS(description="UTC timestamp of the most recent Shopify-side mutation. Drives the MERGE freshness guard."),
  cancelled_at TIMESTAMP OPTIONS(description="UTC timestamp the order was cancelled, or NULL if not cancelled."),
  closed_at TIMESTAMP OPTIONS(description="UTC timestamp the order was archived/closed in Shopify, or NULL if still open."),
  financial_status STRING OPTIONS(description="Payment state. Common values: pending, authorized, paid, partially_paid, refunded, partially_refunded, voided. Clustering key."),
  fulfillment_status STRING OPTIONS(description="Fulfilment state. One of: fulfilled, partial, unfulfilled, restocked. 'unfulfilled' is explicit (never NULL or empty string)."),
  currency STRING OPTIONS(description="ISO-4217 code of the order's native currency (e.g. AUD, USD, GBP, CAD, EUR). All *_price columns on this row are in this currency."),
  subtotal_price FLOAT64 OPTIONS(description="Sum of line-item prices after per-line discounts but BEFORE order-level discounts, tax, and shipping. Native currency."),
  total_discounts FLOAT64 OPTIONS(description="Total discount applied across the order. Native currency."),
  total_tax FLOAT64 OPTIONS(description="Total tax collected on the order. Native currency."),
  total_shipping_price FLOAT64 OPTIONS(description="Total shipping charged to the customer. Native currency."),
  total_price FLOAT64 OPTIONS(description="Grand total charged at checkout. Includes tax and shipping; is net of discounts. Native currency."),
  tags STRING OPTIONS(description="Comma-separated Shopify order tags (e.g. 'vip, pre-order'). Exposed as an ARRAY<STRING> on v_orders."),
  discount_codes STRING OPTIONS(description="Comma-separated discount codes applied to the order. Exposed as an ARRAY<STRING> on v_orders."),
  source_name STRING OPTIONS(description="Raw Shopify channel identifier (e.g. 'web', 'pos', 'shopify_draft_order', or a numeric app ID). v_orders exposes a friendly mapping."),
  order_number INT64 OPTIONS(description="Customer-visible order number (e.g. 1234). Not globally unique; scope by store_region."),
  cancel_reason STRING OPTIONS(description="Reason code if cancelled: customer, fraud, inventory, declined, other. NULL if not cancelled."),
  payment_gateway STRING OPTIONS(description="Gateway that processed payment (e.g. 'shopify_payments', 'paypal', 'afterpay')."),
  device_type STRING OPTIONS(description="Device class inferred from the user agent at checkout: desktop, mobile, tablet, or empty."),
  referring_site STRING OPTIONS(description="Referrer URL at checkout (HTTP referer). Free text; empty if direct."),
  shipping_city STRING OPTIONS(description="Shipping address city."),
  shipping_province STRING OPTIONS(description="Shipping address state / province name."),
  shipping_country_code STRING OPTIONS(description="ISO 3166-1 alpha-2 country code of the shipping address (e.g. 'US', 'AU'). Renamed from shipping_country in PR 1."),
  total_weight_grams INT64 OPTIONS(description="Total parcel weight in grams as reported by Shopify."),
  presentment_currency STRING OPTIONS(description="Currency the customer saw at checkout. For Peppermayo's single-currency storefronts this equals `currency`."),
  current_total_price FLOAT64 OPTIONS(description="Grand total after any post-order refunds. For refund-sensitive revenue use this; for gross revenue use total_price. Native currency."),
  hashed_email STRING OPTIONS(description="SHA-256 of lower-cased, trimmed customer email. The only way to group orders by person without storing PII.")
)
PARTITION BY DATE(created_at)
CLUSTER BY store_region, financial_status
OPTIONS(
  description="One row per Shopify order across all five Peppermayo storefronts. Keyed on order_id (globally unique). Partitioned by UTC DATE(created_at). Prefer v_orders for AUD/USD-normalised metrics, tag/discount arrays, and friendly source_name."
);

CREATE TABLE `peppermayo.order_items_master` (
  line_item_id INT64 NOT NULL OPTIONS(description="Shopify line-item ID. Globally unique across stores. Primary key."),
  order_id INT64 NOT NULL OPTIONS(description="Parent order ID. Join key to orders_master."),
  store_region STRING NOT NULL OPTIONS(description="Storefront region, denormalised from the parent order for cheap filtering without a join. One of: AU, US, UK, CA, EU. Clustering key."),
  created_at TIMESTAMP NOT NULL OPTIONS(description="Parent order's created_at (UTC), denormalised so this table can be partitioned. Matches orders_master.created_at exactly."),
  product_id INT64 OPTIONS(description="Shopify product ID. Scoped per-store: the same physical product has different IDs in AU vs US. Join to products_master (PR 3) on (product_id, store_region)."),
  variant_id INT64 OPTIONS(description="Shopify variant ID. Per-store scope, same as product_id."),
  sku STRING OPTIONS(description="Seller SKU. The most reliable cross-store join key for 'same physical product' questions. Clustering key."),
  name STRING OPTIONS(description="Human-readable product + variant name as shown on the order."),
  quantity INT64 OPTIONS(description="Quantity ordered at time of purchase. NOT net of refunds. For refund-adjusted units join refunds_master (PR 3) or use v_order_items.quantity_net."),
  price FLOAT64 OPTIONS(description="Unit price in the parent order's native currency (see orders_master.currency)."),
  size STRING OPTIONS(description="Size parsed from Shopify's 'Colour / Size' variant_title. Empty when the variant has no size dimension."),
  colour STRING OPTIONS(description="Colour parsed from Shopify's 'Colour / Size' variant_title. Falls back to the whole variant_title when the delimiter is missing."),
  vendor STRING OPTIONS(description="Brand / vendor as set on the Shopify product."),
  total_discount FLOAT64 OPTIONS(description="Total discount applied to this line. Native currency."),
  compare_at_price FLOAT64 OPTIONS(description="Original 'compare at' price (RRP) before markdown. NULL if the product isn't on sale. Native currency."),
  gift_card BOOL OPTIONS(description="TRUE if the line item is a gift-card product. Typically excluded from revenue metrics.")
)
PARTITION BY DATE(created_at)
CLUSTER BY store_region, order_id, sku
OPTIONS(
  description="One row per Shopify line item. Partitioned by DATE(created_at) (denormalised from the parent order) to keep time-bound queries cheap. Prefer v_order_items for AUD/USD-normalised and refund-adjusted metrics."
);