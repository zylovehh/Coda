// macOS player: the dual-deck `PlaybackEngine` with AutoMix, stems and the
// output-device picker. iOS never gets AutoMix and keeps the original
// AVPlayer-based `PlayerService` in PlayerServiceIOS.swift (kept identical to
// the pre-AutoMix file). Exactly one of the two compiles per platform, so
// every call site sees a single `PlayerService`; anything shared UI calls on
// it must exist in both, or be guarded with `#if os(macOS)` at the call site.
#if os(macOS)
import Combine
import AVFoundation
import Foundation

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
/// lyrics and playback history, backed by the Mac playback engine.
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
    /// The AutoMix order's working list: `queue` with the decided next track
    /// spliced to `currentIndex + 1` as each pick is made.
    ///
    /// Materializing the choice into a list — rather than teaching the advance
    /// path a second way to find "next" — is what keeps `currentIndex`
    /// meaningful. `advanceToNext`, `previous`, `adoptTransitionedTrack` and
    /// `upcomingTracks` are the code they always were, and predev §2.1's
    /// display contract ("only the decided next is shown reordered; the rest
    /// stays list order") falls out of the splice rather than needing its own
    /// rule.
    @Published private(set) var autoMixQueue: [Track] = []
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
    @Published private(set) var isPlaying = false {
        didSet { updateLyricsCursor(at: livePlaybackTime); samplePlaybackReporting() }
    }
    @Published private(set) var isBuffering = false {
        didSet { updateLyricsCursor(at: livePlaybackTime); samplePlaybackReporting() }
    }
    @Published private(set) var duration: TimeInterval = 0
    typealias AudioQualityBadgeState = PlaybackState.AudioQualityBadge
    @Published private(set) var audioQualityBadgeState: AudioQualityBadgeState?
    @Published private(set) var isSwitchingAudioQuality = false
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
    /// The quality title of the third-party stream, with its bitrate.
    @Published private(set) var externalQualityTitle: String?
    @Published private(set) var unblockSource: String? {
        didSet {
            if unblockSource == nil { externalQualityTitle = nil }
            if unblockSource != nil {
                audioQualityBadgeState = .externalSource
            } else if oldValue != nil, let servedQuality, !servedQuality.isEmpty {
                audioQualityBadgeState = .quality(servedQuality)
            }
        }
    }
    /// The unblock source serving the current track, and every source already
    /// tried for it, so a stream that dies mid-song moves on to the next one.
    @Published private(set) var currentUnblockSourceID: AudioSourceID?
    private var attemptedUnblockSources: Set<AudioSourceID> = []
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

    /// Which order the player walks its queue in (predev §2.1). The three
    /// states are mutually exclusive by construction — there is one value —
    /// and none of them ever reorders `queue` itself, so leaving a mode always
    /// restores the list the user gave us.
    @Published private(set) var queueOrder: QueueOrder = .listed
    /// The old two-state name, kept as a read-only derivation so every call
    /// site that only ever asked "is shuffle on" — the Dock menu, the two
    /// transport bars, the persisted state — keeps working unchanged.
    var shuffleEnabled: Bool { queueOrder == .shuffled }
    @Published var volume: Float = 1 {
        didSet {
            engine.outputVolume = volume
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
    @Published private(set) var lyricsSource: LyricsSource = .automatic
    @Published private(set) var resolvedLyricsSource: LyricsSource?
    @Published private(set) var lyricsSourceLoading = false
    private var lyricsRequestID = UUID()
    @Published var activePanel: RightPanel?
    @Published var showNowPlaying = false

    /// The list the player is walking through.
    var activeQueue: [Track] {
        switch queueOrder {
        case .listed: return queue
        case .shuffled: return shuffledQueue
        case .autoMix: return autoMixQueue
        }
    }

    var upcomingTracks: [Track] {
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    // MARK: - Engine

    private let engine = PlaybackEngine()
    /// The deck currently carrying the audible track; hand-overs flip it.
    private var activeDeck: Deck = .a
    /// The active deck has a source loaded (file or progressive stream).
    private var deckLoaded = false
    /// The loaded source is a complete local file, so the engine can seek
    /// sample-accurately and repeat-one can restart in place.
    private var hasLocalFile = false
    /// Cache entry for the source now playing; nil for trial fragments,
    /// which are never cached.
    private var currentCacheKey: EngineAudioCache.Key?
    private var currentRemoteURL: URL?
    private var progressTimer: Timer?
    private var lyricsClockSampling: Task<Void, Never>?
    private var lastPlaybackCheckpoint = ContinuousClock.now

    /// Live playback position straight off the deck, for frame-synced UI.
    /// The published `progress` is intentionally coarse.
    ///
    /// Falls back to `progress` whenever no deck is carrying a source, so a
    /// paused or unloaded player still reports where the playhead sits.
    var livePlaybackTime: TimeInterval {
        guard deckLoaded else { return progress }
        let t = engine.position(of: activeDeck)
        return t.isFinite ? t : progress
    }
    private var resolveGeneration = 0
    private var lyricsResync: Task<Void, Never>?
    @Published private var trackResolution: (generation: Int, task: Task<Void, Never>)?
    /// True while the engine is paused by us (togglePlayPause/pause/
    /// interruption). When false, "resume" must re-issue play() instead —
    /// engine.resume() is a no-op on a drained or never-paused deck.
    private var enginePaused = false

    // Auto-advance pipeline: the next track is resolved, downloaded (and
    // later analyzed) while the current one plays, then armed on the other
    // deck so the engine can hand over without touching the network.
    private struct PrefetchedNext {
        let track: Track
        let key: EngineAudioCache.Key
        let localURL: URL
        let level: String?
        let qishuiQualityOption: AudioQualityOption?
        let unblockSource: String?
        let externalQualityTitle: String?
        var analysis: TrackAnalysis?
    }

    private var prefetchTask: Task<Void, Never>?
    private var prefetchedNext: PrefetchedNext? { didSet { publishCacheFilesInUse() } }
    private var pendingTransitionTrack: Track?
    /// The plan the engine is currently holding, kept so the stem pre-render
    /// knows which seam it is rendering for (and notices when a re-plan moves
    /// it). Nil whenever no hand-over is armed.
    private var armedPlan: PlannedTransition?
    /// A hand-over is armed exactly when a plan is held for it.
    private var transitionArmed: Bool { armedPlan != nil }
    /// The complete local file of the track now playing, when there is one —
    /// the outgoing source a stem pre-render reads.
    private var currentLocalURL: URL? { didSet { publishCacheFilesInUse() } }
    /// The cached file each deck was last loaded with (absent: nothing, or a
    /// stream). Kept for `EngineAudioCache`'s eviction, which must not delete a file
    /// a deck is playing — a converted (Hi-Res) deck re-opens its file by path
    /// on every seek or cue. A deck the engine retired on its own may linger
    /// here until its next load, which only ever protects one file too many.
    private var deckFiles: [Deck: URL] = [:] { didSet { publishCacheFilesInUse() } }
    /// One parse of the outgoing track's `.lrc`, kept for as long as that file
    /// stays the outgoing one. `Audition.Lyrics.timing(for:)` reads and parses
    /// the sidecar off disk, and the 0.2 s progress tick asks for it on every
    /// AutoMix rank step — so without this the same file is re-read five times
    /// a second.
    private var outgoingLyricCache: (url: URL, timing: TransitionPlanner.PlanContext.LyricTiming?)?

    /// `Audition.Lyrics.timing(for:)` with that one-entry cache in front. Nil
    /// for a track with no sidecar — which is also exactly when
    /// `Audition.Lyrics.lineEnds(for:)` returns an empty grid, so
    /// `outgoingLyricTiming(for:)?.lineEnds ?? []` is the same value it gave.
    private func outgoingLyricTiming(for url: URL?)
        -> TransitionPlanner.PlanContext.LyricTiming? {
        guard let url else { return nil }
        if let cached = outgoingLyricCache, cached.url == url { return cached.timing }
        let timing = Audition.Lyrics.timing(for: url)
        outgoingLyricCache = (url, timing)
        return timing
    }
    /// Beat/energy analysis of the track now playing, once its full file is
    /// on disk. Feeds the outgoing side of TransitionPlanner.
    private var currentAnalysis: TrackAnalysis?
    /// Raw LRC body of the track now playing, kept only so the `.lrc` sidecar
    /// can be written whenever the local file lands — the words and the file
    /// arrive in either order (streamed first play, cache hit, hand-over).
    private var currentLyricLRC: String?
    private var consecutiveFailures = 0
    private var scrobbled = false
    private let historyReporter = PlaybackHistoryReporter()
    private let kugouReporter = KugouPlaybackReporter()
    private let qishuiHistoryReporter = QishuiHistoryReporter()
    private var historySession: PlaybackHistoryReporter.Session?

    // MARK: - Offline playback (downloads)

    /// The song that could not play because it is not on this device.
    @Published var offlineIssue: OfflinePlaybackIssue?
    /// Held while the active deck plays a downloaded file, so the download
    /// cannot be deleted from under it.
    private var offlinePlaybackLease: OfflinePlaybackLease?
    private var offlineScan: Task<Void, Never>?
    private var offlineScanID = UUID()
    private var networkState = DownloadNetworkState.unknown
    private var networkObservation: AnyCancellable?
    private var queueOrderSettingsObservation: AnyCancellable?
    private var offlineActivatedScope: String?
    /// Set by an automatic advance and consumed by `startPlaying`: a song that
    /// turns out to be missing offline is skipped rather than reported.
    private var pendingAutoAdvance = false
    private var currentWasAdvanced = false

    private init() {
        sleepTimer.onDeadlineReached = { [weak self] in
            self?.pause()
        }
        sleepTimer.onStateChange = { [weak self] state in
            guard let self else { return }
            if state == .endOfCurrentTrack {
                self.disarmTransition()
            } else {
                self.armTransitionIfReady()
            }
        }
        volume = UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.8
        engine.outputVolume = volume
        // The persisted overrides are restored before anything plays, so the
        // recorder is armed for the first seam of the session rather than the
        // first one after somebody opens the panel.
        engine.setVerboseTrace(AutoMixDebugModel.shared.overrides.verboseEngineTrace)
        // Likewise the master path: the limiter has to be in circuit before the
        // first track is loaded, because that load is where the bent-rate pad
        // it retires would otherwise be sized.
        engine.setMasterLimiter(AutoMixDebugModel.shared.overrides.enableMasterLimiter)
        // And the head compensation's manual pin, for the same reason: the very
        // first splice of a session must arm under the regime the panel says
        // it is in.
        engine.setHeadLatencyPin(
            AutoMixDebugModel.shared.overrides.headLatencyCompensationMS)
        // The engine measures the seam's alignment on its own queue and folds
        // it into a persisted calibration; this is the one wire that carries
        // those numbers up to the panel, so the engine never has to know a
        // panel exists.
        SeamLatencyStore.shared.observe { report in
            Task { @MainActor in AutoMixDebugModel.shared.setSeamLatency(report) }
        }
        repeatMode = UserDefaults.standard.string(forKey: "player.repeat")
            .flatMap(RepeatMode.init) ?? .off

        // The playing indicator's band levels, straight off the engine's mixer:
        // installed once here and never touched again, so no track change, seek
        // or hand-over has to think about it. The closure runs on the audio
        // thread and only writes floats into a preallocated store.
        engine.setOutputSampleSink { buffer in
            AudioSpectrum.shared.ingest(buffer)
        }

        // macOS output routing (incl. AirPlay endpoints the system publishes):
        // the controller owns the device list and the user's choice, and this
        // is the only place it can reach the engine. Restores the persisted
        // device as a side effect.
        let engine = engine
        AudioOutputController.shared.attach { deviceID in
            engine.setOutputDevice(deviceID)
        }

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The AutoMix debug panel refreshes off this tick rather than a
                // timer of its own, so a closed window costs exactly one Bool
                // test here. It runs before the guard below because a paused or
                // buffering player is precisely when the panel is being read.
                if AutoMixDebugModel.shared.isActive { self.publishDebugNow() }
                // The queue-order pick rides this tick for the same reason:
                // with the mode off it is one optional test, and with it on
                // there is no second timer to own.
                self.updateAutoMixPick()
                guard self.isPlaying, self.deckLoaded, !self.isScrubbing else { return }
                let seconds = self.engine.position(of: self.activeDeck)
                guard seconds.isFinite else { return }
                self.samplePlaybackReporting(position: seconds, advancing: !self.isBuffering)

                // The scrubber samples the deck on its own display schedule.
                // Keep clock publications coarse for the other observers.
                if abs(seconds - self.progress) > 0.45 {
                    self.progress = seconds
                    NowPlayingManager.shared.updateElapsed(seconds, rate: 1)
                }
                if self.lastPlaybackCheckpoint.duration(to: .now) >= .seconds(20) {
                    self.persistState()
                }
                self.updateStemPrerender()
            }
        }
        // .common keeps the clock ticking through menu tracking and window
        // drags, where the default run-loop mode starves plain timers.
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer

        // Match the iPad sampler without increasing AutoMix planning work.
        lyricsClockSampling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(33)) }
                catch { return }
                self?.sampleLyricsClock()
            }
        }

        Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                guard let self else { return }
                self.handleEngineEvent(event)
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
        restoreState()
        // Restored sessions stay paused, but their metadata must not wait for playback.
        Task { await loadCurrentLyricsIfNeeded() }
        let settings = SettingsManager.shared
        queueOrderSettingsObservation = settings.$automixEnabled
            .combineLatest(settings.$automixOrderEnabled)
            .map { $0 && $1 }
            .removeDuplicates()
            // @Published emits before assignment; reconcile after both values are stored.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileQueueOrderAvailability() }
    }

    /// Set while the user drags the seek bar so the time observer doesn't fight the thumb.
    var isScrubbing = false

    // MARK: - Entry points

    /// - Parameter context: the place these tracks came from. Supplying it
    ///   lists that place in the Dock menu's recently played section; callers
    ///   playing an ad-hoc selection (search results, a single track) omit it.
    func play(tracks: [Track], source: PlaySource, startAt track: Track? = nil,
              context: PlayContext? = nil) {
        guard !tracks.isEmpty else { return }
        // A mixed playlist queues as-is: each track resolves through its own
        // platform in startPlaying/resolveSource, so playing never asks the
        // user to switch platforms first.
        tracks.forEach { PlatformMusicAPI.shared.restore($0) }
        if let context { recordRecent(context) }
        isFMMode = false
        queue = tracks
        self.source = source
        playNextList.removeAll()
        let startTrack = track ?? tracks[0]
        queueOrderSelector?.reset()
        switch queueOrder {
        case .listed:
            currentIndex = tracks.firstIndex(where: { $0.id == startTrack.id }) ?? 0
        case .shuffled:
            reshuffle(keeping: startTrack)
            currentIndex = 0
        case .autoMix:
            reorderForAutoMix(keeping: startTrack)
            currentIndex = 0
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
            schedulePrefetch()
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
        } else if !deckLoaded {
            // Restored session: re-resolve the source.
            startPlaying(track, resumeAt: progress)
            return
        } else if enginePaused {
            engine.resume()
            enginePaused = false
            isPlaying = true
        } else {
            // The deck drained (queue end) or was loaded without playing —
            // resume() would be a no-op; re-issue play from where we are.
            engine.play(deck: activeDeck, from: min(progress, max(0, duration - 0.1)))
            isPlaying = true
            scrobbleStartIfNeeded(track)
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
            stopForOffline()
            isBuffering = false
        }
        engine.pause()
        enginePaused = true
        isPlaying = false
        AudioSpectrum.shared.reset()
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
        persistState()
    }

    func next() {
        // **Next during a hand-over lands on the incoming track, through the
        // hand-over.** Two cases, and neither of them is the hard cut this
        // used to be.
        //
        // Already sounding (overlapping, a pre-rendered splice, or a gapless
        // hand-over pinned to the host clock): the seam is audible and it is
        // landing on exactly the track the listener just asked for, seconds
        // from now. Cutting it off mid-overlap is the ugliest thing this
        // button can do, and starting the incoming track over from zero would
        // play its first bars twice. Let it finish.
        //
        // Armed but still waiting: bring the seam to now. The decks are
        // already loaded, so the two tracks can meet immediately over a short
        // blend instead of one being torn down and the other re-resolved. A
        // `.gapless` plan is not a seam that can be brought forward — it has
        // no overlap — so that one advances the way it always did.
        if transitionArmed, pendingTransitionTrack != nil {
            if engine.handOverStarted { return }
            if armedPlan?.plan.outPoint != nil, engine.startHandOverNow() {
                // Whatever was being rendered was cut for the seam that just
                // stopped existing; there is no runway left to finish it in
                // and its audio is now the wrong audio.
                cancelStemPrerender()
                return
            }
        }
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
    /// Uses the same engine clock as per-word highlighting.
    private func updateLyricsCursor(at seconds: TimeInterval, wordByWord: Bool? = nil,
                                    playbackRate: Double? = nil) {
        let wordTimed = (wordByWord ?? SettingsManager.shared.verbatimLyrics)
            && lyrics?.lines.contains(where: { $0.words?.isEmpty == false }) == true
        // Line lyrics lead by 0.2s. Authored word timing uses its original timestamps.
        lyricsCursor.synchronize(lyrics: lyrics, at: seconds, playing: isPlaying && !isBuffering,
            rate: playbackRate ?? engine.playbackSample(of: activeDeck).rate,
            duration: duration, advanceTime: wordTimed ? 0 : 0.2, timeOffset: lyricsTimeOffset)
    }

    private func sampleLyricsClock() {
        guard deckLoaded, !isScrubbing else { return }
        let sample = engine.playbackSample(of: activeDeck)
        updateLyricsCursor(at: sample.position, playbackRate: sample.rate)
    }

    /// After a user adjustment (progress, lyrics timing/source, audio quality),
    /// wait until the deck is rendering again, then re-anchor the lyrics to its
    /// media time. Follow-up checks only redraw when the lyric clock drifted.
    private func scheduleLyricsResync() {
        lyricsResync?.cancel()
        lyricsResync = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline {
                guard !Task.isCancelled, let self else { return }
                if self.deckLoaded, !self.isBuffering, !self.isScrubbing { break }
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
        guard deckLoaded, !isBuffering, !isScrubbing else { return }
        let sample = engine.playbackSample(of: activeDeck)
        guard sample.position.isFinite else { return }
        let drift = abs(lyricsCursor.playbackTime - lyricsTimeOffset - sample.position)
        updateLyricsCursor(at: sample.position, playbackRate: sample.rate)
        if force || drift > 0.12 {
            lyricsCursor.seekRevision &+= 1
            NowPlayingManager.shared.updateElapsed(sample.position, rate: sample.rate)
        }
    }

    /// Restore the engine anchor after background suspension or window restoration.
    func refreshPlaybackPresentation() {
        sampleLyricsClock()
        lyricsCursor.seekRevision &+= 1
    }

    /// Enqueue a seek; engine samples anchor lyrics to the resulting media time.
    /// The legacy completion reports submission, not decoder readiness.
    func seek(to seconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        guard seconds.isFinite else { return }
        cancelQishuiFeedLoad()
        qishuiFeedDrained = false
        qishuiHistoryReporter.discontinuity()
        kugouReporter.willSeek(position: engine.position(of: activeDeck))
        let seconds = min(max(0, seconds), duration > 0 ? duration : max(0, seconds))
        // An armed/overlapping hand-over is anchored to the old timeline —
        // cancel it, seek, then re-arm from the prefetched file.
        //
        // The re-armed plan still carries the out point the planner computed
        // for the whole track, which the seek may have just jumped past. The
        // engine (resolvePlanLocked) degrades such a plan to a tail-anchored
        // crossfade or to gapless instead of firing it on the spot — a seek
        // into the transition window must never start the next song.
        //
        // The stem render in flight is *parked*, not killed. A seek moves the
        // playhead, not the seam: the panel's own jump-to-seam moves it towards
        // the very hand-over being rendered, and re-planning from the new
        // position almost always lands on the identical signature. Killing the
        // render there and restarting it inside the lead window was how a jump
        // turned a comfortable `trigger=settled` into a `trigger=late` that lost
        // the race to its own splice. `reconcileParkedPrerender` decides after
        // the re-arm, on the signature, and drops it if the seam really moved.
        let wasArmed = transitionArmed
        if wasArmed { disarmTransition(keepingPrerender: true) }
        scheduleLyricsResync()
        progress = seconds
        updateLyricsCursor(at: seconds)
        lyricsCursor.seekRevision &+= 1
        if !adoptCompletedDownload(at: seconds) {
            engine.seek(deck: activeDeck, to: seconds)
        }
        NowPlayingManager.shared.updateElapsed(seconds, rate: isPlaying ? 1 : 0)
        if wasArmed {
            armTransitionIfReady()
            reconcileParkedPrerender()
        }
        persistState()
        completion?()
    }

    /// A stream seek without an exact packet offset (FLAC, VBR) re-downloads
    /// from byte 0 and decodes everything before the target, which takes
    /// seconds on a lossless file. Once the stream's mirror has landed as a
    /// complete cache file, move the deck onto that file instead: file seeks
    /// are sample-accurate and immediate. The stream played with no loudness
    /// trim, so the file is loaded with none to keep the level unchanged.
    private func adoptCompletedDownload(at seconds: TimeInterval) -> Bool {
        guard deckLoaded, !hasLocalFile, !isTrial, offlinePlaybackLease == nil,
              let local = currentLocalURL, currentCacheKey != nil,
              FileManager.default.fileExists(atPath: local.path),
              let fileDuration = try? engine.loadFile(at: local, on: activeDeck, trimDB: 0) else { return false }
        hasLocalFile = true
        deckFiles[activeDeck] = local
        isBuffering = false
        if fileDuration > 0 { duration = fileDuration }
        let target = min(seconds, max(0, fileDuration - 0.1))
        if isPlaying {
            engine.play(deck: activeDeck, from: target)
            AudioSpectrum.shared.markTapped()
        } else {
            // A freshly loaded deck is not paused: the next play starts it at `progress`.
            enginePaused = false
        }
        PlaybackJournal.note("seek moved stream onto cached file at=\(String(format: "%.1f", target))")
        return true
    }

    /// Keep the audible deck running until a complete replacement is ready.
    /// Loading the other deck first leaves the old source intact on failure.
    func switchAudioQuality(to quality: AudioQuality?, alwaysHighest: Bool) async {
        guard !isSwitchingAudioQuality else { return }
        let settings = SettingsManager.shared
        let preferenceChanged = settings.alwaysHighestAudioQuality != alwaysHighest
            || (quality.map { $0 != settings.audioQuality } ?? false)
        settings.alwaysHighestAudioQuality = alwaysHighest
        if let quality { settings.audioQuality = quality }
        guard let track = currentTrack else { return }
        guard !usesOfflineQueue else {
            ToastCenter.shared.show("音质偏好已保存，联网播放时生效")
            return
        }
        guard deckLoaded, !isBuffering else {
            ToastCenter.shared.show("音质偏好已保存，下次载入时生效")
            return
        }
        var generation = resolveGeneration
        let scope = offlineAccountScope
        isSwitchingAudioQuality = true
        if preferenceChanged {
            disarmTransition()
            prefetchTask?.cancel()
            prefetchedNext = nil
        }
        defer {
            isSwitchingAudioQuality = false
            if generation == resolveGeneration, currentTrack?.id == track.id { schedulePrefetch() }
        }
        do {
            let url: URL
            let level: String?
            var qishuiOption: AudioQualityOption?
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
                level = resolved.quality?.rawValue
                external = resolved
            } else {
                let data: SongURLData?
                if alwaysHighest {
                    data = try await NeteaseAPI.preferredSongURL(id: track.id,
                        quality: settings.preferredPlaybackQuality, alwaysHighest: true)
                } else {
                    data = try await NeteaseAPI.songURL(ids: [track.id], level: settings.audioQuality.rawValue).first
                }
                guard !Task.isCancelled, generation == resolveGeneration,
                      currentTrack?.id == track.id, scope == offlineAccountScope else { return }
                guard let data, let address = data.url,
                      let platformURL = track.playbackURL(address),
                      data.freeTrialInfo == nil else {
                    ToastCenter.shared.show("当前歌曲或账号暂不支持此完整音质，继续原音质播放")
                    return
                }
                url = platformURL
                level = data.resolvedAudioQuality?.rawValue ?? data.level
                qishuiOption = data.qishuiQualityOption
            }
            let actual = level.flatMap(AudioQuality.init(rawValue:))
            if let level, level == servedQuality, external?.id == currentUnblockSourceID, !isTrial {
                if let actual,
                   !alwaysHighest, actual != quality {
                    ToastCenter.shared.show("当前可播放音质为\(actual.displayName)")
                }
                return
            }
            let key = EngineAudioCache.Key(trackID: track.id, level: level ?? "unknown",
                source: external.map { "unblock:\($0.id.rawValue)" } ?? track.platformSong?.source.rawValue ?? "netease",
                fileExtension: url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased())
            let local = url.isFileURL ? url : try await EngineAudioCache.shared.download(from: url, key: key)
            guard !Task.isCancelled, generation == resolveGeneration,
                  currentTrack?.id == track.id, scope == offlineAccountScope else { return }
            let position = livePlaybackTime
            let replacement = activeDeck.other
            disarmTransition()
            prefetchTask?.cancel()
            prefetchedNext = nil
            let fileDuration = try engine.loadFile(at: local, on: replacement, trimDB: 0)
            resolveGeneration &+= 1
            generation = resolveGeneration
            let oldDeck = activeDeck
            activeDeck = replacement
            engine.stop(deck: oldDeck)
            deckFiles[oldDeck] = nil
            deckFiles[replacement] = local
            releaseOfflineLease()
            deckLoaded = true
            hasLocalFile = true
            enginePaused = false
            currentCacheKey = key
            currentRemoteURL = url
            currentLocalURL = local
            currentAnalysis = nil
            duration = fileDuration
            progress = min(max(0, position), max(0, fileDuration - 0.1))
            servedQuality = level
            if track.platformSong?.source == .qishui, external == nil {
                servedQishuiQualityOption = .qishuiLocal(url: local, level: level, duration: fileDuration) ?? qishuiOption
            }
            unblockSource = external?.displayName
            externalQualityTitle = external?.title
            currentUnblockSourceID = external?.id
            isTrial = false
            if isPlaying { engine.play(deck: replacement, from: progress) }
            else { engine.seek(deck: replacement, to: progress) }
            updateLyricsCursor(at: progress)
            lyricsCursor.seekRevision &+= 1
            scheduleLyricsResync()
            NowPlayingManager.shared.updateMetadata(for: track, duration: fileDuration)
            NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
            persistCurrentLyricsSidecar()
            ensureCurrentAnalysis(key: key, fileURL: local)
            if lyrics == nil {
                let qualityGeneration = generation
                Task { await loadLyrics(for: track, generation: qualityGeneration) }
            }
            persistState()
            if external != nil, let actual, !alwaysHighest, actual != quality {
                ToastCenter.shared.show("当前可播放音质为\(actual.displayName)")
            }
        } catch {
            guard generation == resolveGeneration, currentTrack?.id == track.id,
                  scope == offlineAccountScope else { return }
            ToastCenter.shared.show("音质切换失败，继续原音质播放：\(error.localizedDescription)")
        }
    }

    func toggleShuffle() {
        setQueueOrder(shuffleEnabled ? .listed : .shuffled)
    }

    /// Whether the AutoMix order can do anything at all. It picks by planning,
    /// and planning needs analyses — which iOS and an AutoMix-off player never
    /// compute — and it downloads candidates the listener did not ask for,
    /// which is its own opt-in. The shuffle button cycles through two states
    /// rather than three when this is false.
    var autoMixOrderAvailable: Bool {
        return SettingsManager.shared.automixEnabled
            && SettingsManager.shared.automixOrderEnabled
    }

    /// The single queue-order control (predev §2.1, now the only one): the
    /// shuffle button walks `listed → shuffled → autoMix → listed`, skipping
    /// the third state wherever it could do nothing.
    func cycleQueueOrder() {
        setQueueOrder(Self.nextQueueOrder(after: queueOrder,
                                          autoMixAvailable: autoMixOrderAvailable))
    }

    /// The cycle as a pure function — one place the order of the states is
    /// written down, for the button, the Dock menu and the tests.
    static func nextQueueOrder(after order: QueueOrder,
                               autoMixAvailable: Bool) -> QueueOrder {
        switch order {
        case .listed: return .shuffled
        case .shuffled: return autoMixAvailable ? .autoMix : .listed
        case .autoMix: return .listed
        }
    }

    /// The AutoMix order's switch was turned off (or the master was) while the
    /// queue was in that order: fall back to the list the user gave us, rather
    /// than leaving a mode running that the settings say is gone.
    private func reconcileQueueOrderAvailability() {
        guard queueOrder == .autoMix, !autoMixOrderAvailable else { return }
        setQueueOrder(.listed)
    }

    func setQueueOrder(_ order: QueueOrder) {
        guard !isFMMode, queueOrder != order else { return }
        let current = currentTrack
        queueOrder = order
        syncQueueOrderSelector()
        autoMixPickCommitted = false
        switch order {
        case .listed:
            shuffledQueue = []
            autoMixQueue = []
            if let current {
                currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
            }
        case .shuffled:
            autoMixQueue = []
            guard let current else { break }
            reshuffle(keeping: current)
            currentIndex = 0
        case .autoMix:
            shuffledQueue = []
            guard let current else { break }
            reorderForAutoMix(keeping: current)
            currentIndex = 0
        }
        persistState()
        schedulePrefetch()
    }

    func cycleRepeatMode() {
        guard !isFMMode else { return }
        repeatMode = repeatMode.next
        // Repeat-one forbids auto hand-overs; the other modes change what
        // comes after the final queue entry.
        schedulePrefetch()
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
        if let idx = queue.firstIndex(where: { $0.id == track.id }),
           idx != currentIndex || queueOrder != .listed {
            queue.remove(at: idx)
        }
        if let idx = shuffledQueue.firstIndex(where: { $0.id == track.id }) {
            shuffledQueue.remove(at: idx)
        }
        if let idx = autoMixQueue.firstIndex(where: { $0.id == track.id }), idx != currentIndex {
            autoMixQueue.remove(at: idx)
        }
        // The chain may have been planning around the track that just left.
        refreshAutoMixLookahead(force: true)
        schedulePrefetch()
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

    @discardableResult
    func moveUpcoming(from offsets: IndexSet, to destination: Int, matching trackIDs: [Int]) -> Bool {
        guard !isFMMode, upcomingTracks.map(\.id) == trackIDs,
              offsets.allSatisfy({ trackIDs.indices.contains($0) }),
              (0...trackIDs.count).contains(destination),
              let reordered = PlaybackQueuePlan.reorderingUpcoming(
                queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                from: offsets, to: destination
              ) else { return false }
        switch queueOrder {
        case .listed: queue = reordered
        case .shuffled:
            queue.append(contentsOf: playNextList)
            shuffledQueue = reordered
        case .autoMix:
            queue.append(contentsOf: playNextList)
            autoMixQueue = reordered
        }
        playNextList.removeAll()
        refreshAutoMixLookahead(force: true)
        schedulePrefetch()
        persistState()
        return true
    }

    /// The row sits after the current index in the active order; the other
    /// orders drop one copy of the same song so all stay the same length.
    private func removeQueueRow(at offset: Int, trackID: Int) {
        switch queueOrder {
        case .listed: queue.remove(at: offset)
        case .shuffled: shuffledQueue.remove(at: offset)
        case .autoMix: autoMixQueue.remove(at: offset)
        }
        if queueOrder != .listed, let idx = queue.firstIndex(where: { $0.id == trackID }) { queue.remove(at: idx) }
        if queueOrder != .shuffled, let idx = shuffledQueue.firstIndex(where: { $0.id == trackID }) { shuffledQueue.remove(at: idx) }
        if queueOrder != .autoMix, let idx = autoMixQueue.firstIndex(where: { $0.id == trackID }) { autoMixQueue.remove(at: idx) }
        // The chain may have been planning around the track that just left.
        refreshAutoMixLookahead(force: true)
        schedulePrefetch()
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
        queueOrder = .listed
        syncQueueOrderSelector()
        repeatMode = .off
        queue = []
        shuffledQueue = []
        autoMixQueue = []
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
                    switch self.queueOrder {
                    case .listed: break
                    case .shuffled: self.shuffledQueue.append(contentsOf: tracks)
                    case .autoMix: self.autoMixQueue.append(contentsOf: tracks)
                    }
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
            cancelQishuiFeedLoad()
            // The deck has drained on its own — there is no hand-over, because
            // arming one is refused while this mode is on — so there is nothing
            // to pause in the engine. `enginePaused` stays false, which sends
            // the next play press down `togglePlayPause`'s drained branch: it
            // plays out the last instant and advances, so the listener picks up
            // on the next song rather than on silence.
            progress = duration
            updateLyricsCursor(at: duration)
            isPlaying = false
            AudioSpectrum.shared.reset()
            NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            return
        }

        guard isPlaying else { return }

        if repeatMode == .one, !isFMMode {
            scrobbled = false
            historySession = nil
            if hasLocalFile {
                progress = 0
                engine.play(deck: activeDeck, from: 0)
                if let track = currentTrack { scrobbleStartIfNeeded(track) }
                isPlaying = true
                NowPlayingManager.shared.updateElapsed(0, rate: 1)
            } else if let track = currentTrack {
                // A drained stream can't restart in place; re-resolve (the
                // second pass usually hits the cache the first one committed).
                startPlaying(track)
            }
            return
        }
        advanceToNext(userInitiated: false)
    }

    // MARK: - Source resolution

    /// Void an armed hand-over, keeping the prefetched file/analysis around
    /// so the transition can be re-armed (post-seek) without re-downloading.
    ///
    /// `keepingPrerender` parks the stem render instead of killing it, for the
    /// one caller whose disarm/re-arm pair is not a change of mind: a seek.
    /// See `reconcileParkedPrerender` — nothing is *kept* on the strength of
    /// this flag alone, only held long enough for the re-armed plan to be
    /// compared against it.
    private func disarmTransition(keepingPrerender: Bool = false) {
        engine.cancelScheduledTransition()
        pendingTransitionTrack = nil
        armedPlan = nil
        AutoMixDebugModel.shared.setPlan(nil)
        AutoMixDebugModel.shared.setScoreRefusal(nil)
        // Whatever the pre-render was aiming at is void: a re-arm re-derives
        // the plan, and `updateStemPrerender` starts again from there.
        //
        // Unless the caller is only *re-deriving* this same seam — see
        // `keepingPrerender`, and `reconcileParkedPrerender` for who decides.
        if keepingPrerender, stemPrerenderState.signature != nil {
            parkedPrerender = stemPrerenderState
        } else {
            cancelStemPrerender()
        }
        // The stability clock too, and for a reason worth naming: a seek moves
        // the playhead this clock is read on, so a `since` taken before it is
        // not a duration afterwards. A re-arm restarts it honestly.
        stemPrerenderStable = nil
    }

    private func startPlaying(_ track: Track,
                              localLease: OfflinePlaybackLease? = nil, resumeAt: TimeInterval = 0) {
        // No platform gate here: a track from another platform resolves
        // through its own platform in resolveSource.
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
        releaseOfflineLease()
        // Any armed hand-over is void: this is a hard track change.
        disarmTransition()
        engine.stop(deck: activeDeck.other)
        deckFiles[activeDeck.other] = nil
        prefetchTask?.cancel()
        prefetchedNext = nil
        currentAnalysis = nil
        currentLocalURL = nil
        scrobbleIfNeeded(completed: false)
        engine.stop(deck: activeDeck)
        deckFiles[activeDeck] = nil
        currentCacheKey = nil
        currentRemoteURL = nil
        hasLocalFile = false
        deckLoaded = false
        // A new track is a new decision round for the queue-order mode: the
        // escalation restarts from nothing admitted, on top of the (now
        // richer) pool of everything analyzed so far.
        autoMixPickCommitted = false
        queueOrderSelector?.beginPick()
        autoMixStaleDeadlineNoted = false
        AutoMixDebugModel.shared.clearNext()
        isBuffering = false
        enginePaused = false

        currentTrack = track
        playbackAccountID = AccountStore.shared.profile?.userId
        progress = resumeAt
        duration = track.duration
        servedQuality = nil
        servedQishuiQualityOption = nil
        unblockSource = nil
        currentUnblockSourceID = nil
        attemptedUnblockSources = []
        isTrial = false
        lyrics = nil
        resolvedLyricsSource = nil
        currentLyricLRC = nil
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

    private struct ResolvedSource {
        let url: URL
        let key: EngineAudioCache.Key
        let level: String?
        let qishuiQualityOption: AudioQualityOption?
        let unblockSource: ResolvedAudioSource?
        let attemptedUnblockSources: Set<AudioSourceID>
        let isTrial: Bool
        let durationMS: Int?
    }

    /// The full URL-resolution chain (quality fallback → https upgrade →
    /// unblock rescue) plus cache-key derivation — shared by playback and
    /// prefetch so both always derive identical keys. Pure: no toasts, no
    /// state changes.
    private func resolveSource(for track: Track,
                               excluding excludedSources: Set<AudioSourceID> = [],
                               purpose: UnblockResolver.Purpose = .playback,
                               onFailure: ((Error) -> Void)? = nil) async -> ResolvedSource? {
        let settings = SettingsManager.shared
        let quality = settings.audioQuality.rawValue
        let isNetease = MusicProviderContext.shared.current == .netease
        var data: SongURLData?
        if track.platformSong?.source == .qishui {
            do { data = try await NeteaseAPI.songURL(ids: [track.id], level: settings.preferredPlaybackQuality.rawValue).first }
            catch {
                onFailure?(error)
                // Without membership or rights, look for the song elsewhere.
                guard (error as? QishuiError)?.invitesUnblock == true else { return nil }
            }
        } else if isNetease || settings.alwaysHighestAudioQuality {
            data = try? await NeteaseAPI.preferredSongURL(id: track.id,
                quality: settings.preferredPlaybackQuality, alwaysHighest: settings.alwaysHighestAudioQuality)
        } else {
            data = try? await NeteaseAPI.songURL(ids: [track.id], level: quality).first
        }
        if !isNetease, data?.url == nil, quality != AudioQuality.standard.rawValue {
            data = try? await NeteaseAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
        }
        var url: URL?
        var unblock: ResolvedAudioSource?
        var attempted = Set<AudioSourceID>()
        if let urlString = data?.url {
            url = track.playbackURL(urlString)
        }
        // The platform refused the song or offers only a preview: a track
        // that came from another platform first tries its own platform, so
        // a mixed playlist plays without switching the current platform;
        // only then look for the same recording elsewhere.
        if url == nil || data?.freeTrialInfo != nil {
            if let own = await ownPlatformURLString(for: track, quality: quality),
               let ownURL = track.playbackURL(own) {
                url = ownURL
                data = nil
            } else {
                let resolution = await UnblockResolver.resolve(
                    track,
                    quality: settings.preferredPlaybackQuality,
                    excluding: excludedSources,
                    purpose: purpose
                )
                attempted = resolution.attemptedSources
                if let unblocked = resolution.source {
                    url = unblocked.url
                    unblock = unblocked
                    data = nil
                }
            }
        }
        guard let url else { return nil }
        let level = data?.resolvedAudioQuality?.rawValue ?? data?.level ?? unblock?.quality?.rawValue
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased()
        return ResolvedSource(
            url: url,
            key: EngineAudioCache.Key(trackID: track.id, level: level ?? (isNetease && unblock == nil ? "unknown" : quality),
                                source: unblock.map { "unblock:\($0.id.rawValue)" } ?? track.platformSong?.source.rawValue ?? "netease",
                                fileExtension: ext),
            level: level,
            qishuiQualityOption: track.platformSong?.source == .qishui ? data?.qishuiQualityOption : nil,
            unblockSource: unblock,
            attemptedUnblockSources: attempted,
            isTrial: data?.freeTrialInfo != nil,
            durationMS: data?.time)
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

    private func resolveAndLoad(_ track: Track, generation: Int,
                                localLease: OfflinePlaybackLease? = nil, resumeAt: TimeInterval = 0) async {
        let resolveHighestFirst = SettingsManager.shared.alwaysHighestAudioQuality
            && MusicProviderContext.shared.current == .netease && !usesOfflineQueue
        var sourceError: Error?
        let highestSource = resolveHighestFirst
            ? await resolveSource(for: track, excluding: attemptedUnblockSources, onFailure: { sourceError = $0 }) : nil
        let fullOnlineQuality = highestSource.flatMap { source in
            source.isTrial || source.unblockSource != nil ? nil : source.level
        }
        // Compare downloads with the highest resolved stream. A complete
        // download can also cover a refused request or a trial.
        if let lease = await acquireOfflineLease(for: track, generation: generation, reusing: localLease,
                anyQuality: resolveHighestFirst && fullOnlineQuality == nil,
                preferredQuality: resolveHighestFirst ? (fullOnlineQuality ?? AudioQuality.hires.rawValue) : nil) {
            playLocalFile(lease.url, lease: lease, for: track, generation: generation, from: resumeAt)
            return
        }
        guard generation == resolveGeneration else { return }
        if usesOfflineQueue {
            // Without a network, the cache is the last place to look.
            if let cached = await EngineAudioCache.shared.cachedFileURL(trackID: track.id) {
                guard generation == resolveGeneration else { return }
                playLocalFile(cached, lease: nil, for: track, generation: generation, from: resumeAt)
                return
            }
            guard generation == resolveGeneration else { return }
            unavailableOffline(track, generation: generation)
            return
        }
        let resolved = resolveHighestFirst
            ? highestSource
            : await resolveSource(for: track, excluding: attemptedUnblockSources, onFailure: { sourceError = $0 })
        guard generation == resolveGeneration else { return }
        if let resolved { attemptedUnblockSources.formUnion(resolved.attemptedUnblockSources) }

        guard let resolved else {
            consecutiveFailures += 1
            let reason = sourceError?.localizedDescription ?? track.playability(privilege: nil,
                                           isLoggedIn: AccountStore.shared.isLoggedIn,
                                           vipType: AccountStore.shared.vipType).reason
            ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放\(reason.map { "：\($0)" } ?? "")"))
            guard isPlaying else { return }
            if consecutiveFailures < 5 {
                advanceToNext(userInitiated: false)
            } else {
                isPlaying = false
            }
            return
        }

        consecutiveFailures = 0
        servedQuality = resolved.level
        servedQishuiQualityOption = resolved.qishuiQualityOption
        // The one line that would have caught the silent quality fallback: a
        // preferred-level refusal degrades to `standard`, which now always
        // cache-hits the escalation's scoring copy — a whole muffled song with
        // clean engine telemetry. Journal the level actually served, every
        // start, so "整首闷" is answerable with one grep.
        PlaybackJournal.note(
            "now playing id=\(track.id) level=\(resolved.level ?? "?") "
            + "wanted=\(SettingsManager.shared.alwaysHighestAudioQuality ? "highest" : SettingsManager.shared.audioQuality.rawValue) "
            + (resolved.unblockSource.map { "unblock=\($0.id.rawValue) " } ?? "")
            + (resolved.isTrial ? "trial " : ""))
        scheduleAudioUnitReadback()
        unblockSource = resolved.unblockSource?.displayName
        externalQualityTitle = resolved.unblockSource?.title
        currentUnblockSourceID = resolved.unblockSource?.id
        if let source = resolved.unblockSource {
            ToastCenter.shared.show(String(localized: "已使用 \(source.displayName) 音源"))
        }
        if resolved.isTrial {
            isTrial = true
            ToastCenter.shared.show(String(localized: "VIP 歌曲，当前为试听片段"))
        }

        if resolved.url.isFileURL {
            playLocalFile(resolved.url, lease: nil, for: track, generation: generation, from: resumeAt, resolved: resolved)
            return
        }

        let key = resolved.key
        currentCacheKey = resolved.isTrial ? nil : key
        currentRemoteURL = resolved.url

        // Progressive streams cannot seek before their bytes arrive. A received
        // checkpoint therefore loads a complete file through the existing cache.
        if resumeAt > 0, !resolved.isTrial {
            isBuffering = true
            do {
                let local = try await EngineAudioCache.shared.download(from: resolved.url, key: key)
                guard generation == resolveGeneration else { return }
                playLocalFile(local, lease: nil, for: track, generation: generation, from: resumeAt, resolved: resolved)
                return
            } catch {
                guard generation == resolveGeneration else { return }
                isBuffering = false
                isPlaying = false
                engine.stop(deck: activeDeck)
                ToastCenter.shared.show(error.localizedDescription)
                return
            }
        }

        if !resolved.isTrial {
            var local = await EngineAudioCache.shared.cachedFileURL(for: key)
            if local == nil, let inflight = await EngineAudioCache.shared.activeDownload(for: key) {
                // A prefetch of this very track is mid-flight — wait for it
                // instead of opening a second transfer of the same file.
                guard generation == resolveGeneration else { return }
                isBuffering = true
                local = try? await inflight.value
                guard generation == resolveGeneration else { return }
                isBuffering = false
            }
            guard generation == resolveGeneration else { return }
            // A cached sidecar (this track has been heard before) lets the deck
            // open at its compensated level right away. On a miss the trim is 0
            // and stays 0 for this play: `ensureCurrentAnalysis` below will
            // compute and persist the analysis, but applying it now would be an
            // audible jump mid-song, so it takes effect from the next load.
            let cachedAnalysis = analysisWanted
                ? await AnalysisStore.shared.loadAnalysis(for: key) : nil
            guard generation == resolveGeneration else { return }
            if let local,
               let fileDuration = try? engine.loadFile(
                   at: local, on: activeDeck, trimDB: loudnessTrimDB(for: cachedAnalysis),
                   peakDBFS: cachedAnalysis?.peakDBFS) {
                deckLoaded = true
                hasLocalFile = true
                deckFiles[activeDeck] = local
                currentLocalURL = local
                persistCurrentLyricsSidecar()
                engine.play(deck: activeDeck, from: 0)
                isPlaying = true
                AudioSpectrum.shared.markTapped()
                scrobbleStartIfNeeded(track)
                duration = fileDuration
                if track.platformSong?.source == .qishui {
                    servedQishuiQualityOption = .qishuiLocal(url: local, level: servedQuality, duration: fileDuration)
                        ?? resolved.qishuiQualityOption
                }
                NowPlayingManager.shared.updateMetadata(for: track, duration: fileDuration)
                ensureCurrentAnalysis(key: key, fileURL: local)
                schedulePrefetch()
                return
            }
            // Unreadable cache entry — fall through to streaming.
        }
        guard generation == resolveGeneration else { return }

        let partURL: URL
        if resolved.isTrial {
            // Trial fragments never enter the cache; the mirror write goes to
            // a temp file the OS cleans up.
            partURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("coda-trial-\(track.id).part")
        } else {
            partURL = EngineAudioCache.shared.partFileURL(for: key)
        }
        // Buffering until the first decoded chunk lands (streamResumed).
        deckLoaded = true
        isBuffering = true
        engine.startStreaming(from: resolved.url, formatHint: key.fileExtension,
                              writingTo: partURL, on: activeDeck)
        engine.play(deck: activeDeck, from: 0)
        isPlaying = true
        AudioSpectrum.shared.markTapped()
        scrobbleStartIfNeeded(track)

        if let time = resolved.durationMS, time > 0 {
            duration = TimeInterval(time) / 1000
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        }
        schedulePrefetch()
    }

    // MARK: - Engine events

    private func handleEngineEvent(_ event: PlaybackEngineEvent) {
        switch event {
        case .deckFinished(let deck):
            guard deck == activeDeck, deckLoaded else { return }
            handleItemEnded()
        case .streamStalled(let deck):
            if deck == activeDeck, deckLoaded { isBuffering = true }
        case .streamResumed(let deck):
            if deck == activeDeck, deckLoaded { isBuffering = false }
        case .streamDownloadCompleted(let deck):
            guard deck == activeDeck, deckLoaded, let key = currentCacheKey else { return }
            let generation = resolveGeneration
            Task { [weak self] in
                guard let final = try? await EngineAudioCache.shared.commitPartFile(for: key),
                      let self, generation == self.resolveGeneration else { return }
                // The complete file just landed — which is exactly what
                // `currentLocalURL` means. The deck keeps playing its stream
                // source (so `hasLocalFile` stays honest), but everything that
                // reads the *file* — the stem pre-render's outgoing side, the
                // pick's lyric line-ends, and the queue-order politeness gate —
                // can start now instead of waiting for the next track.
                self.currentLocalURL = final
                self.ensureCurrentAnalysis(key: key, fileURL: final)
                // The progressive mirror just became a complete file: the words
                // fetched at the start of the song now have something to sit by.
                self.persistCurrentLyricsSidecar(audio: final)
                // The prefetch pipeline may have deferred while this track
                // was still streaming (same-track repeat) — re-run it.
                self.schedulePrefetch()
            }
        case .streamFailed(let deck, _):
            guard deck == activeDeck, deckLoaded else { return }
            handleStreamFailure()
        case .transitionMidpoint(_, let to, let outcome):
            // Freeze the seam *before* adopting: from here on `currentTrack`
            // is the incoming song and the outgoing one is gone.
            recordDebugSeam(outcome)
            adoptTransitionedTrack(on: to)
        case .transitionCompleted:
            armedPlan = nil
            AutoMixDebugModel.shared.setPlan(nil)
            cancelStemPrerender()
            schedulePrefetch()
        }
    }

    /// Progressive playback died (parse error, mid-file network loss, format
    /// the stream parser can't resync): download the whole file instead and
    /// resume near where it stopped.
    private func handleStreamFailure() {
        if isPlaying { isBuffering = true }
        let generation = resolveGeneration
        let resumeAt = progress
        guard let key = currentCacheKey, let remote = currentRemoteURL,
              let track = currentTrack else {
            streamFallbackFailed()
            return
        }
        Task {
            do {
                let local = try await EngineAudioCache.shared.download(from: remote, key: key)
                guard generation == resolveGeneration else { return }
                // Mid-song recovery: keep the level exactly where the listener
                // has been hearing it (the stream started at unity), so the
                // fallback is inaudible.
                let fileDuration = try engine.loadFile(at: local, on: activeDeck, trimDB: 0)
                deckFiles[activeDeck] = local
                hasLocalFile = true
                currentLocalURL = local
                persistCurrentLyricsSidecar()
                isBuffering = false
                duration = fileDuration
                if isPlaying {
                    engine.play(deck: activeDeck, from: min(resumeAt, max(0, fileDuration - 1)))
                } else {
                    // The user paused mid-stream: stay silent. The play
                    // button re-issues play() from `progress`.
                    enginePaused = false
                }
                NowPlayingManager.shared.updateMetadata(for: track, duration: fileDuration)
                ensureCurrentAnalysis(key: key, fileURL: local)
                schedulePrefetch()
            } catch {
                guard generation == resolveGeneration else { return }
                // The network is gone mid-song; a download of it plays on.
                if let lease = await acquireOfflineLease(for: track, generation: generation, anyQuality: true) {
                    playLocalFile(lease.url, lease: lease, for: track, generation: generation, from: resumeAt)
                    return
                }
                guard generation == resolveGeneration else { return }
                if retryNextUnblockSource(track, generation: generation, resumeAt: resumeAt) { return }
                streamFallbackFailed()
            }
        }
    }

    /// A third-party stream died mid-song: resolve again without the sources
    /// already tried and resume where it stopped.
    private func retryNextUnblockSource(_ track: Track, generation: Int, resumeAt: TimeInterval) -> Bool {
        guard let failed = currentUnblockSourceID else { return false }
        attemptedUnblockSources.insert(failed)
        currentUnblockSourceID = nil
        unblockSource = nil
        engine.stop(deck: activeDeck)
        trackResolution?.task.cancel()
        let resolution = Task {
            defer {
                if trackResolution?.generation == generation { trackResolution = nil }
            }
            await resolveAndLoad(track, generation: generation, resumeAt: resumeAt)
        }
        trackResolution = (generation, resolution)
        return true
    }

    private func streamFallbackFailed() {
        isBuffering = false
        consecutiveFailures += 1
        ToastCenter.shared.show(String(localized: "播放失败，已跳过"))
        if consecutiveFailures < 5 {
            advanceToNext(userInitiated: false)
        } else {
            isPlaying = false
        }
    }

    // MARK: - Auto-advance pipeline (prefetch + transitions)

    /// The track the player would advance to on its own, or nil when the
    /// hand-over must stay manual (repeat-one, trial fragment, end of queue).
    private func autoAdvanceTarget() -> Track? {
        guard !isTrial, repeatMode != .one else { return nil }
        if isFMMode { return fmUpcoming.first }
        if let next = playNextList.first { return next }
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return nil }
        let idx = currentIndex + 1
        if idx < activeQueue.count { return activeQueue[idx] }
        return repeatMode == .all && source.qishuiFeed == nil ? activeQueue.first : nil
    }

    /// (Re)start the pipeline for the current auto-advance target. Call after
    /// playback starts and whenever the upcoming list changes.
    private func schedulePrefetch() {
        // AutoMix order decides *which* track is next, and until it has there
        // is nothing to prefetch: committing to the list's answer now would
        // download the wrong song and arm it before the choice was made.
        // `updateAutoMixPick` calls back in here the moment it decides — at the
        // latest at `autoMixDeadline`, which is sized so the winner still has
        // time to be downloaded, analyzed and armed.
        if autoMixPickPending {
            prefetchTask?.cancel()
            // Nilled, not just cancelled, so `autoMixMayDownload` can read it
            // as the truthful "no playback-quality transfer is running".
            prefetchTask = nil
            prefetchedNext = nil
            AutoMixDebugModel.shared.setNextTitle(
                nil, stage: .deferred("AutoMix order is still choosing"))
            return
        }
        prefetchTask?.cancel()
        let target = autoAdvanceTarget()
        if let armed = pendingTransitionTrack {
            // Already armed for the right track — the pipeline is done.
            if armed.id == target?.id { return }
            // The armed hand-over points at a track that is no longer next.
            disarmTransition()
            engine.stop(deck: activeDeck.other)
        deckFiles[activeDeck.other] = nil
        }
        prefetchedNext = nil
        guard let target else {
            AutoMixDebugModel.shared.clearNext()
            return
        }
        AutoMixDebugModel.shared.setNextTitle(target.name, stage: .resolving)
        if target.id == currentTrack?.id, deckLoaded, !hasLocalFile {
            AutoMixDebugModel.shared.setNextStage(
                .deferred("same track still streaming into the cache"))
            // The next track IS the one still streaming into the cache
            // (single-track repeat-all). A parallel download would race the
            // .part mirror; streamDownloadCompleted re-runs this instead.
            return
        }
        let generation = resolveGeneration
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            guard let resolved = await self.resolveForPrefetch(target) else {
                AutoMixDebugModel.shared.setNextStage(.failed("no playable source"))
                return
            }
            guard !Task.isCancelled, generation == self.resolveGeneration else { return }
            AutoMixDebugModel.shared.setNextStage(.downloading)
            let prepared: URL?
            if resolved.url.isFileURL {
                prepared = resolved.url
            } else {
                prepared = try? await EngineAudioCache.shared.download(from: resolved.url, key: resolved.key)
            }
            guard let local = prepared else {
                AutoMixDebugModel.shared.setNextStage(.failed("download failed"))
                return
            }
            guard !Task.isCancelled, generation == self.resolveGeneration else { return }
            AutoMixDebugModel.shared.setNextStage(.downloaded)
            // The words next: this track is about to be the *incoming* side of
            // a seam and, one song later, the outgoing side whose lyric line
            // decides where a vocal exchange hands over. One small JSON call.
            Task.detached(priority: .utility) { [id = target.id] in
                await LyricsSidecar.fetchAndWrite(trackID: id, for: local)
            }
            AutoMixDebugModel.shared.setNextStage(.analyzing)
            let analysis = await self.analysis(for: resolved.key, fileURL: local)
            guard !Task.isCancelled, generation == self.resolveGeneration,
                  self.autoAdvanceTarget()?.id == target.id else { return }
            // The `.lrc` write above is detached, so this may read a beat before
            // the file lands; the sidecar row is re-read on the next re-plan.
            AutoMixDebugModel.shared.setNextAnalysis(analysis, localURL: local)
            self.prefetchedNext = PrefetchedNext(
                track: target, key: resolved.key, localURL: local,
                level: resolved.level, qishuiQualityOption: resolved.qishuiQualityOption,
                unblockSource: resolved.unblockSource?.displayName,
                externalQualityTitle: resolved.unblockSource?.title, analysis: analysis)
            self.armTransitionIfReady()
        }
    }

    /// Prefetch variant of the shared resolver: trial fragments resolve to
    /// nil (they can't be cached, so they can't be armed either), and the
    /// slow whole-file Qishui source waits until the song actually plays.
    private func resolveForPrefetch(_ track: Track) async -> ResolvedSource? {
        guard let resolved = await resolveSource(for: track, purpose: .prefetch), !resolved.isTrial else { return nil }
        return resolved
    }

    /// Load the prefetched track on the idle deck and pre-arm the hand-over.
    /// Tell the cache which of its files playback has open: whatever each
    /// deck holds, the current track's complete file (seeks, stem
    /// pre-renders and lyric reads open it by path, even while the deck plays
    /// the stream it was mirrored from) and the prefetched next one.
    private func publishCacheFilesInUse() {
        var urls = Set(deckFiles.values)
        if let currentLocalURL { urls.insert(currentLocalURL) }
        if let next = prefetchedNext?.localURL { urls.insert(next) }
        EngineAudioCache.shared.setFilesInUse(urls)
    }

    private func armTransitionIfReady() {
        guard !transitionArmed, let next = prefetchedNext else { return }
        // "Stop after this track" needs the track to *end*: an armed hand-over
        // (AutoMix or gapless) would carry playback into the next one first.
        guard sleepTimer.state != .endOfCurrentTrack else { return }
        let incoming = activeDeck.other
        guard (try? engine.loadFile(at: next.localURL, on: incoming,
                                    trimDB: loudnessTrimDB(for: next.analysis),
                                    peakDBFS: next.analysis?.peakDBFS)) != nil else {
            prefetchedNext = nil
            AutoMixDebugModel.shared.setNextStage(.failed("incoming deck would not load the file"))
            return
        }
        deckFiles[incoming] = next.localURL
        let planned = makeTransitionPlan(for: next)
        engine.scheduleTransition(planned, from: activeDeck, to: incoming)
        armedPlan = planned
        noteArmedSignature(planned)
        pendingTransitionTrack = next.track
        publishDebugPlan(planned, next: next)
    }

    private func makeTransitionPlan(for next: PrefetchedNext) -> PlannedTransition {
        vettingScore(planTransition(for: next), next: next)
    }

    /// **Compile the score at arming time, and strip it when the compiler says
    /// no.**
    ///
    /// The compiler is pure — geometry, two beat grids and a lyric sidecar, all
    /// of them in hand the moment the plan is — but until now the only thing
    /// that ever ran it was the segment render. So a score the compiler was
    /// always going to refuse (no bar line within half a bar of the hand-over,
    /// a grid that drifts through the seam) still cost a spawned render task
    /// that died on the way, once per re-arm, and reported itself to the panel
    /// as "render produced nothing" — a sentence that names neither the reason
    /// nor even the right layer.
    ///
    /// Asking first fixes all of it at once: nothing downstream ever sees a
    /// score that cannot be performed, so there is no render to spawn, no
    /// corpse to explain, and the seam plays today's blend — which is what it
    /// was always going to play. The reason goes to the journal and to the
    /// panel, once, in the words the compiler used.
    ///
    /// It also makes the signature honest. A score that survives this is part
    /// of what the armed plan promises, so a re-arm that reaches the same plan
    /// *and* the same verdict reuses the render, exactly as the settle window
    /// wants it to.
    ///
    /// **Where the verdict goes** is two separate decisions, and conflating them
    /// was the field report's complaint. The *panel* gets it unconditionally and
    /// in its own row (`AutoMixDebugSnapshot.scoreRefusal`, printed in the Plan
    /// group next to the score it explains) — a refusal is a planning verdict,
    /// and putting it in the pre-render's state row made a correct arm-time
    /// decision read as a render that had failed. The *journal* gets it once per
    /// seam, not once per arm: see `journalledScoreRefusal`.
    private func vettingScore(_ planned: PlannedTransition,
                              next: PrefetchedNext) -> PlannedTransition {
        let vetted = Self.vettingScore(planned, outgoing: currentAnalysis,
                                       incoming: next.analysis,
                                       outgoingURL: currentLocalURL)
        AutoMixDebugModel.shared.setScoreRefusal(vetted.refusal)
        guard let refusal = vetted.refusal else { return vetted.planned }
        let key = Self.scoreRefusalKey(
            outgoing: currentTrack?.id, incoming: next.track.id,
            outPoint: vetted.planned.plan.outPoint, reason: refusal)
        // Once per seam, not once per arm. The field journal's churn is ~2.9
        // arms per seam and a seek adds a whole disarm/re-arm pair on top, so
        // three identical refusals read as three problems — which is why the
        // identity here is the *seam* (the pair of tracks and the hand-over
        // point) rather than "since the last arm". A re-plan that genuinely
        // moves the seam gets its own line, because that is a different seam.
        if journalledScoreRefusal != key {
            journalledScoreRefusal = key
            PlaybackJournal.note("score refused: \(refusal)")
        }
        return vetted.planned
    }

    /// **Which seam a score refusal has already been journalled for.**
    ///
    /// The out point is quantised to whole seconds: a re-plan that nudges it by
    /// a frame is the same hand-over being re-derived, not a new one, and the
    /// journal should not say otherwise.
    struct ScoreRefusalKey: Equatable {
        var outgoing: Int?
        var incoming: Int?
        var outPoint: Int?
        var reason: String
    }

    static func scoreRefusalKey(outgoing: Int?, incoming: Int?,
                                outPoint: TimeInterval?,
                                reason: String) -> ScoreRefusalKey {
        ScoreRefusalKey(outgoing: outgoing, incoming: incoming,
                        outPoint: outPoint.map { Int($0.rounded()) }, reason: reason)
    }

    /// The decision itself, without the reporting: the plan that will be armed,
    /// and the compiler's sentence when the score was taken off it.
    static func vettingScore(
        _ planned: PlannedTransition, outgoing: TrackAnalysis?,
        incoming: TrackAnalysis?, outgoingURL: URL?
    ) -> (planned: PlannedTransition, refusal: String?) {
        guard let score = planned.style.score else { return (planned, nil) }
        func strip(_ why: String) -> (PlannedTransition, String?) {
            var style = planned.style
            style.score = nil
            // The **aim stays**, and deliberately. Its arithmetic is already in
            // the plan's entry and cannot be taken back out here; more to the
            // point it is still true — the incoming deck is entered so that the
            // drop falls on the hand-over, which under a blend is the predev's
            // own aimed-blend geometry (§2.3: overlap end on T) rather than an
            // orphan. Keeping it means the panel says "aimed at the drop, score
            // refused" instead of quietly showing an entry nothing explains.
            return (PlannedTransition(plan: planned.plan, style: style,
                                      rideDB: planned.rideDB), why)
        }
        guard let outgoing, let incoming else {
            return strip("乐谱要按两侧的小节网格落点，这次转场手里没有分析。")
        }
        let compiled = ScoreCompiler.compile(
            score, planned: planned, outgoing: outgoing, incoming: incoming,
            outgoingURL: outgoingURL)
        guard compiled.didCompile else {
            return strip(compiled.refusalReason ?? "编译器没有给出理由。")
        }
        return (planned, nil)
    }

    /// The seam a `score refused:` line has already been written for.
    ///
    /// Deliberately **not** cleared by `disarmTransition`: a seek disarms and
    /// re-arms the same seam, and clearing here is exactly how the field journal
    /// came to carry the same refusal three times for one hand-over. It falls
    /// out of date on its own, because a new seam has a new key.
    private var journalledScoreRefusal: ScoreRefusalKey?

    private func planTransition(for next: PrefetchedNext) -> PlannedTransition {
        guard transitionsWanted else { return .plain(.gapless) }
        if currentAnalysis == nil || next.analysis == nil {
            // Analyses not ready (first listen, current track still
            // streaming): a plain crossfade still beats a hard cut.
            //
            // No analysis means no beat grid, so this is the one refusal the
            // force override cannot argue with — and the one a listener is most
            // likely to hit, by flipping the toggle on a track heard for the
            // first time. Say so rather than leaving the badge on next to a
            // crossfade.
            if AutoMixDebugModel.shared.overrides.forceBeatMatch {
                AutoMixDebugModel.shared.setForceNote(
                    "force requested but impossible: "
                        + (currentAnalysis == nil ? "the playing track" : "the next track")
                        + " has no analysis yet")
            }
            guard duration > 45 else { return .plain(.gapless) }
            let fade: TimeInterval = 6
            return .plain(.crossfade(duration: fade,
                                     outPoint: max(duration - fade, duration * 0.6),
                                     inPoint: 0))
        }
        // Stem separation is archived (Archive/StemSeparation): no separator
        // is ever installed, so the planner is always told `.none` and every
        // hand-over takes the whole-mix path.
        let stems: StemAvailability = .none
        // Lyric line ends for the outgoing track, so the planner can pull its
        // out point back onto a full stop instead of cutting mid-line. The
        // `.lrc` sits next to the cached audio (written by `LyricsSidecar` on
        // the prefetch path), so this is a few-KB synchronous read on the main
        // actor — the same read `VocalExchange.compile` already does at
        // plan-adjacent time, run once per seam, minutes apart. Off the main
        // actor it would have to be awaited, which would turn arming into an
        // async step for no measurable gain. Missing file → empty → the
        // pre-structure decision, unchanged.
        // …and the two queue facts the intent layer's first rule turns on: are
        // these two tracks the same record, and are they in that record's
        // order. Both are read off the **listed** queue — `queue`, the order
        // the user sees — and never off the shuffled or AutoMix-reordered one,
        // because "an album in sequence" is a claim about the listing, not
        // about which two tracks a reorder happened to put together.
        //
        // Album id 0 is the empty `AlbumRef` a search result carries, so it
        // never counts as "the same album": two unknowns are not a record.
        // With `intentEnabled` off — every shipped build — nothing reads
        // either field.
        let outgoingAlbum = currentTrack?.album.id ?? 0
        let incomingAlbum = next.track.album.id
        let listedAdjacent = currentTrack.flatMap { current in
            queue.firstIndex(where: { $0.id == current.id }).map { index in
                index + 1 < queue.count && queue[index + 1].id == next.track.id
            }
        } ?? false
        // Both lyric clocks, for the same reason and off the same sidecars: the
        // vocal-exchange aim needs to know where the *incoming* track starts
        // singing, or it will enter deck B on top of a verse and mute the first
        // lines of it. Nil where there is no `.lrc`, which is the decision this
        // path made before the rule existed.
        let context = TransitionPlanner.PlanContext(
            outgoingLyricLineEnds: outgoingLyricTiming(for: currentLocalURL)?.lineEnds ?? [],
            outgoingLyricTiming: outgoingLyricTiming(for: currentLocalURL),
            incomingLyricTiming: Audition.Lyrics.timing(for: next.localURL),
            sameAlbum: outgoingAlbum != 0 && outgoingAlbum == incomingAlbum,
            listedAdjacent: listedAdjacent)
        let config = plannerConfig
        guard AutoMixDebugModel.shared.overrides.forceBeatMatch else {
            AutoMixDebugModel.shared.setForceNote(nil)
            return TransitionPlanner.plan(outgoing: currentAnalysis, incoming: next.analysis,
                                          stems: stems, config: config, context: context)
        }
        // Forced: take the ledger too. Under the override every admission gate
        // abstains, so whatever `blocker` names is one of the physical
        // requirements the panel refuses to fake — which is exactly the sentence
        // the listener needs when the seam comes out as a crossfade anyway.
        // The traced overload decides identically; it only costs the ledger,
        // and only on a seam somebody asked to force.
        var trace: PlanTrace? = PlanTrace()
        let planned = TransitionPlanner.plan(
            outgoing: currentAnalysis, incoming: next.analysis, stems: stems,
            config: config, context: context, trace: &trace)
        if case .beatMatched = planned.plan {
            AutoMixDebugModel.shared.setForceNote(nil)
        } else {
            AutoMixDebugModel.shared.setForceNote(
                trace?.blocker.map { "force requested but impossible: \($0.label) — \($0.detail)" }
                    ?? "force requested but impossible: no beat-matched plan and no blocking gate")
        }
        return planned
    }

    // MARK: - Stem pre-render

    /// How far ahead of the splice the pre-render is started, and the point at
    /// which an unfinished one is abandoned.
    ///
    /// A separation pass runs at roughly realtime per side, so a 15 s hand-over
    /// wanting both sides is ~30 s of work plus a second of rendering: a minute
    /// of lead is comfortable, and the guard is there so a machine that is
    /// busier than that never delays a hand-over — it simply gets the live one.
    // `nonisolated` for the same reason the runway constants below are: the
    // lead window is derived from the runway and both are read from the pure
    // helpers the tests drive directly.
    nonisolated static let stemPrerenderLead: TimeInterval = 60
    nonisolated private static let stemPrerenderGuard: TimeInterval = 5

    /// Cushion between "the work fits" and "start it now".
    ///
    /// The lead window's job is to open *before* the work stops fitting, and a
    /// window that opens exactly at `remaining == runway` opens for a single
    /// tick — the progress timer would have to land on it. Fifteen seconds is
    /// the same order as `stemPrerenderMargin` and gives the window a couple of
    /// hundred ticks to fire in.
    nonisolated static let stemPrerenderLeadSlack: TimeInterval = 15

    /// **How far ahead of the splice this particular seam's window opens.**
    ///
    /// The flat 60 s was measured in the two-lane era, when the most expensive
    /// seam anyone could arm was a 15 s overlap on both decks — 45 s of runway,
    /// comfortably inside it. It has since become the single number that
    /// decides *whether a long render can ever start at all*, and for a seam
    /// whose runway exceeds it the answer is no: `remaining` inside a 60 s
    /// window is by definition below a 74 s runway, so the feasibility guard
    /// refuses every tick of it and the only surviving start path is the 12 s
    /// stability clock, which a deadline-committed pick spends its whole life
    /// resetting. That is the field sample: `refused — not enough runway
    /// (60.0s left, 74.1s needed for a 29.6s overlap)`.
    ///
    /// So the window is derived from the work rather than fixed: a seam that
    /// needs 74.1 s gets a window that opens at 89.1 s, and starting inside it
    /// is what the `.lead` trigger has always meant. The classic 60 s is the
    /// floor, so nothing that used to start early now starts later.
    ///
    /// Bounded, deliberately, by the decision lead the pick deadline works to:
    /// the widest render anyone can arm is `TransitionSegmentRenderer.maxOverlap`
    /// at two sides (or one four-lane side, which costs the same), so this is
    /// never more than `2 x 30 + 15 + 15` = 90 s — inside the 120 s at which
    /// `updateAutoMixPick` commits a winner. The pick deadline therefore does
    /// not have to move for this, which is the whole reason it is not moving.
    nonisolated static func stemPrerenderLeadWindow(runway: TimeInterval) -> TimeInterval {
        max(stemPrerenderLead, runway + stemPrerenderLeadSlack)
    }

    /// **How long an armed plan must hold still before its pre-render may start
    /// early**, ahead of the lead window entirely.
    ///
    /// The lead window was a proxy for "the plan has stopped moving": start too
    /// soon and a re-plan throws the render away. Six hours of field journal say
    /// the proxy is far too expensive. 45 seams produced 130 `plan armed` lines
    /// — ~2.9 arms per seam — and **zero** of them were a genuine "plan
    /// replaced": the churn is the late analysis and the deadline-committed pick
    /// landing, all of it within seconds of the first arm and none of it after
    /// that. Meanwhile only 5 of the 45 seams got their spliced segment; the
    /// rest ran out of runway waiting for a window that opens 60 s before a
    /// splice a 30 s overlap needs 75 s for.
    ///
    /// So the trigger is stability, not proximity: twelve seconds is comfortably
    /// past where the churn lives and still leaves minutes of runway on a
    /// typical track. The feasibility check is unchanged and still has the last
    /// word — starting early buys runway, it does not excuse not having any —
    /// and a seam that moves afterwards cancels and re-renders exactly as it did.
    nonisolated static let stemPrerenderSettleSeconds: TimeInterval = 12

    /// Why a pre-render started, for the journal.
    enum StemPrerenderTrigger: String {
        /// The armed plan held still long enough to be believed, with more than
        /// the lead window still to go. The common case after this change.
        case settled
        /// The classic: the splice came inside the lead window.
        case lead
        /// Inside the lead window and short of it — the seam moved under a
        /// finished render, which is what a deadline-committed pick does.
        case late
    }

    /// Whether this tick starts the pre-render, and what to call the reason.
    ///
    /// Pure, and static, so the window can be tested without a player: the
    /// caller supplies the three numbers and gets back the journal's word for
    /// what it is about to do, or nil for "not yet, come back next tick".
    nonisolated static func stemPrerenderTrigger(
        remaining: TimeInterval, stableFor: TimeInterval, runway: TimeInterval
    ) -> StemPrerenderTrigger? {
        // Feasibility first, and it is never waived. A render that cannot
        // finish is Metal time spent on audio nobody will hear.
        guard remaining >= runway, remaining > stemPrerenderGuard else { return nil }
        // The window this seam's own work asks for, not the flat one — see
        // `stemPrerenderLeadWindow`. Inside it the stability clock is not
        // consulted at all, which is what guarantees an expensive seam a start:
        // the window opens while the work still fits, by construction.
        let lead = stemPrerenderLeadWindow(runway: runway)
        guard remaining > lead else {
            return remaining < lead - 2 ? .late : .lead
        }
        return stableFor >= stemPrerenderSettleSeconds ? .settled : nil
    }

    /// **Whether a four-lane render has to be taken down to two to fit.**
    ///
    /// The bill for a four-lane `bedIntro` is twice a two-lane one
    /// (`stemPrerenderFourLaneFactor`), so there is a band of runway — 44.6 s to
    /// 74.1 s for the field sample's 29.6 s overlap — where the seam can be
    /// rendered with the bed whole but not with the bed split three ways.
    ///
    /// Before this the band was simply refused, which made installing the
    /// four-stem checkpoint *worse* than not having it: the same seam on a
    /// machine with only the vocals model rendered a two-lane bed happily, and
    /// the machine with the better model got the live blend. A gesture heard in
    /// its two-lane form is the degradation `StemTechniqueLayer` already
    /// implements and already announces; not hearing it at all is not.
    ///
    /// Only feasibility decides this. Outside the lead window the trigger is
    /// still waiting for the plan to hold still, and waiting is not a reason to
    /// spend fewer lanes than the seam can afford.
    nonisolated static func stemPrerenderDegradesToTwoLanes(
        remaining: TimeInterval, fourLaneRunway: TimeInterval, twoLaneRunway: TimeInterval
    ) -> Bool {
        remaining < fourLaneRunway && remaining >= twoLaneRunway
    }

    /// How many lanes a started render is getting, in the journal's and the
    /// panel's shared vocabulary. `"0"` is a whole-mix score: no separator
    /// consulted on either side.
    nonisolated static func stemPrerenderLaneTag(
        separates: Bool, fourLane: Bool, degraded: Bool
    ) -> String {
        guard separates else { return "0" }
        guard degraded else { return fourLane ? "4" : "2" }
        return "2 (degraded from 4: runway)"
    }

    /// **Whether a refusal recorded earlier still stands.**
    ///
    /// A refusal is a statement about the clock — *this much left, that much
    /// needed* — and not about the seam, so it has to expire when the clock
    /// changes its mind. `remaining` normally only shrinks, which is why this
    /// was written as a terminal state, but two ordinary things grow it: a seek
    /// backwards (the parked render comes back onto the very same signature,
    /// now with minutes in front of it) and a re-plan that moves the splice
    /// later without moving the three numbers a `Signature` compares.
    ///
    /// The field sample shows exactly that shape — `refused … (60.0s left,
    /// 74.1s needed)` sitting on the panel next to a countdown reading T−01:45.
    /// 105 s is ample for a 74.1 s render, and the seam was refused anyway,
    /// because the refusal had been filed as "this seam has had its one
    /// attempt". It has not: it had one attempt *at 60 s*.
    nonisolated static func stemPrerenderRefusalStands(
        remaining: TimeInterval, runway: TimeInterval
    ) -> Bool {
        remaining < runway
    }

    /// Separation runs at roughly realtime **per side**, and a segment wants
    /// both sides of the seam.
    // `nonisolated` because `stemPrerenderRunway` is, and a default argument is
    // evaluated at the call site: leaving these main-actor-isolated makes the
    // new `sides:` default an actor hop the compiler has to complain about.
    nonisolated private static let stemPrerenderSidesPerSeam: Double = 2
    /// Slack on top of the separation estimate: the render pull loop, the file
    /// writes, and a machine that is doing other things at the same time.
    nonisolated private static let stemPrerenderMargin: TimeInterval = 15

    /// What a side costs when it is split four ways instead of two.
    ///
    /// The flat `1 x overlap` per side above was measured against the vocals
    /// checkpoint, which runs a 12 s window in 5.5 s on an M4 — comfortably
    /// inside its own budget. The four-stem checkpoint is a 131 M-parameter
    /// model against a 34 M one and takes **21.7 s** for the same window, which
    /// is 1.8x the term this formula charges rather than 0.46x of it. Charging
    /// it twice is the honest reading, rounded up, and it is what stops a
    /// four-lane bed from starting a render that then gets abandoned at the
    /// guard with the Metal time already spent.
    nonisolated static let stemPrerenderFourLaneFactor: Double = 2

    /// How much runway one seam's pre-render actually needs.
    ///
    /// This is the arithmetic that was hiding inside the flat 60 s lead — "a
    /// 15 s hand-over wanting both sides is ~30 s of work plus a second of
    /// rendering" — pulled out and made **per-seam**, so a seam that moves
    /// underneath a finished render can be judged on whether the re-render
    /// *fits* rather than on whether it is early.
    ///
    /// That distinction is the whole fix. The old code had one number doing two
    /// jobs: "not yet" and "no longer possible". A deadline-committed pick
    /// arrives late by construction — the winner still has to be re-downloaded
    /// at playback quality, re-analyzed and re-planned, which moves the seam —
    /// and the re-render was then refused for being late even when there was
    /// ample time to do it. A 16 s overlap needs 47 s; being handed 49 s is not
    /// a problem, and now it is not treated as one.
    ///
    /// `separatesStems` false is a **score-only** segment: whole-mix gain lanes,
    /// no separator consulted on either side (`WholeMixLaneLayer`). The
    /// separation term is then not small, it is *absent* — what is left is one
    /// render pass, and the margin already covers that with room to spare. This
    /// is why a cut-on-one costs the runway a 30 s overlap used to be refused
    /// for and a `.vocalExchange` still does.
    ///
    /// `sides` is how many decks get separated, and P4 gave it a second value.
    /// A stem technique rewrites the outgoing deck and, for a four-lane
    /// envelope, the incoming one too — two passes, which is the flat 2 this
    /// has always assumed. A score's `bedIntro` splits the **incoming deck
    /// only**: the bed is the incoming track minus its singer and the outgoing
    /// track is not touched at all. So it pays one pass, not two, and a 16 s
    /// hand-over that would need 47 s of runway with stems on both sides needs
    /// 31 s with a bed — which is what keeps the one stem-bearing gesture
    /// inside the 120 s decision lead the predev budgets for (§2.2).
    nonisolated static func stemPrerenderRunway(
        overlapDuration: TimeInterval, separatesStems: Bool = true,
        sides: Double = stemPrerenderSidesPerSeam,
        fourLane: Bool = false
    ) -> TimeInterval {
        guard separatesStems else { return stemPrerenderMargin }
        let perSide = fourLane ? stemPrerenderFourLaneFactor : 1
        return max(0, sides) * perSide * max(0, overlapDuration) + stemPrerenderMargin
    }

    /// Internal rather than private only so the reuse rule below can be tested
    /// on both of its arms: what "already have this one" means is exactly that
    /// a finished render and an in-flight one answer `signature` alike.
    enum StemPrerenderState {
        case idle
        /// A job is running for this seam.
        case running(TransitionSegment.Signature)
        /// This seam has had its one attempt — finished, failed or abandoned.
        /// Never retried: the lead time is gone either way.
        case settled(TransitionSegment.Signature)
        /// Never started, because the work did not fit in what was left. Held
        /// with the runway it was judged against, because that judgement is
        /// only good for as long as `remaining` keeps shrinking — see
        /// `stemPrerenderRefusalStands`.
        case refused(TransitionSegment.Signature, runway: TimeInterval)

        var signature: TransitionSegment.Signature? {
            switch self {
            case .idle: return nil
            case .running(let s), .settled(let s): return s
            case .refused(let s, _): return s
            }
        }
    }

    /// **Whether a re-arm throws away the render already held for this seam.**
    ///
    /// Only a signature that actually *differs* does. An identical one is not a
    /// new seam — the splice, the entry and the overlap are the three things a
    /// segment is rendered against, and if none of them moved then the audio in
    /// hand is the audio wanted, whether it is finished (`.settled`) or still
    /// being made (`.running`). The field journal's 2.9 arms per seam are almost
    /// entirely this case, and discarding on any of them would have thrown away
    /// work that was already correct.
    static func stemPrerenderDiscards(
        held: StemPrerenderState, armed: TransitionSegment.Signature
    ) -> Bool {
        guard let held = held.signature else { return false }
        return held != armed
    }

    /// A pre-render's stop switch.
    ///
    /// `Task.cancel` alone would only orphan the job: the render is a
    /// synchronous pull loop inside a detached task and a separation pass is
    /// seconds of Metal work. So cancellation is also checked where it can
    /// actually be acted on — at each separation boundary, which is where all
    /// the time goes.
    private final class PrerenderCancel: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
    }

    private var stemPrerenderTask: Task<Void, Never>?
    private var stemPrerenderCancel: PrerenderCancel?
    private var stemPrerenderState: StemPrerenderState = .idle

    /// The signature the armed plan has been carrying, and the playhead reading
    /// at which it first appeared — the clock `stemPrerenderTrigger` reads.
    ///
    /// Measured in playback seconds rather than wall-clock on purpose: it is the
    /// same clock `remaining` is measured against, so "held still for 12 s" and
    /// "60 s of lead" are the same kind of second, and a paused player does not
    /// accrue confidence in a seam nobody is approaching.
    private var stemPrerenderStable: (signature: TransitionSegment.Signature,
                                      since: TimeInterval)?

    /// Polled from the progress timer: start, abandon or ignore the pre-render
    /// of the armed hand-over. Cheap — a few comparisons — until the moment it
    /// starts the one background job it will ever run for a given seam.
    private func updateStemPrerender() {
        // Debug A/B: skip the render entirely so the seam is carried by the
        // live two-deck path, which is the approximation a stem hand-over
        // exists to beat. `setOverrides` tears down and re-arms when this is
        // switched on, so a segment armed a moment ago is already gone.
        if AutoMixDebugModel.shared.overrides.forceLivePath {
            AutoMixDebugModel.shared.setPrerender(
                .refused("force live path (debug override)"))
            return
        }
        guard transitionArmed, let planned = armedPlan else { return }
        // A hand-over with neither a stem technique nor a score has nothing to
        // pre-render, and the row must say that rather than keep whatever the
        // last seam left there. This is where a refused score lands — the plan
        // it leaves behind is a plain blend, and a plain blend is not a failed
        // render. The reason itself has its own row in the Plan group.
        guard planned.style.stemTechnique != nil || planned.style.score != nil else {
            AutoMixDebugModel.shared.setPrerender(.notNeeded)
            return
        }
        guard let signature = TransitionSegment.Signature(plan: planned.plan),
              let outgoingURL = currentLocalURL, let next = prefetchedNext
        else { return }
        // A stem technique needs a separator; four of the five gestures in the
        // score library do not touch one. That asymmetry is the whole cost
        // story of the score model — a score-only segment is a render and
        // nothing else — so it decides both the admission above and the runway
        // below. The fifth gesture, `bedIntro`, is the exception and says so
        // itself: `RunwayClass` is a property of the score, read here at arming
        // time and again by the compiler, so the bill and the work cannot
        // disagree.
        let scoreSeparates = planned.style.score?.runwayClass == .incomingStems
        let separatesStems = planned.style.stemTechnique != nil || scoreSeparates
        // One deck for a bed, two for a stem technique that may write all four
        // lanes.
        let separatedSides = planned.style.stemTechnique != nil
            ? Self.stemPrerenderSidesPerSeam : 1
        // A score that asks for the incoming track's stems (`bedIntro`) is the
        // one separating job the plan gate above cannot pre-empt, because the
        // score is chosen after `stems`. Stem separation is archived, so such a
        // seam is never rendered and the live blend carries it.
        guard !separatesStems else { return }

        // A re-plan (a late analysis, a degraded seam after a seek) moves the
        // splice; whatever was rendered for the old one is the wrong audio.
        // A re-plan that lands on the *same* signature is not a move at all and
        // is deliberately not handled here — see `noteArmedSignature`.
        if Self.stemPrerenderDiscards(held: stemPrerenderState, armed: signature) {
            cancelStemPrerender()
        }
        let splice = signature.outPoint - TransitionSegmentRenderer.handoff
        // The live playhead, not the published `progress`: that one is only
        // republished when the scrubber would visibly move, so it can sit up to
        // half a second behind — half a second of runway this decision spends.
        let remaining = splice - livePlaybackTime

        // A refusal expires when the clock it was filed against does. The seam
        // has not moved (a moved one was discarded above) — the playhead has,
        // backwards, or the splice has slid later inside the millisecond slack
        // a `Signature` compares on. Either way the arithmetic that said no is
        // no longer the arithmetic in front of us, so the seam goes back to
        // `.idle` and this very tick reconsiders it.
        if case .refused(_, let refusedRunway) = stemPrerenderState,
           !Self.stemPrerenderRefusalStands(remaining: remaining, runway: refusedRunway) {
            stemPrerenderState = .idle
            AutoMixDebugModel.shared.setPrerender(.idle)
            PlaybackJournal.note(String(
                format: "prerender refusal lifted (%.1fs left now, %.1fs needed)",
                remaining, refusedRunway))
        }

        switch stemPrerenderState {
        case .settled, .refused:
            return
        case .running:
            // Out of runway: drop the job and let the live path have the
            // hand-over. The engine has never been told about this segment, so
            // there is nothing to undo there.
            if remaining < Self.stemPrerenderGuard {
                stemPrerenderCancel?.cancel()
                stemPrerenderTask?.cancel()
                stemPrerenderTask = nil
                stemPrerenderState = .settled(signature)
                AutoMixDebugModel.shared.setPrerender(
                    .abandoned(String(format: "out of runway (%.1fs left)", remaining)))
            }
            return
        case .idle:
            // Whole-mix only: separation is archived, so nothing here is
            // ever billed for a separator.
            let runway = Self.stemPrerenderRunway(
                overlapDuration: signature.overlapDuration,
                separatesStems: false, sides: separatedSides, fourLane: false)

            let stableFor = stemPrerenderStable.map { livePlaybackTime - $0.since } ?? 0
            guard let trigger = Self.stemPrerenderTrigger(
                remaining: remaining, stableFor: stableFor, runway: runway) else {
                // Two very different "no"s, and only one of them stops the next
                // tick from asking. Outside the lead window this is "not yet" —
                // the plan is still churning — and nothing is recorded. Inside
                // it the work genuinely does not fit in what is left, and by
                // here that is true of the cheapest lane count this seam has,
                // so say so with the numbers and stand down. Standing down is
                // not the same as giving up: the refusal is filed against the
                // clock that produced it and lifts if the clock changes.
                guard remaining <= Self.stemPrerenderLeadWindow(runway: runway) else { return }
                stemPrerenderState = .refused(signature, runway: runway)
                let why = String(
                    format: "not enough runway (%.1fs left, %.1fs needed for a %.1fs overlap)",
                    remaining, runway, signature.overlapDuration)
                AutoMixDebugModel.shared.setPrerender(.refused(why))
                PlaybackJournal.note("prerender refused \(why)")
                return
            }
            PlaybackJournal.note(String(
                format: "prerender start trigger=%@ remaining=%.1fs runway=%.1fs "
                    + "overlap=%.1fs stable=%.1fs lanes=%@",
                trigger.rawValue, remaining, runway, signature.overlapDuration, stableFor,
                Self.stemPrerenderLaneTag(separates: false, fourLane: false,
                                          degraded: false)))
        }

        // A whole-mix score never asks for stems, so it is handed a provider
        // that throws if it ever did; separation is archived.
        let provider: VocalStemProvider = { _ in throw StemTechniqueLayer.StemError.noProvider }
        let request = TransitionSegmentRenderer.Request(
            planned: planned, outgoingURL: outgoingURL, incomingURL: next.localURL,
            outgoingTrimDB: loudnessTrimDB(for: currentAnalysis),
            incomingTrimDB: loudnessTrimDB(for: next.analysis),
            masterLimiterActive: AutoMixDebugModel.shared.overrides.enableMasterLimiter,
            outgoingAnalysis: currentAnalysis, incomingAnalysis: next.analysis,
            config: plannerConfig)
        let generation = resolveGeneration
        let stop = PrerenderCancel()
        stemPrerenderCancel = stop
        let cancellable: VocalStemProvider = { request in
            if stop.isCancelled { throw CancellationError() }
            return try provider(request)
        }
        stemPrerenderState = .running(signature)
        AutoMixDebugModel.shared.setPrerender(
            .rendering(Self.debugSignature(signature) + " · whole-mix"))
        stemPrerenderTask = Task { [weak self] in
            // Separation is Metal work and rendering is a synchronous pull
            // loop; both belong off the main actor entirely.
            // The error is kept, not discarded. Every refusal in there already
            // carries a sentence (`SegmentError.errorDescription`), and
            // throwing them away was how a compile refusal, a missing separator
            // and a genuinely empty buffer all arrived at the panel as "render
            // produced nothing" — the one of the three that was almost never
            // true.
            let outcome = await Task.detached(priority: .utility) {
                Result {
                    try TransitionSegmentRenderer.render(
                        request, provider: cancellable, fullProvider: nil)
                }
            }.value
            guard let self, !Task.isCancelled, generation == self.resolveGeneration else { return }
            switch outcome {
            case .failure(let error):
                AutoMixDebugModel.shared.setPrerender(
                    .abandoned(error.localizedDescription))
            case .success(let segment):
                // The engine rejects it if the seam moved underneath us or the
                // playhead is already past the splice, and plays the live
                // hand-over instead — this is a suggestion, not a command.
                self.engine.armTransitionSegment(segment)
                // The offer is fire-and-forget, so the outcome is asked for
                // afterwards — but the engine now says *which* guard declined
                // rather than leaving the panel to guess, which is how a render
                // that finished 27 s early came to be reported as a seam that
                // had moved. One queue hop, once per seam.
                AutoMixDebugModel.shared.setPrerender(
                    self.engine.lastSegmentDecline.map {
                        .refused("engine declined — \($0.explanation)")
                    } ?? .armed(Self.debugSignature(signature) + " · whole-mix"))
            }
            self.stemPrerenderTask = nil
            self.stemPrerenderState = .settled(signature)
        }
    }

    /// The armed plan was just written or re-written: run the stability clock
    /// the settle trigger reads, and say so when a re-arm landed on the very
    /// render that is already in flight or already in hand.
    ///
    /// Reuse is structural rather than newly built — `updateStemPrerender`
    /// cancels only on a signature that *differs* — but it was invisible, and
    /// invisible is how 2.9 arms per seam came to look like 2.9 reasons to be
    /// cautious. None of those arms was a real plan change; the journal now says
    /// that out loud, per arm, so the next reading of the field data can tell a
    /// kept render from a lucky one.
    private func noteArmedSignature(_ planned: PlannedTransition) {
        guard let signature = TransitionSegment.Signature(plan: planned.plan) else {
            stemPrerenderStable = nil
            return
        }
        guard stemPrerenderStable?.signature == signature else {
            stemPrerenderStable = (signature, livePlaybackTime)
            return
        }
        if let held = stemPrerenderState.signature, held == signature {
            PlaybackJournal.note(
                "prerender reuse signature=\(Self.debugSignature(signature))")
        }
    }

    private func cancelStemPrerender() {
        stemPrerenderCancel?.cancel()
        stemPrerenderCancel = nil
        stemPrerenderTask?.cancel()
        stemPrerenderTask = nil
        stemPrerenderState = .idle
        parkedPrerender = nil
        AutoMixDebugModel.shared.setPrerender(.idle)
    }

    /// A render held across a disarm/re-arm pair, waiting to find out whether
    /// the seam that comes back is the seam it was made for.
    private var parkedPrerender: StemPrerenderState?

    /// **Whether a parked render survives the re-arm.**
    ///
    /// The same rule as `stemPrerenderDiscards`, from the other side: the splice,
    /// the entry and the overlap are the three things a segment is rendered
    /// against, so a re-armed plan that answers `Signature` identically wants
    /// exactly the audio already in hand — finished or still being made.
    ///
    /// A seek used to lose that unconditionally. The field journal shows the
    /// cost: a jump to the seam starts a render at `trigger=settled` with 159 s
    /// of runway, the jump disarms and re-arms one second later onto the *same*
    /// signature, and the replacement starts at `trigger=late` with 29 s — which
    /// then loses the race and reaches the engine after the splice — which the
    /// panel of the day reported as `seam moved or splice passed`, a guess it
    /// no longer has to make (`PlaybackEngine.SegmentDecline`). Nothing had moved.
    ///
    /// A refusal is the one thing that deliberately does **not** survive. There
    /// is no audio to keep — that is what a refusal is — and the reason it was
    /// filed is a clock reading the seek has just rewritten. Carrying it across
    /// would preserve "no" as the answer to a question nobody has asked since.
    static func prerenderSurvivesReArm(
        parked: StemPrerenderState, rearmed: TransitionSegment.Signature?
    ) -> Bool {
        if case .refused = parked { return false }
        guard let held = parked.signature, let rearmed else { return false }
        return held == rearmed
    }

    /// Settle a parked render against whatever was just re-armed: keep it when
    /// the signature is unchanged, drop it otherwise. Called after the re-arm,
    /// and unconditionally — a re-arm that never happened (no prefetched track
    /// left) has no plan to match, so the render goes.
    ///
    /// The engine-side offer is untouched by any of this. When the finished
    /// segment is handed over it is still checked against the live plan and the
    /// live playhead, and still declined if the splice really has passed — the
    /// rescue is about not throwing away correct work, not about forcing it in.
    private func reconcileParkedPrerender() {
        guard let parked = parkedPrerender else { return }
        parkedPrerender = nil
        let rearmed = armedPlan.flatMap { TransitionSegment.Signature(plan: $0.plan) }
        guard Self.prerenderSurvivesReArm(parked: parked, rearmed: rearmed),
              let held = parked.signature else {
            cancelStemPrerender()
            return
        }
        PlaybackJournal.note(
            "prerender kept across seek signature=\(Self.debugSignature(held))")
    }

    /// `Config.standard` with the one knob the user can see: the planner's
    /// loudness gate must measure the same thing the decks will play, so the
    /// compensation setting has to reach it.
    ///
    /// The debug panel's force override is applied here rather than at the one
    /// planning call, so the stem pre-render is built against the very config
    /// the plan was made under. Off — always, on iOS and for anyone who has not
    /// opened the panel — `plannerConfig` returns exactly what it always did.
    private var plannerConfig: TransitionPlanner.Config {
        var config = TransitionPlanner.Config.standard
        config.loudnessCompensation = loudnessCompensationEnabled
        return AutoMixDebugOverrides.plannerConfig(
            config, overrides: AutoMixDebugModel.shared.overrides)
    }

    /// Flip the debug panel's overrides and re-derive the hand-over that is
    /// already armed, so a toggle is heard at the *next* seam rather than the
    /// one after it — flipping and then replaying the same seam is the whole
    /// point of the switches.
    ///
    /// A plain re-plan is enough for the planner knobs: the engine only swaps a
    /// hand-over that has not started, so it can never cut audio. Turning the
    /// live path on needs more, because the engine has no un-arm call for a
    /// pre-rendered segment — the seam is torn down and re-armed instead, the
    /// same two calls a seek makes.
    func setOverrides(_ new: AutoMixOverrides) {
        let old = AutoMixDebugModel.shared.overrides
        AutoMixDebugModel.shared.writeOverrides(new)
        // Pure observation: pushed straight through, and deliberately not part
        // of the re-arm test below — see `needsReArm`.
        if new.verboseEngineTrace != old.verboseEngineTrace {
            engine.setVerboseTrace(new.verboseEngineTrace)
        }
        // Pushed before the re-arm below, so a segment re-rendered because of
        // this very flag is rendered under the regime the engine is now in.
        // The track already on a deck keeps the pad it was loaded with — the
        // pad is a load-time size, deliberately (see `LoudnessCompensation`),
        // so the switch takes full effect on the next load, exactly like the
        // body-level trim it sits beside.
        if new.enableMasterLimiter != old.enableMasterLimiter {
            engine.setMasterLimiter(new.enableMasterLimiter)
        }
        // Also pure arming arithmetic, and also deliberately not a re-arm: the
        // pin is read when the *next* segment goes on the render clock, so a
        // seam already armed keeps the compensation it was armed with — which
        // is the honest thing for the A/B, since that seam's audio was
        // scheduled under it.
        if new.headLatencyCompensationMS != old.headLatencyCompensationMS {
            engine.setHeadLatencyPin(new.headLatencyCompensationMS)
        }
        if new.needsReArm(comparedTo: old), transitionArmed {
            disarmTransition()
            armTransitionIfReady()
        } else {
            replanArmedTransition()
        }
    }

    /// Spill the engine's knob-write ring into a file, on demand — the panel's
    /// button, for the moment a listener hears something wrong and there is no
    /// seam or alarm about to dump it for them.
    func dumpEngineTrace(reason: String = "manual") {
        engine.dumpEngineTrace(reason: reason)
    }

    /// The panel's other button: the master path as wired plus eight seconds
    /// of output on tape, for a listener who hears it wrong *right now*.
    func captureOutputNow() {
        engine.captureOutputNow()
    }

    /// Whether cross-track gain compensation is active right now. AutoMix off
    /// means no analyses are computed at all, so there is nothing to compensate
    /// with either.
    private var loudnessCompensationEnabled: Bool {
        return SettingsManager.shared.automixEnabled
            && SettingsManager.shared.loudnessCompensationEnabled
    }

    /// The playback trim to load a track at, given whatever analysis is in hand.
    ///
    /// Reads its house level from `plannerConfig`, which is also what the
    /// planner's loudness gate and both offline renderers measure against: the
    /// deck and the plan must never be trimmed to two different targets, or the
    /// gate would judge a seam the player does not play. See
    /// `TransitionPlanner.Config.loudnessTargetLUFS`.
    private func loudnessTrimDB(for analysis: TrackAnalysis?) -> Double {
        LoudnessCompensation.trimDB(for: analysis, enabled: loudnessCompensationEnabled,
                                    config: plannerConfig.loudnessConfig)
    }

    /// Whether analysis results would ever be consumed: on iOS, with the
    /// AutoMix master off, and with every sub-setting that could read an
    /// analysis off, decoding + analyzing the whole track would be pure waste.
    ///
    /// Three consumers, so three terms. Transitions plan against two beat
    /// grids; the AutoMix order scores candidates with the same planner; the
    /// loudness trim reads the integrated LUFS off the same analysis. Stems
    /// are deliberately *not* a term — a stem technique only ever exists
    /// inside a transition, so it can never be the reason an analysis is
    /// computed.
    private var analysisWanted: Bool {
        let settings = SettingsManager.shared
        return Self.analysisWanted(master: settings.automixEnabled,
                                   transitions: settings.automixTransitionsEnabled,
                                   order: settings.automixOrderEnabled,
                                   loudness: settings.loudnessCompensationEnabled)
    }

    /// The rule above as a pure function, so it can be stated once and tested
    /// without a player.
    static func analysisWanted(master: Bool, transitions: Bool,
                               order: Bool, loudness: Bool) -> Bool {
        master && (transitions || order || loudness)
    }

    /// Whether a seam may be anything other than gapless. The master switch
    /// and the transitions sub-switch, and nothing else — an analysis computed
    /// for the loudness trim must not quietly buy a crossfade.
    private var transitionsWanted: Bool {
        return SettingsManager.shared.automixEnabled
            && SettingsManager.shared.automixTransitionsEnabled
    }

    /// Sidecar-cached analysis, computing (and persisting) it on a miss.
    private func analysis(for key: EngineAudioCache.Key, fileURL: URL) async -> TrackAnalysis? {
        guard analysisWanted else { return nil }
        if let cached = await AnalysisStore.shared.loadAnalysis(for: key) { return cached }
        let analyzed = await Task.detached(priority: .utility) {
            try? TrackAnalyzer.analyze(fileAt: fileURL)
        }.value
        if let analyzed {
            await AnalysisStore.shared.storeAnalysis(analyzed, for: key)
        }
        return analyzed
    }

    /// Analyze the track now playing once its complete file exists locally
    /// (cache hit, stream commit, or fallback download).
    private func ensureCurrentAnalysis(key: EngineAudioCache.Key, fileURL: URL) {
        guard analysisWanted else { return }
        let generation = resolveGeneration
        Task { [weak self] in
            guard let self else { return }
            let result = await self.analysis(for: key, fileURL: fileURL)
            guard generation == self.resolveGeneration, let result else { return }
            self.currentAnalysis = result
            // The outgoing side of every candidate score just arrived; a pick
            // that was waiting on it can now be made. Harmless once the pick
            // is committed — `updateAutoMixPick` returns on the first guard.
            self.updateAutoMixPick()
            self.replanArmedTransition()
        }
    }

    /// The outgoing analysis landed after the hand-over was armed with a
    /// degraded plan — upgrade it in place. The engine only swaps the plan
    /// while the transition is still waiting, so audible audio is never cut.
    private func replanArmedTransition() {
        guard transitionArmed, let next = prefetchedNext else { return }
        let planned = makeTransitionPlan(for: next)
        engine.replaceTransitionPlan(planned)
        armedPlan = planned
        noteArmedSignature(planned)
        publishDebugPlan(planned, next: next)
    }

    /// The engine crossed the transition midpoint: the incoming deck is now
    /// the audible one, so the app's notion of "current track" flips here.
    /// Two AU state dumps per track: one at start (the state the song begins
    /// under) and one 25 s in — past every release/glide the transition leaves
    /// running — so a "the whole song sounds underwater" report can be answered
    /// by reading what the units actually held mid-song, not what we set.
    private func scheduleAudioUnitReadback() {
        engine.journalAudioUnitReadback("start")
        // What the delayed half must still be true of is *this track, still on
        // the air* — which is not what `resolveGeneration` counts.
        //
        // The generation belongs to source resolution, and only a directly
        // started track goes through it: a track adopted through a hand-over
        // (`adoptTransitionedTrack`) was resolved as the *next* track long
        // before it became current, and by 25 s in the generation has usually
        // moved on again for the one after it. So every hand-over's readback
        // was silently dropped and the remote journal had `AU readback(t+25s)`
        // exactly once a session — for the first, directly-started track,
        // which is the one case the "whole song sounds underwater" report is
        // least about, since almost every track arrives through a hand-over.
        //
        // The identity of the track is the honest guard, and pausing is the
        // other half of it: reading the units back and taking an eight-second
        // tap of silence would answer a question nobody asked.
        let trackID = currentTrack?.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, let trackID,
                  self.currentTrack?.id == trackID, self.isPlaying else { return }
            self.engine.journalAudioUnitReadback("t+25s")
            // The "muffled" phase specimen; its bright counterpart is the
            // engine's own capture at overlap begin. Eight seconds of output is
            // a ~3 MB CAF on disk *per track*, so it is tied to the trace
            // switch rather than taken from every listener all the time — the
            // AU readback lines above are free and stay unconditional.
            guard AutoMixDebugModel.shared.overrides.verboseEngineTrace else { return }
            self.engine.captureOutputTap(seconds: 8, label: "t25-\(trackID)")
        }
    }

    private func adoptTransitionedTrack(on deck: Deck) {
        guard let next = pendingTransitionTrack else { return }
        // A hand-over is an automatic advance, and the outgoing download is done.
        releaseOfflineLease()
        currentWasAdvanced = true
        scrobbleIfNeeded(completed: true)
        scrobbled = false
        consecutiveFailures = 0

        // Advance the queue pointers the same way advanceToNext would have.
        if isFMMode {
            if fmUpcoming.first?.id == next.id { fmUpcoming.removeFirst() }
        } else if playNextList.first?.id == next.id {
            playNextList.removeFirst()
        } else {
            // Advance sequentially like advanceToNext would; only fall back
            // to searching if the queue changed under us. A plain firstIndex
            // would jump back to an earlier copy of a duplicated track.
            var idx = currentIndex + 1
            if idx >= activeQueue.count { idx = 0 }
            if idx < activeQueue.count, activeQueue[idx].id == next.id {
                currentIndex = idx
            } else if let found = activeQueue.firstIndex(where: { $0.id == next.id }) {
                currentIndex = found
            }
        }

        currentTrack = next
        historySession = nil
        scrobbleStartIfNeeded(next)
        activeDeck = deck
        deckLoaded = true
        hasLocalFile = true
        isBuffering = false
        currentCacheKey = prefetchedNext?.key
        currentLocalURL = prefetchedNext?.localURL
        currentRemoteURL = nil
        currentAnalysis = prefetchedNext?.analysis
        servedQuality = prefetchedNext?.level
        servedQishuiQualityOption = prefetchedNext?.qishuiQualityOption
        // Same telemetry as the direct-start path: most tracks arrive here.
        PlaybackJournal.note(
            "now playing id=\(next.id) level=\(prefetchedNext?.level ?? "?") "
            + "wanted=\(SettingsManager.shared.audioQuality.rawValue) via=handover")
        scheduleAudioUnitReadback()
        unblockSource = prefetchedNext?.unblockSource
        externalQualityTitle = prefetchedNext?.externalQualityTitle
        // A handed-over track plays from a complete local file.
        currentUnblockSourceID = nil
        attemptedUnblockSources = []
        isTrial = false
        isPlaying = true
        progress = engine.position(of: deck)
        duration = engine.duration(of: deck) ?? next.duration
        if next.platformSong?.source == .qishui, let local = prefetchedNext?.localURL {
            servedQishuiQualityOption = .qishuiLocal(url: local, level: servedQuality, duration: duration)
                ?? servedQishuiQualityOption
        }
        lyrics = nil
        resolvedLyricsSource = nil
        currentLyricLRC = nil
        pendingTransitionTrack = nil
        prefetchedNext = nil
        // A hand-over is as much a "new track" as a manual start: without this
        // the committed flag survives into the next song, `autoMixPickPending`
        // never comes back up, and the mode silently degrades to list order
        // for every track that arrives via a transition (which is all of them).
        // `progress`/`duration`/`currentAnalysis` above are already this
        // track's, so the deadline the next tick reads is not stale.
        autoMixPickCommitted = false
        queueOrderSelector?.beginPick()
        autoMixStaleDeadlineNoted = false
        // The song that was "next" is now "now"; `schedulePrefetch` (via
        // transitionCompleted) fills the group in again a moment later.
        AutoMixDebugModel.shared.clearNext()
        publishDebugNow()

        resolveGeneration += 1
        let generation = resolveGeneration
        NowPlayingManager.shared.updateMetadata(for: next, duration: duration)
        NowPlayingManager.shared.updateElapsed(progress, rate: 1)
        persistState()
        Task { await loadLyrics(for: next, generation: generation) }

        if isFMMode, fmUpcoming.count < 1 {
            Task {
                if let more = try? await NeteaseAPI.personalFM() {
                    fmUpcoming.append(contentsOf: more)
                    schedulePrefetch()
                }
            }
        }
    }

    private func displayLyrics(_ response: LyricResponse) {
        lyrics = LyricsParser.parse(response, track: currentTrack)
    }

    func selectLyricsSource(_ source: LyricsSource) async {
        guard let track = currentTrack else { return }
        source.save(for: track.id)
        await loadLyrics(for: track, generation: resolveGeneration, userInitiated: true)
        scheduleLyricsResync()
    }

    func loadCurrentLyricsIfNeeded() async {
        guard lyrics == nil, !lyricsSourceLoading, let track = currentTrack else { return }
        await loadLyrics(for: track, generation: resolveGeneration)
    }

    private func loadLyrics(for track: Track, generation: Int, userInitiated: Bool = false) async {
        let scope = offlineAccountScope
        guard generation == resolveGeneration, currentTrack?.id == track.id else { return }
        let requestID = UUID()
        lyricsRequestID = requestID
        let source = LyricsSource.saved(for: track.id)
        if lyrics == nil { lyricsSource = source }
        lyricsSourceLoading = true
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
            guard lyricsRequestID == requestID, generation == resolveGeneration,
                  currentTrack?.id == track.id else { return }
            applyLyrics(selection.response)
            lyricsSource = source
            resolvedLyricsSource = selection.source
            if let scope { await OfflineMetadataStore.shared.keepPlaybackData(track: track, scope: scope) }
        } catch {
            guard lyricsRequestID == requestID, generation == resolveGeneration,
                  currentTrack?.id == track.id else { return }
            if lyrics != nil { lyricsSource.save(for: track.id) }
            else { lyrics = ParsedLyrics() }
            if let message = source.failureToast(for: error, userInitiated: userInitiated, keptLyrics: !(lyrics?.isEmpty ?? true)) {
                ToastCenter.shared.show(message)
            }
        }
    }

    private func applyLyrics(_ response: LyricResponse) {
        displayLyrics(response)
        updateLyricsCursor(at: livePlaybackTime)
        currentLyricLRC = response.lrc?.lyric
        persistCurrentLyricsSidecar()
    }

    /// Write the current track's `.lrc` next to its local file once both halves
    /// are known. The outgoing side of a seam is the one a `vocalExchange`
    /// reads, so the *playing* track needs its sidecar too — a prefetch-only
    /// write leaves the first track of every session wordless.
    ///
    /// Streaming-only playback has no file and writes nothing.
    private func persistCurrentLyricsSidecar(audio: URL? = nil) {
        guard let audio = audio ?? currentLocalURL, let lrc = currentLyricLRC else { return }
        Task.detached(priority: .utility) { LyricsSidecar.write(lrc, for: audio) }
    }

    // MARK: - AutoMix debug panel

    // Everything below only *reads* state this class already keeps, and writes
    // it into `AutoMixDebugModel`. Nothing here may change playback: the panel
    // is a mirror, and a mirror that moved the thing it reflects would make the
    // listening tests it exists for worthless.

    private static func debugSignature(_ signature: TransitionSegment.Signature) -> String {
        String(format: "out %.2fs · in %.2fs · overlap %.2fs",
               signature.outPoint, signature.inPoint, signature.overlapDuration)
    }

    /// A player-level phase. The engine's own `TransitionPhase` lives on its
    /// audio queue and is not reported, so this is what the *orchestrator*
    /// believes — which is also what the plan/pre-render groups are keyed to.
    private func debugPhaseLabel() -> String {
        guard deckLoaded else { return currentTrack == nil ? "idle" : "no source" }
        var phase = isBuffering ? "buffering" : (isPlaying ? "playing" : "paused")
        if transitionArmed { phase += " · handover armed" }
        return phase
    }

    private func publishDebugNow() {
        // One queue hop for both decks, and only while the panel is open — see
        // `PlaybackEngine.deckGains`. Reading them separately could straddle a
        // transition tick, which is the exact instant a stuck rate is about to
        // be explained away.
        let gains = engine.deckGains()
        func deck(_ which: Deck, _ snapshot: PlaybackEngine.DeckGainSnapshot)
            -> AutoMixDebugDeck {
            AutoMixDebugDeck(
                role: which == activeDeck
                    ? (transitionArmed ? "outgoing" : "playing")
                    : (transitionArmed ? "incoming" : "idle"),
                rate: snapshot.rate, trimDB: snapshot.trimDB, rideDB: snapshot.rideDB,
                ratePadDB: snapshot.ratePadDB, inTransition: snapshot.inTransition)
        }
        AutoMixDebugModel.shared.setNow(AutoMixDebugNow(
            title: currentTrack?.name,
            phase: debugPhaseLabel(),
            deck: activeDeck.rawValue.uppercased(),
            position: livePlaybackTime,
            duration: duration,
            trimDB: loudnessTrimDB(for: currentAnalysis),
            analyzed: currentAnalysis != nil,
            deckA: deck(.a, gains.a),
            deckB: deck(.b, gains.b)))
        publishDebugOrder()
    }

    /// How long a preview scoring pass is reused for while the pick is still
    /// pending. The table has to be *live* to be worth anything — the whole
    /// question is "what is it weighing right now" — but a pass costs one
    /// `TransitionPlanner.plan` per candidate, which is not a thing to run
    /// five times a second. Two seconds is faster than a listener can read a
    /// row and slow enough to be free.
    private static let debugOrderPreviewInterval: TimeInterval = 2

    private var lastDebugOrderPreview: Date = .distantPast

    /// The queue-order group. Only ever called from `publishDebugNow`, which
    /// only the open panel calls — so the preview pass below cannot cost a
    /// closed window anything.
    private func publishDebugOrder() {
        guard let selector = queueOrderSelector else {
            AutoMixDebugModel.shared.setOrder(AutoMixDebugOrder(mode: queueOrder.rawValue))
            return
        }
        let remaining = autoMixRemaining()
        let pool = selector.pool(remaining: remaining)
        // While the pick is pending, re-score for display. This does not age
        // anything — `noteRound` is the only thing that moves a counter — so
        // previewing is free of consequence, and after the commit the table is
        // the real one, frozen.
        if autoMixPickPending, currentAnalysis != nil,
           Date().timeIntervalSince(lastDebugOrderPreview) >= Self.debugOrderPreviewInterval {
            lastDebugOrderPreview = Date()
            // A preview pass is one full rank of the pool — the same work the
            // real pick does, and measured under the same tripwire. It stays on
            // the main actor because that is where `lastPick` lives and because
            // one rank measures 0.9 ms in release (13.8 ms in debug) at a
            // 156-track pool; the throttle above is what keeps it there.
            let start = ContinuousClock.now
            _ = selector.pick(
                outgoing: currentTrack, outgoingAnalysis: currentAnalysis, pool: pool,
                plannerConfig: plannerConfig,
                outgoingLyricLineEnds: outgoingLyricTiming(for: currentLocalURL)?.lineEnds ?? [])
            Self.noteIfSlow("debug-preview", (ContinuousClock.now - start).milliseconds,
                            detail: "pool=\(pool.count)")
        }
        let candidates = selector.lastPick.enumerated().map { index, candidate in
            AutoMixDebugCandidate(
                id: candidate.track.id, title: candidate.track.name,
                tier: candidate.score.tier.label,
                tempo: candidate.score.tempoAffinity, key: candidate.score.keyAffinity,
                style: candidate.score.styleAffinity, energy: candidate.score.energyContinuity,
                aging: candidate.score.aging, samePenalty: candidate.score.sameArtistPenalty,
                future: candidate.score.futureRichness,
                total: candidate.score.total, chosen: index == 0)
        }
        let state: String
        if isTrial {
            state = "stood down — trial fragment (never cached, no analysis possible)"
        } else if !playNextList.isEmpty {
            state = "stood down — a manual “play next” is sovereign"
        } else if autoMixPickCommitted {
            state = "decided"
        } else if currentAnalysis == nil {
            state = "waiting for the playing track's own analysis"
        } else {
            state = "choosing"
        }
        AutoMixDebugModel.shared.setOrder(AutoMixDebugOrder(
            mode: queueOrder.rawValue, state: state,
            poolSize: remaining.count,
            analyzed: pool.count,
            rounds: selector.rounds, downloads: selector.downloadsThisPick,
            downloadBudget: selector.config.maxDownloadsPerPick,
            lookahead: selector.lookahead.map {
                "\($0.track.name) — \($0.score.tier.label)"
            },
            deadline: duration > 0 ? autoMixDeadline : nil,
            candidates: candidates))
    }

    private func publishDebugPlan(_ planned: PlannedTransition, next: PrefetchedNext) {
        AutoMixDebugModel.shared.setPlan(AutoMixDebugPlan(
            planned: planned, outgoing: currentAnalysis, incoming: next.analysis))
        // The sidecar may have landed since the prefetch reported; a re-plan is
        // the natural moment to re-read it, and it is one `stat`.
        AutoMixDebugModel.shared.setNextAnalysis(next.analysis, localURL: next.localURL)
        // A replay is waiting for exactly this: the seam it asked for, planned
        // with both analyses in hand.
        serviceSeamReplayIfPending()
    }

    /// The seam just became audible: freeze what was armed next to what the
    /// engine says it actually ran, so a listener who heard something odd can
    /// look afterwards instead of guessing.
    private func recordDebugSeam(_ outcome: TransitionOutcome) {
        let planned = armedPlan.map {
            AutoMixDebugPlan(planned: $0, outgoing: currentAnalysis,
                             incoming: prefetchedNext?.analysis)
        }
        AutoMixDebugModel.shared.recordSeam(AutoMixDebugSeam(
            from: currentTrack?.name,
            to: pendingTransitionTrack?.name,
            // Kept so the pair can be queued up and heard again; both are
            // cached files by now, so a replay is a queue rebuild and a seek.
            outgoingTrack: currentTrack,
            incomingTrack: pendingTransitionTrack,
            gesture: armedPlan?.style.stemTechnique?.label,
            overrides: AutoMixDebugModel.shared.overrides.badges,
            configFingerprint: AutoMixFeedbackLog.configFingerprint(plannerConfig),
            planned: planned,
            path: outcome.path.rawValue,
            executedKind: AutoMixDebugFormat.planKind(outcome.plan),
            executedOutPoint: outcome.plan.outPoint,
            executedOverlap: AutoMixDebugFormat.overlap(outcome.plan),
            fallback: AutoMixDebugFormat.fallback(planned: planned, executed: outcome.plan),
            prerender: AutoMixDebugModel.shared.currentPrerenderLabel))
    }

    // MARK: - Debug panel: jump, replay, mark

    /// Why the panel's jump button is unavailable, or nil when it is not.
    var seamJumpBlocker: String? {
        guard transitionArmed, let planned = armedPlan else { return "nothing armed" }
        guard let outPoint = planned.plan.outPoint else {
            return "gapless — the seam is the end of the track"
        }
        guard outPoint > progress else { return "the out point is already behind us" }
        return nil
    }

    /// The lead this seam needs, and why — the same computation the button
    /// performs, exposed so the panel can show it before anyone presses.
    func seamJumpPlan() -> AutoMixSeamJump.Result? {
        guard seamJumpBlocker == nil, let planned = armedPlan,
              let outPoint = planned.plan.outPoint else { return nil }
        var inputs = AutoMixSeamJump.Inputs(outPoint: outPoint)
        if case .beatMatched(let p) = planned.plan {
            inputs.isBeatMatched = true
            inputs.rampLeadSeconds = p.rampLeadSeconds
        }
        // The pad the *outgoing* deck will actually use, straight off the deck
        // that is carrying the track — it is sized from that track's peak, so
        // there is no useful constant to substitute.
        inputs.padDB = engine.deckGains(of: activeDeck).padCeilingDB
        inputs.segmentArmed = engine.hasArmedSegment
        // This seam's window, not the flat floor: the jump button exists to land
        // where every stage still has room, and for a wide overlap the room the
        // pre-render needs is now the thing that sets the window
        // (`stemPrerenderLeadWindow`). Landing 60 s out from a seam whose render
        // wants 75 s is landing inside the runway, which is the one outcome the
        // button is meant to prevent.
        inputs.prerenderLead = Self.stemPrerenderLeadWindow(
            runway: TransitionSegment.Signature(plan: planned.plan).map {
                Self.stemPrerenderRunway(overlapDuration: $0.overlapDuration,
                                         sides: Self.stemPrerenderSidesPerSeam)
            } ?? 0)
        inputs.prerenderHandoff = TransitionSegmentRenderer.handoff
        return AutoMixSeamJump.compute(inputs)
    }

    /// Seek to the latest position that still leaves every stage of the
    /// pipeline room to do its work. Goes through the ordinary `seek`, which
    /// re-validates the armed hand-over against the new playhead — a jump must
    /// not be a second, private path into the transition machinery.
    func jumpToArmedSeam() {
        guard let jump = seamJumpPlan() else { return }
        seek(to: jump.target)
    }

    /// Set while a replay is waiting for its rebuilt queue to arm a hand-over.
    /// One-shot: cleared by the jump it triggers, and by any track change.
    private var pendingSeamReplay = false

    /// Why the panel cannot replay this seam, or nil when it can.
    func seamReplayBlocker(_ seam: AutoMixDebugSeam) -> String? {
        guard seam.outgoingTrack != nil, seam.incomingTrack != nil else {
            return "this seam was recorded without its tracks"
        }
        return nil
    }

    /// Queue the recorded pair again and jump to just before the seam, so the
    /// same hand-over runs a second time.
    ///
    /// The plan is **re-derived, not replayed**: both analyses are cached, so
    /// the planner should reach the same decision, and the panel badges the
    /// difference if it does not. Replaying a frozen plan would hide exactly
    /// the thing an A/B is trying to see — that a toggle changed the decision.
    ///
    /// The queue is rebuilt as an ad-hoc two-track list, which replaces
    /// whatever was playing (personal FM included). That is the honest cost of
    /// the feature and the panel says so.
    func replaySeam(_ seam: AutoMixDebugSeam) {
        guard seamReplayBlocker(seam) == nil,
              let outgoing = seam.outgoingTrack, let incoming = seam.incomingTrack
        else { return }
        AutoMixDebugModel.shared.setReplayDiff(nil)
        replayTarget = seam
        play(tracks: [outgoing, incoming], source: .none, startAt: outgoing)
        // Set after `play`, which runs `startPlaying` and clears it.
        pendingSeamReplay = true
    }

    /// The seam a pending replay is trying to reproduce, for the diff badge.
    private var replayTarget: AutoMixDebugSeam?

    /// Called from `publishDebugPlan`: a replay waits for the *upgraded* plan,
    /// not the first degraded one, because the outgoing analysis lands a beat
    /// after playback starts and the seam is only real once it has.
    private func serviceSeamReplayIfPending() {
        guard pendingSeamReplay, currentAnalysis != nil, seamJumpBlocker == nil
        else { return }
        pendingSeamReplay = false
        if let target = replayTarget?.planned, let planned = armedPlan {
            AutoMixDebugModel.shared.setReplayDiff(
                AutoMixDebugFormat.fallback(planned: target, executed: planned.plan))
        }
        replayTarget = nil
        // Off this turn of the loop: we are inside `armTransitionIfReady`, and
        // `seek` disarms and re-arms — doing that to the frame we are standing
        // in would work, but only by accident.
        Task { @MainActor [weak self] in
            guard let self, let jump = self.seamJumpPlan() else { return }
            self.seek(to: jump.target)
        }
    }

    /// Append a listening verdict to the feedback corpus. `seam` nil marks the
    /// hand-over that is armed right now, which has no executed side yet.
    @discardableResult
    func markSeam(verdict: AutoMixFeedbackEntry.Verdict, note: String?,
                  seam: AutoMixDebugSeam?) -> Bool {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let armed = armedPlan.map {
            AutoMixDebugPlan(planned: $0, outgoing: currentAnalysis,
                             incoming: prefetchedNext?.analysis)
        }
        let entry = AutoMixFeedbackEntry(
            at: seam?.at ?? Date(),
            verdict: verdict,
            note: (trimmed?.isEmpty ?? true) ? nil : trimmed,
            outgoing: (seam?.outgoingTrack ?? currentTrack)
                .map { .init(id: $0.id, title: $0.name) },
            incoming: (seam?.incomingTrack ?? pendingTransitionTrack)
                .map { .init(id: $0.id, title: $0.name) },
            planned: (seam?.planned ?? armed).map(AutoMixFeedbackEntry.PlanRef.init),
            executed: seam.map {
                .init(kind: $0.executedKind, outPoint: $0.executedOutPoint,
                      overlap: $0.executedOverlap)
            },
            gesture: seam?.gesture ?? armedPlan?.style.stemTechnique?.label,
            intent: seam?.planned?.intentClass ?? armed?.intentClass,
            path: seam?.path,
            overrides: seam?.overrides ?? AutoMixDebugModel.shared.overrides.badges,
            config: seam.map { $0.configFingerprint.isEmpty
                ? AutoMixFeedbackLog.configFingerprint(plannerConfig)
                : $0.configFingerprint }
                ?? AutoMixFeedbackLog.configFingerprint(plannerConfig))
        guard AutoMixFeedbackLog.append(entry) else { return false }
        AutoMixDebugModel.shared.countMark()
        return true
    }

    // MARK: - Offline playback

    /// Downloads belong to one account; see `activateAccount`.
    private var offlineAccountScope: String? { AccountStore.shared.offlineScope }
    private var usesOfflineQueue: Bool { networkState.isKnown && !networkState.connected }

    private func nextCandidates() -> [PlaybackQueueCandidate] {
        PlaybackQueuePlan.next(queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                               fm: fmUpcoming, isFM: isFMMode, repeatAll: repeatMode == .all && source.qishuiFeed == nil)
    }

    /// A downloaded copy of the track. Online it must match the chosen quality
    /// or better; offline, any quality will do.
    private func acquireOfflineLease(for track: Track, generation: Int, reusing lease: OfflinePlaybackLease? = nil,
                                     anyQuality: Bool = false, preferredQuality: String? = nil) async -> OfflinePlaybackLease? {
        let scope = offlineAccountScope
        var lease = lease
        if preferredQuality != nil, let previous = lease {
            try? await OfflineStore.shared.release(previous)
            lease = nil
        }
        guard generation == resolveGeneration, scope == offlineAccountScope else {
            if let lease { try? await OfflineStore.shared.release(lease) }
            return nil
        }
        if lease == nil, let scope {
            lease = try? await OfflineStore.shared.acquire(accountScope: scope, trackID: track.id,
                preferredQuality: preferredQuality ?? SettingsManager.shared.audioQuality.rawValue,
                allowLowerQuality: anyQuality || usesOfflineQueue || (preferredQuality == nil && !networkState.connected))
        }
        guard let lease else { return nil }
        guard generation == resolveGeneration, scope == offlineAccountScope,
              lease.descriptor.identity.accountScope == scope else {
            try? await OfflineStore.shared.release(lease)
            return nil
        }
        return lease
    }

    /// Plays a file already on this device: a download (with its lease) or,
    /// offline, a cache entry found without a key. Neither gets an analysis
    /// or a loudness trim, so hand-overs from it fall back to gapless.
    private func playLocalFile(_ url: URL, lease: OfflinePlaybackLease?, for track: Track, generation: Int,
                               from position: TimeInterval = 0, resolved: ResolvedSource? = nil) {
        consecutiveFailures = 0
        servedQishuiQualityOption = nil
        servedQuality = AudioQualityCheck.localLevel(url: url, reported: resolved?.level ?? lease?.descriptor.identity.quality)
        currentCacheKey = nil
        currentRemoteURL = nil
        engine.stop(deck: activeDeck)
        deckFiles[activeDeck] = nil
        guard let fileDuration = try? engine.loadFile(at: url, on: activeDeck, trimDB: 0) else {
            if let lease { Task { try? await OfflineStore.shared.release(lease) } }
            deckLoaded = false
            unavailableOffline(track, generation: generation)
            return
        }
        offlinePlaybackLease = lease
        deckLoaded = true
        hasLocalFile = true
        deckFiles[activeDeck] = url
        // Only a cache file is `currentLocalURL`: the stem pre-render and the
        // lyric sidecar write next to it, and downloads are not cache entries.
        currentLocalURL = lease == nil ? url : nil
        isBuffering = false
        duration = fileDuration
        if track.platformSong?.source == .qishui {
            servedQishuiQualityOption = .qishuiLocal(url: url, level: servedQuality, duration: fileDuration)
                ?? resolved?.qishuiQualityOption
        }
        if isPlaying {
            engine.play(deck: activeDeck, from: min(position, max(0, fileDuration - 1)))
            AudioSpectrum.shared.markTapped()
            scrobbleStartIfNeeded(track)
        } else {
            enginePaused = false
        }
        NowPlayingManager.shared.updateMetadata(for: track, duration: fileDuration)
        schedulePrefetch()
    }

    private func stopForOffline() {
        disarmTransition()
        engine.stop(deck: activeDeck)
        deckFiles[activeDeck] = nil
        deckLoaded = false
        hasLocalFile = false
        currentLocalURL = nil
    }

    private func releaseOfflineLease() {
        guard let lease = offlinePlaybackLease else { return }
        offlinePlaybackLease = nil
        Task { try? await OfflineStore.shared.release(lease) }
    }

    private func unavailableOffline(_ track: Track, generation: Int) {
        guard generation == resolveGeneration else { return }
        if currentWasAdvanced {
            advanceOffline(initialSkipped: 1, excludingFailedCurrent: true)
            return
        }
        stopForOffline()
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
        stopForOffline()
        releaseOfflineLease()
        isPlaying = false
        offlineScan = Task { [weak self] in
            guard let self, !Task.isCancelled, self.offlineScanID == requestID else { return }
            let selected = try? await OfflineQueueSelector.firstAvailable(candidates, scope: scope,
                quality: SettingsManager.shared.audioQuality.rawValue, store: .shared,
                isCached: { await EngineAudioCache.shared.cachedFileURL(trackID: $0) != nil })
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
        guard offlinePlaybackLease != nil else { return }
        resolveGeneration += 1
        stopForOffline()
        releaseOfflineLease()
        isPlaying = false
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    // MARK: - Scrobble

    private func samplePlaybackReporting() {
        guard !isScrubbing else { return }
        samplePlaybackReporting(position: engine.position(of: activeDeck),
            advancing: isPlaying && !isBuffering && deckLoaded)
    }


    private func samplePlaybackReporting(position: TimeInterval, advancing: Bool) {
        kugouReporter.sample(position: position, advancing: advancing)
        qishuiHistoryReporter.sample(position: position, advancing: advancing)
    }

    /// Tell the server the track started, once per track. Called from the
    /// point playback actually begins — the cache-hit path and the streaming
    /// path both reach it, and `startPlaying` clears the flag.
    private func scrobbleStartIfNeeded(_ track: Track) {
        if !isTrial { qishuiHistoryReporter.begin(track) }
        kugouReporter.begin(track: track, position: engine.position(of: activeDeck))
        guard historySession == nil else { return }
        let sourceID = source.sourceID > 0 ? source.sourceID : track.album.id
        historySession = historyReporter.start(trackID: track.id, sourceID: sourceID,
            duration: track.duration, quality: servedQuality, fee: track.fee)
    }

    private func scrobbleIfNeeded(completed: Bool) {
        qishuiHistoryReporter.finish()
        if source.qishuiFeed != nil { qishuiContinuation.record(currentTrack, position: progress) }
        kugouReporter.finish(position: engine.position(of: activeDeck), completed: completed)
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

    /// The AutoMix order's equivalent: the same "current track first, the rest
    /// behind it" contract shuffle has, except the rest keeps list order —
    /// nothing is decided yet, and predev §2.1 forbids pretending otherwise.
    private func reorderForAutoMix(keeping first: Track) {
        autoMixQueue = [first] + queue.filter { $0.id != first.id }
    }

    // MARK: - AutoMix queue order (predev §2.2 / §2.4)

    /// Nil whenever the mode is off — which is the whole of predev §5.3's
    /// regression contract. A player in `.listed` or `.shuffled` allocates no
    /// selector, scores nothing and issues no candidate request.
    private var queueOrderSelector: QueueOrderSelector?
    /// The pick for the track now playing has been made (or deliberately
    /// declined). Cleared by `startPlaying`, so every track gets exactly one
    /// decision round.
    private var autoMixPickCommitted = false

    /// How long before the end of the track the pick is made even if
    /// candidates are still downloading.
    ///
    /// The winner does not go straight to the engine: it still has to be
    /// re-resolved, downloaded at *playback* quality and re-analyzed by the
    /// ordinary prefetch path (a lossy file's beat grid may not be aligned to
    /// the real one — predev §2.2), and a stem hand-over then wants
    /// `stemPrerenderLead` = 60 s on top.
    ///
    /// 90 s was sized as 30 for the first half and 60 for the second. The first
    /// half measured 40 s and more in the field — a lossless transfer on a
    /// domestic line plus an analyzer pass — so the pre-render was routinely
    /// handed under 50 s and the stem gesture dropped to a whole-mix crossfade
    /// without anyone being told. 120 s is the same arithmetic with the
    /// measured number in it. The fraction floor keeps a short track from
    /// deciding before it has played at all.
    ///
    /// This is the *worst* case, not the common one: only a deadline-committed
    /// pick waits this long. A pick that satisfies, exhausts the queue or spends
    /// its download budget commits as soon as it does, which on a warm pool is
    /// within seconds of the track starting.
    nonisolated private static let autoMixDecisionLead: TimeInterval = 120

    /// The fraction floor, so a short track does not decide before it has
    /// played at all.
    nonisolated static let autoMixDecisionFloor: Double = 0.35

    nonisolated static func autoMixDeadline(
        duration: TimeInterval,
        lead: TimeInterval = autoMixDecisionLead,
        floor: Double = autoMixDecisionFloor
    ) -> TimeInterval {
        max(duration - lead, duration * floor)
    }

    private var autoMixDeadline: TimeInterval {
        Self.autoMixDeadline(duration: duration)
    }

    /// What one pick tick is entitled to do, decided from facts alone.
    ///
    /// Pulled out of `updateAutoMixPick` because the interesting part of this
    /// mode's worst failure is not arithmetic but *precedence*: which fact is
    /// allowed to override which. A deadline that fires against a playhead
    /// belonging to the previous song commits an empty pool and then refuses to
    /// reconsider for the rest of the track, and no amount of scoring downstream
    /// can recover from it. That ordering is worth asserting on directly, and it
    /// cannot be asserted on inside a `@MainActor` method that reads six
    /// published properties.
    enum AutoMixPickStep: Equatable {
        /// One track or fewer to choose between: there is no decision to make,
        /// and the list already says the right thing.
        case declineTrivialQueue
        /// `progress` does not describe the track this pick is for — the deck
        /// is still carrying the previous one, or carries nothing yet. Top the
        /// pool up for free and read the clock again next tick; **never**
        /// commit, because the deadline this playhead reports is another song's.
        case waitForPlayhead
        /// The outgoing analysis has not landed, so nothing can be scored yet
        /// (every candidate would come back `.gapless` and the escalation would
        /// have nothing to steer by). Free acquisition only.
        case acquireFree
        /// Rank the pool. `atDeadline` is whether the answer is final.
        case rank(atDeadline: Bool)
    }

    /// - Parameter playheadIsCurrent: the active deck is carrying the track the
    ///   pick is being made for, so `progress` is this track's position and not
    ///   an inheritance from the one before it.
    nonisolated static func autoMixPickStep(
        remainingCount: Int,
        progress: TimeInterval, duration: TimeInterval,
        playheadIsCurrent: Bool, hasOutgoingAnalysis: Bool
    ) -> AutoMixPickStep {
        guard remainingCount > 1 else { return .declineTrivialQueue }
        guard playheadIsCurrent else { return .waitForPlayhead }
        let atDeadline = duration > 0 && progress >= autoMixDeadline(duration: duration)
        guard hasOutgoingAnalysis || atDeadline else { return .acquireFree }
        return .rank(atDeadline: atDeadline)
    }

    /// Why a commit came back without a winner — the missing half of the
    /// journal line that made the field report unreadable.
    ///
    /// `winner=none` has five distinguishable causes and the log printed the
    /// same nine characters for all of them. The one that actually bit —
    /// `analysesOffQueue` — is the reason `order round … analyzed=19` and
    /// `order commit … analyzed=0` were never in contradiction: the round line
    /// counts the selector's whole analysis dictionary, which is cumulative
    /// across every queue the session has seen, and the pool counts only the
    /// analyses belonging to tracks still *ahead of the playhead*. Nineteen of
    /// the former and none of the latter is an ordinary state of affairs, and
    /// now it says so.
    ///
    /// Nil when there is a winner: the line is already complete then.
    nonisolated static func autoMixCommitCause(
        hasWinner: Bool, poolCount: Int, analyzedCount: Int,
        downloads: Int, hasOutgoingAnalysis: Bool
    ) -> String? {
        guard !hasWinner else { return nil }
        // Candidates were scorable and the scorer still produced nothing. This
        // should not be reachable; if it ever is, the journal says so out loud
        // rather than blaming the pool.
        if poolCount > 0 { return "unranked" }
        // The whole point of the distinction: analyses in hand, none of them in
        // the queue ahead of us.
        if analyzedCount > 0 { return "analysesOffQueue" }
        // Nothing analyzed at all. Which of the two starvations was it?
        if !hasOutgoingAnalysis { return "noOutgoingAnalysis" }
        if downloads == 0 { return "unfunded" }
        return "nothingAnalyzed"
    }

    /// The mode is on and owes an answer — so the prefetch pipeline must wait
    /// rather than commit to whatever the list happens to say next.
    private var autoMixPickPending: Bool {
        queueOrderSelector != nil && queueOrder == .autoMix
            && !autoMixPickCommitted && !isFMMode && playNextList.isEmpty
            // A trial fragment is never cached, so it never gets an analysis
            // and never reaches its metadata-length deadline (the fragment
            // ends first) — a pick would pend forever while the escalation
            // opens a pointless round per fragment. The mode stands down
            // exactly like FM: nothing to plan with, nothing to hold up.
            && !isTrial
    }

    private func syncQueueOrderSelector() {
        guard queueOrder == .autoMix, autoMixOrderAvailable else {
            queueOrderSelector = nil
            return
        }
        guard queueOrderSelector == nil else {
            queueOrderSelector?.reset()
            return
        }
        let selector = QueueOrderSelector()
        selector.onCandidateReady = { [weak self] in
            self?.updateAutoMixPick()
            // The pool just grew, so the provisional chain past the decided
            // next may well be different now. Redoing it is microseconds.
            self?.refreshAutoMixLookahead()
        }
        queueOrderSelector = selector
    }

    /// Everything still ahead of the playhead in the working list.
    private func autoMixRemaining() -> [Track] {
        guard currentIndex >= 0, currentIndex + 1 < activeQueue.count else { return [] }
        return Array(activeQueue[(currentIndex + 1)...])
    }

    /// Polled from the progress tick while the mode owes a decision: top the
    /// candidate pool up, and pick as soon as there is nothing left to wait
    /// for — or when the deadline arrives, whichever comes first.
    ///
    /// Costs one optional test per tick with the mode off.
    private func updateAutoMixPick() {
        guard autoMixPickPending, let selector = queueOrderSelector else { return }
        let remaining = autoMixRemaining()
        let atDeadline: Bool
        switch Self.autoMixPickStep(
            remainingCount: remaining.count, progress: progress, duration: duration,
            playheadIsCurrent: deckLoaded, hasOutgoingAnalysis: currentAnalysis != nil
        ) {
        case .declineTrivialQueue:
            // Nothing to choose between: let the ordinary pipeline have the
            // track the list already points at.
            return commitAutoMixPick(nil, pool: [], reason: "trivial-queue",
                                     because: "trivialQueue")
        case .waitForPlayhead:
            noteAutoMixStaleDeadlineIfDue()
            selector.acquire(remaining: remaining, mayDownload: false)
            return
        case .acquireFree:
            selector.acquire(remaining: remaining, mayDownload: false)
            return
        case .rank(let deadline):
            atDeadline = deadline
        }

        let pool = selector.pool(remaining: remaining)
        // The real decision stays on the main actor: one rank measures 0.9 ms
        // in release and 13.8 ms in debug at a 156-track pool, it happens once
        // per landing candidate rather than nine times, and the pick is the one
        // thing here that is not provisional. The tripwire says so if that
        // stops being true.
        let pickStart = ContinuousClock.now
        let winner = selector.pick(
            outgoing: currentTrack, outgoingAnalysis: currentAnalysis, pool: pool,
            plannerConfig: plannerConfig,
            outgoingLyricLineEnds: outgoingLyricTiming(for: currentLocalURL)?.lineEnds ?? [])
        Self.noteIfSlow("pick", (ContinuousClock.now - pickStart).milliseconds,
                        detail: "pool=\(pool.count)")
        // Good enough is good enough: the tier is the dominant term, so a
        // further round can only buy a *higher* tier or a second-order
        // reshuffle inside this one — not worth another download and another
        // minute of waiting.
        if atDeadline || selector.lastPickSatisfies {
            return commitAutoMixPick(winner, pool: pool,
                                     reason: atDeadline ? "deadline" : "satisfied",
                                     because: autoMixCommitCause(winner, pool: pool))
        }
        // Nothing satisfies yet: open the next round, unless the queue is spent
        // or this pick has spent its budget — in either case the best analyzed
        // candidate is the answer, and a nil one honestly leaves the list order
        // alone. The budget stop differs only in what it means: the queue still
        // has material, and the next pick escalates into it from the pool this
        // one just enriched.
        switch selector.acquire(remaining: remaining, mayDownload: autoMixMayDownload) {
        case .exhausted:
            commitAutoMixPick(winner, pool: pool, reason: "exhausted",
                              because: autoMixCommitCause(winner, pool: pool))
        case .spent:
            commitAutoMixPick(winner, pool: pool, reason: "budget",
                              because: autoMixCommitCause(winner, pool: pool))
        case .acquiring, .deferred: break
        }
    }

    /// The commit line's `because=`, bound to the selector's live counters.
    private func autoMixCommitCause(_ winner: Track?, pool: [Track]) -> String? {
        Self.autoMixCommitCause(
            hasWinner: winner != nil, poolCount: pool.count,
            analyzedCount: queueOrderSelector?.analyzedCount ?? 0,
            downloads: queueOrderSelector?.downloadsThisPick ?? 0,
            hasOutgoingAnalysis: currentAnalysis != nil)
    }

    /// One line per pick, the first time a deadline is refused for belonging to
    /// the previous head.
    ///
    /// The bug this guards against was invisible: the commit it produced looked
    /// exactly like an honest deadline commit that happened to find nothing, and
    /// the only tell was `rounds=0` on a track that had been playing for
    /// minutes. Now the refusal is the thing that gets written down, and the
    /// commit that used to follow it does not happen at all.
    private var autoMixStaleDeadlineNoted = false

    private func noteAutoMixStaleDeadlineIfDue() {
        guard !autoMixStaleDeadlineNoted, duration > 0, progress >= autoMixDeadline
        else { return }
        autoMixStaleDeadlineNoted = true
        PlaybackJournal.note(
            "order deadline ignored because=staleHead "
            + String(format: "progress=%.3f duration=%.3f", progress, duration))
    }

    /// Whether the escalation may open a transfer right now.
    ///
    /// The politeness rule (predev §2.2's budget of one): candidate downloads
    /// are background work and never compete with audio that is about to play,
    /// or is playing. `prefetchTask` is the playback-quality fetch of the
    /// *chosen* next track — while the pick is pending `schedulePrefetch` has
    /// already stood it down, so this is nil then by construction — and
    /// `currentLocalURL` is nil exactly while the current track is still
    /// streaming into the cache (not `hasLocalFile`, which describes the
    /// deck's *source* and stays false for a streamed track even after its
    /// download completes — that read kept the escalation deferred for the
    /// whole first song of a fresh playlist). Both resume the escalation on
    /// their own: the progress tick calls back in every second.
    private var autoMixMayDownload: Bool {
        prefetchTask == nil && currentLocalURL != nil
    }

    /// Freeze the decision for this track and hand the pipeline the result.
    ///
    /// **This is the one change to the advance path.** Rather than teach
    /// `advanceToNext` a second way to find "next", the winner is spliced to
    /// `currentIndex + 1` — so `currentIndex + 1` is still the answer, and
    /// every index-based path downstream is untouched. A nil winner (nothing
    /// analyzed by the deadline) leaves the list exactly as it was: the mode
    /// never holds up a hand-over waiting for a download.
    ///
    /// **`pool=` and `analyzed=` are two different numbers and the line now
    /// says which is which.** This used to print `analyzed=\(pool.count)` while
    /// `order round …` printed `analyzed=<the whole analysis dictionary>`, so a
    /// journal reading `round 1 … analyzed=19` followed by `commit … analyzed=0`
    /// looked like the pool had been thrown away between them. It had not: the
    /// dictionary is cumulative across every queue the session has seen, the
    /// pool is its intersection with the tracks still ahead of the playhead, and
    /// the two agree only by coincidence. `pool=` is what the pick could choose
    /// from; `analyzed=` is the same quantity the round line reports.
    private func commitAutoMixPick(_ winner: Track?, pool: [Track],
                                   reason: String, because: String? = nil) {
        autoMixPickCommitted = true
        let tier = queueOrderSelector?.lastPick.first?.score.tier.label ?? "-"
        PlaybackJournal.note(
            "order commit reason=\(reason) winner=\(winner?.id.description ?? "none") "
            + "tier=\(tier) pool=\(pool.count) "
            + "analyzed=\(queueOrderSelector?.analyzedCount ?? 0) "
            + "rounds=\(queueOrderSelector?.rounds ?? 0) "
            + "downloads=\(queueOrderSelector?.downloadsThisPick ?? 0)"
            + (because.map { " because=\($0)" } ?? ""))
        if let winner {
            queueOrderSelector?.noteRound(chosen: winner, pool: pool)
            spliceAutoMixPlan([winner])
        }
        // The chain's head just changed: this is the one moment it is worth
        // being right, so it jumps the throttle.
        refreshAutoMixLookahead(force: true)
        schedulePrefetch()
    }

    /// Move `tracks` to sit at `currentIndex + 1, + 2, …` in the working list,
    /// in the order given, leaving everything else in the order the user gave
    /// us.
    ///
    /// One track is the decided next — firm. The rest is the provisional chain,
    /// and it is shown rather than promised: the pick at each of those seams is
    /// still made fresh at its own decision point, and a chain step that turns
    /// out wrong is simply re-spliced then. Materializing it into the list
    /// (rather than teaching `upcomingTracks` a second source of truth) is the
    /// same trick the decided next already uses, so `currentIndex` stays the
    /// only cursor there is.
    ///
    /// **One assignment, or none.** `autoMixQueue` is `@Published` and the
    /// queue view is a list of a few hundred rows, so every mutation costs a
    /// full SwiftUI diff of the whole list. The first version of this moved the
    /// tracks one at a time — nine publishes and nine diffs per refresh, on
    /// every candidate that landed. The reordered array is now built whole and
    /// assigned once, and not assigned at all when the order is already what it
    /// should be, which is the common case after the first refresh.
    private func spliceAutoMixPlan(_ tracks: [Track]) {
        guard let reordered = Self.queueSplicingPlan(
            autoMixQueue, at: currentIndex + 1, plan: tracks) else { return }
        autoMixQueue = reordered
    }

    /// The reordered queue, or **nil when it would change nothing** — which is
    /// the common case once the chain has settled, and the signal the caller
    /// uses to skip the publish entirely.
    ///
    /// Pure, so the property that matters (this is a permutation of the input
    /// that moves the plan to the front of the tail and disturbs nothing else)
    /// is assertable without a player.
    nonisolated static func queueSplicingPlan(
        _ queue: [Track], at target: Int, plan: [Track]
    ) -> [Track]? {
        guard target >= 0, target <= queue.count else { return nil }
        let ahead = queue[target...]
        let aheadIDs = Set(ahead.map(\.id))
        var planned: [Track] = []
        var placed: Set<Int> = []
        // Only tracks that are actually still ahead of the playhead, each once.
        for track in plan where aheadIDs.contains(track.id) && !placed.contains(track.id) {
            placed.insert(track.id)
            planned.append(track)
        }
        guard !planned.isEmpty else { return nil }
        let reordered = Array(queue[..<target]) + planned
            + ahead.filter { !placed.contains($0.id) }
        // Compare identities, not whole tracks: a `Track` carries nested arrays
        // and this runs on every refresh.
        guard reordered.map(\.id) != queue.map(\.id) else { return nil }
        return reordered
    }

    /// How often the provisional chain may be recomputed off the back of a
    /// landing analysis.
    ///
    /// A commit always recomputes — that is the moment the chain's head
    /// changes and the moment it is worth being right. In between, candidates
    /// land every few seconds during an escalation, and a pool one track richer
    /// does not meaningfully change an eight-step preview. So the pool-growth
    /// trigger is throttled and the work is skipped rather than queued.
    static let lookaheadRefreshInterval: TimeInterval = 5

    /// The throttle rule, in one place: a commit always goes, a landing
    /// analysis waits its turn, and only one computation is ever in flight.
    nonisolated static func lookaheadRefreshAllowed(
        force: Bool, computing: Bool, sinceLast: TimeInterval
    ) -> Bool {
        force || (!computing && sinceLast >= lookaheadRefreshInterval)
    }

    private var lastLookaheadRefresh: Date = .distantPast
    /// A chain computation is in flight; a second one would only race it.
    private var lookaheadComputing = false
    /// Bumped whenever the chain's premise changes, so an answer computed
    /// against a queue that has since moved on is dropped rather than shown.
    private var lookaheadGeneration = 0

    /// Redo the provisional chain and lay it into the working list.
    ///
    /// Called on every commit, whenever a candidate analysis lands (the pool
    /// grew) and when the queue is edited.
    ///
    /// The computation itself runs **off the main actor**. Measured at a
    /// 156-track pool it is 5.6 ms in release and 110 ms in debug, and it grows
    /// linearly with the pool — which grew from the 4-track window this feature
    /// shipped with to 200+ as the cache warmed. Main-actor work of that size,
    /// arriving every time a download lands, is a stutter; it is what made the
    /// app appear to hang after a queue action.
    private func refreshAutoMixLookahead(force: Bool = false) {
        guard let selector = queueOrderSelector, queueOrder == .autoMix else { return }
        // The chain hangs off the decided next. While the pick is still
        // pending there is nothing to hang it off, and showing a chain from a
        // head that is about to change would be worse than showing none.
        guard !autoMixPickPending, currentIndex >= 0,
              currentIndex + 1 < autoMixQueue.count else {
            lookaheadGeneration += 1
            return selector.clearLookahead()
        }
        guard selector.config.lookaheadDepth > 0 else { return selector.clearLookahead() }
        let now = Date()
        // A commit forces; a landing analysis waits its turn. Either way only
        // one computation is ever in flight — a forced one supersedes whatever
        // is running by bumping the generation below, and the superseded task
        // drops its answer without touching the flag.
        guard Self.lookaheadRefreshAllowed(
            force: force, computing: lookaheadComputing,
            sinceLast: now.timeIntervalSince(lastLookaheadRefresh)) else { return }

        let head = autoMixQueue[currentIndex + 1]
        let rest = Array(autoMixQueue[(currentIndex + 2)...])
        lastLookaheadRefresh = now
        lookaheadComputing = true
        lookaheadGeneration += 1
        let generation = lookaheadGeneration
        let depth = selector.config.lookaheadDepth
        let input = selector.chainInput(head: head, remaining: rest,
                                        plannerConfig: plannerConfig)
        Task { [weak self] in
            let start = ContinuousClock.now
            let results = await Task.detached(priority: .utility) {
                QueueOrderSelector.chain(input, depth: depth)
            }.value
            let elapsed = (ContinuousClock.now - start).milliseconds
            guard let self else { return }
            // A commit, a queue edit or a track change happened while this was
            // running: its premise is gone, and a provisional chain is never
            // worth showing against the wrong head. The flag stays set — it
            // belongs to whichever computation superseded this one.
            guard generation == self.lookaheadGeneration else { return }
            self.lookaheadComputing = false
            guard self.currentIndex >= 0,
                  self.currentIndex + 1 < self.autoMixQueue.count,
                  self.autoMixQueue[self.currentIndex + 1].id == input.headID else { return }
            let current = Array(self.autoMixQueue[(self.currentIndex + 2)...])
            self.queueOrderSelector?.applyLookahead(results, remaining: current)
            let chain = self.queueOrderSelector?.lookahead.map(\.track) ?? []
            self.spliceAutoMixPlan([head] + chain)
            Self.noteIfSlow("lookahead", elapsed,
                            detail: "pool=\(input.poolIDs.count) depth=\(depth) "
                                + "steps=\(chain.count)")
        }
    }

    /// The permanent tripwire on the queue-order arithmetic.
    ///
    /// Everything this mode computes was designed when the pool was four tracks
    /// and described in the predev as "microseconds". The pool is now whatever
    /// the cache has warmed to, and the cost is linear in it — so the honest
    /// thing is not to assert the cost is small but to say so out loud the
    /// moment it is not. 50 ms is three frames.
    private static let slowWorkThresholdMS: Double = 50

    private static func noteIfSlow(_ what: String, _ ms: Double, detail: String) {
        guard ms >= slowWorkThresholdMS else { return }
        PlaybackJournal.note(String(format: "order SLOW %@ %.0fms %@", what, ms, detail))
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
                               automaticOrder: queueOrder == .autoMix, isFM: isFMMode, progress: progress)
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
        queue = session.queue
        shuffledQueue = session.shuffled ? session.orderedQueue : []
        if session.automaticOrder, autoMixOrderAvailable {
            queueOrder = .autoMix
            autoMixQueue = session.orderedQueue
        } else if session.shuffled {
            queueOrder = .shuffled
        } else {
            queueOrder = .listed
            queue = session.orderedQueue
        }
        syncQueueOrderSelector()
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
        // A received checkpoint is not listening earned on this device.
        scrobbled = true
    }

    func checkpointPlayback() { samplePlaybackReporting(); persistState() }

    func finishPlaybackReporting() async {
        pause()
        kugouReporter.finish(position: engine.position(of: activeDeck), completed: false)
        await kugouReporter.waitForPendingSubmissions(timeout: 3)
    }

    func suspendForAccountChange() {
        qishuiHistoryReporter.finish()
        resolveGeneration += 1
        trackResolution?.task.cancel()
        trackResolution = nil
        scrobbled = true
        pause()
        stopForOffline()
        releaseOfflineLease()
        prefetchTask?.cancel()
    }

    func resetForMusicAccountChange() {
        suspendForAccountChange()
        qishuiContinuation.reset()
        qishuiFeedDrained = false
        queue = []; shuffledQueue = []; autoMixQueue = []; playNextList = []
        currentTrack = nil; currentIndex = -1
        recentContexts = []; source = .none
        progress = 0; duration = 0
        isPlaying = false; isBuffering = false; isFMMode = false
        showNowPlaying = false
        audioQualityBadgeState = nil
        lyricsRequestID = UUID()
        lyrics = nil
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
        queueOrder = PlayerService.restoredQueueOrder(legacy)
        syncQueueOrderSelector()
        switch queueOrder {
        case .listed: break
        case .shuffled: shuffledQueue = queue.shuffled()
        // No pick has been made for a session that has not started playing,
        // so the working list is the plain queue — which is what the mode
        // shows anyway until the first decision lands.
        case .autoMix: autoMixQueue = queue
        }
        if let id = legacy.currentID,
           let idx = activeQueue.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
            currentTrack = activeQueue[idx]
            duration = activeQueue[idx].duration
            NowPlayingManager.shared.updateMetadata(for: activeQueue[idx], duration: duration)
        }
    }

    /// The queue order a persisted session restores to, migrating a state file
    /// written before the mode existed. Static and pure so the migration is
    /// testable without a player.
    nonisolated static func restoredQueueOrder(_ state: PlaybackState.Legacy) -> QueueOrder {
        state.queueOrder.flatMap(QueueOrder.init(rawValue:))
            ?? QueueOrder(migratingShuffle: state.shuffle)
    }

    private static var stateFileURL: URL {
        CodaDirectories.applicationSupport().appendingPathComponent("player-state.json")
    }
}
#endif
