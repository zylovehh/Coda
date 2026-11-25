import Combine
import SwiftUI

extension Notification.Name {
    static let showDownloadedMusic = Notification.Name("Coda.showDownloadedMusic")
    static let showSettings = Notification.Name("Coda.showSettings")
}

private struct OpenLoginKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct PopDestinationKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct OpenDestinationKey: EnvironmentKey {
    static let defaultValue: (Destination) -> Void = { _ in }
}

extension EnvironmentValues {
    var popDestination: (() -> Void)? {
        get { self[PopDestinationKey.self] }
        set { self[PopDestinationKey.self] = newValue }
    }

    var openLogin: () -> Void {
        get { self[OpenLoginKey.self] }
        set { self[OpenLoginKey.self] = newValue }
    }

    var openDestination: (Destination) -> Void {
        get { self[OpenDestinationKey.self] }
        set { self[OpenDestinationKey.self] = newValue }
    }
}

struct PlayerChromeModifier: ViewModifier {
    @Environment(\.compactWindowLayout) private var compactWindowLayout
    @EnvironmentObject private var player: PlayerService
    let geometry: MainColumnGeometry

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .overlay(alignment: .bottomTrailing) {
                if !compactWindowLayout { MainColumnPlayerBar(geometry: geometry) }
            }
            #endif
            .overlay(alignment: .trailing) {
                rightPanel
            }
            .animation(AppAnimation.standard, value: player.activePanel)
    }

    @ViewBuilder
    private var rightPanel: some View {
        if let panel = player.activePanel {
            Group {
                switch panel {
                case .lyrics:
                    LyricsPanel()
                case .queue:
                    QueuePanel()
                }
            }
            .padding(.top, 12)
            .padding(.bottom, Theme.Layout.playerChromeClearance + 10)
            .padding(.trailing, 16)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

#if os(macOS)
private struct MainColumnPlayerBar: View {
    @ObservedObject var geometry: MainColumnGeometry

    var body: some View {
        if geometry.layout.width > 0 {
            PlayerBar().frame(width: geometry.layout.width)
        }
    }
}

#endif

enum SidebarItem: Hashable {
    case downloaded
    case home
    case fm
    case search
    case account
    case settings
    case likedSongs
    case daily
    case recents
    case collections
    case cloud
    case playlist(Int)
    case localPlaylist(UUID)
}

enum Destination: Hashable {
    case sidebar(SidebarItem)
    case downloaded, downloadTasks
    case openSourceLicenses
    #if os(macOS)
    case shortcuts
    #endif
    case playlist(Int)
    case localPlaylist(UUID)
    case radarPlaylist(Int)
    case album(Int)
    case artist(Int)
    case artistSection(Int, ArtistSection)
    case daily
    case toplists
    case newAlbums
    case recommendedArtists
    case homeRecommendation(HomeRecommendationPage)
    case recents
    case playRanking
    case collections
    case librarySection(LibrarySection)
    case cloud
    case search(String)
    case qqBrowse(QQMusicBrowseKind)
    case exploreCategory(String)
}

extension Destination {
    /// Only an explicit sidebar route replaces the selected root. Page links
    /// keep their own history, even when the sidebar has an equivalent entry.
    var sidebarRoot: SidebarItem? {
        guard case .sidebar(let item) = self else { return nil }
        return item
    }
}

extension Array where Element == Destination {
    mutating func appendIfNotCurrent(_ destination: Destination) {
        guard last != destination else { return }
        append(destination)
    }
}

/// Registers all shared navigation destinations on a stack.
struct DestinationsModifier: ViewModifier {
    @Environment(\.compactWindowLayout) private var compactWindowLayout
    @EnvironmentObject private var account: AccountStore
    #if os(iOS)
    @Environment(\.sceneScrollPage) private var scrollPage
    @Environment(\.mainColumnGeometry) private var mainColumnGeometry
    @Environment(\.iPadChrome) private var iPadChrome
    #endif

    func body(content: Content) -> some View {
        content.navigationDestination(for: Destination.self) { destination in
            sizedDestinationView(for: destination)
                .id(destination)
                #if os(iOS)
                .environment(\.sceneScrollPage, .init(section: scrollPage?.section ?? .home,
                                                    path: [destination]))
                #endif
                .playerContentInset()
                .appNavigationBarBackground()
        }
    }

    @ViewBuilder
    private func sizedDestinationView(for destination: Destination) -> some View {
        if compactWindowLayout {
            destinationView(for: destination)
                .navigationBarBackButtonHidden(false)
        } else {
        #if os(iOS)
        if let mainColumnGeometry, iPadChrome == .legacy {
            destinationView(for: destination)
                .iPadDestinationBackButton()
                .legacyIPadContentClearance(geometry: mainColumnGeometry)
        } else if let mainColumnGeometry {
            // Pushed pages need their own subscription: NavigationStack can
            // retain the environment captured when the destination was pushed.
            IPadDetailColumnContent(geometry: mainColumnGeometry) {
                destinationView(for: destination)
                    .iPadDestinationBackButton()
            }
        } else {
            destinationView(for: destination)
                .iPadDestinationBackButton()
        }
        #else
        destinationView(for: destination)
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .top, alignment: .leading, spacing: 12) {
                DesktopDestinationBackButton()
                    .padding(.leading, 20)
            }
            .desktopContentClearance()
        #endif
        }
    }

    @ViewBuilder
    private func destinationView(for destination: Destination) -> some View {
        switch destination {
        case .sidebar(let item):
            SidebarDestinationView(item: item)
        case .downloaded:
            DownloadedMusicView()
        case .downloadTasks:
            DownloadTasksView()
        case .openSourceLicenses:
            OpenSourceLicensesView()
        #if os(macOS)
        case .shortcuts:
            ShortcutSettingsView()
        #endif
        case .playlist(let id):
            PlaylistDetailView(playlistID: id, isLikedList: id == account.likedSongsPlaylist?.id)
        case .localPlaylist(let id):
            LocalPlaylistDetailView(playlistID: id)
        case .radarPlaylist(let id):
            PlaylistDetailView(playlistID: id, recommendationContext: .radar)
        case .album(let id):
            AlbumDetailView(albumID: id)
        case .artist(let id):
            ArtistDetailView(artistID: id)
        case .artistSection(let id, let section):
            ArtistSectionView(artistID: id, section: section)
        case .daily:
            DailySongsView()
        case .toplists:
            ToplistsView()
        case .newAlbums:
            HomeBrowseView(kind: .albums)
        case .recommendedArtists:
            HomeBrowseView(kind: .artists)
        case .homeRecommendation(let page):
            HomeRecommendationPageView(page: page)
        case .recents:
            RecentsView()
        case .playRanking:
            AccountDetailsView(rankingOnly: true)
        case .collections:
            CollectionsView()
        case .librarySection(let section):
            LibrarySectionView(section: section)
        case .cloud:
            CloudView()
        case .search(let query):
            SearchView(query: query)
        case .qqBrowse(let kind):
            QQMusicBrowseView(kind: kind)
        case .exploreCategory(let category):
            ExploreCategoryView(category: category)
        }
    }
}

extension View {
    func desktopContentClearance() -> some View {
        #if os(macOS)
        modifier(DesktopContentClearance())
        #else
        self
        #endif
    }

    /// Legacy iPad's canvas owns the shared top edge beside the sidebar.
    func pageHeaderTopPadding(_ defaultPadding: CGFloat) -> some View {
        #if os(iOS)
        modifier(PageHeaderTopPadding(defaultPadding: defaultPadding))
        #else
        // Desktop's shared column owns the first content edge.
        self
        #endif
    }

    func legacyIPadContentClearance(geometry: MainColumnGeometry) -> some View {
        #if os(iOS)
        modifier(LegacyIPadContentClearance(geometry: geometry))
        #else
        self
        #endif
    }

    @ViewBuilder
    fileprivate func iPadDestinationBackButton() -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            safeAreaInset(edge: .top, alignment: .leading, spacing: 12) {
                IPadDestinationBackButton()
                    .padding(.leading, 20)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    func playerChrome(geometry: MainColumnGeometry) -> some View {
        modifier(PlayerChromeModifier(geometry: geometry))
    }

    /// Reserve the dock inside each destination; a split-view-level inset can
    /// be lost on pushes on iPadOS 16. Keep the scroll viewport full-height so
    /// the translucent dock can blur the content passing behind it.
    @ViewBuilder
    func playerContentInset() -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            modifier(IPadPlayerContentInset())
        } else {
            self
        }
        #else
        // The macOS floating bar and legacy iPhone chrome use explicit trailing
        // PlayerClearanceSpacer content instead.
        self
        #endif
    }

    func appDestinations() -> some View {
        appNavigationBarBackground()
            .modifier(DestinationsModifier())
    }
}

#if os(iOS)
private struct PageHeaderTopPadding: ViewModifier {
    var phoneLayout = PhonePageLayout()
    let defaultPadding: CGFloat
    @Environment(\.iPadChrome) private var chrome

    func body(content: Content) -> some View {
        content.padding(.top, UIDevice.current.userInterfaceIdiom == .pad && !phoneLayout.isEnabled && chrome == .legacy
                        ? 0 : defaultPadding)
    }
}

private struct IPadPlayerContentInset: ViewModifier {
    @Environment(\.compactWindowLayout) private var compactWindowLayout
    @Environment(\.iPadChrome) private var chrome

    @ViewBuilder
    func body(content: Content) -> some View {
        if compactWindowLayout {
            content
        } else if chrome == .legacy {
            content.padding(.bottom, Theme.Layout.iPadPlayerChromeClearance)
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: Theme.Layout.iPadPlayerChromeClearance)
            }
        }
    }
}

/// Apply to every navigation destination, rather than to NavigationStack:
/// iPadOS 16 does not reliably forward stack-level safe areas after pushes.
private struct LegacyIPadContentClearance: ViewModifier {
    @Environment(\.compactWindowLayout) private var compactWindowLayout
    @ObservedObject var geometry: MainColumnGeometry
    @Environment(\.iPadChrome) private var chrome
    @Environment(\.legacyIPadSystemInsets) private var systemInsets
    @Environment(\.legacyIPadKeyboardOverlap) private var keyboardOverlap

    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad, chrome == .legacy, !compactWindowLayout {
            content
                .environment(\.musicLibraryContentWidth, geometry.layout.width)
                // Explicit proposals avoid iPadOS 16 centering the search
                // header above the window when nested safe-area insets shrink.
                .padding(.top, systemInsets.top + SidebarLayout.outerInset)
                .padding(.bottom, systemInsets.bottom + keyboardOverlap)
                .padding(.leading, geometry.layout.leadingInset)
                .background(LegacyIPadHostingSafeAreaProbe())
        } else {
            content
        }
    }
}

/// A compact floating control shares the sidebar and player surface on pushed pages.
private struct IPadDestinationBackButton: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.popDestination) private var popDestination

    var body: some View {
        Button {
            if let popDestination { popDestination() }
            else { dismiss() }
        } label: {
            Image(systemName: "chevron.backward")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .modifier(IPadFloatingSurface())
        .accessibilityLabel("返回")
        .accessibilityIdentifier("iPad.destination.back")
    }
}

#endif

/// The two playback facts page chrome depends on. Observing PlayerService
/// itself would rebuild every page's spacer and toolbar on each progress tick.
@MainActor
final class PlayerChromeState: ObservableObject {
    static let shared = PlayerChromeState()
    @Published private(set) var hasCurrentTrack: Bool
    @Published private(set) var showNowPlaying: Bool

    private init() {
        let player = PlayerService.shared
        hasCurrentTrack = player.hasCurrentTrack
        showNowPlaying = player.showNowPlaying
        player.$currentTrack.map { $0 != nil }.removeDuplicates()
            .assign(to: &$hasCurrentTrack)
        player.$showNowPlaying.removeDuplicates()
            .assign(to: &$showNowPlaying)
    }
}

/// Trailing spacer for scrollable pages so the last row clears the
/// floating player bar.
struct PlayerClearanceSpacer: View {
    @Environment(\.compactWindowLayout) private var compactWindowLayout
    @ObservedObject private var player = PlayerChromeState.shared

    var body: some View {
        if compactWindowLayout {
            Color.clear.frame(height: Theme.Layout.scrollBreathingMargin)
        } else {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            Color.clear.frame(height: Theme.Layout.scrollBreathingMargin)
        } else if #available(iOS 26.0, *) {
            // On iOS 26+, the native TabView bottom accessory automatically
            // expands the content safe area insets; keep only the breathing margin.
            Color.clear.frame(height: Theme.Layout.scrollBreathingMargin)
        } else {
            // On iOS < 26, customTabInterface floats above content and requires
            // explicit bottom clearance.
            Color.clear.frame(
                height: player.hasCurrentTrack
                    ? Theme.Layout.FloatingChrome.fullChromeClearance
                    : Theme.Layout.FloatingChrome.tabBarClearance
            )
        }
        #else
        Color.clear.frame(
            height: Theme.Layout.playerChromeClearance + Theme.Layout.scrollBreathingMargin
        )
        #endif
        }
    }
}

#if os(macOS)
enum DesktopChromeLayout {
    // Wide content extends under the transparent titlebar. Reserve its native
    // window-button row plus the floating surfaces' usual outer margin so the
    // sidebar and page begin together below the traffic lights.
    static let topInset: CGFloat = 30 + SidebarLayout.outerInset
}

private struct DesktopContentClearance: ViewModifier {
    @Environment(\.compactWindowLayout) private var compactWindowLayout
    @Environment(\.mainColumnGeometry) private var geometry

    func body(content: Content) -> some View {
        if compactWindowLayout {
            content
        } else if let geometry {
            DesktopColumnContent(geometry: geometry) { content }
        } else {
            content
        }
    }
}

private struct DesktopColumnContent<Content: View>: View {
    @ObservedObject var geometry: MainColumnGeometry
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.musicLibraryContentWidth, geometry.layout.width)
            .contentMargins(.top, 0, for: .scrollContent)
            .padding(.leading, geometry.layout.leadingInset)
            .padding(.top, DesktopChromeLayout.topInset)
    }
}

struct DesktopFloatingSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(FloatingGlassSurface(
            shape: RoundedRectangle(cornerRadius: 26, style: .continuous)))
    }
}

private struct DesktopDestinationBackButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.backward")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .modifier(DesktopFloatingSurface())
        .accessibilityLabel("返回")
    }
}
#endif
