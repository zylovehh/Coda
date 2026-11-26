import Foundation

/// Merges a local playlist into one of the user's own Kugou playlists.
///
/// A local playlist mixes songs from several platforms, while a Kugou
/// playlist can only hold Kugou songs, so every track is first resolved
/// to a Kugou song: a track that already came from Kugou is used as-is,
/// any other track is searched on Kugou by title + artist + duration.
/// Songs already in the target playlist are skipped, and a song that
/// appears several times in the local playlist is only added once. The
/// local playlist itself is not changed.
enum KugouPlaylistMerger {
    /// What a merge run did; see `PlaylistMergeOutcome`.
    typealias Outcome = PlaylistMergeOutcome

    /// The user's own Kugou playlists that can receive songs. Collected
    /// lists belong to someone else and "我喜欢" is not a real playlist,
    /// so both are left out.
    static func ownedKugouPlaylists() async throws -> [ProviderPlaylist] {
        let items = try await KugouMusicAPI.shared.userPlaylists()
        return items.filter { ($0.isOwned ?? false) && !["我喜欢", "我的喜欢", "我喜欢的音乐"].contains($0.name) }
    }

    static func createKugouPlaylist(name: String) async throws -> ProviderPlaylist {
        try await KugouMusicAPI.shared.createPlaylist(name: name, isPrivate: false)
    }

    /// Resolves every track to a Kugou song, skips what is already in the
    /// target, and adds the rest in batches of 100.
    /// `onProgress` reports resolved tracks, so the UI can show "12 / 269".
    static func merge(_ playlist: LocalPlaylist, into target: ProviderPlaylist,
                      onProgress: @escaping @MainActor (Int, Int) -> Void) async throws -> Outcome {
        let existing = try await KugouMusicAPI.shared.playlistSongs(playlist: target)
        // The target says it has songs but we could read none: dedup would be
        // blind, so stop instead of risking duplicates.
        guard target.trackCount <= 0 || !existing.isEmpty else {
            throw ProviderRequestError.unknown("读不到「\(target.name)」里现有的歌，没法去重，先去酷狗音乐里确认一下再合并")
        }
        let existingHashes = Set(existing.compactMap { $0.kugouHash?.lowercased() }.filter { !$0.isEmpty })
        var seenHashes = Set<String>()
        var toAdd: [ProviderSong] = []
        var skipped = 0
        var notFound: [Track] = []
        let total = playlist.tracks.count
        for (index, track) in playlist.tracks.enumerated() {
            try Task.checkCancellation()
            await onProgress(index + 1, total)
            guard let song = await resolveKugouSong(for: track),
                  let hash = song.kugouHash?.lowercased(), !hash.isEmpty else {
                notFound.append(track)
                continue
            }
            if existingHashes.contains(hash) || seenHashes.contains(hash) {
                skipped += 1
                continue
            }
            seenHashes.insert(hash)
            toAdd.append(song)
        }
        var offset = 0
        while offset < toAdd.count {
            try Task.checkCancellation()
            let chunk = Array(toAdd[offset..<min(offset + 100, toAdd.count)])
            try await KugouMusicAPI.shared.addSongs(listID: target.id, songs: chunk)
            offset += chunk.count
        }
        AccountStore.shared.invalidateLibrary()
        return Outcome(added: toAdd.count, skippedDuplicate: skipped, notFound: notFound, targetName: target.name)
    }

    /// The Kugou song for one local track, or nil when Kugou has no match.
    /// A track that already came from Kugou is used as-is; anything else is
    /// searched on Kugou and picked by the same strict matcher the import
    /// uses.
    private static func resolveKugouSong(for track: Track) async -> ProviderSong? {
        if let song = track.platformSong, song.source == .kugou,
           let hash = song.kugouHash, !hash.isEmpty {
            return song
        }
        let query = UnblockQuery(track: track)
        guard let songs = try? await UnblockSessionPool.shared.kugouAPI().searchSongs(keyword: query.keyword, limit: 10),
              !songs.isEmpty else { return nil }
        let candidates = songs.map {
            UnblockCandidate(title: $0.name, artist: $0.artists, album: $0.album,
                             durationMS: Int($0.duration * 1000), payload: $0)
        }
        if let best = AudioSourceTrackMatcher.best(query, in: candidates) { return best }
        return PlaylistMergeMatching.looseMatch(query, in: candidates)
    }
}
