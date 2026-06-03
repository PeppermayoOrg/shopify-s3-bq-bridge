# Final Project Verification Checklist

End-to-end checks to confirm the shopify-s3-bq-bridge pipeline is wired up
correctly. Work through top-to-bottom — each section assumes the one above it
passes. Replace `<account-id>`, `<region>`, `<lambda-function-name>`,
`<gcp-project>` with your values. Commands assume `aws`, `gcloud`, `bq`, `jq`
are installed and authenticated.

Dataset: `peppermayo` in `australia-southeast1`. S3 bucket:
`peppermayo-shopify-orders`.

---

## 1. Local project setup

- [ ] Node.js 24+ installed: `node -v`
- [ ] Dependencies install cleanly: `npm install`
- [ ] `.env` present with five Shopify and five Refundid tokens (see .env.example):

  ```sh
  grep -c '^\(SHOPIFY\|REFUNDID\)_TOKEN_\(AU\|US\|UK\|CA\|EU\)=' .env   # expect 10
  ```

- [ ] AWS CLI authenticated to the right account: `aws sts get-caller-identity`
- [ ] gcloud authenticated to the right project:

  ```sh
  gcloud config get-value project
  gcloud auth application-default print-access-token >/dev/null
  ```

- [ ] `bq` CLI reaches the dataset: `bq ls peppermayo`
- [ ] Lambda build produces a zip: `npm run build && ls -lh lambda.zip`

---

## 2. AWS — SSM, S3, IAM

### 2.1 SSM Parameter Store (Shopify tokens)

- [ ] Five SecureString parameters exist, one per region:

  ```sh
  for r in au us uk ca eu; do
    aws ssm get-parameter --name "/shopify/peppermayo-$r/token" \
      --with-decryption --query 'Parameter.{Name:Name,Type:Type}' --output table
  done
  ```

  Each must return `Type: SecureString`. No value should print in plaintext
  unless you explicitly add `Value:Value`.

### 2.2 S3 bucket

- [ ] Bucket exists in the same account:

  ```sh
  aws s3api head-bucket --bucket peppermayo-shopify-orders
  ```

- [ ] Versioning + encryption are enabled:

  ```sh
  aws s3api get-bucket-versioning --bucket peppermayo-shopify-orders   # Status: Enabled
  aws s3api get-bucket-encryption --bucket peppermayo-shopify-orders   # AES256
  ```

- [ ] Expected prefixes exist after the first run (empty pre-launch is fine):

  ```sh
  aws s3 ls s3://peppermayo-shopify-orders/daily/
  aws s3 ls s3://peppermayo-shopify-orders/weekly/
  ```

### 2.3 Lambda execution role

- [ ] Identify the Lambda's role:

  ```sh
  aws lambda get-function-configuration --function-name <lambda-function-name> \
    --query 'Role' --output text
  ```

- [ ] Role has `ssm:GetParameter` on `/shopify/peppermayo-*/token` and
      `s3:PutObject` on `arn:aws:s3:::peppermayo-shopify-orders/*`:

  ```sh
  aws iam list-attached-role-policies --role-name <role-name>
  aws iam list-role-policies --role-name <role-name>
  # Inspect each policy document and confirm the two statements above
  ```

### 2.4 BigQuery DTS IAM user (separate from the Lambda role)

- [ ] IAM user exists with an active access key (see [INFRA.md](INFRA.md)).
- [ ] Policy scopes `s3:GetObject` + `s3:ListBucket` to `daily/*`, `weekly/*`,
      `historical/*` only — not the whole bucket.
- [ ] Access key ID used in the BigQuery transferConfigs matches a key that
      exists:

  ```sh
  aws iam list-access-keys --user-name <dts-user-name>
  ```

### 2.5 EventBridge schedules

- [ ] Two rules target the Lambda, both **ENABLED**:

  ```sh
  aws events list-rule-names-by-target --target-arn \
    arn:aws:lambda:<region>:<account-id>:function:<lambda-function-name>
  ```

- [ ] Daily rule: `cron(0 15 * * ? *)`, no input payload.
- [ ] Weekly rule: `cron(0 14 ? * MON *)`, input `{"mode":"products"}`:

  ```sh
  aws events describe-rule --name <daily-rule-name>
  aws events describe-rule --name <weekly-rule-name>
  aws events list-targets-by-rule --rule <weekly-rule-name>   # check Input
  ```

- [ ] Lambda has permission to be invoked by both rules:

  ```sh
  aws lambda get-policy --function-name <lambda-function-name> | jq .
  ```

### 2.6 CloudWatch alarms ([INFRA.md](INFRA.md))

- [ ] Both alarms exist and are in `OK` state:

  ```sh
  aws cloudwatch describe-alarms \
    --alarm-names shopify-s3-bq-bridge-lambda-errors \
                  shopify-s3-bq-bridge-lambda-no-invocations \
    --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Actions:AlarmActions}'
  ```

- [ ] SNS topic has a **confirmed** email subscription:

  ```sh
  aws sns list-subscriptions-by-topic \
    --topic-arn arn:aws:sns:<region>:<account-id>:shopify-s3-bq-bridge-alerts
  # SubscriptionArn must NOT be "PendingConfirmation"
  ```

---

## 3. Lambda — smoke test

### 3.1 Daily mode (orders + fx)

- [ ] Manual invoke with empty payload succeeds:

  ```sh
  aws lambda invoke --function-name <lambda-function-name> \
    --payload '{}' --cli-binary-format raw-in-base64-out /tmp/out.json
  cat /tmp/out.json
  ```

  Exit code 0 and no `errorMessage` in output.
- [ ] Seven daily prefixes received fresh objects in the last few minutes:

  ```sh
  for p in orders items refunds refund_items fulfillments fulfillment_items fx; do
    echo "== $p =="
    aws s3 ls s3://peppermayo-shopify-orders/daily/$p/ --recursive \
      | sort | tail -5
  done
  ```

  Each should include a newly-timestamped CSV. Order/item/refund/fulfilment
  files should be per-region (×5); fx should be one file per day.
- [ ] Spot-check one CSV has header + rows:

  ```sh
  aws s3 cp s3://peppermayo-shopify-orders/daily/orders/<latest>.csv - | head -3
  ```

### 3.2 Weekly mode (products)

- [ ] Manual invoke with `products` payload succeeds:

  ```sh
  aws lambda invoke --function-name <lambda-function-name> \
    --payload '{"mode":"products"}' --cli-binary-format raw-in-base64-out /tmp/out.json
  cat /tmp/out.json
  ```

- [ ] Both weekly prefixes received CSVs:

  ```sh
  aws s3 ls s3://peppermayo-shopify-orders/weekly/products/
  aws s3 ls s3://peppermayo-shopify-orders/weekly/product_variants/
  ```

### 3.3 Logs / runtime config

- [ ] Runtime is `nodejs24.x`, handler is `src/lambda/index.handler`, timeout
      900 s:

  ```sh
  aws lambda get-function-configuration --function-name <lambda-function-name> \
    --query '{Runtime:Runtime,Handler:Handler,Timeout:Timeout,MemorySize:MemorySize}'
  ```

- [ ] Recent log stream shows successful region processing + FX snapshot:

  ```sh
  aws logs tail /aws/lambda/<lambda-function-name> --since 10m
  ```

---

## 4. BigQuery — dataset, tables, views

### 4.1 Dataset location

- [ ] Dataset is in `australia-southeast1`:

  ```sh
  bq --format=prettyjson show peppermayo | jq '.location'
  ```

### 4.2 Master + staging tables exist

- [ ] All expected tables present (spot-count; expect ~17+):

  ```sh
  bq ls --max_results 200 peppermayo
  ```

  Required master tables: `orders_master`, `order_items_master`,
  `refunds_master`, `refund_line_items_master`, `fulfillments_master`,
  `fulfillment_line_items_master`, `fx_rates_master`, `customers_master`,
  `products_master`, `product_variants_master`.

  Required staging tables: `staging_orders`, `staging_order_items`,
  `staging_refunds`, `staging_refund_line_items`, `staging_fulfillments`,
  `staging_fulfillment_line_items`, `staging_fx_rates`, `staging_products`,
  `staging_product_variants`.

- [ ] `orders_master` is partitioned on `DATE(created_at)` and clustered on
      `store_region, financial_status`:

  ```sh
  bq show --format=prettyjson peppermayo.orders_master \
    | jq '{timePartitioning, clustering}'
  ```

### 4.3 Views deployed

- [ ] All 14 views present:

  ```sh
  bq ls --max_results 200 peppermayo | grep '^ v_' | wc -l   # expect 14
  ```

  Required: `v_fx_rates_filled`, `v_orders`, `v_order_items`, `v_customers`,
  `v_daily_sales`, `v_monthly_sales`, `v_discount_code_performance`,
  `v_cohort_retention`, `v_refunds`, `v_fulfillments`, `v_products`,
  `v_product_variants`, `v_product_performance`, `v_pipeline_health`.
- [ ] Re-deploying is idempotent: `npm run deploy:views` prints all green.

---

## 5. BigQuery Data Transfer Service — nine configs

Project: `229575872283`. Location: `australia-southeast1`. Config IDs are
pinned below so these checks run unattended.

### 5.1 All nine DTS configs present with expected names + data source

- [ ] Listing returns exactly these nine `amazon_s3` configs (plus any
      historical one-offs):

  ```sh
  bq ls --transfer_config --transfer_location=australia-southeast1 \
    --max_results=50 --format=prettyjson \
    | jq -r '.[] | select(.dataSourceId=="amazon_s3")
             | [.displayName, (.name | split("/")[-1])] | @tsv' \
    | sort
  ```

  Expect (order-independent) these nine rows:

  | Display name | Config ID |
  | --- | --- |
  | Shopify Daily Sync - Orders (Staging) | `69e86084-0000-294c-9104-94eb2c1b9988` |
  | Shopify Daily Sync - Items (Staging) | `69e96150-0000-2dc2-9ed8-94eb2c1bb748` |
  | Shopify Daily Sync - Refunds (Staging) | `69e99c49-0000-2151-828c-3c286d33ef3e` |
  | Shopify Daily Sync - Refund Items (Staging) | `69e9fe21-0000-204d-89f7-94eb2c1b9880` |
  | Shopify Daily Sync - Fulfillments (Staging) | `69eb61f4-0000-2a50-aa66-94eb2c1bbac8` |
  | Shopify Daily Sync - Fulfillment Items (Staging) | `69e9fc33-0000-299c-8adb-089e0827d1bc` |
  | Shopify Daily Sync - FX (Staging) | `69ea0159-0000-2dfe-8bd1-b8db38fc7672` |
  | Shopify Weekly Sync - Products (Staging) | `69eba1eb-0000-201c-a2e0-94eb2c1bbcfa` |
  | Shopify Weekly Sync - Variants (Staging) | `69e9d8b3-0000-2425-832f-f4f5e804ca84` |

### 5.2 Schedule + destination table + S3 URI + write disposition

- [ ] Run the full DTS audit script. For each config it prints
      `displayName`, `schedule`, `destinationDatasetId`, `destinationTable`,
      `data_path`, `write_disposition`, and `disabled`. Paste the output
      back and it can be cross-checked against the expected-values table
      below.

  ```sh
  PROJECT=229575872283
  LOC=australia-southeast1

  DTS_CFGS=(
    "69e86084-0000-294c-9104-94eb2c1b9988"
    "69e96150-0000-2dc2-9ed8-94eb2c1bb748"
    "69e99c49-0000-2151-828c-3c286d33ef3e"
    "69e9fe21-0000-204d-89f7-94eb2c1b9880"
    "69eb61f4-0000-2a50-aa66-94eb2c1bbac8"
    "69e9fc33-0000-299c-8adb-089e0827d1bc"
    "69ea0159-0000-2dfe-8bd1-b8db38fc7672"
    "69eba1eb-0000-201c-a2e0-94eb2c1bbcfa"
    "69e9d8b3-0000-2425-832f-f4f5e804ca84"
  )

  for cfg in "${DTS_CFGS[@]}"; do
    bq --format=prettyjson show --transfer_config "projects/$PROJECT/locations/$LOC/transferConfigs/$cfg" | jq '{displayName, schedule, nextRunTime, disabled, destinationDatasetId, destinationTable: .params.destination_table_name_template, data_path: .params.data_path, write_disposition: .params.write_disposition, file_format: .params.file_format, skip_leading_rows: .params.skip_leading_rows, allow_quoted_newlines: .params.allow_quoted_newlines, ignore_unknown_values: .params.ignore_unknown_values}'
  done
  ```

  Notes:

  - `schedule` may display as `"every 24 hours"` instead of `"every day 15:30"` —
    BigQuery normalises the string for configs created without a pinned time.
    What matters is `nextRunTime`. If `nextRunTime` is **not** at 15:30 UTC
    (daily) / Monday 14:30 UTC (weekly), edit the config in the console and
    set Schedule to `every day 15:30` / `every mon 14:30` to pin it.
  - `skip_leading_rows` returns as the string `"1"` rather than the integer `1`
    — that's normal for DTS params.

  Expected values per config:

  | Display name | schedule | destinationTable | data_path |
  | --- | --- | --- | --- |
  | Shopify Daily Sync - Orders (Staging) | `every day 15:30` | `staging_orders` | `s3://peppermayo-shopify-orders/daily/orders/*.csv` |
  | Shopify Daily Sync - Items (Staging) | `every day 15:30` | `staging_order_items` | `s3://peppermayo-shopify-orders/daily/items/*.csv` |
  | Shopify Daily Sync - Refunds (Staging) | `every day 15:30` | `staging_refunds` | `s3://peppermayo-shopify-orders/daily/refunds/*.csv` |
  | Shopify Daily Sync - Refund Items (Staging) | `every day 15:30` | `staging_refund_line_items` | `s3://peppermayo-shopify-orders/daily/refund_items/*.csv` |
  | Shopify Daily Sync - Fulfillments (Staging) | `every day 15:30` | `staging_fulfillments` | `s3://peppermayo-shopify-orders/daily/fulfillments/*.csv` |
  | Shopify Daily Sync - Fulfillment Items (Staging) | `every day 15:30` | `staging_fulfillment_line_items` | `s3://peppermayo-shopify-orders/daily/fulfillment_items/*.csv` |
  | Shopify Daily Sync - FX (Staging) | `every day 15:30` | `staging_fx_rates` | `s3://peppermayo-shopify-orders/daily/fx/*.csv` |
  | Shopify Weekly Sync - Products (Staging) | `every monday 14:30` | `staging_products` | `s3://peppermayo-shopify-orders/weekly/products/*.csv` |
  | Shopify Weekly Sync - Variants (Staging) | `every monday 14:30` | `staging_product_variants` | `s3://peppermayo-shopify-orders/weekly/product_variants/*.csv` |

  For every row: `destinationDatasetId = peppermayo`,
  `write_disposition = WRITE_TRUNCATE`, `file_format = CSV`,
  `skip_leading_rows = 1`, `allow_quoted_newlines = true`,
  `ignore_unknown_values = true`, `disabled` absent or `false`.

### 5.3 Last run of every DTS config succeeded

- [ ] No config's most recent run is `FAILED` / `CANCELLED`:

  ```sh
  for cfg in "${DTS_CFGS[@]}"; do
    bq --format=prettyjson ls --transfer_run --max_results=1 \
      "projects/$PROJECT/locations/$LOC/transferConfigs/$cfg" \
      | jq -r --arg cfg "$cfg" '.[] | [$cfg, .state, .runTime, .errorStatus.message // ""] | @tsv'
  done
  ```

  Expect `state = SUCCEEDED` on every row. Empty result for weekly configs is
  acceptable if the first Monday run hasn't happened yet.

### 5.4 Post-smoke-test sanity

- [ ] After a Lambda smoke run, trigger the Orders DTS manually and confirm
      `staging_orders` populates:

  ```sh
  bq mk --transfer_run --run_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "projects/$PROJECT/locations/$LOC/transferConfigs/69e86084-0000-294c-9104-94eb2c1b9988"

  # wait ~1 min, then:
  bq query --use_legacy_sql=false \
    'SELECT COUNT(*) AS rows, MAX(updated_at) AS latest FROM peppermayo.staging_orders'
  ```

---

## 6. BigQuery Scheduled Queries — nine queries

Project: `229575872283`. Location: `australia-southeast1`.

### 6.1 All nine scheduled queries present

- [ ] Listing returns exactly these nine `scheduled_query` configs:

  ```sh
  bq ls --transfer_config --transfer_location=australia-southeast1 \
    --max_results=50 --format=prettyjson \
    | jq -r '.[] | select(.dataSourceId=="scheduled_query")
             | [.displayName, (.name | split("/")[-1])] | @tsv' \
    | sort
  ```

  Expect (name → config ID):

  | Display name | Config ID | Expected schedule (UTC) |
  | --- | --- | --- |
  | Daily Shopify Merge - Orders | `69e9381c-0000-24bd-966d-94eb2c1bbc54` | `every day 16:00` |
  | Daily Shopify Merge - Items | `69e9389c-0000-24bd-966d-94eb2c1bbc54` | `every day 16:00` |
  | Daily FX Merge | `69ecec40-0000-220f-b077-94eb2c1bbb4e` | `every day 16:05` |
  | Daily Shopify Merge - Refunds | `69ea6feb-0000-20e7-8554-94eb2c1bbcd4` | `every day 16:10` |
  | Daily Shopify Merge - Refund Items | `69e9bba0-0000-2454-93e7-3c286d400f8a` | `every day 16:10` |
  | Daily Shopify Merge - Fulfillments | `69edafd8-0000-2766-88b4-3c286d33ef46` | `every day 16:10` |
  | Daily Shopify Merge - Fulfillment Items | `69ed4398-0000-2944-a0ca-94eb2c1bb6dc` | `every day 16:10` |
  | Daily Customers Refresh | `69e9ec9f-0000-23a8-90ac-f403045d80ea` | `every day 16:15` |
  | Weekly Products Refresh | `69ea8d00-0000-23ca-9040-94eb2c1b9828` | `every monday 14:45` |

### 6.2 Schedule + SQL body match the repo

- [ ] Audit script prints `displayName`, `schedule`, `disabled`, next run
      time, and the first 120 chars of the query body for each scheduled
      query:

  ```sh
  PROJECT=229575872283
  LOC=australia-southeast1

  SQ_CFGS=(
    "69e9381c-0000-24bd-966d-94eb2c1bbc54::every day 16:00::merge_orders.sql"
    "69e9389c-0000-24bd-966d-94eb2c1bbc54::every day 16:00::merge_items.sql"
    "69ecec40-0000-220f-b077-94eb2c1bbb4e::every day 16:05::merge_fx_rates.sql"
    "69ea6feb-0000-20e7-8554-94eb2c1bbcd4::every day 16:10::merge_refunds.sql"
    "69e9bba0-0000-2454-93e7-3c286d400f8a::every day 16:10::merge_refund_line_items.sql"
    "69edafd8-0000-2766-88b4-3c286d33ef46::every day 16:10::merge_fulfillments.sql"
    "69ed4398-0000-2944-a0ca-94eb2c1bb6dc::every day 16:10::merge_fulfillment_line_items.sql"
    "69e9ec9f-0000-23a8-90ac-f403045d80ea::every day 16:15::refresh_customers_master.sql"
    "69ea8d00-0000-23ca-9040-94eb2c1b9828::every monday 14:45::refresh_products_master.sql"
  )

  for entry in "${SQ_CFGS[@]}"; do
    cfg="${entry%%::*}"
    rest="${entry#*::}"
    expected_sched="${rest%%::*}"
    sql_file="${rest##*::}"
    echo "=== $sql_file (cfg=$cfg, expect: $expected_sched) ==="
    bq --format=prettyjson show --transfer_config "projects/$PROJECT/locations/$LOC/transferConfigs/$cfg" | jq '{displayName, schedule, disabled, nextRunTime, query_head: (.params.query[:120])}'
  done
  ```

  For each block check: `schedule` matches the `expect:` column, `disabled`
  is absent/false, and `query_head` starts with the first line of the
  matching `sql/dml/<file>`.

- [ ] Full body match (byte-for-byte safety net) — re-running the deploy is
      the canonical check. It's idempotent:

  ```sh
  npm run deploy:sql
  ```

  Requires the nine `*_CFG` env vars, e.g.:

  ```sh
  export ORDERS_CFG=projects/229575872283/locations/australia-southeast1/transferConfigs/69e9381c-0000-24bd-966d-94eb2c1bbc54
  export ITEMS_CFG=projects/229575872283/locations/australia-southeast1/transferConfigs/69e9389c-0000-24bd-966d-94eb2c1bbc54
  export FX_CFG=projects/229575872283/locations/australia-southeast1/transferConfigs/69ecec40-0000-220f-b077-94eb2c1bbb4e
  export REFUNDS_CFG=projects/229575872283/locations/australia-southeast1/transferConfigs/69ea6feb-0000-20e7-8554-94eb2c1bbcd4
  export REFUND_ITEMS_CFG=projects/229575872283/locations/australia-southeast1/transferConfigs/69e9bba0-0000-2454-93e7-3c286d400f8a
  export FULFILLMENTS_CFG=projects/229575872283/locations/australia-southeast1/transferConfigs/69edafd8-0000-2766-88b4-3c286d33ef46
  export FULFILLMENT_ITEMS_CFG=projects/229575872283/locations/australia-southeast1/transferConfigs/69ed4398-0000-2944-a0ca-94eb2c1bb6dc
  export CUSTOMERS_CFG=projects/229575872283/locations/australia-southeast1/transferConfigs/69e9ec9f-0000-23a8-90ac-f403045d80ea
  export PRODUCTS_CFG=projects/229575872283/locations/australia-southeast1/transferConfigs/69ea8d00-0000-23ca-9040-94eb2c1b9828
  ```

  (Or hard-code them into `scripts/deploy_scheduled_queries.sh` once.)

### 6.3 Last run of every scheduled query succeeded

- [ ] No query's most recent run is `FAILED`:

  ```sh
  for entry in "${SQ_CFGS[@]}"; do
    cfg="${entry%%::*}"
    name="${entry##*::}"
    bq --format=prettyjson ls --transfer_run --max_results=1 \
      "projects/$PROJECT/locations/$LOC/transferConfigs/$cfg" \
      | jq -r --arg name "$name" '.[] | [$name, .state, .runTime, .errorStatus.message // ""] | @tsv'
  done
  ```

  Expect `state = SUCCEEDED` for every row that exists. Empty output for
  the weekly Products Refresh is acceptable if the first Monday run hasn't
  happened yet — trigger it on-demand from the console to verify wiring.

---

## 7. End-to-end data correctness

Run these after the first full daily cycle completes.

- [ ] Pipeline health shows `fresh` for every region:

  ```sql
  SELECT store_region, orders_freshness, products_freshness,
         days_since_last_fx, fx_coverage_ok, overall_status
  FROM peppermayo.v_pipeline_health;
  ```

  Every `overall_status` should be `fresh`. `fx_coverage_ok` should be TRUE.

- [ ] All five regions are producing orders:

  ```sql
  SELECT store_region, COUNT(*) AS orders, MAX(updated_at) AS last_update
  FROM peppermayo.orders_master
  GROUP BY store_region ORDER BY store_region;
  ```

  Expect rows for `AU`, `US`, `UK`, `CA`, `EU`.

- [ ] Orders ↔ items join integrity (no orphan items):

  ```sql
  SELECT COUNT(*) AS orphan_items
  FROM peppermayo.order_items_master i
  LEFT JOIN peppermayo.orders_master o USING (order_id)
  WHERE o.order_id IS NULL;
  ```

  Expect `0`.

- [ ] FX coverage has an AUD self-row per date with `rate_to_aud = 1.0`:

  ```sql
  SELECT COUNT(*) AS bad_aud_rows
  FROM peppermayo.fx_rates_master
  WHERE currency = 'AUD' AND rate_to_aud != 1.0;
  ```

  Expect `0`.

- [ ] `v_daily_sales` returns non-zero rows for recent days across regions:

  ```sql
  SELECT sales_date, store_region, orders, gross_revenue_aud
  FROM peppermayo.v_daily_sales
  WHERE sales_date >= CURRENT_DATE('Australia/Sydney') - 7
  ORDER BY sales_date DESC, store_region;
  ```

- [ ] `customers_master` rebuilt today and has non-zero AUD LTV:

  ```sql
  SELECT COUNT(*) AS customers,
         MIN(refreshed_at) AS refreshed_at,
         SUM(lifetime_net_revenue_aud) AS total_ltv_aud
  FROM peppermayo.customers_master;
  ```

- [ ] `products_master` / `product_variants_master` rebuilt by most recent
      Monday run and carry rows per region.

---

## 8. Post-launch

- [ ] Trigger one failed Lambda (e.g. temporarily revoke one SSM parameter)
      and confirm the CloudWatch **Errors** alarm fires and emails arrive.
      Restore the parameter afterwards.
- [ ] Document the nine transferConfig IDs in your password manager alongside
      the DTS IAM key (per [INFRA.md](INFRA.md)).
- [ ] Bookmark `SELECT * FROM peppermayo.v_pipeline_health` as the daily
      canary query.
