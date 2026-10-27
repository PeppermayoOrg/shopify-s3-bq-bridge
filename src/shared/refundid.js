const { GetParameterCommand, SSMClient } = require("@aws-sdk/client-ssm");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");

const ssm = new SSMClient({});
const s3 = new S3Client({ maxAttempts: 5 });

const REGIONS = ["au", "us", "uk", "ca", "eu"];
const BASE_URL = "https://api.refundid.com/v1/merchant/returns";
const S3_BUCKET = process.env.S3_BUCKET || "peppermayo-shopify-orders";
const PAGE_SIZE = 200;

async function getMerchantToken(region) {
  const command = new GetParameterCommand({
    Name: `/refundid/peppermayo-${region}/token`,
    WithDecryption: true,
  });
  const response = await ssm.send(command);
  return response.Parameter.Value;
}

// Every page of returns for one query (dateType LODGED = created in the window, UPDATED = whose status or
// tracking status changed in the window). The API takes whole dates in the store's timezone, date_to inclusive.
async function fetchReturns(region, token, dateType, dateFrom, dateTo) {
  const records = [];
  let offset = 0;
  let hasMore = true;
  while (hasMore) {
    const url = new URL(BASE_URL);
    url.searchParams.append("date_type", dateType);
    url.searchParams.append("date_from", dateFrom);
    url.searchParams.append("date_to", dateTo);
    url.searchParams.append("limit", PAGE_SIZE.toString());
    url.searchParams.append("offset", offset.toString());

    console.log(`[refundid/${region}] ${dateType} limit=${PAGE_SIZE} offset=${offset}...`);

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 30000);
    const response = await fetch(url.toString(), {
      method: "GET",
      headers: {
        "x-refundid-api-key": token,
        Accept: "application/json",
      },
      signal: controller.signal,
    });
    clearTimeout(timeoutId);

    if (!response.ok) {
      throw new Error(
        `Refundid error ${region.toUpperCase()} (${dateType}): ${response.status} ${response.statusText}`,
      );
    }

    const data = await response.json();
    const page = data.returns || data.refunds || [];
    console.log(`[refundid/${region}] ${dateType} received ${page.length} records. hasMore=${data.more}`);
    records.push(...page);
    hasMore = data.more === true && page.length > 0;
    offset += PAGE_SIZE;
  }
  return records;
}

// Returns created yesterday or today, plus every return whose status or tracking status changed yesterday or today
// (the overlap means a late or retried run never leaves a gap), so tracking updates (in transit, delivered, lost)
// reach BigQuery after a return's first day. Each record carries
// _peppermayo_fetched_at; the merge keeps the most recently fetched copy of a return.
// `options.lodgedDays` re-pulls every return created in the last N days instead (one-off catch-up).
async function syncDailyRefundid(options = {}) {
  const endDate = new Date();
  const startDate = new Date();
  startDate.setDate(endDate.getDate() - (options.lodgedDays || 1));

  const dateStr = endDate.toISOString().split("T")[0];
  const fetchedAt = endDate.toISOString();
  const dateFrom = startDate.toISOString().split("T")[0];
  const yesterday = new Date(endDate.getTime() - 24 * 60 * 60 * 1000).toISOString().split("T")[0];

  for (const region of REGIONS) {
    try {
      console.log(`[refundid/${region}] fetching token from SSM...`);
      const token = await getMerchantToken(region);
      const lodged = await fetchReturns(region, token, "LODGED", dateFrom, dateStr);
      const updated = options.lodgedDays ? [] : await fetchReturns(region, token, "UPDATED", yesterday, dateStr);
      const byId = new Map();
      for (const record of [...lodged, ...updated]) {
        byId.set(record.standard_return_id || record.refundid_id || record.rma_ref, record);
      }
      const collectedRecords = [...byId.values()];
      console.log(`[refundid/${region}] ${lodged.length} lodged + ${updated.length} updated = ${collectedRecords.length} returns`);

      if (collectedRecords.length > 0) {
        const jsonl = collectedRecords
          .map((record) =>
            JSON.stringify({
              raw_json: { ...record, _peppermayo_region: region, _peppermayo_fetched_at: fetchedAt },
            }),
          )
          .join("\n");

        // The DTS reloads every file under daily/refundid/ each night, so a catch-up gets its own file name.
        const s3Key = `daily/refundid/${region}/refundid_${dateStr}${options.lodgedDays ? `_last${options.lodgedDays}d` : ""}.jsonl`;

        console.log(`[refundid/${region}] uploading ${collectedRecords.length} records to S3 at ${s3Key}...`);
        await s3.send(
          new PutObjectCommand({
            Bucket: S3_BUCKET,
            Key: s3Key,
            Body: jsonl,
          }),
        );
        console.log(`[refundid/${region}] S3 upload complete.`);
      } else {
        console.log(`[refundid/${region}] no records to upload.`);
      }
    } catch (error) {
      console.error(
        `Failed execution for region ${region.toUpperCase()}:`,
        error,
      );
      throw error;
    }
  }
}

module.exports = {
  syncDailyRefundid,
};
