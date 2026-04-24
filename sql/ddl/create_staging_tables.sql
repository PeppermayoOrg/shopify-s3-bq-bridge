-- Staging tables.
--
-- These mirror the master tables' column names and types but:
--    Every column is nullable (no NOT NULL). Staging holds raw CSV
--     payloads and must not fail a load on a stray empty field.
--    No partitioning or clustering. Each run WRITE_TRUNCATEs staging
--     and the tables only ever hold the last ~26 hours of deltas, so
--     there's nothing to prune.
--    No column descriptions. Staging is internal; consumers should
--     always query the master tables (or the v_* views) instead.

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