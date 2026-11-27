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

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-License-Key, X-Device-Id, X-File-Name, X-Direct-Secret, X-Mime-Type, X-Nonce-B64",
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...CORS_HEADERS,
    },
  });
}

function safeJsonParse(raw, fallback = null) {
  if (!raw) return fallback;
  try {
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

function formatOsLabel(raw) {
  const s = String(raw || "?").trim();
  if (!s || s === "?") return "iOS ?";
  return s.toLowerCase().startsWith("android") ? s : `iOS ${s}`;
}

function nowSec() {
  return Math.floor(Date.now() / 1000);
}

function parseDuration(raw) {
  const token = String(raw || "").trim().toLowerCase();
  if (!token) return null;
  if (token === "lifetime" || token === "perm" || token === "forever") {
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
  return safeJsonParse(raw, null);
}

function buildLicenseMetadata(rec) {
  const devs = rec.devices && typeof rec.devices === "object" ? Object.values(rec.devices) : [];
  const firstDev = devs[0] || null;
  return {
    key: rec.key,
    admin: Boolean(rec.admin),
    revoked: Boolean(rec.revoked),
    lifetime: Boolean(rec.lifetime),
    activatedAt: rec.activatedAt || null,
    expiresAt: rec.expiresAt || null,
    durationLabel: String(rec.durationLabel || "").slice(0, 32),
    maxDevices: rec.maxDevices || 1,
    deviceIds: Array.isArray(rec.deviceIds) ? rec.deviceIds.slice(0, 10) : [],
    createdAt: rec.createdAt || 0,
    note: String(rec.note || "").slice(0, 80),
    devices: firstDev ? { _0: { model: firstDev.model || "", ios: firstDev.ios || "", app: firstDev.app || "", lastSeenAt: firstDev.lastSeenAt || 0 } } : {},
  };
}

async function saveLicense(env, rec) {
  await env.LICENSES.put(`lic:${rec.key}`, JSON.stringify(rec), {
    metadata: buildLicenseMetadata(rec),
  });
}

function validateRecordAccess(rec, deviceId, opts = {}) {
  if (!rec) return { ok: false, error: "License key not found." };
  if (rec.revoked) return { ok: false, error: "This license key has been revoked." };
  if (!rec.lifetime && rec.activatedAt && rec.expiresAt && nowSec() >= rec.expiresAt) {
    return { ok: false, error: "License key has expired." };
  }
  const dev = String(deviceId || "").trim();
  if (opts.requireDeviceId && !dev) {
    return { ok: false, error: "Missing deviceId." };
  }
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

async function sendTelegram(env, chatId, text, replyMarkup = null) {
  if (!env.TELEGRAM_BOT_TOKEN) return;
  const safeText = String(text || "").length > 3950 ? String(text).slice(0, 3940) + "\n…(truncated)" : String(text || "");
  const payload = {
    chat_id: chatId,
    text: safeText,
    parse_mode: "HTML",
    disable_web_page_preview: true,
  };
  if (replyMarkup) payload.reply_markup = replyMarkup;
  await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  }).catch(() => null);
}

async function sendTelegramDocumentUrl(env, chatId, docUrl, caption = "", replyMarkup = null) {
  if (!env.TELEGRAM_BOT_TOKEN) return false;
  const payload = {
    chat_id: chatId,
    document: docUrl,
    caption: String(caption || "").slice(0, 1000),
    parse_mode: "HTML",
  };
  if (replyMarkup) payload.reply_markup = replyMarkup;
  try {
    const r = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendDocument`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    return r.ok;
  } catch {
    return false;
  }
}

async function sendTelegramBinaryFile(env, chatId, sourceUrl, filename, caption = "", replyMarkup = null) {
  if (!env.TELEGRAM_BOT_TOKEN) return { ok: false, error: "no_token" };
  try {
    const dl = await fetch(sourceUrl, {
      headers: { "User-Agent": "TinyTiny-Worker" },
      redirect: "follow",
    });
    if (!dl.ok) return { ok: false, error: `download_${dl.status}` };
    const buf = await dl.arrayBuffer();
    if (!buf || buf.byteLength < 100_000) {
      return { ok: false, error: `too_small_${buf?.byteLength || 0}` };
    }
    const form = new FormData();
    form.append("chat_id", String(chatId));
    form.append("document", new Blob([buf], { type: "application/octet-stream" }), filename);
    if (caption) {
      form.append("caption", String(caption).slice(0, 1000));
      form.append("parse_mode", "HTML");
    }
    if (replyMarkup) {
      form.append("reply_markup", JSON.stringify(replyMarkup));
    }
    const r = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendDocument`, {
      method: "POST",
      body: form,
    });
    if (!r.ok) {
      const txt = await r.text().catch(() => "");
      return { ok: false, error: `tg_${r.status}:${txt.slice(0, 160)}` };
    }
    return { ok: true, bytes: buf.byteLength };
  } catch (e) {
    return { ok: false, error: String(e?.message || e) };
  }
}

async function editTelegramMessage(env, chatId, messageId, text, replyMarkup = null) {
  if (!env.TELEGRAM_BOT_TOKEN) return;
  const safeText = String(text || "").length > 3950 ? String(text).slice(0, 3940) + "\n…(truncated)" : String(text || "");
  const payload = {
    chat_id: chatId,
    message_id: messageId,
    text: safeText,
    parse_mode: "HTML",
    disable_web_page_preview: true,
  };
  if (replyMarkup) payload.reply_markup = replyMarkup;
  await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/editMessageText`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  }).catch(() => null);
}

async function answerCallbackQuery(env, callbackQueryId, text = "") {
  if (!env.TELEGRAM_BOT_TOKEN || !callbackQueryId) return;
  await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/answerCallbackQuery`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ callback_query_id: callbackQueryId, text }),
  }).catch(() => null);
}

async function getRemoteConfig(env) {
  const raw = await env.LICENSES.get("config:app");
  if (!raw) return { announcement: null, announcementId: null, minVersion: null, maintenance: null };
  try {
    return JSON.parse(raw);
  } catch {
    return { announcement: null, announcementId: null, minVersion: null, maintenance: null };
  }
}

async function saveRemoteConfig(env, cfg) {
  await env.LICENSES.put("config:app", JSON.stringify(cfg));
}

async function listAllLicenses(env) {
  const entries = [];
  let cursor = undefined;
  do {
    const res = await env.LICENSES.list({ prefix: "lic:", cursor, limit: 1000 });
    for (const k of res.keys || []) entries.push(k);
    cursor = res.list_complete ? undefined : res.cursor;
  } while (cursor);

  const records = [];
  const missingMetaKeys = [];
  for (const entry of entries) {
    if (entry.metadata && entry.metadata.key) {
      records.push(entry.metadata);
    } else {
      missingMetaKeys.push(entry.name);
    }
  }
  // Fallback only for older keys saved before KV metadata optimization (capped to stay under subrequest limit)
  for (let i = 0; i < Math.min(missingMetaKeys.length, 40); i += 20) {
    const chunk = missingMetaKeys.slice(i, i + 20);
    const vals = await Promise.all(chunk.map((k) => env.LICENSES.get(k)));
    for (const raw of vals) {
      const rec = safeJsonParse(raw, null);
      if (rec) records.push(rec);
    }
  }
  records.sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
  return records;
}

function recordDeviceTelemetry(rec, deviceId, deviceInfo) {
  const dev = String(deviceId || "").trim();
  if (!dev || !deviceInfo || typeof deviceInfo !== "object") return false;
  if (!rec.devices || typeof rec.devices !== "object") rec.devices = {};
  const prev = rec.devices[dev] || {};
  const model = String(deviceInfo.model || prev.model || "Unknown").slice(0, 48);
  const modelId = String(deviceInfo.modelId || prev.modelId || "").slice(0, 32);
  const ios = String(deviceInfo.ios || prev.ios || "?").slice(0, 20);
  const app = String(deviceInfo.app || prev.app || "1.0").slice(0, 20);
  const now = nowSec();
  // Debounce telemetry KV writes to 12h unless device/OS/app version changed (protects free-tier KV write quota)
  const changed =
    !prev.lastSeenAt ||
    prev.model !== model ||
    prev.ios !== ios ||
    prev.app !== app ||
    now - prev.lastSeenAt >= 12 * 3600;
  rec.devices[dev] = {
    model,
    modelId,
    ios,
    app,
    firstSeenAt: prev.firstSeenAt || now,
    lastSeenAt: now,
  };
  return changed;
}

function classifyLicenseState(rec) {
  if (rec.revoked) return "revoked";
  if (!rec.activatedAt) return "unused";
  if (!rec.lifetime && rec.expiresAt && nowSec() >= rec.expiresAt) return "expired";
  return "active";
}

function formatKeyDetails(rec) {
  const devs = rec.devices && typeof rec.devices === "object" ? Object.entries(rec.devices) : [];
  const devLines = devs.map(([, info]) => {
    const agoMin = Math.max(0, Math.floor((nowSec() - (info.lastSeenAt || 0)) / 60));
    const agoStr = agoMin < 60 ? `${agoMin}m ago` : agoMin < 1440 ? `${Math.floor(agoMin / 60)}h ago` : `${Math.floor(agoMin / 1440)}d ago`;
    const osRaw = String(info.ios || "?");
    const osLabel = osRaw.toLowerCase().startsWith("android") ? osRaw : `iOS ${osRaw}`;
    return `  • ${escapeHtmlTg(info.model || "iPhone")} (${escapeHtmlTg(osLabel)}, v${escapeHtmlTg(info.app || "1.0")}) · ${agoStr}`;
  });
  return [
    `<b>${rec.key}</b>`,
    rec.admin ? `Role: <b>ADMIN</b>` : `Role: Standard`,
    `Status: <b>${formatRemaining(rec)}</b>`,
    `Devices: ${(rec.deviceIds || []).length}/${rec.maxDevices || 1}`,
    ...devLines,
    rec.note ? `Note: ${escapeHtmlTg(rec.note)}` : null,
  ]
    .filter(Boolean)
    .join("\n");
}

function keyActionKeyboard(rec) {
  const noteRow = rec.note
    ? [
        { text: "📝 Set Note", callback_data: `k:note:${rec.key}` },
        { text: "🗑 Clear Note", callback_data: `k:clrnote:${rec.key}` },
        { text: "🔄 Refresh", callback_data: `k:ref:${rec.key}` },
      ]
    : [
        { text: "📝 Set Note", callback_data: `k:note:${rec.key}` },
        { text: "🔄 Refresh", callback_data: `k:ref:${rec.key}` },
      ];
  return {
    inline_keyboard: [
      [
        { text: "+7d", callback_data: `k:ext7:${rec.key}` },
        { text: "+30d", callback_data: `k:ext30:${rec.key}` },
        { text: "Lifetime", callback_data: `k:life:${rec.key}` },
        { text: "⏱ Custom", callback_data: `k:extc:${rec.key}` },
      ],
      [
        { text: "-1 Dev", callback_data: `k:devm1:${rec.key}` },
        { text: "+1 Dev", callback_data: `k:dev1:${rec.key}` },
        { text: "+5 Dev", callback_data: `k:dev5:${rec.key}` },
      ],
      [
        { text: "📱 Unbind Devices", callback_data: `k:unbmenu:${rec.key}` },
        rec.revoked
          ? { text: "✅ Unrevoke", callback_data: `k:unrev:${rec.key}` }
          : { text: "🚫 Revoke", callback_data: `k:rev:${rec.key}` },
      ],
      noteRow,
      [
        { text: "🔑 All Keys", callback_data: "keys:all:1" },
        { text: "🏠 Menu", callback_data: "menu:home" },
      ],
    ],
  };
}

function unbindDevicesKeyboard(rec) {
  const ids = Array.isArray(rec.deviceIds) ? rec.deviceIds : [];
  const devMap = rec.devices || {};
  const rows = ids.map((id, idx) => {
    const info = devMap[id] || {};
    const label = info.model || `Device ${idx + 1}`;
    const osRaw = String(info.ios || "");
    const tag = osRaw.toLowerCase().startsWith("android") ? "Android" : (osRaw ? `iOS ${osRaw}` : "");
    const btnText = `❌ Unbind ${label}${tag ? ` (${tag})` : ""}`.slice(0, 48);
    const idPrefix = String(id).replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 12) || String(idx);
    return [{ text: btnText, callback_data: `k:unbd:${idPrefix}:${rec.key}` }];
  });
  if (ids.length > 0) {
    rows.push([{ text: `🗑 Unbind ALL (${ids.length})`, callback_data: `k:unball:${rec.key}` }]);
  }
  rows.push([{ text: "← Back to Key", callback_data: `k:open:${rec.key}` }]);
  return { inline_keyboard: rows };
}

async function buildHomeMenu(env) {
  const alertsOn = (await env.LICENSES.get("alerts:enabled")) === "1";
  const cfg = await getRemoteConfig(env);
  const statusBits = [];
  if (cfg.maintenance) statusBits.push("🛠 Maintenance: <b>ON</b>");
  if (cfg.minVersion) statusBits.push(`📱 Min Ver: <b>v${escapeHtmlTg(cfg.minVersion)}</b>`);
  if (cfg.announcement) statusBits.push(`📢 Banner: <i>${escapeHtmlTg(cfg.announcement)}</i>`);
  const text = [
    `<b>TinyTiny Admin Panel</b>`,
    `Every command is a button — zero typing required.`,
    statusBits.length ? `\n${statusBits.join("\n")}` : null,
  ]
    .filter(Boolean)
    .join("\n");

  const keyboard = {
    inline_keyboard: [
      [
        { text: "📊 Fleet & Users", callback_data: "stats:ref" },
        { text: "🔑 All Keys", callback_data: "keys:all:1" },
      ],
      [
        { text: "➕ New Key", callback_data: "menu:new" },
        { text: "👑 New Admin Key", callback_data: "menu:newadmin" },
      ],
      [
        { text: "📦 Batch Keys", callback_data: "menu:batch" },
        { text: "🔍 Search Keys", callback_data: "menu:find" },
      ],
      [
        { text: "⚙️ Config & Gates", callback_data: "menu:config" },
        { text: "⚠️ Error Log", callback_data: "menu:errors" },
      ],
      [
        { text: alertsOn ? "🔔 Alerts: ON" : "🔕 Alerts: OFF", callback_data: "menu:alerts" },
        { text: "📥 Sync Watchit", callback_data: "menu:watchit" },
      ],
      [
        { text: "📲 Latest APK & IPA", callback_data: "menu:builds" },
        { text: "📤 Direct IG Drop", callback_data: "menu:directig" },
      ],
      [
        { text: "🆔 My ID", callback_data: "menu:myid" },
        { text: "❓ All Commands", callback_data: "menu:help" },
      ],
    ],
  };
  return { text, keyboard };
}

function buildCreateKeyMenu(isAdmin, maxDev = 1) {
  const tag = isAdmin ? "adm" : "std";
  const label = isAdmin ? "👑 New ADMIN Key" : "➕ New Standard Key";
  const text = `<b>${label}</b>\nDevice Cap: <b>${maxDev}</b> · Choose a duration (starts on first activation):`;
  const devRow = [1, 3, 5, 10].map((d) => ({
    text: d === maxDev ? `• ${d} Dev •` : `${d} Dev`,
    callback_data: `menu:${isAdmin ? "newadmin" : "new"}:${d}`,
  }));
  const keyboard = {
    inline_keyboard: [
      devRow,
      [
        { text: "12 Hours", callback_data: `gen:${tag}:12h:${maxDev}` },
        { text: "7 Days", callback_data: `gen:${tag}:7d:${maxDev}` },
        { text: "30 Days", callback_data: `gen:${tag}:30d:${maxDev}` },
      ],
      [
        { text: "1 Year", callback_data: `gen:${tag}:1y:${maxDev}` },
        { text: "Lifetime", callback_data: `gen:${tag}:lifetime:${maxDev}` },
        { text: "⏱ Custom", callback_data: `gen:${tag}:custom:${maxDev}` },
      ],
      [{ text: "🏠 Back to Menu", callback_data: "menu:home" }],
    ],
  };
  return { text, keyboard };
}

function buildBatchMenu(count = 5, maxDev = 1) {
  const text = `<b>📦 Batch Generate Keys</b>\nCount: <b>${count} keys</b> · Device Cap: <b>${maxDev}</b>\nPick duration to generate immediately:`;
  const countRow = [5, 10, 25].map((c) => ({
    text: c === count ? `• ${c}× •` : `${c}×`,
    callback_data: `menu:batch:${c}:${maxDev}`,
  }));
  const devRow = [1, 3, 5].map((d) => ({
    text: d === maxDev ? `• ${d} Dev •` : `${d} Dev`,
    callback_data: `menu:batch:${count}:${d}`,
  }));
  const keyboard = {
    inline_keyboard: [
      countRow,
      devRow,
      [
        { text: `${count}× 7d`, callback_data: `gen:batch:7d:${count}:${maxDev}` },
        { text: `${count}× 30d`, callback_data: `gen:batch:30d:${count}:${maxDev}` },
      ],
      [
        { text: `${count}× 1y`, callback_data: `gen:batch:1y:${count}:${maxDev}` },
        { text: `${count}× Lifetime`, callback_data: `gen:batch:lifetime:${count}:${maxDev}` },
      ],
      [{ text: "🏠 Back to Menu", callback_data: "menu:home" }],
    ],
  };
  return { text, keyboard };
}

async function buildConfigMenu(env) {
  const cfg = await getRemoteConfig(env);
  const alertsOn = (await env.LICENSES.get("alerts:enabled")) === "1";
  const text = [
    `<b>⚙️ Remote App Config</b>`,
    `📢 Banner: ${cfg.announcement ? escapeHtmlTg(cfg.announcement) : "<i>None</i>"}`,
    `🛠 Maintenance: ${cfg.maintenance ? `<b>ON</b> (${escapeHtmlTg(cfg.maintenance)})` : "<i>OFF</i>"}`,
    `📱 Min Version: ${cfg.minVersion ? `<b>v${escapeHtmlTg(cfg.minVersion)}</b>` : "<i>OFF</i>"}`,
    `🔔 Alerts: <b>${alertsOn ? "ON" : "OFF"}</b>`,
  ].join("\n");
  const keyboard = {
    inline_keyboard: [
      [
        { text: "📢 Set Banner", callback_data: "cfg:ann" },
        { text: "🗑 Clear Banner", callback_data: "cfg:clearann" },
      ],
      [
        { text: "🛠 Maintenance ON", callback_data: "cfg:maint" },
        { text: "✅ Maintenance OFF", callback_data: "cfg:maint_off" },
      ],
      [
        { text: "📱 Set Min Ver", callback_data: "cfg:minver" },
        { text: "🔓 Clear Min Ver", callback_data: "cfg:minver_off" },
      ],
      [
        { text: alertsOn ? "🔔 Alerts: ON" : "🔕 Alerts: OFF", callback_data: "cfg:alerts" },
        { text: "🏠 Menu", callback_data: "menu:home" },
      ],
    ],
  };
  return { text, keyboard };
}

async function buildErrorsText(env) {
  const raw = await env.LICENSES.get("errors:recent");
  const list = safeJsonParse(raw, []);
  if (!list.length) return "<b>⚠️ Recent Error Reports</b>\nNo recent anonymous error reports.";
  const lines = list.slice(0, 15).map((e) => {
    const ago = Math.max(0, Math.floor((nowSec() - (e.at || 0)) / 60));
    return `• <b>${escapeHtmlTg(e.source)}</b> — ${escapeHtmlTg(e.model || "Device")} (${escapeHtmlTg(formatOsLabel(e.ios))}, v${escapeHtmlTg(e.app || "1.0")}) · ${ago}m ago\n  <i>${escapeHtmlTg(e.detail || "")}</i>`;
  });
  return `<b>⚠️ Recent Anonymous Error Reports</b>\n${lines.join("\n")}`;
}

async function sendLatestBuildsToTelegram(env, chatId) {
  const apkUrl = "https://raw.githubusercontent.com/aokifrlol-maker/TinyTiny/main/APK%20VERSION/TinyTiny.apk";
  const ipaUrl = "https://github.com/aokifrlol-maker/TinyTiny/releases/download/latest/TinyTiny.ipa";
  let commitShort = "main";
  try {
    const r = await fetch("https://api.github.com/repos/aokifrlol-maker/TinyTiny/actions/workflows/build.yml/runs?per_page=1", {
      headers: { "User-Agent": "TinyTiny-Worker" },
    });
    if (r.ok) {
      const data = await r.json();
      const run = data?.workflow_runs?.[0];
      if (run?.head_sha) commitShort = String(run.head_sha).slice(0, 7);
    }
  } catch {}

  const menuKb = {
    inline_keyboard: [[{ text: "🏠 Back to Menu", callback_data: "menu:home" }]],
  };

  const apkRes = await sendTelegramBinaryFile(
    env,
    chatId,
    apkUrl,
    "TinyTiny.apk",
    `🤖 <b>TinyTiny Android APK</b> (<code>${commitShort}</code>)`
  );
  const ipaRes = await sendTelegramBinaryFile(
    env,
    chatId,
    ipaUrl,
    "TinyTiny.ipa",
    `🍎 <b>TinyTiny iOS IPA</b> (<code>${commitShort}</code>)`,
    menuKb
  );
  return { commitShort, apk: apkRes, ipa: ipaRes };
}

async function createAndSaveKey(env, { isAdmin = false, durSpec, maxDevices = 1, note = "" }) {
  const key = generateLicenseKey();
  const rec = {
    key,
    admin: isAdmin,
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
  return rec;
}

async function searchKeysResult(env, qRaw) {
  const q = qRaw.trim().toLowerCase();
  const all = await listAllLicenses(env);
  const hits = all.filter((rec) => {
    if ((rec.key || "").toLowerCase().includes(q)) return true;
    if ((rec.note || "").toLowerCase().includes(q)) return true;
    if (rec.devices) {
      for (const info of Object.values(rec.devices)) {
        const hay = `${info.model || ""} ${info.modelId || ""} ios ${info.ios || ""}`.toLowerCase();
        if (hay.includes(q)) return true;
      }
    }
    return false;
  });
  const top = hits.slice(0, 8);
  const lines = top.map((rec) => {
    const devs = rec.devices ? Object.values(rec.devices) : [];
    const devTag = devs.length ? ` · ${escapeHtmlTg(devs[0].model || "")} (${escapeHtmlTg(devs[0].ios || "?")})` : "";
    return `<code>${rec.key}</code> — ${formatRemaining(rec)}${devTag}${rec.note ? ` (${escapeHtmlTg(rec.note)})` : ""}`;
  });
  const keyButtons = top.map((rec) => [
    { text: `🔧 ${rec.key} (${formatRemaining(rec)})`, callback_data: `k:open:${rec.key}` },
  ]);
  keyButtons.push([{ text: "🏠 Menu", callback_data: "menu:home" }]);
  return {
    text: `<b>🔍 Search "${escapeHtmlTg(q)}" (${hits.length} match${hits.length === 1 ? "" : "es"})</b>\n` + (lines.length ? lines.join("\n") : "No matches."),
    keyboard: { inline_keyboard: keyButtons },
  };
}

async function buildUsersStatsMessage(env) {
  const all = await listAllLicenses(env);
  let active = 0, unused = 0, expired = 0, revoked = 0, admins = 0;
  let active24h = 0, active7d = 0;
  const now = nowSec();
  const modelCounts = {};
  const iosCounts = {};
  const appCounts = {};

  for (const rec of all) {
    if (rec.admin) admins++;
    const st = classifyLicenseState(rec);
    if (st === "active") active++;
    else if (st === "unused") unused++;
    else if (st === "expired") expired++;
    else if (st === "revoked") revoked++;

    if (rec.devices && typeof rec.devices === "object") {
      for (const [, info] of Object.entries(rec.devices)) {
        const last = info.lastSeenAt || 0;
        if (now - last <= DAY_SEC) active24h++;
        if (now - last <= 7 * DAY_SEC) active7d++;
        if (st === "active" || now - last <= 7 * DAY_SEC) {
          const m = info.model || "Unknown iPhone";
          const ios = `iOS ${info.ios || "?"}`;
          const app = `v${info.app || "1.0"}`;
          modelCounts[m] = (modelCounts[m] || 0) + 1;
          iosCounts[ios] = (iosCounts[ios] || 0) + 1;
          appCounts[app] = (appCounts[app] || 0) + 1;
        }
      }
    }
  }

  const fmtTop = (obj, limit = 10) =>
    Object.entries(obj)
      .sort((a, b) => b[1] - a[1])
      .slice(0, limit)
      .map(([k, v]) => `  • ${escapeHtmlTg(k)}: <b>${v}</b>`)
      .join("\n") || "  • No device telemetry yet";

  return [
    `<b>TinyTiny Fleet &amp; Users</b>`,
    `Total Keys: <b>${all.length}</b> (${admins} admin)`,
    `Active: <b>${active}</b> · Unused: <b>${unused}</b> · Expired: <b>${expired}</b> · Revoked: <b>${revoked}</b>`,
    `Active Devices: <b>${active24h}</b> (24h) · <b>${active7d}</b> (7d)`,
    ``,
    `<b>iPhone Models (Active / 7d)</b>`,
    fmtTop(modelCounts, 12),
    ``,
    `<b>iOS Versions</b>`,
    fmtTop(iosCounts, 8),
    ``,
    `<b>App Builds</b>`,
    fmtTop(appCounts, 6),
  ].join("\n");
}

async function buildAllKeysPage(env, filter = "all", page = 1) {
  const all = await listAllLicenses(env);
  const filtered = all.filter((rec) => {
    if (filter === "all") return true;
    if (filter === "admin") return Boolean(rec.admin);
    return classifyLicenseState(rec) === filter;
  });
  const perPage = 6;
  const totalPages = Math.max(1, Math.ceil(filtered.length / perPage));
  const p = Math.min(totalPages, Math.max(1, page));
  const slice = filtered.slice((p - 1) * perPage, p * perPage);

  const lines = slice.map((rec) => {
    const devs = rec.devices ? Object.values(rec.devices) : [];
    const devTag = devs.length > 0 ? ` · ${escapeHtmlTg(devs[0].model || "")} (${escapeHtmlTg(devs[0].ios || "?")})` : "";
    return `<code>${rec.key}</code> — ${formatRemaining(rec)}${devTag}${rec.note ? ` (${escapeHtmlTg(rec.note)})` : ""}`;
  });

  const text = [
    `<b>🔑 All Keys (${filter.toUpperCase()})</b> · ${filtered.length} total · Page ${p}/${totalPages}`,
    lines.length ? lines.join("\n") : "No keys match this filter.",
    ``,
    `Tap a key button below to Extend, Unbind, or Revoke:`,
  ].join("\n");

  const keyRows = slice.map((rec) => [
    {
      text: `${rec.revoked ? "🚫 " : rec.admin ? "👑 " : "🔑 "}${rec.key} · ${formatRemaining(rec)}`,
      callback_data: `k:open:${rec.key}`,
    },
  ]);

  const navRow = [];
  if (p > 1) navRow.push({ text: "◀ Prev", callback_data: `keys:${filter}:${p - 1}` });
  if (p < totalPages) navRow.push({ text: "Next ▶", callback_data: `keys:${filter}:${p + 1}` });
  navRow.push({ text: "🏠 Menu", callback_data: "menu:home" });

  const filterRow = [
    { text: filter === "all" ? "• All •" : "All", callback_data: "keys:all:1" },
    { text: filter === "active" ? "• Active •" : "Active", callback_data: "keys:active:1" },
    { text: filter === "unused" ? "• Unused •" : "Unused", callback_data: "keys:unused:1" },
  ];
  const filterRow2 = [
    { text: filter === "expired" ? "• Expired •" : "Expired", callback_data: "keys:expired:1" },
    { text: filter === "revoked" ? "• Revoked •" : "Revoked", callback_data: "keys:revoked:1" },
    { text: filter === "admin" ? "• Admin •" : "Admin", callback_data: "keys:admin:1" },
  ];
  const keyboard = { inline_keyboard: [...keyRows, filterRow, filterRow2, navRow] };
  return { text, keyboard };
}

async function handleTelegramUpdate(env, update) {
  if (update?.callback_query) {
    const cq = update.callback_query;
    const senderId = String(cq.from?.id || "");
    if (!env.ADMIN_USER_ID || String(env.ADMIN_USER_ID) !== senderId) {
      await answerCallbackQuery(env, cq.id, "Unauthorized");
      return new Response("ok");
    }
    const chatId = cq.message?.chat?.id;
    const msgId = cq.message?.message_id;
    const data = String(cq.data || "");
    const parts = data.split(":");

    try {
    if (parts[0] === "keys" && chatId && msgId) {
      const filter = parts[1] || "all";
      const page = parseInt(parts[2] || "1", 10) || 1;
      const res = await buildAllKeysPage(env, filter, page);
      await editTelegramMessage(env, chatId, msgId, res.text, res.keyboard);
      await answerCallbackQuery(env, cq.id);
      return new Response("ok");
    }

    if (parts[0] === "menu" && chatId && msgId) {
      const sub = parts[1];
      if (sub === "home") {
        const home = await buildHomeMenu(env);
        await editTelegramMessage(env, chatId, msgId, home.text, home.keyboard);
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      if (sub === "new" || sub === "newadmin") {
        const maxDev = Math.min(50, Math.max(1, parseInt(parts[2] || "1", 10) || 1));
        const m = buildCreateKeyMenu(sub === "newadmin", maxDev);
        await editTelegramMessage(env, chatId, msgId, m.text, m.keyboard);
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      if (sub === "batch") {
        const cnt = Math.min(25, Math.max(1, parseInt(parts[2] || "5", 10) || 5));
        const maxDev = Math.min(50, Math.max(1, parseInt(parts[3] || "1", 10) || 1));
        const b = buildBatchMenu(cnt, maxDev);
        await editTelegramMessage(env, chatId, msgId, b.text, b.keyboard);
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      if (sub === "config") {
        const c = await buildConfigMenu(env);
        await editTelegramMessage(env, chatId, msgId, c.text, c.keyboard);
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      if (sub === "errors") {
        const txt = await buildErrorsText(env);
        await editTelegramMessage(env, chatId, msgId, txt, {
          inline_keyboard: [
            [{ text: "🔄 Refresh", callback_data: "menu:errors" }, { text: "🗑 Clear Errors", callback_data: "menu:clearerrors" }],
            [{ text: "🏠 Menu", callback_data: "menu:home" }],
          ],
        });
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      if (sub === "clearerrors") {
        await env.LICENSES.put("errors:recent", "[]");
        const txt = await buildErrorsText(env);
        await editTelegramMessage(env, chatId, msgId, txt, {
          inline_keyboard: [[{ text: "🔄 Refresh", callback_data: "menu:errors" }, { text: "🏠 Menu", callback_data: "menu:home" }]],
        });
        await answerCallbackQuery(env, cq.id, "Error log cleared");
        return new Response("ok");
      }
      if (sub === "alerts") {
        const cur = (await env.LICENSES.get("alerts:enabled")) === "1";
        await env.LICENSES.put("alerts:enabled", cur ? "0" : "1");
        const home = await buildHomeMenu(env);
        await editTelegramMessage(env, chatId, msgId, home.text, home.keyboard);
        await answerCallbackQuery(env, cq.id, `Alerts ${cur ? "OFF" : "ON"}`);
        return new Response("ok");
      }
      if (sub === "find") {
        await sendTelegram(env, chatId, "🔍 <b>Search Keys</b>\nReply to this message with a key, note, or phone model (e.g. <code>iPhone 15</code>):", {
          force_reply: true,
          input_field_placeholder: "iPhone 15, Friend, TT-...",
        });
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      if (sub === "directig") {
        await sendTelegram(env, chatId, "📤 <b>Direct IG Drop</b>\nReply to this message with an XVideos or direct MP4 URL:", {
          force_reply: true,
          input_field_placeholder: "https://...",
        });
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      if (sub === "builds") {
        await answerCallbackQuery(env, cq.id, "Uploading latest APK & IPA...");
        await sendLatestBuildsToTelegram(env, chatId);
        return new Response("ok");
      }
      if (sub === "myid") {
        await answerCallbackQuery(env, cq.id, `ID: ${senderId}`);
        await editTelegramMessage(
          env,
          chatId,
          msgId,
          `🆔 <b>Your Telegram Admin ID</b>\n<code>${senderId}</code>`,
          { inline_keyboard: [[{ text: "🏠 Back to Menu", callback_data: "menu:home" }]] }
        );
        return new Response("ok");
      }
      if (sub === "watchit") {
        await answerCallbackQuery(env, cq.id, "Syncing Watchit...");
        const res = await syncWatchitFolder(env, getPublicBaseUrl(env), true);
        if (!res.ok) {
          await sendTelegram(env, chatId, `Watchit sync error: ${escapeHtmlTg(res.error || "Unknown")}`);
        } else if (res.sent === 0) {
          await sendTelegram(env, chatId, `Seedr <code>/Watchit/</code> is ready (${res.total} video${res.total === 1 ? "" : "s"} tracked, no new uploads).`);
        }
        return new Response("ok");
      }
      if (sub === "help") {
        const helpText = [
          "<b>TinyTiny Commands (All available as Buttons!)</b>",
          "<code>/menu</code> · <code>/users</code> · <code>/allkeys</code> · <code>/myid</code>",
          "<code>/info KEY</code> · <code>/find query</code> · <code>/builds</code>",
          "<code>/gen 30d [maxDev] [note]</code> · <code>/genadmin ...</code>",
          "<code>/genbatch 5 30d [maxDev] [note]</code>",
          "<code>/extend KEY 30d</code> · <code>/setdevices KEY 5</code>",
          "<code>/unbind KEY</code> · <code>/revoke KEY</code> · <code>/unrevoke KEY</code>",
          "<code>/note KEY text</code> · <code>/config</code> · <code>/errors</code> · <code>/alerts</code>",
          "<code>/announce text</code> · <code>/clearannounce</code> · <code>/maintenance text|off</code> · <code>/minversion 1.2|off</code>",
          "<code>/watchit</code> · <code>/directig URL</code>",
        ].join("\n");
        await editTelegramMessage(env, chatId, msgId, helpText, {
          inline_keyboard: [
            [{ text: "📊 Fleet", callback_data: "stats:ref" }, { text: "🔑 All Keys", callback_data: "keys:all:1" }, { text: "➕ New Key", callback_data: "menu:new" }],
            [{ text: "📦 Batch", callback_data: "menu:batch" }, { text: "⚙️ Config", callback_data: "menu:config" }, { text: "📲 Builds", callback_data: "menu:builds" }],
            [{ text: "🏠 Back to Menu", callback_data: "menu:home" }],
          ],
        });
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
    }

    if (parts[0] === "gen" && chatId && msgId) {
      const kind = parts[1];
      const dur = parts[2] || "30d";
      if (dur === "custom") {
        const maxDev = Math.min(50, Math.max(1, parseInt(parts[3] || "1", 10) || 1));
        const roleLabel = kind === "adm" ? "ADMIN" : "STANDARD";
        await sendTelegram(
          env,
          chatId,
          `⏱ <b>Custom ${roleLabel} Key (${maxDev} dev)</b>\nReply with duration + optional note (e.g. <code>90d VIP Friend</code> or <code>48h Trial</code>):`,
          { force_reply: true, input_field_placeholder: "90d VIP Friend" }
        );
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      const durSpec = parseDuration(dur);
      if (!durSpec) {
        await answerCallbackQuery(env, cq.id, "Invalid duration");
        return new Response("ok");
      }
      if (kind === "batch") {
        const count = Math.min(25, Math.max(1, parseInt(parts[3] || "5", 10) || 5));
        const maxDev = Math.min(50, Math.max(1, parseInt(parts[4] || "1", 10) || 1));
        const recs = Array.from({ length: count }, () => ({
          key: generateLicenseKey(),
          admin: false,
          lifetime: durSpec.lifetime,
          durationSeconds: durSpec.seconds,
          durationLabel: durSpec.label,
          maxDevices: maxDev,
          note: "",
          createdAt: nowSec(),
          activatedAt: null,
          expiresAt: null,
          deviceIds: [],
          revoked: false,
        }));
        await Promise.all(recs.map((r) => saveLicense(env, r)));
        const idxRaw = await env.LICENSES.get("index:recent");
        const idx = safeJsonParse(idxRaw, []);
        const keys = recs.map((r) => r.key);
        await env.LICENSES.put("index:recent", JSON.stringify([...keys, ...idx].slice(0, 60)));
        await editTelegramMessage(
          env,
          chatId,
          msgId,
          `<b>📦 Generated ${count} Keys (${durSpec.label} · ${maxDev} dev)</b>\n` + keys.map((k) => `<code>${k}</code>`).join("\n"),
          { inline_keyboard: [[{ text: "📦 More Batch", callback_data: "menu:batch" }, { text: "🔑 All Keys", callback_data: "keys:all:1" }], [{ text: "🏠 Menu", callback_data: "menu:home" }]] }
        );
        await answerCallbackQuery(env, cq.id, `Created ${count} keys`);
        return new Response("ok");
      }
      const isAdmin = kind === "adm";
      const maxDev = Math.min(50, Math.max(1, parseInt(parts[3] || "1", 10) || 1));
      const rec = await createAndSaveKey(env, { isAdmin, durSpec, maxDevices: maxDev, note: "" });
      await editTelegramMessage(env, chatId, msgId, formatKeyDetails(rec), keyActionKeyboard(rec));
      await answerCallbackQuery(env, cq.id, `Created ${rec.key}`);
      return new Response("ok");
    }

    if (parts[0] === "cfg" && chatId && msgId) {
      const action = parts[1];
      if (action === "alerts") {
        const cur = (await env.LICENSES.get("alerts:enabled")) === "1";
        await env.LICENSES.put("alerts:enabled", cur ? "0" : "1");
        const c = await buildConfigMenu(env);
        await editTelegramMessage(env, chatId, msgId, c.text, c.keyboard);
        await answerCallbackQuery(env, cq.id, `Alerts ${cur ? "OFF" : "ON"}`);
        return new Response("ok");
      }
      const cfg = await getRemoteConfig(env);
      if (action === "clearann") {
        cfg.announcement = null;
        cfg.announcementId = null;
        await saveRemoteConfig(env, cfg);
        const c = await buildConfigMenu(env);
        await editTelegramMessage(env, chatId, msgId, c.text, c.keyboard);
        await answerCallbackQuery(env, cq.id, "Banner cleared");
        return new Response("ok");
      }
      if (action === "maint_off") {
        cfg.maintenance = null;
        await saveRemoteConfig(env, cfg);
        const c = await buildConfigMenu(env);
        await editTelegramMessage(env, chatId, msgId, c.text, c.keyboard);
        await answerCallbackQuery(env, cq.id, "Maintenance OFF");
        return new Response("ok");
      }
      if (action === "minver_off") {
        cfg.minVersion = null;
        await saveRemoteConfig(env, cfg);
        const c = await buildConfigMenu(env);
        await editTelegramMessage(env, chatId, msgId, c.text, c.keyboard);
        await answerCallbackQuery(env, cq.id, "Min Version cleared");
        return new Response("ok");
      }
      if (action === "ann") {
        await sendTelegram(env, chatId, "📢 <b>Set In-App Banner</b>\nReply to this message with the announcement text:", { force_reply: true });
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      if (action === "maint") {
        await sendTelegram(env, chatId, "🛠 <b>Enable Maintenance Gate</b>\nReply to this message with the maintenance notice:", { force_reply: true });
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      if (action === "minver") {
        await sendTelegram(env, chatId, "📱 <b>Set Minimum App Version</b>\nReply to this message with the version (e.g. <code>1.3</code>):", { force_reply: true });
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
    }

    if (parts[0] === "stats" && chatId && msgId) {
      const text = await buildUsersStatsMessage(env);
      await editTelegramMessage(env, chatId, msgId, text, {
        inline_keyboard: [[{ text: "🔄 Refresh", callback_data: "stats:ref" }, { text: "🔑 All Keys", callback_data: "keys:all:1" }, { text: "🏠 Menu", callback_data: "menu:home" }]],
      });
      await answerCallbackQuery(env, cq.id, "Refreshed");
      return new Response("ok");
    }

    if (parts[0] === "k" && parts.length >= 3 && chatId && msgId) {
      const action = parts[1];
      if (action === "unbd" && parts.length >= 4) {
        const targetPrefix = parts[2];
        const key = parts.slice(3).join(":");
        const rec = await getLicense(env, key);
        if (!rec) {
          await answerCallbackQuery(env, cq.id, "Key not found");
          return new Response("ok");
        }
        const ids = Array.isArray(rec.deviceIds) ? rec.deviceIds : [];
        let removedId = ids.find((id) => String(id).replace(/[^a-zA-Z0-9_-]/g, "").startsWith(targetPrefix));
        if (!removedId && /^\d+$/.test(targetPrefix)) {
          const idx = parseInt(targetPrefix, 10);
          if (idx >= 0 && idx < ids.length) removedId = ids[idx];
        }
        if (removedId) {
          const label = rec.devices?.[removedId]?.model || "Device";
          rec.deviceIds = ids.filter((id) => id !== removedId);
          if (rec.devices && rec.devices[removedId]) {
            delete rec.devices[removedId];
          }
          await saveLicense(env, rec);
          await editTelegramMessage(
            env,
            chatId,
            msgId,
            `${formatKeyDetails(rec)}\n\n<i>Cloud backup untouched. Pick another device to unbind or go Back:</i>`,
            unbindDevicesKeyboard(rec)
          );
          await answerCallbackQuery(env, cq.id, `Unbound ${label}`);
          return new Response("ok");
        }
        await editTelegramMessage(env, chatId, msgId, formatKeyDetails(rec), unbindDevicesKeyboard(rec));
        await answerCallbackQuery(env, cq.id, "Device already unbound");
        return new Response("ok");
      }

      const key = parts.slice(2).join(":");
      const rec = await getLicense(env, key);
      if (!rec) {
        await answerCallbackQuery(env, cq.id, "Key not found");
        return new Response("ok");
      }
      if (action === "note") {
        await sendTelegram(env, chatId, `📝 <b>Set Note for ${rec.key}</b>\nReply to this message with the note:`, { force_reply: true });
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      if (action === "extc") {
        await sendTelegram(env, chatId, `⏱ <b>Custom Extend for ${rec.key}</b>\nReply with duration to add (e.g. <code>90d</code>, <code>1y</code>, <code>lifetime</code>):`, { force_reply: true, input_field_placeholder: "90d" });
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      if (action === "unbmenu") {
        const count = (rec.deviceIds || []).length;
        const hint = count === 0
          ? "\n\n<i>No devices currently bound to this key.</i>"
          : "\n\n<i>Pick a specific device to unbind (cloud saves are kept safe):</i>";
        await editTelegramMessage(env, chatId, msgId, formatKeyDetails(rec) + hint, unbindDevicesKeyboard(rec));
        await answerCallbackQuery(env, cq.id);
        return new Response("ok");
      }
      let toast = "Updated";
      if (action === "open") {
        toast = "";
      } else if (action === "ext7" || action === "ext30") {
        if (rec.lifetime) {
          toast = "Already Lifetime";
        } else {
          const days = action === "ext7" ? 7 : 30;
          const sec = days * DAY_SEC;
          if (rec.activatedAt) {
            const base = Math.max(nowSec(), rec.expiresAt || nowSec());
            rec.expiresAt = base + sec;
          } else {
            rec.durationSeconds = (rec.durationSeconds || 0) + sec;
          }
          rec.durationLabel = `Extended (+${days}d)`;
          await saveLicense(env, rec);
          toast = `Extended +${days}d`;
        }
      } else if (action === "life") {
        rec.lifetime = true;
        rec.expiresAt = null;
        rec.durationLabel = "Lifetime";
        await saveLicense(env, rec);
        toast = "Set to Lifetime";
      } else if (action === "devm1" || action === "dev1" || action === "dev5") {
        const delta = action === "devm1" ? -1 : (action === "dev1" ? 1 : 5);
        rec.maxDevices = Math.min(50, Math.max(1, (rec.maxDevices || 1) + delta));
        await saveLicense(env, rec);
        toast = `Max devices: ${rec.maxDevices}`;
      } else if (action === "clrnote") {
        rec.note = "";
        await saveLicense(env, rec);
        toast = "Note cleared";
      } else if (action === "unb" || action === "unball") {
        rec.deviceIds = [];
        rec.devices = {};
        await saveLicense(env, rec);
        toast = "All devices unbound (cloud backup safe)";
      } else if (action === "rev") {
        rec.revoked = true;
        await saveLicense(env, rec);
        toast = "Key revoked";
      } else if (action === "unrev") {
        rec.revoked = false;
        await saveLicense(env, rec);
        toast = "Key unrevoked";
      } else if (action === "ref") {
        toast = "Refreshed";
      }
      await editTelegramMessage(env, chatId, msgId, formatKeyDetails(rec), keyActionKeyboard(rec));
      await answerCallbackQuery(env, cq.id, toast);
      return new Response("ok");
    }

    if (parts[0] === "igdrop" && chatId) {
      await answerCallbackQuery(env, cq.id, "Creating IG drop...");
      const saved = await env.LICENSES.get(`admin:last_mp4:${senderId}`);
      const mp4Info = safeJsonParse(saved, null);
      if (!mp4Info?.mp4Url) {
        await sendTelegram(env, chatId, "No recent MP4 found. Send an XVideos link first.");
        return new Response("ok");
      }
      const dropId = randomId(10);
      await env.LICENSES.put(`igdrop:${dropId}`, JSON.stringify({ mp4Url: mp4Info.mp4Url, title: mp4Info.title || "Video", createdAt: nowSec() }), { expirationTtl: DAY_SEC });
      const openUrl = `${getPublicBaseUrl(env)}/ig/${dropId}`;
      await sendTelegram(env, chatId, `<b>Send MP4 to Instagram DM / Group</b>\n<code>${escapeHtmlTg(mp4Info.title || "Video")}</code>\n\n${openUrl}`, {
        inline_keyboard: [[{ text: "📤 Open in TinyTiny", url: openUrl }], [{ text: "🏠 Menu", callback_data: "menu:home" }]],
      });
      return new Response("ok");
    }

    await answerCallbackQuery(env, cq.id);
    return new Response("ok");
    } catch (err) {
      await answerCallbackQuery(env, cq.id, "Error — try again");
      return new Response("ok");
    }
  }

  const msg = update?.message;
  if (!msg || !msg.text) return new Response("ok");
  const chatId = msg.chat.id;
  const senderId = String(msg.from?.id || chatId);
  const text = msg.text.trim();
  const parts = text.split(/\s+/);
  const cmd = parts[0].split("@")[0].toLowerCase();

  if (cmd === "/myid") {
    const adminConfigured = Boolean(env.ADMIN_USER_ID);
    const isAdmin = adminConfigured && String(env.ADMIN_USER_ID) === senderId;
    await sendTelegram(
      env,
      chatId,
      `🆔 Your Telegram User ID is: <code>${senderId}</code>\n` +
        (isAdmin ? "Role: <b>ADMIN</b>" : adminConfigured ? "Unauthorized." : "Set via: <code>wrangler secret put ADMIN_USER_ID</code>"),
      isAdmin ? { inline_keyboard: [[{ text: "🏠 Open Button Panel", callback_data: "menu:home" }]] } : null
    );
    return new Response("ok");
  }

  if (cmd === "/start") {
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

  // Handle Force-Reply prompts from inline buttons (no slash commands needed!)
  const replyPrompt = msg.reply_to_message?.text || "";
  if (replyPrompt) {
    if (replyPrompt.includes("Search Keys")) {
      const res = await searchKeysResult(env, text);
      await sendTelegram(env, chatId, res.text, res.keyboard);
      return new Response("ok");
    }
    if (replyPrompt.includes("Set In-App Banner")) {
      const cfg = await getRemoteConfig(env);
      cfg.announcement = text;
      cfg.announcementId = `ann_${nowSec()}`;
      await saveRemoteConfig(env, cfg);
      const c = await buildConfigMenu(env);
      await sendTelegram(env, chatId, c.text, c.keyboard);
      return new Response("ok");
    }
    if (replyPrompt.includes("Enable Maintenance Gate")) {
      const cfg = await getRemoteConfig(env);
      cfg.maintenance = text;
      await saveRemoteConfig(env, cfg);
      const c = await buildConfigMenu(env);
      await sendTelegram(env, chatId, c.text, c.keyboard);
      return new Response("ok");
    }
    if (replyPrompt.includes("Set Minimum App Version")) {
      if (!/^\d+(\.\d+){0,2}$/.test(text)) {
        await sendTelegram(env, chatId, "Invalid version format. Use numbers like <code>1.3</code> or <code>1.3.1</code>.");
        return new Response("ok");
      }
      const cfg = await getRemoteConfig(env);
      cfg.minVersion = text;
      await saveRemoteConfig(env, cfg);
      const c = await buildConfigMenu(env);
      await sendTelegram(env, chatId, c.text, c.keyboard);
      return new Response("ok");
    }
    if (replyPrompt.includes("Direct IG Drop")) {
      let mp4Info = null;
      if (text.toLowerCase().includes("xvideos.com")) {
        mp4Info = await extractXVideosMP4(text);
      } else if (/^https?:\/\//i.test(text)) {
        mp4Info = { mp4Url: text, title: "Direct Video", pageUrl: text };
      }
      if (!mp4Info?.mp4Url) {
        await sendTelegram(env, chatId, "Could not extract an MP4 from that link.");
        return new Response("ok");
      }
      const dropId = randomId(10);
      await env.LICENSES.put(`igdrop:${dropId}`, JSON.stringify({ mp4Url: mp4Info.mp4Url, title: mp4Info.title || "Video", createdAt: nowSec() }), { expirationTtl: DAY_SEC });
      const openUrl = `${getPublicBaseUrl(env)}/ig/${dropId}`;
      await sendTelegram(env, chatId, `<b>Send MP4 to Instagram DM / Group</b>\n<code>${escapeHtmlTg(mp4Info.title || "Video")}</code>\n\n${openUrl}`, {
        inline_keyboard: [[{ text: "📤 Open in TinyTiny", url: openUrl }], [{ text: "🏠 Menu", callback_data: "menu:home" }]],
      });
      return new Response("ok");
    }
    const customGenMatch = replyPrompt.match(/Custom (ADMIN|STANDARD) Key \((\d+) dev\)/i);
    if (customGenMatch) {
      const isAdm = customGenMatch[1].toUpperCase() === "ADMIN";
      const maxDev = Math.min(50, Math.max(1, parseInt(customGenMatch[2], 10) || 1));
      const p = text.split(/\s+/);
      const durSpec = parseDuration(p[0]);
      if (!durSpec) {
        await sendTelegram(env, chatId, "Invalid duration. Examples: <code>90d VIP</code>, <code>48h Trial</code>, <code>lifetime</code>");
        return new Response("ok");
      }
      const note = p.slice(1).join(" ");
      const rec = await createAndSaveKey(env, { isAdmin: isAdm, durSpec, maxDevices: maxDev, note });
      await sendTelegram(env, chatId, formatKeyDetails(rec), keyActionKeyboard(rec));
      return new Response("ok");
    }
    const customExtMatch = replyPrompt.match(/Custom Extend for (TT-[A-Z0-9-]+)/i);
    if (customExtMatch) {
      const rec = await getLicense(env, customExtMatch[1]);
      const durSpec = parseDuration(text.split(/\s+/)[0]);
      if (!rec || !durSpec) {
        await sendTelegram(env, chatId, "Invalid duration or key not found.");
        return new Response("ok");
      }
      if (durSpec.lifetime) {
        rec.lifetime = true;
        rec.expiresAt = null;
        rec.durationLabel = "Lifetime";
      } else if (!rec.lifetime) {
        if (rec.activatedAt) {
          rec.expiresAt = Math.max(nowSec(), rec.expiresAt || nowSec()) + durSpec.seconds;
        } else {
          rec.durationSeconds = (rec.durationSeconds || 0) + durSpec.seconds;
        }
        rec.durationLabel = `Extended (+${durSpec.label})`;
      }
      await saveLicense(env, rec);
      await sendTelegram(env, chatId, formatKeyDetails(rec), keyActionKeyboard(rec));
      return new Response("ok");
    }
    const noteMatch = replyPrompt.match(/Set Note for (TT-[A-Z0-9-]+)/i);
    if (noteMatch) {
      const rec = await getLicense(env, noteMatch[1]);
      if (rec) {
        rec.note = text;
        await saveLicense(env, rec);
        await sendTelegram(env, chatId, formatKeyDetails(rec), keyActionKeyboard(rec));
      } else {
        await sendTelegram(env, chatId, "Key not found.");
      }
      return new Response("ok");
    }
  }

  if (cmd === "/builds") {
    await sendLatestBuildsToTelegram(env, chatId);
    return new Response("ok");
  }

  if (cmd === "/start" || cmd === "/menu") {
    const home = await buildHomeMenu(env);
    await sendTelegram(env, chatId, home.text, home.keyboard);
    return new Response("ok");
  }

  if (cmd === "/help") {
    await sendTelegram(
      env,
      chatId,
      [
        "<b>TinyTiny Slash Commands</b>",
        "<code>/menu</code> — Open button panel",
        "<code>/users</code> — Fleet &amp; iPhone/iOS breakdown",
        "<code>/allkeys</code> — Browse all keys",
        "<code>/info KEY</code> · <code>/find query</code>",
        "<code>/gen 30d [maxDevices] [note]</code> · <code>/genadmin ...</code>",
        "<code>/genbatch 5 30d [maxDevices] [note]</code>",
        "<code>/extend KEY 30d</code> · <code>/unbind KEY</code> · <code>/revoke KEY</code> · <code>/unrevoke KEY</code>",
        "<code>/note KEY text</code> · <code>/announce text</code> · <code>/maintenance text|off</code> · <code>/minversion 1.2|off</code>",
      ].join("\n"),
      { inline_keyboard: [[{ text: "🏠 Open Button Panel", callback_data: "menu:home" }]] }
    );
    return new Response("ok");
  }

  if (cmd === "/users" || cmd === "/stats") {
    const statsText = await buildUsersStatsMessage(env);
    await sendTelegram(env, chatId, statsText, {
      inline_keyboard: [[{ text: "🔄 Refresh", callback_data: "stats:ref" }, { text: "🔑 All Keys", callback_data: "keys:all:1" }, { text: "🏠 Menu", callback_data: "menu:home" }]],
    });
    return new Response("ok");
  }

  if (cmd === "/allkeys") {
    const arg = (parts[1] || "all").toLowerCase();
    const validFilters = new Set(["all", "active", "unused", "expired", "revoked", "admin"]);
    const filter = validFilters.has(arg) ? arg : "all";
    const page = validFilters.has(arg) ? (parseInt(parts[2] || "1", 10) || 1) : (parseInt(arg, 10) || 1);
    const res = await buildAllKeysPage(env, filter, page);
    await sendTelegram(env, chatId, res.text, res.keyboard);
    return new Response("ok");
  }

  if (cmd === "/gen" || cmd === "/genadmin") {
    const isAdminKey = cmd === "/genadmin";
    const durSpec = parseDuration(parts[1] || "30d");
    if (!durSpec) {
      await sendTelegram(
        env,
        chatId,
        `Invalid duration. Examples: <code>${cmd} 24h</code>, <code>${cmd} 7d</code>, <code>${cmd} 30d 2 Friend</code>, <code>${cmd} lifetime</code>`
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
    const rec = await createAndSaveKey(env, { isAdmin: isAdminKey, durSpec, maxDevices, note });

    await sendTelegram(env, chatId, formatKeyDetails(rec), keyActionKeyboard(rec));
    return new Response("ok");
  }

  if (cmd === "/info" || cmd === "/key") {
    const rec = await getLicense(env, parts[1]);
    if (!rec) {
      await sendTelegram(env, chatId, "Key not found.");
      return new Response("ok");
    }
    await sendTelegram(env, chatId, formatKeyDetails(rec), keyActionKeyboard(rec));
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
    await sendTelegram(
      env,
      chatId,
      `${formatKeyDetails(rec)}\n\n<i>Pick a specific device to unbind (cloud saves are kept safe):</i>`,
      unbindDevicesKeyboard(rec)
    );
    return new Response("ok");
  }

  if (cmd === "/setdevices") {
    const rec = await getLicense(env, parts[1]);
    const cap = parseInt(parts[2], 10);
    if (!rec || !Number.isFinite(cap) || cap < 1) {
      await sendTelegram(env, chatId, "Usage: <code>/setdevices TT-XXXX-XXXX-XXXX 5</code>");
      return new Response("ok");
    }
    rec.maxDevices = Math.min(50, Math.max(1, cap));
    await saveLicense(env, rec);
    await sendTelegram(env, chatId, formatKeyDetails(rec), keyActionKeyboard(rec));
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
    await sendTelegram(env, chatId, `Revoked <code>${rec.key}</code>.`, keyActionKeyboard(rec));
    return new Response("ok");
  }

  if (cmd === "/unrevoke") {
    const rec = await getLicense(env, parts[1]);
    if (!rec) {
      await sendTelegram(env, chatId, "Key not found.");
      return new Response("ok");
    }
    rec.revoked = false;
    await saveLicense(env, rec);
    await sendTelegram(env, chatId, `Restored <code>${rec.key}</code> -> <b>${formatRemaining(rec)}</b>`, keyActionKeyboard(rec));
    return new Response("ok");
  }

  if (cmd === "/genbatch") {
    const count = Math.min(25, Math.max(1, parseInt(parts[1] || "5", 10) || 5));
    const durSpec = parseDuration(parts[2] || "30d");
    if (!durSpec) {
      await sendTelegram(env, chatId, "Usage: <code>/genbatch 5 30d [maxDevices] [note]</code>");
      return new Response("ok");
    }
    let maxDevices = 1;
    let noteStart = 3;
    if (parts[3] && /^\d+$/.test(parts[3])) {
      maxDevices = Math.min(10, Math.max(1, parseInt(parts[3], 10)));
      noteStart = 4;
    }
    const note = parts.slice(noteStart).join(" ");
    const generated = [];
    for (let i = 0; i < count; i++) {
      const key = generateLicenseKey();
      const rec = {
        key,
        admin: false,
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
      generated.push(key);
    }
    const idxRaw = await env.LICENSES.get("index:recent");
    const idx = idxRaw ? JSON.parse(idxRaw) : [];
    await env.LICENSES.put("index:recent", JSON.stringify([...generated, ...idx].slice(0, 60)));
    await sendTelegram(
      env,
      chatId,
      `<b>Generated ${generated.length} Keys (${durSpec.label})</b>\n` +
        generated.map((k) => `<code>${k}</code>`).join("\n")
    );
    return new Response("ok");
  }

  if (cmd === "/note") {
    const rec = await getLicense(env, parts[1]);
    if (!rec) {
      await sendTelegram(env, chatId, "Usage: <code>/note TT-XXXX-XXXX-XXXX new note</code>");
      return new Response("ok");
    }
    rec.note = parts.slice(2).join(" ");
    await saveLicense(env, rec);
    await sendTelegram(env, chatId, formatKeyDetails(rec), keyActionKeyboard(rec));
    return new Response("ok");
  }

  if (cmd === "/find") {
    const q = parts.slice(1).join(" ").trim().toLowerCase();
    if (!q) {
      await sendTelegram(env, chatId, "Usage: <code>/find iPhone 15</code> or <code>/find note</code>");
      return new Response("ok");
    }
    const all = await listAllLicenses(env);
    const hits = all.filter((rec) => {
      if ((rec.key || "").toLowerCase().includes(q)) return true;
      if ((rec.note || "").toLowerCase().includes(q)) return true;
      if (rec.devices) {
        for (const info of Object.values(rec.devices)) {
          const hay = `${info.model || ""} ${info.modelId || ""} ios ${info.ios || ""}`.toLowerCase();
          if (hay.includes(q)) return true;
        }
      }
      return false;
    });
    const lines = hits.slice(0, 20).map((rec) => {
      const devs = rec.devices ? Object.values(rec.devices) : [];
      const devTag = devs.length ? ` · ${escapeHtmlTg(devs[0].model || "")} (${escapeHtmlTg(devs[0].ios || "?")})` : "";
      return `<code>${rec.key}</code> — ${formatRemaining(rec)}${devTag}${rec.note ? ` (${escapeHtmlTg(rec.note)})` : ""}`;
    });
    await sendTelegram(
      env,
      chatId,
      `<b>Search "${escapeHtmlTg(q)}" (${hits.length} match${hits.length === 1 ? "" : "es"})</b>\n` +
        (lines.length ? lines.join("\n") : "No matches.")
    );
    return new Response("ok");
  }

  if (cmd === "/announce") {
    const message = parts.slice(1).join(" ").trim();
    if (!message) {
      await sendTelegram(env, chatId, "Usage: <code>/announce New update available!</code>");
      return new Response("ok");
    }
    const cfg = await getRemoteConfig(env);
    cfg.announcement = message;
    cfg.announcementId = `ann_${nowSec()}`;
    await saveRemoteConfig(env, cfg);
    await sendTelegram(env, chatId, `In-app announcement set:\n<i>${escapeHtmlTg(message)}</i>`);
    return new Response("ok");
  }

  if (cmd === "/clearannounce") {
    const cfg = await getRemoteConfig(env);
    cfg.announcement = null;
    cfg.announcementId = null;
    await saveRemoteConfig(env, cfg);
    await sendTelegram(env, chatId, "In-app announcement cleared.");
    return new Response("ok");
  }

  if (cmd === "/maintenance") {
    const val = parts.slice(1).join(" ").trim();
    const cfg = await getRemoteConfig(env);
    if (!val || val.toLowerCase() === "off") {
      cfg.maintenance = null;
      await saveRemoteConfig(env, cfg);
      await sendTelegram(env, chatId, "Maintenance mode turned <b>OFF</b>.");
    } else {
      cfg.maintenance = val;
      await saveRemoteConfig(env, cfg);
      await sendTelegram(env, chatId, `Maintenance mode <b>ON</b>:\n<i>${escapeHtmlTg(val)}</i>`);
    }
    return new Response("ok");
  }

  if (cmd === "/minversion") {
    const val = (parts[1] || "").trim();
    const cfg = await getRemoteConfig(env);
    if (!val || val.toLowerCase() === "off") {
      cfg.minVersion = null;
      await saveRemoteConfig(env, cfg);
      await sendTelegram(env, chatId, "Minimum app version gate turned <b>OFF</b>.");
    } else {
      cfg.minVersion = val;
      await saveRemoteConfig(env, cfg);
      await sendTelegram(env, chatId, `Minimum app version set to <b>v${escapeHtmlTg(val)}</b>.`);
    }
    return new Response("ok");
  }

  if (cmd === "/alerts") {
    const mode = (parts[1] || "").toLowerCase();
    if (mode === "on" || mode === "off") {
      await env.LICENSES.put("alerts:enabled", mode === "on" ? "1" : "0");
      await sendTelegram(env, chatId, `Activation &amp; error alerts: <b>${mode.toUpperCase()}</b>`);
    } else {
      const cur = (await env.LICENSES.get("alerts:enabled")) === "1" ? "ON" : "OFF";
      await sendTelegram(env, chatId, `Alerts are currently <b>${cur}</b>. Use <code>/alerts on</code> or <code>/alerts off</code>.`);
    }
    return new Response("ok");
  }

  if (cmd === "/errors") {
    const raw = await env.LICENSES.get("errors:recent");
    const list = raw ? JSON.parse(raw) : [];
    if (!list.length) {
      await sendTelegram(env, chatId, "No recent anonymous error reports.");
      return new Response("ok");
    }
    const lines = list.slice(0, 15).map((e) => {
      const ago = Math.max(0, Math.floor((nowSec() - (e.at || 0)) / 60));
      return `• <b>${escapeHtmlTg(e.source)}</b> — ${escapeHtmlTg(e.model || "iPhone")} (iOS ${escapeHtmlTg(e.ios || "?")}, v${escapeHtmlTg(e.app || "1.0")}) · ${ago}m ago\n  <i>${escapeHtmlTg(e.detail || "")}</i>`;
    });
    await sendTelegram(env, chatId, `<b>Recent Anonymous Error Reports</b>\n${lines.join("\n")}`);
    return new Response("ok");
  }

  if (cmd === "/config") {
    const cfg = await getRemoteConfig(env);
    const alerts = (await env.LICENSES.get("alerts:enabled")) === "1" ? "ON" : "OFF";
    await sendTelegram(
      env,
      chatId,
      [
        `<b>Remote App Config</b>`,
        `Announcement: ${cfg.announcement ? escapeHtmlTg(cfg.announcement) : "<i>None</i>"}`,
        `Maintenance: ${cfg.maintenance ? escapeHtmlTg(cfg.maintenance) : "<i>OFF</i>"}`,
        `Min Version: ${cfg.minVersion ? `<b>v${escapeHtmlTg(cfg.minVersion)}</b>` : "<i>OFF</i>"}`,
        `Telegram Alerts: <b>${alerts}</b>`,
      ].join("\n")
    );
    return new Response("ok");
  }

  if (cmd === "/watchit") {
    const res = await syncWatchitFolder(env, getPublicBaseUrl(env), true);
    if (!res.ok) {
      await sendTelegram(env, chatId, `Watchit sync error: ${res.error}`);
    } else if (res.sent === 0) {
      await sendTelegram(
        env,
        chatId,
        `Seedr <code>/Watchit/</code> is ready (${res.total} video${res.total === 1 ? "" : "s"} tracked, no new uploads).`
      );
    }
    return new Response("ok");
  }

  if (cmd === "/directig") {
    let mp4Info = null;
    if (parts[1] && /^https?:\/\//i.test(parts[1])) {
      if (parts[1].toLowerCase().includes("xvideos.com")) {
        mp4Info = await extractXVideosMP4(parts[1]);
      } else {
        mp4Info = { mp4Url: parts[1], title: "Direct Video", pageUrl: parts[1] };
      }
    } else {
      const saved = await env.LICENSES.get(`admin:last_mp4:${senderId}`);
      if (saved) mp4Info = JSON.parse(saved);
    }

    if (!mp4Info || !mp4Info.mp4Url) {
      await sendTelegram(
        env,
        chatId,
        "No recent MP4 found. Send an XVideos link first, or run <code>/directig https://...</code>"
      );
      return new Response("ok");
    }

    const dropId = randomId(10);
    await env.LICENSES.put(
      `igdrop:${dropId}`,
      JSON.stringify({ mp4Url: mp4Info.mp4Url, title: mp4Info.title || "Video", createdAt: nowSec() }),
      { expirationTtl: DAY_SEC }
    );
    const openUrl = `${getPublicBaseUrl(env)}/ig/${dropId}`;
    await sendTelegram(
      env,
      chatId,
      `<b>Send MP4 to Instagram DM / Group</b>\n<code>${escapeHtmlTg(mp4Info.title || "Video")}</code>\n\nTap below to list your IG DMs &amp; Group Chats in TinyTiny:\n${openUrl}`
    );
    return new Response("ok");
  }

  // Auto-extract MP4 when Admin pastes an XVideos URL
  const xvMatch = text.match(/https?:\/\/(?:www\.)?xvideos\.com\/[^\s]+/i);
  if (xvMatch) {
    const info = await extractXVideosMP4(xvMatch[0]);
    if (!info || !info.mp4Url) {
      await sendTelegram(env, chatId, "Could not extract an MP4 from that XVideos link.");
      return new Response("ok");
    }
    const xvId = randomId(10);
    await env.LICENSES.put(`xv:${xvId}`, JSON.stringify(info), { expirationTtl: DAY_SEC });
    await env.LICENSES.put(`admin:last_mp4:${senderId}`, JSON.stringify(info), { expirationTtl: DAY_SEC });
    const proxyMp4 = `${getPublicBaseUrl(env)}/xv/${xvId}/video.mp4`;
    await sendTelegram(
      env,
      chatId,
      `<b>XVideos MP4 Ready</b>\n<code>${escapeHtmlTg(info.title)}</code>\n\nMP4 Link:\n${proxyMp4}`,
      { inline_keyboard: [[{ text: "📤 Send to Instagram DM / Group", callback_data: "igdrop:last" }], [{ text: "🏠 Menu", callback_data: "menu:home" }]] }
    );
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

// MARK: - DirectStuff Encrypted R2 Video Streaming & Direct Download

function b64UrlToUint8(str) {
  const pad = "=".repeat((4 - (str.length % 4)) % 4);
  const b64 = (str + pad).replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function b64ToUint8(str) {
  const bin = atob(str);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function isDirectAuthorized(request, env) {
  const secret = env.DIRECT_UPLOAD_SECRET;
  if (!secret) return false;
  const provided = request.headers.get("X-Direct-Secret") || "";
  if (provided.length !== secret.length || provided.length === 0) return false;
  const a = new TextEncoder().encode(provided);
  const b = new TextEncoder().encode(secret);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

function parseByteRange(rangeHeader, totalSize) {
  if (!rangeHeader || !rangeHeader.startsWith("bytes=")) return null;
  const spec = rangeHeader.slice(6).split(",")[0].trim();
  const [startStr, endStr] = spec.split("-");
  let start, end;
  if (startStr === "") {
    const suffix = Number(endStr);
    if (!Number.isFinite(suffix) || suffix <= 0) return { invalid: true };
    start = Math.max(0, totalSize - suffix);
    end = totalSize - 1;
  } else {
    start = Number(startStr);
    end = endStr ? Number(endStr) : totalSize - 1;
  }
  if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || start >= totalSize || end < start) {
    return { invalid: true };
  }
  end = Math.min(end, totalSize - 1);
  return { start, end, invalid: false };
}

function counterForBlock(nonce16, blockIndex) {
  const counter = new Uint8Array(nonce16);
  const view = new DataView(counter.buffer, counter.byteOffset, counter.byteLength);
  const base = view.getBigUint64(8, false);
  view.setBigUint64(8, base + blockIndex, false);
  return counter;
}

async function createCtrDecryptStream(keyBytes, nonce16, byteOffset) {
  const cryptoKey = await crypto.subtle.importKey("raw", keyBytes, { name: "AES-CTR" }, false, ["decrypt"]);
  let blockIndex = BigInt(Math.floor(byteOffset / 16));
  let skipFirst = byteOffset % 16;
  let pending = new Uint8Array(0);
  const CHUNK_TARGET = 65536; // 64 KB (exact multiple of 16 bytes)

  async function decryptBlockAligned(bytes, controller) {
    const counter = counterForBlock(nonce16, blockIndex);
    const plainBuf = await crypto.subtle.decrypt({ name: "AES-CTR", counter, length: 64 }, cryptoKey, bytes);
    blockIndex += BigInt(Math.floor(bytes.byteLength / 16));
    let out = new Uint8Array(plainBuf);
    if (skipFirst > 0) {
      out = out.subarray(skipFirst);
      skipFirst = 0;
    }
    if (out.byteLength > 0) controller.enqueue(out);
  }

  return new TransformStream({
    async transform(chunk, controller) {
      const merged = new Uint8Array(pending.byteLength + chunk.byteLength);
      merged.set(pending, 0);
      merged.set(chunk, pending.byteLength);
      pending = merged;

      while (pending.byteLength >= CHUNK_TARGET) {
        const slice = pending.subarray(0, CHUNK_TARGET);
        pending = pending.subarray(CHUNK_TARGET);
        await decryptBlockAligned(slice, controller);
      }
    },
    async flush(controller) {
      if (pending.byteLength > 0) {
        await decryptBlockAligned(pending, controller);
        pending = new Uint8Array(0);
      }
    },
  });
}

function formatBytesHuman(bytes) {
  if (!bytes || bytes < 1024) return `${bytes || 0} B`;
  const units = ["KB", "MB", "GB"];
  let v = bytes / 1024;
  let u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return `${v.toFixed(1)} ${units[u]}`;
}

function sanitizeFilename(name) {
  return String(name || "video.mp4").replace(/["\\\r\n]/g, "_");
}

function renderDirectVideoHTML(id, meta) {
  const safeName = sanitizeFilename(meta.filename || "video.mp4")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
  const sizeLabel = formatBytesHuman(meta.size);
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>${safeName} · TinyTiny Direct</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; min-height: 100vh; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: radial-gradient(circle at top, #220b15, #090609 65%); color: #fff; display: flex; align-items: center; justify-content: center; padding: 20px; box-sizing: border-box; }
  .wrap { width: 100%; max-width: 780px; background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.12); border-radius: 22px; padding: 20px; box-shadow: 0 24px 70px rgba(0,0,0,0.55); }
  .top { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 14px; }
  .title { font-size: 16px; font-weight: 700; word-break: break-word; }
  .sub { font-size: 12px; color: #b5a9b0; margin-top: 2px; }
  video { width: 100%; max-height: 70vh; border-radius: 14px; background: #000; display: block; }
  .actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 14px; }
  .btn { display: inline-flex; align-items: center; justify-content: center; gap: 8px; padding: 12px 18px; border-radius: 999px; font-size: 14px; font-weight: 700; text-decoration: none; cursor: pointer; border: none; }
  .btn-primary { background: linear-gradient(135deg, #ff3b7f, #d91b5c); color: #fff; }
  .btn-ghost { background: rgba(255,255,255,0.09); color: #fff; border: 1px solid rgba(255,255,255,0.15); }
  .err { color: #ff7a9f; font-size: 14px; padding: 18px 0; display: none; }
</style>
</head>
<body>
  <div class="wrap">
    <div class="top">
      <div>
        <div class="title">${safeName}</div>
        <div class="sub">${sizeLabel} · AES-256-CTR Encrypted R2 Stream</div>
      </div>
    </div>
    <div id="err" class="err">Missing decryption key (?k=...) in URL.</div>
    <video id="player" controls playsinline preload="metadata"></video>
    <div class="actions">
      <a id="dlBtn" class="btn btn-primary" href="#" download="${safeName}">Download Video</a>
      <button id="copyBtn" class="btn btn-ghost" type="button">Copy Direct Download URL</button>
    </div>
  </div>
  <script>
    const k = new URLSearchParams(location.search).get("k");
    const player = document.getElementById("player");
    const dlBtn = document.getElementById("dlBtn");
    const copyBtn = document.getElementById("copyBtn");
    const err = document.getElementById("err");
    if (!k) {
      player.style.display = "none";
      dlBtn.style.display = "none";
      err.style.display = "block";
    } else {
      const q = "?k=" + encodeURIComponent(k);
      player.src = "/d/${id}/video" + q;
      const dlUrl = location.origin + "/d/${id}/download" + q;
      dlBtn.href = dlUrl;
      copyBtn.onclick = async () => {
        await navigator.clipboard.writeText(dlUrl);
        copyBtn.textContent = "Copied!";
        setTimeout(() => (copyBtn.textContent = "Copy Direct Download URL"), 1800);
      };
    }
  </script>
</body>
</html>`;
}

export default {
  async fetch(request, env, ctx) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
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
      const check = validateRecordAccess(rec, body.deviceId, { requireDeviceId: true });
      if (!check.ok) return json({ valid: false, error: check.error }, 403);

      const dev = String(body.deviceId || "").trim();
      let changed = false;
      let isFirstActivation = false;
      if (!rec.activatedAt) {
        rec.activatedAt = nowSec();
        rec.expiresAt = rec.lifetime ? null : rec.activatedAt + (rec.durationSeconds || 30 * DAY_SEC);
        changed = true;
        isFirstActivation = true;
      }
      if (dev && !(rec.deviceIds || []).includes(dev)) {
        rec.deviceIds = [...(rec.deviceIds || []), dev];
        changed = true;
      }
      if (recordDeviceTelemetry(rec, dev, body.deviceInfo)) {
        changed = true;
      }
      if (changed) await saveLicense(env, rec);

      if (isFirstActivation && env.ADMIN_USER_ID && (await env.LICENSES.get("alerts:enabled")) === "1") {
        const d = body.deviceInfo || {};
        const alertPromise = sendTelegram(
          env,
          env.ADMIN_USER_ID,
          `🔑 <b>Key Activated</b>\n<code>${rec.key}</code>${rec.note ? ` (${escapeHtmlTg(rec.note)})` : ""}\nDevice: ${escapeHtmlTg(d.model || "Device")} · ${escapeHtmlTg(formatOsLabel(d.ios))} · v${escapeHtmlTg(d.app || "1.0")}`
        ).catch(() => null);
        if (ctx?.waitUntil) ctx.waitUntil(alertPromise);
      }

      const config = await getRemoteConfig(env);
      return json({
        valid: true,
        admin: Boolean(rec.admin),
        lifetime: Boolean(rec.lifetime),
        expiresAt: rec.expiresAt,
        durationLabel: rec.durationLabel,
        config,
      });
    }

    // 3. Silent Verification
    if (request.method === "POST" && path === "/v1/verify") {
      const body = await request.json().catch(() => ({}));
      const rec = await getLicense(env, body.key);
      const check = validateRecordAccess(rec, body.deviceId, { requireDeviceId: true });
      if (!check.ok) return json({ valid: false, error: check.error }, 200);

      const dev = String(body.deviceId || "").trim();
      if (dev && (rec.deviceIds || []).includes(dev) && recordDeviceTelemetry(rec, dev, body.deviceInfo)) {
        await saveLicense(env, rec);
      }

      const config = await getRemoteConfig(env);
      return json({
        valid: true,
        admin: Boolean(rec.admin),
        lifetime: Boolean(rec.lifetime),
        expiresAt: rec.expiresAt,
        durationLabel: rec.durationLabel,
        config,
      });
    }

    // 3b. Remote Config & Anonymous Error Telemetry
    if (request.method === "GET" && path === "/v1/config") {
      return json(await getRemoteConfig(env));
    }

    if (request.method === "POST" && path === "/v1/report-error") {
      const body = await request.json().catch(() => ({}));
      const source = String(body.source || "Unknown").slice(0, 40);
      const detail = String(body.detail || "").slice(0, 240);
      const devId = String(body.deviceId || "anon").slice(0, 48);
      const d = body.deviceInfo || {};
      const rlKey = `err_rl:${devId}:${source}`;
      if (await env.LICENSES.get(rlKey)) {
        return json({ ok: true, throttled: true });
      }
      await env.LICENSES.put(rlKey, "1", { expirationTtl: 300 });

      const raw = await env.LICENSES.get("errors:recent");
      const list = safeJsonParse(raw, []);
      list.unshift({
        source,
        detail,
        model: String(d.model || "Device").slice(0, 48),
        ios: String(d.ios || "?").slice(0, 20),
        app: String(d.app || "1.0").slice(0, 20),
        at: nowSec(),
      });
      await env.LICENSES.put("errors:recent", JSON.stringify(list.slice(0, 25)));

      if (env.ADMIN_USER_ID && (await env.LICENSES.get("alerts:enabled")) === "1") {
        const alertPromise = sendTelegram(
          env,
          env.ADMIN_USER_ID,
          `⚠️ <b>${escapeHtmlTg(source)} Error</b>\n${escapeHtmlTg(d.model || "Device")} (${escapeHtmlTg(formatOsLabel(d.ios))}, v${escapeHtmlTg(d.app || "1.0")})\n<i>${escapeHtmlTg(detail)}</i>`
        ).catch(() => null);
        if (ctx?.waitUntil) ctx.waitUntil(alertPromise);
      }
      return json({ ok: true });
    }

    // 4. Zero-Knowledge Encrypted Profile Sync (Client-encrypted Likes/Follows/Seedr Key)
    if (request.method === "PUT" && path === "/v1/backup") {
      const body = await request.json().catch(() => ({}));
      const rec = await getLicense(env, body.key);
      const check = validateRecordAccess(rec, body.deviceId, { requireDeviceId: true });
      if (!check.ok) return json({ error: check.error }, 403);
      if (!body.blob || typeof body.blob !== "string") return json({ error: "Missing blob" }, 400);
      if (body.blob.length > 12 * 1024 * 1024) return json({ error: "Backup exceeds 12MB cap" }, 413);

      const existingBlob = await env.LICENSES.get(`backup:${rec.key}`);
      if (existingBlob && existingBlob !== body.blob) {
        await env.LICENSES.put(`backup_prev:${rec.key}`, existingBlob);
      }
      const version = String(Date.now());
      await env.LICENSES.put(`backup:${rec.key}`, body.blob, { metadata: { version } });
      await env.LICENSES.put(`backup_ver:${rec.key}`, version);
      return json({ ok: true, version });
    }

    if (request.method === "POST" && path === "/v1/backup/version") {
      const body = await request.json().catch(() => ({}));
      const rec = await getLicense(env, body.key);
      const check = validateRecordAccess(rec, body.deviceId, { requireDeviceId: true });
      if (!check.ok) return json({ error: check.error }, 403);

      const version = await env.LICENSES.get(`backup_ver:${rec.key}`);
      return json({ version: version || null });
    }

    if (request.method === "POST" && path === "/v1/backup/get") {
      const body = await request.json().catch(() => ({}));
      const rec = await getLicense(env, body.key);
      const check = validateRecordAccess(rec, body.deviceId, { requireDeviceId: true });
      if (!check.ok) return json({ error: check.error }, 403);

      const { value: blob, metadata } = await env.LICENSES.getWithMetadata(`backup:${rec.key}`);
      if (!blob) return json({ error: "No backup yet" }, 404);
      const version = metadata?.version || (await env.LICENSES.get(`backup_ver:${rec.key}`)) || null;
      return json({ blob, version });
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
        const meta = safeJsonParse(metaRaw, null);
        if (meta?.backend === "seedr" && meta?.path) {
          const upstream = await seedrFetchEncryptedBlob(env, meta.path);
          if (upstream) {
            return new Response(upstream.body, {
              headers: {
                "Content-Type": "application/octet-stream",
                "Cache-Control": "public, max-age=3600",
                "Access-Control-Allow-Origin": "*",
              },
            });
          }
          return json({ error: "Encrypted storage backend temporarily unavailable" }, 502);
        }
      }

      const buf = await env.LICENSES.get(`blob:${id}`, "arrayBuffer");
      if (!buf) return json({ error: "Not found or expired" }, 404);
      return new Response(buf, {
        headers: {
          "Content-Type": "application/octet-stream",
          "Cache-Control": "public, max-age=3600",
          "Access-Control-Allow-Origin": "*",
        },
      });
    }

    // 7. DirectStuff Encrypted R2 Upload + On-the-Fly Decrypt Streaming + Direct Download
    if (request.method === "POST" && path === "/v1/direct/init") {
      if (!isDirectAuthorized(request, env)) return json({ error: "Unauthorized" }, 403);
      if (!env.DIRECT_R2) return json({ error: "R2 bucket DIRECT_R2 not bound" }, 500);

      const body = await request.json().catch(() => ({}));
      const filename = sanitizeFilename(body.filename || "video.mp4");
      const contentType = String(body.contentType || "video/mp4");
      const size = Number(body.size || 0);
      const nonceB64 = String(body.nonceB64 || "");
      if (!size || !nonceB64) return json({ error: "Missing size or nonceB64" }, 400);

      const id = randomId(12);
      const r2Key = `direct/${id}.enc`;
      const multipart = size > 90 * 1024 * 1024;
      let uploadId = null;
      if (multipart) {
        const mpu = await env.DIRECT_R2.createMultipartUpload(r2Key);
        uploadId = mpu.uploadId;
      }

      return json({ ok: true, id, r2Key, multipart, uploadId, filename, contentType, size });
    }

    if (request.method === "PUT" && path.startsWith("/v1/direct/upload/")) {
      if (!isDirectAuthorized(request, env)) return json({ error: "Unauthorized" }, 403);
      if (!env.DIRECT_R2) return json({ error: "R2 bucket DIRECT_R2 not bound" }, 500);

      const id = path.slice("/v1/direct/upload/".length).replace(/[^a-z0-9]/gi, "");
      if (!id) return json({ error: "Invalid id" }, 400);

      const filename = sanitizeFilename(request.headers.get("X-File-Name") || "video.mp4");
      const contentType = request.headers.get("X-Mime-Type") || "video/mp4";
      const nonceB64 = request.headers.get("X-Nonce-B64") || "";
      const size = Number(request.headers.get("Content-Length") || 0);
      if (!nonceB64) return json({ error: "Missing X-Nonce-B64" }, 400);

      const r2Key = `direct/${id}.enc`;
      const buf = await request.arrayBuffer();
      await env.DIRECT_R2.put(r2Key, buf);

      const meta = {
        filename,
        contentType,
        size: size || buf.byteLength,
        nonceB64,
        r2Key,
        createdAt: nowSec(),
      };
      await env.LICENSES.put(`direct:${id}`, JSON.stringify(meta));
      return json({
        ok: true,
        id,
        watchPath: `/d/${id}`,
        videoPath: `/d/${id}/video`,
        downloadPath: `/d/${id}/download`,
      });
    }

    if (request.method === "PUT" && path.startsWith("/v1/direct/part/")) {
      if (!isDirectAuthorized(request, env)) return json({ error: "Unauthorized" }, 403);
      if (!env.DIRECT_R2) return json({ error: "R2 bucket DIRECT_R2 not bound" }, 500);

      const id = path.slice("/v1/direct/part/".length).replace(/[^a-z0-9]/gi, "");
      const uploadId = url.searchParams.get("uploadId") || "";
      const partNumber = Number(url.searchParams.get("partNumber") || 0);
      if (!id || !uploadId || partNumber < 1) return json({ error: "Invalid multipart params" }, 400);

      const mpu = env.DIRECT_R2.resumeMultipartUpload(`direct/${id}.enc`, uploadId);
      const buf = await request.arrayBuffer();
      const uploaded = await mpu.uploadPart(partNumber, buf);
      return json({ ok: true, partNumber: uploaded.partNumber, etag: uploaded.etag });
    }

    if (request.method === "POST" && path.startsWith("/v1/direct/complete/")) {
      if (!isDirectAuthorized(request, env)) return json({ error: "Unauthorized" }, 403);
      if (!env.DIRECT_R2) return json({ error: "R2 bucket DIRECT_R2 not bound" }, 500);

      const id = path.slice("/v1/direct/complete/".length).replace(/[^a-z0-9]/gi, "");
      const body = await request.json().catch(() => ({}));
      const { uploadId, parts, filename, contentType, size, nonceB64 } = body;
      if (!id || !uploadId || !Array.isArray(parts) || !size || !nonceB64) {
        return json({ error: "Invalid complete payload" }, 400);
      }

      const r2Key = `direct/${id}.enc`;
      const mpu = env.DIRECT_R2.resumeMultipartUpload(r2Key, uploadId);
      await mpu.complete(parts);

      const meta = {
        filename: sanitizeFilename(filename || "video.mp4"),
        contentType: String(contentType || "video/mp4"),
        size: Number(size),
        nonceB64: String(nonceB64),
        r2Key,
        createdAt: nowSec(),
      };
      await env.LICENSES.put(`direct:${id}`, JSON.stringify(meta));
      return json({
        ok: true,
        id,
        watchPath: `/d/${id}`,
        videoPath: `/d/${id}/video`,
        downloadPath: `/d/${id}/download`,
      });
    }

    if ((request.method === "GET" || request.method === "HEAD") && path.startsWith("/d/")) {
      if (!env.DIRECT_R2) return new Response("R2 storage not configured", { status: 500 });
      const parts = path.slice(3).split("/").filter(Boolean);
      const id = (parts[0] || "").replace(/[^a-z0-9]/gi, "");
      const sub = parts[1] || "";
      if (!id) return new Response("Not found", { status: 404 });

      const metaRaw = await env.LICENSES.get(`direct:${id}`);
      if (!metaRaw) return new Response("Video not found or removed", { status: 404 });
      const meta = JSON.parse(metaRaw);

      if (!sub) {
        return new Response(renderDirectVideoHTML(id, meta), {
          headers: {
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store",
          },
        });
      }

      if (sub !== "video" && sub !== "download") {
        return new Response("Not found", { status: 404 });
      }

      const kParam = url.searchParams.get("k") || "";
      if (!kParam) return new Response("Missing decryption key (?k=...)", { status: 403 });

      let keyBytes;
      let nonceBytes;
      try {
        keyBytes = b64UrlToUint8(kParam);
        nonceBytes = b64ToUint8(meta.nonceB64);
      } catch {
        return new Response("Invalid decryption key", { status: 400 });
      }
      if (keyBytes.byteLength !== 32 || nonceBytes.byteLength !== 16) {
        return new Response("Invalid key or nonce length", { status: 400 });
      }

      const totalSize = Number(meta.size);
      const rangeHeader = request.headers.get("Range");
      const parsedRange = parseByteRange(rangeHeader, totalSize);
      if (parsedRange?.invalid) {
        return new Response("Range Not Satisfiable", {
          status: 416,
          headers: { "Content-Range": `bytes */${totalSize}` },
        });
      }

      const isRange = Boolean(parsedRange);
      const start = isRange ? parsedRange.start : 0;
      const end = isRange ? parsedRange.end : totalSize - 1;
      const outLen = end - start + 1;
      const disp = sub === "download" ? "attachment" : "inline";
      const safeFile = sanitizeFilename(meta.filename);

      const headers = new Headers({
        "Content-Type": meta.contentType || "video/mp4",
        "Accept-Ranges": "bytes",
        "Content-Length": String(outLen),
        "Content-Disposition": `${disp}; filename="${safeFile}"`,
        "Cache-Control": "private, no-store",
        "Access-Control-Allow-Origin": "*",
      });
      if (isRange) {
        headers.set("Content-Range", `bytes ${start}-${end}/${totalSize}`);
      }

      if (request.method === "HEAD") {
        return new Response(null, { status: isRange ? 206 : 200, headers });
      }

      const alignedStart = start - (start % 16);
      const fetchLen = end - alignedStart + 1;
      const obj = await env.DIRECT_R2.get(meta.r2Key, {
        range: { offset: alignedStart, length: fetchLen },
      });
      if (!obj || !obj.body) {
        return new Response("Encrypted object missing from R2", { status: 404 });
      }

      const decryptStream = await createCtrDecryptStream(keyBytes, nonceBytes, start);
      const bodyStream = obj.body.pipeThrough(decryptStream);
      return new Response(bodyStream, { status: isRange ? 206 : 200, headers });
    }

    // 8. Seedr "Watchit" Folder -> Public Watch + Direct Download URLs
    if ((request.method === "GET" || request.method === "HEAD") && path.startsWith("/w/")) {
      const parts = path.slice(3).split("/").filter(Boolean);
      const id = (parts[0] || "").replace(/[^a-z0-9]/gi, "");
      const sub = parts[1] || "";
      if (!id) return new Response("Not found", { status: 404 });

      const metaRaw = await env.LICENSES.get(`watchit:${id}`);
      if (!metaRaw) return new Response("Video not found or removed", { status: 404 });
      const meta = JSON.parse(metaRaw);

      if (!sub) {
        return new Response(renderWatchitHTML(id, meta), {
          headers: {
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store",
          },
        });
      }

      if (sub !== "video" && sub !== "download") {
        return new Response("Not found", { status: 404 });
      }

      const auth = seedrAuthHeader(env);
      if (!auth) return new Response("Seedr credentials not configured", { status: 500 });

      const encodedPath = meta.davPath
        .split("/")
        .filter(Boolean)
        .map((s) => encodeURIComponent(s))
        .join("/");
      const seedrUrl = `${SEEDR_DAV_BASE}/${encodedPath}`;
      const reqHeaders = { Authorization: auth };
      const rangeHeader = request.headers.get("Range");
      if (rangeHeader) reqHeaders["Range"] = rangeHeader;

      const upstream = await fetch(seedrUrl, {
        method: request.method,
        headers: reqHeaders,
      });
      if (!upstream.ok && upstream.status !== 206) {
        return new Response("Video unavailable on Seedr", { status: upstream.status === 404 ? 404 : 502 });
      }

      const disp = sub === "download" ? "attachment" : "inline";
      const safeFile = sanitizeFilename(meta.filename);
      const outHeaders = new Headers({
        "Content-Type": meta.contentType || upstream.headers.get("Content-Type") || "video/mp4",
        "Accept-Ranges": "bytes",
        "Content-Disposition": `${disp}; filename="${safeFile}"`,
        "Cache-Control": "private, max-age=300",
        "Access-Control-Allow-Origin": "*",
      });
      const cl = upstream.headers.get("Content-Length");
      if (cl) outHeaders.set("Content-Length", cl);
      const cr = upstream.headers.get("Content-Range");
      if (cr) outHeaders.set("Content-Range", cr);

      return new Response(request.method === "HEAD" ? null : upstream.body, {
        status: upstream.status,
        headers: outHeaders,
      });
    }

    // 9. XVideos MP4 Proxy + DirectIG Drop Redirector
    if ((request.method === "GET" || request.method === "HEAD") && path.startsWith("/xv/")) {
      const id = (path.slice(4).split("/")[0] || "").replace(/[^a-z0-9]/gi, "");
      const raw = id ? await env.LICENSES.get(`xv:${id}`) : null;
      if (!raw) return new Response("Not found or expired", { status: 404 });
      const info = JSON.parse(raw);
      const reqHeaders = {
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
        Referer: "https://www.xvideos.com/",
      };
      const range = request.headers.get("Range");
      if (range) reqHeaders["Range"] = range;
      const upstream = await fetch(info.mp4Url, { method: request.method, headers: reqHeaders });
      const outHeaders = new Headers({
        "Content-Type": "video/mp4",
        "Accept-Ranges": "bytes",
        "Content-Disposition": `inline; filename="xvideos_${id}.mp4"`,
        "Access-Control-Allow-Origin": "*",
      });
      for (const h of ["content-length", "content-range"]) {
        const v = upstream.headers.get(h);
        if (v) outHeaders.set(h, v);
      }
      return new Response(request.method === "HEAD" ? null : upstream.body, {
        status: upstream.status,
        headers: outHeaders,
      });
    }

    if (request.method === "GET" && path.startsWith("/v1/igdrop/")) {
      const id = path.slice("/v1/igdrop/".length).replace(/[^a-z0-9]/gi, "");
      const raw = id ? await env.LICENSES.get(`igdrop:${id}`) : null;
      if (!raw) return json({ error: "Not found or expired" }, 404);
      return json(JSON.parse(raw));
    }

    if (request.method === "GET" && path.startsWith("/ig/")) {
      const id = path.slice(4).replace(/[^a-z0-9]/gi, "");
      const deepLink = `tinytiny://directig/${id}`;
      return new Response(
        `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Open TinyTiny</title><meta http-equiv="refresh" content="0;url=${deepLink}"><style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#070306;color:#fff;font-family:-apple-system,sans-serif;text-align:center;padding:24px;}a{display:inline-block;margin-top:16px;padding:14px 24px;border-radius:999px;background:#f73677;color:#fff;font-weight:700;text-decoration:none;}</style></head><body><div><h2>Send MP4 to Instagram</h2><p>Opening TinyTiny IG DM/Group Picker...</p><a href="${deepLink}">Open in TinyTiny</a></div><script>location.href="${deepLink}";</script></body></html>`,
        { headers: { "Content-Type": "text/html; charset=utf-8" } }
      );
    }

    if (request.method === "POST" && path === "/v1/admin/deliver-builds") {
      if (!env.TELEGRAM_BOT_TOKEN || !env.ADMIN_USER_ID) {
        return json({ ok: false, error: "telegram_not_configured" }, 500);
      }
      const res = await sendLatestBuildsToTelegram(env, env.ADMIN_USER_ID);
      return json({ ok: Boolean(res.apk?.ok && res.ipa?.ok), ...res });
    }

    if (request.method === "GET" && (path === "/" || path === "/health")) {
      return json({ ok: true, service: "tinytiny-license" });
    }
    return json({ error: "Not found" }, 404);
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(
      Promise.all([
        syncWatchitFolder(env, getPublicBaseUrl(env), false),
        autoDeliverLatestBuildsToTelegram(env),
      ])
    );
  },
};

async function autoDeliverLatestBuildsToTelegram(env) {
  if (!env.TELEGRAM_BOT_TOKEN || !env.ADMIN_USER_ID) return;
  try {
    const r = await fetch("https://api.github.com/repos/aokifrlol-maker/TinyTiny/actions/workflows/build.yml/runs?per_page=1", {
      headers: { "User-Agent": "TinyTiny-Worker" },
    });
    if (!r.ok) return;
    const data = await r.json();
    const run = data?.workflow_runs?.[0];
    if (!run || run.status !== "completed" || run.conclusion !== "success" || !run.head_sha) return;
    const lastSha = await env.LICENSES.get("builds:last_notified_sha");
    if (lastSha === run.head_sha) return;
    await env.LICENSES.put("builds:last_notified_sha", run.head_sha);
    await sendLatestBuildsToTelegram(env, env.ADMIN_USER_ID);
  } catch {}
}

function escapeHtmlTg(s) {
  return String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

async function extractXVideosMP4(pageUrl) {
  try {
    const resp = await fetch(pageUrl, {
      headers: {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
        Accept: "text/html,application/xhtml+xml",
      },
      redirect: "follow",
    });
    if (!resp.ok) return null;
    const html = await resp.text();
    const high = html.match(/setVideoUrlHigh\('([^']+)'\)/i)?.[1];
    const low = html.match(/setVideoUrlLow\('([^']+)'\)/i)?.[1];
    const mp4Url = high || low;
    if (!mp4Url) return null;
    const titleMatch =
      html.match(/setVideoTitle\('([^']+)'\)/i)?.[1] ||
      html.match(/<meta\s+property="og:title"\s+content="([^"]+)"/i)?.[1] ||
      "XVideos Clip";
    return { mp4Url, title: decodeXmlEntities(titleMatch), pageUrl };
  } catch {
    return null;
  }
}

// MARK: - Seedr "Watchit" Folder Auto-Link + Telegram Notifier

const WATCHIT_FOLDER = "Watchit";
const WATCHIT_EXT_MIME = {
  ".mp4": "video/mp4",
  ".mov": "video/quicktime",
  ".m4v": "video/x-m4v",
  ".webm": "video/webm",
  ".mkv": "video/x-matroska",
  ".avi": "video/x-msvideo",
};

function getPublicBaseUrl(env) {
  return String(env.PUBLIC_URL || "https://tinytiny-license.aokifrlol.workers.dev").replace(/\/+$/, "");
}

function guessVideoMime(filename) {
  const lower = String(filename || "").toLowerCase();
  const dot = lower.lastIndexOf(".");
  if (dot === -1) return null;
  return WATCHIT_EXT_MIME[lower.slice(dot)] || null;
}

function decodeXmlEntities(str) {
  return String(str || "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
}

async function seedrEnsureWatchitFolder(auth) {
  const folderUrl = `${SEEDR_DAV_BASE}/${WATCHIT_FOLDER}/`;
  await fetch(folderUrl, { method: "MKCOL", headers: { Authorization: auth } }).catch(() => null);
}

async function seedrListWatchitVideos(auth) {
  const folderUrl = `${SEEDR_DAV_BASE}/${WATCHIT_FOLDER}/`;
  const resp = await fetch(folderUrl, {
    method: "PROPFIND",
    headers: {
      Authorization: auth,
      Depth: "1",
      "Content-Type": "application/xml",
    },
  });
  if (!resp.ok) {
    return { ok: false, error: `Seedr PROPFIND ${resp.status}`, files: [] };
  }

  const xml = await resp.text();
  const files = [];
  const respMatches = xml.matchAll(/<[^:>]*:?response\b[^>]*>([\s\S]*?)<\/[^:>]*:?response>/gi);
  for (const m of respMatches) {
    const block = m[1];
    const hrefMatch = block.match(/<[^:>]*:?href\b[^>]*>([\s\S]*?)<\/[^:>]*:?href>/i);
    if (!hrefMatch) continue;
    const rawHref = decodeXmlEntities(hrefMatch[1].trim());
    let decodedPath = rawHref;
    try {
      decodedPath = decodeURIComponent(rawHref.replace(/^https?:\/\/[^/]+/i, ""));
    } catch {}
    decodedPath = decodedPath.replace(/^\/+/, "");
    if (!decodedPath || decodedPath.endsWith("/")) continue;
    if (decodedPath.toLowerCase() === WATCHIT_FOLDER.toLowerCase()) continue;

    const filename = decodedPath.split("/").pop() || "";
    const contentType = guessVideoMime(filename);
    if (!contentType) continue;

    const lenMatch = block.match(/<[^:>]*:?getcontentlength\b[^>]*>(\d+)<\/[^:>]*:?getcontentlength>/i);
    const size = lenMatch ? Number(lenMatch[1]) : 0;

    files.push({
      davPath: decodedPath,
      filename,
      contentType,
      size,
    });
  }
  return { ok: true, files };
}

async function syncWatchitFolder(env, baseUrl, notifyEvenIfEmpty = false) {
  const auth = seedrAuthHeader(env);
  if (!auth) return { ok: false, error: "Missing SEEDR_EMAIL / SEEDR_PASSWORD", total: 0, sent: 0 };

  await seedrEnsureWatchitFolder(auth);
  const listed = await seedrListWatchitVideos(auth);
  if (!listed.ok) return { ok: false, error: listed.error, total: 0, sent: 0 };

  let sent = 0;
  for (const file of listed.files) {
    const seenKey = `watchit:seen:${file.davPath}`;
    const existingId = await env.LICENSES.get(seenKey);
    if (existingId) continue;

    const id = randomId(10);
    const meta = {
      davPath: file.davPath,
      filename: file.filename,
      contentType: file.contentType,
      size: file.size,
      createdAt: nowSec(),
    };
    await env.LICENSES.put(`watchit:${id}`, JSON.stringify(meta));
    await env.LICENSES.put(seenKey, id);

    const watchUrl = `${baseUrl}/w/${id}`;
    const dlUrl = `${baseUrl}/w/${id}/download`;
    if (env.ADMIN_USER_ID && env.TELEGRAM_BOT_TOKEN) {
      const sizeStr = file.size ? ` (${formatBytesHuman(file.size)})` : "";
      const escName = file.filename.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
      await sendTelegram(
        env,
        env.ADMIN_USER_ID,
        `<b>New Watchit Video</b>\n<code>${escName}</code>${sizeStr}\n\nWatch &amp; Download:\n${watchUrl}\n\nDirect Download:\n${dlUrl}`
      );
      sent++;
    }
  }

  return { ok: true, total: listed.files.length, sent };
}

function renderWatchitHTML(id, meta) {
  const safeName = sanitizeFilename(meta.filename || "video.mp4")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
  const sizeLabel = meta.size ? `${formatBytesHuman(meta.size)} · ` : "";
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>${safeName} · Watchit</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; min-height: 100vh; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: radial-gradient(circle at top, #220b15, #090609 65%); color: #fff; display: flex; align-items: center; justify-content: center; padding: 20px; box-sizing: border-box; }
  .wrap { width: 100%; max-width: 780px; background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.12); border-radius: 22px; padding: 20px; box-shadow: 0 24px 70px rgba(0,0,0,0.55); }
  .title { font-size: 16px; font-weight: 700; word-break: break-word; }
  .sub { font-size: 12px; color: #b5a9b0; margin: 4px 0 14px; }
  video { width: 100%; max-height: 70vh; border-radius: 14px; background: #000; display: block; }
  .actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 14px; }
  .btn { display: inline-flex; align-items: center; justify-content: center; padding: 12px 18px; border-radius: 999px; font-size: 14px; font-weight: 700; text-decoration: none; cursor: pointer; border: none; }
  .btn-primary { background: linear-gradient(135deg, #ff3b7f, #d91b5c); color: #fff; }
  .btn-ghost { background: rgba(255,255,255,0.09); color: #fff; border: 1px solid rgba(255,255,255,0.15); }
</style>
</head>
<body>
  <div class="wrap">
    <div class="title">${safeName}</div>
    <div class="sub">${sizeLabel}Watchit Stream</div>
    <video controls playsinline preload="metadata" src="/w/${id}/video"></video>
    <div class="actions">
      <a class="btn btn-primary" href="/w/${id}/download" download="${safeName}">Download Video</a>
      <button id="copyBtn" class="btn btn-ghost" type="button">Copy Direct Download URL</button>
    </div>
  </div>
  <script>
    const copyBtn = document.getElementById("copyBtn");
    copyBtn.onclick = async () => {
      await navigator.clipboard.writeText(location.origin + "/w/${id}/download");
      copyBtn.textContent = "Copied!";
      setTimeout(() => (copyBtn.textContent = "Copy Direct Download URL"), 1800);
    };
  </script>
</body>
</html>`;
}
