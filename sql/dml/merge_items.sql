-- Upsert daily staging into order_items_master.
--
-- Line items have no updated_at of their own, so the freshness guarantee is
-- inherited from the parent order. This merge runs *after* merge_orders.sql
-- and filters staging to only those line items whose parent order in
-- staging matches the parent order now in master (same updated_at). That
-- equality means merge_orders either just inserted the order or just
-- accepted the staging snapshot (its own `S.updated_at > T.updated_at`
-- guard passed). Orders where merge_orders rejected the staging snapshot
-- because master already had fresher data are skipped here too, so their
-- line items can't be clobbered by stale data.
--
-- This matters most during the one-shot historical load: the backfill's
-- captured snapshot for a given order may be weeks older than what the
-- daily pipeline has since written to master. Without this guard, the
-- items merge would happily overwrite the fresher line-item state with
-- the old historical rows.
--
-- Under normal daily operation the guard is a no-op: merge_orders updates
-- master to match staging for every in-window order, so every row in
-- staging_order_items also satisfies the join.
--
-- All mutable attributes are refreshed (quantity, price, sku, name, size,
-- colour) so product renames, SKU changes and variant parsing corrections
-- propagate to the warehouse.
--
-- Known limitation: this merge does not delete line items that have been
-- removed from an order in Shopify. In practice Shopify refunds rather than
-- deletes line items, so stale rows are rare. If this becomes an issue,
-- extend the merge with a WHEN NOT MATCHED BY SOURCE ... DELETE clause
-- scoped to the order_ids present in staging.
MERGE `peppermayo.order_items_master` T
USING (
  SELECT S.*
  FROM `peppermayo.staging_order_items` S
  JOIN `peppermayo.staging_orders` SO USING (order_id)
  JOIN `peppermayo.orders_master` M USING (order_id)
  WHERE SO.updated_at = M.updated_at
) S
ON T.line_item_id = S.line_item_id
WHEN MATCHED THEN
  UPDATE SET
    quantity = S.quantity,
    price = S.price,
    sku = S.sku,
    name = S.name,
    size = S.size,
    colour = S.colour
WHEN NOT MATCHED THEN
  INSERT (line_item_id, order_id, product_id, variant_id, sku, name, quantity, price, size, colour)
  VALUES (S.line_item_id, S.order_id, S.product_id, S.variant_id, S.sku, S.name, S.quantity, S.price, S.size, S.colour);