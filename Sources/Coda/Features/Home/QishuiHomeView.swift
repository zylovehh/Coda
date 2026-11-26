import Combine
import SwiftUI
#if os(macOS)
import CoreGraphics
#endif

struct QishuiHomeView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var scenes = PanelResource<[QishuiListeningScene]>([])
    @StateObject private var charts = HomeViewModel.qishui
    @ObservedObject private var discovery = HomeDiscoveryModel.shared
    #if os(macOS)
    @State private var modeIcons: [String: CGImage] = [:]
    #endif
    private let layout = PhonePageLayout()

    var body: some View {
        ScenePreservingScrollView {
            LazyVStack(alignment: .leading, spacing: HomeLayout.sectionSpacing) {
                listeningModes
                HomeToplistsSection(model: charts, contentInset: layout.contentInset)
                HomeDiscoverySections(model: discovery, songRows: false)
                PlayerClearanceSpacer()
            }
            .pageHeaderTopPadding(layout.contentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appRootNavigationTitle(String(localized: "推荐"))
        #if os(macOS)
        .task {
            let icons = await ListeningModeIcons.thumbnails.value
            if !Task.isCancelled { modeIcons = icons }
        }
        #endif
        .panelRefresh(key: "qishuiHome") { force in
            #if os(macOS)
            // The restored account is published before its library finishes.
            // PanelRefresh restarts when the scope becomes available.
            guard account.offlineScope != nil else { return }
            #endif
            async let common: Void = loadScenes(force: force)
            async let rankings: Void = charts.load(loggedIn: account.isLoggedIn, force: force)
            await discovery.load(loggedIn: account.isLoggedIn, force: force)
            _ = await (common, rankings)
        }
    }

    /// Listening modes are personal feeds; the server rejects them without a session.
    private var scenesExpired: Bool {
        scenes.error == QishuiError.expiredLogin.errorDescription
    }

    @ViewBuilder
    private var listeningModes: some View {
        if !account.isLoggedIn || scenesExpired {
            HomeLoginPrompt(message: String(localized: "听歌模式会根据你的口味连续推荐，需登录后使用"),
                            expired: account.isLoggedIn && scenesExpired)
                .padding(.horizontal, layout.contentInset)
        } else {
            sceneGrid
        }
    }

    private var sceneGrid: some View {
        VStack(alignment: .leading, spacing: HomeLayout.headerSpacing) {
            #if os(macOS)
            QishuiSceneGrid(scenes: scenes.value.isEmpty ? QishuiListeningScene.preferences : scenes.value,
                            modeIcons: modeIcons)
            #else
            QishuiSceneGrid(scenes: scenes.value.isEmpty ? QishuiListeningScene.preferences : scenes.value)
            #endif

            if let error = scenes.error {
                ErrorStateView(message: error) { Task { await loadScenes(force: true) } }
            } else if scenes.isLoading && scenes.value.isEmpty {
                ProgressView("正在加载听歌模式")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(.horizontal, layout.contentInset)
    }

    private func loadScenes(force: Bool) async {
        guard account.isLoggedIn else { return }
        await scenes.load(lifetime: 900, force: force) {
            try await QishuiMusicAPI.shared.listeningScenes()
        }
    }
}

/// The listening-mode tiles. Kept apart from the page so playback state
/// changes re-render only this grid, and only when the selected or pending
/// scene actually changes — not on every PlayerService publish.
private struct QishuiSceneGrid: View {
    let scenes: [QishuiListeningScene]
    #if os(macOS)
    let modeIcons: [String: CGImage]
    #endif
    @State private var selectedMode: String?
    @State private var pendingMode: String?
    private let player = PlayerService.shared

    var body: some View {
        ListeningModeGrid {
            ForEach(scenes) { scene in
                ListeningModeTile(title: scene.title, icon: modeIcon(for: scene.mode),
                                  isSelected: scene.mode == selectedMode, isPending: scene.mode == pendingMode) {
                    player.playQishuiScene(scene)
                }
            }
        }
        .onReceive(player.$pendingQishuiScene.combineLatest(player.$source)
            .map { pending, source in Self.selection(pending: pending, source: source) }
            .removeDuplicates { $0 == $1 }) { selection in
            pendingMode = selection.pending
            selectedMode = selection.selected
        }
    }

    private static func selection(pending: QishuiListeningScene?, source: PlaySource) -> (pending: String?, selected: String?) {
        if let pending { return (pending.mode, pending.mode) }
        guard let feed = source.qishuiFeed else { return (nil, QishuiListeningScene.defaultRecommendation.mode) }
        if case .scene(let scene) = feed.kind { return (nil, scene.mode) }
        return (nil, nil)
    }

    private func modeIcon(for mode: String) -> Image {
        #if os(macOS)
        ListeningModeIcons.image(for: mode, in: modeIcons)
        #else
        ListeningModeIcons.image(for: mode)
        #endif
    }
}
