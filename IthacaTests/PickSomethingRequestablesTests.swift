import Foundation
import Testing
@testable import Ithaca

/// Describe It's To Request row: Athena's suggestions found on Seerr.
@Suite("Pick Something to request")
struct PickSomethingRequestablesTests {
    @Test("A suggestion is the search result of the same kind and title, a year either side, or a longer title in that exact year")
    func match() throws {
        let results = try [
            media(1, "tv", "Sunshine", date: "2007-01-01"),
            media(2, "movie", "Sunshine", date: "2007-04-05"),
            media(3, "movie", "Borat: Cultural Learnings of America", date: "2006-11-02"),
            media(4, "movie", "Moonlight", date: "2016-10-21"),
        ]
        func found(_ title: String, _ year: Int?, _ type: SeerrMediaType = .movie) -> Int? {
            let suggestion = AthenaSuggestion(title: title, year: year, discoverId: nil, reason: "")
            return PickSomethingRequestFinder.match(suggestion, in: results, type: type)?.id
        }
        #expect(found("sunshine", 2008) == 2)
        #expect(found("Sunshine", 2007, .tv) == 1)
        #expect(found("Sunshine", 2010) == nil)
        #expect(found("Borat", 2006) == 3)
        #expect(found("Borat", 2007) == nil)
        #expect(found("Moon", 2016) == nil)
        #expect(found("Sunshine", nil) == 2)
    }

    @Test("Only released titles of the kind that nobody has requested and no server has can be requested")
    func requestable() throws {
        let owned = try JSONDecoder().decode(PlexItem.self, from: JSONSerialization.data(withJSONObject: [
            "ratingKey": "1", "key": "/library/metadata/1", "type": "movie", "title": "Heat",
            "Guid": [["id": "tmdb://949"]],
        ]))
        let library = TasteLibrary(items: [owned], serverOrder: [])
        func requestable(_ media: SeerrSearchMedia) -> Bool {
            PickSomethingRequestFinder.isRequestable(media, type: .movie, library: library, today: "2026-10-25")
        }
        #expect(requestable(try media(10, "movie", "Moon", date: "2009-06-12")))
        #expect(requestable(try media(10, "movie", "Moon", date: "2009-06-12", status: 7)))
        #expect(!requestable(try media(10, "movie", "Moon", date: "2009-06-12", status: 5)))
        #expect(!requestable(try media(10, "movie", "Moon", date: "2009-06-12", status: 2)))
        #expect(!requestable(try media(10, "movie", "Moon", date: "2026-12-16")))
        #expect(!requestable(try media(10, "movie", "Moon", date: nil)))
        #expect(!requestable(try media(10, "tv", "Moon", date: "2009-06-12")))
        #expect(!requestable(try media(949, "movie", "Heat", date: "1995-12-15")))
    }

    @Test("Scores read each Plex rating's source, and only a known score below a minimum fails it")
    func scores() throws {
        let rottenTomatoes = try plexItem(
            rating: 7.3, ratingImage: "rottentomatoes://image.rating.ripe",
            audience: 8.7, audienceImage: "rottentomatoes://image.rating.upright"
        )
        #expect(ReviewScores(item: rottenTomatoes) == ReviewScores(critics: 73, audience: 87))
        let imdb = try plexItem(audience: 8.1, audienceImage: "imdb://image.rating")
        #expect(ReviewScores(item: imdb) == ReviewScores(imdb: 8.1))

        let critics80 = AthenaMinimums(critics: 80)
        #expect(!ReviewScores(critics: 73).meets(critics80))
        #expect(ReviewScores(critics: 80).meets(critics80))
        #expect(ReviewScores(imdb: 8.1).meets(critics80))
        #expect(!ReviewScores(imdb: 7.4).meets(AthenaMinimums(imdb: 7.5)))
    }

    @Test("An older Athena's answer, picks alone, still reads")
    func olderAnswer() throws {
        let answer = try JSONDecoder().decode(AthenaAnswer.self, from: Data(#"{"picks":[{"id":"1","reason":"Gags."}]}"#.utf8))
        #expect(answer.picks == [AthenaPick(id: "1", reason: "Gags.")])
        #expect(answer.suggestions.isEmpty)
        #expect(answer.minimums == AthenaMinimums())
    }

    // MARK: - Fixtures

    private func media(_ id: Int, _ type: String, _ title: String, date: String?, status: Int? = nil) throws -> SeerrSearchMedia {
        var object: [String: Any] = ["id": id, "mediaType": type, type == "tv" ? "name" : "title": title]
        object[type == "tv" ? "firstAirDate" : "releaseDate"] = date
        if let status {
            object["mediaInfo"] = ["status": status]
        }
        return try JSONDecoder().decode(SeerrSearchMedia.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func plexItem(
        rating: Double? = nil,
        ratingImage: String? = nil,
        audience: Double? = nil,
        audienceImage: String? = nil
    ) throws -> PlexItem {
        var object: [String: Any] = ["ratingKey": "1", "key": "/library/metadata/1", "type": "movie", "title": "Title"]
        object["rating"] = rating
        object["ratingImage"] = ratingImage
        object["audienceRating"] = audience
        object["audienceRatingImage"] = audienceImage
        return try JSONDecoder().decode(PlexItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
