import Foundation

/// A title Describe It suggests requesting: on Seerr, out already, not in the
/// library, and nobody has asked for it.
struct PickSomethingRequestable: Identifiable, Sendable {
    let media: SeerrSearchMedia
    let type: SeerrMediaType
    /// Athena's; on the device there is none, and the card shows the overview.
    let reason: String?
    /// What Seerr found on Rotten Tomatoes and IMDb.
    let scores: ReviewScores

    var id: String { media.discoverKey }
}

/// Seerr's popular recent titles of one kind that the household could
/// request, as Athena or `DescribeItRanker` reads them. Ids are positions, so the same list sends
/// the same text and Athena's cached prompt is reused.
struct PickSomethingRequestFeed: Sendable {
    let entries: [AthenaPickRequest.Outside]
    /// Every page and the genre names arrived: worth keeping.
    let isComplete: Bool
    /// `SeerrService.requestRevision` when it was read. A request sent since
    /// makes its request states stale.
    let requestRevision: Int
    private let media: [String: SeerrSearchMedia]

    init(media list: [SeerrSearchMedia], genreNames: [Int: String], isComplete: Bool, requestRevision: Int) {
        var entries: [AthenaPickRequest.Outside] = []
        var media: [String: SeerrSearchMedia] = [:]
        for (index, item) in list.enumerated() {
            let id = "d\(index + 1)"
            media[id] = item
            let names: [String] = (item.genreIds ?? []).compactMap { genreNames[$0] }
            let genres: [String] = names.prefix(12).map { String($0.prefix(60)) }
            var score: Double?
            if let average = item.voteAverage, average > 0 {
                score = (average * 10).rounded() / 10
            }
            entries.append(AthenaPickRequest.Outside(
                id: id,
                title: String(item.displayTitle.prefix(300)),
                year: item.year,
                genres: genres.isEmpty ? nil : genres,
                overview: item.overview?.nilIfEmpty.map { String($0.prefix(200)) },
                tmdb: score
            ))
        }
        self.entries = entries
        self.isComplete = isComplete
        self.requestRevision = requestRevision
        self.media = media
    }

    func media(for id: String) -> SeerrSearchMedia? {
        media[id]
    }
}

private enum FeedSource: Sendable {
    case trending(page: Int)
    case recent(page: Int)
}

/// Describe It's Seerr side: the recent list Athena chooses from, and
/// Athena's suggestions found on Seerr.
struct PickSomethingRequestFinder: Sendable {
    let seerrService: SeerrService

    /// Shown at most.
    static let count = 6
    /// Asked of Athena: some turn out to be in the library already.
    static let askedCount = 8
    static let feedLimit = 60

    /// Trending first, then the year's most popular releases, two pages each.
    @MainActor
    func feed(type: SeerrMediaType, library: TasteLibrary) async -> PickSomethingRequestFeed {
        let service = seerrService
        let revision = service.requestRevision
        async let genreNames = try? service.genreNames(type)
        let sources: [FeedSource] = [.trending(page: 1), .trending(page: 2), .recent(page: 1), .recent(page: 2)]
        let pages: [[SeerrSearchMedia]?] = await RecommendationGenreScoring.concurrentMap(sources) { source in
            switch source {
            case .trending(let page): try? await service.discover(.trending, page: page)
            case .recent(let page): try? await service.recentReleases(type, page: page)
            }
        }
        let names = await genreNames
        let today = Self.today()
        var ids = Set<Int>()
        let media = pages.compactMap { $0 }.joined().filter { media in
            Self.isRequestable(media, type: type, library: library, today: today) && ids.insert(media.id).inserted
        }
        return PickSomethingRequestFeed(
            media: Array(media.prefix(Self.feedLimit)),
            genreNames: names ?? [:],
            isComplete: names != nil && !pages.contains { $0 == nil } && !Task.isCancelled,
            requestRevision: revision
        )
    }

    /// Athena's suggestions found on Seerr, in Athena's order: a title from
    /// the recent list by its id (when the id's title is the one Athena named),
    /// any other by searching its name. Drops what
    /// Seerr can't find, what can't be requested, and what a minimum rating
    /// rules out.
    @MainActor
    func resolve(
        _ suggestions: [AthenaSuggestion],
        feed: PickSomethingRequestFeed,
        type: SeerrMediaType,
        library: TasteLibrary,
        minimums: AthenaMinimums
    ) async -> [PickSomethingRequestable] {
        let service = seerrService
        let found = await RecommendationGenreScoring.concurrentMap(suggestions) { suggestion -> SeerrSearchMedia? in
            if let id = suggestion.discoverId, let media = feed.media(for: id),
               Self.match(suggestion, in: [media], type: type) != nil {
                return media
            }
            guard let results = try? await service.search(query: suggestion.title) else { return nil }
            return Self.match(suggestion, in: results, type: type)
        }

        let today = Self.today()
        var ids = Set<Int>()
        let kept: [(media: SeerrSearchMedia, reason: String?)] = zip(suggestions, found).compactMap { suggestion, media in
            guard let media,
                  Self.isRequestable(media, type: type, library: library, today: today),
                  ids.insert(media.id).inserted else { return nil }
            return (media, suggestion.reason.nilIfEmpty)
        }
        let scores = await RecommendationGenreScoring.concurrentMap(kept.map(\.media)) { media in
            (try? await service.reviewScores(type: type, id: media.id)) ?? ReviewScores()
        }
        let requestables = zip(kept, scores).compactMap { entry, scores in
            scores.meets(minimums)
                ? PickSomethingRequestable(media: entry.media, type: type, reason: entry.reason, scores: scores)
                : nil
        }
        return Array(requestables.prefix(Self.count))
    }

    /// The cards nobody has requested since they were found, read again from
    /// Seerr. One that can't be read stays.
    @MainActor
    func stillRequestable(_ requestables: [PickSomethingRequestable]) async -> [PickSomethingRequestable] {
        let service = seerrService
        let keep = await RecommendationGenreScoring.concurrentMap(requestables) { requestable in
            let id = requestable.media.id
            let mediaInfo: SeerrMediaInfo?
            do {
                mediaInfo = switch requestable.type {
                case .movie: try await service.movieDetails(id: id).mediaInfo
                case .tv: try await service.tvDetails(id: id).mediaInfo
                }
            } catch {
                return true
            }
            return SeerrMediaInfo.isUnrequested(mediaInfo)
        }
        return zip(requestables, keep).compactMap { $1 ? $0 : nil }
    }

    /// Out already (an unreleased title has nothing to download), the
    /// screen's kind, not on any server, and nobody has asked for it.
    static func isRequestable(
        _ media: SeerrSearchMedia,
        type: SeerrMediaType,
        library: TasteLibrary,
        today: String
    ) -> Bool {
        guard media.supportedMediaType == type,
              media.isUnrequested,
              let released = media.releaseDate?.nilIfEmpty ?? media.firstAirDate?.nilIfEmpty,
              released.prefix(10) <= today,
              let key = TasteTitleKey(media: media) else {
            return false
        }
        return library.copies[key] == nil
    }

    /// The search result Athena meant: the screen's kind and the same title,
    /// in the year it gave or one either side (release dates differ between
    /// festivals, countries and TMDB). Failing that, a title that is it before
    /// a colon ("Borat" for TMDB's "Borat: Cultural Learnings of…") in exactly
    /// that year.
    static func match(
        _ suggestion: AthenaSuggestion,
        in results: [SeerrSearchMedia],
        type: SeerrMediaType
    ) -> SeerrSearchMedia? {
        let wanted = normalizedTitle(suggestion.title)
        guard !wanted.isEmpty else { return nil }
        let candidates = results.filter { $0.supportedMediaType == type }
        let exact = candidates.first { media in
            guard normalizedTitle(media.displayTitle) == wanted else { return false }
            guard let year = suggestion.year, let mediaYear = media.year else { return true }
            return abs(year - mediaYear) <= 1
        }
        if let exact { return exact }
        guard let year = suggestion.year else { return nil }
        return candidates.first { media in
            let mainTitle = media.displayTitle.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            return media.year == year && normalizedTitle(mainTitle) == wanted
        }
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: "and")
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Seerr's date form, "2026-10-25".
    static func today() -> String {
        Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }
}
