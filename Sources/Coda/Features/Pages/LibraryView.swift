import SwiftUI

// The same library page is used by phone tabs and compact windows.

struct LibraryView: View {
    @Binding var showLogin: Bool
    @Environment(\.openDestination) private var openDestination
    @EnvironmentObject private var account: AccountStore
    @State private var showSettings = false
    @State private var showNewPlaylist = false
    @State private var showAppleImport = false
    @State private var newPlaylistName = ""
    @StateObject private var profileDetail = PanelResource<NeteaseAPI.UserDetailResponse?>(nil)
    @StateObject private var localPlaylists = LocalPlaylistStore.shared

    var phoneLayout = PhonePageLayout()
    private var isPhone: Bool { phoneLayout.isEnabled }

    private var phoneCreatedPlaylists: [PlaylistSummary] {
        guard let liked = account.likedSongsPlaylist else { return account.createdPlaylists }
        return [liked] + account.createdPlaylists.filter { $0.id != liked.id }
    }

    var body: some View {
        Group {
            if isPhone {
                phonePage
            } else {
                tabletPage
            }
        }
        .textCase(nil)
        .appRootNavigationTitle(String(localized: "我的"))
        .panelRefresh(key: "ios-library:\(account.sessionRevision):\(account.libraryRevision):\(SidebarResources.playbackRevision)") { force in
            guard account.provider.supports(.profileStatistics), let uid = account.authenticatedAccountID else {
                profileDetail.reset()
                await account.refreshLibrary(force: force)
                if account.provider.supports(.collectionArtists) { await account.refreshSublists(force: force) }
                return
            }
            await profileDetail.load(lifetime: 60,
                                     key: "\(account.libraryRevision):\(SidebarResources.playbackRevision)",
                                     force: force) {
                try await NeteaseAPI.userDetail(uid: uid)
            }
            if isPhone {
                await account.refreshSublists(force: force)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("设置")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") {
                                showSettings = false
                            }
                        }
                    }
            }
            .environment(\.openDestination, { destination in
                showSettings = false
                openDestination(destination)
            })
        }
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

    private var phonePage: some View {
        ProfileDetailPage() {
            if account.provider.supports(.accountSync) { SyncedLoginButtons() }
            if let profile = account.profile {
                PlaylistDetailHero(
                    artworkURL: profile.avatarUrl,
                    title: profile.nickname,
                    subtitle: profileSubtitle,
                    avatarURL: nil,
                    metadataText: profileMetadata,
                    circularArtwork: true, showsAvatar: false, showsArtwork: false
                ) {
                    profileActions
                }
            } else {
                PlaylistDetailHero(artworkURL: nil, title: String(localized: "我的"),
                                        subtitle: String(localized: "登录\(account.provider.name)"), avatarURL: nil,
                                        metadataText: String(localized: "同步我喜欢的音乐、歌单与收藏"),
                                        circularArtwork: true, showsAvatar: false, showsArtwork: false) {
                    VStack(spacing: 16) {
                        Button("登录\(account.provider.name)") { showLogin = true }
                        profileActions
                    }
                }
            }
            if account.hasAuthCookie {
                HStack {
                    SectionHeader(title: LocalizedStringKey(account.provider.playlistSectionTitle), action: {
                        openDestination(.librarySection(.createdPlaylists))
                    })
                    Spacer()
                    Button { showNewPlaylist = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("新建歌单")
                    .disabled(!account.provider.supports(.playlistCreation))
                    Button { showAppleImport = true } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("导入 Apple Music 歌单")
                }
                .padding(.horizontal, 16)
                playlistShelf(phoneCreatedPlaylists)
                if !localPlaylists.playlists.isEmpty {
                    SectionHeader(title: "本地歌单").padding(.horizontal, 16)
                    localPlaylistShelf(localPlaylists.playlists)
                }
                if account.provider.supports(.playlistSubscriptions) || !account.subscribedPlaylists.isEmpty {
                    SectionHeader(title: "收藏的歌单", action: {
                        openDestination(.librarySection(.subscribedPlaylists))
                    }).padding(.horizontal, 16)
                    if account.subscribedPlaylists.isEmpty {
                        emptyNote("暂无收藏歌单").padding(.horizontal, 16)
                    } else {
                        playlistShelf(account.subscribedPlaylists)
                    }
                }
                if account.provider.supports(.collectionAlbums) || !account.likedAlbums.isEmpty {
                    SectionHeader(title: "收藏的专辑", action: {
                        openDestination(.librarySection(.albums))
                    }).padding(.horizontal, 16)
                    if account.likedAlbums.isEmpty {
                        emptyNote(collectionEmptyMessage("还没有收藏专辑")).padding(.horizontal, 16)
                    } else {
                    ProfileDetailCoverShelf(itemCount: account.likedAlbums.count, resetKey: account.likedAlbums.first?.id) { visibleCount in
                        ForEach(account.likedAlbums.prefix(visibleCount)) { album in
                            NavigationLink(value: Destination.album(album.id)) {
                                CoverCardBody(coverURL: album.picUrl?.resizedImageURL(384),
                                              title: album.name, subtitle: album.artistName)
                            }
                            .buttonStyle(.interactiveCard)
                        }
                    }
                    }
                }
                if account.provider.supports(.collectionArtists) || !account.likedArtists.isEmpty {
                    SectionHeader(title: "收藏的歌手", action: {
                        openDestination(.librarySection(.artists))
                    }).padding(.horizontal, 16)
                    if account.likedArtists.isEmpty {
                        emptyNote(collectionEmptyMessage("还没有收藏歌手")).padding(.horizontal, 16)
                    } else {
                    ProfileDetailCoverShelf(itemCount: account.likedArtists.count, resetKey: account.likedArtists.first?.id) { visibleCount in
                        ForEach(account.likedArtists.prefix(visibleCount)) { artist in
                            NavigationLink(value: Destination.artist(artist.id)) {
                                ProfileDetailArtistCardBody(artist: artist)
                            }
                            .buttonStyle(.interactiveCard)
                        }
                    }
                    }
                }
            }
            PlayerClearanceSpacer()
        }
    }

    private var profileSubtitle: String {
        if account.provider.supports(.profileStatistics) {
            return "Lv.\(profileDetail.value?.level.map(String.init) ?? "—") · 累计听歌 \(profileDetail.value?.listenSongs?.formatted() ?? "—") 首"
        }
        return account.provider.name
    }

    private var profileMetadata: String {
        if account.provider.supports(.profileStatistics) {
            return "\(profileDetail.value?.profile?.follows?.formatted() ?? "—") 关注 · \(profileDetail.value?.profile?.followeds?.formatted() ?? "—") 粉丝 · \(profileDetail.value?.profile?.playlistCount?.formatted() ?? "—") 歌单"
        }
        return String(localized: "\(account.userPlaylists.count) 个歌单")
    }

    private var profileActions: some View {
        let hasHistory = account.provider.supports(.recentPlays)
        return PlaylistPrimaryActions(
            isSaved: false, canSave: account.provider.supports(.cloud),
            canPlay: hasHistory || account.likedSongsPlaylist != nil || !account.hasAuthCookie, isSaving: false,
            onToggleSaved: { openPhoneShortcut(.cloud) },
            onPlayAll: {
                if hasHistory { openPhoneShortcut(.recents) }
                else if let liked = account.likedSongsPlaylist { openPhoneShortcut(.playlist(liked.id)) }
                else { showLogin = true }
            },
            leadingIcon: "icloud.fill", primaryTitle: hasHistory ? "最近" : "我喜欢的音乐",
            primaryIcon: hasHistory ? "clock.fill" : "heart.fill",
            showsSaveButton: account.provider.supports(.cloud),
            saveAccessibilityLabel: String(localized: "云盘"),
            saveAccessibilityIdentifier: "profileCloud"
        ) {
            Menu { profileMoreActions } label: { PlaylistMoreLabel() }
                .accessibilityLabel("更多操作")
        }
    }

    private func openPhoneShortcut(_ destination: Destination, requiresLogin: Bool = true) {
        if requiresLogin && !account.hasAuthCookie {
            showLogin = true
        } else {
            openDestination(destination)
        }
    }

    private var tabletPage: some View {
        List {
            // Profile / Login header
            Section {
                if account.provider.supports(.accountSync) { SyncedLoginButtons() }
                if let profile = account.profile {
                    profileHeader(profile)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0))
                        .listRowBackground(Color.clear)
                } else {
                    Button {
                        showLogin = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 32))
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("登录\(account.provider.name)")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("同步我喜欢的音乐、歌单与收藏")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    guestProfileShortcuts
                        .font(.system(size: 16, weight: .semibold))
                        .buttonStyle(.pressable)
                        .listRowSeparator(.hidden)
                }
            }

            if account.hasAuthCookie {
                Section("我的音乐") {
                    if let liked = account.likedSongsPlaylist {
                        NavigationLink(value: Destination.playlist(liked.id)) {
                            Label("我喜欢的音乐", systemImage: "heart.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }

            if account.hasAuthCookie {
                if !account.createdPlaylists.isEmpty || account.provider.supports(.playlistCreation) {
                    Section {
                        if account.createdPlaylists.isEmpty {
                            Text("还没有创建歌单").foregroundStyle(.secondary)
                        } else {
                            playlistShelf(account.createdPlaylists)
                        }
                    } header: {
                        HStack {
                            SectionHeader(title: LocalizedStringKey(account.provider.playlistSectionTitle), action: {
                        openDestination(.librarySection(.createdPlaylists))
                    })
                            Spacer()
                            Button {
                                showNewPlaylist = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .accessibilityLabel("新建歌单")
                            .disabled(!account.provider.supports(.playlistCreation))
                            Button {
                                showAppleImport = true
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .accessibilityLabel("导入 Apple Music 歌单")
                        }
                    }
                }

                if !localPlaylists.playlists.isEmpty {
                    Section {
                        localPlaylistShelf(localPlaylists.playlists)
                    } header: {
                        SectionHeader(title: "本地歌单")
                    }
                }

                if account.provider.supports(.playlistSubscriptions) || !account.subscribedPlaylists.isEmpty {
                    Section {
                        if account.subscribedPlaylists.isEmpty {
                            emptyNote("暂无收藏歌单")
                        } else {
                            playlistShelf(account.subscribedPlaylists)
                        }
                    } header: {
                        SectionHeader(title: "收藏的歌单", action: {
                        openDestination(.librarySection(.subscribedPlaylists))
                    })
                    }
                }

                if isPhone {
                    if account.provider.supports(.collectionAlbums) || !account.likedAlbums.isEmpty {
                        Section {
                            if account.likedAlbums.isEmpty {
                                emptyNote(collectionEmptyMessage("还没有收藏专辑"))
                            } else {
                            collectionShelf(count: account.likedAlbums.count) { visibleCount in
                                ForEach(account.likedAlbums.prefix(visibleCount)) { album in
                                    NavigationLink(value: Destination.album(album.id)) {
                                        CoverCardBody(coverURL: album.picUrl?.resizedImageURL(384),
                                                      title: album.name, subtitle: album.artistName)
                                    }
                                    .buttonStyle(.interactiveCard)
                                }
                            }
                            }
                        } header: {
                            SectionHeader(title: "收藏的专辑", action: {
                        openDestination(.librarySection(.albums))
                    })
                        }
                    }

                    if account.provider.supports(.collectionArtists) || !account.likedArtists.isEmpty {
                        Section {
                            if account.likedArtists.isEmpty {
                                emptyNote(collectionEmptyMessage("还没有收藏歌手"))
                            } else {
                            collectionShelf(count: account.likedArtists.count) { visibleCount in
                                ForEach(account.likedArtists.prefix(visibleCount)) { artist in
                                    NavigationLink(value: Destination.artist(artist.id)) {
                                        ProfileDetailArtistCardBody(artist: artist)
                                    }
                                    .buttonStyle(.interactiveCard)
                                }
                            }
                            }
                        } header: {
                            SectionHeader(title: "收藏的歌手", action: {
                        openDestination(.librarySection(.artists))
                    })
                        }
                    }
                }
            }

            Section {
                PlayerClearanceSpacer()
                    .listRowBackground(Color.clear)
            }
        }
    }

    /// A load failure (such as an expired login) replaces the plain empty message.
    private func collectionEmptyMessage(_ empty: String.LocalizationValue) -> String {
        account.sublistsError ?? String(localized: empty)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.secondary)
            .foregroundStyle(.secondary)
            .padding(.vertical, Theme.Spacing.control)
    }

    private func emptyNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Theme.Typography.secondary)
            .foregroundStyle(.secondary)
            .padding(.vertical, Theme.Spacing.control)
    }

    private func collectionShelf<Content: View>(count: Int, @ViewBuilder content: @escaping (Int) -> Content) -> some View {
        ProfileDetailCoverShelf(itemCount: count, content: content)
            .padding(.vertical, 8)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func playlistShelf(_ playlists: [PlaylistSummary]) -> some View {
        ProfileDetailCoverShelf(itemCount: playlists.count, resetKey: playlists.first?.id) { visibleCount in
            ForEach(playlists.prefix(visibleCount)) { playlist in
                NavigationLink(value: Destination.playlist(playlist.id)) {
                    PlaylistCoverCard(playlist: playlist, subtitle: "\(playlist.trackCount) 首")
                }
                .buttonStyle(.interactiveCard)
            }
        }
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// Local playlists (imported Apple Music playlists): each can mix
    /// platforms, so the card shows the first track's cover.
    private func localPlaylistShelf(_ playlists: [LocalPlaylist]) -> some View {
        ProfileDetailCoverShelf(itemCount: playlists.count, resetKey: playlists.first?.id) { visibleCount in
            ForEach(playlists.prefix(visibleCount)) { playlist in
                NavigationLink(value: Destination.localPlaylist(playlist.id)) {
                    CoverCardBody(coverURL: playlist.coverURL, title: playlist.name,
                                  subtitle: "\(playlist.tracks.count) 首")
                }
                .buttonStyle(.interactiveCard)
            }
        }
        .padding(.vertical, 8)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func profileHeader(_ profile: UserProfile) -> some View {
        MusicLibraryHeaderLayout(title: profile.nickname, icon: nil, coverURL: profile.avatarUrl,
                                 circularCover: true, showsCover: false, usesPlaylistActions: true) {
            EmptyView()
        } metadata: {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { listeningStatistics }
                    VStack(alignment: .leading, spacing: 4) { listeningStatistics }
                }
                Text("用户 ID \(account.displayUserID)")
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Text(profileMetadata)
                    .fixedSize(horizontal: false, vertical: true)
                if profileDetail.error != nil {
                    Button("账户统计加载失败，点此重试") {
                        Task {
                            await profileDetail.load(lifetime: 1800, force: true) {
                                try await NeteaseAPI.userDetail(uid: profile.userId)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        } actions: {
            profileActions
        }
    }

    private var guestProfileShortcuts: some View {
        profileActions
    }

    @ViewBuilder
    private var profileMoreActions: some View {
        if (account.provider.supports(.collectionAlbums) || account.provider.supports(.collectionArtists)), !isPhone {
            Button { openPhoneShortcut(.collections) } label: {
                Label("我的收藏", systemImage: "star")
            }
        }
        if account.provider.supports(.playRanking), isPhone {
            Button { openPhoneShortcut(.playRanking) } label: {
                Label("播放排行", image: "ProfilePlayRanking")
            }
        }
        if account.provider.supports(.downloads) {
        Button { openPhoneShortcut(.downloaded, requiresLogin: false) } label: {
            if isPhone {
                Label("我的下载", image: "ProfileDownloads")
            } else {
                Label("下载", systemImage: "arrow.down.circle.fill")
            }
        }
        }
        if account.isLoggedIn {
            Button(role: .destructive) {
                Task {
                    do { try await account.logout() }
                    catch { ToastCenter.shared.show(error.localizedDescription) }
                }
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    @ViewBuilder
    private var listeningStatistics: some View {
        if account.provider.supports(.profileStatistics) {
            Text("Lv.\(profileDetail.value?.level.map(String.init) ?? "—")")
            Text("累计听歌 \(profileDetail.value?.listenSongs?.formatted() ?? "—") 首")
        } else { Text(account.provider.name) }
    }

}
