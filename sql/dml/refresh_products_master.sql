-- Refresh products_master + product_variants_master from staging.
--
-- Weekly full rebuild (CREATE OR REPLACE TABLE) — the product catalog
-- is small (low tens of thousands of rows across all regions) and
-- changes infrequently enough that incremental MERGE isn't worth the
-- complexity. Same pattern as refresh_customers_master.sql.
--
-- Each store's catalog is pulled independently so a product that's
-- listed in both AU and US appears as two rows (one per store_region).
-- Primary key therefore is (product_id, store_region), not product_id
-- alone — Shopify re-uses product IDs across stores only by accident,
-- but treating store_region as part of the key means we never silently
-- clobber one store's row with another's.

CREATE OR REPLACE TABLE `peppermayo.products_master` (
  product_id INT64 NOT NULL OPTIONS(description="Shopify product ID within the store. Part of primary key."),
  store_region STRING NOT NULL OPTIONS(description="Storefront region (AU/US/UK/CA/EU). Part of primary key."),
  title STRING OPTIONS(description="Product title as shown on the storefront."),
  handle STRING OPTIONS(description="URL slug (e.g. 'black-lace-mini-dress'). Stable; safe to join on."),
  product_type STRING OPTIONS(description="Shopify product_type (free-text taxonomy, e.g. 'Dress', 'Top')."),
  vendor STRING OPTIONS(description="Vendor / brand. For Peppermayo this is usually 'Peppermayo'; collabs carry the partner name."),
  status STRING OPTIONS(description="Shopify lifecycle status: 'active', 'archived', or 'draft'. Only 'active' is visible on the storefront."),
  tags STRING OPTIONS(description="Comma-separated tag string, Shopify's native format."),
  tags_array ARRAY<STRING> OPTIONS(description="tags split on ', ' for UNNEST filtering."),
  created_at TIMESTAMP OPTIONS(description="UTC timestamp the product was created in Shopify."),
  updated_at TIMESTAMP OPTIONS(description="UTC timestamp of the last Shopify-side mutation."),
  published_at TIMESTAMP OPTIONS(description="UTC timestamp the product first went live on the storefront, or NULL if unpublished."),
  image_count INT64 OPTIONS(description="Number of images attached to the product at sync time."),
  variant_count INT64 OPTIONS(description="Number of variants attached to the product at sync time."),
  refreshed_at TIMESTAMP NOT NULL OPTIONS(description="UTC timestamp this row was (re)computed.")
)
CLUSTER BY store_region, product_id
OPTIONS(description="Current product catalog per store. Rebuilt weekly from staging_products. Primary key: (product_id, store_region).")
AS
SELECT
  product_id,
  store_region,
  title,
  handle,
  product_type,
  vendor,
  status,
  tags,
  IF(tags IS NULL OR tags = '', [], SPLIT(tags, ', ')) AS tags_array,
  created_at,
  updated_at,
  published_at,
  image_count,
  variant_count,
  CURRENT_TIMESTAMP() AS refreshed_at
FROM `peppermayo.staging_products`
WHERE product_id IS NOT NULL;

CREATE OR REPLACE TABLE `peppermayo.product_variants_master` (
  variant_id INT64 NOT NULL OPTIONS(description="Shopify variant ID. Part of primary key."),
  product_id INT64 NOT NULL OPTIONS(description="Parent product. Join to products_master on (product_id, store_region)."),
  store_region STRING NOT NULL OPTIONS(description="Storefront region. Part of primary key."),
  title STRING OPTIONS(description="Variant title as Shopify stores it, typically 'Colour / Size'."),
  sku STRING OPTIONS(description="Merchant-supplied SKU. Join to order_items_master.sku for sell-through analysis."),
  price FLOAT64 OPTIONS(description="Current variant price in native currency."),
  compare_at_price FLOAT64 OPTIONS(description="Original / strike-through price in native currency, or NULL if not on sale."),
  currency STRING OPTIONS(description="Native currency of the storefront (AUD/USD/GBP/CAD/EUR)."),
  option1 STRING OPTIONS(description="Raw Shopify option1 value."),
  option2 STRING OPTIONS(description="Raw Shopify option2 value."),
  option3 STRING OPTIONS(description="Raw Shopify option3 value."),
  colour STRING OPTIONS(description="Parsed colour. Derived from 'Colour / Size' title the same way order_items.colour is."),
  size STRING OPTIONS(description="Parsed size. Derived from 'Colour / Size' title."),
  inventory_quantity INT64 OPTIONS(description="On-hand units at sync time. Snapshot; not updated between weekly refreshes."),
  inventory_policy STRING OPTIONS(description="'deny' (block overselling) or 'continue' (allow backorder)."),
  inventory_management STRING OPTIONS(description="Who tracks inventory: 'shopify', NULL (not tracked), or a fulfilment-service handle."),
  barcode STRING OPTIONS(description="Barcode/UPC if set."),
  grams INT64 OPTIONS(description="Variant weight in grams. Used for shipping calculations."),
  requires_shipping BOOL OPTIONS(description="FALSE for digital products / gift cards."),
  taxable BOOL OPTIONS(description="TRUE when the variant is subject to tax at checkout."),
  created_at TIMESTAMP OPTIONS(description="UTC timestamp the variant was created in Shopify."),
  updated_at TIMESTAMP OPTIONS(description="UTC timestamp of the last Shopify-side mutation."),
  refreshed_at TIMESTAMP NOT NULL OPTIONS(description="UTC timestamp this row was (re)computed.")
)
CLUSTER BY store_region, sku
OPTIONS(description="Current variant catalog per store. Rebuilt weekly from staging_product_variants. Primary key: (variant_id, store_region).")
AS
SELECT
  variant_id,
  product_id,
  store_region,
  title,
  sku,
  price,
  compare_at_price,
  currency,
  option1,
  option2,
  option3,
  colour,
  size,
  inventory_quantity,
  inventory_policy,
  inventory_management,
  barcode,
  grams,
  requires_shipping,
  taxable,
  created_at,
  updated_at,
  CURRENT_TIMESTAMP() AS refreshed_at
FROM `peppermayo.staging_product_variants`
WHERE variant_id IS NOT NULL;
