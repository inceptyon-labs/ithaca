import Foundation

@MainActor
@Observable
final class ShowDetailViewModel {
    enum SeasonItem: Identifiable {
        case plex(PlexSeason)
        case seerr(tvID: Int, season: SeerrSeasonSummary)

        var id: String {
            switch self {
            case .plex(let season): "plex:\(season.ratingKey)"
            case .seerr(let tvID, let season): "seerr:\(tvID):\(season.seasonNumber)"
            }
        }

        var seasonNumber: Int {
            switch self {
            case .plex(let season): season.index
            case .seerr(_, let season): season.seasonNumber
            }
        }
    }

    private let plexService: PlexService
    private let seerrService: SeerrService?
    private let downloadManager: DownloadManager?
    private let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    private let prefersOfflineAvailability: Bool
    /// Server-scoped identity of the show. Seasons, episodes, and artwork all
    /// come from `id.serverID` — a show's children only exist on its own server.
    let id: PlexItemID

    var ratingKey: String { id.ratingKey }

    /// The route's server wins; the download record and the primary server are
    /// only fallbacks for an id that reached us without one (an offline cache).
    var serverID: String? {
        id.serverID
            ?? downloadManager?.serverID(for: id)
            ?? plexService.pool.primary?.serverID
    }

    private(set) var details: PlexMediaDetails?
    private(set) var seasons: [PlexSeason] = []
    private(set) var missingSeerrSeasons: [SeerrSeasonSummary] = []
    private(set) var seerrTVID: Int?
    private(set) var seerrMediaInfo: SeerrMediaInfo?
    /// The tvOS series page shows seasons only and never reads `nextEpisode`,
    /// so it turns this off and skips two requests before first paint.
    @ObservationIgnored var resolvesNextEpisode = true
    /// Seerr enrichment runs after the Plex state is published: it is an
    /// external service and must never hold up the page or the Play button.
    @ObservationIgnored private var seerrTask: Task<Void, Never>?
    private(set) var nextEpisode: PlexEpisode?
    private(set) var nextEpisodeDetails: PlexMediaDetails?
    /// What the card that opened this page was showing. Draws the hero while
    /// `details` loads (`DetailSeeds`).
    let seed: PlexItem?
    private(set) var isLoading = false
    /// Metadata from the last few minutes is on screen and not yet revalidated.
    private var showsRecentData = false
    private(set) var error: String?
    /// A failed action (Mark Watched and the like). Shown as an alert, because
    /// `error` only shows while the screen has no content.
    var actionError: String?
    private(set) var isUsingCachedData = false
    private(set) var offlineStateVersion = 0
    /// Show-level trailers and featurettes. Loaded once per page, after the
    /// details, and never from offline data: they play from the server.
    private(set) var extras: [PlexItem] = []
    @ObservationIgnored private var hasLoadedExtras = false
    @ObservationIgnored private var extrasTask: Task<Void, Never>?
    /// The recent-metadata generation the last load started from. Every
    /// watch-state write moves it, so coming back from a child page that
    /// marked something watched reloads the show.
    @ObservationIgnored private var loadedWatchStateGeneration: Int?

    init(
        id: PlexItemID,
        plexService: PlexService,
        seerrService: SeerrService? = nil,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil,
        prefersOfflineAvailability: Bool = false
    ) {
        self.id = id
        self.seed = DetailSeeds.item(for: id)
        self.plexService = plexService
        self.seerrService = seerrService
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
        self.prefersOfflineAvailability = prefersOfflineAvailability
    }

    func load() async {
        if details != nil, loadedWatchStateGeneration == plexService.mediaDetailsCache.generation {
            startSeerrEnrichment()
            return
        }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        error = nil

        do {
            try await reload()
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Loads the extras in the background after a refresh, so they never hold
    /// up the page. Runs until one load succeeds: a failed first load, Retry,
    /// or offline data that comes back online all try again.
    private func startExtrasLoad() {
        guard !hasLoadedExtras, extrasTask == nil else { return }
        extrasTask = Task { [weak self] in
            await self?.loadExtras()
            self?.extrasTask = nil
        }
    }

    private func loadExtras() async {
        guard !hasLoadedExtras, details != nil, !isUsingCachedData else { return }
        do {
            extras = try await plexService.getExtras(ratingKey: ratingKey, serverID: serverID)
            hasLoadedExtras = true
        } catch {
            // No row; the next refresh tries again.
        }
    }

    /// The trailer the tvOS banner previews: Plex's main trailer, else the first.
    var previewTrailer: PlexItem? {
        PlexItem.previewTrailer(in: extras, primaryExtraKey: details?.primaryExtraKey)
    }

    func markSeason(_ season: PlexSeason, watched: Bool) async {
        do {
            try await plexService.setWatchedAcrossServers(
                watched,
                id: PlexItemID(serverID: season.serverID ?? serverID, ratingKey: season.ratingKey)
            )
            try await reload()
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Rating

    private var pendingRating = PendingTasteRating()

    /// The viewer's rating, shown by the hero's rating button.
    var tasteRating: PlexTasteRating? {
        pendingRating.resolved(stored: details?.userRating)
    }

    /// Saves the rating on every copy of the title, then re-reads the details.
    func rate(_ rating: PlexTasteRating?) async {
        guard details != nil else { return }
        pendingRating.begin(rating)
        defer { pendingRating.end() }
        do {
            try await plexService.setRatingAcrossServers(
                rating,
                id: PlexItemID(serverID: serverID, ratingKey: ratingKey)
            )
        } catch {
            actionError = error.localizedDescription
            return
        }
        if let refreshed = try? await plexService.getMediaDetails(ratingKey: ratingKey, serverID: serverID) {
            details = refreshed
        }
    }

    /// The whole show is "watched" once every episode has been viewed.
    var isWatched: Bool {
        guard let viewed = details?.viewedLeafCount, let total = details?.leafCount, total > 0 else {
            return false
        }
        return viewed >= total
    }

    func toggleWatched() async {
        let target = !isWatched
        do {
            try await plexService.setWatchedAcrossServers(
                target,
                id: PlexItemID(serverID: serverID, ratingKey: ratingKey)
            )
            try await reload()
        } catch {
            actionError = error.localizedDescription
        }
    }

    var genreText: String? {
        guard let genres = details?.genres, !genres.isEmpty else { return nil }
        return genres.prefix(3).map(\.tag).joined(separator: ", ")
    }

    var seasonCountText: String? {
        if !missingSeerrSeasons.isEmpty {
            return MediaTextFormatter.seasonCount(seasonItems.count)
        }
        if let count = details?.childCount, count > 0 {
            return MediaTextFormatter.seasonCount(count)
        }

        return MediaTextFormatter.seasonCount(visibleSeasons.count)
    }

    var episodeCountText: String? {
        if DownloadsFeature.isVisible && isUsingCachedData {
            return MediaTextFormatter.episodeCount(downloadManager?.downloadedEpisodeCount(show: id))
        }
        return MediaTextFormatter.episodeCount(details?.leafCount)
    }

    var visibleSeasons: [PlexSeason] {
        guard DownloadsFeature.isVisible, isUsingCachedData, let downloadManager else { return seasons }
        return seasons.filter { downloadManager.hasDownloadedEpisodes(season: $0.id) }
    }

    var seasonItems: [SeasonItem] {
        let plexItems = visibleSeasons.map(SeasonItem.plex)
        guard let seerrTVID else { return plexItems }
        return (plexItems + missingSeerrSeasons.map {
            .seerr(tvID: seerrTVID, season: $0)
        })
        .sorted { $0.seasonNumber < $1.seasonNumber }
    }

    var showsOfflineAvailability: Bool {
        DownloadsFeature.isVisible && (isUsingCachedData || prefersOfflineAvailability)
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        let path = details != nil ? details?.art : seed?.art
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, serverID: serverID, width: width, height: height)
    }

    func posterURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.thumb)
            ?? plexService.imageURL(for: details?.thumb, serverID: serverID, width: width, height: height)
    }

    func titleLogoURL(width: Int, height: Int) -> URL? {
        let path = details != nil ? details?.clearLogo : seed?.clearLogo
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, serverID: serverID, width: width, height: height)
    }

    func seasonPosterURL(_ season: PlexSeason, width: Int, height: Int) -> URL? {
        let path = season.thumb ?? season.parentThumb ?? season.art
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(
                for: path,
                serverID: season.serverID ?? serverID,
                width: width,
                height: height
            )
    }

    func seasonPosterURL(_ season: SeerrSeasonSummary, width: Int) -> URL? {
        seerrService?.posterURL(path: season.posterPath, width: width)
    }

    func seasonRequestState(_ season: SeerrSeasonSummary) -> SeerrRequestState {
        seerrService?.requestState(
            mediaInfo: seerrMediaInfo,
            seasonNumber: season.seasonNumber
        ) ?? .requestable
    }

    func seasonSubtitle(_ season: PlexSeason) -> String? {
        guard DownloadsFeature.isVisible else {
            return MediaTextFormatter.episodeCount(season.leafCount)
        }

        if let downloadManager {
            let downloadedCount = downloadManager.downloadedEpisodeCount(season: season.id)
            if showsOfflineAvailability {
                let episodeCount = MediaTextFormatter.episodeCount(season.leafCount)
                guard downloadedCount > 0 else {
                    return ["Not downloaded", episodeCount].compactMap { $0 }.joined(separator: " · ")
                }

                let total = season.leafCount ?? downloadedCount
                if downloadedCount >= total {
                    return ["Downloaded", episodeCount].compactMap { $0 }.joined(separator: " · ")
                }
                return "\(downloadedCount) of \(total) downloaded"
            } else if downloadedCount > 0 {
                let total = season.leafCount ?? downloadedCount
                return "\(downloadedCount) of \(total) downloaded"
            }
        }
        return MediaTextFormatter.episodeCount(season.leafCount)
    }

    func seasonProgress(_ season: PlexSeason) -> Double? {
        if DownloadsFeature.isVisible, let downloadManager {
            let downloadedCount = downloadManager.downloadedEpisodeCount(season: season.id)
            if let total = season.leafCount, total > 0, downloadedCount > 0 {
                return Double(downloadedCount) / Double(total)
            }
        }

        // Fully watched seasons show a checkmark next to the title instead of a
        // full progress bar, so suppress the bar once everything has been viewed.
        guard let total = season.leafCount,
              let viewed = season.viewedLeafCount,
              total > 0,
              viewed > 0,
              viewed < total else { return nil }
        return Double(viewed) / Double(total)
    }

    func seasonAvailabilityBadge(_ season: PlexSeason) -> String? {
        guard showsOfflineAvailability, let downloadManager else { return nil }
        let downloadedCount = downloadManager.downloadedEpisodeCount(season: season.id)
        guard downloadedCount > 0 else { return "Not Downloaded" }
        guard let total = season.leafCount, total > 0, downloadedCount < total else { return "Available Offline" }
        return "Partial"
    }

    func isSeasonUnavailableOffline(_ season: PlexSeason) -> Bool {
        guard showsOfflineAvailability, let downloadManager else { return false }
        return !downloadManager.hasDownloadedEpisodes(season: season.id)
    }

    func detailRoute(type: PlexMediaType, id: PlexItemID) -> AppNavigationRoute {
        prefersOfflineAvailability && DownloadsFeature.isVisible
            ? .downloadedMedia(type: type, id: id)
            : .media(type: type, id: id)
    }

    func detailRoute(season: PlexSeason) -> AppNavigationRoute {
        DetailSeeds.remember(season)
        return detailRoute(type: .season, id: season.id)
    }

    func detailRoute(episode: PlexEpisode) -> AppNavigationRoute {
        DetailSeeds.remember(episode)
        return detailRoute(type: .episode, id: episode.id)
    }


    // MARK: - Play Next

    var playButtonLabel: String {
        _ = offlineStateVersion
        guard let ep = nextEpisode else { return "Play" }
        let label = MediaTextFormatter.seasonEpisodeLabel(
            season: ep.parentIndex,
            episode: ep.index
        ) ?? "Episode \(ep.index ?? 1)"
        if isPartiallyWatched(ep) {
            return "Resume · \(label)"
        }
        return "Play · \(label)"
    }

    /// Short play-button label for the show hero: intentionally omits which episode
    /// will resume/play so the primary button stays simple ("Play" / "Resume").
    var playButtonShortLabel: String {
        _ = offlineStateVersion
        guard let ep = nextEpisode else { return "Play" }
        return isPartiallyWatched(ep) ? "Resume" : "Play"
    }

    var nextEpisodeRoute: AppNavigationRoute? {
        guard let nextEpisode else { return nil }
        return detailRoute(episode: nextEpisode)
    }

    var nextSeasonRoute: AppNavigationRoute? {
        guard let seasonRatingKey = nextEpisode?.parentRatingKey else { return nil }
        let seasonID = PlexItemID(serverID: nextEpisode?.serverID ?? serverID, ratingKey: seasonRatingKey)
        if let season = seasons.first(where: { $0.id == seasonID }) {
            return detailRoute(season: season)
        }
        return detailRoute(type: .season, id: seasonID)
    }

    var nextEpisodeMenuLabel: String {
        guard let nextEpisode else { return "Go to Episode" }
        let label = MediaTextFormatter.seasonEpisodeLabel(
            season: nextEpisode.parentIndex,
            episode: nextEpisode.index,
            separator: " "
        ) ?? nextEpisode.title
        return "Go to \(label)"
    }

    var nextSeasonMenuLabel: String {
        guard let nextEpisode else { return "Go to Season" }
        let label = MediaTextFormatter.seasonEpisodeLabel(
            season: nextEpisode.parentIndex,
            episode: nil,
            separator: " "
        ) ?? nextEpisode.parentTitle ?? "Season"
        return "Go to \(label)"
    }

    var nextEpisodePlayableVersions: [PlexMedia] {
        nextEpisodeDetails?.media.filter { !$0.parts.isEmpty } ?? []
    }

    var offlineBannerText: String? {
        guard showsOfflineAvailability else { return nil }
        let downloadedCount = downloadManager?.downloadedEpisodeCount(show: id) ?? 0
        guard let total = details?.leafCount, total > 0, downloadedCount > 0 else {
            return nil
        }

        let baseText = "\(downloadedCount) of \(total) episodes are saved on this device."
        guard downloadedCount < total else { return baseText }
        return "\(baseText) Items marked Not Downloaded require an Internet connection."
    }

    /// Draws the show from this profile's metadata of the last few minutes,
    /// with no request, when its details and non-empty seasons are there. The next
    /// `refresh()` revalidates.
    func seedFromRecent() -> Bool {
        guard details == nil,
              let recentDetails = plexService.recentMediaDetails(for: id),
              let recentSeasons = plexService.recentSeasons(for: id), !recentSeasons.isEmpty else { return false }
        details = recentDetails
        seasons = recentSeasons.sorted { $0.index < $1.index }
        showsRecentData = true
        return true
    }

    private func reload() async throws {
        loadedWatchStateGeneration = plexService.mediaDetailsCache.generation
        // Seed from the offline cache only on a first load; a refresh over live
        // data would flash the downloaded-only season list and offline banner.
        // A live answer from the last few minutes beats the download-time copy;
        // the downloaded seasons are seeded unless recent ones are there.
        if details == nil {
            if let recentDetails = plexService.recentMediaDetails(for: id) {
                details = recentDetails
                showsRecentData = true
            } else if let cachedDetails = downloadManager?.cachedMediaDetails(for: id) {
                details = cachedDetails
                isUsingCachedData = true
            }
            if showsRecentData, let recentSeasons = plexService.recentSeasons(for: id) {
                seasons = recentSeasons.sorted { $0.index < $1.index }
            } else if let cachedSeasons = downloadManager?.cachedSeasons(show: id) {
                seasons = cachedSeasons.sorted { $0.index < $1.index }
                isUsingCachedData = true
            }
        }

        // Context-menu navigation can create transient view/task lifetimes here.
        // Keeping these requests sequential avoids the async-let runtime abort seen in TestFlight.
        do {
            let loadedDetails = try await plexService.getMediaDetails(
                ratingKey: ratingKey,
                serverID: serverID
            )
            let loadedSeasons = try await plexService.getSeasons(
                showKey: ratingKey,
                serverID: serverID
            )
            details = loadedDetails
            seasons = loadedSeasons.sorted { $0.index < $1.index }
            isUsingCachedData = false
            showsRecentData = false
        } catch {
            // Recent metadata without seasons is no page at all: fail like a
            // first load so Retry shows.
            if showsRecentData, seasons.isEmpty {
                details = nil
            }
            if details == nil && seasons.isEmpty {
                throw error
            }
            // Recent metadata that could not be revalidated is offline data.
            if showsRecentData { isUsingCachedData = true }
        }
        if resolvesNextEpisode {
            await resolveNextEpisode()
        }
        startSeerrEnrichment()
        startExtrasLoad()
    }

    private func startSeerrEnrichment() {
        seerrTask?.cancel()
        seerrTask = Task { [weak self] in
            await self?.loadMissingSeerrSeasons()
        }
    }

    private func loadMissingSeerrSeasons() async {
        guard !isUsingCachedData,
              let details,
              let service = seerrService,
              service.isAvailableForCurrentContext,
              let tmdbID = details.guids
                .compactMap({ $0.value(for: "tmdb") })
                .compactMap(Int.init)
                .first else {
            missingSeerrSeasons = []
            seerrTVID = nil
            seerrMediaInfo = nil
            return
        }

        do {
            let seerrDetails = try await service.tvDetails(id: tmdbID)
            guard !Task.isCancelled else { return }
            let existingNumbers = Set(seasons.map(\.index))
            // Assigned only once Seerr answered, so a refresh never drops the
            // season cards on screen while it waits.
            missingSeerrSeasons = seerrDetails.seasons.filter {
                let state = service.requestState(
                    mediaInfo: seerrDetails.mediaInfo,
                    seasonNumber: $0.seasonNumber
                )
                let shouldDisplay = ![.available, .completed, .blocklisted].contains(state)
                return !existingNumbers.contains($0.seasonNumber) &&
                    ($0.seasonNumber > 0 || service.publicSettings?.enableSpecialEpisodes == true) &&
                    shouldDisplay
            }
            seerrTVID = tmdbID
            seerrMediaInfo = seerrDetails.mediaInfo
        } catch {
            // Seerr is additive; its failure must never disturb Plex show details.
        }
    }

    private func resolveNextEpisode() async {
        // The first regular season that isn't fully watched. Specials sort
        // first but are rarely where someone left off, so they only count
        // when the show has nothing else (the tvOS page uses the same rule).
        let regularSeasons = visibleSeasons.filter { $0.index > 0 }
        let candidateSeasons = regularSeasons.isEmpty ? visibleSeasons : regularSeasons
        let targetSeason = candidateSeasons.first(where: { !$0.isFullyWatched })
            ?? candidateSeasons.first

        guard let season = targetSeason else {
            nextEpisode = nil
            nextEpisodeDetails = nil
            return
        }

        do {
            let episodes = try await plexService.getEpisodes(
                seasonKey: season.ratingKey,
                serverID: season.serverID ?? serverID
            )
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            nextEpisode = episodes.first(where: { isPartiallyWatched($0) })
                ?? episodes.first(where: { !isWatched($0) })
                ?? episodes.first
            await loadNextEpisodeDetails()
        } catch {
            let episodes = downloadManager?.cachedEpisodes(season: season.id)?
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) } ?? []
            let playableEpisodes = isUsingCachedData
                ? episodes.filter { downloadManager?.isPlayableOffline(id: $0.id) == true }
                : episodes
            nextEpisode = playableEpisodes.first(where: { isPartiallyWatched($0) })
                ?? playableEpisodes.first(where: { !isWatched($0) })
                ?? playableEpisodes.first
            await loadNextEpisodeDetails()
        }
    }

    private func loadNextEpisodeDetails() async {
        guard let nextEpisode else {
            nextEpisodeDetails = nil
            return
        }

        do {
            nextEpisodeDetails = try await plexService.getMediaDetails(
                ratingKey: nextEpisode.ratingKey,
                serverID: nextEpisode.serverID ?? serverID
            )
        } catch {
            nextEpisodeDetails = downloadManager?.cachedMediaDetails(for: nextEpisode.id)
        }
    }

    private func isWatched(_ episode: PlexEpisode) -> Bool {
        _ = offlineStateVersion
        return offlinePlaybackSyncManager?.effectiveWatched(
            serverID: serverID(for: episode),
            ratingKey: episode.ratingKey,
            fallback: episode.isWatched
        ) ?? episode.isWatched
    }

    private func isPartiallyWatched(_ episode: PlexEpisode) -> Bool {
        guard let offset = effectiveViewOffsetMs(for: episode), offset > 0 else { return false }
        return !isWatched(episode)
    }

    private func effectiveViewOffsetMs(for episode: PlexEpisode) -> Int? {
        offlinePlaybackSyncManager?.effectiveViewOffsetMs(
            serverID: serverID(for: episode),
            ratingKey: episode.ratingKey,
            fallback: episode.viewOffset
        ) ?? episode.viewOffset
    }

    /// An episode decoded from this show's server is already stamped with it;
    /// the download records only answer for an episode restored from a cache.
    ///
    /// The show's own server wins over any rating-key-only guess: an episode of
    /// *this* show can only live on the server the show was read from, whereas
    /// `DownloadManager.record(for:)` matches an unstamped id on the rating key
    /// alone and could hand back an unrelated download from another server.
    private func serverID(for episode: PlexEpisode) -> String? {
        episode.serverID
            ?? downloadManager?.serverID(for: episode.id)
            ?? serverID
    }
}
