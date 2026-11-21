import Foundation

/// A title by its TMDB identity: what TMDB's recommendations name and what a
/// Plex `tmdb://` guid carries. Movie and TV ids are separate spaces.
struct TasteTitleKey: Hashable, Sendable {
    let type: SeerrMediaType
    let tmdbID: Int

    init(type: SeerrMediaType, tmdbID: Int) {
        self.type = type
        self.tmdbID = tmdbID
    }

    init?(item: PlexItem) {
        let type: SeerrMediaType
        switch item.type {
        case .movie: type = .movie
        case .show: type = .tv
        default: return nil
        }
        guard let value = item.guids.lazy.compactMap({ $0.value(for: "tmdb") }).first,
              let tmdbID = Int(value) else {
            return nil
        }
        self.init(type: type, tmdbID: tmdbID)
    }

    init?(media: SeerrSearchMedia) {
        guard let type = media.supportedMediaType else { return nil }
        self.init(type: type, tmdbID: media.id)
    }
}

/// The viewer's movie and TV libraries by TMDB id, every server's copies of a
/// title together.
struct TasteLibrary: Sendable {
    /// Each title's copies, highest-priority server first.
    let copies: [TasteTitleKey: [PlexItem]]
    /// Every copy this profile has rated. A rating is written to every copy
    /// (`setRatingAcrossServers`), so a genre shelf's copy is in here too.
    let ratedItemIDs: Set<PlexItemID>

    init(items: [PlexItem], serverOrder: [String]) {
        let rank = Dictionary(
            serverOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var copies: [TasteTitleKey: [PlexItem]] = [:]
        for item in items where !item.isPlaceholder {
            guard let key = TasteTitleKey(item: item) else { continue }
            copies[key, default: []].append(item)
        }
        self.copies = copies.mapValues { items in
            items.sorted { (rank[$0.serverID ?? ""] ?? .max) < (rank[$1.serverID ?? ""] ?? .max) }
        }
        self.ratedItemIDs = Set(items.filter { $0.userRating != nil }.map(\.id))
    }

    /// The copy a shelf shows: the one on the highest-priority server.
    func item(for key: TasteTitleKey) -> PlexItem? {
        copies[key]?.first
    }

    /// Watched, started or rated on any copy. A rating means the viewer has
    /// seen it, whatever it says.
    func isSeen(_ key: TasteTitleKey) -> Bool {
        copies[key]?.contains { item in
            item.userRating != nil
                || (item.viewCount ?? 0) > 0
                || (item.viewOffset ?? 0) > 0
                || (item.viewedLeafCount ?? 0) > 0
        } ?? false
    }
}

/// A title the viewer's taste is read from: one they rated, or one they
/// finished recently without rating it.
struct TasteSeed: Sendable, Hashable {
    enum Reason: Sendable, Hashable {
        case loved
        case liked
        case watched
        case disliked
    }

    let key: TasteTitleKey
    let title: String
    let reason: Reason
    /// How strongly this title steers recommendations. Negative for a dislike.
    let weight: Double

    var shelfTitle: String {
        switch reason {
        case .watched: "Because You Watched \(title)"
        case .loved, .liked, .disliked: "Because You Liked \(title)"
        }
    }
}

/// A title TMDB recommends from the viewer's seeds, scored across all of them.
struct TasteCandidate: Sendable, Hashable {
    let key: TasteTitleKey
    let media: SeerrSearchMedia
    var score: Double
    /// The liked title that recommends this one most strongly. Its shelf is
    /// where the title goes.
    var strongestSeed: TasteTitleKey?
    var strongestContribution: Double
}

/// Home's taste shelves, plus the titles the profile has rated, which the
/// genre shelves leave out too (`HomePersonalizedShelf.combining`).
struct TasteHomeShelves: Sendable {
    var shelves: [HomePersonalizedShelf] = []
    var ratedItemIDs: Set<PlexItemID> = []
}

/// Everything one recommendation pass learned, shared by Home and Discover.
struct TasteAnalysis: TasteSnapshot {
    let library: TasteLibrary
    let seeds: [TasteSeed]
    let candidates: [TasteCandidate]
    /// When the library behind it was read.
    var readAt = Date.now
    var isComplete = true
}

/// "Because you liked X": the viewer's ratings and recently finished titles,
/// TMDB's recommendations for each (through Seerr), and the viewer's library.
/// Pure functions, so the ranking can be tested without a server.
enum TasteScoring {
    static let maximumLikes = 8
    static let maximumDislikes = 4
    /// How long a finished title counts as taste when it is not rated.
    static let watchedWindow: TimeInterval = 90 * 24 * 60 * 60
    /// A rating fades over this long to `ratingFadeFloor` of its weight, so
    /// what was watched last week outweighs a rating from years ago.
    static let ratingFade: TimeInterval = 2 * 365 * 24 * 60 * 60
    static let ratingFadeFloor = 0.3
    /// TMDB lists its closest matches first; by this position a match counts
    /// for a quarter.
    static let rankFalloff = 40.0

    static func seeds(in library: TasteLibrary, now: Date) -> [TasteSeed] {
        var likes: [(seed: TasteSeed, activity: Int)] = []
        var dislikes: [(seed: TasteSeed, activity: Int)] = []
        let nowSeconds = now.timeIntervalSince1970

        for (key, copies) in library.copies {
            guard let title = copies.first?.title else { continue }

            let rated = copies
                .filter { $0.userRating != nil }
                .max { ($0.lastRatedAt ?? 0) < ($1.lastRatedAt ?? 0) }
            if let rated {
                // Three stars leans neither way: rated, but not a seed.
                guard let rating = PlexTasteRating(plexValue: rated.userRating) else { continue }
                let ratedAt = rated.lastRatedAt ?? Int(nowSeconds)
                let fade = max(ratingFadeFloor, 1 - (nowSeconds - Double(ratedAt)) / ratingFade)
                switch rating {
                case .loved:
                    likes.append((TasteSeed(key: key, title: title, reason: .loved, weight: 2.0 * fade), ratedAt))
                case .liked:
                    likes.append((TasteSeed(key: key, title: title, reason: .liked, weight: 1.3 * fade), ratedAt))
                case .disliked:
                    dislikes.append((TasteSeed(key: key, title: title, reason: .disliked, weight: -1.0 * fade), ratedAt))
                }
                continue
            }

            guard copies.contains(where: isFinished),
                  let lastViewedAt = copies.compactMap(\.lastViewedAt).max() else {
                continue
            }
            let age = nowSeconds - Double(lastViewedAt)
            guard age < watchedWindow else { continue }
            let weight = 0.8 * max(0.4, 1 - age / watchedWindow)
            likes.append((TasteSeed(key: key, title: title, reason: .watched, weight: weight), lastViewedAt))
        }

        func strongestFirst(_ lhs: (seed: TasteSeed, activity: Int), _ rhs: (seed: TasteSeed, activity: Int)) -> Bool {
            if abs(lhs.seed.weight) != abs(rhs.seed.weight) { return abs(lhs.seed.weight) > abs(rhs.seed.weight) }
            if lhs.activity != rhs.activity { return lhs.activity > rhs.activity }
            return lhs.seed.key.tmdbID < rhs.seed.key.tmdbID
        }

        return likes.sorted(by: strongestFirst).prefix(maximumLikes).map(\.seed)
            + dislikes.sorted(by: strongestFirst).prefix(maximumDislikes).map(\.seed)
    }

    /// A movie played to the end, or a show with at least two episodes seen.
    static func isFinished(_ item: PlexItem) -> Bool {
        switch item.type {
        case .movie: (item.viewCount ?? 0) > 0
        case .show: (item.viewedLeafCount ?? 0) >= 2
        default: false
        }
    }

    /// Every title the seeds' recommendation lists name, best first. A title
    /// several liked titles recommend rises; one a disliked title recommends
    /// sinks, and drops out once its score is no longer positive.
    static func candidates(
        seeds: [TasteSeed],
        recommendations: [TasteTitleKey: [SeerrSearchMedia]]
    ) -> [TasteCandidate] {
        let seedKeys = Set(seeds.map(\.key))
        var byKey: [TasteTitleKey: TasteCandidate] = [:]

        for seed in seeds {
            var listed = Set<TasteTitleKey>()
            for (position, media) in (recommendations[seed.key] ?? []).enumerated() {
                guard let key = TasteTitleKey(media: media),
                      key.type == seed.key.type,
                      !seedKeys.contains(key),
                      listed.insert(key).inserted else {
                    continue
                }
                let contribution = seed.weight * max(0.25, 1 - Double(position) / rankFalloff)
                var candidate = byKey[key] ?? TasteCandidate(
                    key: key,
                    media: media,
                    score: 0,
                    strongestSeed: nil,
                    strongestContribution: 0
                )
                candidate.score += contribution
                if contribution > candidate.strongestContribution {
                    candidate.strongestContribution = contribution
                    candidate.strongestSeed = seed.key
                }
                byKey[key] = candidate
            }
        }

        return byKey.values
            .filter { $0.score > 0 && $0.strongestSeed != nil }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.key.tmdbID < $1.key.tmdbID
            }
    }

    /// Home's taste shelves: one "Because You Liked X" row per strong seed
    /// that has enough unseen titles in the library, then "Top Picks for You"
    /// with whatever good matches are left over.
    static func shelves(
        analysis: TasteAnalysis,
        itemsPerShelf: Int,
        maximumSeedShelves: Int = 3,
        minimumItems: Int = 3
    ) -> [HomePersonalizedShelf] {
        let library = analysis.library
        let owned = analysis.candidates.filter { library.item(for: $0.key) != nil && !library.isSeen($0.key) }
        var placed = Set<TasteTitleKey>()
        var shelves: [HomePersonalizedShelf] = []

        for seed in analysis.seeds where seed.weight > 0 {
            guard shelves.count < maximumSeedShelves else { break }
            let picks = Array(owned.filter { $0.strongestSeed == seed.key }.prefix(itemsPerShelf))
            guard picks.count >= minimumItems else { continue }
            shelves.append(HomePersonalizedShelf(
                id: "taste:\(seed.key.type.rawValue):\(seed.key.tmdbID)",
                title: seed.shelfTitle,
                items: picks.compactMap { library.item(for: $0.key) },
                showAll: nil
            ))
            placed.formUnion(picks.map(\.key))
        }

        let rest = owned.filter { !placed.contains($0.key) }.prefix(itemsPerShelf)
        if rest.count >= minimumItems {
            shelves.append(HomePersonalizedShelf(
                id: "taste:top-picks",
                title: "Top Picks for You",
                items: rest.compactMap { library.item(for: $0.key) },
                showAll: nil
            ))
        }

        return shelves
    }

    /// Recommended titles the library does not have and nobody has requested:
    /// Discover's "Recommended for You".
    static func requestable(analysis: TasteAnalysis, limit: Int) -> [SeerrSearchMedia] {
        analysis.candidates
            .filter { analysis.library.item(for: $0.key) == nil && $0.media.isUnrequested }
            .prefix(limit)
            .map(\.media)
    }
}

/// The profile's movie and TV libraries and the taste read from them: Plex
/// only, so Pick Something's Describe It works without Seerr.
struct TasteCatalog: TasteSnapshot {
    let library: TasteLibrary
    let seeds: [TasteSeed]
    var readAt = Date.now
    /// False when a library failed to list: such a catalog is used once,
    /// never kept.
    var isComplete = true
}

/// What `TasteBuildCache` keeps: its age is the age of the library read.
protocol TasteSnapshot: Sendable {
    var readAt: Date { get }
    var isComplete: Bool { get }
}

/// Builds taste recommendations for the active profile and keeps them for a
/// few minutes, so Home, Discover and Pick Something share one pass. TMDB's
/// recommendations come through Seerr: without Seerr there are none, and Home
/// keeps only its genre shelves. The library itself (`catalog`) needs only Plex.
@MainActor
@Observable
final class TasteRecommender {
    @ObservationIgnored private let plexService: PlexService
    @ObservationIgnored private let seerrService: SeerrService
    @ObservationIgnored private let catalogs = TasteBuildCache<TasteCatalog>()
    @ObservationIgnored private let analyses = TasteBuildCache<TasteAnalysis>()

    init(plexService: PlexService, seerrService: SeerrService) {
        self.plexService = plexService
        self.seerrService = seerrService
    }

    /// Whether ratings feed recommendations for the current profile.
    var isAvailable: Bool { contextKey != nil }

    /// - Parameter force: re-read the library even when the last pass is
    ///   recent (the player closed: what was just watched has changed).
    func homeShelves(itemsPerShelf: Int, force: Bool = false) async -> TasteHomeShelves {
        guard let analysis = await analysis(force: force) else { return TasteHomeShelves() }
        return TasteHomeShelves(
            shelves: TasteScoring.shelves(analysis: analysis, itemsPerShelf: itemsPerShelf),
            ratedItemIDs: analysis.library.ratedItemIDs
        )
    }

    /// - Parameter refresh: start over, Seerr's recommendation pages included
    ///   (pull to refresh).
    func requestableTitles(limit: Int, refresh: Bool = false) async -> [SeerrSearchMedia] {
        guard let analysis = await analysis(force: refresh, refreshesSeerr: refresh) else { return [] }
        return TasteScoring.requestable(analysis: analysis, limit: limit)
    }

    /// The active profile's libraries and seeds. nil without a profile.
    func catalog(force: Bool = false) async -> TasteCatalog? {
        await catalogs.value(force: force, key: { [weak self] in self?.catalogKey }) { [plexService] _ in
            await Self.buildCatalog(plexService: plexService)
        }
    }

    /// Whose library, on which servers, with which ratings. A rating or a
    /// watched mark sent from the app bumps `tasteRevision`, so the next pass
    /// starts over.
    private var catalogKey: String? {
        guard let profileID = plexService.activeProfileID else { return nil }
        return [
            profileID,
            plexService.mergeServerIDs.joined(separator: ","),
            String(plexService.tasteRevision),
        ].joined(separator: "|")
    }

    /// The catalog's context plus Seerr: which one, and its request revision
    /// (a request sent from the app changes what is requestable).
    private var contextKey: String? {
        guard seerrService.isAvailableForCurrentContext, let catalogKey else { return nil }
        return [
            catalogKey,
            String(seerrService.requestRevision),
            seerrService.configuredBaseURL?.absoluteString ?? "",
        ].joined(separator: "|")
    }

    private func analysis(force: Bool, refreshesSeerr: Bool = false) async -> TasteAnalysis? {
        await analyses.value(force: force, key: { [weak self] in self?.contextKey }) { [self, seerrService] force in
            guard let catalog = await catalog(force: force) else { return nil }
            return await Self.buildAnalysis(
                catalog: catalog,
                seerrService: seerrService,
                refreshesSeerr: refreshesSeerr && force
            )
        }
    }

    private static func buildCatalog(plexService: PlexService) async -> TasteCatalog {
        let readAt = Date.now
        let allLibraries = try? await plexService.ensureLibraryOrderLoaded()
        let libraries = (allLibraries ?? []).filter { $0.libraryType == .movie || $0.libraryType == .show }
        // One library failing leaves its titles out; the others still count.
        let itemLists = await RecommendationGenreScoring.concurrentMap(libraries, limit: 4) { library in
            try? await plexService.getTasteLibraryItems(sectionId: library.key, serverID: library.serverID)
        }
        let library = TasteLibrary(items: itemLists.flatMap { $0 ?? [] }, serverOrder: plexService.mergeServerIDs)
        return TasteCatalog(
            library: library,
            seeds: TasteScoring.seeds(in: library, now: .now),
            readAt: readAt,
            isComplete: allLibraries != nil && !itemLists.contains { $0 == nil }
        )
    }

    private static func buildAnalysis(
        catalog: TasteCatalog,
        seerrService: SeerrService,
        refreshesSeerr: Bool
    ) async -> TasteAnalysis {
        // Two pages (40 titles) for a like, one for a dislike.
        let pageRequests: [PageRequest] = catalog.seeds.flatMap { seed in
            (seed.weight > 0 ? [1, 2] : [1]).map { PageRequest(key: seed.key, page: $0) }
        }
        let pages = await RecommendationGenreScoring.concurrentMap(pageRequests, limit: 6) { request in
            (try? await seerrService.recommendations(
                type: request.key.type,
                tmdbID: request.key.tmdbID,
                page: request.page,
                refresh: refreshesSeerr
            )) ?? []
        }
        var recommendations: [TasteTitleKey: [SeerrSearchMedia]] = [:]
        for (request, results) in zip(pageRequests, pages) {
            recommendations[request.key, default: []].append(contentsOf: results)
        }

        return TasteAnalysis(
            library: catalog.library,
            seeds: catalog.seeds,
            candidates: TasteScoring.candidates(seeds: catalog.seeds, recommendations: recommendations),
            readAt: catalog.readAt,
            isComplete: catalog.isComplete
        )
    }

    private struct PageRequest: Sendable {
        let key: TasteTitleKey
        let page: Int
    }
}

/// One value per context (profile, servers, revisions), kept until its
/// library read is ten minutes old (an analysis built late from an older
/// catalog expires with it). A caller that asks while a build for the same
/// context runs joins it, and a build that finishes after its context changed
/// hands over to an unforced one for the new context rather than return
/// stale taste. Nothing is kept from a build that returned nil or read only
/// part of the library.
@MainActor
private final class TasteBuildCache<Value: TasteSnapshot> {
    private var cached: (key: String, value: Value)?
    private var building: (key: String, task: Task<Value?, Never>)?
    private let lifetime: TimeInterval = 10 * 60

    /// - Parameter build: called with `force`, which is false on a hand-over.
    func value(
        force: Bool,
        key currentKey: @escaping @MainActor () -> String?,
        build: @escaping @MainActor (_ force: Bool) async -> Value?
    ) async -> Value? {
        guard let key = currentKey() else { return nil }
        if !force, let cached, cached.key == key,
           Date.now.timeIntervalSince(cached.value.readAt) < lifetime {
            return cached.value
        }

        let value: Value?
        if let building, building.key == key {
            value = await building.task.value
        } else {
            // Unstructured, so a caller that goes away (Home leaving the
            // screen) does not throw away a pass the next caller can use.
            let task = Task { @MainActor in await build(force) }
            building = (key, task)
            value = await task.value
            if building?.key == key { building = nil }
        }

        guard key == currentKey() else { return await self.value(force: false, key: currentKey, build: build) }
        if let value, value.isComplete {
            cached = (key, value)
        }
        return value
    }
}
