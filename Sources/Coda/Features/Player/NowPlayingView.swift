import SwiftUI

#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-only
// Motion adapted from youshen2/MeloX at 09713edb847a0f0a3515a34f779cc630d4fe5985:
// NowPlayingMotionSpec.swift and the shared overlay in NowPlayingView.swift.
// See ThirdPartyNotices/MeloX.md for iOS 16 and renderer adaptations.
private enum PortraitPageMotion {
    static func artwork(reduced: Bool) -> Animation? {
        guard !reduced else { return nil }
        return smooth(duration: 0.30)
    }

    static func lyricsSpatial(reduced: Bool) -> Animation? {
        guard !reduced else { return nil }
        return .interpolatingSpring(mass: 1, stiffness: 350, damping: 40, initialVelocity: 0)
    }

    static func opacity(reduced: Bool) -> Animation? {
        reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: 0.18)
    }

    static func header(presented: Bool, reduced: Bool) -> Animation? {
        guard !reduced else { return nil }
        return smooth(duration: presented ? 0.40 : 0.24).delay(presented ? 0.08 : 0)
    }

    static func smooth(duration: Double) -> Animation {
        if #available(iOS 17, *) { return .smooth(duration: duration) }
        // No-bounce spring fallback for the physical iPad on iPadOS 16.
        return .spring(response: duration, dampingFraction: 1)
    }
}
#endif

/// Immersive full-window now-playing page: artwork-driven flowing backdrop,
/// large artwork on the left, big synced lyrics on the right.
struct NowPlayingView: View {
    let onOpenDestination: (Destination) -> Void
    let backgroundColorScheme: ColorScheme

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    #if os(macOS)
    @EnvironmentObject private var artworkStore: NowPlayingArtworkStore
    #endif
    #if os(iOS)
    @Environment(\.nowPlayingBackgroundIsExternal) private var backgroundIsExternal
    @Environment(\.dismissNowPlayingAction) private var dismissNowPlayingAction
    @Environment(\.dismissNowPlayingThenAction) private var dismissNowPlayingThenAction
    #endif

    @Environment(\.accessibilityReduceMotion) private var reducePlayerMotion
    /// 封面变色的脉动（跟着音频低频走；关了封面变色也不用它）。
    @StateObject private var coverPulse = CoverPulseModel()
    @ScaledMetric(relativeTo: .title3) private var iPadMetadataHeight: CGFloat = 56
    #if os(iOS)
    // Restore the last explicit lyric/artwork choice across presentations and launches.
    @AppStorage("player.singleColumnLyricsVisible") private var showsSingleColumnLyrics = true
    @State private var loadedArtwork = CachedImageState()
    @State private var loadedArtworkColors: ArtworkColors = .fallback
    @State private var portraitLyricsEntrancePresented = true
    @State private var portraitLyricsEntranceStartedAt: ContinuousClock.Instant?
    @State private var portraitLyricsExitStartedAt: ContinuousClock.Instant?
    @State private var portraitPreparedLyricsTrackID: Int?
    @State private var portraitArtworkPageFrame: CGRect = .zero
    @State private var portraitControlsCollapsed = false
    @State private var portraitControlsHeight: CGFloat = 320
    @State private var portraitControlsActivityGeneration = 0
    @State private var portraitControlsInteractionActive = false
    @Environment(\.accessibilityVoiceOverEnabled) private var playerVoiceOverEnabled
    #endif
    @State private var showLyricsOnMobile = false
    private enum IPadPanel { case lyrics, queue, comments }
    @State private var iPadPanel: IPadPanel = .lyrics
    @State private var iPadComments: SongCommentsStore?
    @State private var playlistTrack: Track?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                #if os(iOS)
                NowPlayingTouchShield()
                    .ignoresSafeArea()
                #endif
                #if os(iOS)
                if !backgroundIsExternal { backdrop }
                #else
                backdrop
                #endif

                #if os(iOS)
                if usesPortraitLayout(size: geo.size) {
                    portraitLayout(size: geo.size)
                } else {
                    regularLayout(size: geo.size)
                }
                #else
                if geo.size.width < WindowLayout.singleColumnPlayerWidth {
                    compactLayout(size: geo.size)
                } else {
                    regularLayout(size: geo.size)
                }
                #endif
            }
            // Pin to the screen width so an intrinsically-wide child can never
            // stretch the ZStack and push the corner overlays off-screen.
            .frame(width: geo.size.width)
            .environment(\.playlistPanelSelected, playlistTrack != nil)
            #if os(macOS)
            .overlay(alignment: .top) {
                DesktopPlayerHandle(close: close)
                    .padding(.top, NowPlayingSplitGeometry.verticalInset(height: geo.size.height))
            }
            #endif

        }
        #if os(iOS)
        // The iPad player is an overlay. A preferredColorScheme would escape
        // to the app window, then flip the browsing page when this view exits.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(UIDevice.current.userInterfaceIdiom == .pad ? nil : .dark)
        #else
        .environment(\.colorScheme, .dark)
        #endif
        #if os(iOS)
        .modifier(OfflinePlaybackAlert(player: player, onDownloads: { openTrackDestination(.downloaded) },
            enabled: player.showNowPlaying))
        .modifier(MeteredDownloadAlert(enabled: player.showNowPlaying))
        #endif
        #if os(iOS)
        .task(id: currentArtworkURL) {
            await loadArtwork()
        }
        .task(id: player.currentTrack?.id) {
            await player.loadCurrentLyricsIfNeeded()
        }
        #endif
        .onChange(of: player.currentTrack?.id) { _ in
            if playlistTrack != nil { playlistTrack = player.currentTrack }
            iPadComments = iPadPanel == .comments
                ? player.currentTrack.map { SongCommentsStore(trackID: $0.id) } : nil
        }
        #if os(macOS)
        .onExitCommand {
            close()
        }
        #endif
    }

    private var hasLyricsColumn: Bool {
        if let lyrics = player.lyrics, !lyrics.isEmpty { return true }
        return player.lyrics == nil // still loading — keep layout stable
    }

    private func close() {
        #if os(iOS)
        if let dismissNowPlayingAction {
            dismissNowPlayingAction()
        } else {
            withAnimation(NowPlayingPresentationMetrics.presentationAnimation) {
                player.showNowPlaying = false
            }
        }
        #else
        player.showNowPlaying = false
        #endif
    }

    private func openTrackDestination(_ destination: Destination) {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad,
           player.showNowPlaying,
           let dismissThen = dismissNowPlayingThenAction {
            dismissThen.perform { onOpenDestination(destination) }
            return
        }
        #endif
        onOpenDestination(destination)
    }

    // MARK: - Backdrop

    private var artworkImage: PlatformImage? {
        #if os(macOS)
        artworkStore.artwork
        #else
        loadedArtwork.image(for: currentArtworkURL)
        #endif
    }

    private var colors: ArtworkColors {
        #if os(macOS)
        artworkStore.colors
        #else
        artworkImage == nil ? .fallback : loadedArtworkColors
        #endif
    }

    /// 播放页强调色：开着封面变色且有封面时用封面主色（跟着脉动微亮），
    /// 否则用 WQ 主题的强调色。
    private var playerAccent: Color {
        CoverReactiveAccent.color(colors: colors, enabled: settings.coverReactiveColors,
                                  pulse: coverPulse.pulse)
    }

    private var backdrop: some View {
        Group {
            if settings.coverReactiveColors {
                NowPlayingFluidBackground(artwork: artworkImage, artworkKey: player.currentTrack?.album.picUrl,
                                          colors: colors, playing: player.isPlaying)
            } else {
                // 关了封面变色：播放页用 WQ 主题的背景。
                CodaThemeBackgroundView()
            }
        }
        .environment(\.colorScheme, backgroundColorScheme)
    }

    #if os(iOS)
    private var currentArtworkURL: URL? {
        player.currentTrack?.album.picUrl?.resizedImageURL(1536)
    }

    private func loadArtwork() async {
        loadedArtworkColors = .fallback
        guard let urlString = player.currentTrack?.album.picUrl,
              let url = currentArtworkURL else {
            loadedArtwork = CachedImageState()
            return
        }
        loadedArtwork = CachedImageState(url: url)
        let image = await ImageCache.shared.image(for: url) { preview in
            applyArtwork(preview, for: url, cacheKey: urlString)
        }
        if let image { applyArtwork(image, for: url, cacheKey: urlString) }
    }

    private func applyArtwork(_ image: PlatformImage, for url: URL, cacheKey: String) {
        guard !Task.isCancelled, currentArtworkURL == url else { return }
        loadedArtwork.finish(image, for: url)
        loadedArtworkColors = ArtworkPalette.extract(from: image, cacheKey: cacheKey)
    }
    #endif

    // MARK: - Layouts

    /// Slider dimensions shared across devices; the iPhone also uses this spacing rhythm.
    private struct ControlMetrics {
        let scale: CGFloat
        init(width: CGFloat) { scale = min(1.15, max(0.95, width / 356)) }
        init(scale: CGFloat) { self.scale = scale }
        var progressHeight: CGFloat { 52 * scale }
        var progressGap: CGFloat { 24 * scale }
        var transportHeight: CGFloat { 82 * scale }
        var transportGap: CGFloat { 36 * scale }
        var volumeHeight: CGFloat { 32 * scale }
        var utilityGap: CGFloat { 4 * scale }
        var utilityHeight: CGFloat { 50 * scale }
        var trackHeight: CGFloat { 7 * scale }
        var totalHeight: CGFloat { 280 * scale }
    }

    private func playbackControls<Utility: View>(width: CGFloat, animated: Bool = false,
                                                 metrics: ControlMetrics? = nil,
                                                 @ViewBuilder utility: () -> Utility) -> some View {
        let metrics = metrics ?? ControlMetrics(width: width)
        return VStack(spacing: 0) {
            controlLayer(animated: animated, offset: 180, showDelay: 0.025, hideDelay: 0.075) {
                NowPlayingScrubber(showsRemainingTime: true, rowHeight: metrics.progressHeight,
                                   trackHeight: metrics.trackHeight, tint: playerAccent)
            }
            Color.clear.frame(height: metrics.progressGap)
            controlLayer(animated: animated, offset: 165, showDelay: 0.05, hideDelay: 0.05) {
                PlayerTransportControls(width: width, height: metrics.transportHeight, tint: playerAccent)
            }
            Color.clear.frame(height: metrics.transportGap)
            controlLayer(animated: animated, offset: 148, showDelay: 0.075, hideDelay: 0.025) {
                volumeControl(rowHeight: metrics.volumeHeight, trackHeight: metrics.trackHeight)
            }
            Color.clear.frame(height: metrics.utilityGap)
            controlLayer(animated: animated, offset: 128, showDelay: 0.10, hideDelay: 0) {
                utility().frame(height: metrics.utilityHeight)
            }
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func controlLayer<Content: View>(animated: Bool, offset: CGFloat,
                                             showDelay: Double, hideDelay: Double,
                                             @ViewBuilder content: () -> Content) -> some View {
        #if os(iOS)
        if animated {
            portraitControlLayer(offset: offset, showDelay: showDelay, hideDelay: hideDelay, content: content)
        } else {
            content()
        }
        #else
        content()
        #endif
    }

    @ViewBuilder
    private func regularLayout(size: CGSize) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            phoneRegularLayout(size: size)
        } else {
            iPadRegularLayout(size: size)
        }
        #else
        desktopRegularLayout(size: size)
        #endif
    }

    private func usesPortraitLayout(size: CGSize) -> Bool {
        #if os(iOS)
        return size.width < 600 || size.height > size.width
        #else
        return false
        #endif
    }

    private func singleColumnTrackHeader(width: CGFloat) -> some View {
        HStack(spacing: 12) {
            #if os(iOS)
            portraitArtworkLink(size: 72, expanded: false)
            #else
            artworkView(size: 72, cornerRadius: 12)
            #endif
            NowPlayingTrackInfoRow(
                onOpenDestination: openTrackDestination,
                largeMetadata: true,
                usesPortraitHeaderSizing: true,
                movesMoreToDeviceRow: true,
                showsMoreBesideFavorite: true,
                metadataWidth: max(0, width - 72 - 12 - (player.currentTrack == nil ? 0 : 132 + 3 * Theme.Spacing.small)),
                onAddToPlaylist: togglePlaylistPanel
            )
            .frame(maxWidth: .infinity)
        }
        .frame(width: width)
        .frame(minHeight: max(72, iPadMetadataHeight))
        .fixedSize(horizontal: false, vertical: true)
    }

    #if os(iOS)
    /// Shared vertical composition for iPad portrait and iPhone. The viewport
    /// reuses the landscape panels while the controls keep their own space.
    private func portraitLayout(size: CGSize) -> some View {
        portraitControlsAutoHide(portraitLayoutContent(size: size), showsArtwork: portraitShowsArtwork)
    }

    private var portraitShowsArtwork: Bool {
        !showsSingleColumnLyrics && iPadPanel == .lyrics && playlistTrack == nil
    }

    /// The playback controls float over the lyrics and fade out after 3s of
    /// inactivity while playing. Shared by iPhone portrait and landscape.
    private func portraitControlsAutoHide<Content: View>(_ content: Content, showsArtwork: Bool) -> some View {
        content
            .onPreferenceChange(PortraitControlsHeightKey.self) { height in
                if height > 0 { portraitControlsHeight = height }
            }
            // Rotation swaps the layout subtree; keep the remembered collapse
            // state and only restart the idle timer. Artwork mode always shows them.
            .onAppear {
                if showsArtwork { registerPortraitControlsActivity() } else { restartPortraitControlsIdleTimer() }
            }
            .onChange(of: player.showNowPlaying) { shown in
                if shown { registerPortraitControlsActivity() }
            }
            .onChange(of: iPadPanel) { _ in registerPortraitControlsActivity() }
            .onChange(of: playlistTrack?.id) { _ in registerPortraitControlsActivity() }
            .onChange(of: usesPortraitLyricsInterface) { usesLyrics in
                // A track change clears lyrics while the next ones load; keep
                // collapsed controls hidden then. Reveal only for a song without lyrics.
                if usesLyrics || player.lyrics == nil {
                    restartPortraitControlsIdleTimer()
                } else {
                    registerPortraitControlsActivity()
                }
            }
            .onChange(of: player.currentTrack?.id) { _ in restartPortraitControlsIdleTimer() }
            .onChange(of: player.isPlaying) { _ in registerPortraitControlsActivity() }
            .onChange(of: playerVoiceOverEnabled) { _ in registerPortraitControlsActivity() }
            .task(id: portraitControlsActivityGeneration) {
                guard !showsArtwork, player.isPlaying, usesPortraitLyricsInterface, !portraitControlsCollapsed,
                      !playerVoiceOverEnabled, !portraitControlsInteractionActive else { return }
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                guard !Task.isCancelled, usesPortraitLyricsInterface else { return }
                setPortraitControlsVisible(false)
            }
    }

    private func portraitLayoutContent(size: CGSize) -> some View {
        let isNarrow = size.width < 600
        let inset: CGFloat = isNarrow ? 24 : min(72, size.width * 0.06)
        let width = max(0, min(size.width - inset * 2, 960))
        // The header and panels share the progress bar's width, as on Mac.
        let contentWidth = portraitControlsWidth(availableWidth: width)
        let showsFullControls = iPadPanel == .lyrics && playlistTrack == nil
        let showsArtwork = !showsSingleColumnLyrics && showsFullControls
        let lyricsVisible = !showsArtwork && portraitLyricsEntrancePresented
        let trackID = player.currentTrack?.id
        let lyricsPrepared = player.lyrics?.isEmpty != false || portraitPreparedLyricsTrackID == trackID
        return ZStack(alignment: .bottom) {
            // Keep the lyric viewport alive across artwork toggles. Recreating
            // its native text hosts during the transition stalls the first frames.
            VStack(spacing: isNarrow ? Theme.Spacing.small : Theme.Spacing.component) {
                singleColumnTrackHeader(width: contentWidth)
                .offset(y: showsArtwork && !reducePlayerMotion ? 40 : 0)
                .opacity(showsArtwork ? 0 : 1)
                .animation(PortraitPageMotion.header(presented: !showsArtwork, reduced: reducePlayerMotion),
                           value: showsArtwork)

                playbackContentPanel
                    .environment(\.nowPlayingLyricsPresented, !showsArtwork)
                    .environment(\.nowPlayingLyricsInitialFocusPrepared, {
                        guard player.currentTrack?.id == trackID else { return }
                        portraitPreparedLyricsTrackID = trackID
                    })
                    .environment(\.nowPlayingLyricsInterface, usesPortraitLyricsInterface ? NowPlayingLyricsInterface(
                        isVisible: !portraitControlsCollapsed,
                        bottomOverlayHeight: portraitControlsHeight,
                        onVisibilityChange: { setPortraitControlsVisible($0) },
                        onInteraction: togglePortraitControlsFromTap
                    ) : nil)
                    .padding(.bottom, usesPortraitLyricsInterface ? 0 : portraitControlsHeight)
                    // As on Mac, lyrics, comments, queue and playlist panels
                    // start at the header's leading edge with no own gutter.
                    .environment(\.nowPlayingFlushPanelEdges, true)
                    .overlay(alignment: .bottomTrailing) {
                        if iPadPanel == .lyrics && playlistTrack == nil {
                            iPadLyricsAnnotationButtons
                                .offset(y: portraitControlsCollapsed ? 64 : -portraitControlsHeight)
                                .scaleEffect(portraitControlsCollapsed ? 0.82 : 1)
                                .opacity(portraitControlsCollapsed ? 0 : 1)
                                .allowsHitTesting(!portraitControlsCollapsed)
                                .accessibilityHidden(portraitControlsCollapsed)
                                .animation(portraitInterfaceAnimation(duration: 0.24,
                                    delay: portraitControlsCollapsed ? 0.10 : 0), value: portraitControlsCollapsed)
                        }
                    }
                    .layoutPriority(-1)
                    .scaleEffect(!lyricsVisible && !reducePlayerMotion ? 0.90 : 1)
                    .animation(PortraitPageMotion.lyricsSpatial(reduced: reducePlayerMotion), value: lyricsVisible)
                    .opacity(lyricsVisible ? 1 : 0)
                    .animation(PortraitPageMotion.opacity(reduced: reducePlayerMotion), value: lyricsVisible)
            }
            .frame(width: contentWidth)
            .allowsHitTesting(!showsArtwork)
            .accessibilityHidden(showsArtwork)

            portraitArtworkContent(width: width)
                .offset(y: showsArtwork || reducePlayerMotion ? 0 : -300)
                .opacity(showsArtwork ? 1 : 0)
                .allowsHitTesting(showsArtwork)
                .accessibilityHidden(!showsArtwork)
                .animation(reducePlayerMotion ? nil : PortraitPageMotion.smooth(
                    duration: showsArtwork ? 0.22 : 0.24).delay(showsArtwork ? 0.07 : 0), value: showsArtwork)

            // One controls tree remains in place for both content presentations.
            Group {
                if showsFullControls {
                    portraitPlaybackControls(width: width, allowsArtwork: true)
                } else {
                    portraitUtilityBar(allowsArtwork: true)
                        .frame(width: portraitControlsWidth(availableWidth: width),
                               height: ControlMetrics(width: portraitControlsWidth(availableWidth: width)).utilityHeight)
                }
            }
            .background {
                GeometryReader { controls in
                    Color.clear.preference(key: PortraitControlsHeightKey.self, value: controls.size.height)
                }
            }
            .allowsHitTesting(!showsFullControls || !portraitControlsCollapsed)
            .accessibilityHidden(showsFullControls && portraitControlsCollapsed)
        }
        .frame(width: width)
        .background {
            portraitArtworkContent(width: width, measuresArtwork: true)
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            portraitSharedArtwork(expanded: showsArtwork, headerLeading: (width - contentWidth) / 2)
        }
        .coordinateSpace(name: "NowPlayingPortraitArtwork")
        .onPreferenceChange(PortraitArtworkFrameKey.self) { frame in
            guard frame.width > 0, frame.height > 0,
                  frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite else { return }
            if abs(frame.minX - portraitArtworkPageFrame.minX) > 0.5
                || abs(frame.minY - portraitArtworkPageFrame.minY) > 0.5
                || abs(frame.width - portraitArtworkPageFrame.width) > 0.5
                || abs(frame.height - portraitArtworkPageFrame.height) > 0.5 {
                portraitArtworkPageFrame = frame
            }
        }
        .padding(.top, UIDevice.current.userInterfaceIdiom == .pad ? 64 : 34)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onChange(of: showsArtwork) { expanded in
            registerPortraitControlsActivity()
            if expanded {
                portraitLyricsExitStartedAt = .now
                portraitLyricsEntrancePresented = false
                portraitLyricsEntranceStartedAt = nil
            } else {
                // Reversing an unfinished exit continues immediately.
                let reversesExit = portraitLyricsExitStartedAt.map {
                    $0.duration(to: .now) < .seconds(0.18)
                } ?? false
                portraitLyricsEntrancePresented = reversesExit || reducePlayerMotion
                portraitLyricsEntranceStartedAt = .now
            }
        }
        .task(id: PortraitLyricsEntranceID(expanded: showsArtwork, trackID: trackID, prepared: lyricsPrepared)) {
            guard !showsArtwork, !portraitLyricsEntrancePresented else { return }
            await Task.yield()
            let start = portraitLyricsEntranceStartedAt ?? .now
            let deadline = start.advanced(by: .seconds(reducePlayerMotion ? 0 : lyricsPrepared ? 0.07 : 0.35))
            do {
                let remaining = ContinuousClock.now.duration(to: deadline)
                if remaining > .zero { try await Task.sleep(for: remaining) }
                try Task.checkCancellation()
            } catch { return }
            portraitLyricsEntrancePresented = true
        }
        .accessibilityIdentifier("portraitNowPlaying")
    }

    /// Artwork occupies the space above metadata and the same playback controls.
    /// Its size follows the available height so small phones keep every control reachable.
    private func portraitArtworkContent(width: CGFloat, measuresArtwork: Bool = false) -> some View {
        GeometryReader { available in
            let controlsWidth = portraitControlsWidth(availableWidth: width)
            let metrics = ControlMetrics(width: controlsWidth)
            let controlsHeight = metrics.progressHeight + metrics.progressGap
                + metrics.transportHeight + metrics.transportGap
                + metrics.volumeHeight + metrics.utilityGap + metrics.utilityHeight
            let coverSize = max(0, min(width,
                available.size.height - controlsHeight - iPadMetadataHeight - 32))
            VStack(spacing: 0) {
                portraitArtworkLink(size: coverSize, expanded: true)
                    .background {
                        if measuresArtwork {
                            GeometryReader { geometry in
                                Color.clear.preference(key: PortraitArtworkFrameKey.self,
                                    value: geometry.frame(in: .named("NowPlayingPortraitArtwork")))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                NowPlayingTrackInfoRow(
                    onOpenDestination: openTrackDestination,
                    largeMetadata: true,
                    usesPortraitHeaderSizing: true,
                    movesMoreToDeviceRow: true,
                    showsMoreBesideFavorite: true,
                    metadataWidth: max(0, controlsWidth - portraitMetadataActionsWidth),
                    onAddToPlaylist: togglePlaylistPanel
                )
                .frame(width: controlsWidth, alignment: .leading)
                .frame(minHeight: iPadMetadataHeight)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
                .padding(.bottom, 12)
                Color.clear.frame(height: controlsHeight)
                    .accessibilityHidden(true)
            }
            .frame(width: width, height: available.size.height)
        }
    }

    /// One overlay travels between the stationary artwork-page measurement and
    /// the 72pt song header; page details animate independently underneath it.
    @ViewBuilder
    private func portraitSharedArtwork(expanded: Bool, headerLeading: CGFloat) -> some View {
        if portraitArtworkPageFrame.width > 0 {
            let frame = expanded ? portraitArtworkPageFrame : CGRect(x: headerLeading, y: 0, width: 72, height: 72)
            let pausedInset = expanded && !player.isPlaying ? frame.width * (1 - 0.74) / 2 : 0
            let displayedFrame = frame.insetBy(dx: pausedInset, dy: pausedInset)
            NowPlayingPortraitArtwork(image: artworkImage, isArtworkPage: expanded, isPlaying: player.isPlaying)
                .frame(width: displayedFrame.width, height: displayedFrame.height)
                .position(x: displayedFrame.midX, y: displayedFrame.midY)
                .animation(PortraitPageMotion.artwork(reduced: reducePlayerMotion), value: expanded)
                .animation(reducePlayerMotion ? nil : PortraitPageMotion.smooth(duration: 0.48),
                           value: player.isPlaying)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func portraitArtworkLink(size: CGFloat, expanded: Bool) -> some View {
        if let album = player.currentTrack?.album, album.id != 0 {
            Button {
                openTrackDestination(.album(album.id))
            } label: {
                Color.clear
                    .frame(width: size, height: size)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .noFocusRing()
            .accessibilityLabel("打开专辑：\(album.name)")
            .accessibilityIdentifier(expanded ? "portraitLargeArtwork" : "portraitSmallArtwork")
        } else {
            Color.clear.frame(width: size, height: size)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var portraitMetadataActionsWidth: CGFloat {
        player.currentTrack == nil ? 0 : 132 + 3 * Theme.Spacing.small
    }

    private var usesPortraitLyricsInterface: Bool {
        iPadPanel == .lyrics && playlistTrack == nil && player.lyrics?.isEmpty == false
    }

    private func portraitControlsWidth(availableWidth: CGFloat) -> CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad
            ? max(0, availableWidth) : max(0, min(availableWidth - 16, 420))
    }

    private func portraitPlaybackControls(width: CGFloat, allowsArtwork: Bool,
                                          metrics: ControlMetrics? = nil) -> some View {
        let controlsWidth = portraitControlsWidth(availableWidth: width)
        return playbackControls(width: controlsWidth, animated: true, metrics: metrics) {
            portraitUtilityBar(allowsArtwork: allowsArtwork)
        }
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture {}
        }
        .background {
            NowPlayingControlsTouchObserver(isEnabled: !portraitControlsCollapsed) { active in
                portraitControlsInteractionActive = active
            }
        }
        .onChange(of: portraitControlsInteractionActive) { _ in
            // Cancel the pending hide on touch-down; start a fresh idle interval
            // on release (including gesture cancellation), even after a long hold.
            registerPortraitControlsActivity()
        }
    }

    private func portraitControlLayer<Content: View>(
        offset: CGFloat, showDelay: Double, hideDelay: Double,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .offset(y: portraitControlsCollapsed && !reducePlayerMotion ? offset : 0)
            .opacity(portraitControlsCollapsed ? 0 : 1)
            .animation(portraitInterfaceAnimation(duration: 0.24,
                delay: portraitControlsCollapsed ? hideDelay : showDelay), value: portraitControlsCollapsed)
    }

    private func portraitInterfaceAnimation(duration: Double, delay: Double = 0) -> Animation? {
        guard !reducePlayerMotion else { return nil }
        if #available(iOS 17, *) {
            return .smooth(duration: duration).delay(delay)
        }
        // SwiftUI's smooth spring is unavailable on the deployment target.
        return .timingCurve(0.4, 0, 0.2, 1, duration: duration).delay(delay)
    }

    private func registerPortraitControlsActivity() {
        portraitControlsActivityGeneration &+= 1
        withAnimation(portraitInterfaceAnimation(duration: 0.34)) {
            portraitControlsCollapsed = false
        }
    }

    /// Restarts the 3s idle interval without revealing collapsed controls.
    private func restartPortraitControlsIdleTimer() {
        portraitControlsActivityGeneration &+= 1
    }

    /// A tap on blank lyric space toggles the controls. Hiding by hand also
    /// works while paused; VoiceOver keeps them visible.
    private func togglePortraitControlsFromTap() {
        guard !portraitControlsCollapsed, usesPortraitLyricsInterface, !playerVoiceOverEnabled,
              !portraitControlsInteractionActive else {
            registerPortraitControlsActivity()
            return
        }
        portraitControlsActivityGeneration &+= 1
        withAnimation(portraitInterfaceAnimation(duration: 0.34)) {
            portraitControlsCollapsed = true
        }
    }

    private func setPortraitControlsVisible(_ visible: Bool) {
        if visible {
            registerPortraitControlsActivity()
        } else {
            guard player.isPlaying, usesPortraitLyricsInterface, !playerVoiceOverEnabled,
                  !portraitControlsCollapsed, !portraitControlsInteractionActive else { return }
            portraitControlsActivityGeneration &+= 1
            withAnimation(portraitInterfaceAnimation(duration: 0.34)) {
                portraitControlsCollapsed = true
            }
        }
    }

    private func portraitUtilityBar(allowsArtwork: Bool) -> some View {
        HStack(spacing: 0) {
            CurrentPlaybackDeviceButton()
                .layoutPriority(-1)
            Spacer(minLength: 12)
            HStack(spacing: Theme.Spacing.small) {
                iPadPanelButton("text.bubble", label: "歌曲评论", selected: iPadPanel == .comments && playlistTrack == nil) {
                    if let track = player.currentTrack, iPadComments?.trackID != track.id {
                        iPadComments = SongCommentsStore(trackID: track.id)
                    }
                    iPadPanel = iPadPanel == .comments && playlistTrack == nil ? .lyrics : .comments
                    playlistTrack = nil
                }
                .disabled(player.currentTrack == nil)
                iPadPanelButton("list.bullet", label: "待播清单", selected: iPadPanel == .queue && playlistTrack == nil) {
                    iPadPanel = iPadPanel == .queue && playlistTrack == nil ? .lyrics : .queue
                    playlistTrack = nil
                }
                iPadPanelButton("quote.bubble", label: "歌词",
                                selected: iPadPanel == .lyrics && playlistTrack == nil
                                    && (!allowsArtwork || showsSingleColumnLyrics)) {
                    // Only the resident page layers animate. Do not propagate
                    // a layout animation into the lyric glyphs or volume slider.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        portraitControlsCollapsed = false
                    }
                    if allowsArtwork {
                        showsSingleColumnLyrics = iPadPanel == .lyrics && playlistTrack == nil
                            ? !showsSingleColumnLyrics : true
                    }
                    playlistTrack = nil
                    iPadPanel = .lyrics
                }
                .accessibilityValue(iPadPanel == .lyrics && playlistTrack == nil
                    && (!allowsArtwork || showsSingleColumnLyrics) ? "已显示" : "已收起")
                .accessibilityHint(allowsArtwork ? "切换歌词与大封面" : "显示歌词")
                .accessibilityIdentifier("portraitLyricsToggle")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    #endif

    private var playbackContentPanel: some View {
        ZStack {
            if let track = playlistTrack {
                NowPlayingAddToPlaylistColumn(track: track) { playlistTrack = nil }
                    .id(track.id)
                    .transition(.opacity)
            } else if iPadPanel == .comments, let track = player.currentTrack,
               let comments = iPadComments, comments.trackID == track.id {
                SongCommentsColumn(track: track, model: comments)
                    .id(track.id)
                    .transition(.opacity)
            } else if iPadPanel == .queue {
                IOSInlinePlaybackQueueView()
                    .transition(.opacity)
            } else if hasLyricsColumn || player.lyrics?.isInstrumental == true {
                lyricsColumn
                    .transition(.opacity)
            } else {
                VStack(spacing: Theme.Spacing.control) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 32, weight: .light))
                    Text("暂无歌词")
                        .font(.subheadline)
                }
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.24), value: iPadPanel)
        .animation(.easeInOut(duration: 0.24), value: playlistTrack?.id)
    }

    private struct SplitControlSpacing {
        // Apple Music's controls have separate gaps rather than one uniform stack gap.
        var artwork: CGFloat { 32 }
        var metadata: CGFloat { 12 }
        var progress: CGFloat { 12 }
        var transport: CGFloat { 25 }
        var footer: CGFloat { 2 }
    }

    private func iPadRegularLayout(size: CGSize) -> some View {
        let shortViewport = size.height < 600
        // Reference screenshot measured in points: 52pt seek, 64pt transport, 32pt volume.
        let metrics = ControlMetrics(scale: 1)
        let transportHeight: CGFloat = 64
        let footerHeight: CGFloat = 44
        let spacing = SplitControlSpacing()
        let reservedHeight = spacing.artwork + iPadMetadataHeight + spacing.metadata
            + metrics.progressHeight + spacing.progress + transportHeight + spacing.transport
            + metrics.volumeHeight + spacing.footer + footerHeight
        let layout = NowPlayingSplitGeometry(size: size, reservedLeftHeight: reservedHeight)
        return HStack(spacing: 0) {
            playbackControlColumn(coverSize: layout.playerWidth, columnWidth: layout.halfWidth,
                                  spacing: spacing, transportHeight: transportHeight,
                                  largeMetadata: !shortViewport, controlsWidth: layout.playerWidth,
                                  metrics: metrics, onAddToPlaylist: togglePlaylistPanel)
                .frame(height: layout.contentHeight)
            VStack(spacing: Theme.Spacing.small) {
                playbackContentPanel
                    .environment(\.nowPlayingFlushPanelEdges, true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack {
                    Spacer(minLength: 0)
                    splitLyricsAnnotationButtons
                }
                .frame(height: footerHeight, alignment: .bottom)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("splitPlayerRightFooter")
            }
            .frame(width: layout.panelWidth, height: layout.contentHeight)
            .padding(.trailing, layout.horizontalInset)
        }
        .frame(width: size.width, height: layout.contentHeight, alignment: .top)
        .padding(.top, layout.top)
        .padding(.bottom, layout.verticalInset)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    #if os(iOS)
    /// iPhone landscape: the left column only carries the artwork and song
    /// actions; the right column mirrors portrait, with the playback controls
    /// floating over the lyrics and fading out after 3s of inactivity.
    private func phoneRegularLayout(size: CGSize) -> some View {
        // Same split rules as iPad and Mac: the halves meet at the centered
        // handle, and the cover keeps equal margins on both sides.
        let metadataSpacing: CGFloat = 14
        func geometry(reserving reserved: CGFloat) -> NowPlayingSplitGeometry {
            NowPlayingSplitGeometry(size: size, reservedLeftHeight: reserved,
                                    handleWidth: NowPlayingPresentationMetrics.indicatorWidth,
                                    handleToContentSpacing: 16,
                                    preferredHorizontalInset: 20)
        }
        // Content height does not depend on the reserved height.
        let contentHeight = geometry(reserving: 0).contentHeight
        // Landscape height is scarce; size the controls by height so the
        // lyrics keep a usable band while the controls are showing.
        let metrics = ControlMetrics(scale: min(1, max(0.72, contentHeight * 0.62 / 280)))
        // The song row shares its center line with the right column's bottom
        // utility bar (device, comments, queue, lyrics), so the playlist and
        // favorite buttons sit level with them. A taller row may reach into
        // the bottom inset rather than shrink the cover.
        let rowBottomInset = max(-geometry(reserving: 0).verticalInset,
                                 (metrics.utilityHeight - iPadMetadataHeight) / 2)
        let rowHeight = iPadMetadataHeight + metadataSpacing + rowBottomInset
        let layout = geometry(reserving: rowHeight)
        let leftWidth = layout.halfWidth
        let rightWidth = layout.panelWidth
        let coverSize = max(0, min(layout.playerWidth, contentHeight - rowHeight))
        let content = HStack(spacing: 0) {
            VStack(spacing: 0) {
                artworkView(size: coverSize)
                    .accessibilityIdentifier("landscapePlayerArtwork")
                Spacer(minLength: metadataSpacing)
                NowPlayingTrackInfoRow(onOpenDestination: openTrackDestination,
                                       largeMetadata: true, movesMoreToDeviceRow: true,
                                       showsMoreBesideFavorite: true,
                                       onAddToPlaylist: togglePlaylistPanel)
                    .frame(width: coverSize, height: iPadMetadataHeight)
                    .offset(y: -rowBottomInset)
            }
            .frame(width: leftWidth, height: contentHeight)

            landscapeLyricsColumn(width: rightWidth, metrics: metrics)
                .frame(width: rightWidth, height: contentHeight)
                .padding(.trailing, layout.horizontalInset)
        }
        .frame(width: size.width, height: contentHeight, alignment: .top)
        .padding(.top, layout.top)
        .padding(.bottom, layout.verticalInset)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background {
            // All blank page space, including the margins and safe-area
            // edges, toggles the controls like blank lyric space. The
            // artwork, buttons and lyric lines keep their own taps.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { togglePortraitControlsFromTap() }
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("landscapeNowPlaying")
        return portraitControlsAutoHide(content, showsArtwork: false)
    }

    private func landscapeLyricsColumn(width: CGFloat, metrics: ControlMetrics) -> some View {
        // portraitControlsWidth subtracts 16pt on iPhone; add it back so the
        // controls span the whole column.
        let controlsWidth = width + 16
        let showsFullControls = iPadPanel == .lyrics && playlistTrack == nil
        return ZStack(alignment: .bottom) {
            playbackContentPanel
                .environment(\.nowPlayingLyricsInterface, usesPortraitLyricsInterface ? NowPlayingLyricsInterface(
                    isVisible: !portraitControlsCollapsed,
                    bottomOverlayHeight: portraitControlsHeight,
                    onVisibilityChange: { setPortraitControlsVisible($0) },
                    onInteraction: togglePortraitControlsFromTap
                ) : nil)
                .padding(.bottom, usesPortraitLyricsInterface ? 0 : portraitControlsHeight)
                .environment(\.nowPlayingFlushPanelEdges, true)
                .overlay(alignment: .bottomTrailing) {
                    if iPadPanel == .lyrics && playlistTrack == nil {
                        iPadLyricsAnnotationButtons
                            .offset(y: portraitControlsCollapsed ? 64 : -portraitControlsHeight)
                            .scaleEffect(portraitControlsCollapsed ? 0.82 : 1)
                            .opacity(portraitControlsCollapsed ? 0 : 1)
                            .allowsHitTesting(!portraitControlsCollapsed)
                            .accessibilityHidden(portraitControlsCollapsed)
                            .animation(portraitInterfaceAnimation(duration: 0.24,
                                delay: portraitControlsCollapsed ? 0.10 : 0), value: portraitControlsCollapsed)
                    }
                }

            // Playlist, comments and queue panels keep only the bottom bar, as in portrait.
            Group {
                if showsFullControls {
                    portraitPlaybackControls(width: controlsWidth, allowsArtwork: false, metrics: metrics)
                } else {
                    portraitUtilityBar(allowsArtwork: false)
                        .frame(width: portraitControlsWidth(availableWidth: controlsWidth),
                               height: metrics.utilityHeight)
                }
            }
            .background {
                GeometryReader { controls in
                    Color.clear.preference(key: PortraitControlsHeightKey.self, value: controls.size.height)
                }
            }
            .allowsHitTesting(!showsFullControls || !portraitControlsCollapsed)
            .accessibilityHidden(showsFullControls && portraitControlsCollapsed)
        }
    }
    #endif

    private func lyricsPanelSelected(singleColumn: Bool) -> Bool {
        #if os(macOS)
        return iPadPanel == .lyrics && playlistTrack == nil
            && (!singleColumn || showLyricsOnMobile)
        #else
        return iPadPanel == .lyrics && playlistTrack == nil
        #endif
    }

    private func playbackPanelButtons(singleColumn: Bool = false) -> some View {
        HStack(spacing: Theme.Spacing.small) {
                iPadPanelButton("text.bubble", label: "歌曲评论", selected: iPadPanel == .comments && playlistTrack == nil) {
                    if let track = player.currentTrack, iPadComments?.trackID != track.id {
                        iPadComments = SongCommentsStore(trackID: track.id)
                    }
                    iPadPanel = iPadPanel == .comments && playlistTrack == nil ? .lyrics : .comments
                    playlistTrack = nil
                    showLyricsOnMobile = true
                }
                .disabled(player.currentTrack == nil)
                iPadPanelButton("list.bullet", label: "播放队列", selected: iPadPanel == .queue && playlistTrack == nil) {
                    iPadPanel = iPadPanel == .queue && playlistTrack == nil ? .lyrics : .queue
                    playlistTrack = nil
                    showLyricsOnMobile = true
                }
                iPadPanelButton("quote.bubble", label: "歌词", selected: lyricsPanelSelected(singleColumn: singleColumn)) {
                    #if os(macOS)
                    // A second tap returns the single-column player to its large artwork.
                    showLyricsOnMobile = singleColumn ? !lyricsPanelSelected(singleColumn: true) : true
                    #else
                    showLyricsOnMobile = true
                    #endif
                    playlistTrack = nil
                    iPadPanel = .lyrics
                }
        }
    }

    private var splitLyricsAnnotationButtons: some View {
        HStack(spacing: Theme.Spacing.small) {
            if iPadPanel == .lyrics && playlistTrack == nil {
                lyricsAnnotationButtonContents
            }
        }
        .frame(height: 44)
        .accessibilityIdentifier("splitLyricsAnnotationControls")
    }

    private func togglePlaylistPanel() {
        playlistTrack = playlistTrack == nil ? player.currentTrack : nil
    }

    private var iPadLyricsAnnotationButtons: some View {
        VStack(spacing: Theme.Spacing.small) {
            lyricsAnnotationButtonContents
        }
    }

    @ViewBuilder
    private var lyricsAnnotationButtonContents: some View {
        if hasLyricsRomaji {
            iPadPanelButton("", label: "罗马音",
                            selected: settings.lyricsAnnotation == .romaji,
                            customIcon: Image("LyricsRomaji").renderingMode(.template)) {
                settings.lyricsAnnotation = settings.lyricsAnnotation == .romaji ? .off : .romaji
            }
            .accessibilityValue(settings.lyricsAnnotation == .romaji ? "已显示" : "已隐藏")
            .accessibilityHint("切换罗马音的显示")
            .accessibilityIdentifier("iPadLyricsRomajiButton")
        }
        if hasLyricsTranslation {
            iPadPanelButton("translate", label: "歌词翻译",
                            selected: settings.showLyricsTranslation,
                            customIcon: Image("LyricsLanguages").renderingMode(.template)) {
                settings.showLyricsTranslation.toggle()
            }
            .accessibilityValue(settings.showLyricsTranslation ? "已显示" : "已隐藏")
            .accessibilityHint("切换歌词翻译的显示")
            .accessibilityIdentifier("iPadLyricsTranslationButton")
        }
    }

    private var hasLyricsRomaji: Bool {
        player.lyrics?.lines.contains { line in
            guard let romaji = line.romaji else { return false }
            return !romaji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } == true
    }

    private var hasLyricsTranslation: Bool {
        player.lyrics?.lines.contains { line in
            guard let translation = line.translation else { return false }
            return !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } == true
    }

    private func iPadPanelButton(_ icon: String, label: String, selected: Bool,
                                 customIcon: Image? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let customIcon {
                    customIcon.resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 20)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                }
            }
                .foregroundStyle(.white.opacity(selected ? 1 : 0.65))
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(selected ? 0.16 : 0))
                        .padding(3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .animation(reducePlayerMotion ? nil : .easeInOut(duration: 0.2), value: selected)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func playbackControlColumn(coverSize: CGFloat, columnWidth: CGFloat,
                                       spacing: SplitControlSpacing, transportHeight: CGFloat,
                                       largeMetadata: Bool, controlsWidth: CGFloat, metrics: ControlMetrics,
                                       onAddToPlaylist: (() -> Void)? = nil) -> some View {
        return VStack(spacing: 0) {
            artworkView(size: coverSize)
                .accessibilityIdentifier("splitPlayerArtwork")
                .padding(.bottom, spacing.artwork)
            VStack(spacing: 0) {
                NowPlayingTrackInfoRow(onOpenDestination: openTrackDestination,
                                       largeMetadata: largeMetadata, movesMoreToDeviceRow: true,
                                       showsMoreBesideFavorite: true,
                                       onAddToPlaylist: onAddToPlaylist)
                    .frame(height: iPadMetadataHeight)
                    .padding(.bottom, spacing.metadata)
                NowPlayingScrubber(showsRemainingTime: true, rowHeight: metrics.progressHeight,
                                   trackHeight: metrics.trackHeight, tint: playerAccent)
                    .padding(.bottom, spacing.progress)
                PlayerTransportControls(width: controlsWidth, height: transportHeight, tint: playerAccent)
                    .padding(.bottom, spacing.transport)
                volumeControl(rowHeight: metrics.volumeHeight, trackHeight: metrics.trackHeight)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: controlsWidth)
            Spacer(minLength: spacing.footer)
            HStack {
                CurrentPlaybackDeviceButton()
                    .layoutPriority(-1)
                Spacer(minLength: 0)
                playbackPanelButtons()
            }
            .frame(width: controlsWidth, height: 44)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("splitPlayerLeftFooter")
        }
        .frame(width: columnWidth)
    }

    private func volumeControl(rowHeight: CGFloat,
                               trackHeight: CGFloat = NowPlayingSliderStyle.trackHeight) -> some View {
        HStack(spacing: Theme.Spacing.control) {
            Image(systemName: "speaker.fill").font(.system(size: 13))
            #if os(iOS) && !targetEnvironment(simulator)
            IOSSystemVolumeSlider(trackHeight: trackHeight, showsLevelIcon: true).frame(height: rowHeight)
            #else
            // The simulator has no system volume route (MPVolumeView shows
            // "No Volume Available"), so drive the in-app gain there instead.
            PlayerSlider(fraction: Double(player.volume), trackHeight: trackHeight,
                         onChanged: { player.volume = Float($0) },
                         onEnded: { player.volume = Float($0) })
                .frame(height: rowHeight)
            PlayerVolumeIcon(volume: Double(player.volume))
            #endif
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(height: rowHeight)
    }

    private func desktopRegularLayout(size: CGSize) -> some View {
        iPadRegularLayout(size: size)
    }

    private func compactLayout(size: CGSize) -> some View {
        let width = max(0, min(size.width - 64, 420))
        let artworkDim = max(0, min(width, size.height - 420))
        let metrics = ControlMetrics(width: width)
        let showsContentPanel = showLyricsOnMobile || playlistTrack != nil || iPadPanel != .lyrics
        return VStack(spacing: Theme.Spacing.small) {
            if showsContentPanel {
                singleColumnTrackHeader(width: width)
                playbackContentPanel
                    .environment(\.nowPlayingFlushPanelEdges, true)
                    .frame(maxHeight: .infinity)
            } else {
                artworkView(size: artworkDim)
                    .frame(maxHeight: .infinity)
            }
            if !showsContentPanel {
                NowPlayingTrackInfoRow(onOpenDestination: openTrackDestination,
                                       largeMetadata: true, usesPortraitHeaderSizing: true,
                                       movesMoreToDeviceRow: true, showsMoreBesideFavorite: true,
                                       onAddToPlaylist: togglePlaylistPanel)
            }
            NowPlayingScrubber(showsRemainingTime: true, rowHeight: metrics.progressHeight,
                               trackHeight: metrics.trackHeight, tint: playerAccent)
                .frame(width: width)
            PlayerTransportControls(width: width, tint: playerAccent)
            volumeControl(rowHeight: metrics.volumeHeight, trackHeight: metrics.trackHeight)
            HStack {
                CurrentPlaybackDeviceButton(showsName: false)
                Spacer()
                playbackPanelButtons(singleColumn: true)
            }
        }
        .frame(width: width)
        .padding(.top, 34)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Views

    private func artworkView(size: CGFloat, cornerRadius: CGFloat? = nil) -> some View {
        Group {
            if let album = player.currentTrack?.album, album.id != 0, !album.name.isEmpty {
                Button {
                    openTrackDestination(.album(album.id))
                } label: {
                    artworkSurface(size: size, cornerRadius: cornerRadius)
                }
                .buttonStyle(.plain)
                .noFocusRing()
                .accessibilityLabel("打开专辑：\(album.name)")
            } else {
                artworkSurface(size: size, cornerRadius: cornerRadius)
            }
        }
    }

    private func artworkSurface(size: CGFloat, cornerRadius: CGFloat? = nil) -> some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.06))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                )
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .modifier(PlayerArtworkFrame(size: size, style: .detail, cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.45), radius: 36, y: 18)
        .animation(.easeIn(duration: 0.25), value: artworkImage != nil)
        .scaleEffect(player.isPlaying ? 1 : 0.95)
        .animation(AppAnimation.bouncy, value: player.isPlaying)
    }

    // MARK: - Lyrics column

    @ViewBuilder
    private var lyricsColumn: some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            AppleMusicLyricsColumn(lyrics: lyrics)
                .id(player.currentTrack?.id)
        } else if player.lyrics?.isInstrumental == true {
            VStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("纯音乐，请欣赏")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if player.lyrics != nil {
            Text("暂无歌词")
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: Theme.Spacing.control) {
                #if os(iOS)
                if player.lyricsLoadFailed {
                    Text("歌词加载失败")
                        .foregroundStyle(.white.opacity(0.6))
                    Button("重新加载") {
                        Task { await player.loadCurrentLyricsIfNeeded() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
                #else
                ProgressView().controlSize(.small).tint(.white)
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }


}


/// The main lyric line. Renders karaoke-style per-character highlighting from
/// verbatim (`yrc`) timings, driven live by the player, when the line is active
/// and verbatim data exists; otherwise a plain line.
///
/// Whether the line carries furigana is `LyricText`'s decision; the wipe is
/// handed down as per-character opacity so it reads the same either way.
struct LyricMainText: View {
    let line: LyricLine
    let isActive: Bool
    let size: CGFloat
    let weight: Font.Weight
    let verbatim: Bool
    var inactiveOpacity: Double = 0.45

    var body: some View {
        let words = line.words ?? []
        let karaoke = isActive && verbatim && !words.isEmpty
        // The same static typesetting owns row geometry in both modes. Per-
        // frame karaoke drawing is an overlay and cannot resize the scroll rows.
        LyricText(
            line: line, size: size, weight: weight,
            color: .white.opacity(isActive ? 1 : (verbatim ? min(inactiveOpacity, 0.25) : inactiveOpacity))
        )
        .opacity(karaoke ? 0 : 1)
        .overlay(alignment: .topLeading) {
            if karaoke {
                ActiveKaraokeLyricText(line: line, words: words, size: size, weight: weight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityRepresentation { Text(line.text.isEmpty ? "♪" : line.text) }
    }

    /// One opacity per character of `line.text`: sung characters are bright,
    /// the current one fades in, unsung stay dim.
    static func alphas(for line: LyricLine, words: [LyricWord], at time: TimeInterval) -> [Double] {
        let syllables = words.map {
            LyricSyllable(text: $0.text, startTime: $0.start, endTime: $0.end)
        }
        let timing = TimedLyricTextBuilder.attributes(from: syllables)
        let alphas = timing.map {
            let progress = LyricHighlightRevealProgress.progress(
                playbackTime: time, timing: $0, detectionMode: .character,
                durationThreshold: 0.95)
            return 0.28 + 0.72 * progress
        }
        let joined = words.map(\.text).joined()
        guard joined.count != line.text.count else { return alphas }
        let leading = joined.count - joined.drop(while: \.isWhitespace).count
        return Array(alphas.dropFirst(leading).prefix(line.text.count))
    }
}

private struct ActiveKaraokeLyricText: View {
    let line: LyricLine
    let words: [LyricWord]
    let size: CGFloat
    let weight: Font.Weight
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var cursor = PlayerService.shared.lyricsCursor
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.nowPlayingLyricsPresented) private var lyricsPresented

    private var allowsAnimation: Bool {
        #if os(iOS)
        // KaraokeLineView suspends on didEnterBackground and resumes on
        // didBecomeActive itself. On iPadOS 16 the scenePhase environment
        // inside the equatable lyric row stays `.background` after returning,
        // which froze the active line's wipe.
        return true
        #else
        // A visible Mac window keeps singing when another app takes focus.
        return scenePhase != .background
        #endif
    }

    var body: some View {
        // Native display-link drawing on iOS too: SwiftUI never receives a
        // playback tick or re-lays out LazyVStack during a karaoke wipe.
        KaraokeLyricLine(
            line: line, words: words, size: size, weight: weight,
            playing: lyricsPresented && player.isPlaying && windowVisibility.isVisible && allowsAnimation
        )
        .padding(-8) // Native drawing reserves room for glow and lifted ascenders.
        .id(cursor.seekRevision)
    }
}

// MARK: - Track info row

private struct NowPlayingTrackInfoRow: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.playlistPanelSelected) private var playlistPanelSelected
    @State private var showAddToPlaylist = false
    let onOpenDestination: (Destination) -> Void
    var metadataOnly = false
    var actionsOnly = false
    var largeMetadata = false
    var usesPortraitHeaderSizing = false
    var movesMoreToDeviceRow = false
    var showsMoreBesideFavorite = false
    var metadataWidth: CGFloat? = nil
    var onAddToPlaylist: (() -> Void)? = nil

    var body: some View {
        Group {
            if metadataOnly {
                metadata(alignment: .center, textAlignment: .center)
                    .padding(.horizontal, 48)
            } else if actionsOnly {
                if let track = player.currentTrack {
                    HStack {
                        favoriteButton(for: track)
                        Spacer()
                        NowPlayingTrackMoreMenu(track: track, onOpenDestination: onOpenDestination)
                    }
                }
            } else {
                HStack(spacing: Theme.Spacing.small) {
                    metadata(alignment: .leading, textAlignment: .leading)
                        .frame(width: metadataWidth, alignment: .leading)
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let track = player.currentTrack {
                        if movesMoreToDeviceRow {
                            addToPlaylistButton
                        }
                        favoriteButton(for: track)
                        if !movesMoreToDeviceRow || showsMoreBesideFavorite {
                            NowPlayingTrackMoreMenu(track: track, onOpenDestination: onOpenDestination)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
    }

    private func metadata(
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: usesPortraitHeaderSizing ? 2 : Theme.Spacing.tight) {
            HStack(spacing: 6) {
                Text(player.currentTrack?.name ?? "")
                    .font(usesPortraitHeaderSizing ? .title3.weight(.semibold) : (largeMetadata ? Theme.Typography.cardTitle : Theme.Typography.trackTitle))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            if let track = player.currentTrack {
                NowPlayingTrackDestinationLinks(
                    track: track,
                    font: usesPortraitHeaderSizing ? .title3 : Theme.Typography.secondary,
                    color: .white.opacity(0.62),
                    onOpenDestination: onOpenDestination
                )
            }
        }
        .multilineTextAlignment(textAlignment)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersiveTrackMetadata")
    }

    private var addToPlaylistButton: some View {
        Button {
            if let onAddToPlaylist { onAddToPlaylist() }
            else { showAddToPlaylist = true }
        } label: {
            Image("PlaylistAdd")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity((playlistPanelSelected || showAddToPlaylist) ? 0.16 : 0))
                        .padding(3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits((playlistPanelSelected || showAddToPlaylist) ? .isSelected : [])
        .accessibilityLabel("添加到歌单")
        .accessibilityIdentifier("iPadAddToPlaylistButton")
    }

    private func favoriteButton(for track: Track) -> some View {
        PlayerFavoriteButton(trackID: track.id, size: 22, side: 44, tint: .white)
            .accessibilityIdentifier("immersiveFavoriteButton")
    }
}

struct NowPlayingTrackMoreMenu: View {
    @EnvironmentObject private var player: PlayerService
    let track: Track
    var tint: Color = .white.opacity(0.88)
    var accessibilityID = "immersiveMoreMenu"
    var showsLyricsAdjustment = true
    var showsPlaybackControls = false
    var showsPlaybackPanels = false
    var usesPortraitStyle = true
    var onAddToPlaylist: (() -> Void)? = nil
    var onOpenDestination: ((Destination) -> Void)? = nil
    @EnvironmentObject private var account: AccountStore

    #if os(macOS)
    @EnvironmentObject private var settings: SettingsManager
    @State private var showsMorePopover = false
    #endif

    var body: some View {
        #if os(macOS)
        Button { showsMorePopover.toggle() } label: {
            moreButtonLabel
        }
        .buttonStyle(.pressable)
        .popover(isPresented: $showsMorePopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if showsPlaybackPanels {
                    Button {
                        player.activePanel = player.activePanel == .lyrics ? nil : .lyrics
                        showsMorePopover = false
                    } label: { Label("歌词", systemImage: "quote.bubble") }
                    Button {
                        settings.showDesktopLyrics.toggle()
                        showsMorePopover = false
                    } label: { Label("桌面歌词", systemImage: "inset.filled.bottomthird.square") }
                    Button {
                        player.activePanel = player.activePanel == .queue ? nil : .queue
                        showsMorePopover = false
                    } label: { Label("播放列表", systemImage: "list.bullet") }
                    .disabled(player.isFMMode)
                    Divider()
                }
                menuContents
            }
            .padding(12)
            .frame(width: 286)
            .buttonStyle(LyricsMoreMenuRowStyle())
            // Submenus reuse the row button style so they match the other rows.
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier(accessibilityID)
        #else
        Menu {
            menuContents
        } label: {
            moreButtonLabel
        }
        .menuOrder(.fixed)
        .tint(.white)
        .preferredColorScheme(.dark)
        .buttonStyle(.pressable)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier(accessibilityID)
        #endif
    }

    private var moreButtonLabel: some View {
        Image(systemName: "ellipsis")
            .font(usesPortraitStyle ? .title3.weight(.semibold) : .system(size: 22, weight: .medium))
            .foregroundStyle(usesPortraitStyle ? .white : tint)
            .frame(width: usesPortraitStyle ? 40 : 44, height: usesPortraitStyle ? 40 : 44)
            .contentShape(Circle())
    }

    @ViewBuilder
    private var menuContents: some View {
        if usesPortraitStyle {
            portraitMenuContents
        } else {
            standardMenuContents
        }
    }

    @ViewBuilder
    private var portraitMenuContents: some View {
        if showsPlaybackControls {
            playbackControls
            Divider()
        }
        LyricsSourceMenu()
        if showsLyricsAdjustment {
            lyricsTimingControls
        }
        #if os(iOS)
        Divider()
        SleepTimerMenu(player: player)
        #endif
        Divider()
        if track.album.id != 0 {
            let album = track.album
            Button { onOpenDestination?(.album(album.id)) } label: {
                Label("前往专辑：" + album.name, systemImage: "music.note.list")
            }
        }
        Menu {
            ForEach(track.artists.filter { $0.id != 0 }) { artist in
                Button(artist.name) { onOpenDestination?(.artist(artist.id)) }
            }
        } label: { Label("前往歌手", systemImage: "music.mic") }
        Divider()
        if let url = track.musicShareURL {
            ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
        }
        TrackDownloadActions(track: track, showsIcons: true)
    }

    @ViewBuilder
    private var standardMenuContents: some View {
        if showsPlaybackControls {
            playbackControls
            Divider()
        }
        Button {
            Platform.copyToPasteboard(string: track.musicShareURL?.absoluteString ?? "")
            ToastCenter.shared.show(String(localized: "链接已复制"))
            #if os(macOS)
            showsMorePopover = false
            #endif
        } label: {
            Label("复制链接", systemImage: "link")
        }

        #if os(iOS)
        Divider()
        SleepTimerMenu(player: player)
        #endif

        Divider()
        LyricsSourceMenu()
        if showsLyricsAdjustment {
            lyricsTimingControls
        }

        Divider()
        TrackDownloadActions(track: track, showsIcons: true)
    }

    @ViewBuilder
    private var playbackControls: some View {
        if player.isFMMode {
            Button { player.fmTrash() } label: {
                Label("不喜欢，换一首", systemImage: "trash")
            }
        } else {
            #if os(macOS)
            Button { player.cycleQueueOrder() } label: {
                Label(player.queueOrder.controlHelp, systemImage: player.queueOrder.symbolName)
            }
            #else
            Toggle(isOn: Binding(get: { player.shuffleEnabled }, set: { _ in player.toggleShuffle() })) {
                Label("随机播放", systemImage: "shuffle")
            }
            #endif
            Button { player.cycleRepeatMode() } label: {
                Label(player.repeatMode == .one ? "单曲循环" : (player.repeatMode == .off ? "循环关闭" : "列表循环"),
                      systemImage: player.repeatMode == .one ? "repeat.1" : "repeat")
            }
        }
        #if os(iOS)
        Button {
            player.activePanel = player.activePanel == .queue ? nil : .queue
        } label: {
            Label("播放列表", systemImage: "list.bullet")
        }
        .disabled(player.isFMMode)
        #endif
    }

    @ViewBuilder
    private var lyricsTimingControls: some View {
        #if os(iOS)
        if #available(iOS 16.4, *) {
            lyricsTimingButtons.menuActionDismissBehavior(.disabled)
        } else {
            lyricsTimingButtons
        }
        #else
        VStack(alignment: .leading, spacing: 10) {
            Text("歌词时间调节")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                timingButton("-0.2s", symbol: "arrow.left") {
                    player.adjustLyricsTiming(by: -2)
                }
                timingButton("还原", symbol: "arrow.counterclockwise") {
                    player.setLyricsTiming(steps: 0)
                }
                timingButton("+0.2s", symbol: "arrow.right") {
                    player.adjustLyricsTiming(by: 2)
                }
            }
        }
        .padding(.vertical, 4)
        .disabled(player.lyrics?.isEmpty != false || player.currentTrack?.id != track.id)
        #endif
    }

    #if os(macOS)
    private func timingButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .medium))
                    .frame(height: 25)
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(title)
    }
    #endif

    #if os(iOS)
    private var lyricsTimingButtons: some View {
        ControlGroup {
            Button {
                player.adjustLyricsTiming(by: -2)
            } label: {
                lyricsTimingLabel("-0.2s", image: "LyricsTimingEarlier")
            }
            .accessibilityLabel("歌词快了，延后零点二秒")

            Button {
                player.setLyricsTiming(steps: 0)
            } label: {
                lyricsTimingLabel("还原", image: "LyricsTimingReset")
            }
            .accessibilityLabel("还原歌词时间")

            Button {
                player.adjustLyricsTiming(by: 2)
            } label: {
                lyricsTimingLabel("+0.2s", image: "LyricsTimingLater")
            }
            .accessibilityLabel("歌词慢了，提前零点二秒")
        }
        .disabled(player.lyrics?.isEmpty != false || player.currentTrack?.id != track.id)
    }

    private func lyricsTimingLabel(_ title: String, image: String) -> some View {
        Label {
            Text(title)
                .font(.system(size: 12))
        } icon: {
            Image(image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.white)
        }
    }
    #endif

}


#if os(macOS)
private struct LyricsMoreMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
    }
}
#endif

// MARK: - Scrubber (white-on-dark variant)

struct NowPlayingScrubber: View {
    var showsRemainingTime = false
    var rowHeight: CGFloat = 44
    var trackHeight: CGFloat = NowPlayingSliderStyle.trackHeight
    var tint: Color = .white
    var showsQualityControl = true
    var alignsWithTrackSummary = false
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var dragDuration: TimeInterval = 0
    @State private var dragTrackID: Int?
    @State private var cancelledDuringGesture = false

    private var updatesContinuously: Bool {
        player.isPlaying && !player.isBuffering && !isDragging
            && windowVisibility.isVisible && scenePhase != .background
    }

    var body: some View {
        // Read the engine clock on the display schedule without publishing
        // per-frame playback updates to the rest of the player.
        TimelineView(.animation(paused: !updatesContinuously)) { _ in
            let duration = isDragging ? dragDuration : player.duration
            let position = isDragging ? dragProgress : player.livePlaybackTime
            let elapsed = position.isFinite ? max(position, 0) : clock.progress
            let fraction = duration.isFinite && duration > 0 ? min(elapsed / duration, 1) : 0
            scrubber(fraction: fraction, elapsed: elapsed)
        }
        .frame(height: rowHeight)
        // Keep quality controls outside the seek gesture's subtree.
        .overlay(alignment: .bottom) {
            if showsQualityControl {
                NowPlayingQualityControl()
                    .frame(width: 148, height: 24)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlayingProgress")
        .onChange(of: player.currentTrack?.id) { _ in
            if isDragging {
                cancelledDuringGesture = true
                cancelScrubbing()
            }
        }
        .onDisappear { cancelScrubbing() }
    }

    private func scrubber(fraction: Double, elapsed: TimeInterval) -> some View {
        GeometryReader { geo in
            VStack(spacing: 5) {
                PlayerSlider(fraction: fraction, fillColor: tint,
                             trackColor: tint.opacity(NowPlayingSliderStyle.trackOpacity),
                             trackHeight: trackHeight, onChanged: { value in
                    guard !cancelledDuringGesture else { return }
                    if !isDragging {
                        guard player.duration.isFinite, player.duration > 0 else { return }
                        dragDuration = player.duration
                        dragTrackID = player.currentTrack?.id
                        isDragging = true
                        player.isScrubbing = true
                    }
                    guard dragTrackID == player.currentTrack?.id else {
                        cancelledDuringGesture = true
                        cancelScrubbing()
                        return
                    }
                    dragProgress = value * dragDuration
                }, onEnded: { value in
                    if isDragging, dragTrackID == player.currentTrack?.id {
                        player.seek(to: value * dragDuration)
                    }
                    cancelScrubbing()
                    cancelledDuringGesture = false
                }, onCancelled: {
                    cancelScrubbing()
                    cancelledDuringGesture = false
                })
                .frame(height: 24)
                // The dock title is centered 9.5pt above the summary's midpoint.
                .offset(y: alignsWithTrackSummary ? -(16 + 3) / 2 : 0)

                if !alignsWithTrackSummary {
                    timeLabels(elapsed: elapsed)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay {
                if alignsWithTrackSummary {
                    // Match the dock's 18pt title + 3pt gap above its 16pt artist line.
                    timeLabels(elapsed: elapsed).offset(y: (18 + 3) / 2)
                }
            }
        }
    }

    private func timeLabels(elapsed: TimeInterval) -> some View {
        HStack {
            Text(Formatters.duration(elapsed))
                .accessibilityIdentifier("nowPlayingElapsedTime")
            Spacer()
            if showsRemainingTime {
                Text("−" + Formatters.duration(max(0, player.duration - elapsed)))
                    .accessibilityIdentifier("nowPlayingRemainingTime")
            } else {
                Text(Formatters.duration(player.duration))
            }
        }
        .font(Theme.Typography.caption.monospacedDigit())
        .foregroundStyle(tint.opacity(0.55))
    }

    private func cancelScrubbing() {
        guard isDragging else { return }
        isDragging = false
        dragTrackID = nil
        dragDuration = 0
        player.isScrubbing = false
    }


}

// MARK: - Mini lyrics (compact now-playing)


/// Shared by the iPad/iPhone detail controls and the desktop detail menu.
private struct LyricsSourceMenu: View {
    @EnvironmentObject private var player: PlayerService

    private var selectedSourceTitle: String {
        let mode = LyricsSource.saved(for: player.currentTrack?.id ?? 0)
        if mode == .automatic && player.lyricsSourceLoading { return "自动优选中…" }
        guard let source = player.resolvedLyricsSource else { return "" }
        let wordTimed = player.lyrics?.lines.contains { ($0.words?.count ?? 0) > 1 } == true
        let format = player.lyrics?.isInstrumental == true ? "纯音乐" : (wordTimed ? "逐字歌词" : "逐行歌词")
        return "当前：\(source.title) · \(format)"
    }

    var body: some View {
        Menu {
            ForEach(LyricsSource.allCases) { source in
                Button {
                    Task { await player.selectLyricsSource(source) }
                } label: {
                    if source == player.lyricsSource {
                        Label(source.title, systemImage: "checkmark")
                    } else {
                        Text(source.title)
                    }
                }
            }
            if !selectedSourceTitle.isEmpty {
                Divider()
                Text(selectedSourceTitle)
            }
        } label: {
            Label(player.lyricsSourceLoading ? "歌词来源（加载中…）" : "歌词来源", systemImage: "quote.bubble")
        }
        .disabled(player.currentTrack == nil)
        .accessibilityIdentifier("lyricsSourceMenu")
    }
}

#if os(iOS)
private struct PortraitControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif

private struct PlaylistPanelSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var playlistPanelSelected: Bool {
        get { self[PlaylistPanelSelectedKey.self] }
        set { self[PlaylistPanelSelectedKey.self] = newValue }
    }
}

#if os(macOS)
/// The player's top handle: click to close, or drag down to pull the player
/// away and release past the threshold to close it.
private struct DesktopPlayerHandle: View {
    let close: () -> Void
    @Environment(\.desktopNowPlayingDrag) private var drag
    @State private var isDragging = false
    @State private var isHovering = false

    var body: some View {
        Capsule().fill(.white.opacity(isDragging || isHovering ? 0.6 : 0.38))
            .frame(width: 44, height: NowPlayingSplitGeometry.handleHeight)
            .frame(width: 120, height: 24, alignment: .top)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: isDragging || isHovering)
            .onHover { isHovering = $0 }
            .gesture(
                // Global space: the surface moves under the pointer while dragging.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let moved = abs(value.translation.height) > 3 || abs(value.translation.width) > 3
                        guard isDragging || moved else { return }
                        isDragging = true
                        drag?.changed(value.translation.height)
                    }
                    .onEnded { value in
                        guard isDragging else {
                            close()
                            return
                        }
                        isDragging = false
                        let shouldClose = drag?.ended(value.translation.height,
                                                      value.predictedEndTranslation.height) ?? false
                        if shouldClose { close() }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("收起播放页")
            .accessibilityHint("向下拖动或点按以收起")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { close() }
    }
}
#endif
