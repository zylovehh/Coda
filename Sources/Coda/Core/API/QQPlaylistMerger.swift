import Foundation

/// Merges a local playlist into one of the user's own QQ playlists.
///
/// A local playlist mixes songs from several platforms, while a QQ playlist
/// can only hold QQ songs, so every track is first resolved to a QQ song:
/// a track that already came from QQ is used as-is, any other track is
/// searched on QQ by title + artist + duration. Songs already in the target
/// playlist are skipped, and a song that appears several times in the local
/// playlist is only added once. The local playlist itself is not changed.
enum QQPlaylistMerger {
    /// What a merge run did. `notFound` lists the local tracks no QQ song
    /// could be found for, so the user knows exactly what did not make it.
    struct Outcome {
        let added: Int
        let skippedDuplicate: Int
        let notFound: [Track]
        let targetName: String
    }

    /// The user's own QQ playlists that can receive songs. Collected lists
    /// belong to someone else, "我的喜欢" is not a real playlist, and radios
    /// cannot take new songs.
    static func ownedQQPlaylists() async throws -> [ProviderPlaylist] {
        let items = try await QQMusicAPI.shared.userPlaylists(uin: QQMusicAuth.shared.playlistUin)
        return items.filter { ($0.isOwned ?? false) && $0.id != QQMusicAPI.qqLikedPlaylistID && $0.isQQRadio != true }
    }

    static func createQQPlaylist(name: String) async throws -> ProviderPlaylist {
        try await QQMusicAPI.shared.createPlaylist(name: name, isPrivate: false)
    }

    /// Resolves every track to a QQ song, skips what is already in the
    /// target, and adds the rest in batches of 100 (the QQ API limit).
    /// `onProgress` reports resolved tracks, so the UI can show "12 / 269".
    static func merge(_ playlist: LocalPlaylist, into target: ProviderPlaylist,
                      onProgress: @escaping @MainActor (Int, Int) -> Void) async throws -> Outcome {
        let existing = try await QQMusicAPI.shared.playlistSongs(listID: target.id, ownedDirectoryID: target.qqDirectoryID)
        // The target says it has songs but we could read none: dedup would be
        // blind, so stop instead of risking duplicates.
        guard target.trackCount <= 0 || !existing.isEmpty else {
            throw ProviderRequestError.unknown("读不到「\(target.name)」里现有的歌，没法去重，先去 QQ 音乐里确认一下再合并")
        }
        let existingIDs = Set(existing.map(\.id))
        var seenIDs = Set<Int>()
        var toAdd: [Int] = []
        var skipped = 0
        var notFound: [Track] = []
        let total = playlist.tracks.count
        for (index, track) in playlist.tracks.enumerated() {
            try Task.checkCancellation()
            await onProgress(index + 1, total)
            guard let qqID = await resolveQQSongID(for: track) else {
                notFound.append(track)
                continue
            }
            if existingIDs.contains(qqID) || seenIDs.contains(qqID) {
                skipped += 1
                continue
            }
            seenIDs.insert(qqID)
            toAdd.append(qqID)
        }
        var offset = 0
        while offset < toAdd.count {
            try Task.checkCancellation()
            let chunk = Array(toAdd[offset..<min(offset + 100, toAdd.count)])
            try await QQMusicAPI.shared.updatePlaylistTracks(tid: target.id, songIDs: chunk, adding: true)
            offset += chunk.count
        }
        AccountStore.shared.invalidateLibrary()
        return Outcome(added: toAdd.count, skippedDuplicate: skipped, notFound: notFound, targetName: target.name)
    }

    /// The QQ song id for one local track, or nil when QQ has no match.
    /// A track that already came from QQ is used as-is; anything else is
    /// searched on QQ and picked by the same strict matcher the import uses.
    private static func resolveQQSongID(for track: Track) async -> Int? {
        if let song = track.platformSong, song.source == .qq, song.id > 0 {
            return song.id
        }
        let query = UnblockQuery(track: track)
        guard let songs = try? await UnblockSessionPool.shared.qqAPI().searchSongs(keyword: query.keyword, limit: 10),
              !songs.isEmpty else { return nil }
        let candidates = songs.map {
            UnblockCandidate(title: $0.name, artist: $0.artists, album: $0.album,
                             durationMS: Int($0.duration * 1000), payload: $0.id)
        }
        if let best = AudioSourceTrackMatcher.best(query, in: candidates) { return best }
        return looseMatch(query, in: candidates)
    }

    /// Second chance when the strict matcher rejects everything: the title
    /// and the first artist still have to match exactly, only the duration
    /// is allowed to drift (pressings of one song often differ by seconds).
    /// Returns the closest-duration candidate, or nil.
    private static func looseMatch(_ query: UnblockQuery, in candidates: [UnblockCandidate<Int>]) -> Int? {
        let wantedTitle = AudioSourceTrackMatcher.normalized(query.title)
        let wantedStripped = AudioSourceTrackMatcher.normalized(AudioSourceTrackMatcher.stripped(query.title))
        let primary = query.artists.first.map(AudioSourceTrackMatcher.normalized) ?? ""
        return candidates
            .filter { candidate in
                let title = AudioSourceTrackMatcher.normalized(candidate.title)
                let stripped = AudioSourceTrackMatcher.normalized(AudioSourceTrackMatcher.stripped(candidate.title))
                guard title == wantedTitle || stripped == wantedStripped else { return false }
                guard !primary.isEmpty else { return false }
                return AudioSourceTrackMatcher.normalized(candidate.artist).contains(primary)
            }
            .min { abs($0.durationMS - query.durationMS) < abs($1.durationMS - query.durationMS) }?
            .payload
    }
}
