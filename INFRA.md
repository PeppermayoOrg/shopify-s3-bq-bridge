# Infrastructure credentials

Credentials that are **not** consumed by any code in this repo but which
operators need when (re)configuring the pipeline's infrastructure. Kept here
so the full set of secrets the pipeline depends on is documented in one
place.

None of the values below should be committed. Store them in your password
manager of choice; paste into the relevant AWS / GCP console when wiring
things up.

## BigQuery Data Transfer Service → S3

The nine DTS configs (seven daily: orders, items, refunds, refund_items,
fulfillments, fulfillment_items, FX; two weekly: products, product_variants)
authenticate to AWS as a dedicated IAM user with read-only access scoped to
the `daily/`, `weekly/`, and `historical/` prefixes of the
`peppermayo-shopify-orders` bucket. Specifically the user needs
`s3:GetObject` / `s3:ListBucket` on:

- `daily/orders/*`, `daily/items/*`, `daily/refunds/*`,
  `daily/refund_items/*`, `daily/fulfillments/*`,
  `daily/fulfillment_items/*`, `daily/fx/*`
- `weekly/products/*`, `weekly/product_variants/*`
- `historical/orders/*`, `historical/items/*`, `historical/refunds/*`,
  `historical/refund_items/*`, `historical/fulfillments/*`,
  `historical/fulfillment_items/*`, `historical/fx/*`

When creating or rotating that user, you will need:

```text
BIGQUERY_KEY_ID=
BIGQUERY_SECRET_ACCESS_KEY=
```

Paste these into the "Access key ID" / "Secret access key" fields of each
transferConfig in the BigQuery console (Data Transfers → edit transfer).

Rotation: create a new access key on the IAM user, update all transfer
configs, confirm the next scheduled run succeeds, then delete the old key.

## CloudWatch alarm on Lambda failures

Without an alarm, a silently-failing Lambda produces stale or missing
data for 24 hours before anyone notices. Wire up an SNS-backed alarm so
one failed invocation pages someone.

### 1. SNS topic + email subscription

```sh
# Create topic
aws sns create-topic --name shopify-s3-bq-bridge-alerts

# Subscribe an email (confirm via the email SNS sends)
aws sns subscribe \
  --topic-arn arn:aws:sns:<region>:<account-id>:shopify-s3-bq-bridge-alerts \
  --protocol email \
  --notification-endpoint ritchie.v@peppermayo.com.au
```

### 2. Alarm on the Lambda's `Errors` metric

```sh
aws cloudwatch put-metric-alarm \
  --alarm-name shopify-s3-bq-bridge-lambda-errors \
  --alarm-description "Fires when the daily or weekly Shopify Lambda throws any error." \
  --metric-name Errors \
  --namespace AWS/Lambda \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 0 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --dimensions Name=FunctionName,Value=<lambda-function-name> \
  --alarm-actions arn:aws:sns:<region>:<account-id>:shopify-s3-bq-bridge-alerts
```

Any `Errors > 0` in a 5-minute window triggers. `treat-missing-data
notBreaching` means a quiet period (no invocations, e.g. between the
daily and weekly windows) does not trip the alarm — we only care about
invocations that actually ran and failed.

### 3. (Optional) Second alarm for no-invocation

If the EventBridge rule itself gets disabled or deleted, `Errors` stays
at zero and the first alarm won't fire. A second alarm catches this:

```sh
aws cloudwatch put-metric-alarm \
  --alarm-name shopify-s3-bq-bridge-lambda-no-invocations \
  --alarm-description "Fires if the daily Shopify Lambda hasn't run in ~28h." \
  --metric-name Invocations \
  --namespace AWS/Lambda \
  --statistic Sum \
  --period 3600 \
  --evaluation-periods 28 \
  --threshold 1 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --dimensions Name=FunctionName,Value=<lambda-function-name> \
  --alarm-actions arn:aws:sns:<region>:<account-id>:shopify-s3-bq-bridge-alerts
```

The 28-hour evaluation window accommodates the daily cron's natural
jitter without flapping. For pipeline-freshness checks from inside
BigQuery, query `peppermayo.v_pipeline_health`.
