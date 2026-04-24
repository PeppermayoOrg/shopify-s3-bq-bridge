-- v_product_variants — variants joined to their parent product so
-- product_type / vendor / tags are available alongside SKU-level
-- facts.

CREATE OR REPLACE VIEW `peppermayo.v_product_variants`
(
  variant_id OPTIONS(description="Shopify variant ID, scoped per store_region."),
  product_id OPTIONS(description="Parent Shopify product ID."),
  store_region OPTIONS(description="Storefront region: AU, US, UK, CA, EU."),
  product_title OPTIONS(description="Parent product's title."),
  product_handle OPTIONS(description="Parent product's URL handle."),
  product_type OPTIONS(description="Parent product's product_type."),
  vendor OPTIONS(description="Parent product's vendor."),
  product_status OPTIONS(description="Parent product's status (active/draft/archived)."),
  product_tags_array OPTIONS(description="Parent product's tags as ARRAY<STRING>."),
  variant_title OPTIONS(description="Raw Shopify variant title (e.g. 'Blue / M')."),
  sku OPTIONS(description="Seller SKU. Best cross-store join key for 'same physical variant'."),
  colour OPTIONS(description="Parsed colour from 'Colour / Size' variant_title."),
  size OPTIONS(description="Parsed size from 'Colour / Size' variant_title."),
  option1 OPTIONS(description="Shopify raw option 1 value."),
  option2 OPTIONS(description="Shopify raw option 2 value."),
  option3 OPTIONS(description="Shopify raw option 3 value."),
  price OPTIONS(description="Variant unit price in NATIVE currency."),
  compare_at_price OPTIONS(description="RRP before markdown in NATIVE currency. NULL if not on sale."),
  currency OPTIONS(description="ISO-4217 native currency."),
  inventory_quantity OPTIONS(description="Current on-hand stock count as of last refresh."),
  is_out_of_stock OPTIONS(description="TRUE when inventory_quantity <= 0."),
  inventory_policy OPTIONS(description="Shopify inventory policy: deny / continue."),
  inventory_management OPTIONS(description="Inventory source: shopify / null / third-party."),
  barcode OPTIONS(description="Barcode / GTIN."),
  grams OPTIONS(description="Unit weight in grams."),
  requires_shipping OPTIONS(description="TRUE when the variant is a physical good."),
  taxable OPTIONS(description="TRUE when tax applies."),
  created_at OPTIONS(description="UTC timestamp of variant creation."),
  updated_at OPTIONS(description="UTC timestamp of last Shopify-side mutation."),
  refreshed_at OPTIONS(description="UTC timestamp this row was last refreshed (weekly).")
)
OPTIONS(description="Variant catalog view with parent-product context. Refreshed weekly. Inventory snapshot only — NOT a real-time stock feed.")
AS
SELECT
  v.variant_id,
  v.product_id,
  v.store_region,
  p.title AS product_title,
  p.handle AS product_handle,
  p.product_type,
  p.vendor,
  p.status AS product_status,
  p.tags_array AS product_tags_array,
  v.title AS variant_title,
  v.sku,
  v.colour,
  v.size,
  v.option1,
  v.option2,
  v.option3,
  v.price,
  v.compare_at_price,
  v.currency,
  v.inventory_quantity,
  v.inventory_quantity <= 0 AS is_out_of_stock,
  v.inventory_policy,
  v.inventory_management,
  v.barcode,
  v.grams,
  v.requires_shipping,
  v.taxable,
  v.created_at,
  v.updated_at,
  v.refreshed_at
FROM `peppermayo.product_variants_master` v
LEFT JOIN `peppermayo.products_master` p
  ON p.product_id   = v.product_id
  AND p.store_region = v.store_region;
