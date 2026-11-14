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
<title>TinyTiny Shared Collection</title>
<style>
  * { box-sizing: border-box; }
  body { margin:0; background:#09090d; color:#fff; font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif; min-height:100vh; padding:24px 16px 60px; }
  .wrap { max-width:960px; margin:0 auto; }
  .header { background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.14); border-radius:22px; padding:20px 22px; margin-bottom:20px; display:flex; flex-wrap:wrap; align-items:center; justify-content:space-between; gap:14px; }
  h1 { font-size:20px; margin:0 0 4px; }
  .sub { font-size:13px; color:rgba(255,255,255,0.68); margin:0; }
  .actions { display:flex; flex-wrap:wrap; gap:10px; }
  a.btn, button.btn { display:inline-flex; align-items:center; justify-content:center; padding:11px 18px; border-radius:999px; border:none; background:#e93b78; color:#fff; font-weight:700; font-size:13.5px; text-decoration:none; cursor:pointer; }
  button.secondary { background:rgba(255,255,255,0.12); }
  #status { text-align:center; padding:36px 16px; color:rgba(255,255,255,0.72); font-size:14px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:16px; }
  .item { background:rgba(255,255,255,0.05); border:1px solid rgba(255,255,255,0.12); border-radius:18px; overflow:hidden; display:flex; flex-direction:column; }
  .media { width:100%; aspect-ratio:9/16; max-height:480px; background:#000; object-fit:contain; display:block; }
  .meta { padding:12px 14px; }
  .title { font-size:13.5px; font-weight:600; line-height:1.35; margin:0 0 6px; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden; }
  .author { font-size:12px; color:rgba(255,255,255,0.6); }
</style>
</head>
<body>
  <div class="wrap">
    <div class="header">
      <div>
        <h1 id="dropTitle">TinyTiny Shared Drop</h1>
        <p class="sub" id="dropSub">End-to-end encrypted with AES-256-GCM. Decrypted locally in your browser.</p>
      </div>
      <div class="actions">
        <a id="openBtn" class="btn" href="#">Open in TinyTiny</a>
        <button id="copyBtn" class="btn secondary">Copy Drop Code</button>
      </div>
    </div>
    <div id="status">Decrypting shared videos...</div>
    <div id="gallery" class="grid"></div>
  </div>
  <script>
    const hash = location.hash || "";
    const deep = "tinytiny://drop/${shareId}" + hash;
    document.getElementById("openBtn").href = deep;
    const k = hash.startsWith("#k=") ? hash.slice(3) : (new URLSearchParams(location.search).get("k") || "");
    const code = k ? "TTDROP:${shareId}." + k : deep;
    document.getElementById("copyBtn").onclick = async () => {
      await navigator.clipboard.writeText(code);
      document.getElementById("copyBtn").textContent = "Copied!";
    };

    function b64UrlToBytes(token) {
      let b64 = token.replace(/-/g, "+").replace(/_/g, "/");
      while (b64.length % 4) b64 += "=";
      const bin = atob(b64);
      const out = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out;
    }

    function b64ToBytes(b64) {
      const bin = atob(b64);
      const out = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out;
    }

    async function openTTENC(cipherBytes, cryptoKey) {
      let offset = 0;
      if (
        cipherBytes.length > 6 &&
        cipherBytes[0] === 84 && cipherBytes[1] === 84 && cipherBytes[2] === 69 &&
        cipherBytes[3] === 78 && cipherBytes[4] === 67 && cipherBytes[5] === 49
      ) {
        offset = 6;
      }
      const iv = cipherBytes.slice(offset, offset + 12);
      const ct = cipherBytes.slice(offset + 12);
      const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, cryptoKey, ct);
      return new Uint8Array(plain);
    }

    function pickVideoUrl(post) {
      return post.muxedUrlHd || post.muxedUrl || post.mediaUrl || post.hlsUrl || "";
    }

    function renderPostCard(post) {
      const card = document.createElement("div");
      card.className = "item";
      const src = pickVideoUrl(post);
      const poster = post.posterUrl || post.thumbnailUrl || "";
      const isImg = (post.mediaType || "").toLowerCase() === "image" || /\\.(jpe?g|png|webp|gif)(\\?|$)/i.test(src);
      if (src) {
        if (isImg) {
          const img = document.createElement("img");
          img.className = "media";
          img.src = src;
          img.loading = "lazy";
          card.appendChild(img);
        } else {
          const vid = document.createElement("video");
          vid.className = "media";
          vid.src = src;
          if (poster) vid.poster = poster;
          vid.controls = true;
          vid.playsInline = true;
          vid.preload = "metadata";
          card.appendChild(vid);
        }
      }
      const meta = document.createElement("div");
      meta.className = "meta";
      const title = document.createElement("div");
      title.className = "title";
      title.textContent = post.title || "Shared Clip";
      const author = document.createElement("div");
      author.className = "author";
      author.textContent = [post.author ? "@" + post.author : "", post.subreddit || ""].filter(Boolean).join(" · ");
      meta.appendChild(title);
      if (author.textContent) meta.appendChild(author);
      card.appendChild(meta);
      return card;
    }

    (async () => {
      const statusEl = document.getElementById("status");
      const galleryEl = document.getElementById("gallery");
      if (!k) {
        statusEl.textContent = "Missing decryption key (#k=...) in URL.";
        return;
      }
      try {
        const resp = await fetch("/v1/share/${shareId}");
        if (!resp.ok) {
          statusEl.textContent = "This share link has expired or does not exist.";
          return;
        }
        const { cipher } = await resp.json();
        const keyBytes = b64UrlToBytes(k);
        const cryptoKey = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["decrypt"]);
        const plainBytes = await openTTENC(b64ToBytes(cipher), cryptoKey);
        const payload = JSON.parse(new TextDecoder().decode(plainBytes));

        if (payload.title) {
          document.getElementById("dropTitle").textContent = payload.title;
        }

        const list = Array.isArray(payload.posts) && payload.posts.length
          ? payload.posts
          : (payload.post ? [payload.post] : []);

        if (list.length > 0) {
          statusEl.style.display = "none";
          document.getElementById("dropSub").textContent = list.length + " shared video" + (list.length === 1 ? "" : "s") + " · Decrypted locally in your browser.";
          for (const p of list) {
            galleryEl.appendChild(renderPostCard(p));
          }
          return;
        }

        if (payload.encryptedBlobUrl) {
          statusEl.textContent = "Decrypting encrypted video file...";
          const bResp = await fetch(payload.encryptedBlobUrl);
          const encBuf = new Uint8Array(await bResp.arrayBuffer());
          const filePlain = await openTTENC(encBuf, cryptoKey);
          const ext = (payload.fileExtension || "mp4").toLowerCase();
          const isImg = ["jpg", "jpeg", "png", "webp", "gif"].includes(ext);
          const mime = isImg ? "image/" + (ext === "jpg" ? "jpeg" : ext) : "video/mp4";
          const blobUrl = URL.createObjectURL(new Blob([filePlain], { type: mime }));
          statusEl.style.display = "none";
          galleryEl.appendChild(renderPostCard({
            title: payload.title || payload.fileName || "Encrypted Video",
            author: "TinyTiny Drop",
            mediaType: isImg ? "image" : "video",
            mediaUrl: blobUrl,
            muxedUrl: blobUrl
          }));
          return;
        }

        statusEl.textContent = "Tap Open in TinyTiny to view this drop.";
      } catch (e) {
        statusEl.textContent = "Could not decrypt drop (" + (e && e.message ? e.message : "invalid key") + ").";
      }
    })();
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
