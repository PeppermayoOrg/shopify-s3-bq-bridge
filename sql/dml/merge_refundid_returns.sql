MERGE peppermayo.refundid_returns_master T
USING (
  SELECT * FROM (
    SELECT
      COALESCE(LAX_STRING(raw_json.standard_return_id), LAX_STRING(raw_json.refundid_id)) AS refundid_id,
      LAX_STRING(raw_json._peppermayo_region) AS region,
      LAX_STRING(raw_json.rma_ref) AS rma_reference,
      LAX_STRING(raw_json.status) AS refund_status,
      LAX_STRING(raw_json.return_resolution) AS resolution_type,
      COALESCE(
        SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Z', LAX_STRING(raw_json.created_at)),
        CURRENT_TIMESTAMP()
      ) AS created_at,
      COALESCE(
        SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%E*S%Z', LAX_STRING(raw_json.updated_at)),
        CURRENT_TIMESTAMP()
      ) AS updated_at,
      COALESCE(
        LAX_FLOAT64(raw_json.requested_refund_breakdown.total.amount),
        LAX_FLOAT64(raw_json.refund_breakdown.total.amount)
      ) AS total_refunded_amount,
      raw_json AS raw_payload,
      ingested_at
    FROM peppermayo.staging_refundid_returns
    WHERE COALESCE(LAX_STRING(raw_json.standard_return_id), LAX_STRING(raw_json.refundid_id)) IS NOT NULL
  )
  -- Every file under daily/refundid/ is reloaded nightly, so one return can appear in several files: keep the copy
  -- fetched most recently (files from before _peppermayo_fetched_at existed sort last).
  QUALIFY ROW_NUMBER() OVER(
    PARTITION BY refundid_id
    ORDER BY LAX_STRING(raw_payload._peppermayo_fetched_at) DESC NULLS LAST, updated_at DESC, ingested_at DESC
  ) = 1
) S
ON T.refundid_id = S.refundid_id
WHEN MATCHED THEN
  UPDATE SET
    refund_status = S.refund_status,
    resolution_type = S.resolution_type,
    total_refunded_amount = S.total_refunded_amount,
    raw_payload = S.raw_payload
WHEN NOT MATCHED THEN
  INSERT (refundid_id, region, rma_reference, refund_status, resolution_type, created_at, total_refunded_amount, raw_payload)
  VALUES (S.refundid_id, S.region, S.rma_reference, S.refund_status, S.resolution_type, S.created_at, S.total_refunded_amount, S.raw_payload);

DELETE FROM peppermayo.refundid_items_master
WHERE refundid_id IN (
  SELECT COALESCE(LAX_STRING(raw_json.standard_return_id), LAX_STRING(raw_json.refundid_id))
  FROM peppermayo.staging_refundid_returns
  WHERE COALESCE(LAX_STRING(raw_json.standard_return_id), LAX_STRING(raw_json.refundid_id)) IS NOT NULL
);

INSERT INTO peppermayo.refundid_items_master (refundid_id, shopify_order_id, shopify_line_item_id, sku, return_quantity, item_price, reason)
SELECT
  refundid_id,
  LAX_STRING(item.merchant_order_ref) AS shopify_order_id,
  LAX_STRING(item.line_item_ref) AS shopify_line_item_id,
  LAX_STRING(item.sku) AS sku,
  LAX_INT64(item.quantity) AS return_quantity,
  LAX_FLOAT64(item.price.amount) AS item_price,
  COALESCE(LAX_STRING(item.child_return_reason), LAX_STRING(item.return_reason)) AS reason
FROM (
  SELECT 
    COALESCE(LAX_STRING(raw_json.standard_return_id), LAX_STRING(raw_json.refundid_id)) AS refundid_id,
    raw_json
  FROM peppermayo.staging_refundid_returns
  WHERE COALESCE(LAX_STRING(raw_json.standard_return_id), LAX_STRING(raw_json.refundid_id)) IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(
    PARTITION BY COALESCE(LAX_STRING(raw_json.standard_return_id), LAX_STRING(raw_json.refundid_id))
    ORDER BY LAX_STRING(raw_json._peppermayo_fetched_at) DESC NULLS LAST, ingested_at DESC
  ) = 1
) p,
UNNEST(JSON_QUERY_ARRAY(p.raw_json.line_items)) AS item;