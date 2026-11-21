import Foundation

@MainActor
@Observable
final class HomeHubItemsViewModel {
    let hub: PlexHub

    private let plexService: PlexService

    private(set) var items: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var error: String?
    /// A failed action (Mark Watched and the like). Shown as an alert, because
    /// `error` only shows while the screen has no content.
    var actionError: String?
    /// Set when a "load more" page failed. The grid keeps its items and the
    /// page can be retried.
    private(set) var loadMoreFailed = false

    /// Items asked of each source per page.
    private let pageSize = 50
    /// How far each contributing server's share of the row has been paged, in
    /// priority order.
    private var cursors: [SourceCursor] = []
    private var queryGeneration = 0
    /// The last card to appear: the scroll position, and the item just opened
    /// when the grid is shown again. Read only by the refresh.
    @ObservationIgnored private var lastAppearedID: PlexItemID?
    /// A refresh re-fetches what is loaded and replaces it, so no page may
    /// be appended meanwhile.
    private var isRefreshing = false
    /// The tail was reached during a refresh. Its cells are already on screen
    /// and will not appear again, so the page is fetched once the refresh lands.
    private var loadsMoreAfterRefresh = false

    private struct SourceCursor {
        let key: String
        let serverID: String
        var offset = 0
        var isExhausted = false
    }

    init(hub: PlexHub, plexService: PlexService) {
        self.hub = hub
        self.plexService = plexService
    }

    var navigationTitle: String {
        normalizedTitle(for: hub.title)
    }

    private var hasMoreItems: Bool {
        cursors.contains { !$0.isExhausted }
    }

    func loadItems() async {
        guard items.isEmpty else {
            // Back from a detail page or the player, or the app returning:
            // pick up watch progress made meanwhile. A failure keeps the grid.
            await refreshLoadedItems()
            return
        }
        await reloadItems()
    }

    /// Loads the first page of the row from **every** server that contributed
    /// to it and merges them, so "Show All" on a merged row is the full row
    /// rather than the primary server's share of it.
    func reloadItems() async {
        let generation = beginNewQuery()
        isLoading = true
        error = nil

        // A source that fails contributes nothing rather than failing the page:
        // one unreachable server must not hide the other's half of the row.
        // Only when every server fails is the error shown, with Retry.
        let sources = hub.sources.compactMap { source in
            source.key?.nilIfEmpty.map { SourceCursor(key: $0, serverID: source.serverID) }
        }
        do {
            let page = try await fetchFromStart(sources)
            guard generation == queryGeneration else { return }
            apply(page)
        } catch {
            guard generation == queryGeneration else { return }
            items = []
            cursors = []
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func setWatched(_ watched: Bool, for item: PlexItem) async {
        do {
            try await plexService.setWatchedAcrossServers(watched, id: item.id)
            await refreshLoadedItems()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Re-fetches what is already loaded from each source, so the grid keeps
    /// its length and scroll position. A failure keeps the current items.
    /// Past three pages per source only a window around the last card that
    /// appeared is re-fetched, and changed items are replaced in place.
    private func refreshLoadedItems() async {
        let generation = beginNewQuery()
        isRefreshing = true
        if cursors.contains(where: { $0.offset > 3 * pageSize }) {
            await refreshWindow(generation: generation)
        } else {
            let page = try? await fetchFromStart(cursors)
            guard generation == queryGeneration else { return }
            if let page { apply(page) }
        }
        guard generation == queryGeneration else { return }
        isRefreshing = false
        if loadsMoreAfterRefresh {
            loadsMoreAfterRefresh = false
            if hasMoreItems { await loadMore() }
        }
    }

    private func refreshWindow(generation: Int) async {
        let anchor = lastAppearedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let perSource = anchor / max(cursors.count, 1)
        let start = max(perSource / pageSize - 1, 0) * pageSize
        let requests: [HubItemsPageRequest] = cursors.map {
            (key: $0.key, serverID: $0.serverID, start: start, size: 3 * pageSize)
        }
        let outcomes = await plexService.hubItemsPages(requests)
        guard generation == queryGeneration else { return }

        var fetchedByID: [PlexItemID: PlexItem] = [:]
        for case .success(let fetched) in outcomes {
            for item in fetched { fetchedByID[item.id] = item }
        }
        var updated = items
        var changed = false
        for index in updated.indices {
            guard let fresh = fetchedByID[updated[index].id],
                  fresh != updated[index]
                    || fresh.viewedLeafCount != updated[index].viewedLeafCount
                    || fresh.leafCount != updated[index].leafCount
            else { continue }
            updated[index] = fresh
            changed = true
        }
        if changed { items = updated }
    }

    /// How far from the end of the loaded items the next page is requested,
    /// matching the library grid.
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
        guard hasMoreItems, !isLoadingMore, !loadMoreFailed, !isLoading,
              items.suffix(Self.loadMoreLookahead).contains(where: { $0.id == currentItem.id })
        else { return }
        guard !isRefreshing else {
            loadsMoreAfterRefresh = true
            return
        }

        await loadMore()
    }

    /// Retries after a failed "load more".
    func retryLoadMore() async {
        guard hasMoreItems, !isLoadingMore, !isLoading, !isRefreshing else { return }
        await loadMore()
    }

    /// Fetches the next page of every source that has more, appends the batch
    /// merged, and advances each source by what it returned.
    private func loadMore() async {
        let generation = queryGeneration
        isLoadingMore = true
        loadMoreFailed = false
        defer {
            if generation == queryGeneration { isLoadingMore = false }
        }

        // A page of titles the grid already shows (the same items from another
        // server) adds nothing and leaves no new cell to trigger the next
        // page, so keep going, a few pages at most, until something new comes.
        for _ in 0..<5 {
            let pending = cursors.indices.filter { !cursors[$0].isExhausted }
            guard !pending.isEmpty else { return }
            let requests: [HubItemsPageRequest] = pending.map {
                (key: cursors[$0].key, serverID: cursors[$0].serverID, start: cursors[$0].offset, size: pageSize)
            }

            let outcomes = await plexService.hubItemsPages(requests)
            guard generation == queryGeneration else { return }

            // A failed source keeps its cursor and is asked again with the next
            // page; the page only counts as failed when nothing new arrived.
            var lists: [[PlexItem]] = []
            var sourceFailed = false
            for (index, outcome) in zip(pending, outcomes) {
                guard case .success(let fetched) = outcome else {
                    sourceFailed = true
                    continue
                }
                lists.append(fetched)
                cursors[index].offset += fetched.count
                cursors[index].isExhausted = Self.isExhausted(returned: fetched.count, requested: pageSize)
            }

            let merged = PlexItemMerge.interleave(lists)
            plexService.registerAlternates(merged.alternates)
            let newItems = unseen(merged.items)
            items.append(contentsOf: newItems)
            if sourceFailed {
                loadMoreFailed = newItems.isEmpty
                return
            }
            if !newItems.isEmpty { return }
        }
        // Still nothing new: offer Retry rather than leave the grid stuck.
        loadMoreFailed = hasMoreItems
    }

    /// Fetches each source from the start, as far as it was already paged and
    /// at least one page, and merges the lists. A failed source starts over on
    /// the next page; throws only when every source failed.
    private func fetchFromStart(
        _ sources: [SourceCursor]
    ) async throws -> (merged: MergedPlexItems, cursors: [SourceCursor]) {
        let sizes = sources.map { max($0.offset, pageSize) }
        let requests: [HubItemsPageRequest] = zip(sources, sizes).map {
            (key: $0.key, serverID: $0.serverID, start: 0, size: $1)
        }
        let outcomes = await plexService.hubItemsPages(requests)

        var lists: [[PlexItem]] = []
        var cursors: [SourceCursor] = []
        var firstError: (any Error)?
        for (index, outcome) in outcomes.enumerated() {
            var cursor = SourceCursor(key: sources[index].key, serverID: sources[index].serverID)
            switch outcome {
            case .success(let fetched):
                lists.append(fetched)
                cursor.offset = fetched.count
                cursor.isExhausted = Self.isExhausted(returned: fetched.count, requested: sizes[index])
            case .failure(let error):
                firstError = firstError ?? error
            }
            cursors.append(cursor)
        }
        if lists.isEmpty, let firstError { throw firstError }

        return (PlexItemMerge.interleave(lists), cursors)
    }

    private func apply(_ page: (merged: MergedPlexItems, cursors: [SourceCursor])) {
        plexService.registerAlternates(page.merged.alternates)
        cursors = page.cursors
        items = page.merged.items
    }

    /// A source is done once it returns other than what was asked: fewer is
    /// the end of its row, more means its key ignores container paging and
    /// sent everything.
    private static func isExhausted(returned: Int, requested: Int) -> Bool {
        returned != requested
    }

    /// The batch without what the grid already shows. Offset paging can repeat
    /// a boundary item, and on a merged row a title can arrive from one server
    /// on an earlier page and from another on this one.
    private func unseen(_ batch: [PlexItem]) -> [PlexItem] {
        let isMerged = cursors.count > 1
        var seenIDs = Set(items.map(\.id))
        var seenKeys: Set<PlexContentKey> = isMerged ? Set(items.map(\.contentKey)) : []
        return batch.filter { item in
            guard seenIDs.insert(item.id).inserted else { return false }
            return !isMerged || seenKeys.insert(item.contentKey).inserted
        }
    }

    private func beginNewQuery() -> Int {
        queryGeneration += 1
        isLoadingMore = false
        isRefreshing = false
        loadsMoreAfterRefresh = false
        loadMoreFailed = false
        return queryGeneration
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

    private func normalizedTitle(for title: String) -> String {
        guard title.lowercased().contains("recently added") else { return title }

        let suffix = title.replacingOccurrences(
            of: "Recently Added",
            with: "",
            options: [.caseInsensitive]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return suffix.isEmpty ? "Recently added" : "Recently added \(suffix)"
    }
}
