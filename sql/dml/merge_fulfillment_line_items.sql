-- Merge staging_fulfillment_line_items into fulfillment_line_items_master.
-- Composite primary key (fulfillment_id, line_item_id).

MERGE `peppermayo.fulfillment_line_items_master` T
USING (
  SELECT s.*
  FROM `peppermayo.staging_fulfillment_line_items` s
  JOIN `peppermayo.fulfillments_master` f USING (fulfillment_id)
) S
ON T.fulfillment_id = S.fulfillment_id
AND T.line_item_id  = S.line_item_id
WHEN MATCHED THEN UPDATE SET
  order_id         = S.order_id,
  store_region     = S.store_region,
  order_created_at = S.order_created_at,
  fulfilled_at     = S.fulfilled_at,
  status           = S.status,
  quantity         = S.quantity,
  updated_at       = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
  fulfillment_id, line_item_id, order_id, store_region,
  order_created_at, fulfilled_at, status, quantity, updated_at
) VALUES (
  S.fulfillment_id, S.line_item_id, S.order_id, S.store_region,
  S.order_created_at, S.fulfilled_at, S.status, S.quantity, CURRENT_TIMESTAMP()
);
