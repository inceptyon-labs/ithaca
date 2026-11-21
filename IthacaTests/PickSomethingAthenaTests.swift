import Foundation
import Testing
@testable import Ithaca

/// Describe It: what Pick Something sends Athena.
@Suite("Pick Something with Athena")
struct PickSomethingAthenaTests {
    @Test("The list is the kind's titles that fit the filters, unseen on every copy, in a stable order, without placeholders; genre is Plex's own membership")
    func options() throws {
        let library = TasteLibrary(items: [
            try item("movie", 1, "Zodiac", genres: ["Thriller"], minutes: 157),
            try item("movie", 2, "Airplane!", genres: ["Comedy"], minutes: 88, contentRating: "PG", critics: 9.7),
            try item("movie", 3, "Hot Fuzz", genres: ["Comedy", "Action"], minutes: 121),
            // Unseen here, watched on the other server: seen.
            try item("movie", 4, "Clue", genres: ["Comedy"], minutes: 94, server: "a"),
            try item("movie", 4, "Clue", genres: ["Comedy"], minutes: 94, viewCount: 1, server: "b"),
            try item("movie", 5, "Heat", genres: ["Crime"], minutes: 170, rating: 10),
            try item("show", 6, "Brassic", genres: ["Comedy"], minutes: 45),
            // An Agregarr placeholder: a trailer filed as an edition.
            try item("movie", 8, "Casablanca", genres: ["Drama"], minutes: 2, edition: "Trailer"),
        ], serverOrder: ["a", "b"])

        var criteria = PickSomethingCriteria(kind: .movie)
        let unwatched = PickSomethingAthenaOptions(library: library, criteria: criteria, genreMemberIDs: nil)
        #expect(unwatched.titles.map(\.title) == ["Airplane!", "Hot Fuzz", "Zodiac"])
        #expect(unwatched.titles[0] == AthenaPickRequest.Title(
            id: "1", title: "Airplane!", genres: ["Comedy"], minutes: 88, contentRating: "PG",
            scores: ReviewScores(critics: 97)
        ))

        criteria.unwatchedOnly = false
        criteria.genreTitle = "comedy"
        criteria.runtime = PickSomethingRuntime(maxMinutes: 120)
        // Plex files Clue's copy on the other server under Comedy; Zodiac is
        // a member but too long.
        let comedies = PickSomethingAthenaOptions(library: library, criteria: criteria, genreMemberIDs: [
            PlexItemID(serverID: nil, ratingKey: "2"),
            PlexItemID(serverID: "b", ratingKey: "4b"),
            PlexItemID(serverID: nil, ratingKey: "1"),
        ])
        #expect(comedies.titles.map(\.title) == ["Airplane!", "Clue"])
        #expect(comedies.titles[1].seen == true)
        // The shown copy is the higher-priority server's.
        #expect(comedies.entry(for: "2")?.item.serverID == "a")
        #expect(comedies.entry(for: "2")?.copies.count == 2)
        #expect(comedies.ids { $0.title == "Clue" } == ["2"])
    }

    @Test("Taste reads seeds as loved, liked, disliked and watched lately, with years")
    func taste() throws {
        let library = TasteLibrary(items: [
            try item("movie", 5, "Heat", minutes: 170, rating: 10, year: 1995),
            try item("movie", 7, "Cats", minutes: 110, rating: 2),
        ], serverOrder: [])
        let catalog = TasteCatalog(library: library, seeds: TasteScoring.seeds(in: library, now: .now))
        #expect(AthenaPickRequest.Taste(catalog: catalog) == AthenaPickRequest.Taste(
            loved: ["Heat (1995)"], disliked: ["Cats"]
        ))
    }

    @Test("A typed address without a scheme is plain HTTP; nonsense is no address")
    func address() {
        #expect(AthenaClient(address: " 192.168.1.10:8800/ ")?.baseURL.absoluteString == "http://192.168.1.10:8800")
        #expect(AthenaClient(address: "https://athena.local")?.baseURL.absoluteString == "https://athena.local")
        #expect(AthenaClient(address: "") == nil)
        #expect(AthenaClient(address: "ftp://host") == nil)
    }

    @Test("Plain HTTP is refused for a host outside the home network")
    func plainHTTPStaysOnTheHomeNetwork() {
        #expect(AthenaClient(address: "http://203.0.113.7:8800") == nil)
        #expect(AthenaClient(address: "athena.example.com") == nil)
        #expect(AthenaClient.refusesAsInsecure("athena.example.com"))
        #expect(AthenaClient(address: "https://athena.example.com") != nil)
        #expect(!AthenaClient.refusesAsInsecure(""))
    }

    // MARK: - Fixtures

    /// An item as the slim library listing returns it.
    private func item(
        _ type: String,
        _ tmdbID: Int,
        _ title: String,
        genres: [String] = [],
        minutes: Int,
        contentRating: String? = nil,
        viewCount: Int? = nil,
        rating: Double? = nil,
        year: Int? = nil,
        server: String? = nil,
        edition: String? = nil,
        critics: Double? = nil
    ) throws -> PlexItem {
        var object: [String: Any] = [
            "ratingKey": "\(tmdbID)\(server ?? "")",
            "key": "/library/metadata/\(tmdbID)",
            "type": type,
            "title": title,
            "duration": minutes * 60_000,
            "Guid": [["id": "tmdb://\(tmdbID)"]],
            "Genre": genres.map { ["tag": $0] },
        ]
        object["contentRating"] = contentRating
        object["viewCount"] = viewCount
        object["year"] = year
        object["editionTitle"] = edition
        if let critics {
            object["rating"] = critics
            object["ratingImage"] = "rottentomatoes://image.rating.ripe"
        }
        if let rating {
            object["userRating"] = rating
            object["lastRatedAt"] = Int(Date.now.timeIntervalSince1970)
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.ithacaServerID] = server
        return try decoder.decode(PlexItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
