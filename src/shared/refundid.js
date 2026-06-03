const { GetParameterCommand, SSMClient } = require("@aws-sdk/client-ssm");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");

const ssm = new SSMClient({});
const s3 = new S3Client({ maxAttempts: 5 });

const REGIONS = ["au", "us", "uk", "ca", "eu"];
const BASE_URL = "https://api.refundid.com/v1/merchant/returns";
const S3_BUCKET = process.env.S3_BUCKET || "peppermayo-shopify-orders";

async function getMerchantToken(region) {
  const command = new GetParameterCommand({
    Name: `/refundid/peppermayo-${region}/token`,
    WithDecryption: true,
  });
  const response = await ssm.send(command);
  return response.Parameter.Value;
}

async function syncDailyRefundid() {
  const endDate = new Date();
  const startDate = new Date();
  startDate.setDate(endDate.getDate() - 1);

  const dateStr = endDate.toISOString().split("T")[0];
  const dateFrom = startDate.toISOString().split("T")[0] + "T00:00:00Z";
  const dateTo = endDate.toISOString().split("T")[0] + "T00:00:00Z";

  for (const region of REGIONS) {
    try {
      const token = await getMerchantToken(region);
      let offset = 0;
      const limit = 100;
      let hasMore = true;
      const collectedRecords = [];

      while (hasMore) {
        const url = new URL(BASE_URL);
        url.searchParams.append("date_from", dateFrom);
        url.searchParams.append("date_to", dateTo);
        url.searchParams.append("limit", limit.toString());
        url.searchParams.append("offset", offset.toString());

        const response = await fetch(url.toString(), {
          method: "GET",
          headers: {
            "x-refundid-api-key": token,
            Accept: "application/json",
          },
        });

        if (!response.ok) {
          throw new Error(
            `Refundid error ${region.toUpperCase()}: ${response.status} ${response.statusText}`,
          );
        }

        const data = await response.json();

        const records = data.returns || data.refunds || [];
        if (records.length > 0) {
          collectedRecords.push(...records);
        }

        hasMore = data.more === true && records.length > 0;
        offset += limit;
      }

      if (collectedRecords.length > 0) {
        const jsonl = collectedRecords
          .map((record) =>
            JSON.stringify({
              raw_json: { ...record, _peppermayo_region: region },
            }),
          )
          .join("\n");

        const s3Key = `daily/refundid/${region}/refundid_${dateStr}.jsonl`;

        await s3.send(
          new PutObjectCommand({
            Bucket: S3_BUCKET,
            Key: s3Key,
            Body: jsonl,
          }),
        );
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
