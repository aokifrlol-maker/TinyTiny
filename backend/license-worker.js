/**
 * TinyTiny License + Zero-Knowledge Backup + Encrypted Share Drop Worker
 * Deploy on Cloudflare Workers (free tier) with a bound KV namespace `LICENSES`.
 *
 * Required Wrangler Secrets (never commit secrets into source control!):
 *   wrangler secret put TELEGRAM_BOT_TOKEN
 *   wrangler secret put ADMIN_USER_ID
 *   wrangler secret put WEBHOOK_SECRET
 */

const DAY_SEC = 86400;

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, PUT, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, X-License-Key, X-Device-Id, X-File-Name",
    },
  });
}

function nowSec() {
  return Math.floor(Date.now() / 1000);
}

function parseDuration(raw) {
  const token = String(raw || "").trim().toLowerCase();
  if (!token || token === "lifetime" || token === "perm" || token === "forever") {
    return { lifetime: true, seconds: null, label: "Lifetime" };
  }
  const match = token.match(/^(\d+)(m|h|d|w|mo|y)$/);
  if (!match) return null;
  const n = parseInt(match[1], 10);
  const unit = match[2];
  if (n <= 0) return null;
  const mult = {
    m: 60,
    h: 3600,
    d: DAY_SEC,
    w: 7 * DAY_SEC,
    mo: 30 * DAY_SEC,
    y: 365 * DAY_SEC,
  }[unit];
  const labelMap = {
    m: `${n} Min`,
    h: `${n} Hour${n > 1 ? "s" : ""}`,
    d: `${n} Day${n > 1 ? "s" : ""}`,
    w: `${n} Week${n > 1 ? "s" : ""}`,
    mo: `${n} Month${n > 1 ? "s" : ""}`,
    y: `${n} Year${n > 1 ? "s" : ""}`,
  };
  return { lifetime: false, seconds: n * mult, label: labelMap[unit] };
}

function generateLicenseKey() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  const seg = (start, len) =>
    Array.from(bytes.slice(start, start + len), (b) => alphabet[b % alphabet.length]).join("");
  return `TT-${seg(0, 4)}-${seg(4, 4)}-${seg(8, 4)}`;
}

function randomId(len = 12) {
  const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
  const bytes = new Uint8Array(len);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
}

function formatRemaining(rec) {
  if (rec.revoked) return "REVOKED";
  if (rec.lifetime) return "Lifetime";
  if (!rec.activatedAt) return `${rec.durationLabel} (unused)`;
  const rem = (rec.expiresAt || 0) - nowSec();
  if (rem <= 0) return "EXPIRED";
  const d = Math.floor(rem / DAY_SEC);
  const h = Math.floor((rem % DAY_SEC) / 3600);
  if (d > 0) return `${d}d ${h}h left`;
  const m = Math.max(1, Math.floor((rem % 3600) / 60));
  return `${h}h ${m}m left`;
}

async function getLicense(env, rawKey) {
  const key = String(rawKey || "").trim().toUpperCase();
  if (!key) return null;
  const raw = await env.LICENSES.get(`lic:${key}`);
  return raw ? JSON.parse(raw) : null;
}

async function saveLicense(env, rec) {
  await env.LICENSES.put(`lic:${rec.key}`, JSON.stringify(rec));
}

function validateRecordAccess(rec, deviceId) {
  if (!rec) return { ok: false, error: "License key not found." };
  if (rec.revoked) return { ok: false, error: "This license key has been revoked." };
  if (!rec.lifetime && rec.activatedAt && rec.expiresAt && nowSec() >= rec.expiresAt) {
    return { ok: false, error: "License key has expired." };
  }
  const dev = String(deviceId || "").trim();
  const devices = Array.isArray(rec.deviceIds) ? rec.deviceIds : [];
  if (dev && !devices.includes(dev)) {
    const cap = Math.max(1, rec.maxDevices || 1);
    if (devices.length >= cap) {
      return {
        ok: false,
        error: `Key already active on ${devices.length}/${cap} device(s). Ask admin for /unbind.`,
      };
    }
  }
  return { ok: true };
}

async function sendTelegram(env, chatId, text) {
  if (!env.TELEGRAM_BOT_TOKEN) return;
  await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      chat_id: chatId,
      text,
      parse_mode: "HTML",
      disable_web_page_preview: true,
    }),
  });
}

async function handleTelegramUpdate(env, update) {
  const msg = update?.message;
  if (!msg || !msg.text) return new Response("ok");
  const chatId = msg.chat.id;
  const senderId = String(msg.from?.id || chatId);
  const text = msg.text.trim();
  const parts = text.split(/\s+/);
  const cmd = parts[0].split("@")[0].toLowerCase();

  if (cmd === "/myid" || cmd === "/start") {
    const adminConfigured = Boolean(env.ADMIN_USER_ID);
    const isAdmin = adminConfigured && String(env.ADMIN_USER_ID) === senderId;
    if (!adminConfigured || !isAdmin) {
      await sendTelegram(
        env,
        chatId,
        `Your Telegram User ID is: <code>${senderId}</code>\n` +
          (adminConfigured
            ? "Unauthorized: this bot only responds to its configured admin."
            : "Set this ID via: <code>wrangler secret put ADMIN_USER_ID</code>")
      );
      return new Response("ok");
    }
  }

  if (!env.ADMIN_USER_ID || String(env.ADMIN_USER_ID) !== senderId) {
    return new Response("ok");
  }

  if (cmd === "/start" || cmd === "/help") {
    await sendTelegram(
      env,
      chatId,
      [
        "<b>TinyTiny License Admin</b>",
        "<code>/gen 30d [maxDevices] [note]</code> — Create key (e.g. 12h, 7d, 30d, 1y, lifetime)",
        "<code>/info TT-XXXX-XXXX-XXXX</code> — Inspect key",
        "<code>/list</code> — Recent license keys",
        "<code>/extend TT-XXXX-XXXX-XXXX 30d</code> — Add duration",
        "<code>/unbind TT-XXXX-XXXX-XXXX</code> — Reset device lock",
        "<code>/revoke TT-XXXX-XXXX-XXXX</code> — Revoke key",
      ].join("\n")
    );
    return new Response("ok");
  }

  if (cmd === "/gen") {
    const durSpec = parseDuration(parts[1] || "30d");
    if (!durSpec) {
      await sendTelegram(
        env,
        chatId,
        "Invalid duration. Examples: <code>/gen 24h</code>, <code>/gen 7d</code>, <code>/gen 30d 2 Friend</code>, <code>/gen lifetime</code>"
      );
      return new Response("ok");
    }
    let maxDevices = 1;
    let noteStart = 2;
    if (parts[2] && /^\d+$/.test(parts[2])) {
      maxDevices = Math.min(10, Math.max(1, parseInt(parts[2], 10)));
      noteStart = 3;
    }
    const note = parts.slice(noteStart).join(" ");
    const key = generateLicenseKey();
    const rec = {
      key,
      lifetime: durSpec.lifetime,
      durationSeconds: durSpec.seconds,
      durationLabel: durSpec.label,
      maxDevices,
      note,
      createdAt: nowSec(),
      activatedAt: null,
      expiresAt: null,
      deviceIds: [],
      revoked: false,
    };
    await saveLicense(env, rec);

    const idxRaw = await env.LICENSES.get("index:recent");
    const idx = idxRaw ? JSON.parse(idxRaw) : [];
    idx.unshift(key);
    await env.LICENSES.put("index:recent", JSON.stringify(idx.slice(0, 60)));

    await sendTelegram(
      env,
      chatId,
      `<b>New License Key</b>\nKey: <code>${key}</code>\nDuration: <b>${durSpec.label}</b> (starts on first activation)\nMax Devices: ${maxDevices}` +
        (note ? `\nNote: ${note}` : "")
    );
    return new Response("ok");
  }

  if (cmd === "/info") {
    const rec = await getLicense(env, parts[1]);
    if (!rec) {
      await sendTelegram(env, chatId, "Key not found.");
      return new Response("ok");
    }
    await sendTelegram(
      env,
      chatId,
      [
        `<b>${rec.key}</b>`,
        `Status: <b>${formatRemaining(rec)}</b>`,
        `Devices: ${(rec.deviceIds || []).length}/${rec.maxDevices || 1}`,
        rec.note ? `Note: ${rec.note}` : null,
      ]
        .filter(Boolean)
        .join("\n")
    );
    return new Response("ok");
  }

  if (cmd === "/list") {
    const idxRaw = await env.LICENSES.get("index:recent");
    const idx = idxRaw ? JSON.parse(idxRaw) : [];
    if (idx.length === 0) {
      await sendTelegram(env, chatId, "No keys created yet. Send <code>/gen 30d</code>");
      return new Response("ok");
    }
    const lines = [];
    for (const k of idx.slice(0, 20)) {
      const rec = await getLicense(env, k);
      if (rec) {
        lines.push(`<code>${rec.key}</code> — ${formatRemaining(rec)}${rec.note ? ` (${rec.note})` : ""}`);
      }
    }
    await sendTelegram(env, chatId, `<b>Recent Keys</b>\n${lines.join("\n")}`);
    return new Response("ok");
  }

  if (cmd === "/extend") {
    const rec = await getLicense(env, parts[1]);
    const durSpec = parseDuration(parts[2]);
    if (!rec || !durSpec) {
      await sendTelegram(env, chatId, "Usage: <code>/extend TT-XXXX-XXXX-XXXX 30d</code>");
      return new Response("ok");
    }
    if (durSpec.lifetime) {
      rec.lifetime = true;
      rec.expiresAt = null;
      rec.durationLabel = "Lifetime";
    } else if (rec.activatedAt) {
      const base = Math.max(nowSec(), rec.expiresAt || nowSec());
      rec.lifetime = false;
      rec.expiresAt = base + durSpec.seconds;
      rec.durationLabel = `${rec.durationLabel} + ${durSpec.label}`;
    } else {
      rec.lifetime = false;
      rec.durationSeconds = (rec.durationSeconds || 0) + durSpec.seconds;
      rec.durationLabel = `${rec.durationLabel} + ${durSpec.label}`;
    }
    await saveLicense(env, rec);
    await sendTelegram(env, chatId, `Extended <code>${rec.key}</code> -> <b>${formatRemaining(rec)}</b>`);
    return new Response("ok");
  }

  if (cmd === "/unbind") {
    const rec = await getLicense(env, parts[1]);
    if (!rec) {
      await sendTelegram(env, chatId, "Key not found.");
      return new Response("ok");
    }
    rec.deviceIds = [];
    await saveLicense(env, rec);
    await sendTelegram(env, chatId, `Unbound all devices from <code>${rec.key}</code>.`);
    return new Response("ok");
  }

  if (cmd === "/revoke") {
    const rec = await getLicense(env, parts[1]);
    if (!rec) {
      await sendTelegram(env, chatId, "Key not found.");
      return new Response("ok");
    }
    rec.revoked = true;
    await saveLicense(env, rec);
    await sendTelegram(env, chatId, `Revoked <code>${rec.key}</code>.`);
    return new Response("ok");
  }

  return new Response("ok");
}

const SEEDR_DAV_BASE = "https://dav.seedr.cc";
const SEEDR_DAV_DIR = "tt_drops";

function seedrAuthHeader(env) {
  if (!env.SEEDR_EMAIL || !env.SEEDR_PASSWORD) return null;
  return "Basic " + btoa(`${env.SEEDR_EMAIL}:${env.SEEDR_PASSWORD}`);
}

async function seedrUploadEncryptedBlob(env, id, buf) {
  const auth = seedrAuthHeader(env);
  if (!auth) return null;

  const dirUrl = `${SEEDR_DAV_BASE}/${SEEDR_DAV_DIR}/`;
  await fetch(dirUrl, { method: "MKCOL", headers: { Authorization: auth } }).catch(() => null);

  const relPath = `${SEEDR_DAV_DIR}/${id}.ttenc`;
  const fileUrl = `${SEEDR_DAV_BASE}/${relPath}`;
  const putResp = await fetch(fileUrl, {
    method: "PUT",
    headers: {
      Authorization: auth,
      "Content-Type": "application/octet-stream",
    },
    body: buf,
  });

  // SabreDAV on dav.seedr.cc can return 404 on PUT even when the object lands cleanly,
  // so verify object readability before accepting or falling back to KV.
  if (putResp.status >= 200 && putResp.status < 300) {
    return relPath;
  }
  const headResp = await fetch(fileUrl, { method: "HEAD", headers: { Authorization: auth } }).catch(() => null);
  if (headResp && headResp.status >= 200 && headResp.status < 300) {
    return relPath;
  }
  const probeResp = await fetch(fileUrl, {
    method: "GET",
    headers: { Authorization: auth, Range: "bytes=0-0" },
  }).catch(() => null);
  if (probeResp && (probeResp.status === 200 || probeResp.status === 206)) {
    return relPath;
  }
  return null;
}

async function seedrFetchEncryptedBlob(env, relPath) {
  const auth = seedrAuthHeader(env);
  if (!auth || !relPath) return null;
  const resp = await fetch(`${SEEDR_DAV_BASE}/${relPath}`, {
    method: "GET",
    headers: { Authorization: auth },
  }).catch(() => null);
  if (!resp || resp.status < 200 || resp.status >= 300) return null;
  return resp;
}

function renderShareLandingHTML(shareId) {
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>TinyTiny Encrypted Drop</title>
<style>
  body { margin:0; background:#09090d; color:#fff; font-family:-apple-system,BlinkMacSystemFont,sans-serif; display:flex; align-items:center; justify-content:center; min-height:100vh; }
  .card { max-width:420px; width:90%; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.16); border-radius:24px; padding:28px; text-align:center; }
  h1 { font-size:22px; margin:0 0 8px; }
  p { font-size:14px; color:rgba(255,255,255,0.7); line-height:1.45; }
  a.btn, button.btn { display:block; width:100%; box-sizing:border-box; margin-top:14px; padding:14px 18px; border-radius:999px; border:none; background:#e93b78; color:#fff; font-weight:700; font-size:15px; text-decoration:none; cursor:pointer; }
  button.secondary { background:rgba(255,255,255,0.12); }
</style>
</head>
<body>
  <div class="card">
    <h1>Encrypted TinyTiny Drop</h1>
    <p>This drop is end-to-end encrypted with AES-256-GCM. The decryption key stays strictly inside your link fragment and never reaches the server.</p>
    <a id="openBtn" class="btn" href="#">Open in TinyTiny</a>
    <button id="copyBtn" class="btn secondary">Copy Drop Code</button>
  </div>
  <script>
    const hash = location.hash || "";
    const deep = "tinytiny://drop/${shareId}" + hash;
    document.getElementById("openBtn").href = deep;
    const k = hash.startsWith("#k=") ? hash.slice(3) : "";
    const code = k ? "TTDROP:${shareId}." + k : deep;
    document.getElementById("copyBtn").onclick = async () => {
      await navigator.clipboard.writeText(code);
      document.getElementById("copyBtn").textContent = "Copied!";
    };
  </script>
</body>
</html>`;
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return json({ ok: true }, 204);
    }

    const url = new URL(request.url);
    const path = url.pathname;

    // 1. Telegram Admin Bot Webhook
    if (request.method === "POST" && env.WEBHOOK_SECRET && path === `/telegram/${env.WEBHOOK_SECRET}`) {
      const update = await request.json().catch(() => null);
      return await handleTelegramUpdate(env, update);
    }

    // 2. License Activation (countdown begins on first activation!)
    if (request.method === "POST" && path === "/v1/activate") {
      const body = await request.json().catch(() => ({}));
      const rec = await getLicense(env, body.key);
      const check = validateRecordAccess(rec, body.deviceId);
      if (!check.ok) return json({ valid: false, error: check.error }, 403);

      const dev = String(body.deviceId || "").trim();
      let changed = false;
      if (!rec.activatedAt) {
        rec.activatedAt = nowSec();
        rec.expiresAt = rec.lifetime ? null : rec.activatedAt + (rec.durationSeconds || 30 * DAY_SEC);
        changed = true;
      }
      if (dev && !(rec.deviceIds || []).includes(dev)) {
        rec.deviceIds = [...(rec.deviceIds || []), dev];
        changed = true;
      }
      if (changed) await saveLicense(env, rec);

      return json({
        valid: true,
        lifetime: Boolean(rec.lifetime),
        expiresAt: rec.expiresAt,
        durationLabel: rec.durationLabel,
      });
    }

    // 3. Silent Verification
    if (request.method === "POST" && path === "/v1/verify") {
      const body = await request.json().catch(() => ({}));
      const rec = await getLicense(env, body.key);
      const check = validateRecordAccess(rec, body.deviceId);
      if (!check.ok) return json({ valid: false, error: check.error }, 200);
      return json({
        valid: true,
        lifetime: Boolean(rec.lifetime),
        expiresAt: rec.expiresAt,
        durationLabel: rec.durationLabel,
      });
    }

    // 4. Zero-Knowledge Encrypted Profile Sync (Client-encrypted Likes/Follows/Seedr Key)
    if (request.method === "PUT" && path === "/v1/backup") {
      const body = await request.json().catch(() => ({}));
      const rec = await getLicense(env, body.key);
      const check = validateRecordAccess(rec, body.deviceId);
      if (!check.ok) return json({ error: check.error }, 403);
      if (!body.blob || typeof body.blob !== "string") return json({ error: "Missing blob" }, 400);

      await env.LICENSES.put(`backup:${rec.key}`, body.blob);
      return json({ ok: true });
    }

    if (request.method === "POST" && path === "/v1/backup/get") {
      const body = await request.json().catch(() => ({}));
      const rec = await getLicense(env, body.key);
      const check = validateRecordAccess(rec, body.deviceId);
      if (!check.ok) return json({ error: check.error }, 403);

      const blob = await env.LICENSES.get(`backup:${rec.key}`);
      if (!blob) return json({ error: "No backup yet" }, 404);
      return json({ blob });
    }

    // 5. E2EE Peer-to-Peer Share Drops (7-day TTL, stores strictly ciphertext)
    if (request.method === "POST" && path === "/v1/share") {
      const body = await request.json().catch(() => ({}));
      const rec = await getLicense(env, body.key);
      const check = validateRecordAccess(rec, null);
      if (!check.ok) return json({ error: check.error }, 403);
      if (!body.cipher || typeof body.cipher !== "string") return json({ error: "Missing cipher" }, 400);

      const id = randomId(10);
      await env.LICENSES.put(`share:${id}`, body.cipher, { expirationTtl: 7 * DAY_SEC });
      return json({ id });
    }

    if (request.method === "GET" && path.startsWith("/v1/share/")) {
      const id = path.slice("/v1/share/".length).replace(/[^a-z0-9]/gi, "");
      const cipher = id ? await env.LICENSES.get(`share:${id}`) : null;
      if (!cipher) return json({ error: "Not found or expired" }, 404);
      return json({ cipher });
    }

    if (request.method === "GET" && path.startsWith("/s/")) {
      const id = path.slice("/s/".length).replace(/[^a-z0-9]/gi, "");
      return new Response(renderShareLandingHTML(id), {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    // 6. Hidden Encrypted Binary File Blob Relay (AES-256-GCM ciphertext only; 7-day TTL via Seedr WebDAV up to 95MB, or <= 24MB KV fallback)
    if (request.method === "POST" && path === "/v1/blob") {
      const licKey = request.headers.get("X-License-Key");
      const devId = request.headers.get("X-Device-Id");
      const rec = await getLicense(env, licKey);
      const check = validateRecordAccess(rec, devId);
      if (!check.ok) return json({ error: check.error }, 403);

      const buf = await request.arrayBuffer();
      if (!buf || buf.byteLength === 0 || buf.byteLength > 95 * 1024 * 1024) {
        return json({ error: "Blob empty or exceeds 95MB relay cap" }, 400);
      }

      const id = randomId(14);
      const seedrPath = await seedrUploadEncryptedBlob(env, id, buf);
      if (seedrPath) {
        await env.LICENSES.put(
          `meta:blob:${id}`,
          JSON.stringify({ backend: "seedr", path: seedrPath, bytes: buf.byteLength }),
          { expirationTtl: 7 * DAY_SEC }
        );
        return json({ id, url: `${url.origin}/v1/blob/${id}` });
      }

      if (buf.byteLength > 24 * 1024 * 1024) {
        return json({ error: "Encrypted storage backend unavailable for >24MB blob" }, 503);
      }
      await env.LICENSES.put(`blob:${id}`, buf, { expirationTtl: 7 * DAY_SEC });
      return json({ id, url: `${url.origin}/v1/blob/${id}` });
    }

    if (request.method === "GET" && path.startsWith("/v1/blob/")) {
      const id = path.slice("/v1/blob/".length).replace(/[^a-z0-9]/gi, "");
      if (!id) return json({ error: "Not found or expired" }, 404);

      const metaRaw = await env.LICENSES.get(`meta:blob:${id}`);
      if (metaRaw) {
        const meta = JSON.parse(metaRaw);
        if (meta?.backend === "seedr" && meta?.path) {
          const upstream = await seedrFetchEncryptedBlob(env, meta.path);
          if (upstream) {
            return new Response(upstream.body, {
              headers: {
                "Content-Type": "application/octet-stream",
                "Cache-Control": "public, max-age=3600",
              },
            });
          }
        }
      }

      const buf = await env.LICENSES.get(`blob:${id}`, "arrayBuffer");
      if (!buf) return json({ error: "Not found or expired" }, 404);
      return new Response(buf, {
        headers: {
          "Content-Type": "application/octet-stream",
          "Cache-Control": "public, max-age=3600",
        },
      });
    }

    return json({ ok: true, service: "tinytiny-license" });
  },
};
