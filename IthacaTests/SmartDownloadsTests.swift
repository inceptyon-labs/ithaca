import Foundation
import Testing
@testable import Ithaca

/// Smart Downloads: which downloads a pass removes and which episodes it queues.
@Suite("Smart Downloads")
struct SmartDownloadsTests {
    @Test("Watched downloads are removed; only downloads, never other watched episodes")
    func removesWatchedDownloads() throws {
        let episodes = try [
            episode(1, 1, viewCount: 1),
            episode(1, 2, viewCount: 2),
            episode(1, 3),
        ]
        let plan = SmartDownloadsPlan(episodes: episodes, onDevice: ["101", "103"], keepReadyCount: 3)
        #expect(plan.ratingKeysToRemove == ["101"])
    }

    @Test("The next unwatched episodes after the last watched one are kept, up to the count; ones already on the device count and aren't queued again")
    func queuesNextUnwatched() throws {
        let episodes = try [
            episode(1, 1, viewCount: 1),
            // Skipped, but before the last watched one: not next.
            episode(1, 2),
            episode(1, 3, viewCount: 1),
            episode(1, 4),
            episode(1, 5),
            episode(2, 1),
            episode(2, 2),
        ]
        let plan = SmartDownloadsPlan(episodes: episodes, onDevice: ["104"], keepReadyCount: 3)
        #expect(plan.ratingKeysToQueue == ["105", "201"])

        let caughtUp = SmartDownloadsPlan(episodes: try [episode(1, 1, viewCount: 1)], onDevice: ["101"], keepReadyCount: 5)
        #expect(caughtUp.ratingKeysToQueue.isEmpty)
    }

    @Test("A watch in progress counts as unwatched, a rewatch too; a watched mark recorded offline counts as watched")
    func inProgressAndOfflineWatchState() throws {
        let rewatching = try plexEpisode(1, 1, viewCount: 1, viewOffset: 600_000)
        let firstWatch = try plexEpisode(1, 3, viewOffset: 900_000)
        // Plex hasn't seen it yet: finished offline, past the watched point.
        let offline = try plexEpisode(1, 2)
        let episodes = [
            SmartDownloadsEpisode(rewatching, watched: true, viewOffsetMs: 600_000),
            SmartDownloadsEpisode(offline, watched: true, viewOffsetMs: 2_600_000),
            SmartDownloadsEpisode(firstWatch, watched: false, viewOffsetMs: 900_000),
            try episode(1, 4),
        ]
        let plan = SmartDownloadsPlan(episodes: episodes, onDevice: ["101", "102", "103"], keepReadyCount: 2)
        #expect(plan.ratingKeysToRemove == ["102"])
        #expect(plan.ratingKeysToQueue == ["104"])
    }

    @Test("Specials are removed once watched but never queued")
    func specials() throws {
        let episodes = try [
            episode(0, 1),
            episode(0, 2, viewCount: 1),
            episode(1, 1),
            episode(1, 2),
        ]
        let plan = SmartDownloadsPlan(episodes: episodes, onDevice: ["2", "101"], keepReadyCount: 3)
        #expect(plan.ratingKeysToRemove == ["2"])
        #expect(plan.ratingKeysToQueue == ["102"])
    }

    @Test("An episode watched before it was downloaded is a rewatch, and stays")
    func rewatchStays() throws {
        let downloaded = Date(timeIntervalSince1970: 2_000_000)
        let episodes = [
            try episode(1, 1, viewCount: 1, lastViewedAt: 1_000_000),
            try episode(1, 2, viewCount: 1, lastViewedAt: 3_000_000),
        ]
        let plan = SmartDownloadsPlan(
            episodes: episodes,
            onDevice: ["101", "102"],
            downloadedAt: ["101": downloaded, "102": downloaded],
            keepReadyCount: 1
        )
        #expect(plan.ratingKeysToRemove == ["102"])
    }

    // MARK: - Fixtures

    /// An episode with its watch state taken from Plex alone.
    private func episode(
        _ season: Int,
        _ number: Int,
        viewCount: Int? = nil,
        viewOffset: Int? = nil,
        lastViewedAt: Int? = nil
    ) throws -> SmartDownloadsEpisode {
        let episode = try plexEpisode(season, number, viewCount: viewCount, viewOffset: viewOffset, lastViewedAt: lastViewedAt)
        return SmartDownloadsEpisode(episode, watched: episode.isWatched, viewOffsetMs: episode.viewOffset)
    }

    /// An episode as `allLeaves` returns it, 45 minutes long. Rating key:
    /// season × 100 + number, so S01E03 is "103" and S00E02 is "2".
    private func plexEpisode(
        _ season: Int,
        _ number: Int,
        viewCount: Int? = nil,
        viewOffset: Int? = nil,
        lastViewedAt: Int? = nil
    ) throws -> PlexEpisode {
        let ratingKey = String(season * 100 + number)
        var object: [String: Any] = [
            "ratingKey": ratingKey,
            "key": "/library/metadata/\(ratingKey)",
            "title": "Episode \(number)",
            "parentIndex": season,
            "index": number,
            "duration": 2_700_000,
        ]
        object["viewCount"] = viewCount
        object["viewOffset"] = viewOffset
        object["lastViewedAt"] = lastViewedAt
        let decoder = JSONDecoder()
        decoder.userInfo[.ithacaServerID] = "server-a"
        return try decoder.decode(PlexEpisode.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
