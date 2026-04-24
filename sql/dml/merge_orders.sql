-- Upsert daily staging into orders_master.
--
-- Matched rows are only updated when staging carries a strictly newer
-- updated_at, so an out-of-order or replayed run can never clobber fresher
-- data. All mutable fields (status, totals, tags, discount codes, timestamps)
-- are refreshed so refunds and order edits propagate correctly.
--
-- Immutable identity fields (order_id, store_region, customer_id, created_at,
-- currency) are intentionally omitted from the UPDATE.
--
-- The join is on order_id alone (not (store_region, order_id)). Shopify order
-- IDs are globally unique across stores, so this is safe today. If a
-- non-Shopify source is ever added, revisit this join key.
MERGE `peppermayo.orders_master` T
USING `peppermayo.staging_orders` S
ON T.order_id = S.order_id
WHEN MATCHED AND S.updated_at > T.updated_at THEN
  UPDATE SET
    financial_status = S.financial_status,
    fulfillment_status = S.fulfillment_status,
    cancelled_at = S.cancelled_at,
    closed_at = S.closed_at,
    updated_at = S.updated_at,
    subtotal_price = S.subtotal_price,
    total_discounts = S.total_discounts,
    total_tax = S.total_tax,
    total_shipping_price = S.total_shipping_price,
    total_price = S.total_price,
    tags = S.tags,
    discount_codes = S.discount_codes,
    cancel_reason = S.cancel_reason,
    total_weight_grams = S.total_weight_grams,
    current_total_price = S.current_total_price
WHEN NOT MATCHED THEN
  INSERT (store_region, order_id, customer_id, created_at, updated_at, cancelled_at, closed_at, financial_status, fulfillment_status, currency, subtotal_price, total_discounts, total_tax, total_shipping_price, total_price, tags, discount_codes, source_name, order_number, cancel_reason, payment_gateway, device_type, referring_site, shipping_city, shipping_province, shipping_country_code, total_weight_grams, presentment_currency, current_total_price, hashed_email)
  VALUES (S.store_region, S.order_id, S.customer_id, S.created_at, S.updated_at, S.cancelled_at, S.closed_at, S.financial_status, S.fulfillment_status, S.currency, S.subtotal_price, S.total_discounts, S.total_tax, S.total_shipping_price, S.total_price, S.tags, S.discount_codes, S.source_name, S.order_number, S.cancel_reason, S.payment_gateway, S.device_type, S.referring_site, S.shipping_city, S.shipping_province, S.shipping_country_code, S.total_weight_grams, S.presentment_currency, S.current_total_price, S.hashed_email);