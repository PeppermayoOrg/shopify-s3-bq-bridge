-- Merge staging_fulfillments into fulfillments_master. Runs after
-- merge_orders.sql. Fulfilments mutate (shipment_status transitions
-- through label_purchased → in_transit → delivered over days), so
-- every matched row refreshes.
--
-- tracking_numbers arrives as a comma-joined STRING in staging
-- (CSV-friendly) and is split into an ARRAY<STRING> here.

MERGE `peppermayo.fulfillments_master` T
USING (
  SELECT s.*
  FROM `peppermayo.staging_fulfillments` s
  JOIN `peppermayo.orders_master` o USING (order_id)
) S
ON T.fulfillment_id = S.fulfillment_id
WHEN MATCHED THEN UPDATE SET
  order_id         = S.order_id,
  store_region     = S.store_region,
  order_created_at = S.order_created_at,
  created_at       = S.created_at,
  fulfilled_at     = S.fulfilled_at,
  status           = S.status,
  shipment_status  = S.shipment_status,
  tracking_company = S.tracking_company,
  tracking_number  = S.tracking_number,
  tracking_numbers = IF(S.tracking_numbers IS NULL OR S.tracking_numbers = '', [], SPLIT(S.tracking_numbers, ',')),
  tracking_url     = S.tracking_url,
  service          = S.service,
  location_id      = S.location_id,
  name             = S.name,
  updated_at       = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
  fulfillment_id, order_id, store_region, order_created_at,
  created_at, fulfilled_at, status, shipment_status,
  tracking_company, tracking_number, tracking_numbers, tracking_url,
  service, location_id, name, updated_at
) VALUES (
  S.fulfillment_id, S.order_id, S.store_region, S.order_created_at,
  S.created_at, S.fulfilled_at, S.status, S.shipment_status,
  S.tracking_company, S.tracking_number,
  IF(S.tracking_numbers IS NULL OR S.tracking_numbers = '', [], SPLIT(S.tracking_numbers, ',')),
  S.tracking_url, S.service, S.location_id, S.name, CURRENT_TIMESTAMP()
);
