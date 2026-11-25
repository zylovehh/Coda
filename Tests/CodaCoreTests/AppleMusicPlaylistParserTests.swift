import Foundation
import Testing
@testable import CodaCore

@Suite("Apple Music playlist parser tests")
struct AppleMusicPlaylistParserTests {
    /// Minimal page shaped like the real one: serialized-server-data carries
    /// title, artist (subtitleLinks) and duration in milliseconds; the
    /// schema.org block carries title and ISO 8601 duration only.
    private static let serializedSample = """
        {"data":[{"data":{"sections":[
        {"id":"header","items":[{"id":"h","title":"Surf Essentials"}]},
        {"id":"tracks","items":[
        {"id":"1","title":"Surfin' Bird","duration":144707,"subtitleLinks":[{"title":"The Trashmen"}],"tertiaryLinks":[{"title":"Surfin' Bird"}]},
        {"id":"2","title":"Wipe Out","duration":157760,"subtitleLinks":[{"title":"The Surfaris"}],"tertiaryLinks":[{"title":"The Best of the Surfaris"}]}
        ]},
        {"id":"about","items":[{"id":"a","description":"x"}]}
        ]}}]}
        """

    private static let schemaSample = """
        {"@type":"MusicPlaylist","name":"Surf Essentials","track":[
        {"@type":"MusicRecording","name":"Surfin' Bird","duration":"PT2M24S"},
        {"@type":"MusicRecording","name":"Wipe Out","duration":"PT2M37S"}
        ]}
        """

    private static func page(serialized: String? = nil, schema: String? = nil) -> String {
        var html = "<html><head><title>x</title></head><body>"
        if let serialized {
            html += "<script type=\"application/json\" id=\"serialized-server-data\">\(serialized)</script>"
        }
        if let schema {
            html += "<script id=schema:music-playlist type=\"application/ld+json\">\(schema)</script>"
        }
        return html + "</body></html>"
    }

    @Test func parsesSerializedServerData() throws {
        let playlist = try AppleMusicPlaylistParser.parse(html: Self.page(serialized: Self.serializedSample))
        #expect(playlist.title == "Surf Essentials")
        #expect(playlist.songs.count == 2)
        #expect(playlist.songs[0].title == "Surfin' Bird")
        #expect(playlist.songs[0].artist == "The Trashmen")
        #expect(playlist.songs[0].durationMS == 144707)
        #expect(playlist.songs[1].artist == "The Surfaris")
        #expect(playlist.songs[1].durationMS == 157760)
    }

    @Test func fallsBackToSchemaWhenSerializedIsMissing() throws {
        let playlist = try AppleMusicPlaylistParser.parse(html: Self.page(schema: Self.schemaSample))
        #expect(playlist.title == "Surf Essentials")
        #expect(playlist.songs.count == 2)
        #expect(playlist.songs[0].title == "Surfin' Bird")
        #expect(playlist.songs[0].artist.isEmpty)
        #expect(playlist.songs[0].durationMS == 144_000)
        #expect(playlist.songs[1].durationMS == 157_000)
    }

    @Test func prefersSerializedOverSchema() throws {
        let playlist = try AppleMusicPlaylistParser.parse(
            html: Self.page(serialized: Self.serializedSample, schema: Self.schemaSample))
        #expect(playlist.songs[0].artist == "The Trashmen")
    }

    @Test func throwsWhenNoSongsAreFound() {
        #expect(throws: AppleMusicPlaylistImportError.self) {
            try AppleMusicPlaylistParser.parse(html: "<html><body>no playlist here</body></html>")
        }
    }

    @Test func parsesISODurations() {
        #expect(AppleMusicPlaylistParser.parseISODuration("PT2M24S") == 144_000)
        #expect(AppleMusicPlaylistParser.parseISODuration("PT1H3M12S") == 3_792_000)
        #expect(AppleMusicPlaylistParser.parseISODuration("PT45S") == 45_000)
        #expect(AppleMusicPlaylistParser.parseISODuration("bogus") == 0)
    }
}
