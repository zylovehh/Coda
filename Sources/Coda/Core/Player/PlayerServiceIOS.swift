#if os(iOS)
import Combine
import AVFoundation
import Foundation
import UIKit

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Where playback started from — listed under "Recently Played" in the Dock
/// menu, where picking one reloads it and starts playing again.
///
/// This is deliberately separate from `PlaySource`: heartbeat mode plays out
/// of the liked-songs playlist for scrobbling purposes, but as a *place* it is
/// its own thing, and the recents page has no source at all.
struct PlayContext: Codable, Hashable {
    enum Kind: String, Codable {
        /// Reloaded by id.
        case playlist, album, artist
        /// Fixed per-account entry points, each reloaded from its own API.
        case daily, cloud, recents, heartbeat, fm
    }

    let kind: Kind
    /// Zero for the fixed entry points, which have no id of their own.
    let id: Int
    let name: String

    static func playlist(id: Int, name: String) -> PlayContext {
        .init(kind: .playlist, id: id, name: name)
    }

    static func album(id: Int, name: String) -> PlayContext {
        .init(kind: .album, id: id, name: name)
    }

    static func artist(id: Int, name: String) -> PlayContext {
        .init(kind: .artist, id: id, name: name)
    }

    static var daily: PlayContext { .init(kind: .daily, id: 0, name: String(localized: "每日推荐")) }
    static var cloud: PlayContext { .init(kind: .cloud, id: 0, name: String(localized: "音乐云盘")) }
    static var recents: PlayContext { .init(kind: .recents, id: 0, name: String(localized: "最近播放")) }
    static var heartbeat: PlayContext { .init(kind: .heartbeat, id: 0, name: String(localized: "心动模式")) }
    static var fm: PlayContext { .init(kind: .fm, id: 0, name: String(localized: "私人漫游")) }

    /// Identity is the place, not its current title — a renamed playlist is
    /// still the same entry in the recents list.
    static func == (lhs: PlayContext, rhs: PlayContext) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
    }
}

enum RightPanel {
    case lyrics, queue
}

/// The playback engine: queue, shuffle/repeat, personal FM, URL resolution,
/// lyrics and playback history, backed by the iOS streaming deck.
/// High-frequency playback position, isolated so per-tick updates only
/// re-render the scrubbers/lyrics that observe it — not every view holding
/// the PlayerService.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var progress: TimeInterval = 0
}

@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    // MARK: - Observable state

    @Published private(set) var queue: [Track] = []
    @Published private(set) var shuffledQueue: [Track] = []
    @Published private(set) var playNextList: [Track] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var currentTrack: Track? {
        didSet {
            guard currentTrack?.id != oldValue?.id else { return }
            lyricsTimingSteps = currentTrack.map {
                UserDefaults.standard.integer(forKey: "lyrics.timing.\($0.id)")
            } ?? 0
        }
    }
    /// Positive values display lyrics earlier; integer tenths avoid rounding drift.
    @Published private(set) var lyricsTimingSteps = 0 {
        didSet {
            updateLyricsCursor(at: livePlaybackTime)
            lyricsCursor.seekRevision &+= 1
        }
    }
    var lyricsTimeOffset: TimeInterval { Double(lyricsTimingSteps) / 10 }

    func adjustLyricsTiming(by steps: Int) {
        setLyricsTiming(steps: lyricsTimingSteps + steps)
    }

    func setLyricsTiming(steps: Int) {
        guard let track = currentTrack else { return }
        lyricsTimingSteps = steps
        scheduleLyricsResync()
        let key = "lyrics.timing.\(track.id)"
        if steps == 0 { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(steps, forKey: key) }
    }
    private var playbackAccountID: Int?
    @Published private(set) var source: PlaySource = .none
    private let qishuiContinuation = QishuiQueueContinuation()
    private var qishuiFeedDrained = false
    @Published private var isLoadingQishuiFeed = false
    @Published private(set) var pendingQishuiScene: QishuiListeningScene?
    @Published private var fmLoadID: UUID?

    var showsPlaybackLoading: Bool {
        isLoadingQishuiFeed || fmLoadID != nil
            || (isPlaying && (trackResolution?.generation == resolveGeneration || isBuffering))
    }
    @Published private var trackResolution: (generation: Int, task: Task<Void, Never>)?
    private var qishuiPrefetch: (trackID: String, quality: AudioQuality, task: Task<Void, Never>)?
    @Published private(set) var isPlaying = false {
        didSet { updateLyricsCursor(at: livePlaybackTime); samplePlaybackReporting() }
    }
    @Published private(set) var isBuffering = false {
        didSet { updateLyricsCursor(at: livePlaybackTime); samplePlaybackReporting() }
    }
    @Published private(set) var duration: TimeInterval = 0
    typealias AudioQualityBadgeState = PlaybackState.AudioQualityBadge
    /// Keep the last resolved badge while the next stream is being resolved.
    @Published private(set) var audioQualityBadgeState: AudioQualityBadgeState?
    @Published private(set) var servedQishuiQualityOption: AudioQualityOption?
    @Published private(set) var servedQuality: String? {
        didSet {
            // A third-party stream keeps its "external source" badge; the
            // badge reads the served tier alongside it.
            if let servedQuality, !servedQuality.isEmpty, unblockSource == nil {
                audioQualityBadgeState = .quality(servedQuality)
            }
        }
    }
    @Published private(set) var isSwitchingAudioQuality = false
    private var isReplacingQualityStream = false
    /// The quality title of the third-party stream, with its bitrate.
    @Published private(set) var externalQualityTitle: String?
    /// Bits per second the third-party source reported, kept with its cached copy.
    private var externalBitrate: Int?
    @Published private(set) var unblockSource: String? {
        didSet {
            if unblockSource == nil { externalQualityTitle = nil; externalBitrate = nil }
            if unblockSource != nil {
                audioQualityBadgeState = .externalSource
            } else if oldValue != nil, let servedQuality, !servedQuality.isEmpty {
                audioQualityBadgeState = .quality(servedQuality)
            }
        }
    }
    @Published private(set) var isTrial = false
    let clock = PlaybackClock()
    let lyricsCursor = LyricsCursor()
    let sleepTimer = SleepTimer()
    /// Passthrough to the clock so existing `progress` reads/writes keep working.
    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat") }
    }

    @Published private(set) var shuffleEnabled = false
    @Published var volume: Float = 1 {
        didSet {
            engine.volume = volume
            UserDefaults.standard.set(volume, forKey: "player.volume")
        }
    }

    @Published private(set) var isFMMode = false
    /// The QQ listening mode FM is playing; nil is the regular FM feed.
    @Published private(set) var qqFMSceneID: String?
    @Published private(set) var fmUpcoming: [Track] = []
    /// Where playback was most recently started from, newest first —
    /// surfaced as "Recently Played" in the Dock menu.
    @Published private(set) var recentContexts: [PlayContext] = []
    @Published private(set) var lyrics: ParsedLyrics? {
        didSet {
            updateLyricsCursor(at: livePlaybackTime)
        }
    }
    private var lyricsSettingsObservation: AnyCancellable?
    @Published private(set) var lyricsLoadFailed = false
    @Published private(set) var lyricsSource: LyricsSource = .automatic
    @Published private(set) var resolvedLyricsSource: LyricsSource?
    @Published private(set) var lyricsSourceLoading = false
    private var lyricsRequestID = UUID()
    @Published var activePanel: RightPanel?
    @Published var showNowPlaying = false

    /// The list the player is walking through (shuffled or ordered).
    var activeQueue: [Track] { shuffleEnabled ? shuffledQueue : queue }

    var upcomingTracks: [Track] {
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    // MARK: - Engine

    private let engine = AudioPlaybackDeck()
    private var lastPlaybackCheckpoint = ContinuousClock.now

    /// Live playback position straight from the player, for smooth per-frame
    /// karaoke highlighting (the published `progress` is intentionally coarse).
    var livePlaybackTime: TimeInterval {
        if let pendingSeek, engine.itemID == pendingSeek.itemID { return pendingSeek.target }
        return engine.currentPlaybackTime ?? progress
    }
    private var pendingSeek: (target: TimeInterval, itemID: UUID)?
    private var seekCompletion: (@MainActor () -> Void)?
    private var clockSampling: Task<Void, Never>?
    private var lyricsResync: Task<Void, Never>?
    private var streamCache: StreamingAudioCacheWriter?
    private var audioCacheLease: UUID?
    private var engineInstallationID = UUID()
    private var resolveGeneration = 0
    private var lyricsLoad: (trackID: Int, generation: Int, requestID: UUID, task: Task<Void, Never>)?
    private var consecutiveFailures = 0
    private var attemptedUnblockSources: Set<AudioSourceID> = []
    @Published private(set) var currentUnblockSourceID: AudioSourceID?
    /// The resolve generation that already spent its one reload after a
    /// failed item, so a reload that fails too gives up instead of looping.
    private var itemRetryGeneration: Int?
    /// Set when a failure skips to the next song, so that skip keeps counting
    /// toward the stop after five in a row instead of resetting it.
    private var advancingAfterFailure = false
    private var scrobbled = false
    private var reportingBitrate: Int?
    private let historyReporter = PlaybackHistoryReporter()
    private let kugouReporter = KugouPlaybackReporter()
    private let qishuiHistoryReporter = QishuiHistoryReporter()
    private var historySession: PlaybackHistoryReporter.Session?

    // MARK: - Offline playback (downloads)

    /// The song that could not play because it is not on this device.
    @Published var offlineIssue: OfflinePlaybackIssue?
    /// Held while the player item reads a downloaded file, so the download
    /// cannot be deleted from under it.
    private var offlinePlaybackLease: OfflinePlaybackLease?
    private var offlineScan: Task<Void, Never>?
    private var offlineScanID = UUID()
    private var networkState = DownloadNetworkState.unknown
    private var networkObservation: AnyCancellable?
    private var offlineActivatedScope: String?
    /// Set by an automatic advance and consumed by `startPlaying`: a song that
    /// turns out to be missing offline is skipped rather than reported.
    private var pendingAutoAdvance = false
    private var currentWasAdvanced = false

    // MARK: - Queue prefetch (song cache)

    /// Fills the cache with the next few songs while the network is free.
    private let queuePrefetcher = QueuePrefetcher()
    private var prefetchObservations: Set<AnyCancellable> = []
    private var prefetchUpdateScheduled = false

    private enum ResolvedURLLoadResult {
        case loaded
        case superseded
    }

    private init() {
        sleepTimer.onDeadlineReached = { [weak self] in
            self?.pause()
        }
        // The iPad uses the system volume control; avoid a second persisted
        // gain underneath it. Other layouts retain their in-app volume control.
        volume = UIDevice.current.userInterfaceIdiom == .pad
            ? 1 : (UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.8)
        engine.volume = volume
        repeatMode = UserDefaults.standard.string(forKey: "player.repeat")
            .flatMap(RepeatMode.init) ?? .off

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to activate audio session: \(error)")
        }

        // Resume after interruptions (phone calls, WeChat voice messages, …).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleAudioInterruption(note)
            }
        }
        // Pause when the output route disappears (headphones unplugged).
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.kugouReporter.finish(position: self.engine.currentPlaybackTime ?? self.progress, completed: false)
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                      reason == .oldDeviceUnavailable, self.isPlaying else { return }
                self.pause()
            }
        }
        #endif

        clockSampling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled else { return }
                self?.samplePlaybackClock()
            }
        }

        lyricsSettingsObservation = SettingsManager.shared.$verbatimLyrics
            .removeDuplicates().dropFirst().sink { [weak self] enabled in
                guard let self else { return }
                // This switch changes presentation and lead time, not
                // the authored source timeline. @Published delivers before
                // the setting is stored, so use its incoming value explicitly.
                self.updateLyricsCursor(at: self.livePlaybackTime, wordByWord: enabled)
                self.lyricsCursor.seekRevision &+= 1
            }

        NowPlayingManager.shared.attach(to: self)
        offlineActivatedScope = AccountStore.shared.offlineScope
        networkObservation = DownloadManager.shared.$network.removeDuplicates().sink { [weak self] network in
            self?.networkState = network
        }
        observePrefetchInputs()
        // The cache keeps its default limit until something writes to it, and
        // trims to that on every release; a cache-only session must not lose
        // songs on the way.
        if SettingsManager.shared.enableAudioCache {
            Task { try? await AudioCache.shared.enforce(maximumSizeMB: await SettingsManager.shared.effectiveAudioCacheSizeMB()) }
        }
        restoreState()
        // Restoring a paused session does not call startPlaying. Its lyrics
        // still need to load before the player is opened for the first time.
        Task { await loadCurrentLyricsIfNeeded() }
    }

    /// Set while the user drags the seek bar so the time observer doesn't fight the thumb.
    var isScrubbing = false

    #if os(iOS)
    private var wasPlayingBeforeInterruption = false

    private func handleAudioInterruption(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                // Freeze decoding too, so resume can restart the hardware after
                // the system releases our audio session.
                engine.pause()
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                persistState()
            }
        case .ended:
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = wasPlayingBeforeInterruption && options.contains(.shouldResume)
            wasPlayingBeforeInterruption = false
            guard shouldResume else { return }
            engine.play()
            isPlaying = engine.state == .playing || engine.state == .loading
            NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Entry points

    /// - Parameter context: the place these tracks came from. Supplying it
    ///   lists that place in the Dock menu's recently played section; callers
    ///   playing an ad-hoc selection (search results, a single track) omit it.
    func play(tracks: [Track], source: PlaySource, startAt track: Track? = nil,
              context: PlayContext? = nil) {
        guard !tracks.isEmpty else { return }
        // A mixed playlist queues as-is: each track resolves through its own
        // platform in startPlaying/resolveAndLoad, so playing never asks the
        // user to switch platforms first.
        tracks.forEach { PlatformMusicAPI.shared.restore($0) }
        if let context { recordRecent(context) }
        isFMMode = false
        queue = tracks
        self.source = source
        playNextList.removeAll()
        let startTrack = track ?? tracks[0]
        if shuffleEnabled {
            reshuffle(keeping: startTrack)
            currentIndex = 0
        } else {
            currentIndex = tracks.firstIndex(where: { $0.id == startTrack.id }) ?? 0
        }
        startPlaying(activeQueue[currentIndex])
        qishuiContinuation.reset()
    }

    func playQishuiScene(_ scene: QishuiListeningScene) {
        guard MusicProviderContext.shared.current == .qishui, pendingQishuiScene != scene else { return }
        pause()
        let outgoing = currentTrack
        let played = QishuiPlayedMedia(track: outgoing, position: progress)
        let state = QishuiMusicAPI.shared.feedState(.scene(scene))
        pendingQishuiScene = scene
        isLoadingQishuiFeed = true
        qishuiContinuation.load(state, excluding: [outgoing].compactMap { $0 },
                                played: [played].compactMap { $0 }) { [weak self] result in
            guard let self else { return }
            self.pendingQishuiScene = nil
            self.isLoadingQishuiFeed = false
            switch result {
            case .success(let batch):
                guard !batch.tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "此场景暂无推荐歌曲"))
                    return
                }
                self.play(tracks: batch.tracks, source: .qishuiFeed(batch.state, playlistID: nil))
            case .failure(let error):
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func cancelQishuiFeedLoad() {
        qishuiContinuation.cancel()
        pendingQishuiScene = nil
        isLoadingQishuiFeed = false
    }

    func playTrack(_ track: Track) {
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        } else {
            play(tracks: [track], source: .none)
        }
    }

    /// Insert a track right after the current one.
    func addToPlayNext(_ track: Track, playNow: Bool = false) {
        playNextList.append(track)
        if playNow || currentTrack == nil {
            advanceToNext(userInitiated: true)
        } else {
            ToastCenter.shared.show(String(localized: "已添加到下一首播放"))
        }
    }

    func togglePlayPause() {
        if isLoadingQishuiFeed || fmLoadID != nil {
            pause()
            return
        }
        guard let track = currentTrack else { return }
        if !isPlaying, qishuiFeedDrained, source.qishuiFeed?.hasMore == true {
            advanceToNext(userInitiated: true)
            return
        }
        if isPlaying {
            pause()
            return
        } else if !engine.hasCurrentItem {
            zzTrace("toggle restart resumeAt=\(progress)")
            // Restored session: re-resolve the source.
            startPlaying(track, resumeAt: progress)
            return
        } else {
            engine.play()
            zzTrace("toggle engine.play state=\(engine.state) t=\(String(describing: engine.currentPlaybackTime)) progress=\(progress)")
            isPlaying = engine.state == .playing || engine.state == .loading
            if isPlaying { scrobbleStartIfNeeded() }
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
    }

    func pause() {
        fmLoadID = nil
        cancelQishuiFeedLoad()
        if let resolution = trackResolution, resolution.generation == resolveGeneration {
            resolveGeneration += 1
            resolution.task.cancel()
            trackResolution = nil
            clearEngine()
            releaseCurrentPlaybackResources()
        }
        engine.pause()
        isPlaying = false
        AudioSpectrum.shared.reset()
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
        persistState()
    }

    func next() {
        advanceToNext(userInitiated: true)
    }

    func previous() {
        guard let idx = PlaybackAdvancePlan.previousIndex(
            queueCount: activeQueue.count, currentIndex: currentIndex,
            isFM: isFMMode, repeatMode: repeatMode) else { return }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    /// Recomputes the current lyric line, publishing only on a change.
    /// Uses the same media-time basis as karaoke word highlighting.
    private func updateLyricsCursor(at seconds: TimeInterval, wordByWord: Bool? = nil) {
        let wordTimed = (wordByWord ?? SettingsManager.shared.verbatimLyrics)
            && lyrics?.lines.contains(where: { $0.words?.isEmpty == false }) == true
        // Line lyrics lead by 0.2s. Authored word timing uses its original timestamps.
        lyricsCursor.synchronize(lyrics: lyrics, at: seconds, playing: isPlaying && !isBuffering && pendingSeek == nil,
            rate: Double(engine.rate), duration: duration, advanceTime: wordTimed ? 0 : 0.2, timeOffset: lyricsTimeOffset)
    }

    /// After a user adjustment (progress, lyrics timing/source, audio quality),
    /// wait until the engine is actually rendering again, then re-anchor the
    /// lyrics to its media time. A few follow-up checks catch a stream that
    /// settles late; they only redraw when the lyric clock has drifted.
    private func scheduleLyricsResync() {
        lyricsResync?.cancel()
        lyricsResync = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline {
                guard !Task.isCancelled, let self else { return }
                if self.pendingSeek == nil, !self.isBuffering, !self.isScrubbing,
                   self.engine.currentPlaybackTime != nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            for (index, delay) in [0, 400, 1200, 3000].enumerated() {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard !Task.isCancelled, let self else { return }
                self.resyncLyricsToPlayback(force: index == 0)
            }
        }
    }

    private func resyncLyricsToPlayback(force: Bool) {
        guard !isScrubbing, pendingSeek == nil, !isBuffering,
              let seconds = engine.currentPlaybackTime, seconds.isFinite else { return }
        let drift = abs(lyricsCursor.playbackTime - lyricsTimeOffset - seconds)
        progress = seconds
        updateLyricsCursor(at: seconds)
        if force || drift > 0.12 {
            zzTrace("lyricsResync t=\(seconds) drift=\(drift) force=\(force)")
            lyricsCursor.seekRevision &+= 1
            NowPlayingManager.shared.updateElapsed(seconds, rate: Double(engine.rate))
        }
    }

    func seek(to seconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        guard seconds.isFinite else { return }
        scheduleLyricsResync()
        cancelQishuiFeedLoad()
        qishuiFeedDrained = false
        qishuiHistoryReporter.discontinuity()
        kugouReporter.willSeek(position: engine.currentPlaybackTime ?? progress)
        let target = min(max(0, seconds), duration > 0 ? duration : max(0, seconds))
        zzTrace("seek target=\(target) item=\(engine.itemID != nil) state=\(engine.state) progress=\(progress)")
        progress = target
        guard let itemID = engine.itemID else {
            updateLyricsCursor(at: target)
            lyricsCursor.seekRevision &+= 1
            persistState()
            completion?()
            return
        }
        seekCompletion?()
        pendingSeek = (target, itemID)
        seekCompletion = completion
        engine.seek(to: target)
        updateLyricsCursor(at: target)
        lyricsCursor.seekRevision &+= 1
        NowPlayingManager.shared.updateElapsed(target, rate: 0)
        persistState()
    }

    /// Resolve first while the old stream keeps playing. Only swap after a
    /// usable URL arrives; the queue, lyrics and current play/pause state stay put.
    func switchAudioQuality(to quality: AudioQuality?, alwaysHighest: Bool) async {
        guard !isSwitchingAudioQuality else { return }
        let settings = SettingsManager.shared
        settings.alwaysHighestAudioQuality = alwaysHighest
        if let quality { settings.audioQuality = quality }
        guard let track = currentTrack else { return }
        guard networkState.connected else {
            ToastCenter.shared.show("音质偏好已保存，联网播放时生效")
            return
        }
        guard engine.hasCurrentItem, !isBuffering else {
            ToastCenter.shared.show("音质偏好已保存，下次载入时生效")
            return
        }
        let generation = resolveGeneration
        let scope = offlineAccountScope
        isSwitchingAudioQuality = true
        defer { isSwitchingAudioQuality = false }
        do {
            let url: URL
            let served: String?
            var qishuiOption: AudioQualityOption?
            var bitrate: Int?
            var durationMS: Int?
            var trial = false
            var external: ResolvedAudioSource?
            if let sourceID = currentUnblockSourceID {
                // A gray track switches tiers on the source that is serving it.
                let resolution = await UnblockResolver.resolve(
                    track, quality: settings.preferredPlaybackQuality,
                    excluding: Set(AudioSourceID.allCases).subtracting([sourceID]))
                guard !Task.isCancelled, generation == resolveGeneration,
                      currentTrack?.id == track.id, scope == offlineAccountScope else { return }
                guard let resolved = resolution.source else {
                    ToastCenter.shared.show("当前音源暂不支持此音质，继续原音质播放")
                    return
                }
                url = resolved.url
                served = resolved.quality?.rawValue
                external = resolved
            } else {
                let result: SongURLData?
                if alwaysHighest {
                    result = try await NeteaseAPI.preferredSongURL(id: track.id,
                        quality: settings.preferredPlaybackQuality, alwaysHighest: true)
                } else {
                    result = try await NeteaseAPI.songURL(ids: [track.id], level: settings.audioQuality.rawValue).first
                }
                guard !Task.isCancelled, generation == resolveGeneration,
                      currentTrack?.id == track.id, scope == offlineAccountScope else { return }
                guard let data = result, let address = data.url,
                      let platformURL = track.playbackURL(address) else {
                    ToastCenter.shared.show("当前歌曲或账号暂不支持此音质，继续原音质播放")
                    return
                }
                guard data.freeTrialInfo == nil || isTrial else {
                    ToastCenter.shared.show("此音质仅可试听，继续原音质完整播放")
                    return
                }
                url = platformURL
                served = data.resolvedAudioQuality?.rawValue ?? data.level
                qishuiOption = track.platformSong?.source == .qishui ? data.qishuiQualityOption : nil
                bitrate = data.br > 0 ? data.br / 1000 : nil
                durationMS = data.time
                trial = data.freeTrialInfo != nil
            }
            let actual = served.flatMap(AudioQuality.init(rawValue:))
            if let served, served == servedQuality, external?.id == currentUnblockSourceID, trial == isTrial {
                if let actual, !alwaysHighest, actual != quality {
                    ToastCenter.shared.show("当前可播放音质为\(actual.displayName)")
                }
                return
            }
            let position = livePlaybackTime
            let previousURL = engine.sourceURL
            let previousQuality = servedQuality
            let previousQishuiQualityOption = servedQishuiQualityOption
            let previousBitrate = reportingBitrate
            let previousDuration = duration
            let previousTrial = isTrial
            let previousUnblock = unblockSource
            let previousExternalTitle = externalQualityTitle
            let previousExternalBitrate = externalBitrate
            let previousSourceID = currentUnblockSourceID
            // Hold a file lease until the replacement succeeds, so a cache trim
            // cannot remove the rollback file while the new stream is buffering.
            let previousCacheLease = audioCacheLease
            let previousOfflineLease = offlinePlaybackLease
            audioCacheLease = nil
            offlinePlaybackLease = nil
            var transferredPreviousLeases = false
            defer {
                isReplacingQualityStream = false
                if !transferredPreviousLeases {
                    if let previousCacheLease { releaseAudioCacheLease(previousCacheLease) }
                    if let previousOfflineLease {
                        Task { try? await OfflineStore.shared.release(previousOfflineLease) }
                    }
                }
            }
            isReplacingQualityStream = true
            progress = position
            servedQuality = served
            servedQishuiQualityOption = qishuiOption
            reportingBitrate = bitrate
            isTrial = trial
            unblockSource = external?.displayName
            externalQualityTitle = external?.title
            externalBitrate = external?.bitrate
            if let external { reportingBitrate = external.bitrate.map { $0 / 1000 } }
            currentUnblockSourceID = external?.id
            AudioSpectrum.shared.beginPreparing()
            let loaded = await loadResolvedURL(track, url: url, durationMS: durationMS,
                generation: generation, resumeAt: position)
            guard generation == resolveGeneration, currentTrack?.id == track.id else { return }
            if case .loaded = loaded {
                scheduleLyricsResync()
                persistState()
                if let actual, !alwaysHighest, actual != quality {
                    ToastCenter.shared.show("当前可播放音质为\(actual.displayName)")
                }
            } else if let previousURL {
                servedQuality = previousQuality
                servedQishuiQualityOption = previousQishuiQualityOption
                reportingBitrate = previousBitrate
                duration = previousDuration
                NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
                isTrial = previousTrial
                unblockSource = previousUnblock
                externalQualityTitle = previousExternalTitle
                externalBitrate = previousExternalBitrate
                currentUnblockSourceID = previousSourceID
                transferredPreviousLeases = true
                let restored = await installResolvedAsset(AVURLAsset(url: previousURL), for: track,
                    generation: generation, durationMS: nil,
                    remoteURL: previousURL.isFileURL ? nil : previousURL,
                    cacheLease: previousCacheLease, offlineLease: previousOfflineLease,
                    resumeAt: position)
                guard generation == resolveGeneration, currentTrack?.id == track.id else { return }
                if case .loaded = restored {
                    scheduleLyricsResync()
                    ToastCenter.shared.show("音质切换失败，已恢复原音源")
                } else {
                    ToastCenter.shared.show("音质切换失败，请重试播放")
                }
            }
        } catch is CancellationError { return }
        catch {
            guard generation == resolveGeneration, currentTrack?.id == track.id else { return }
            ToastCenter.shared.show("音质切换失败，继续原音质播放")
        }
    }

    private func finishSeek() {
        guard let pendingSeek, engine.itemID == pendingSeek.itemID else { return }
        self.pendingSeek = nil
        progress = livePlaybackTime
        zzTrace("finishSeek progress=\(progress)")
        updateLyricsCursor(at: progress)
        lyricsCursor.seekRevision &+= 1
        NowPlayingManager.shared.updateElapsed(progress, rate: Double(engine.rate))
        let completion = seekCompletion
        seekCompletion = nil
        completion?()
        persistState()
    }

    private func clearEngine() {
        engineInstallationID = UUID()
        engine.onStateChanged = nil
        engine.onSeekCompleted = nil
        engine.onEnded = nil
        engine.onFailure = nil
        pendingSeek = nil
        let completion = seekCompletion
        seekCompletion = nil
        engine.clear()
        engine.httpDataSink = nil
        isBuffering = false
        completion?()
    }

    /// Reanchor from the engine before showing lyrics after system overlays or
    /// background suspension; a projected clock may span missed engine events.
    func refreshPlaybackPresentation() {
        samplePlaybackClock()
        updateLyricsCursor(at: livePlaybackTime)
        lyricsCursor.seekRevision &+= 1
    }

    private func samplePlaybackClock() {
        guard !isScrubbing, pendingSeek == nil,
              let seconds = engine.currentPlaybackTime, seconds.isFinite else { return }
        samplePlaybackReporting(position: seconds, advancing: isPlaying && engine.state == .playing && !isBuffering)
        updateLyricsCursor(at: seconds)
        if let actualDuration = engine.playbackDuration(referenceDuration: currentTrack?.duration ?? duration), abs(actualDuration - duration) > 0.1 {
            duration = actualDuration
            if let track = currentTrack { NowPlayingManager.shared.updateMetadata(for: track, duration: duration) }
        }
        if abs(seconds - progress) > 0.45 {
            progress = seconds
            NowPlayingManager.shared.updateElapsed(seconds, rate: Double(engine.rate))
        }
        if isPlaying, lastPlaybackCheckpoint.duration(to: .now) >= .seconds(20) { persistState() }
    }

    func toggleShuffle() {
        guard !isFMMode else { return }
        shuffleEnabled.toggle()
        guard let current = currentTrack else { return }
        if shuffleEnabled {
            reshuffle(keeping: current)
            currentIndex = 0
        } else {
            currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
    }

    func cycleRepeatMode() {
        guard !isFMMode else { return }
        repeatMode = repeatMode.next
    }

    /// Jump to a track in the upcoming list (queue panel click).
    func jumpTo(_ track: Track) {
        if let nextIdx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.removeSubrange(0...nextIdx)
            startPlaying(track)
            return
        }
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        }
    }

    func removeFromUpcoming(_ track: Track) {
        if let idx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.remove(at: idx)
            return
        }
        if let idx = queue.firstIndex(where: { $0.id == track.id }), idx != currentIndex || shuffleEnabled {
            queue.remove(at: idx)
        }
        if let idx = shuffledQueue.firstIndex(where: { $0.id == track.id }) {
            shuffledQueue.remove(at: idx)
        }
    }

    /// Queue rows carry their occurrence, so a repeated song selects the row
    /// the listener clicked rather than its first occurrence.
    func jumpToUpcoming(at index: Int, matching trackID: Int) {
        guard let selected = upcomingCandidate(at: index, matching: trackID) else { return }
        switch selected.origin {
        case .inserted(let offset):
            playNextList.removeSubrange(0...offset)
        case .queue(let offset):
            if !playNextList.isEmpty { playNextList.removeAll() }
            currentIndex = offset
        case .fm: return
        }
        startPlaying(selected.track)
    }

    /// Removes the row itself: a repeated song leaves the occurrence the
    /// listener chose, not its first one, so the current index stays put.
    func removeUpcoming(at index: Int, matching trackID: Int) {
        guard let selected = upcomingCandidate(at: index, matching: trackID) else { return }
        switch selected.origin {
        case .inserted(let offset): playNextList.remove(at: offset)
        case .queue(let offset): removeQueueRow(at: offset, trackID: selected.track.id)
        case .fm: return
        }
    }

    /// Match the displayed snapshot so a drag cannot edit a different row if
    /// playback advances before it is dropped. Index-based movement preserves
    /// separate occurrences of the same song.
    @discardableResult
    func moveUpcoming(from offsets: IndexSet, to destination: Int, matching trackIDs: [Int]) -> Bool {
        guard !isFMMode, upcomingTracks.map(\.id) == trackIDs,
              offsets.allSatisfy({ trackIDs.indices.contains($0) }),
              (0...trackIDs.count).contains(destination),
              let reordered = PlaybackQueuePlan.reorderingUpcoming(
                queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                from: offsets, to: destination
              ) else { return false }
        if shuffleEnabled {
            // Keep the canonical order's membership in sync when priority
            // entries are promoted; only the active shuffled order is edited.
            queue.append(contentsOf: playNextList)
            shuffledQueue = reordered
        } else {
            queue = reordered
        }
        playNextList.removeAll()
        persistState()
        return true
    }

    /// The row sits after the current index in the active order; the other
    /// order drops one copy of the same song so both stay the same length.
    private func removeQueueRow(at offset: Int, trackID: Int) {
        if shuffleEnabled {
            shuffledQueue.remove(at: offset)
            if let idx = queue.firstIndex(where: { $0.id == trackID }) { queue.remove(at: idx) }
        } else {
            queue.remove(at: offset)
            if let idx = shuffledQueue.firstIndex(where: { $0.id == trackID }) { shuffledQueue.remove(at: idx) }
        }
    }

    /// The row at `index` of `upcomingTracks`, if it still shows `trackID`.
    private func upcomingCandidate(at index: Int, matching trackID: Int) -> PlaybackQueueCandidate? {
        let candidates = PlaybackQueuePlan.next(queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                                                fm: [], isFM: false, repeatAll: false, limit: max(0, index + 1))
        guard candidates.indices.contains(index), candidates[index].track.id == trackID else { return nil }
        return candidates[index]
    }

    // MARK: - Personal FM

    func startFM(qqScene: QQMusicRecommendationMode? = nil) {
        let switchesScene = qqScene?.id != qqFMSceneID
        guard fmLoadID == nil, !isFMMode || !isPlaying || switchesScene else { return }
        if MusicProviderContext.shared.current == .qq {
            PlatformMusicAPI.shared.resetQQFM(scene: qqScene)
            // Songs prefetched for another mode must not play in this one.
            if switchesScene { fmUpcoming = [] }
            qqFMSceneID = qqScene?.id
        }
        qishuiContinuation.reset()
        qishuiFeedDrained = false
        recordRecent(.fm)
        isFMMode = true
        shuffleEnabled = false
        repeatMode = .off
        queue = []
        shuffledQueue = []
        playNextList = []
        currentIndex = -1
        source = .none
        Task { await fmAdvance() }
    }

    func fmNext() {
        guard isFMMode else { return }
        Task { await fmAdvance() }
    }

    func fmTrash() {
        guard isFMMode, let track = currentTrack else { return }
        Task {
            await fmAdvance()
            try? await NeteaseAPI.fmTrash(id: track.id)
        }
    }

    private func fmAdvance() async {
        guard isFMMode, fmLoadID == nil else { return }
        if usesOfflineQueue {
            advanceOffline()
            return
        }
        if fmUpcoming.isEmpty {
            pause()
            let requestID = UUID()
            fmLoadID = requestID
            let refill = await PersonalFMRefill.load { self.fmLoadID == requestID }
            if refill == .superseded { return }
            if case .loaded(let tracks) = refill { fmUpcoming = tracks }
            fmLoadID = nil
        }
        guard !fmUpcoming.isEmpty else { return }
        let track = fmUpcoming.removeFirst()
        pendingAutoAdvance = true
        startPlaying(track)
        if fmUpcoming.isEmpty {
            let generation = resolveGeneration
            if let more = try? await NeteaseAPI.personalFM(),
               isFMMode, fmLoadID == nil, generation == resolveGeneration {
                fmUpcoming.append(contentsOf: more)
            }
        }
    }

    // MARK: - Advancing

    private func advanceToNext(userInitiated: Bool) {
        if pendingQishuiScene != nil { cancelQishuiFeedLoad() }
        let step = PlaybackAdvancePlan.next(
            queueCount: activeQueue.count, currentIndex: currentIndex,
            hasPlayNext: !playNextList.isEmpty, isFM: isFMMode,
            offlineHasCandidates: usesOfflineQueue && !nextCandidates().isEmpty,
            repeatMode: repeatMode, qishuiFeed: source.qishuiFeed,
            isLoadingQishuiFeed: isLoadingQishuiFeed)
        switch step {
        case .offline:
            pendingAutoAdvance = !userInitiated
            advanceOffline()
        case .personalFM:
            Task { await fmAdvance() }
        case .playNext:
            let track = playNextList.removeFirst()
            pendingAutoAdvance = !userInitiated
            startPlaying(track)
        case .queue(let idx):
            currentIndex = idx
            pendingAutoAdvance = !userInitiated
            startPlaying(activeQueue[idx])
        case .loadMoreQishui(let feed):
            loadMoreQishui(feed, userInitiated: userInitiated)
        case .endOfQueue:
            if userInitiated {
                ToastCenter.shared.show(String(localized: "已经是最后一首了"))
            } else {
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            }
        case .waitForQishui, .idle:
            break
        }
    }

    private func loadMoreQishui(_ state: QishuiFeedState, userInitiated: Bool) {
        pause()
        qishuiFeedDrained = true
        isLoadingQishuiFeed = true
        qishuiContinuation.record(currentTrack, position: progress)
        let excluded = PlaybackAdvancePlan.qishuiExclusions(
            queue: queue, playNext: playNextList, current: currentTrack)
        qishuiContinuation.load(state, excluding: excluded) { [weak self] result in
            guard let self else { return }
            self.isLoadingQishuiFeed = false
            let message: String
            switch result {
            case .success(let batch):
                self.source = self.source.withQishuiFeed(batch.state)
                let tracks = batch.tracks
                if !tracks.isEmpty {
                    self.queue.append(contentsOf: tracks)
                    if self.shuffleEnabled { self.shuffledQueue.append(contentsOf: tracks) }
                    self.advanceToNext(userInitiated: userInitiated)
                    return
                }
                message = String(localized: "汽水暂时没有新的推荐歌曲")
            case .failure(let error):
                message = error.localizedDescription
            }
            self.persistState()
            ToastCenter.shared.show(message)
        }
    }

    private func handleItemEnded() {
        scrobbleIfNeeded(completed: true)

        if sleepTimer.consumeEndOfCurrentTrack() {
            progress = duration
            updateLyricsCursor(at: duration)
            pause()
            clearEngine()
            releaseCurrentPlaybackResources()
            return
        }

        guard isPlaying else { return }

        if repeatMode == .one, !isFMMode {
            scrobbled = false
            historySession = nil
            seek(to: 0)
            engine.play()
            isPlaying = true
            scrobbleStartIfNeeded()
            return
        }
        advanceToNext(userInitiated: false)
    }

    // MARK: - Source resolution

    private func startPlaying(_ track: Track,
                              localLease: OfflinePlaybackLease? = nil, resumeAt: TimeInterval = 0) {
        // No platform gate here: a track from another platform resolves
        // through its own platform in resolveAndLoad.
        fmLoadID = nil
        cancelQishuiFeedLoad()
        qishuiFeedDrained = false
        PlatformMusicAPI.shared.restore(track)
        offlineScan?.cancel()
        offlineScan = nil
        offlineScanID = UUID()
        offlineIssue = nil
        currentWasAdvanced = pendingAutoAdvance
        pendingAutoAdvance = false
        scrobbleIfNeeded(completed: false)
        clearEngine()
        releaseCurrentPlaybackResources()
        currentTrack = track
        playbackAccountID = AccountStore.shared.profile?.userId
        progress = resumeAt
        duration = track.duration
        reportingBitrate = nil
        servedQishuiQualityOption = nil
        servedQuality = nil
        unblockSource = nil
        currentUnblockSourceID = nil
        attemptedUnblockSources.removeAll()
        isTrial = false
        lyrics = nil
        resolvedLyricsSource = nil
        lyricsLoadFailed = false
        scrobbled = false
        historySession = nil
        isPlaying = true
        lyricsCursor.activeIndex = nil
        // Before the URL is even resolved: holds the bars still rather than
        // letting them fall back to the decorative animation for the moment it
        // takes to find out whether this source can be tapped.
        AudioSpectrum.shared.beginPreparing()
        resolveGeneration += 1
        let generation = resolveGeneration
        if advancingAfterFailure {
            advancingAfterFailure = false
        } else {
            consecutiveFailures = 0
        }

        NowPlayingManager.shared.updateMetadata(for: track, duration: track.duration)
        persistState()

        trackResolution?.task.cancel()
        let resolution = Task {
            defer {
                if trackResolution?.generation == generation { trackResolution = nil }
            }
            await resolveAndLoad(track, generation: generation, localLease: localLease, resumeAt: resumeAt)
        }
        trackResolution = (generation, resolution)
        Task {
            await loadLyrics(for: track, generation: generation)
        }
    }

    /// The stream address for a track from its own platform (QQ or Kugou),
    /// used when the current platform cannot serve it — a mixed playlist
    /// plays each song from where it was found. Returns nil for NetEase
    /// tracks and for Qishui, which already has its own branch above.
    private func ownPlatformURLString(for track: Track, quality: String) async -> String? {
        guard let song = track.platformSong else { return nil }
        let level = ProviderAudioQuality(rawValue: quality) ?? .hires
        switch song.source {
        case .qq:
            guard let mid = song.qqMid else { return nil }
            do {
                return try await QQMusicAPI.shared.songURL(songmid: mid, mediaMid: song.qqMediaMid, quality: level)
            } catch {
                return nil
            }
        case .kugou:
            do {
                return try await KugouMusicAPI.shared.songURL(song: song, quality: level)
            } catch {
                return nil
            }
        case .qishui, .netease:
            return nil
        }
    }

    /// - Parameter skipsLocalCopies: set when the downloaded or cached copy
    ///   just failed to play, so the reload fetches the song again instead
    ///   of the same file.
    private func resolveAndLoad(_ track: Track, generation: Int,
                                localLease: OfflinePlaybackLease? = nil,
                                skipsLocalCopies: Bool = false,
                                resumeAt: TimeInterval = 0) async {
        let settings = SettingsManager.shared
        // Resolve the real highest tier before choosing a local cache key. A
        // lower-tier prefetch must never silently override "always highest".
        var highestSource: SongURLData?
        if settings.alwaysHighestAudioQuality, networkState.connected, track.platformSong?.source != .qishui {
            highestSource = try? await NeteaseAPI.preferredSongURL(id: track.id,
                quality: settings.preferredPlaybackQuality, alwaysHighest: true)
            guard generation == resolveGeneration else { return }
        }
        let quality = highestSource?.resolvedAudioQuality?.rawValue ?? highestSource?.level ?? settings.preferredPlaybackQuality.rawValue
        let cacheEnabled = SettingsManager.shared.enableAudioCache && !skipsLocalCopies

        // A downloaded copy beats the network, and is all there is without one.
        if !skipsLocalCopies, let lease = await acquireOfflineLease(for: track, generation: generation, reusing: localLease, preferredQuality: quality) {
            await playOfflineFile(lease, for: track, generation: generation, resumeAt: resumeAt)
            return
        }
        guard generation == resolveGeneration else { return }

        if cacheEnabled {
            do {
                if let cached = try await AudioCache.shared.entry(
                    for: track.id,
                    requestedQuality: quality,
                    requiresServedQuality: MusicProviderContext.shared.current == .netease && !usesOfflineQueue
                ) {
                    guard generation == resolveGeneration else { return }
                    let lease = await AudioCache.shared.retain(cached)
                    guard generation == resolveGeneration else {
                        releaseAudioCacheLease(lease)
                        return
                    }
                    servedQuality = AudioQualityCheck.localLevel(url: cached.fileURL, reported: cached.metadata.servedQuality)
                    if case .unblock(let source) = cached.metadata.source {
                        unblockSource = source
                        externalQualityTitle = cachedQualityTitle(cached, track: track)
                    }
                    _ = await installResolvedAsset(
                        AVURLAsset(url: cached.fileURL),
                        for: track,
                        generation: generation,
                        durationMS: nil,
                        cacheLease: lease,
                        resumeAt: resumeAt
                    )
                    return
                }
            } catch {
                print("Audio cache lookup failed: \(error)")
            }
        }

        // Without a network, the cache is the last place to look.
        if usesOfflineQueue {
            if cacheEnabled, await loadFallbackCache(for: track, generation: generation, resumeAt: resumeAt) { return }
            guard generation == resolveGeneration else { return }
            unavailableOffline(track, generation: generation)
            return
        }

        var data: SongURLData?
        var qishuiRefusal: Error?
        do {
            if let highestSource {
                data = highestSource
            } else {
                data = try await NeteaseAPI.preferredSongURL(id: track.id,
                    quality: SettingsManager.shared.preferredPlaybackQuality,
                    alwaysHighest: SettingsManager.shared.alwaysHighestAudioQuality)
            }
        } catch {
            guard generation == resolveGeneration else { return }
            if track.platformSong?.source == .qishui {
                // Without membership or rights, look for the song elsewhere.
                guard (error as? QishuiError)?.invitesUnblock == true else {
                    isPlaying = false
                    ToastCenter.shared.show(error.localizedDescription)
                    return
                }
                qishuiRefusal = error
            } else if ConnectivityFailure.matches(error) {
                // A download covers a request that died on the network. Anything
                // else keeps upstream's path: third-party sources, then the cache.
                if let lease = await acquireOfflineLease(for: track, generation: generation, anyQuality: true) {
                    await playOfflineFile(lease, for: track, generation: generation, resumeAt: resumeAt)
                    return
                }
                guard generation == resolveGeneration else { return }
                if usesOfflineQueue {
                    if cacheEnabled, await loadFallbackCache(for: track, generation: generation, resumeAt: resumeAt) { return }
                    guard generation == resolveGeneration else { return }
                    unavailableOffline(track, generation: generation)
                    return
                }
            }
        }
        guard generation == resolveGeneration else { return }

        var resolvedURL: URL?
        if let urlString = data?.url {
            resolvedURL = track.playbackURL(urlString)
        }

        // NetEase refused the request. The song's own platform goes first: a
        // mixed playlist plays each song from where it was found; only then
        // look for the same recording elsewhere.
        if resolvedURL == nil || data?.freeTrialInfo != nil {
            if let own = await ownPlatformURLString(for: track, quality: quality),
               let ownURL = track.playbackURL(own) {
                resolvedURL = ownURL
                data = nil
            } else if await resolveAndLoadUnblocked(track, generation: generation, resumeAt: resumeAt) { return }
        }
        guard generation == resolveGeneration else { return }

        guard let url = resolvedURL else {
            if cacheEnabled, await loadFallbackCache(
                for: track,
                generation: generation,
                resumeAt: resumeAt
            ) {
                return
            }
            handleUnplayable(track, reason: qishuiRefusal?.localizedDescription)
            return
        }

        servedQuality = data?.resolvedAudioQuality?.rawValue ?? data?.level
        servedQishuiQualityOption = track.platformSong?.source == .qishui ? data?.qishuiQualityOption : nil
        reportingBitrate = data.flatMap { $0.br > 0 ? $0.br / 1000 : nil }
        if data?.freeTrialInfo != nil {
            isTrial = true
            ToastCenter.shared.show(String(localized: "VIP 歌曲，当前为试听片段"))
        }
        _ = await loadResolvedURL(track, url: url, durationMS: data?.time, generation: generation, resumeAt: resumeAt)
    }

    private func resolveAndLoadUnblocked(
        _ track: Track,
        generation: Int,
        requiresActivePlayback: Bool = false,
        resumeAt: TimeInterval = 0
    ) async -> Bool {
        guard generation == resolveGeneration,
              !requiresActivePlayback || isPlaying
        else { return false }

        let resolution = await UnblockResolver.resolve(
            track,
            quality: SettingsManager.shared.preferredPlaybackQuality,
            excluding: attemptedUnblockSources
        )
        attemptedUnblockSources.formUnion(resolution.attemptedSources)
        guard let unblocked = resolution.source else { return false }
        guard generation == resolveGeneration,
              !requiresActivePlayback || isPlaying
        else { return false }

        currentUnblockSourceID = unblocked.id
        unblockSource = unblocked.displayName
        externalQualityTitle = unblocked.title
        externalBitrate = unblocked.bitrate
        reportingBitrate = unblocked.bitrate.map { $0 / 1000 }
        servedQishuiQualityOption = nil
        servedQuality = unblocked.quality?.rawValue
        isTrial = false

        let loadResult = await loadResolvedURL(
            track,
            url: unblocked.url,
            durationMS: nil,
            generation: generation,
            resumeAt: resumeAt
        )
        guard case .loaded = loadResult else { return false }

        ToastCenter.shared.show(String(localized: "已使用 \(unblocked.displayName) 音源"))
        return true
    }

    private func handleUnplayable(_ track: Track, reason explicitReason: String? = nil) {
        consecutiveFailures += 1
        let reason = explicitReason ?? track.playability(privilege: nil,
                                       isLoggedIn: AccountStore.shared.isLoggedIn,
                                       vipType: AccountStore.shared.vipType).reason
        ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放\(reason.map { "：\($0)" } ?? "")"))
        guard isPlaying else {
            clearEngine()
            releaseCurrentPlaybackResources()
            return
        }
        if consecutiveFailures < 5 {
            advancingAfterFailure = true
            advanceToNext(userInitiated: false)
        } else {
            isPlaying = false
        }
    }

    private func loadResolvedURL(
        _ track: Track,
        url: URL,
        durationMS: Int?,
        generation: Int,
        resumeAt: TimeInterval = 0
    ) async -> ResolvedURLLoadResult {
        // Skip a CDN host that just failed to connect (see NeteaseCDNHost).
        let remote = url.isFileURL ? url : NeteaseCDNHost.preferred(for: url)

        return await installResolvedAsset(
            AVURLAsset(url: remote), for: track, generation: generation,
            durationMS: durationMS, remoteURL: remote.isFileURL ? nil : remote, resumeAt: resumeAt
        )
    }

    private func loadFallbackCache(
        for track: Track,
        generation: Int,
        resumeAt: TimeInterval = 0
    ) async -> Bool {
        do {
            guard let cached = try await AudioCache.shared.fallbackEntry(for: track.id) else { return false }
            guard generation == resolveGeneration else { return true }
            let lease = await AudioCache.shared.retain(cached)
            guard generation == resolveGeneration else {
                releaseAudioCacheLease(lease)
                return true
            }
            servedQuality = AudioQualityCheck.localLevel(url: cached.fileURL, reported: cached.metadata.servedQuality)
            servedQishuiQualityOption = nil
            if case .unblock(let source) = cached.metadata.source {
                unblockSource = source
                externalQualityTitle = cachedQualityTitle(cached, track: track)
            }
            _ = await installResolvedAsset(
                AVURLAsset(url: cached.fileURL),
                for: track,
                generation: generation,
                durationMS: nil,
                cacheLease: lease,
                resumeAt: resumeAt
            )
            return true
        } catch {
            print("Audio cache fallback lookup failed: \(error)")
            return false
        }
    }

    /// The bitrate the source reported when the file was cached; only older
    /// entries without one fall back to measuring the file.
    private func cachedQualityTitle(_ cached: AudioCacheEntry, track: Track) -> String? {
        servedQuality.flatMap(AudioQuality.init(rawValue:)).map { quality in
            if let bitrate = cached.metadata.servedBitrate {
                return AudioQualityOption.unifiedTitle(quality: quality, bitrate: Double(bitrate))
            }
            return AudioQualityOption.unifiedLocal(url: cached.fileURL, quality: quality, duration: track.duration).title
        }
    }

    private func installResolvedAsset(
        _ asset: AVURLAsset,
        for track: Track,
        generation: Int,
        durationMS: Int?,
        remoteURL: URL? = nil,
        cacheLease: UUID? = nil,
        offlineLease: OfflinePlaybackLease? = nil,
        resumeAt: TimeInterval = 0
    ) async -> ResolvedURLLoadResult {
        guard generation == resolveGeneration else {
            if let cacheLease { releaseAudioCacheLease(cacheLease) }
            if let offlineLease { Task { try? await OfflineStore.shared.release(offlineLease) } }
            return .superseded
        }
        clearEngine()
        releaseCurrentPlaybackResources()
        audioCacheLease = cacheLease
        offlinePlaybackLease = offlineLease
        let installationID = engineInstallationID
        let sourceID = currentUnblockSourceID
        if let remoteURL, SettingsManager.shared.enableAudioCache, !isTrial {
            let writer = await StreamingAudioCacheWriter.make(
                url: remoteURL, track: track,
                requestedQuality: SettingsManager.shared.alwaysHighestAudioQuality
                    ? (servedQuality ?? SettingsManager.shared.preferredPlaybackQuality.rawValue)
                    : SettingsManager.shared.preferredPlaybackQuality.rawValue,
                servedQuality: servedQuality,
                source: unblockSource.map(AudioCacheSource.unblock) ?? .netease,
                servedBitrate: unblockSource == nil ? nil : externalBitrate,
                scope: AccountStore.shared.offlineScope)
            guard generation == resolveGeneration, installationID == engineInstallationID else {
                writer?.cancel()
                return .superseded
            }
            streamCache = writer
            engine.httpDataSink = writer.map { writer in { chunk in writer.receive(chunk) } }
        }
        engine.sampleSink = AudioSpectrum.shared.makeStreamingSink()
        engine.onStateChanged = { [weak self] in
            guard let self, generation == self.resolveGeneration, installationID == self.engineInstallationID else { return }
            self.isBuffering = self.engine.state == .loading
            self.updateLyricsCursor(at: self.livePlaybackTime)
            NowPlayingManager.shared.updateElapsed(self.livePlaybackTime, rate: Double(self.engine.rate))
        }
        engine.onSeekCompleted = { [weak self] in
            guard let self, installationID == self.engineInstallationID else { return }
            self.finishSeek()
        }
        engine.onEnded = { [weak self] in
            guard let self, generation == self.resolveGeneration, installationID == self.engineInstallationID else { return }
            self.progress = self.engine.currentPlaybackTime ?? self.duration
            self.handleItemEnded()
        }
        engine.onFailure = { [weak self] error in
            // Leave the delegate stack before replacing/discarding its player.
            Task { @MainActor in
                guard let self, generation == self.resolveGeneration, installationID == self.engineInstallationID else { return }
                // A quality replacement owns its rollback. It must not trigger
                // the ordinary failure path that may advance to another song.
                guard !self.isReplacingQualityStream else { return }
                if let sourceID {
                    self.handleUnblockItemFailure(track: track, generation: generation, sourceID: sourceID)
                } else {
                    self.handleItemFailure(track: track, generation: generation, remoteURL: remoteURL,
                                           durationMS: durationMS, error: error)
                }
            }
        }
        if let durationMS, durationMS > 0 {
            duration = TimeInterval(durationMS) / 1000
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        }
        let length = durationMS.map { TimeInterval($0) / 1000 } ?? duration
        let initialPosition = max(0, length > 0.1 ? min(resumeAt, length - 0.1) : resumeAt)
        zzTrace("install start=\(initialPosition) resumeAt=\(resumeAt) file=\(asset.url.isFileURL) ext=\(asset.url.pathExtension)")
        let extendedBuffer = !asset.url.isFileURL
            && ["lossless", "hires", "jyeffect", "sky", "jymaster"].contains(servedQuality ?? "")
        let loaded = await engine.load(asset.url, identifier: track.id, startAt: initialPosition,
                                       autoplay: isPlaying, bufferDuration: extendedBuffer ? 16 : 8)
        guard generation == resolveGeneration, installationID == engineInstallationID else { return .superseded }
        if loaded {
            itemBecameReady(generation: generation)
            if track.platformSong?.source == .qishui, asset.url.isFileURL,
               let option = AudioQualityOption.qishuiLocal(url: asset.url, level: servedQuality, duration: duration) {
                servedQishuiQualityOption = option
            }
            progress = livePlaybackTime
            updateLyricsCursor(at: progress)
            lyricsCursor.seekRevision &+= 1
            if isPlaying { scrobbleStartIfNeeded() }
            zzTrace("install loaded t=\(String(describing: engine.currentPlaybackTime)) progress=\(progress)")
        }
        return loaded ? .loaded : .superseded
    }

    private func handleUnblockItemFailure(
        track: Track,
        generation: Int,
        sourceID: AudioSourceID
    ) {
        guard generation == resolveGeneration,
              currentTrack?.id == track.id,
              currentUnblockSourceID == sourceID
        else { return }

        currentUnblockSourceID = nil
        unblockSource = nil
        clearEngine()
        releaseCurrentPlaybackResources()
        AudioSpectrum.shared.beginPreparing()

        guard isPlaying else {
            return
        }

        Task {
            let loaded = await resolveAndLoadUnblocked(
                track,
                generation: generation,
                requiresActivePlayback: true
            )
            guard isPlaying else { return }
            guard loaded else {
                guard generation == resolveGeneration else { return }
                handleUnplayable(track)
                return
            }
        }
    }

    /// The song is playing for real: the failure streak is over.
    private func itemBecameReady(generation: Int) {
        guard generation == resolveGeneration else { return }
        consecutiveFailures = 0
    }

    /// A NetEase stream or a cached file failed. The song gets one reload,
    /// resuming where it stopped: on the CDN twin when the host could not be
    /// reached (the caching loader already swaps hosts itself, so this covers
    /// streams that bypass it), otherwise from a freshly resolved URL, since a
    /// signature may have expired, the network changed, or the local file
    /// was bad. With no network at all, or when the reload fails for lack of
    /// one, a downloaded copy takes over; any other second failure goes to the
    /// third-party sources, then skips.
    private func handleItemFailure(
        track: Track,
        generation: Int,
        remoteURL: URL?,
        durationMS: Int?,
        error: Error?
    ) {
        guard generation == resolveGeneration,
              currentTrack?.id == track.id,
              currentUnblockSourceID == nil
        else { return }

        clearEngine()
        releaseCurrentPlaybackResources()
        let connectivity = error.map(ConnectivityFailure.matches) ?? false

        guard itemRetryGeneration != generation else {
            if connectivity {
                handleConnectivityItemFailure(track: track, generation: generation)
                return
            }
            Task {
                guard await resolveAndLoadUnblocked(track, generation: generation) else {
                    guard generation == resolveGeneration else { return }
                    handleUnplayable(track)
                    return
                }
            }
            return
        }
        itemRetryGeneration = generation
        let twin = remoteURL.flatMap { url in
            error.flatMap { NeteaseCDNHost.failover(from: url, after: $0) }
        }
        // No network at all: the downloaded copy is the only way on.
        if twin == nil, connectivity, usesOfflineQueue {
            handleConnectivityItemFailure(track: track, generation: generation)
            return
        }
        AudioSpectrum.shared.beginPreparing()
        let resumeAt = progress > 1 ? progress : 0
        zzTrace("itemFailure resumeAt=\(resumeAt) error=\(String(describing: error))")
        Task {
            if let twin {
                _ = await loadResolvedURL(track, url: twin, durationMS: durationMS, generation: generation, resumeAt: resumeAt)
            } else {
                await resolveAndLoad(track, generation: generation, skipsLocalCopies: remoteURL == nil, resumeAt: resumeAt)
            }
        }
    }

    private func releaseAudioCacheLease(_ leaseID: UUID) {
        Task {
            do {
                try await AudioCache.shared.release(leaseID)
            } catch {
                print("Audio cache could not release its playback lease: \(error)")
            }
        }
    }

    private func releaseCurrentPlaybackResources() {
        let cacheLease = audioCacheLease
        audioCacheLease = nil
        streamCache?.cancel()
        streamCache = nil
        if let cacheLease {
            releaseAudioCacheLease(cacheLease)
        }
        releaseOfflineLease()
    }

    private func displayLyrics(_ response: LyricResponse) {
        lyrics = LyricsParser.parse(response, track: currentTrack)
    }

    func selectLyricsSource(_ source: LyricsSource) async {
        guard let track = currentTrack else { return }
        lyricsLoad?.task.cancel()
        lyricsLoad = nil
        source.save(for: track.id)
        await loadLyrics(for: track, generation: resolveGeneration, userInitiated: true)
        scheduleLyricsResync()
    }

    func loadCurrentLyricsIfNeeded() async {
        guard lyrics == nil, let track = currentTrack else { return }
        await loadLyrics(for: track, generation: resolveGeneration)
    }

    private func loadLyrics(for track: Track, generation: Int, userInitiated: Bool = false) async {
        guard generation == resolveGeneration, currentTrack?.id == track.id else { return }
        if let pending = lyricsLoad, pending.trackID == track.id, pending.generation == generation {
            await pending.task.value
            return
        }
        lyricsLoad?.task.cancel()
        lyricsLoadFailed = false
        // Owned by the player, so closing the lyric view does not cancel a
        // useful request. Startup and presentation share this same task.
        let requestID = UUID()
        lyricsRequestID = requestID
        let source = LyricsSource.saved(for: track.id)
        if lyrics == nil { lyricsSource = source }
        lyricsSourceLoading = true
        let task = Task { await fetchLyrics(for: track, generation: generation, source: source, requestID: requestID, userInitiated: userInitiated) }
        lyricsLoad = (track.id, generation, requestID, task)
        await task.value
        if lyricsLoad?.requestID == requestID {
            lyricsLoad = nil
        }
    }

    private func fetchLyrics(for track: Track, generation: Int, source: LyricsSource, requestID: UUID, userInitiated: Bool) async {
        let scope = offlineAccountScope
        defer { if lyricsRequestID == requestID { lyricsSourceLoading = false } }
        do {
            guard !usesOfflineQueue else { throw URLError(.notConnectedToInternet) }
            let selection = try await AlternativeLyricsAPI.resolve(track: track, source: source, onUpdate: { [weak self] interim in
                await MainActor.run {
                    guard let self, self.lyricsRequestID == requestID,
                          self.resolveGeneration == generation, self.currentTrack?.id == track.id else { return }
                    self.displayLyrics(interim.response)
                    self.lyricsSource = source
                    self.resolvedLyricsSource = interim.source
                    self.updateLyricsCursor(at: self.livePlaybackTime)
                }
            })
            guard !Task.isCancelled, lyricsRequestID == requestID,
                  generation == resolveGeneration, currentTrack?.id == track.id else { return }
            displayLyrics(selection.response)
            lyricsSource = source
            resolvedLyricsSource = selection.source
            updateLyricsCursor(at: livePlaybackTime)
            if let scope, SettingsManager.shared.enableAudioCache || DownloadManager.shared.isDownloaded(trackID: track.id) {
                await OfflineMetadataStore.shared.keepPlaybackData(track: track, scope: scope)
            }
        } catch {
            guard !Task.isCancelled, lyricsRequestID == requestID,
                  generation == resolveGeneration, currentTrack?.id == track.id else { return }
            lyricsLoadFailed = lyrics == nil
            // Keep the displayed lyrics and their selection if a replacement fails.
            if lyrics != nil { lyricsSource.save(for: track.id) }
            if let message = source.failureToast(for: error, userInitiated: userInitiated, keptLyrics: !(lyrics?.isEmpty ?? true)) {
                ToastCenter.shared.show(message)
            }
        }
    }

    // MARK: - Offline playback

    /// Downloads belong to one account; see `activateAccount`.
    private var offlineAccountScope: String? { AccountStore.shared.offlineScope }
    private var usesOfflineQueue: Bool { networkState.isKnown && !networkState.connected }

    private func nextCandidates() -> [PlaybackQueueCandidate] {
        PlaybackQueuePlan.next(queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                               fm: fmUpcoming, isFM: isFMMode, repeatAll: repeatMode == .all && source.qishuiFeed == nil)
    }

    /// Everything the prefetch window depends on. `@Published` fires before
    /// the value lands, so the update itself waits for the next turn.
    private func observePrefetchInputs() {
        let player: [AnyPublisher<Void, Never>] = [
            $queue.map { _ in }.eraseToAnyPublisher(), $shuffledQueue.map { _ in }.eraseToAnyPublisher(),
            $shuffleEnabled.map { _ in }.eraseToAnyPublisher(), $playNextList.map { _ in }.eraseToAnyPublisher(),
            $currentIndex.map { _ in }.eraseToAnyPublisher(), $currentTrack.map { _ in }.eraseToAnyPublisher(),
            $fmUpcoming.map { _ in }.eraseToAnyPublisher(), $isFMMode.map { _ in }.eraseToAnyPublisher(),
            $repeatMode.map { _ in }.eraseToAnyPublisher(), $isPlaying.map { _ in }.eraseToAnyPublisher(),
            $isBuffering.map { _ in }.eraseToAnyPublisher(),
        ]
        let environment: [AnyPublisher<Void, Never>] = [
            DownloadManager.shared.$network.map { _ in }.eraseToAnyPublisher(),
            DownloadManager.shared.$jobs.map { _ in }.eraseToAnyPublisher(),
            SettingsManager.shared.$enableAudioCache.map { _ in }.eraseToAnyPublisher(),
            SettingsManager.shared.$audioQuality.map { _ in }.eraseToAnyPublisher(),
            SettingsManager.shared.$alwaysHighestAudioQuality.map { _ in }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(player + environment)
            .sink { [weak self] _ in self?.scheduleUpdatePrefetch() }
            .store(in: &prefetchObservations)
    }

    private func scheduleUpdatePrefetch() {
        guard !prefetchUpdateScheduled else { return }
        prefetchUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.prefetchUpdateScheduled = false
            self.updatePrefetch()
        }
    }

    private func updatePrefetch() {
        guard isPlaying, !isBuffering, SettingsManager.shared.enableAudioCache,
              let current = currentTrack,
              QueuePrefetcher.permits(network: networkState, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        else { cancelQishuiPrefetch(); queuePrefetcher.update(nil); return }
        if current.platformSong?.source == .qishui {
            queuePrefetcher.update(nil)
            guard let next = nextCandidates().first?.track.platformSong?.qishui?.trackID else {
                cancelQishuiPrefetch()
                return
            }
            let quality = SettingsManager.shared.preferredPlaybackQuality
            guard qishuiPrefetch?.trackID != next || qishuiPrefetch?.quality != quality else { return }
            cancelQishuiPrefetch()
            qishuiPrefetch = (next, quality, Task {
                _ = try? await QishuiMusicAPI.shared.playback(trackID: next, quality: quality)
            })
            return
        }
        cancelQishuiPrefetch()
        guard !SettingsManager.shared.alwaysHighestAudioQuality else { queuePrefetcher.update(nil); return }
        let upcoming = PrefetchLimits().window(nextCandidates().map(\.track))
        guard !upcoming.isEmpty else { queuePrefetcher.update(nil); return }
        let scope = offlineAccountScope
        let pending = Set(DownloadManager.shared.pendingJobs.filter { $0.accountScope == scope }.map(\.track.id))
        queuePrefetcher.update(.init(scope: scope, currentTrackID: current.id, tracks: upcoming,
                                     quality: SettingsManager.shared.preferredPlaybackQuality.rawValue,
                                     pendingDownloadTrackIDs: pending))
    }

    private func cancelQishuiPrefetch() {
        qishuiPrefetch?.task.cancel()
        qishuiPrefetch = nil
    }

    /// A downloaded copy of the track. Online it must match the chosen quality
    /// or better; offline, any quality will do.
    private func acquireOfflineLease(for track: Track, generation: Int, reusing lease: OfflinePlaybackLease? = nil,
                                     anyQuality: Bool = false,
                                     preferredQuality: String? = nil) async -> OfflinePlaybackLease? {
        let scope = offlineAccountScope
        var lease = lease
        if lease == nil, let scope {
            lease = try? await OfflineStore.shared.acquire(accountScope: scope, trackID: track.id,
                preferredQuality: preferredQuality ?? SettingsManager.shared.preferredPlaybackQuality.rawValue,
                allowLowerQuality: anyQuality || !networkState.connected)
        }
        guard let lease else { return nil }
        guard generation == resolveGeneration, scope == offlineAccountScope,
              lease.descriptor.identity.accountScope == scope else {
            try? await OfflineStore.shared.release(lease)
            return nil
        }
        return lease
    }

    private func playOfflineFile(_ lease: OfflinePlaybackLease, for track: Track, generation: Int,
                                 resumeAt: TimeInterval = 0) async {
        servedQishuiQualityOption = nil
        servedQuality = AudioQualityCheck.localLevel(url: lease.url, reported: lease.descriptor.identity.quality)
        _ = await installResolvedAsset(AVURLAsset(url: lease.url), for: track, generation: generation,
                                       durationMS: Int(lease.descriptor.duration * 1000),
                                       offlineLease: lease, resumeAt: resumeAt)
    }

    /// The stream died for lack of network. A download of the same song picks
    /// up where it stopped; otherwise the song is reported or skipped.
    private func handleConnectivityItemFailure(track: Track, generation: Int) {
        guard generation == resolveGeneration, currentTrack?.id == track.id else { return }
        let position = max(progress, livePlaybackTime)
        resolveGeneration += 1
        let recovery = resolveGeneration
        clearEngine()
        releaseCurrentPlaybackResources()
        Task {
            if let lease = await acquireOfflineLease(for: track, generation: recovery, anyQuality: true) {
                await playOfflineFile(lease, for: track, generation: recovery, resumeAt: position)
                return
            }
            guard recovery == resolveGeneration else { return }
            unavailableOffline(track, generation: recovery, autoAdvance: currentWasAdvanced && position < 0.5)
        }
    }

    private func releaseOfflineLease() {
        guard let lease = offlinePlaybackLease else { return }
        offlinePlaybackLease = nil
        Task { try? await OfflineStore.shared.release(lease) }
    }

    private func unavailableOffline(_ track: Track, generation: Int, autoAdvance: Bool? = nil) {
        guard generation == resolveGeneration else { return }
        if autoAdvance ?? currentWasAdvanced {
            advanceOffline(initialSkipped: 1, excludingFailedCurrent: true)
            return
        }
        clearEngine()
        releaseCurrentPlaybackResources()
        isPlaying = false
        isBuffering = false
        offlineIssue = .init(kind: .missingTrack, trackName: track.name)
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    func playNextAvailableOffline() {
        offlineIssue = nil
        advanceOffline()
    }

    /// Walks the upcoming list for the first song that is on this device.
    private func advanceOffline(initialSkipped: Int = 0, excludingFailedCurrent: Bool = false) {
        offlineScan?.cancel()
        let requestID = UUID()
        offlineScanID = requestID
        resolveGeneration += 1
        let generation = resolveGeneration
        let scope = offlineAccountScope
        var candidates = nextCandidates()
        if excludingFailedCurrent { candidates.removeAll { $0.origin == .queue(currentIndex) } }
        clearEngine()
        releaseCurrentPlaybackResources()
        isPlaying = false
        offlineScan = Task { [weak self] in
            guard let self, !Task.isCancelled, self.offlineScanID == requestID else { return }
            let selected = try? await OfflineQueueSelector.firstAvailable(candidates, scope: scope,
                quality: SettingsManager.shared.preferredPlaybackQuality.rawValue, store: .shared,
                isCached: { await self.isCachedForOffline($0) })
            guard !Task.isCancelled, self.offlineScanID == requestID, self.resolveGeneration == generation,
                  self.offlineAccountScope == scope else {
                if let lease = selected?.lease { try? await OfflineStore.shared.release(lease) }
                return
            }
            self.offlineScan = nil
            guard let selected else {
                self.pendingAutoAdvance = false
                self.offlineIssue = .init(kind: .emptyQueue, trackName: nil)
                self.isBuffering = false
                NowPlayingManager.shared.updateElapsed(self.progress, rate: 0)
                return
            }
            // The queue may have been edited while the scan ran.
            guard self.stillHolds(selected.candidate) else {
                if let lease = selected.lease { try? await OfflineStore.shared.release(lease) }
                self.advanceOffline(initialSkipped: initialSkipped, excludingFailedCurrent: excludingFailedCurrent)
                return
            }
            switch selected.candidate.origin {
            case .inserted(let index): self.playNextList.removeSubrange(0...index)
            case .queue(let index):
                if !self.playNextList.isEmpty { self.playNextList.removeAll() }
                self.currentIndex = index
            case .fm(let index): self.fmUpcoming.removeSubrange(0...index)
            }
            let skipped = initialSkipped + selected.skipped
            self.pendingAutoAdvance = true
            self.startPlaying(selected.candidate.track, localLease: selected.lease)
            if skipped > 0 { ToastCenter.shared.show(String(localized: "已跳过 \(skipped) 首未下载歌曲")) }
        }
    }

    /// Whether the song cache can play the track without the network.
    private func isCachedForOffline(_ trackID: Int) async -> Bool {
        guard SettingsManager.shared.enableAudioCache else { return false }
        return (try? await AudioCache.shared.fallbackEntry(for: trackID)) != nil
    }

    private func stillHolds(_ candidate: PlaybackQueueCandidate) -> Bool {
        switch candidate.origin {
        case .inserted(let index): return playNextList.indices.contains(index) && playNextList[index].id == candidate.track.id
        case .queue(let index): return activeQueue.indices.contains(index) && activeQueue[index].id == candidate.track.id
        case .fm(let index): return fmUpcoming.indices.contains(index) && fmUpcoming[index].id == candidate.track.id
        }
    }

    /// Downloads belong to one account. Audio leased under the previous
    /// account stops, and the offline queue scan starts over.
    func activateAccount(scope: String?) {
        guard offlineActivatedScope != scope else { return }
        offlineActivatedScope = scope
        offlineScan?.cancel()
        offlineScan = nil
        offlineScanID = UUID()
        offlineIssue = nil
        scheduleUpdatePrefetch()
        guard offlinePlaybackLease != nil else { return }
        resolveGeneration += 1
        clearEngine()
        releaseCurrentPlaybackResources()
        isPlaying = false
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    // MARK: - Scrobble

    private func samplePlaybackReporting() {
        guard !isScrubbing, pendingSeek == nil else { return }
        samplePlaybackReporting(position: engine.currentPlaybackTime ?? progress,
            advancing: isPlaying && !isBuffering && engine.state == .playing)
    }


    private func samplePlaybackReporting(position: TimeInterval, advancing: Bool) {
        kugouReporter.sample(position: position, advancing: advancing)
        qishuiHistoryReporter.sample(position: position, advancing: advancing)
    }

    private func scrobbleStartIfNeeded() {
        guard let track = currentTrack else { return }
        if !isTrial { qishuiHistoryReporter.begin(track) }
        kugouReporter.begin(track: track, position: engine.currentPlaybackTime ?? progress)
        guard historySession == nil else { return }
        let sourceID = source.sourceID > 0 ? source.sourceID : track.album.id
        historySession = historyReporter.start(trackID: track.id, sourceID: sourceID,
            duration: track.duration, quality: servedQuality, fee: track.fee, bitrate: reportingBitrate)
    }

    private func scrobbleIfNeeded(completed: Bool) {
        qishuiHistoryReporter.finish()
        if source.qishuiFeed != nil { qishuiContinuation.record(currentTrack, position: progress) }
        kugouReporter.finish(position: engine.currentPlaybackTime ?? progress, completed: completed)
        guard let session = historySession, !scrobbled else { return }
        scrobbled = true
        historyReporter.finish(session, playbackTime: progress, duration: duration, completed: completed)
    }

    // MARK: - Shuffle helpers

    private func reshuffle(keeping first: Track) {
        var rest = queue
        if let index = rest.firstIndex(where: { $0.id == first.id }) { rest.remove(at: index) }
        rest.shuffle()
        shuffledQueue = [first] + rest
    }

    // MARK: - Persistence

    private static let recentContextsLimit = 6

    private func recordRecent(_ context: PlayContext) {
        recentContexts.removeAll { $0 == context }
        recentContexts.insert(context, at: 0)
        if recentContexts.count > Self.recentContextsLimit {
            recentContexts.removeLast(recentContexts.count - Self.recentContextsLimit)
        }
    }

    /// Reloads a place from the recents list and starts playing it again.
    func play(context: PlayContext) {
        // Personal FM is a stream, not a fixed list — restart it in place.
        guard context.kind != .fm else { return startFM() }
        Task {
            do {
                guard let resolved = try await resolve(context) else { return }
                play(tracks: resolved.tracks, source: resolved.source, context: context)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    func resolve(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        try await OfflineContextResolver.resolve(context, offline: usesOfflineQueue) { try await resolveOnline(context) }
    }

    private func resolveOnline(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        switch context.kind {
        case .fm:
            return nil
        case .album:
            return (try await NeteaseAPI.album(id: context.id).songs, .album(context.id))
        case .artist:
            return (try await NeteaseAPI.artist(id: context.id).hotSongs, .artist(context.id))
        case .daily:
            return (try await NeteaseAPI.dailyRecommendSongs(), .daily)
        case .cloud:
            let songs = try await NeteaseAPI.cloudSongs().data?.compactMap(\.simpleSong) ?? []
            return (songs, .cloud)
        case .recents:
            if MusicProviderContext.shared.current == .qishui {
                return (try await NeteaseAPI.recentSongs().map(\.song), .none)
            }
            guard let uid = AccountStore.shared.profile?.userId else { return nil }
            return (try await NeteaseAPI.playRecords(uid: uid, week: false).map(\.song), .none)
        case .heartbeat:
            // Regenerated from a fresh seed, the same way the Home card does it.
            guard let liked = AccountStore.shared.likedSongsPlaylist,
                  let seed = AccountStore.shared.likedTrackIDs.randomElement() else { return nil }
            let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: liked.id)
            return (tracks, .playlist(liked.id))
        case .playlist:
            let response = try await NeteaseAPI.playlistDetail(id: context.id)
            if response.playlist.qishuiFeed != nil {
                return (response.playlist.tracks, response.playlist.playSource)
            }
            var tracks = response.playlist.tracks
            // /v6/playlist/detail only carries the first page of tracks.
            let remaining = response.playlist.trackIds.map(\.id).dropFirst(tracks.count)
            for chunk in stride(from: 0, to: remaining.count, by: 500)
                .map({ Array(remaining.dropFirst($0).prefix(500)) }) {
                guard let more = try? await NeteaseAPI.songDetails(ids: chunk) else { break }
                tracks += more.songs
            }
            return (tracks, .playlist(context.id))
        }
    }

    var playbackSession: PlaybackSession? {
        guard let currentTrack else { return nil }
        return PlaybackSession(accountID: playbackAccountID, queue: queue, orderedQueue: activeQueue,
                               currentIndex: currentIndex, currentTrack: currentTrack, playNext: playNextList,
                               source: source, repeatMode: repeatMode.rawValue, shuffled: shuffleEnabled,
                               automaticOrder: false, isFM: isFMMode, progress: progress)
    }

    func resume(_ session: PlaybackSession) throws {
        let accountID = AccountStore.shared.authenticatedAccountID
        try session.validateAccess(accountID: accountID)
        scrobbleIfNeeded(completed: false)
        pause()
        applyPlaybackSession(session)
        startPlaying(session.currentTrack, resumeAt: session.progress)
    }

    private func applyPlaybackSession(_ session: PlaybackSession) {
        // Materialize a Mac AutoMix order on iOS, which has no AutoMix engine.
        queue = session.automaticOrder ? session.orderedQueue : session.queue
        shuffledQueue = session.shuffled ? session.orderedQueue : []
        shuffleEnabled = session.shuffled
        currentIndex = session.currentIndex
        currentTrack = session.currentTrack
        playbackAccountID = session.accountID
        playNextList = session.playNext
        qishuiContinuation.reset()
        qishuiFeedDrained = false
        source = PlatformMusicAPI.shared.restoredPlaySource(session.source)
        if let mode = RepeatMode(rawValue: session.repeatMode) { repeatMode = mode }
        isFMMode = session.isFM
        fmUpcoming = []
        progress = session.progress
        duration = session.currentTrack.duration
        scrobbled = true
    }

    func checkpointPlayback() { samplePlaybackReporting(); persistState() }

    func finishPlaybackReporting() async {
        pause()
        kugouReporter.finish(position: engine.currentPlaybackTime ?? progress, completed: false)
        await kugouReporter.waitForPendingSubmissions(timeout: 3)
    }

    func suspendForAccountChange() {
        qishuiHistoryReporter.finish()
        resolveGeneration += 1
        trackResolution?.task.cancel()
        trackResolution = nil
        cancelQishuiPrefetch()
        scrobbled = true
        pause()
        clearEngine()
        releaseCurrentPlaybackResources()
    }

    func resetForMusicAccountChange() {
        suspendForAccountChange()
        qishuiContinuation.reset()
        qishuiFeedDrained = false
        queue = []; shuffledQueue = []; playNextList = []
        currentTrack = nil; currentIndex = -1
        recentContexts = []; source = .none; fmUpcoming = []
        progress = 0; duration = 0
        isPlaying = false; isBuffering = false; isFMMode = false
        showNowPlaying = false
        audioQualityBadgeState = nil
        lyricsLoad?.task.cancel(); lyricsLoad = nil
        lyricsRequestID = UUID(); lyrics = nil
        lyricsSourceLoading = false
        persistState()
        NowPlayingManager.shared.clear()
    }

    private func persistState() {
        lastPlaybackCheckpoint = .now
        let state = PlaybackState(session: playbackSession, recentContexts: recentContexts, audioQualityBadge: audioQualityBadgeState)
        PlaybackStateStorage.save(state, to: Self.stateFileURL)
    }

    private func restoreState() {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let state = try? JSONDecoder().decode(PlaybackState.self, from: data)
        else { return }
        // Recents outlive the queue: restore them before bailing out on an
        // empty queue, or the next played track persists an empty list over
        // them and the Dock menu loses its history for good.
        recentContexts = Array((state.recentContexts ?? []).prefix(Self.recentContextsLimit))
        if let session = state.session {
            do {
                try session.validate()
                guard (session.currentTrack.platformSong?.source.rawValue ?? "netease") == MusicProviderContext.shared.current.rawValue else { recentContexts = []; return }
                session.queue.forEach { PlatformMusicAPI.shared.restore($0) }
                applyPlaybackSession(session)
                audioQualityBadgeState = state.audioQualityBadge
                NowPlayingManager.shared.updateMetadata(for: session.currentTrack, duration: duration)
            } catch { ToastCenter.shared.show(error.localizedDescription) }
            return
        }
        guard MusicProviderContext.shared.current == .netease, let legacy = state.legacy, !legacy.queue.isEmpty else { return }
        queue = legacy.queue
        shuffleEnabled = legacy.shuffle
        if shuffleEnabled {
            shuffledQueue = queue.shuffled()
        }
        if let id = legacy.currentID,
           let idx = activeQueue.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
            currentTrack = activeQueue[idx]
            duration = activeQueue[idx].duration
            NowPlayingManager.shared.updateMetadata(for: activeQueue[idx], duration: duration)
        }
    }

    private static var stateFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coda", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("player-state.json")
    }
}
#endif

#if os(iOS)
import os
private let zzLog = Logger(subsystem: "wow.caicai.coda.zz", category: "seek")
func zzTrace(_ m: String) { zzLog.notice("ZZ \(m, privacy: .public)") }
#endif
