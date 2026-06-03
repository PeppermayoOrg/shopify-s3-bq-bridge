const fs = require("fs");
const os = require("os");
const path = require("path");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
require("dotenv").config();

const REGIONS = ["au", "us", "uk", "ca", "eu"];
const BASE_URL = "https://api.refundid.com/v1/merchant/returns";
const s3 = new S3Client({ maxAttempts: 5 });

async function executeLocalBackfill(startDateIso, endDateIso) {
  for (const region of REGIONS) {
    const token = process.env[`REFUNDID_TOKEN_${region.toUpperCase()}`];
    if (!token) continue;

    console.log(
      `\n=== Processing historical run for region: ${region.toUpperCase()} ===`,
    );

    let currentStart = new Date(startDateIso);
    const finalEnd = new Date(endDateIso);

    while (currentStart < finalEnd) {
      let currentEnd = new Date(currentStart);
      currentEnd.setDate(currentEnd.getDate() + 30);
      if (currentEnd > finalEnd) currentEnd = finalEnd;

      const dateFrom = currentStart.toISOString().split("T")[0] + "T00:00:00Z";
      const dateTo = currentEnd.toISOString().split("T")[0] + "T00:00:00Z";

      console.log(`Fetching window: ${dateFrom} -> ${dateTo}`);

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
          headers: { "x-refundid-api-key": token },
        });

        if (!response.ok) {
          const errorText = await response.text();
          throw new Error(
            `API Failure ${response.status}: ${errorText}\nURL: ${url.toString()}`,
          );
        }

        const data = await response.json();
        const records = data.returns || data.refunds || [];

        if (records.length > 0) {
          collectedRecords.push(...records);
        }

        hasMore = data.more === true && records.length > 0;
        offset += limit;

        await new Promise((resolve) => setTimeout(resolve, 250)); // Throttling
      }

      if (collectedRecords.length > 0) {
        const jsonl = collectedRecords
          .map((record) =>
            JSON.stringify({
              raw_json: { ...record, _peppermayo_region: region },
            }),
          )
          .join("\n");

        const fileSafeStart = dateFrom.split("T")[0];
        const fileSafeEnd = dateTo.split("T")[0];
        const tmpFile = path.join(
          os.tmpdir(),
          `refundid_hist_${region}_${fileSafeStart}.jsonl`,
        );

        fs.writeFileSync(tmpFile, jsonl);

        const s3Key = `historical/refundid/${region}/refundid_historical_${fileSafeStart}_to_${fileSafeEnd}.jsonl`;

        await s3.send(
          new PutObjectCommand({
            Bucket: process.env.S3_BUCKET || "peppermayo-shopify-orders",
            Key: s3Key,
            Body: fs.createReadStream(tmpFile),
          }),
        );

        console.log(
          `Successfully uploaded ${collectedRecords.length} historical rows to S3 path: ${s3Key}`,
        );
      } else {
        console.log(`No records found for this window.`);
      }

      currentStart = currentEnd;
    }
  }
}

executeLocalBackfill("2025-01-01T00:00:00Z", "2026-06-30T23:59:59Z").catch(
  console.error,
);
