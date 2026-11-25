import Foundation

/// A playlist that lives only in the app, saved as JSON under Application
/// Support. A server playlist can only hold one platform's tracks, so an
/// imported Apple Music playlist is saved here instead: its tracks can come
/// from any logged-in platform (NetEase, QQ, Kugou, Qishui), one playlist
/// holds them all, and each song remembers the platform it came from
/// (Track.platformSong) so playback resolves it through that platform.
struct LocalPlaylist: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var tracks: [Track]
    let createdAt: Date
    var updatedAt: Date

    /// The first usable cover: the first track that has album art.
    var coverURL: URL? {
        tracks.lazy.compactMap(\.album.picUrl).compactMap { URL(string: $0) }.first
    }

    /// How many of this playlist's songs came from each platform.
    var countsByProvider: [MusicProvider: Int] {
        Dictionary(grouping: tracks, by: { $0.platformSong?.source ?? .netease }).mapValues(\.count)
    }
}

@MainActor
final class LocalPlaylistStore: ObservableObject {
    static let shared = LocalPlaylistStore()

    @Published private(set) var playlists: [LocalPlaylist] = []

    private let url = CodaPaths.applicationSupport.appendingPathComponent("local-playlists.json")

    private init() { load() }

    func playlist(id: UUID) -> LocalPlaylist? {
        playlists.first { $0.id == id }
    }

    /// Creates the local playlist with this name, or replaces the tracks of
    /// the one already there — re-importing the same Apple Music playlist
    /// updates it instead of piling up duplicates.
    @discardableResult
    func upsert(name: String, tracks: [Track]) -> LocalPlaylist {
        let now = Date()
        if let index = playlists.firstIndex(where: { $0.name == name }) {
            playlists[index].tracks = tracks
            playlists[index].updatedAt = now
            save()
            return playlists[index]
        }
        let playlist = LocalPlaylist(id: UUID(), name: name, tracks: tracks, createdAt: now, updatedAt: now)
        playlists.append(playlist)
        save()
        return playlist
    }

    func delete(id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([LocalPlaylist].self, from: data) else { return }
        playlists = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(playlists).write(to: url, options: .atomic)
        } catch {
            // Local playlists are a convenience store; a failed save must not
            // break the import that just produced them.
        }
    }
}
