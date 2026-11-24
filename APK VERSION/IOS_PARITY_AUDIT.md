# TinyTiny Android ↔ iOS Exhaustive Line-by-Line Parity Audit (Complete Unabridged Edition)

> **Scope:** Every single line of all **19 iOS Swift files** (`TinyTiny/*.swift`) compared 1:1 against all **19 Android Kotlin files** (`APK VERSION/app/src/main/java/com/bella/tinytiny/*.kt`) + `AndroidManifest.xml`, `build.gradle.kts`, `proguard-rules.pro`, and `res/*`.
> **Total Discrepancies & Bugs Cataloged:** **185+ verified, line-numbered items across all 20 audit sections.**
> **Hard Constraint:** NEVER break existing iOS code or iOS Cloudflare KV cloud saves (`backup:<KEY>`).
> **Status:** Complete audit — awaiting user greenlight before modifying any code.

---

## Table of Contents
1. [Android Build, Manifest, ProGuard & Resources](#1-android-build-manifest-proguard--resources)
2. [`API.swift` vs `API.kt`](#2-apiswift-vs-apikt)
3. [`Models.swift` vs `Models.kt`](#3-modelsswift-vs-modelskt)
4. [`Theme.swift` vs `Theme.kt`](#4-themeswift-vs-themekt)
5. [`CryptoBox.swift` vs `CryptoBox.kt`](#5-cryptoboxswift-vs-cryptoboxkt)
6. [`LicenseManager.swift` vs `LicenseManager.kt`](#6-licensemanagerswift-vs-licensemanagerkt)
7. [`ShareService.swift` vs `ShareService.kt`](#7-shareserviceswift-vs-shareservicekt)
8. [`Security.swift` vs `Security.kt`](#8-securityswift-vs-securitykt)
9. [`OfflineManager.swift` vs `OfflineManager.kt`](#9-offlinemanagerswift-vs-offlinemanagerkt)
10. [`TinyTinyApp.swift` vs `TinyTinyApplication.kt` + `MainActivity.kt`](#10-tinytinyappswift-vs-tinytinyapplicationkt--mainactivitykt)
11. [`FeedView.swift` vs `FeedView.kt`](#11-feedviewswift-vs-feedviewkt)
12. [`Screens.swift` vs `Screens.kt`](#12-screensswift-vs-screenskt)
13. [`FeedModel.swift` vs `FeedModel.kt`](#13-feedmodelswift-vs-feedmodelkt)
14. [`SmartTasteEngine.swift` vs `SmartTasteEngine.kt`](#14-smarttasteengineswift-vs-smarttasteenginekt)
15. [`UserStore.swift` vs `UserStore.kt` (incl. `AdultContentClassifier` & `PornTagCatalog`)](#15-userstoreswift-vs-userstorekt)
16. [`XService.swift` vs `XService.kt`](#16-xserviceswift-vs-xservicekt)
17. [`InstagramService.swift` vs `InstagramService.kt`](#17-instagramserviceswift-vs-instagramservicekt)
18. [`OnlyFansService.swift` vs `OnlyFansService.kt`](#18-onlyfansserviceswift-vs-onlyfansservicekt)
19. [`Rule34Service.swift` vs `Rule34Service.kt`](#19-rule34serviceswift-vs-rule34servicekt)
20. [`LongVideoService.swift` vs `LongVideoService.kt`](#20-longvideoserviceswift-vs-longvideoservicekt)
21. [Phased Implementation Roadmap](#21-phased-implementation-roadmap)

---

## 1. Android Build, Manifest, ProGuard & Resources

- [ ] **`AndroidManifest.xml:17` — CRITICAL Cleartext HTTP Block:** `android:usesCleartextTraffic="false"` with NO `android:networkSecurityConfig`. Any `http://` media URL (allowed by `Models.kt:238`) or HTTP redirect from scraped CDNs fails in OkHttp, ExoPlayer, Coil, and WebView with `Cleartext HTTP traffic not permitted`. Fix: add `res/xml/network_security_config.xml` (or enable cleartext for media CDNs) and reference it in the manifest.
- [ ] **`AndroidManifest.xml:11-17` — Missing App Icon:** No `android:icon` or `android:roundIcon` and no `mipmap`/`drawable` icon resources in `res/` — APK installs with the default green Android robot icon instead of the TinyTiny logo.
- [ ] **`AndroidManifest.xml:21` — Incomplete `configChanges`:** Only declares `orientation|screenSize|screenLayout|keyboardHidden` — missing `smallestScreenSize|uiMode|density` (split-screen, foldable, or system dark-mode changes destroy & recreate `MainActivity`, wiping all in-memory `FeedModel` state).
- [ ] **`res/xml/file_paths.xml:1-5` — Overly Broad FileProvider Scope:** Exposes entire `<files-path path="."/>` (including encrypted stores!) instead of restricting to `OfflineVault/` and `cache/`. Also `FileProvider` is declared in `AndroidManifest.xml:38-46` but **never referenced anywhere in Kotlin** (local file sharing in `ShareItemSheet` is unwired).
- [ ] **`proguard-rules.pro:1-3` — R8/ProGuard Stripping Bugs:** Missing `-keepattributes *Annotation*, JavascriptInterface, InnerClasses, EnclosingMethod`, missing `-keepclassmembers class * { @android.webkit.JavascriptInterface <methods>; }` (would silently destroy X & IG JS bridges if `isMinifyEnabled = true`), and missing `-dontwarn org.bouncycastle.**, org.openjsse.**, javax.annotation.**`.
- [ ] **`AndroidManifest.xml:30-35` — Deep Links:** Registers `tinytiny://` only; does not register `https://` links for `/s/<id>` drops.

---

## 2. `API.swift` vs `API.kt`

- [ ] **Missing `Lossy<T>` Decoding Wrapper (`API.swift:43`, `Models.swift:11-14` vs `API.kt:65, 83, 91, 99, 107, 116, 120`):** A single malformed `Gif` or `GoonedSearchItem` in any feed/search JSON array crashes the **entire** request with `SerializationException` on Android; iOS silently drops the bad item and keeps the rest.
- [ ] **Path Encoding Divergence (`API.swift:46-48` vs `API.kt:41`):** `encPath` uses `URLEncoder.encode` (encodes `/`, `&`, `@`, `+`) vs iOS `.urlPathAllowed`.
- [ ] **Timeout Parity (`API.swift:19-31` vs `TinyTinyApplication.kt:17-24`):** Android uses 25s read/write timeout (iOS uses 18s with `.reloadIgnoringLocalCacheData`).

---

## 3. `Models.swift` vs `Models.kt`

- [ ] **CRITICAL — Blurred Reddit Thumbnails (`Models.swift:296-304` vs `Models.kt:195-197`):** `Gif.thumbURL` checks `thumbnailUrl` **before** `posterUrl` (inverted from iOS!). Reddit's `thumbnailUrl` is the 140px blurred NSFW placeholder. Must check `OfflineManager.localThumbURL(id)` → `posterUrl` → `thumbnailUrl` → `mediaUrl`.
- [ ] **CRITICAL — `GoonedSearchItem` JSON Key Mismatch (`Models.swift:345-350` vs `Models.kt:285-292`):** Android names the field `icon: String?` instead of `iconUrl: String?`, so subreddit icons returned by the API are silently ignored! Also `id` is not lowercased (`name.lowercase()`).
- [ ] **CRITICAL — `MediaHeaders.headers()` Missing Default Referer & Hosts (`FeedView.swift:64-104` vs `Models.kt:368-389`):**
  - Missing default `else -> Config.referer` (`"https://gooned.app/"`) — proxied Reddit/Redgifs streams on `api.gooned.app` get no `Referer` and 403!
  - Missing host rules: `yande.re`, `hypnohub`, `realbooru`, `gelbooru`, `x.com`/`twitter.com` (Android only checks `twimg.com`), `instagram.com` (Android only checks `cdninstagram`/`fbcdn`).
  - Narrower substring checks (`rule34.xxx` vs `rule34`, `eporner.com` vs `eporner`, `sb-cd.com` vs `sb-cd`).
  - Should match against `URI(urlString).host?.lowercase()` instead of full URL string, and accept `includeReferer: Boolean = true` for no-Referer retry.
- [ ] **`Gif` Equality & Hashing (`Models.swift:37-38` vs `Models.kt:17`):** Android `data class Gif` compares all 18 fields instead of only `id` (two `Gif` instances with same `id` but updated `upvotes` or `posterUrl` are treated as unequal in `Set`/`List`).
- [ ] **URL Resolver Gaps (`Models.swift:250-310` vs `Models.kt:149-201`):**
  - `imageFallbackURLs`, `posterURL`, `posterFallbackURLs`, `thumbURL` all omit `OfflineManager.localMediaURL` / `OfflineManager.localThumbURL`.
  - `webURL` (`permalink ?? sourceUrl ?? "https://gooned.app"`) is missing on Android.
  - `normalizedMediaDedupeKey` (`Models.kt:272`) uses `cleanPath.substringBeforeLast('.')` which truncates directory segments containing `.` if filename has no extension (must only strip extension on last path segment).
  - `contentSimilarityKey` (`Models.kt:135-147`) uses ASCII-only regex `[^a-z0-9]+` (drops non-ASCII letters).
- [ ] **`Gif.relativeTime` (`Models.swift:312-324` vs `Models.kt:202-218`):** `Instant.parse(raw)` fails on non-`Z` offsets (`+00:00`), shows `"Xs"` instead of flooring `<1h` to `"1m"`, and lacks years (`"2y"` shows as `"24mo"`).
- [ ] **`shortCount` (`Models.swift:373-378` vs `Models.kt:241-249`):** Returns `""` instead of `"0"` for `null`/`0`.
- [ ] **`MediaMetaRegistry` Major Gaps (`Models.swift:388-586` vs `Models.kt:319-366`):**
  - Missing **44 of 61 stop tags** (`eporner`, `pornhub`, `xhamster`, `spankbang`, `xvideos`, `tiktok`, `tiktok_nsfw`, `snapchat`, `snapchat_nsfw`, `foryoupage`, `viral`, `trending`, `new`, `free`, `ppv`, `customs`, `linkinbio`, `dm`, `dms`, `announcements`, `vip`, `promo`, `subscribe`, `sub`, `like`, `repost`, `rt`, `videos`, `gifs`, `hd`, `4k`, `1080p`, `720p`, `mp4`, `18+`, `18plus`, `explore`, `reels`, `reel`, `shorts`, `gooning`, `gooned`).
  - `register(...)` does NOT filter stop tags and overwrites `tagsById[postId]` instead of merging.
  - Missing `fingerprint` map, `postCreatorIds`, `viewerFollowsByKey`, `creatorClusterTags` (24-tag cap/creator), `creatorGenderByKey`, and `>4000` eviction cap.
  - Missing methods: `registerAlbumItems`, `registerCreatorGender`, `isFollowedByViewer`, `creatorId(for:)`, and creator-cluster inheritance in `tags(for:author:)` & `creatorGender(for:author:)`.
  - `canonicalMediaFingerprint` ignores registered fingerprints.

---

## 4. `Theme.swift` vs `Theme.kt`

- [ ] **Liquid Glass Alpha & Tint Parity (`Theme.swift:46-142` vs `Theme.kt:69-111`):**
  - `liquidGlassCapsule`: tinted alpha `0.68` vs iOS `0.55`; clear alpha `0.42` vs iOS `0.25`.
  - `liquidGlassCard`: tinted uses crimson `0.62` vs iOS `Color.white.opacity(0.10)`; clear `0.08` vs iOS `0.05`.
  - `liquidGlassBackground`: gradient `0.92..0.96` vs iOS `0.62` / `0.35`.
- [ ] **Missing `ScalePressButtonStyle` (`Theme.swift:215-222`):** Press scale `0.92` + opacity `0.85` (130ms easeOut).
- [ ] **Brand Logos (`TinyTinyApp.swift:1342-1530` vs `Theme.kt:113-219`):**
  - Missing `active: Boolean` & `connected: Boolean` props, active/inactive border strokes (`1.5..1.8` white vs `0.7..0.8` white `0.28`), inactive dim opacity, and `6dp` `Theme.accentBright` connected dot with black stroke.
  - `BrandLogoX`: missing `26dp` circle container (currently bare white `"𝕏"` text).
  - `BrandLogoInstagram`: uses Material `CameraAlt` + 3-stop gradient instead of iOS 4-stop gradient (`#FCC247`, `#F54557`, `#C229A6`, `#613DE0`) + custom-drawn camera outline/lens/flash glyph.
  - `BrandLogoRule34`, `BrandLogoErome`, `BrandLogoLongVideos`, `BrandLogoOnlyFans`: match exact iOS diagonal gradients & colors.

---

## 5. `CryptoBox.swift` vs `CryptoBox.kt`

- [ ] **CRITICAL Performance & Key-Loss Bug (`CryptoBox.kt:31-46, 54-76, 95-100`):** `securePrefs()` rebuilds `MasterKey` and re-opens `EncryptedSharedPreferences` on **every single call** (not cached with `by lazy`!). Also transient Keystore error falls back to `_fallback` and mints a brand-new key, stranding previously encrypted local vault files.
- [ ] **Off-by-One Decrypt Bug (`CryptoBox.kt:119`):** `ciphertext.size > offset + 12 + 16` rejects valid 0-byte encrypted payloads (must be `>=`).

---

## 6. `LicenseManager.swift` vs `LicenseManager.kt`

- [ ] **CRITICAL — Cookie Scope & Expiry Bug (`LicenseManager.kt:480-490` vs `LicenseManager.swift:459-502`):** `injectRestoredSocialCookies()` sets session-only cookies with **NO `Domain=.x.com`/`.twitter.com`/`.instagram.com`** and **NO `Max-Age`/`Expires`** — subdomains (`i.instagram.com`, `api.x.com`) don't receive them and cookies vanish when WebView closes!
- [ ] **Sync Triggers & Merge Safety (`UserStore.kt:214`, `LicenseManager.kt:354-356, 413-418`):**
  - `scheduleCloudSync()` only called in `toggleLike` — never in `toggleFollow*`, `updateXSession`, `updateIGSession`, `updateR34Credentials`, `recordDownloaded`, `dislike`, `updateSourceSettings`, `resetTaste`, or `MainActivity.onStop()`.
  - `scheduleCloudSync()` uploads without restoring/merging remote backup first (can overwrite newer iOS likes).
  - `lastRemoteBackupJson` is set before decode succeeds.
  - `followedOFCreators` merge (`L439`) dedupes by `id` only instead of `(id, handle)`.
- [ ] **`activate()` & `verifySilently()` Bugs (`LicenseManager.kt:254, 262, 291, 297`):**
  - `optDouble("expiresAt")` returns `Double.NaN` on non-numeric value → permanently locks user out (`now < NaN` is `false`).
  - `optString("error", fallback)` returns `""` or `"null"` when server returns empty/null error.
  - `verifySilently()` defaults `valid = true` when key omitted, and retains stale `expiresAt` when a key is upgraded to lifetime (`expiresAt: null`).
- [ ] **Missing `clearLicense()` (`LicenseManager.swift:215-223`)** and **25s upload timeout** on `uploadTemporaryEncryptedBlob` (iOS uses 120s).
- [ ] **`LicenseGateView` Missing UI (`LicenseManager.swift:698-733` vs `LicenseManager.kt:560-658`):** Missing `"Copy Key"` button + 2s `"Copied!"` toast, missing `"Check Status"` button, missing haptics & radial gradient halo.
- [ ] **Device ID Reinstall Survival (`LicenseManager.kt:119-147`):** Uninstalling wipes `deviceId` (new UUID on reinstall), and transient Keystore errors split state between `PREFS_NAME` and `_fb`.

---

## 7. `ShareService.swift` vs `ShareService.kt`

- [ ] **CRITICAL — iOS Cannot Decode Android Drops (`ShareService.swift:8-18` vs `ShareService.kt:41-48`):** `ShareDropPayload` omits required iOS non-optional fields `version: Int = 1`, `kind: String`, and non-null `title: String`, plus optional `fileName: String?` and `inlineBase64: String?`.
- [ ] **Infinite Spinner Bug (`ShareService.kt:292-296, 316-318, 382-383`):** If `createEncryptedShareLink` or `createEncryptedCollectionShareLink` returns `null`, `ShareItemSheet` & `ShareCollectionSheet` spin forever with no error message or retry button.
- [ ] **Metadata Leak (`ShareService.kt:72`):** Sends real `file.name` in `X-File-Name` header instead of random `"${UUID}.ttenc"`.
- [ ] **25s HTTP Timeout (`ShareService.kt:58`):** Uses `sharedHttpClient` (25s) vs iOS 90s/180s for encrypted video blob uploads/downloads.
- [ ] **Missing Functions:** `createEncryptedFileShareLink(fileURL, title)` and `createEncryptedRemoteMediaShareLink(for:)`; `createEncryptedCollectionShareLink` doesn't guard empty list or delegate 1-item list.
- [ ] **Missing UI in Sheets:**
  - `ShareItemSheet`: manual `"Generate Secret Link"` / `"Regenerate"`, error `statusNote`, Admin **"Send MP4 to IG DM / Group (Admin)"** button, **"Share Downloaded Video File"** (via `FileProvider`), **"Share Source URL"**.
  - `ShareCollectionSheet`: optional **"Collection Title"** `TextField`, `"Regenerate Link"`, error `statusNote`.
  - `ReceiveDropSheet`: **"Share a Video or File From Files (AES-256 Encrypted)"** file picker + `onOpenPost` callback.
  - `IGDirectSendSheet`: group vs DM icons (`person.3.fill`/`person.fill`) and inbox error display.

---

## 8. `Security.swift` vs `Security.kt`

- [ ] **SECURITY BUG — `PasscodeSetupView` (`Security.swift:918-1038` vs `Security.kt:264-306`):** Missing `Mode.change` + `Step.current` (never verifies current passcode before changing it!). Missing post-creation `"Enable Biometrics Unlock?"` prompt, shake animation, haptics, step badges.
- [ ] **`LockView` Biometric Resume Bug (`Security.swift:1077-1078` vs `Security.kt:323-327`):** Only triggers biometrics in `LaunchedEffect(Unit)` — does NOT re-trigger on `Lifecycle.Event.ON_RESUME`. Missing shake animation, haptics, and async loading spinner on `verifyPasscodeRecovery()`.
- [ ] **`AppState` Gaps (`Security.swift:74, 78, 114-125` vs `Security.kt:107-109`):** Init doesn't check `LicenseManager.isValidAccess` for `onboardingCompleted` or `Passcode.exists` for `passcodeChoiceCompleted`; missing `eraseEverything()`.
- [ ] **`AgeGateView` (`Security.swift:422-545` vs `Security.kt:169-204`):** Missing `"I'm under 18"` button + `"Access Restricted"` alert, `"18+"` glass badge, spring entrance, radial glow, `"by bella"`.
- [ ] **`WelcomeOnboardingView` (`Security.swift:547-916` vs `Security.kt:206-262`):** 3 non-swipeable cards with no `"Skip"` button vs iOS 4 swipeable pages (`HorizontalPager`), `"Skip"` button on pages 0–2, floating aura blobs, pulsing ring, staggered reveals.
- [ ] **`Biometrics.PromptInfo` (`Security.kt:71-99`):** Add `.setAllowedAuthenticators(BIOMETRIC_WEAK or BIOMETRIC_STRONG)` to match `available()`.

---

## 9. `OfflineManager.swift` vs `OfflineManager.kt`

- [ ] **CRITICAL — Discards Resolved LongVideo URLs (`OfflineManager.kt:55-57` vs `OfflineManager.swift:102-104`):** Calls `LongVideoAPI.resolvePlayableURLs(gif)` and throws away the return value!
- [ ] **CRITICAL — No `Content-Type` Validation (`OfflineManager.kt:110-124`):** Accepts any HTTP 200 body > 1KB, saving HTML error/login pages as corrupt `.mp4` files (iOS rejects `text/html`, `application/json`, `mpegurl`).
- [ ] **CRITICAL — No WebView Cookies Attached (`OfflineManager.kt:102-129`):** Never attaches `CookieManager` cookies to OkHttp download requests, so cookie-gated X/IG/OF downloads fail.
- [ ] **CRITICAL — Pollutes Cloud Backup With `file://` Paths (`OfflineManager.kt:85-91`):** Overwrites `mediaUrl`/`muxedUrl`/`muxedUrlHd` with local Android `file://` URIs in `UserStore`, breaking iOS sync! Must keep original remote URLs and resolve local paths dynamically via `localMediaURL(id)`.
- [ ] **Missing Offline Thumbnails (`OfflineManager.swift:59-66, 186-200, 217-229`):** Never downloads `_thumb.jpg` or extracts first video frame via `MediaMetadataRetriever` (`localThumbURL(id)` missing), so offline grid breaks in Airplane Mode.
- [ ] **Image Download Priority Wrong (`OfflineManager.kt:59-62`):** Doesn't branch on `gif.isImage` to iterate `imageFallbackURLs`.
- [ ] **25s Read Timeout (`OfflineManager.kt:19, 109`):** Uses `sharedHttpClient` (25s) instead of dedicated 300s download client.
- [ ] **Unchecked `renameTo` (`OfflineManager.kt:118`):** Doesn't delete existing `dest` before `tmp.renameTo(dest)`.
- [ ] **Missing Progress Tracking (`OfflineManager.swift:12-13`):** Exposes `Set<String>` instead of `StateFlow<Map<String, Double>>` (no determinate progress ring).
- [ ] **Dead & Buggy `saveToMediaStoreGallery` (`OfflineManager.kt:131-157`):** Marked `private` and never called; hardcodes `"video/mp4"`/`"image/jpeg"` regardless of extension (`.png`, `.gif`, `.webp`, `.mov`); missing API 26–28 permission check.
- [ ] **`safeFileStem` (`OfflineManager.kt:28`):** Allows `.`, no 64-char cap, no `"media"` fallback.

---

## 10. `TinyTinyApp.swift` vs `TinyTinyApplication.kt` + `MainActivity.kt`

- [ ] **Missing OkHttp Disk Cache (`TinyTinyApplication.kt:17-24`):** Configure `Cache(cacheDir/http_cache, 200MB)` (iOS has 64MB mem / 400MB disk `URLCache`) + dedicated 300s/120s clients for offline downloads & share blobs.
- [ ] **Missing `onStop()` Background Sync & Taste Save (`MainActivity.kt:68-73`):** Must call `SmartTasteEngine.shared.saveNow()` AND `LicenseManager.syncEncryptedBackupNow()`.
- [ ] **Missing Foreground License Re-verify (`MainActivity.kt:114-119`):** Re-run `LicenseManager.verifySilently()` on `ON_RESUME`, not only once on cold start.
- [ ] **Unconditional `FLAG_SECURE` & Privacy Cover Bug (`MainActivity.kt:53, 741-748`):** Only apply `FLAG_SECURE` / `PrivacyCover` when `AppState.hasPasscode && AppState.requirePasscodeOnOpen`.
- [ ] **Missing Dynamic Orientation Lock (`TinyTinyApp.swift:4-32, 728-737`):** Allow landscape on Home feed; lock portrait on Likes/Browse/Profile.
- [ ] **Missing `key(activeChannel)` Around `FeedView` (`MainActivity.kt:482-496`):** Switching channels inherits stale `pagerState.currentPage`.
- [ ] **Persistent Per-Site LongVideo `FeedModel`s (`MainActivity.kt:45, 236-237, 595-602`):** Maintain 7 separate `FeedModel` instances (`longAll`, `longEporner`, `longXVideos`, `longPornhub`, `longXHamster`, `longSpankBang`, `longErome`) instead of mutating 1 model and destroying scroll position. Label `"All"` instead of `"All Sites"`.
- [ ] **Sub-Channel Memory (`MainActivity.kt:540-562`):** Remember `lastXChannel`, `lastIGChannel`, `lastOFChannel`, `lastLongChannel`.
- [ ] **Tap Active Channel to Force-Reload & Tap Home When on Home to Refresh (`MainActivity.kt:341-363, 535-567, 687`).**
- [ ] **Live Taste-Change Feed Observers (`TinyTinyApp.swift:688-705`):** Observe `boostedTags`/`blockedTags` to immediately call `refreshTailForUpdatedTaste` and `purgeSuppressedItems` on all main models.
- [ ] **Inverted X Connection Dot & Missing IG Dot (`MainActivity.kt:539`):** Fix `showDot = userData.xSession.isConnected` (currently `!isConnected`!) and add connected dot on IG.
- [ ] **Top Channel Rail Auto-Centering & Edge Fade Mask (`MainActivity.kt:530-568`):** Center active icon with smooth scroll + horizontal fade gradient mask + scale/opacity animation (`1.08` vs `0.90`), no underline under brand icons.
- [ ] **Sub-Channel Bar (`MainActivity.kt:605-624`):** Single centered `liquidGlassCapsule` wrapping sub-channel text items (matching iOS) instead of separate left-aligned pills.
- [ ] **Horizontal Swipe Album Conflict (`MainActivity.kt:446-480`):** Skip channel swipe when current post has `albumItems.size > 1`; allow swipe on `CUSTOM`.
- [ ] **Bottom Dock Parity (`MainActivity.kt:676-692, 816-827`):** Full-width minus 28dp padding, 58dp height, swipe-down >16dp to collapse controls, outline vs filled icons, white active tint, bordered active circle, haptics.
- [ ] **Other Shell Parity:** Keep `FeedView` mounted during X/IG login (pause via `isVisible`); preserve `activeModel.source` on `onConnectX`/`onConnectIG`; pass `initialScope` & `onOpenPost` to Browse; cap `customBackStack` at 16; stagger cold-launch prewarming + call `loadMore()` for X/IG; animate `RootView` gate transitions & announcement banner; add icon circle + glass button to `RemoteGateOverlay`.

---

## 11. `FeedView.swift` vs `FeedView.kt`

- [ ] **CRITICAL — `SurfaceView` → `TextureView` (`FeedView.kt:894-909`):** `PlayerView` defaults to `SurfaceView`, causing black frames, detached surfaces, and compositing glitches inside Compose `VerticalPager`. Switch to `TextureView` (`app:surface_type="texture_view"` or custom `TextureView` + `player.setVideoTextureView`).
- [ ] **CRITICAL — `DisposableEffect` Kills Live `ExoPlayer` (`FeedView.kt:259-300`):** `DisposableEffect(exoPlayer, autoScroll, playVideosToEnd)` calls `exoPlayer?.release()` whenever settings change → permanent blackscreen! Decouple settings with `rememberUpdatedState`.
- [ ] **CRITICAL — `DefaultDataSource.Factory`, Per-Request Headers & HLS MIME (`FeedView.kt:263-271`):**
  - Wrap `OkHttpDataSource.Factory` in `DefaultDataSource.Factory(ctx, okHttpFactory)` so offline `file://` videos play!
  - Use a dynamic per-request OkHttp interceptor for `MediaHeaders` + `CookieManager` cookies (fixes redirected streams).
  - Set `MimeTypes.APPLICATION_M3U8` when URL path contains `.m3u8` (fixes query-stringed `v.redd.it` HLS).
- [ ] **CRITICAL — Keep Poster Visible Until `onRenderedFirstFrame` (`FeedView.kt:465-488`):** Never unmount poster when `exoPlayer != null`; reveal video layer only once `isFirstFrameRendered == true` (eliminates black flash on every swipe).
- [ ] **CRITICAL — 4.8s Stall Watchdog + No-Referer Retry (`FeedView.kt:286-293` vs `FeedView.swift:510-560`):** Append no-Referer fallback candidate per URL and auto-advance after 4.8s stall or 0×0 video size.
- [ ] **CRITICAL — Broken "Tap to Retry Video" (`FeedView.kt:514-517`):** Add `retryToken` key so tapping retry rebuilds `ExoPlayer` even when `urlIndex == 0`.
- [ ] **CRITICAL — Dead Long-Press 2x / Scrub on Pre-Composed Pages (`FeedView.kt:371-372`):** Include `exoPlayer` in `pointerInput` keys; allow long-press on images for `"Post Details"`; tune thresholds (`220ms` hold, `14dp` scrub, `28dp` lock).
- [ ] **CRITICAL — 4Hz Full-Cell Recomposition Storm (`FeedView.kt:302-328, 766`):** Isolate progress polling inside a dedicated full-width `PlayerScrubberBar` composable with floating timestamp pill (shown in both expanded & collapsed modes).
- [ ] **Video/Image Preloading & `SimpleCache`:** Add ExoPlayer disk `SimpleCache`, pre-buffer next 1–2 videos, prefetch 6 posters, and pre-resolve next 3 LongVideo URLs.
- [ ] **Dwell & Loop Taste Signals (`FeedView.kt:120-132`):** Call `store.recordDwellSignal` on scroll-away and `store.recordLoopSignal` on video loop/end.
- [ ] **End-of-Feed "Rotate More Videos" Page (`FeedView.swift:828-836, 1179-1204`):** Append `FeedStateView` after last item when `!canLoadMore && !isLoading` + auto-`loadMore()` on appear.
- [ ] **Dislike Toast & Live OF Gender Resolution (`FeedView.swift:845-878, 950-1053`):** 3.6s animated top glass toast with `"Hide #<tag>"` quick button, live `OnlyFansAPI.lookupCreator` gender purge, and auto-`loadMore()` when `<10` items remain.
- [ ] **Tall Image Scrolling & Image Fallback/Retry (`FeedView.kt:913-933`):** Scroll images with `height/width > 1.35`, iterate `imageFallbackURLs`, and show retry UI on failure.
- [ ] **Fill Screen Logic (`FeedView.kt:221`):** Only crop/fill portrait videos (`ratio < 0.68`) so landscape videos aren't clipped.
- [ ] **Album `<`/`>` Chevrons & Scaling (`FeedView.kt:446-462`):** Add tappable `<` / `>` chevrons inside `"1 / N"` capsule; respect `effectiveFill` on non-active album slides.
- [ ] **Overlay & Controls Parity:**
  - Remove permanent bottom gradient + author/title clutter (move to Hold Details HUD & More sheet like iOS).
  - Add Long Video site+duration pill (`EPORNER · 12:34`) & `"Full Wide"` / `"Portrait"` rotation button (expanded & collapsed) + auto-collapse in landscape.
  - Sort `DropdownMenu` with dynamic icons (`Hot`, `New`, `Top`).
  - Optimistic Like `+1` count; `"Muted"` vs `"Sound"` label; determinate circular download progress ring; 42dp bottom-left circles; 40dp circular source badges; spring-animated skip indicator (`±5s`/`±10s`) with icons; 104dp glowing spring double-tap heart; shuffle haptic + scroll-to-0.
  - Rich **Collapsed / Zen Mode**: `"^ Controls"` + `"Full Wide"`/`"Portrait"` + 3 quick buttons (Download, Like, Mute) + full-width scrubber + `navigationBarsPadding()`.
  - Rich **Hold Details HUD**: tappable `@author`, colored source name, `relativeTime`, full unwrapped `title`, likes count, duration, `W×H`, `"Offline"` badge (no duplicate speed hint).
  - Rich **`PostMoreSheet` (`ModalBottomSheet`)**: Post title, Offline Download card, Export Downloaded File, Subreddit card + Join/Joined, Author Follow/Following, `"Not Interested · Show Less Like This"`, `"Share Original Post Link"`.

---

## 12. `Screens.swift` vs `Screens.kt`

### Search / Browse (`GoonedBrowseOverlay`, `Screens.kt:36-444` vs `Screens.swift:6-1076`)
- [ ] **Render `BrowseScope` Pill Bar** (`All`, `OnlyFans`, `Reddit`, `Rule34`, `𝕏`, `IG`, `Erome`, `Long Videos`) — declared in Kotlin but never rendered!
- [ ] **180ms Debounce + Parallel `async` API Calls + Loading `ProgressView` + `imeAction = Search` / `submitSearch()`** (`of:`, `r34:`, `#`, `ig:`, `@` prefixes; trigger from 1 char, not `>=2`).
- [ ] **Exact iOS Search Results Layout:**
  - **"Search \"<query>\" Across All Sources"** pink-sparkle hero card.
  - **`ONLYFANS CREATORS`** section: circular avatar, `displayTitle`, `@handle · N videos`, up to 3 `#tags`, inline **`Follow`/`Following`** pill button.
  - Full-width glass cards: **`Rule34: #<query>`** (green `34`), **`r/<subClean>`** (pink arrow), **`Search "<query>" on 𝕏`**, **`Search "<query>" on Erome`**, **`Search "<query>" in Long Videos`** (orange play).
  - **`EROME ALBUMS`** 2-column thumbnail grid (up to 6, 44×58 thumbs).
  - Side-by-side **`𝕏 @handle`** and **`IG @handle`** cards.
  - **`RULE34 TAG SUGGESTIONS`**: post counts `(503072)` + green **`+`** button to chain multi-tag queries as removable green `#tag` pills (`"Space = new tag · _ = combine"`).
  - Matching **`CATEGORIES`**, **`SUBREDDITS`** (with icon + subscriber count), and **`REDDIT USERS`** sections.
- [ ] **Default Browse Parity:** Hide Quick Platforms strip while searching; label `"Share Drop"`; **Continue Watching** handles all **20+** `recent.kind` values (fallback `"Continue: For You"`); `"OF"` gradient fallback avatar on Trending Creators; **All Categories (A–Z)** excludes featured, uses multi-column pill grid, routes `"Rule34"` to `FeedSource.Rule34("")`; pass `onOpenPost` to `ReceiveDropSheet`.

### Likes / Vault (`GoonedLikesView`, `Screens.kt:447-680`)
- [ ] Put `"Liked (N)"` / `"Offline (N)"` pills directly in header; add **`"Play Offline (X MB)"`** button; add glass empty-state button + subtitle.
- [ ] Add **Long-Press Context Menu** (`Share Encrypted Drop`, `Export / Share File`, `Delete Offline Copy` / `Download for Offline`, `Remove from Likes`).
- [ ] Upgrade **Bulk Selection Bar** to 2 rows: `N selected`, `Select All`/`Deselect All`, red `Delete`, **`Save File`**, **`Save to Photos`**, **`Share`**, animated `bulkToast`, and dark dimming overlay + bottom-right checkmark.
- [ ] `GridThumb`: iterate `posterFallbackURLs` on load error + show upvote count next to source badge.

### Following / Profile (`GoonedFollowsView`, `Screens.kt:683-828`)
- [ ] Always show Lock button; when IG connected show 3 quick buttons (`"IG Reels"`, `"IG Following"`, `"IG Saved"`) and hide `"Connect"`.
- [ ] Add missing **`"Reddit Creators"` (`u/`)** dropdown; hide empty dropdowns and show centered `"No follows yet"` empty state.
- [ ] Add **34dp circular avatars/badges**, `@handle` subtitles, leading icons on dropdown headers, and inline **`"Unfollow"` buttons** on every row!

### Settings (`GoonedSettingsModal`, `Screens.kt:976-1167`)
- [ ] Floating 30dp rounded glass modal card over dimmed backdrop; add `"Mix 𝕏 into For You"` & `"Mix IG Reels into For You"` toggles, brand icon circles & subtitles.
- [ ] Add `topTasteSummary`, inline scrollable boosted `#tag` chips with `×`, and `"Reset Taste"` button.
- [ ] Side-by-side pill selectors for SD/HD, Clear/Tinted, Expanded/Collapsed + descriptive subtitles.
- [ ] Add `"Offline Vault Storage"` + `"Clear Vault"`, `"Feed Rotation History"` + `"Reset Seen"`, `"Copy Key"` + `"Refresh"` license + `onAppear` silent verify, and biometric auth check before enabling `faceID`.

### Algorithm Editor, Wipe Data & Creator Grid (`Screens.kt:831-961, 1178-1362`)
- [ ] **`AlgorithmEditorSheet`**: Add **Smart Archetype Guardrails** (5 chips: `Hide Gay (M/M)`, `Hide Yaoi / Bara`, `Boost Femboy`, `Boost Trans Women`, `Boost Futanari`), **debounced Rule34 autocomplete** + live `#tag` pills, **Learned Taste Signals** (`+score`, `−`/`+`/`×` + learned `r/sub` chips), and **`hiddenOFGenders` unhide chips**.
- [ ] **`WipeDataSheet`**: Add explanatory footer + trash icon; remove unused `tasteState`.
- [ ] **`CreatorProfileGridView`**: Show `model.items.count`, fix double-bordered Rule34 filter + keyboard search submit, add `"Loading <title>..."` / `"No posts found for <title>"`, and add **bottom pagination spinner + `"Load More"` button**.

---

## 13. `FeedModel.swift` vs `FeedModel.kt`

- [ ] **CRITICAL CONCURRENCY BUG (`FeedModel.kt:224-245, 252-253`):** `switchSource` & `setSort` cancel `activeJob` and immediately call `refresh()` WITHOUT resetting `isLoading.value = false` → new `loadMore()` sees `isLoading == true` and silently aborts, leaving feed **permanently blank**!
- [ ] **CRITICAL COROUTINE BUG (`FeedModel.kt:384-387`):** `catch (e: Throwable)` swallows `CancellationException` and writes `"StandaloneCoroutine was cancelled"` to `errorText`! Must rethrow `CancellationException` and check `ensureActive()`.
- [ ] **`swipeKey` & `displayTitle` Parity (`FeedModel.kt:67-123`):** Fix `ofCreator` (`"$id|$handle"`), `longVideos` (`"longvideos"`), strip all `@`, match `OF @handle` / `"Long Videos"` titles.
- [ ] **Add `isSwitching`, `emptyPageStreak`, `lastAppearedIndex`, `followingRoundRobin`, `followingCursors`, `prefetchIfNeeded`, `refreshTailForUpdatedTaste`, `purgeSuppressedItems`.**
- [ ] **Fix `seenSimKeys` (`FeedModel.kt:166-184, 235-237`):** Populate on init, disk cache load, `switchSource`, and `removeDisliked`.
- [ ] **Fix Pre-Dedup Filtering (`FeedModel.kt:342`):** Filter `hasPlayableMedia`, `!isDisliked`, `!(isDiscoverySource && isBlockedByAlgorithm)`, and `AdultContentClassifier.isEligible` on ALL feeds.
- [ ] **Infinite Rotation & Fallbacks (`FeedModel.swift:525-633`):** Rotate cursors infinitely for `ForYou`, `Rule34`, `LongVideos`; add X search fallback & IG reels fallback when `emptyPageStreak >= 2`; auto-prefetch continuation after 280ms; increase prefetch threshold from 10 to **20** items.
- [ ] **Multi-Source `Following` Feed (`FeedModel.kt:395-398` vs `FeedModel.swift:685-742`):** Round-robin across **Reddit + 𝕏 (`x_following` + `followedXUsers`) + Instagram (`ig_following` + `followedIGUsers`) + OnlyFans (`followedOFCreators`)** with per-pool cursors!
- [ ] **`ForYou` Deficit Round-Robin + `redditTasteTask` + Strict Source Toggles (`FeedModel.kt:449-481`):**
  - Strictly respect `sourceSettings` (disabling Rule34 immediately purges & stops fetching Rule34; also fix `scope` leak & collector attachment).
  - Add parallel `redditTasteTask`, pass `seedCreatorIds` + `tasteTags` to OF, filter & score each bucket, and interleave with weighted **Deficit Round-Robin** (cap 36).
- [ ] **`MultiSearch` Parity (`FeedModel.kt:425-446`):** Add 3.5s per-source timeouts, include **Reddit** search (remove duplicate Erome), platform-specific page cursors, relevance scoring (`+12` exact, `+4.5`/token, `-9999` blocked), and `[x, of, r34, reddit, long]` interleave.
- [ ] **`Category`, `XSearch`, `OFForYou`, `OFCreator` Params:** Pass `excludedHead` + random subreddit fallback on `Category`; pass `sort` on `XSearch`; pass `seedCreatorIds`/`tasteTags`/`displayName`/`sort` on OF.
- [ ] **Atomic Disk Cache & Missing Error Messages:** Write cache atomically (`.tmp` + rename); add X rate-limit, Following empty, and Offline-with-downloads messages; fix `FeedSort` order (`HOT, NEW, TOP`) + `icon`.

---

## 14. `SmartTasteEngine.swift` vs `SmartTasteEngine.kt`

- [ ] **CRITICAL — Schema & Sign Inversion (`SmartTasteEngine.kt:16-51, 249, 287`):**
  - Fix `SourcePlatform` rawValues: `"reddit"`, `"x"`, `"onlyfans"`, `"instagram"`, `"rule34"`, `"long"`.
  - Fix `ForYouSourceSettings` JSON keys: `includeReddit`, `includeX`, `includeOnlyFans`, `includeInstagram` (default `false`), plus `includeRule34`, `includeLongVideos`.
  - Fix `TasteV2Data` JSON key: `sourceSettings` (not `forYouSources`), add `sourceWeights`, `creatorLatentClusters`, `creatorWatchStats`, `positiveVisualPrints`, `negativeVisualPrints`.
  - **Fix `tagPenalties` sign inversion:** store negative values (`-2.0`, `-16.0`, `-45.0`) and **add** them like iOS!
- [ ] **CRITICAL — `MutableStateFlow` In-Place Mutation Bug (`SmartTasteEngine.kt:161-277`):** Always create fresh immutable copies of nested lists/maps before assigning `state.value = ...` so `StateFlow` never suppresses emissions!
- [ ] **Fix `suppressedCreators` & Dislike Rules (`SmartTasteEngine.kt:228-279`):**
  - Actually populate `suppressedCreators` (excluding generic authors) and set `creatorWatchStats = -30.0`.
  - Port **Archetype Guardrails**: `protectedBroadTags` (42 tags), `immediateArchetypeTags` (11 tags, 1-dislike suppress), `mascMaleOnlyTags` (9), `femboyOrTransRescueTags` (17), `isUserLikedOrPinnedTag` protection, `applyGenderSuppressionRules`, `applyCreatorDislikeResolution`, femboy/trans rescue in `isSuppressedInDiscovery`.
  - Fix `unblockTag` to clear `tagDislikeCounts` & `tagPenalties`; fix `blockDislikedTag` to reject stop tags and set `-45.0`; cap `dislikedIDs` at 4000; apply `0.93` platform weight decay on dislike.
- [ ] **Port SimClusters, Session Co-Visitation & Extended Tag Extraction:**
  - `creatorClusterKey` (`of:`, `creator:`, `sub:`), `ingestPostIntoCreatorGraph` (16 tags/creator, 800 cap), `sessionContextTags` (0.88 decay), tagless co-visitation transfer, `creatorWatchStats` (`+1.4*intensity` / `-1.1` skip / `-30.0` dislike).
  - 18-niche `extraOrientationAndNicheRules` (120+ keywords) + `PornTagCatalog.extractRecognizedTags` + `extractExtendedTags` (creator-cluster inheritance).
  - Full `scoreAdjustment` formula (disliked `-1000`, `tagPenalties`, `-40`/suppressed tag, `watchScore * 1.35`, `clusterMatch` `[-30, 24]`, `-35` suppressed creator, `(sourceWeight - 1.0) * 3.5`).
  - Fix `activeQueryTags` (`pinned` -> `tagWeights > 0.35` -> `sessionContextTags > 0.25`, space→`_`), `topOnlyFansSeedHandles`, `sanitizeStopTagsFromState()`, and `hiddenOFGenders` `SharedPreferences` mirror.

---

## 15. `UserStore.swift` vs `UserStore.kt`

- [ ] **CRITICAL — Fix `RecentFeedEntry.updatedAt` Epoch (`UserStore.kt:25-36, 72-73`):** Encode/decode Apple Reference Date (seconds since Jan 1, 2001 = `unixSeconds - 978307200.0`) so iOS & Android timestamps match.
- [ ] **CRITICAL — Port Full `PornTagCatalog` (`UserStore.swift:880-1100` vs `UserStore.kt:528-535`):** Port all **105 `canonicalTags`**, **250+ `aliases`**, **20 `relatedTags` clusters**, `normalize`, `extractRecognizedTags(from:)`, `extractRecognizedTags(fromQuery:)`, and `displayTitle(for:)`.
- [ ] **CRITICAL — Port Full `AdultContentClassifier` (`UserStore.swift:1104-1241` vs `UserStore.kt:464-526`):**
  - Make `hasExplicitAdultIndicators` check `PornTagCatalog.extractRecognizedTags` (not just `explicitAdultMarkers`).
  - Port `isEligibleIGReel` (with all 27 `sfwIGNoise` terms) and unified `isEligible(post, source, categories, store)` (verifying Reddit posts are genuinely adult + checking `hasPlayableMedia` & `sfwBlockedTerms` across all sources).
- [ ] **CRITICAL — Fix `rankWithAlgorithm` & Signal Pipeline (`UserStore.swift:545-875` vs `UserStore.kt:348-395`):**
  - Port `recordAlgorithmSignal(for, weight)` (every-35-signals `0.92` decay, `subredditWeights`/`creatorWeights`/`tagWeights` `[-12, 45]`, contrastive protection, `videoPreference` EMA `[0.1, 0.95]`).
  - Port `recordLoopSignal` (`+3.8`), `recordSearchSignal` (`+4.5`), `applyCreatorDislikeResolution`, `scorePost`, `isBlockedByAlgorithm`, `adjustLearnedTag`, `addBoostedTags`/`removeBoostedTag`, `removeLearnedSubreddit`/`removeLearnedTag`, `addBlockedTags`/`removeBlockedTag`, `topAlgorithmSubreddits`, `topAlgorithmTags`, `topAlgorithmSubredditEntries`, `topTasteSummary`, `resetAlgorithm`, `eraseAll`, `clearSeenHistory`, `sanitizeLearnedProfile`.
  - Fix `rankWithAlgorithm` to read `creatorWeights`/`subredditWeights` (not dead `preferredAuthors`/`preferredSubreddits`), apply `+48.0` boosted tags, following bonus (`+3.5`/`+4.0`), related-tag synergy, `videoPreference`, `log10(upvotes)`, `[-0.65, 0.65]` jitter, and **75/25 Exploit-Explore** interleaving.
  - Gate `recordDwellSignal` on `algorithmEnabled`; send `-2.5`/`+5.0` on `toggleLike`, `+6.5` on `recordDownload`, `-8.0` on `dislike`.
- [ ] **Follows & Wipe Parity:** Insert follows at index `0`, trim/strip all `@`/reject empty, add `toggleFollowAndSync`, `disconnectX`, `disconnectIG`; cap `recentFeeds` at 8; reset `settings` & `seenIDs` properly in `performSelectiveWipe` + clear Coil/ExoPlayer/OkHttp caches; debounce saves at 500ms.

---

## 16. `XService.swift` vs `XService.kt`

- [ ] **CRITICAL — Fix `XAccountSession` `@JsonNames` Crash (`XService.kt:38-50`):** Remove `@JsonNames("screenName")` collision on `username`; keep exact iOS fields (`authToken`, `ct0`, `userId`, `screenName`, `mixIntoForYou: Boolean = true`).
- [ ] **CRITICAL — Implement GraphQL Capture & `fetchGraphQLDirect` Cursor Replay (`XService.swift:606-717, 1185-1246`):** Capture live `/graphql` op URLs + headers (`HomeTimeline`, `HomeLatestTimeline`, `SearchTimeline`, `UserMedia`, `Bookmarks`) in JS hook and replay directly with `cursor = after` & `count = 40` + `directDisabledOps` circuit breaker.
- [ ] **CRITICAL — Fix `XTweetParser.walk` & Strict Porn/Zero-Ad Filtering (`XService.kt:55-211` vs `XService.swift:22-404`):**
  - Remove `depth > 18` cap and premature `return` at `XService.kt:121` (skip rejected tweet, keep walking subtree).
  - Add `routeKey`, `inheritedBio`, `inheritedFollowed`, `parseScreenName`.
  - Reject `promotedMetadata`, `promoted_metadata`, `adMetadata`, `entryId` containing `promoted`/`who-to-follow`/` module`, and `clientEventInfo` ads.
  - On `x_following`: skip retweets/quote-tweets and reject `isFollowed == false`.
  - Support `media_entities2`, `dict.extended_entities`, `note_tweet`, `details`, `created_at_ms`, `is_nsfw`, `ext_sensitive_media_warning`, `nudity`, `core.description`/`result.description`/REST `user.description`.
  - Fix bitrate selection: pick **highest** bitrate MP4 for `mediaUrl`/`muxedUrlHd` and fast-start (`<=2.5Mbps`) for `muxedUrl` (not lowest!), register `allVariantURLs` + `bioTags` + `fingerprint` + `followedByViewer`, `subreddit = null`, `mediaType = "gif"` for `animated_gif`.
  - Recursive JSON walker for `Bottom` / `bottom_cursor` (replace 120-char regex).
- [ ] **CRITICAL — Upgrade `XWebEngine` (`XService.kt:214-390` vs `XService.swift:412-1305`):**
  - Dual WebView lanes (`XWebEngine.home` + `XWebEngine.shared`) + FIFO `Mutex` lock + continuation `waiters` (replace 6s polling) + `onRenderProcessGone` crash recovery.
  - Fix permanent rate-limit lockout: 45s `rateLimitedUntil` cooldown + detect `"code": 88` + drop `status >= 400`.
  - Inject hook early, mute/pause `HTMLMediaElement.prototype.play`, block `image|font|media` in headless WebView, add `adaptive.json`/`settings.json`/SSR `<script>` scan.
  - Add route isolation, `seenIdsByRoute`, `isSeen`/`isBlockedByAlgorithm`/`followedXUsers`, dry-payload `nextAdultSupplementURL`, `scheduleBackgroundPump`, multi-container `scrollAdvanceJS`, 24×180ms `selectHomeTabJS`, `softNavigate`, `followUser`, `resolveCt0IfNeeded`, `injectStoredCookies`, and clear X cookies in `resetSession`.
- [ ] **`XAPI` Parity (`XService.kt:394-417`):** Blend `boostedTags`/`topAlgorithmTags` in parallel in `forYou`; use `HomeLatestTimeline` direct in `following`; fix `likes` to use `screenName` + `/i/history/likes`; add `sort`, `filter:videos`, `&src=typed_query`, and broad fallback to `search`; lowercase `userMedia` routeKey.
- [ ] **Fix `XLoginSheet` Flickering & Missing Features (`XService.kt:420-527`):**
  - Load `https://x.com/i/flow/login`, stabilize WebView composition/focus so email/password inputs never flicker or collapse, support OAuth popups (`setSupportMultipleWindows(true)` + `onCreateWindow`), add **Manual Cookie Entry** (`auth_token`, auto-`ct0`, `@username`) + `"Done"` button, extract `twid` (`userId`), check both `.x.com` & `.twitter.com`, and call `warmUp()`.

---

## 17. `InstagramService.swift` vs `InstagramService.kt`

- [ ] **CRITICAL — Fix `InstagramAccountSession` Schema (`InstagramService.kt:36-44`):** Add `var mixIntoForYou: Boolean = false` and fix `isConnected = sessionId.isNotEmpty()`.
- [ ] **CRITICAL — Ad, Following & Adult Filtering (`InstagramService.kt:47-112`):**
  - Remove `depth > 16` cap; add `routeKey`, `inheritedAuthor`, `inheritedFollowed`.
  - Reject `ad_id`, `ad_action`, `injected`, `is_paid_partnership`; on `ig_following` reject `explore_item_info`, `suggested_users`, `bloks_netego`, `clips_netego`, `EndOfFeedDemarcator`, `inventory_source` (`recommend|explore|suggest|unconnected|isf_|chaining`), and `isFollowed == false`.
  - Strip `_ownerId` from `pk`/`id`, support GraphQL `video_url`/`dimensions`/`edge_media_to_caption`/`edge_media_preview_like`/`owner`/`display_url`/`thumbnail_src`, set SD/HD tiers from `video_versions`, register `MediaMetaRegistry`, and enforce `AdultContentClassifier.isEligibleIGReel`.
- [ ] **Upgrade `InstagramWebEngine` & `InstagramAPI` (`InstagramService.kt:135-392`):**
  - Add route isolation, `max_id`/`end_cursor` extraction, FIFO lock, continuation waiters, `scheduleBackgroundPump`, `scrollAdvanceJS` (`ArrowDown` + `WheelEvent` + scrollable containers), `apiTriggerJS` (`POST /api/v1/clips/home/`, `POST /api/v1/feed/timeline/?variant=following`, `GET /api/v1/feed/saved/posts/`, `web_profile_info`), `followUser`, `injectStoredCookies`, media/image blocking, `onRenderProcessGone`, and clear IG cookies in `resetSession`.
  - Fix `followingFeed` URL (`https://www.instagram.com/?variant=following`, currently loads algorithmic home!).
- [ ] **Fix IG Direct Inbox & Video DM Sending (`InstagramService.kt:277-373`):** Properly URL-encode `thread_ids=["$threadId"]`, add `upload_media_width/height = 720`, `X-ASBD-ID: 129477`, `X-Requested-With`, `Origin`, `Referer`, validate `status == "ok"`, and add Desktop WebView inbox/DOM composer fallback.
- [ ] **Upgrade `InstagramLoginSheet` (`InstagramService.kt:397-510`):** Add Manual Cookie Entry (`sessionid`, `csrftoken`, `@username`), `"Done"` button, require `sessionid` only, stabilize WebView focus, call `warmUp()`.

---

## 18. `OnlyFansService.swift` vs `OnlyFansService.kt`

- [ ] **CRITICAL — Fix Pagination Parameter (`OnlyFansService.kt:259-330`):** Change `"offset"` → `"o"` and add `"type" to "videos"` on EVERY `cum.st` endpoint!
- [ ] **CRITICAL — Fix Endpoints & Sort Parameters:**
  - `fetchTrending`: `/posts/popular` (`period=week`→`month`→`daysAgo`→recent, `n=50`), not `/posts?sort=trending`.
  - `fetchLatest`: `sort=recent`, `n=40`, not `sort=newest`.
  - `fetchDMs`: `/dms/popular` (`week`→`month`) then `/dms?sort=recent`.
  - `fetchCreatorPosts`: `/onlyfans/user/$id/posts` with `sort=popular|recent`, staged `posts` → `/dms` → `/similar` → `trending` (currently hits wrong `/creators/onlyfans/$id/posts`!).
  - `fetchTopCreators`: 2 pages (`o=0,50`, `n=50`) with `sort=bookmarked&content=imported`, 300s TTL, local `hiddenGenders` filter.
- [ ] **CRITICAL — Fix Video Variant Matching (`OnlyFansService.kt:177-212`):** Match `"original.mp4"`, `"1080"`, `"720p.mp4"`, `"240p.mp4"` (currently checks `"720p"` without `.mp4` and never matches!).
- [ ] **Port Missing OF Features:**
  - `lookupCreator(id/handle)` + `creatorSearchCache` + `MediaMetaRegistry.registerCreatorGender`.
  - `forYou` 4-bucket blend: `tasteTags` (`/posts?q=` + `creator_tag=`), Similar-Creators Graph (`/onlyfans/user/{seedId}/similar`), `trending`, `latest` with base64 JSON cursor `{"page": N}`.
  - Register `post.tags + post.creatorTags + cachedCreator.creatorTags` + `creatorId`; filter `videosOnly = true`; apply local `hiddenGenders` filter with **femboy/trans rescue**; don't drop rows when `creatorId == null`.
  - `searchCreators`: strip `of:`/`@`, cache, local top-100 filter for 1–2 char queries, `sort=bookmarked`, sort by `videoCount` desc.
  - `searchPosts`: `q.length >= 3` guard, `sort=relevance`, blend top 3 matching creators when `<8` results.

---

## 19. `Rule34Service.swift` vs `Rule34Service.kt`

- [ ] **CRITICAL — Built-In Default Credentials (`Rule34Service.swift:50-154` vs `Rule34Service.kt:35-42`):** Port built-in XOR-obfuscated default `userId`/`apiKey` + `hasCustomCredentials`/`effectiveUserId`/`effectiveApiKey`/`setCustom`/`resetToDefault` so `api.rule34.xxx` works out of the box!
- [ ] **Fix Tier 2 Zero-Auth Boorus (`Rule34Service.kt:185-221`):** Parallel fetch `yande.re` (`r34y`), `hypnohub.net` (`r34h`), `realbooru.com` (`r34b`); remove unintended Reddit fallback; stop hardcoding `yande.re` IDs/permalinks on non-yande.re posts.
- [ ] **Fix Parsers (`Rule34Service.kt:242-340`):**
  - Reject `rating` in `s|safe|general`.
  - Normalize `//` and `http://` → `https://`.
  - Strip `?query` before extension checks.
  - Use `fileUrl` (not static `sampleUrl`) for animated `.gif`; fix `parseYandereJSON` setting image `sampleUrl` as `mediaUrl` on `.mp4`s; add `jpeg_url` fallback; add `Rule34KeySheet` default-status card, `"Use Default"` button, and password-masked API key field.

---

## 20. `LongVideoService.swift` vs `LongVideoService.kt`

- [ ] **CRITICAL — Wire `tasteQuery` on ALL 6 Sites (`LongVideoService.kt:71-99`):** Currently only Erome uses `tasteQuery`! Also pre-resolve first 3 posts in background.
- [ ] **CRITICAL — Fix `\/` → `/` Unescaping on xHamster, SpankBang & Eporner Resolvers (`LongVideoService.kt:559, 601-609`):** Unescape `\/` → `/` **before** running video URL regexes (fixes broken playback!).
- [ ] **SpankBang Cloudflare 403 Fallback (`LongVideoService.swift:737-782`):** Seamlessly fall back to interleaved XVideos + Eporner rebadged as SpankBang with resolver routing; fix sort (`most_popular`/`new_videos`/`trending_videos`), `+` encoding, `[a-z0-9\-_]+/video/` regex, and match both `sb-cd.com` & `spankbang.com`.
- [ ] **Pornhub Parity (`LongVideoService.kt:191-258`):** Stop replacing empty query with `"amateur"`; support `sort=top` (`rating`), `period=daily|weekly`, `thumbsize=large_hd`, parse `duration`/`views`/register `tags`+`categories`, prefer `default_thumb ?? thumb`.
- [ ] **Eporner Parity (`LongVideoService.kt:104-133, 522-560`):** Support `sort=top` (`top-rated`), stop forcing `gay=0` on explicit `"gay"` searches, remove `lq=1`, filter `lengthSec >= 90 || query.isNotEmpty()`, register `keywords`, parse `views` & dimensions, add JSON-LD `"contentUrl"` fallback.
- [ ] **xHamster Parity (`LongVideoService.kt:274-308`):** Parse full `window.initials` JSON recursively (`id`, `duration`, `views`, `thumbURL ?? landing.logo`) instead of fragile 600-char regex.
- [ ] **XVideos & Erome Parity (`LongVideoService.kt:147-184, 376-464`):** Support `sort` & duration parsing on XVideos search + register `video_tags`; support `&o=new`, `?page=`, multi-word fallback, and `posterURL` on Erome photo `AlbumMediaItem`s.

---

## 21. Phased Implementation Roadmap (Awaiting Your Greenlight)

Once you give the **greenlight**, I will execute all **185+ items** in **5 verified build phases**, compiling locally with Gradle 8.9 after each phase:

1. **Phase 1 — Foundation, Sync, Security & Manifest:** `AndroidManifest.xml` (cleartext config, app icon, `configChanges`), `proguard-rules.pro`, `CryptoBox.kt` (cached prefs + `>=`), `Models.kt` (`Lossy`, `thumbURL`, `iconUrl`, `MediaHeaders`, `MediaMetaRegistry`, `Gif` equality/relativeTime), `LicenseManager.kt` (cookie domain/expiry, sync triggers, merge safety, `clearLicense`, `NaN`/lifetime fixes, `LicenseGateView`), `ShareService.kt` (`ShareDropPayload` iOS wire parity, no infinite spinner, file/IG DM sheets), `OfflineManager.kt` (LongVideo URLs, cookies, `Content-Type`, `_thumb.jpg`, progress map, stop `file://` pollution), `Security.kt` (`PasscodeSetupView` `.change`, `LockView` resume biometrics, 4-page swipeable onboarding, AgeGate).
2. **Phase 2 — Video Playback & FeedView Overhaul:** `TinyTinyApplication.kt` (OkHttp disk cache + ExoPlayer `SimpleCache`), `FeedView.kt` (`TextureView`, decoupled `DisposableEffect`, `DefaultDataSource` + per-request headers + HLS MIME, poster until `onRenderedFirstFrame`, 4.8s stall watchdog + no-Referer retry, `retryToken`, preloading, dwell/loop signals, fixed gestures/hold HUD/scrubber/collapsed mode/landscape Full Wide/dislike toast/album chevrons/PostMoreSheet/end-of-feed card).
3. **Phase 3 — All 5 Social & Media Services:** `XService.kt` (fix `@JsonNames` crash, GraphQL capture/replay, dual lanes, FIFO lock, 45s rate-limit, fixed `XTweetParser` + strict porn/no-ad filter, background pump, stable `XLoginSheet` + OAuth + manual cookies), `InstagramService.kt` (`mixIntoForYou`, ad/following/adult filters, `apiTriggerJS`, fixed DM send, manual cookies), `OnlyFansService.kt` (`o` param, `type=videos`, endpoints/sorts, `.mp4` variants, 4-bucket `forYou`, femboy/trans rescue, `lookupCreator`), `Rule34Service.kt` (default creds, hypnohub/realbooru, rating filter, GIF/MP4 fixes), `LongVideoService.kt` (`tasteQuery` all 6 sites, `\/` unescape, SpankBang CF fallback, Pornhub/Eporner/xHamster/XVideos/Erome parity).
4. **Phase 4 — Algorithm, `UserStore`, `SmartTasteEngine` & `FeedModel`:** Full `PornTagCatalog` (105 tags / 250+ aliases / 20 clusters), full `AdultContentClassifier`, `RecentFeedEntry` Apple epoch, `SmartTasteEngine` schema/sign parity + immutable `StateFlow` + SimClusters + Archetype Guardrails, `UserStore` full signal/decay/75-25 Exploit-Explore ranking, `FeedModel` concurrency/cancellation fixes + multi-source `Following` + DRR `ForYou` + `MultiSearch` timeouts/Reddit.
5. **Phase 5 — UI Carbon Copy (`MainActivity.kt`, `Screens.kt`, `Theme.kt`) & Release Build:** Exact iOS Search screen (scope pills, debounced parallel search, All Sources hero, OF creators w/ Follow, Erome 2-col grid, R34 `+` tag composer, Categories/Subreddits/Users), Likes/Vault, Following (avatars + Unfollow + Reddit Creators + IG quick pills), Settings, AlgorithmEditor (Guardrails + Learned Signals), CreatorGrid pagination, `MainActivity` (7 persistent LongVideo models, sub-channel memory, auto-centering rail + fade mask, orientation lock, live taste observers, dock swipe-down), `Theme.kt` (`BrandLogo*` active/connected styling), full `gradle assembleRelease --no-daemon`, copy to `APK VERSION/TinyTiny.apk`, and push.
