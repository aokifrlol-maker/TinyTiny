const WORKER_BASE = "https://tinytiny-license.aokifrlol.workers.dev";
const PROXY = (url) => `${WORKER_BASE}/v1/proxy?url=${encodeURIComponent(url)}`;

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {});
}

// MARK: - Crisp SF-Style SVG Icons (Zero Emojis)

const ICONS = {
  search: `<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>`,
  gear: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9c.26.604.852.997 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>`,
  playSmall: `<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><polygon points="6,4 20,12 6,20"/></svg>`,
  playLarge: `<svg width="26" height="26" viewBox="0 0 24 24" fill="currentColor"><polygon points="7,4 21,12 7,20"/></svg>`,
  heart: `<svg width="19" height="19" viewBox="0 0 24 24" fill="currentColor"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>`,
  bookmark: `<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M6 3h12a1 1 0 0 1 1 1v17l-7-4-7 4V4a1 1 0 0 1 1-1z"/></svg>`,
  thumbsDown: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 15v4a3 3 0 0 0 3 3l4-9V2H5.72a2 2 0 0 0-2 1.7l-1.38 9a2 2 0 0 0 2 2.3H10z"/><path d="M17 2h2.67A2.31 2.31 0 0 1 22 4v7a2.31 2.31 0 0 1-2.33 2H17"/></svg>`,
  share: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 17L17 7"/><path d="M7 7h10v10"/></svg>`,
  more: `<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/></svg>`,
  home: `<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M12 3l9 8h-3v9h-5v-6h-2v6H6v-9H3l9-8z"/></svg>`,
  compass: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1"><circle cx="12" cy="12" r="9"/><polygon points="15.5,8.5 13.5,13.5 8.5,15.5 10.5,10.5" fill="currentColor" stroke="none"/></svg>`,
  person: `<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="8" r="4"/><path d="M4 20c0-3.8 3.6-6 8-6s8 2.2 8 6z"/></svg>`,
  volOn: `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" fill="currentColor"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M19 5a10 10 0 0 1 0 14"/></svg>`,
  volOff: `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" fill="currentColor"/><line x1="23" y1="9" x2="17" y2="15"/><line x1="17" y1="9" x2="23" y2="15"/></svg>`,
  grid: `<svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor"><rect x="3" y="3" width="8" height="8" rx="2"/><rect x="13" y="3" width="8" height="8" rx="2"/><rect x="3" y="13" width="8" height="8" rx="2"/><rect x="13" y="13" width="8" height="8" rx="2"/></svg>`,
  shuffle: `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><polyline points="16 3 21 3 21 8"/><line x1="4" y1="20" x2="21" y2="3"/><polyline points="21 16 21 21 16 21"/><line x1="15" y1="15" x2="21" y2="21"/><line x1="4" y1="4" x2="9" y2="9"/></svg>`,
  autoScroll: `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"><polyline points="7 7 12 12 17 7"/><polyline points="7 13 12 18 17 13"/></svg>`,
  plus: `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>`,
  check: `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>`,
  chevDown: `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>`,
  chevUp: `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><polyline points="18 15 12 9 6 15"/></svg>`,
  flame: `<svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2c.5 3.5-2 5.5-2 8.5 0 1.8 1.2 3.2 2.8 3.2 1.7 0 2.7-1.4 2.7-3.2 0-1-.3-2-.8-2.8C17.5 9.2 19 12 19 14.8A7 7 0 1 1 5 14.8c0-4.2 3-7.6 7-12.8z"/></svg>`,
  lock: `<svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4" fill="none" stroke="currentColor" stroke-width="2.2"/></svg>`,
  key: `<svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><circle cx="7.5" cy="15.5" r="5.5"/><path d="m21 2-9.6 9.6"/><path d="m15.5 7.5 3 3L22 7l-3-3"/></svg>`,
  bolt: `<svg width="34" height="34" viewBox="0 0 24 24" fill="currentColor"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>`,
  shield: `<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2l8 4v6c0 5.2-3.4 9.8-8 11-4.6-1.2-8-5.8-8-11V6l8-4z"/></svg>`,
};

// MARK: - Categories

const CATEGORIES = [
  { label: "PAWG", sub: "pawg" },
  { label: "TikTok Porn", sub: "tiktokporn" },
  { label: "Petite", sub: "PetiteGoneWild" },
  { label: "Asians", sub: "AsiansGoneWild" },
  { label: "Latina", sub: "latinacuties" },
  { label: "Thick", sub: "thick" },
  { label: "Goth", sub: "gothsluts" },
  { label: "Amateur", sub: "RealGirls" },
  { label: "Blowjobs", sub: "Blowjobs" },
  { label: "Anal", sub: "anal" },
  { label: "Creampie", sub: "creampies" },
  { label: "COSPLAY", sub: "nsfwcosplay" },
  { label: "Rule 34", r34: "sort:score:desc" },
  { label: "Hentai", r34: "hentai sort:score:desc" },
];

// MARK: - Persistent Store

function getOrCreateDeviceId() {
  let id = localStorage.getItem("tt_device_id");
  if (!id) {
    id = crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now();
    localStorage.setItem("tt_device_id", id);
  }
  return id;
}

const state = {
  ageVerified: localStorage.getItem("tt_age") === "1",
  onboarded: localStorage.getItem("tt_onboarded") === "1",
  licenseKey: localStorage.getItem("tt_license_key") || "",
  passcode: localStorage.getItem("tt_passcode") || "",
  passcodeSkipped: localStorage.getItem("tt_pin_skipped") === "1",
  unlocked: !localStorage.getItem("tt_passcode"),

  muted: localStorage.getItem("tt_muted") !== "0",
  hd: localStorage.getItem("tt_hd") !== "0",
  autoScroll: localStorage.getItem("tt_autoscroll") === "1",
  fitMode: localStorage.getItem("tt_fit") === "1",
  controlsCollapsed: false,

  liked: JSON.parse(localStorage.getItem("tt_liked") || "[]"),
  saved: JSON.parse(localStorage.getItem("tt_saved") || "[]"),
  following: JSON.parse(localStorage.getItem("tt_following") || "[]"),
  dislikedIds: new Set(JSON.parse(localStorage.getItem("tt_disliked") || "[]")),
  watchedCount: Number(localStorage.getItem("tt_watched") || "0"),

  tab: "home", // home | favorites | explore | profile
  channel: "forYou", // following | forYou | rule34 | of | long
  sort: "hot", // hot | top | new
  ofSub: "forYou", // forYou | trending | latest
  longSub: "latest", // latest | top | trending
  customFilter: null,

  items: [],
  page: 1,
  afterCursor: "",
  loading: false,
  error: "",
  speedLocked2x: false,
  activeModal: null, // null | 'settings' | 'categories' | { type:'more'|'share', idx:number }
  showInstallHint:
    !window.matchMedia("(display-mode: standalone)").matches &&
    !window.navigator.standalone &&
    !localStorage.getItem("tt_hide_install"),
};

function saveStore() {
  localStorage.setItem("tt_age", state.ageVerified ? "1" : "0");
  localStorage.setItem("tt_onboarded", state.onboarded ? "1" : "0");
  localStorage.setItem("tt_license_key", state.licenseKey);
  localStorage.setItem("tt_passcode", state.passcode);
  localStorage.setItem("tt_pin_skipped", state.passcodeSkipped ? "1" : "0");
  localStorage.setItem("tt_muted", state.muted ? "1" : "0");
  localStorage.setItem("tt_hd", state.hd ? "1" : "0");
  localStorage.setItem("tt_autoscroll", state.autoScroll ? "1" : "0");
  localStorage.setItem("tt_fit", state.fitMode ? "1" : "0");
  localStorage.setItem("tt_liked", JSON.stringify(state.liked.slice(0, 300)));
  localStorage.setItem("tt_saved", JSON.stringify(state.saved.slice(0, 300)));
  localStorage.setItem("tt_following", JSON.stringify(state.following.slice(0, 200)));
  localStorage.setItem("tt_disliked", JSON.stringify(Array.from(state.dislikedIds).slice(-500)));
  localStorage.setItem("tt_watched", String(state.watchedCount));
}

function showToast(msg) {
  document.querySelector(".toast")?.remove();
  const el = document.createElement("div");
  el.className = "glass-pill toast";
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 2200);
}

// MARK: - API Fetchers

async function fetchGoonedPosts(endpoint) {
  const res = await fetch(PROXY(`https://api.gooned.app${endpoint}`));
  if (!res.ok) throw new Error(`Feed error (${res.status})`);
  const data = await res.json();
  if (data.after) state.afterCursor = data.after;
  const list = Array.isArray(data) ? data : (data.posts || data.items || []);
  return list
    .map((p) => {
      let videoUrl = state.hd
        ? (p.muxedUrlHd || p.muxedUrl || "")
        : (p.muxedUrl || p.muxedUrlHd || "");
      if (!videoUrl && p.mediaUrl && /\.(mp4|webm|mov)(\?|$)/i.test(p.mediaUrl) && !p.mediaUrl.includes("CMAF_")) {
        videoUrl = p.mediaUrl;
      }
      let imageUrl = p.posterUrl || p.thumbnailUrl || "";
      if (p.mediaType === "gallery" && Array.isArray(p.galleryUrls) && p.galleryUrls[0]) {
        imageUrl = p.galleryUrls[0].posterUrl || p.galleryUrls[0].sourceUrl || imageUrl;
      }
      if (!videoUrl && p.mediaType === "image") {
        imageUrl = p.posterUrl || p.mediaUrl || p.sourceUrl || imageUrl;
      }
      if (!videoUrl && !imageUrl) return null;
      const isImg = !videoUrl;
      return {
        id: String(p.id || Math.random()),
        source: "reddit",
        author: p.author || p.subreddit || "reddit",
        subreddit: p.subreddit || "",
        title: p.title || "",
        upvotes: p.upvotes || 0,
        videoUrl: videoUrl ? PROXY(videoUrl) : "",
        imageUrl: imageUrl ? PROXY(imageUrl) : "",
        isImage: isImg,
        rawUrl: videoUrl || imageUrl || p.permalink || "",
        permalink: p.permalink || "",
      };
    })
    .filter(Boolean);
}

async function fetchOnlyFansPosts(sort, offset) {
  const sortParam = sort === "trending" ? "trending" : (sort === "latest" ? "latest" : "foryou");
  const res = await fetch(PROXY(`https://cum.st/api/v1/posts?sort=${sortParam}&limit=24&offset=${offset}`));
  if (!res.ok) throw new Error(`OF error (${res.status})`);
  const data = await res.json();
  const list = Array.isArray(data) ? data : (data.posts || data.data || []);
  return list
    .map((p) => {
      const att = Array.isArray(p.attachments) ? p.attachments[0] : null;
      if (!att || !att.storageKey) return null;
      const sk = att.storageKey;
      const variants = Array.isArray(att.variants) ? att.variants : [];
      const mp4 = variants.find((v) => /\.mp4$/i.test(v)) || variants[0];
      const videoUrl = mp4 ? `https://cdn.cum.st/media/${sk}/${mp4}` : "";
      const thumbUrl = `https://img.cum.st/thumbnail/${sk}/preview.webp`;
      const creator = p.creator?.username || p.creator?.name || p.username || "creator";
      const isImg = att.type === "photo" || !videoUrl;
      return {
        id: `of_${p.id || sk}`,
        source: "of",
        author: creator,
        title: p.text || p.title || `@${creator}`,
        upvotes: p.likes || 0,
        videoUrl: videoUrl ? PROXY(videoUrl) : "",
        imageUrl: PROXY(thumbUrl),
        isImage: isImg,
        rawUrl: videoUrl || thumbUrl,
      };
    })
    .filter(Boolean);
}

async function fetchRule34Posts(tags, page) {
  const pid = Math.max(0, page - 1);
  const q = encodeURIComponent(tags || "sort:score:desc");
  const res = await fetch(PROXY(`https://api.rule34.xxx/index.php?page=dapi&s=post&q=index&json=1&limit=25&pid=${pid}&tags=${q}`));
  if (!res.ok) throw new Error(`Rule34 error (${res.status})`);
  const list = await res.json();
  if (!Array.isArray(list)) return [];
  return list
    .map((p) => {
      const fileUrl = p.file_url || "";
      if (!fileUrl) return null;
      const isVid = /\.(mp4|webm|mov)(\?|$)/i.test(fileUrl);
      return {
        id: `r34_${p.id}`,
        source: "rule34",
        author: (p.tags || "").split(" ").slice(0, 2).join(" ") || "rule34",
        title: p.tags || "",
        upvotes: p.score || 0,
        videoUrl: isVid ? PROXY(fileUrl) : "",
        imageUrl: PROXY(p.sample_url || p.preview_url || fileUrl),
        isImage: !isVid,
        rawUrl: fileUrl,
      };
    })
    .filter(Boolean);
}

async function fetchLongVideos(sort, page, query = "") {
  const order = sort === "top" ? "top-rated" : (sort === "trending" ? "most-popular" : "latest");
  const q = encodeURIComponent(query || "all");
  const res = await fetch(PROXY(`https://www.eporner.com/api/v2/video/search/?query=${q}&per_page=20&page=${page}&thumbsize=big&order=${order}&format=json`));
  if (!res.ok) throw new Error(`Long videos error (${res.status})`);
  const data = await res.json();
  const vids = Array.isArray(data.videos) ? data.videos : [];
  return vids
    .map((v) => {
      const thumb = v.default_thumb?.src || "";
      if (!thumb) return null;
      return {
        id: `ep_${v.id}`,
        source: "long",
        author: v.keywords ? v.keywords.split(",")[0].trim() : "eporner",
        title: `${v.title || "Video"} (${v.length_min || ""})`,
        upvotes: v.views || 0,
        videoUrl: "",
        imageUrl: PROXY(thumb),
        externalUrl: v.url || "",
        embedUrl: v.embed || "",
        isImage: true,
        rawUrl: v.url || thumb,
      };
    })
    .filter(Boolean);
}

async function loadFeed(reset = false) {
  if (state.loading) return;
  if (reset) {
    state.items = [];
    state.page = 1;
    state.afterCursor = "";
    state.error = "";
    render();
  }
  state.loading = true;
  try {
    let fetched = [];
    const afterQ = state.afterCursor ? `&after=${encodeURIComponent(state.afterCursor)}` : "";
    if (state.customFilter) {
      if (state.customFilter.type === "subreddit") {
        fetched = await fetchGoonedPosts(`/reddit/subreddit/${encodeURIComponent(state.customFilter.value)}?sort=${state.sort}&limit=25${afterQ}`);
      } else if (state.customFilter.type === "r34") {
        fetched = await fetchRule34Posts(state.customFilter.value, state.page);
      } else if (state.customFilter.type === "search") {
        const [r, r34] = await Promise.all([
          fetchGoonedPosts(`/reddit/search?q=${encodeURIComponent(state.customFilter.value)}&limit=18`).catch(() => []),
          fetchRule34Posts(state.customFilter.value.replace(/\s+/g, "_"), state.page).catch(() => []),
        ]);
        fetched = [...r, ...r34];
      }
    } else if (state.channel === "following") {
      if (state.following.length > 0) {
        const pick = state.following[Math.floor(Math.random() * state.following.length)];
        fetched = await fetchGoonedPosts(`/reddit/subreddit/${encodeURIComponent(pick)}?sort=${state.sort}&limit=25${afterQ}`);
      }
    } else if (state.channel === "forYou") {
      fetched = await fetchGoonedPosts(`/reddit/foryou?sort=${state.sort}&limit=25${afterQ}`);
    } else if (state.channel === "of") {
      fetched = await fetchOnlyFansPosts(state.ofSub, (state.page - 1) * 24);
    } else if (state.channel === "rule34") {
      fetched = await fetchRule34Posts("sort:score:desc", state.page);
    } else if (state.channel === "long") {
      fetched = await fetchLongVideos(state.longSub, state.page);
    }

    const seen = new Set(state.items.map((x) => x.id));
    const fresh = fetched.filter((x) => !seen.has(x.id) && !state.dislikedIds.has(x.id));
    state.items = [...state.items, ...fresh];
    state.page += 1;
  } catch (err) {
    state.error = err.message || "Failed to load feed";
  } finally {
    state.loading = false;
    render();
  }
}

// MARK: - License Activation

async function activateLicenseKey(rawKey) {
  const key = rawKey.trim().toUpperCase();
  const res = await fetch(`${WORKER_BASE}/v1/activate`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ key, deviceId: getOrCreateDeviceId() }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.valid) throw new Error(data.error || "Invalid or expired license key");
  state.licenseKey = key;
  saveStore();
}

// MARK: - Render Root

const root = document.getElementById("app");

function render() {
  if (!state.ageVerified) return renderAgeGate();
  if (!state.onboarded) return renderOnboarding();
  if (!state.licenseKey) return renderLicenseGate();
  if (!state.unlocked && state.passcode) return renderPasscodeGate("unlock");
  if (!state.passcode && !state.passcodeSkipped) return renderPasscodeGate("create");
  return renderMainApp();
}

function renderAgeGate() {
  root.innerHTML = `
    <div class="ambient-bg"></div>
    <div class="screen" style="text-align:center;">
      <div class="age-badge">18+</div>
      <h1 style="font-size:30px;font-weight:900;margin:0 0 8px;">Welcome to Gooned</h1>
      <div style="color:var(--accent);font-weight:700;font-size:14px;margin-bottom:14px;">Adults Only (18+)</div>
      <p style="color:var(--muted);font-size:14px;line-height:1.5;max-width:310px;margin:0 0 36px;">
        This platform contains sexually explicit adult media. By entering, you confirm you are at least 18 years old.
      </p>
      <button id="ageYes" class="btn-primary">I am 18 or older — Continue</button>
      <button id="ageNo" class="btn-ghost" style="margin-top:8px;">I am under 18</button>
    </div>
  `;
  document.getElementById("ageYes").onclick = () => { state.ageVerified = true; saveStore(); render(); };
  document.getElementById("ageNo").onclick = () => { location.href = "https://www.google.com"; };
}

let onboardIdx = 0;
function renderOnboarding() {
  const slides = [
    { icon: ICONS.flame, title: "Welcome to Gooned", sub: "Swipe endlessly. Everything you want in one clean feed.", credit: true },
    { icon: ICONS.bolt, title: "All you need", sub: "to goon your brains out — hold for 2x, pull down to lock, double tap to like." },
    { icon: ICONS.shield, title: "Settings & Privacy", sub: "Set a 4-digit passcode or wipe the app in one tap anytime." },
  ];
  root.innerHTML = `
    <div class="ambient-bg"></div>
    <div class="screen" style="justify-content:space-between;padding-bottom:calc(var(--safe-bottom) + 28px);">
      <div style="height:10px;"></div>
      <div id="slides" class="onboard-slides">
        ${slides.map((s) => `
          <div class="onboard-slide">
            <div class="onboard-orb">${s.icon}</div>
            <h2 class="onboard-title">${s.title}</h2>
            <p class="onboard-sub">${s.sub}</p>
            ${s.credit ? `<div class="matted-credit">by bella</div>` : ""}
          </div>
        `).join("")}
      </div>
      <div style="width:100%;display:flex;flex-direction:column;align-items:center;">
        <div class="dots">${slides.map((_, i) => `<div class="dot ${i === onboardIdx ? "active" : ""}"></div>`).join("")}</div>
        <button id="obNext" class="btn-primary">${onboardIdx === slides.length - 1 ? "Get Started" : "Next"}</button>
      </div>
    </div>
  `;
  const scroller = document.getElementById("slides");
  scroller.scrollLeft = onboardIdx * scroller.clientWidth;
  scroller.addEventListener("scroll", () => {
    const idx = Math.round(scroller.scrollLeft / Math.max(scroller.clientWidth, 1));
    if (idx !== onboardIdx) {
      onboardIdx = idx;
      document.querySelectorAll(".dot").forEach((d, i) => d.classList.toggle("active", i === idx));
      document.getElementById("obNext").textContent = idx === slides.length - 1 ? "Get Started" : "Next";
    }
  });
  document.getElementById("obNext").onclick = () => {
    if (onboardIdx < slides.length - 1) {
      onboardIdx += 1;
      scroller.scrollTo({ left: onboardIdx * scroller.clientWidth, behavior: "smooth" });
    } else {
      state.onboarded = true;
      saveStore();
      render();
    }
  };
}

function renderLicenseGate() {
  root.innerHTML = `
    <div class="ambient-bg"></div>
    <div class="screen" style="text-align:center;">
      <div class="onboard-orb" style="width:74px;height:74px;border-radius:50%;">${ICONS.key}</div>
      <h2 style="font-size:26px;font-weight:900;margin:0 0 8px;">Activate Access</h2>
      <p style="color:var(--muted);font-size:14px;max-width:290px;margin:0 0 24px;">
        Enter the license key sent by @JarveyIsBot to unlock your feed.
      </p>
      <div class="glass-card" style="width:100%;max-width:340px;padding:16px;display:flex;flex-direction:column;gap:12px;">
        <input id="licInput" class="input-box" placeholder="TT-XXXX-XXXX-XXXX" autocomplete="off" autocapitalize="characters" />
        <button id="licBtn" class="btn-primary">Activate License Key</button>
        <div id="licErr" style="color:#ff7a9f;font-size:13px;min-height:18px;"></div>
      </div>
      <div class="matted-credit" style="margin-top:28px;">by bella</div>
    </div>
  `;
  const input = document.getElementById("licInput");
  const btn = document.getElementById("licBtn");
  const errEl = document.getElementById("licErr");
  btn.onclick = async () => {
    const val = input.value.trim();
    if (!val) { errEl.textContent = "Enter a license key"; return; }
    btn.disabled = true; btn.textContent = "Activating..."; errEl.textContent = "";
    try {
      await activateLicenseKey(val);
      render();
    } catch (e) {
      errEl.textContent = e.message;
      btn.disabled = false; btn.textContent = "Activate License Key";
    }
  };
}

let pinBuffer = "";
function renderPasscodeGate(mode) {
  const isCreate = mode === "create";
  root.innerHTML = `
    <div class="ambient-bg"></div>
    <div class="screen" style="justify-content:space-between;">
      <div style="text-align:center;margin-top:16px;">
        <div class="glass-pill" style="display:inline-block;padding:5px 12px;font-size:11px;font-weight:700;letter-spacing:1.2px;color:var(--muted);margin-bottom:14px;">
          ${isCreate ? "OPTIONAL LOCK" : "LOCKED"}
        </div>
        <h2 style="font-size:24px;font-weight:900;margin:0 0 6px;">${isCreate ? "Create 4-Digit Passcode" : "Enter Passcode"}</h2>
        <div id="pinSub" style="color:var(--muted);font-size:13.5px;">${isCreate ? "Keep it private on your Home Screen" : "Unlock Gooned"}</div>
      </div>
      <div style="display:flex;flex-direction:column;align-items:center;">
        <div class="glass-pill pin-dots">${[0,1,2,3].map((i) => `<div class="pin-dot ${i < pinBuffer.length ? "filled" : ""}"></div>`).join("")}</div>
        <div class="keypad">
          ${[1,2,3,4,5,6,7,8,9].map((n) => `<button class="key-btn" data-k="${n}">${n}</button>`).join("")}
          <div class="key-empty"></div>
          <button class="key-btn" data-k="0">0</button>
          <button class="key-btn" id="pinDel">⌫</button>
        </div>
      </div>
      <div style="display:flex;flex-direction:column;align-items:center;gap:6px;">
        ${isCreate ? `<button id="pinSkip" class="btn-ghost">Skip Passcode</button>` : ""}
        <div class="matted-credit">by bella</div>
      </div>
    </div>
  `;
  document.querySelectorAll("[data-k]").forEach((b) => {
    b.onclick = () => {
      if (pinBuffer.length >= 4) return;
      pinBuffer += b.dataset.k;
      if (pinBuffer.length === 4) {
        if (isCreate) {
          state.passcode = pinBuffer; state.unlocked = true; pinBuffer = ""; saveStore(); render();
        } else if (pinBuffer === state.passcode) {
          state.unlocked = true; pinBuffer = ""; render();
        } else {
          pinBuffer = "";
          document.getElementById("pinSub").textContent = "Wrong passcode — try again";
          document.getElementById("pinSub").style.color = "#ff7a9f";
          document.querySelectorAll(".pin-dot").forEach((d) => d.classList.remove("filled"));
        }
      } else {
        document.querySelectorAll(".pin-dot").forEach((d, i) => d.classList.toggle("filled", i < pinBuffer.length));
      }
    };
  });
  document.getElementById("pinDel").onclick = () => {
    pinBuffer = pinBuffer.slice(0, -1);
    document.querySelectorAll(".pin-dot").forEach((d, i) => d.classList.toggle("filled", i < pinBuffer.length));
  };
  if (isCreate) {
    document.getElementById("pinSkip").onclick = () => {
      state.passcodeSkipped = true; state.unlocked = true; pinBuffer = ""; saveStore(); render();
    };
  }
}

// MARK: - Main App

let reelObserver = null;

function renderMainApp() {
  if (state.tab === "home" && state.items.length === 0 && !state.loading && !state.error) {
    loadFeed(false);
  }

  root.innerHTML = `
    <div class="main-shell">
      ${state.tab === "home" ? renderHomeView() : ""}
      ${state.tab === "favorites" ? renderFavoritesView() : ""}
      ${state.tab === "explore" ? renderExploreView() : ""}
      ${state.tab === "profile" ? renderProfileView() : ""}

      ${state.showInstallHint ? `
        <div class="glass-pill install-banner">
          <span>Tap Share → <b>Add to Home Screen</b></span>
          <button id="dismissInstall" style="background:none;border:none;color:#fff;font-weight:900;cursor:pointer;">✕</button>
        </div>
      ` : ""}

      <div class="glass-pill bottom-dock">
        <button class="dock-btn ${state.tab === "home" ? "active" : ""}" data-tab="home">${ICONS.home}</button>
        <button class="dock-btn ${state.tab === "favorites" ? "active" : ""}" data-tab="favorites">${ICONS.heart}</button>
        <button class="dock-btn ${state.tab === "explore" ? "active" : ""}" data-tab="explore">${ICONS.compass}</button>
        <button class="dock-btn ${state.tab === "profile" ? "active" : ""}" data-tab="profile">${ICONS.person}</button>
      </div>

      ${renderActiveModal()}
    </div>
  `;

  document.querySelectorAll("[data-tab]").forEach((btn) => {
    btn.onclick = () => { state.tab = btn.dataset.tab; render(); };
  });

  document.getElementById("dismissInstall")?.addEventListener("click", () => {
    state.showInstallHint = false;
    localStorage.setItem("tt_hide_install", "1");
    render();
  });

  if (state.tab === "home") bindHomeEvents();
  if (state.tab === "explore") bindExploreEvents();
  if (state.tab === "favorites") bindFavoritesEvents();
  if (state.tab === "profile") bindProfileEvents();
  bindModalEvents();
}

function renderHomeView() {
  const showOFSubs = state.channel === "of" && !state.customFilter;
  const showLongSubs = state.channel === "long" && !state.customFilter;

  return `
    ${!state.controlsCollapsed ? `
      <div class="top-bar-wrap">
        <div class="top-row">
          <button id="topSearchBtn" class="icon-circle">${ICONS.search}</button>
          <div class="channel-strip">
            ${state.customFilter ? `
              <button id="clearFilterBtn" class="ch-pill active">${escapeHtml(state.customFilter.label)} ✕</button>
            ` : `
              <button class="ch-pill ${state.channel === "following" ? "active" : ""}" data-ch="following">Following</button>
              <button class="ch-pill ${state.channel === "forYou" ? "active" : ""}" data-ch="forYou">For You</button>
              <button class="badge-btn badge-r34 ${state.channel === "rule34" ? "active" : ""}" data-ch="rule34">34</button>
              <button class="badge-btn badge-of ${state.channel === "of" ? "active" : ""}" data-ch="of">OF</button>
              <button class="badge-btn badge-long ${state.channel === "long" ? "active" : ""}" data-ch="long">${ICONS.playSmall}</button>
            `}
          </div>
          <button id="topSettingsBtn" class="icon-circle">${ICONS.gear}</button>
        </div>

        ${showOFSubs ? `
          <div class="subtab-pill">
            ${[["forYou","For You"],["trending","Trending"],["latest","Latest"]].map(([k, lbl]) => `
              <button class="subtab-btn ${state.ofSub === k ? "active" : ""}" data-ofsub="${k}">${lbl}</button>
            `).join("")}
          </div>
        ` : ""}

        ${showLongSubs ? `
          <div class="subtab-pill">
            ${[["latest","Latest"],["top","Top"],["trending","Trending"]].map(([k, lbl]) => `
              <button class="subtab-btn ${state.longSub === k ? "active" : ""}" data-longsub="${k}">${lbl}</button>
            `).join("")}
          </div>
        ` : ""}
      </div>
    ` : ""}

    ${state.speedLocked2x ? `<div class="glass-pill speed-badge">${ICONS.lock} 2x Locked · Tap to Unlock</div>` : ""}

    <div id="feedScroller" class="feed-scroller">
      ${state.items.length === 0 ? `
        <div class="reel-cell" style="flex-direction:column;gap:14px;text-align:center;padding:24px;">
          <div style="font-size:15px;color:var(--muted);">
            ${state.loading ? "Loading feed..." : (state.error || (state.channel === "following" && state.following.length === 0 ? "Follow creators or subreddits first" : "No posts found"))}
          </div>
          ${!state.loading ? `<button id="retryFeedBtn" class="btn-primary" style="width:auto;padding:12px 24px;">Retry</button>` : ""}
        </div>
      ` : state.items.map((item, idx) => renderReelCell(item, idx)).join("")}
    </div>
  `;
}

function renderReelCell(item, idx) {
  const isLiked = state.liked.some((x) => x.id === item.id);
  const isSaved = state.saved.some((x) => x.id === item.id);
  const isFollowed = item.subreddit && state.following.includes(item.subreddit);
  const fitClass = state.fitMode ? "fit" : "";

  return `
    <div class="reel-cell" data-idx="${idx}" data-id="${escapeHtml(item.id)}">
      ${item.isImage || !item.videoUrl ? `
        <img class="reel-media ${fitClass}" src="${escapeHtml(item.imageUrl)}" decoding="async" alt="" />
      ` : `
        <video class="reel-media ${fitClass}" src="${escapeHtml(item.videoUrl)}" poster="${escapeHtml(item.imageUrl || "")}"
          playsinline webkit-playsinline loop preload="${idx < 2 ? "auto" : "metadata"}" ${state.muted ? "muted" : ""}></video>
      `}

      ${!state.controlsCollapsed ? `
        <div class="left-cluster">
          <div class="left-top-pills">
            <button class="mini-pill" data-sort-cycle="${idx}">${ICONS.flame} ${state.sort.toUpperCase()}</button>
            <button class="mini-pill ${state.fitMode ? "active" : ""}" data-fit="${idx}">${state.fitMode ? "Fit" : "Fill"}</button>
            <button class="mini-pill" data-collapse="${idx}">${ICONS.chevDown}</button>
          </div>
          <button class="ctrl-circle" data-mute="${idx}" title="Mute">${state.muted ? ICONS.volOff : ICONS.volOn}</button>
          <button class="ctrl-circle" data-cats="${idx}" title="Categories">${ICONS.grid}</button>
          <button class="ctrl-circle" data-shuffle="${idx}" title="Shuffle">${ICONS.shuffle}</button>
          <button class="ctrl-circle ${state.autoScroll ? "active" : ""}" data-autoscroll="${idx}" title="Auto Scroll">${ICONS.autoScroll}</button>
          ${item.subreddit ? `<button class="ctrl-circle ${isFollowed ? "active" : ""}" data-follow="${idx}" title="Follow">${isFollowed ? ICONS.check : ICONS.plus}</button>` : ""}
        </div>
      ` : `
        <div style="position:absolute;bottom:calc(var(--safe-bottom) + 74px);left:14px;z-index:12;">
          <button class="mini-pill" data-collapse="${idx}">${ICONS.chevUp} Controls</button>
        </div>
      `}

      <div class="reel-actions">
        <div class="act-wrap">
          <button class="act-btn ${isLiked ? "liked" : ""}" data-like="${idx}">${ICONS.heart}</button>
          ${item.upvotes ? `<span class="act-count">${formatCount(item.upvotes)}</span>` : ""}
        </div>
        <button class="act-btn ${isSaved ? "saved" : ""}" data-save="${idx}">${ICONS.bookmark}</button>
        <button class="act-btn" data-dislike="${idx}">${ICONS.thumbsDown}</button>
        <button class="act-btn" data-share="${idx}">${ICONS.share}</button>
        <button class="act-btn" data-more="${idx}">${ICONS.more}</button>
      </div>

      ${!item.isImage && item.videoUrl ? `
        <div class="scrubber-wrap" data-scrub="${idx}">
          <div class="scrubber-track"><div class="scrubber-fill"></div></div>
        </div>
      ` : ""}

      <div class="reel-overlay-bottom">
        <button class="creator-chip" data-creator="${idx}">
          ${item.subreddit ? `r/${escapeHtml(item.subreddit)}` : `@${escapeHtml(item.author || "post")}`}
        </button>
        ${item.title ? `<div class="reel-title">${escapeHtml(item.title)}</div>` : ""}
      </div>
    </div>
  `;
}

function bindHomeEvents() {
  document.getElementById("topSearchBtn")?.addEventListener("click", () => { state.tab = "explore"; render(); });
  document.getElementById("topSettingsBtn")?.addEventListener("click", () => { state.activeModal = "settings"; render(); });
  document.getElementById("clearFilterBtn")?.addEventListener("click", () => { state.customFilter = null; loadFeed(true); });

  document.querySelectorAll("[data-ch]").forEach((btn) => {
    btn.onclick = () => { state.channel = btn.dataset.ch; state.customFilter = null; loadFeed(true); };
  });
  document.querySelectorAll("[data-ofsub]").forEach((btn) => {
    btn.onclick = () => { state.ofSub = btn.dataset.ofsub; loadFeed(true); };
  });
  document.querySelectorAll("[data-longsub]").forEach((btn) => {
    btn.onclick = () => { state.longSub = btn.dataset.longsub; loadFeed(true); };
  });
  document.getElementById("retryFeedBtn")?.addEventListener("click", () => loadFeed(true));

  document.querySelectorAll("[data-sort-cycle]").forEach((b) => {
    b.onclick = (e) => {
      e.stopPropagation();
      const order = ["hot", "top", "new"];
      state.sort = order[(order.indexOf(state.sort) + 1) % order.length];
      loadFeed(true);
    };
  });
  document.querySelectorAll("[data-fit]").forEach((b) => {
    b.onclick = (e) => {
      e.stopPropagation();
      state.fitMode = !state.fitMode;
      saveStore();
      render();
    };
  });
  document.querySelectorAll("[data-collapse]").forEach((b) => {
    b.onclick = (e) => {
      e.stopPropagation();
      state.controlsCollapsed = !state.controlsCollapsed;
      render();
    };
  });
  document.querySelectorAll("[data-mute]").forEach((b) => {
    b.onclick = (e) => {
      e.stopPropagation();
      state.muted = !state.muted;
      saveStore();
      document.querySelectorAll("video").forEach((v) => (v.muted = state.muted));
      document.querySelectorAll("[data-mute]").forEach((btn) => (btn.innerHTML = state.muted ? ICONS.volOff : ICONS.volOn));
    };
  });
  document.querySelectorAll("[data-cats]").forEach((b) => {
    b.onclick = (e) => { e.stopPropagation(); state.activeModal = "categories"; render(); };
  });
  document.querySelectorAll("[data-shuffle]").forEach((b) => {
    b.onclick = (e) => {
      e.stopPropagation();
      state.items.sort(() => Math.random() - 0.5);
      showToast("Shuffled feed");
      render();
    };
  });
  document.querySelectorAll("[data-autoscroll]").forEach((b) => {
    b.onclick = (e) => {
      e.stopPropagation();
      state.autoScroll = !state.autoScroll;
      saveStore();
      showToast(state.autoScroll ? "Auto-scroll ON" : "Auto-scroll OFF");
      render();
    };
  });
  document.querySelectorAll("[data-follow]").forEach((b) => {
    b.onclick = (e) => {
      e.stopPropagation();
      const item = state.items[Number(b.dataset.follow)];
      if (!item?.subreddit) return;
      const idx = state.following.indexOf(item.subreddit);
      if (idx >= 0) {
        state.following.splice(idx, 1);
        showToast(`Unfollowed r/${item.subreddit}`);
      } else {
        state.following.push(item.subreddit);
        showToast(`Following r/${item.subreddit}`);
      }
      saveStore();
      render();
    };
  });

  document.querySelectorAll("[data-like]").forEach((b) => {
    b.onclick = (e) => { e.stopPropagation(); toggleList(state.liked, state.items[Number(b.dataset.like)], b, "liked"); };
  });
  document.querySelectorAll("[data-save]").forEach((b) => {
    b.onclick = (e) => { e.stopPropagation(); toggleList(state.saved, state.items[Number(b.dataset.save)], b, "saved"); };
  });
  document.querySelectorAll("[data-dislike]").forEach((b) => {
    b.onclick = (e) => {
      e.stopPropagation();
      const idx = Number(b.dataset.dislike);
      const item = state.items[idx];
      if (!item) return;
      state.dislikedIds.add(item.id);
      state.items.splice(idx, 1);
      saveStore();
      showToast("Not interested · Hidden");
      render();
    };
  });
  document.querySelectorAll("[data-share]").forEach((b) => {
    b.onclick = (e) => {
      e.stopPropagation();
      state.activeModal = { type: "share", idx: Number(b.dataset.share) };
      render();
    };
  });
  document.querySelectorAll("[data-more]").forEach((b) => {
    b.onclick = (e) => {
      e.stopPropagation();
      state.activeModal = { type: "more", idx: Number(b.dataset.more) };
      render();
    };
  });
  document.querySelectorAll("[data-creator]").forEach((b) => {
    b.onclick = (e) => {
      e.stopPropagation();
      const item = state.items[Number(b.dataset.creator)];
      if (!item) return;
      if (item.subreddit) {
        state.customFilter = { type: "subreddit", value: item.subreddit, label: `r/${item.subreddit}` };
        loadFeed(true);
      } else if (item.externalUrl) {
        window.open(item.externalUrl, "_blank");
      }
    };
  });

  if (reelObserver) reelObserver.disconnect();
  const scroller = document.getElementById("feedScroller");
  if (!scroller) return;

  reelObserver = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        const cell = entry.target;
        const vid = cell.querySelector("video");
        const idx = Number(cell.dataset.idx);
        if (entry.isIntersecting && entry.intersectionRatio >= 0.65) {
          state.watchedCount += 1;
          saveStore();
          if (vid) {
            vid.muted = state.muted;
            vid.playbackRate = state.speedLocked2x ? 2.0 : 1.0;
            vid.play().catch(() => {});
          }
          if (idx >= state.items.length - 4 && !state.loading) loadFeed(false);
        } else if (vid) {
          vid.pause();
        }
      }
    },
    { root: scroller, threshold: 0.65 }
  );

  document.querySelectorAll(".reel-cell").forEach((cell) => {
    reelObserver.observe(cell);
    attachCellGestures(cell, scroller);
  });
}

function attachCellGestures(cell, scroller) {
  const vid = cell.querySelector("video");
  const fill = cell.querySelector(".scrubber-fill");
  if (vid && fill) {
    vid.addEventListener("timeupdate", () => {
      if (vid.duration) fill.style.width = `${(vid.currentTime / vid.duration) * 100}%`;
    });
    vid.addEventListener("ended", () => {
      if (state.autoScroll) {
        scroller.scrollBy({ top: scroller.clientHeight, behavior: "smooth" });
      }
    });
  }

  const scrub = cell.querySelector("[data-scrub]");
  if (scrub && vid) {
    scrub.onclick = (e) => {
      e.stopPropagation();
      const rect = scrub.getBoundingClientRect();
      const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
      if (vid.duration) vid.currentTime = ratio * vid.duration;
    };
  }

  let holdTimer = null, holding = false, startY = 0, lastTap = 0;
  cell.addEventListener("pointerdown", (e) => {
    if (e.target.closest("button") || e.target.closest("[data-scrub]")) return;
    startY = e.clientY;
    holdTimer = setTimeout(() => {
      holding = true;
      if (vid) vid.playbackRate = 2.0;
    }, 220);
  });
  cell.addEventListener("pointermove", (e) => {
    if (holding && !state.speedLocked2x && e.clientY - startY > 28) {
      state.speedLocked2x = true;
      showToast("2x Speed Locked");
      const badge = document.createElement("div");
      badge.className = "glass-pill speed-badge";
      badge.innerHTML = `${ICONS.lock} 2x Locked · Tap to Unlock`;
      document.querySelector(".main-shell")?.appendChild(badge);
    } else if (!holding && Math.abs(e.clientY - startY) > 12) {
      clearTimeout(holdTimer);
    }
  });
  const endHold = () => {
    clearTimeout(holdTimer);
    if (holding) {
      holding = false;
      if (!state.speedLocked2x && vid) vid.playbackRate = 1.0;
    }
  };
  cell.addEventListener("pointerup", (e) => {
    if (e.target.closest("button") || e.target.closest("[data-scrub]")) { endHold(); return; }
    const wasHolding = holding;
    endHold();
    if (wasHolding || Math.abs(e.clientY - startY) > 14) return;
    const now = Date.now();
    if (now - lastTap < 250) {
      lastTap = 0;
      const idx = Number(cell.dataset.idx);
      const likeBtn = cell.querySelector(`[data-like="${idx}"]`);
      if (state.items[idx] && !state.liked.some((x) => x.id === state.items[idx].id)) {
        toggleList(state.liked, state.items[idx], likeBtn, "liked");
      }
      const heart = document.createElement("div");
      heart.className = "heart-burst";
      heart.innerHTML = `<svg width="88" height="88" viewBox="0 0 24 24" fill="currentColor"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>`;
      cell.appendChild(heart);
      setTimeout(() => heart.remove(), 650);
    } else {
      lastTap = now;
      setTimeout(() => {
        if (lastTap !== now) return;
        if (state.speedLocked2x) {
          state.speedLocked2x = false;
          if (vid) vid.playbackRate = 1.0;
          document.querySelectorAll(".speed-badge").forEach((b) => b.remove());
          return;
        }
        if (vid) {
          if (vid.paused) {
            vid.play().catch(() => {});
            cell.querySelector(".pause-badge")?.remove();
          } else {
            vid.pause();
            const p = document.createElement("div");
            p.className = "pause-badge";
            p.innerHTML = ICONS.playLarge;
            cell.appendChild(p);
          }
        }
      }, 260);
    }
  });
  cell.addEventListener("pointercancel", endHold);
}

function toggleList(arr, item, btnEl, cls) {
  if (!item) return;
  const idx = arr.findIndex((x) => x.id === item.id);
  if (idx >= 0) {
    arr.splice(idx, 1);
    btnEl?.classList.remove(cls);
  } else {
    arr.unshift(item);
    btnEl?.classList.add(cls);
  }
  saveStore();
}

// MARK: - Modals (Settings / Categories / More / Share)

function renderActiveModal() {
  if (!state.activeModal) return "";
  if (state.activeModal === "settings") {
    return `
      <div class="sheet-backdrop" id="modalBackdrop">
        <div class="sheet-panel">
          <div class="sheet-handle"></div>
          <h3 style="margin:0 0 12px;font-size:20px;font-weight:900;">Settings</h3>
          <div class="sheet-row"><span>HD Video Quality</span><button class="toggle-btn ${state.hd ? "on" : ""}" id="togHd"><div class="toggle-knob"></div></button></div>
          <div class="sheet-row"><span>Mute by Default</span><button class="toggle-btn ${state.muted ? "on" : ""}" id="togMute"><div class="toggle-knob"></div></button></div>
          <div class="sheet-row"><span>Auto-Scroll on End</span><button class="toggle-btn ${state.autoScroll ? "on" : ""}" id="togAuto"><div class="toggle-knob"></div></button></div>
          <div class="sheet-row"><span>Fit Video (No Crop)</span><button class="toggle-btn ${state.fitMode ? "on" : ""}" id="togFit"><div class="toggle-knob"></div></button></div>
          <div style="margin-top:16px;display:flex;flex-direction:column;gap:10px;">
            <button id="mResetBtn" class="btn-primary" style="background:linear-gradient(135deg,#dc2626,#991b1b);">Reset App & Log Out</button>
          </div>
        </div>
      </div>
    `;
  }
  if (state.activeModal === "categories") {
    return `
      <div class="sheet-backdrop" id="modalBackdrop">
        <div class="sheet-panel">
          <div class="sheet-handle"></div>
          <h3 style="margin:0 0 14px;font-size:20px;font-weight:900;">Categories</h3>
          <div style="display:flex;flex-wrap:wrap;gap:8px;">
            ${CATEGORIES.map((c, i) => `<button class="ch-pill" data-cat-pick="${i}">${escapeHtml(c.label)}</button>`).join("")}
          </div>
        </div>
      </div>
    `;
  }
  if (typeof state.activeModal === "object") {
    const item = state.items[state.activeModal.idx];
    if (!item) return "";
    if (state.activeModal.type === "share") {
      const shareUrl = item.rawUrl || item.permalink || location.href;
      return `
        <div class="sheet-backdrop" id="modalBackdrop">
          <div class="sheet-panel">
            <div class="sheet-handle"></div>
            <h3 style="margin:0 0 10px;font-size:20px;font-weight:900;">Share Video</h3>
            <p style="color:var(--muted);font-size:13px;margin:0 0 16px;">Send a direct link or open in TinyTiny.</p>
            <div style="display:flex;flex-direction:column;gap:10px;">
              <button id="shareCopyBtn" class="btn-primary">Copy Share Link</button>
              ${navigator.share ? `<button id="shareNativeBtn" class="btn-primary" style="background:rgba(255,255,255,0.12);box-shadow:none;">System Share Sheet</button>` : ""}
            </div>
          </div>
        </div>
      `;
    }
    if (state.activeModal.type === "more") {
      const dlUrl = item.videoUrl || item.imageUrl;
      return `
        <div class="sheet-backdrop" id="modalBackdrop">
          <div class="sheet-panel">
            <div class="sheet-handle"></div>
            <h3 style="margin:0 0 6px;font-size:18px;font-weight:900;">${escapeHtml(item.subreddit ? `r/${item.subreddit}` : `@${item.author}`)}</h3>
            <p style="color:var(--muted);font-size:13px;margin:0 0 16px;">${escapeHtml(item.title)}</p>
            <div style="display:flex;flex-direction:column;gap:10px;">
              ${dlUrl ? `<a class="btn-primary" style="text-align:center;text-decoration:none;" href="${escapeHtml(dlUrl)}" download="gooned_${escapeHtml(item.id)}.mp4">Download Media</a>` : ""}
              ${item.permalink || item.externalUrl ? `<a class="btn-primary" style="text-align:center;text-decoration:none;background:rgba(255,255,255,0.12);box-shadow:none;" href="${escapeHtml(item.permalink || item.externalUrl)}" target="_blank">Open Original Source</a>` : ""}
            </div>
          </div>
        </div>
      `;
    }
  }
  return "";
}

function bindModalEvents() {
  const backdrop = document.getElementById("modalBackdrop");
  if (!backdrop) return;
  backdrop.onclick = (e) => {
    if (e.target === backdrop) { state.activeModal = null; render(); }
  };
  document.getElementById("togHd")?.addEventListener("click", () => { state.hd = !state.hd; saveStore(); render(); });
  document.getElementById("togMute")?.addEventListener("click", () => { state.muted = !state.muted; saveStore(); render(); });
  document.getElementById("togAuto")?.addEventListener("click", () => { state.autoScroll = !state.autoScroll; saveStore(); render(); });
  document.getElementById("togFit")?.addEventListener("click", () => { state.fitMode = !state.fitMode; saveStore(); render(); });
  document.getElementById("mResetBtn")?.addEventListener("click", () => {
    if (!confirm("Reset all data, passcode, and log out of your license key?")) return;
    localStorage.clear();
    location.reload();
  });
  document.querySelectorAll("[data-cat-pick]").forEach((b) => {
    b.onclick = () => {
      const cat = CATEGORIES[Number(b.dataset.catPick)];
      state.activeModal = null;
      if (cat.sub) state.customFilter = { type: "subreddit", value: cat.sub, label: `r/${cat.sub}` };
      else if (cat.r34) state.customFilter = { type: "r34", value: cat.r34, label: cat.label };
      loadFeed(true);
    };
  });
  document.getElementById("shareCopyBtn")?.addEventListener("click", async () => {
    const item = state.items[state.activeModal.idx];
    await navigator.clipboard.writeText(item?.rawUrl || item?.permalink || location.href).catch(() => {});
    state.activeModal = null;
    showToast("Link copied!");
    render();
  });
  document.getElementById("shareNativeBtn")?.addEventListener("click", () => {
    const item = state.items[state.activeModal.idx];
    navigator.share?.({ title: item?.title || "Gooned", url: item?.rawUrl || location.href }).catch(() => {});
  });
}

// MARK: - Favorites / Explore / Profile

function renderFavoritesView() {
  const combined = [...state.liked, ...state.saved.filter((s) => !state.liked.some((l) => l.id === s.id))];
  return `
    <div class="page-scroll">
      <h2 style="font-size:24px;font-weight:900;margin:0 0 14px;">Favorites & Saved (${combined.length})</h2>
      ${combined.length === 0 ? `<p style="color:var(--muted);">Double-tap or tap heart/bookmark on any post to save it here.</p>` : `
        <div class="grid-2">
          ${combined.map((item, i) => `
            <div class="thumb-card" data-fav="${i}">
              <img src="${escapeHtml(item.imageUrl || item.videoUrl)}" decoding="async" alt="" />
              <div class="thumb-label">${item.subreddit ? `r/${escapeHtml(item.subreddit)}` : `@${escapeHtml(item.author || "post")}`}</div>
            </div>
          `).join("")}
        </div>
      `}
    </div>
  `;
}

function bindFavoritesEvents() {
  const combined = [...state.liked, ...state.saved.filter((s) => !state.liked.some((l) => l.id === s.id))];
  document.querySelectorAll("[data-fav]").forEach((card) => {
    card.onclick = () => {
      const item = combined[Number(card.dataset.fav)];
      if (!item) return;
      state.items = [item, ...combined.filter((x) => x.id !== item.id)];
      state.tab = "home";
      render();
    };
  });
}

function renderExploreView() {
  return `
    <div class="page-scroll">
      <h2 style="font-size:24px;font-weight:900;margin:0 0 12px;">Explore & Search</h2>
      <div style="display:flex;gap:8px;margin-bottom:18px;">
        <input id="searchInput" class="input-box" style="text-align:left;" placeholder="Search tags, subreddits, creators..." />
        <button id="searchGo" class="btn-primary" style="width:auto;padding:0 20px;">Go</button>
      </div>
      <div style="color:var(--muted);font-size:12px;font-weight:700;letter-spacing:1px;margin-bottom:10px;">CATEGORIES</div>
      <div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:22px;">
        ${CATEGORIES.map((c, i) => `<button class="ch-pill" data-ex-cat="${i}">${escapeHtml(c.label)}</button>`).join("")}
      </div>
      <div style="color:var(--muted);font-size:12px;font-weight:700;letter-spacing:1px;margin-bottom:10px;">FOLLOWING (${state.following.length})</div>
      <div style="display:flex;flex-wrap:wrap;gap:8px;">
        ${state.following.length === 0 ? `<span style="color:var(--muted);font-size:13px;">Tap + on any post to follow its subreddit</span>` :
          state.following.map((s) => `<button class="ch-pill" data-fsub="${escapeHtml(s)}">r/${escapeHtml(s)}</button>`).join("")}
      </div>
    </div>
  `;
}

function bindExploreEvents() {
  const go = () => {
    const q = document.getElementById("searchInput").value.trim();
    if (!q) return;
    state.customFilter = { type: "search", value: q, label: `Search: ${q}` };
    state.tab = "home";
    loadFeed(true);
  };
  document.getElementById("searchGo").onclick = go;
  document.getElementById("searchInput").addEventListener("keydown", (e) => { if (e.key === "Enter") go(); });
  document.querySelectorAll("[data-ex-cat]").forEach((b) => {
    b.onclick = () => {
      const cat = CATEGORIES[Number(b.dataset.exCat)];
      state.customFilter = cat.sub
        ? { type: "subreddit", value: cat.sub, label: `r/${cat.sub}` }
        : { type: "r34", value: cat.r34, label: cat.label };
      state.tab = "home";
      loadFeed(true);
    };
  });
  document.querySelectorAll("[data-fsub]").forEach((b) => {
    b.onclick = () => {
      state.customFilter = { type: "subreddit", value: b.dataset.fsub, label: `r/${b.dataset.fsub}` };
      state.tab = "home";
      loadFeed(true);
    };
  });
}

function renderProfileView() {
  return `
    <div class="page-scroll">
      <h2 style="font-size:24px;font-weight:900;margin:0 0 16px;">Profile & Vault</h2>
      <div class="glass-card" style="padding:16px;margin-bottom:14px;display:grid;grid-template-columns:repeat(3,1fr);text-align:center;gap:8px;">
        <div><div style="font-size:22px;font-weight:900;">${state.watchedCount}</div><div style="font-size:12px;color:var(--muted);">Watched</div></div>
        <div><div style="font-size:22px;font-weight:900;">${state.liked.length}</div><div style="font-size:12px;color:var(--muted);">Liked</div></div>
        <div><div style="font-size:22px;font-weight:900;">${state.following.length}</div><div style="font-size:12px;color:var(--muted);">Following</div></div>
      </div>
      <div class="glass-card" style="padding:16px;display:flex;flex-direction:column;gap:12px;">
        <div style="font-size:13px;color:var(--muted);">License: <b style="color:#fff;">${escapeHtml(state.licenseKey)}</b></div>
        ${state.passcode ? `<button id="lockNowBtn" class="btn-primary" style="background:rgba(255,255,255,0.12);box-shadow:none;">Lock App Now</button>` : ""}
        <button id="openSettingsBtn" class="btn-primary" style="background:rgba(255,255,255,0.12);box-shadow:none;">Open Settings</button>
        <button id="resetAppBtn" class="btn-primary" style="background:linear-gradient(135deg,#dc2626,#991b1b);">Reset App & Log Out</button>
      </div>
      <div class="matted-credit" style="text-align:center;margin-top:24px;">by bella</div>
    </div>
  `;
}

function bindProfileEvents() {
  document.getElementById("lockNowBtn")?.addEventListener("click", () => { state.unlocked = false; render(); });
  document.getElementById("openSettingsBtn")?.addEventListener("click", () => { state.activeModal = "settings"; render(); });
  document.getElementById("resetAppBtn")?.addEventListener("click", () => {
    if (!confirm("Reset all data, passcode, and log out of your license key?")) return;
    localStorage.clear();
    location.reload();
  });
}

function formatCount(n) {
  if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
  return String(n);
}

function escapeHtml(s) {
  return String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

render();
