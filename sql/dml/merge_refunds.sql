-- Merge staging_refunds into refunds_master.
--
-- Runs after merge_orders.sql (so the parent order is guaranteed
-- present / fresh in master). Refunds are append-mostly — Shopify
-- doesn't typically mutate an existing refund row, but we still
-- overwrite matched rows to pick up the rare note/user edit.

MERGE `peppermayo.refunds_master` T
USING (
  -- Filter to refunds whose parent order is present in orders_master.
  -- This handles the edge case where a refund arrived in the staging
  -- slice but the order itself was rejected by merge_orders.sql
  -- (because master had a fresher copy than staging).
  --
  -- Dedupe staging by refund_id first: the daily DTS uses WRITE_TRUNCATE
  -- against `daily/refunds/*.csv`, so it re-loads every CSV ever written
  -- under that prefix. Combined with the lambda's 2h window overlap,
  -- the same refund_id appears in multiple days' files.
  WITH refunds_dedup AS (
    SELECT * FROM `peppermayo.staging_refunds`
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY refund_id
      ORDER BY processed_at DESC NULLS LAST, created_at DESC NULLS LAST
    ) = 1
  )
  SELECT s.*
  FROM refunds_dedup s
  JOIN `peppermayo.orders_master` o USING (order_id)
) S
ON T.refund_id = S.refund_id
WHEN MATCHED THEN UPDATE SET
  order_id         = S.order_id,
  store_region     = S.store_region,
  order_created_at = S.order_created_at,
  created_at       = S.created_at,
  processed_at     = S.processed_at,
  currency         = S.currency,
  refund_subtotal  = S.refund_subtotal,
  refund_total_tax = S.refund_total_tax,
  refund_amount    = S.refund_amount,
  note             = S.note,
  user_id          = S.user_id,
  updated_at       = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
  refund_id, order_id, store_region, order_created_at,
  created_at, processed_at, currency,
  refund_subtotal, refund_total_tax, refund_amount,
  note, user_id, updated_at
) VALUES (
  S.refund_id, S.order_id, S.store_region, S.order_created_at,
  S.created_at, S.processed_at, S.currency,
  S.refund_subtotal, S.refund_total_tax, S.refund_amount,
  S.note, S.user_id, CURRENT_TIMESTAMP()
);
