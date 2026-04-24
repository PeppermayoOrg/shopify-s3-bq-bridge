-- Migration: realign orders + order_items staging / master tables with
-- the repo DDL. Covers both the `source_name` drift (caught by the
-- 2026-04-23 DTS failure) and the `store_region` / `created_at`
-- drift on the items tables (caught by `npm run verify:schema:live`).
--
-- Context
-- -------
-- The extractor started emitting `source_name` at column index 17 of
-- the orders CSV (between `discount_codes` and `order_number`). The
-- DDL in sql/ddl/create_staging_tables.sql and
-- sql/ddl/create_master_tables.sql was updated to match, but the live
-- BigQuery tables were created from an older schema and had columns
-- appended via `ALTER TABLE ADD COLUMN` instead of rebuilt. The
-- BQ Data Transfer daily load on 2026-04-23 failed with:
--
--   Unable to parse; column_index: 17 column_name: "order_number"
--   column_type: INT64 value: "web"
--
-- BigQuery CSV loads bind columns by ORDINAL POSITION (the header row is
-- only consumed via `skip_leading_rows`). So we cannot fix this with a
-- plain `ALTER TABLE ADD COLUMN source_name STRING` -- that appends at
-- the end and the CSV columns would still be off-by-one.
--
-- Fix: rebuild each table with columns in the correct position.
--
-- Drift summary (as of 2026-04-24, from `npm run verify:schema:live`):
--
--   staging_orders         : missing `source_name` entirely (29 cols vs 30)
--   orders_master          : has `source_name` appended at idx 29 (should be 17)
--   staging_order_items    : missing `store_region` + `created_at` entirely (14 cols vs 16)
--   order_items_master     : has `store_region` + `created_at` appended at 14,15 (should be 2,3)
--
-- Run order: staging tables first (safe / truncated each run), then
-- master tables (preserves history via CTAS). Afterwards, re-trigger the
-- failed daily transfer runs in the BigQuery Data Transfer UI.
--
-- Idempotency: every statement is safe to re-run. Staging tables are
-- always re-truncated by the next transfer run anyway; master tables
-- use CREATE OR REPLACE ... AS SELECT so re-running just rebuilds from
-- current contents.

-- 1) staging_orders -- drop and recreate (no data to preserve).
DROP TABLE IF EXISTS `peppermayo.staging_orders`;

CREATE TABLE `peppermayo.staging_orders` (
  store_region STRING,
  order_id INT64,
  customer_id STRING,
  created_at TIMESTAMP,
  updated_at TIMESTAMP,
  cancelled_at TIMESTAMP,
  closed_at TIMESTAMP,
  financial_status STRING,
  fulfillment_status STRING,
  currency STRING,
  subtotal_price FLOAT64,
  total_discounts FLOAT64,
  total_tax FLOAT64,
  total_shipping_price FLOAT64,
  total_price FLOAT64,
  tags STRING,
  discount_codes STRING,
  source_name STRING,
  order_number INT64,
  cancel_reason STRING,
  payment_gateway STRING,
  device_type STRING,
  referring_site STRING,
  shipping_city STRING,
  shipping_province STRING,
  shipping_country_code STRING,
  total_weight_grams INT64,
  presentment_currency STRING,
  current_total_price FLOAT64,
  hashed_email STRING
);

-- 2) orders_master -- rebuild with source_name in correct position,
-- preserving all existing rows AND any source_name data already present.
--
-- The live orders_master already has a `source_name` column -- it was
-- added via `ALTER TABLE ADD COLUMN` at some point, which appended it
-- at the end (idx 29) instead of idx 17. Some rows may have been
-- populated by the MERGE over the last few days of daily runs, so we
-- preserve the existing values rather than nulling them out. The
-- CREATE OR REPLACE ... AS SELECT just reorders the columns.
CREATE OR REPLACE TABLE `peppermayo.orders_master` (
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
)
AS
SELECT
  store_region,
  order_id,
  customer_id,
  created_at,
  updated_at,
  cancelled_at,
  closed_at,
  financial_status,
  fulfillment_status,
  currency,
  subtotal_price,
  total_discounts,
  total_tax,
  total_shipping_price,
  total_price,
  tags,
  discount_codes,
  source_name,
  order_number,
  cancel_reason,
  payment_gateway,
  device_type,
  referring_site,
  shipping_city,
  shipping_province,
  shipping_country_code,
  total_weight_grams,
  presentment_currency,
  current_total_price,
  hashed_email
FROM `peppermayo.orders_master`;

-- 3) staging_order_items -- drop and recreate (no data to preserve).
--
-- Live table is missing `store_region` (idx 2) and `created_at` (idx 3)
-- entirely. DTS has never been able to load today's CSV shape into it
-- because `store_region = 'au'` would try to cast into `product_id INT64`.
DROP TABLE IF EXISTS `peppermayo.staging_order_items`;

CREATE TABLE `peppermayo.staging_order_items` (
  line_item_id INT64,
  order_id INT64,
  store_region STRING,
  created_at TIMESTAMP,
  product_id INT64,
  variant_id INT64,
  sku STRING,
  name STRING,
  quantity INT64,
  price FLOAT64,
  size STRING,
  colour STRING,
  vendor STRING,
  total_discount FLOAT64,
  compare_at_price FLOAT64,
  gift_card BOOL
);

-- 4) order_items_master -- DROP + CREATE (not OR REPLACE).
--
-- The live master is currently unpartitioned with clustering
-- (order_id, sku). The repo DDL adds PARTITION BY DATE(created_at) and
-- extends clustering to (store_region, order_id, sku). BigQuery
-- rejects `CREATE OR REPLACE` when partitioning changes -- it returns
-- "Cannot replace a table with a different partitioning spec. Instead,
-- DROP the table, and then recreate it." The table is empty today
-- (verified: 0 rows), so DROP is safe and no CTAS is needed.
DROP TABLE IF EXISTS `peppermayo.order_items_master`;

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
