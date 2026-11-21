import Foundation
import Testing
@testable import Ithaca

@Suite("Plex media part decoding")
struct PlexMediaPartDecodingTests {
    /// Plex can omit `id` on a stream (seen on an embedded EIA-608 caption
    /// track); that stream is dropped instead of failing the whole item.
    @Test func streamWithoutIDOrUnknownTypeIsDroppedNotFatal() throws {
        let json = """
        {
            "id": 1,
            "key": "/library/parts/1/file.mkv",
            "container": "mkv",
            "Stream": [
                { "id": 175569, "streamType": 1, "codec": "h264" },
                { "id": 175568, "streamType": 2, "codec": "eac3", "channels": 6 },
                { "streamType": 3, "codec": "eia_608", "embeddedInVideo": "1" },
                { "id": 175572, "streamType": 9, "codec": "unknown" },
                { "id": 175571, "streamType": 3, "codec": "srt", "key": "/library/streams/175571" }
            ]
        }
        """

        let part = try JSONDecoder().decode(PlexMediaPart.self, from: Data(json.utf8))

        #expect(part.streams.map(\.id) == [175569, 175568, 175571])
        #expect(part.streams.map(\.streamType) == [.video, .audio, .subtitle])
    }

    @Test func endCreditsIsTheFinalMarkerElseTheLastOne() throws {
        let json = """
        [
            { "id": 1, "type": "credits", "startTimeOffset": 100, "endTimeOffset": 200 },
            { "id": 2, "type": "credits", "startTimeOffset": 300, "endTimeOffset": 400, "final": true },
            { "id": 3, "type": "credits", "startTimeOffset": 500, "endTimeOffset": 600 }
        ]
        """
        let markers = try JSONDecoder().decode([PlexMarker].self, from: Data(json.utf8))
        #expect(markers.map(\.final) == [nil, true, nil])
        #expect(PlexMarker.endCredits(in: markers)?.id == 2)
        #expect(PlexMarker.endCredits(in: markers.filter { $0.final != true })?.id == 3)
    }
}
