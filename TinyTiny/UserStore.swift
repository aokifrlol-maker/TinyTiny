import SwiftUI
import AVFoundation
import WebKit

struct AppSettings: Codable {
    var hd: Bool = true
    var muted: Bool = true
    var faceID: Bool = false
    var autoScroll: Bool = false
    var autoScrollDelay: Int = 6       // 3, 6, 10, 15 seconds (matches gooned.app Settings)
    var playVideosToEnd: Bool = true   // matches gooned.app Settings
    var tintedGlass: Bool = false      // Liquid Glass: Clear (default) vs Tinted
    var videoFitScreen: Bool = true    // Fit entire video on screen by default (prevents weird cropping)
    var controlsCollapsed: Bool = false // Collapses bottom-left UI & dock down out of the way
    var algorithmEnabled: Bool = true  // Smart on-device For You personalization algorithm

    enum CodingKeys: String, CodingKey {
        case hd, muted, faceID, autoScroll, autoScrollDelay, playVideosToEnd, tintedGlass, videoFitScreen, controlsCollapsed, algorithmEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hd = (try? c.decode(Bool.self, forKey: .hd)) ?? true
        muted = (try? c.decode(Bool.self, forKey: .muted)) ?? true
        faceID = (try? c.decode(Bool.self, forKey: .faceID)) ?? false
        autoScroll = (try? c.decode(Bool.self, forKey: .autoScroll)) ?? false
        autoScrollDelay = (try? c.decode(Int.self, forKey: .autoScrollDelay)) ?? 6
        playVideosToEnd = (try? c.decode(Bool.self, forKey: .playVideosToEnd)) ?? true
        tintedGlass = (try? c.decode(Bool.self, forKey: .tintedGlass)) ?? false
        videoFitScreen = (try? c.decode(Bool.self, forKey: .videoFitScreen)) ?? true
        controlsCollapsed = (try? c.decode(Bool.self, forKey: .controlsCollapsed)) ?? false
        algorithmEnabled = (try? c.decode(Bool.self, forKey: .algorithmEnabled)) ?? true
    }
}

struct AlgorithmProfile: Codable {
    var subredditWeights: [String: Double] = [:]
    var creatorWeights: [String: Double] = [:]
    var tagWeights: [String: Double] = [:]
    var boostedTags: [String] = []
    var blockedTags: [String] = []
    var videoPreference: Double = 0.5   // > 0.5 favors videos over static images
    var totalSignals: Int = 0

    enum CodingKeys: String, CodingKey {
        case subredditWeights, creatorWeights, tagWeights, boostedTags, blockedTags, videoPreference, totalSignals
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subredditWeights = (try? c.decode([String: Double].self, forKey: .subredditWeights)) ?? [:]
        creatorWeights = (try? c.decode([String: Double].self, forKey: .creatorWeights)) ?? [:]
        tagWeights = (try? c.decode([String: Double].self, forKey: .tagWeights)) ?? [:]
        boostedTags = (try? c.decode([String].self, forKey: .boostedTags)) ?? []
        blockedTags = (try? c.decode([String].self, forKey: .blockedTags)) ?? []
        videoPreference = (try? c.decode(Double.self, forKey: .videoPreference)) ?? 0.5
        totalSignals = (try? c.decode(Int.self, forKey: .totalSignals)) ?? 0
    }
}

struct RecentFeedEntry: Codable, Hashable, Identifiable {
    var id: String { "\(kind):\(name)" }
    var kind: String
    var name: String
    var displayTitle: String
    var swipedCount: Int
    var updatedAt: Date
}

struct UserData: Codable {
    var liked: [Gif] = []
    var downloaded: [Gif] = []
    var followedSubreddits: [String] = []
    var followedUsers: [String] = []
    var followedXUsers: [String] = []
    var followedIGUsers: [String] = []
    var followedOFCreators: [FollowedOFCreator] = []
    var recentFeeds: [RecentFeedEntry] = []
    var seenIDs: [String] = []
    var savedCursors: [String: String] = [:]
    var swipedTotal: Int = 0
    var settings = AppSettings()
    var xSession = XAccountSession()
    var igSession = InstagramAccountSession()
    var redditSession = RedditAccountSession()
    var r34Credentials = Rule34Credentials()
    var algorithm = AlgorithmProfile()
    var removedLikedIDs: [String: Double] = [:]
    var removedDownloadedIDs: [String: Double] = [:]
    var removedFollows: [String: Double] = [:]

    enum CodingKeys: String, CodingKey {
        case liked, downloaded, followedSubreddits, followedUsers, followedXUsers, followedIGUsers, followedOFCreators
        case recentFeeds, seenIDs, savedCursors, swipedTotal, settings, xSession, igSession, redditSession, r34Credentials, algorithm
        case removedLikedIDs, removedDownloadedIDs, removedFollows
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liked = (try? c.decode([Gif].self, forKey: .liked)) ?? []
        downloaded = (try? c.decode([Gif].self, forKey: .downloaded)) ?? []
        followedSubreddits = (try? c.decode([String].self, forKey: .followedSubreddits)) ?? []
        followedUsers = (try? c.decode([String].self, forKey: .followedUsers)) ?? []
        followedXUsers = (try? c.decode([String].self, forKey: .followedXUsers)) ?? []
        followedIGUsers = (try? c.decode([String].self, forKey: .followedIGUsers)) ?? []
        followedOFCreators = (try? c.decode([FollowedOFCreator].self, forKey: .followedOFCreators)) ?? []
        recentFeeds = (try? c.decode([RecentFeedEntry].self, forKey: .recentFeeds)) ?? []
        seenIDs = (try? c.decode([String].self, forKey: .seenIDs)) ?? []
        savedCursors = (try? c.decode([String: String].self, forKey: .savedCursors)) ?? [:]
        swipedTotal = (try? c.decode(Int.self, forKey: .swipedTotal)) ?? 0
        settings = (try? c.decode(AppSettings.self, forKey: .settings)) ?? AppSettings()
        xSession = (try? c.decode(XAccountSession.self, forKey: .xSession)) ?? XAccountSession()
        igSession = (try? c.decode(InstagramAccountSession.self, forKey: .igSession)) ?? InstagramAccountSession()
        redditSession = (try? c.decode(RedditAccountSession.self, forKey: .redditSession)) ?? RedditAccountSession()
        r34Credentials = (try? c.decode(Rule34Credentials.self, forKey: .r34Credentials)) ?? Rule34Credentials()
        algorithm = (try? c.decode(AlgorithmProfile.self, forKey: .algorithm)) ?? AlgorithmProfile()
        removedLikedIDs = (try? c.decode([String: Double].self, forKey: .removedLikedIDs)) ?? [:]
        removedDownloadedIDs = (try? c.decode([String: Double].self, forKey: .removedDownloadedIDs)) ?? [:]
        removedFollows = (try? c.decode([String: Double].self, forKey: .removedFollows)) ?? [:]
    }
}

@MainActor
final class UserStore: ObservableObject {
    static let shared = UserStore()

    private(set) var seenSet: Set<String>
    private var _seenIDs: [String]
    private var _savedCursors: [String: String]
    var localAddedTimestamps: [String: Double] = [:]
    @Published var data: UserData {
        didSet {
            let now = Date().timeIntervalSince1970
            if !oldValue.xSession.isConnected && data.xSession.isConnected {
                data.removedFollows.removeValue(forKey: "session:x")
                localAddedTimestamps["session:x"] = now
            }
            if !oldValue.igSession.isConnected && data.igSession.isConnected {
                data.removedFollows.removeValue(forKey: "session:ig")
                localAddedTimestamps["session:ig"] = now
            }
            if !oldValue.redditSession.isConnected && data.redditSession.isConnected {
                data.removedFollows.removeValue(forKey: "session:reddit")
                localAddedTimestamps["session:reddit"] = now
            }
            scheduleSave()
        }
    }
    @Published var categories: [GoonedCategory] = GoonedCategory.defaultCategories
    private var saveTask: Task<Void, Never>?
    private var suppressSaveDueToDecryptError = false
    private static let saveQueue = DispatchQueue(label: "tinytiny.userstore.save", qos: .utility)

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gooned_userdata.json")
    }

    init() {
        let loaded: UserData
        var decryptFailed = false
        if FileManager.default.fileExists(atPath: Self.fileURL.path),
           let raw = try? Data(contentsOf: Self.fileURL), !raw.isEmpty {
            if let decoded = CryptoBox.openCodable(UserData.self, from: raw) {
                loaded = decoded
            } else {
                // Preserve unreadable vault file as backup and do not overwrite with empty state
                let bak = Self.fileURL.appendingPathExtension("bak")
                if !FileManager.default.fileExists(atPath: bak.path) {
                    try? raw.write(to: bak, options: [.atomic, .completeFileProtection])
                }
                decryptFailed = true
                loaded = UserData()
            }
        } else {
            loaded = UserData()
        }
        self._seenIDs = loaded.seenIDs
        self.seenSet = Set(loaded.seenIDs)
        self._savedCursors = loaded.savedCursors
        self.suppressSaveDueToDecryptError = decryptFailed
        self.data = loaded
        sanitizeLearnedProfile()
        Self.configureAudioSession(muted: loaded.settings.muted)
        Task { await refreshCategories() }
    }

    static func configureAudioSession(muted: Bool) {
        Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            if muted {
                try? session.setCategory(.ambient, mode: .moviePlayback, options: [.mixWithOthers])
            } else {
                try? session.setCategory(.playback, mode: .moviePlayback, options: [])
                try? session.setActive(true)
            }
        }
    }

    func refreshCategories() async {
        if let remote = try? await GoonedAPI.shared.categories(), !remote.isEmpty {
            self.categories = remote
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func exportSnapshotForBackup() -> UserData {
        var snapshot = data
        snapshot.seenIDs = _seenIDs
        snapshot.savedCursors = _savedCursors
        return snapshot
    }

    func replaceAllData(_ newData: UserData) {
        suppressSaveDueToDecryptError = false
        _seenIDs = newData.seenIDs
        seenSet = Set(newData.seenIDs)
        _savedCursors = newData.savedCursors
        data = newData
    }

    func saveNow() {
        guard !suppressSaveDueToDecryptError else { return }
        var snapshot = data
        snapshot.seenIDs = _seenIDs
        snapshot.savedCursors = _savedCursors
        let url = Self.fileURL
        Self.saveQueue.async {
            if let raw = CryptoBox.sealCodable(snapshot) {
                try? raw.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
    }

    func markSeenBulk(_ ids: [String]) {
        var addedAny = false
        for id in ids where !id.isEmpty && seenSet.insert(id).inserted {
            _seenIDs.append(id)
            addedAny = true
        }
        if _seenIDs.count > 12_000 {
            let overflow = _seenIDs.count - 10_000
            for old in _seenIDs.prefix(overflow) { seenSet.remove(old) }
            _seenIDs.removeFirst(overflow)
        }
        if addedAny { scheduleSave() }
    }

    struct WipeOptions {
        var keepLikes: Bool = true
        var keepFollowing: Bool = true
        var keepOfflineVault: Bool = true
        var keepAccounts: Bool = true
        var keepAlgorithm: Bool = true
        var keepPasscode: Bool = true
    }

    func performSelectiveWipe(options: WipeOptions, app: AppState) async {
        // 1. Preserve only chosen slices of UserData; record tombstones for wiped slices so cloud sync doesn't resurrect them
        let now = Date().timeIntervalSince1970
        var fresh = UserData()
        fresh.removedLikedIDs = data.removedLikedIDs
        fresh.removedDownloadedIDs = data.removedDownloadedIDs
        fresh.removedFollows = data.removedFollows
        if options.keepLikes {
            fresh.liked = data.liked
        } else {
            for item in data.liked { fresh.removedLikedIDs[item.id] = now }
            trimTombstones(&fresh.removedLikedIDs)
        }
        if options.keepFollowing {
            fresh.followedUsers = data.followedUsers
            fresh.followedSubreddits = data.followedSubreddits
            fresh.followedXUsers = data.followedXUsers
            fresh.followedIGUsers = data.followedIGUsers
            fresh.followedOFCreators = data.followedOFCreators
        } else {
            for u in data.followedUsers { fresh.removedFollows["u:\(u.lowercased())"] = now }
            for s in data.followedSubreddits { fresh.removedFollows["sub:\(s.lowercased())"] = now }
            for x in data.followedXUsers { fresh.removedFollows["x:\(x.lowercased())"] = now }
            for ig in data.followedIGUsers { fresh.removedFollows["ig:\(ig.lowercased())"] = now }
            for of in data.followedOFCreators { fresh.removedFollows["of:\(of.id.lowercased())"] = now }
            trimTombstones(&fresh.removedFollows)
        }
        if options.keepOfflineVault {
            fresh.downloaded = data.downloaded
        } else {
            for item in data.downloaded { fresh.removedDownloadedIDs[item.id] = now }
            trimTombstones(&fresh.removedDownloadedIDs)
        }
        if options.keepAccounts {
            fresh.xSession = data.xSession
            fresh.igSession = data.igSession
            fresh.redditSession = data.redditSession
            fresh.r34Credentials = data.r34Credentials
        }
        if options.keepAlgorithm {
            fresh.algorithm = data.algorithm
        }

        // 2. Clear seen history, cursors, and in-memory caches
        suppressSaveDueToDecryptError = false
        localAddedTimestamps.removeAll()
        _seenIDs = []
        seenSet = []
        _savedCursors = [:]
        data = fresh

        if !options.keepAlgorithm {
            SmartTasteEngine.shared.reset()
        }
        if !options.keepOfflineVault {
            OfflineManager.shared.clearAllDownloads()
        }
        if !options.keepPasscode {
            app.removePasscodeKeepingData()
        }

        MediaImageLoader.shared.clearCache()
        VideoPreloader.shared.clearCache()
        URLCache.shared.removeAllCachedResponses()

        // 3. Clear FeedDiskCache, tmp media, and legacy files from older app versions (never touch License!)
        let fm = FileManager.default
        if let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let feedCache = cachesDir.appendingPathComponent("FeedCache", isDirectory: true)
            let legacyCache = cachesDir.appendingPathComponent("FeedDiskCache", isDirectory: true)
            try? fm.removeItem(at: feedCache)
            try? fm.removeItem(at: legacyCache)
        }
        if let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
        if let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
           let docItems = try? fm.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: nil) {
            let protectedNames: Set<String> = ["gooned_userdata.json", "gooned_taste_v2.json", "OfflineVault"]
            for item in docItems where !protectedNames.contains(item.lastPathComponent) {
                try? fm.removeItem(at: item)
            }
        }

        // 4. Sweep legacy UserDefaults keys from older versions while keeping License/Onboarding/Passcode state
        let preservedDefaults: Set<String> = [
            "ageConfirmed", "tt.onboardingCompleted", "tt.passcodeChoiceCompleted",
            "tt.requirePasscodeOnOpen", "tinytiny.dismissed.announcement", "tt.passcode.lockedUntil"
        ]
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if !preservedDefaults.contains(key) && (key.hasPrefix("tt.") || key.hasPrefix("tt_") || key.hasPrefix("tinytiny.") || key.hasPrefix("gooned")) {
                if options.keepOfflineVault && key == "tt_saved_photo_asset_ids_v1" { continue }
                if options.keepAlgorithm && key == "tinytiny.of.hidden_genders.v1" { continue }
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // 5. Clear WebKit cookies/storage if Connected Accounts are being wiped
        if !options.keepAccounts {
            let dataStore = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            let records = await dataStore.dataRecords(ofTypes: types)
            await dataStore.removeData(ofTypes: types, for: records)
        }

        saveNow()
    }

    // MARK: - Seen History & Cursor Rotation (Prevents Repeating Videos)

    func isSeen(_ id: String) -> Bool {
        seenSet.contains(id)
    }

    func isSeen(_ post: Gif) -> Bool {
        seenSet.contains(post.id)
            || seenSet.contains(post.canonicalDedupeKey)
            || SmartTasteEngine.shared.isSeenOrDuplicate(post)
    }

    func markSeen(_ post: Gif) {
        markSeen(post.id)
        markSeen(post.canonicalDedupeKey)
        SmartTasteEngine.shared.markSeenSimilarity(post)
    }

    func markSeen(_ id: String) {
        guard !id.isEmpty, seenSet.insert(id).inserted else { return }
        _seenIDs.append(id)
        if _seenIDs.count > 12_000 {
            let overflow = _seenIDs.count - 10_000
            let removed = _seenIDs.prefix(overflow)
            for r in removed { seenSet.remove(r) }
            _seenIDs.removeFirst(overflow)
        }
        scheduleSave()
    }

    @discardableResult
    func dislike(_ post: Gif) -> SmartTasteEngine.DislikeOutcome {
        markSeen(post)
        let outcome = SmartTasteEngine.shared.recordDislike(post, categories: categories)
        recordAlgorithmSignal(for: post, weight: -8.0)
        return outcome
    }

    @discardableResult
    func applyCreatorDislikeResolution(for post: Gif, gender: String?, creatorTags: [String]) -> SmartTasteEngine.DislikeOutcome {
        SmartTasteEngine.shared.applyCreatorDislikeResolution(
            for: post,
            gender: gender,
            creatorTags: creatorTags,
            categories: categories
        )
    }

    func savedCursor(for key: String) -> String? {
        _savedCursors[key]
    }

    func setSavedCursor(_ cursor: String?, for key: String) {
        if let cursor, !cursor.isEmpty {
            _savedCursors[key] = cursor
        } else {
            _savedCursors.removeValue(forKey: key)
        }
        scheduleSave()
    }

    func clearSeenHistory() {
        seenSet.removeAll()
        _seenIDs.removeAll()
        _savedCursors.removeAll()
        data.seenIDs.removeAll()
        data.savedCursors.removeAll()
        saveNow()
    }

    // MARK: - Likes (Stash) & Offline Downloads

    func isLiked(_ g: Gif) -> Bool {
        data.liked.contains { $0.id == g.id }
    }

    private func trimTombstones(_ map: inout [String: Double], maxCount: Int = 400) {
        if map.count > maxCount {
            let keep = map.sorted { $0.value > $1.value }.prefix(maxCount)
            map = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    func toggleLike(_ g: Gif) {
        let now = Date().timeIntervalSince1970
        if let i = data.liked.firstIndex(where: { $0.id == g.id }) {
            data.liked.remove(at: i)
            data.removedLikedIDs[g.id] = now
            localAddedTimestamps.removeValue(forKey: "like:\(g.id)")
            trimTombstones(&data.removedLikedIDs)
            recordAlgorithmSignal(for: g, weight: -2.5)
        } else {
            data.liked.insert(g, at: 0)
            data.removedLikedIDs.removeValue(forKey: g.id)
            localAddedTimestamps["like:\(g.id)"] = now
            recordAlgorithmSignal(for: g, weight: 5.0)
        }
        LicenseManager.shared.scheduleCloudSync()
    }

    func like(_ g: Gif) {
        if !isLiked(g) { toggleLike(g) }
    }

    func recordDownload(_ g: Gif) {
        let now = Date().timeIntervalSince1970
        if let i = data.downloaded.firstIndex(where: { $0.id == g.id }) {
            data.downloaded[i] = g
        } else {
            data.downloaded.insert(g, at: 0)
            recordAlgorithmSignal(for: g, weight: 6.5)
        }
        data.removedDownloadedIDs.removeValue(forKey: g.id)
        localAddedTimestamps["dl:\(g.id)"] = now
        LicenseManager.shared.scheduleCloudSync()
    }

    func removeDownloadedRecord(_ g: Gif) {
        let now = Date().timeIntervalSince1970
        data.downloaded.removeAll { $0.id == g.id }
        data.removedDownloadedIDs[g.id] = now
        localAddedTimestamps.removeValue(forKey: "dl:\(g.id)")
        trimTombstones(&data.removedDownloadedIDs)
        LicenseManager.shared.scheduleCloudSync()
    }

    func clearAllDownloadedRecords() {
        let now = Date().timeIntervalSince1970
        for g in data.downloaded {
            data.removedDownloadedIDs[g.id] = now
            localAddedTimestamps.removeValue(forKey: "dl:\(g.id)")
        }
        trimTombstones(&data.removedDownloadedIDs)
        data.downloaded.removeAll()
        saveNow()
        LicenseManager.shared.scheduleCloudSync()
    }

    // MARK: - Follows (Subreddits, Reddit Creators, X Creators & Instagram Creators)

    func isFollowingSubreddit(_ sub: String) -> Bool {
        data.followedSubreddits.contains { $0.caseInsensitiveCompare(sub) == .orderedSame }
    }

    func toggleFollowSubreddit(_ sub: String) {
        let clean = sub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let key = "sub:\(clean.lowercased())"
        let now = Date().timeIntervalSince1970
        if let i = data.followedSubreddits.firstIndex(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            data.followedSubreddits.remove(at: i)
            data.removedFollows[key] = now
            localAddedTimestamps.removeValue(forKey: "follow:\(key)")
            trimTombstones(&data.removedFollows)
        } else {
            data.followedSubreddits.insert(clean, at: 0)
            data.removedFollows.removeValue(forKey: key)
            localAddedTimestamps["follow:\(key)"] = now
        }
        LicenseManager.shared.scheduleCloudSync()
    }

    func isFollowingUser(_ user: String) -> Bool {
        data.followedUsers.contains { $0.caseInsensitiveCompare(user) == .orderedSame }
    }

    func toggleFollowUser(_ user: String) {
        let clean = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let key = "u:\(clean.lowercased())"
        let now = Date().timeIntervalSince1970
        if let i = data.followedUsers.firstIndex(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            data.followedUsers.remove(at: i)
            data.removedFollows[key] = now
            localAddedTimestamps.removeValue(forKey: "follow:\(key)")
            trimTombstones(&data.removedFollows)
        } else {
            data.followedUsers.insert(clean, at: 0)
            data.removedFollows.removeValue(forKey: key)
            localAddedTimestamps["follow:\(key)"] = now
        }
        LicenseManager.shared.scheduleCloudSync()
    }

    func isFollowingXUser(_ handle: String) -> Bool {
        let clean = handle.replacingOccurrences(of: "@", with: "")
        return data.followedXUsers.contains { $0.caseInsensitiveCompare(clean) == .orderedSame }
    }

    func toggleFollowXUser(_ handle: String) {
        let clean = handle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        guard !clean.isEmpty else { return }
        let key = "x:\(clean.lowercased())"
        let now = Date().timeIntervalSince1970
        if let i = data.followedXUsers.firstIndex(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            data.followedXUsers.remove(at: i)
            data.removedFollows[key] = now
            localAddedTimestamps.removeValue(forKey: "follow:\(key)")
            trimTombstones(&data.removedFollows)
        } else {
            data.followedXUsers.insert(clean, at: 0)
            data.removedFollows.removeValue(forKey: key)
            localAddedTimestamps["follow:\(key)"] = now
        }
        LicenseManager.shared.scheduleCloudSync()
    }

    func isFollowingIGUser(_ handle: String) -> Bool {
        let clean = handle.replacingOccurrences(of: "@", with: "")
        return data.followedIGUsers.contains { $0.caseInsensitiveCompare(clean) == .orderedSame }
    }

    func toggleFollowIGUser(_ handle: String) {
        let clean = handle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        guard !clean.isEmpty else { return }
        let key = "ig:\(clean.lowercased())"
        let now = Date().timeIntervalSince1970
        if let i = data.followedIGUsers.firstIndex(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            data.followedIGUsers.remove(at: i)
            data.removedFollows[key] = now
            localAddedTimestamps.removeValue(forKey: "follow:\(key)")
            trimTombstones(&data.removedFollows)
        } else {
            data.followedIGUsers.insert(clean, at: 0)
            data.removedFollows.removeValue(forKey: key)
            localAddedTimestamps["follow:\(key)"] = now
        }
        LicenseManager.shared.scheduleCloudSync()
    }

    func isFollowingOFCreator(id: String?, handle: String?) -> Bool {
        if let id, !id.isEmpty, data.followedOFCreators.contains(where: { $0.id == id }) {
            return true
        }
        if let handle, !handle.isEmpty {
            let clean = handle.replacingOccurrences(of: "@", with: "")
            return data.followedOFCreators.contains { $0.name.caseInsensitiveCompare(clean) == .orderedSame }
        }
        return false
    }

    func toggleFollowOFCreator(id: String, name: String, displayName: String? = nil) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }
        let key = "of:\(cleanId.lowercased())"
        let now = Date().timeIntervalSince1970
        if let idx = data.followedOFCreators.firstIndex(where: { $0.id == cleanId || $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }) {
            let removed = data.followedOFCreators.remove(at: idx)
            let remKey = "of:\(removed.id.lowercased())"
            data.removedFollows[remKey] = now
            localAddedTimestamps.removeValue(forKey: "follow:\(remKey)")
            trimTombstones(&data.removedFollows)
        } else {
            data.followedOFCreators.insert(
                FollowedOFCreator(id: cleanId, name: cleanName.isEmpty ? cleanId : cleanName, displayName: displayName),
                at: 0
            )
            data.removedFollows.removeValue(forKey: key)
            localAddedTimestamps["follow:\(key)"] = now
        }
        LicenseManager.shared.scheduleCloudSync()
    }

    /// Toggles follow locally AND syncs Follow/Unfollow on the user's connected X or Instagram account.
    func toggleFollowAndSync(for post: Gif) {
        if post.isOnlyFansPost, let cid = post.onlyFansCreatorId {
            toggleFollowOFCreator(id: cid, name: post.author ?? cid)
        } else if post.isXPost, let u = post.author {
            toggleFollowXUser(u)
            let shouldUnfollow = !isFollowingXUser(u)
            if data.xSession.isConnected {
                Task { _ = await XWebEngine.shared.followUser(u, unfollow: shouldUnfollow) }
            }
        } else if post.isIGPost, let u = post.author {
            toggleFollowIGUser(u)
            let shouldUnfollow = !isFollowingIGUser(u)
            if data.igSession.isConnected {
                Task { _ = await InstagramWebEngine.shared.followUser(u, unfollow: shouldUnfollow) }
            }
        } else if let sub = post.subreddit {
            toggleFollowSubreddit(sub)
        } else if let u = post.author {
            toggleFollowUser(u)
        }
    }

    func updateXSession(_ session: XAccountSession) {
        let now = Date().timeIntervalSince1970
        var next = data
        next.xSession = session
        if session.isConnected {
            next.removedFollows.removeValue(forKey: "session:x")
            localAddedTimestamps["session:x"] = now
        }
        data = next
        saveNow()
        LicenseManager.shared.scheduleCloudSync()
    }

    func disconnectX() {
        let now = Date().timeIntervalSince1970
        var next = data
        next.xSession = XAccountSession()
        next.removedFollows["session:x"] = now
        trimTombstones(&next.removedFollows)
        localAddedTimestamps.removeValue(forKey: "session:x")
        data = next
        saveNow()
        LicenseManager.shared.scheduleCloudSync()
        Task {
            await XWebEngine.shared.resetSession()
            await XWebEngine.home.resetSession()
        }
    }

    func updateIGSession(_ session: InstagramAccountSession) {
        let now = Date().timeIntervalSince1970
        var next = data
        next.igSession = session
        if session.isConnected {
            next.removedFollows.removeValue(forKey: "session:ig")
            localAddedTimestamps["session:ig"] = now
        }
        data = next
        saveNow()
        LicenseManager.shared.scheduleCloudSync()
    }

    func disconnectIG() {
        let now = Date().timeIntervalSince1970
        var next = data
        next.igSession = InstagramAccountSession()
        next.removedFollows["session:ig"] = now
        trimTombstones(&next.removedFollows)
        localAddedTimestamps.removeValue(forKey: "session:ig")
        data = next
        saveNow()
        LicenseManager.shared.scheduleCloudSync()
        Task { await InstagramWebEngine.shared.resetSession() }
    }

    func updateRedditSession(_ session: RedditAccountSession) {
        let now = Date().timeIntervalSince1970
        var next = data
        next.redditSession = session
        if session.isConnected {
            next.removedFollows.removeValue(forKey: "session:reddit")
            localAddedTimestamps["session:reddit"] = now
        }
        data = next
        saveNow()
        LicenseManager.shared.scheduleCloudSync()
    }

    func disconnectReddit() {
        let now = Date().timeIntervalSince1970
        var next = data
        next.redditSession = RedditAccountSession()
        next.removedFollows["session:reddit"] = now
        trimTombstones(&next.removedFollows)
        localAddedTimestamps.removeValue(forKey: "session:reddit")
        data = next
        saveNow()
        LicenseManager.shared.scheduleCloudSync()
        Task { await RedditPersonalAPI.clearCookies() }
    }

    // MARK: - Pick Up Where You Left Off (Swipe Tracking)

    func recordSwipe(kind: String, name: String, displayTitle: String, postID: String? = nil) {
        if let postID { markSeen(postID) }
        var next = data
        next.swipedTotal += 1
        if let idx = next.recentFeeds.firstIndex(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            var entry = next.recentFeeds.remove(at: idx)
            entry.swipedCount += 1
            entry.updatedAt = Date()
            next.recentFeeds.insert(entry, at: 0)
        } else {
            let entry = RecentFeedEntry(kind: kind, name: name, displayTitle: displayTitle, swipedCount: 1, updatedAt: Date())
            next.recentFeeds.insert(entry, at: 0)
        }
        if next.recentFeeds.count > 8 {
            next.recentFeeds = Array(next.recentFeeds.prefix(8))
        }
        data = next
    }

    // MARK: - Porn-Specific Preference Learning & Content Filtering

    private func sanitizeLearnedProfile() {
        var normalizedTags: [String: Double] = [:]
        for (rawKey, weight) in data.algorithm.tagWeights {
            let clean = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "#", with: "")
            guard abs(weight) > 0.2, !clean.isEmpty, !MediaMetaRegistry.isStopTag(clean) else { continue }
            let canonical = PornTagCatalog.normalize(clean, categories: categories) ?? clean
            guard !MediaMetaRegistry.isStopTag(canonical) else { continue }
            normalizedTags[canonical] = min(max((normalizedTags[canonical] ?? 0) + weight, -12), 45)
        }
        data.algorithm.tagWeights = normalizedTags
        data.algorithm.boostedTags.removeAll { MediaMetaRegistry.isStopTag($0) }
        data.algorithm.blockedTags.removeAll { MediaMetaRegistry.isStopTag($0) }
    }

    func recordAlgorithmSignal(for post: Gif, weight: Double) {
        guard data.settings.algorithmEnabled else { return }

        SmartTasteEngine.shared.ingestPostIntoCreatorGraph(post, categories: categories)

        // Batch all algorithm mutations into a single UserData assignment to avoid SwiftUI re-render storms
        var next = data
        next.algorithm.totalSignals += 1
        if next.algorithm.totalSignals % 35 == 0 {
            next.algorithm.subredditWeights = next.algorithm.subredditWeights.mapValues { $0 * 0.92 }.filter { abs($0.value) > 0.2 }
            next.algorithm.creatorWeights = next.algorithm.creatorWeights.mapValues { $0 * 0.92 }.filter { abs($0.value) > 0.2 }
            next.algorithm.tagWeights = next.algorithm.tagWeights.mapValues { $0 * 0.92 }.filter { abs($0.value) > 0.2 }
        }

        if let sub = post.subreddit?.lowercased(), !sub.isEmpty,
           !AdultContentClassifier.sfwBlockedSubreddits.contains(sub),
           !MediaMetaRegistry.isStopTag(sub) {
            let cur = next.algorithm.subredditWeights[sub] ?? 0
            next.algorithm.subredditWeights[sub] = min(max(cur + weight, -12), 45)
        }
        if let author = post.author?.lowercased(), !author.isEmpty,
           !["instagram", "x_user", "rule34", "eporner", "pornhub", "xhamster", "spankbang", "xvideos"].contains(author) {
            let cur = next.algorithm.creatorWeights[author] ?? 0
            next.algorithm.creatorWeights[author] = min(max(cur + weight * 1.15, -12), 45)
        }

        let recognized = SmartTasteEngine.extractExtendedTags(from: post, categories: categories)
        for tag in recognized where !MediaMetaRegistry.isStopTag(tag) {
            let cur = next.algorithm.tagWeights[tag] ?? 0
            if weight < 0 {
                let isPinned = next.algorithm.boostedTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                if isPinned || cur >= 3.0 {
                    continue
                }
                if SmartTasteEngine.protectedBroadTags.contains(tag) {
                    continue
                }
            }
            let updated = min(max(cur + weight * 0.85, -12), 45)
            if abs(updated) < 0.15 {
                next.algorithm.tagWeights.removeValue(forKey: tag)
            } else {
                next.algorithm.tagWeights[tag] = updated
            }
        }

        let target: Double = post.isImage ? (weight > 0 ? 0.0 : 1.0) : (weight > 0 ? 1.0 : 0.0)
        let alpha = weight > 0 ? 0.06 : 0.02
        next.algorithm.videoPreference = min(max(next.algorithm.videoPreference + (target - next.algorithm.videoPreference) * alpha, 0.1), 0.95)
        data = next
        if weight > 0 {
            SmartTasteEngine.shared.recordPositiveEngagement(for: post, intensity: weight, categories: categories)
        }
    }

    func recordDwellSignal(for post: Gif, secondsWatched: TimeInterval) {
        if secondsWatched >= 9.0 {
            recordAlgorithmSignal(for: post, weight: 3.2)
        } else if secondsWatched >= 3.8 {
            recordAlgorithmSignal(for: post, weight: 1.6)
        } else if secondsWatched < 1.6 {
            // Immediate skip reduces relevance without hurting pinned/loved tags
            recordAlgorithmSignal(for: post, weight: -1.1)
            SmartTasteEngine.shared.recordFastSkip(for: post, categories: categories)
        }
    }

    func recordLoopSignal(for post: Gif) {
        // Repeatedly watching / looping a clip is the strongest implicit positive signal (like IG Reels / TikTok)
        recordAlgorithmSignal(for: post, weight: 3.8)
    }

    func recordSearchSignal(_ rawQuery: String) {
        guard data.settings.algorithmEnabled else { return }
        var matched = PornTagCatalog.extractRecognizedTags(fromQuery: rawQuery, categories: categories)
        let customTokens = Rule34API.parseTags(rawQuery).filter { !MediaMetaRegistry.isStopTag($0) }
        for tok in customTokens where !matched.contains(tok) {
            matched.append(tok)
        }
        guard !matched.isEmpty else { return }
        data.algorithm.totalSignals += 1
        for tag in matched where !MediaMetaRegistry.isStopTag(tag) {
            let cur = data.algorithm.tagWeights[tag] ?? 0
            data.algorithm.tagWeights[tag] = min(max(cur + 4.5, -12), 45)
        }
    }

    func adjustLearnedTag(_ tag: String, delta: Double) {
        let key = PornTagCatalog.normalize(tag, categories: categories) ?? tag.lowercased()
        let next = (data.algorithm.tagWeights[key] ?? 0) + delta
        if next <= 0.25 {
            data.algorithm.tagWeights.removeValue(forKey: key)
        } else {
            data.algorithm.tagWeights[key] = min(next, 45)
        }
    }

    func scorePost(_ post: Gif) -> Double {
        guard data.settings.algorithmEnabled else { return 0 }
        var score = 0.0
        let subLower = post.subreddit?.lowercased() ?? ""
        let authorLower = post.author?.lowercased() ?? ""
        let titleLower = post.title?.lowercased() ?? ""

        if !subLower.isEmpty {
            score += (data.algorithm.subredditWeights[subLower] ?? 0) * 1.4
            if isFollowingSubreddit(subLower) { score += 3.5 }
        }
        if !authorLower.isEmpty {
            score += (data.algorithm.creatorWeights[authorLower] ?? 0) * 1.6
            if isFollowingUser(authorLower) || isFollowingXUser(authorLower) || isFollowingIGUser(authorLower) {
                score += 4.0
            }
        }

        let recognizedTags = SmartTasteEngine.extractExtendedTags(from: post, categories: categories)
        for tag in recognizedTags {
            let direct = data.algorithm.tagWeights[tag] ?? 0
            score += direct * 1.9

            // Cross-tag cluster synergy: consistent interest in related categories boosts companion tags
            if let related = PornTagCatalog.relatedTags[tag] {
                var clusterBonus = 0.0
                for rel in related {
                    let relWeight = data.algorithm.tagWeights[rel] ?? 0
                    if relWeight >= 2.5 {
                        clusterBonus += relWeight * 0.32
                    }
                }
                score += min(clusterBonus, 7.0)
            }
        }

        for pinned in data.algorithm.boostedTags {
            let p = pinned.lowercased()
            let cleanP = p.replacingOccurrences(of: "_", with: "")
            let spacedP = p.replacingOccurrences(of: "_", with: " ")
            let canonicalPinned = PornTagCatalog.normalize(p, categories: categories) ?? p
            if recognizedTags.contains(canonicalPinned)
                || recognizedTags.contains(p)
                || subLower.contains(cleanP)
                || authorLower.contains(cleanP)
                || titleLower.contains(p)
                || titleLower.contains(cleanP)
                || titleLower.contains(spacedP) {
                score += 48.0
            }
        }
        if !post.isImage {
            score += (data.algorithm.videoPreference - 0.5) * 4.0
        }
        if let up = post.upvotes, up > 0 {
            score += min(log10(Double(up)) * 0.55, 2.2)
        }
        score += SmartTasteEngine.shared.scoreAdjustment(for: post, categories: categories)
        return score
    }

    func isBlockedByAlgorithm(_ post: Gif) -> Bool {
        if SmartTasteEngine.shared.isDisliked(post) { return true }
        guard data.settings.algorithmEnabled else { return false }
        if SmartTasteEngine.shared.isSuppressedInDiscovery(post, categories: categories) { return true }
        guard !data.algorithm.blockedTags.isEmpty else { return false }
        let sub = post.subreddit?.lowercased() ?? ""
        let author = post.author?.lowercased() ?? ""
        let title = post.title?.lowercased() ?? ""
        let postTags = Set(SmartTasteEngine.extractExtendedTags(from: post, categories: categories))
        for blocked in data.algorithm.blockedTags {
            let b = blocked.lowercased()
            let canonicalBlocked = PornTagCatalog.normalize(b, categories: categories) ?? b
            if !b.isEmpty && (postTags.contains(canonicalBlocked) || sub.contains(b) || author.contains(b) || title.contains(b)) {
                return true
            }
        }
        return false
    }

    func addBoostedTags(_ rawInput: String) {
        let parsed = Rule34API.parseTags(rawInput)
        for tag in parsed {
            let key = PornTagCatalog.normalize(tag, categories: categories) ?? tag
            if !data.algorithm.boostedTags.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                data.algorithm.boostedTags.insert(key, at: 0)
            }
            data.algorithm.tagWeights[key] = max(data.algorithm.tagWeights[key] ?? 0, 15.0)
            let subKey = key.replacingOccurrences(of: "_", with: "")
            if !subKey.isEmpty {
                data.algorithm.subredditWeights[subKey] = max(data.algorithm.subredditWeights[subKey] ?? 0, 10.0)
            }
        }
    }

    func removeBoostedTag(_ tag: String) {
        let lower = tag.lowercased()
        let norm = PornTagCatalog.normalize(lower, categories: categories) ?? lower
        data.algorithm.boostedTags.removeAll { $0.lowercased() == lower || $0.lowercased() == norm }
        data.algorithm.tagWeights.removeValue(forKey: norm)
        data.algorithm.tagWeights.removeValue(forKey: lower)
        let subKey = norm.replacingOccurrences(of: "_", with: "")
        data.algorithm.subredditWeights.removeValue(forKey: subKey)
    }

    func removeLearnedSubreddit(_ sub: String) {
        data.algorithm.subredditWeights.removeValue(forKey: sub.lowercased())
    }

    func removeLearnedTag(_ tag: String) {
        data.algorithm.tagWeights.removeValue(forKey: tag.lowercased())
    }

    func addBlockedTags(_ rawInput: String) {
        let parsed = Rule34API.parseTags(rawInput)
        for tag in parsed {
            let key = PornTagCatalog.normalize(tag, categories: categories) ?? tag
            if !data.algorithm.blockedTags.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                data.algorithm.blockedTags.insert(key, at: 0)
            }
            data.algorithm.tagWeights.removeValue(forKey: key)
            data.algorithm.tagWeights.removeValue(forKey: tag)
        }
    }

    func removeBlockedTag(_ tag: String) {
        let lower = tag.lowercased()
        data.algorithm.blockedTags.removeAll { $0.lowercased() == lower }
    }

    /// Ranks posts using an 80/20 Exploit-Explore mix so For You feels personalized yet never repetitive.
    func rankWithAlgorithm(_ posts: [Gif]) -> [Gif] {
        SmartTasteEngine.shared.ingestPostsIntoCreatorGraph(posts, categories: categories)
        SmartTasteEngine.shared.precomputeVisualSimilarity(for: posts)
        guard data.settings.algorithmEnabled, posts.count > 3 else {
            return posts.shuffled()
        }
        let scored = posts.map { ($0, scorePost($0) + Double.random(in: -0.65...0.65)) }
            .sorted { $0.1 > $1.1 }

        // Separate high-affinity matches from discovery posts, interleaving 1 discovery post every 4 items
        let splitIdx = max(1, (scored.count * 3) / 4)
        var topPool = Array(scored.prefix(splitIdx).map(\.0))
        var explorePool = Array(scored.dropFirst(splitIdx).map(\.0)).shuffled()

        var result: [Gif] = []
        var counter = 0
        while !topPool.isEmpty || !explorePool.isEmpty {
            if counter % 4 == 3, let exp = explorePool.first {
                explorePool.removeFirst()
                result.append(exp)
            } else if let top = topPool.first {
                topPool.removeFirst()
                result.append(top)
            } else if let exp = explorePool.first {
                explorePool.removeFirst()
                result.append(exp)
            }
            counter += 1
        }
        return result
    }

    var topAlgorithmSubreddits: [String] {
        var combined: [String] = []
        for pinned in data.algorithm.boostedTags {
            let key = PornTagCatalog.normalize(pinned, categories: categories) ?? pinned
            if let cat = categories.first(where: { $0.name.lowercased() == key.replacingOccurrences(of: "_", with: "") }),
               let sub = cat.subreddits.first,
               !combined.contains(sub) {
                combined.append(sub)
            } else {
                let clean = key.replacingOccurrences(of: "_", with: "")
                if !clean.isEmpty && !combined.contains(clean) { combined.append(clean) }
            }
        }
        let learned = data.algorithm.subredditWeights
            .filter { $0.value > 1.5 }
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)
        for s in learned where !combined.contains(s) {
            combined.append(s)
        }
        return Array(combined.prefix(6))
    }

    var topAlgorithmTags: [(tag: String, score: Double)] {
        data.algorithm.tagWeights
            .filter { $0.value > 0.6 }
            .sorted { $0.value > $1.value }
            .prefix(16)
            .map { (tag: $0.key, score: $0.value) }
    }

    var topAlgorithmSubredditEntries: [(name: String, score: Double)] {
        data.algorithm.subredditWeights
            .filter { $0.value > 0.8 }
            .sorted { $0.value > $1.value }
            .prefix(12)
            .map { (name: $0.key, score: $0.value) }
    }

    var topTasteSummary: String {
        let pinned = data.algorithm.boostedTags.prefix(3).map { PornTagCatalog.displayTitle(for: $0) }
        if !pinned.isEmpty { return pinned.joined(separator: " · ") }
        let tags = data.algorithm.tagWeights.filter { $0.value > 1.0 }.sorted { $0.value > $1.value }.prefix(3).map { PornTagCatalog.displayTitle(for: $0.key) }
        if !tags.isEmpty { return tags.joined(separator: " · ") }
        let subs = topAlgorithmSubreddits.prefix(3).map { "r/\($0)" }
        if !subs.isEmpty { return subs.joined(separator: " · ") }
        return "Learning from your likes, loops & watch time"
    }

    func resetAlgorithm() {
        data.algorithm = AlgorithmProfile()
        SmartTasteEngine.shared.reset()
    }

    var seenCount: Int { seenSet.count }

    func eraseAll() {
        suppressSaveDueToDecryptError = false
        localAddedTimestamps.removeAll()
        seenSet.removeAll()
        _seenIDs.removeAll()
        _savedCursors.removeAll()
        SmartTasteEngine.shared.reset()
        OfflineManager.shared.clearAllDownloads()
        var fresh = UserData()
        fresh.r34Credentials.resetToDefault()
        data = fresh
        // Cancel the debounced save scheduled by `data = fresh` so the file isn't recreated
        saveTask?.cancel()
        saveTask = nil
        let url = Self.fileURL
        Self.saveQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
        Task {
            await XWebEngine.shared.resetSession()
            await InstagramWebEngine.shared.resetSession()
            await RedditPersonalAPI.clearCookies()
        }
    }
}

// MARK: - Canonical Porn-Specific Category & Tag Catalog

enum PornTagCatalog {
    static let quickPickerCategories: [String] = [
        "ebony", "femboy", "trans_woman", "futanari", "goth", "hentai", "latina", "asian",
        "milf", "petite", "curvy", "big_tits", "ass", "anal", "blowjob", "creampie",
        "cumshot", "ahegao", "cosplay", "bdsm", "femdom", "lesbian",
        "threesome", "public", "squirt", "interracial", "pawg", "redhead"
    ]

    static let canonicalTags: Set<String> = [
        "ebony", "femboy", "trans", "trans_woman", "trans_man", "futanari", "hentai", "ahegao", "cosplay",
        "goth", "bimbo", "milf", "mature", "teen", "petite", "curvy", "thick", "pawg",
        "bbw", "latina", "asian", "jav", "indian", "interracial", "bbc", "redhead",
        "blonde", "brunette", "amateur", "homemade",
        "lesbian", "gay", "yaoi", "bara", "twink", "bisexual", "threesome", "gangbang", "cuckold", "hotwife",
        "freeuse", "public", "pov", "solo", "masturbation", "joi", "vintage", "anal", "ass",
        "twerk", "big_tits", "boobs", "natural_tits", "blowjob", "deepthroat", "facefuck",
        "handjob", "titfuck", "paizuri", "creampie", "breeding", "cumshot", "facial",
        "cumslut", "squirt", "orgasm", "grool", "pussy", "innie", "gape", "fisting", "bdsm",
        "bondage", "femdom", "pegging", "facesitting", "spanking", "choking", "rough",
        "hardcore", "feet", "footjob", "stockings", "thigh_highs", "lingerie", "latex",
        "upskirt", "flashing", "oil", "tentacle", "hypno", "monster_girl", "elf",
        "succubus", "bunny_girl", "maid", "nurse", "flexible", "riding", "cowgirl",
        "doggystyle", "missionary", "prone_bone", "dildo", "vibrator", "fucking_machine"
    ]

    static let aliases: [String: String] = [
        // Identities / Orientations / Niches
        "ebony": "ebony", "ebonycuties": "ebony", "ebonyhomemade": "ebony",
        "ebonythroatqueens": "ebony", "blacktittyworld": "ebony", "blackgirl": "ebony", "darkskin": "ebony",
        "femboy": "femboy", "femboys": "femboy", "sissy": "femboy", "sissies": "femboy",
        "trap": "femboy", "traps": "femboy", "trapsgonewild": "femboy", "straighttosissy": "femboy", "boypussy": "femboy",
        "trans": "trans", "transgender": "trans", "tgirl": "trans", "tgirls": "trans",
        "transgirl": "trans", "transgirls": "trans", "transporn": "trans", "gonewildtrans": "trans",
        "mtf": "trans", "shemale": "trans", "ladyboy": "trans", "transwoman": "trans",
        "futa": "futanari", "futanari": "futanari", "futanarigifs": "futanari", "dickgirl": "futanari",
        "hentai": "hentai", "hentai_gif": "hentai", "hentai__videos": "hentai", "doujinshi": "hentai", "ecchi": "hentai",
        "rule34": "rule34", "r34": "rule34", "overwatch_porn": "rule34",
        "ahegao": "ahegao", "realahegao": "ahegao", "ahegao_irl": "ahegao", "ahegaogirls": "ahegao", "ahegaos": "ahegao", "ahegaohardcore": "ahegao",
        "cosplay": "cosplay", "cosplaygirls": "cosplay", "nsfwcosplay": "cosplay", "cosplaybabes": "cosplay", "cosplaypornvideos": "cosplay", "cosplaylewd": "cosplay",
        "goth": "goth", "gothgirl": "goth", "gothgf": "goth", "bigtiddygothgf": "goth", "gothsluts": "goth", "altgonewild": "goth", "gothgirlsgw": "goth", "suicidegirls": "goth",
        "bimbo": "bimbo", "bimbofetish": "bimbo", "bimbocumsluts": "bimbo", "bimbolovers": "bimbo", "enhancedfucktoys": "bimbo",
        // Ages / Builds / Ethnicities
        "milf": "milf", "milfs": "milf", "maturemilf": "milf", "realmoms": "milf", "gonewild30plus": "milf", "mommy": "milf",
        "teen": "teen", "teens": "teen", "legalteens": "teen", "barelylegalteens": "teen", "18_19": "teen", "teenbeauties": "teen", "collegeamateurs": "teen",
        "petite": "petite", "petitegonewild": "petite", "bustypetite": "petite", "lipsthatgrip": "petite", "tiny": "petite",
        "curvy": "curvy", "massivetitsnass": "curvy", "slimthick": "curvy", "thickwhitegirls": "curvy",
        "pawg": "pawg", "thick": "thick", "thicc": "thick", "chubby": "bbw", "bbw": "bbw", "bbwhardcore": "bbw", "bbwvideos": "bbw",
        "latina": "latina", "latinas": "latina", "latinacuties": "latina", "mexicana": "latina", "latinchickswhitedicks": "latina",
        "asian": "asian", "asiansgonewild": "asian", "asianhotties": "asian", "bustyasians": "asian", "nsfw_japan": "asian", "asiancumsluts": "asian",
        "jav": "jav", "indian": "indian", "indiansgonewild": "indian", "indianhotwife": "indian", "desiindiansex": "indian",
        "interracial": "interracial", "blacked": "interracial", "blackedpawgs": "interracial", "blackchickswhitedicks": "interracial",
        "bbc": "bbc", "bbcparadise": "bbc",
        "redhead": "redhead", "redheads": "redhead", "ginger": "redhead", "gingerbeauties": "redhead", "petitegingers": "redhead", "redheadmilfs": "redhead", "redheadsporn": "redhead",
        // Styles / Orientations (Orthogonal Separation: Femboy / Trans / Futa / Gay / Yaoi)
        "amateur": "amateur", "realgirls": "amateur", "homemadexxx": "homemade", "homemade": "homemade", "onoff": "amateur", "gonewild": "amateur",
        "lesbian": "lesbian", "lesbians": "lesbian", "girlskissing": "lesbian", "girlswithgirls": "lesbian", "lesbian_gifs": "lesbian", "cutelesbians": "lesbian", "wlw": "lesbian", "yuri": "lesbian",
        "gay": "gay", "gayporn": "gay", "malesmasturbating": "gay", "gaybrosgonewild": "gay", "twink": "twink", "m4m": "gay",
        "yaoi": "yaoi", "bara": "bara",
        "trans_woman": "trans_woman", "trans_man": "trans_man", "ftm": "trans_man",
        "threesome": "threesome", "threesomesnsfw": "threesome", "threesomegw": "threesome",
        "gangbang": "gangbang", "groupsex_gw": "gangbang", "groupsexnsfw": "gangbang",
        "cuckold": "cuckold", "hotwife": "hotwife", "hotwifecuckolds": "cuckold", "wifesharing": "cuckold",
        "freeuse": "freeuse", "public": "public", "publicsexporn": "public", "publicflashing": "public", "flashing": "flashing", "upskirt": "upskirt",
        "pov": "pov", "cheatingpov": "pov", "femalepov": "pov", "doggystylepov": "pov",
        "solo": "solo", "gettingherselfoff": "solo", "jilling": "solo", "fingering": "solo", "masturbation": "masturbation", "joi": "joi",
        "vintage": "vintage", "vintagebabes": "vintage", "vintagesmut": "vintage",
        // Body Parts & Acts
        "anal": "anal", "analgw": "anal", "analgonewild": "anal", "anal_gifs": "anal", "upherbutt": "anal", "buttsex": "anal", "asshole": "anal",
        "ass": "ass", "bigass": "ass", "bigasses": "ass", "booty": "ass", "twerk": "twerk", "twerking": "twerk",
        "bigtits": "big_tits", "big_tits": "big_tits", "big_breasts": "big_tits", "large_breasts": "big_tits", "tittydrop": "big_tits", "boobbounce": "big_tits", "stacked": "big_tits", "busty": "big_tits",
        "boobs": "boobs", "tits": "boobs", "boobies": "boobs", "breasts": "boobs", "natural_tits": "natural_tits",
        "blowjob": "blowjob", "blowjobs": "blowjob", "oral": "blowjob", "sucking": "blowjob", "girlsfinishingthejob": "blowjob", "gawkgawkgawk": "blowjob",
        "deepthroat": "deepthroat", "facefuck": "facefuck", "handjob": "handjob", "femdomhandjob": "handjob", "titfuck": "titfuck", "paizuri": "paizuri",
        "creampie": "creampie", "creampies": "creampie", "creampieflowingout": "creampie", "breeding": "breeding", "breeding_her": "breeding", "breedmedaddy": "breeding", "breedingmaterial": "breeding",
        "cumshot": "cumshot", "cumshots": "cumshot", "cum": "cumshot", "coveredincum": "cumshot", "facial": "facial", "facials": "facial", "cumslut": "cumslut", "cumsluts": "cumslut",
        "squirt": "squirt", "squirting": "squirt", "orgasm": "orgasm", "orgasms": "orgasm", "grool": "grool",
        "pussy": "pussy", "rearpussy": "pussy", "pussy_perfection": "pussy", "innie": "innie", "innies": "innie", "gape": "gape", "fisting": "fisting", "pussystretching": "fisting",
        // Kinks / Positions / Fantasy
        "bdsm": "bdsm", "bdsmgw": "bdsm", "bondage": "bondage", "sheLikesitrough": "bdsm", "shelikesitrough": "bdsm", "dominated": "bdsm",
        "femdom": "femdom", "pegging": "pegging", "facesitting": "facesitting", "spanking": "spanking", "strapon": "femdom",
        "hardcore": "hardcore", "hardcorensfw": "hardcore", "nsfwhardcore": "hardcore", "roughporn": "rough", "rough": "rough", "rough_sex": "rough",
        "feet": "feet", "feetfuckers": "feet", "feet_nsfw": "feet", "feetinyourface": "feet", "vipfeet": "feet", "footjob": "footjob",
        "stockings": "stockings", "thighhighs": "thigh_highs", "thigh_highs": "thigh_highs", "lingerie": "lingerie", "latex": "latex",
        "oilporn": "oil", "wetoil": "oil", "oil": "oil", "tentai": "tentacle", "tentacle": "tentacle", "tentacles": "tentacle",
        "hypno": "hypno", "monstergirl": "monster_girl", "monster_girl": "monster_girl", "elf": "elf", "succubus": "succubus", "bunny_girl": "bunny_girl", "maid": "maid", "nurse": "nurse",
        "cowgirl": "cowgirl", "riding": "riding", "doggystyle": "doggystyle", "missionary": "missionary", "pronebone": "prone_bone", "prone_bone": "prone_bone",
        "dildo": "dildo", "hugedildos": "dildo", "vibrator": "vibrator", "fuckingmachine": "fucking_machine", "fuckingmachines": "fucking_machine", "fucking_machine": "fucking_machine"
    ]

    static let relatedTags: [String: [String]] = [
        "ebony": ["curvy", "ass", "interracial", "bbc", "big_tits"],
        "femboy": ["thigh_highs", "cosplay", "anal", "dildo", "stockings"],
        "trans": ["trans_woman", "anal", "blowjob", "thigh_highs", "lingerie"],
        "trans_woman": ["trans", "anal", "blowjob", "thigh_highs", "lingerie"],
        "futanari": ["hentai", "creampie", "big_tits", "ahegao"],
        "hentai": ["ahegao", "futanari", "tentacle", "paizuri", "cosplay"],
        "goth": ["alt", "amateur", "big_tits", "bdsm", "stockings"],
        "latina": ["curvy", "ass", "pawg", "big_tits"],
        "asian": ["petite", "jav", "amateur", "cosplay"],
        "milf": ["mature", "curvy", "big_tits", "creampie"],
        "petite": ["teen", "anal", "blowjob", "pov"],
        "curvy": ["thick", "pawg", "ass", "big_tits"],
        "big_tits": ["boobs", "natural_tits", "titfuck", "milf", "curvy"],
        "anal": ["ass", "gape", "creampie", "doggystyle", "femboy"],
        "blowjob": ["deepthroat", "facefuck", "facial", "cumshot", "cumslut"],
        "creampie": ["breeding", "pussy", "hardcore", "cumshot"],
        "bdsm": ["femdom", "bondage", "rough", "hardcore", "spanking"],
        "femdom": ["bdsm", "pegging", "facesitting", "handjob"],
        "cosplay": ["ahegao", "hentai", "rule34", "stockings"],
        "lesbian": ["solo", "facesitting", "pussy", "squirt"]
    ]

    static func normalize(_ raw: String, categories: [GoonedCategory]) -> String? {
        let cleaned = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "r/", with: "")
        guard !cleaned.isEmpty, !MediaMetaRegistry.isStopTag(cleaned) else { return nil }
        if canonicalTags.contains(cleaned) { return cleaned }
        if let mapped = aliases[cleaned] { return mapped }
        for cat in categories {
            if cat.name.lowercased() == cleaned { return cat.name.lowercased() }
            if cat.subreddits.contains(where: { $0.lowercased() == cleaned }) {
                let cName = cat.name.lowercased()
                return aliases[cName] ?? (canonicalTags.contains(cName) ? cName : nil)
            }
        }
        return nil
    }

    static func extractRecognizedTags(from post: Gif, categories: [GoonedCategory]) -> [String] {
        var found = Set<String>()

        if let sub = post.subreddit, !sub.isEmpty {
            if let norm = normalize(sub, categories: categories) {
                found.insert(norm)
            } else {
                let subLower = sub.lowercased()
                for key in ["ebony", "femboy", "trans", "futanari", "hentai", "latina", "asian", "milf", "goth", "cosplay", "lesbian", "bdsm", "femdom", "anal", "blowjob", "creampie", "cumshot", "squirt", "petite", "curvy", "pawg", "bbw", "redhead", "interracial", "threesome"] {
                    if subLower.contains(key) {
                        found.insert(key)
                    }
                }
            }
        }

        if let title = post.title?.lowercased(), !title.isEmpty {
            let rawTokens = title
                .replacingOccurrences(of: "#", with: " ")
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
                .filter { !$0.isEmpty }

            for i in rawTokens.indices {
                let t = rawTokens[i]
                if let norm = normalize(t, categories: categories) {
                    found.insert(norm)
                }
                if i + 1 < rawTokens.count {
                    let pair = "\(t)_\(rawTokens[i + 1])"
                    if let normPair = normalize(pair, categories: categories) {
                        found.insert(normPair)
                    }
                }
            }
        }

        return Array(found)
    }

    static func extractRecognizedTags(fromQuery rawQuery: String, categories: [GoonedCategory]) -> [String] {
        var found = Set<String>()
        let tokens = rawQuery.lowercased()
            .replacingOccurrences(of: "#", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
            .filter { !$0.isEmpty }
        for i in tokens.indices {
            if let norm = normalize(tokens[i], categories: categories) {
                found.insert(norm)
            }
            if i + 1 < tokens.count {
                let pair = "\(tokens[i])_\(tokens[i + 1])"
                if let normPair = normalize(pair, categories: categories) {
                    found.insert(normPair)
                }
            }
        }
        return Array(found)
    }

    static func displayTitle(for tag: String) -> String {
        switch tag.lowercased() {
        case "femboy": return "Femboys"
        case "ebony": return "Ebony"
        case "trans", "trans_woman": return "Trans Women"
        case "trans_man": return "Trans Men"
        case "gay": return "Gay (M/M)"
        case "yaoi": return "Yaoi / 2D M/M"
        case "bara": return "Bara"
        case "futanari": return "Futanari"
        case "milf": return "MILF"
        case "bdsm": return "BDSM"
        case "pov": return "POV"
        case "bbw": return "BBW"
        case "bbc": return "BBC"
        case "pawg": return "PAWG"
        case "jav": return "JAV"
        case "joi": return "JOI"
        case "big_tits": return "Big Tits"
        case "natural_tits": return "Natural Tits"
        case "thigh_highs": return "Thigh Highs"
        case "monster_girl": return "Monster Girl"
        case "bunny_girl": return "Bunny Girl"
        case "fucking_machine": return "Fucking Machine"
        case "prone_bone": return "Prone Bone"
        case "tiktok_nsfw": return "TikTok NSFW"
        case "snapchat_nsfw": return "Snapchat NSFW"
        default:
            return tag.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Strict Porn-Only Content Eligibility Classifier

enum AdultContentClassifier {
    static let sfwBlockedSubreddits: Set<String> = [
        "earthporn", "foodporn", "carporn", "fightporn", "spaceporn", "cityporn",
        "natureporn", "historyporn", "mapporn", "designporn", "roomporn", "houseporn",
        "powerwashingporn", "artporn", "movieporn", "abandonedporn", "architectureporn",
        "humanporn", "animalporn", "weatherporn", "botanicalporn", "mechanicalgifs",
        "gaming", "funny", "memes", "dankmemes", "videos", "pics", "news", "worldnews",
        "politics", "sports", "nba", "nfl", "soccer", "ufc", "mma", "formula1",
        "minecraft", "fortnitebr", "valorant", "leagueoflegends", "callofduty",
        "tiktokcringe", "publicfreakout", "nextfuckinglevel", "interestingasfuck",
        "damnthatsinteresting", "wholesomememes", "aww", "animals", "eyebleach",
        "teenagers", "livestreamfail", "cryptocurrency", "wallstreetbets", "stocks",
        "technology", "science", "askreddit", "movies", "television", "music", "hiphopheads"
    ]

    static let sfwBlockedTerms: [String] = [
        "#nba", "#nfl", "#ufc", "#fifa", "#mlb", "#nhl", "#premierleague", "#championsleague",
        "#election", "#trump", "#biden", "#kamala", "#breakingnews", "#foxnews", "#cnn", "#msnbc",
        "#minecraft", "#roblox", "#valorant", "#warzone", "#esports", "#callofduty", "#fortnitebr",
        "#bitcoin", "#ethereum", "#crypto", "#stockmarket", "#forex", "#tradingview",
        "#recipe", "#cooking", "#baking", "#mealprep", "#workoutroutine", "#gymmotivation",
        "street fight", "knockout", "car crash", "dashcam", "bodycam", "police shooting",
        "press conference", "box score", "touchdown", "home run", "earnings report"
    ]

    private static let explicitAdultMarkers: [String] = [
        "nsfw", "18+", "onlyfans", "fansly", "manyvids", "pornhub", "xvideos", "xhamster",
        "redgifs", "brazzers", "chaturbate", "camgirl", "xxx", "porn", "nude", "nudes",
        "lewd", "hentai", "rule34", "r34", "futanari", "femboy", "tgirl", "shemale",
        "ladyboy", "ebony", "milf", "anal", "blowjob", "deepthroat", "facefuck", "creampie",
        "cumshot", "cumslut", "gangbang", "threesome", "cuckold", "hotwife", "bdsm",
        "femdom", "pegging", "boobs", "tits", "pussy", "cock", "dick", "sucking",
        "riding", "doggystyle", "squirt", "orgasm", "masturbat", "nsfwtwt", "hornytwt",
        "lewdtok", "18plus", "uncensored", "goon", "gooned", "gooning", "edging",
        "fisting", "ahegao", "paizuri", "bukkake", "freeuse", "bimbo", "slut",
        "link in bio", "vip page", "full video", "dm for"
    ]

    static func containsSFWBlockedTerm(_ text: String) -> Bool {
        let lower = text.lowercased()
        return sfwBlockedTerms.contains { lower.contains($0) }
    }

    static func hasExplicitAdultIndicators(_ text: String) -> Bool {
        let lower = text.lowercased()
        if explicitAdultMarkers.contains(where: { lower.contains($0) }) {
            return true
        }
        return !PornTagCatalog.extractRecognizedTags(fromQuery: lower, categories: GoonedCategory.defaultCategories).isEmpty
    }

    static func isEligibleXTweet(
        text: String,
        author: String,
        authorBio: String,
        possiblySensitive: Bool,
        hasAdultWarning: Bool,
        hasGraphicViolenceOnly: Bool,
        routeKey: String
    ) -> Bool {
        if hasGraphicViolenceOnly { return false }
        let combined = "\(text) \(author) \(authorBio)"
        if containsSFWBlockedTerm(combined) { return false }

        // User-curated bookmarks/likes or direct creator feeds still undergo SFW blocklist check,
        // while discovery timelines (x_foryou, x_following, x_search) enforce strict adult verification.
        if routeKey == "x_bookmarks" || routeKey.hasPrefix("x_likes_") || routeKey.hasPrefix("x_user_") {
            return hasAdultWarning || possiblySensitive || hasExplicitAdultIndicators(combined)
        }
        return hasAdultWarning || possiblySensitive || hasExplicitAdultIndicators(combined)
    }

    static func isEligibleIGReel(caption: String, author: String, routeKey: String) -> Bool {
        let combined = "\(caption) \(author)"
        if containsSFWBlockedTerm(combined) { return false }
        // Exclude blatantly non-adult everyday content across all IG feeds
        let sfwIGNoise = [
            "recipe", "cooking", "baby", "toddler", "kindergarten", "homework",
            "stock market", "real estate", "mortgage", "nfl", "nba", "premier league",
            "unboxing", "tech review", "sermon", "bible study", "tutorial", "coding",
            "excel", "tax", "insurance", "dentist", "homework", "minecraft", "fortnite",
            "politics", "election", "news", "weather forecast"
        ]
        let lower = combined.lowercased()
        if sfwIGNoise.contains(where: { lower.contains($0) }) { return false }

        // Keep SFW-clean IG reels across Reels, Following, Saved, and @user feeds
        // instead of dropping captionless/emoji-captioned Reels and starving the feed.
        return true
    }

    @MainActor
    static func isEligible(_ post: Gif, source: FeedSource, categories: [GoonedCategory], store: UserStore) -> Bool {
        guard post.hasPlayableMedia else { return false }
        if source == .redditSaved || source == .redditUpvoted { return true }
        guard !store.isBlockedByAlgorithm(post) else { return false }
        if source.isRedditPersonalFeed { return true }

        if let sub = post.subreddit?.lowercased(), !sub.isEmpty {
            if sfwBlockedSubreddits.contains(sub) { return false }
        }

        let combinedText = "\(post.title ?? "") \(post.author ?? "") \(post.subreddit ?? "")"
        if containsSFWBlockedTerm(combinedText) { return false }

        if post.isRule34Post {
            return true
        }
        if post.isXPost {
            // Tweets already passed XTweetParser verification, re-check against blocked terms
            return !containsSFWBlockedTerm(combinedText)
        }
        if post.isIGPost {
            return !containsSFWBlockedTerm(combinedText)
        }
        if post.isOnlyFansPost || post.isLongVideoPost {
            return !containsSFWBlockedTerm(combinedText)
        }

        // Personal saved lists (Liked / Offline Vault) were explicitly chosen by user
        if source.isList { return true }

        // Reddit / Gooned posts: verify known adult subreddit, redgifs host, or recognized porn tags
        if let sub = post.subreddit?.lowercased(), !sub.isEmpty {
            if categories.contains(where: { $0.subreddits.contains { $0.lowercased() == sub } }) {
                return true
            }
            if sub.contains("porn") || sub.contains("nsfw") || sub.contains("gonewild") || sub.contains("hentai") || sub.contains("rule34") || sub.contains("xxx") || sub.contains("sluts") || sub.contains("fetish") || sub.contains("goon") {
                return true
            }
        }
        if let media = post.mediaUrl?.lowercased(), media.contains("redgifs.com") {
            return true
        }
        if !PornTagCatalog.extractRecognizedTags(from: post, categories: categories).isEmpty {
            return true
        }
        return hasExplicitAdultIndicators(combinedText)
    }
}
