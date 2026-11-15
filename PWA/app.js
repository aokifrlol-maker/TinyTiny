const WORKER_BASE = "https://tinytiny-license.aokifrlol.workers.dev";
const PROXY = (url) => `${WORKER_BASE}/v1/proxy?url=${encodeURIComponent(url)}`;

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {});
}

// MARK: - Persistent Store

function getOrCreateDeviceId() {
  let id = localStorage.getItem("tt_device_id");
  if (!id) {
    id = (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now());
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
  fitMode: localStorage.getItem("tt_fit") === "1",
  liked: JSON.parse(localStorage.getItem("tt_liked") || "[]"),
  following: JSON.parse(localStorage.getItem("tt_following") || "[]"),
  dislikedIds: new Set(JSON.parse(localStorage.getItem("tt_disliked") || "[]")),
  watchedCount: Number(localStorage.getItem("tt_watched") || "0"),

  tab: "home", // home | favorites | explore | profile
  channel: "forYou", // following | forYou | rule34 | of | long
  ofSub: "forYou", // forYou | trending | latest
  longSub: "latest", // latest | top | trending
  customFilter: null, // { type: 'subreddit'|'ofCreator'|'search', value: string, label: string }

  items: [],
  page: 1,
  cursor: "",
  loading: false,
  error: "",
  speedLocked2x: false,
  showInstallHint: !window.matchMedia("(display-mode: standalone)").matches && !window.navigator.standalone && !localStorage.getItem("tt_hide_install"),
};

function saveStore() {
  localStorage.setItem("tt_age", state.ageVerified ? "1" : "0");
  localStorage.setItem("tt_onboarded", state.onboarded ? "1" : "0");
  localStorage.setItem("tt_license_key", state.licenseKey);
  localStorage.setItem("tt_passcode", state.passcode);
  localStorage.setItem("tt_pin_skipped", state.passcodeSkipped ? "1" : "0");
  localStorage.setItem("tt_muted", state.muted ? "1" : "0");
  localStorage.setItem("tt_fit", state.fitMode ? "1" : "0");
  localStorage.setItem("tt_liked", JSON.stringify(state.liked.slice(0, 300)));
  localStorage.setItem("tt_following", JSON.stringify(state.following.slice(0, 200)));
  localStorage.setItem("tt_disliked", JSON.stringify(Array.from(state.dislikedIds).slice(-500)));
  localStorage.setItem("tt_watched", String(state.watchedCount));
}

function showToast(msg) {
  const existing = document.querySelector(".toast");
  if (existing) existing.remove();
  const el = document.createElement("div");
  el.className = "glass-pill toast";
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 2200);
}

// MARK: - API Fetchers (via Worker Proxy)

async function fetchGoonedPosts(endpoint) {
  const res = await fetch(PROXY(`https://api.gooned.app${endpoint}`));
  if (!res.ok) throw new Error(`Feed error (${res.status})`);
  const data = await res.json();
  const list = Array.isArray(data) ? data : (data.posts || data.items || data.data || []);
  return list
    .map((p) => {
      const videoUrl = p.videoUrl || p.mp4Url || p.mediaUrl || p.url || "";
      const imageUrl = p.thumbUrl || p.thumbnail || p.poster || p.preview || "";
      const isImg = /\.(jpe?g|png|webp)(\?|$)/i.test(videoUrl) && !/\.mp4|\.webm/i.test(videoUrl);
      if (!videoUrl && !imageUrl) return null;
      return {
        id: String(p.id || p._id || Math.random()),
        source: "reddit",
        author: p.author || p.subreddit || "reddit",
        subreddit: p.subreddit || "",
        title: p.title || "",
        videoUrl: isImg ? "" : PROXY(videoUrl),
        imageUrl: imageUrl ? PROXY(imageUrl) : (isImg ? PROXY(videoUrl) : ""),
        isImage: isImg || !videoUrl,
        rawUrl: videoUrl || imageUrl,
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
      const isImg = att.type === "photo" || (!videoUrl && Boolean(thumbUrl));
      return {
        id: `of_${p.id || sk}`,
        source: "of",
        author: creator,
        creatorId: p.creator?.id || "",
        title: p.text || p.title || `@${creator}`,
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
      const previewMp4 = v.embed ? "" : "";
      if (!thumb) return null;
      return {
        id: `ep_${v.id}`,
        source: "long",
        author: v.keywords ? v.keywords.split(",")[0].trim() : "eporner",
        title: `${v.title || "Video"} (${v.length_min || ""})`,
        videoUrl: previewMp4,
        imageUrl: PROXY(thumb),
        externalUrl: v.url || "",
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
    state.error = "";
    render();
  }
  state.loading = true;
  try {
    let fetched = [];
    if (state.customFilter) {
      if (state.customFilter.type === "subreddit") {
        fetched = await fetchGoonedPosts(`/reddit/subreddit/${encodeURIComponent(state.customFilter.value)}?limit=25`);
      } else if (state.customFilter.type === "search") {
        const [r, r34] = await Promise.all([
          fetchGoonedPosts(`/reddit/search?q=${encodeURIComponent(state.customFilter.value)}&limit=18`).catch(() => []),
          fetchRule34Posts(state.customFilter.value.replace(/\s+/g, "_"), state.page).catch(() => []),
        ]);
        fetched = [...r, ...r34];
      }
    } else if (state.channel === "following") {
      if (state.following.length === 0) {
        fetched = [];
      } else {
        const pick = state.following[Math.floor(Math.random() * state.following.length)];
        fetched = await fetchGoonedPosts(`/reddit/subreddit/${encodeURIComponent(pick)}?limit=25`);
      }
    } else if (state.channel === "forYou") {
      fetched = await fetchGoonedPosts(`/reddit/foryou?limit=25&page=${state.page}`);
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

// MARK: - License Check

async function activateLicenseKey(rawKey) {
  const key = rawKey.trim().toUpperCase();
  const res = await fetch(`${WORKER_BASE}/v1/activate`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ key, deviceId: getOrCreateDeviceId() }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.valid) {
    throw new Error(data.error || "Invalid or expired license key");
  }
  state.licenseKey = key;
  saveStore();
}

// MARK: - Screens

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
  document.getElementById("ageYes").onclick = () => {
    state.ageVerified = true;
    saveStore();
    render();
  };
  document.getElementById("ageNo").onclick = () => {
    location.href = "https://www.google.com";
  };
}

let onboardIdx = 0;
function renderOnboarding() {
  const slides = [
    { icon: "🔥", title: "Welcome to Gooned", sub: "Swipe endlessly. Everything you want in one clean feed.", credit: true },
    { icon: "⚡", title: "All you need", sub: "to goon your brains out — hold for 2x, pull down to lock, double tap to like." },
    { icon: "🔒", title: "Settings & Privacy", sub: "Set a 4-digit passcode or wipe the app in one tap anytime." },
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
        <div class="dots">
          ${slides.map((_, i) => `<div class="dot ${i === onboardIdx ? "active" : ""}"></div>`).join("")}
        </div>
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
      <div class="onboard-orb" style="width:74px;height:74px;font-size:30px;border-radius:50%;">🔑</div>
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
    btn.disabled = true;
    btn.textContent = "Activating...";
    errEl.textContent = "";
    try {
      await activateLicenseKey(val);
      render();
    } catch (e) {
      errEl.textContent = e.message;
      btn.disabled = false;
      btn.textContent = "Activate License Key";
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
        <div class="glass-pill pin-dots">
          ${[0, 1, 2, 3].map((i) => `<div class="pin-dot ${i < pinBuffer.length ? "filled" : ""}"></div>`).join("")}
        </div>
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
          state.passcode = pinBuffer;
          state.unlocked = true;
          pinBuffer = "";
          saveStore();
          render();
        } else if (pinBuffer === state.passcode) {
          state.unlocked = true;
          pinBuffer = "";
          render();
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
      state.passcodeSkipped = true;
      state.unlocked = true;
      pinBuffer = "";
      saveStore();
      render();
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
          <span>Tap Share ↑ → <b>Add to Home Screen</b></span>
          <button id="dismissInstall" style="background:none;border:none;color:#fff;font-weight:900;cursor:pointer;">✕</button>
        </div>
      ` : ""}

      <div class="glass-pill bottom-dock">
        <button class="dock-btn ${state.tab === "home" ? "active" : ""}" data-tab="home" title="Home">🏠</button>
        <button class="dock-btn ${state.tab === "favorites" ? "active" : ""}" data-tab="favorites" title="Favorites">♥</button>
        <button class="dock-btn ${state.tab === "explore" ? "active" : ""}" data-tab="explore" title="Explore">🔍</button>
        <button class="dock-btn ${state.tab === "profile" ? "active" : ""}" data-tab="profile" title="Profile">👤</button>
      </div>
    </div>
  `;

  document.querySelectorAll("[data-tab]").forEach((btn) => {
    btn.onclick = () => {
      state.tab = btn.dataset.tab;
      render();
    };
  });

  const dismiss = document.getElementById("dismissInstall");
  if (dismiss) {
    dismiss.onclick = () => {
      state.showInstallHint = false;
      localStorage.setItem("tt_hide_install", "1");
      render();
    };
  }

  if (state.tab === "home") bindHomeEvents();
  if (state.tab === "explore") bindExploreEvents();
  if (state.tab === "favorites") bindFavoritesEvents();
  if (state.tab === "profile") bindProfileEvents();
}

function renderHomeView() {
  const showOFSubs = state.channel === "of" && !state.customFilter;
  const showLongSubs = state.channel === "long" && !state.customFilter;

  return `
    <div class="top-bar-wrap">
      <div class="top-row">
        <button id="topSearchBtn" class="icon-circle">🔍</button>
        <div class="channel-strip">
          ${state.customFilter ? `
            <button id="clearFilterBtn" class="ch-pill active">${escapeHtml(state.customFilter.label)} ✕</button>
          ` : `
            <button class="ch-pill ${state.channel === "following" ? "active" : ""}" data-ch="following">Following</button>
            <button class="ch-pill ${state.channel === "forYou" ? "active" : ""}" data-ch="forYou">For You</button>
            <button class="ch-pill ${state.channel === "rule34" ? "active" : ""}" data-ch="rule34">34</button>
            <button class="ch-pill ${state.channel === "of" ? "active" : ""}" data-ch="of">OF</button>
            <button class="ch-pill ${state.channel === "long" ? "active" : ""}" data-ch="long">▶</button>
          `}
        </div>
        <button id="topMuteBtn" class="icon-circle">${state.muted ? "🔇" : "🔊"}</button>
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

    ${state.speedLocked2x ? `
      <div class="glass-pill speed-badge">🔒 2x Locked · Tap to Unlock</div>
    ` : ""}

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
  const fitClass = state.fitMode ? "fit" : "";
  return `
    <div class="reel-cell" data-idx="${idx}" data-id="${escapeHtml(item.id)}">
      ${item.isImage || !item.videoUrl ? `
        <img class="reel-media ${fitClass}" src="${escapeHtml(item.imageUrl)}" loading="lazy" alt="" />
      ` : `
        <video class="reel-media ${fitClass}" src="${escapeHtml(item.videoUrl)}" poster="${escapeHtml(item.imageUrl || "")}"
          playsinline webkit-playsinline loop preload="${idx < 2 ? "auto" : "metadata"}" ${state.muted ? "muted" : ""}></video>
      `}

      <div class="reel-actions">
        <button class="act-btn ${isLiked ? "liked" : ""}" data-like="${idx}" title="Like">♥</button>
        <button class="act-btn" data-fit="${idx}" title="Fit/Fill">${state.fitMode ? "⤢" : "⤡"}</button>
        <button class="act-btn" data-dislike="${idx}" title="Dislike">👎</button>
        <button class="act-btn" data-share="${idx}" title="Share">↗</button>
      </div>

      <div class="reel-overlay-bottom">
        <button class="creator-chip" data-creator="${idx}">@${escapeHtml(item.author || "post")}</button>
        ${item.title ? `<div class="reel-title">${escapeHtml(item.title)}</div>` : ""}
      </div>
    </div>
  `;
}

function bindHomeEvents() {
  document.getElementById("topSearchBtn").onclick = () => {
    state.tab = "explore";
    render();
  };

  document.getElementById("topMuteBtn").onclick = () => {
    state.muted = !state.muted;
    saveStore();
    document.querySelectorAll("video").forEach((v) => (v.muted = state.muted));
    document.getElementById("topMuteBtn").textContent = state.muted ? "🔇" : "🔊";
  };

  const clearBtn = document.getElementById("clearFilterBtn");
  if (clearBtn) {
    clearBtn.onclick = () => {
      state.customFilter = null;
      loadFeed(true);
    };
  }

  document.querySelectorAll("[data-ch]").forEach((btn) => {
    btn.onclick = () => {
      state.channel = btn.dataset.ch;
      state.customFilter = null;
      loadFeed(true);
    };
  });

  document.querySelectorAll("[data-ofsub]").forEach((btn) => {
    btn.onclick = () => {
      state.ofSub = btn.dataset.ofsub;
      loadFeed(true);
    };
  });

  document.querySelectorAll("[data-longsub]").forEach((btn) => {
    btn.onclick = () => {
      state.longSub = btn.dataset.longsub;
      loadFeed(true);
    };
  });

  const retryBtn = document.getElementById("retryFeedBtn");
  if (retryBtn) retryBtn.onclick = () => loadFeed(true);

  document.querySelectorAll("[data-like]").forEach((btn) => {
    btn.onclick = (e) => {
      e.stopPropagation();
      toggleLike(state.items[Number(btn.dataset.like)], btn);
    };
  });

  document.querySelectorAll("[data-fit]").forEach((btn) => {
    btn.onclick = (e) => {
      e.stopPropagation();
      state.fitMode = !state.fitMode;
      saveStore();
      document.querySelectorAll(".reel-media").forEach((m) => m.classList.toggle("fit", state.fitMode));
      document.querySelectorAll("[data-fit]").forEach((b) => (b.textContent = state.fitMode ? "⤢" : "⤡"));
    };
  });

  document.querySelectorAll("[data-dislike]").forEach((btn) => {
    btn.onclick = (e) => {
      e.stopPropagation();
      const idx = Number(btn.dataset.dislike);
      const item = state.items[idx];
      if (!item) return;
      state.dislikedIds.add(item.id);
      state.items.splice(idx, 1);
      saveStore();
      showToast("Hidden from feed");
      render();
    };
  });

  document.querySelectorAll("[data-share]").forEach((btn) => {
    btn.onclick = async (e) => {
      e.stopPropagation();
      const item = state.items[Number(btn.dataset.share)];
      if (!item) return;
      const url = item.externalUrl || item.rawUrl || location.href;
      if (navigator.share) {
        navigator.share({ title: item.title || "Gooned", url }).catch(() => {});
      } else {
        await navigator.clipboard.writeText(url).catch(() => {});
        showToast("Link copied!");
      }
    };
  });

  document.querySelectorAll("[data-creator]").forEach((btn) => {
    btn.onclick = (e) => {
      e.stopPropagation();
      const item = state.items[Number(btn.dataset.creator)];
      if (!item) return;
      if (item.subreddit) {
        if (!state.following.includes(item.subreddit)) {
          state.following.push(item.subreddit);
          saveStore();
        }
        state.customFilter = { type: "subreddit", value: item.subreddit, label: `r/${item.subreddit}` };
        loadFeed(true);
      } else if (item.externalUrl) {
        window.open(item.externalUrl, "_blank");
      }
    };
  });

  // Active video playback + Hold 2x + Pull Down Lock + Tap/Double-Tap
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
          if (idx >= state.items.length - 4 && !state.loading) {
            loadFeed(false);
          }
        } else if (vid) {
          vid.pause();
        }
      }
    },
    { root: scroller, threshold: 0.65 }
  );

  document.querySelectorAll(".reel-cell").forEach((cell) => {
    reelObserver.observe(cell);
    attachCellGestures(cell);
  });
}

function attachCellGestures(cell) {
  let holdTimer = null;
  let holding = false;
  let startY = 0;
  let lastTap = 0;

  cell.addEventListener("pointerdown", (e) => {
    if (e.target.closest("button")) return;
    startY = e.clientY;
    holdTimer = setTimeout(() => {
      holding = true;
      const vid = cell.querySelector("video");
      if (vid) vid.playbackRate = 2.0;
    }, 220);
  });

  cell.addEventListener("pointermove", (e) => {
    if (holding && !state.speedLocked2x && e.clientY - startY > 28) {
      state.speedLocked2x = true;
      showToast("2x Speed Locked");
      const badge = document.createElement("div");
      badge.className = "glass-pill speed-badge";
      badge.textContent = "🔒 2x Locked · Tap to Unlock";
      document.querySelector(".main-shell")?.appendChild(badge);
    } else if (!holding && Math.abs(e.clientY - startY) > 12) {
      clearTimeout(holdTimer);
    }
  });

  const endHold = () => {
    clearTimeout(holdTimer);
    if (holding) {
      holding = false;
      if (!state.speedLocked2x) {
        const vid = cell.querySelector("video");
        if (vid) vid.playbackRate = 1.0;
      }
    }
  };
  cell.addEventListener("pointerup", (e) => {
    if (e.target.closest("button")) { endHold(); return; }
    const wasHolding = holding;
    endHold();
    if (wasHolding || Math.abs(e.clientY - startY) > 14) return;

    const now = Date.now();
    const vid = cell.querySelector("video");
    if (now - lastTap < 260) {
      // Double tap -> Like
      lastTap = 0;
      const idx = Number(cell.dataset.idx);
      const likeBtn = cell.querySelector(`[data-like="${idx}"]`);
      if (state.items[idx] && !state.liked.some((x) => x.id === state.items[idx].id)) {
        toggleLike(state.items[idx], likeBtn);
      }
      const heart = document.createElement("div");
      heart.className = "heart-burst";
      heart.textContent = "♥";
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
            p.textContent = "▶";
            cell.appendChild(p);
          }
        }
      }, 265);
    }
  });
  cell.addEventListener("pointercancel", endHold);
}

function toggleLike(item, btnEl) {
  if (!item) return;
  const idx = state.liked.findIndex((x) => x.id === item.id);
  if (idx >= 0) {
    state.liked.splice(idx, 1);
    btnEl?.classList.remove("liked");
  } else {
    state.liked.unshift(item);
    btnEl?.classList.add("liked");
  }
  saveStore();
}

function renderFavoritesView() {
  return `
    <div class="page-scroll">
      <h2 style="font-size:24px;font-weight:900;margin:0 0 14px;">Favorites (${state.liked.length})</h2>
      ${state.liked.length === 0 ? `<p style="color:var(--muted);">Double-tap or press ♥ on any post to save it here.</p>` : `
        <div class="grid-2">
          ${state.liked.map((item, i) => `
            <div class="thumb-card" data-fav="${i}">
              <img src="${escapeHtml(item.imageUrl || item.videoUrl)}" loading="lazy" alt="" />
              <div class="thumb-label">@${escapeHtml(item.author || "post")}</div>
            </div>
          `).join("")}
        </div>
      `}
    </div>
  `;
}

function bindFavoritesEvents() {
  document.querySelectorAll("[data-fav]").forEach((card) => {
    card.onclick = () => {
      const item = state.liked[Number(card.dataset.fav)];
      if (!item) return;
      state.items = [item, ...state.liked.filter((x) => x.id !== item.id)];
      state.tab = "home";
      render();
    };
  });
}

function renderExploreView() {
  return `
    <div class="page-scroll">
      <h2 style="font-size:24px;font-weight:900;margin:0 0 12px;">Search</h2>
      <div style="display:flex;gap:8px;margin-bottom:18px;">
        <input id="searchInput" class="input-box" style="text-align:left;" placeholder="Search tags, subreddits, creators..." />
        <button id="searchGo" class="btn-primary" style="width:auto;padding:0 20px;">Go</button>
      </div>
      <div style="color:var(--muted);font-size:13px;font-weight:700;margin-bottom:10px;">FOLLOWED SUBREDDITS</div>
      <div style="display:flex;flex-wrap:wrap;gap:8px;">
        ${state.following.length === 0 ? `<span style="color:var(--muted);font-size:13px;">Tap any @creator pill on a post to follow</span>` :
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
      <h2 style="font-size:24px;font-weight:900;margin:0 0 16px;">Profile & Settings</h2>
      <div class="glass-card" style="padding:16px;margin-bottom:14px;display:grid;grid-template-columns:repeat(3,1fr);text-align:center;gap:8px;">
        <div><div style="font-size:22px;font-weight:900;">${state.watchedCount}</div><div style="font-size:12px;color:var(--muted);">Watched</div></div>
        <div><div style="font-size:22px;font-weight:900;">${state.liked.length}</div><div style="font-size:12px;color:var(--muted);">Liked</div></div>
        <div><div style="font-size:22px;font-weight:900;">${state.following.length}</div><div style="font-size:12px;color:var(--muted);">Following</div></div>
      </div>

      <div class="glass-card" style="padding:16px;display:flex;flex-direction:column;gap:12px;">
        <div style="font-size:13px;color:var(--muted);">License: <b style="color:#fff;">${escapeHtml(state.licenseKey)}</b></div>
        ${state.passcode ? `<button id="lockNowBtn" class="btn-primary" style="background:rgba(255,255,255,0.12);box-shadow:none;">Lock App Now</button>` : ""}
        <button id="resetAppBtn" class="btn-primary" style="background:linear-gradient(135deg,#dc2626,#991b1b);">Reset App & Log Out</button>
      </div>
      <div class="matted-credit" style="text-align:center;margin-top:24px;">by bella</div>
    </div>
  `;
}

function bindProfileEvents() {
  const lockBtn = document.getElementById("lockNowBtn");
  if (lockBtn) {
    lockBtn.onclick = () => {
      state.unlocked = false;
      render();
    };
  }
  document.getElementById("resetAppBtn").onclick = () => {
    if (!confirm("Reset all data, passcode, and log out of your license key?")) return;
    localStorage.clear();
    location.reload();
  };
}

function escapeHtml(s) {
  return String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

render();
