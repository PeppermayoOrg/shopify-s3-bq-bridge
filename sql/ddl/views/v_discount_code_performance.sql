-- v_discount_code_performance — discount_code × month × region.
--
-- Unnests v_orders.discount_codes_array so an order with two codes
-- contributes once to each code's numbers. This intentionally
-- double-counts orders across codes; when reporting "orders with any
-- discount" aggregate without unnesting.
--
-- LTV attribution is coarse: avg_customer_ltv_aud averages the
-- customers_master LTV of every customer who used the code. A
-- customer acquired by the code and a loyal customer who happened to
-- redeem it count equally. Use customers_master.first_discount_code
-- for strict acquisition attribution.

CREATE OR REPLACE VIEW `peppermayo.v_discount_code_performance`
(
  month OPTIONS(description="Sydney-local first-of-month DATE of the order."),
  store_region OPTIONS(description="Storefront region: AU, US, UK, CA, EU."),
  discount_code OPTIONS(description="Discount code, trimmed. One row per (code, month, region)."),
  orders OPTIONS(description="Count of non-cancelled orders that applied this code. An order with N codes contributes to N rows (double-counted across codes)."),
  distinct_customers OPTIONS(description="Distinct identified customer_ids that used this code."),
  gross_revenue_aud OPTIONS(description="SUM(total_price_aud) for orders that used this code. Pre-refund."),
  discount_aud OPTIONS(description="SUM(total_discounts_aud) for orders that used this code."),
  avg_discount_depth_pct OPTIONS(description="Average of total_discounts / (total_price + total_discounts). Rough, order-level."),
  avg_customer_ltv_aud OPTIONS(description="Average customers_master.lifetime_revenue_aud across users of the code. COARSE — a customer acquired by the code and a loyal customer who happened to redeem it count equally. For acquisition attribution use customers_master.first_discount_code.")
)
OPTIONS(description="Discount code performance. Orders with multiple codes are counted N times (once per code) — do NOT SUM(orders) thinking it equals distinct orders. ALREADY excludes cancelled orders.")
AS
WITH unnested AS (
  SELECT
    o.created_month_sydney AS month,
    o.store_region,
    code AS discount_code,
    o.customer_id,
    o.total_price_aud,
    o.total_discounts_aud,
    SAFE_DIVIDE(o.total_discounts_aud, o.total_price_aud + o.total_discounts_aud) AS discount_depth_pct
  FROM `peppermayo.v_orders` o,
  UNNEST(o.discount_codes_array) AS code
  WHERE NOT o.is_cancelled
)
SELECT
  u.month,
  u.store_region,
  u.discount_code,
  COUNT(*) AS orders,
  COUNT(DISTINCT u.customer_id) AS distinct_customers,
  SUM(u.total_price_aud)     AS gross_revenue_aud,
  SUM(u.total_discounts_aud) AS discount_aud,
  AVG(u.discount_depth_pct)  AS avg_discount_depth_pct,
  AVG(c.lifetime_revenue_aud) AS avg_customer_ltv_aud
FROM unnested u
LEFT JOIN `peppermayo.customers_master` c USING (customer_id)
GROUP BY u.month, u.store_region, u.discount_code;
