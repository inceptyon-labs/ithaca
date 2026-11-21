import Foundation
import Testing
@testable import Ithaca

/// "Because You Liked X": ratings and recently finished titles, TMDB's
/// recommendations for each, and the viewer's library.
@Suite("Taste recommendations")
struct TasteRecommendationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    @Test("Plex ratings read as loved, liked or not for me; three stars is no answer")
    func ratingMapping() {
        #expect(PlexTasteRating(plexValue: 10) == .loved)
        #expect(PlexTasteRating(plexValue: 9) == .loved)
        #expect(PlexTasteRating(plexValue: 8) == .liked)
        #expect(PlexTasteRating(plexValue: 6) == nil)
        #expect(PlexTasteRating(plexValue: 2) == .disliked)
        #expect(PlexTasteRating(plexValue: nil) == nil)
        for rating in PlexTasteRating.allCases {
            #expect(PlexTasteRating(plexValue: Double(rating.plexValue)) == rating)
        }
    }

    @Test("Seeds: ratings outweigh recent viewing; old, unfinished and three-star titles are not taste")
    func seeds() throws {
        let library = TasteLibrary(items: [
            try movie(1, "Loved", rating: 10, ratedAgo: 10),
            try movie(2, "Watched", viewCount: 1, viewedAgo: 5),
            try movie(3, "Long Ago", viewCount: 1, viewedAgo: 200),
            try movie(4, "Fine", rating: 6, ratedAgo: 1),
            try movie(5, "Disliked", rating: 2, ratedAgo: 1),
            try movie(6, "Started", viewOffset: 600_000, viewedAgo: 1),
            try show(7, "One Episode", viewedLeafCount: 1, viewedAgo: 1),
            try show(8, "Binged", viewedLeafCount: 6, viewedAgo: 2),
        ], serverOrder: [])

        let seeds = TasteScoring.seeds(in: library, now: now)
        // Binged two days ago edges out Watched five days ago.
        #expect(seeds.map(\.title) == ["Loved", "Binged", "Watched", "Disliked"])
        #expect(seeds.first?.reason == .loved)
        #expect(seeds.last?.weight ?? 0 < 0)
        #expect(seeds[0].shelfTitle == "Because You Liked Loved")
        #expect(seeds[2].shelfTitle == "Because You Watched Watched")
    }

    @Test("Shelves: each title goes under the liked title that recommends it most; seen titles drop out, a dislike's picks sink")
    func shelves() throws {
        let library = TasteLibrary(items: [
            try movie(1, "Arrival", rating: 10, ratedAgo: 1),
            try movie(2, "Heat", rating: 8, ratedAgo: 1),
            try movie(3, "Cats", rating: 2, ratedAgo: 1),
            try movie(10, "Sicario"),
            try movie(11, "Dune"),
            try movie(12, "Contact"),
            try movie(13, "Interstellar", viewCount: 1, viewedAgo: 400),
            try movie(14, "Thief"),
            try movie(15, "Ronin"),
            try movie(16, "Collateral"),
            try movie(17, "Musical"),
        ], serverOrder: [])
        let analysis = TasteAnalysis(
            library: library,
            seeds: TasteScoring.seeds(in: library, now: now),
            candidates: TasteScoring.candidates(
                seeds: TasteScoring.seeds(in: library, now: now),
                recommendations: [
                    TasteTitleKey(type: .movie, tmdbID: 1): try media([10, 11, 12, 13]),
                    TasteTitleKey(type: .movie, tmdbID: 2): try media([17, 14, 15, 16, 10]),
                    TasteTitleKey(type: .movie, tmdbID: 3): try media([17]),
                ]
            )
        )

        let shelves = TasteScoring.shelves(analysis: analysis, itemsPerShelf: 10)
        #expect(shelves.map(\.title) == ["Because You Liked Arrival", "Because You Liked Heat"])
        // Sicario is on both lists, higher on Arrival's; Interstellar was seen.
        #expect(shelves[0].items.map(\.title) == ["Sicario", "Dune", "Contact"])
        // Heat's first pick is also what Cats recommends, so it sinks to last.
        #expect(shelves[1].items.map(\.title) == ["Thief", "Ronin", "Collateral", "Musical"])
    }

    @Test("A liked title with too few matches feeds Top Picks instead of its own shelf")
    func topPicks() throws {
        let library = TasteLibrary(items: [
            try movie(1, "Arrival", rating: 10, ratedAgo: 1),
            try movie(2, "Heat", rating: 8, ratedAgo: 1),
            try movie(10, "Sicario"),
            try movie(11, "Dune"),
            try movie(14, "Thief"),
        ], serverOrder: [])
        let seeds = TasteScoring.seeds(in: library, now: now)
        let analysis = TasteAnalysis(
            library: library,
            seeds: seeds,
            candidates: TasteScoring.candidates(seeds: seeds, recommendations: [
                TasteTitleKey(type: .movie, tmdbID: 1): try media([10, 11]),
                TasteTitleKey(type: .movie, tmdbID: 2): try media([14]),
            ])
        )

        let shelves = TasteScoring.shelves(analysis: analysis, itemsPerShelf: 10)
        #expect(shelves.map(\.title) == ["Top Picks for You"])
        #expect(shelves.first?.items.map(\.title) == ["Sicario", "Dune", "Thief"])
    }

    @Test("Recommended for You lists titles the library lacks that nobody has requested")
    func requestable() throws {
        let library = TasteLibrary(items: [try movie(1, "Arrival", rating: 10, ratedAgo: 1)], serverOrder: [])
        let seeds = TasteScoring.seeds(in: library, now: now)
        let recommendations = [
            try seerrMovie(20, status: nil),
            try seerrMovie(21, status: 2),
            try seerrMovie(22, status: 5),
            try seerrMovie(23, status: 7),
        ]
        let analysis = TasteAnalysis(
            library: library,
            seeds: seeds,
            candidates: TasteScoring.candidates(
                seeds: seeds,
                recommendations: [TasteTitleKey(type: .movie, tmdbID: 1): recommendations]
            )
        )

        #expect(TasteScoring.requestable(analysis: analysis, limit: 10).map(\.id) == [20, 23])
    }

    // MARK: - Fixtures

    private func movie(
        _ tmdbID: Int,
        _ title: String,
        rating: Double? = nil,
        ratedAgo: Double? = nil,
        viewCount: Int? = nil,
        viewOffset: Int? = nil,
        viewedAgo: Double? = nil
    ) throws -> PlexItem {
        try item(type: "movie", tmdbID: tmdbID, title: title, fields: [
            "userRating": rating,
            "lastRatedAt": ratedAgo.map { now.timeIntervalSince1970 - $0 * day },
            "viewCount": viewCount.map(Double.init),
            "viewOffset": viewOffset.map(Double.init),
            "lastViewedAt": viewedAgo.map { now.timeIntervalSince1970 - $0 * day },
        ])
    }

    private func show(_ tmdbID: Int, _ title: String, viewedLeafCount: Int, viewedAgo: Double) throws -> PlexItem {
        try item(type: "show", tmdbID: tmdbID, title: title, fields: [
            "leafCount": 10,
            "viewedLeafCount": Double(viewedLeafCount),
            "lastViewedAt": now.timeIntervalSince1970 - viewedAgo * day,
        ])
    }

    /// An item as a Plex library listing returns it.
    private func item(type: String, tmdbID: Int, title: String, fields: [String: Double?]) throws -> PlexItem {
        var object: [String: Any] = [
            "ratingKey": String(tmdbID),
            "key": "/library/metadata/\(tmdbID)",
            "type": type,
            "title": title,
            "Guid": [["id": "tmdb://\(tmdbID)"]],
        ]
        for case let (key, value?) in fields {
            object[key] = key == "userRating" ? value : Int(value)
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(PlexItem.self, from: data)
    }

    private func media(_ tmdbIDs: [Int]) throws -> [SeerrSearchMedia] {
        try tmdbIDs.map { try seerrMovie($0, status: nil) }
    }

    /// A result as Seerr's recommendations endpoint returns it.
    private func seerrMovie(_ tmdbID: Int, status: Int?) throws -> SeerrSearchMedia {
        let mediaInfo = status.map { #","mediaInfo":{"tmdbId":\#(tmdbID),"status":\#($0)}"# } ?? ""
        let json = #"{"id":\#(tmdbID),"mediaType":"movie","title":"Movie \#(tmdbID)"\#(mediaInfo)}"#
        return try JSONDecoder().decode(SeerrSearchMedia.self, from: Data(json.utf8))
    }
}
