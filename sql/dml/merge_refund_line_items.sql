-- Merge staging_refund_line_items into refund_line_items_master.
-- Runs after merge_refunds.sql. Same "parent must exist in master"
-- guard as merge_items does for orders.

MERGE `peppermayo.refund_line_items_master` T
USING (
  -- Dedupe staging by refund_line_item_id first: the daily DTS uses
  -- WRITE_TRUNCATE against `daily/refund_items/*.csv`, so it re-loads
  -- every CSV ever written under that prefix. Combined with the
  -- lambda's 2h window overlap, the same refund_line_item_id appears
  -- in multiple days' files.
  WITH refund_items_dedup AS (
    SELECT * FROM `peppermayo.staging_refund_line_items`
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY refund_line_item_id
      ORDER BY refund_processed_at DESC NULLS LAST
    ) = 1
  )
  SELECT s.*
  FROM refund_items_dedup s
  JOIN `peppermayo.refunds_master` r USING (refund_id)
) S
ON T.refund_line_item_id = S.refund_line_item_id
WHEN MATCHED THEN UPDATE SET
  refund_id           = S.refund_id,
  order_id            = S.order_id,
  line_item_id        = S.line_item_id,
  store_region        = S.store_region,
  order_created_at    = S.order_created_at,
  refund_processed_at = S.refund_processed_at,
  quantity            = S.quantity,
  subtotal            = S.subtotal,
  total_tax           = S.total_tax,
  restock_type        = S.restock_type,
  updated_at          = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
  refund_line_item_id, refund_id, order_id, line_item_id,
  store_region, order_created_at, refund_processed_at,
  quantity, subtotal, total_tax, restock_type, updated_at
) VALUES (
  S.refund_line_item_id, S.refund_id, S.order_id, S.line_item_id,
  S.store_region, S.order_created_at, S.refund_processed_at,
  S.quantity, S.subtotal, S.total_tax, S.restock_type, CURRENT_TIMESTAMP()
);
