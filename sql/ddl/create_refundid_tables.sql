-- Create Staging Layer
CREATE OR REPLACE TABLE peppermayo.staging_refundid_returns (
    raw_json JSON,
    ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Create Master Headers
CREATE OR REPLACE TABLE peppermayo.refundid_returns_master (
    refundid_id STRING NOT NULL,
    region STRING NOT NULL,
    rma_reference STRING,
    refund_status STRING,
    resolution_type STRING,
    created_at TIMESTAMP,
    total_refunded_amount FLOAT64,
    raw_payload JSON
);

-- Create Master Line Items
CREATE OR REPLACE TABLE peppermayo.refundid_items_master (
    refundid_id STRING NOT NULL,
    shopify_order_id STRING NOT NULL,
    shopify_line_item_id STRING,
    sku STRING,
    return_quantity INT64,
    item_price FLOAT64,
    reason STRING
);