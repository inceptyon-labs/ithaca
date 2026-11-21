import Foundation

/// A row Ithaca builds for Home: a taste shelf ("Because You Liked X", "Top
/// Picks for You") or a genre shelf ("Comedy Movies").
struct HomePersonalizedShelf: Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let items: [PlexItem]
    /// Genre shelves only: the library and genre "Show All" opens.
    let showAll: HomeShelfShowAll?

    func replacingItems(_ items: [PlexItem]) -> HomePersonalizedShelf {
        HomePersonalizedShelf(id: id, title: title, items: items, showAll: showAll)
    }

    var isTasteShelf: Bool { id.hasPrefix("taste:") }

    /// Taste shelves first, then the genre shelves without the titles the
    /// taste shelves already show or the profile has rated since the genre
    /// shelves were built. A genre shelf left with fewer than `minimumItems`
    /// is dropped. `genre` is the genre engine's own answer, so a rebuild of
    /// the taste shelves alone starts from the full rows again.
    static func combining(
        taste: TasteHomeShelves,
        genre: [HomePersonalizedShelf],
        minimumItems: Int
    ) -> [HomePersonalizedShelf] {
        var used = RecommendationSeenTitles()
        for shelf in taste.shelves {
            used.formUnion(shelf.items)
        }
        let genreShelves = genre.compactMap { shelf -> HomePersonalizedShelf? in
            let items = shelf.items.filter { item in
                !used.contains(item) && !taste.ratedItemIDs.contains(item.id)
            }
            return items.count >= minimumItems ? shelf.replacingItems(items) : nil
        }
        return taste.shelves + genreShelves
    }
}

struct HomeShelfShowAll: Sendable, Hashable {
    let library: PlexLibrary
    let genre: LibraryGenreOption
}
