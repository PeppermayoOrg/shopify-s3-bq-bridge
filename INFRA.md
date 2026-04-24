# Infrastructure credentials

Credentials that are **not** consumed by any code in this repo but which
operators need when (re)configuring the pipeline's infrastructure. Kept here
so the full set of secrets the pipeline depends on is documented in one
place.

None of the values below should be committed. Store them in your password
manager of choice; paste into the relevant AWS / GCP console when wiring
things up.

## BigQuery Data Transfer Service → S3

The two daily DTS configs authenticate to AWS as a dedicated IAM user with
read-only access scoped to the `daily/` prefixes of the
`peppermayo-shopify-orders` bucket. When creating or rotating that user,
you will need:

```
BIGQUERY_KEY_ID=
BIGQUERY_SECRET_ACCESS_KEY=
```

Paste these into the "Access key ID" / "Secret access key" fields of each
transferConfig in the BigQuery console (Data Transfers → edit transfer).

Rotation: create a new access key on the IAM user, update both transfer
configs, confirm the next scheduled run succeeds, then delete the old key.
