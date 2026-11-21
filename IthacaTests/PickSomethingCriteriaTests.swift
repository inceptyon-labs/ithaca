import Foundation
import Testing
@testable import Ithaca

/// Pick Something's filters: the Plex query, the final check on the active
/// profile's copy, and the room check for everyone else watching.
@Suite("Pick Something criteria")
struct PickSomethingCriteriaTests {
    @Test("Movies send unwatched, genre and Plex's less-than duration filter")
    func movieServerFilters() {
        let criteria = PickSomethingCriteria(
            kind: .movie,
            runtime: PickSomethingRuntime(maxMinutes: 120),
            genreTitle: "Comedy"
        )
        #expect(criteria.serverFilters(genreValue: "7") == [
            "unwatched": "1",
            "genre": "7",
            "duration<<": "7200000",
        ])
    }

    @Test("Shows filter on their episodes and leave the length to the local check")
    func showServerFilters() {
        let criteria = PickSomethingCriteria(kind: .show, runtime: PickSomethingRuntime(maxMinutes: 30))
        #expect(criteria.serverFilters(genreValue: nil) == ["unwatchedLeaves": "1"])
    }

    @Test("Runtime is a strict upper bound, and an item with no duration never fits one")
    func runtimeMatch() throws {
        let criteria = PickSomethingCriteria(kind: .movie, runtime: PickSomethingRuntime(maxMinutes: 90))
        #expect(criteria.matches(try item(duration: 89 * 60_000)))
        #expect(!criteria.matches(try item(duration: 90 * 60_000)))
        #expect(!criteria.matches(try item(duration: nil)))
        #expect(PickSomethingCriteria(kind: .movie).matches(try item(duration: nil)))
    }

    @Test("Unwatched leaves out started movies and shows, and nothing when off")
    func unwatchedMatch() throws {
        let unwatched = PickSomethingCriteria(kind: .movie)
        #expect(unwatched.matches(try item()))
        #expect(!unwatched.matches(try item(viewCount: 1)))
        #expect(!unwatched.matches(try item(viewOffset: 60_000)))

        let shows = PickSomethingCriteria(kind: .show)
        #expect(shows.matches(try item(type: "show")))
        #expect(!shows.matches(try item(type: "show", viewedLeafCount: 2)))
        #expect(!shows.matches(try item(type: "movie")))

        var anything = PickSomethingCriteria(kind: .movie)
        anything.unwatchedOnly = false
        #expect(anything.matches(try item(viewCount: 3)))
    }

    @Test("A placeholder trailer filed as a movie edition never fits")
    func placeholderMatch() throws {
        #expect(!PickSomethingCriteria(kind: .movie).matches(try item(duration: 2 * 60_000, edition: "Trailer")))
        #expect(PickSomethingCriteria(kind: .movie).matches(try item(edition: "Director's Cut")))
    }

    @Test("Another viewer rules out what they have seen, and anything they cannot see")
    func roomCheck() {
        var criteria = PickSomethingCriteria(kind: .movie)
        let unseen = PlexViewerItemState(viewCount: 0, viewOffset: 0, viewedLeafCount: 0)
        let seen = PlexViewerItemState(viewCount: 1, viewOffset: 0, viewedLeafCount: 0)
        #expect(criteria.allows(unseen))
        #expect(!criteria.allows(seen))
        #expect(!criteria.allows(nil))

        criteria.unwatchedOnly = false
        #expect(criteria.allows(seen))
        #expect(!criteria.allows(nil))
    }

    @Test("Length options per kind")
    func runtimeOptions() {
        #expect(PickSomethingRuntime.options(for: .movie).map(\.title)
            == ["Any Length", "Under 1h 30m", "Under 2h", "Under 2h 30m"])
        #expect(PickSomethingRuntime.options(for: .show).map(\.title)
            == ["Any Length", "Under 30m", "Under 1h"])
    }

    private func item(
        type: String = "movie",
        duration: Int? = 100 * 60_000,
        viewCount: Int? = nil,
        viewOffset: Int? = nil,
        viewedLeafCount: Int? = nil,
        edition: String? = nil
    ) throws -> PlexItem {
        var json: [String: Any] = ["ratingKey": "1", "key": "/library/metadata/1", "type": type, "title": "Title"]
        json["duration"] = duration
        json["viewCount"] = viewCount
        json["viewOffset"] = viewOffset
        json["viewedLeafCount"] = viewedLeafCount
        json["editionTitle"] = edition
        return try JSONDecoder().decode(PlexItem.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
