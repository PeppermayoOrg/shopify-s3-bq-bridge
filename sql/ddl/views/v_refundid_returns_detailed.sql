-- v_refundid_returns_detailed — return × line_item × note grain.
--
-- Extracts detailed line item and reason note data from the raw JSON payload
-- provided by the RefundID webhook/API.
--
-- This view uses LEFT JOIN UNNEST to ensure that returns without line items
-- or line items without notes are not dropped from the dataset.
--
-- WARNING: Because this view joins line items with their associated notes,
-- a single line item may appear on multiple rows if it has multiple return
-- reason notes (e.g., a TEXT note and an IMAGE note). When aggregating 
-- item-level or return-level metrics, be sure to account for this grain
-- to avoid double-counting.

CREATE OR REPLACE VIEW `peppermayo.v_refundid_returns_detailed`
(
  refundid_id OPTIONS(description="Unique RefundID return identifier."),
  region OPTIONS(description="Storefront region (e.g., uk, au, us)."),
  rma_reference OPTIONS(description="RMA reference number for the return."),
  refund_status OPTIONS(description="Current status of the refund."),
  resolution_type OPTIONS(description="Resolution type for the return."),
  created_at OPTIONS(description="Timestamp when the return was created in RefundID."),
  total_refunded_amount OPTIONS(description="Total refunded amount from the master table."),

  order_number OPTIONS(description="Shopify order number (e.g., PMUK400170926)."),
  customer_email OPTIONS(description="Customer email address associated with the return."),
  closed_by OPTIONS(description="Who closed the return (e.g., merchant, system)."),
  closed_on OPTIONS(description="Timestamp when the return was closed."),

  status OPTIONS(description="Status extracted directly from the payload."),
  return_resolution OPTIONS(description="Return resolution extracted directly from the payload (e.g., Store Credit)."),
  
  -- Close Breakdown
  final_refund_amount OPTIONS(description="Final refund amount from the close breakdown."),
  final_refund_currency OPTIONS(description="Currency of the final refund amount."),
  refund_methods_json OPTIONS(description="Raw JSON array of refund methods and amounts from the close breakdown."),
  
  -- Additional Top-level Details
  exchange OPTIONS(description="Exchange details, if applicable."),
  shipping_label OPTIONS(description="Shipping label details as JSON, if applicable."),
  tracking_status OPTIONS(description="Latest tracking status of the return parcel (e.g. TRANSIT, DELIVERED). Refreshed nightly."),
  tracking_status_date OPTIONS(description="When the tracking status last changed."),
  tracking_carrier OPTIONS(description="Carrier of the return label."),
  tracking_number OPTIONS(description="Tracking number of the return label."),
  standard_return_id OPTIONS(description="Standard return ID."),
  standard_return_encrypted_id OPTIONS(description="Encrypted standard return ID."),
  
  -- Exchange Rate
  exchange_rate OPTIONS(description="Estimated order to store currency exchange rate."),
  exchange_rate_from_currency OPTIONS(description="Currency the exchange rate is from."),
  exchange_rate_to_currency OPTIONS(description="Currency the exchange rate is to."),
  
  -- Requested Breakdown
  requested_total_amount OPTIONS(description="Total requested refund amount."),
  requested_total_currency OPTIONS(description="Currency of the requested total amount."),
  requested_subtotal_amount OPTIONS(description="Subtotal requested refund amount."),
  requested_subtotal_currency OPTIONS(description="Currency of the requested subtotal amount."),
  requested_shipping_cost OPTIONS(description="Customer shipping cost in the requested refund breakdown."),
  requested_shipping_cost_currency OPTIONS(description="Currency of the requested shipping cost."),
  requested_store_return_fee OPTIONS(description="Store return fee in the requested refund breakdown."),
  requested_store_return_fee_currency OPTIONS(description="Currency of the requested store return fee."),

  -- Line Item Details
  sku OPTIONS(description="Product SKU of the returned item."),
  barcode OPTIONS(description="Product barcode of the returned item."),
  item_title OPTIONS(description="Product title of the returned item."),
  item_variant OPTIONS(description="Product variant title of the returned item."),
  product_ref OPTIONS(description="Shopify product reference ID."),
  variant_ref OPTIONS(description="Shopify variant reference ID."),
  line_item_ref OPTIONS(description="Shopify line item reference ID."),
  merchant_order_ref OPTIONS(description="Merchant order reference ID."),
  return_quantity OPTIONS(description="Quantity returned for this line item."),
  item_price OPTIONS(description="Price amount for a single item."),
  item_currency OPTIONS(description="Currency of the item price."),
  item_tax_amount OPTIONS(description="Tax amount for the returned item."),
  item_tax_included OPTIONS(description="Whether tax is included in the item price."),
  return_reason OPTIONS(description="Customer-selected reason for the return."),
  child_return_reason OPTIONS(description="Secondary or child return reason, if applicable."),
  item_notes OPTIONS(description="Additional notes for the line item."),
  item_resolution OPTIONS(description="Resolution chosen for this specific line item (e.g., accept, reject)."),
  is_restocked OPTIONS(description="Boolean indicating whether the item was restocked."),
  image_url OPTIONS(description="Image URL of the returned product variant."),
  
  -- Notes Details
  note_type OPTIONS(description="Type of the return reason note (e.g., TEXT, IMAGE)."),
  note_question OPTIONS(description="Title/question prompted to the customer for the note."),
  note_answer OPTIONS(description="Value/answer provided by the customer or URL to the image.")
)
OPTIONS(description="Detailed view of RefundID returns, expanding line items and return reason notes. GRAIN: Return × Line Item × Note.")
AS
SELECT
    r.refundid_id,
    r.region,
    r.rma_reference,
    r.refund_status,
    r.resolution_type,
    r.created_at,
    r.total_refunded_amount,
    
    -- Extracting Top-level Details from JSON payload
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.order_number') AS order_number,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.customer.email') AS customer_email,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.close_breakdown.closed_by') AS closed_by,
    CAST(JSON_EXTRACT_SCALAR(r.raw_payload, '$.close_breakdown.closed_on') AS TIMESTAMP) AS closed_on,
    
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.status') AS status,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.return_resolution') AS return_resolution,
    
    CAST(JSON_EXTRACT_SCALAR(r.raw_payload, '$.close_breakdown.final_refund_amount.amount') AS FLOAT64) AS final_refund_amount,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.close_breakdown.final_refund_amount.currency') AS final_refund_currency,
    JSON_EXTRACT(r.raw_payload, '$.close_breakdown.refunds') AS refund_methods_json,
    
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.exchange') AS exchange,
    JSON_EXTRACT(r.raw_payload, '$.shipping_label') AS shipping_label,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.shipping_label.tracking.status') AS tracking_status,
    SAFE_CAST(JSON_EXTRACT_SCALAR(r.raw_payload, '$.shipping_label.tracking.status_date') AS TIMESTAMP) AS tracking_status_date,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.shipping_label.tracking.carrier') AS tracking_carrier,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.shipping_label.tracking.tracking_number') AS tracking_number,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.standard_return_id') AS standard_return_id,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.standard_return_encrypted_id') AS standard_return_encrypted_id,
    
    CAST(JSON_EXTRACT_SCALAR(r.raw_payload, '$.estimated_order_to_store_currency_exchange_rate.exchange_rate') AS FLOAT64) AS exchange_rate,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.estimated_order_to_store_currency_exchange_rate.from_currency') AS exchange_rate_from_currency,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.estimated_order_to_store_currency_exchange_rate.to_currency') AS exchange_rate_to_currency,

    CAST(JSON_EXTRACT_SCALAR(r.raw_payload, '$.requested_refund_breakdown.total.amount') AS FLOAT64) AS requested_total_amount,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.requested_refund_breakdown.total.currency') AS requested_total_currency,
    CAST(JSON_EXTRACT_SCALAR(r.raw_payload, '$.requested_refund_breakdown.subtotal.amount') AS FLOAT64) AS requested_subtotal_amount,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.requested_refund_breakdown.subtotal.currency') AS requested_subtotal_currency,
    CAST(JSON_EXTRACT_SCALAR(r.raw_payload, '$.requested_refund_breakdown.customer_shipping_cost.amount') AS FLOAT64) AS requested_shipping_cost,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.requested_refund_breakdown.customer_shipping_cost.currency') AS requested_shipping_cost_currency,
    CAST(JSON_EXTRACT_SCALAR(r.raw_payload, '$.requested_refund_breakdown.store_return_fee.amount') AS FLOAT64) AS requested_store_return_fee,
    JSON_EXTRACT_SCALAR(r.raw_payload, '$.requested_refund_breakdown.store_return_fee.currency') AS requested_store_return_fee_currency,

    -- Extracting Item Details from JSON
    JSON_EXTRACT_SCALAR(item, '$.sku') AS sku,
    JSON_EXTRACT_SCALAR(item, '$.barcode') AS barcode,
    JSON_EXTRACT_SCALAR(item, '$.title') AS item_title,
    JSON_EXTRACT_SCALAR(item, '$.variant') AS item_variant,
    JSON_EXTRACT_SCALAR(item, '$.product_ref') AS product_ref,
    JSON_EXTRACT_SCALAR(item, '$.variant_ref') AS variant_ref,
    JSON_EXTRACT_SCALAR(item, '$.line_item_ref') AS line_item_ref,
    JSON_EXTRACT_SCALAR(item, '$.merchant_order_ref') AS merchant_order_ref,
    CAST(JSON_EXTRACT_SCALAR(item, '$.quantity') AS INT64) AS return_quantity,
    CAST(JSON_EXTRACT_SCALAR(item, '$.price.amount') AS FLOAT64) AS item_price,
    JSON_EXTRACT_SCALAR(item, '$.price.currency') AS item_currency,
    CAST(JSON_EXTRACT_SCALAR(item, '$.tax_detail.tax.amount') AS FLOAT64) AS item_tax_amount,
    CAST(JSON_EXTRACT_SCALAR(item, '$.tax_detail.tax_included') AS BOOL) AS item_tax_included,
    JSON_EXTRACT_SCALAR(item, '$.return_reason') AS return_reason,
    JSON_EXTRACT_SCALAR(item, '$.child_return_reason') AS child_return_reason,
    JSON_EXTRACT_SCALAR(item, '$.notes') AS item_notes,
    JSON_EXTRACT_SCALAR(item, '$.resolution') AS item_resolution,
    CAST(JSON_EXTRACT_SCALAR(item, '$.restock') AS BOOL) AS is_restocked,
    JSON_EXTRACT_SCALAR(item, '$.image_url') AS image_url,
    
    -- Extracting the Notes we discovered
    JSON_EXTRACT_SCALAR(note, '$.type') AS note_type,
    JSON_EXTRACT_SCALAR(note, '$.title') AS note_question,
    JSON_EXTRACT_SCALAR(note, '$.value') AS note_answer
FROM
    `peppermayo.refundid_returns_master` AS r
    -- This unparses the array of items
    LEFT JOIN UNNEST(JSON_QUERY_ARRAY(r.raw_payload, '$.line_items')) AS item
    -- This unparses the array of notes within each item
    LEFT JOIN UNNEST(JSON_QUERY_ARRAY(item, '$.return_reason_notes')) AS note;