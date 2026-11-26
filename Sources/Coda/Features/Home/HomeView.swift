import SwiftUI

/// Shared rhythm for the recommendation page, including its nested song sections.
enum HomeLayout {
    static let sectionSpacing = Theme.Spacing.discoverySection
    static let headerSpacing = Theme.Spacing.component
    static let headerHeight: CGFloat = 44
    /// Every home cover shelf matches the radar cards in the first row, on all platforms.
    static let coverSize: CGFloat = Theme.Layout.cardSize
    /// Covers share the radar cards' continuous corner radius.
    static let coverCornerRadius: CGFloat = Theme.Radius.cover
}

@MainActor
final class HomeViewModel: ObservableObject {
    /// Shared so the loaded page survives sidebar switches (no skeleton flash).
    static let shared = HomeViewModel()
    static let qishui = HomeViewModel()

    enum State {
        case idle, loading, loaded
        case error(String)
    }

    typealias RadarPlaylist = NeteaseAPI.RadarPlaylist
    typealias ToplistPreview = (tracks: [Track], previousRanks: [Int: Int], growthRatios: [Int: Double])
    private let fetchRadarPlaylists: () async throws -> [RadarPlaylist]
    private let fetchToplistPreview: (Int) async throws -> ToplistPreview
    private let refreshGate = PanelRefreshGate()
    private var authentication: String?
    private var radarFetchedAt: Date?
    private var radarAuthentication: String?
    private var radarRequest: UUID?

    init(fetchRadarPlaylists: @escaping () async throws -> [RadarPlaylist] = { try await NeteaseAPI.radarPlaylists() },
         fetchToplistPreview: @escaping (Int) async throws -> ToplistPreview = { try await NeteaseAPI.toplistPreviewTracks(id: $0) }) {
        self.fetchRadarPlaylists = fetchRadarPlaylists
        self.fetchToplistPreview = fetchToplistPreview
    }

    enum Module: Hashable { case features, toplists, albums, artists }
    @Published private(set) var loadingModules: Set<Module> = [.features, .toplists, .albums, .artists]
    @Published var state: State = .idle
    @Published var radarPlaylists: [RadarPlaylist] = []
    @Published var toplists: [ToplistItem] = []
    @Published var toplistGrowthRatios: [Int: [Int: Double]] = [:]
    @Published var toplistPreviousRanks: [Int: [Int: Int]] = [:]
    @Published var toplistTracks: [Int: [Track]] = [:]
    @Published var failedToplistIDs: Set<Int> = []
    private var toplistRequests: [Int: UUID] = [:]
    private var toplistFetchedAt: [Int: Date] = [:]
    static let homeToplistIDs = [19_723_756, 3_778_678, 3_779_629]

    let albumPages = HorizontalPageSource<AlbumSummary>(pageSize: 20)
    @Published var newAlbums: [AlbumSummary] = []
    @Published var topArtists: [ArtistSummary] = []
    @Published var dailyFirstCover: String?
    @Published var refreshError: String?
    func load(loggedIn: Bool, force: Bool = false) async {
        let binding = MusicProviderContext.shared.authenticationKey
        if binding != authentication {
            authentication = binding; refreshGate.invalidate()
            dailyFirstCover = nil
            toplists = []; newAlbums = []; topArtists = []
            albumPages.replace([], hasMore: false)
            state = .idle
            toplistRequests = [:]; toplistFetchedAt = [:]
            toplistTracks = [:]; toplistPreviousRanks = [:]; toplistGrowthRatios = [:]
            failedToplistIDs = []
        }
        guard let ticket = refreshGate.begin(key: binding ?? "guest", lifetime: 1800, force: force) else {
            for chart in toplists.prefix(3) { await loadToplistTracks(id: chart.id) }
            await refreshRadarPlaylists(loggedIn: loggedIn, force: force)
            await refreshDailyCover(loggedIn: loggedIn, force: force)
            return
        }
        var success = false
        defer { refreshGate.finish(ticket, success: success) }
        albumPages.invalidate()
        loadingModules = [.features, .toplists, .albums, .artists]
        if toplists.isEmpty && newAlbums.isEmpty { state = .loading }

        let provider = MusicProviderContext.shared.current
        // Each module commits a complete batch and clears its own skeleton.
        // Slow modules never hold the rest of the page behind a loading state.
        @MainActor func acceptContent() -> Bool {
            !Task.isCancelled && refreshGate.accepts(ticket)
                && binding == MusicProviderContext.shared.authenticationKey
        }
        @MainActor @Sendable func loadCharts() async -> Bool {
            defer { if refreshGate.isCurrent(ticket) { loadingModules.remove(.toplists) } }
            guard let charts = try? await NeteaseAPI.toplists(), acceptContent() else { return false }
            let leading = Self.homeToplistIDs.compactMap { id in charts.first { $0.id == id } }
            var seen = Set<Int>()
            let ordered = (leading + charts).filter { seen.insert($0.id).inserted }
            await withTaskGroup(of: Void.self) { group in
                for chart in ordered.prefix(3) {
                    group.addTask { await self.loadToplistTracks(id: chart.id, force: force) }
                }
            }
            guard acceptContent() else { return false }
            toplists = ordered
            state = .loaded
            return true
        }
        @MainActor @Sendable func loadAlbums() async -> Bool {
            defer { if refreshGate.isCurrent(ticket) { loadingModules.remove(.albums) } }
            guard provider.supports(.newAlbums) else { return true }
            guard let albums = try? await NeteaseAPI.newAlbums(limit: 20), acceptContent() else { return false }
            newAlbums = albums
            albumPages.replace(albums, hasMore: albums.count == 20)
            if !albums.isEmpty { state = .loaded }
            return true
        }
        @MainActor @Sendable func loadArtists() async -> Bool {
            defer { if refreshGate.isCurrent(ticket) { loadingModules.remove(.artists) } }
            guard provider.supports(.topArtists) else { return true }
            guard let artists = try? await NeteaseAPI.topArtists(), acceptContent() else { return false }
            topArtists = artists.shuffled()
            return true
        }
        @MainActor @Sendable func loadFeatures() async {
            defer { if refreshGate.isCurrent(ticket) { loadingModules.remove(.features) } }
            async let daily: Void = refreshDailyCover(loggedIn: loggedIn, force: force)
            async let radar: Void = refreshRadarPlaylists(loggedIn: loggedIn, force: force)
            _ = await (daily, radar)
        }
        async let chartsTask = loadCharts()
        async let albumsTask = loadAlbums()
        async let artistsTask = loadArtists()
        async let featuresTask: Void = loadFeatures()
        let (charts, albums, artists) = await (chartsTask, albumsTask, artistsTask)
        await featuresTask
        guard refreshGate.accepts(ticket), binding == MusicProviderContext.shared.authenticationKey else { return }
        success = charts && albums && artists
        refreshError = success ? nil : String(localized: "部分推荐刷新失败，请重试")
        state = toplists.isEmpty && newAlbums.isEmpty ? .error(String(localized: "网络连接失败")) : .loaded
    }

    private func refreshDailyCover(loggedIn: Bool, force: Bool) async {
        guard loggedIn, MusicProviderContext.shared.current.supports(.dailySongs) else { dailyFirstCover = nil; return }
        let binding = MusicProviderContext.shared.authenticationKey
        await SidebarResources.daily.load(lifetime: 86_400, key: SidebarResources.dailyPeriod(), force: force) {
            try await NeteaseAPI.dailyRecommendSongs()
        }
        guard !Task.isCancelled, binding == MusicProviderContext.shared.authenticationKey else { return }
        dailyFirstCover = SidebarResources.daily.value.first?.album.picUrl
    }

    func reload(loggedIn: Bool) async {
        await load(loggedIn: loggedIn, force: true)
    }

    /// Cache previews and request additional charts only as they become visible.
    func loadToplistTracks(id: Int, force: Bool = false, now: Date = Date()) async {
        if !force {
            guard toplistRequests[id] == nil else { return }
            if let fetchedAt = toplistFetchedAt[id], now.timeIntervalSince(fetchedAt) >= 0,
               now.timeIntervalSince(fetchedAt) < 1800 { return }
        }
        let request = UUID()
        let binding = MusicProviderContext.shared.authenticationKey
        toplistRequests[id] = request
        defer { if toplistRequests[id] == request { toplistRequests[id] = nil } }
        do {
            let tracks = try await fetchToplistPreview(id)
            try Task.checkCancellation()
            guard toplistRequests[id] == request, binding == MusicProviderContext.shared.authenticationKey else { return }
            toplistGrowthRatios[id] = tracks.growthRatios
            toplistPreviousRanks[id] = tracks.previousRanks
            toplistTracks[id] = tracks.tracks
            toplistFetchedAt[id] = now
            failedToplistIDs.remove(id)
        } catch {
            if !Task.isCancelled, toplistRequests[id] == request,
               binding == MusicProviderContext.shared.authenticationKey { failedToplistIDs.insert(id) }
        }
    }

    func retryToplistTracks(id: Int) async {
        failedToplistIDs.remove(id)
        await loadToplistTracks(id: id, force: true)
    }

    func refreshRadarPlaylists(loggedIn: Bool, force: Bool = false, now: Date = Date()) async {
        let authentication = MusicProviderContext.shared.authenticationKey
        if !loggedIn || radarAuthentication != authentication {
            radarPlaylists = []
            radarFetchedAt = nil
            radarRequest = nil
            radarAuthentication = authentication
        }
        guard loggedIn, MusicProviderContext.shared.current.supports(.radarPlaylists) else { radarPlaylists = []; return }
        if !force {
            guard radarRequest == nil else { return }
            if let fetchedAt = radarFetchedAt,
               now.timeIntervalSince(fetchedAt) < 300,
               Calendar.current.isDate(fetchedAt, inSameDayAs: now) { return }
        }
        let request = UUID()
        radarRequest = request
        defer { if radarRequest == request { radarRequest = nil } }
        do {
            let fresh = try await fetchRadarPlaylists()
            guard !Task.isCancelled, radarRequest == request,
                  authentication == MusicProviderContext.shared.authenticationKey else { return }
            // Replace the whole successful snapshot: removals and reordering are source updates too.
            radarPlaylists = fresh
            radarFetchedAt = now
        } catch {
            // Keep the previous snapshot on transport/schema failure and retry on the next refresh.
        }
    }


}

struct HomeView: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        if account.provider == .qishui {
            QishuiHomeView()
                .id(account.offlineScope)
        } else {
            StandardHomeView()
        }
    }
}

private struct StandardHomeView: View {
    private var phoneLayout = PhonePageLayout()
    @ObservedObject private var albumPages = HomeViewModel.shared.albumPages
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var account: AccountStore
    private let player = PlayerService.shared
    @Environment(\.openDestination) private var openDestination
    @StateObject private var model = HomeViewModel.shared
    @StateObject private var suggestions = HomeSongSuggestionsModel.shared
    @StateObject private var discovery = HomeDiscoveryModel.shared
    @ObservedObject private var dailySongs = SidebarResources.daily
    @State private var likedCoverTracks: [Track] = []
    @State private var likedCoverAuthentication: String?
    @State private var likedCoverRequest = UUID()

    private struct LikedCoverContext: Hashable {
        let authentication: String?
        let trackIDs: Set<Int>
    }

    private var likedCoverContext: LikedCoverContext {
        .init(authentication: MusicProviderContext.shared.authenticationKey,
              trackIDs: account.isLoggedIn ? account.likedTrackIDs : [])
    }

    private var likedCoverURLs: [URL] {
        guard likedCoverAuthentication == likedCoverContext.authentication else { return [] }
        var seen = Set<URL>()
        return likedCoverTracks.filter { account.likedTrackIDs.contains($0.id) }.compactMap {
            $0.album.picUrl?.resizedImageURL(256)
        }.filter { seen.insert($0).inserted }
    }

    private func loadLikedCovers(context: LikedCoverContext, force: Bool = true) async {
        guard force else { return }
        let request = UUID()
        likedCoverRequest = request
        if likedCoverAuthentication != context.authentication {
            likedCoverTracks = []
            likedCoverAuthentication = context.authentication
        }
        guard !context.trackIDs.isEmpty else { likedCoverTracks = []; return }
        // Sample the whole favorites library without loading every song's details.
        let ids = Array(context.trackIDs.shuffled().prefix(24))
        guard let response = try? await NeteaseAPI.songDetails(ids: ids),
              !Task.isCancelled, request == likedCoverRequest, context == likedCoverContext else { return }
        likedCoverTracks = response.songs.shuffled()
    }
    var body: some View {
        ScenePreservingScrollView {
            homeBody
        }
        .loadingCrossfade(model.loadingModules)
        .appRootNavigationTitle(String(localized: "推荐"))
        .task(id: likedCoverContext) {
            await loadLikedCovers(context: likedCoverContext)
        }
        .task(id: suggestionReadiness) {
            // The liked library arrives after the profile when switching platforms.
            await refreshRecommendations()
        }
        .panelRefresh(key: "home") { force in
            async let home: Void = model.load(loggedIn: account.isLoggedIn, force: force)
            async let shelves: Void = discovery.load(loggedIn: account.isLoggedIn, force: force)
            async let covers: Void = loadLikedCovers(context: likedCoverContext, force: force)
            await refreshRecommendations(force: force)
            await home
            await shelves
            await covers
        }
        .safeAreaInset(edge: .top) {
            PanelRefreshFailure(message: model.refreshError) { Task { await model.reload(loggedIn: account.isLoggedIn) } }
        }
    }

    private var homeBody: some View {
        loadedBody
    }

    /// Changes only when the account or the presence of liked songs changes,
    /// so liking a single song does not replace the current batch.
    private var suggestionReadiness: String {
        let accountKey = account.provider == .netease
            ? account.authenticatedAccountID.map { "netease:\($0)" }
            : account.isLoggedIn ? "\(account.provider.rawValue):\(account.displayUserID)" : nil
        return "\(accountKey ?? "guest"):\(account.likedTrackIDs.isEmpty)"
    }

    private func refreshRecommendations(force: Bool = false) async {
        guard account.provider.supports(.personalizedSuggestions) else { return }
        let context = HomeSongSuggestionsModel.Context.current(account)
        if force {
            await suggestions.load(context: context, currentTrack: player.currentTrack)
        } else {
            await suggestions.loadIfNeeded(context: context, currentTrack: player.currentTrack)
        }
    }

    private var featureSkeleton: some View {
            ScenePreservingScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: Theme.Spacing.component) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: Theme.Spacing.component) {
                            ForEach(0..<6, id: \.self) { _ in
                                SkeletonView(cornerRadius: 22)
                                    .frame(width: FeatureCard.width, height: FeatureCard.height)
                            }
                        }
                    }
                }
                .padding(.horizontal, phoneLayout.contentInset)
            }
            .frame(height: FeatureCard.height * 2 + 16)
            .pageHeaderTopPadding(8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("正在加载推荐卡片")
            .accessibilityIdentifier("homeFeatureSkeleton")
    }

    private func shelfSkeleton(_ title: LocalizedStringKey, circularCover: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: HomeLayout.headerSpacing) {
            SectionHeader(title: title)
                .frame(minHeight: HomeLayout.headerHeight)
                .padding(.horizontal, phoneLayout.contentInset)
            ScenePreservingScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Spacing.component) {
                    ForEach(0..<6, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                            SkeletonView(cornerRadius: circularCover ? 1000 : HomeLayout.coverCornerRadius)
                                .aspectRatio(1, contentMode: .fit)
                            SkeletonView(cornerRadius: 4).frame(height: 14)
                            SkeletonView(cornerRadius: 4).frame(width: 100, height: 11)
                        }
                        .frame(width: HomeLayout.coverSize)
                    }
                }
                .padding(.horizontal, phoneLayout.contentInset)
            }
            .allowsHitTesting(false)
        }
    }

    private var loadedBody: some View {
        LazyVStack(alignment: .leading, spacing: HomeLayout.sectionSpacing) {
            if showsDailySongRows {
                dailySongRows.pageHeaderTopPadding(8)
            } else if !account.isLoggedIn, account.provider.supports(.dailySongs), model.radarPlaylists.isEmpty {
                // Daily picks, radar and FM are all personal; show the way in instead of an empty row.
                HomeLoginPrompt(message: String(localized: "\(account.provider.dailySongsTitle)、私人推荐等内容需登录后查看"))
                    .padding(.horizontal, phoneLayout.contentInset)
                    .pageHeaderTopPadding(8)
            } else if account.provider == .netease || account.isLoggedIn || !model.radarPlaylists.isEmpty {
                if model.loadingModules.contains(.features) {
                    featureSkeleton
                } else {
                    featureCards.pageHeaderTopPadding(8)
                }
            }

            if account.provider.supports(.personalizedSuggestions) { HomeSongRecommendationLists(model: suggestions) }

            HomeDiscoverySections(model: discovery, songRows: true)

            HomeToplistsSection(model: model, contentInset: phoneLayout.contentInset)

            HomeDiscoverySections(model: discovery, songRows: false)

            if model.loadingModules.contains(.albums), account.provider.supports(.newAlbums) {
                shelfSkeleton("新碟上架")
            } else if !model.newAlbums.isEmpty {
                VStack(alignment: .leading, spacing: HomeLayout.headerSpacing) {
                    SectionHeader(title: "新碟上架", action: { openDestination(.newAlbums) })
                        .frame(minHeight: HomeLayout.headerHeight)
                        .padding(.horizontal, phoneLayout.contentInset)
                    HomeCoverShelf(items: albumPages.items,
                                   loading: albumPages.loading { limit, offset in
                                       let items = try await NeteaseAPI.newAlbums(limit: limit, offset: offset)
                                       return .init(items: items, hasMore: items.count == limit)
                                   }, cardWidth: HomeLayout.coverSize) { album in
                        albumCard(album, size: HomeLayout.coverSize)
                    }
                }
            }

            if model.loadingModules.contains(.artists), account.provider.supports(.topArtists) {
                shelfSkeleton("推荐歌手", circularCover: true)
            } else if !model.topArtists.isEmpty {
                VStack(alignment: .leading, spacing: HomeLayout.headerSpacing) {
                    SectionHeader(title: "推荐歌手", action: { openDestination(.recommendedArtists) })
                        .frame(minHeight: HomeLayout.headerHeight)
                        .padding(.horizontal, phoneLayout.contentInset)
                    ProfileDetailCoverShelf(itemCount: model.topArtists.count,
                                            resetKey: model.topArtists.first?.id, circularCover: true) { visibleCount in
                        ForEach(model.topArtists.prefix(visibleCount)) { artist in
                            artistCard(artist)
                        }
                    }
                    .compatScrollClipDisabled()
                }
            }

            PlayerClearanceSpacer()
        }
        .pageHeaderTopPadding(phoneLayout.contentInset - 8)
        .padding(.bottom, phoneLayout.contentInset - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Daily song rows

    /// QQ and Kugou have no radar playlists, so two lone feature cards would leave
    /// the row mostly empty; show the daily songs themselves instead.
    private var showsDailySongRows: Bool {
        account.isLoggedIn && (account.provider == .qq || account.provider == .kugou)
            && account.provider.supports(.dailySongs)
    }

    private var dailySongRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: LocalizedStringKey(account.provider.dailySongsTitle),
                              action: { openDestination(.daily) })
                Spacer(minLength: Theme.Spacing.small)
                if account.provider == .qq {
                    Button { player.startFM(qqScene: .guessYouLike) } label: {
                        Label("猜你喜欢", systemImage: "music.note")
                            .font(Theme.Typography.secondary.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
                if account.provider.supports(.personalFM) {
                    Button { player.startFM() } label: {
                        Label("私人漫游", systemImage: "wave.3.right")
                            .font(Theme.Typography.secondary.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, minHeight: HomeLayout.headerHeight, alignment: .leading)
            .padding(.bottom, HomeLayout.headerSpacing)
            .padding(.horizontal, phoneLayout.contentInset)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .padding(.bottom, Theme.Spacing.control)
                .padding(.horizontal, phoneLayout.contentInset)
            if dailySongs.value.isEmpty, model.loadingModules.contains(.features) {
                MusicLibraryLoadingView(rowsPerColumn: 3, scrollsHorizontally: true,
                                        showsHorizontalPanel: false,
                                        horizontalInset: Theme.Layout.trackListInset,
                                        fixedColumnWidth: Theme.Layout.homeSongColumnWidth)
            } else if dailySongs.value.isEmpty {
                Text("暂无每日推荐")
                    .font(Theme.Typography.secondary).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                MusicTrackPanel(tracks: dailySongs.value, scrollsHorizontally: true,
                                horizontalRowLimit: 3, horizontalInset: Theme.Layout.trackListInset, fixedColumnWidth: Theme.Layout.homeSongColumnWidth,
                                showsHorizontalPanel: false, source: .daily, context: .daily,
                                showsRowSeparators: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("homeDailySongRows")
    }

    // MARK: - Feature cards

    private var featureCards: some View {
        let coverURLs = likedCoverURLs
        let entryCount = account.isLoggedIn ? 1 + (account.provider.supports(.personalFM) ? 1 : 0) + (account.provider.supports(.intelligenceList) ? 1 : 0) : 0
        let columns = max(entryCount, (entryCount + model.radarPlaylists.count + 1) / 2)
        let firstRowRadarCount = max(0, columns - entryCount)
        let showsSecondRow = account.provider == .netease || model.radarPlaylists.count > firstRowRadarCount

        return HorizontalPagingScrollView(itemCount: model.radarPlaylists.count,
                                          resetKey: model.radarPlaylists.first?.id) { visibleCount in
            VStack(alignment: .leading, spacing: Theme.Spacing.component) {
                HStack(spacing: Theme.Spacing.component) {
                    if account.isLoggedIn {
                        NavigationLink(value: Destination.daily) {
                            FeatureCard(
                                title: account.provider == .qq ? "每日 30 首" : "每日推荐",
                                subtitle: "根据你的口味每天更新",
                                icon: "calendar",
                                coverURL: model.dailyFirstCover?.resizedImageURL(384),
                                showsDate: true
                            )
                        }
                        .buttonStyle(.interactiveCard)
                        .accessibilityIdentifier("homeFeatureCard-daily")

                        if account.provider.supports(.personalFM) {
                            Button {
                                player.startFM()
                            } label: {
                                FeatureCard(title: "私人漫游", subtitle: "随机探索", icon: "wave.3.right",
                                            collageURLs: Array(coverURLs.prefix(12)), showsCollage: true)
                            }
                            .buttonStyle(.interactiveCard)
                        }
                        if account.provider.supports(.intelligenceList) {
                            Button {
                                startHeartbeatMode()
                            } label: {
                                FeatureCard(title: "心动模式", subtitle: "只听喜欢的", icon: "heart.fill",
                                            collageURLs: Array((coverURLs.count > 12
                                                ? Array(coverURLs.dropFirst(12)) : Array(coverURLs.reversed())).prefix(12)),
                                            showsCollage: true)
                            }
                            .buttonStyle(.interactiveCard)
                        }
                    }
                    ForEach(model.radarPlaylists.prefix(min(firstRowRadarCount, visibleCount))) { radar in
                        radarFeatureCard(radar)
                    }
                }
                .frame(height: FeatureCard.height)

                if showsSecondRow {
                    HStack(spacing: Theme.Spacing.component) {
                        ForEach(model.radarPlaylists.prefix(visibleCount).dropFirst(firstRowRadarCount)) { radar in
                            radarFeatureCard(radar)
                        }
                    }
                    .frame(height: FeatureCard.height)
                }
            }
        } placeholder: {
            EmptyView()
        }
        .frame(height: showsSecondRow ? FeatureCard.height * 2 + 16 : FeatureCard.height)
        .compatScrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("homeFeatureCards")
    }

    private func radarFeatureCard(_ radar: HomeViewModel.RadarPlaylist) -> some View {
        NavigationLink(value: Destination.radarPlaylist(radar.id)) {
            FeatureCard(
                title: LocalizedStringKey(radar.title),
                subtitle: LocalizedStringKey(radar.subtitle ?? "为你推荐的专属雷达"),
                icon: "dot.radiowaves.left.and.right",
                coverURL: radar.coverURL?.resizedImageURL(384),
                showsIcon: false
            )
        }
        .buttonStyle(.interactiveCard)
    }

    private func startHeartbeatMode() {
        guard let likedList = account.likedSongsPlaylist else { return }
        Task {
            guard let seed = account.likedTrackIDs.randomElement() else {
                ToastCenter.shared.show(String(localized: "先收藏一些喜欢的歌曲吧"))
                return
            }
            do {
                let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: likedList.id)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                player.play(tracks: tracks, source: .playlist(likedList.id),
                            context: .heartbeat)
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    // MARK: - Cards

    private func albumCard(_ album: AlbumSummary, size: CGFloat) -> some View {
        NavigationLink(value: Destination.album(album.id)) {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.artistName,
                size: size,
                cornerRadius: HomeLayout.coverCornerRadius
            ) {
                Task {
                    if let detail = try? await NeteaseAPI.album(id: album.id) {
                        player.play(tracks: detail.songs, source: .album(album.id),
                                    context: .album(id: album.id, name: album.name))
                    }
                }
            }
        }
        .buttonStyle(.interactiveCard)
    }

    private func artistCard(_ artist: ArtistSummary) -> some View {
        NavigationLink(value: Destination.artist(artist.id)) {
            VStack(spacing: Theme.Spacing.small) {
                CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                    .frame(width: 128, height: 128)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                Text(artist.name)
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 140)
        }
        .buttonStyle(.interactiveCard)
    }

    private func playPlaylist(_ id: Int) {
        Task {
            guard let detail = try? await NeteaseAPI.playlistDetail(id: id) else { return }
            var tracks = detail.playlist.tracks
            if tracks.isEmpty {
                let ids = detail.playlist.trackIds.map(\.id)
                tracks = (try? await NeteaseAPI.songDetails(ids: Array(ids.prefix(500))))?.songs ?? []
            }
            player.play(tracks: tracks, source: .playlist(id),
                        context: .playlist(id: id, name: detail.playlist.name))
        }
    }
}

// MARK: - Feature card

struct FeatureCard: View {
    static let width: CGFloat = Theme.Layout.cardSize
    // Loaded cards, skeletons and both shelf rows share the same square size.
    static let height: CGFloat = width

    @Environment(\.colorScheme) private var colorScheme
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    var coverURL: URL?
    var collageURLs: [URL] = []
    var showsCollage = false
    var showsDate = false
    var showsIcon = true

    private var usesLightForeground: Bool { showsDate || coverURL != nil || showsCollage }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if showsCollage {
                collageArtwork
                LinearGradient(colors: [.black.opacity(0.18), .black.opacity(0.76)],
                               startPoint: .top, endPoint: .bottom)
            } else if let coverURL {
                CachedAsyncImage(url: coverURL)
                    .frame(width: Self.width, height: Self.height)
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.20), .black.opacity(0.72)],
                               startPoint: .top, endPoint: .bottom)
            } else if showsDate {
                Color(white: 0.28)
            } else {
                Theme.cardBackground(colorScheme)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                if showsDate {
                    Text(Date.now, format: .dateTime.month(.twoDigits).day(.twoDigits))
                        .font(Theme.Typography.secondary.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                } else if showsIcon {
                    Image(systemName: icon)
                        .font(.system(size: showsCollage ? 15 : 21, weight: .semibold))
                        .foregroundStyle(usesLightForeground ? Color.white : Theme.accent)
                        .frame(width: showsCollage ? 28 : 46, height: showsCollage ? 28 : 46)
                        .background(usesLightForeground ? Color.white.opacity(0.20) : Theme.accent.opacity(0.12), in: Circle())
                }
                Spacer(minLength: 12)
                Text(title)
                    .font(Theme.Typography.sectionTitle.weight(.bold))
                    .foregroundStyle(usesLightForeground ? Color.white : Color.primary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(Theme.Typography.body)
                    .foregroundStyle(usesLightForeground ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
            .padding(Theme.Spacing.phonePage)
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: HomeLayout.coverCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HomeLayout.coverCornerRadius, style: .continuous)
                .strokeBorder(usesLightForeground ? Color.clear : Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    private var collageArtwork: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.32, green: 0.25, blue: 0.29), Color(white: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if !collageURLs.isEmpty {
                let gap: CGFloat = 3
                let tile = (Self.width - gap * 2) / 3
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<3, id: \.self) { column in
                        VStack(spacing: gap) {
                            ForEach(0..<4, id: \.self) { row in
                                CachedAsyncImage(url: collageURLs[(column * 4 + row) % collageURLs.count])
                                    .frame(width: tile, height: tile)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                        }
                        .offset(y: column == 1 ? -tile * 0.55 : -tile * 0.15)
                    }
                }
                .frame(width: Self.width, height: Self.height, alignment: .top)
                .clipped()
            }
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityHidden(true)
    }
}

/// Card body without its own Button wrapper (for use inside NavigationLink).
struct CoverCardBody: View {
    let coverURL: URL?
    var playlistID: Int?
    let title: String
    var subtitle: String?
    var playCount: Int = 0
    var size: CGFloat = Theme.Layout.cardSize
    var cornerRadius: CGFloat = Theme.Radius.cover
    var reservesTitleSpace = false
    var onPlay: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.flexibleCardWidth) private var flexibleWidth
    /// 彩色卡片开关（主题设置里开）：没封面的卡片垫一层主题渐变。
    @ObservedObject private var theme = CodaThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            artwork
                .background {
                    if theme.colorfulCards && theme.themeID != .default {
                        theme.cardGradient(forItemID: title)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if playCount > 0 {
                        PlayCountBadge(count: playCount)
                            .padding(Theme.Spacing.small)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let onPlay {
                        PlayOverlayButton(visible: isHovering, action: onPlay)
                            .padding(Theme.Spacing.small)
                    }
                }

            Text(title)
                .font(Theme.Typography.body.weight(.medium))
                .lineLimit(2, reservesSpace: reservesTitleSpace)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            }
        }
        .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
        .contentShape(Rectangle())
        #if os(macOS)
        .scrollAwareHover { isHovering = $0 }
        #endif
    }

    @ViewBuilder
    private var artwork: some View {
        if flexibleWidth {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PlaylistArtwork(coverURL: coverURL, playlistID: playlistID)
                }
        } else {
            PlaylistArtwork(coverURL: coverURL, playlistID: playlistID)
                .frame(width: size, height: size)
        }
    }
}


/// Playlist rows with chart position in the trailing duration slot.
struct HomeToplistsSection: View {
    @ObservedObject var model: HomeViewModel
    let contentInset: CGFloat
    @Environment(\.openDestination) private var openDestination
    // Read, not observed: playback updates must not rebuild every chart row.
    private let player = PlayerService.shared
    private var phoneLayout = PhonePageLayout()

    init(model: HomeViewModel, contentInset: CGFloat) {
        self.model = model
        self.contentInset = contentInset
    }

    @ScaledMetric(relativeTo: .body) private var chartRowHeight: CGFloat = Theme.Layout.trackRowHeight

    /// Chart header row, its divider block, then ten song rows 1pt apart like the song shelves.
    private var toplistHeight: CGFloat {
        chartRowHeight + HomeToplistPreview.dividerBlockHeight + chartRowHeight * 10 + 9
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeLayout.headerSpacing) {
            NavigationLink(value: Destination.toplists) {
                HStack(spacing: Theme.Spacing.small) {
                    Text("排行榜").font(Theme.Typography.sectionTitle.bold())
                    DisclosureChevron()
                }
                .foregroundStyle(.primary)
                .frame(minHeight: HomeLayout.headerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看全部排行榜")
            .padding(.horizontal, contentInset)

            if model.loadingModules.contains(.toplists) {
                MusicLibraryLoadingView(rowsPerColumn: 10, scrollsHorizontally: true,
                                        showsHorizontalPanel: false,
                                        horizontalInset: Theme.Layout.trackListInset,
                                        fixedColumnWidth: Theme.Layout.homeSongColumnWidth)
            } else {
                GeometryReader { geometry in
                    // Same column geometry as the home song shelves.
                    let available = geometry.size.width - 2 * Theme.Layout.trackListInset
                    let peek: CGFloat = phoneLayout.isEnabled && model.toplists.count > 1 ? 20 : 0
                    let width = max(1, min(Theme.Layout.homeSongColumnWidth, available - peek))
                    HorizontalPagingScrollView(itemCount: model.toplists.count,
                                               resetKey: model.toplists.first?.id, pageSize: 3,
                                               horizontalInset: Theme.Layout.trackListInset,
                                               spacing: Theme.Spacing.group) { visibleCount in
                        LazyHStack(alignment: .top, spacing: Theme.Spacing.group) {
                            ForEach(model.toplists.prefix(visibleCount)) { chart in
                                HomeToplistPreview(
                                    chart: chart,
                                    reservedHeight: toplistHeight,
                                    tracks: model.toplistTracks[chart.id],
                                    previousRanks: model.toplistPreviousRanks[chart.id] ?? [:],
                                    growthRatios: model.toplistGrowthRatios[chart.id] ?? [:],
                                    failed: model.failedToplistIDs.contains(chart.id),
                                    onRetry: { Task { await model.retryToplistTracks(id: chart.id) } },
                                    onOpen: { openDestination(.playlist(chart.id)) },
                                    onPlay: { track, tracks in
                                        player.play(tracks: tracks, source: .playlist(chart.id), startAt: track,
                                                    context: .playlist(id: chart.id, name: chart.name))
                                    }
                                )
                                .equatable()
                                .frame(width: width)
                                .task { await model.loadToplistTracks(id: chart.id) }
                            }
                        }
                    } placeholder: {
                        EmptyView()
                    }
                }
                .frame(height: model.toplists.isEmpty ? 0 : toplistHeight)
            }
        }
    }
}

/// Equatable on its data only: one chart finishing its load must not rebuild
/// the ten rows of every other chart. The closures act on the same chart id.
private struct HomeToplistPreview: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chart.id == rhs.chart.id && lhs.chart.name == rhs.chart.name
            && lhs.chart.coverImgUrl == rhs.chart.coverImgUrl
            && lhs.chart.updateFrequency == rhs.chart.updateFrequency
            && lhs.reservedHeight == rhs.reservedHeight && lhs.failed == rhs.failed
            && lhs.tracks?.map(\.id) == rhs.tracks?.map(\.id)
            && lhs.previousRanks == rhs.previousRanks && lhs.growthRatios == rhs.growthRatios
    }

    let chart: ToplistItem
    let reservedHeight: CGFloat
    let tracks: [Track]?
    let previousRanks: [Int: Int]
    let growthRatios: [Int: Double]
    let failed: Bool
    let onRetry: () -> Void
    let onOpen: () -> Void
    let onPlay: (Track, [Track]) -> Void

    /// Divider plus the space above and below it.
    static let dividerBlockHeight: CGFloat = Theme.Spacing.small * 2 + 0.5

    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = Theme.Layout.trackRowHeight
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = Theme.Layout.trackArtworkSize

    private var contentMinHeight: CGFloat { reservedHeight - rowHeight - Self.dividerBlockHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The chart header is laid out exactly like a song row.
            Button(action: onOpen) {
                HStack(spacing: Theme.Spacing.control) {
                    CachedAsyncImage(url: chart.coverImgUrl?.resizedImageURL(160), animated: false)
                        .frame(width: artworkSize, height: artworkSize)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        Text(chart.name)
                            .font(Theme.Typography.trackTitle)
                            .lineLimit(1)
                        if let frequency = chart.updateFrequency, !frequency.isEmpty {
                            Text(frequency)
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    DisclosureChevron()
                        .frame(width: TrackRow.chartRankColumnWidth)
                }
                .padding(.horizontal, Theme.Layout.trackRowHorizontalInset)
                .foregroundStyle(.primary)
                .frame(height: rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, Theme.Spacing.small)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, Theme.Layout.trackRowHorizontalInset)
                .padding(.bottom, Theme.Spacing.small)
            if let tracks, !tracks.isEmpty {
                LazyVStack(spacing: 1) {
                    ForEach(Array(tracks.prefix(10).enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, index: index + 1, style: .likedMusic,
                                 showsLikeButton: false,
                                 showsAlbumSubtitle: true,
                                 chartRank: index + 1, previousChartRank: previousRanks[track.id],
                                 chartGrowthRatio: growthRatios[track.id]) {
                            onPlay(track, tracks)
                        }
                        .accessibilityLabel("第 \(index + 1) 名，\(track.name)，\(track.artistNames)")
                    }
                }
            } else if failed {
                VStack(spacing: Theme.Spacing.control) {
                    Text("榜单歌曲加载失败").foregroundStyle(.secondary)
                    Button("重试", action: onRetry).frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity, minHeight: contentMinHeight)
            } else if tracks != nil {
                Text("暂无榜单歌曲")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: contentMinHeight)
            } else {
                ProgressView("正在加载榜单")
                    .frame(maxWidth: .infinity, minHeight: contentMinHeight)
            }
        }
        .frame(maxWidth: .infinity, minHeight: reservedHeight, alignment: .topLeading)
    }
}
