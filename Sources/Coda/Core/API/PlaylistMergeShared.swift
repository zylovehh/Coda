import Foundation

/// What one merge run did, shared by every platform merger. `notFound`
/// lists the local tracks no song could be found for on that platform,
/// so the user knows exactly what did not make it.
struct PlaylistMergeOutcome {
    let added: Int
    let skippedDuplicate: Int
    let notFound: [Track]
    let targetName: String
}

enum PlaylistMergeMatching {
    /// Second chance when the strict matcher rejects everything: the title
    /// and the first artist still have to match exactly, only the duration
    /// is allowed to drift (pressings of one song often differ by seconds).
    /// Returns the closest-duration candidate, or nil.
    static func looseMatch<Payload>(_ query: UnblockQuery, in candidates: [UnblockCandidate<Payload>]) -> Payload? {
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
