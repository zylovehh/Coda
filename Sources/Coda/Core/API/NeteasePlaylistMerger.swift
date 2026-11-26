import Foundation

/// Merges a local playlist into one of the user's own NetEase playlists.
///
/// A local playlist mixes songs from several platforms, while a NetEase
/// playlist can only hold NetEase songs, so every track is first resolved
/// to a NetEase song: a track that already came from NetEase is used as-is,
/// any other track is searched on NetEase by title + artist + duration.
/// Songs already in the target playlist are skipped, and a song that
/// appears several times in the local playlist is only added once. The
/// local playlist itself is not changed.
///
/// All requests go through the isolated NetEase client built from the
/// saved NetEase account, so merging works no matter which platform the
/// app is currently showing.
enum NeteasePlaylistMerger {
    /// What a merge run did; see `PlaylistMergeOutcome`.
    typealias Outcome = PlaylistMergeOutcome

    /// The user's own NetEase playlists that can receive songs. Collected
    /// lists belong to someone else and "我喜欢的音乐" is not a real
    /// playlist, so both are left out.
    static func ownedNeteasePlaylists() async throws -> [ProviderPlaylist] {
        let client = await UnblockSessionPool.shared.neteaseClient()
        let uid = try await neteaseUID(using: client)
        let data = try await client.eapi("/user/playlist",
                                         ["uid": uid, "limit": 2000, "offset": 0, "includeVideo": true])
        let summaries = try client.decoded(NeteaseAPI.UserPlaylistsResponse.self, from: data).playlist
        return summaries
            .filter { !$0.subscribed && !$0.isLikedSongsList && $0.creator?.userId == uid }
            .map { summary in
                ProviderPlaylist(id: summary.id, name: summary.name,
                                 coverURL: summary.coverURL.flatMap(URL.init(string:)),
                                 trackCount: summary.trackCount, source: .netease)
            }
    }

    static func createNeteasePlaylist(name: String) async throws -> ProviderPlaylist {
        let client = await UnblockSessionPool.shared.neteaseClient()
        _ = try await neteaseUID(using: client)
        let data = try await client.eapi("/playlist/create",
                                         ["name": name, "privacy": 0, "type": "NORMAL"])
        let result = try client.decoded(NeteaseAPI.PlaylistCreateResponse.self, from: data)
        guard let id = result.id, id > 0 else {
            throw ProviderRequestError.unknown("网易云没有返回新歌单编号，请刷新歌单列表")
        }
        await AccountStore.shared.invalidateLibrary()
        return ProviderPlaylist(id: id, name: name, coverURL: nil, trackCount: 0, source: .netease)
    }

    /// Resolves every track to a NetEase song, skips what is already in the
    /// target, and adds the rest in batches of 100.
    /// `onProgress` reports resolved tracks, so the UI can show "12 / 269".
    static func merge(_ playlist: LocalPlaylist, into target: ProviderPlaylist,
                      onProgress: @escaping @MainActor (Int, Int) -> Void) async throws -> Outcome {
        let client = await UnblockSessionPool.shared.neteaseClient()
        _ = try await neteaseUID(using: client)
        let detailData = try await client.eapi("/v6/playlist/detail",
                                               ["id": target.id, "n": 100_000, "s": 8])
        let existing = try client.decoded(NeteaseAPI.PlaylistDetailResponse.self, from: detailData)
            .playlist.trackIds.map(\.id)
        // The target says it has songs but we could read none: dedup would be
        // blind, so stop instead of risking duplicates.
        guard target.trackCount <= 0 || !existing.isEmpty else {
            throw ProviderRequestError.unknown("读不到「\(target.name)」里现有的歌，没法去重，先去网易云音乐里确认一下再合并")
        }
        let existingIDs = Set(existing)
        var seenIDs = Set<Int>()
        var toAdd: [Int] = []
        var skipped = 0
        var notFound: [Track] = []
        let total = playlist.tracks.count
        for (index, track) in playlist.tracks.enumerated() {
            try Task.checkCancellation()
            await onProgress(index + 1, total)
            guard let neteaseID = await resolveNeteaseSongID(for: track, using: client) else {
                notFound.append(track)
                continue
            }
            if existingIDs.contains(neteaseID) || seenIDs.contains(neteaseID) {
                skipped += 1
                continue
            }
            seenIDs.insert(neteaseID)
            toAdd.append(neteaseID)
        }
        var offset = 0
        while offset < toAdd.count {
            try Task.checkCancellation()
            let chunk = Array(toAdd[offset..<min(offset + 100, toAdd.count)])
            try await addTracks(chunk, to: target.id, using: client)
            offset += chunk.count
        }
        await AccountStore.shared.invalidateLibrary()
        return Outcome(added: toAdd.count, skippedDuplicate: skipped, notFound: notFound, targetName: target.name)
    }

    /// The NetEase user id, from the saved NetEase account when there is
    /// one, otherwise from the logged-in profile behind the cookies.
    private static func neteaseUID(using client: NeteaseClient) async throws -> Int {
        if let stored = await MusicAccountManager.shared.accounts
            .last(where: { $0.provider == .netease && !$0.credentials.isEmpty })?.userID,
           let uid = Int(stored), uid > 0 {
            return uid
        }
        let data = try await client.eapi("/nuser/account/get")
        guard let uid = try client.decoded(NeteaseAPI.AccountResponse.self, from: data).profile?.userId, uid > 0 else {
            throw ProviderRequestError.unknown("请先在「我的」里登录网易云音乐，再把本地歌单合并过去。")
        }
        return uid
    }

    /// Adds NetEase songs to a playlist, with the same 512 quirk the app
    /// already uses elsewhere: when the server says a song is already in
    /// the list, retry with the ids doubled.
    private static func addTracks(_ trackIDs: [Int], to playlistID: Int, using client: NeteaseClient) async throws {
        let ids = "[" + trackIDs.map(String.init).joined(separator: ",") + "]"
        let data = try await client.eapi("/playlist/manipulate/tracks",
                                         ["op": "add", "pid": playlistID, "trackIds": ids, "imme": "true"])
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = obj["code"] as? Int, code != 200 {
            if code == 512 {
                let doubled = "[" + (trackIDs + trackIDs).map(String.init).joined(separator: ",") + "]"
                _ = try await client.eapi("/playlist/manipulate/tracks",
                                          ["op": "add", "pid": playlistID, "trackIds": doubled, "imme": "true"])
                return
            }
            throw NeteaseAPIError.business(code: code, message: obj["message"] as? String)
        }
    }

    /// The NetEase song id for one local track, or nil when NetEase has no
    /// match. A track that already came from NetEase is used as-is; anything
    /// else is searched on NetEase and picked by the same strict matcher
    /// the import uses.
    private static func resolveNeteaseSongID(for track: Track, using client: NeteaseClient) async -> Int? {
        if let song = track.platformSong, song.source == .netease, track.id > 0 {
            return track.id
        }
        let query = UnblockQuery(track: track)
        guard let data = try? await client.eapi("/cloudsearch/pc",
                                                ["s": query.keyword, "type": NeteaseAPI.SearchType.songs.rawValue,
                                                 "limit": 10, "offset": 0, "total": true]),
              let songs = try? client.decoded(NeteaseAPI.SearchResponse.self, from: data).result?.songs,
              !songs.isEmpty else { return nil }
        let candidates = songs.map {
            UnblockCandidate(title: $0.name, artist: $0.artistNames, album: $0.album.name,
                             durationMS: $0.durationMS, payload: $0.id)
        }
        if let best = AudioSourceTrackMatcher.best(query, in: candidates) { return best }
        return PlaylistMergeMatching.looseMatch(query, in: candidates)
    }
}
