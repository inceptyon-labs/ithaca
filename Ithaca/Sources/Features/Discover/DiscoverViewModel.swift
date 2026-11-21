import Foundation
import Observation

/// Seerr's discover lists (trending, popular, upcoming) for the Discover
/// screen, led by "Recommended for You": titles the viewer's taste points to
/// that the library does not have (`TasteRecommender`). Titles already in Plex
/// open their Plex page; everything else opens the Seerr page, where it can be
/// requested.
@MainActor
@Observable
final class DiscoverViewModel {
    struct Row: Identifiable {
        let id: String
        let title: String
        let items: [SeerrSearchMedia]
    }

    private static let recommendedLimit = 20
    /// How long the lists wait for "Recommended for You" so both appear
    /// together. A cold recommendation pass takes longer; its row then joins
    /// the page when it is ready.
    private static let recommendedGrace: Duration = .milliseconds(1500)

    /// "Recommended for You" first, then Seerr's lists.
    var rows: [Row] { (recommendedRow.map { [$0] } ?? []) + listRows }

    private(set) var listRows: [Row] = []
    private(set) var recommendedRow: Row?
    private(set) var isLoading = false
    private(set) var error: String?

    @ObservationIgnored private let seerrService: SeerrService
    @ObservationIgnored private let plexService: PlexService
    @ObservationIgnored private let tasteRecommender: TasteRecommender?
    @ObservationIgnored private var loadedAt: Date?
    /// `SeerrService.requestRevision` when the rows were loaded: a request
    /// sent since makes their badges stale.
    @ObservationIgnored private var loadedRequestRevision: Int?
    @ObservationIgnored private var recommendedTask: Task<Void, Never>?
    @ObservationIgnored private var recommendedIsSettled = false

    /// Request badges go stale as titles are requested and arrive.
    private static let staleAfter: TimeInterval = 10 * 60

    init(seerrService: SeerrService, plexService: PlexService, tasteRecommender: TasteRecommender? = nil) {
        self.seerrService = seerrService
        self.plexService = plexService
        self.tasteRecommender = tasteRecommender
    }

    /// Loads every list side by side. One list failing still shows the others;
    /// all of them failing shows the error.
    ///
    /// - Parameter refreshesRecommendations: start the recommendations over,
    ///   Seerr's pages included (pull to refresh). Otherwise they come from
    ///   the shared pass, which a request sent from the app already renews.
    func load(force: Bool = false, refreshesRecommendations: Bool = false) async {
        guard seerrService.isAvailableForCurrentContext else {
            recommendedTask?.cancel()
            listRows = []
            recommendedRow = nil
            error = nil
            loadedAt = nil
            return
        }
        guard !isLoading, force || loadedAt == nil else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        let requestRevision = seerrService.requestRevision

        loadRecommendations(refresh: refreshesRecommendations)

        let seerrService = seerrService
        let outcomes = await withTaskGroup(
            of: (Int, Result<[SeerrSearchMedia], any Error>).self
        ) { group in
            for (index, list) in SeerrDiscoverList.allCases.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await seerrService.discover(list)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<[SeerrSearchMedia], any Error>)] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let deadline = ContinuousClock.now + Self.recommendedGrace
        while !recommendedIsSettled, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else { return }

        var loadedRows: [Row] = []
        var firstError: (any Error)?
        for (list, outcome) in zip(SeerrDiscoverList.allCases, outcomes) {
            switch outcome {
            case .success(let items):
                // Movie and TV ids are separate TMDB spaces, and a page can
                // repeat a title.
                var seen = Set<String>()
                let unique = items.filter { seen.insert($0.discoverKey).inserted }
                if !unique.isEmpty {
                    loadedRows.append(Row(id: list.rawValue, title: list.title, items: unique))
                }
            case .failure(let failure):
                firstError = firstError ?? failure
            }
        }

        listRows = loadedRows
        loadedAt = .now
        loadedRequestRevision = requestRevision
        if loadedRows.isEmpty, recommendedRow == nil, let firstError {
            error = firstError.localizedDescription
            loadedAt = nil
        }
    }

    /// Reloads after ten minutes, or at once when a request has been sent
    /// since (from a Discover title's page, say).
    func reloadIfStale() async {
        guard let loadedAt else { return }
        let requested = loadedRequestRevision != seerrService.requestRevision
        guard requested || Date.now.timeIntervalSince(loadedAt) > Self.staleAfter else { return }
        await load(force: true)
    }

    private func loadRecommendations(refresh: Bool) {
        recommendedTask?.cancel()
        guard let tasteRecommender else {
            recommendedIsSettled = true
            return
        }
        recommendedIsSettled = false
        recommendedTask = Task { @MainActor [weak self] in
            let items = await tasteRecommender.requestableTitles(limit: Self.recommendedLimit, refresh: refresh)
            guard let self, !Task.isCancelled else { return }
            recommendedRow = items.isEmpty
                ? nil
                : Row(id: "recommended", title: "Recommended for You", items: items)
            recommendedIsSettled = true
        }
    }

    /// A title already in Plex opens its Plex page, which plays it (and, for a
    /// show, offers the missing seasons through Seerr). Seerr often has no
    /// Plex rating key (a title marked available through Radarr or Sonarr), so
    /// those are found by TMDB id when opened.
    func route(for item: SeerrSearchMedia) -> AppNavigationRoute {
        let type = item.supportedMediaType ?? .movie
        guard let mediaInfo = item.mediaInfo,
              mediaInfo.status == .available || mediaInfo.status == .partiallyAvailable else {
            return .seerrMedia(type: type, id: item.id)
        }
        if let ratingKey = mediaInfo.ratingKey?.nilIfEmpty,
           let serverID = plexService.seerrBindingServerID {
            return .media(
                type: type == .tv ? .show : .movie,
                id: PlexItemID(serverID: serverID, ratingKey: ratingKey)
            )
        }
        return .seerrInPlex(type: type, id: item.id, title: item.displayTitle)
    }

    /// `width` is points; Seerr picks a TMDB size bucket by pixel width.
    func posterURL(for item: SeerrSearchMedia, width: Int) -> URL? {
        seerrService.posterURL(
            path: item.posterPath,
            width: plexService.scaledImageDimension(width) ?? width
        )
    }

    /// Requested, available and similar states. Plain "Request" would sit on
    /// almost every card, so it is left off.
    func badge(for item: SeerrSearchMedia) -> String? {
        let state = seerrService.requestState(mediaInfo: item.mediaInfo)
        if case .requestable = state { return nil }
        return state.badgeTitle
    }
}

/// Finds the Plex copy of a Seerr title by TMDB id. Plex cannot filter by an
/// external id, so it searches every server by title and matches the item's
/// `tmdb://` guid and type.
@MainActor
@Observable
final class DiscoverPlexTitleResolver {
    enum State {
        case resolving
        case found(PlexItem)
        case notFound
    }

    private(set) var state = State.resolving

    @ObservationIgnored private let plexService: PlexService

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    func resolve(type: SeerrMediaType, tmdbID: Int, title: String) async {
        let plexType: PlexMediaType = type == .tv ? .show : .movie
        let tmdbValue = String(tmdbID)
        for await result in plexService.streamSearch(query: title) {
            guard case let .success(groups) = result.value else { continue }
            let match = groups.lazy.flatMap(\.items).first { item in
                item.type == plexType
                    && item.guids.contains { $0.value(for: "tmdb") == tmdbValue }
            }
            if let match {
                state = .found(match)
                return
            }
        }
        guard !Task.isCancelled else { return }
        state = .notFound
    }
}

extension SeerrSearchMedia {
    /// Unique within a list: movie and TV ids are separate TMDB spaces.
    var discoverKey: String { "\(mediaType):\(id)" }
}
