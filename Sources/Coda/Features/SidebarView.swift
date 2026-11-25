import SwiftUI

enum SidebarLayout {
    static let outerInset: CGFloat = 8
    static let rowInset: CGFloat = 16
    static let rowPadding: CGFloat = 12
    static let contentInset = rowInset + rowPadding
    static let hitSize: CGFloat = 44
}

struct SidebarView: View {
    @Binding var selection: SidebarItem
    var onSearchSelected: () -> Void = {}

    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var accountManager = MusicAccountManager.shared
    @ScaledMetric(relativeTo: .headline) private var identityTextSize: CGFloat = 14
    @ScaledMetric(relativeTo: .title2) private var sectionTextSize: CGFloat = 20
    @State private var showNewPlaylist = false
    @State private var showAppleImport = false
    @State private var newPlaylistName = ""
    @State private var showAccountSwitcher = false
    @State private var isHoveringIdentity = false
    @StateObject private var localPlaylists = LocalPlaylistStore.shared
    @State private var gearTurns: Double = 0
    @Namespace private var selectionHighlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    private var sections: some View {
        Group {
            SidebarSection {
                row(.home, title: "推荐", icon: "house.fill")
                // One 探索 entry, as in the tab bar: search with the 精选 shelves under it.
                row(.search, title: "探索", icon: "magnifyingglass")
                row(.account, title: "账户", icon: "person.crop.circle")
            } header: {
                sectionTitle("音乐")
            }

            if !account.hasAuthCookie && account.provider.supports(.downloads) {
                SidebarSection {
                    row(.downloaded, title: "已下载", icon: "arrow.down.circle.fill")
                } header: {
                    sectionTitle("我的")
                }
            }
            if account.hasAuthCookie {
                SidebarSection {
                    if account.provider == .netease || account.likedSongsPlaylist != nil {
                        row(.likedSongs, title: "我喜欢的音乐", icon: "heart.fill")
                    }
                    if account.provider.supports(.downloads) {
                        row(.downloaded, title: "已下载", icon: "arrow.down.circle.fill")
                    }
                    if account.provider.supports(.recentPlays) {
                        row(.recents, title: "最近播放", icon: "clock.fill")
                    }
                    if account.provider.supports(.collectionAlbums) || account.provider.supports(.collectionArtists) {
                        row(.collections, title: "我的收藏", icon: "star.fill")
                    }
                    if account.provider.supports(.cloud) {
                        row(.cloud, title: "音乐云盘", icon: "icloud.fill")
                    }
                } header: {
                    sectionTitle("我的")
                }

                if !account.createdPlaylists.isEmpty || account.provider.supports(.playlistCreation) {
                    SidebarSection {
                        ForEach(account.createdPlaylists) { playlist in
                            playlistRow(playlist).transition(playlistTransition)
                        }
                    } header: {
                        HStack(spacing: 4) {
                            sectionTitle(LocalizedStringKey(account.provider.playlistSectionTitle))
                            Spacer()
                            Button {
                                showNewPlaylist = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: SidebarLayout.hitSize, height: SidebarLayout.hitSize)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("新建歌单")
                            .disabled(!account.provider.supports(.playlistCreation))
                            Button {
                                showAppleImport = true
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: SidebarLayout.hitSize, height: SidebarLayout.hitSize)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("导入 Apple Music 歌单")
                        }
                    }
                    .modifier(PlaylistEditAnimation(ids: account.createdPlaylists.map(\.id), owner: libraryOwner))
                }

                if !localPlaylists.playlists.isEmpty {
                    SidebarSection {
                        ForEach(localPlaylists.playlists) { playlist in
                            localPlaylistRow(playlist).transition(playlistTransition)
                        }
                    } header: {
                        sectionTitle("本地歌单")
                    }
                }

                if !account.subscribedPlaylists.isEmpty {
                    SidebarSection {
                        ForEach(account.subscribedPlaylists) { playlist in
                            playlistRow(playlist).transition(playlistTransition)
                        }
                    } header: {
                        sectionTitle("收藏的歌单")
                    }
                    .modifier(PlaylistEditAnimation(ids: account.subscribedPlaylists.map(\.id), owner: libraryOwner))
                }
            }
        }
    }

    /// Whose library the sidebar shows; playlist edits animate only within one owner.
    private var libraryOwner: String { "\(account.provider.rawValue)|\(accountManager.currentID ?? "guest")" }

    private var playlistTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                platformMenu
                Spacer(minLength: 0)
                settingsButton
            }
            .padding(.leading, SidebarLayout.contentInset)
            .padding(.trailing, SidebarLayout.rowInset)
            .frame(minHeight: 56)
            .padding(.top, 8)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    sections
                }
                // The selection highlight slides between rows (matchedGeometryEffect in SidebarRowStyle).
                .animation(reduceMotion ? nil : AppAnimation.snappy, value: selection)
                .padding(.horizontal, SidebarLayout.rowInset)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .tint(Theme.accent)
#if os(macOS)
        // Unlike .hidden, .never also applies when a mouse is connected.
        .scrollIndicators(.never)
#endif
        .panelRefresh(key: "sidebar-library") { await account.refreshLibrary(force: $0) }
        .alert("新建歌单", isPresented: $showNewPlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                newPlaylistName = ""
                guard !name.isEmpty else { return }
                Task {
                    do {
                        try await NeteaseAPI.createPlaylist(name: name, isPrivate: false)
                        await account.refreshLibrary()
                        ToastCenter.shared.show(String(localized: "歌单已创建"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
            Button("取消", role: .cancel) { newPlaylistName = "" }
        }
        .sheet(isPresented: $showAppleImport) {
            AppleMusicImportSheet()
                .environmentObject(account)
        }
    }

    /// Platforms follow accounts: switching the account switches the platform.
    /// A popover rather than a Menu, so entries can show avatars and status dots.
    private var platformMenu: some View {
        Button { showAccountSwitcher = true } label: {
            ZStack(alignment: .leading) {
                identityRow(currentIdentity, showsSpinner: accountManager.isSwitching, showsChevron: true)
                    .id(libraryOwner)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))
            }
            .animation(reduceMotion ? AppAnimation.quick : AppAnimation.standard, value: libraryOwner)
                .frame(minHeight: SidebarLayout.hitSize)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : AppAnimation.quick) { isHoveringIdentity = hovering }
        }
        .disabled(accountManager.isSwitching)
        .accessibilityLabel("切换账号")
        .accessibilityValue(Text(currentIdentity.accessibilityText))
        .accessibilityIdentifier("sidebarPlatformMenu")
        .popover(isPresented: $showAccountSwitcher, arrowEdge: .bottom) { accountSwitcher }
        .task(id: "\(accountManager.currentID ?? "guest")|\(currentAccount?.credentials.hashValue ?? 0)") {
            try? accountManager.rememberCurrent()
            if let current = currentAccount { await accountManager.refreshStatus(of: current) }
        }
    }

    private var accountSwitcher: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(accountManager.accounts) { item in
                    switcherRow(identity(for: item), isCurrent: accountManager.currentID == item.id) { selectAccount(item) }
                }
                // Platforms without any signed-in account appear inline as guest entries.
                ForEach(guestProviders) { provider in
                    switcherRow(.guest(provider), isCurrent: accountManager.isBrowsingAsGuest(provider)) { browseAsGuest(provider) }
                }
            }
            .padding(6)
        }
        .frame(width: 300)
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accent)
        .task { await accountManager.refreshMemberships() }
        .modifier(PopoverOnCompact())
    }

    private func switcherRow(_ identity: SidebarIdentity, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button {
            showAccountSwitcher = false
            guard !isCurrent else { return }
            action()
        } label: {
            HStack(spacing: 8) {
                identityRow(identity, showsSpinner: false)
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(SwitcherRowButtonStyle(isCurrent: isCurrent))
        .disabled(accountManager.isSwitching)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(identity.accessibilityText)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private var guestProviders: [MusicProvider] {
        let signedIn = Set(accountManager.accounts.map(\.provider))
        return MusicProvider.allCases.filter { !signedIn.contains($0) || accountManager.isBrowsingAsGuest($0) }
    }

    private var currentAccount: MusicAccount? {
        guard let id = accountManager.currentID else { return nil }
        return accountManager.accounts.first { $0.id == id }
    }

    private var currentIdentity: SidebarIdentity {
        guard account.isLoggedIn else { return .guest(account.provider) }
        if let item = currentAccount { return identity(for: item) }
        // Signed in but not saved to the account list yet.
        return SidebarIdentity(provider: account.provider, isGuest: false,
                               nickname: account.profile?.nickname ?? "", avatarURL: account.profile?.avatarUrl,
                               validity: .unknown, membership: nil, isMember: false)
    }

    private func identity(for item: MusicAccount) -> SidebarIdentity {
        SidebarIdentity(provider: item.provider, isGuest: false, nickname: item.nickname, avatarURL: item.avatarURL,
                        validity: accountManager.validity(for: item),
                        membership: accountManager.membershipTitle(for: item),
                        isMember: item.membership?.membership.isMember == true)
    }

    /// Mirrors the settings account card, laid out horizontally:
    /// avatar, then platform with validity dot, then nickname · membership.
    private func identityRow(_ identity: SidebarIdentity, showsSpinner: Bool, showsChevron: Bool = false) -> some View {
        HStack(spacing: 10) {
            sidebarAvatar(identity)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(identity.provider.name)
                        .font(.system(size: identityTextSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Group {
                        if showsSpinner {
                            ProgressView().controlSize(.mini)
                        } else if !identity.isGuest {
                            AccountValidityBadge(status: identity.validity)
                        }
                    }
                    .frame(height: 12)
                    if showsChevron {
                        // Same arrow and hover nudge as the main content's section headers.
                        DisclosureChevron()
                            .rotationEffect(.degrees(showAccountSwitcher ? 90 : 0))
                            .offset(x: isHoveringIdentity && !showAccountSwitcher ? 2 : 0)
                            .animation(reduceMotion ? nil : AppAnimation.snappy, value: showAccountSwitcher)
                    }
                }
                HStack(spacing: 0) {
                    if identity.isGuest {
                        Text("游客").foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(identity.nickname)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let membership = identity.membership {
                            Text(" · ").foregroundStyle(.tertiary)
                            Text(membership)
                                .foregroundStyle(identity.isMember ? Theme.accent : .secondary)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func sidebarAvatar(_ identity: SidebarIdentity) -> some View {
        if identity.isGuest {
            ZStack {
                Circle().strokeBorder(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                Image(systemName: "person.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 40, height: 40)
        } else {
            CachedAsyncImage(url: identity.avatarURL.flatMap { $0.isEmpty ? nil : URL(string: $0) }) {
                ZStack {
                    Circle().fill(.quaternary.opacity(0.5))
                    Text(String(identity.nickname.prefix(1)))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        }
    }

    private func browseAsGuest(_ provider: MusicProvider) {
        Task {
            do {
                try await accountManager.browseAsGuest(provider)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func selectAccount(_ item: MusicAccount) {
        Task {
            do {
                try await accountManager.select(item)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private var settingsButton: some View {
        Button {
            selection = .settings
            if !reduceMotion { gearTurns += 1 }
        } label: { settingsIcon }
        .buttonStyle(SidebarSettingsButtonStyle())
        .tint(Theme.accent)
        .accessibilityLabel("设置")
        .accessibilityIdentifier("sidebarSettingsButton")
    }

    private var settingsIcon: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 16))
            // Half a turn lands the symmetric gear back on its resting outline.
            .rotationEffect(.degrees(gearTurns * 180))
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: gearTurns)
            .frame(width: SidebarLayout.hitSize, height: 56)
            .contentShape(Rectangle())
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: sectionTextSize, weight: .bold))
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: SidebarItem, title: LocalizedStringKey, icon: String) -> some View {
        SidebarRow(title: Text(title), iconSize: 22, isSelected: selection == item, highlight: selectionHighlight) {
            selection = item
            if item == .search { onSearchSelected() }
        } icon: {
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Theme.accent)
        }
    }

    private func playlistRow(_ playlist: PlaylistSummary) -> some View {
        let iconSize: CGFloat = 24
        return SidebarRow(title: Text(playlist.name), iconSize: iconSize, isSelected: selection == .playlist(playlist.id), highlight: selectionHighlight) {
            selection = .playlist(playlist.id)
        } icon: {
            PlaylistArtwork(playlist: playlist, pixelSize: 64, animated: false)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .contextMenu {
            Button("播放") {
                Task {
                    if let detail = try? await NeteaseAPI.playlistDetail(id: playlist.id) {
                        await playPlaylist(detail)
                    }
                }
            }
            Divider()
            if playlist.creator?.userId == account.profile?.userId, account.provider.supports(.playlistDeletion), !playlist.isLikedSongsList {
                Button("删除歌单", role: .destructive) {
                    Task {
                        do {
                            try await NeteaseAPI.deletePlaylist(id: playlist.id)
                            if selection == .playlist(playlist.id) { selection = .home }
                            await account.refreshLibrary()
                        } catch { ToastCenter.shared.show("删除失败：\(error.localizedDescription)") }
                    }
                }
            } else if playlist.creator?.userId != account.profile?.userId, account.provider.supports(.playlistSubscriptions) {
                Button("取消收藏") {
                    Task {
                        do {
                            try await NeteaseAPI.subscribePlaylist(id: playlist.id, subscribe: false)
                            await account.refreshLibrary()
                        } catch { ToastCenter.shared.show("取消收藏失败：\(error.localizedDescription)") }
                    }
                }
            }
        }
    }

    /// A local playlist (imported Apple Music playlist): its tracks can mix
    /// platforms, so the row uses the first track's cover and a play action
    /// that plays the saved tracks directly.
    private func localPlaylistRow(_ playlist: LocalPlaylist) -> some View {
        let iconSize: CGFloat = 24
        return SidebarRow(title: Text(playlist.name), iconSize: iconSize, isSelected: selection == .localPlaylist(playlist.id), highlight: selectionHighlight) {
            selection = .localPlaylist(playlist.id)
        } icon: {
            PlaylistArtwork(coverURL: playlist.coverURL, playlistID: nil, pixelSize: 64, animated: false)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .contextMenu {
            Button("播放") {
                PlayerService.shared.play(tracks: playlist.tracks, source: .none)
            }
            Divider()
            Button("删除歌单", role: .destructive) {
                if selection == .localPlaylist(playlist.id) { selection = .home }
                localPlaylists.delete(id: playlist.id)
            }
        }
    }

    private func playPlaylist(_ detail: NeteaseAPI.PlaylistDetailResponse) async {
        var tracks = detail.playlist.tracks
        if tracks.count < detail.playlist.trackCount {
            let ids = detail.playlist.trackIds.map(\.id)
            if let full = try? await NeteaseAPI.songDetails(ids: Array(ids.prefix(1000))) {
                tracks = full.songs
            }
        }
        PlayerService.shared.play(tracks: tracks, source: .playlist(detail.playlist.id))
    }

}

private struct SidebarSettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.tint)
            .background {
                Circle()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .frame(width: SidebarLayout.hitSize, height: SidebarLayout.hitSize)
            }
    }
}

private struct SidebarSection<Content: View, Header: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header()
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.horizontal, SidebarLayout.rowPadding)
            VStack(spacing: 2, content: content)
        }
    }
}

private struct SidebarRow<Icon: View>: View {
    let title: Text
    let iconSize: CGFloat
    let isSelected: Bool
    let highlight: Namespace.ID
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var iconScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var iconBounce: CGFloat = 1
    @State private var bounceTask: Task<Void, Never>?

    var body: some View {
        Button {
            bounceIcon()
            action()
        } label: {
            HStack(spacing: SidebarLayout.rowPadding) {
                icon()
                    .frame(width: iconSize * iconScale, height: iconSize * iconScale)
                    .scaleEffect(iconBounce)
                    .accessibilityHidden(true)
                title
                    .font(.system(size: textSize))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, SidebarLayout.rowPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: SidebarLayout.hitSize, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle(isSelected: isSelected, isHovered: isHovered, highlight: highlight, reduceMotion: reduceMotion))
        // Pointer hover on Mac and on iPad with a trackpad or mouse.
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : AppAnimation.quick) { isHovered = hovering }
        }
        .onDisappear { bounceTask?.cancel(); iconBounce = 1 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// One pop on tap only; selection changes from elsewhere never bounce.
    private func bounceIcon() {
        guard !reduceMotion else { return }
        bounceTask?.cancel()
        bounceTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.1)) { iconBounce = 1.15 }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { iconBounce = 1; return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { iconBounce = 1 }
        }
    }
}

private struct SidebarRowStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool
    let highlight: Namespace.ID
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .background {
                ZStack {
                    if isSelected {
                        // One highlight shared by all rows, so it slides to the new selection.
                        shape.fill(Color.primary.opacity(0.10))
                            .matchedGeometryEffect(id: "sidebarSelection", in: highlight)
                    }
                    shape.fill(Color.primary.opacity(configuration.isPressed ? 0.08 : isHovered && !isSelected ? 0.05 : 0))
                }
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : AppAnimation.snappy, value: configuration.isPressed)
    }
}

/// Animates small playlist edits (create, delete, unsubscribe) only, so a first
/// load or an account switch does not slide every row in.
private struct PlaylistEditAnimation<ID: Hashable>: ViewModifier {
    let ids: [ID]
    let owner: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previous: (owner: String, ids: [ID])?

    func body(content: Content) -> some View {
        content
            .animation(isEdit ? (reduceMotion ? AppAnimation.quick : AppAnimation.standard) : nil, value: ids)
            .onAppear { previous = (owner, ids) }
            .onChange(of: ids) { previous = (owner, $0) }
    }

    private var isEdit: Bool {
        guard let previous, previous.owner == owner else { return false }
        return (1...2).contains(Set(previous.ids).symmetricDifference(ids).count)
    }
}

struct AccountDetailsView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openLogin) private var openLogin
    @Environment(\.openDestination) private var openDestination
    private var layout = ProfileDetailLayout()
    @State private var detailRefresh = PanelRefreshGate()
    @State private var recordsRefresh = PanelRefreshGate()
    @State private var displayedAccount: String?
    @State private var displayedRecordsKey = ""
    @State private var statisticsRevision = 0
    @State private var week = true
    @State private var qqRankPeriod = 2
    @State private var records: [PlayRecordItem] = []
    @State private var isLoadingRecords = false
    @State private var recordError: String?
    @State private var detail: NeteaseAPI.UserDetailResponse?
    @State private var detailFailed = false
    @State private var isLoadingCollections = true

    private let rankingOnly: Bool

    init(rankingOnly: Bool = false) { self.rankingOnly = rankingOnly }

    var body: some View {
        Group {
            if let profile = account.profile {
                ProfileDetailPage(artworkBackdropURL: profile.avatarUrl, usesArtworkBackdrop: true) {
                    if !rankingOnly {
                        profileHeader(profile)
                            .accessibilityIdentifier("accountPageHeader")
                    }
                    if account.provider.supports(.playRanking) {
                        rankingHeader.padding(.horizontal, layout.contentInset)
                        rankingSongs
                    }
                    if !rankingOnly {
                        playlistSection(LocalizedStringKey(account.provider.playlistSectionTitle), section: .createdPlaylists,
                                        playlists: account.createdPlaylists)
                        if account.provider.supports(.playlistSubscriptions) {
                            playlistSection("收藏的歌单", section: .subscribedPlaylists, playlists: account.subscribedPlaylists)
                        }
                        if account.provider.supports(.collectionAlbums) { collectedAlbumsSection }
                        if account.provider.supports(.collectionArtists) { collectedArtistsSection }
                    }
                    PlayerClearanceSpacer()
                }
                .id(profile.userId)
                .accessibilityIdentifier("accountProfileScroll")
            } else {
                #if os(iOS)
                ProfileDetailPage(usesArtworkBackdrop: true) {
                    PlaylistDetailHero(artworkURL: nil, title: String(localized: "账户"),
                                           subtitle: String(localized: "登录\(account.provider.name)"), avatarURL: nil,
                                           metadataText: String(localized: "同步我喜欢的音乐、歌单与收藏"),
                                           circularArtwork: true, showsAvatar: false) {
                        profileActions
                    }
                    if account.provider.supports(.accountSync) {
                        SyncedLoginButtons().padding(.horizontal, layout.contentInset)
                    }
                    PlayerClearanceSpacer()
                }
                #else
                VStack(spacing: Theme.Spacing.section) {
                    Label("登录后查看账户信息", systemImage: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Button("登录\(account.provider.name)", action: openLogin)
                        .buttonStyle(.borderedProminent)
                    if account.provider.supports(.accountSync) { SyncedLoginButtons() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }
        }
        #if os(macOS)
        .navigationTitle("账户")
        #else
        .navigationTitle(rankingOnly ? "播放排行" : "")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .panelDataChanged)) { _ in
            // Playback reports invalidate statistics even inside their normal cache lifetime.
            statisticsRevision += 1
        }
        .panelRefresh(key: "account:\(week):\(qqRankPeriod):\(account.libraryRevision):\(statisticsRevision)") { force in
            if displayedAccount != MusicProviderContext.shared.authenticationKey {
                displayedAccount = MusicProviderContext.shared.authenticationKey
                detail = nil; records = []; detailFailed = false
                detailRefresh.invalidate(); recordsRefresh.invalidate()
            }
            async let profile: Void = loadDetail(force: force)
            async let ranking: Void = loadRecords(force: force)
            await account.refreshLibrary(force: force)
            isLoadingCollections = account.likedAlbums.isEmpty && account.likedArtists.isEmpty
            await account.refreshSublists(force: force)
            isLoadingCollections = false
            _ = await (profile, ranking)
        }
    }

    private func profileHeader(_ profile: UserProfile) -> some View {
        ProfileDetailHeader(imageURL: profile.avatarUrl, title: profile.nickname, category: "账户") {
            if let signature = profile.signature, !signature.isEmpty {
                Text(signature)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.small) {
                    listeningStatistics
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    listeningStatistics
                }
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            Text("用户 ID \(account.displayUserID)")
                .font(Theme.Typography.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            if let stats = detail?.profile {
                Text("\(stats.follows?.formatted() ?? "—") 关注 · \(stats.followeds?.formatted() ?? "—") 粉丝 · \(stats.playlistCount?.formatted() ?? "—") 歌单")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            if detailFailed {
                Button("账户统计加载失败，点此重试") {
                    Task { await loadDetail() }
                }
                .font(Theme.Typography.caption)
            }
        } actions: {
            profileActions
        }
    }

    private var profileActions: some View {
        let hasProfile = account.profile != nil
        return PlaylistPrimaryActions(
            isSaved: false, canSave: hasProfile && account.provider.supports(.cloud),
            canPlay: !hasProfile || (account.provider.supports(.playRanking) ? !records.isEmpty && !isLoadingRecords : account.likedSongsPlaylist != nil),
            isSaving: false,
            onToggleSaved: { openDestination(.cloud) },
            onPlayAll: {
                if !hasProfile { openLogin() }
                else if account.provider.supports(.playRanking) { playRecords() }
                else if let liked = account.likedSongsPlaylist { openDestination(.playlist(liked.id)) }
            },
            leadingIcon: "icloud.fill",
            primaryTitle: hasProfile ? (account.provider.supports(.playRanking) ? "播放排行" : "我喜欢的音乐") : "登录",
            primaryIcon: hasProfile ? "play.fill" : "person.crop.circle",
            showsSaveButton: hasProfile && account.provider.supports(.cloud),
            saveAccessibilityLabel: String(localized: "云盘"),
            saveAccessibilityIdentifier: "accountCloud"
        ) {
            Menu {
                if hasProfile && account.provider.supports(.recentPlays) {
                    Button { openDestination(.recents) } label: {
                        Label("最近播放", systemImage: "clock.fill")
                    }
                }
                if hasProfile && (account.provider.supports(.collectionAlbums) || account.provider.supports(.collectionArtists)) {
                    Button { openDestination(.collections) } label: {
                        Label("我的收藏", systemImage: "star")
                    }
                }
                if account.provider.supports(.downloads) {
                    Button { openDestination(.downloaded) } label: { Label("下载", systemImage: "arrow.down.circle.fill") }
                }
                if account.isLoggedIn {
                    Button("退出登录", role: .destructive) {
                        Task {
                            do { try await account.logout() }
                            catch { ToastCenter.shared.show(error.localizedDescription) }
                        }
                    }
                }
            } label: { PlaylistMoreLabel() }
            .accessibilityLabel("账户选项")
            .accessibilityIdentifier("accountMoreActions")
        }
    }

    @ViewBuilder
    private var listeningStatistics: some View {
        if !account.provider.supports(.profileStatistics) { Text(account.provider.name) }
        if let level = detail?.level {
            Text("Lv.\(level)")
        }
        if let count = detail?.listenSongs {
            Text("累计听歌 \(count.formatted()) 首")
        }
    }

    private var usesVerticalRanking: Bool {
        #if os(iOS)
        rankingOnly || UIDevice.current.userInterfaceIdiom == .phone
        #else
        rankingOnly
        #endif
    }

    private func accountModuleAction(_ destination: Destination) -> (() -> Void)? {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad, !rankingOnly else { return nil }
        return { openDestination(destination) }
        #else
        return nil
        #endif
    }

    private var rankingHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.component) {
                SectionHeader(title: "听歌排行", action: accountModuleAction(.playRanking))
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                rankingPeriodPicker
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.control) {
                SectionHeader(title: "听歌排行", action: accountModuleAction(.playRanking))
                rankingPeriodPicker
            }
        }
    }

    @ViewBuilder
    private var rankingPeriodPicker: some View {
        if account.provider == .qq {
            Picker("排行时间", selection: $qqRankPeriod) {
                Text("日").tag(1)
                Text("周").tag(2)
                Text("月").tag(3)
                Text("年").tag(4)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        } else {
            Picker("排行时间", selection: $week) {
                Text("最近一周").tag(true)
                Text("全部时间").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
    }

    /// Fades between periods and between the spinner and the loaded ranking.
    private var rankingSongs: some View {
        rankingSongsContent
            .contentCrossfade(on: "\(week)|\(qqRankPeriod)|\(isLoadingRecords)|\(recordError != nil)|\(records.isEmpty)")
    }

    @ViewBuilder
    private var rankingSongsContent: some View {
        if isLoadingRecords {
            ProgressView("正在加载排行")
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if let recordError {
            ErrorStateView(message: recordError) { Task { await loadRecords() } }
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if records.isEmpty {
            EmptyStateView(icon: "chart.bar.xaxis", title: "暂无听歌排行")
                .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            let playCounts = Dictionary(records.map { ($0.song.id, $0.playCount) },
                                        uniquingKeysWith: { first, _ in first })
            MusicTrackPanel(tracks: records.map(\.song), scrollsHorizontally: !usesVerticalRanking,
                            context: .recents, showsRowSeparators: false, trailingText: { track in
                playCounts[track.id].map { String(localized: "\($0) 次") }
            })
            .accessibilityIdentifier("accountRankingScroll")
        }
    }

    private func playlistSection(_ title: LocalizedStringKey, section: LibrarySection, playlists: [PlaylistSummary]) -> some View {
        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
            SectionHeader(title: title, subtitle: "\(playlists.count)",
                          action: accountModuleAction(.librarySection(section)))
                .padding(.horizontal, layout.contentInset)
            if playlists.isEmpty {
                Text("暂无歌单")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, layout.contentInset)
                    .padding(.vertical, Theme.Spacing.control)
            } else {
                ProfileDetailCoverShelf(itemCount: playlists.count, resetKey: playlists.first?.id) { visibleCount in
                    ForEach(playlists.prefix(visibleCount)) { playlist in
                        Button {
                            openDestination(.playlist(playlist.id))
                        } label: {
                            PlaylistCoverCard(playlist: playlist,
                                              subtitle: String(localized: "\(playlist.trackCount) 首歌曲"))
                        }
                        .buttonStyle(.interactiveCard)
                    }
                }
            }
        }
    }

    private var collectedAlbumsSection: some View {
        collectionSection("收藏的专辑", section: .albums, count: account.likedAlbums.count, emptyMessage: "还没有收藏专辑") { visibleCount in
            ForEach(account.likedAlbums.prefix(visibleCount)) { album in
                Button {
                    openDestination(.album(album.id))
                } label: {
                    CoverCardBody(
                        coverURL: album.picUrl?.resizedImageURL(384),
                        title: album.name,
                        subtitle: album.artistName
                    )
                }
                .buttonStyle(.interactiveCard)
            }
        }
    }

    private var collectedArtistsSection: some View {
        collectionSection("收藏的歌手", section: .artists, count: account.likedArtists.count, emptyMessage: "还没有收藏歌手") { visibleCount in
            ForEach(account.likedArtists.prefix(visibleCount)) { artist in
                Button {
                    openDestination(.artist(artist.id))
                } label: {
                    ProfileDetailArtistCardBody(artist: artist)
                }
                .buttonStyle(.interactiveCard)
            }
        }
    }

    private func collectionSection<Content: View>(
        _ title: LocalizedStringKey, section: LibrarySection, count: Int, emptyMessage: LocalizedStringKey,
        @ViewBuilder content: @escaping (Int) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: layout.sectionSpacing) {
            SectionHeader(title: title, subtitle: "\(count)",
                          action: accountModuleAction(.librarySection(section)))
                .padding(.horizontal, layout.contentInset)
            if count == 0 {
                if isLoadingCollections {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    Group {
                        if let error = account.sublistsError { Text(error) } else { Text(emptyMessage) }
                    }
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, layout.contentInset)
                        .padding(.vertical, Theme.Spacing.control)
                }
            } else {
                ProfileDetailCoverShelf(itemCount: count, content: content)
            }
        }
    }

    @MainActor
    private func loadDetail(force: Bool = true) async {
        guard account.provider.supports(.profileStatistics), let uid = account.authenticatedAccountID else { return }
        guard let ticket = detailRefresh.begin(key: "\(uid):\(SidebarResources.playbackRevision):\(statisticsRevision)", lifetime: 60, force: force) else { return }
        var success = false
        defer { detailRefresh.finish(ticket, success: success) }
        do {
            let fetched = try await NeteaseAPI.userDetail(uid: uid)
            guard detailRefresh.accepts(ticket), account.authenticatedAccountID == uid else { return }
            detail = fetched
            detailFailed = false
            success = true
        } catch {
            guard detailRefresh.accepts(ticket), account.authenticatedAccountID == uid else { return }
            detailFailed = true
        }
    }

    private func playRecords(startAt track: Track? = nil) {
        PlayerService.shared.play(tracks: records.map(\.song), source: .none,
                                  startAt: track, context: .recents)
    }

    @MainActor
    private func loadRecords(force: Bool = true) async {
        guard account.provider.supports(.playRanking), account.isLoggedIn, let uid = account.profile?.userId else {
            isLoadingRecords = false
            return
        }
        let requestedWeek = week
        let period = qqRankPeriod
        let binding = MusicProviderContext.shared.authenticationKey
        let key = "\(binding ?? "guest"):\(uid):\(week):\(period)"
        guard let ticket = recordsRefresh.begin(key: "\(key):\(SidebarResources.playbackRevision):\(statisticsRevision)", lifetime: 300, force: force) else { return }
        if displayedRecordsKey != key { records = []; displayedRecordsKey = key }
        recordError = nil
        isLoadingRecords = records.isEmpty
        var success = false
        defer {
            if recordsRefresh.isCurrent(ticket) { isLoadingRecords = false }
            recordsRefresh.finish(ticket, success: success)
        }
        do {
            let fetched = try await (account.provider == .qq ? PlatformMusicAPI.shared.qqListeningRank(period: period)
                : NeteaseAPI.playRecords(uid: uid, week: requestedWeek))
            guard recordsRefresh.accepts(ticket), MusicProviderContext.shared.authenticationKey == binding, week == requestedWeek, qqRankPeriod == period else { return }
            records = fetched
            success = true
            isLoadingRecords = false
        } catch {
            guard recordsRefresh.accepts(ticket), MusicProviderContext.shared.authenticationKey == binding, week == requestedWeek, qqRankPeriod == period else { return }
            recordError = "听歌排行加载失败，请重试"
            isLoadingRecords = false
        }
    }
}

/// What the sidebar shows for one account or guest platform.
private struct SidebarIdentity {
    let provider: MusicProvider
    let isGuest: Bool
    let nickname: String
    let avatarURL: String?
    let validity: MusicAccountValidity
    let membership: String?
    let isMember: Bool

    static func guest(_ provider: MusicProvider) -> SidebarIdentity {
        SidebarIdentity(provider: provider, isGuest: true, nickname: "", avatarURL: nil,
                        validity: .unknown, membership: nil, isMember: false)
    }

    var accessibilityText: String {
        if isGuest { return "\(provider.name)，游客" }
        return [provider.name, nickname, validity.rawValue, membership].compactMap { $0 }.joined(separator: "，")
    }
}

private struct SwitcherRowButtonStyle: ButtonStyle {
    let isCurrent: Bool
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (isHovered || isCurrent) ? 0.06 : 0))
            )
            .onHover { isHovered = $0 }
    }
}

/// Keeps the account switcher a popover in compact widths (iPad Slide Over/Split View).
private struct PopoverOnCompact: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { content.presentationCompactAdaptation(.popover) } else { content }
        #else
        content
        #endif
    }
}
