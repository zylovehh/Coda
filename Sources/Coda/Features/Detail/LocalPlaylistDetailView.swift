import SwiftUI

/// The detail page for a local playlist (an imported Apple Music playlist).
/// Its tracks can come from several platforms, so each row shows the platform
/// the song came from, and playback resolves each song through its own
/// platform — one playlist, no switching.
struct LocalPlaylistDetailView: View {
    let playlistID: UUID

    @StateObject private var store = LocalPlaylistStore.shared
    private let player = PlayerService.shared
    @State private var confirmDelete = false
    @State private var showsMerge = false
    @Environment(\.dismiss) private var dismiss

    private var playlist: LocalPlaylist? { store.playlist(id: playlistID) }

    var body: some View {
        Group {
            if let playlist {
                ScenePreservingScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(playlist)
                        MusicTrackPanel(
                            tracks: playlist.tracks,
                            source: .none,
                            trailingText: { shortProviderName(for: $0) }
                        )
                    }
                    .padding(.horizontal, Theme.Spacing.component)
                }
                .navigationTitle(playlist.name)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("删除歌单", systemImage: "trash")
                        }
                    }
                }
                .confirmationDialog("删除这个本地歌单？", isPresented: $confirmDelete) {
                    Button("删除", role: .destructive) {
                        store.delete(id: playlist.id)
                        dismiss()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("只删 App 里的这份本地歌单，各平台上的歌单不受影响。")
                }
                .sheet(isPresented: $showsMerge) {
                    LocalPlaylistMergeSheet(playlist: playlist)
                }
            } else {
                Text("这个本地歌单已经删掉了")
                    .foregroundStyle(.secondary)
                    .navigationTitle("本地歌单")
            }
        }
    }

    private func header(_ playlist: LocalPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(playlist.tracks.count) 首 · 本地歌单")
                .font(Theme.Typography.secondary)
                .foregroundStyle(.secondary)
            if !playlist.tracks.isEmpty {
                Text(providerBreakdown(for: playlist))
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.Spacing.control) {
                Button {
                    player.play(tracks: playlist.tracks, source: .none)
                } label: {
                    Label("全部播放", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(playlist.tracks.isEmpty)
                Button {
                    showsMerge = true
                } label: {
                    Label("合并到平台歌单", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.bordered)
                .disabled(playlist.tracks.isEmpty)
            }
        }
        .padding(.top, 8)
    }

    /// "网易云 31 首 · QQ 180 首 · 酷狗 20 首", only platforms that supplied songs.
    private func providerBreakdown(for playlist: LocalPlaylist) -> String {
        MusicProvider.allCases.compactMap { provider in
            guard let count = playlist.countsByProvider[provider], count > 0 else { return nil }
            return "\(provider.name) \(count) 首"
        }.joined(separator: " · ")
    }

    private func shortProviderName(for track: Track) -> String? {
        switch track.platformSong?.source {
        case .netease: return "网易云"
        case .qq: return "QQ"
        case .kugou: return "酷狗"
        case .qishui: return "汽水"
        case nil: return nil
        }
    }
}
