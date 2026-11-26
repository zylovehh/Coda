import SwiftUI

private struct MusicLibraryContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
    var musicLibraryContentWidth: CGFloat {
        get { self[MusicLibraryContentWidthKey.self] }
        set { self[MusicLibraryContentWidthKey.self] = newValue }
    }
}

/// Shared presentation for iOS library pages and their song panels.
struct MusicLibraryTrackLayout: DynamicProperty {
    var phoneLayout = PhonePageLayout()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.musicLibraryContentWidth) private var contentWidth

    var usesPanel: Bool { true }

    // Portrait with the sidebar visible leaves about 500pt for the detail.
    // Measure that column so rotation, sidebar toggles and multitasking all
    // update the list without relying on the device's size class alone.
    var columns: Int {
        phoneLayout.isEnabled ? 1 : (contentWidth >= 700 ? 2 : 1)
    }
    var usesPlaylistHero: Bool { phoneLayout.isEnabled }
    static let dividedColumnSpacing = Theme.Layout.dividedColumnSpacing
    /// Balance the visible duration and rank labels, whose text has unequal side bearings.
    static let columnSeparatorOpticalOffset: CGFloat = 6
    /// Page background: the window already paints the theme background behind
    /// every page, so a panel must not paint its own opaque color over it.
    var background: Color { usesPanel ? .clear : Platform.windowBackgroundColor }
}

/// Shared thin rule for library headers and the text area of song rows.
struct MusicLibrarySeparator: View {
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct MusicLibraryTrackPanel: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, enabled ? Theme.Spacing.component : 0)
            .padding(.horizontal, Theme.Layout.trackListInset)
    }
}

extension View {

    func musicLibraryTrackPanel(_ enabled: Bool) -> some View {
        modifier(MusicLibraryTrackPanel(enabled: enabled))
    }
}

/// One loading presentation for liked songs, downloads, recents and cloud.
/// Match the real list's column count and row geometry as the iPad resizes.
struct MusicLibraryLoadingView: View {
    var rowsPerColumn = 6
    var scrollsHorizontally = false
    var showsHorizontalPanel = true
    var horizontalInset: CGFloat = Theme.Layout.trackListInset
    /// Caps each horizontal column at one width on every platform.
    var fixedColumnWidth: CGFloat?
    private var layout = MusicLibraryTrackLayout()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = Theme.Layout.trackArtworkSize
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = Theme.Layout.trackRowHeight

    init(rowsPerColumn: Int = 6, scrollsHorizontally: Bool = false, showsHorizontalPanel: Bool = true,
         horizontalInset: CGFloat = Theme.Layout.trackListInset, fixedColumnWidth: CGFloat? = nil) {
        self.fixedColumnWidth = fixedColumnWidth
        self.rowsPerColumn = rowsPerColumn
        self.scrollsHorizontally = scrollsHorizontally
        self.showsHorizontalPanel = showsHorizontalPanel
        self.horizontalInset = horizontalInset
    }

    var phoneLayout = PhonePageLayout()
    private var isCompact: Bool { phoneLayout.isEnabled }

    var body: some View {
        Group {
            if scrollsHorizontally {
                horizontalShelf
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MusicLibraryTrackLayout.dividedColumnSpacing), count: layout.columns), spacing: 1) {
                    ForEach(0..<(rowsPerColumn * layout.columns), id: \.self) { _ in songRow }
                }
                .musicLibraryTrackPanel(layout.usesPanel)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载歌曲")
        .accessibilityIdentifier("musicLibraryLoadingSkeleton")
    }

    private var songRow: some View {
        MusicLibraryLoadingRow(rowHeight: rowHeight)
    }

    // Match MusicTrackPanel's horizontal shelf, including the phone's next-column peek.
    private var horizontalShelf: some View {
        let panelInset: CGFloat = showsHorizontalPanel ? Theme.Spacing.component : 0
        return GeometryReader { geometry in
            let available = max(1, geometry.size.width - 2 * horizontalInset)
            let columns = !isCompact && geometry.size.width >= 700 ? 2 : 1
            let fittedWidth = max(1, (available - CGFloat(columns - 1) * 24) / CGFloat(columns)
                                  - (isCompact ? 20 : 0))
            let columnWidth = fixedColumnWidth.map { max(1, min($0, available - (isCompact ? 20 : 0))) } ?? fittedWidth
            let visibleColumns = fixedColumnWidth.map { max(1, Int(ceil(available / ($0 + 24)))) } ?? columns
            ScenePreservingScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(rowHeight), spacing: 1), count: rowsPerColumn), spacing: Theme.Spacing.group) {
                    ForEach(0..<(rowsPerColumn * (visibleColumns + 1)), id: \.self) { _ in
                        songRow.frame(width: columnWidth)
                    }
                }
                .padding(.horizontal, horizontalInset)
            }
            .padding(.vertical, panelInset)
        }
        .frame(height: CGFloat(rowsPerColumn) * rowHeight + CGFloat(max(0, rowsPerColumn - 1)) + 2 * panelInset)
    }
}

/// The same row geometry for initial loading and appended horizontal columns.
private struct MusicLibraryLoadingRow: View {
    let rowHeight: CGFloat
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = Theme.Layout.trackArtworkSize

    var body: some View {
        HStack(spacing: Theme.Spacing.control) {
            SkeletonView(cornerRadius: Theme.Radius.small)
                .frame(width: artworkSize, height: artworkSize)
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                SkeletonView(cornerRadius: 4).frame(height: 20)
                SkeletonView(cornerRadius: 4).frame(maxWidth: 140).frame(height: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SkeletonView(cornerRadius: 3).frame(width: 30, height: 10)
        }
        .padding(.horizontal, Theme.Layout.trackRowHorizontalInset)
        .frame(height: rowHeight)
    }

}

/// Shared song panel; artist and album pages opt into horizontal shelves.
struct MusicTrackPanel: View {
    let tracks: [Track]
    var scrollsHorizontally = false
    var horizontalRowLimit = 7
    var horizontalInset: CGFloat = Theme.Layout.trackListInset
    /// Caps each horizontal column at one width on every platform.
    var fixedColumnWidth: CGFloat?
    var showsHorizontalPanel = true
    var onLastTrackAppear: (() -> Void)?
    var horizontalLoading = HorizontalPageLoading()
    var source: PlaySource = .none
    var context: PlayContext?
    var showsLikeButton = false
    var showsRowSeparators: Bool? = nil
    var removableFromPlaylistID: Int?
    var onRemoved: ((Track) -> Void)?
    var recommendationContext: RecommendationContext?
    var onRecommendationReduced: ((Track, Track) -> Void)?
    var trailingText: ((Track) -> String?)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.musicLibraryContentWidth) private var contentWidth
    @ScaledMetric(relativeTo: .body) private var compactRowHeight: CGFloat = Theme.Layout.trackRowHeight

    var phoneLayout = PhonePageLayout()
    private var isCompact: Bool { phoneLayout.isEnabled }

    @ViewBuilder
    var body: some View {
        if scrollsHorizontally {
            horizontalShelf
        } else {
            songList()
                .musicLibraryTrackPanel(true)
        }
    }

    private func songList(horizontalLayout: TrackListView.HorizontalLayout? = nil, displayLimit: Int? = nil) -> some View {
        TrackListView(tracks: tracks, displayLimit: displayLimit, style: .likedMusic,
                      showsLikeButton: showsLikeButton, showsAlbumSubtitle: true,
                      columns: !isCompact && contentWidth >= 700 ? 2 : 1,
                      showsRowSeparators: showsRowSeparators,
                      source: source, context: context,
                      removableFromPlaylistID: removableFromPlaylistID, onRemoved: onRemoved,
                      recommendationContext: recommendationContext,
                      onRecommendationReduced: onRecommendationReduced,
                      trailingText: trailingText,
                      onLastTrackAppear: horizontalLayout == nil ? onLastTrackAppear : nil,
                      horizontalLayout: horizontalLayout)
    }

    private var horizontalShelf: some View {
        let rows = min(max(1, horizontalRowLimit), tracks.count)
        #if os(iOS)
        let rowHeight = compactRowHeight
        #else
        let rowHeight: CGFloat = 64
        #endif
        let panelInset: CGFloat = showsHorizontalPanel ? Theme.Spacing.component : 0
        return GeometryReader { geometry in
            let available = max(1, geometry.size.width - 2 * horizontalInset)
            let columns = !isCompact && geometry.size.width >= 700 ? 2 : 1
            let peek: CGFloat = isCompact && tracks.count > rows ? 20 : 0
            let fittedWidth = max(1, (available - CGFloat(columns - 1) * 24) / CGFloat(columns) - peek)
            let columnWidth = fixedColumnWidth.map { max(1, min($0, available - peek)) } ?? fittedWidth
            HorizontalPagingScrollView(itemCount: tracks.count, resetKey: tracks.first?.id,
                                       pageSize: max(1, rows) * 4, horizontalInset: horizontalInset,
                                       spacing: Theme.Spacing.group, loading: horizontalLoading) { visibleCount in
                songList(horizontalLayout: .init(rows: max(1, rows), columnWidth: columnWidth, rowHeight: rowHeight),
                         displayLimit: visibleCount)
            } placeholder: {
                VStack(spacing: 1) {
                    ForEach(0..<max(1, rows), id: \.self) { _ in
                        MusicLibraryLoadingRow(rowHeight: rowHeight)
                    }
                }
                .frame(width: columnWidth)
            }
            .padding(.vertical, panelInset)
        }
        .frame(height: CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) + 2 * panelInset)
    }
}

/// A complete song-list page: one scroll owner, reusable desktop rows and
/// content-sized chrome. Mobile keeps the existing lazy stack and spacing.
struct TrackListScrollView<Header: View, Rows: View, Footer: View>: View {
    let trackIDs: [Int]
    var style: TrackRowStyle = .full
    var spacing: CGFloat = Theme.Spacing.section
    @ViewBuilder var header: () -> Header
    @ViewBuilder var rows: (TrackListView.Layout) -> Rows
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ScenePreservingScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                header()
                if !trackIDs.isEmpty { rows(.stack) }
                footer()
            }
        }
    }
}

/// Stable header geometry shared by liked songs, downloads, recents and cloud.
/// Page-specific controls fill slots without replacing the cover/title hierarchy.
struct MusicLibraryHeaderLayout<Eyebrow: View, Metadata: View, Actions: View>: View {
    let title: String
    let icon: String?
    let coverURL: String?
    var description: String? = nil
    var circularCover = false
    /// The "我的" page hides the big profile picture; playlist, collection
    /// and artist pages keep their cover.
    var showsCover = true
    var isLoading = false
    var actionColumns: Int? = nil
    var usesPlaylistActions = false
    var searchText: Binding<String>? = nil
    var searchFocused: Binding<Bool>? = nil
    var searchPlaceholder: String = String(localized: "在歌单中搜索")
    @State private var showDescription = false
    @State private var measuredWidth: CGFloat = 0
    @Environment(\.musicLibraryContentWidth) private var contentWidth
    @Environment(\.horizontalSizeClass) private var sizeClass

    // The split-view width is supplied only on iPad. Other navigation hosts
    // must use this header's actual proposal, never the environment's infinity.
    private var availableWidth: CGFloat {
        contentWidth.isFinite && contentWidth > 0 ? contentWidth : measuredWidth
    }
    private var coverSize: CGFloat { min(240, max(200, availableWidth * 0.3)) }
    @ViewBuilder var eyebrow: () -> Eyebrow
    @ViewBuilder var metadata: () -> Metadata
    @ViewBuilder var actions: () -> Actions

    private var isNarrow: Bool {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone || sizeClass == .compact { return true }
        #endif
        return availableWidth < 700
    }
    private var inset: CGFloat { Theme.Layout.contentInset }
    private var artworkSize: CGFloat { isNarrow ? min(200, max(112, availableWidth * 0.28)) : coverSize }

    private var hasPlaylistActions: Bool { usesPlaylistActions }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.component) {
            if let searchText, let searchFocused {
                if isLoading {
                    SkeletonView(cornerRadius: 22).frame(minHeight: Theme.Layout.controlHeight)
                } else {
                    PlaylistSearchBar(text: searchText, isFocused: searchFocused,
                                          placeholder: searchPlaceholder)
                }
            }
            if hasPlaylistActions {
                playlistHeader
            } else if showsCover {
                HStack(alignment: .top, spacing: Theme.Spacing.group) {
                    artwork
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        information
                        if !isNarrow {
                            Spacer(minLength: 8)
                            controls
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: isNarrow ? nil : artworkSize, alignment: .top)
                }
                if isNarrow {
                    descriptionButton
                    controls
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    information
                    if !isNarrow {
                        Spacer(minLength: 8)
                        controls
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isNarrow {
                    descriptionButton
                    controls
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, inset)
        .pageHeaderTopPadding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("musicLibraryHeader")
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { recordWidth(geometry.size.width) }
                    .onChange(of: geometry.size.width) { recordWidth($0) }
            }
        }
    }

    @ViewBuilder
    private var playlistHeader: some View {
        if !showsCover {
            VStack(alignment: .leading, spacing: Theme.Spacing.component) {
                information
                controls
            }
        } else if availableWidth >= 480 {
            HStack(alignment: .bottom, spacing: Theme.Spacing.group) {
                artwork
                VStack(alignment: .leading, spacing: Theme.Spacing.component) {
                    information
                    Spacer(minLength: 0)
                    controls
                }
                .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
            }
        } else {
            // Keep full-size controls when a narrow split window cannot fit
            // the cover and three-button row beside each other.
            HStack(alignment: .top, spacing: Theme.Spacing.component) {
                artwork
                information
            }
            controls
        }
    }

    private func recordWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0, width != measuredWidth else { return }
        measuredWidth = width
    }

    @ViewBuilder
    private var artwork: some View {
        if circularCover {
            artworkImage.clipShape(Circle())
        } else {
            artworkImage.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var artworkImage: some View {
        Group {
            if isLoading {
                SkeletonView(cornerRadius: 16)
            } else {
                loadedArtworkImage
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .accessibilityHidden(true)
    }

    private var loadedArtworkImage: some View {
        CachedAsyncImage(url: coverURL?.resizedImageURL(512), animated: false) {
            Theme.LikedMusic.cover
        }
        .frame(width: artworkSize, height: artworkSize)
        .overlay {
            if let icon {
                Color.black.opacity(0.18)
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var information: some View {
        if isLoading {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: 220).frame(height: 24)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
        } else {
            loadedInformation
        }
    }

    private var loadedInformation: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            eyebrow()
            Text(title).font(Theme.Typography.detailTitle)
                .lineLimit(2).minimumScaleFactor(0.75).accessibilityAddTraits(.isHeader)
                .appMainTitle()
            metadata()
            if !isNarrow || hasPlaylistActions { descriptionButton }
        }
    }

    @ViewBuilder
    private var descriptionButton: some View {
        if !isLoading, let description, !description.isEmpty {
            Button { showDescription = true } label: {
                Text(description.replacingOccurrences(of: "\n", with: " "))
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(isNarrow ? 2 : 1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDescription, arrowEdge: .bottom) {
                ScenePreservingScrollView {
                    Text(description)
                        .font(Theme.Typography.secondary)
                        .padding(Theme.Spacing.phonePage)
                        .frame(maxWidth: 380, alignment: .leading)
                }
                .frame(maxHeight: 400)
            }
        }
    }

    private var controls: some View {
        Group {
            if isLoading {
                if hasPlaylistActions {
                    actions()
                } else {
                    SkeletonView(cornerRadius: 22).frame(width: 240, height: 44)
                }
            } else if hasPlaylistActions {
                actions()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let actionColumns {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.small),
                                         count: max(1, actionColumns)), spacing: Theme.Spacing.small) {
                    actions()
                }
            } else {
                PlaylistActionLayout(spacing: Theme.Spacing.small) { actions() }
            }
        }
        .font(Theme.Typography.body.weight(.semibold))
        .buttonStyle(.pressable)
    }

}

/// Shared loading header for detail and library pages, using the real header geometry.
struct MusicLibraryHeaderSkeleton: View {
    var circularCover = false
    var collectionHeader = false
    var showsSaveButton = true

    var body: some View {
        Group {
            if collectionHeader {
                MusicLibraryHeaderLayout(title: "", icon: nil, coverURL: nil,
                                         circularCover: circularCover, isLoading: true,
                                         usesPlaylistActions: circularCover) {
                    EmptyView()
                } metadata: {
                    EmptyView()
                } actions: {
                    MusicLibraryActionSkeleton()
                }
            } else if circularCover {
                // Artist pages use the same centered phone hero as their loaded content.
                PlaylistDetailHero(artworkURL: nil, title: "正在加载歌手",
                                       subtitle: "歌手信息", avatarURL: nil,
                                       metadataText: "正在加载歌曲信息",
                                       circularArtwork: true, showsAvatar: false, isLoading: true) {
                    MusicLibraryActionSkeleton()
                }
            } else {
                PlaylistHeader(artworkURL: nil, title: "正在加载页面",
                                    subtitle: "正在加载", avatarURL: nil,
                                    metadataText: "正在加载歌曲信息",
                                    filter: .constant(""), searchFocused: .constant(false),
                                    isLoading: true) {
                    MusicLibraryActionSkeleton(showsSaveButton: showsSaveButton)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载页面")
        .accessibilityIdentifier("musicLibraryHeaderSkeleton")
    }
}

/// Card-based collections retain card geometry while sharing the same shimmer.
struct MusicLibraryCardLoadingView: View {
    var circularCover = false

    var body: some View {
        CardGrid {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    SkeletonView(cornerRadius: circularCover ? 1000 : Theme.Radius.cover)
                        .aspectRatio(1, contentMode: .fit)
                    SkeletonView(cornerRadius: 4).frame(height: 14)
                    SkeletonView(cornerRadius: 4).frame(maxWidth: 100).frame(height: 11)
                }
            }
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载收藏")
    }
}

/// Match the player detail's icon-only overflow affordance.
struct MusicLibraryMoreLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 22, weight: .medium))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("更多操作")
    }
}

/// Library destinations share the liked-music header without playlist-only actions.
struct MusicLibraryHeader: View {
    let title: String
    let icon: String
    let tracks: [Track]
    var subtitle: String? = nil
    @Binding var filter: String
    @Binding var sort: MusicLibrarySort
    var selectDownloads: (() -> Void)? = nil
    var downloadTaskCount: Int = 0
    var openDownloadTasks: (() -> Void)? = nil
    var upload: (() -> Void)? = nil
    var isUploading = false
    let play: () -> Void

    @State private var searchFocused = false
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        PlaylistHeader(
            artworkURL: tracks.first?.album.picUrl, title: title,
            subtitle: account.profile?.nickname ?? String(localized: "我的音乐"),
            avatarURL: account.profile?.avatarUrl,
            metadataText: subtitle.map { "\(tracks.count) 首歌曲 · \($0)" } ?? "\(tracks.count) 首歌曲",
            filter: $filter, searchFocused: $searchFocused,
            searchPlaceholder: String(localized: "搜索歌曲")
        ) {
            playlistActions()
        }

    }

    private func playlistActions(horizontalPadding: CGFloat? = nil) -> some View {
        PlaylistPrimaryActions(
            isSaved: false, canSave: upload != nil && account.isLoggedIn, canPlay: !tracks.isEmpty,
            isSaving: isUploading, onToggleSaved: { upload?() }, onPlayAll: play,
            leadingIcon: isUploading ? "arrow.triangle.2.circlepath" : "square.and.arrow.up",
            showsSaveButton: upload != nil, saveAccessibilityLabel: isUploading ? String(localized: "正在上传…") : String(localized: "上传音乐"),
            saveAccessibilityIdentifier: "cloud-upload", horizontalPadding: horizontalPadding
        ) {
            Menu { moreActions } label: { PlaylistMoreLabel() }
                .accessibilityLabel("更多操作")
        }
    }

    private var moreActions: some View {
        Group {
            Picker("排序方式", selection: $sort) {
                ForEach(MusicLibrarySort.allCases, id: \.self) { order in
                    Text(LocalizedStringKey(order.rawValue)).tag(order)
                }
            }
            if let selectDownloads {
                Button(action: selectDownloads) { Label("选择", systemImage: "checkmark.circle") }
                    .disabled(tracks.isEmpty)
                    .accessibilityIdentifier("select-downloads")
            }
            if let openDownloadTasks {
                Button(action: openDownloadTasks) {
                    Label("下载任务 (\(downloadTaskCount))", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("download-tasks")
            }
        }
    }

    #if os(macOS)
    #endif
}

enum MusicLibrarySort: String, CaseIterable {
    case original = "默认顺序"
    case reversed = "倒序"
    case song = "歌曲名"
    case album = "专辑名"
    case artist = "歌手名"

    func tracks(_ tracks: [Track], matching filter: String) -> [Track] {
        let order: PlaylistTrackSort
        switch self {
        case .original: order = .addedNewestFirst
        case .reversed: order = .addedOldestFirst
        case .song: order = .songName
        case .album: order = .albumName
        case .artist: order = .artistName
        }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return order.sorted(tracks).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.artistNames.localizedCaseInsensitiveContains(query)
                || $0.album.name.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct MusicLibraryNavigationTitle: ViewModifier {
    let title: String
    let enabled: Bool
    @Environment(\.appMainTitleHidden) private var headerTitleHidden

    func body(content: Content) -> some View {
        content
            .navigationTitle(enabled && !headerTitleHidden ? "" : title)
    }
}

extension View {
    func musicLibraryNavigationTitle(_ title: String, enabled: Bool) -> some View {
        modifier(MusicLibraryNavigationTitle(title: title, enabled: enabled))
    }
}

private struct MusicLibraryArtworkBackground: ViewModifier {
    let artworkURL: String?

    // Wrap the content so the artwork's light/dark verdict also sets the
    // foreground color scheme (white text on dark art, black on light art).
    // Off the phone layout, DetailArtworkBackground falls back to the plain
    // library background.
    func body(content: Content) -> some View {
        content.modifier(DetailArtworkBackground(artworkURL: artworkURL))
    }
}

extension View {
    func musicLibraryArtworkBackground(_ artworkURL: String?) -> some View {
        modifier(MusicLibraryArtworkBackground(artworkURL: artworkURL))
    }
}
