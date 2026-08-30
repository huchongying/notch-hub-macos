//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var lyricsRequestID = UUID()
    private var lyricsCache: [String: LyricCacheEntry] = [:]

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        lyricsCache = Self.loadLyricsCache()
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        lyricsTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController()
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        case .youtubeMusic:
            newController = YouTubeMusicController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType == .nowPlaying)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller
        
        self.canFavoriteTrack = controller.supportsFavorite

        // Get current state from active controller
        forceUpdate()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }
            self.artworkData = state.artwork

            if artworkChanged || state.artwork == nil {
                // Update last artwork change values
                self.lastArtworkTitle = state.title
                self.lastArtworkArtist = state.artist
                self.lastArtworkAlbum = state.album
                self.lastArtworkBundleIdentifier = state.bundleIdentifier
            }

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }

            // Fetch lyrics on content change
            self.fetchLyricsIfAvailable(
                bundleIdentifier: state.bundleIdentifier,
                title: state.title,
                artist: state.artist,
                duration: state.duration
            )
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }
        
        self.timestampDate = state.lastUpdated
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    private func fetchLyricsIfAvailable(
        bundleIdentifier: String?,
        title: String,
        artist: String,
        duration: TimeInterval
    ) {
        lyricsTask?.cancel()
        lyricsRequestID = UUID()
        let requestID = lyricsRequestID
        let cacheKey = lyricCacheKey(title: title, artist: artist, duration: duration)

        guard Defaults[.enableLyrics], !title.isEmpty else {
            DispatchQueue.main.async {
                self.isFetchingLyrics = false
                self.currentLyrics = ""
                self.syncedLyrics = []
            }
            return
        }

        let hasCachedLyrics: Bool
        if let cached = cachedLyrics(for: cacheKey) {
            currentLyrics = cached.plainLyrics.isEmpty ? cached.syncedLyrics : cached.plainLyrics
            syncedLyrics = parseLRC(cached.syncedLyrics)
            isFetchingLyrics = false
            hasCachedLyrics = true
        } else {
            hasCachedLyrics = false
        }

        if bundleIdentifier == "com.tencent.QQMusicMac" {
            lyricsTask = Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFetchingLyrics = true
                if !hasCachedLyrics {
                    self.currentLyrics = ""
                    self.syncedLyrics = []
                }
                if await self.fetchLyricsFromQQMusic(
                    title: title,
                    artist: artist,
                    duration: duration,
                    requestID: requestID,
                    cacheKey: cacheKey
                ) {
                    return
                }
                await self.fetchLyricsFromWeb(
                    title: title,
                    artist: artist,
                    duration: duration,
                    requestID: requestID,
                    cacheKey: cacheKey,
                    preserveCurrent: hasCachedLyrics
                )
            }
        } else if let bundleIdentifier = bundleIdentifier, bundleIdentifier.contains("com.apple.Music") {
            lyricsTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                guard !runningApps.isEmpty else {
                    await self.fetchLyricsFromWeb(
                        title: title,
                        artist: artist,
                        duration: duration,
                        requestID: requestID,
                        cacheKey: cacheKey,
                        preserveCurrent: hasCachedLyrics
                    )
                    return
                }

                self.isFetchingLyrics = true
                if !hasCachedLyrics {
                    self.currentLyrics = ""
                    self.syncedLyrics = []
                }
                do {
                    let script = """
                    tell application \"Music\"
                        if it is running then
                            if player state is playing or player state is paused then
                                try
                                    set l to lyrics of current track
                                    if l is missing value then
                                        return \"\"
                                    else
                                        return l
                                    end if
                                on error
                                    return \"\"
                                end try
                            else
                                return \"\"
                            end if
                        else
                            return \"\"
                        end if
                    end tell
                    """
                    if let result = try await AppleScriptHelper.execute(script),
                       let lyricsString = result.stringValue,
                       !lyricsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       self.lyricsRequestID == requestID,
                       !Task.isCancelled
                    {
                        let resolved = lyricsString.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.currentLyrics = resolved
                        self.isFetchingLyrics = false
                        self.syncedLyrics = []
                        self.storeLyrics(
                            LyricCacheEntry(
                                plainLyrics: resolved,
                                syncedLyrics: "",
                                updatedAt: Date(),
                                lastAccessedAt: Date()
                            ),
                            for: cacheKey
                        )
                        return
                    }
                } catch {
                    // fall through to web lookup
                }
                await self.fetchLyricsFromWeb(
                    title: title,
                    artist: artist,
                    duration: duration,
                    requestID: requestID,
                    cacheKey: cacheKey,
                    preserveCurrent: hasCachedLyrics
                )
            }
        } else {
            lyricsTask = Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFetchingLyrics = true
                if !hasCachedLyrics {
                    self.currentLyrics = ""
                    self.syncedLyrics = []
                }
                await self.fetchLyricsFromWeb(
                    title: title,
                    artist: artist,
                    duration: duration,
                    requestID: requestID,
                    cacheKey: cacheKey,
                    preserveCurrent: hasCachedLyrics
                )
            }
        }
    }

    @MainActor
    private func fetchLyricsFromQQMusic(
        title: String,
        artist: String,
        duration: TimeInterval,
        requestID: UUID,
        cacheKey: String
    ) async -> Bool {
        var searchComponents = URLComponents(
            string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
        )
        searchComponents?.queryItems = [
            URLQueryItem(name: "w", value: "\(title) \(artist)"),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: "8"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let searchURL = searchComponents?.url else { return false }

        do {
            let (searchData, searchResponse) = try await URLSession.shared.data(
                for: qqMusicRequest(url: searchURL)
            )
            guard let searchHTTP = searchResponse as? HTTPURLResponse,
                  searchHTTP.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let data = root["data"] as? [String: Any],
                  let song = data["song"] as? [String: Any],
                  let candidates = song["list"] as? [[String: Any]],
                  let songMID = bestQQMusicSongMID(
                    from: candidates,
                    title: title,
                    artist: artist,
                    duration: duration
                  )
            else {
                return false
            }

            var lyricComponents = URLComponents(
                string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg"
            )
            lyricComponents?.queryItems = [
                URLQueryItem(name: "songmid", value: songMID),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "inCharset", value: "utf8"),
                URLQueryItem(name: "outCharset", value: "utf-8"),
                URLQueryItem(name: "nobase64", value: "1"),
            ]
            guard let lyricURL = lyricComponents?.url else { return false }

            let (lyricData, lyricResponse) = try await URLSession.shared.data(
                for: qqMusicRequest(url: lyricURL)
            )
            guard let lyricHTTP = lyricResponse as? HTTPURLResponse,
                  lyricHTTP.statusCode == 200,
                  let lyricRoot = try JSONSerialization.jsonObject(with: lyricData)
                    as? [String: Any],
                  let lyric = lyricRoot["lyric"] as? String,
                  !lyric.isEmpty
            else {
                return false
            }

            guard lyricsRequestID == requestID, !Task.isCancelled else { return false }
            let parsed = parseLRC(lyric)
            guard !parsed.isEmpty else { return false }
            self.currentLyrics = lyric
            self.syncedLyrics = parsed
            self.isFetchingLyrics = false
            storeLyrics(
                LyricCacheEntry(
                    plainLyrics: lyric,
                    syncedLyrics: lyric,
                    updatedAt: Date(),
                    lastAccessedAt: Date()
                ),
                for: cacheKey
            )
            return true
        } catch {
            return false
        }
    }

    private func qqMusicRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("BoringNotch/QQMusicLyrics", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        return request
    }

    private func bestQQMusicSongMID(
        from candidates: [[String: Any]],
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> String? {
        let expectedTitle = normalizedLyricMatchText(title)
        let expectedArtist = normalizedLyricMatchText(artist)

        return candidates.compactMap { candidate -> (mid: String, score: Int)? in
            guard let mid = candidate["songmid"] as? String, !mid.isEmpty,
                  let candidateTitle = candidate["songname"] as? String
            else {
                return nil
            }

            let singers = (candidate["singer"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String }
                .joined(separator: " ") ?? ""
            let normalizedTitle = normalizedLyricMatchText(candidateTitle)
            let normalizedArtists = normalizedLyricMatchText(singers)

            guard normalizedTitle == expectedTitle,
                  expectedArtist.isEmpty || normalizedArtists.contains(expectedArtist)
            else {
                return nil
            }

            var score = 10
            if duration > 0 {
                let candidateDuration = (candidate["interval"] as? Double)
                    ?? (candidate["interval"] as? Int).map(Double.init)
                guard let candidateDuration, abs(candidateDuration - duration) <= 3 else {
                    return nil
                }
                score += 4
            }
            return (mid, score)
        }
        .max { $0.score < $1.score }?
        .mid
    }

    private func normalizedLyricMatchText(_ string: String) -> String {
        normalizedQuery(string)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    private func bestLRCLIBResult(
        from candidates: [[String: Any]],
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> [String: Any]? {
        let expectedTitle = normalizedLyricMatchText(title)
        let expectedArtist = normalizedLyricMatchText(artist)
        return candidates.first { candidate in
            guard let candidateTitle = candidate["trackName"] as? String,
                  let candidateArtist = candidate["artistName"] as? String,
                  normalizedLyricMatchText(candidateTitle) == expectedTitle
            else { return false }
            let normalizedArtist = normalizedLyricMatchText(candidateArtist)
            guard expectedArtist.isEmpty
                || normalizedArtist.contains(expectedArtist)
                || expectedArtist.contains(normalizedArtist)
            else { return false }
            guard duration > 0 else { return true }
            let candidateDuration = (candidate["duration"] as? Double)
                ?? (candidate["duration"] as? Int).map(Double.init)
                ?? (candidate["duration"] as? NSNumber)?.doubleValue
            return candidateDuration.map { abs($0 - duration) <= 3 } ?? false
        }
    }

    private func lyricCacheKey(title: String, artist: String, duration: TimeInterval) -> String {
        let durationBucket = duration > 0 ? Int(duration.rounded()) : 0
        return "\(normalizedLyricMatchText(title))|\(normalizedLyricMatchText(artist))|\(durationBucket)"
    }

    private func cachedLyrics(for key: String) -> LyricCacheEntry? {
        guard var entry = lyricsCache[key],
              Date().timeIntervalSince(entry.updatedAt) <= 30 * 24 * 60 * 60
        else {
            lyricsCache.removeValue(forKey: key)
            return nil
        }
        entry.lastAccessedAt = Date()
        lyricsCache[key] = entry
        persistLyricsCache()
        return entry
    }

    private func storeLyrics(_ entry: LyricCacheEntry, for key: String) {
        lyricsCache[key] = entry
        if lyricsCache.count > 500 {
            let overflow = lyricsCache.count - 500
            for key in lyricsCache
                .sorted(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt })
                .prefix(overflow)
                .map(\.key)
            {
                lyricsCache.removeValue(forKey: key)
            }
        }
        persistLyricsCache()
    }

    private static var lyricsCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("boringNotch", isDirectory: true)
            .appendingPathComponent("lyrics-cache-v1.json")
    }

    private static func loadLyricsCache() -> [String: LyricCacheEntry] {
        guard let data = try? Data(contentsOf: lyricsCacheURL),
              let cache = try? JSONDecoder().decode([String: LyricCacheEntry].self, from: data)
        else { return [:] }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        return cache.filter { $0.value.updatedAt >= cutoff }
    }

    private func persistLyricsCache() {
        let directory = Self.lyricsCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(lyricsCache) else { return }
        try? data.write(to: Self.lyricsCacheURL, options: .atomic)
    }

    @MainActor
    private func fetchLyricsFromWeb(
        title: String,
        artist: String,
        duration: TimeInterval,
        requestID: UUID,
        cacheKey: String,
        preserveCurrent: Bool
    ) async {
        let cleanTitle = normalizedQuery(title)
        let cleanArtist = normalizedQuery(artist)
        guard let encodedTitle = cleanTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedArtist = cleanArtist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            if !preserveCurrent {
                self.currentLyrics = ""
                self.syncedLyrics = []
            }
            self.isFetchingLyrics = false
            return
        }

        // LRCLIB simple search (no auth): https://lrclib.net/api/search?track_name=...&artist_name=...
        let urlString = "https://lrclib.net/api/search?track_name=\(encodedTitle)&artist_name=\(encodedArtist)"
        guard let url = URL(string: urlString) else {
            if !preserveCurrent {
                self.currentLyrics = ""
                self.syncedLyrics = []
            }
            self.isFetchingLyrics = false
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                guard lyricsRequestID == requestID, !Task.isCancelled else { return }
                if !preserveCurrent {
                    self.currentLyrics = ""
                    self.syncedLyrics = []
                }
                self.isFetchingLyrics = false
                return
            }
            if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let match = bestLRCLIBResult(
                   from: jsonArray,
                   title: title,
                   artist: artist,
                   duration: duration
               ),
               lyricsRequestID == requestID,
               !Task.isCancelled
            {
                let plain = (match["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let synced = (match["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let resolved = plain.isEmpty ? synced : plain
                guard !resolved.isEmpty else {
                    if !preserveCurrent {
                        self.currentLyrics = ""
                        self.syncedLyrics = []
                    }
                    self.isFetchingLyrics = false
                    return
                }
                self.currentLyrics = resolved
                self.isFetchingLyrics = false
                if !synced.isEmpty {
                    self.syncedLyrics = self.parseLRC(synced)
                } else {
                    self.syncedLyrics = []
                }
                storeLyrics(
                    LyricCacheEntry(
                        plainLyrics: plain,
                        syncedLyrics: synced,
                        updatedAt: Date(),
                        lastAccessedAt: Date()
                    ),
                    for: cacheKey
                )
            } else {
                guard lyricsRequestID == requestID, !Task.isCancelled else { return }
                if !preserveCurrent {
                    self.currentLyrics = ""
                    self.syncedLyrics = []
                }
                self.isFetchingLyrics = false
            }
        } catch {
            guard lyricsRequestID == requestID, !Task.isCancelled else { return }
            if !preserveCurrent {
                self.currentLyrics = ""
                self.syncedLyrics = []
            }
            self.isFetchingLyrics = false
        }
    }

    // MARK: - Synced lyrics helpers
    private func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        var result: [(Double, String)] = []
        lrc.split(separator: "\n").forEach { lineSub in
            let line = String(lineSub)
            // Match [mm:ss.xx] or [m:ss]
            let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,2}))?\]"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let nsLine = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                let minStr = nsLine.substring(with: match.range(at: 1))
                let secStr = nsLine.substring(with: match.range(at: 2))
                let csRange = match.range(at: 3)
                let centiStr = csRange.location != NSNotFound ? nsLine.substring(with: csRange) : "0"
                let minutes = Double(minStr) ?? 0
                let seconds = Double(secStr) ?? 0
                let centis = Double(centiStr) ?? 0
                let time = minutes * 60 + seconds + centis / 100.0
                let textStart = match.range.location + match.range.length
                let text = nsLine.substring(from: textStart).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    result.append((time, text))
                }
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    func lyricLine(at elapsed: Double) -> String {
        guard !syncedLyrics.isEmpty else { return currentLyrics }
        // Binary search for last line with time <= elapsed
        var low = 0
        var high = syncedLyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return syncedLyrics[idx].text
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    self?.usingAppIconForArtwork = false
                    self?.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, elapsedTime + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
            }
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        // Check if bundle identifier is valid and if the app is actually running
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = """
            tell application "Music"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else if bundleID == "com.spotify.client" {
            script = """
            tell application "Spotify"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}

private struct LyricCacheEntry: Codable {
    let plainLyrics: String
    let syncedLyrics: String
    let updatedAt: Date
    var lastAccessedAt: Date
}
