import Foundation
import Testing
@testable import Ithaca

@Suite("Live TV guide lineup")
struct LiveTVGuideLineupTests {
    /// Plex's grid groups a title's airings under one entry. Each airing
    /// belongs to its own channel and slot in the guide.
    @Test func airingsAreSplitAcrossChannelsAndSlots() throws {
        let channelsJSON = """
        [
            { "id": "102", "gridKey": "102", "vcn": "102", "title": "ABC News Live 1" },
            { "id": "103", "gridKey": "103", "vcn": "103", "title": "ABC News Live 2" }
        ]
        """
        let programsJSON = """
        [
            {
                "ratingKey": "news",
                "title": "World News Tonight",
                "Media": [
                    { "id": 1, "beginsAt": 1000, "endsAt": 2000, "channelIdentifier": "102" },
                    { "id": 2, "beginsAt": 1000, "endsAt": 2000, "channelIdentifier": "103" },
                    { "id": 3, "beginsAt": 3000, "endsAt": 4000, "channelIdentifier": "102" }
                ]
            }
        ]
        """
        let channels = try JSONDecoder().decode([PlexLiveChannel].self, from: Data(channelsJSON.utf8))
        let programs = try JSONDecoder().decode([PlexLiveProgram].self, from: Data(programsJSON.utf8))

        let guides = PlexService.liveTVGuides(channels: channels, programs: programs)

        #expect(guides.map { $0.programs.count } == [2, 1])
        #expect(guides[0].programs.map { $0.beginsAt?.timeIntervalSince1970 } == [1000, 3000])
        #expect(guides[1].programs.first?.channelIdentifier == "103")
    }
}
