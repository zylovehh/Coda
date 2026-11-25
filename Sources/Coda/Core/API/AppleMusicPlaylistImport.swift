import Foundation

/// One song parsed from a public Apple Music playlist page.
struct AppleMusicPlaylistSong: Sendable, Hashable {
    let title: String
    let artist: String
    let album: String
    let durationMS: Int
}

struct AppleMusicPlaylist: Sendable {
    let title: String
    let songs: [AppleMusicPlaylistSong]
}

enum AppleMusicPlaylistImportError: LocalizedError {
    case invalidLink
    case loadFailed
    case playlistNotFound
    case noSongs
    case notLoggedIn(MusicProvider)
    case nothingMatched(Int)

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "链接不是 Apple Music 歌单页，请粘贴 music.apple.com 的歌单链接"
        case .loadFailed: return "打不开这个 Apple Music 歌单链接，请检查网络后重试"
        case .playlistNotFound: return "找不到这个 Apple Music 歌单，它可能已下架或设为不公开"
        case .noSongs: return "这个歌单里没有解析到歌曲"
        case .notLoggedIn(let provider): return "请先登录\(provider.name)，再导入歌单"
        case .nothingMatched(let count): return "歌单里的 \(count) 首歌在已登录的平台上一首都没找到"
        }
    }
}

/// Reads a public Apple Music playlist page (no sign-in) and pulls out its
/// songs. Primary source is the page's `serialized-server-data` blob
/// (title + artist + album + duration in milliseconds); the schema.org
/// JSON-LD block is the fallback (title + duration only, no artist).
enum AppleMusicPlaylistParser {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    static func fetch(url: URL) async throws -> AppleMusicPlaylist {
        guard url.host?.lowercased() == "music.apple.com",
              url.pathComponents.contains("playlist") else { throw AppleMusicPlaylistImportError.invalidLink }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AppleMusicPlaylistImportError.loadFailed
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw AppleMusicPlaylistImportError.playlistNotFound
        }
        return try parse(html: html)
    }

    static func parse(html: String) throws -> AppleMusicPlaylist {
        if let serialized = extractScript(html, containing: "serialized-server-data"),
           let playlist = parseSerializedServerData(serialized) {
            return playlist
        }
        if let schema = extractScript(html, containing: "schema:music-playlist"),
           let playlist = parseSchemaPlaylist(schema) {
            return playlist
        }
        throw AppleMusicPlaylistImportError.noSongs
    }

    private static func extractScript(_ html: String, containing marker: String) -> String? {
        let pattern = "<script[^>]*" + NSRegularExpression.escapedPattern(for: marker) + "[^>]*>(.*?)</script>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    /// `data[0].data.sections`: the track section is the one whose items carry
    /// both a title and a duration; the first section's first item is the playlist.
    static func parseSerializedServerData(_ text: String) -> AppleMusicPlaylist? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = root["data"] as? [[String: Any]],
              let first = dataArray.first,
              let page = first["data"] as? [String: Any],
              let sections = page["sections"] as? [[String: Any]] else { return nil }
        var title = ""
        if let firstSection = sections.first,
           let items = firstSection["items"] as? [[String: Any]],
           let firstItem = items.first,
           let name = firstItem["title"] as? String, !name.isEmpty {
            title = name
        }
        var bestItems: [[String: Any]] = []
        for section in sections {
            guard let items = section["items"] as? [[String: Any]] else { continue }
            let tracks = items.filter { $0["title"] is String && $0["duration"] is NSNumber }
            if tracks.count > bestItems.count { bestItems = tracks }
        }
        guard !bestItems.isEmpty else { return nil }
        let songs: [AppleMusicPlaylistSong] = bestItems.compactMap { item in
            guard let name = item["title"] as? String, !name.isEmpty,
                  let duration = item["duration"] as? NSNumber else { return nil }
            let artist = (item["subtitleLinks"] as? [[String: Any]])?.first?["title"] as? String ?? ""
            let album = (item["tertiaryLinks"] as? [[String: Any]])?.first?["title"] as? String ?? ""
            return AppleMusicPlaylistSong(title: name, artist: artist, album: album, durationMS: duration.intValue)
        }
        guard !songs.isEmpty else { return nil }
        return AppleMusicPlaylist(title: title, songs: songs)
    }

    /// schema.org `MusicPlaylist`: `track` entries carry `name` and an ISO 8601
    /// `duration` ("PT2M24S"); no artist is published here.
    static func parseSchemaPlaylist(_ text: String) -> AppleMusicPlaylist? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = root["track"] as? [[String: Any]] else { return nil }
        let songs: [AppleMusicPlaylistSong] = tracks.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            let durationMS = (item["duration"] as? String).map(parseISODuration) ?? 0
            return AppleMusicPlaylistSong(title: name, artist: "", album: "", durationMS: durationMS)
        }
        guard !songs.isEmpty else { return nil }
        return AppleMusicPlaylist(title: (root["name"] as? String) ?? "", songs: songs)
    }

    /// "PT2M24S" / "PT1H3M12S" / "PT45S" -> milliseconds.
    static func parseISODuration(_ value: String) -> Int {
        guard value.hasPrefix("PT") else { return 0 }
        var total = 0.0
        var number = ""
        for ch in value.dropFirst(2) {
            if ch.isNumber || ch == "." {
                number.append(ch)
            } else if ch == "H" {
                total += (Double(number) ?? 0) * 3600; number = ""
            } else if ch == "M" {
                total += (Double(number) ?? 0) * 60; number = ""
            } else if ch == "S" {
                total += Double(number) ?? 0; number = ""
            } else {
                number = ""
            }
        }
        return Int(total * 1000)
    }
}

/// Imports an Apple Music playlist across every signed-in platform: parses
/// the shared link, then searches each song on the preferred platform first
/// and on the other logged-in platforms after it, with the same strict
/// matcher the gray-track unlock uses. A server playlist can only hold one
/// platform's tracks, so the songs found are saved as one local playlist
/// named "Apple" instead — each song remembers the platform it came from
/// (Track.platformSong) and playback resolves it through that platform.
/// Searching goes through each platform's own saved account
/// (UnblockSessionPool), so the active account, the current platform and
/// playback are never touched.
@MainActor
final class AppleMusicPlaylistImporter: ObservableObject {
    static let playlistName = "Apple"
    private static let searchLimit = 10

    struct Outcome {
        let playlistTitle: String
        let preferredProvider: MusicProvider
        /// How many imported songs came from each platform.
        let countsByProvider: [MusicProvider: Int]
        let imported: Int
        let missing: [AppleMusicPlaylistSong]
    }

    private struct MatchedSong {
        let track: Track
    }

    func loggedInProviders() -> [MusicProvider] {
        MusicProvider.allCases.filter { UnblockSessionPool.shared.hasAccount($0) }
    }

    func importPlaylist(from url: URL, preferredProvider: MusicProvider,
                        onProgress: @escaping @MainActor (Int, Int) -> Void) async throws -> Outcome {
        guard UnblockSessionPool.shared.hasAccount(preferredProvider) else {
            throw AppleMusicPlaylistImportError.notLoggedIn(preferredProvider)
        }
        let playlist = try await AppleMusicPlaylistParser.fetch(url: url)
        guard !playlist.songs.isEmpty else { throw AppleMusicPlaylistImportError.noSongs }
        // Preferred platform first, then every other logged-in platform.
        // A platform the user has not logged in to is skipped silently.
        let providers = [preferredProvider] + loggedInProviders().filter { $0 != preferredProvider }
        var matched: [MatchedSong] = []
        var missing: [AppleMusicPlaylistSong] = []
        var seenTrackIDs = Set<Int>()
        for (index, song) in playlist.songs.enumerated() {
            try Task.checkCancellation()
            var found: MatchedSong?
            for provider in providers {
                if let hit = await match(song, on: provider) {
                    found = hit
                    break
                }
            }
            if let found, seenTrackIDs.insert(found.track.id).inserted {
                matched.append(found)
            } else {
                missing.append(song)
            }
            onProgress(index + 1, playlist.songs.count)
        }
        guard !matched.isEmpty else { throw AppleMusicPlaylistImportError.nothingMatched(playlist.songs.count) }
        let tracks = matched.map(\.track)
        let counts = Dictionary(grouping: tracks, by: { MusicProvider(rawValue: $0.platformSong?.source.rawValue ?? "netease") ?? .netease }).mapValues(\.count)
        LocalPlaylistStore.shared.upsert(name: Self.playlistName, tracks: tracks)
        return Outcome(playlistTitle: playlist.title, preferredProvider: preferredProvider,
                       countsByProvider: counts, imported: matched.count, missing: missing)
    }

    // MARK: - Matching

    private func match(_ song: AppleMusicPlaylistSong, on provider: MusicProvider) async -> MatchedSong? {
        let query = UnblockQuery(origin: provider, title: song.title,
                                 artists: song.artist.isEmpty ? [] : [song.artist],
                                 album: song.album, durationMS: song.durationMS)
        do {
            switch provider {
            case .netease:
                let client = UnblockSessionPool.shared.neteaseClient()
                let data = try await client.eapi("/cloudsearch/pc", [
                    "s": query.keyword, "type": NeteaseAPI.SearchType.songs.rawValue,
                    "limit": Self.searchLimit, "offset": 0, "total": true,
                ])
                let songs = try client.decoded(NeteaseAPI.SearchResponse.self, from: data).result?.songs ?? []
                let candidates = songs.map {
                    UnblockCandidate(title: $0.name, artist: $0.artistNames, album: $0.album.name,
                                     durationMS: $0.durationMS, payload: $0)
                }
                guard let best = pick(query, song: song, candidates: candidates) else { return nil }
                return MatchedSong(track: best)
            case .qq:
                let songs = try await UnblockSessionPool.shared.qqAPI().searchSongs(keyword: query.keyword, limit: Self.searchLimit)
                return try await matchProviderSongs(song, query: query, songs: songs)
            case .kugou:
                let songs = try await UnblockSessionPool.shared.kugouAPI().searchSongs(keyword: query.keyword, limit: Self.searchLimit)
                return try await matchProviderSongs(song, query: query, songs: songs)
            case .qishui:
                guard let api = UnblockSessionPool.shared.qishuiAPI() else { return nil }
                let page = try await api.search(keyword: query.keyword, type: .songs, limit: Self.searchLimit, offset: 0)
                return try await matchProviderSongs(song, query: query, songs: page.songs)
            }
        } catch {
            // A failed search counts as "not found", never as a fatal error.
            return nil
        }
    }

    private func matchProviderSongs(_ song: AppleMusicPlaylistSong, query: UnblockQuery,
                                    songs: [ProviderSong]) async throws -> MatchedSong? {
        let candidates = songs.map {
            UnblockCandidate(title: $0.name, artist: $0.artists, album: $0.album,
                             durationMS: Int($0.duration * 1000), payload: $0)
        }
        guard let best = pick(query, song: song, candidates: candidates) else { return nil }
        guard let track = try PlatformMusicAPI.shared.tracks([best]).first else { return nil }
        return MatchedSong(track: track)
    }

    /// Strict title + artist + duration match first. Only when the Apple page
    /// gave no artist at all does title + duration decide, so a wrong version
    /// never sneaks into the playlist on a known artist.
    private func pick<Payload>(_ query: UnblockQuery, song: AppleMusicPlaylistSong,
                               candidates: [UnblockCandidate<Payload>]) -> Payload? {
        if let best = AudioSourceTrackMatcher.best(query, in: candidates) { return best }
        guard song.artist.isEmpty else { return nil }
        let wanted = AudioSourceTrackMatcher.normalized(song.title)
        let wantedStripped = AudioSourceTrackMatcher.normalized(AudioSourceTrackMatcher.stripped(song.title))
        return candidates
            .filter {
                let title = AudioSourceTrackMatcher.normalized($0.title)
                let stripped = AudioSourceTrackMatcher.normalized(AudioSourceTrackMatcher.stripped($0.title))
                return title == wanted || stripped == wantedStripped
            }
            .filter { abs($0.durationMS - song.durationMS) <= AudioSourceTrackMatcher.maximumDurationDifferenceMS }
            .min { abs($0.durationMS - song.durationMS) < abs($1.durationMS - song.durationMS) }?.payload
    }
}
