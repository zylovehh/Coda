import Foundation

/// Merges a local playlist into one of the user's own Qishui playlists.
///
/// A local playlist mixes songs from several platforms, while a Qishui
/// playlist can only hold Qishui songs, so every track is first resolved
/// to a Qishui song: a track that already came from Qishui is used as-is,
/// any other track is searched on Qishui by title + artist + duration.
/// Songs already in the target playlist are skipped, and a song that
/// appears several times in the local playlist is only added once. The
/// local playlist itself is not changed.
enum QishuiPlaylistMerger {
    /// What a merge run did; see `PlaylistMergeOutcome`.
    typealias Outcome = PlaylistMergeOutcome

    /// The user's own Qishui playlists that can receive songs. Radios
    /// cannot take new songs and the favorites list (type 1) is not a
    /// real playlist, so both are left out.
    static func ownedQishuiPlaylists() async throws -> [ProviderPlaylist] {
        let items = try await QishuiMusicAPI.shared.userPlaylists()
        return items.filter { $0.qishui?.radio == nil && $0.qishui?.type != 1 }
    }

    static func createQishuiPlaylist(name: String) async throws -> ProviderPlaylist {
        try await QishuiMusicAPI.shared.createPlaylist(name: name, isPrivate: false)
    }

    /// Resolves every track to a Qishui song, skips what is already in the
    /// target, and adds the rest in batches of 100.
    /// `onProgress` reports resolved tracks, so the UI can show "12 / 269".
    static func merge(_ playlist: LocalPlaylist, into target: ProviderPlaylist,
                      onProgress: @escaping @MainActor (Int, Int) -> Void) async throws -> Outcome {
        guard let reference = target.qishui else {
            throw ProviderRequestError.unknown("这个汽水歌单缺少编号，没法合并，请刷新歌单列表")
        }
        let existing = try await QishuiMusicAPI.shared.playlistSongs(reference)
        // The target says it has songs but we could read none: dedup would be
        // blind, so stop instead of risking duplicates.
        guard target.trackCount <= 0 || !existing.isEmpty else {
            throw ProviderRequestError.unknown("读不到「\(target.name)」里现有的歌，没法去重，先去汽水音乐里确认一下再合并")
        }
        let existingIDs = Set(existing.compactMap { $0.qishui?.trackID }.filter { !$0.isEmpty })
        var seenIDs = Set<String>()
        var toAdd: [String] = []
        var skipped = 0
        var notFound: [Track] = []
        let total = playlist.tracks.count
        for (index, track) in playlist.tracks.enumerated() {
            try Task.checkCancellation()
            await onProgress(index + 1, total)
            guard let trackID = await resolveQishuiTrackID(for: track), !trackID.isEmpty else {
                notFound.append(track)
                continue
            }
            if existingIDs.contains(trackID) || seenIDs.contains(trackID) {
                skipped += 1
                continue
            }
            seenIDs.insert(trackID)
            toAdd.append(trackID)
        }
        var offset = 0
        while offset < toAdd.count {
            try Task.checkCancellation()
            let chunk = Array(toAdd[offset..<min(offset + 100, toAdd.count)])
            try await QishuiMusicAPI.shared.appendPlaylistTracks(playlistID: reference.playlistID, trackIDs: chunk)
            offset += chunk.count
        }
        AccountStore.shared.invalidateLibrary()
        return Outcome(added: toAdd.count, skippedDuplicate: skipped, notFound: notFound, targetName: target.name)
    }

    /// The Qishui track id for one local track, or nil when Qishui has no
    /// match. A track that already came from Qishui is used as-is; anything
    /// else is searched on Qishui and picked by the same strict matcher
    /// the import uses.
    private static func resolveQishuiTrackID(for track: Track) async -> String? {
        if let song = track.platformSong, song.source == .qishui,
           let trackID = song.qishui?.trackID, !trackID.isEmpty {
            return trackID
        }
        guard let api = UnblockSessionPool.shared.qishuiAPI() else { return nil }
        let query = UnblockQuery(track: track)
        guard let page = try? await api.search(keyword: query.keyword, type: .songs, limit: 10, offset: 0),
              !page.songs.isEmpty else { return nil }
        let candidates = page.songs.compactMap { song -> UnblockCandidate<String>? in
            guard let trackID = song.qishui?.trackID, !trackID.isEmpty else { return nil }
            return UnblockCandidate(title: song.name, artist: song.artists, album: song.album,
                                    durationMS: Int(song.duration * 1000), payload: trackID)
        }
        guard !candidates.isEmpty else { return nil }
        if let best = AudioSourceTrackMatcher.best(query, in: candidates) { return best }
        return PlaylistMergeMatching.looseMatch(query, in: candidates)
    }
}
