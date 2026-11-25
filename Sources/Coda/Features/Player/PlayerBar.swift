import SwiftUI

/// Window-owned chrome delegates all content and sizing to the shared dock.
#if os(macOS)
struct PlayerBar: View {
    var body: some View {
        DockedPlayerBar()
            .modifier(DesktopFloatingSurface())
            .modifier(NowPlayingZoomSourceReporter(cornerRadius: 26))
            .padding(.horizontal, Theme.Layout.playerBarHorizontalMargin)
            .padding(.bottom, Theme.Layout.playerBarBottomMargin)
    }
}

#endif

/// One row on Mac and iPad, fitted to the space remaining beside the sidebar.
private struct DockedPlayerBar: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        GeometryReader { proxy in
            let showsProgress = proxy.size.width >= Theme.Layout.playerBarProgressMinimumWidth
            HStack(spacing: Theme.Spacing.component) {
                trackSummary
                    .frame(maxWidth: showsProgress ? 180 : .infinity, alignment: .leading)
                if showsProgress {
                    ScrubberLane()
                        .frame(minWidth: 140, maxWidth: .infinity)
                        .disabled(!player.hasCurrentTrack)
                        .opacity(player.hasCurrentTrack ? 1 : 0.4)
                }
                controls(showsPanelControls: proxy.size.width >= 640)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
            .frame(width: proxy.size.width, height: Theme.Layout.playerBarHeight)
        }
        .frame(height: Theme.Layout.playerBarHeight)
        .accessibilityElement(children: .contain)
    }

    private var trackSummary: some View {
        Button {
            guard player.hasCurrentTrack else { return }
            #if os(iOS)
            if #available(iOS 18.0, *) {
                player.showNowPlaying = true
            } else {
                withAnimation(AppAnimation.smooth) { player.showNowPlaying = true }
            }
            #else
            withAnimation(AppAnimation.smooth) { player.showNowPlaying = true }
            #endif
        } label: {
            HStack(spacing: Theme.Spacing.control) {
                CachedAsyncImage(url: player.currentTrack?.album.picUrl?.resizedImageURL(128))
                    .modifier(PlayerArtworkFrame(size: 40, style: .dock))
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentTrack?.name ?? String(localized: "未在播放"))
                        .font(Theme.Typography.trackTitle)
                        .frame(height: 18)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(player.currentTrack?.artistNames ?? "Coda")
                        .font(Theme.Typography.secondary)
                        .frame(height: 16)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开完整播放器")
        .accessibilityIdentifier("iPadOpenNowPlaying")
    }

    private func controls(showsPanelControls: Bool) -> some View {
        HStack(spacing: 0) {
            favoriteButton
            PlayerTransportButton(icon: "backward.fill", label: "上一首", size: 24,
                                  width: 44, tint: .primary, height: 44,
                                  disabled: player.isFMMode, action: player.previous)
            PlayerPlayPauseButton(isPlaying: player.isPlaying, isLoading: player.showsPlaybackLoading,
                                  size: 26, width: 44, tint: .primary, height: 44,
                                  action: player.togglePlayPause)
                .accessibilityIdentifier("iPadPlayPauseButton")
            PlayerTransportButton(icon: "forward.fill", label: "下一首", size: 24,
                                  width: 44, tint: .primary, height: 44, action: player.next)
            CurrentPlaybackDeviceButton(showsName: false, tint: .primary)
            #if os(macOS)
            VolumeControl(controlWidth: 44)
            if showsPanelControls {
                PlayerTransportButton(icon: "quote.bubble", label: "歌词", size: 19,
                                      width: 44, tint: .primary, height: 44,
                                      active: player.activePanel == .lyrics) {
                    player.activePanel = player.activePanel == .lyrics ? nil : .lyrics
                }
                PlayerTransportButton(icon: "inset.filled.bottomthird.square", label: "桌面歌词", size: 19,
                                      width: 44, tint: .primary, height: 44,
                                      active: settings.showDesktopLyrics) {
                    settings.showDesktopLyrics.toggle()
                }
                PlayerTransportButton(icon: "list.bullet", label: "播放列表", size: 19,
                                      width: 44, tint: .primary, height: 44,
                                      active: player.activePanel == .queue, disabled: player.isFMMode) {
                    player.activePanel = player.activePanel == .queue ? nil : .queue
                }
            }
            #endif
            if let track = player.currentTrack {
                NowPlayingTrackMoreMenu(track: track, tint: .primary,
                                        accessibilityID: "iPadDockMoreMenu", showsLyricsAdjustment: false,
                                        showsPlaybackControls: true, showsPlaybackPanels: !showsPanelControls)
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .disabled(!player.hasCurrentTrack)
        .opacity(player.hasCurrentTrack ? 1 : 0.4)
    }

    private var favoriteButton: some View {
        PlayerFavoriteButton(trackID: player.currentTrack?.id, size: 22, side: 44)
    }
}

// MARK: - Icon button
#if os(macOS)

/// How the one queue-order control presents each state. Here rather than on
/// the enum itself so `QueueOrder` stays a pure Core type: three transports
/// (this bar, the now-playing page, the Dock menu) read the same two answers.
extension QueueOrder {
    /// `wand.and.stars` for AutoMix: it reads as "smart shuffle" next to the
    /// plain `shuffle` arrows, and the accent tint the button applies to any
    /// non-listed state carries the rest.
    var symbolName: String {
        switch self {
        case .listed, .shuffled: return "shuffle"
        case .autoMix: return "wand.and.stars"
        }
    }

    /// Tooltip / menu wording for the state the control is *in*.
    var controlHelp: LocalizedStringKey {
        switch self {
        case .listed, .shuffled: return "随机播放"
        case .autoMix: return "AutoMix 顺序"
        }
    }

    /// The Dock menu names all three states — it is a list of them rather than
    /// a button standing in one, so `listed` gets a word of its own.
    var menuTitle: String {
        switch self {
        case .listed: return String(localized: "列表顺序")
        case .shuffled: return String(localized: "随机播放")
        case .autoMix: return String(localized: "AutoMix 顺序")
        }
    }
}
#endif

struct PlayerIconButton: View {
    let icon: String
    var size: CGFloat = 14
    var isActive = false
    var disabled = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Group {
                if icon == "heart" || icon == "heart.fill" {
                    PlayerHeartIcon(liked: icon == "heart.fill", size: size)
                } else {
                    Image(systemName: icon)
                        .modifier(PlayerSymbolTransition(symbol: icon))
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                }
            }
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
    }

    private var backgroundColor: Color {
        let base: Color = colorScheme == .dark ? .white : .black
        if isHovering, !disabled { return base.opacity(0.08) }
        if isActive { return base.opacity(0.05) }
        return .clear
    }
}

/// Shared favorite glyph for song rows, the full player and playback controls.
struct PlayerHeartIcon: View {
    let liked: Bool
    var size: CGFloat = 22
    var tint: Color = .primary
    var feedbackTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image(systemName: "heart")
                .opacity(liked ? 0 : 1)
            Image(systemName: "heart.fill")
                .foregroundStyle(Color(red: 1, green: 59 / 255.0, blue: 48 / 255.0))
                .opacity(liked ? 1 : 0)
        }
        .font(.system(size: size, weight: .regular))
        .foregroundStyle(tint)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: liked)
        .modifier(PlayerSymbolBounce(trigger: feedbackTrigger))
        .accessibilityHidden(true)
    }
}

/// Keep animation identity with the song; optimistic state changes only fade.
/// A single bounce confirms a completed favorite request from this button.
struct PlayerFavoriteButton: View {
    let trackID: Int?
    var size: CGFloat = 22
    var side: CGFloat = 44
    var tint: Color = .primary

    var body: some View {
        PlayerFavoriteButtonBody(trackID: trackID, size: size, side: side, tint: tint)
            .id(trackID)
    }
}

private struct PlayerFavoriteButtonBody: View {
    let trackID: Int?
    let size: CGFloat
    let side: CGFloat
    let tint: Color
    @EnvironmentObject private var account: AccountStore
    @State private var feedbackTrigger = 0
    @State private var isUpdating = false

    var body: some View {
        let liked = trackID.map { account.isLiked($0) } ?? false
        Button {
            guard let trackID, !isUpdating else { return }
            let session = account.sessionRevision
            isUpdating = true
            Task { @MainActor in
                defer { isUpdating = false }
                await account.toggleLike(trackID: trackID)
                if !liked, account.sessionRevision == session, account.isLiked(trackID) {
                    feedbackTrigger += 1
                }
            }
        } label: {
            PlayerHeartIcon(liked: liked, size: size, tint: tint, feedbackTrigger: feedbackTrigger)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(trackID == nil || !account.provider.supportsFavoriteChanges)
        .accessibilityLabel(liked ? "取消喜欢" : "喜欢")
        .accessibilityValue(liked ? "已喜欢" : "未喜欢")
        .help(liked ? String(localized: "取消喜欢") : String(localized: "喜欢"))
    }
}

// MARK: - Like button

struct LikeButton: View {
    let trackID: Int
    var size: CGFloat = 13

    var body: some View {
        PlayerFavoriteButton(trackID: trackID, size: size, side: 26)
    }
}

// MARK: - Scrubber

/// Reuse the detail player's rail, time layout and seek handling on the dock.
struct ScrubberLane: View {
    var body: some View {
        NowPlayingScrubber(showsRemainingTime: true, tint: .primary, showsQualityControl: false, alignsWithTrackSummary: true)
            .frame(maxWidth: 460)
    }
}

/// The system-volume adapter supplies its observed level on iOS.
struct PlayerVolumeIcon: View {
    let volume: Double
    var size: CGFloat = 15

    private var symbol: String {
        switch volume {
        case ...0.001: return "speaker.slash.fill"
        case ..<0.35: return "speaker.wave.1.fill"
        case ..<0.7: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .modifier(PlayerSymbolTransition(symbol: symbol))
            .frame(width: 22)
            .accessibilityHidden(true)
    }
}

// MARK: - Volume

struct VolumeControl: View {
    var controlWidth: CGFloat = 26
    @EnvironmentObject private var player: PlayerService
    @State private var showPopover = false

    var body: some View {
        Group {
            if controlWidth == 44 {
                PlayerTransportButton(icon: volumeIcon, label: "音量", size: 19,
                                      width: 44, tint: .primary, height: 44) {
                    showPopover.toggle()
                }
            } else {
                PlayerIconButton(icon: volumeIcon, size: 13) { showPopover.toggle() }
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VolumeSlider()
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
        }
        .help("音量")
    }

    private var volumeIcon: String {
        switch player.volume {
        case 0: return "speaker.slash"
        case ..<0.4: return "speaker.wave.1"
        case ..<0.75: return "speaker.wave.2"
        default: return "speaker.wave.3"
        }
    }
}

struct VolumeSlider: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        PlayerSlider(
            fraction: Double(player.volume), axis: .vertical, fillColor: .primary,
            trackColor: .primary.opacity(NowPlayingSliderStyle.trackOpacity),
            onChanged: { player.volume = Float($0) },
            onEnded: { player.volume = Float($0) }
        )
        .frame(width: 22, height: 110)
    }

}

#if os(iOS)
/// Align the window-owned dock with the detail column without making the
/// navigation hierarchy observe every split-view geometry update.
struct IPadMainColumnPlayerBar: View {
    @ObservedObject var geometry: MainColumnGeometry

    var body: some View {
        Group {
            // A zero-width proposal still lets the fixed-size transport
            // buttons draw outside the window during the first scene layout.
            if geometry.layout.width > 0 {
                IPadDockedPlayerBar()
                    // Preserve artwork and native controls across rotation;
                    // changing identity on every width update flashes the dock.
                    .transaction { $0.animation = nil }
                    .padding(.horizontal, Theme.Layout.iPadPlayerBarHorizontalMargin)
                    .padding(.bottom, Theme.Layout.iPadPlayerBarBottomMargin)
                    .frame(width: geometry.layout.width)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// Same shape and contrast rules on supported iPadOS versions; the OS only
/// changes the material implementation.
struct IPadFloatingSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Layout.iPadChromeCornerRadius, style: .continuous)
        // Sidebar, back button and dock all float over the page.
        content
            .blocksTouchPassThrough(in: shape)
            .modifier(FloatingGlassSurface(shape: shape))
    }
}

/// A floating playback surface shared by all iPad destinations.
struct IPadDockedPlayerBar: View {
    @Environment(\.nowPlayingTransitionNamespace) private var transitionNamespace

    var body: some View {
        DockedPlayerBar()
            .modifier(IPadFloatingSurface())
            .nowPlayingTransitionSource(in: transitionNamespace)
            .accessibilityIdentifier("iPadPlayerDock")
    }
}

#endif

/// One transport row for iPhone and iPad, in either orientation.
struct PlayerTransportControls: View {
    @EnvironmentObject private var player: PlayerService
    let width: CGFloat
    var height: CGFloat = 64
    /// 按钮颜色；默认白色（悬浮播放条）。播放页传封面主色进来。
    var tint: Color = PlayerControlAppearance.tint

    private var glyphScale: CGFloat { min(1, width / 280) }

    private var orderIcon: String {
        #if os(macOS)
        player.queueOrder.symbolName
        #else
        "shuffle"
        #endif
    }

    private var orderActive: Bool {
        #if os(macOS)
        player.queueOrder != .listed
        #else
        player.shuffleEnabled
        #endif
    }

    private func cycleOrder() {
        #if os(macOS)
        player.cycleQueueOrder()
        #else
        player.toggleShuffle()
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            PlayerTransportButton(
                icon: player.isFMMode ? "trash" : orderIcon,
                label: player.isFMMode ? "不喜欢" : "随机播放",
                size: 17 * glyphScale, width: width / 5, tint: tint, height: height,
                active: !player.isFMMode && orderActive
            ) {
                if player.isFMMode { player.fmTrash() } else { cycleOrder() }
            }
            PlayerTransportButton(icon: "backward.fill", label: "上一首", size: 28 * glyphScale,
                                  width: width / 5, tint: tint, height: height, disabled: player.isFMMode, action: player.previous)
            PlayerPlayPauseButton(isPlaying: player.isPlaying, isLoading: player.showsPlaybackLoading,
                                  size: 40 * glyphScale, width: width / 5, tint: tint, height: height,
                                  action: player.togglePlayPause)
                .accessibilityIdentifier("iPadPlayPauseButton")
            PlayerTransportButton(icon: "forward.fill", label: "下一首", size: 28 * glyphScale,
                                  width: width / 5, tint: tint, height: height, action: player.next)
            PlayerTransportButton(icon: player.repeatMode == .one ? "repeat.1" : "repeat",
                                  label: "循环模式", size: 17 * glyphScale, width: width / 5, tint: tint, height: height,
                                  active: player.repeatMode != .off, disabled: player.isFMMode,
                                  action: player.cycleRepeatMode)
        }
    }
}

enum PlayerControlAppearance {
    static let tint: Color = .white
    static let barTint: Color = .primary
}

/// Shared transport appearance for full and docked playback controls.
struct PlayerTransportButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 28
    let width: CGFloat
    var tint: Color = PlayerControlAppearance.tint
    var height: CGFloat = 64
    var active = false
    var disabled = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .modifier(PlayerSymbolTransition(symbol: icon))
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: width, height: height)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(active ? 0.14 : 0))
                        .frame(width: min(width, size + 16), height: min(height, size + 12))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerTransportButtonStyle(diameter: min(width, height, size + 16), tint: tint))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: active)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(Text(label))
        .accessibilityValue(active ? "已开启" : "")
    }
}

struct PlayerPlayPauseButton: View {
    let isPlaying: Bool
    let isLoading: Bool
    var size: CGFloat = 40
    let width: CGFloat
    var tint: Color = PlayerControlAppearance.tint
    var height: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView().tint(tint)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: size, weight: .semibold))
                        .modifier(PlayerSymbolTransition(symbol: isPlaying ? "pause.fill" : "play.fill"))
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .foregroundStyle(tint)
        }
        .buttonStyle(PlayerTransportButtonStyle(diameter: min(width, height, size + 16), tint: tint))
        .accessibilityLabel(isLoading ? "正在加载" : (isPlaying ? "暂停" : "播放"))
    }
}
