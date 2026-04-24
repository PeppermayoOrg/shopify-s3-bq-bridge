-- Staging tables for the weekly product catalog pull.
-- These are the only product tables that ever receive raw DTS loads —
-- refresh_products_master.sql rebuilds products_master /
-- product_variants_master weekly from these staging tables.
--
-- All columns nullable so DTS loads don't fail on sparse data.

CREATE TABLE IF NOT EXISTS `peppermayo.staging_products` (
  product_id INT64,
  store_region STRING,
  title STRING,
  handle STRING,
  product_type STRING,
  vendor STRING,
  status STRING,
  tags STRING,
  created_at TIMESTAMP,
  updated_at TIMESTAMP,
  published_at TIMESTAMP,
  template_suffix STRING,
  image_count INT64,
  variant_count INT64
)
OPTIONS(description="DTS load target for weekly/products/*.csv. Truncated and rewritten weekly.");

CREATE TABLE IF NOT EXISTS `peppermayo.staging_product_variants` (
  variant_id INT64,
  product_id INT64,
  store_region STRING,
  title STRING,
  sku STRING,
  price FLOAT64,
  compare_at_price FLOAT64,
  currency STRING,
  option1 STRING,
  option2 STRING,
  option3 STRING,
  colour STRING,
  size STRING,
  inventory_quantity INT64,
  inventory_policy STRING,
  inventory_management STRING,
  barcode STRING,
  grams INT64,
  requires_shipping BOOL,
  taxable BOOL,
  created_at TIMESTAMP,
  updated_at TIMESTAMP
)
OPTIONS(description="DTS load target for weekly/product_variants/*.csv. Truncated and rewritten weekly.");
