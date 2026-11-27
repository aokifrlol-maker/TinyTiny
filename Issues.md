# TinyTiny — Exhaustive Full-Stack Codebase Audit (`Issues.md`)

**Audit Date:** 2026-11-27  
**Repository Baseline:** `HEAD` (`f7bb9f1`, `v1.7.0`)  
**Scope:** 100% line-by-line review of every source, config, backend, and CI/CD file (~38,000+ lines):
- **iOS (`TinyTiny/`):** 20 Swift files (`TinyTinyApp.swift`, `FeedView.swift`, `Screens.swift`, `Theme.swift`, `OfflineManager.swift`, `Models.swift`, `UserStore.swift`, `FeedModel.swift`, `SmartTasteEngine.swift`, `CryptoBox.swift`, `Security.swift`, `LicenseManager.swift`, `ShareService.swift`, `API.swift`, `XService.swift`, `InstagramService.swift`, `RedditService.swift`, `OnlyFansService.swift`, `Rule34Service.swift`, `LongVideoService.swift`)
- **Android (`APK VERSION/`):** 21 Kotlin files + `AndroidManifest.xml`, `app/build.gradle.kts`, `proguard-rules.pro`, `network_security_config.xml`
- **Backend & Telegram Bot:** `backend/license-worker.js` (3,005 lines), `backend/wrangler.toml`
- **CI/CD & Build:** `.github/workflows/build.yml`, `.github/workflows/build-apk.yml`, `project.yml`

---

## Executive Summary

| Subsystem | Critical | High | Medium | Low | Total |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Cross-System / Architectural** *(synthesized across repos)* | 7 | 4 | 2 | — | **13** |
| **iOS — UI, Playback, Gestures & Offline** | 6 | 11 | 14 | 5 | **36** |
| **iOS — Core, Algo, Security, Sync & Share** | 3 | 13 | 13 | 12 | **41** |
| **iOS — API & Social Services** | 7 | 16 | 10 | 1 | **34** |
| **Android — UI, Playback, Offline & Config** | 4 | 19 | 17 | 5 | **45** |
| **Android — Core, Algo, Security, Sync & Share** | 7 | 11 | 12 | 7 | **37** |
| **Android — API & Social Services** | 1 | 8 | 5 | 3 | **17** |
| **Backend Worker, Telegram Bot & CI/CD** | 5 | 8 | 7 | 4 | **24** |
| **Grand Total (Unique & Cross-Correlated Issues)** | **33+** | **86+** | **78+** | **37+** | **~234** |

### Top 10 "Drop Everything" Showstoppers
1. **Unauthenticated Backend DoS & Admin Abuse (`backend/license-worker.js:2294, 2764`):** `POST /v1/admin/deliver-builds` has **zero authentication**, and `/v1/report-error` lets ~500 unauthenticated requests exhaust Cloudflare KV's 1,000 writes/day free-tier limit, bricking licensing, backups, shares, and Watchit globally.
2. **Complete Passcode Lock Bypasses on iOS & Android (`Security.swift:1079`, `LicenseManager.swift:386`, `MainActivity.kt:164, 208`, `TinyTinyApp.swift:140`):** iOS "Forgot Passcode?" accepts *any* valid license key to unlock a victim's vault; deep links (`tinytiny://`) render `IGDirectSendSheet` directly on top of `LockView` on both platforms; and 4-digit PIN lockouts reset on app restart/rotation.
3. **Silent Local Vault Wipe via Keychain / `EncryptedSharedPreferences` Races (`CryptoBox.swift:18-51`, `CryptoBox.kt:37-97`):** Transient Keychain/Keystore errors trigger generation of a brand-new 256-bit key (overwriting the old key on iOS or falling back to plaintext prefs on Android), causing `UserStore`/`SmartTasteEngine` to fail decryption and overwrite `gooned_userdata.json` with empty data.
4. **iOS ↔ Android Cloud Sync Mutual Destruction (`SmartTasteEngine.swift:881`, `SmartTasteEngine.kt:794`):** Both platforms blindly overwrite `state = imported` on cloud restore. Because iOS and Android store different visual-taste/source fields, syncing iOS wipes Android's visual vectors & Rule34/LongVideo toggles, and syncing Android wipes iOS's Vision neural prints.
5. **Broken iOS Bottom Video Scrubber & Android Bulk Gallery Save (`FeedView.swift:1298, 2542`, `OfflineManager.kt:96`, `Screens.kt:1045`):** Touching the iOS bottom scrubber unmounts `PlayerScrubberBar` mid-drag; Android's bulk "Save to Photos" runs synchronous OkHttp on `Dispatchers.Main` (`NetworkOnMainThreadException` silently swallowed -> `"Saved 0 to Gallery"`).
6. **Stale/Broken Build & Telegram Delivery Pipeline (`license-worker.js:208, 572, 2800`, `build-apk.yml`, `build.yml`, `project.yml`, `app/build.gradle.kts:24-32`):** Android release APKs are signed with the **debug keystore** with minification off; `build-apk.yml` never publishes to GitHub Releases so `/builds` sends a stale git APK; `project.yml` hardcodes version `1.0`/`1` (breaking `/minversion`); Worker `wrangler.toml` is missing `DIRECT_R2` (next deploy breaks `/d/*`).
7. **"Zero-Knowledge" Cloud Backup Illusion (`LicenseManager.swift:394`, `LicenseManager.kt:389`):** Backup AES-256-GCM keys are derived via fast HKDF from `licenseKey`, which is sent in plaintext to the Worker in the same request — exposing X/IG/Reddit session cookies, Rule34 keys, and Seedr master keys to anyone with KV access or an unbound multi-device key slot (`license-worker.js:139-160`).
8. **iOS & Android OOM Crashes on File Drops, Bulk Exports, & IG DM Video Sends (`ShareService.swift:75`, `ShareService.kt:89`, `InstagramService.kt:590`, `Screens.swift:1565`, `license-worker.js:2499`):** Full 90MB–150MB videos are buffered into RAM (up to 270MB–500MB heap spikes) instead of streaming to/from disk or R2.
9. **WebView Memory Leaks, JS Injection, & Broken Pagination in X / Instagram / Reddit (`XService.swift`, `InstagramService.swift`, `RedditService.swift`, `XService.kt`, `InstagramService.kt`):** Duplicate hidden `WKWebView`s on iOS, unleaked `AndroidView` WebViews on Android, unescaped JS string interpolation in authenticated `x.com`/`instagram.com` origins, `seen.add(gid) && seen.add(dedupeKey)` dropping valid posts on Android, and `RedditPersonalAPI.verifyUsername` hitting Fastly 403 WAF on iOS.
10. **Android App-Wide Recomposition Storm & Double-Caching (`MainActivity.kt:157`, `FeedView.kt:103, 429`, `TinyTinyApplication.kt:25-55`):** Collecting monolithic `UserStore.data` in `RootView` + `GoonedMainShell` + `FeedView` + 3 `GoonedReelCell`s recomposes the entire app tree on every swipe/loop/download tick; ExoPlayer stacks 250MB `SimpleCache` on top of 150MB OkHttp `Cache` and steals audio focus even when muted.

---

## Section 1: Cross-System & Architectural Failures

These bugs only become visible when tracing data flows across **iOS ↔ Android ↔ Cloudflare Worker ↔ Telegram Bot ↔ CI/CD**.

### XS-1. [CRITICAL] iOS ↔ Android Cloud Backup Mutual Wipe of Visual Taste & Source Toggles
- **Files:** `TinyTiny/LicenseManager.swift:639`, `TinyTiny/SmartTasteEngine.swift:29-58, 881-886` ↔ `APK VERSION/.../LicenseManager.kt:618`, `APK VERSION/.../SmartTasteEngine.kt:35-42, 75-76, 794-799`
- **Interaction:** Both clients call `SmartTasteEngine.shared.applyImportedBackup(backup.tasteV2)` which blindly executes `state = imported`.
  - iOS `TasteV2Data` contains `positiveVisualPrints`/`negativeVisualPrints` (Apple Vision), which Android does not model (or preserves only if `lastRemoteBackupJson` wasn't cleared).
  - Android `TasteV2Data` contains `androidPosVisualVectors`, `androidNegVisualVectors`, `includeRule34`, and `includeLongVideos`, which iOS does not model.
  - Worse, `syncBidirectionalBackup()` restores *before* uploading, so unsynced local dislikes/suppressions are wiped on both platforms.
- **Fix:** Replace `applyImportedBackup` with a true field-level `mergeImportedBackup` on both platforms (unioning dislike/suppression sets, merging numeric counters/weights by max magnitude, preserving platform-specific visual vectors/prints when absent in remote JSON, and hydrating `VisualTasteAnalyzer` on iOS).

### XS-2. [CRITICAL] Cross-Platform Tombstone & Last-Item Deletion Resurrection + Selective Wipe Reversal
- **Files:** `TinyTiny/UserStore.swift:136, 233-319, 570-576`, `TinyTiny/LicenseManager.swift:512-615, 723-738` ↔ `APK VERSION/.../UserStore.kt:123, 441-462, 818-860`, `APK VERSION/.../LicenseManager.kt:508-678`
- **Interaction:**
  1. `localAddedTimestamps` is in-memory only on **both** platforms; restarting before sync lets an older remote tombstone delete a newer re-like/re-follow.
  2. Deleting the **last** liked/followed item makes `hasAnyData`/`hasData` evaluate to `false`, so `syncBidirectionalBackup()` skips uploading the tombstone — the item resurrects on the next sync.
  3. `isTrulyEmpty` and `hasAnyData` omit `redditSession.isConnected` (and `r34Credentials` on Android), wiping or failing to sync Reddit-only accounts.
  4. `toggleFollowOFCreator` on **both** platforms writes the wrong tombstone key when matching by handle instead of ID (`"of:\(cleanId)"` vs `"of:\(removed.id)"`), resurrecting unfollowed OF creators.
  5. `performSelectiveWipe()` on **both** platforms wipes slices without recording tombstones or stopping the 18-second `liveSync` loop — wiped likes/follows resurrect from Cloudflare KV within 18 seconds.
- **Fix:** Persist `addedLikedIDs`/`addedDownloadedIDs`/`addedFollows` timestamps inside `UserData` (true LWW); include tombstone non-emptiness and `redditSession`/`r34Credentials` in `hasAnyData`/`isTrulyEmpty`; use `removed.id` for OF tombstones; record tombstones during `performSelectiveWipe()`.

### XS-3. [CRITICAL] "Zero-Knowledge" Cloud Backup Key Is Server-Known + Unbound Device Slot Read/Write
- **Files:** `TinyTiny/LicenseManager.swift:394-404, 430-434` ↔ `APK VERSION/.../LicenseManager.kt:389-404, 436-441` ↔ `backend/license-worker.js:139-160, 2330-2368`
- **Interaction:** Both apps derive the AES-256-GCM backup key via `HKDF-SHA256(licenseKey)` and send `licenseKey` in plaintext in the same request to `/v1/backup`. Meanwhile, `validateRecordAccess` on the Worker allows *any* unknown `deviceId` to read/overwrite `/v1/backup` and `/v1/backup/get` whenever `devices.length < maxDevices` without binding the device.
- **Impact:** Anyone with KV access or a shared/leaked multi-device key (with 1 free slot) can silently decrypt all X/IG/Reddit session cookies, Rule34 keys, Seedr master keys, and likes.
- **Fix:** Require `requireBoundDevice: true` on `/v1/verify` and `/v1/backup*` in `license-worker.js`; stop storing plaintext social cookies in `UserData` (keep them in device Keychain/Keystore), or derive backup encryption keys from a separate user passphrase never sent to the server.

### XS-4. [CRITICAL] Broken CI/CD → GitHub Releases → Telegram Binary Delivery Pipeline
- **Files:** `.github/workflows/build.yml:3-61`, `.github/workflows/build-apk.yml:1-37`, `project.yml:9-10`, `APK VERSION/app/build.gradle.kts:24-32`, `backend/license-worker.js:200-234, 571-606, 2788-2803`
- **Interaction:**
  1. `build-apk.yml` never publishes `TinyTiny.apk` to the `latest` GitHub Release; `license-worker.js:572` fetches a stale git file (`raw.githubusercontent.com/.../APK%20VERSION/TinyTiny.apk`).
  2. `build.yml` has no `branches:`/`paths:`/`concurrency:` filter, so concurrent pushes clobber `latest/TinyTiny.ipa`.
  3. `project.yml` hardcodes `MARKETING_VERSION: "1.0"` and `CURRENT_PROJECT_VERSION: "1"`, breaking the Worker's `/minversion` enforcement for all iOS builds.
  4. `autoDeliverLatestBuildsToTelegram` writes `builds:last_notified_sha` **before** uploading; `sendTelegramBinaryFile` buffers entire binaries into 128MB Worker RAM / Telegram's 50MB limit and callers silently ignore `{ apk, ipa }` failure flags.
  5. Cron polls `api.github.com` unauthenticated every 2 minutes (720 req/day on shared Cloudflare IP -> frequent HTTP 403 rate limits).
- **Fix:** Publish `TinyTiny.apk` to `latest` Release in `build-apk.yml`; update `apkUrl` in Worker; add `branches`/`paths`/`concurrency` to both workflows; inject version/build numbers in CI; check `Content-Length < 49MB` before Telegram upload; persist `builds:last_notified_sha` only on success; pass `GITHUB_TOKEN`.

### XS-5. [CRITICAL] Missing `DIRECT_R2` Binding in `wrangler.toml` Will Break All `/v1/direct/*` & `/d/*` Routes on Next Deploy
- **Files:** `backend/wrangler.toml:1-10` ↔ `backend/license-worker.js:2464-2651`
- **Interaction:** `license-worker.js` relies heavily on `env.DIRECT_R2` for DirectStuff uploads, multipart parts, and `/d/:id` downloads, but `wrangler.toml` only binds `LICENSES` KV. Running `wrangler deploy` overwrites dashboard bindings and drops `DIRECT_R2`, causing HTTP 500 across all direct drop routes.
- **Fix:** Add `[[r2_buckets]] binding = "DIRECT_R2" bucket_name = "<bucket>"` to `backend/wrangler.toml`.

### XS-6. [CRITICAL] Encrypted Share (`TTDROP`) Cross-Platform Incompatibilities & Seedr Leak
- **Files:** `TinyTiny/ShareService.swift:40, 54, 154, 192-224` ↔ `APK VERSION/.../ShareService.kt:54, 214-240, 254-303` ↔ `backend/license-worker.js:1875, 1993, 2371-2426`
- **Interaction:**
  1. iOS emits `tinytiny://drop/<id>#k=<key>` even though its UI promises a browser-playable web link (`https://.../s/<id>#k=<key>`).
  2. iOS sends small files via `inlineBase64`, but Android `ShareService.kt:254-303` never reads `payload.inlineBase64` -> iOS-to-Android inline drops fail with `"Shared drop has no playable content."`.
  3. Neither iOS nor Android validates `shareId` regex (path traversal), and both break if `#k=` has extra fragment parameters.
  4. Worker `/v1/share` and `/v1/blob` omit `requireDeviceId: true`, have no `cipher` size cap, and never delete expired `.ttenc` blobs from Seedr (`dav.seedr.cc/tt_drops/`), slowly filling the admin's Seedr quota.
- **Fix:** Align on `https://.../s/<id>#k=<key>`, implement `inlineBase64` on Android, validate `shareId` with `^[A-Za-z0-9_-]{4,64}$`, enforce `requireDeviceId: true` + `cipher` size cap + Seedr TTL cleanup in the Worker.

### XS-7. [CRITICAL] Seedr Master Key Auto-Generation Race Permanently Breaks Cross-Device Seedr Decryption
- **Files:** `TinyTiny/CryptoBox.swift:43-51, 76-81`, `TinyTiny/LicenseManager.swift:640` ↔ `APK VERSION/.../CryptoBox.kt:82-97, 114-123`, `APK VERSION/.../LicenseManager.kt:619`
- **Interaction:** If Device B triggers `seedrVaultKey()` (e.g. during an upload/export) before pulling Device A's backup, Device B generates a random local key. Later, `restoreSeedrMasterKeyIfMissing()` sees an existing key and refuses to overwrite it — permanently desynchronizing Seedr encryption keys across devices.
- **Fix:** Track whether the local Seedr key has actually encrypted any Seedr upload; if unused (or on `isTrulyEmpty` restore), allow overwriting it with the restored backup's `seedrMasterKey`.

### XS-8. [HIGH] Cross-Platform Reddit Feed & Auth Breakdown (`homeFeed`/`popularFeed` Aliases, WAF 403, Cursor Collisions)
- **Files:** `TinyTiny/RedditService.swift:45-56, 131, 425-441`, `TinyTiny/FeedModel.swift:924, 949, 1042-1044` ↔ `APK VERSION/.../RedditService.kt:57-59`, `APK VERSION/.../FeedModel.kt:800`, `APK VERSION/.../MainActivity.kt:769`, `APK VERSION/.../FeedView.kt:1557`
- **Interaction:**
  - iOS `verifyUsername` only hits `www.reddit.com/api/me.json` (blocked by Fastly 403 WAF), stalling login completion; `homeFeed`/`followingFeed`/`popularFeed` all call `/best`; `FeedModel.swift` reuses `igMixAfterCursor` for Reddit Home and passes `after: nil` on every For You page.
  - Android `popularFeed` calls `/best` instead of `/r/popular`; `fetchBalancedForYou` ignores `fy.includeReddit` for personal Reddit; UI labels `REDDIT_POPULAR` as `"Following"` in the pill and `"Popular"` in `FeedStateView`.
- **Fix:** Use `oauth.reddit.com/api/v1/me` first in iOS `verifyUsername`; give personal Reddit its own `redditMixAfterCursor` in iOS `FeedModel`; gate Android personal Reddit on `fy.includeReddit`; unify labels and endpoints.

### XS-9. [HIGH] Cross-Platform `MediaMetaRegistry` Unbounded Memory Growth & Cliff-Eviction
- **Files:** `TinyTiny/Models.swift:398-406, 483-490` ↔ `APK VERSION/.../Models.kt:392-518`
- **Interaction:** On iOS, eviction only runs when `fingerprints.count > 4000` (X only), so non-X sessions leak memory forever, and when X hits 4001 it calls `removeAll()`, nuking active Erome albums and video fallbacks mid-session. On Android, eviction only checks `tagsById.size > 4000`, leaking 9 other `ConcurrentHashMap`s.
- **Fix:** Replace both with bounded LRU caches per map (evicting oldest 25% independently).

### XS-10. [HIGH] Hardcoded Shared Rule34.xxx Credentials in Both iOS & Android Binaries
- **Files:** `TinyTiny/Rule34Service.swift:50-74` ↔ `APK VERSION/.../Rule34Service.kt:55-77`
- **Interaction:** Both apps embed the exact same static `user_id` and `api_key` behind a trivial 8-byte XOR mask. Extraction or rate-limit abuse bans Rule34.xxx for all users on both platforms simultaneously.
- **Fix:** Proxy default Rule34 DAPI requests through the Cloudflare Worker (storing credentials in Wrangler secrets) or support remote key rotation via `/v1/config`.

### XS-11. [HIGH] Browse "Continue Watching" Ignores New Feed Kinds on Both iOS & Android
- **Files:** `TinyTiny/Screens.swift:234-265` ↔ `APK VERSION/.../Screens.kt:656-688`
- **Interaction:** `FeedSource.swipeKey` writes `reddithome`, `redditpopular`, `redditsaved`, `redditupvoted`, `longvideos`, `longsearch`, `multisearch`, and `list`, but Browse's `Continue` handler omits 8 kinds on iOS and 5 kinds on Android, dumping users back into `For You`.
- **Fix:** Map all `swipeKey.kind` values in both Browse overlays.

### XS-12. [MEDIUM] Worker Telemetry & Admin Stats Mislabel Android Devices as `"iOS Android 14"`
- **Files:** `backend/license-worker.js:114-131, 686, 1676`
- **Interaction:** `buildUsersStatsMessage` and `/errors` hardcode `iOS ${info.ios}` instead of `formatOsLabel(...)`, and `buildLicenseMetadata` only stores device `_0` (dropping multi-device telemetry and `modelId`).
- **Fix:** Use `formatOsLabel(...)` everywhere and store compact multi-device summaries in metadata.

### XS-13. [MEDIUM] Client-Side Clock Rollback Bypasses License Expiration on Both iOS & Android
- **Files:** `TinyTiny/LicenseManager.swift:247-254, 349-384` ↔ `APK VERSION/.../LicenseManager.kt:206-214, 344-378`
- **Interaction:** Both apps validate expiry against mutable local wall-clock time, grant permanent access if `!isLifetime && expiresAt == nil`, and ignore non-200 revocations in `verifySilently()`.
- **Fix:** Reject `!isLifetime && expiresAt == nil`, enforce an offline grace window + monotonic high-water timestamp, and handle HTTP 401/403 in `verifySilently()`.

---

## Section 2: Security & Privacy Vulnerabilities Summary

All security/privacy issues across the stack (detailed with exact fixes in Sections 3–5):

| ID | Severity | Platform | Location | Summary |
| :--- | :---: | :---: | :--- | :--- |
| **SEC-1** | `CRITICAL` | Backend | `license-worker.js:2764-2770` | `POST /v1/admin/deliver-builds` completely unauthenticated (spam + bandwidth/API DoS). |
| **SEC-2** | `CRITICAL` | Backend | `license-worker.js:2294-2327` | Unauthenticated `/v1/report-error` allows ~500 requests to exhaust KV's 1,000 writes/day limit. |
| **SEC-3** | `CRITICAL` | Backend | `license-worker.js:2371-2426` | `/v1/share` & `/v1/blob` omit `requireDeviceId`, lack `cipher` cap, allow unlimited Seedr fill. |
| **SEC-4** | `CRITICAL` | Backend | `license-worker.js:2215-2218` | Telegram webhook lacks `X-Telegram-Bot-Api-Secret-Token` header verification. |
| **SEC-5** | `CRITICAL` | iOS | `Security.swift:1079`, `LicenseManager.swift:386` | Passcode recovery accepts **any** valid license key -> full vault bypass. |
| **SEC-6** | `CRITICAL` | Android | `MainActivity.kt:164, 208`, `AndroidManifest.xml:33` | Exported `tinytiny://` deep links execute & open `IGDirectSendSheet` over `LockView`. |
| **SEC-7** | `CRITICAL` | iOS / Android | `XService.swift:6`, `InstagramService.swift:6`, `RedditService.swift:6`, `LicenseManager.*` | Live social session cookies (`auth_token`, `ct0`, `sessionid`, `token_v2`) stored in `UserData` & synced in server-decryptable cloud backups. |
| **SEC-8** | `CRITICAL` | Android | `CryptoBox.kt:37-53`, `Security.kt:51-63`, `LicenseManager.kt:173-185` | Silent fallback from `EncryptedSharedPreferences` to plaintext `SharedPreferences` XML. |
| **SEC-9** | `CRITICAL` | Android | `app/build.gradle.kts:24-32`, `proguard-rules.pro:2` | Release APK signed with debug keystore; minification/obfuscation disabled. |
| **SEC-10** | `CRITICAL` | iOS | `InstagramService.swift:1230-1350` | JS Injection/XSS via unescaped `clean` username & `maxId` inside authenticated `instagram.com`. |
| **SEC-11** | `HIGH` | Backend | `license-worker.js:139-160, 2330-2368` | Unbound device can read/overwrite `/v1/backup` & pass `/v1/verify` when device slots remain. |
| **SEC-12** | `HIGH` | Backend | `license-worker.js:2180-2193, 2043` | DirectStuff `/d/:id` leaks `?k=` in query string, uses unauthenticated AES-CTR; `isDirectAuthorized` leaks length. |
| **SEC-13** | `HIGH` | iOS / Android | `Security.swift:11-28, 1047`, `Security.kt:65-76, 476-550` | Unsalted 1-round SHA-256 on 4-digit PIN; in-memory `failures` resets on kill/rotate; wall-clock lockout; no lockout on Change Passcode. |
| **SEC-14** | `HIGH` | iOS | `XService.swift:498-512, 1038-1058` | JS Injection in `softNavigate` and `selectHomeTabJS` inside `x.com`. |
| **SEC-15** | `HIGH` | Android | `InstagramService.kt:697-721` | Unescaped `$maxId` JS injection in `followingFeed`/`savedFeed`. |
| **SEC-16** | `HIGH` | iOS / Android | `ShareService.swift:192-224, 745-758`, `ShareService.kt:214-240, 272` | Unsanitized `shareId`/`dropId` path traversal; iOS `igdrop` accepts `file://` URLs; Android SSRF check omits `normalize()`/`userInfo`/`port`. |
| **SEC-17** | `HIGH` | Android | `AndroidManifest.xml:20`, `network_security_config.xml:3-7` | Global cleartext HTTP allowed across all domains (`usesCleartextTraffic="true"`). |
| **SEC-18** | `HIGH` | iOS / Android | `RedditService.swift:456-469`, `RedditService.kt:461-472` | `RedditLoginSheet.loadMagicLink` loads arbitrary `http://` clipboard URLs into authenticated WebView. |
| **SEC-19** | `HIGH` | Android | `Security.kt:83-112` | Biometrics allows `BIOMETRIC_WEAK` (2D face) with non-crypto boolean callback. |
| **SEC-20** | `MEDIUM` | iOS | `TinyTinyApp.swift:140-157` | `onOpenURL` presents sheets / handles shares while `LockView` is active. |
| **SEC-21** | `MEDIUM` | Backend | `license-worker.js:13-17, 2871-2955` | Wildcard CORS (`*`) on `/v1/backup*` & `/v1/direct/*`; public Seedr Watchit links never expire. |
| **SEC-22** | `MEDIUM` | Android | `MainActivity.kt:76, 115-121` | `FLAG_SECURE` not updated immediately when toggling passcode settings. |
| **SEC-23** | `MEDIUM` | iOS / Android | `ShareService.swift:266`, `ShareService.kt:279` | Plaintext decrypted media drops (`tt_drop_*`) leaked in temp/cache directories without cleanup or file protection. |

---

## Section 3: iOS Exhaustive Audit (`TinyTiny/*.swift`)

### 3.1 UI, Video Playback, Gestures & Offline Vault
*Files: `TinyTinyApp.swift`, `FeedView.swift`, `Screens.swift`, `Theme.swift`, `OfflineManager.swift`*

#### CRITICAL
1. **Shared `isScrubbing` State Unmounts `PlayerScrubberBar` Mid-Drag (`FeedView.swift:1298, 1458-1660, 2255-2283, 2496-2552`)**
   - **Cause:** `GoonedReelCell` shares one `isScrubbing` `@State` between `ReelGestureOverlay` (hold-scrub) and `PlayerScrubberBar`. Touching `PlayerScrubberBar` sets `isScrubbing = true`, which switches `body` to the hold-scrub HUD and unmounts `PlayerScrubberBar`, killing the drag and flashing `0:00 / 0:00`.
   - **Fix:** Split into `isHoldScrubbing` and `isBarScrubbing`; increase scrubber touch height to `36–44pt`.
2. **Synchronous Main-Thread Disk I/O & Lock Contention in `OfflineManager` (`OfflineManager.swift:29-95, 126-147, 382-401`; `Models.swift:222, 265, 284, 297`; `Screens.swift:1263, 2640`)**
   - **Cause:** `ensureIndexReady()` unlocks `indexLock` before calling `contentsOfDirectory`, racing with SwiftUI `body` reads on MainActor. `totalDiskUsageString()` runs `stat()` on every vault file synchronously inside `GoonedLikesView.body` and `GoonedSettingsModal.body` on every state change.
   - **Fix:** Serialize `ensureIndexReady()` cleanly off-main; cache `@Published var cachedDiskUsageString` recomputed in `Task.detached` on vault mutations only.
3. **`HorizontalSwipeBridge` Leaks & Stacks `UISwipeGestureRecognizer`s + Hijacks Scrubbing/Albums (`TinyTinyApp.swift:447-461, 1712-1800`)**
   - **Cause:** Attached inside `.id(activeChannel)` with no `dismantleUIView`/`deinit`, accumulating orphaned recognizers on `uiView.superview` on every channel switch; `shouldRecognizeSimultaneouslyWith` unconditionally returns `true`.
   - **Fix:** Move outside `.id(activeChannel)`, remove recognizers in `dismantleUIView` + `deinit`, and return `false` for active `UILongPressGestureRecognizer`s and horizontal `UIScrollView`s.
4. **Multi-Item Album (`TabView`) Double-Skips Slides, Lacks Video Loading/Error UI, & Breaks Hold HUD on Images (`FeedView.swift:1373-1395, 2284-2295, 2342-2423`)**
   - **Cause:** `ReelGestureOverlay` (`onSwipeLeft`/`Right`) and `mediaView` (`DragGesture`) mutate `albumIndex` simultaneously with `TabView(.page)` (double-advancing slides). Album video branch renders bare `PlayerLayerView` with no poster/spinner/`allFailed` retry. `if !isShowingImage` disables `gestureZones` on images so `holdDetailsHUD` never triggers on images.
   - **Fix:** Let `TabView(.page)` own album paging exclusively; share `videoPlayerContainer` with poster/spinner/retry; add lightweight long-press/double-tap handler for images.
5. **`PlayerModel` Lifecycle Bugs: Double `onClipEnded`, Premature `play()`, Deferred `replaceCurrentItem` Race, & Missing `deinit` (`FeedView.swift:449-473, 542-555, 603-619, 751-790`)**
   - **Cause:** `onClipEnded` fires at `ratio >= 0.97` (cutting off the last 18s of a 10-min video) AND again on `AVPlayerItemDidPlayToEndTime`; `advanceToNextCandidate()` calls `player.play()` before async `loadItemTask` attaches the new item; deferred `replaceCurrentItem(with: nil)` races with `retry()`; no `deinit`.
   - **Fix:** Remove the `0.97` trigger (use `AVPlayerItemDidPlayToEndTime` only); remove premature `player.play()`; clear current item synchronously on teardown; add `deinit`.
6. **Background Task Expiration Crash (`0x8badf00d`) (`TinyTinyApp.swift:166-175`)**
   - **Cause:** `beginBackgroundTask(withName: "TinyTinyCloudSync") {}` has an empty expiration handler that never calls `endBackgroundTask(bgId)`.
   - **Fix:** End `bgId` inside the expiration handler and merge the two duplicate `.onChange(of: phase)` modifiers (lines 132 & 158).

#### HIGH
7. **`GoonedReelCell.activateTask` Never Cleared -> Videos Permanently Stuck Black (`FeedView.swift:1740-1794`):** `activateTask` is never set to `nil` on completion or early exit (`!isActive`), so returning from Browse/Settings/CreatorGrid fails `activateTask == nil` and never prepares the video. **Fix:** `defer { if !Task.isCancelled { activateTask = nil } }`.
8. **`GoonedLikesView.deleteSelected()` Deletes Camera Roll Photos When Unliking (`Screens.swift:1532-1548`):** Calls `deleteSavedPhotos` unconditionally before `if mode == "offline"`. **Fix:** Move inside `if mode == "offline"`.
9. **Bulk Export & Save to Photos Buffers 4 Videos in RAM (OOM), Fails on HLS `.m3u8`, Exports Thumbnails for Images, & Omits Cookies (`Screens.swift:1550-1655`):** Uses `URLSession.shared.data` in a 4-way `TaskGroup`, picks `.m3u8` first, uses `post.thumbURL` for images, and omits `WKWebsiteDataStore` cookies. **Fix:** Stream via `URLSession.shared.download`, skip `.m3u8`, use `post.imageURL`, attach cookies.
10. **Collapsed Mode & `PostMoreSheet` Download `gif` Instead of `activeDownloadGif` + 6 `gif.isImage` vs `isShowingImage` Mismatches (`FeedView.swift:1090, 1439, 1563-1572, 2125, 2236, 2242, 2316, 2501, 2608-2633`):** Wrong slide downloaded in Erome albums; image slides show dead video scrubber; image albums stall auto-scroll. **Fix:** Pass `activeDownloadGif` and use `isShowingImage` consistently.
11. **Hardcoded Top/Horizontal Offsets Cause UI Overlaps & Notch Clipping (`TinyTinyApp.swift:466-521`, `FeedView.swift:907, 1451, 1597, 1653, 2132, 2420`):** Erome album counter (`top: 96`) is buried under `homeTopBar`/`subChannelBar`; `dislikeToast`/`2x`/`holdDetailsHUD` collide with announcements; landscape padding (`24–28pt`) clips behind Dynamic Island (`~59pt`). **Fix:** Use `geo.safeAreaInsets` / `.safeAreaPadding`.
12. **Browse "Continue" Card Ignores 8 `FeedSource` Types (`Screens.swift:234-265` vs `FeedModel.swift:136-169`):** Falls back to `For You` for `reddithome`, `redditpopular`, `redditsaved`, `redditupvoted`, `longvideos`, `longsearch`, `multisearch`, `list`. **Fix:** Handle all 8 cases.
13. **`OfflineManager` Main-Thread File Moves/Thumbnail Encoding, Async Delete Race, Wasted `.m3u8` Loop, Missing Thumbnail Cookies, & Fake Progress (`OfflineManager.swift:173-380`):** `@MainActor` runs file moves + `jpegData` on MainActor; `removeDownload` async delete races immediate re-download; `.m3u8`-only streams spin uselessly; thumbnails lack cookies; progress is hardcoded constants. **Fix:** Move I/O to serial background actor/queue; fail fast on HLS-only; attach cookies to thumbnails; report real download bytes.
14. **`MediaImageLoader` Prefetch Key Mismatch, `clearCache()` Task Leak, Double-Timeout on 404s, & Stale Image in `RemoteImageView` (`FeedView.swift:165-215, 292-315`):** Prefetches full-res (`nil`) while `GridThumb` requests `#w420`; `clearCache()` doesn't cancel `inFlight`; retries without Referer on 404/timeout (40s hang); `RemoteImageView` doesn't reset stale `image`/`didFail` on URL change. **Fix:** Cancel tasks in `clearCache()`, retry without Referer only on 400/401/403, align prefetch sizes, reset state on URL change.
15. **`CreatorProfileGridView` Passes Unfiltered `gridSrc` on Rule34 Search & Rebuilds From Scratch on Back (`Screens.swift:3495-3501, 3674`, `TinyTinyApp.swift:690-709, 853-856`):** Paginating from a filtered Rule34 grid drops the tag filter; pressing Back destroys/recreates the grid from page 1. **Fix:** Pass `model.source` and keep grid state alive while viewing a post.
16. **Erome Overwrites `lastLongChannel` (`TinyTinyApp.swift:1029`):** Visiting Erome resets the Long Videos tab back to `All`. **Fix:** `if mapped != .longErome { lastLongChannel = mapped }`.
17. **`GoonedLikesView` Top Bar Overflows on 375–393pt iPhones (`Screens.swift:1129-1216`):** 5 controls in a non-scrolling `HStack` wrap/clip. **Fix:** Add `.lineLimit(1).minimumScaleFactor(0.8)` and move `Select` to the sub-toolbar.

#### MEDIUM & LOW (UI/Playback/Offline)
- **M-18:** `"Snapchat"` category unreachable in Browse & `"Videos"` duplicated (`Theme.swift:159`, `Screens.swift:43-54, 332-337`).
- **M-19:** `GoonedBrowseOverlay` fires all 4 search APIs regardless of `searchScope` and renders Reddit sections under non-Reddit scopes (`Screens.swift:177-202, 968-1062`).
- **M-20:** `onOpenURL` presents sheets / handles shares while `LockView` or age/license gate is active (`TinyTinyApp.swift:140-157`).
- **M-21:** Missing `else` causes private `UIDevice.setValue(..., forKey: "orientation")` to run on iOS 16+ (`TinyTinyApp.swift:21-30`).
- **M-22:** `syncOrientationLock()` ignores open modals (`Settings`/`CreatorGrid`/Login sheets) & `.onChange(of: customModel.source)` eagerly instantiates `lazy var customModel` (`TinyTinyApp.swift:759-761, 802-811`).
- **M-23:** Rotating to landscape & back permanently overwrites user's persisted `controlsCollapsed` setting (`FeedView.swift:1663-1668`).
- **M-24:** Paused Play icon gets stuck over Erome album photo slides with no way to dismiss (`FeedView.swift:1393-1408, 2376-2385`).
- **M-25:** Tag-change observers defeat `FeedModelRegistry` lazy init (instantiating 6 models eagerly); cold launch runs `license.verifySilently()` twice (`TinyTinyApp.swift:126-139, 762-779`).
- **M-26:** Uncancellable `DispatchQueue.main.asyncAfter` prematurely hides rapid double-tap skip/heart indicators (`FeedView.swift:2322-2335`).
- **M-27:** `FeedStateView.onAppear` duplicates initial `loadMore()` and fires when `canLoadMore == false` (`FeedView.swift:858-867, 924-927, 1264`).
- **M-28:** `GoonedLikesView` multi-select shows duplicate "Clear All"/"Deselect All" buttons and stale selection counts across filter tabs (`Screens.swift:1224-1255, 1416-1434`).
- **M-29:** `AlgorithmEditorSheet` autocomplete lacks `Task.isCancelled` check and `onDisappear` cancel (`Screens.swift:3271-3284`).
- **M-30:** `GoonedFollowsView` omits Personal Reddit card; Settings has duplicate "Copy Key" buttons; avatars use raw `AsyncImage` without `MediaHeaders`/cache (`Screens.swift:467-489, 1002-1012, 1831-1953, 2016-2026, 2695-2735`).
- **M-31:** Four screens call unthrottled `checkAndPullIfRemoteChanged()` on every mount; `FeedView` spawns uncancelled 50ms swipe tasks & double `markSeen` (`Screens.swift:1125, 1800, 2913, 3547`, `FeedView.swift:941-964, 1112`).
- **L-32–L-36:** ~20–25 stacked `.ultraThinMaterial` live blurs over 60fps video (`Theme.swift:46-142`); synchronous `AVAudioSession` on MainActor (`FeedView.swift:1587, 2053`); `RemoteGateOverlay` touch passthrough (`TinyTinyApp.swift:200-247`); 2KB floor rejects valid small images (`OfflineManager.swift:247-251`); dead code (`didPrewarm`, `VideoPreloader.preloadedItems`, `PrivacyCover` flashing on `.inactive`, unused `Theme` constants/helpers).

---

### 3.2 Core State, Algorithm, Security, Sync & Sharing
*Files: `Models.swift`, `UserStore.swift`, `FeedModel.swift`, `SmartTasteEngine.swift`, `CryptoBox.swift`, `Security.swift`, `LicenseManager.swift`, `ShareService.swift`*

#### CRITICAL
1. **Passcode Lock Complete Bypass via Any Valid License Key (`Security.swift:1079-1090`, `LicenseManager.swift:386-390`)**
   - **Cause:** `verifyPasscodeRecovery(rawKey:)` never checks `entered == status.licenseKey`; it calls `activate(rawKey: entered)` directly. Any attacker with their own license key unlocks the victim's vault and merges the victim's data into the attacker's cloud backup.
   - **Fix:** Require exact match `entered == active` and call `verifySilently()` instead of `activate()`.
2. **Unsynchronized Keychain Key Generation & Overwrite Causes Permanent Vault Data Loss (`CryptoBox.swift:18-26, 43-51, 111-139`; `UserStore.swift:149-154`; `SmartTasteEngine.swift:244-249`)**
   - **Cause:** `localVaultKey()` / `seedrVaultKey()` have no lock or cache; `readKeychain` treats transient `errSecInteractionNotAllowed` as `nil`, generates a new 256-bit key, and calls `SecItemUpdate` (overwriting the real key). `UserStore`/`SmartTasteEngine` then fail decryption and overwrite disk files with empty state.
   - **Fix:** Add `NSLock` + cached key; only generate on `errSecItemNotFound`; use `SecItemAdd` only (never `SecItemUpdate`); never overwrite an existing undecryptable file on disk.
3. **Cloud Sync Blindly Overwrites `SmartTasteEngine.state` & Never Hydrates Vision (`LicenseManager.swift:639`, `SmartTasteEngine.swift:881-886`)**
   - **Cause:** `applyImportedBackup` replaces `state = imported`, wiping local dislikes/settings and iOS Vision prints on Android syncs, without calling `VisualTasteAnalyzer.shared.hydrate(...)` or clearing `visualScoreMirror`.
   - **Fix:** Implement true `mergeImportedBackup(_:)` and call `VisualTasteAnalyzer.shared.hydrate(...)`.

#### HIGH
4. **"Zero-Knowledge" Backup Key Derived via HKDF from Server-Known License Key (`LicenseManager.swift:394-404, 430-434`).**
5. **Passcode Weaknesses (`Security.swift:11-28, 42, 84-88, 1047-1052, 1118-1129`):** Unsalted SHA-256 of 4-digit PIN, `UserDefaults` fallback & `requirePasscodeOnOpen` in `UserDefaults`, in-memory `failures` resets on force-quit, wall-clock `lockedUntil`. **Fix:** Per-device salt + PBKDF2 (>=100k iterations) + Keychain-only failure/lockout state.
6. **Cloud Restore (`isTrulyEmpty`) Wipes `seenIDs` & `savedCursors` + Missing `redditSession` & Last-Item Deletion Bug (`LicenseManager.swift:512-530, 641, 723-738`, `UserStore.swift:133-135, 198-202`):** `UserStore.shared.data = deduped` never updates `_seenIDs`, `seenSet`, or `_savedCursors`, so `saveNow()` immediately wipes them. **Fix:** Add atomic `UserStore.replaceAllData(_:)`.
7. **In-Memory `localAddedTimestamps` Causes Tombstone Resurrection (`UserStore.swift:136, 404-586`, `LicenseManager.swift:531-615`):** Persist added timestamps inside `UserData`.
8. **TOCTOU Race in `LicenseManager.checkAndPullIfRemoteChanged()` (`LicenseManager.swift:128-153, 711-717`):** `isSyncingBackup` isn't re-checked after `await session.data(for: req)`, allowing concurrent restore + upload. **Fix:** Re-check guard after `await` or use an async mutex.
9. **Offline Clock-Rollback License Bypass & Non-200 Verification Ignored (`LicenseManager.swift:247-254, 349-384`).**
10. **Path Traversal & `file://` Scheme Injection in `ShareService` (`ShareService.swift:192-224, 745-758`):** Unsanitized `shareId`/`dropId` in URL paths; `DirectIGDropPayload` accepts `file://` for `mp4Url`. **Fix:** Regex validate IDs and require `https` scheme.
11. **`ShareService` Main-Thread Blocking & OOM Crash on Large File Shares (`ShareService.swift:20, 75-99, 262-268, 569-582`):** `@MainActor` reads unbounded `Data(contentsOf:)` and runs `CryptoBox.seal`/`open` synchronously on Main Thread. **Fix:** Enforce 90MB cap and run in `Task.detached`.
12. **`UserStore.eraseAll()` & `SmartTasteEngine.reset()` Re-Create Deleted Files on Disk (`UserStore.swift:980-996`, `SmartTasteEngine.swift:291-299, 873-879`):** Assigning fresh struct triggers `didSet { scheduleSave() }` after `saveTask?.cancel()`, recreating deleted files 0.5–2s later; `SmartTasteEngine.saveNow()` is unserialized. **Fix:** Cancel `saveTask` *after* assignment and serialize deletion on `saveQueue`.
13. **`UserStore.performSelectiveWipe()` Resurrects Wiped Data & Breaks OF Gender Filter (`UserStore.swift:233-319`, `SmartTasteEngine.swift:187-191`):** No tombstones recorded -> 18s live sync restores wiped slices; `"tinytiny."` sweep deletes `"tinytiny.of.hidden_genders.v1"` even when `keepAlgorithm == true`.
14. **`VisualTasteAnalyzer` Never Cleared on Algorithm Reset & Never Hydrated on Restore (`SmartTasteEngine.swift:86-101, 873-886`).**
15. **`FeedModel` Stale-Response Race on Source/Sort Switching (`FeedModel.swift:236-245, 325-378, 510-742`):** Untracked `Task`s from `onItemAppear`, `prefetchIfNeeded`, `shuffleItems`, `init`, and self-chaining `loadMore()` append Source A posts into Source B and corrupt cursors/caches. **Fix:** Add `loadGeneration: Int` checked after every `await`.
16. **`Gif.isPlayableVideoURLString` Misclassifies Query-String CDN Images as Videos (`Models.swift:171-175, 182-195`):** `hasSuffix(".jpg")` fails on `...jpg?stp=dst-jpg`, falling through to `contains("cdninstagram.com") -> true` -> black video player. **Fix:** Check `URL(string: s)?.pathExtension.lowercased()`.

#### MEDIUM & LOW (iOS Core/Algo/Sync)
- **M-17:** `PasscodeSetupView` leaves `requirePasscodeOnOpen = false` & no rate limit on `.change` (`Security.swift:84-97, 1005-1036`).
- **M-18:** `PasscodePad` 120ms double-submission race & duplicate Face ID prompts (`Security.swift:381-384, 1077-1102`).
- **M-19:** `AppState.eraseEverything()` leaves sync tasks, `requirePasscodeOnOpen`, lockout defaults, and media caches intact (`Security.swift:114-125`, `LicenseManager.swift:274-282`).
- **M-20:** `CryptoBox.restoreSeedrMasterKeyIfMissing` fails if Device B auto-generated a key first (`CryptoBox.swift:43-51, 76-81`).
- **M-21:** `LicenseManager` merge branch omits `r34Credentials`, `subredditWeights`, `creatorWeights` & fires `@Published` in loops (`LicenseManager.swift:538-638`).
- **M-22:** `ShareService` emits `tinytiny://` despite browser-link copy, breaks on multi-param `#k=` fragments, leaks unprotected `/tmp/tt_drop_*` files, and doesn't clear `pendingReceivedPosts` (`ShareService.swift:40, 54, 154, 199-200, 266-293, 607, 637`).
- **M-23:** `UserStore.data.seenIDs` frozen at launch, breaking `FeedModel.swift:807` category exclusion (`UserStore.swift:133-137, 339-349`).
- **M-24:** `toggleFollowOFCreator` tombstone key mismatch on handle match (`UserStore.swift:570-576`).
- **M-25:** `AdultContentClassifier.isEligible` enforces `isBlockedByAlgorithm` on non-discovery sources (profiles/saved/search), overriding `FeedModel`'s `isDiscoverySource` guard (`FeedModel.swift:569-570`, `UserStore.swift:1320`).
- **M-26:** `SmartTasteEngine.topOnlyFansSeedHandles` passes `"creator:..."` and `"sub:..."` verbatim to OnlyFans API (`SmartTasteEngine.swift:314-329, 1037-1053`).
- **M-27:** `SmartTasteEngine` unbounded maps/mirror, random `keys.first` eviction, & `applyGenderSuppressionRules` overrides pinned tags (`SmartTasteEngine.swift:167-169, 355-357, 641-644, 722-758`).
- **M-28:** `FeedModel` never resets `ofMixAfterCursor`, computes `scorePost` inside `.sorted` ($O(N \log N)$ on MainActor), passes `after: nil` to Reddit Home in For You, and fetches `.following` pools sequentially (`FeedModel.swift:341-351, 777-803, 920-925, 1042-1058`).
- **M-29:** `MediaMetaRegistry` cliff-eviction wipes active posts at 4000 fingerprints and leaks non-X sessions (`Models.swift:398-406, 483-490`).
- **L-1–L-12:** `isRenderableImageURLString` accepts `file://` & `webURL` accepts `javascript:` (`Models.swift:197-206, 306-310`); per-call regex compile in `contentSimilarityKey` (`Models.swift:114-125`); loop `@Published` mutations in `UserStore` (`743-747, 842-882`); `scorePost` omits `isFollowingOFCreator` (`771-776`); dead `"sheLikesitrough"` alias (`1079`); `isEligibleXTweet` identical branches (`1291-1294`); unused `VisualTasteAnalyzer.inFlightPosts` & `cachedWordEmbedding`; `saveDiskCache` omits `.completeFileProtection`; `ShareService` names images `.mp4` & allows duplicate Generate taps; `CryptoBox` lacks GCM AAD; non-constant-time `Passcode.verify`; `clearLicense()` double-writes Keychain.

---

### 3.3 API & Social Services
*Files: `API.swift`, `XService.swift`, `InstagramService.swift`, `RedditService.swift`, `OnlyFansService.swift`, `Rule34Service.swift`, `LongVideoService.swift`*

#### CRITICAL
1. **`XWebEngine` Lock & Continuation Cancellation Leaks + Rate-Limit Buffer Replay (`XService.swift:427, 463-469, 518-535, 974-984, 1069-1071, 1143-1165`):** `acquireLock()` and `fetchFeed` ignore `Task` cancellation (multi-search timeout leaves lock held ~6s); `isRateLimited` returns `routeBuffers[routeKey]` without clearing it (replaying stale batches); `flushWaitersIfNeeded` resumes all waiters with identical `buf`. **Fix:** Add `withTaskCancellationHandler`, clear buffer on return, resume single waiter.
2. **Plaintext X Session Cookies in `UserData` & Missing `saveNow()` (`XService.swift:6-16, 816, 898, 1628-1630, 1698-1715`):** Move to Keychain and call `saveNow()` on login.
3. **`InstagramWebEngine.ensureWebView()` & `ensureDirectWebView()` Lack Creation Coalescing (`InstagramService.swift:400-516, 881-900`):** Concurrent calls spawn duplicate hidden `WKWebView`s in `keyWindow` running `setInterval(scanSSRScripts, 1400)` forever. **Fix:** Coalesce via `webViewCreationTask`.
4. **`InstagramWebEngine.waiters` Lacks Per-Call Tokens & Cancellation (`InstagramService.swift:241, 327-344, 633-643, 738-759`):** Expired call #1 timeout kills call #2's active waiter with `[]`, falsely triggering full page reloads. **Fix:** Add UUID token per waiter + `withTaskCancellationHandler`.
5. **JS Injection / XSS in `InstagramAPI` (`InstagramService.swift:1230-1350`):** Unescaped `clean` username (`userReels:1342`) and `maxId` (`saved:1314`) interpolated into JS inside authenticated `instagram.com`. **Fix:** Use `callAsyncJavaScript` with `arguments` + `encodeURIComponent`.
6. **`InstagramWebEngine.resetSession()` Leaks State & `ensureDirectWebView()` Leaks DM Videos Into Reels (`InstagramService.swift:239-240, 881-900, 1204-1219`):** Clears dead `seenIds` instead of `seenIdsByRoute`, leaves `cachedDirectThreads` & `directWebView` alive; `directWebView` shares `userContentController` (routing DM media into `ig_reels`) and gets resized to mobile `390x844` by `attachToKeyWindowIfNeeded`. **Fix:** Separate `WKUserContentController`, preserve `1280x800`, and clear all state on reset.
7. **Force-Unwrapped `URLComponents(string: ...)!` Crash in `RedditPersonalAPI` (`RedditService.swift:61, 67, 106, 152`):** Unencoded `uname` in `/user/\(uname)/saved` causes fatal crash on invalid URL chars. **Fix:** Percent-encode `uname` and `guard let`.
8. **Hardcoded Shared Rule34.xxx Credentials + Synchronous Keychain IPC in SwiftUI `body` (`Rule34Service.swift:50-74, 86-129, 601-611`):** Static XOR-masked credentials shared by all users; `Rule34Credentials` calls `SecItemCopyMatching` on every SwiftUI render. **Fix:** Proxy via Worker + cache Keychain reads in memory.

#### HIGH
- **`API.swift:58-69` (`FeedModel.swift:807`):** `categoryExclusionCursor` only strips `x_`, leaking OF/IG/R34/LV/RD IDs into the 120-ID cap and risking HTTP 414.
- **`XService.swift:498-512, 1038-1058`:** JS Injection in `softNavigate` and `selectHomeTabJS` (newlines/line separators unescaped).
- **`XService.swift:351-372, 876-878, 1318-1320`:** Thread-unsafe `DateFormatter`/`ISO8601DateFormatter` called concurrently from `Task.detached` (`EXC_BAD_ACCESS` risk).
- **`XService.swift:698-703, 814-818, 1483-1492`:** `hookJS` DOM `screen_name` regex grabs a stranger's handle -> `XAPI.likes()` opens the wrong user's likes.
- **`XService.swift:748-779, 1349-1363`:** `injectStoredCookies` skips `ct0` when `auth_token` exists; `followUser` uses stale `session.ct0` instead of live `WKHTTPCookieStore`.
- **`XService.swift:1220-1266, 1415-1445`:** `XAPI.forYou` resets `searchFast` to `after: nil` every page (burning 429 limits); `searchFast` paginates infinitely with no max stage.
- **`XService.swift:77, 202-339, 258-295, 421-426`:** `XTweetParser` drops videos 2–4 in multi-video tweets, registers `MediaMetaRegistry` before `AdultContentClassifier`, leaks `seenIdsByRoute`/`routeBuffers`, and has `" module"` typo.
- **`InstagramService.swift:441-493`:** `hookJS` clones & decodes EVERY `fetch` response (including media/binary) to text and runs `setInterval(..., 1400)` in all iframes forever.
- **`InstagramService.swift:588-604`:** Double-parses JSON and returns early when `reels.isEmpty` BEFORE saving `nextMaxIdByRoute` (stalling `IG Following`/`Saved` on photo-only pages).
- **`InstagramService.swift:1043-1192`:** `sendMP4ToDirectThread` buffers full MP4 + Base64 in JS bridge (~5–6x RAM -> OOM) and interpolates unvalidated `threadId`.
- **`InstagramService.swift:6-16, 777-826, 1472-1478`:** Plaintext IG cookies in `UserData`, missing `saveNow()`, `followUser` uses stale CSRF, `fetchFeed` omits `isConnected` guard.
- **`RedditService.swift:131, 425-441, 702`:** `verifyUsername` only calls `www.reddit.com/api/me.json` (blocked by Fastly 403 WAF -> stuck login).
- **`RedditService.swift:6-26, 70-78`:** `fullWebCookieHeader` overwrites live `reddit_session` with stale fallback; plaintext cookies in `UserData`.
- **`RedditService.swift:45-56, 105-180`:** `homeFeed`/`followingFeed`/`popularFeed` all call `/best`; `fetchListing` silently swallows HTTP 401/403/429/5xx.
- **`OnlyFansService.swift:485-509, 690, 721`:** `forYou` receives creator *names* (not IDs) and interpolates them unencoded into `/onlyfans/user/\(seedId)/similar`.
- **`OnlyFansService.swift:847-897`:** `searchPosts` lacks `Int(after)` fallback (breaking Multi-Search page 2+) and never returns `after: nil`.
- **`OnlyFansService.swift:335-344` vs `391-394`:** `mapDms` omits `femboyOrTransRescueTags` check present in `mapPosts`.
- **`Rule34Service.swift:290, 482, 511, 545-553`:** `fetchFeed` never returns `after: nil`; `parseMoebooruJSON` hardcodes `rule34.xxx` permalink for `yande.re` and passes `.webm` to `AVPlayer`; `posterUrl` uses full-res 8K PNG `fileUrl` instead of `previewUrl`.
- **`LongVideoService.swift:63-67, 163-168, 369-385, 470, 585-995`:** Compiles ~300 regexes/page on the `LongVideoAPI` actor (stalling concurrent playback resolution); `resolvedCache` grows unbounded with no in-flight coalescing; photo-only Erome albums never cached; `hasPrefix(stem)` drops `1.jpg` when `10.mp4` exists; unsafe `.urlPathAllowed`/`.urlQueryAllowed`; Pornhub search restricted to `period=weekly`.

#### MEDIUM & LOW (iOS API & Social Services)
- **`API.swift:33-48, 99-152`:** `.urlPathAllowed` permits `/`; mid-string `r/`/`u/` stripping; unbounded `following()` query string (HTTP 414); random `categories()` dictionary order; per-call `JSONDecoder`.
- **`XService.swift:732-737, 854-868, 968, 1213, 1294-1355, 1504, 1723-1809`:** `x_likes_` missing from route isolation; `fetchGraphQLDirect` double-captured by `hookJS`; unsafe `.urlQueryAllowed`; unencoded `userMedia`; `WKContentRuleList` compile race; missing `XLoginWebViewRepresentable.dismantleUIView`.
- **`InstagramService.swift:118-139, 180-185, 763-766`:** Drops reel if widest variant lacks URL; registers metadata before eligibility filter; never returns `after: nil` on finite routes.
- **`RedditService.swift:406-412, 456-469, 539-546`:** `loadMagicLink` accepts arbitrary `http://` clipboard URLs; RedGIFs fallback downgrades videos to static images.
- **`OnlyFansService.swift:129-141, 203-247, 620, 641, 717, 755-844`:** Per-attachment `ISO8601DateFormatter` allocation; unbounded caches; stale `topCreators` cache on gender filter change; `latest`/`dms` wrap back to offset `0` on empty page.
- **`Rule34Service.swift:196, 307-390, 700-716`:** Substring check skips `-men` on `"women"`; unsafe `.urlQueryAllowed` in autocomplete; ignored HTTP status codes; unused `Rule34AccountWebView` bindings.
- **`LongVideoService.swift:229-239, 758-780`:** SpankBang fallback rebadges Eporner IDs without copying `MediaMetaRegistry` tags; resolvers regex-scan 403/429 pages without checking HTTP 200.

---

## Section 4: Android Exhaustive Audit (`APK VERSION/`)

### 4.1 UI, ExoPlayer, Gestures, Offline & Config
*Files: `MainActivity.kt`, `TinyTinyApplication.kt`, `FeedView.kt`, `Screens.kt`, `Theme.kt`, `OfflineManager.kt`, `AndroidManifest.xml`, `app/build.gradle.kts`, `proguard-rules.pro`, `network_security_config.xml`*

#### CRITICAL
1. **Bulk "Save to Photos" Runs Blocking Network/File I/O on `Dispatchers.Main` (`OfflineManager.kt:96-159, 187-237` ↔ `Screens.kt:1043-1057`)**
   - **Cause:** `OfflineManager.download(gif)` runs synchronous OkHttp `.execute()`, disk writes, and `MediaMetadataRetriever` without `withContext(Dispatchers.IO)`. `GoonedLikesView` calls it from `rememberCoroutineScope()` (`Dispatchers.Main`) -> `NetworkOnMainThreadException` silently swallowed -> `"Saved 0 to Gallery"`.
   - **Fix:** Wrap `OfflineManager.download(gif)` body in `withContext(Dispatchers.IO)`.
2. **Exported `tinytiny://` Deep Links Execute & Open Sheets Over `LockView()` (`MainActivity.kt:164-174, 194, 208-210` ↔ `AndroidManifest.xml:33-38`)**
   - **Cause:** `LaunchedEffect(directIGId)` and `LaunchedEffect(shareUri)` fire regardless of `isLocked`/`licenseActivated`, and `IGDirectSendSheet` is rendered outside the lock gate on top of `LockView()`.
   - **Fix:** Gate both effects and `IGDirectSendSheet` on `canHandleDeepLinks = ageConfirmed && onboardingCompleted && licenseActivated && passcodeChoiceCompleted && !isLocked`.
3. **State Mutation During Composition Inside `ExoPlayer` `remember { ... }` (`FeedView.kt:423-427`)**
   - **Cause:** Directly mutates `playbackFailed = false` and `isFirstFrameRendered = false` inside `remember(...)`, violating Compose's contract and triggering invalidation loops/flicker.
   - **Fix:** Move resets into `LaunchedEffect(exoPlayer)` or event callbacks.
4. **Release APK Signed With Debug Keystore & Minification/Shrinking Disabled (`app/build.gradle.kts:24-32, 73`, `proguard-rules.pro:2`)**
   - **Cause:** `release` uses `signingConfigs.getByName("debug")`, `isMinifyEnabled = false`, no `isShrinkResources = true`, and `proguard-rules.pro:2` has `-keep class com.bella.tinytiny.** { *; }` while pulling all of `material-icons-extended` (~10–15MB bloat).
   - **Fix:** Configure a real release `signingConfig`, enable `isMinifyEnabled = true` + `isShrinkResources = true`, and narrow ProGuard rules to `@Serializable`/`@JavascriptInterface`.

#### HIGH
5. **App-Wide Compose Recomposition Storm on Every Swipe, Loop, & Download Tick (`MainActivity.kt:157, 257`, `FeedView.kt:103, 153, 163, 336-338, 491, 500`):** Collecting full `UserStore.shared.data` in `RootView`, `GoonedMainShell`, `FeedView`, and 3 `GoonedReelCell`s + `downloadProgress` in every cell recomposes the entire app on every swipe/loop/3% tick. **Fix:** Slice flows with `.map { ... }.distinctUntilChanged()` and isolate the download button composable.
6. **Main-Thread Disk I/O & SQLite Init (`TinyTinyApplication.kt:25-35, 48-55`, `FeedView.kt:436`, `OfflineManager.kt:37-54`):** `mediaSimpleCache` (250MB SQLite + dir scan) and `OfflineManager.ensureIndex()` (`vaultDir.listFiles()`) initialize synchronously on Main Thread during composition. **Fix:** Warm up on `Dispatchers.IO` in `TinyTinyApplication.onCreate()`.
7. **ExoPlayer Steals Audio Focus Even When Muted (`FeedView.kt:453-462, 529, 537`):** `setAudioAttributes(audioAttrs, true)` unconditionally requests `AUDIOFOCUS_GAIN`, pausing Spotify/podcasts even while muted. **Fix:** Pass `handleAudioFocus = !userData.settings.muted` and update on mute toggle.
8. **ExoPlayer & Coil Double-Caching Over 150MB OkHttp `Cache` (`FeedView.kt:429-439, 1373-1393`, `TinyTinyApplication.kt:25-35, 48-64`):** `SharedExoClients` and Coil inherit `sharedHttpClient`'s 150MB HTTP cache on top of 250MB `SimpleCache` / Coil disk cache, causing range-request stalls and double disk writes. **Fix:** Add `.cache(null)` in `SharedExoClients.buildClient()` and `newImageLoader()`.
9. **ExoPlayer & Hardware `MediaCodec` Retained While Backgrounded or Locked (`FeedView.kt:423-469`, `MainActivity.kt:100-113, 632`):** Holds hardware decoders indefinitely when backgrounded/locked -> black screen if evicted by YouTube/Camera. **Fix:** Release on `!isAppForeground` and restore `currentPosition` on resume.
10. **Activity / View Tree Memory Leak via `XWebEngine` & `InstagramWebEngine` Host Container (`MainActivity.kt:553-561`):** `AndroidView` attaches `FrameLayout(ctx2)` to singleton WebEngines with no `onRelease`. **Fix:** Detach WebViews and clear `hostContainer` in `onRelease` (or use `WeakReference`).
11. **26 Persistent `FeedModel` Instances Leak CoroutineScopes & Fire 26 Disk Reads at Launch (`MainActivity.kt:262-288`, `FeedModel.kt:169-177, 214-230`):** Never calls `model.close()` in `DisposableEffect`. **Fix:** Lazily instantiate per channel and close all on dispose.
12. **Broken Multi-Slide Erome Album Retry Loop (`FeedView.kt:408-420`):** `advanceOrFail()` increments `urlIndex` while `activeVideoUrl` stays pinned to `currentAlbumItem.url`, recreating ExoPlayer repeatedly on the same failing URL. **Fix:** Cap album video retries to 2 passes (`useReferer = true/false`).
13. **Horizontal Channel Swipe Conflicts With Erome `HorizontalPager`, `PlayerScrubberBar`, & Long-Press Scrubbing (`MainActivity.kt:575-627`, `FeedView.kt:585-647, 1349-1365`):** Full-screen `detectHorizontalDragGestures` hijacks scrubber drags and albums. **Fix:** Ignore horizontal swipes while scrubbing / in scrubber zone.
14. **Vertical Scroll Conflict on Standard Portrait Images (`FeedView.kt:1445, 1470-1486`):** `(1.0 / knownAspect) > 1.35` wraps standard 9:16/2:3 portrait photos in `.verticalScroll()` inside `VerticalPager`, making vertical swipes sticky. **Fix:** Raise threshold to `> 2.2` (genuine tall comics only).
15. **`VerticalPager` Stale State After Dislike, Shuffle, or Custom-to-Custom Feed Switch (`FeedView.kt:131-169, 209-248`, `MainActivity.kt:629`):** Keying only on `activeChannel` doesn't reset pager between two `CUSTOM` feeds; `snapshotFlow { settledPage }` doesn't fire when `removeDisliked` shifts a new item into the same index. **Fix:** Key on `src` and observe `items.getOrNull(settledPage)?.id`.
16. **Broken Backdrop Click Blocking (`.clickable(enabled = false) {}`) in `PostMoreSheet` & `GoonedSettingsModal` (`FeedView.kt:1615-1626`, `Screens.kt:1703, 1713`):** In Compose, `enabled = false` lets taps pass straight through to the backdrop, dismissing modals on any empty-space tap. **Fix:** Use `enabled = true` with `indication = null`.
17. **Invisible Black Text in `OutlinedTextField`s & Bright-White Material3 Dialogs (`MainActivity.kt:78`, `Screens.kt:1090, 1595-1603, 2023-2072, 2232`, `FeedView.kt:1025`):** `RootView()` isn't wrapped in dark `MaterialTheme(colorScheme = darkColorScheme(...))`, leaving black text on `#120A0F` in Rule34 filter and Algorithm editor. **Fix:** Wrap `RootView()` in a dark `MaterialTheme`.
18. **Broken Erome Album Tap in Search Results (`Screens.kt:433-460`):** Clicking an Erome album card opens generic `LongSearch` instead of `onOpenPost(album)`. **Fix:** Call `onOpenPost(album)`.
19. **`OfflineManager.saveToMediaStoreGallery` Missing `IS_PENDING`, Orphaned Entries, & Broken API 26–28 Export (`OfflineManager.kt:239-280`, `AndroidManifest.xml:7-9`):** Never sets `IS_PENDING`, never deletes failed MediaStore rows, and never requests runtime `WRITE_EXTERNAL_STORAGE` on Android 8–9 (`SecurityException`). **Fix:** Use `IS_PENDING`, delete on failure, request permission on API < 29.
20. **Concurrent `MutableStateFlow` Races, Indexed `.part` Files, & 64-Char Stem Collision in `OfflineManager` (`OfflineManager.kt:41-57, 83-98, 156, 215`, `FeedView.kt:399`):** Non-atomic `.value = .value + ...`; `ensureIndex()` indexes interrupted `*.part` files; `safeFileStem` `.take(64)` causes multi-slide Erome IDs >= 64 chars to overwrite slide 0. **Fix:** Use `.update {}`, ignore/delete `*.part`, hash stems > 48 chars.
21. **Non-Reactive `OfflineManager.isDownloaded()` & Silent HLS Download Errors (`OfflineManager.kt:26-153`, `FeedView.kt:1167`, `Screens.kt:1237`):** `isDownloaded` reads a plain map (grids don't update live); `lastError` for HLS-only streams is never shown. **Fix:** Expose `StateFlow<Set<String>>` and display `lastError` toast.
22. **Global Cleartext HTTP Traffic Permitted (`AndroidManifest.xml:20`, `network_security_config.xml:3-7`):** Allows unencrypted HTTP to all domains. **Fix:** Set `cleartextTrafficPermitted="false"` globally and allowlist only specific legacy media domains if needed.
23. **`scrubPreview` Bitmap Leak, Uncancelled Blocking JNI Call, & Missing Cookies (`FeedView.kt:350, 622-645, 1797-1818`):** Slow `MediaMetadataRetriever` completes after drag end and leaks `Bitmap` into state; omits `CookieManager` cookies (failing on X/IG/Reddit). **Fix:** Cancel job on drag end, guard `if (isScrubbing)`, attach cookies, prefer local vault file.

#### MEDIUM & LOW (Android UI/Playback/Config)
- **M-24:** Orientation stays permanently locked to Portrait after tapping "Portrait"/"^ Controls"; Settings/CreatorGrid stay cramped in landscape (`MainActivity.kt:314-320`, `FeedView.kt:988-992, 1230-1251`).
- **M-25:** `FLAG_SECURE` not synced immediately on passcode toggle; "Require Passcode on Open" can be toggled ON with no PIN (`MainActivity.kt:76, 115-121`, `Screens.kt:1890-1907`).
- **M-26:** `MainActivity.bgScope` never cancelled in `onDestroy()`; `onStop()` locks the app when opening system Share Choosers (`MainActivity.kt:70, 100-113`).
- **M-27:** `ExoPlayer` `Player.Listener` captures stale `isActive` boolean (`FeedView.kt:472, 492`).
- **M-28:** Double-tap forward skip seeks back to `0:00` when `duration == C.TIME_UNSET` (`FeedView.kt:569`).
- **M-29:** `ExoTextureSurface` misses initial `videoSize` aspect ratio on fast local files and calls methods on released player (`FeedView.kt:1397-1437`).
- **M-30:** Top HUD overlaps (`2x`, Erome counter, `dislikeToast` vs sub-channel/announcement pills); missing `.displayCutoutPadding()` in landscape; collapsed download button omits progress indicator (`MainActivity.kt:650-865`, `FeedView.kt:268, 687, 826, 1210-1291`).
- **M-31:** Hold Details HUD `@author` `.clickable` is unreachable while finger is held down (`FeedView.kt:894-923`).
- **M-32:** `PlayerScrubberBar` initializes `durationSec = 1.0` (fake 1s range before load) and `.height(20.dp)` clips thumb (`FeedView.kt:1318, 1332, 1364`).
- **M-33:** `TallOrNormalImage` "Tap to retry" is a no-op on single-URL images (`FeedView.kt:1454, 1464`).
- **M-34:** `FeedStateView` reads `UserStore.shared.data.value` non-reactively (`FeedView.kt:1540-1554`).
- **M-35:** `GoonedBrowseOverlay` parallel search leaves spinner stuck if any sibling search throws (`Screens.kt:109-130`).
- **M-36:** "Continue Watching" omits 5 feed kinds (`reddithome`, `redditpopular`, `redditsaved`, `redditupvoted`, `longsearch`) (`Screens.kt:656-688`).
- **M-37:** Missing `BackHandler` on Settings sub-sheets (`AlgorithmEditorSheet`, `WipeDataSheet`, `PasscodeSetupView`) & non-scrollable `WipeDataSheet` (`Screens.kt:1921-1923, 2196`).
- **M-38:** `AlgorithmEditorSheet` "Hide Yaoi / Bara" toggle OFF leaves `"bara"` permanently blocked (`Screens.kt:1991, 2005-2007`).
- **M-39:** Bottom dock collapse threshold uses raw `18f` px (~5dp) instead of `dp` (`MainActivity.kt:953`).
- **M-40:** `ShimmerPlaceholder` invalidates composition at 60–120fps instead of using `drawBehind` (`Theme.kt:352-364`).
- **L-41–L-45:** Unused `dismissedAnn` in `RootView` (`MainActivity.kt:156`); brand logo `.sp` clips at large font scales (`Theme.kt:135-345`); uncancelled toast/indicator timers; clipboard copy of License Key omits `EXTRA_IS_SENSITIVE` (`Screens.kt:1870`); `REDDIT_POPULAR` pill says `"Following"` vs `FeedStateView` `"Popular"`; deprecated `security-crypto:1.1.0-alpha06`; unbounded Coil caches; missing `Locale.US` in `String.format`; uncaught `ActivityNotFoundException` on `createChooser`.

---

### 4.2 Core State, Algorithm, Security, Sync & Sharing
*Files: `Models.kt`, `UserStore.kt`, `FeedModel.kt`, `SmartTasteEngine.kt`, `CryptoBox.kt`, `Security.kt`, `LicenseManager.kt`, `ShareService.kt`*

#### CRITICAL
1. **Silent Plaintext Fallback on `EncryptedSharedPreferences` Failure + Silent Vault Wipe (`CryptoBox.kt:37-53, 63-97`, `Security.kt:51-63`, `LicenseManager.kt:173-185`, `UserStore.kt:131-141`, `SmartTasteEngine.kt:378-388`):** Catching `Throwable` falls back to plaintext `*_fallback`/`*_fb` prefs and generates a fresh vault key, causing `UserStore`/`SmartTasteEngine` to fail decryption and overwrite local vault files with empty data. **Fix:** Remove plaintext fallback, exclude secure prefs from Android Auto Backup, and back up undecryptable files instead of overwriting.
2. **Passcode Brute-Force (Unsalted 1-Round SHA-256) + Lockout Bypasses (`Security.kt:65-76, 358-449, 476-550`):** 10,000-PIN unsalted SHA-256; `failures` in Compose `remember` resets on rotate/kill; wall-clock `lockedUntilMs` in plaintext prefs; zero lockout on Change Passcode. **Fix:** Per-device salt + PBKDF2-HMAC-SHA256 (>=100k), monotonic `elapsedRealtime()` lockout in `EncryptedSharedPreferences`, enforced centrally in `Passcode.verify()`.
3. **Non-Atomic Read-Modify-Write Races on `UserStore.data` & `SmartTasteEngine.state` (`UserStore.kt:226-860`, `SmartTasteEngine.kt:325-799`, `LicenseManager.kt:508-618`):** `val cur = state.value; state.value = cur.copy(...)` across Main, Default, and IO threads silently drops likes, dislikes, visual prototypes, and toggles. **Fix:** Use atomic `.update { ... }` and batch `ingestPostsIntoCreatorGraph` per page.
4. **Non-Atomic File Saves (`f.delete()` Before `tmp.renameTo(f)`) & Unlocked Concurrent Disk Cache Writes (`UserStore.kt:158-185`, `SmartTasteEngine.kt:421-442`, `FeedModel.kt:867-878`):** Deleting the target file before `renameTo` risks permanent loss on crash; concurrent `saveDiskCache` calls write to the same `.tmp` file simultaneously. **Fix:** Use `AtomicFile` (or unique `.tmp` + atomic `renameTo` without pre-delete) and per-key locks.
5. **Cross-Platform iOS↔Android Backup Sync Wipes Android Visual Vectors & Source Toggles (`LicenseManager.kt:618`, `SmartTasteEngine.kt:35-42, 75-76, 794-799`).**
6. **Client-Side Clock Tampering Bypasses License Expiry & Null `expiresAt` Grants Permanent Access (`LicenseManager.kt:206-214, 344-378`).**
7. **OOM Crashes on Encrypted File Drops (270MB Heap Allocation) + Main-Thread File Copy + Hardcoded `.mp4` Extension (`ShareService.kt:89-108, 276-280, 599-623, 678`):** `file.readBytes()` + `CryptoBox.seal()` allocates ~3x file size (270MB for 90MB file); `filePicker` copies files on Main Thread into `"pick_....mp4"` and leaks temp files on error. **Fix:** Copy on `Dispatchers.IO`, preserve real extension/MIME, delete in `finally`, cap/stream large files.

#### HIGH
- **H-1 (`LicenseManager.kt:389-404, 436-476`):** "Zero-Knowledge" backup key derived from server-known `licenseKey`.
- **H-2 (`FeedModel.kt:279-335, 408-412, 436-572`):** Untracked `loadMore()` jobs, `setSort()` doesn't increment `loadGen`, and old `finally { isLoading.value = false }` clobbers active loads.
- **H-3 (`FeedModel.kt:214-235`):** `init` async disk cache load injects old source's items after quick `switchSource()`.
- **H-4 (`FeedModel.kt:205-212, 776-858`, `SmartTasteEngine.kt:41`):** `fetchBalancedForYou` ignores `fy.includeReddit` for personal Reddit and never fetches `LongVideoAPI` when `fy.includeLongVideos` is true.
- **H-5 (`FeedModel.kt:488-493`, `SmartTasteEngine.kt:94, 341-365, 579, 748`):** Visual similarity runs asynchronously *after* `rankWithAlgorithm` (always 1 page behind), leaks `post.id` permanently in `visualInFlight` when thumb URL is null, and calls unbounded `resp.body?.bytes()`.
- **H-6 (`Security.kt:83-112, 489-505`):** Biometrics uses `BIOMETRIC_WEAK`, double-prompts on launch (`LaunchedEffect` + `ON_RESUME`), and omits `isFinishing`/`isDestroyed` check.
- **H-7 (`Security.kt:128-183`, `LicenseManager.kt:380-386`):** Passcode setup leaves `requirePasscodeOnOpen = false`; recovery accepts any valid key if `active` is empty and runs `activate()` (restoring backup) as a side effect.
- **H-8 (`LicenseManager.kt:114-169, 328, 421-689`, `UserStore.kt:123`):** Last-item deletion skips upload; Reddit/R34 omitted from `isTrulyEmpty`/`hasData`; in-memory `localAddedTimestamps`; missing `syncMutex` on `activate()`/`syncEncryptedBackupNow()`; blind union of boosted/blocked tags; case-sensitive `.distinct()` on follows.
- **H-9 (`CryptoBox.kt:82-97, 114-123`, `LicenseManager.kt:619`):** `restoreSeedrMasterKeyIfMissing` fails permanently if `seedrVaultKey()` ran first.
- **H-10 (`ShareService.kt:54, 100, 214-303`):** `shareId` path injection, incomplete SSRF path check (missing `normalize()`/`userInfo`/`port`), missing `inlineBase64` support (breaks iOS inline drops), stale `pendingReceivedPosts`, leaked plaintext `cacheDir/tt_drop_*`.
- **H-11 (`Models.kt:56-78`):** `Gif` overrides `equals`/`hashCode` to compare only `id` on a mutable `data class` -> `StateFlow` drops updates when `muxedUrl`/`posterUrl`/`upvotes` mutate.

#### MEDIUM & LOW (Android Core/Algo/Sync)
- **M-1:** `eraseEverything()` & `performSelectiveWipe()` race with 18s `liveSyncJob` (wiped data resurrects) and unconditionally reset `settings` (`Security.kt:185-203`, `UserStore.kt:818-860`).
- **M-2:** `verifySilently()` never calls `AppState.markLicenseActivated(false)` on revocation; `clearLicense()` leaks sync jobs & `lastRemoteBackupJson` (`LicenseManager.kt:239-244, 344-378`).
- **M-3:** Uncaught `CookieManager.getInstance()` exception in `injectRestoredSocialCookies()` & unsanitized cookie values (`LicenseManager.kt:635-666`).
- **M-4:** `UserStore` `seenSet` mutated outside lock, $O(N^2)$ `removeAt(0)` eviction, and `clearSeenHistory()` doesn't clear `SmartTasteEngine.seenSimilarityKeys` (`UserStore.kt:189-222, 795-800`).
- **M-5:** `toggleFollowOFCreator` tombstone key mismatch resurrects unfollowed creators (`UserStore.kt:441-462`).
- **M-6:** `sourceUrl?.contains("x.com")` misclassifies `sex.com`/`box.com` as X; `video.mp4.jpg` fails both video & image checks (`Models.kt:80-90, 286-305, 567-593`).
- **M-7:** `MediaMetaRegistry` leaks 9 `ConcurrentHashMap`s and has non-atomic list merges (`Models.kt:392-518`).
- **M-8:** `SmartTasteEngine` unbounded maps & `reset()` races with pending `saveJob` (`SmartTasteEngine.kt:611-623, 801-807`).
- **M-9:** Substring false positives (`"anal"` matches `"analysis"`, `"ass"` matches `"class"`, `"cock"` matches `"cocktail"`) & per-call regex recompilation (`Models.kt:185-197`, `UserStore.kt:635, 756, 897-919`, `SmartTasteEngine.kt:265-277`).
- **M-10:** `FeedModel` `removeDisliked` index shift, unsynchronized/un-cleared `followingCursors`, unfiltered X/IG dry-streak fallback, unbounded `LongVideoAPI` pre-resolve (`FeedModel.kt:194-195, 290-299, 337-425, 518-533, 684-707`).
- **M-11:** `Security.kt` 90–110ms verification delay allows 5th-digit/backspace double verification (`Security.kt:402-448, 515-552`).
- **M-12:** `ShareService` UI allows duplicate Regenerate taps, sends `file://` to `IGDirectSendSheet`, ignores collection drops in `ReceiveDropSheet`, and uses wrong MIME types (`video/mov`, unknown -> `image/jpeg`) (`ShareService.kt:176-182, 344-665`).
- **L-1–L-7:** Per-call `SecureRandom()` (`CryptoBox.kt:59, 128`); plaintext fallback downgrade on `openCodable` (`167-174`); unnormalized keys in `removeLearnedTag`/`removeLearnedSubreddit`; insertion-order eviction of `creatorLatentClusters`; `compareVersions` drops `"0-beta"`; `String.format` missing `Locale.US`; `sanitizeLoadedData` skips alias normalization.

---

### 4.3 API & Social Services
*Files: `API.kt`, `XService.kt`, `InstagramService.kt`, `RedditService.kt`, `OnlyFansService.kt`, `Rule34Service.kt`, `LongVideoService.kt`*

#### CRITICAL
1. **Guaranteed OOM Crash on Large Video Direct IG Drops (`InstagramService.kt:590-620`):** `sendVideoToDirectThread` buffers the entire MP4 into a single JVM heap `ByteArray` via `r.body?.bytes()`. **Fix:** Stream to a temp file in `cacheDir`, upload via `file.asRequestBody(...)`, and delete in `finally`.

#### HIGH
2. **WebView Leaks & Off-Main-Thread Crashes (`XService.kt:563-569, 620-623, 1077-1082`; `InstagramService.kt:372-377, 435-438, 850-887`; `Rule34Service.kt:474-503`):** `resetSession` destroys WebViews without `Dispatchers.Main`; `onRenderProcessGone` doesn't detach/destroy; `InstagramLoginSheet` and `Rule34KeySheet` have **no `onRelease`**; `XLoginSheet` leaks `popupWebView`. **Fix:** Teardown on Main thread and add `onRelease` / `DisposableEffect` cleanup.
3. **`seen.add(gid) && seen.add(dedupeKey)` Silently Drops Valid Posts (`XService.kt:242-244`, `InstagramService.kt:161-162`):** When `dedupeKey == gid`, the first `seen.add(gid)` inserts it (`true`) and the second `seen.add(dedupeKey)` returns `false`, discarding every such tweet/reel! **Fix:** `if (dedupeKey == gid) seen.add(gid) else (seen.add(gid) && seen.add(dedupeKey))`.
4. **`InstagramAPI` Unescaped JS Injection & Missing `X-CSRFToken` (`InstagramService.kt:697-721`):** `followingFeed`/`savedFeed` interpolate raw `$maxId` into JS strings; `apiTriggerJS` POSTs omit `x-csrftoken` (HTTP 403). **Fix:** Use `JSONObject.quote(maxId)` and attach `x-csrftoken`.
5. **`XWebLane` Route Cross-Contamination, `screenName` Hijack, & Timed-Out Waiter Leak (`XService.kt:490-502, 531-544`, `InstagramService.kt:345-357`):** Late XHRs pollute the new `activeRouteKey`; any JSON with `"screen_name"` overwrites logged-in handle; timed-out `CompletableDeferred` waiters leak. **Fix:** Match URL endpoint to route, restrict `screenName` to `settings.json`/`Viewer`, remove timed-out waiters in `finally`.
6. **`RedditLoginSheet.loadMagicLink` Loads Arbitrary `http://` Clipboard URLs (`RedditService.kt:461-472, 562-569, 654, 675`):** Allowlist `https://` on `reddit.com`/`redditmail.com` only.
7. **Hardcoded XOR-Obfuscated Rule34.xxx Credentials (`Rule34Service.kt:55-77`).**
8. **`OnlyFansAPI` Infinite Empty Pagination, Unbounded Caches, & Offset Mismatch (`OnlyFansService.kt:118-120, 411-423, 453, 475, 508-512`):** `fetchLatest`/`fetchDMs`/`fetchForYou` return non-null `after` on empty pages; caches grow unbounded; `fetchCreatorPosts` skips to `dms:0` on photo-only page 0; `fetchForYou` passes `page * 24` to step-50/40 endpoints (heavy duplicates).
9. **`LongVideoAPI` Loop Regex Recompilation, Unbounded `resolvedCache`, & `ALL` Feed Duplication (`LongVideoService.kt:35, 87-95, 188-202, 293, 427-462, 715-736`):** Compiles 240+ regexes/page inside loops; `resolvedCache` never evicts; SpankBang 403 fallback inside `LongVideoSite.ALL` re-fetches XVideos/Eporner under `lv_sb_*` IDs (duplicating items & doubling traffic); `ALL` omits `EROME`.

#### MEDIUM & LOW (Android API & Social Services)
- **`API.kt:41, 87, 95, 111-112`:** `URLEncoder` used for path segments & broad `.replace("r/", "")` strips mid-string substrings.
- **`XService.kt:121, 451, 708`, `InstagramService.kt:308, 455, 644`:** `" module"` typo; DOM layout thrashing in `scrollAdvanceJS`; `preDrained` outside lock; fragile `!respText.contains("\"ok\"")`.
- **`RedditService.kt:57-59, 434-439`:** `popularFeed` calls `/best`; RedGIFs fallback turns videos into static images; `cm.flush()` on Main thread every 1.4s.
- **`OnlyFansService.kt:399-570`, `Rule34Service.kt:183`, `LongVideoService.kt:336`:** Unencoded `creatorId` in paths; `Rule34API.fetchFeed` always returns non-null `after`; fragile `;</script>` delimiter in `fetchXHamster`.
- **All 7 Services (LOW):** Synchronous blocking OkHttp `.execute()` ignores coroutine cancellation (wrap in `suspendCancellableCoroutine` with `call.cancel()`).

---

## Section 5: Backend Worker, Telegram Bot & CI/CD Audit
*Files: `backend/license-worker.js`, `backend/wrangler.toml`, `.github/workflows/build.yml`, `.github/workflows/build-apk.yml`, `project.yml`*

#### CRITICAL
1. **Unauthenticated Admin Endpoint `POST /v1/admin/deliver-builds` (`license-worker.js:2764-2770`):** Zero authentication check -> anyone can spam admin Telegram with builds and exhaust Worker CPU/RAM + GitHub/Telegram rate limits. **Fix:** Require constant-time `ADMIN_API_SECRET` header + KV rate limit.
2. **Unauthenticated `/v1/report-error` Enables Free-Tier KV Quota DoS (`license-worker.js:2294-2327`):** No auth; rate-limit key uses caller-controlled `deviceId`; 2 KV writes/request -> ~500 requests exhaust Cloudflare KV's 1,000 writes/day limit, bricking the entire app ecosystem. Also read-modify-write race on `errors:recent`. **Fix:** Require valid license key or Cloudflare IP WAF rate-limit, and throttle Telegram error alerts.
3. **Missing `requireDeviceId` & Unbounded Storage Abuse on `/v1/share` and `/v1/blob` (`license-worker.js:2371-2426`):** No device check, no `body.cipher` size cap, unlimited 95MB Seedr uploads with **no TTL cleanup** of `.ttenc` files on Seedr. **Fix:** Require bound `deviceId`, cap `cipher` size (2MB), add per-key daily quota, and schedule Seedr `.ttenc` cleanup.
4. **Telegram Webhook Lacks `X-Telegram-Bot-Api-Secret-Token` Verification (`license-worker.js:2215-2218`):** Relies only on non-constant-time URL path comparison. **Fix:** Register `secret_token` and verify header in constant time.
5. **Telegram 50MB Cap, Worker 128MB OOM, Stale APK URL, Broken Retry, & Unauthenticated GitHub Cron (`license-worker.js:200-234, 571-606, 2788-2803`):** Buffers full APK/IPA via `arrayBuffer()`; ignores upload failure results; `apkUrl` points to stale static git file; persists `builds:last_notified_sha` *before* upload succeeds; `*/2 * * * *` cron hits unauthenticated `api.github.com` (403 rate limits). **Fix:** Check `Content-Length < 49MB`, report failures, write `last_notified_sha` only on success, use `GITHUB_TOKEN`, and serve APK from `latest` GitHub Release.

#### HIGH
6. **Unbound Device Can Read/Overwrite Cloud Backups & Pass `/v1/verify` (`license-worker.js:139-160, 2267-2287, 2330-2368`):** `validateRecordAccess` allows any unknown `deviceId` while `devices.length < maxDevices`. **Fix:** Add `requireBoundDevice: true` for `/v1/verify` and `/v1/backup*`.
7. **DirectStuff `/d/:id` Leaks `?k=` in Query String, Uses Unauthenticated AES-CTR, Buffers 90MB Uploads in Worker RAM, & Non-Constant-Time Secret Length (`license-worker.js:2043, 2180-2193, 2499-2530, 2592-2651`):** `await request.arrayBuffer()` OOMs Worker on 90MB uploads; trusts client `Content-Length`; `?k=` leaks in history/logs. **Fix:** Stream `request.body` to R2, use `obj.size`, add `Referrer-Policy: no-referrer` + CSP, move key to `#k=`.
8. **Unescaped Telegram HTML Injection Breaks `/list` and `/watchit` (`license-worker.js:1427, 1702`):** `rec.note` and `res.error` unescaped -> `<`/`>`/`&` causes silent HTTP 400. **Fix:** Wrap in `escapeHtmlTg(...)`.
9. **Telegram 3,940-Char Truncation Slices Mid-HTML-Tag (`license-worker.js:164, 238`):** Causes silent HTTP 400 with no plain-text fallback. **Fix:** Truncate safely and retry without `parse_mode` if `!r.ok`.
10. **KV Eventual Consistency, Redundant Writes, & Subrequest Limits (`license-worker.js:625-628, 956-959, 1424-1429, 2338-2345, 2926-2955`):** `syncWatchitFolder` can double-post, exceed 50 subrequests, and exceed 512-byte KV keys on long torrent paths; `PUT /v1/backup` writes redundant `backup_ver` (3 KV writes/sync); `/list` does 20 sequential KV reads. **Fix:** Hash `davPath`, cap 8 videos/tick, drop `backup_ver` write (read `getWithMetadata`), parallelize `/list`.
11. **`buildLicenseMetadata` Drops Multi-Device Telemetry & Mislabels Android as `"iOS Android 14"` (`license-worker.js:114-131, 290-303, 686, 1676`):** Only stores device `_0`, caps legacy reads at 40, and hardcodes `iOS ${info.ios}`. **Fix:** Store compact multi-device summaries and call `formatOsLabel(...)`.
12. **`/extend` Downgrades Lifetime Keys, Inconsistent `maxDevices` Caps (10 vs 50), & 12-Char `unbindDevicesKeyboard` Prefix Collision (`license-worker.js:412-413, 1051, 1396, 1445-1454, 1522`).**
13. **CI/CD Release Clobbering, Unfiltered `macos-latest` Runs, & Missing APK Release Publishing (`.github/workflows/build.yml:3-61`, `build-apk.yml:1-37`):** Add `branches: [main]`, `paths:`, `concurrency:`, explicit `permissions:`, `HOMEBREW_NO_AUTO_UPDATE=1`, and publish `TinyTiny.apk` to `latest` Release.

#### MEDIUM & LOW (Backend & CI/CD)
- **M-1 (`wrangler.toml:1-10`):** Missing `DIRECT_R2` R2 binding (next deploy breaks all `/v1/direct/*` and `/d/*`).
- **M-2 (`license-worker.js:13-17`):** Wildcard CORS (`*`) on `/v1/backup*`, `/v1/activate`, `/v1/direct/*`, `/v1/blob`.
- **M-3 (`license-worker.js:2871-2955`):** Public Seedr Watchit links never expire (`no expirationTtl`) and `Depth: "1"` misses all videos inside torrent subfolders.
- **M-4 (`license-worker.js:2720-2746`):** `/xv/:id` proxy serves upstream 403/410 HTML error pages with `Content-Type: video/mp4`.
- **M-5 (`license-worker.js:1875, 1993`):** `renderShareLandingHTML` omits `!bResp.ok` check (shows misleading `"invalid key"`) and allows `?k=` query fallback.
- **M-6 (`project.yml:9-10`):** Static `MARKETING_VERSION: "1.0"` & `CURRENT_PROJECT_VERSION: "1"` breaks `/minversion` enforcement for iOS.
- **M-7 (`.github/workflows/*.yml`):** Node 20 action deprecation & mutable `@v4` tags.
- **L-1–L-4:** `randomId` modulo bias (`87-92`); dead `sendTelegramDocumentUrl` (`179-198`); unnecessary KV write in `customExtMatch` (`1307`); hardcoded KV namespace ID / repo slug / Worker URL.

---

## Section 6: Prioritized Engineering Fix Roadmap

### P0 — Immediate Security, Data-Loss & Outage Fixes (Do First)
1. **Backend Worker Security & Stability (`backend/license-worker.js`, `wrangler.toml`):**
   - Lock down `POST /v1/admin/deliver-builds`, `/v1/report-error`, Telegram `X-Telegram-Bot-Api-Secret-Token`, `requireBoundDevice: true` on `/v1/verify` & `/v1/backup*`, and `requireDeviceId: true` + size caps on `/v1/share` & `/v1/blob`.
   - Add `DIRECT_R2` to `wrangler.toml` and stream R2 uploads (`request.body`) instead of `arrayBuffer()`.
   - Fix `sendLatestBuildsToTelegram` (50MB guard, error reporting, `last_notified_sha` after success, `GITHUB_TOKEN`, release APK URL) + `escapeHtmlTg` in `/list` & `/watchit`.
2. **Passcode Lock & Deep-Link Bypasses (iOS & Android):**
   - Fix iOS `verifyPasscodeRecovery` to require `entered == active` without calling `activate()`.
   - Gate `tinytiny://` deep links & `IGDirectSendSheet` behind `!isLocked` on both iOS and Android.
   - Upgrade 4-digit PIN hashing to salted PBKDF2-HMAC-SHA256, persist `failures` + monotonic lockout in Keychain/`EncryptedSharedPreferences`, and remove plaintext fallbacks.
3. **Vault Data-Loss Prevention (`CryptoBox`, `UserStore`, `SmartTasteEngine`):**
   - Fix iOS `CryptoBox` Keychain race (lock + cache + `SecItemAdd` only + only generate on `errSecItemNotFound`).
   - Fix Android `CryptoBox` plaintext fallback & non-atomic `f.delete()` before `renameTo` (`AtomicFile`), plus atomic `.update {}` on `UserStore`/`SmartTasteEngine`.
   - Replace `applyImportedBackup` overwrite with true cross-platform `mergeImportedBackup` on both iOS and Android; fix `isTrulyEmpty` `seenIDs` wipe, last-item tombstone upload, `performSelectiveWipe()` tombstones, and Seedr key restore race.

### P1 — Critical UX, Playback, Crash & Pipeline Fixes
4. **iOS Playback & UI Showstoppers:** Split `isScrubbing` into `isHoldScrubbing`/`isBarScrubbing`; clear `GoonedReelCell.activateTask` in `defer`; fix `PlayerModel` double `onClipEnded` & premature `play()`; fix `HorizontalSwipeBridge` recognizer leak; fix `TabView` album double-skip & video error UI; fix `OfflineManager` main-thread I/O & `deleteSelected()` Camera Roll bug; fix `beginBackgroundTask` expiration handler.
5. **Android Playback, Crash & UI Showstoppers:** Wrap `OfflineManager.download` in `withContext(Dispatchers.IO)`; fix `InstagramService.sendVideoToDirectThread` & `ShareService` OOMs; remove state mutation inside `ExoPlayer` `remember`; wrap `RootView` in dark `MaterialTheme`; fix `ExoPlayer` muted audio-focus steal & double-caching (`.cache(null)`); slice `UserStore.data` flows to stop app-wide recomposition storms; fix `.clickable(enabled = false)` modal backdrops.
6. **Build & Release Pipeline:** Configure real Android release signing + R8 minification (`app/build.gradle.kts`, `proguard-rules.pro`); publish `TinyTiny.apk` to `latest` Release in `build-apk.yml`; add `branches`/`paths`/`concurrency` to workflows; inject iOS version/build numbers in `build.yml`/`project.yml`.

### P2 — Social Services, Algorithm & Performance Polish
7. **X / Instagram / Reddit / OnlyFans / Rule34 / LongVideo Fixes:** Fix Android `seen.add(gid) && seen.add(dedupeKey)` post drops; fix iOS/Android JS injection & WebView leaks; fix iOS `RedditPersonalAPI.verifyUsername` (`oauth.reddit.com/api/v1/me`), `URLComponents!` crash, and `FeedModel` cursor collisions; fix `XWebEngine`/`InstagramWebEngine` waiter tokens & cancellation; precompile regexes in `LongVideoService` & `Models`; fix `OnlyFansAPI` seed IDs & `searchPosts` cursor; fix `Rule34API` pagination & `yande.re` links; replace `MediaMetaRegistry` cliff-eviction with bounded LRU.
8. **Cross-Platform UX & Algorithm Consistency:** Fix Browse "Continue Watching" missing feed kinds; fix iOS/Android HUD/notch overlaps; fix `FeedModel` `loadGeneration` races; fix Android `VisualTasteEngine` 1-page lag; fix `SmartTasteEngine` pinned-tag overrides & word-boundary matching.

### P3 — Hardening & Cleanup
9. Migrate social session cookies out of `UserData` / cloud backups into device Keychain/Keystore (or implement true passphrase-based E2EE backup v3); proxy default Rule34 DAPI key through Worker; tighten Android `network_security_config.xml` & Worker CORS; remove dead code and deprecated dependencies.
