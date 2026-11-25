import SwiftUI

struct MainWindow: View {
    private let externalPath: Binding<[Destination]>?
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @State private var destinationAfterPlayerDismissal: Destination?
#endif
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.nowPlayingTransitionNamespace) private var compactPlayerNamespace
    @Environment(\.iPadChrome) private var iPadChrome
    @Environment(\.legacyIPadSystemInsets) private var legacySystemInsets
    @Environment(\.legacyIPadKeyboardOverlap) private var legacyKeyboardOverlap
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // App-switcher snapshots can temporarily propose a compact size class.
    // Letting the split view adapt then destroys the entire detail subtree.
    // Real foreground multitasking changes must still adapt normally.
    @State private var activeSizeClass: UserInterfaceSizeClass?
    @StateObject private var scrollPositions = SceneScrollPositionStore()
    @State private var viewportSize = SceneViewportSize()
    @State private var compactPageBackground: Color?
    #endif
    #if os(macOS)
    // Observe only the chrome flags. Every other PlayerService change (queue,
    // buffering, lyrics, quality) would otherwise re-render the window and
    // re-diff the whole hosted navigation tree.
    @ObservedObject private var playerChrome = PlayerChromeState.shared
    private var player: PlayerService { PlayerService.shared }
    private var showNowPlayingBinding: Binding<Bool> {
        Binding(get: { PlayerService.shared.showNowPlaying },
                set: { PlayerService.shared.showNowPlaying = $0 })
    }
    #else
    @EnvironmentObject private var player: PlayerService
    #endif
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var toasts: ToastCenter

    #if os(macOS)
    @StateObject private var artworkStore = NowPlayingArtworkStore()
    @State private var browsingViewportSize: CGSize?
    #else
    @EnvironmentObject private var artworkStore: NowPlayingArtworkStore
    #endif
    @State private var compactWindowLayout = false
    @State private var compactLibraryVisible = false
    @State private var selection: SidebarItem = .home
    @State private var sidebarSearchFocusRequested = false
    @State private var localPath: [Destination] = []
    @State private var showLogin = false
    @State private var mainColumnGeometry = MainColumnGeometry()

    init(path: Binding<[Destination]>? = nil) {
        externalPath = path
    }

    private var path: [Destination] {
        get { externalPath?.wrappedValue ?? localPath }
        nonmutating set {
            if let externalPath {
                externalPath.wrappedValue = newValue
            } else {
                localPath = newValue
            }
        }
    }

    private var pathBinding: Binding<[Destination]> {
        externalPath ?? $localPath
    }

    private var sidebarSelection: Binding<SidebarItem> {
        Binding(get: { selection }, set: selectSidebarItem)
    }

    private func selectSidebarItem(_ item: SidebarItem) {
        compactLibraryVisible = false
        path = []
        selection = item
    }

    private func navigate(to destination: Destination) {
        if compactWindowLayout {
            path.appendIfNotCurrent(destination)
        } else if let item = destination.sidebarRoot {
            selectSidebarItem(item)
        } else {
            path.appendIfNotCurrent(destination)
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            GeometryReader { viewport in
                let size = viewportSize.resolved(viewport.size, active: scenePhase == .active)
                windowContent
                    .environment(\.sceneScrollStore, scrollPositions)
                    .environment(\.horizontalSizeClass,
                        UIDevice.current.userInterfaceIdiom == .pad ? (compactWindowLayout ? .compact : .regular) :
                            (scenePhase == .active ? horizontalSizeClass : (activeSizeClass ?? horizontalSizeClass)))
                    .frame(width: size.width, height: size.height)
                    .onAppear {
                        if scenePhase == .active { compactWindowLayout = viewport.size.width < WindowLayout.compactWidth }
                        viewportSize.record(viewport.size, active: scenePhase == .active)
                        if scenePhase == .active { activeSizeClass = horizontalSizeClass }
                    }
                    .onChange(of: horizontalSizeClass) { sizeClass in
                        if scenePhase == .active { activeSizeClass = sizeClass }
                    }
                    .onChange(of: viewport.size) { size in
                        if scenePhase == .active { compactWindowLayout = size.width < WindowLayout.compactWidth }
                        viewportSize.record(size, active: scenePhase == .active)
                    }
                    .onChange(of: scenePhase) { phase in
                        viewportSize.record(viewport.size, active: phase == .active)
                        if phase == .active {
                            compactWindowLayout = viewport.size.width < WindowLayout.compactWidth
                            activeSizeClass = horizontalSizeClass
                        }
                    }
            }
            #else
            GeometryReader { viewport in
                // The opaque player covers browsing content. Keep that content's
                // layout stable during live resize instead of reflowing both pages.
                let browsingSize = player.showNowPlaying ? (browsingViewportSize ?? viewport.size) : viewport.size
                windowContent
                    .frame(width: browsingSize.width, height: browsingSize.height, alignment: .topLeading)
                    .clipped()
                    .onAppear {
                        browsingViewportSize = viewport.size
                        compactWindowLayout = viewport.size.width < WindowLayout.compactWidth
                    }
                    .onGeometryChange(for: Bool.self) { geometry in
                        geometry.size.width < WindowLayout.compactWidth
                    } action: { compact in
                        if !player.showNowPlaying { compactWindowLayout = compact }
                    }
                    .onChange(of: player.showNowPlaying) { _ in
                        browsingViewportSize = viewport.size
                        compactWindowLayout = viewport.size.width < WindowLayout.compactWidth
                    }
            }
            // The wide canvas already extends under the hidden titlebar. The
            // resize-stabilizing frame must receive that full height as well;
            // otherwise its clip cuts off the child's safe-area extension.
            .ignoresSafeArea(.container, edges: compactWindowLayout ? [] : .top)
            #endif
        }
        #if os(iOS)
        .modifier(IPadSplitStyle())
        #endif
        #if os(iOS)
        .background {
            if iPadChrome == .native && !compactWindowLayout {
                IPadMainColumnGeometryReader(geometry: mainColumnGeometry)
            }
        }
        #endif
        #if os(iOS)
        .backgroundPreferenceValue(AppPageBackgroundKey.self) { color in
            // 有页面自带背景时用页面的；没有就用当前主题的背景。
            if let color {
                color.ignoresSafeArea(.container)
            } else {
                CodaThemeBackgroundView()
            }
        }
        #endif
        .coordinateSpace(name: "mainWindow")
        #if os(macOS)
        .background(MainWindowConfigurator(showsNowPlaying: player.showNowPlaying))
        #endif
        .playerChrome(geometry: mainColumnGeometry)
        .environment(\.compactWindowLayout, compactWindowLayout)
        #if os(macOS)
        .modifier(OfflinePlaybackAlert(player: player, onDownloads: { openDestination(.downloaded) }))
        .modifier(MeteredDownloadAlert())
        .modifier(AddToPlaylistPresentation())
        #endif
        .environment(\.openLogin, { showLogin = true })
        .environment(\.openDestination, openDestination)
        #if os(macOS)
        .modifier(PlaybackLifecycle())
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .showDownloadedMusic)) { _ in
            openDestination(.downloaded)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
            player.showNowPlaying = false
            selectSidebarItem(.settings)
        }
        #if os(macOS)
        .environmentObject(artworkStore)
        #endif
        .task {
#if os(macOS)
            // Keep this action in the app delegate: when the user closes the
            // last WindowGroup window, there is no view left to receive a
            // Dock reopen event directly.
            AppDelegate.shared?.openMainWindow = { openWindow(id: "main") }
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
#endif
            DesktopLyricsController.shared.sync(with: settings.showDesktopLyrics)
            await DownloadManager.shared.start()
            if CodaPaths.isOfflineUITest { selection = .downloaded }
            await account.bootstrap()
        }
        .onChange(of: account.sessionRevision) { _ in
            path = []
            if selection != .settings { selection = .home }
        }
        .onChange(of: settings.showDesktopLyrics) { _ in
            DesktopLyricsController.shared.sync(with: settings.showDesktopLyrics)
        }
        #if os(macOS)
        .onChange(of: settings.showMainWindowAmbientBackground) { _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        // Warm the cover as soon as a track loads: the now-playing page only
        // slides in smoothly when the artwork is already in memory.
        .onChange(of: player.hasCurrentTrack) { _ in
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
        }
        #endif
        .onChange(of: player.showNowPlaying) { _ in
            #if os(macOS)
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
            #endif
        }
        .sheet(isPresented: $showLogin) {
            LoginSheet()
        }
        .modifier(FirstLaunchOnboarding())
        #if os(macOS)
        // iOS presents Now Playing exclusively in IOSMainWindow. Adding it
        // here as well leaves a second player visible behind a dragged cover.
        .overlay {
            // Preserve the surface across Dock and Mission Control transitions.
            // Animation leaves observe visibility themselves; the navigation
            // and hosting trees must not rebuild when occlusion changes.
                DesktopNowPlayingPresentation(isPresented: showNowPlayingBinding,
                    onDismissed: {
                        if let destination = destinationAfterPlayerDismissal {
                            destinationAfterPlayerDismissal = nil
                            navigate(to: destination)
                        }
                    }) {
                    NowPlayingView(onOpenDestination: openDestination,
                        backgroundColorScheme: settings.appearance.colorScheme ?? colorScheme)
                        .environmentObject(artworkStore)
                        .background(ArrowCursorOverride())
                        .modifier(ToastOverlay(topPadding: 12))
                }
                .ignoresSafeArea(.container)
        }
        // iOS shows toasts once, from IOSMainWindow, which embeds this view.
        .modifier(ToastOverlay(enabled: !player.showNowPlaying, topPadding: 12))
        #endif
    }

    @ViewBuilder
    private var windowContent: some View {
        if compactWindowLayout {
            compactInterface
        } else {
        #if os(iOS)
        // Keep chrome outside navigation so pushes preserve its identity.
        // Each destination reserves its own sidebar and playback clearance.
        if iPadChrome == .legacy {
            legacyFloatingInterface
        } else {
            ZStack(alignment: .bottom) {
                splitInterface
                IPadMainColumnPlayerBar(geometry: mainColumnGeometry)
            }
        }
        #else
        desktopFloatingInterface
        #endif
        }
    }

    private var compactTab: Binding<IOSTab> {
        Binding(get: {
            if compactLibraryVisible { return .library }
            switch selection {
            case .home: return .home
            case .search: return .search
            default: return .library
            }
        }, set: { tab in
            if tab == .library {
                path = []
                compactLibraryVisible = true
            } else {
                selectSidebarItem(tab == .home ? .home : .search)
            }
        })
    }

    private var compactBottomChromeHeight: CGFloat {
        let metrics = Theme.Layout.FloatingChrome.self
        return metrics.fullChromeClearance - metrics.extraPadding
    }

    private var compactInterface: some View {
        GeometryReader { viewport in
            Group {
                #if os(iOS)
                if iPadChrome == .legacy {
                    CompactChromeHost(chromeHeight: compactBottomChromeHeight,
                                      onPageBackgroundChange: { compactPageBackground = $0 }) {
                        compactNavigation(width: viewport.size.width)
                    } chrome: {
                        compactBottomChrome
                    }
                    // Preferences do not cross a hosting-controller boundary.
                    .preference(key: AppPageBackgroundKey.self, value: compactPageBackground)
                } else {
                    compactSwiftUIInterface(width: viewport.size.width)
                }
                #else
                compactSwiftUIInterface(width: viewport.size.width)
                #endif
            }
            #if os(iOS)
            .padding(.bottom, iPadChrome == .legacy ? legacyKeyboardOverlap : 0)
            #endif
            .onAppear { mainColumnGeometry.update(.init(frame: CGRect(origin: .zero, size: viewport.size))) }
            .onChange(of: viewport.size) { mainColumnGeometry.update(.init(frame: CGRect(origin: .zero, size: $0))) }
        }
    }

    private func compactNavigation(width: CGFloat) -> some View {
        detailStack
            .environment(\.musicLibraryContentWidth, width)
            .safeAreaInset(edge: .bottom, spacing: Theme.Layout.FloatingChrome.extraPadding) {
                Color.clear.frame(height: compactBottomChromeHeight)
            }
            .clipped()
    }

    private func compactSwiftUIInterface(width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            compactNavigation(width: width)
            compactBottomChrome.zIndex(1)
        }
    }

    private var compactBottomChrome: some View {
        VStack(spacing: Theme.Layout.FloatingChrome.barSpacing) {
            IOSMiniPlayerBar(presentation: .legacyOverlay)
                .frame(height: Theme.Layout.FloatingChrome.miniPlayerHeight)
                .padding(.horizontal, Theme.Layout.FloatingChrome.horizontalMargin)
                #if os(iOS)
                .nowPlayingTransitionSource(in: compactPlayerNamespace)
                #else
                .modifier(NowPlayingZoomSourceReporter())
                #endif
            GlassTabBar(items: IOSTab.barItems, selection: compactTab, onReselect: { _ in path = [] })
            .frame(height: Theme.Layout.FloatingChrome.tabBarHeight)
            .padding(.horizontal, Theme.Layout.FloatingChrome.horizontalMargin)
        }
        .padding(.bottom, Theme.Layout.FloatingChrome.bottomMargin)
        .frame(height: compactBottomChromeHeight)
        .background {
            // Transparent padding and gaps belong to the chrome too. A hit
            // shape alone stops taps reaching the page; a tap gesture here
            // would win iPadOS 16's fuzzy finger hit-testing over the buttons.
            Color.clear
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
    }

    #if os(macOS)
    /// Navigation owns the canvas; the sidebar and dock float above it.
    private var desktopFloatingInterface: some View {
        GeometryReader { viewport in
            // Match the iPad's floating sidebar before falling back to phone navigation.
            let sidebarWidth = min(Theme.Layout.sidebarWidth, max(180, viewport.size.width * 0.32))
            let leadingClearance = sidebarWidth + 20
            let layout = MainColumnGeometry.Layout(frame: CGRect(
                x: leadingClearance, y: 0,
                width: max(0, viewport.size.width - leadingClearance),
                height: viewport.size.height))
            ZStack(alignment: .leading) {
                DesktopNavigationTransition(selection: selection, path: path) {
                    detailStack
                }
                    // Match the sidebar canvas; DesktopContentClearance owns the top inset.
                    .ignoresSafeArea(.container, edges: .top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay {
                        if settings.showMainWindowAmbientBackground {
                            MainWindowAmbientBackground(
                                colors: artworkStore.colors,
                                intensity: settings.mainWindowAmbientBackgroundIntensity
                            )
                            .ignoresSafeArea()
                        }
                    }
                SidebarView(selection: sidebarSelection, onSearchSelected: {
                    path = []
                    sidebarSearchFocusRequested = true
                })
                    .frame(width: sidebarWidth)
                    .modifier(DesktopFloatingSurface())
                    .padding(.leading, SidebarLayout.outerInset)
                    .padding(.top, DesktopChromeLayout.topInset)
                    .padding(.bottom, SidebarLayout.outerInset)
            }
            .background(CodaThemeBackgroundView())
            .onAppear { mainColumnGeometry.update(layout) }
            .onChange(of: layout) { mainColumnGeometry.update($0) }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
    #endif

    #if os(iOS)
    /// The navigation stack owns the full canvas. Chrome is composed above it,
    /// while each destination reserves space for controls without splitting
    /// the underlying page background into separate columns.
    private var legacyFloatingInterface: some View {
        GeometryReader { viewport in
            let sidebarWidth = min(Theme.Layout.sidebarWidth, max(180, viewport.size.width * 0.32))
            let leadingClearance = sidebarWidth + 20
            let layout = MainColumnGeometry.Layout(frame: CGRect(
                x: leadingClearance, y: 0,
                width: max(0, viewport.size.width - leadingClearance),
                height: viewport.size.height))
            ZStack(alignment: .leading) {
                detailStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The full-screen canvas includes system indicator areas;
                    // shelves still cannot draw outside the window.
                    .clipped()
                    .overlay {
                        if settings.showMainWindowAmbientBackground {
                            MainWindowAmbientBackground(
                                colors: artworkStore.colors,
                                intensity: settings.mainWindowAmbientBackgroundIntensity
                            )
                            .ignoresSafeArea(.container)
                        }
                    }
                SidebarView(selection: sidebarSelection, onSearchSelected: {
                    path = []
                    sidebarSearchFocusRequested = true
                })
                    .frame(width: sidebarWidth)
                    .modifier(IPadFloatingSurface())
                    .padding(.top, legacySystemInsets.top + SidebarLayout.outerInset)
                    .padding(.bottom, legacySystemInsets.bottom + legacyKeyboardOverlap + SidebarLayout.outerInset)
                    .padding(.leading, SidebarLayout.outerInset)
            }
            .overlay(alignment: .bottom) {
                IPadMainColumnPlayerBar(geometry: mainColumnGeometry)
                    .padding(.bottom, legacySystemInsets.bottom + legacyKeyboardOverlap)
            }
            .background(CodaThemeBackgroundView())
            .onAppear { mainColumnGeometry.update(layout) }
            .onChange(of: layout) { next in
                if scenePhase == .active { mainColumnGeometry.update(next) }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { mainColumnGeometry.update(layout) }
            }
        }
    }
    #endif

    #if os(iOS)
    private var splitInterface: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebarColumn
        } detail: {
            IPadDetailColumnContent(geometry: mainColumnGeometry) {
                detailStack
            }
            .overlay {
                if settings.showMainWindowAmbientBackground {
                    MainWindowAmbientBackground(
                        colors: artworkStore.colors,
                        intensity: settings.mainWindowAmbientBackgroundIntensity
                    )
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
                }
            }
        }
    }

    @ViewBuilder
    private var sidebarColumn: some View {
        let sidebar = SidebarView(selection: sidebarSelection, onSearchSelected: {
            path = []
            sidebarSearchFocusRequested = true
        })
        if #available(iOS 26.0, *), iPadChrome == .native {
            sidebar
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(removing: .sidebarToggle)
        } else {
            sidebar.navigationSplitViewColumnWidth(min: 300, ideal: 332, max: 360)
        }
    }
    #endif

    private var detailStack: some View {
        NavigationStack(path: pathBinding) {
            // A sidebar selection is the stack's root, not a pushed page.
            // iPadOS can rebuild the stack when the scene returns to the
            // foreground; its root must still represent the selected section.
            Group {
                if compactLibraryVisible && compactWindowLayout {
                    LibraryView(showLogin: $showLogin)
                } else {
                    SidebarDestinationView(item: selection, searchFocusRequested: $sidebarSearchFocusRequested, onPlaylistDeleted: { selection = .home })
                }
            }
                .desktopContentClearance()
                .legacyIPadContentClearance(geometry: mainColumnGeometry)
                #if os(iOS)
                .environment(\.sceneScrollPage, .init(section: selection, path: []))
                #endif
                .playerContentInset()
                .appDestinations()
        }
        .environment(\.mainColumnGeometry, mainColumnGeometry)
        .environment(\.popDestination, {
            guard !path.isEmpty else { return }
            path.removeLast()
        })
        #if os(iOS)
        .ignoresSafeArea(.keyboard, edges: iPadChrome == .legacy ? .bottom : [])
        .environment(\.sceneScrollPage, .init(section: selection, path: []))
        #endif
        .onChange(of: path) { destinations in
            // NavigationLink and the outer iPad player also enter through this path.
            // Only explicit sidebar routes replace the root. Links inside pages
            // remain pushed destinations with their own back navigation.
            if !compactWindowLayout, let item = destinations.last?.sidebarRoot {
                selectSidebarItem(item)
            }
        }
        #if os(iOS)
        .onChange(of: path) { destinations in
            if !destinations.isEmpty { sidebarSearchFocusRequested = false }
            dismissLegacyIPadKeyboard()
            // A popped screen starts at the top on its next visit. Keep the
            // positions of screens still in the stack for back navigation.
            scrollPositions.offsets = scrollPositions.offsets.filter { key, _ in
                key.page.section != selection || key.page.path.isEmpty
                    || key.page.path.allSatisfy { destinations.contains($0) }
            }
        }
        #endif
        .onChange(of: selection) { next in
            if next != .search { sidebarSearchFocusRequested = false }
            // Only an explicit section change clears the detail history.
            #if os(iOS)
            dismissLegacyIPadKeyboard()
            #endif
            path = []
        }
    }

    #if os(iOS)
    private func dismissLegacyIPadKeyboard() {
        guard iPadChrome == .legacy else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
    #endif

    private func openDestination(_ destination: Destination) {
        #if os(macOS)
        guard player.showNowPlaying else {
            navigate(to: destination)
            return
        }

        destinationAfterPlayerDismissal = destination
        player.showNowPlaying = false
        #else
        player.showNowPlaying = false
        navigate(to: destination)
        #endif
    }

    #if os(macOS)
    private var needsCurrentArtwork: Bool {
        settings.showMainWindowAmbientBackground || player.hasCurrentTrack
    }

    #endif
}

#if os(macOS)
// MARK: - Cursor override

/// Claims the arrow cursor over the whole now-playing page. AppKit cursor
/// rects ignore hit-testing, so without this the split-view divider's resize
/// cursor leaks through the full-window overlay wherever the divider sits (#6).
struct ArrowCursorOverride: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorOverrideView { CursorOverrideView() }

    func updateNSView(_ nsView: CursorOverrideView, context: Context) {}

    final class CursorOverrideView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}

// MARK: - Main window configurator

/// Grabs the single main `NSWindow` once it exists and installs a close
/// interceptor: Cmd+W / the red button *hide* the window (`orderOut`) instead
/// of destroying the single-instance `Window` scene. Destroying the scene left
/// the app running with no way to reopen it (#60/#66/#70); hiding keeps the
/// SwiftUI scene fully alive so `AppDelegate.applicationShouldHandleReopen`
/// can front it again on a Dock click. Every other window-delegate callback is
/// forwarded untouched to SwiftUI's own delegate.
struct MainWindowConfigurator: NSViewRepresentable {
    @Environment(\.compactWindowLayout) private var compactWindowLayout
    let showsNowPlaying: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowHost {
        let view = WindowHost(frame: .zero)
        let coordinator = context.coordinator
        view.windowDidChange = { [weak coordinator, weak view] in
            guard let view else { return }
            coordinator?.scheduleConfiguration(from: view)
        }
        return view
    }

    func updateNSView(_ view: WindowHost, context: Context) {
        let coordinator = context.coordinator
        let showsNavigationBar = compactWindowLayout && !showsNowPlaying
        guard coordinator.showsNavigationBar != showsNavigationBar || coordinator.window !== view.window else { return }
        coordinator.showsNavigationBar = showsNavigationBar
        coordinator.scheduleConfiguration(from: view)
    }

    static func dismantleNSView(_ view: WindowHost, coordinator: Coordinator) {
        view.windowDidChange = nil
        coordinator.detach()
    }

    final class WindowHost: NSView {
        var windowDidChange: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowDidChange?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private(set) weak var window: NSWindow?
        private weak var forwardee: NSWindowDelegate?
        private weak var configurationHost: NSView?
        private var hasScheduledConfiguration = false
        private var isApplyingChrome = false
        private var windowObservers: [NSObjectProtocol] = []
        private var fullScreenUpdate: Task<Void, Never>?
        private var titlebarMouseMonitor: Any?
        var showsNavigationBar = false

        /// Keep the standard window controls while removing all toolbar chrome.
        private func applyWindowToolbarVisibility() {
            guard !isApplyingChrome, let window else { return }
            isApplyingChrome = true
            defer { isApplyingChrome = false }
            let visibility: NSWindow.TitleVisibility = showsNavigationBar ? .visible : .hidden
            if window.titleVisibility != visibility { window.titleVisibility = visibility }
            if window.titlebarAppearsTransparent == showsNavigationBar {
                window.titlebarAppearsTransparent = !showsNavigationBar
            }
            if showsNavigationBar, window.toolbarStyle != .unifiedCompact {
                window.toolbarStyle = .unifiedCompact
            }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if !window.isMovableByWindowBackground { window.isMovableByWindowBackground = true }
            if let toolbar = window.toolbar, toolbar.isVisible != showsNavigationBar {
                toolbar.isVisible = showsNavigationBar
            }
            // Keep AppKit's controls even when the wide layout has no toolbar.
            // Full screen owns their visibility while its titlebar is revealed.
            if !window.styleMask.contains(.fullScreen) {
                for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                    if let button = window.standardWindowButton(buttonType), button.isHidden {
                        button.isHidden = false
                    }
                }
            }
        }

        func attach(to window: NSWindow?) {
            guard window !== self.window else { return }
            detach()
            guard let window else { return }
            self.window = window
            window.isReleasedWhenClosed = false
            installTitlebarDoubleClickHandler()
            // Insert ourselves as the delegate, forwarding to whatever
            // delegate SwiftUI installed.
            if window.delegate !== self {
                forwardee = window.delegate
                window.delegate = self
            }
            AppDelegate.shared?.mainWindow = window
            observeFullScreenChanges(of: window)
            observeWindowVisibility(of: window)
            refreshWindowVisibility()
        }

        func detach() {
            configurationHost = nil
            fullScreenUpdate?.cancel()
            fullScreenUpdate = nil
            for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
            windowObservers.removeAll()
            if let titlebarMouseMonitor { NSEvent.removeMonitor(titlebarMouseMonitor) }
            titlebarMouseMonitor = nil
            if let window {
                if window.delegate === self { window.delegate = forwardee }
                if AppDelegate.shared?.mainWindow === window { AppDelegate.shared?.mainWindow = nil }
            }
            window = nil
            forwardee = nil
        }

        /// Keep title-bar double clicks consistent regardless of the system's
        /// minimize/zoom preference, without intercepting content or window buttons.
        private func installTitlebarDoubleClickHandler() {
            titlebarMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseUp]
            ) { [weak self] event in
                guard let window = self?.window, event.window === window,
                      event.clickCount == 2, !window.styleMask.contains(.fullScreen),
                      let frameView = window.contentView?.superview else { return event }
                let titlebarHeight = window.frame.height - window.contentLayoutRect.height
                let point = frameView.convert(event.locationInWindow, from: nil)
                let titlebar = NSRect(
                    x: frameView.bounds.minX,
                    y: frameView.isFlipped ? frameView.bounds.minY : frameView.bounds.maxY - titlebarHeight,
                    width: frameView.bounds.width, height: titlebarHeight
                )
                guard titlebar.contains(point) else { return event }
                var hit = frameView.hitTest(point)
                while let view = hit {
                    if view is NSControl { return event }
                    hit = view.superview
                }
                if event.type == .leftMouseUp { window.performZoom(nil) }
                return nil
            }
        }

        func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
            window.screen?.visibleFrame ?? newFrame
        }

        /// Reapply the floating layout when AppKit hands chrome back after
        /// a full-screen transition.
        private func observeFullScreenChanges(of window: NSWindow) {
            let center = NotificationCenter.default
            for name in [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ] {
                windowObservers.append(center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window, self.window === window else { return }
                        self.reassertChromeState()
                        self.fullScreenUpdate?.cancel()
                        // Reapply once SwiftUI finishes committing window chrome.
                        self.fullScreenUpdate = Task { @MainActor [weak self] in
                            do { try await Task.sleep(for: .milliseconds(100)) }
                            catch { return }
                            self?.reassertChromeState()
                        }
                    }
                })
            }
        }

        /// SwiftUI keeps the page's `TimelineView`s ticking while the window
        /// is off screen, so track the states that take it there — and bring
        /// it back — and tell `MainWindowVisibility`.
        private func observeWindowVisibility(of window: NSWindow) {
            let center = NotificationCenter.default
            for name in [
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification
            ] {
                windowObservers.append(center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window, self.window === window else { return }
                        self.refreshWindowVisibility()
                    }
                })
            }
        }

        /// Pause animated leaves without removing their hosting trees.
        private func refreshWindowVisibility() {
            guard let window else { return }
            let onScreen = window.isVisible && !window.isMiniaturized
            MainWindowVisibility.shared.update(
                isVisible: onScreen && window.occlusionState.contains(.visible),
                isOnScreen: onScreen
            )
        }

        private func reassertChromeState() {
            applyWindowToolbarVisibility()
            refreshWindowVisibility()
        }

        func scheduleConfiguration(from host: NSView) {
            configurationHost = host
            guard !hasScheduledConfiguration else { return }
            hasScheduledConfiguration = true

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasScheduledConfiguration = false
                guard let host = self.configurationHost else { return }
                self.attach(to: host.window)
                self.applyWindowToolbarVisibility()
            }
        }

        func windowDidUpdate(_ notification: Notification) {
            forwardee?.windowDidUpdate?(notification)
            // Mission Control also updates windows. Chrome belongs to explicit
            // configuration/full-screen changes, not every compositor update.
        }

        func windowDidResize(_ notification: Notification) {
            forwardee?.windowDidResize?(notification)
            refreshWindowVisibility()
        }

        // Hide instead of close; keep the scene alive.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            refreshWindowVisibility()
            return false
        }

        // Transparently forward every other delegate callback to SwiftUI.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (forwardee?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if forwardee?.responds(to: aSelector) == true { return forwardee }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

#endif

// MARK: - Toast

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .compatGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

/// Shows the current toast at the top of a surface. The now-playing page is
/// presented above the window root (a full-screen cover on iOS, an AppKit
/// surface on macOS), so it hosts its own copy while the root hides theirs.
struct ToastOverlay: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared
    var enabled = true
    var topPadding: CGFloat = 8

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            ZStack {
                if enabled, let toast = center.current {
                    ToastView(toast: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, topPadding)
                }
            }
            .allowsHitTesting(false)
            .animation(.spring(duration: 0.3), value: center.current)
        }
    }
}

/// The same page content can be the initial root or a native navigation destination.
struct SidebarDestinationView: View {
    let item: SidebarItem
    var searchFocusRequested: Binding<Bool> = .constant(false)
    var onPlaylistDeleted: (() -> Void)? = nil
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openLogin) private var openLogin

    @ViewBuilder
    var body: some View {
        switch item {
        case .downloaded:
            DownloadedMusicView()
        case .home:
            HomeView()
        case .fm:
            FMView()
        case .account:
            AccountDetailsView()
        case .settings:
            SettingsView()
                .navigationTitle("设置")
        case .search:
            // 探索 (search plus the 精选 shelves) lives in the detail column on both Mac and iPad.
            SearchView(query: "", focusRequested: searchFocusRequested).id(account.sessionRevision)
        case .likedSongs:
            if let playlist = account.likedSongsPlaylist {
                PlaylistDetailView(playlistID: playlist.id, isLikedList: true)
                    .id(playlist.id)
            } else {
                loginPrompt
            }
        case .daily:
            DailySongsView()
        case .recents:
            RecentsView()
        case .collections:
            CollectionsView()
        case .cloud:
            CloudView()
        case .playlist(let id):
            PlaylistDetailView(playlistID: id, onDeleted: onPlaylistDeleted)
                .id(id)
        case .localPlaylist(let id):
            LocalPlaylistDetailView(playlistID: id)
                .id(id)
        }
    }

    private var loginPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("登录后查看你喜欢的音乐")
                .font(.headline)
            Button("登录") { openLogin() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
