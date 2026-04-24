-- v_products — thin passthrough of products_master with the variant
-- roll-up aggregated at query time. Separate from v_product_variants
-- because downstream questions split cleanly into "about a product"
-- and "about a variant".

CREATE OR REPLACE VIEW `peppermayo.v_products`
(
  product_id OPTIONS(description="Shopify product ID, scoped per store_region. Join items on (product_id, store_region)."),
  store_region OPTIONS(description="Storefront region: AU, US, UK, CA, EU."),
  title OPTIONS(description="Product display name."),
  handle OPTIONS(description="URL handle / slug."),
  product_type OPTIONS(description="Shopify product_type taxonomy."),
  vendor OPTIONS(description="Brand / vendor."),
  status OPTIONS(description="Shopify status: active / draft / archived."),
  tags OPTIONS(description="Raw comma-separated tags."),
  tags_array OPTIONS(description="ARRAY<STRING> of tags. Prefer this over `tags`."),
  is_active OPTIONS(description="TRUE when status='active'."),
  is_published OPTIONS(description="TRUE when published_at IS NOT NULL."),
  created_at OPTIONS(description="UTC timestamp of product creation in Shopify."),
  updated_at OPTIONS(description="UTC timestamp of last Shopify-side mutation."),
  published_at OPTIONS(description="UTC timestamp the product was published, or NULL."),
  created_date_sydney OPTIONS(description="DATE of created_at in Australia/Sydney."),
  image_count OPTIONS(description="Number of images on the product."),
  variant_count OPTIONS(description="Number of variants on the product."),
  refreshed_at OPTIONS(description="UTC timestamp this catalog row was last refreshed (weekly).")
)
OPTIONS(description="Product catalog view. Refreshed weekly on Mondays. For catalog questions (exists / active / published). For sales performance use v_product_performance.")
AS
SELECT
  p.product_id,
  p.store_region,
  p.title,
  p.handle,
  p.product_type,
  p.vendor,
  p.status,
  p.tags,
  p.tags_array,
  p.status = 'active' AS is_active,
  p.published_at IS NOT NULL AS is_published,
  p.created_at,
  p.updated_at,
  p.published_at,
  DATE(p.created_at, "Australia/Sydney") AS created_date_sydney,
  p.image_count,
  p.variant_count,
  p.refreshed_at
FROM `peppermayo.products_master` p;
