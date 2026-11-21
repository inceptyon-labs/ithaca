import Foundation

struct LibraryGenreOption: Hashable, Identifiable, Sendable {
    static let all = LibraryGenreOption(title: "All Genres", value: nil)

    var id: String { value ?? "__all__" }

    let title: String
    let value: String?
}

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case titleAscending
    case titleDescending
    case yearDescending
    case yearAscending
    case releaseDateDescending
    case addedAtDescending
    case durationDescending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .titleAscending:
            "Title A-Z"
        case .titleDescending:
            "Title Z-A"
        case .yearDescending:
            "Year Newest"
        case .yearAscending:
            "Year Oldest"
        case .releaseDateDescending:
            "Release Date Newest"
        case .addedAtDescending:
            "Date Added Newest"
        case .durationDescending:
            "Duration Longest"
        }
    }

    var plexValue: String {
        switch self {
        case .titleAscending:
            "titleSort"
        case .titleDescending:
            "titleSort:desc"
        case .yearDescending:
            "year:desc"
        case .yearAscending:
            "year"
        case .releaseDateDescending:
            "originallyAvailableAt:desc"
        case .addedAtDescending:
            "addedAt:desc"
        case .durationDescending:
            "duration:desc"
        }
    }

    /// The sort choices offered for a library of the given type. Video
    /// libraries lead with upload-date sorts (year is meaningless for clips);
    /// movie/show libraries keep their original options untouched.
    static func options(for libraryType: PlexLibraryType?) -> [LibrarySortOption] {
        switch libraryType {
        case .video:
            [.releaseDateDescending, .addedAtDescending, .titleAscending, .titleDescending, .durationDescending]
        default:
            [.titleAscending, .titleDescending, .yearDescending, .yearAscending]
        }
    }

    static func defaultOption(for libraryType: PlexLibraryType?) -> LibrarySortOption {
        libraryType == .video ? .releaseDateDescending : .titleAscending
    }
}

private struct LibraryItemsQuery: Hashable {
    let genreValue: String?
    let sort: LibrarySortOption
    let unwatchedOnly: Bool
}

@MainActor
@Observable
final class LibraryItemsViewModel {
    private let plexService: PlexService
    let library: PlexLibrary
    /// When set, every fetch is scoped to this collection (used for the
    /// per-channel grids of video libraries).
    private let collection: PlexLibraryCollection?
    private let preferredInitialGenre: LibraryGenreOption?
    private let preferLocalGenreFiltering: Bool
    private let unwatchedFilterStore: LibraryUnwatchedFilterStore

    private(set) var items: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    /// A failed action (Mark Watched and the like). Shown as an alert, because
    /// `error` only shows while the screen has no content.
    var actionError: String?
    /// Set when a "load more" page failed. The grid keeps its items and
    /// `hasMoreItems` stays true so the page can be retried.
    private(set) var loadMoreFailed = false
    private(set) var hasMoreItems = true
    private(set) var availableGenres: [LibraryGenreOption] = [.all]
    private(set) var selectedGenre: LibraryGenreOption = .all
    private(set) var selectedSort: LibrarySortOption = .titleAscending
    /// Remembered per library, so it also applies to the library's genre and
    /// collection grids.
    private(set) var showsUnwatchedOnly: Bool

    private let pageSize = 50
    private var hasLoadedBrowseOptions = false
    private var queryGeneration = 0
    /// The last card to appear: the scroll position, and the item just opened
    /// when the grid is shown again. Read only by the refresh.
    @ObservationIgnored private var lastAppearedID: PlexItemID?
    private var genreMatchCache: [String: Bool] = [:]
    private var localGenreScan: LocalGenreScan?
    /// True when the shelf genre is not in the library's filter list, so it
    /// can only be matched locally.
    private var needsLocalGenreMatch = false

    /// Progress of a local genre scan, kept across "load more" so list pages
    /// already fetched and matched are not requested again.
    private struct LocalGenreScan {
        let generation: Int
        var matched: [PlexItem] = []
        var nextPage = 0
        var pageCount: Int?
        var isExhausted = false
    }

    /// How many detail lookups run at once during a local genre scan.
    private let genreLookupConcurrency = 8

    init(
        library: PlexLibrary,
        plexService: PlexService,
        collection: PlexLibraryCollection? = nil,
        initialGenre: LibraryGenreOption? = nil,
        preferLocalGenreFiltering: Bool = false,
        unwatchedFilterStore: LibraryUnwatchedFilterStore = LibraryUnwatchedFilterStore()
    ) {
        self.library = library
        self.plexService = plexService
        self.collection = collection
        self.preferredInitialGenre = initialGenre
        self.preferLocalGenreFiltering = preferLocalGenreFiltering
        self.selectedGenre = initialGenre ?? .all
        self.selectedSort = LibrarySortOption.defaultOption(for: library.libraryType)
        self.unwatchedFilterStore = unwatchedFilterStore
        self.showsUnwatchedOnly = unwatchedFilterStore.isEnabled(forLibraryID: library.id)
    }

    /// Every fetch on this screen is scoped to the library's own server.
    var serverID: String? { library.serverID }

    var isVideoLibrary: Bool {
        library.libraryType == .video
    }

    var availableSortOptions: [LibrarySortOption] {
        LibrarySortOption.options(for: library.libraryType)
    }

    var defaultSortOption: LibrarySortOption {
        LibrarySortOption.defaultOption(for: library.libraryType)
    }

    var navigationTitle: String {
        if let collection {
            return collection.title
        }

        return selectedGenre == .all ? library.title : selectedGenre.title
    }

    var showsBrowseControls: Bool {
        !items.isEmpty || selectedGenre != .all || showsUnwatchedOnly || availableGenres.count > 1
    }

    var emptyStateSystemImage: String {
        switch library.libraryType {
        case .video: "play.rectangle.fill"
        case .show: "tv"
        default: "film"
        }
    }

    var emptyStateTitle: String {
        if showsUnwatchedOnly {
            return selectedGenre == .all ? "You're all caught up" : "No unwatched titles"
        }
        guard selectedGenre == .all else { return "No matching titles" }
        return collection == nil ? "This library is empty" : "This collection is empty"
    }

    var emptyStateMessage: String? {
        if showsUnwatchedOnly {
            return selectedGenre == .all
                ? "Everything here has been watched. Turn off Unwatched to see it all."
                : "Try another genre or turn off Unwatched."
        }
        guard selectedGenre != .all else { return nil }
        return "Try another genre or switch back to all titles."
    }

    func loadItems() async {
        await loadBrowseOptionsIfNeeded()

        guard items.isEmpty else {
            // Back from a detail page or the player, or the app returning:
            // pick up watch progress and Unwatched changes made meanwhile.
            await refreshLoadedItems()
            return
        }
        await reloadItems()
    }

    func reloadItems() async {
        let generation = beginNewQuery()
        isLoading = true
        error = nil

        do {
            let fetched = try await fetchItems(start: 0, count: pageSize, query: currentQuery)
            guard generation == queryGeneration else { return }

            items = fetched
            hasMoreItems = fetched.count >= pageSize
        } catch {
            guard generation == queryGeneration else { return }

            items = []
            hasMoreItems = false
            self.error = error.localizedDescription
        }

        guard generation == queryGeneration else { return }
        isLoading = false
    }

    func selectGenre(_ genre: LibraryGenreOption) async {
        guard selectedGenre != genre else { return }
        selectedGenre = genre
        await reloadItems()
    }

    func selectSort(_ sort: LibrarySortOption) async {
        guard selectedSort != sort else { return }
        selectedSort = sort
        await reloadItems()
    }

    func setShowsUnwatchedOnly(_ unwatchedOnly: Bool) async {
        guard showsUnwatchedOnly != unwatchedOnly else { return }
        showsUnwatchedOnly = unwatchedOnly
        unwatchedFilterStore.setEnabled(unwatchedOnly, forLibraryID: library.id)
        await reloadItems()
    }

    func setWatched(_ watched: Bool, for item: PlexItem) async {
        do {
            try await plexService.setWatchedAcrossServers(
                watched,
                id: PlexItemID(serverID: item.serverID ?? serverID, ratingKey: item.ratingKey)
            )
            await refreshLoadedItems()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Re-fetches a window of up to three pages around the last card that
    /// appeared (where the user is, or the item they opened), so a deep grid
    /// does not re-download everything loaded. Changed items are replaced in
    /// place; nothing is published when the window is unchanged.
    private func refreshLoadedItems() async {
        let hadMoreItems = hasMoreItems
        let generation = beginNewQuery()
        hasMoreItems = hadMoreItems

        let anchor = lastAppearedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let start = max(anchor / pageSize - 1, 0) * pageSize
        let end = min(start + 3 * pageSize, items.count)
        let count = max(end - start, pageSize)

        do {
            let fetched = try await fetchItems(start: start, count: count, query: currentQuery)
            guard generation == queryGeneration else { return }

            let range = start..<min(start + count, items.count)
            let current = items[range]
            let unchanged = current.count == fetched.count && zip(current, fetched).allSatisfy {
                $0 == $1 && $0.viewedLeafCount == $1.viewedLeafCount && $0.leafCount == $1.leafCount
            }
            if !unchanged {
                let outside = Set(items[..<range.lowerBound].map(\.id))
                    .union(items[range.upperBound...].map(\.id))
                items.replaceSubrange(range, with: fetched.filter { !outside.contains($0.id) })
            }
            if range.upperBound == items.count, fetched.count < count {
                hasMoreItems = false
            }
        } catch {
            guard generation == queryGeneration else { return }

            self.error = error.localizedDescription
        }
    }

    /// How far from the end of the loaded items the next page is requested.
    /// About five rows of the tvOS grid, so holding Down on the remote does
    /// not reach the end before the next page lands.
    private static var loadMoreLookahead: Int {
        #if os(tvOS)
        40
        #else
        30
        #endif
    }

    func loadMoreIfNeeded(currentItem: PlexItem) async {
        lastAppearedID = currentItem.id
        // Only the tail can trigger a page, so never scan the whole list for
        // every cell that appears.
        guard hasMoreItems, !isLoadingMore, !loadMoreFailed,
              items.suffix(Self.loadMoreLookahead).contains(where: { $0.id == currentItem.id })
        else { return }

        await loadMore()
    }

    /// Retries after a failed "load more".
    func retryLoadMore() async {
        guard hasMoreItems, !isLoadingMore else { return }
        await loadMore()
    }

    private func loadMore() async {
        let generation = queryGeneration
        let start = items.count
        let query = currentQuery

        isLoadingMore = true
        loadMoreFailed = false
        defer {
            if generation == queryGeneration { isLoadingMore = false }
        }

        do {
            let fetched = try await fetchItems(start: start, count: pageSize, query: query)
            guard generation == queryGeneration else { return }

            // Offset paging can repeat a boundary item when the library changes between pages.
            let existingIDs = Set(items.map(\.id))
            items.append(contentsOf: fetched.filter { !existingIDs.contains($0.id) })
            hasMoreItems = fetched.count >= pageSize
        } catch {
            guard generation == queryGeneration else { return }
            loadMoreFailed = true
        }
    }

    func posterURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(plexService: plexService, width: width, height: height)
    }

    func progress(for item: PlexItem) -> Double? {
        item.posterProgress
    }

    func subtitle(for item: PlexItem) -> String? {
        item.standardPosterSubtitle
    }

    private var currentQuery: LibraryItemsQuery {
        LibraryItemsQuery(
            genreValue: selectedGenre.value,
            sort: selectedSort,
            unwatchedOnly: showsUnwatchedOnly
        )
    }

    private func beginNewQuery() -> Int {
        queryGeneration += 1
        hasMoreItems = true
        isLoadingMore = false
        loadMoreFailed = false
        localGenreScan = nil
        return queryGeneration
    }

    private func fetchItems(start: Int, count: Int, query: LibraryItemsQuery) async throws -> [PlexItem] {
        // Local matching is only needed while the genre is the unresolved
        // shelf genre (a tag name, not a Plex filter id).
        if query.genreValue != nil, needsLocalGenreMatch, selectedGenre == preferredInitialGenre {
            return try await fetchLocallyFilteredItems(
                start: start,
                count: count,
                query: query,
                genre: selectedGenre
            )
        }

        return try await fetchServerFilteredItems(start: start, count: count, query: query)
    }

    /// The query's filters Plex applies; the genre is left out when it is
    /// matched locally instead.
    private func serverFilters(for query: LibraryItemsQuery, includingGenre: Bool) -> [String: String] {
        LibraryUnwatchedFilter.serverFilters(
            libraryType: library.libraryType,
            collectionKey: collection?.key,
            unwatchedOnly: query.unwatchedOnly,
            genreValue: includingGenre ? query.genreValue : nil
        )
    }

    private func fetchServerFilteredItems(start: Int, count: Int, query: LibraryItemsQuery) async throws -> [PlexItem] {
        try await plexService.getLibraryItems(
            sectionId: library.key,
            start: start,
            size: count,
            sort: query.sort.plexValue,
            filters: serverFilters(for: query, includingGenre: true),
            serverID: serverID
        )
    }

    private func fetchLocallyFilteredItems(
        start: Int,
        count: Int,
        query: LibraryItemsQuery,
        genre: LibraryGenreOption
    ) async throws -> [PlexItem] {
        let generation = queryGeneration
        var scan = localGenreScan.flatMap { $0.generation == generation ? $0 : nil }
            ?? LocalGenreScan(generation: generation)
        let baseFilters = serverFilters(for: query, includingGenre: false)
        let serverPageSize = pageSize
        let neededMatchCount = start + count

        if scan.pageCount == nil {
            let totalCount = try await plexService.getLibraryItemCount(
                sectionId: library.key,
                filters: baseFilters,
                serverID: serverID
            )
            scan.pageCount = Int(ceil(Double(totalCount) / Double(serverPageSize)))
        }
        let pageCount = scan.pageCount ?? 0

        while scan.matched.count < neededMatchCount, !scan.isExhausted, scan.nextPage < pageCount {
            let fetchedItems = try await plexService.getLibraryItems(
                sectionId: library.key,
                start: scan.nextPage * serverPageSize,
                size: serverPageSize,
                sort: query.sort.plexValue,
                filters: baseFilters,
                serverID: serverID
            )
            guard generation == queryGeneration else { return [] }

            if fetchedItems.isEmpty {
                scan.isExhausted = true
            } else {
                scan.matched.append(contentsOf: await matchingItems(in: fetchedItems, genre: genre))
                scan.nextPage += 1
                if fetchedItems.count < serverPageSize {
                    scan.isExhausted = true
                }
            }

            guard generation == queryGeneration else { return [] }
            localGenreScan = scan
        }

        guard scan.matched.count > start else { return [] }
        return Array(scan.matched.dropFirst(start).prefix(count))
    }

    /// The items matching the genre, in list order, with detail lookups for
    /// unknown items running `genreLookupConcurrency` at a time.
    private func matchingItems(in items: [PlexItem], genre: LibraryGenreOption) async -> [PlexItem] {
        var matches = [Bool](repeating: false, count: items.count)

        await withTaskGroup(of: (Int, Bool).self) { group in
            var next = 0
            func addNext() {
                guard next < items.count else { return }
                let index = next
                next += 1
                group.addTask { [self] in
                    (index, await self.itemMatchesGenre(items[index], genre: genre))
                }
            }

            for _ in 0..<min(genreLookupConcurrency, items.count) { addNext() }
            while let (index, matched) = await group.next() {
                matches[index] = matched
                addNext()
            }
        }

        return zip(items, matches).compactMap { $1 ? $0 : nil }
    }

    private func loadBrowseOptionsIfNeeded() async {
        guard !hasLoadedBrowseOptions else { return }
        hasLoadedBrowseOptions = true

        do {
            var loadedGenres = try await LibraryGenreSupport.loadGenreOptions(
                sectionId: library.key,
                serverID: serverID,
                plexService: plexService
            )

            // A shelf genre carries a tag name, which Plex's genre filter does
            // not accept. When the library lists that genre, switch to its
            // real filter id so Plex filters server-side.
            if preferLocalGenreFiltering,
               let preferredInitialGenre,
               selectedGenre == preferredInitialGenre,
               let resolved = loadedGenres.first(where: {
                   $0.value != nil && LibraryGenreSupport.normalizeGenreTitle($0.title)
                       == LibraryGenreSupport.normalizeGenreTitle(preferredInitialGenre.title)
               }) {
                selectedGenre = resolved
            } else if preferLocalGenreFiltering, preferredInitialGenre != nil {
                needsLocalGenreMatch = true
            }

            if let preferredInitialGenre,
               preferredInitialGenre != .all,
               !loadedGenres.contains(preferredInitialGenre),
               selectedGenre == preferredInitialGenre {
                loadedGenres.insert(preferredInitialGenre, at: min(1, loadedGenres.count))
            }

            availableGenres = loadedGenres
        } catch {
            needsLocalGenreMatch = preferLocalGenreFiltering
            if let preferredInitialGenre, preferredInitialGenre != .all {
                availableGenres = [.all, preferredInitialGenre]
            } else {
                availableGenres = [.all]
            }
        }
    }

    private func itemMatchesGenre(
        _ item: PlexItem,
        genre: LibraryGenreOption
    ) async -> Bool {
        let cacheKey = "\(genre.id)|\(item.id.storageKey)"

        if let cached = genreMatchCache[cacheKey] {
            return cached
        }

        let matches: Bool

        if let genres = item.genres,
           LibraryGenreSupport.containsGenre(genres, matching: genre) {
            matches = true
        } else if let details = try? await plexService.getMediaDetails(
            ratingKey: item.ratingKey,
            serverID: item.serverID ?? serverID
        ),
                  let genres = details.genres {
            matches = LibraryGenreSupport.containsGenre(genres, matching: genre)
        } else {
            matches = false
        }

        genreMatchCache[cacheKey] = matches
        return matches
    }
}
