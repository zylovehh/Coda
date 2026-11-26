import SwiftUI
import Combine

enum TrackRowStyle {
    /// Artwork + album column (playlists, search, daily).
    case full
    /// Track number, no artwork (album pages).
    case albumTrack
    /// Compact with artwork, no album column (artist hot songs, panels).
    case compact
    /// Spacious rows in the iPad liked music panel.
    case likedMusic

    var desktopRowHeight: CGFloat { Theme.Layout.trackRowHeight }
}

enum RecommendationContext {
    case daily
    case radar
}

/// Song rows need playback identity and indicator state, never the playback clock.
@MainActor
private final class TrackRowPlaybackState: ObservableObject {
    struct Snapshot: Equatable {
        var trackID: Int?
        var isPlaying: Bool
        var showNowPlaying: Bool
    }

    static let shared = TrackRowPlaybackState()
    @Published private(set) var snapshot: Snapshot
    private var subscription: AnyCancellable?

    private init() {
        let player = PlayerService.shared
        snapshot = Snapshot(trackID: player.currentTrack?.id, isPlaying: player.isPlaying,
                            showNowPlaying: player.showNowPlaying)
        subscription = Publishers.CombineLatest3(
            player.$currentTrack.map { $0?.id }.removeDuplicates(),
            player.$isPlaying.removeDuplicates(),
            player.$showNowPlaying.removeDuplicates()
        )
        .map { Snapshot(trackID: $0.0, isPlaying: $0.1, showNowPlaying: $0.2) }
        .removeDuplicates()
        .sink { [weak self] in self?.snapshot = $0 }
    }
}

// MARK: - Row

struct TrackRow: View {
    /// Shared with the home chart header to keep its disclosure on the rank centerline.
    static let chartRankColumnWidth: CGFloat = 52

    let track: Track
    let index: Int
    var style: TrackRowStyle = .full
    var showsLikeButton = true
    var highlightsTopRanks = false
    var chartRank: Int?
    var chartGrowthRatio: Double?
    var previousChartRank: Int?
    var showsDuration = true
    var showsTrailingActions = true
    var showsAlbumSubtitle = false
    var playability: TrackPlayability = .playable
    /// Extra trailing text (e.g. play count for recents).
    var trailingText: String?
    /// Set when the row lives inside a user's own playlist (enables 删除).
    var removableFromPlaylistID: Int?
    var onRemoved: (() -> Void)?
    var onRecommendationReduced: ((Track) -> Void)?
    var onDeleteFromCloud: ((Track) -> Void)?
    let onPlay: () -> Void

    private let player = PlayerService.shared
    @ObservedObject private var playback = TrackRowPlaybackState.shared
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var compactArtworkSize: CGFloat = Theme.Layout.trackArtworkSize
    @ScaledMetric(relativeTo: .body) private var compactRowHeight: CGFloat = Theme.Layout.trackRowHeight
    @ScaledMetric(relativeTo: .body) private var compactAlbumRowHeight: CGFloat = 50
    // Native cells retain this view graph when rebound to another song. Scope
    // transient state and asynchronous completions to the song they belong to.
    @State private var hoveredTrackID: Int?
    #if os(iOS)
    @State private var addToPlaylistTrack: Track?
    #endif
    @State private var reducingRecommendationIDs: Set<Int> = []
    /// Only this track's download state, so another row's transfer cannot
    /// re-evaluate this body four times a second.
    @ObservedObject private var downloadState: TrackDownloadState

    init(track: Track, index: Int, style: TrackRowStyle = .full, playability: TrackPlayability = .playable,
         highlightsTopRanks: Bool = false, showsDuration: Bool = true, showsTrailingActions: Bool = true, showsLikeButton: Bool = true, showsAlbumSubtitle: Bool = false,
         chartRank: Int? = nil, previousChartRank: Int? = nil, chartGrowthRatio: Double? = nil,
         trailingText: String? = nil, removableFromPlaylistID: Int? = nil, onRemoved: (() -> Void)? = nil,
         onRecommendationReduced: ((Track) -> Void)? = nil, onDeleteFromCloud: ((Track) -> Void)? = nil, onPlay: @escaping () -> Void) {
        self.chartGrowthRatio = chartGrowthRatio
        self.chartRank = chartRank
        self.previousChartRank = previousChartRank
        self.onDeleteFromCloud = onDeleteFromCloud
        self.track = track
        self.index = index
        self.style = style
        self.showsTrailingActions = showsTrailingActions
        self.showsDuration = showsDuration
        self.highlightsTopRanks = highlightsTopRanks
        self.showsLikeButton = showsLikeButton
        self.showsAlbumSubtitle = showsAlbumSubtitle
        self.playability = playability
        self.trailingText = trailingText
        self.removableFromPlaylistID = removableFromPlaylistID
        self.onRemoved = onRemoved
        self.onRecommendationReduced = onRecommendationReduced
        self.onPlay = onPlay
        _downloadState = ObservedObject(wrappedValue: DownloadManager.shared.trackState(for: track.id))
    }

    private var isCurrent: Bool { playback.snapshot.trackID == track.id }
    private var isHovering: Bool { hoveredTrackID == track.id }
    private var isReducingRecommendation: Bool { reducingRecommendationIDs.contains(track.id) }
    private var isOffline: Bool { downloadState.isOffline }
    private var isPlayable: Bool { playability == .playable || isOffline }
    private var needsNetwork: Bool { downloadState.needsNetwork }
    private var showsArtwork: Bool {
        #if os(iOS)
        return true
        #else
        return style != .albumTrack
        #endif
    }

    private var hidesLeadingIndex: Bool {
        if chartRank != nil { return true }
        #if os(iOS)
        return !highlightsTopRanks
        #else
        return !highlightsTopRanks
        #endif
    }

    private var isCompact: Bool { true }

    var body: some View {
        HStack(spacing: Theme.Spacing.control) {
            if !hidesLeadingIndex {
                leadingIndicator
            }

            if showsArtwork {
                artwork
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                songTitle
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsAlbumSubtitle, !track.album.name.isEmpty {
                    Text("\(track.artistNames)\(!isCompact && style == .likedMusic ? " · " : " - ")\(track.album.name)")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    artistLinks
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if style == .full && !isCompact {
                if track.album.id != 0, !track.album.name.isEmpty {
                    Button {
                        openDestination(.album(track.album.id))
                    } label: {
                        Text(track.album.name)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开专辑：\(track.album.name)")
                    .frame(maxWidth: 220, alignment: .leading)
                } else {
                    Text(track.album.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }

            if let reason = playability.reason, !isOffline {
                Text(reason)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            }

            if let trailingText {
                Text(trailingText)
                    .font(Theme.Typography.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if showsTrailingActions {
                likeAndDuration
                    .padding(.leading, Theme.Spacing.control)
            }
        }
        .padding(.horizontal, Theme.Layout.trackRowHorizontalInset)
        .padding(.vertical, Theme.Spacing.small)
        // Keep the row and its virtual scroll extent in agreement (#3).
        .frame(height: rowHeight)
        .opacity(isPlayable && !needsNetwork ? 1 : 0.45)
        .contentShape(Rectangle())
        .scrollAwareHover { hovering in
            // Scrolling moves many rows beneath the pointer. Avoid starting a
            // new implicit animation for every row crossed during a scroll.
            hoveredTrackID = hovering ? track.id : nil
        }
        #if os(macOS)
        .onTapGesture(count: 2) {
            playSelectedTrack()
        }
        #else
        .onTapGesture {
            playSelectedTrack()
        }
        #endif
        .contextMenu { contextMenuItems }
        #if os(iOS)
        .sheet(item: $addToPlaylistTrack) { selectedTrack in
            AddToPlaylistSheet(track: selectedTrack)
        }
        #endif
        .onChange(of: track.id) { _ in
            hoveredTrackID = nil
            #if os(iOS)
            addToPlaylistTrack = nil
            #endif
        }
    }

    private func playSelectedTrack() {
        if needsNetwork { ToastCenter.shared.show(String(localized: "此歌曲需要联网播放")) }
        else if isPlayable { onPlay() }
    }

    @ViewBuilder
    private var artwork: some View {
        #if os(iOS)
        Button(action: onPlay) {
            artworkImage
        }
        .buttonStyle(.plain)
        .disabled(!isPlayable)
        .accessibilityLabel("播放：\(track.name)")
        #else
        if track.album.id != 0, !track.album.name.isEmpty {
            Button {
                openDestination(.album(track.album.id))
            } label: {
                artworkImage
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开专辑：\(track.album.name)")
        } else {
            artworkImage
        }
        #endif
    }

    @ViewBuilder
    private var artworkImage: some View {
        if isCompact {
            CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(160), animated: false)
                .frame(width: compactArtworkSize, height: compactArtworkSize)
                #if os(iOS)
                .compositingGroup()
                #endif
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        } else {
            CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                .frame(width: style == .likedMusic ? 48 : 42, height: style == .likedMusic ? 48 : 42)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
    }

    @ViewBuilder
    private var artistLinks: some View {
        #if os(iOS)
        Text(track.artistNames)
            .font(Theme.Typography.secondary)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        #else
        let artists = track.artists.filter { $0.id != 0 && !$0.name.isEmpty }
        if artists.isEmpty {
            Text(track.artistNames)
                .font(Theme.Typography.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                    if index > 0 {
                        Text(" / ")
                    }
                    Button {
                        openDestination(.artist(artist.id))
                    } label: {
                        Text(artist.name)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开歌手：\(artist.name)")
                }
            }
            .font(Theme.Typography.secondary)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        #endif
    }

    private var rowHeight: CGFloat {
        if isCompact { return compactRowHeight }
        if style == .likedMusic { return 64 }
        if style == .albumTrack {
            return isCompact ? compactAlbumRowHeight : style.desktopRowHeight
        }
        return isCompact ? compactRowHeight : style.desktopRowHeight
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        ZStack {
            if isCurrent && !highlightsTopRanks {
                PlayingIndicator(animating: playback.snapshot.isPlaying && !playback.snapshot.showNowPlaying)
            } else if isHovering, isPlayable, !highlightsTopRanks {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.pressable)
            } else {
                Text(String(index))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(highlightsTopRanks && index <= 3 ? AnyShapeStyle(Color.red) : (style == .likedMusic ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)))
            }
        }
        .frame(width: 28)
    }

    private var songTitle: Text {
        let title = Text(track.name)
            .font(Theme.Typography.trackTitle)
            .foregroundColor(isCurrent ? Theme.accent : .primary)
        guard let subtitle = track.subtitle, !subtitle.isEmpty, !isCompact else { return title }
        // One text run truncates once, after giving the main title its full width.
        return title + Text("  (\(subtitle))")
            .font(.system(size: 12))
            .foregroundColor(Color.secondary.opacity(0.6))
    }

    private var likeAndDuration: some View {
        HStack(spacing: 8) {
            #if os(macOS)
            // A saved track already keeps the button visible through its own state.
            TrackDownloadButton(track: track, isVisible: isHovering)
                // Keep download confirmation and in-flight button state bound
                // to their original song without replacing the whole row.
                .id(track.id)
            #else
            TrackDownloadButton(track: track, isVisible: false)
            #endif
            if showsLikeButton && account.provider.supportsFavoriteChanges {
                let liked = account.isLiked(track.id)
                PlayerHeartIcon(liked: liked, size: 18)
                    .frame(width: 24, height: 24)
                    .opacity(liked ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("已喜欢")
                    .accessibilityHidden(!liked)
            }

            if let chartRank {
                ZStack(alignment: .center) {
                    if isCurrent {
                        PlayingIndicator(animating: playback.snapshot.isPlaying && !playback.snapshot.showNowPlaying)
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel(playback.snapshot.isPlaying ? "正在播放" : "已暂停")
                    } else {
                        VStack(alignment: .center, spacing: 3) {
                            Text(String(chartRank))
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundStyle(chartRank <= 3 ? Color.red : Color.secondary)
                            chartMovement(rank: chartRank)
                        }
                    }
                }
                .frame(width: Self.chartRankColumnWidth, alignment: .center)
            } else if showsDuration {
                // Keep duration text and its playback replacement on the same centerline.
                ZStack(alignment: .center) {
                    Text(Formatters.duration(track.duration))
                        .font(Theme.Typography.caption.monospacedDigit())
                        .foregroundStyle(!isCompact && style == .likedMusic ? .secondary : .tertiary)
                        .opacity(isCompact && isCurrent ? 0 : 1)
                        .accessibilityHidden(isCompact && isCurrent)
                    if isCompact && isCurrent {
                        PlayingIndicator(animating: playback.snapshot.isPlaying && !playback.snapshot.showNowPlaying)
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel(playback.snapshot.isPlaying ? "正在播放" : "已暂停")
                    }
                }
                .frame(width: 36, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func chartMovement(rank: Int) -> some View {
        if let ratio = chartGrowthRatio, ratio.isFinite {
            HStack(spacing: 2) {
                if ratio != 0 {
                    Image(systemName: ratio > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 7))
                }
                Text("\(abs(ratio).formatted(.number.precision(.fractionLength(0...1))))%")
                    .font(.system(size: 10).monospacedDigit())
            }
            .foregroundStyle(ratio > 0 ? Color.red : ratio < 0 ? Color.green : Color.secondary)
            .accessibilityLabel("涨跌幅 \(ratio.formatted())%")
        } else if let previousChartRank {
            if previousChartRank <= 0 {
                Text("NEW")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("新上榜")
            } else {
                let change = previousChartRank - rank
                HStack(spacing: 2) {
                    if change != 0 {
                        Image(systemName: change > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(.system(size: 7))
                    }
                    Text(change == 0 ? "—" : String(abs(change)))
                        .font(.system(size: 10).monospacedDigit())
                }
                .foregroundStyle(change > 0 ? Color.red : change < 0 ? Color.green : Color.secondary)
                .accessibilityLabel(change == 0 ? "排名不变" : "\(change > 0 ? "上升" : "下降") \(abs(change)) 名")
            }
        } else {
            Text("—")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .accessibilityLabel("暂无排名变化数据")
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("播放") { onPlay() }
        TrackDownloadActions(track: track)
        Button("下一首播放") {
            player.addToPlayNext(track)
        }
        Divider()
        if account.provider == .qq {
            Button("歌曲相关内容") { openDestination(.qqBrowse(.songRelated(track.id))) }
        }
        let liked = account.isLiked(track.id)
        if account.provider.supportsFavoriteChanges {
        Button(liked ? String(localized: "从「我喜欢」中移除") : String(localized: "添加到「我喜欢」")) {
            Task { await account.toggleLike(trackID: track.id) }
        }
        }
        if account.provider.supports(.playlistTrackAddition) {
        Button("收藏到歌单…") {
            #if os(macOS)
            AddToPlaylistPresenter.shared.track = track
            #else
            addToPlaylistTrack = track
            #endif
        }
        }
        if let onDeleteFromCloud {
            Button("从云盘中删除", role: .destructive) { onDeleteFromCloud(track) }
        }
        if let pid = removableFromPlaylistID {
            Button("从歌单中删除", role: .destructive) {
                Task {
                    do {
                        try await NeteaseAPI.playlistTracks(op: "del", playlistID: pid, trackIDs: [track.id])
                        onRemoved?()
                        ToastCenter.shared.show(String(localized: "已从歌单中删除"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
        }
        #if os(macOS)
        if !account.isLiked(track.id), let onRecommendationReduced {
            Button(String(localized: "减少推荐"), role: .destructive) {
                guard !isReducingRecommendation else { return }
                let trackID = track.id
                reducingRecommendationIDs.insert(trackID)
                Task {
                    defer { reducingRecommendationIDs.remove(trackID) }
                    do {
                        let replacement = try await NeteaseAPI.dislikeRecommendedSong(id: track.id)
                        onRecommendationReduced(replacement)
                        ToastCenter.shared.show(String(localized: "已减少推荐"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
            .disabled(isReducingRecommendation)
        }
        #endif
        Divider()
        if track.album.id != 0 {
            Button("查看专辑") {
                openDestination(.album(track.album.id))
            }
        }
        ForEach(track.artists.filter { $0.id != 0 && !$0.name.isEmpty }.prefix(3)) { artist in
            Button("查看歌手：\(artist.name)") {
                openDestination(.artist(artist.id))
            }
        }
        Divider()
        Button("复制链接") {
            Platform.copyToPasteboard(string: "https://music.163.com/#/song?id=\(track.id)")
            ToastCenter.shared.show(String(localized: "链接已复制"))
        }
        if let url = track.musicShareURL {
            ShareLink(item: url) {
                Text("分享")
            }
        }
    }
}

// MARK: - Playing indicator

/// The four bars beside the row that's playing.
///
/// Deliberately not a SwiftUI animation. Driving these from `TimelineView` —
/// as this did for a long time — makes SwiftUI re-evaluate and re-lay-out the
/// enclosing tree on every tick, and with the now-playing page presented as an
/// overlay that tree is the entire window. Profiling put the cost at roughly
/// 30% of a core, for four 14pt bars.
///
/// Scaling plain `CALayer`s instead is a compositing change: no `draw`, no
/// layout invalidation, nothing above it in the tree ever learns a frame
/// happened.
struct PlayingIndicator: View {
    var animating: Bool

    var body: some View {
        SpectrumBars(animating: animating)
            .frame(width: SpectrumBarsView.width, height: SpectrumBarsView.maxHeight)
    }
}

#if os(macOS)
private struct SpectrumBars: NSViewRepresentable {
    var animating: Bool
    func makeNSView(context: Context) -> SpectrumBarsView { SpectrumBarsView() }
    func updateNSView(_ view: SpectrumBarsView, context: Context) {
        view.animating = animating
    }
    static func dismantleNSView(_ view: SpectrumBarsView, coordinator: ()) {
        view.animating = false
    }
}
#else
private struct SpectrumBars: UIViewRepresentable {
    var animating: Bool
    func makeUIView(context: Context) -> SpectrumBarsView { SpectrumBarsView() }
    func updateUIView(_ view: SpectrumBarsView, context: Context) {
        view.animating = animating
    }
    static func dismantleUIView(_ view: SpectrumBarsView, coordinator: ()) {
        view.animating = false
    }
}
#endif

final class SpectrumBarsView: PlatformView {
    static let minHeight: CGFloat = 3
    static let maxHeight: CGFloat = 14
    static let barWidth: CGFloat = 2.5
    static let spacing: CGFloat = 2
    static let width =
        CGFloat(AudioSpectrum.bandCount) * barWidth
        + CGFloat(AudioSpectrum.bandCount - 1) * spacing

    private var bars: [CALayer] = []
    private var timer: Timer?
    private var startedAt = CACurrentMediaTime()

    var animating = false {
        didSet {
            guard animating != oldValue else { return }
            animating ? start() : stop()
        }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.maxHeight))
        #if os(macOS)
        wantsLayer = true
        #endif
        buildBars()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { timer?.invalidate() }

    /// `NSView.layer` is optional; `UIView.layer` is not.
    private var hostLayer: CALayer? { layer }

    private func buildBars() {
        guard let host = hostLayer else { return }
        let color = PlatformColor(Theme.accent).cgColor
        for _ in 0..<AudioSpectrum.bandCount {
            let bar = CALayer()
            bar.backgroundColor = color
            bar.cornerRadius = 1
            // Centered anchor so a scale grows the bar symmetrically.
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.maxHeight)
            host.addSublayer(bar)
            bars.append(bar)
        }
        apply(scaleForAll: Self.minHeight / Self.maxHeight)
    }

    #if os(macOS)
    override func layout() {
        super.layout()
        positionBars()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        positionBars()
    }
    #endif

    private func positionBars() {
        for (i, bar) in bars.enumerated() {
            bar.position = CGPoint(
                x: CGFloat(i) * (Self.barWidth + Self.spacing) + Self.barWidth / 2,
                y: bounds.midY)
        }
    }

    private func start() {
        guard timer == nil else { return }
        startedAt = CACurrentMediaTime()
        // Common mode so the bars keep moving while a list is being scrolled.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        apply(scaleForAll: Self.minHeight / Self.maxHeight)
    }

    @MainActor
    private func tick() {
        let spectrum = AudioSpectrum.shared
        let live: Bool
        switch spectrum.tapState {
        case .tapped:
            // Samples may still be a few hundred milliseconds out while the
            // source buffers. Hold still through that rather than animating,
            // which reads as a glitch right as a song starts.
            live = spectrum.isLive
            guard live else {
                apply(scaleForAll: Self.minHeight / Self.maxHeight)
                return
            }
        case .untappable:
            live = false
        case .idle, .preparing:
            // Not yet known whether this source can be tapped.
            apply(scaleForAll: Self.minHeight / Self.maxHeight)
            return
        }

        let elapsed = CACurrentMediaTime() - startedAt
        let span = Self.maxHeight - Self.minHeight

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            // Real band levels when the tap is feeding us; otherwise the old
            // decorative sine, so untappable sources still look alive.
            let level = live
                ? CGFloat(spectrum.level(at: i))
                : CGFloat(abs(sin(elapsed * 2.4 + Double(i) * 0.9)))
            let height = Self.minHeight + span * level
            bar.transform = CATransform3DMakeScale(1, height / Self.maxHeight, 1)
        }
        CATransaction.commit()
    }

    private func apply(scaleForAll scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }
}

// MARK: - Track list

struct TrackListView: View {
    struct HorizontalLayout {
        let rows: Int
        let columnWidth: CGFloat
        let rowHeight: CGFloat
    }

    enum Layout {
        case stack
        #if os(macOS)
        /// One reusable native table cell, retaining the complete playback queue.
        case singleRow(Int)
        #endif
    }

    private let rowSpacing: CGFloat = 1

    let tracks: [Track]
    var displayLimit: Int?
    /// History can contain the same song more than once; retain each record's identity.
    var rowIDs: [String]? = nil
    var style: TrackRowStyle = .full
    var showsLikeButton = true
    var showsAlbumSubtitle = false
    var columns = 1
    /// Defaults to the shared iPad library style, including horizontal song shelves.
    var showsRowSeparators: Bool? = nil
    var source: PlaySource = .none
    /// The place this list belongs to, for the Dock menu's recents.
    var context: PlayContext?
    var removableFromPlaylistID: Int?
    var onRemoved: ((Track) -> Void)?
    var onDeleteFromCloud: ((Track) -> Void)?
    var recommendationContext: RecommendationContext?
    var onRecommendationReduced: ((Track, Track) -> Void)?
    var trailingText: ((Track) -> String?)?
    var onLastTrackAppear: (() -> Void)?
    var selection: Binding<Set<Int>>?
    var layout: Layout = .stack
    var horizontalLayout: HorizontalLayout?

    // Playback state belongs to TrackRow; the list only starts playback.
    private let player = PlayerService.shared
    var libraryLayout = MusicLibraryTrackLayout()

    private var showsColumnSeparator: Bool {
        libraryLayout.usesPanel && style == .likedMusic && columns == 2 && tracks.count > 1
    }

    @ViewBuilder
    var body: some View {
        if let horizontalLayout {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(horizontalLayout.rowHeight), spacing: rowSpacing),
                                 count: max(1, horizontalLayout.rows)), alignment: .top, spacing: Theme.Spacing.group) {
                ForEach(tracks.indices.prefix(displayLimit ?? tracks.count), id: \.self) { index in
                    row(at: index)
                        .frame(width: horizontalLayout.columnWidth)
                }
            }
        } else {
            switch layout {
            case .stack:
                if columns > 1 {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: showsColumnSeparator ? MusicLibraryTrackLayout.dividedColumnSpacing : Theme.Spacing.component), count: columns),
                              alignment: .leading, spacing: rowSpacing) {
                        rows(in: tracks.indices)
                    }
                    .overlay {
                        if showsColumnSeparator {
                            // Keep the divider inside the scrolling song grid, away from the header.
                            Rectangle()
                                .fill(Color.primary.opacity(0.05))
                                .frame(width: 0.5)
                                .offset(x: MusicLibraryTrackLayout.columnSeparatorOpticalOffset)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                } else {
                    LazyVStack(spacing: rowSpacing) { rows(in: tracks.indices) }
                }
            #if os(macOS)
            case .singleRow(let index):
                // The native table already provides one reusable cell. A keyed
                // ForEach here would discard the entire row graph on every reuse.
                row(at: index)
            #endif
            }
        }
    }

    private func rows(in range: Range<Int>) -> some View {
        ForEach(range.map { (index: $0, id: rowIDs?[$0] ?? String(tracks[$0].id)) }, id: \.id) { index, _ in
            row(at: index)
        }
    }

    private func row(at index: Int) -> some View {
        let track = tracks[index]
        let recommendationHandler = onRecommendationReduced
        let row = TrackRow(
            track: track,
            index: style == .albumTrack ? (track.trackNo > 0 ? track.trackNo : index + 1) : index + 1,
            style: style,
            showsLikeButton: showsLikeButton,
            showsAlbumSubtitle: showsAlbumSubtitle,
            trailingText: trailingText?(track),
            removableFromPlaylistID: removableFromPlaylistID,
            onRemoved: { onRemoved?(track) },
            onRecommendationReduced: recommendationContext == nil || recommendationHandler == nil
                ? nil
                : { replacement in recommendationHandler?(track, replacement) },
            onDeleteFromCloud: onDeleteFromCloud
        ) {
            player.play(tracks: tracks, source: source, startAt: track,
                        context: context)
        }
        return VStack(spacing: 0) {
            if let selection {
                let selected = selection.wrappedValue.contains(track.id)
                Button {
                    if selected { selection.wrappedValue.remove(track.id) }
                    else { selection.wrappedValue.insert(track.id) }
                } label: {
                    HStack(spacing: 0) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(selected ? Theme.accent : Color.secondary)
                            .frame(width: 32)
                        row.disabled(true).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(track.name), \(track.artistNames)"))
                .accessibilityValue(selected ? Text("已选择") : Text("未选择"))
                .accessibilityIdentifier("select-download-\(track.id)")
            } else { row }
        }
        .onAppear {
            if index == tracks.count - 1 { onLastTrackAppear?() }
        }
        .overlay(alignment: .bottom) {
            if (showsRowSeparators ?? (libraryLayout.usesPanel && style == .likedMusic)),
               hasFollowingRow(at: index) {
                MusicLibrarySeparator(
                    leadingInset: separatorLeadingInset + (selection == nil ? 0 : 32),
                    trailingInset: Theme.Layout.trackRowHorizontalInset)
            }
        }
    }

    private var separatorLeadingInset: CGFloat {
        #if os(iOS)
        return Theme.Layout.trackRowHorizontalInset + Theme.Layout.trackArtworkSize * UIFontMetrics(forTextStyle: .body).scaledValue(for: 1) + Theme.Spacing.control
        #else
        return 10 + 48 + 12
        #endif
    }

    private func hasFollowingRow(at index: Int) -> Bool {
        if let horizontalLayout {
            // A horizontal grid fills each column from top to bottom.
            let rows = max(1, horizontalLayout.rows)
            return index % rows < rows - 1 && index + 1 < tracks.count
        }
        return index + max(1, columns) < tracks.count
    }

}

// MARK: - Add to playlist

#if os(macOS)
/// One window-level sheet for every song row. A `.sheet` on each row gives
/// dozens of on-screen rows their own presentation host.
@MainActor
final class AddToPlaylistPresenter: ObservableObject {
    static let shared = AddToPlaylistPresenter()
    @Published var track: Track?
}

struct AddToPlaylistPresentation: ViewModifier {
    @ObservedObject private var presenter = AddToPlaylistPresenter.shared

    func body(content: Content) -> some View {
        content.sheet(item: $presenter.track) { track in
            AddToPlaylistSheet(track: track)
        }
    }
}
#endif

struct AddToPlaylistSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        sheetContent
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
    }

    @ViewBuilder
    private var sheetContent: some View {
        #if os(iOS)
        if #available(iOS 16.4, *) {
            content.presentationBackground(Theme.barMaterial)
        } else {
            content.background(Theme.barMaterial)
        }
        #else
        content.background(Theme.barMaterial)
        #endif
    }

    private var content: some View {
        AddToPlaylistContent(track: track) { dismiss() }
            #if os(iOS)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            #else
            .frame(width: 440, height: 540)
            #endif
    }
}
