import Foundation
import Testing
@testable import Ithaca

/// Your Requests: where a Seerr request stands, and announcing each arrival
/// exactly once.
@Suite("Seerr request tracking")
struct SeerrRequestTrackingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Phases follow the request, then Seerr's availability, then the download queue")
    func phases() throws {
        #expect(SeerrRequestPhase.resolve(try request(status: 5, mediaStatus: 4)) == .ready)
        #expect(SeerrRequestPhase.resolve(try request(status: 2, mediaStatus: 5)) == .ready)
        #expect(SeerrRequestPhase.resolve(try request(status: 2, mediaStatus: 3)) == .requested)
        #expect(SeerrRequestPhase.resolve(try request(status: 1, mediaStatus: 2)) == .pendingApproval)
        #expect(SeerrRequestPhase.resolve(try request(status: 3, mediaStatus: 1)) == .declined)
        #expect(SeerrRequestPhase.resolve(try request(status: 5, mediaStatus: 7)) == nil)

        let downloading = try request(
            status: 2,
            mediaStatus: 3,
            downloads: #"[{"size":1000,"sizeLeft":250,"status":"downloading","estimatedCompletionTime":null}]"#
        )
        guard case .downloading(let progress) = SeerrRequestPhase.resolve(downloading) else {
            Issue.record("expected a download")
            return
        }
        #expect(progress.fraction == 0.75)
    }

    @Test("Progress sums every queue entry and keeps the latest finish still ahead")
    func downloadProgress() throws {
        let items = try JSONDecoder().decode([SeerrDownloadItem].self, from: Data(#"""
        [
            {"size": 300, "sizeLeft": 300, "estimatedCompletionTime": "2027-01-15T08:20:00.000Z"},
            {"size": 100, "sizeLeft": 900, "estimatedCompletionTime": "2027-01-15T08:00:00.000Z"},
            {"size": 600, "sizeLeft": 0, "estimatedCompletionTime": "2020-01-01T00:00:00.000Z"}
        ]
        """#.utf8))
        let progress = try #require(SeerrDownloadProgress(items, now: now))
        // 400 of 1000 left; an entry's leftover never counts past its size.
        #expect(progress.fraction == 0.6)
        #expect(progress.estimatedCompletion == Date(timeIntervalSince1970: 1_800_000_000 + 20 * 60))
        #expect(progress.label(now: now) == "60% · 20 min left")
        #expect(SeerrDownloadProgress([], now: now) == nil)
    }

    @Test("Only a request seen on its way is announced, and only once")
    func arrivals() throws {
        var record = SeerrRequestWatchRecord()
        let alreadyThere = try request(id: 1, status: 5, mediaStatus: 5)
        let waiting = try request(id: 2, status: 2, mediaStatus: 3)

        #expect(record.update(with: [alreadyThere, waiting], titles: [2: "Dune"], now: now).isEmpty)
        #expect(record.awaiting == [2: "Dune"])

        let landed = try request(id: 2, status: 5, mediaStatus: 5)
        let arrivals = record.update(with: [alreadyThere, landed], titles: [:], now: now)
        #expect(arrivals.map(\.request.id) == [2])
        #expect(arrivals.first?.title == "Dune")
        #expect(record.awaiting.isEmpty)
        #expect(record.showsReady(landed, now: now.addingTimeInterval(60)))

        #expect(record.update(with: [alreadyThere, landed], titles: [:], now: now).isEmpty)
        let later = now.addingTimeInterval(SeerrRequestWatchRecord.readyShelfLife + 1)
        #expect(!record.showsReady(landed, now: later))
    }

    @Test("A ready request stays for the chosen time, up to the longest choice")
    func shelfLife() throws {
        var record = SeerrRequestWatchRecord(awaiting: [3: "Heat"])
        let landed = try request(id: 3, status: 5, mediaStatus: 5)
        _ = record.update(with: [landed], titles: [:], now: now)

        let tenDaysLater = now.addingTimeInterval(10 * 24 * 60 * 60)
        #expect(!record.showsReady(landed, now: tenDaysLater, shelfLife: ReadyRequestShelfLife.week.timeInterval))
        _ = record.update(with: [landed], titles: [:], now: tenDaysLater)
        #expect(record.showsReady(landed, now: tenDaysLater, shelfLife: ReadyRequestShelfLife.month.timeInterval))
    }

    @Test("After a long gap an arrival is listed as ready but not announced")
    func staleArrivalIsQuiet() throws {
        var record = SeerrRequestWatchRecord(
            awaiting: [4: "Alien"],
            checkedAt: now.addingTimeInterval(-3 * 24 * 60 * 60)
        )
        let landed = try request(id: 4, status: 5, mediaStatus: 5)
        #expect(record.update(with: [landed], titles: [:], now: now).isEmpty)
        #expect(record.showsReady(landed, now: now))
    }

    @Test("A TV request reads from its own seasons, not the whole show's availability")
    func tvSeasonPhases() throws {
        // Season 3 asked for, seasons 1 and 2 already in Plex.
        let newSeason = try request(status: 2, mediaStatus: 4, type: "tv", seasons: [(3, 2)])
        #expect(SeerrRequestPhase.resolve(newSeason) == .requested)
        let halfway = try request(status: 2, mediaStatus: 4, type: "tv", seasons: [(3, 5), (4, 2)])
        #expect(SeerrRequestPhase.resolve(halfway) == .partiallyAvailable)
    }

    @Test("A declined request stops being awaited")
    func declinedIsDropped() throws {
        var record = SeerrRequestWatchRecord(awaiting: [3: "Heat"])
        let declined = try request(id: 3, status: 3, mediaStatus: 1)
        #expect(record.update(with: [declined], titles: [:], now: now).isEmpty)
        #expect(record.awaiting.isEmpty)
    }

    @Test("Seasons read as one, a run, or a count")
    func seasonsLabel() throws {
        func label(_ numbers: [Int]) -> String? {
            SeerrRequestTracker.seasonsLabel(
                numbers.map { SeerrSeasonRequest(id: nil, seasonNumber: $0, status: .approved) }
            )
        }
        #expect(label([2]) == "Season 2")
        #expect(label([3, 1, 2]) == "Seasons 1–3")
        #expect(label([1, 4]) == "2 Seasons")
        #expect(label([]) == nil)
    }

    /// A request as Seerr's `GET /api/v1/request` lists it.
    private func request(
        id: Int = 1,
        status: Int,
        mediaStatus: Int,
        type: String = "movie",
        seasons: [(number: Int, status: Int)] = [],
        downloads: String = "[]"
    ) throws -> SeerrListedRequest {
        let seasonsJSON = seasons
            .map { #"{"seasonNumber":\#($0.number),"status":\#($0.status)}"# }
            .joined(separator: ",")
        let json = """
        {
            "id": \(id),
            "status": \(status),
            "type": "\(type)",
            "is4k": false,
            "createdAt": "2020-01-01T00:00:00.000Z",
            "seasons": [\(seasonsJSON)],
            "media": {"tmdbId": \(100 + id), "status": \(mediaStatus), "ratingKey": null, "downloadStatus": \(downloads)}
        }
        """
        return try JSONDecoder().decode(SeerrListedRequest.self, from: Data(json.utf8))
    }
}
