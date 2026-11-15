#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VIDEO_EXTS = new Set([".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi"]);
const MIME_MAP = {
  ".mp4": "video/mp4",
  ".mov": "video/quicktime",
  ".m4v": "video/x-m4v",
  ".webm": "video/webm",
  ".mkv": "video/x-matroska",
  ".avi": "video/x-msvideo",
};
const PART_SIZE = 25 * 1024 * 1024; // 25 MB per multipart chunk

function loadEnv() {
  const envPath = path.join(__dirname, ".env");
  const out = { ...process.env };
  if (fs.existsSync(envPath)) {
    for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eq = trimmed.indexOf("=");
      if (eq === -1) continue;
      const k = trimmed.slice(0, eq).trim();
      const v = trimmed.slice(eq + 1).trim().replace(/^["']|["']$/g, "");
      if (k) out[k] = v;
    }
  }
  return out;
}

function toBase64Url(buf) {
  return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function formatMB(bytes) {
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

async function encryptFileStreamToBuffer(filePath, key, nonce) {
  const cipher = crypto.createCipheriv("aes-256-ctr", key, nonce);
  const chunks = [];
  for await (const chunk of fs.createReadStream(filePath)) {
    chunks.push(cipher.update(chunk));
  }
  const fin = cipher.final();
  if (fin.length) chunks.push(fin);
  return Buffer.concat(chunks);
}

async function uploadVideo(filePath, workerUrl, secret) {
  const stat = fs.statSync(filePath);
  const filename = path.basename(filePath);
  const ext = path.extname(filename).toLowerCase();
  const contentType = MIME_MAP[ext] || "video/mp4";

  // 32-byte AES key + 16-byte nonce (8 random bytes + 8 zero bytes for 64-bit block counter)
  const key = crypto.randomBytes(32);
  const nonce = Buffer.alloc(16, 0);
  crypto.randomBytes(8).copy(nonce, 0);

  const keyB64Url = toBase64Url(key);
  const nonceB64 = nonce.toString("base64");

  console.log(`\nEncrypting ${filename} (${formatMB(stat.size)}) with AES-256-CTR...`);

  const initRes = await fetch(`${workerUrl}/v1/direct/init`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Direct-Secret": secret,
    },
    body: JSON.stringify({
      filename,
      contentType,
      size: stat.size,
      nonceB64,
    }),
  });
  if (!initRes.ok) {
    throw new Error(`Init failed (${initRes.status}): ${await initRes.text()}`);
  }
  const initData = await initRes.json();
  const { id, multipart, uploadId } = initData;

  if (!multipart) {
    const encBuf = await encryptFileStreamToBuffer(filePath, key, nonce);
    console.log(`Uploading encrypted blob (${formatMB(encBuf.length)}) to R2...`);
    const upRes = await fetch(`${workerUrl}/v1/direct/upload/${id}`, {
      method: "PUT",
      headers: {
        "Content-Type": "application/octet-stream",
        "X-Direct-Secret": secret,
        "X-File-Name": filename,
        "X-Mime-Type": contentType,
        "X-Nonce-B64": nonceB64,
      },
      body: encBuf,
    });
    if (!upRes.ok) {
      throw new Error(`Upload failed (${upRes.status}): ${await upRes.text()}`);
    }
  } else {
    console.log(`Uploading large video in ${Math.ceil(stat.size / PART_SIZE)} encrypted parts...`);
    const cipher = crypto.createCipheriv("aes-256-ctr", key, nonce);
    const parts = [];
    let partNumber = 1;
    let bufAcc = Buffer.alloc(0);

    for await (const rawChunk of fs.createReadStream(filePath, { highWaterMark: 1024 * 1024 })) {
      const encChunk = cipher.update(rawChunk);
      bufAcc = Buffer.concat([bufAcc, encChunk]);
      while (bufAcc.length >= PART_SIZE) {
        const partBuf = bufAcc.subarray(0, PART_SIZE);
        bufAcc = bufAcc.subarray(PART_SIZE);
        const pRes = await fetch(`${workerUrl}/v1/direct/part/${id}?uploadId=${encodeURIComponent(uploadId)}&partNumber=${partNumber}`, {
          method: "PUT",
          headers: {
            "Content-Type": "application/octet-stream",
            "X-Direct-Secret": secret,
          },
          body: partBuf,
        });
        if (!pRes.ok) throw new Error(`Part ${partNumber} failed (${pRes.status}): ${await pRes.text()}`);
        const pJson = await pRes.json();
        parts.push({ partNumber: pJson.partNumber, etag: pJson.etag });
        console.log(`  Uploaded part ${partNumber}`);
        partNumber++;
      }
    }

    const fin = cipher.final();
    if (fin.length) bufAcc = Buffer.concat([bufAcc, fin]);
    if (bufAcc.length > 0) {
      const pRes = await fetch(`${workerUrl}/v1/direct/part/${id}?uploadId=${encodeURIComponent(uploadId)}&partNumber=${partNumber}`, {
        method: "PUT",
        headers: {
          "Content-Type": "application/octet-stream",
          "X-Direct-Secret": secret,
        },
        body: bufAcc,
      });
      if (!pRes.ok) throw new Error(`Final part ${partNumber} failed (${pRes.status}): ${await pRes.text()}`);
      const pJson = await pRes.json();
      parts.push({ partNumber: pJson.partNumber, etag: pJson.etag });
      console.log(`  Uploaded part ${partNumber}`);
    }

    const compRes = await fetch(`${workerUrl}/v1/direct/complete/${id}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Direct-Secret": secret,
      },
      body: JSON.stringify({ uploadId, parts, filename, contentType, size: stat.size, nonceB64 }),
    });
    if (!compRes.ok) {
      throw new Error(`Complete failed (${compRes.status}): ${await compRes.text()}`);
    }
  }

  const watchUrl = `${workerUrl}/d/${id}?k=${keyB64Url}`;
  const downloadUrl = `${workerUrl}/d/${id}/download?k=${keyB64Url}`;

  const uploadedDir = path.join(__dirname, "uploaded");
  fs.mkdirSync(uploadedDir, { recursive: true });
  fs.renameSync(filePath, path.join(uploadedDir, filename));

  const logLine = `[${new Date().toISOString()}] ${filename}\n  Watch + Download: ${watchUrl}\n  Direct Download:  ${downloadUrl}\n\n`;
  fs.appendFileSync(path.join(__dirname, "links.txt"), logLine, "utf8");

  console.log(`Done! Moved original to DirectStuff/uploaded/${filename}`);
  console.log(`  Watch + Download URL: ${watchUrl}`);
  console.log(`  Direct Download URL:  ${downloadUrl}`);
}

async function processPending(workerUrl, secret) {
  const entries = fs.readdirSync(__dirname, { withFileTypes: true });
  for (const ent of entries) {
    if (!ent.isFile()) continue;
    const ext = path.extname(ent.name).toLowerCase();
    if (!VIDEO_EXTS.has(ext)) continue;
    const full = path.join(__dirname, ent.name);
    try {
      await uploadVideo(full, workerUrl, secret);
    } catch (err) {
      console.error(`Failed uploading ${ent.name}:`, err.message);
    }
  }
}

async function main() {
  const env = loadEnv();
  const workerUrl = (env.WORKER_URL || "https://tinytiny-license.aokifrlol.workers.dev").replace(/\/+$/, "");
  const secret = env.DIRECT_UPLOAD_SECRET || env.WEBHOOK_SECRET || "";
  if (!secret) {
    console.error("Missing DIRECT_UPLOAD_SECRET in DirectStuff/.env (copy DirectStuff/.env.example to DirectStuff/.env).");
    process.exit(1);
  }

  await processPending(workerUrl, secret);

  if (process.argv.includes("--watch")) {
    console.log(`\nWatching ${__dirname} for new videos... (Ctrl+C to stop)`);
    let timer = null;
    fs.watch(__dirname, () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        processPending(workerUrl, secret).catch((e) => console.error(e));
      }, 1500);
    });
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
